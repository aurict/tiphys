//! serve/stream with the `none` backend: the wire protocol without any desktop.

mod common;

use common::{BIN, Helper};
use serde_json::json;
use std::process::{Command, Stdio};
use std::time::Duration;

fn none() -> Helper {
    Helper::start(&[("TIPHYS_DESKTOP_BACKEND", "none")])
}

#[test]
fn hello_and_unsupported() {
    let mut h = none();
    assert_eq!(h.hello["protocol"], json!(1));
    assert_eq!(h.hello["backend"], json!("none"));
    assert_eq!(h.hello["version"], json!(env!("CARGO_PKG_VERSION")));
    assert!(h.capabilities().is_empty());
    assert_eq!(h.ok(json!({"op": "ping"})), json!({}));
    for op in [
        json!({"op": "windows"}),
        json!({"op": "focused"}),
        json!({"op": "monitors"}),
        json!({"op": "apps"}),
        json!({"op": "pointer", "x": 1, "y": 2}),
        json!({"op": "text", "text": "hi"}),
        json!({"op": "screenshot", "format": "png"}),
        json!({"op": "volume"}),
        json!({"op": "clipboard-get"}),
        json!({"op": "subscribe", "events": ["focus"]}),
        json!({"op": "window", "window": "0x1", "action": "focus"}),
    ] {
        assert_eq!(h.err(op.clone()), "unsupported", "{op}");
    }
    assert_eq!(h.close().code(), Some(0));
}

#[test]
fn bad_requests() {
    let mut h = none();
    // Validation comes before the capability check.
    assert_eq!(h.err(json!({"op": "text", "text": "x".repeat(4001)})), "badRequest");
    assert_eq!(h.err(json!({"op": "scroll", "dy": 50})), "badRequest");
    assert_eq!(h.err(json!({"op": "window", "window": "123", "action": "focus"})), "badRequest");
    assert_eq!(h.err(json!({"op": "teleport"})), "badRequest");
    // Unparsable lines are answered with id null; the helper keeps going.
    h.send_raw("{not json");
    let a = h.next_line(Duration::from_secs(5)).unwrap();
    assert_eq!((a["id"].clone(), a["error"]["code"].clone()), (json!(null), json!("badRequest")));
    h.send_raw(&"x".repeat(200_000));
    let a = h.next_line(Duration::from_secs(5)).unwrap();
    assert_eq!(a["error"]["message"], json!("request line too long"));
    h.send_raw("");
    assert_eq!(h.ok(json!({"op": "ping"})), json!({}));
}

#[test]
fn answers_many_pings_and_stays_small() {
    let mut h = none();
    let ids: Vec<u64> = (0..200).map(|_| h.send(json!({"op": "ping"}))).collect();
    for id in ids {
        assert_eq!(h.wait(id)["ok"], json!(true));
    }
    if let Some(kib) = h.rss_kib() {
        eprintln!("idle RSS (none backend, test build): {kib} KiB");
        assert!(kib < 15 * 1024, "RSS {kib} KiB");
    }
}

#[test]
fn stream_unsupported_and_bad_args() {
    let run = |args: &[&str]| {
        Command::new(BIN)
            .args(args)
            .env("TIPHYS_DESKTOP_BACKEND", "none")
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap()
            .code()
    };
    assert_eq!(run(&["stream", "--monitor", "x"]), Some(5));
    assert_eq!(run(&["stream", "--fps", "99"]), Some(2));
    assert_eq!(run(&["bogus"]), Some(2));
    assert_eq!(run(&["--version"]), Some(0));
}
