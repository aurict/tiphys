//! macOS: CGWindowList for windows, the Accessibility (AX) API for window actions, CGEvent for input (Unicode
//! text through CGEventKeyboardSetUnicodeString), CGWindowListCreateImage for capture.
//!
//! - Coordinates are global points (CoreGraphics' space, origin at the main display's top-left).
//! - Input and window actions need Accessibility permission, capture (and other apps' window titles) Screen
//!   Recording permission; without them the answer is `permission` naming the setting, and macOS is asked once to
//!   show its prompt.
//! - Only on-screen windows are listed (minimized ones are off screen). Spaces have no public API: no workspaces.
//! - Media keys (play/pause, next, previous), Insert and PrintScreen have no keycode here → `unsupported`.
//! - Volume through `osascript`, output list through `system_profiler`; switching outputs needs
//!   `SwitchAudioSource` (Homebrew `switchaudio-osx`).

#![allow(unsafe_code)]

use super::macos_parse;
use super::{
    Backend, CAP_APPS, CAP_AUDIO, CAP_CLIPBOARD, CAP_DPMS, CAP_INPUT, CAP_LAUNCH, CAP_MONITORS, CAP_SCREENSHOT,
    CAP_STREAM, CAP_TEXT, CAP_WINDOW_ACTIONS, CAP_WINDOWS,
};
use crate::frame::{Frame, PixelFormat};
use crate::keys::Key;
use crate::protocol::{Button, Error, Monitor, Output, Rect, Res, Volume, Window, WindowAction, window_id};
use crate::util::{run_ok, spawn_detached, which};
use core_foundation::array::CFArray;
use core_foundation::base::{CFType, CFTypeRef, TCFType};
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
use core_foundation::number::CFNumber;
use core_foundation::string::{CFString, CFStringRef};
use core_graphics::display::CGDisplay;
use core_graphics::event::{
    CGEvent, CGEventFlags, CGEventTapLocation, CGEventType, CGMouseButton, EventField, ScrollEventUnit,
};
use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};
use core_graphics::geometry::{CGPoint, CGRect, CGSize};
use core_graphics::window::{
    copy_window_info, create_image, kCGNullWindowID, kCGWindowImageBestResolution, kCGWindowListExcludeDesktopElements,
    kCGWindowListOptionOnScreenOnly,
};
use std::ffi::{OsStr, c_void};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};

#[link(name = "ApplicationServices", kind = "framework")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(options: CFDictionaryRef) -> bool;
    fn AXUIElementCreateApplication(pid: i32) -> CFTypeRef;
    fn AXUIElementCopyAttributeValue(element: CFTypeRef, attribute: CFStringRef, value: *mut CFTypeRef) -> i32;
    fn AXUIElementSetAttributeValue(element: CFTypeRef, attribute: CFStringRef, value: CFTypeRef) -> i32;
    fn AXUIElementPerformAction(element: CFTypeRef, action: CFStringRef) -> i32;
    /// Private but stable since 10.x and used widely (Hammerspoon, yabai, AltTab): AX element → CGWindowID.
    fn _AXUIElementGetWindow(element: CFTypeRef, id: *mut u32) -> i32;
}

#[link(name = "CoreGraphics", kind = "framework")]
unsafe extern "C" {
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

const AX_SUCCESS: i32 = 0;
const AX_API_DISABLED: i32 = -25211;
const AX_NOT_IMPLEMENTED: i32 = -25208;
/// CGEventKeyboardSetUnicodeString takes at most 20 UTF-16 units per event.
const TEXT_CHUNK: usize = 20;

type Dict = CFDictionary<CFString, CFType>;

pub struct Mac {
    /// The button held down, so pointer motion is posted as a drag.
    held: Mutex<Option<Button>>,
    prompted_ax: AtomicBool,
    prompted_capture: AtomicBool,
    switch_audio: bool,
}

impl Mac {
    pub fn new() -> Self {
        Self {
            held: Mutex::new(None),
            prompted_ax: AtomicBool::new(false),
            prompted_capture: AtomicBool::new(false),
            switch_audio: which("SwitchAudioSource").is_some(),
        }
    }

    /// Accessibility permission (input, window actions); asks macOS to show its prompt the first time.
    fn need_ax(&self) -> Res<()> {
        // SAFETY: no arguments.
        if unsafe { AXIsProcessTrusted() } {
            return Ok(());
        }
        if !self.prompted_ax.swap(true, Ordering::SeqCst) {
            let key = CFString::from_static_string("AXTrustedCheckOptionPrompt");
            let opts = CFDictionary::from_CFType_pairs(&[(key.as_CFType(), CFBoolean::true_value().as_CFType())]);
            // SAFETY: `opts` is a valid dictionary that lives through the call.
            unsafe { AXIsProcessTrustedWithOptions(opts.as_concrete_TypeRef()) };
        }
        Err(Error::permission(
            "Accessibility permission is missing (System Settings → Privacy & Security → Accessibility)",
        ))
    }

    fn need_capture(&self) -> Res<()> {
        // SAFETY: no arguments.
        if unsafe { CGPreflightScreenCaptureAccess() } {
            return Ok(());
        }
        if !self.prompted_capture.swap(true, Ordering::SeqCst) {
            // SAFETY: no arguments; shows the system prompt once.
            unsafe { CGRequestScreenCaptureAccess() };
        }
        Err(Error::permission(
            "Screen Recording permission is missing (System Settings → Privacy & Security → Screen Recording)",
        ))
    }
}

// =====================================================================
// CoreFoundation helpers

fn key(k: &'static str) -> CFString {
    CFString::from_static_string(k)
}

fn num(d: &Dict, k: &'static str) -> Option<f64> {
    d.find(key(k))?.downcast::<CFNumber>()?.to_f64()
}

fn text(d: &Dict, k: &'static str) -> Option<String> {
    Some(d.find(key(k))?.downcast::<CFString>()?.to_string())
}

fn sub_dict(d: &Dict, k: &'static str) -> Option<Dict> {
    let untyped = d.find(key(k))?.downcast::<CFDictionary>()?;
    // SAFETY: the reference is a live CFDictionary (checked by downcast); get rule retains it.
    Some(unsafe { Dict::wrap_under_get_rule(untyped.as_concrete_TypeRef()) })
}

/// A window from the CGWindowList: its info and owner pid.
struct CgWindow {
    window: Window,
    pid: i32,
}

/// On-screen normal windows (layer 0), front to back.
fn cg_windows() -> Vec<CgWindow> {
    let Some(list) =
        copy_window_info(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID)
    else {
        return Vec::new();
    };
    let monitors = displays();
    let mut out = Vec::new();
    for item in list.iter() {
        let ptr: *const c_void = *item;
        // SAFETY: CGWindowListCopyWindowInfo returns an array of CFDictionary; get rule retains each.
        let d = unsafe { Dict::wrap_under_get_rule(ptr as CFDictionaryRef) };
        if num(&d, "kCGWindowLayer") != Some(0.0) {
            continue;
        }
        let Some(b) = sub_dict(&d, "kCGWindowBounds") else { continue };
        let (x, y, w, h) = (num(&b, "X"), num(&b, "Y"), num(&b, "Width"), num(&b, "Height"));
        let (Some(x), Some(y), Some(w), Some(h)) = (x, y, w, h) else { continue };
        if w < 2.0 || h < 2.0 {
            continue;
        }
        let Some(id) = num(&d, "kCGWindowNumber") else { continue };
        let pid = num(&d, "kCGWindowOwnerPID").unwrap_or(0.0) as i32;
        let owner = text(&d, "kCGWindowOwnerName").unwrap_or_default();
        // Other apps' titles need Screen Recording permission; the app name stands in without it.
        let title = text(&d, "kCGWindowName").filter(|t| !t.is_empty()).unwrap_or_else(|| owner.clone());
        let (cx, cy) = (x + w / 2.0, y + h / 2.0);
        out.push(CgWindow {
            pid,
            window: Window {
                id: window_id(id as u64),
                title,
                app_id: owner,
                pid: (pid > 0).then_some(pid as u32),
                workspace: None,
                monitor: monitors.iter().find(|m| m.rect().contains(cx, cy)).map(|m| m.id.clone()),
                x: x.round() as i32,
                y: y.round() as i32,
                w: w.round() as i32,
                h: h.round() as i32,
                focused: false,
                minimized: false,
                fullscreen: monitors
                    .iter()
                    .any(|m| m.x == x as i32 && m.y == y as i32 && m.w == w as i32 && m.h == h as i32),
                floating: false,
            },
        });
    }
    // The frontmost normal window belongs to the active app.
    if let Some(first) = out.first_mut() {
        first.window.focused = true;
    }
    out
}

fn displays() -> Vec<Monitor> {
    let Ok(ids) = CGDisplay::active_displays() else { return Vec::new() };
    ids.into_iter()
        .map(|id| {
            let d = CGDisplay::new(id);
            let b = d.bounds();
            let scale = if b.size.width > 0.0 { d.pixels_wide() as f64 / b.size.width } else { 1.0 };
            Monitor {
                id: id.to_string(),
                name: if d.is_builtin() { "Built-in Display".to_string() } else { format!("Display {id}") },
                x: b.origin.x.round() as i32,
                y: b.origin.y.round() as i32,
                w: b.size.width.round() as i32,
                h: b.size.height.round() as i32,
                scale,
                primary: d.is_main(),
            }
        })
        .collect()
}

// =====================================================================
// Accessibility

fn ax_check(code: i32) -> Res<()> {
    match code {
        AX_SUCCESS => Ok(()),
        AX_API_DISABLED => Err(Error::permission("Accessibility permission is missing")),
        AX_NOT_IMPLEMENTED => Err(Error::unsupported("the app doesn't support this")),
        c => Err(Error::failed(format!("Accessibility error {c}"))),
    }
}

fn ax_copy(el: &CFType, attr: &'static str) -> Res<CFType> {
    let mut v: CFTypeRef = std::ptr::null();
    // SAFETY: `el` is a live AX element; on success `v` is a +1 reference that the wrapper releases.
    unsafe {
        ax_check(AXUIElementCopyAttributeValue(el.as_CFTypeRef(), key(attr).as_concrete_TypeRef(), &mut v))?;
        if v.is_null() {
            return Err(Error::failed("empty Accessibility value"));
        }
        Ok(CFType::wrap_under_create_rule(v))
    }
}

fn ax_set(el: &CFType, attr: &'static str, value: &CFType) -> Res<()> {
    // SAFETY: all references are live for the call.
    ax_check(unsafe {
        AXUIElementSetAttributeValue(el.as_CFTypeRef(), key(attr).as_concrete_TypeRef(), value.as_CFTypeRef())
    })
}

fn ax_action(el: &CFType, action: &'static str) -> Res<()> {
    // SAFETY: all references are live for the call.
    ax_check(unsafe { AXUIElementPerformAction(el.as_CFTypeRef(), key(action).as_concrete_TypeRef()) })
}

fn ax_app(pid: i32) -> CFType {
    // SAFETY: returns a +1 reference (never null for a pid) that the wrapper releases.
    unsafe { CFType::wrap_under_create_rule(AXUIElementCreateApplication(pid)) }
}

/// The app element and the AX window whose CGWindowID is `wid`.
fn ax_window(pid: i32, wid: u32) -> Res<(CFType, CFType)> {
    let app = ax_app(pid);
    let wins = ax_copy(&app, "AXWindows")?.downcast_into::<CFArray>().ok_or_else(|| Error::failed("no window list"))?;
    for item in wins.iter() {
        let ptr: *const c_void = *item;
        let mut id = 0u32;
        // SAFETY: the array holds AX elements; `id` outlives the call.
        if unsafe { _AXUIElementGetWindow(ptr, &mut id) } == AX_SUCCESS && id == wid {
            // SAFETY: the element is alive while `wins` is; get rule retains it.
            return Ok((app, unsafe { CFType::wrap_under_get_rule(ptr) }));
        }
    }
    Err(Error::not_found("the window is not reachable through Accessibility"))
}

fn cf_bool(b: bool) -> CFType {
    if b { CFBoolean::true_value().as_CFType() } else { CFBoolean::false_value().as_CFType() }
}

// =====================================================================
// input

fn source() -> Res<CGEventSource> {
    CGEventSource::new(CGEventSourceStateID::HIDSystemState).map_err(|_| Error::failed("no event source"))
}

fn post(e: Result<CGEvent, ()>) -> Res<()> {
    e.map_err(|_| Error::failed("could not create the event"))?.post(CGEventTapLocation::HID);
    Ok(())
}

fn cursor() -> Res<CGPoint> {
    Ok(CGEvent::new(source()?).map_err(|_| Error::failed("could not read the pointer"))?.location())
}

fn mouse_parts(b: Button) -> (CGMouseButton, CGEventType, CGEventType, CGEventType) {
    match b {
        Button::Left => {
            (CGMouseButton::Left, CGEventType::LeftMouseDown, CGEventType::LeftMouseUp, CGEventType::LeftMouseDragged)
        }
        Button::Right => (
            CGMouseButton::Right,
            CGEventType::RightMouseDown,
            CGEventType::RightMouseUp,
            CGEventType::RightMouseDragged,
        ),
        Button::Middle => (
            CGMouseButton::Center,
            CGEventType::OtherMouseDown,
            CGEventType::OtherMouseUp,
            CGEventType::OtherMouseDragged,
        ),
    }
}

fn flags_for(k: Key) -> CGEventFlags {
    match k {
        Key::Ctrl => CGEventFlags::CGEventFlagControl,
        Key::Shift => CGEventFlags::CGEventFlagShift,
        Key::Alt => CGEventFlags::CGEventFlagAlternate,
        Key::Super => CGEventFlags::CGEventFlagCommand,
        _ => CGEventFlags::CGEventFlagNull,
    }
}

/// UTF-16 chunks of at most TEXT_CHUNK units that never split a surrogate pair.
fn utf16_chunks(s: &str) -> Vec<Vec<u16>> {
    let mut out: Vec<Vec<u16>> = Vec::new();
    for c in s.chars() {
        let mut b = [0u16; 2];
        let units = c.encode_utf16(&mut b);
        match out.last_mut() {
            Some(last) if last.len() + units.len() <= TEXT_CHUNK => last.extend_from_slice(units),
            _ => out.push(units.to_vec()),
        }
    }
    out
}

impl Backend for Mac {
    fn name(&self) -> &'static str {
        "macos"
    }

    fn capabilities(&self) -> Vec<&'static str> {
        // Permissions are checked per request (they can be granted while we run).
        vec![
            CAP_WINDOWS,
            CAP_WINDOW_ACTIONS,
            CAP_MONITORS,
            CAP_SCREENSHOT,
            CAP_STREAM,
            CAP_INPUT,
            CAP_TEXT,
            CAP_APPS,
            CAP_LAUNCH,
            CAP_DPMS,
            CAP_CLIPBOARD,
            CAP_AUDIO,
        ]
    }

    fn windows(&self) -> Res<Vec<Window>> {
        Ok(cg_windows().into_iter().map(|w| w.window).collect())
    }

    fn window_action(&self, id: u64, action: WindowAction) -> Res<()> {
        let wid = window_id(id);
        let cg =
            cg_windows().into_iter().find(|w| w.window.id == wid).ok_or_else(|| Error::not_found("no such window"))?;
        self.need_ax()?;
        let (app, win) = ax_window(cg.pid, id as u32)?;
        match action {
            WindowAction::Focus => {
                ax_action(&win, "AXRaise")?;
                let _ = ax_set(&win, "AXMain", &cf_bool(true));
                ax_set(&app, "AXFrontmost", &cf_bool(true))
            }
            WindowAction::Close => ax_action(&ax_copy(&win, "AXCloseButton")?, "AXPress"),
            WindowAction::Minimize => ax_set(&win, "AXMinimized", &cf_bool(true)),
            // The zoom (green) button is the closest thing to maximize.
            WindowAction::Maximize => ax_action(&ax_copy(&win, "AXZoomButton")?, "AXPress"),
            WindowAction::Fullscreen => {
                let now =
                    ax_copy(&win, "AXFullScreen").ok().and_then(|v| v.downcast::<CFBoolean>()).is_some_and(bool::from);
                ax_set(&win, "AXFullScreen", &cf_bool(!now))
            }
            WindowAction::Float => Err(Error::unsupported("macOS windows always float")),
        }
    }

    fn monitors(&self) -> Res<Vec<Monitor>> {
        Ok(displays())
    }

    fn capture(&self, r: Rect) -> Res<Frame> {
        self.need_capture()?;
        let rect = CGRect::new(&CGPoint::new(r.x as f64, r.y as f64), &CGSize::new(r.w as f64, r.h as f64));
        let img = create_image(rect, kCGWindowListOptionOnScreenOnly, kCGNullWindowID, kCGWindowImageBestResolution)
            .ok_or_else(|| Error::failed("screen capture failed"))?;
        if img.bits_per_pixel() != 32 {
            return Err(Error::failed("unexpected capture pixel format"));
        }
        let (w, h, stride) = (img.width() as u32, img.height() as u32, img.bytes_per_row());
        // 32-bit little-endian premultiplied-first: B, G, R, A in memory.
        let data = img.data().bytes().to_vec();
        Frame::new(w, h, stride, PixelFormat::Bgrx, data)
    }

    fn pointer(&self, x: f64, y: f64) -> Res<()> {
        self.need_ax()?;
        let held = *self.held.lock().unwrap_or_else(|e| e.into_inner());
        let (button, ty) = match held {
            Some(b) => {
                let (mb, _, _, drag) = mouse_parts(b);
                (mb, drag)
            }
            None => (CGMouseButton::Left, CGEventType::MouseMoved),
        };
        post(CGEvent::new_mouse_event(source()?, ty, CGPoint::new(x, y), button))
    }

    fn button(&self, button: Button, down: bool) -> Res<()> {
        self.need_ax()?;
        let (mb, d, u, _) = mouse_parts(button);
        post(CGEvent::new_mouse_event(source()?, if down { d } else { u }, cursor()?, mb))?;
        *self.held.lock().unwrap_or_else(|e| e.into_inner()) = down.then_some(button);
        Ok(())
    }

    fn click(&self, button: Button, at: Option<(f64, f64)>, double: bool) -> Res<()> {
        self.need_ax()?;
        if let Some((x, y)) = at {
            self.pointer(x, y)?;
        }
        let (mb, d, u, _) = mouse_parts(button);
        let p = cursor()?;
        // A double click is two clicks whose second one carries click state 2.
        for n in 1..=if double { 2 } else { 1 } {
            for ty in [d, u] {
                let e = CGEvent::new_mouse_event(source()?, ty, p, mb)
                    .map_err(|_| Error::failed("could not create the event"))?;
                e.set_integer_value_field(EventField::MOUSE_EVENT_CLICK_STATE, n);
                e.post(CGEventTapLocation::HID);
            }
        }
        Ok(())
    }

    fn scroll(&self, dx: i32, dy: i32) -> Res<()> {
        self.need_ax()?;
        // Positive wheel values scroll up/left.
        post(CGEvent::new_scroll_event(source()?, ScrollEventUnit::LINE, 2, -dy, -dx, 0))
    }

    fn key(&self, keys: &[Key]) -> Res<()> {
        self.need_ax()?;
        let codes = keys
            .iter()
            .map(|&k| k.mac_keycode().map(|c| (k, c)).ok_or_else(|| Error::unsupported("macOS has no such key")))
            .collect::<Res<Vec<_>>>()?;
        let mut flags = CGEventFlags::CGEventFlagNull;
        for &(k, c) in &codes {
            flags |= flags_for(k);
            let e = CGEvent::new_keyboard_event(source()?, c, true)
                .map_err(|_| Error::failed("could not create the event"))?;
            e.set_flags(flags);
            e.post(CGEventTapLocation::HID);
        }
        for &(k, c) in codes.iter().rev() {
            let e = CGEvent::new_keyboard_event(source()?, c, false)
                .map_err(|_| Error::failed("could not create the event"))?;
            e.set_flags(flags);
            e.post(CGEventTapLocation::HID);
            flags.remove(flags_for(k));
        }
        Ok(())
    }

    fn text(&self, text: &str) -> Res<()> {
        self.need_ax()?;
        let flush = |buf: &mut String| -> Res<()> {
            for chunk in utf16_chunks(buf) {
                for down in [true, false] {
                    let e = CGEvent::new_keyboard_event(source()?, 0, down)
                        .map_err(|_| Error::failed("could not create the event"))?;
                    e.set_string_from_utf16_unchecked(&chunk);
                    e.post(CGEventTapLocation::HID);
                }
            }
            buf.clear();
            Ok(())
        };
        // Newlines and tabs as their keys (Return, Tab); everything else as Unicode strings on key events.
        let mut buf = String::new();
        for ch in text.chars() {
            let code = match ch {
                '\n' => 0x24,
                '\t' => 0x30,
                '\r' => continue,
                c => {
                    buf.push(c);
                    continue;
                }
            };
            flush(&mut buf)?;
            for down in [true, false] {
                post(CGEvent::new_keyboard_event(source()?, code, down))?;
            }
        }
        flush(&mut buf)
    }

    fn launch(&self, id: &str) -> Res<()> {
        crate::apps::launch(id)
    }

    fn dpms(&self, on: bool) -> Res<()> {
        if on {
            // Declaring user activity wakes the displays.
            spawn_detached(OsStr::new("caffeinate"), &["-u", "-t", "2"])
        } else {
            run_ok("pmset", &["displaysleepnow"], None).map(|_| ())
        }
    }

    fn clipboard_get(&self) -> Res<Option<String>> {
        let mut c = arboard::Clipboard::new().map_err(|e| Error::failed(format!("clipboard: {e}")))?;
        match c.get_text() {
            Ok(t) => Ok(Some(t)),
            Err(arboard::Error::ContentNotAvailable) => Ok(None),
            Err(e) => Err(Error::failed(format!("clipboard: {e}"))),
        }
    }

    fn clipboard_set(&self, text: &str) -> Res<()> {
        let mut c = arboard::Clipboard::new().map_err(|e| Error::failed(format!("clipboard: {e}")))?;
        c.set_text(text).map_err(|e| Error::failed(format!("clipboard: {e}")))
    }

    fn volume(&self) -> Res<Volume> {
        let out = run_ok(
            "osascript",
            &[
                "-e",
                "set s to get volume settings",
                "-e",
                "return (output volume of s as text) & \",\" & (output muted of s as text)",
            ],
            None,
        )?;
        macos_parse::volume(&out.text()).ok_or_else(|| Error::unsupported("this output device has no volume control"))
    }

    fn set_volume(&self, percent: Option<u32>, muted: Option<bool>) -> Res<Volume> {
        if let Some(p) = percent {
            run_ok("osascript", &["-e", &format!("set volume output volume {}", p.min(100))], None)?;
        }
        if let Some(m) = muted {
            run_ok("osascript", &["-e", &format!("set volume output muted {m}")], None)?;
        }
        self.volume()
    }

    fn outputs(&self) -> Res<Vec<Output>> {
        let out = run_ok("system_profiler", &["SPAudioDataType", "-json"], None)?;
        let v: serde_json::Value = serde_json::from_slice(&out.stdout).map_err(|e| Error::failed(e.to_string()))?;
        Ok(macos_parse::outputs(&v))
    }

    fn set_output(&self, id: &str) -> Res<Vec<Output>> {
        if !self.switch_audio {
            return Err(Error::unsupported(
                "install SwitchAudioSource (brew install switchaudio-osx) to switch outputs",
            ));
        }
        if !self.outputs()?.iter().any(|o| o.id == id) {
            return Err(Error::not_found("no such output"));
        }
        run_ok("SwitchAudioSource", &["-t", "output", "-s", id], None)?;
        self.outputs()
    }
}
