//! Text parsers for the macOS backend's helper commands (`osascript`, `system_profiler`). Platform-independent so
//! they are tested on every host.

#![allow(dead_code)] // used by the macOS backend only

use crate::protocol::{Output, Volume};
use serde_json::Value;

/// `osascript` output `"<volume>,<muted>"` (e.g. `50,false`); `missing value` when the device has no volume.
pub fn volume(s: &str) -> Option<Volume> {
    let (v, m) = s.trim().split_once(',')?;
    let percent: f64 = v.trim().parse().ok()?;
    Some(Volume { percent: percent.round().clamp(0.0, 100.0) as u32, muted: m.trim() == "true" })
}

/// Output devices of `system_profiler SPAudioDataType -json` (ids are the device names).
pub fn outputs(v: &Value) -> Vec<Output> {
    v["SPAudioDataType"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|g| g["_items"].as_array().into_iter().flatten())
        .filter(|d| d.get("coreaudio_device_output").is_some())
        .filter_map(|d| {
            let name = d["_name"].as_str()?.to_string();
            Some(Output {
                id: name.clone(),
                name,
                default: d["coreaudio_default_audio_output_device"] == "spaudio_yes",
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn volumes() {
        assert_eq!(volume("50,false\n"), Some(Volume { percent: 50, muted: false }));
        assert_eq!(volume("7, true"), Some(Volume { percent: 7, muted: true }));
        assert_eq!(volume("missing value,false"), None);
    }

    #[test]
    fn audio_devices() {
        let v = json!({"SPAudioDataType": [{"_name": "coreaudio_device", "_items": [
            {"_name": "MacBook Pro Microphone", "coreaudio_device_input": 1, "coreaudio_default_audio_input_device": "spaudio_yes"},
            {"_name": "MacBook Pro Speakers", "coreaudio_device_output": 2, "coreaudio_default_audio_output_device": "spaudio_yes"},
            {"_name": "LG HDR 4K", "coreaudio_device_output": 2}
        ]}]});
        assert_eq!(
            outputs(&v),
            vec![
                Output { id: "MacBook Pro Speakers".into(), name: "MacBook Pro Speakers".into(), default: true },
                Output { id: "LG HDR 4K".into(), name: "LG HDR 4K".into(), default: false },
            ]
        );
        assert!(outputs(&json!({})).is_empty());
    }
}
