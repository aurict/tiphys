//! Wire types of `serve` mode (PROTOCOL.md): requests in, answers and events out, one JSON object per line.
//!
//! - A line is parsed into [`Request`] in two steps: serde reads the shape ([`RawOp`]), then [`validate`] checks the
//!   limits that the agent enforces too (text length, ranges, window id format, key combos).
//! - Results are plain serde structs with camelCase names; [`Error`] carries one of the spec's error codes.

use crate::keys::Key;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::fmt;
use std::time::{Duration, Instant};

pub const PROTOCOL: u32 = 1;
pub const MAX_TEXT_CHARS: usize = 4000;
/// A request line is at most this long (4000 characters escaped as `\uXXXX` plus the envelope fit easily).
pub const MAX_LINE: usize = 64 * 1024;
pub const MAX_INPUT_PER_SEC: u32 = 60;
pub const MAX_KEYS: usize = 8;
pub const SCROLL_LIMIT: i32 = 20;
pub const MAX_WIDTH_RANGE: (u32, u32) = (64, 3840);
pub const FPS_RANGE: (u32, u32) = (1, 60);
pub const QSCALE_RANGE: (u8, u8) = (2, 31);
/// Coordinates beyond this are surely a mistake (the largest desktops are ~16k px wide).
const MAX_COORD: f64 = 100_000.0;
const MAX_ID_LEN: usize = 512;

// =====================================================================
// errors

#[derive(Serialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Code {
    BadRequest,
    Unsupported,
    NotFound,
    #[allow(dead_code)] // portal and macOS only
    Permission,
    Busy,
    Failed,
}

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
pub struct Error {
    pub code: Code,
    pub message: String,
}

impl Error {
    pub fn new(code: Code, message: impl Into<String>) -> Self {
        Self { code, message: message.into() }
    }
    pub fn bad(message: impl Into<String>) -> Self {
        Self::new(Code::BadRequest, message)
    }
    pub fn unsupported(message: impl Into<String>) -> Self {
        Self::new(Code::Unsupported, message)
    }
    pub fn not_found(message: impl Into<String>) -> Self {
        Self::new(Code::NotFound, message)
    }
    #[allow(dead_code)]
    pub fn permission(message: impl Into<String>) -> Self {
        Self::new(Code::Permission, message)
    }
    pub fn busy(message: impl Into<String>) -> Self {
        Self::new(Code::Busy, message)
    }
    pub fn failed(message: impl Into<String>) -> Self {
        Self::new(Code::Failed, message)
    }
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{:?}: {}", self.code, self.message)
    }
}

pub type Res<T> = Result<T, Error>;

// =====================================================================
// result shapes

#[derive(Serialize, Debug, Clone, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Window {
    pub id: String,
    pub title: String,
    pub app_id: String,
    pub pid: Option<u32>,
    pub workspace: Option<String>,
    pub monitor: Option<String>,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub focused: bool,
    pub minimized: bool,
    pub fullscreen: bool,
    pub floating: bool,
}

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Workspace {
    pub id: String,
    pub name: String,
    pub focused: bool,
    pub monitor: Option<String>,
}

#[derive(Serialize, Debug, Clone, PartialEq)]
pub struct Monitor {
    pub id: String,
    pub name: String,
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
    pub scale: f64,
    pub primary: bool,
}

impl Monitor {
    pub fn rect(&self) -> Rect {
        Rect { x: self.x, y: self.y, w: self.w, h: self.h }
    }
}

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
pub struct App {
    pub id: String,
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
}

#[derive(Serialize, Debug, Clone, Copy, PartialEq, Eq)]
pub struct Volume {
    pub percent: u32,
    pub muted: bool,
}

#[derive(Serialize, Debug, Clone, PartialEq, Eq)]
pub struct Output {
    pub id: String,
    pub name: String,
    pub default: bool,
}

/// Global logical rectangle.
#[derive(Deserialize, Serialize, Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    pub fn intersect(&self, o: &Rect) -> Option<Rect> {
        let x0 = self.x.max(o.x);
        let y0 = self.y.max(o.y);
        let x1 = (self.x + self.w).min(o.x + o.w);
        let y1 = (self.y + self.h).min(o.y + o.h);
        (x1 > x0 && y1 > y0).then_some(Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 })
    }
    pub fn contains(&self, x: f64, y: f64) -> bool {
        x >= self.x as f64 && y >= self.y as f64 && x < (self.x + self.w) as f64 && y < (self.y + self.h) as f64
    }
    /// Smallest rectangle around all of them.
    #[allow(dead_code)] // portal only
    pub fn union(rects: impl IntoIterator<Item = Rect>) -> Option<Rect> {
        rects.into_iter().reduce(|a, b| {
            let x0 = a.x.min(b.x);
            let y0 = a.y.min(b.y);
            let x1 = (a.x + a.w).max(b.x + b.w);
            let y1 = (a.y + a.h).max(b.y + b.h);
            Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
        })
    }
}

// =====================================================================
// window ids

/// `0x<lowercase hex>`, at most 16 digits.
pub fn window_id(raw: u64) -> String {
    format!("0x{raw:x}")
}

pub fn parse_window_id(s: &str) -> Res<u64> {
    let hex = s.strip_prefix("0x").ok_or_else(|| Error::bad("window id must look like 0x1a2b"))?;
    if hex.is_empty() || hex.len() > 16 || !hex.bytes().all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b)) {
        return Err(Error::bad("window id must look like 0x1a2b"));
    }
    u64::from_str_radix(hex, 16).map_err(|_| Error::bad("window id must look like 0x1a2b"))
}

// =====================================================================
// requests

#[derive(Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum WindowAction {
    Focus,
    Close,
    Minimize,
    Maximize,
    Fullscreen,
    Float,
}

#[derive(Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Button {
    Left,
    Right,
    Middle,
}

#[derive(Deserialize, Debug, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ImageFormat {
    Png,
    Jpeg,
}

/// Request shape as serde sees it; [`validate`] turns it into a [`Request`].
#[derive(Deserialize, Debug)]
#[serde(tag = "op", rename_all = "kebab-case", rename_all_fields = "camelCase")]
enum RawOp {
    Windows,
    // Target ids are named after their kind: a field `id` would collide with the request id.
    Window { window: String, action: WindowAction },
    Workspaces,
    Workspace { workspace: String },
    MoveToWorkspace { window: String, workspace: String },
    Monitors,
    Screenshot {
        monitor: Option<String>,
        window: Option<String>,
        region: Option<Rect>,
        max_width: Option<u32>,
        format: ImageFormat,
        quality: Option<u8>,
    },
    Pointer { x: f64, y: f64 },
    Click { button: Button, x: Option<f64>, y: Option<f64>, #[serde(default)] double: bool },
    Button { button: Button, down: bool },
    Scroll { #[serde(default)] dx: i32, #[serde(default)] dy: i32 },
    Key { keys: Vec<String> },
    Text { text: String },
    Apps { lang: Option<String> },
    Launch { app: String },
    Dpms { on: bool },
    ClipboardGet,
    ClipboardSet { text: String },
    Volume,
    SetVolume { percent: Option<u32>, muted: Option<bool> },
    Outputs,
    SetOutput { output: String },
    Focused,
    Ping,
    Subscribe { events: Vec<String> },
}

#[derive(Debug, Clone, PartialEq)]
pub enum Target {
    /// No target given: the primary monitor.
    Default,
    Monitor(String),
    Window(u64),
    Region(Rect),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Request {
    Windows,
    Window { id: u64, action: WindowAction },
    Workspaces,
    Workspace { id: String },
    MoveToWorkspace { window: u64, workspace: String },
    Monitors,
    Screenshot { target: Target, max_width: Option<u32>, format: ImageFormat, quality: u8 },
    Pointer { x: f64, y: f64 },
    Click { button: Button, at: Option<(f64, f64)>, double: bool },
    Button { button: Button, down: bool },
    Scroll { dx: i32, dy: i32 },
    Key { keys: Vec<Key> },
    Text { text: String },
    Apps { lang: Option<String> },
    Launch { id: String },
    Dpms { on: bool },
    ClipboardGet,
    ClipboardSet { text: String },
    Volume,
    SetVolume { percent: Option<u32>, muted: Option<bool> },
    Outputs,
    SetOutput { id: String },
    Focused,
    Ping,
    SubscribeFocus,
}

impl Request {
    /// Input requests share the per-second budget and run in order on one thread.
    pub fn is_input(&self) -> bool {
        matches!(
            self,
            Self::Pointer { .. } | Self::Click { .. } | Self::Button { .. } | Self::Scroll { .. } | Self::Key { .. } | Self::Text { .. }
        )
    }
}

/// A parsed line: the id to answer with (a JSON number, or null when it couldn't be read) and the request.
pub struct Parsed {
    pub id: Value,
    pub request: Res<Request>,
}

pub fn parse_line(line: &str) -> Parsed {
    let value: Value = match serde_json::from_str(line) {
        Ok(v) => v,
        Err(_) => return Parsed { id: Value::Null, request: Err(Error::bad("not a JSON object")) },
    };
    let id = match value.get("id") {
        Some(id @ Value::Number(_)) => id.clone(),
        _ => return Parsed { id: Value::Null, request: Err(Error::bad("missing numeric id")) },
    };
    let request = match serde_json::from_value::<RawOp>(value) {
        Ok(raw) => validate(raw),
        Err(e) => Err(Error::bad(shape_message(&e.to_string()))),
    };
    Parsed { id, request }
}

/// serde's message names the field or variant at fault; it never contains request values beyond the op name.
fn shape_message(e: &str) -> String {
    let e = e.split(" at line ").next().unwrap_or(e);
    if e.starts_with("unknown variant") { format!("unknown op or value ({e})") } else { e.to_string() }
}

fn check_coord(v: f64) -> Res<f64> {
    if v.is_finite() && v.abs() <= MAX_COORD { Ok(v) } else { Err(Error::bad("coordinate out of range")) }
}

fn check_text(text: String) -> Res<String> {
    if text.chars().count() > MAX_TEXT_CHARS {
        return Err(Error::bad(format!("text longer than {MAX_TEXT_CHARS} characters")));
    }
    Ok(text)
}

fn check_id(id: String, what: &str) -> Res<String> {
    if id.is_empty() || id.len() > MAX_ID_LEN || id.chars().any(char::is_control) {
        return Err(Error::bad(format!("bad {what} id")));
    }
    Ok(id)
}

fn validate(raw: RawOp) -> Res<Request> {
    Ok(match raw {
        RawOp::Windows => Request::Windows,
        RawOp::Window { window, action } => Request::Window { id: parse_window_id(&window)?, action },
        RawOp::Workspaces => Request::Workspaces,
        RawOp::Workspace { workspace } => Request::Workspace { id: check_id(workspace, "workspace")? },
        RawOp::MoveToWorkspace { window, workspace } => {
            Request::MoveToWorkspace { window: parse_window_id(&window)?, workspace: check_id(workspace, "workspace")? }
        }
        RawOp::Monitors => Request::Monitors,
        RawOp::Screenshot { monitor, window, region, max_width, format, quality } => {
            let target = match (monitor, window, region) {
                (None, None, None) => Target::Default,
                (Some(m), None, None) => Target::Monitor(check_id(m, "monitor")?),
                (None, Some(w), None) => Target::Window(parse_window_id(&w)?),
                (None, None, Some(r)) => {
                    if r.w <= 0 || r.h <= 0 || r.w > 32768 || r.h > 32768 {
                        return Err(Error::bad("region must have a positive size"));
                    }
                    check_coord(r.x as f64)?;
                    check_coord(r.y as f64)?;
                    Target::Region(r)
                }
                _ => return Err(Error::bad("give at most one of monitor, window, region")),
            };
            if let Some(w) = max_width
                && !(MAX_WIDTH_RANGE.0..=MAX_WIDTH_RANGE.1).contains(&w)
            {
                return Err(Error::bad("maxWidth must be 64–3840"));
            }
            let quality = quality.unwrap_or(80);
            if !(1..=100).contains(&quality) {
                return Err(Error::bad("quality must be 1–100"));
            }
            Request::Screenshot { target, max_width, format, quality }
        }
        RawOp::Pointer { x, y } => Request::Pointer { x: check_coord(x)?, y: check_coord(y)? },
        RawOp::Click { button, x, y, double } => {
            let at = match (x, y) {
                (Some(x), Some(y)) => Some((check_coord(x)?, check_coord(y)?)),
                (None, None) => None,
                _ => return Err(Error::bad("give both x and y, or neither")),
            };
            Request::Click { button, at, double }
        }
        RawOp::Button { button, down } => Request::Button { button, down },
        RawOp::Scroll { dx, dy } => {
            if dx.abs() > SCROLL_LIMIT || dy.abs() > SCROLL_LIMIT {
                return Err(Error::bad("scroll is limited to ±20 notches"));
            }
            Request::Scroll { dx, dy }
        }
        RawOp::Key { keys } => Request::Key { keys: parse_combo(&keys)? },
        RawOp::Text { text } => Request::Text { text: check_text(text)? },
        RawOp::Apps { lang } => {
            let lang = lang.filter(|l| !l.is_empty());
            if let Some(l) = &lang
                && (l.len() > 35 || !l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_' || b == b'-' || b == b'@'))
            {
                return Err(Error::bad("bad lang"));
            }
            Request::Apps { lang }
        }
        RawOp::Launch { app } => Request::Launch { id: check_id(app, "app")? },
        RawOp::Dpms { on } => Request::Dpms { on },
        RawOp::ClipboardGet => Request::ClipboardGet,
        RawOp::ClipboardSet { text } => {
            // The clipboard is not typed, so a larger limit would be fine, but the agent caps it the same way.
            Request::ClipboardSet { text: check_text(text)? }
        }
        RawOp::Volume => Request::Volume,
        RawOp::SetVolume { percent, muted } => {
            if percent.is_none() && muted.is_none() {
                return Err(Error::bad("give percent and/or muted"));
            }
            if percent.is_some_and(|p| p > 150) {
                return Err(Error::bad("percent must be 0–150"));
            }
            Request::SetVolume { percent, muted }
        }
        RawOp::Outputs => Request::Outputs,
        RawOp::SetOutput { output } => Request::SetOutput { id: check_id(output, "output")? },
        RawOp::Focused => Request::Focused,
        RawOp::Ping => Request::Ping,
        RawOp::Subscribe { events } => {
            if events.is_empty() || events.iter().any(|e| e != "focus") {
                return Err(Error::bad("the only event is \"focus\""));
            }
            Request::SubscribeFocus
        }
    })
}

/// Modifiers first, then at most one other key; letters and digits only together with a modifier.
pub fn parse_combo(names: &[String]) -> Res<Vec<Key>> {
    if names.is_empty() || names.len() > MAX_KEYS {
        return Err(Error::bad("keys must have 1–8 entries"));
    }
    let mut keys = Vec::with_capacity(names.len());
    for n in names {
        let k = Key::parse(n).ok_or_else(|| Error::bad(format!("unknown key name ({})", short(n))))?;
        if keys.contains(&k) {
            return Err(Error::bad("a key appears twice"));
        }
        keys.push(k);
    }
    let mods = keys.iter().take_while(|k| k.is_modifier()).count();
    if keys.len() - mods > 1 {
        return Err(Error::bad("modifiers first, then one key"));
    }
    if let Some(Key::Char(_)) = keys.last()
        && mods == 0
    {
        return Err(Error::bad("letters and digits need a modifier (plain text goes through \"text\")"));
    }
    Ok(keys)
}

/// Key names are short; a long unknown one is cut so that the message stays small.
fn short(s: &str) -> String {
    s.chars().take(16).collect()
}

// =====================================================================
// answers

// Written by hand so `id` comes first (serde_json's map would sort the keys).
pub fn ok_line(id: &Value, result: Value) -> String {
    format!(r#"{{"id":{id},"ok":true,"result":{result}}}"#)
}

pub fn err_line(id: &Value, e: &Error) -> String {
    format!(r#"{{"id":{id},"ok":false,"error":{}}}"#, json!(e))
}

pub fn hello_line(backend: &str, capabilities: &[&str]) -> String {
    json!({"hello": {"protocol": PROTOCOL, "version": env!("CARGO_PKG_VERSION"), "backend": backend, "capabilities": capabilities}})
        .to_string()
}

pub fn focus_event_line(window: Option<&Window>) -> String {
    json!({"event": "focus", "window": window}).to_string()
}

// =====================================================================
// rate limit

/// Token bucket: `rate` requests per second, bursts up to `rate`.
pub struct RateLimiter {
    rate: f64,
    tokens: f64,
    last: Instant,
}

impl RateLimiter {
    pub fn new(per_sec: u32, now: Instant) -> Self {
        Self { rate: per_sec as f64, tokens: per_sec as f64, last: now }
    }

    pub fn allow(&mut self, now: Instant) -> bool {
        let dt = now.saturating_duration_since(self.last);
        self.last = now;
        self.tokens = (self.tokens + dt.as_secs_f64() * self.rate).min(self.rate);
        if self.tokens >= 1.0 {
            self.tokens -= 1.0;
            true
        } else {
            false
        }
    }
}

/// Frame interval for an fps value.
pub fn frame_interval(fps: u32) -> Duration {
    Duration::from_secs_f64(1.0 / fps.max(1) as f64)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(line: &str) -> Res<Request> {
        parse_line(line).request
    }

    #[test]
    fn window_ids() {
        assert_eq!(window_id(0x1a2b), "0x1a2b");
        assert_eq!(window_id(0), "0x0");
        assert_eq!(parse_window_id("0x1a2b"), Ok(0x1a2b));
        assert_eq!(parse_window_id("0xffffffffffffffff"), Ok(u64::MAX));
        for bad in ["", "0x", "1a2b", "0X1a", "0x1A2B", "0x1ffffffffffffffff", "0x-1", "0x 1", "0xg"] {
            assert!(parse_window_id(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn ids_are_echoed() {
        let p = parse_line(r#"{"id":7,"op":"ping"}"#);
        assert_eq!(p.id, json!(7));
        assert_eq!(p.request, Ok(Request::Ping));
        let p = parse_line(r#"{"id":"7","op":"ping"}"#);
        assert_eq!(p.id, Value::Null);
        assert_eq!(p.request.unwrap_err().code, Code::BadRequest);
        let p = parse_line("not json");
        assert_eq!(p.id, Value::Null);
        let p = parse_line(r#"{"id":3,"op":"nope"}"#);
        assert_eq!(p.id, json!(3));
        assert_eq!(p.request.unwrap_err().code, Code::BadRequest);
    }

    #[test]
    fn simple_ops() {
        assert_eq!(req(r#"{"id":1,"op":"windows"}"#), Ok(Request::Windows));
        assert_eq!(req(r#"{"id":1,"op":"clipboard-get"}"#), Ok(Request::ClipboardGet));
        assert_eq!(
            req(r#"{"id":1,"op":"move-to-workspace","window":"0x10","workspace":"2"}"#),
            Ok(Request::MoveToWorkspace { window: 16, workspace: "2".into() })
        );
        assert_eq!(
            req(r#"{"id":1,"op":"window","window":"0xa","action":"close"}"#),
            Ok(Request::Window { id: 10, action: WindowAction::Close })
        );
        // A second "id" overwrites the request id: the answer couldn't be matched, so it is refused.
        let p = parse_line(r#"{"id":1,"op":"window","id":"0xa","action":"close"}"#);
        assert_eq!((p.id, p.request.unwrap_err().code), (Value::Null, Code::BadRequest));
        assert_eq!(req(r#"{"id":1,"op":"window","action":"close"}"#).unwrap_err().code, Code::BadRequest);
        assert_eq!(req(r#"{"id":1,"op":"window","window":"0xa","action":"explode"}"#).unwrap_err().code, Code::BadRequest);
        assert_eq!(req(r#"{"id":1,"op":"workspace","workspace":"2"}"#), Ok(Request::Workspace { id: "2".into() }));
        assert_eq!(req(r#"{"id":1,"op":"launch","app":"firefox.desktop"}"#), Ok(Request::Launch { id: "firefox.desktop".into() }));
        assert_eq!(req(r#"{"id":1,"op":"set-output","output":"5"}"#), Ok(Request::SetOutput { id: "5".into() }));
        assert_eq!(req(r#"{"id":1,"op":"subscribe","events":["focus"]}"#), Ok(Request::SubscribeFocus));
        assert!(req(r#"{"id":1,"op":"subscribe","events":["title"]}"#).is_err());
        assert!(req(r#"{"id":1,"op":"workspace","workspace":""}"#).is_err());
    }

    #[test]
    fn screenshot() {
        assert_eq!(
            req(r#"{"id":1,"op":"screenshot","format":"png"}"#),
            Ok(Request::Screenshot { target: Target::Default, max_width: None, format: ImageFormat::Png, quality: 80 })
        );
        assert_eq!(
            req(r#"{"id":1,"op":"screenshot","format":"jpeg","monitor":"DP-1","maxWidth":1280,"quality":60}"#),
            Ok(Request::Screenshot {
                target: Target::Monitor("DP-1".into()),
                max_width: Some(1280),
                format: ImageFormat::Jpeg,
                quality: 60
            })
        );
        assert_eq!(
            req(r#"{"id":1,"op":"screenshot","format":"jpeg","region":{"x":-10,"y":0,"w":5,"h":5}}"#),
            Ok(Request::Screenshot {
                target: Target::Region(Rect { x: -10, y: 0, w: 5, h: 5 }),
                max_width: None,
                format: ImageFormat::Jpeg,
                quality: 80
            })
        );
        for bad in [
            r#"{"id":1,"op":"screenshot"}"#,
            r#"{"id":1,"op":"screenshot","format":"gif"}"#,
            r#"{"id":1,"op":"screenshot","format":"png","maxWidth":63}"#,
            r#"{"id":1,"op":"screenshot","format":"png","maxWidth":3841}"#,
            r#"{"id":1,"op":"screenshot","format":"jpeg","quality":0}"#,
            r#"{"id":1,"op":"screenshot","format":"jpeg","quality":101}"#,
            r#"{"id":1,"op":"screenshot","format":"png","monitor":"a","window":"0x1"}"#,
            r#"{"id":1,"op":"screenshot","format":"png","region":{"x":0,"y":0,"w":0,"h":5}}"#,
            r#"{"id":1,"op":"screenshot","format":"png","window":"12"}"#,
        ] {
            assert_eq!(req(bad).unwrap_err().code, Code::BadRequest, "{bad}");
        }
    }

    #[test]
    fn pointer_and_scroll() {
        assert_eq!(req(r#"{"id":1,"op":"pointer","x":10.5,"y":-3}"#), Ok(Request::Pointer { x: 10.5, y: -3.0 }));
        assert!(req(r#"{"id":1,"op":"pointer","x":1e9,"y":0}"#).is_err());
        assert!(req(r#"{"id":1,"op":"pointer","x":1}"#).is_err());
        assert_eq!(
            req(r#"{"id":1,"op":"click","button":"left"}"#),
            Ok(Request::Click { button: Button::Left, at: None, double: false })
        );
        assert_eq!(
            req(r#"{"id":1,"op":"click","button":"right","x":1,"y":2,"double":true}"#),
            Ok(Request::Click { button: Button::Right, at: Some((1.0, 2.0)), double: true })
        );
        assert!(req(r#"{"id":1,"op":"click","button":"left","x":1}"#).is_err());
        assert!(req(r#"{"id":1,"op":"click","button":"back"}"#).is_err());
        assert_eq!(req(r#"{"id":1,"op":"scroll","dy":-20}"#), Ok(Request::Scroll { dx: 0, dy: -20 }));
        assert!(req(r#"{"id":1,"op":"scroll","dy":21}"#).is_err());
        assert!(req(r#"{"id":1,"op":"scroll","dx":1.5}"#).is_err());
        assert!(Request::Scroll { dx: 0, dy: 1 }.is_input());
        assert!(!Request::Windows.is_input());
    }

    #[test]
    fn text_limits() {
        let ok = "ğ".repeat(MAX_TEXT_CHARS);
        let line = json!({"id": 1, "op": "text", "text": ok}).to_string();
        assert_eq!(req(&line), Ok(Request::Text { text: ok }));
        let long = "a".repeat(MAX_TEXT_CHARS + 1);
        let line = json!({"id": 1, "op": "text", "text": long}).to_string();
        assert_eq!(req(&line).unwrap_err().code, Code::BadRequest);
        let line = json!({"id": 1, "op": "clipboard-set", "text": long}).to_string();
        assert!(req(&line).is_err());
        // The longest valid text escaped as \uXXXX still fits in a line.
        let worst = json!({"id": 1, "op": "text", "text": "\u{1}".repeat(MAX_TEXT_CHARS)}).to_string();
        assert!(worst.len() < MAX_LINE);
    }

    #[test]
    fn volume() {
        assert_eq!(req(r#"{"id":1,"op":"set-volume","percent":150}"#), Ok(Request::SetVolume { percent: Some(150), muted: None }));
        assert!(req(r#"{"id":1,"op":"set-volume","percent":151}"#).is_err());
        assert!(req(r#"{"id":1,"op":"set-volume","percent":-1}"#).is_err());
        assert!(req(r#"{"id":1,"op":"set-volume"}"#).is_err());
        assert_eq!(req(r#"{"id":1,"op":"set-volume","muted":true}"#), Ok(Request::SetVolume { percent: None, muted: Some(true) }));
    }

    #[test]
    fn apps_lang() {
        assert_eq!(req(r#"{"id":1,"op":"apps","lang":"tr_TR"}"#), Ok(Request::Apps { lang: Some("tr_TR".into()) }));
        assert_eq!(req(r#"{"id":1,"op":"apps","lang":""}"#), Ok(Request::Apps { lang: None }));
        assert!(req(r#"{"id":1,"op":"apps","lang":"../x"}"#).is_err());
    }

    #[test]
    fn key_combos() {
        let combo = |v: &[&str]| parse_combo(&v.iter().map(|s| s.to_string()).collect::<Vec<_>>());
        assert_eq!(combo(&["ctrl", "shift", "t"]), Ok(vec![Key::Ctrl, Key::Shift, Key::Char('t')]));
        assert_eq!(combo(&["enter"]), Ok(vec![Key::Enter]));
        assert_eq!(combo(&["super"]), Ok(vec![Key::Super]));
        assert_eq!(combo(&["alt", "f4"]), Ok(vec![Key::Alt, Key::F(4)]));
        assert_eq!(combo(&["ctrl", "5"]), Ok(vec![Key::Ctrl, Key::Char('5')]));
        assert!(combo(&["t"]).is_err(), "a letter alone goes through text");
        assert!(combo(&["t", "ctrl"]).is_err(), "modifiers first");
        assert!(combo(&["ctrl", "a", "b"]).is_err(), "one key after the modifiers");
        assert!(combo(&["ctrl", "ctrl", "a"]).is_err());
        assert!(combo(&[]).is_err());
        assert!(combo(&["ctrl", "A"]).is_err(), "names are lowercase");
        assert!(combo(&["hyper"]).is_err());
        assert!(combo(&["ctrl"; 9]).is_err());
    }

    #[test]
    fn rate_limiter() {
        let t0 = Instant::now();
        let mut rl = RateLimiter::new(60, t0);
        assert!((0..60).all(|_| rl.allow(t0)));
        assert!(!rl.allow(t0), "the 61st in the same instant is refused");
        // After 1/60 s one more token is back.
        assert!(rl.allow(t0 + Duration::from_millis(17)));
        assert!(!rl.allow(t0 + Duration::from_millis(17)));
        // A long pause refills to the burst size, no more.
        let t1 = t0 + Duration::from_secs(10);
        assert_eq!((0..100).filter(|_| rl.allow(t1)).count(), 60);
        // Steady 50/s is always allowed.
        let mut rl = RateLimiter::new(60, t0);
        assert!((0..500).all(|i| rl.allow(t0 + Duration::from_millis(20 * i))));
    }

    #[test]
    fn answer_lines() {
        assert_eq!(ok_line(&json!(3), json!({})), r#"{"id":3,"ok":true,"result":{}}"#);
        assert_eq!(
            err_line(&json!(4), &Error::unsupported("no")),
            r#"{"id":4,"ok":false,"error":{"code":"unsupported","message":"no"}}"#
        );
        let hello: Value = serde_json::from_str(&hello_line("none", &[])).unwrap();
        assert_eq!(hello["hello"]["protocol"], 1);
        assert_eq!(hello["hello"]["backend"], "none");
        assert_eq!(focus_event_line(None), r#"{"event":"focus","window":null}"#);
        let w = Window {
            id: window_id(0x42),
            title: "t".into(),
            app_id: "a".into(),
            pid: Some(1),
            workspace: None,
            monitor: Some("M".into()),
            x: 0,
            y: 0,
            w: 1,
            h: 1,
            focused: true,
            minimized: false,
            fullscreen: false,
            floating: false,
        };
        let v = serde_json::to_value(&w).unwrap();
        assert_eq!(v["appId"], "a");
        assert_eq!(v["id"], "0x42");
        assert!(v["workspace"].is_null());
    }

    #[test]
    fn rects() {
        let a = Rect { x: 0, y: 0, w: 100, h: 100 };
        let b = Rect { x: 50, y: 50, w: 100, h: 100 };
        assert_eq!(a.intersect(&b), Some(Rect { x: 50, y: 50, w: 50, h: 50 }));
        assert_eq!(a.intersect(&Rect { x: 100, y: 0, w: 5, h: 5 }), None);
        assert_eq!(Rect::union([a, b]), Some(Rect { x: 0, y: 0, w: 150, h: 150 }));
        assert!(a.contains(99.5, 0.0));
        assert!(!a.contains(100.0, 0.0));
    }
}
