//! X11: EWMH for windows and workspaces, XTest for input, GetImage for capture, RandR for monitors, DPMS for
//! screen power. Pure Rust protocol (x11rb), no Xlib.
//!
//! - Without an EWMH window manager the window list falls back to the root's mapped children.
//! - Text: characters on the current keymap are typed with their keycode (Shift for level 2); others are mapped
//!   temporarily onto an unused keycode (like xdotool), which is restored afterwards.
//! - Coordinates are X11 root pixels (X11 has no logical scale; `scale` is 1).

use super::{
    Backend, CAP_APPS, CAP_AUDIO, CAP_CLIPBOARD, CAP_DPMS, CAP_INPUT, CAP_LAUNCH, CAP_MONITORS, CAP_SCREENSHOT,
    CAP_STREAM, CAP_TEXT, CAP_WINDOW_ACTIONS, CAP_WINDOWS, CAP_WORKSPACES, linux, monitor_at,
};
use crate::frame::{Frame, PixelFormat};
use crate::keys::{Key, char_keysym};
use crate::protocol::{Button, Error, Monitor, Output, Rect, Res, Volume, Window, WindowAction, Workspace, window_id};
use std::sync::Mutex;
use std::time::Duration;
use x11rb::connection::{Connection, RequestConnection};
use x11rb::protocol::dpms::{ConnectionExt as _, DPMSMode};
use x11rb::protocol::randr::ConnectionExt as _;
use x11rb::protocol::xproto::{
    self, AtomEnum, ClientMessageEvent, ConnectionExt as _, EventMask, ImageFormat, MapState,
};
use x11rb::protocol::xtest::ConnectionExt as _;
use x11rb::rust_connection::RustConnection;

const KEY_PRESS: u8 = xproto::KEY_PRESS_EVENT;
const KEY_RELEASE: u8 = xproto::KEY_RELEASE_EVENT;
const BUTTON_PRESS: u8 = xproto::BUTTON_PRESS_EVENT;
const BUTTON_RELEASE: u8 = xproto::BUTTON_RELEASE_EVENT;
const MOTION: u8 = xproto::MOTION_NOTIFY_EVENT;
/// Time for clients to pick up a changed keymap before the key that uses it arrives.
const REMAP_DELAY: Duration = Duration::from_millis(15);
const ICONIC_STATE: u32 = 3;
const ALL_DESKTOPS: u32 = 0xffff_ffff;

fn xerr(e: impl std::fmt::Display) -> Error {
    Error::failed(format!("X11: {e}"))
}

macro_rules! atoms {
    ($($name:ident),* $(,)?) => {
        #[allow(non_snake_case)]
        struct Atoms { $($name: u32,)* }
        impl Atoms {
            #[allow(non_snake_case)]
            fn intern(c: &RustConnection) -> Result<Self, String> {
                $(let $name = c.intern_atom(false, stringify!($name).as_bytes()).map_err(|e| e.to_string())?;)*
                Ok(Self { $($name: $name.reply().map_err(|e| e.to_string())?.atom,)* })
            }
        }
    };
}

atoms!(
    _NET_SUPPORTED,
    _NET_CLIENT_LIST,
    _NET_CLIENT_LIST_STACKING,
    _NET_ACTIVE_WINDOW,
    _NET_CLOSE_WINDOW,
    _NET_WM_NAME,
    _NET_WM_PID,
    _NET_WM_STATE,
    _NET_WM_STATE_HIDDEN,
    _NET_WM_STATE_FULLSCREEN,
    _NET_WM_STATE_MAXIMIZED_VERT,
    _NET_WM_STATE_MAXIMIZED_HORZ,
    _NET_WM_DESKTOP,
    _NET_NUMBER_OF_DESKTOPS,
    _NET_DESKTOP_NAMES,
    _NET_CURRENT_DESKTOP,
    WM_PROTOCOLS,
    WM_DELETE_WINDOW,
    WM_CHANGE_STATE,
    UTF8_STRING,
);

pub struct X11 {
    conn: RustConnection,
    root: u32,
    screen_w: u16,
    screen_h: u16,
    atoms: Atoms,
    xtest: bool,
    dpms: bool,
    randr: bool,
    /// The visual's pixels are 32-bit little-endian BGRX (the only layout we decode).
    bgrx: bool,
    wpctl: bool,
    clipboard: Mutex<Option<arboard::Clipboard>>,
    /// Serializes keymap changes and the key events that depend on them.
    keyboard: Mutex<()>,
}

impl X11 {
    pub fn connect() -> Result<Self, String> {
        let (conn, screen) = x11rb::connect(None).map_err(|e| e.to_string())?;
        let s = &conn.setup().roots[screen];
        let (root, screen_w, screen_h, depth) = (s.root, s.width_in_pixels, s.height_in_pixels, s.root_depth);
        let bgrx = conn.setup().image_byte_order == xproto::ImageOrder::LSB_FIRST
            && conn.setup().pixmap_formats.iter().any(|f| f.depth == depth && f.bits_per_pixel == 32)
            && (depth == 24 || depth == 32);
        let atoms = Atoms::intern(&conn)?;
        let has = |name: &'static str| conn.extension_information(name).ok().flatten().is_some();
        let xtest = has(x11rb::protocol::xtest::X11_EXTENSION_NAME);
        let randr = has(x11rb::protocol::randr::X11_EXTENSION_NAME);
        let dpms = has(x11rb::protocol::dpms::X11_EXTENSION_NAME)
            && conn.dpms_capable().ok().and_then(|c| c.reply().ok()).is_some_and(|r| r.capable);
        Ok(Self {
            conn,
            root,
            screen_w,
            screen_h,
            atoms,
            xtest,
            dpms,
            randr,
            bgrx,
            wpctl: linux::has_wpctl(),
            clipboard: Mutex::new(None),
            keyboard: Mutex::new(()),
        })
    }

    fn prop32(&self, win: u32, prop: u32, ty: impl Into<u32>) -> Res<Vec<u32>> {
        let r = self.conn.get_property(false, win, prop, ty, 0, 4096).map_err(xerr)?.reply().map_err(xerr)?;
        Ok(r.value32().map(|v| v.collect()).unwrap_or_default())
    }

    fn prop_bytes(&self, win: u32, prop: u32, ty: impl Into<u32>) -> Res<Vec<u8>> {
        let r = self.conn.get_property(false, win, prop, ty, 0, 16384).map_err(xerr)?.reply().map_err(xerr)?;
        Ok(r.value)
    }

    fn supports_ewmh(&self, atom: u32) -> bool {
        self.prop32(self.root, self.atoms._NET_SUPPORTED, AtomEnum::ATOM).is_ok_and(|v| v.contains(&atom))
    }

    fn client_list(&self) -> Res<Vec<u32>> {
        // Stacking order (bottom → top) reversed approximates "most recently focused first".
        let mut list = self.prop32(self.root, self.atoms._NET_CLIENT_LIST_STACKING, AtomEnum::WINDOW)?;
        if list.is_empty() {
            list = self.prop32(self.root, self.atoms._NET_CLIENT_LIST, AtomEnum::WINDOW)?;
        }
        if list.is_empty() {
            // No EWMH window manager: mapped top-level windows, stacking order too.
            let tree = self.conn.query_tree(self.root).map_err(xerr)?.reply().map_err(xerr)?;
            list = tree
                .children
                .into_iter()
                .filter(|&w| {
                    self.conn
                        .get_window_attributes(w)
                        .ok()
                        .and_then(|c| c.reply().ok())
                        .is_some_and(|a| a.map_state == MapState::VIEWABLE && !a.override_redirect)
                })
                .collect();
        }
        list.reverse();
        Ok(list)
    }

    fn active(&self) -> Option<u32> {
        let a = self.prop32(self.root, self.atoms._NET_ACTIVE_WINDOW, AtomEnum::WINDOW).ok()?.first().copied();
        match a {
            Some(w) if w != 0 => Some(w),
            _ => {
                let f = self.conn.get_input_focus().ok()?.reply().ok()?.focus;
                (f > 1 && f != self.root).then_some(f)
            }
        }
    }

    fn title(&self, w: u32) -> String {
        let net = self.prop_bytes(w, self.atoms._NET_WM_NAME, self.atoms.UTF8_STRING).unwrap_or_default();
        if !net.is_empty() {
            return String::from_utf8_lossy(&net).into_owned();
        }
        let old = self.prop_bytes(w, AtomEnum::WM_NAME.into(), AtomEnum::STRING).unwrap_or_default();
        // WM_NAME of type STRING is Latin-1.
        old.iter().map(|&b| b as char).collect()
    }

    fn app_id(&self, w: u32) -> String {
        let class = self.prop_bytes(w, AtomEnum::WM_CLASS.into(), AtomEnum::STRING).unwrap_or_default();
        // "instance\0Class\0": the class part names the app.
        let mut parts = class.split(|&b| b == 0).filter(|p| !p.is_empty());
        let instance = parts.next();
        parts.next().or(instance).map(|p| String::from_utf8_lossy(p).into_owned()).unwrap_or_default()
    }

    fn window_info(&self, w: u32, active: Option<u32>, monitors: &[Monitor]) -> Res<Window> {
        let g = self.conn.get_geometry(w).map_err(xerr)?.reply().map_err(xerr)?;
        let t = self.conn.translate_coordinates(w, self.root, 0, 0).map_err(xerr)?.reply().map_err(xerr)?;
        let state = self.prop32(w, self.atoms._NET_WM_STATE, AtomEnum::ATOM).unwrap_or_default();
        let desktop =
            self.prop32(w, self.atoms._NET_WM_DESKTOP, AtomEnum::CARDINAL).unwrap_or_default().first().copied();
        let (x, y, ww, hh) = (t.dst_x as i32, t.dst_y as i32, g.width as i32, g.height as i32);
        Ok(Window {
            id: window_id(w as u64),
            title: self.title(w),
            app_id: self.app_id(w),
            pid: self.prop32(w, self.atoms._NET_WM_PID, AtomEnum::CARDINAL).unwrap_or_default().first().copied(),
            workspace: desktop.filter(|&d| d != ALL_DESKTOPS).map(|d| d.to_string()),
            monitor: monitor_at(monitors, x as f64 + ww as f64 / 2.0, y as f64 + hh as f64 / 2.0),
            x,
            y,
            w: ww,
            h: hh,
            focused: active == Some(w),
            minimized: state.contains(&self.atoms._NET_WM_STATE_HIDDEN),
            fullscreen: state.contains(&self.atoms._NET_WM_STATE_FULLSCREEN),
            floating: false,
        })
    }

    fn known_window(&self, id: u64) -> Res<u32> {
        let w = u32::try_from(id).map_err(|_| Error::not_found("no such window"))?;
        if self.client_list()?.contains(&w) { Ok(w) } else { Err(Error::not_found("no such window")) }
    }

    /// EWMH client message to the root (what pagers send to the window manager).
    fn wm_message(&self, win: u32, ty: u32, data: [u32; 5]) -> Res<()> {
        let ev = ClientMessageEvent::new(32, win, ty, data);
        self.conn
            .send_event(false, self.root, EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY, ev)
            .map_err(xerr)?;
        self.conn.flush().map_err(xerr)
    }

    fn sync(&self) -> Res<()> {
        self.conn.get_input_focus().map_err(xerr)?.reply().map_err(xerr).map(|_| ())
    }

    fn fake(&self, ty: u8, detail: u8, x: i16, y: i16) -> Res<()> {
        let root = if ty == MOTION { self.root } else { x11rb::NONE };
        self.conn.xtest_fake_input(ty, detail, 0, root, x, y, 0).map_err(xerr)?;
        Ok(())
    }

    fn need_xtest(&self) -> Res<()> {
        if self.xtest { Ok(()) } else { Err(Error::unsupported("the X server has no XTest extension")) }
    }

    fn keymap(&self) -> Res<Keymap> {
        let s = self.conn.setup();
        let (min, max) = (s.min_keycode, s.max_keycode);
        let r = self.conn.get_keyboard_mapping(min, max - min + 1).map_err(xerr)?.reply().map_err(xerr)?;
        Ok(Keymap { min, per: r.keysyms_per_keycode, syms: r.keysyms })
    }

    fn tap(&self, code: u8, shift: Option<u8>) -> Res<()> {
        if let Some(s) = shift {
            self.fake(KEY_PRESS, s, 0, 0)?;
        }
        self.fake(KEY_PRESS, code, 0, 0)?;
        self.fake(KEY_RELEASE, code, 0, 0)?;
        if let Some(s) = shift {
            self.fake(KEY_RELEASE, s, 0, 0)?;
        }
        Ok(())
    }

    fn clipboard<T>(&self, f: impl FnOnce(&mut arboard::Clipboard) -> Res<T>) -> Res<T> {
        let mut g = self.clipboard.lock().unwrap_or_else(|e| e.into_inner());
        if g.is_none() {
            *g = Some(arboard::Clipboard::new().map_err(|e| Error::failed(format!("clipboard: {e}")))?);
        }
        f(g.as_mut().expect("set above"))
    }
}

/// Keyboard mapping: `per` keysyms for each keycode from `min`.
struct Keymap {
    min: u8,
    per: u8,
    syms: Vec<u32>,
}

impl Keymap {
    fn codes(&self) -> impl Iterator<Item = (u8, &[u32])> {
        self.syms.chunks(self.per.max(1) as usize).enumerate().map(|(i, s)| (self.min + i as u8, s))
    }

    /// Keycode and whether Shift is needed (levels 1–2 of group 1 only).
    fn find(&self, sym: u32) -> Option<(u8, bool)> {
        let mut shifted = None;
        for (code, s) in self.codes() {
            if s.first() == Some(&sym) {
                return Some((code, false));
            }
            if shifted.is_none() && s.get(1) == Some(&sym) {
                shifted = Some((code, true));
            }
        }
        // A keycode whose only symbol is a letter types its lowercase at level 1 and uppercase with Shift.
        shifted
    }

    /// Highest keycode with no symbols at all (safe to borrow for typing).
    fn spare(&self) -> Option<u8> {
        self.codes().filter(|(_, s)| s.iter().all(|&k| k == 0)).map(|(c, _)| c).last()
    }
}

/// Lowercase/uppercase pairs: X11 maps letters as one keysym per keycode in some keymaps.
fn upper_of(sym: u32) -> Option<u32> {
    let c = char::from_u32(sym)?;
    if c.is_ascii_uppercase() { Some(c.to_ascii_lowercase() as u32) } else { None }
}

impl Backend for X11 {
    fn name(&self) -> &'static str {
        "x11"
    }

    fn capabilities(&self) -> Vec<&'static str> {
        let mut c = vec![CAP_WINDOWS, CAP_WINDOW_ACTIONS];
        if self.supports_ewmh(self.atoms._NET_NUMBER_OF_DESKTOPS)
            || !self
                .prop32(self.root, self.atoms._NET_NUMBER_OF_DESKTOPS, AtomEnum::CARDINAL)
                .unwrap_or_default()
                .is_empty()
        {
            c.push(CAP_WORKSPACES);
        }
        c.push(CAP_MONITORS);
        if self.bgrx {
            c.extend([CAP_SCREENSHOT, CAP_STREAM]);
        }
        if self.xtest {
            c.extend([CAP_INPUT, CAP_TEXT]);
        }
        c.extend([CAP_APPS, CAP_LAUNCH]);
        if self.dpms {
            c.push(CAP_DPMS);
        }
        c.push(CAP_CLIPBOARD);
        if self.wpctl {
            c.push(CAP_AUDIO);
        }
        c
    }

    fn windows(&self) -> Res<Vec<Window>> {
        let active = self.active();
        let monitors = self.monitors().unwrap_or_default();
        let mut out: Vec<Window> =
            self.client_list()?.into_iter().filter_map(|w| self.window_info(w, active, &monitors).ok()).collect();
        // The focused window first, then stacking order.
        out.sort_by_key(|w| !w.focused);
        Ok(out)
    }

    fn focused(&self) -> Res<Option<Window>> {
        let Some(a) = self.active() else { return Ok(None) };
        let monitors = self.monitors().unwrap_or_default();
        Ok(self.window_info(a, Some(a), &monitors).ok())
    }

    fn window_action(&self, id: u64, action: WindowAction) -> Res<()> {
        let w = self.known_window(id)?;
        let a = &self.atoms;
        match action {
            WindowAction::Focus => {
                if self.supports_ewmh(a._NET_ACTIVE_WINDOW) {
                    // source 2 = pager/remote control, so the WM doesn't treat it as focus stealing.
                    self.wm_message(w, a._NET_ACTIVE_WINDOW, [2, 0, 0, 0, 0])
                } else {
                    self.conn.map_window(w).map_err(xerr)?;
                    let aux = xproto::ConfigureWindowAux::new().stack_mode(xproto::StackMode::ABOVE);
                    self.conn.configure_window(w, &aux).map_err(xerr)?;
                    self.conn.set_input_focus(xproto::InputFocus::PARENT, w, x11rb::CURRENT_TIME).map_err(xerr)?;
                    self.sync()
                }
            }
            WindowAction::Close => {
                if self.supports_ewmh(a._NET_CLOSE_WINDOW) {
                    return self.wm_message(w, a._NET_CLOSE_WINDOW, [0, 2, 0, 0, 0]);
                }
                let protocols = self.prop32(w, a.WM_PROTOCOLS, AtomEnum::ATOM).unwrap_or_default();
                if !protocols.contains(&a.WM_DELETE_WINDOW) {
                    return Err(Error::unsupported("the window can't be asked to close"));
                }
                let ev = ClientMessageEvent::new(32, w, a.WM_PROTOCOLS, [a.WM_DELETE_WINDOW, 0, 0, 0, 0]);
                self.conn.send_event(false, w, EventMask::NO_EVENT, ev).map_err(xerr)?;
                self.conn.flush().map_err(xerr)
            }
            WindowAction::Minimize => self.wm_message(w, a.WM_CHANGE_STATE, [ICONIC_STATE, 0, 0, 0, 0]),
            // _NET_WM_STATE: action 2 = toggle, source 2.
            WindowAction::Maximize => self.wm_message(
                w,
                a._NET_WM_STATE,
                [2, a._NET_WM_STATE_MAXIMIZED_VERT, a._NET_WM_STATE_MAXIMIZED_HORZ, 2, 0],
            ),
            WindowAction::Fullscreen => self.wm_message(w, a._NET_WM_STATE, [2, a._NET_WM_STATE_FULLSCREEN, 0, 2, 0]),
            WindowAction::Float => Err(Error::unsupported("X11 window managers have no common floating toggle")),
        }
    }

    fn workspaces(&self) -> Res<Vec<Workspace>> {
        let a = &self.atoms;
        let n = self.prop32(self.root, a._NET_NUMBER_OF_DESKTOPS, AtomEnum::CARDINAL)?.first().copied().unwrap_or(0);
        let current = self.prop32(self.root, a._NET_CURRENT_DESKTOP, AtomEnum::CARDINAL)?.first().copied();
        let names = self.prop_bytes(self.root, a._NET_DESKTOP_NAMES, a.UTF8_STRING).unwrap_or_default();
        let names: Vec<String> = names.split(|&b| b == 0).map(|s| String::from_utf8_lossy(s).into_owned()).collect();
        Ok((0..n.min(64))
            .map(|i| Workspace {
                id: i.to_string(),
                name: names.get(i as usize).filter(|s| !s.is_empty()).cloned().unwrap_or_else(|| (i + 1).to_string()),
                focused: current == Some(i),
                monitor: None,
            })
            .collect())
    }

    fn switch_workspace(&self, id: &str) -> Res<()> {
        let i = self.workspace_index(id)?;
        self.wm_message(self.root, self.atoms._NET_CURRENT_DESKTOP, [i, 0, 0, 0, 0])
    }

    fn move_to_workspace(&self, window: u64, workspace: &str) -> Res<()> {
        let w = self.known_window(window)?;
        let i = self.workspace_index(workspace)?;
        self.wm_message(w, self.atoms._NET_WM_DESKTOP, [i, 2, 0, 0, 0])
    }

    fn monitors(&self) -> Res<Vec<Monitor>> {
        let whole = || Monitor {
            id: "screen".into(),
            name: "screen".into(),
            x: 0,
            y: 0,
            w: self.screen_w as i32,
            h: self.screen_h as i32,
            scale: 1.0,
            primary: true,
        };
        if !self.randr {
            return Ok(vec![whole()]);
        }
        let reply = match self.conn.randr_get_monitors(self.root, true).map_err(xerr)?.reply() {
            Ok(r) => r,
            Err(_) => return Ok(vec![whole()]), // RandR < 1.5
        };
        let mut out = Vec::new();
        for m in reply.monitors {
            let name = self
                .conn
                .get_atom_name(m.name)
                .ok()
                .and_then(|c| c.reply().ok())
                .map(|r| String::from_utf8_lossy(&r.name).into_owned())
                .unwrap_or_else(|| format!("monitor-{}", m.name));
            out.push(Monitor {
                id: name.clone(),
                name,
                x: m.x as i32,
                y: m.y as i32,
                w: m.width as i32,
                h: m.height as i32,
                scale: 1.0,
                primary: m.primary,
            });
        }
        if out.is_empty() {
            out.push(whole());
        }
        if !out.iter().any(|m| m.primary) {
            out[0].primary = true;
        }
        Ok(out)
    }

    fn capture(&self, r: Rect) -> Res<Frame> {
        if !self.bgrx {
            return Err(Error::unsupported("unsupported X visual for capture"));
        }
        let screen = Rect { x: 0, y: 0, w: self.screen_w as i32, h: self.screen_h as i32 };
        let r = r.intersect(&screen).ok_or_else(|| Error::bad("the area is off screen"))?;
        let mut data = Vec::with_capacity(r.w as usize * r.h as usize * 4);
        // Bands keep each reply below the maximum request/reply size of servers without BIG-REQUESTS replies.
        let band = (4 * 1024 * 1024 / (r.w as usize * 4)).clamp(1, r.h as usize) as i32;
        let mut y = r.y;
        while y < r.y + r.h {
            let h = band.min(r.y + r.h - y);
            let img = self
                .conn
                .get_image(ImageFormat::Z_PIXMAP, self.root, r.x as i16, y as i16, r.w as u16, h as u16, !0)
                .map_err(xerr)?
                .reply()
                .map_err(xerr)?;
            data.extend_from_slice(&img.data);
            y += h;
        }
        Frame::new(r.w as u32, r.h as u32, r.w as usize * 4, PixelFormat::Bgrx, data)
    }

    fn pointer(&self, x: f64, y: f64) -> Res<()> {
        self.need_xtest()?;
        self.fake(MOTION, 0, x.round().clamp(-32768.0, 32767.0) as i16, y.round().clamp(-32768.0, 32767.0) as i16)?;
        self.sync()
    }

    fn button(&self, button: Button, down: bool) -> Res<()> {
        self.need_xtest()?;
        let b = match button {
            Button::Left => 1,
            Button::Middle => 2,
            Button::Right => 3,
        };
        self.fake(if down { BUTTON_PRESS } else { BUTTON_RELEASE }, b, 0, 0)?;
        self.sync()
    }

    fn scroll(&self, dx: i32, dy: i32) -> Res<()> {
        self.need_xtest()?;
        // Buttons 4/5 = up/down, 6/7 = left/right; one press per notch.
        let steps = [(dy, 5u8, 4u8), (dx, 7, 6)];
        for (n, pos, neg) in steps {
            let b = if n > 0 { pos } else { neg };
            for _ in 0..n.unsigned_abs() {
                self.fake(BUTTON_PRESS, b, 0, 0)?;
                self.fake(BUTTON_RELEASE, b, 0, 0)?;
            }
        }
        self.sync()
    }

    fn key(&self, keys: &[Key]) -> Res<()> {
        self.need_xtest()?;
        let _g = self.keyboard.lock().unwrap_or_else(|e| e.into_inner());
        let map = self.keymap()?;
        let codes = keys
            .iter()
            .map(|k| {
                map.find(k.keysym()).map(|(c, _)| c).ok_or_else(|| Error::unsupported("the keymap has no such key"))
            })
            .collect::<Res<Vec<u8>>>()?;
        for &c in &codes {
            self.fake(KEY_PRESS, c, 0, 0)?;
        }
        for &c in codes.iter().rev() {
            self.fake(KEY_RELEASE, c, 0, 0)?;
        }
        self.sync()
    }

    fn text(&self, text: &str) -> Res<()> {
        self.need_xtest()?;
        let _g = self.keyboard.lock().unwrap_or_else(|e| e.into_inner());
        let map = self.keymap()?;
        let shift = map.find(Key::Shift.keysym()).map(|(c, _)| c);
        let spare = map.spare();
        let mut borrowed = false;
        let result = (|| {
            for ch in text.chars() {
                let sym = char_keysym(ch);
                let found = map.find(sym).or_else(|| upper_of(sym).and_then(|l| map.find(l)).map(|(c, _)| (c, true)));
                match found {
                    Some((code, false)) => self.tap(code, None)?,
                    Some((code, true)) if shift.is_some() => self.tap(code, shift)?,
                    _ => {
                        let code = spare.ok_or_else(|| Error::unsupported("no free keycode to type this character"))?;
                        let per = map.per.max(1) as usize;
                        let mut syms = vec![0u32; per];
                        syms[0] = sym;
                        if per > 1 {
                            syms[1] = sym;
                        }
                        self.conn.change_keyboard_mapping(1, code, per as u8, &syms).map_err(xerr)?;
                        borrowed = true;
                        self.sync()?;
                        std::thread::sleep(REMAP_DELAY);
                        self.tap(code, None)?;
                        self.sync()?;
                        std::thread::sleep(REMAP_DELAY);
                    }
                }
            }
            self.sync()
        })();
        if borrowed && let Some(code) = spare {
            let _ = self.conn.change_keyboard_mapping(1, code, map.per.max(1), &vec![0; map.per.max(1) as usize]);
            let _ = self.sync();
        }
        result
    }

    fn dpms(&self, on: bool) -> Res<()> {
        if !self.dpms {
            return Err(Error::unsupported("the X server has no DPMS"));
        }
        self.conn.dpms_enable().map_err(xerr)?;
        self.conn.dpms_force_level(if on { DPMSMode::ON } else { DPMSMode::OFF }).map_err(xerr)?;
        self.sync()
    }

    fn clipboard_get(&self) -> Res<Option<String>> {
        self.clipboard(|c| match c.get_text() {
            Ok(t) => Ok(Some(t)),
            Err(arboard::Error::ContentNotAvailable) => Ok(None),
            Err(e) => Err(Error::failed(format!("clipboard: {e}"))),
        })
    }

    fn clipboard_set(&self, text: &str) -> Res<()> {
        // The clipboard object stays alive with the helper, so the selection is served until we exit
        // (a clipboard manager keeps it after that).
        self.clipboard(|c| c.set_text(text).map_err(|e| Error::failed(format!("clipboard: {e}"))))
    }

    fn volume(&self) -> Res<Volume> {
        linux::volume()
    }
    fn set_volume(&self, percent: Option<u32>, muted: Option<bool>) -> Res<Volume> {
        linux::set_volume(percent, muted)
    }
    fn outputs(&self) -> Res<Vec<Output>> {
        linux::outputs()
    }
    fn set_output(&self, id: &str) -> Res<Vec<Output>> {
        linux::set_output(id)
    }
}

impl X11 {
    fn workspace_index(&self, id: &str) -> Res<u32> {
        let n = self
            .prop32(self.root, self.atoms._NET_NUMBER_OF_DESKTOPS, AtomEnum::CARDINAL)?
            .first()
            .copied()
            .unwrap_or(0);
        id.parse::<u32>().ok().filter(|&i| i < n).ok_or_else(|| Error::not_found("no such workspace"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keymap_lookup() {
        // keycodes 8.. with 2 keysyms each: 8 = a/A, 9 = 1/!, 10 = empty, 11 = Shift_L, 12 = empty
        let map = Keymap { min: 8, per: 2, syms: vec![0x61, 0x41, 0x31, 0x21, 0, 0, 0xffe1, 0, 0, 0] };
        assert_eq!(map.find(0x61), Some((8, false)));
        assert_eq!(map.find(0x41), Some((8, true)));
        assert_eq!(map.find(0x21), Some((9, true)));
        assert_eq!(map.find(0xffe1), Some((11, false)));
        assert_eq!(map.find(0x0100_011f), None);
        assert_eq!(map.spare(), Some(12));
        assert_eq!(upper_of(0x41), Some(0x61));
        assert_eq!(upper_of(0x61), None);
    }
}
