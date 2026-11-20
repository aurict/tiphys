//! Sway: IPC over `$SWAYSOCK` for windows, workspaces, outputs, DPMS and the pointer (`seat - cursor …`);
//! `grim` for capture and `wtype` for keys/text when installed (both reported honestly in capabilities).

use super::{
    Backend, CAP_APPS, CAP_AUDIO, CAP_CLIPBOARD, CAP_DPMS, CAP_INPUT, CAP_LAUNCH, CAP_MONITORS, CAP_SCREENSHOT,
    CAP_STREAM, CAP_TEXT, CAP_WINDOW_ACTIONS, CAP_WINDOWS, CAP_WORKSPACES, linux,
};
use crate::frame::{self, Frame};
use crate::keys::Key;
use crate::protocol::{Button, Error, Monitor, Output, Rect, Res, Volume, Window, WindowAction, Workspace, window_id};
use crate::util::{run_ok, which};
use serde_json::Value;
use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

const MAGIC: &[u8; 6] = b"i3-ipc";
const RUN_COMMAND: u32 = 0;
const GET_WORKSPACES: u32 = 1;
const GET_OUTPUTS: u32 = 3;
const GET_TREE: u32 = 4;
const IO_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_REPLY: usize = 64 * 1024 * 1024;
const SCRATCHPAD: &str = "__i3_scratch";

pub struct Sway {
    socket: PathBuf,
    grim: bool,
    wtype: bool,
    wl_clipboard: bool,
    wpctl: bool,
}

fn ipc_err(e: impl std::fmt::Display) -> Error {
    Error::failed(format!("sway IPC: {e}"))
}

impl Sway {
    pub fn connect() -> Result<Self, String> {
        let socket = PathBuf::from(std::env::var_os("SWAYSOCK").ok_or("SWAYSOCK is not set")?);
        let s = Self {
            socket,
            grim: which("grim").is_some(),
            wtype: which("wtype").is_some(),
            wl_clipboard: linux::has_wl_clipboard(),
            wpctl: linux::has_wpctl(),
        };
        s.request(GET_OUTPUTS, "").map_err(|e| e.message)?;
        Ok(s)
    }

    fn request(&self, ty: u32, payload: &str) -> Res<Value> {
        let mut s = UnixStream::connect(&self.socket).map_err(ipc_err)?;
        s.set_read_timeout(Some(IO_TIMEOUT)).map_err(ipc_err)?;
        s.set_write_timeout(Some(IO_TIMEOUT)).map_err(ipc_err)?;
        let mut msg = Vec::with_capacity(14 + payload.len());
        msg.extend_from_slice(MAGIC);
        msg.extend_from_slice(&(payload.len() as u32).to_ne_bytes());
        msg.extend_from_slice(&ty.to_ne_bytes());
        msg.extend_from_slice(payload.as_bytes());
        s.write_all(&msg).map_err(ipc_err)?;
        let mut head = [0u8; 14];
        s.read_exact(&mut head).map_err(ipc_err)?;
        if &head[..6] != MAGIC {
            return Err(ipc_err("bad reply"));
        }
        let len = u32::from_ne_bytes(head[6..10].try_into().expect("4 bytes")) as usize;
        if len > MAX_REPLY {
            return Err(ipc_err("reply too large"));
        }
        let mut body = vec![0; len];
        s.read_exact(&mut body).map_err(ipc_err)?;
        serde_json::from_slice(&body).map_err(ipc_err)
    }

    fn command(&self, cmd: &str) -> Res<()> {
        let r = self.request(RUN_COMMAND, cmd)?;
        let results = r.as_array().ok_or_else(|| ipc_err("bad reply"))?;
        match results.iter().find(|r| r["success"] != Value::Bool(true)) {
            None => Ok(()),
            Some(f) => Err(Error::failed(format!("sway: {}", f["error"].as_str().unwrap_or("command failed")))),
        }
    }

    fn tree_windows(&self) -> Res<Vec<Window>> {
        Ok(parse_tree(&self.request(GET_TREE, "")?))
    }

    fn known_window(&self, id: u64) -> Res<u64> {
        if self.tree_windows()?.iter().any(|w| w.id == window_id(id)) {
            Ok(id)
        } else {
            Err(Error::not_found("no such window"))
        }
    }

    fn need_wtype(&self) -> Res<()> {
        if self.wtype { Ok(()) } else { Err(Error::unsupported("install wtype for keyboard input on sway")) }
    }

    fn cursor(&self, what: &str) -> Res<()> {
        self.command(&format!("seat - cursor {what}"))
    }
}

/// Quoted argument for a sway command.
fn quote(s: &str) -> String {
    format!("\"{}\"", s.replace('\\', "\\\\").replace('"', "\\\""))
}

fn rect_of(v: &Value) -> (i32, i32, i32, i32) {
    let n = |k: &str| v["rect"][k].as_i64().unwrap_or(0) as i32;
    (n("x"), n("y"), n("width"), n("height"))
}

/// Windows of a GET_TREE reply, children visited in each container's focus order (most recent first).
pub fn parse_tree(root: &Value) -> Vec<Window> {
    fn walk(node: &Value, output: Option<&str>, ws: Option<&str>, out: &mut Vec<Window>) {
        let ty = node["type"].as_str().unwrap_or("");
        let name = node["name"].as_str();
        let output = if ty == "output" { name } else { output };
        let ws = if ty == "workspace" { name } else { ws };
        let children: Vec<&Value> =
            node["nodes"].as_array().into_iter().chain(node["floating_nodes"].as_array()).flatten().collect();
        let is_window = (ty == "con" || ty == "floating_con")
            && children.is_empty()
            && (node["app_id"].is_string() || node["window"].is_number());
        if is_window {
            let (x, y, w, h) = rect_of(node);
            let scratch = ws == Some(SCRATCHPAD);
            let app_id = node["app_id"]
                .as_str()
                .or_else(|| node["window_properties"]["class"].as_str())
                .unwrap_or("")
                .to_string();
            out.push(Window {
                id: window_id(node["id"].as_u64().unwrap_or(0)),
                title: name.unwrap_or("").to_string(),
                app_id,
                pid: node["pid"].as_u64().map(|p| p as u32),
                workspace: if scratch { None } else { ws.map(String::from) },
                monitor: if scratch { None } else { output.filter(|o| !o.starts_with("__")).map(String::from) },
                x,
                y,
                w,
                h,
                focused: node["focused"].as_bool().unwrap_or(false),
                minimized: scratch,
                fullscreen: node["fullscreen_mode"].as_u64().unwrap_or(0) > 0,
                floating: ty == "floating_con",
            });
            return;
        }
        let order: Vec<u64> =
            node["focus"].as_array().map(|f| f.iter().filter_map(Value::as_u64).collect()).unwrap_or_default();
        let mut sorted = children;
        sorted.sort_by_key(|c| {
            let id = c["id"].as_u64().unwrap_or(0);
            order.iter().position(|&f| f == id).unwrap_or(usize::MAX)
        });
        for c in sorted {
            walk(c, output, ws, out);
        }
    }
    let mut out = Vec::new();
    walk(root, None, None, &mut out);
    out
}

pub fn parse_outputs(v: &Value) -> Vec<Monitor> {
    v.as_array()
        .into_iter()
        .flatten()
        .filter(|o| o["active"].as_bool().unwrap_or(true) && o["name"].is_string())
        .map(|o| {
            let (x, y, w, h) = rect_of(o);
            let name = o["name"].as_str().unwrap_or("").to_string();
            Monitor {
                id: name.clone(),
                name,
                x,
                y,
                w,
                h,
                scale: o["scale"].as_f64().unwrap_or(1.0),
                primary: o["focused"].as_bool().unwrap_or(false),
            }
        })
        .collect()
}

pub fn parse_workspaces(v: &Value) -> Vec<Workspace> {
    v.as_array()
        .into_iter()
        .flatten()
        .filter_map(|w| {
            let name = w["name"].as_str()?.to_string();
            Some(Workspace {
                id: name.clone(),
                name,
                focused: w["focused"].as_bool().unwrap_or(false),
                monitor: w["output"].as_str().map(String::from),
            })
        })
        .collect()
}

/// `wtype` arguments for a combo: modifiers held with -M/-m around the last key.
pub fn wtype_args(keys: &[Key]) -> Vec<String> {
    let (last, mods) = keys.split_last().expect("validated: at least one key");
    let mut a = Vec::new();
    for m in mods {
        a.extend(["-M".to_string(), m.wtype_modifier().unwrap_or("ctrl").to_string()]);
    }
    a.extend(["-k".to_string(), last.xkb_name()]);
    for m in mods.iter().rev() {
        a.extend(["-m".to_string(), m.wtype_modifier().unwrap_or("ctrl").to_string()]);
    }
    a
}

impl Backend for Sway {
    fn name(&self) -> &'static str {
        "sway"
    }

    fn capabilities(&self) -> Vec<&'static str> {
        let mut c = vec![CAP_WINDOWS, CAP_WINDOW_ACTIONS, CAP_WORKSPACES, CAP_MONITORS];
        if self.grim {
            c.extend([CAP_SCREENSHOT, CAP_STREAM]);
        }
        // The pointer works through IPC alone; keys and text need wtype.
        c.push(CAP_INPUT);
        if self.wtype {
            c.push(CAP_TEXT);
        }
        c.extend([CAP_APPS, CAP_LAUNCH, CAP_DPMS]);
        if self.wl_clipboard {
            c.push(CAP_CLIPBOARD);
        }
        if self.wpctl {
            c.push(CAP_AUDIO);
        }
        c
    }

    fn windows(&self) -> Res<Vec<Window>> {
        self.tree_windows()
    }

    fn window_action(&self, id: u64, action: WindowAction) -> Res<()> {
        let id = self.known_window(id)?;
        let cmd = match action {
            WindowAction::Focus => "focus",
            WindowAction::Close => "kill",
            WindowAction::Minimize => "move scratchpad",
            WindowAction::Fullscreen => "fullscreen toggle",
            WindowAction::Float => "floating toggle",
            WindowAction::Maximize => return Err(Error::unsupported("sway has no maximize (use fullscreen)")),
        };
        self.command(&format!("[con_id={id}] {cmd}"))
    }

    fn workspaces(&self) -> Res<Vec<Workspace>> {
        Ok(parse_workspaces(&self.request(GET_WORKSPACES, "")?))
    }

    fn switch_workspace(&self, id: &str) -> Res<()> {
        self.command(&format!("workspace {}", quote(id)))
    }

    fn move_to_workspace(&self, window: u64, workspace: &str) -> Res<()> {
        let id = self.known_window(window)?;
        self.command(&format!("[con_id={id}] move container to workspace {}", quote(workspace)))
    }

    fn monitors(&self) -> Res<Vec<Monitor>> {
        Ok(parse_outputs(&self.request(GET_OUTPUTS, "")?))
    }

    fn capture(&self, r: Rect) -> Res<Frame> {
        if !self.grim {
            return Err(Error::unsupported("install grim for screen capture on sway"));
        }
        let geometry = format!("{},{} {}x{}", r.x, r.y, r.w, r.h);
        let out = run_ok("grim", &["-t", "ppm", "-g", &geometry, "-"], None)?;
        frame::decode_ppm(&out.stdout)
    }

    fn pointer(&self, x: f64, y: f64) -> Res<()> {
        self.cursor(&format!("set {} {}", x.round() as i64, y.round() as i64))
    }

    fn button(&self, button: Button, down: bool) -> Res<()> {
        let b = match button {
            Button::Left => "button1",
            Button::Middle => "button2",
            Button::Right => "button3",
        };
        self.cursor(&format!("{} {b}", if down { "press" } else { "release" }))
    }

    fn scroll(&self, dx: i32, dy: i32) -> Res<()> {
        // sway turns button4–7 presses into axis events: 4 up, 5 down, 6 left, 7 right.
        for (n, pos, neg) in [(dy, "button5", "button4"), (dx, "button7", "button6")] {
            let b = if n > 0 { pos } else { neg };
            for _ in 0..n.unsigned_abs() {
                self.cursor(&format!("press {b}"))?;
                self.cursor(&format!("release {b}"))?;
            }
        }
        Ok(())
    }

    fn key(&self, keys: &[Key]) -> Res<()> {
        self.need_wtype()?;
        run_ok("wtype", &wtype_args(keys), None).map(|_| ())
    }

    fn text(&self, text: &str) -> Res<()> {
        self.need_wtype()?;
        // Through stdin, so the text never shows up in a process list.
        run_ok("wtype", &["-"], Some(text.as_bytes())).map(|_| ())
    }

    fn dpms(&self, on: bool) -> Res<()> {
        let state = if on { "on" } else { "off" };
        // `power` since sway 1.8; `dpms` before.
        self.command(&format!("output * power {state}")).or_else(|_| self.command(&format!("output * dpms {state}")))
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
    use serde_json::json;

    fn con(id: u64, name: &str, app: &str, focused: bool) -> Value {
        json!({"id": id, "type": "con", "name": name, "app_id": app, "pid": id * 10, "focused": focused,
               "fullscreen_mode": 0, "rect": {"x": 1, "y": 2, "width": 30, "height": 40}, "nodes": [], "floating_nodes": []})
    }

    #[test]
    fn tree() {
        let tree = json!({
            "id": 1, "type": "root", "name": "root", "focus": [3, 2],
            "nodes": [
                {"id": 2, "type": "output", "name": "__i3", "focus": [20], "nodes": [
                    {"id": 20, "type": "workspace", "name": "__i3_scratch", "nodes": [], "floating_nodes": [
                        {"id": 21, "type": "floating_con", "name": "hidden", "app_id": "x", "nodes": [], "floating_nodes": [],
                         "rect": {"x": 0, "y": 0, "width": 1, "height": 1}}
                    ]}
                ]},
                {"id": 3, "type": "output", "name": "DP-1", "focus": [30], "nodes": [
                    {"id": 30, "type": "workspace", "name": "1", "focus": [32, 31], "nodes": [
                        con(31, "Terminal", "foot", false),
                        {"id": 32, "type": "con", "name": null, "focus": [34, 33], "layout": "splitv", "nodes": [
                            con(33, "Old", "firefox", false),
                            con(34, "Now", "org.gnome.Nautilus", true)
                        ], "floating_nodes": []}
                    ], "floating_nodes": [
                        {"id": 35, "type": "floating_con", "name": "Steam", "window": 12345, "app_id": null,
                         "window_properties": {"class": "steam"}, "nodes": [], "floating_nodes": [], "fullscreen_mode": 1,
                         "rect": {"x": 0, "y": 0, "width": 9, "height": 9}}
                    ]}
                ]}
            ]
        });
        let ws = parse_tree(&tree);
        let ids: Vec<&str> = ws.iter().map(|w| w.id.as_str()).collect();
        // Focus order first (34 before 33, the split before 31), unfocused floating ones after, scratchpad last.
        assert_eq!(ids, vec!["0x22", "0x21", "0x1f", "0x23", "0x15"]);
        let now = &ws[0];
        assert!(now.focused);
        assert_eq!((now.title.as_str(), now.app_id.as_str(), now.pid), ("Now", "org.gnome.Nautilus", Some(340)));
        assert_eq!((now.workspace.as_deref(), now.monitor.as_deref()), (Some("1"), Some("DP-1")));
        assert_eq!((now.x, now.y, now.w, now.h), (1, 2, 30, 40));
        let steam = &ws[3];
        assert_eq!(steam.app_id, "steam");
        assert!(steam.floating && steam.fullscreen);
        let hidden = &ws[4];
        assert!(hidden.minimized);
        assert_eq!((hidden.workspace.clone(), hidden.monitor.clone()), (None, None));
    }

    #[test]
    fn outputs_and_workspaces() {
        let outs = json!([
            {"name": "DP-1", "active": true, "focused": true, "scale": 1.5, "rect": {"x": 0, "y": 0, "width": 2560, "height": 1440}},
            {"name": "HDMI-A-1", "active": false, "rect": {"x": 0, "y": 0, "width": 0, "height": 0}}
        ]);
        assert_eq!(
            parse_outputs(&outs),
            vec![Monitor {
                id: "DP-1".into(),
                name: "DP-1".into(),
                x: 0,
                y: 0,
                w: 2560,
                h: 1440,
                scale: 1.5,
                primary: true
            }]
        );
        let wss = json!([{"num": 1, "name": "1: web", "focused": true, "output": "DP-1"}]);
        assert_eq!(
            parse_workspaces(&wss),
            vec![Workspace { id: "1: web".into(), name: "1: web".into(), focused: true, monitor: Some("DP-1".into()) }]
        );
    }

    #[test]
    fn commands() {
        assert_eq!(quote(r#"a "b" \c"#), r#""a \"b\" \\c""#);
        let s = |v: Vec<String>| v.join(" ");
        assert_eq!(s(wtype_args(&[Key::Ctrl, Key::Shift, Key::Char('t')])), "-M ctrl -M shift -k t -m shift -m ctrl");
        assert_eq!(s(wtype_args(&[Key::Enter])), "-k Return");
        assert_eq!(s(wtype_args(&[Key::Super])), "-k Super_L");
    }
}
