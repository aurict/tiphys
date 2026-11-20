//! The x11 backend against a private Xvfb server that this test starts (never the user's display).
//! The test client plays the window manager: it publishes EWMH properties and receives the client messages the
//! helper sends. Skipped when Xvfb isn't installed.

#![cfg(target_os = "linux")]

mod common;

use common::{BIN, Helper, split_jpegs};
use serde_json::json;
use std::io::Read;
use std::path::Path;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};
use x11rb::connection::Connection;
use x11rb::protocol::Event;
use x11rb::protocol::xproto::*;
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

struct Xvfb {
    child: Child,
    display: String,
}

impl Drop for Xvfb {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn start_xvfb() -> Option<Xvfb> {
    if !Path::new("/usr/bin/Xvfb").exists() && Command::new("Xvfb").arg("-help").output().is_err() {
        eprintln!("Xvfb not installed: skipping");
        return None;
    }
    let base = 140 + std::process::id() % 300;
    let n = (base..base + 200)
        .find(|n| !Path::new(&format!("/tmp/.X11-unix/X{n}")).exists() && !Path::new(&format!("/tmp/.X{n}-lock")).exists())?;
    let display = format!(":{n}");
    let child = Command::new("Xvfb")
        .args([&display, "-screen", "0", "1280x800x24", "-nolisten", "tcp", "-noreset"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let x = Xvfb { child, display };
    let deadline = Instant::now() + Duration::from_secs(10);
    while !Path::new(&format!("/tmp/.X11-unix/X{n}")).exists() {
        assert!(Instant::now() < deadline, "Xvfb did not start");
        std::thread::sleep(Duration::from_millis(50));
    }
    Some(x)
}

fn atom(c: &RustConnection, name: &str) -> u32 {
    c.intern_atom(false, name.as_bytes()).unwrap().reply().unwrap().atom
}

fn make_window(c: &RustConnection, root: u32, x: i16, y: i16, w: u16, h: u16, color: u32, title: &str, class: &[u8]) -> u32 {
    let win = c.generate_id().unwrap();
    let aux = CreateWindowAux::new().background_pixel(color).event_mask(
        EventMask::KEY_PRESS | EventMask::KEY_RELEASE | EventMask::BUTTON_PRESS | EventMask::BUTTON_RELEASE,
    );
    c.create_window(0, win, root, x, y, w, h, 0, WindowClass::INPUT_OUTPUT, 0, &aux).unwrap();
    c.change_property8(PropMode::REPLACE, win, atom(c, "_NET_WM_NAME"), atom(c, "UTF8_STRING"), title.as_bytes()).unwrap();
    c.change_property8(PropMode::REPLACE, win, AtomEnum::WM_CLASS, AtomEnum::STRING, class).unwrap();
    c.change_property32(PropMode::REPLACE, win, atom(c, "_NET_WM_PID"), AtomEnum::CARDINAL, &[4242]).unwrap();
    c.change_property32(PropMode::REPLACE, win, atom(c, "_NET_WM_DESKTOP"), AtomEnum::CARDINAL, &[0]).unwrap();
    c.map_window(win).unwrap();
    win
}

/// Events that arrive within `wait`.
fn events(c: &RustConnection, wait: Duration) -> Vec<Event> {
    let deadline = Instant::now() + wait;
    let mut out = Vec::new();
    while Instant::now() < deadline {
        match c.poll_for_event().unwrap() {
            Some(e) => out.push(e),
            None => std::thread::sleep(Duration::from_millis(10)),
        }
    }
    out
}

fn client_messages(evs: &[Event]) -> Vec<(u32, u32, [u32; 5])> {
    evs.iter()
        .filter_map(|e| match e {
            Event::ClientMessage(m) => Some((m.window, m.type_, m.data.as_data32())),
            _ => None,
        })
        .collect()
}

fn decode_png(b64: &str) -> (u32, u32, Vec<u8>) {
    let bytes = base64_decode(b64);
    let mut r = png::Decoder::new(std::io::Cursor::new(bytes)).read_info().unwrap();
    let mut buf = vec![0; r.output_buffer_size().unwrap()];
    let info = r.next_frame(&mut buf).unwrap();
    assert_eq!(info.color_type, png::ColorType::Rgb);
    (info.width, info.height, buf)
}

fn base64_decode(s: &str) -> Vec<u8> {
    let val = |c: u8| match c {
        b'A'..=b'Z' => c - b'A',
        b'a'..=b'z' => c - b'a' + 26,
        b'0'..=b'9' => c - b'0' + 52,
        b'+' => 62,
        b'/' => 63,
        _ => panic!("bad base64"),
    };
    let mut out = Vec::new();
    for chunk in s.as_bytes().chunks(4) {
        let n = chunk.iter().take_while(|&&c| c != b'=').fold(0u32, |a, &c| a << 6 | val(c) as u32);
        let pad = chunk.iter().filter(|&&c| c == b'=').count();
        let n = n << (6 * pad);
        let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend_from_slice(&bytes[..3 - pad]);
    }
    out
}

#[test]
fn x11_backend_in_xvfb() {
    let Some(xvfb) = start_xvfb() else { return };
    let (c, screen) = x11rb::connect(Some(&xvfb.display)).expect("connect to Xvfb");
    let root = c.setup().roots[screen].root;

    // Two client windows and the EWMH root properties a window manager would publish.
    let w1 = make_window(&c, root, 0, 0, 200, 100, 0xff0000, "Alpha", b"alpha\0Alpha\0");
    let w2 = make_window(&c, root, 300, 200, 400, 300, 0x00ff00, "Beta ğ", b"beta\0Beta\0");
    let supported: Vec<u32> =
        ["_NET_ACTIVE_WINDOW", "_NET_CLOSE_WINDOW", "_NET_NUMBER_OF_DESKTOPS", "_NET_CLIENT_LIST"].iter().map(|a| atom(&c, a)).collect();
    c.change_property32(PropMode::REPLACE, root, atom(&c, "_NET_SUPPORTED"), AtomEnum::ATOM, &supported).unwrap();
    c.change_property32(PropMode::REPLACE, root, atom(&c, "_NET_CLIENT_LIST"), AtomEnum::WINDOW, &[w1, w2]).unwrap();
    c.change_property32(PropMode::REPLACE, root, atom(&c, "_NET_ACTIVE_WINDOW"), AtomEnum::WINDOW, &[w2]).unwrap();
    c.change_property32(PropMode::REPLACE, root, atom(&c, "_NET_NUMBER_OF_DESKTOPS"), AtomEnum::CARDINAL, &[2]).unwrap();
    c.change_property32(PropMode::REPLACE, root, atom(&c, "_NET_CURRENT_DESKTOP"), AtomEnum::CARDINAL, &[0]).unwrap();
    c.change_property8(PropMode::REPLACE, root, atom(&c, "_NET_DESKTOP_NAMES"), atom(&c, "UTF8_STRING"), b"one\0two\0").unwrap();
    c.set_input_focus(InputFocus::PARENT, w2, x11rb::CURRENT_TIME).unwrap();
    // Become the "window manager": client messages to the root come to us.
    c.change_window_attributes(root, &ChangeWindowAttributesAux::new().event_mask(EventMask::SUBSTRUCTURE_REDIRECT))
        .unwrap()
        .check()
        .expect("no other WM on the private Xvfb");
    c.sync().unwrap();
    events(&c, Duration::from_millis(100));

    let env = [("DISPLAY", xvfb.display.as_str()), ("TIPHYS_DESKTOP_BACKEND", "x11")];
    let mut h = Helper::start(&env);
    assert_eq!(h.hello["backend"], json!("x11"));
    for cap in ["windows", "windowActions", "workspaces", "monitors", "screenshot", "stream", "input", "text", "apps", "launch", "clipboard"] {
        assert!(h.has(cap), "capability {cap} in {:?}", h.capabilities());
    }
    if let Some(kib) = h.rss_kib() {
        eprintln!("idle RSS (x11 backend, test build): {kib} KiB");
    }

    // windows / focused
    let wins = h.ok(json!({"op": "windows"}));
    let wins = wins.as_array().unwrap();
    assert_eq!(wins.len(), 2);
    let id1 = format!("0x{w1:x}");
    let id2 = format!("0x{w2:x}");
    assert_eq!(wins[0]["id"], json!(id2), "focused first");
    assert_eq!(wins[0]["title"], json!("Beta ğ"));
    assert_eq!(wins[0]["appId"], json!("Beta"));
    assert_eq!(wins[0]["pid"], json!(4242));
    assert_eq!(wins[0]["focused"], json!(true));
    assert_eq!(wins[0]["workspace"], json!("0"));
    assert_eq!((wins[0]["x"].clone(), wins[0]["y"].clone(), wins[0]["w"].clone(), wins[0]["h"].clone()), (json!(300), json!(200), json!(400), json!(300)));
    assert_eq!(wins[1]["id"], json!(id1));
    assert_eq!(h.ok(json!({"op": "focused"}))["id"], json!(id2));

    // monitors
    let mons = h.ok(json!({"op": "monitors"}));
    let m = &mons.as_array().unwrap()[0];
    assert_eq!((m["w"].clone(), m["h"].clone(), m["primary"].clone()), (json!(1280), json!(800), json!(true)));
    assert_eq!(wins[0]["monitor"], m["id"]);

    // workspaces
    let ws = h.ok(json!({"op": "workspaces"}));
    assert_eq!(ws, json!([{"id": "0", "name": "one", "focused": true, "monitor": null}, {"id": "1", "name": "two", "focused": false, "monitor": null}]));

    // window and workspace actions arrive as EWMH client messages
    h.ok(json!({"op": "window", "window": id1, "action": "focus"}));
    h.ok(json!({"op": "window", "window": id1, "action": "close"}));
    h.ok(json!({"op": "window", "window": id1, "action": "fullscreen"}));
    h.ok(json!({"op": "workspace", "workspace": "1"}));
    h.ok(json!({"op": "move-to-workspace", "window": id2, "workspace": "1"}));
    let msgs = client_messages(&events(&c, Duration::from_millis(300)));
    let has = |win: u32, ty: &str, d0: u32| msgs.iter().any(|(w, t, d)| *w == win && *t == atom(&c, ty) && d[0] == d0);
    assert!(has(w1, "_NET_ACTIVE_WINDOW", 2), "{msgs:?}");
    assert!(has(w1, "_NET_CLOSE_WINDOW", 0), "{msgs:?}");
    assert!(has(w1, "_NET_WM_STATE", 2), "{msgs:?}");
    assert!(has(root, "_NET_CURRENT_DESKTOP", 1), "{msgs:?}");
    assert!(has(w2, "_NET_WM_DESKTOP", 1), "{msgs:?}");
    assert_eq!(h.err(json!({"op": "window", "window": "0xdead", "action": "focus"})), "notFound");
    assert_eq!(h.err(json!({"op": "window", "window": id1, "action": "float"})), "unsupported");
    assert_eq!(h.err(json!({"op": "workspace", "workspace": "5"})), "notFound");

    // screenshots
    let shot = h.ok(json!({"op": "screenshot", "format": "png", "region": {"x": 0, "y": 0, "w": 200, "h": 100}}));
    let (w, hh, px) = decode_png(shot["data"].as_str().unwrap());
    assert_eq!((w, hh, shot["width"].clone(), shot["format"].clone()), (200, 100, json!(200), json!("png")));
    assert_eq!(&px[(50 * 200 + 100) * 3..][..3], &[255, 0, 0]);
    let shot = h.ok(json!({"op": "screenshot", "format": "png", "window": id2, "maxWidth": 100}));
    let (w, hh, px) = decode_png(shot["data"].as_str().unwrap());
    assert_eq!((w, hh), (100, 75));
    assert_eq!(&px[(37 * 100 + 50) * 3..][..3], &[0, 255, 0]);
    let shot = h.ok(json!({"op": "screenshot", "format": "jpeg", "quality": 50, "maxWidth": 640}));
    assert_eq!((shot["width"].clone(), shot["height"].clone()), (json!(640), json!(400)));
    assert!(base64_decode(shot["data"].as_str().unwrap()).starts_with(&[0xff, 0xd8]));
    assert_eq!(h.err(json!({"op": "screenshot", "format": "png", "monitor": "nope"})), "notFound");

    // pointer, click, drag, scroll
    h.ok(json!({"op": "pointer", "x": 310, "y": 220}));
    let p = c.query_pointer(root).unwrap().reply().unwrap();
    assert_eq!((p.root_x, p.root_y), (310, 220));
    events(&c, Duration::from_millis(50));
    h.ok(json!({"op": "click", "button": "left", "x": 500, "y": 350, "double": true}));
    h.ok(json!({"op": "button", "button": "right", "down": true}));
    h.ok(json!({"op": "pointer", "x": 520, "y": 360}));
    h.ok(json!({"op": "button", "button": "right", "down": false}));
    h.ok(json!({"op": "scroll", "dy": 2, "dx": -1}));
    let evs = events(&c, Duration::from_millis(300));
    let presses: Vec<u8> = evs.iter().filter_map(|e| if let Event::ButtonPress(b) = e { (b.event == w2).then_some(b.detail) } else { None }).collect();
    let releases = evs.iter().filter(|e| matches!(e, Event::ButtonRelease(_))).count();
    assert_eq!(presses, vec![1, 1, 3, 5, 5, 6], "{evs:?}");
    assert_eq!(releases, 6);

    // keys and text go to the focused window
    let map = c.get_keyboard_mapping(c.setup().min_keycode, c.setup().max_keycode - c.setup().min_keycode + 1).unwrap().reply().unwrap();
    let per = map.keysyms_per_keycode as usize;
    let sym_of = |code: u8, shift: bool| map.keysyms[(code - c.setup().min_keycode) as usize * per + shift as usize];
    let is_mod = |s: u32| (0xffe1..=0xffee).contains(&s);
    h.ok(json!({"op": "key", "keys": ["ctrl", "a"]}));
    h.ok(json!({"op": "text", "text": "Hi!"}));
    let evs = events(&c, Duration::from_millis(300));
    let typed: Vec<(u32, bool)> = evs
        .iter()
        .filter_map(|e| match e {
            Event::KeyPress(k) if k.event == w2 => {
                let shift = u16::from(k.state) & u16::from(KeyButMask::SHIFT) != 0;
                let ctrl = u16::from(k.state) & u16::from(KeyButMask::CONTROL) != 0;
                let s = sym_of(k.detail, shift);
                (!is_mod(sym_of(k.detail, false))).then_some((s, ctrl))
            }
            _ => None,
        })
        .collect();
    assert_eq!(typed, vec![(0x61, true), (0x48, false), (0x69, false), (0x21, false)], "{evs:?}");
    // A character outside the keymap is typed through a borrowed keycode, which is restored afterwards.
    h.ok(json!({"op": "text", "text": "ğ"}));
    let evs = events(&c, Duration::from_millis(300));
    assert_eq!(evs.iter().filter(|e| matches!(e, Event::KeyPress(_))).count(), 1, "{evs:?}");
    let after = c.get_keyboard_mapping(c.setup().min_keycode, c.setup().max_keycode - c.setup().min_keycode + 1).unwrap().reply().unwrap();
    assert_eq!(after.keysyms, map.keysyms, "keymap restored");
    assert_eq!(h.err(json!({"op": "key", "keys": ["a"]})), "badRequest");

    // input budget: 60/s, the rest is busy
    let ids: Vec<u64> = (0..100).map(|i| h.send(json!({"op": "pointer", "x": i, "y": 5}))).collect();
    let busy = ids.into_iter().filter(|&id| h.wait(id)["error"]["code"] == json!("busy")).count();
    assert!((30..=45).contains(&busy), "busy {busy}");

    // clipboard
    h.ok(json!({"op": "clipboard-set", "text": "merhaba ğ"}));
    assert_eq!(h.ok(json!({"op": "clipboard-get"})), json!({"text": "merhaba ğ"}));

    // dpms when the server has it
    if h.has("dpms") {
        h.ok(json!({"op": "dpms", "on": false}));
        h.ok(json!({"op": "dpms", "on": true}));
    }
    assert!(h.ok(json!({"op": "apps"})).is_array());

    // focus events
    h.ok(json!({"op": "subscribe", "events": ["focus"]}));
    c.change_property32(PropMode::REPLACE, root, atom(&c, "_NET_ACTIVE_WINDOW"), AtomEnum::WINDOW, &[w1]).unwrap();
    c.sync().unwrap();
    let ev = h.event(Duration::from_secs(3)).expect("focus event");
    assert_eq!(ev["event"], json!("focus"));
    assert_eq!(ev["window"]["id"], json!(id1));
    assert_eq!(ev["window"]["title"], json!("Alpha"));

    // stream mode: frames until stdin closes
    let mut s = Command::new(BIN)
        .args(["stream", "--region", "0,0,200,100", "--fps", "10", "--max-width", "100", "--quality", "4"])
        .envs(env)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut out = s.stdout.take().unwrap();
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        out.read_to_end(&mut buf).unwrap();
        buf
    });
    std::thread::sleep(Duration::from_millis(600));
    // A change on screen produces a new frame; an unchanged screen doesn't.
    c.change_window_attributes(w1, &ChangeWindowAttributesAux::new().background_pixel(0x0000ff)).unwrap();
    c.clear_area(false, w1, 0, 0, 0, 0).unwrap();
    c.sync().unwrap();
    std::thread::sleep(Duration::from_millis(600));
    drop(s.stdin.take());
    let status = s.wait().unwrap();
    assert_eq!(status.code(), Some(0));
    let frames = split_jpegs(&reader.join().unwrap());
    assert_eq!(frames.len(), 2, "one frame, then one after the change");
    for f in &frames {
        let mut d = zune_jpeg::JpegDecoder::new(std::io::Cursor::new(f));
        let px = d.decode().unwrap();
        let info = d.info().unwrap();
        assert_eq!((info.width, info.height), (100, 50));
        assert!(px.len() >= 3);
    }
    let code = Command::new(BIN).args(["stream", "--monitor", "nope"]).envs(env).stdin(Stdio::null()).status().unwrap().code();
    assert_eq!(code, Some(4));

    assert_eq!(h.close().code(), Some(0));
}
