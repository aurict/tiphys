//! GNOME / KDE on Wayland through xdg-desktop-portal (session D-Bus, zbus blocking API).
//!
//! - Input: one RemoteDesktop session (keyboard + pointer) combined with ScreenCast monitor sources, which gives
//!   each monitor's stream for absolute pointer motion. The portal asks the user once; with RemoteDesktop v2 the
//!   grant is remembered through a restore token in `$XDG_STATE_HOME/tiphys/portal-restore-token`.
//! - Capture: the Screenshot portal (non-interactive). No PipeWire consumer is built in, so `stream` is a series
//!   of screenshots (a few fps at best).
//! - Monitors: GNOME's `org.gnome.Mutter.DisplayConfig`, KDE's `kscreen-doctor -j`, else one "desktop" monitor
//!   sized from a screenshot. DPMS: Mutter's PowerSaveMode or `kscreen-doctor --dpms`.
//! - No window list: GNOME Shell and KWin offer no unprivileged API for it, so `windows` is not offered.

use super::{
    Backend, CAP_APPS, CAP_AUDIO, CAP_CLIPBOARD, CAP_DPMS, CAP_INPUT, CAP_LAUNCH, CAP_MONITORS, CAP_SCREENSHOT,
    CAP_STREAM, CAP_TEXT, linux,
};
use crate::frame::{self, Frame};
use crate::keys::{Key, char_keysym};
use crate::protocol::{Button, Error, Monitor, Output, Rect, Res, Volume};
use crate::util::{run_ok, which};
use serde_json::Value as Json;
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::mpsc;
use std::time::Duration;
use zbus::blocking::{Connection, Proxy, proxy::Builder};
use zbus::proxy::CacheProperties;
use zbus::zvariant::{OwnedObjectPath, OwnedValue, Value};

const DEST: &str = "org.freedesktop.portal.Desktop";
const PATH: &str = "/org/freedesktop/portal/desktop";
const RD: &str = "org.freedesktop.portal.RemoteDesktop";
const SC: &str = "org.freedesktop.portal.ScreenCast";
const SHOT: &str = "org.freedesktop.portal.Screenshot";
const MUTTER: &str = "org.gnome.Mutter.DisplayConfig";
const MUTTER_PATH: &str = "/org/gnome/Mutter/DisplayConfig";
/// The user may take a while to answer the permission dialog.
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(120);
const BTN_LEFT: i32 = 0x110;
const BTN_RIGHT: i32 = 0x111;
const BTN_MIDDLE: i32 = 0x112;

type Dict = HashMap<String, OwnedValue>;

fn dbus_err(e: impl std::fmt::Display) -> Error {
    Error::failed(format!("portal: {e}"))
}

/// A started RemoteDesktop session and its monitor streams (global logical rectangles).
struct Session {
    handle: OwnedObjectPath,
    streams: Vec<(u32, Rect)>,
}

pub struct Portal {
    conn: Connection,
    /// Unique bus name as used in request paths (":1.42" → "1_42").
    sender: String,
    rd_version: Option<u32>,
    screenshot: bool,
    mutter: bool,
    kscreen: bool,
    wl_clipboard: bool,
    wpctl: bool,
    session: Mutex<Option<Session>>,
    token: AtomicU32,
}

fn proxy<'a>(conn: &Connection, dest: &'a str, path: &'a str, iface: &'a str) -> Res<Proxy<'a>> {
    Builder::new(conn)
        .destination(dest)
        .and_then(|b| b.path(path))
        .and_then(|b| b.interface(iface))
        .map(|b| b.cache_properties(CacheProperties::No))
        .and_then(|b| b.build())
        .map_err(dbus_err)
}

impl Portal {
    pub fn new() -> Result<Self, String> {
        let conn = Connection::session().map_err(|e| e.to_string())?;
        let sender = conn.unique_name().ok_or("no unique bus name")?.trim_start_matches(':').replace('.', "_");
        let version = |iface: &str| proxy(&conn, DEST, PATH, iface).ok()?.get_property::<u32>("version").ok();
        let mutter = proxy(&conn, MUTTER, MUTTER_PATH, MUTTER)
            .ok()
            .is_some_and(|p| p.call_method("GetCurrentState", &()).is_ok());
        Ok(Self {
            rd_version: version(RD),
            screenshot: version(SHOT).is_some(),
            mutter,
            kscreen: which("kscreen-doctor").is_some(),
            wl_clipboard: linux::has_wl_clipboard(),
            wpctl: linux::has_wpctl(),
            session: Mutex::new(None),
            token: AtomicU32::new(0),
            conn,
            sender,
        })
    }

    fn token(&self) -> String {
        format!("tiphys{}_{}", std::process::id(), self.token.fetch_add(1, Ordering::SeqCst))
    }

    /// Calls a portal method that answers through a Request object's `Response` signal.
    /// `call` gets the handle token to put into its options.
    fn request(&self, call: impl FnOnce(&str) -> zbus::Result<()>) -> Res<Dict> {
        let token = self.token();
        let path = format!("{PATH}/request/{}/{token}", self.sender);
        let req = proxy(&self.conn, DEST, &path, "org.freedesktop.portal.Request")?;
        // Subscribe before calling, or a fast answer could be missed.
        let mut signals = req.receive_signal("Response").map_err(dbus_err)?;
        call(&token).map_err(dbus_err)?;
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let _ = tx.send(signals.next().map(|m| m.body().deserialize::<(u32, Dict)>()));
        });
        match rx.recv_timeout(RESPONSE_TIMEOUT) {
            Ok(Some(Ok((0, results)))) => Ok(results),
            Ok(Some(Ok((1, _)))) => Err(Error::permission("the request was declined in the portal dialog")),
            Ok(Some(Ok((code, _)))) => Err(Error::failed(format!("portal request ended with code {code}"))),
            Ok(Some(Err(e))) => Err(dbus_err(e)),
            Ok(None) => Err(dbus_err("connection closed")),
            Err(_) => {
                let _ = req.call_method("Close", &());
                Err(Error::permission("no answer to the portal dialog"))
            }
        }
    }

    fn restore_token_path() -> Option<PathBuf> {
        let base = std::env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .filter(|p| p.is_absolute())
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))?;
        Some(base.join("tiphys/portal-restore-token"))
    }

    fn save_restore_token(token: &str) {
        let Some(p) = Self::restore_token_path() else { return };
        let Some(dir) = p.parent() else { return };
        use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
        let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir);
        let _ = std::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&p)
            .and_then(|mut f| std::io::Write::write_all(&mut f, token.as_bytes()));
    }

    fn start_session(&self) -> Res<Session> {
        let rd = proxy(&self.conn, DEST, PATH, RD)?;
        let sc = proxy(&self.conn, DEST, PATH, SC)?;
        let session_token = self.token();
        let created = self.request(|t| {
            let opts: HashMap<&str, Value> = HashMap::from([
                ("handle_token", Value::from(t)),
                ("session_handle_token", Value::from(session_token.as_str())),
            ]);
            rd.call_method("CreateSession", &(opts,)).map(|_| ())
        })?;
        let handle: String = created
            .get("session_handle")
            .and_then(|v| String::try_from(v.clone()).ok())
            .ok_or_else(|| dbus_err("no session handle"))?;
        let handle = OwnedObjectPath::try_from(handle).map_err(dbus_err)?;
        let restore =
            Self::restore_token_path().and_then(|p| std::fs::read_to_string(p).ok()).filter(|t| !t.trim().is_empty());
        self.request(|t| {
            let mut opts: HashMap<&str, Value> =
                HashMap::from([("handle_token", Value::from(t)), ("types", Value::from(3u32))]);
            if self.rd_version.unwrap_or(1) >= 2 {
                opts.insert("persist_mode", Value::from(2u32));
                if let Some(r) = &restore {
                    opts.insert("restore_token", Value::from(r.trim()));
                }
            }
            rd.call_method("SelectDevices", &(&handle, opts)).map(|_| ())
        })?;
        // Monitor streams give absolute pointer coordinates; without them only relative motion would work.
        let with_streams = self
            .request(|t| {
                let opts: HashMap<&str, Value> = HashMap::from([
                    ("handle_token", Value::from(t)),
                    ("types", Value::from(1u32)),
                    ("multiple", Value::from(true)),
                ]);
                sc.call_method("SelectSources", &(&handle, opts)).map(|_| ())
            })
            .is_ok();
        let started = self.request(|t| {
            let opts: HashMap<&str, Value> = HashMap::from([("handle_token", Value::from(t))]);
            rd.call_method("Start", &(&handle, "", opts)).map(|_| ())
        })?;
        if let Some(t) = started.get("restore_token").and_then(|v| String::try_from(v.clone()).ok()) {
            Self::save_restore_token(&t);
        }
        let streams =
            if with_streams { started.get("streams").map(parse_streams).unwrap_or_default() } else { Vec::new() };
        Ok(Session { handle, streams })
    }

    /// Runs `f` with the session, starting it first if needed; a failed call drops the session (it may have been
    /// closed by the compositor) so the next request starts a new one.
    fn with_session<T>(&self, f: impl FnOnce(&Proxy, &Session) -> zbus::Result<T>) -> Res<T> {
        if self.rd_version.is_none() {
            return Err(Error::unsupported("no RemoteDesktop portal"));
        }
        let mut g = self.session.lock().unwrap_or_else(|e| e.into_inner());
        if g.is_none() {
            *g = Some(self.start_session()?);
        }
        let rd = proxy(&self.conn, DEST, PATH, RD)?;
        let r = f(&rd, g.as_ref().expect("set above"));
        if r.is_err() {
            *g = None;
        }
        r.map_err(dbus_err)
    }

    fn keysym(&self, sym: u32, down: bool) -> Res<()> {
        self.with_session(|rd, s| {
            rd.call_method("NotifyKeyboardKeysym", &(&s.handle, empty(), sym as i32, down as u32)).map(|_| ())
        })
    }

    fn screenshot_png(&self) -> Res<Frame> {
        if !self.screenshot {
            return Err(Error::unsupported("no Screenshot portal"));
        }
        let shot = proxy(&self.conn, DEST, PATH, SHOT)?;
        let res = self.request(|t| {
            let opts: HashMap<&str, Value> =
                HashMap::from([("handle_token", Value::from(t)), ("interactive", Value::from(false))]);
            shot.call_method("Screenshot", &("", opts)).map(|_| ())
        })?;
        let uri: String =
            res.get("uri").and_then(|v| String::try_from(v.clone()).ok()).ok_or_else(|| dbus_err("no uri"))?;
        let path = file_uri_path(&uri).ok_or_else(|| dbus_err("unexpected screenshot uri"))?;
        let bytes = std::fs::read(&path).map_err(|e| Error::failed(format!("screenshot file: {e}")));
        // The file was made for this request only; don't let a stream fill the Pictures folder.
        let _ = std::fs::remove_file(&path);
        frame::decode_png(&bytes?)
    }

    fn mutter_monitors(&self) -> Res<Vec<Monitor>> {
        type Spec = (String, String, String, String);
        type Mode = (String, i32, i32, f64, f64, Vec<f64>, Dict);
        type Phys = (Spec, Vec<Mode>, Dict);
        type Logical = (i32, i32, f64, u32, bool, Vec<Spec>, Dict);
        let p = proxy(&self.conn, MUTTER, MUTTER_PATH, MUTTER)?;
        let (_, phys, logical, props): (u32, Vec<Phys>, Vec<Logical>, Dict) =
            p.call("GetCurrentState", &()).map_err(dbus_err)?;
        // layout-mode 1 = logical (sizes divided by scale), 2 = physical.
        let logical_layout = props.get("layout-mode").and_then(|v| u32::try_from(v).ok()).unwrap_or(1) == 1;
        let mut out = Vec::new();
        for (x, y, scale, transform, primary, specs, _) in logical {
            let Some(spec) = specs.first() else { continue };
            let mode = phys
                .iter()
                .find(|(s, _, _)| s.0 == spec.0)
                .and_then(|(_, modes, _)| {
                    modes.iter().find(|m| m.6.get("is-current").and_then(|v| bool::try_from(v).ok()).unwrap_or(false))
                })
                .map(|m| (m.1, m.2));
            let Some((mut w, mut h)) = mode else { continue };
            if transform % 2 == 1 {
                std::mem::swap(&mut w, &mut h);
            }
            let (w, h) = if logical_layout && scale > 0.0 {
                ((w as f64 / scale).round() as i32, (h as f64 / scale).round() as i32)
            } else {
                (w, h)
            };
            out.push(Monitor { id: spec.0.clone(), name: spec.0.clone(), x, y, w, h, scale, primary });
        }
        Ok(out)
    }

    fn pseudo_monitor(&self) -> Res<Vec<Monitor>> {
        let f = self.screenshot_png()?;
        Ok(vec![Monitor {
            id: "desktop".into(),
            name: "desktop".into(),
            x: 0,
            y: 0,
            w: f.width as i32,
            h: f.height as i32,
            scale: 1.0,
            primary: true,
        }])
    }
}

fn empty() -> HashMap<&'static str, Value<'static>> {
    HashMap::new()
}

fn parse_streams(v: &OwnedValue) -> Vec<(u32, Rect)> {
    let Ok(list) = <Vec<(u32, Dict)>>::try_from(v.clone()) else { return Vec::new() };
    list.into_iter()
        .filter_map(|(node, props)| {
            let pair = |k: &str| <(i32, i32)>::try_from(props.get(k)?.clone()).ok();
            let (x, y) = pair("position").unwrap_or((0, 0));
            let (w, h) = pair("size")?;
            Some((node, Rect { x, y, w, h }))
        })
        .collect()
}

/// `file:///a%20b.png` → `/a b.png`.
fn file_uri_path(uri: &str) -> Option<PathBuf> {
    let rest = uri.strip_prefix("file://")?;
    let bytes = rest.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            let h = std::str::from_utf8(bytes.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(h, 16).ok()?);
            i += 3;
        } else {
            out.push(bytes[i]);
            i += 1;
        }
    }
    use std::os::unix::ffi::OsStringExt;
    let p = PathBuf::from(std::ffi::OsString::from_vec(out));
    p.is_absolute().then_some(p)
}

/// KDE: outputs of `kscreen-doctor -j`.
pub fn parse_kscreen(v: &Json) -> Vec<Monitor> {
    v["outputs"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|o| o["enabled"].as_bool().unwrap_or(false) && o["connected"].as_bool().unwrap_or(true))
        .filter_map(|o| {
            let name = o["name"].as_str()?.to_string();
            let scale = o["scale"].as_f64().filter(|s| *s > 0.0).unwrap_or(1.0);
            let (mut w, mut h) = (o["size"]["width"].as_f64()?, o["size"]["height"].as_f64()?);
            // rotation: 1 none, 2 left, 4 inverted, 8 right.
            if matches!(o["rotation"].as_u64(), Some(2 | 8)) {
                std::mem::swap(&mut w, &mut h);
            }
            Some(Monitor {
                id: name.clone(),
                name,
                x: o["pos"]["x"].as_i64().unwrap_or(0) as i32,
                y: o["pos"]["y"].as_i64().unwrap_or(0) as i32,
                w: (w / scale).round() as i32,
                h: (h / scale).round() as i32,
                scale,
                primary: o["priority"].as_u64() == Some(1) || o["primary"].as_bool() == Some(true),
            })
        })
        .collect()
}

/// Cuts `r` (global logical) out of a screenshot of the whole desktop `desk` (global logical bounds).
fn crop(f: &Frame, desk: Rect, r: Rect) -> Res<Frame> {
    let r = r.intersect(&desk).ok_or_else(|| Error::bad("the area is off screen"))?;
    let s = f.width as f64 / desk.w as f64;
    let px = |v: i32, max: u32| ((v as f64 * s).round() as i64).clamp(0, max as i64) as usize;
    let (x0, y0) = (px(r.x - desk.x, f.width), px(r.y - desk.y, f.height));
    let (x1, y1) = (px(r.x + r.w - desk.x, f.width), px(r.y + r.h - desk.y, f.height));
    if x1 <= x0 || y1 <= y0 {
        return Err(Error::bad("the area is too small"));
    }
    let (w, bpp) = (x1 - x0, f.format.bytes());
    let mut data = Vec::with_capacity(w * (y1 - y0) * bpp);
    for y in y0..y1 {
        let row = y * f.stride + x0 * bpp;
        data.extend_from_slice(&f.data[row..row + w * bpp]);
    }
    Frame::new(w as u32, (y1 - y0) as u32, w * bpp, f.format, data)
}

impl Backend for Portal {
    fn name(&self) -> &'static str {
        "portal"
    }

    fn capabilities(&self) -> Vec<&'static str> {
        let mut c = Vec::new();
        if self.screenshot {
            c.extend([CAP_MONITORS, CAP_SCREENSHOT, CAP_STREAM]);
        } else if self.mutter || self.kscreen {
            c.push(CAP_MONITORS);
        }
        if self.rd_version.is_some() {
            c.extend([CAP_INPUT, CAP_TEXT]);
        }
        c.extend([CAP_APPS, CAP_LAUNCH]);
        if self.mutter || self.kscreen {
            c.push(CAP_DPMS);
        }
        if self.wl_clipboard {
            c.push(CAP_CLIPBOARD);
        }
        if self.wpctl {
            c.push(CAP_AUDIO);
        }
        c
    }

    fn monitors(&self) -> Res<Vec<Monitor>> {
        if self.mutter
            && let Ok(m) = self.mutter_monitors()
            && !m.is_empty()
        {
            return Ok(m);
        }
        if self.kscreen
            && let Ok(out) = run_ok("kscreen-doctor", &["-j"], None)
            && let Ok(v) = serde_json::from_slice::<Json>(&out.stdout)
        {
            let m = parse_kscreen(&v);
            if !m.is_empty() {
                return Ok(m);
            }
        }
        self.pseudo_monitor()
    }

    fn capture(&self, r: Rect) -> Res<Frame> {
        let shot = self.screenshot_png()?;
        let desk = self.monitors().ok().and_then(|m| Rect::union(m.iter().map(Monitor::rect))).unwrap_or(Rect {
            x: 0,
            y: 0,
            w: shot.width as i32,
            h: shot.height as i32,
        });
        crop(&shot, desk, r)
    }

    fn pointer(&self, x: f64, y: f64) -> Res<()> {
        self.with_session(|rd, s| {
            let Some((node, r)) = s.streams.iter().find(|(_, r)| r.contains(x, y)).or(s.streams.first()) else {
                return Err(zbus::Error::Failure("no monitor stream for absolute pointer motion".into()));
            };
            let (lx, ly) =
                ((x - r.x as f64).clamp(0.0, r.w as f64 - 1.0), (y - r.y as f64).clamp(0.0, r.h as f64 - 1.0));
            rd.call_method("NotifyPointerMotionAbsolute", &(&s.handle, empty(), *node, lx, ly)).map(|_| ())
        })
    }

    fn button(&self, button: Button, down: bool) -> Res<()> {
        let b = match button {
            Button::Left => BTN_LEFT,
            Button::Right => BTN_RIGHT,
            Button::Middle => BTN_MIDDLE,
        };
        self.with_session(|rd, s| {
            rd.call_method("NotifyPointerButton", &(&s.handle, empty(), b, down as u32)).map(|_| ())
        })
    }

    fn scroll(&self, dx: i32, dy: i32) -> Res<()> {
        self.with_session(|rd, s| {
            // axis 0 = vertical, 1 = horizontal; positive steps scroll down/right.
            for (axis, steps) in [(0u32, dy), (1u32, dx)] {
                if steps != 0 {
                    rd.call_method("NotifyPointerAxisDiscrete", &(&s.handle, empty(), axis, steps))?;
                }
            }
            Ok(())
        })
    }

    fn key(&self, keys: &[Key]) -> Res<()> {
        for k in keys {
            self.keysym(k.keysym(), true)?;
        }
        for k in keys.iter().rev() {
            self.keysym(k.keysym(), false)?;
        }
        Ok(())
    }

    fn text(&self, text: &str) -> Res<()> {
        // The compositor finds a keycode (and Shift level) for each keysym on the active layout.
        for ch in text.chars() {
            let sym = char_keysym(ch);
            self.keysym(sym, true)?;
            self.keysym(sym, false)?;
        }
        Ok(())
    }

    fn dpms(&self, on: bool) -> Res<()> {
        if self.mutter {
            let p = proxy(&self.conn, MUTTER, MUTTER_PATH, MUTTER)?;
            // 0 = on, 3 = off.
            return p.set_property("PowerSaveMode", if on { 0i32 } else { 3i32 }).map_err(dbus_err);
        }
        if self.kscreen {
            return run_ok("kscreen-doctor", &["--dpms", if on { "on" } else { "off" }], None).map(|_| ());
        }
        Err(Error::unsupported("no DPMS control on this desktop"))
    }

    fn clipboard_get(&self) -> Res<Option<String>> {
        linux::wl_clipboard_get()
    }
    fn clipboard_set(&self, text: &str) -> Res<()> {
        linux::wl_clipboard_set(text)
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::PixelFormat;
    use serde_json::json;

    #[test]
    fn uris() {
        assert_eq!(file_uri_path("file:///tmp/a%20b.png"), Some(PathBuf::from("/tmp/a b.png")));
        assert_eq!(file_uri_path("file:///x/%C3%BC.png"), Some(PathBuf::from("/x/ü.png")));
        assert_eq!(file_uri_path("http://x/y"), None);
        assert_eq!(file_uri_path("file://relative"), None);
        assert_eq!(file_uri_path("file:///bad%2"), None);
    }

    #[test]
    fn kscreen() {
        let v = json!({"outputs": [
            {"name": "DP-1", "enabled": true, "connected": true, "pos": {"x": 0, "y": 0}, "size": {"width": 3840, "height": 2160}, "scale": 2.0, "priority": 1, "rotation": 1},
            {"name": "HDMI-A-1", "enabled": true, "connected": true, "pos": {"x": 1920, "y": 0}, "size": {"width": 1920, "height": 1080}, "scale": 1, "priority": 2, "rotation": 8},
            {"name": "eDP-1", "enabled": false, "connected": true, "pos": {"x": 0, "y": 0}, "size": {"width": 1, "height": 1}}
        ]});
        let m = parse_kscreen(&v);
        assert_eq!(m.len(), 2);
        assert_eq!((m[0].w, m[0].h, m[0].scale, m[0].primary), (1920, 1080, 2.0, true));
        assert_eq!((m[1].x, m[1].w, m[1].h, m[1].primary), (1920, 1080, 1920, false));
    }

    #[test]
    fn crops() {
        // A 2x screenshot of a 100x50 desktop at (−100, 0): pixel value = x coordinate in the image.
        let (w, h) = (200u32, 100u32);
        let data: Vec<u8> = (0..h).flat_map(|_| (0..w).flat_map(|x| [x as u8, 0, 0])).collect();
        let f = Frame::new(w, h, w as usize * 3, PixelFormat::Rgb, data).unwrap();
        let desk = Rect { x: -100, y: 0, w: 100, h: 50 };
        let c = crop(&f, desk, Rect { x: -50, y: 10, w: 10, h: 5 }).unwrap();
        assert_eq!((c.width, c.height), (20, 10));
        assert_eq!(c.data[0], 100);
        // Partly outside: clipped to the desktop.
        let c = crop(&f, desk, Rect { x: -10, y: 45, w: 50, h: 50 }).unwrap();
        assert_eq!((c.width, c.height), (20, 10));
        assert!(crop(&f, desk, Rect { x: 10, y: 0, w: 5, h: 5 }).is_err());
    }
}
