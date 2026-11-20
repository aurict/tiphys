//! Pieces shared by the Linux backends: PipeWire volume through `wpctl`, Wayland clipboard through
//! `wl-copy`/`wl-paste`.

#![allow(dead_code)] // not every backend uses every piece

use crate::protocol::{Error, Output, Res, Volume};
use crate::util::{RUN_TIMEOUT, run, run_ok, which};

const SINK: &str = "@DEFAULT_AUDIO_SINK@";

pub fn has_wpctl() -> bool {
    which("wpctl").is_some()
}

pub fn has_wl_clipboard() -> bool {
    which("wl-copy").is_some() && which("wl-paste").is_some()
}

/// `Volume: 0.40 [MUTED]` → 40 %, muted.
pub fn parse_wpctl_volume(s: &str) -> Option<Volume> {
    let rest = s.trim().strip_prefix("Volume:")?.trim();
    let num = rest.split_whitespace().next()?;
    let v: f64 = num.parse().ok()?;
    Some(Volume { percent: (v * 100.0).round().clamp(0.0, 1000.0) as u32, muted: rest.contains("[MUTED]") })
}

/// The `Sinks:` list of the `Audio` section of `wpctl status`.
pub fn parse_wpctl_sinks(status: &str) -> Vec<Output> {
    let mut out = Vec::new();
    let mut in_audio = false;
    let mut in_sinks = false;
    for line in status.lines() {
        if !line.starts_with(' ') && !line.trim().is_empty() {
            in_audio = line.trim() == "Audio";
            in_sinks = false;
            continue;
        }
        if !in_audio {
            continue;
        }
        let body = line.trim_start_matches([' ', '│', '├', '└', '─']).trim_end();
        if body.ends_with(':') {
            in_sinks = body == "Sinks:";
            continue;
        }
        if !in_sinks || body.is_empty() {
            continue;
        }
        let (default, body) = match body.strip_prefix('*') {
            Some(b) => (true, b.trim_start()),
            None => (false, body),
        };
        let Some((id, rest)) = body.split_once(". ") else { continue };
        if id.is_empty() || !id.bytes().all(|b| b.is_ascii_digit()) {
            continue;
        }
        let name = rest.rfind(" [vol:").map_or(rest, |i| &rest[..i]).trim();
        out.push(Output { id: id.to_string(), name: name.to_string(), default });
    }
    out
}

pub fn volume() -> Res<Volume> {
    let out = run_ok("wpctl", &["get-volume", SINK], None)?;
    parse_wpctl_volume(&out.text()).ok_or_else(|| Error::failed("unexpected wpctl output"))
}

pub fn set_volume(percent: Option<u32>, muted: Option<bool>) -> Res<Volume> {
    if let Some(p) = percent {
        run_ok("wpctl", &["set-volume", SINK, &format!("{:.2}", p as f64 / 100.0)], None)?;
    }
    if let Some(m) = muted {
        run_ok("wpctl", &["set-mute", SINK, if m { "1" } else { "0" }], None)?;
    }
    volume()
}

pub fn outputs() -> Res<Vec<Output>> {
    Ok(parse_wpctl_sinks(&run_ok("wpctl", &["status"], None)?.text()))
}

pub fn set_output(id: &str) -> Res<Vec<Output>> {
    if !outputs()?.iter().any(|o| o.id == id) {
        return Err(Error::not_found("no such output"));
    }
    run_ok("wpctl", &["set-default", id], None)?;
    outputs()
}

/// Text on the Wayland clipboard; `None` when it holds something else (or nothing).
pub fn wl_clipboard_get() -> Res<Option<String>> {
    let types = run("wl-paste", &["--list-types"], None, RUN_TIMEOUT)?;
    let types = types.text();
    let Some(mime) = ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "TEXT", "STRING"]
        .into_iter()
        .find(|t| types.lines().any(|l| l.trim() == *t))
    else {
        return Ok(None);
    };
    let out = run_ok("wl-paste", &["--no-newline", "--type", mime], None)?;
    Ok(String::from_utf8(out.stdout).ok())
}

pub fn wl_clipboard_set(text: &str) -> Res<()> {
    // wl-copy forks a server that keeps the selection after we return.
    run_ok("wl-copy", &["--type", "text/plain;charset=utf-8"], Some(text.as_bytes())).map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn volumes() {
        assert_eq!(parse_wpctl_volume("Volume: 0.40\n"), Some(Volume { percent: 40, muted: false }));
        assert_eq!(parse_wpctl_volume("Volume: 1.25 [MUTED]"), Some(Volume { percent: 125, muted: true }));
        assert_eq!(parse_wpctl_volume("nope"), None);
    }

    #[test]
    fn sinks() {
        let status = "PipeWire 'pipewire-0' [1.6.9]\n └─ Clients:\n        33. pipewire   [1.6.9]\n\nAudio\n ├─ Devices:\n │      49. GP107GL High Definition Audio Controller [alsa]\n │  \n ├─ Sinks:\n │  *   57. Family 17h HD Audio Controller Analog Stereo [vol: 1.00]\n │      60. HDMI 1. Output               [vol: 0.40 MUTED]\n │  \n ├─ Sources:\n │  *   58. Mic [vol: 1.00]\n │  \n └─ Streams:\n        64. Velour\n\nVideo\n ├─ Sinks:\n │      99. Not audio\n";
        assert_eq!(
            parse_wpctl_sinks(status),
            vec![
                Output { id: "57".into(), name: "Family 17h HD Audio Controller Analog Stereo".into(), default: true },
                Output { id: "60".into(), name: "HDMI 1. Output".into(), default: false },
            ]
        );
        assert!(parse_wpctl_sinks("").is_empty());
    }
}
