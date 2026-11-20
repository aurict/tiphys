//! Platform backends. Each implements what really works on its desktop and lists exactly that in
//! `capabilities()`; serve mode refuses every other op with `unsupported` before calling the backend.
//!
//! Detection (override with `TIPHYS_DESKTOP_BACKEND=sway|x11|portal|none`): Windows → windows, macOS → macos,
//! `$SWAYSOCK` → sway, `$WAYLAND_DISPLAY` on GNOME/KDE → portal, any other Wayland session → none (XWayland would
//! only see X clients), `$DISPLAY` → x11, else none.

use crate::frame::Frame;
use crate::keys::Key;
use crate::protocol::{
    App, Button, Error, Monitor, Output, Rect, Request, Res, Target, Volume, Window, WindowAction, Workspace,
};

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "macos")]
pub mod macos;
pub mod none;
#[cfg(all(target_os = "linux", feature = "portal"))]
pub mod portal;
#[cfg(target_os = "linux")]
pub mod sway;
#[cfg(windows)]
pub mod windows;
#[cfg(target_os = "linux")]
pub mod x11;

pub const CAP_WINDOWS: &str = "windows";
pub const CAP_WINDOW_ACTIONS: &str = "windowActions";
pub const CAP_WORKSPACES: &str = "workspaces";
pub const CAP_MONITORS: &str = "monitors";
pub const CAP_SCREENSHOT: &str = "screenshot";
pub const CAP_STREAM: &str = "stream";
pub const CAP_INPUT: &str = "input";
pub const CAP_TEXT: &str = "text";
pub const CAP_APPS: &str = "apps";
pub const CAP_LAUNCH: &str = "launch";
pub const CAP_DPMS: &str = "dpms";
pub const CAP_CLIPBOARD: &str = "clipboard";
pub const CAP_AUDIO: &str = "audio";

fn unsupported<T>() -> Res<T> {
    Err(Error::unsupported("not available on this desktop"))
}

#[allow(unused_variables)]
pub trait Backend: Send + Sync {
    fn name(&self) -> &'static str;
    fn capabilities(&self) -> Vec<&'static str>;

    /// Most recently focused first.
    fn windows(&self) -> Res<Vec<Window>> {
        unsupported()
    }
    fn focused(&self) -> Res<Option<Window>> {
        Ok(self.windows()?.into_iter().find(|w| w.focused))
    }
    fn window_action(&self, id: u64, action: WindowAction) -> Res<()> {
        unsupported()
    }
    fn workspaces(&self) -> Res<Vec<Workspace>> {
        unsupported()
    }
    fn switch_workspace(&self, id: &str) -> Res<()> {
        unsupported()
    }
    fn move_to_workspace(&self, window: u64, workspace: &str) -> Res<()> {
        unsupported()
    }
    fn monitors(&self) -> Res<Vec<Monitor>> {
        unsupported()
    }
    /// Pixels of a global logical rectangle (on HiDPI the frame may be larger than `r.w × r.h`).
    fn capture(&self, r: Rect) -> Res<Frame> {
        unsupported()
    }
    fn pointer(&self, x: f64, y: f64) -> Res<()> {
        unsupported()
    }
    fn button(&self, button: Button, down: bool) -> Res<()> {
        unsupported()
    }
    fn click(&self, button: Button, at: Option<(f64, f64)>, double: bool) -> Res<()> {
        if let Some((x, y)) = at {
            self.pointer(x, y)?;
        }
        for _ in 0..if double { 2 } else { 1 } {
            self.button(button, true)?;
            self.button(button, false)?;
        }
        Ok(())
    }
    /// Notches; `dy > 0` scrolls down, `dx > 0` right.
    fn scroll(&self, dx: i32, dy: i32) -> Res<()> {
        unsupported()
    }
    /// Modifiers first, then at most one key (validated): press all in order, release in reverse.
    fn key(&self, keys: &[Key]) -> Res<()> {
        unsupported()
    }
    fn text(&self, text: &str) -> Res<()> {
        unsupported()
    }
    fn apps(&self, lang: Option<&str>) -> Res<Vec<App>> {
        Ok(crate::apps::list(lang))
    }
    fn launch(&self, id: &str) -> Res<()> {
        crate::apps::launch(id)
    }
    fn dpms(&self, on: bool) -> Res<()> {
        unsupported()
    }
    fn clipboard_get(&self) -> Res<Option<String>> {
        unsupported()
    }
    fn clipboard_set(&self, text: &str) -> Res<()> {
        unsupported()
    }
    fn volume(&self) -> Res<Volume> {
        unsupported()
    }
    fn set_volume(&self, percent: Option<u32>, muted: Option<bool>) -> Res<Volume> {
        unsupported()
    }
    fn outputs(&self) -> Res<Vec<Output>> {
        unsupported()
    }
    fn set_output(&self, id: &str) -> Res<Vec<Output>> {
        unsupported()
    }
}

/// Capability an op needs (`None`: always allowed).
pub fn required_capability(r: &Request) -> Option<&'static str> {
    Some(match r {
        Request::Windows | Request::Focused | Request::SubscribeFocus => CAP_WINDOWS,
        Request::Window { .. } => CAP_WINDOW_ACTIONS,
        Request::Workspaces | Request::Workspace { .. } | Request::MoveToWorkspace { .. } => CAP_WORKSPACES,
        Request::Monitors => CAP_MONITORS,
        Request::Screenshot { .. } => CAP_SCREENSHOT,
        Request::Pointer { .. }
        | Request::Click { .. }
        | Request::Button { .. }
        | Request::Scroll { .. }
        | Request::Key { .. } => CAP_INPUT,
        Request::Text { .. } => CAP_TEXT,
        Request::Apps { .. } => CAP_APPS,
        Request::Launch { .. } => CAP_LAUNCH,
        Request::Dpms { .. } => CAP_DPMS,
        Request::ClipboardGet | Request::ClipboardSet { .. } => CAP_CLIPBOARD,
        Request::Volume | Request::SetVolume { .. } | Request::Outputs | Request::SetOutput { .. } => CAP_AUDIO,
        Request::Ping => return None,
    })
}

/// The global rectangle a screenshot/stream target covers.
pub fn target_rect(b: &dyn Backend, t: &Target) -> Res<Rect> {
    match t {
        Target::Region(r) => Ok(*r),
        Target::Monitor(id) => b
            .monitors()?
            .into_iter()
            .find(|m| &m.id == id)
            .map(|m| m.rect())
            .ok_or_else(|| Error::not_found("no such monitor")),
        Target::Default => {
            let ms = b.monitors()?;
            ms.iter().find(|m| m.primary).or(ms.first()).map(|m| m.rect()).ok_or_else(|| Error::not_found("no monitor"))
        }
        Target::Window(id) => {
            let wid = crate::protocol::window_id(*id);
            let w = b.windows()?.into_iter().find(|w| w.id == wid).ok_or_else(|| Error::not_found("no such window"))?;
            if w.minimized {
                return Err(Error::failed("the window is minimized"));
            }
            Ok(Rect { x: w.x, y: w.y, w: w.w, h: w.h })
        }
    }
}

/// Monitor whose rectangle holds the point (or the nearest one's id when none does).
pub fn monitor_at(monitors: &[Monitor], x: f64, y: f64) -> Option<String> {
    monitors.iter().find(|m| m.rect().contains(x, y)).map(|m| m.id.clone())
}

pub fn detect() -> Box<dyn Backend> {
    let forced = std::env::var("TIPHYS_DESKTOP_BACKEND").ok().filter(|s| !s.is_empty());
    let choice = forced.clone().unwrap_or_else(default_choice);
    match open(&choice) {
        Ok(b) => b,
        Err(e) => {
            eprintln!("tiphys-desktop: {choice} backend unavailable ({e}); using none");
            Box::new(none::NoneBackend)
        }
    }
}

fn default_choice() -> String {
    if cfg!(windows) {
        return "windows".into();
    }
    if cfg!(target_os = "macos") {
        return "macos".into();
    }
    let set = |k: &str| std::env::var_os(k).is_some_and(|v| !v.is_empty());
    let desktop = std::env::var("XDG_CURRENT_DESKTOP").unwrap_or_default().to_uppercase();
    if set("SWAYSOCK") {
        "sway"
    } else if set("WAYLAND_DISPLAY") {
        if desktop.split(':').any(|d| d == "GNOME" || d == "KDE") { "portal" } else { "none" }
    } else if set("DISPLAY") {
        "x11"
    } else {
        "none"
    }
    .into()
}

fn open(name: &str) -> Result<Box<dyn Backend>, String> {
    match name {
        "none" => Ok(Box::new(none::NoneBackend)),
        #[cfg(target_os = "linux")]
        "x11" => Ok(Box::new(x11::X11::connect()?)),
        #[cfg(target_os = "linux")]
        "sway" => Ok(Box::new(sway::Sway::connect()?)),
        #[cfg(all(target_os = "linux", feature = "portal"))]
        "portal" => Ok(Box::new(portal::Portal::new()?)),
        #[cfg(windows)]
        "windows" => Ok(Box::new(windows::Win::new())),
        #[cfg(target_os = "macos")]
        "macos" => Ok(Box::new(macos::Mac::new())),
        other => Err(format!("not built for {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_op_but_ping_needs_a_capability() {
        assert_eq!(required_capability(&Request::Ping), None);
        assert_eq!(required_capability(&Request::Text { text: "x".into() }), Some(CAP_TEXT));
        assert_eq!(required_capability(&Request::SubscribeFocus), Some(CAP_WINDOWS));
    }

    #[test]
    fn targets() {
        struct B;
        impl Backend for B {
            fn name(&self) -> &'static str {
                "t"
            }
            fn capabilities(&self) -> Vec<&'static str> {
                vec![]
            }
            fn monitors(&self) -> Res<Vec<Monitor>> {
                let m = |id: &str, x, primary| Monitor { id: id.into(), name: id.into(), x, y: 0, w: 100, h: 50, scale: 1.0, primary };
                Ok(vec![m("A", 0, false), m("B", 100, true)])
            }
        }
        assert_eq!(target_rect(&B, &Target::Default), Ok(Rect { x: 100, y: 0, w: 100, h: 50 }));
        assert_eq!(target_rect(&B, &Target::Monitor("A".into())), Ok(Rect { x: 0, y: 0, w: 100, h: 50 }));
        assert_eq!(target_rect(&B, &Target::Monitor("C".into())).unwrap_err().code, crate::protocol::Code::NotFound);
        assert_eq!(target_rect(&B, &Target::Window(1)).unwrap_err().code, crate::protocol::Code::Unsupported);
        assert_eq!(monitor_at(&B.monitors().unwrap(), 150.0, 10.0), Some("B".into()));
        assert_eq!(monitor_at(&B.monitors().unwrap(), 250.0, 10.0), None);
    }
}
