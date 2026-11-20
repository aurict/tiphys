//! `stream` mode: JPEG frames back to back on stdout (like `wf-recorder -c mjpeg -m mjpeg -f pipe:1`) until stdin
//! closes or the reader goes away. Unchanged frames are skipped.
//!
//! Exit codes: 0 done, 1 failed, 2 bad arguments, 3 permission missing, 4 monitor not found, 5 unsupported here.

use crate::backend::{self, CAP_STREAM};
use crate::frame::{self, Frame};
use crate::protocol::{Code, Error, FPS_RANGE, MAX_WIDTH_RANGE, QSCALE_RANGE, Rect, Res, Target, frame_interval};
use std::io::{self, Read, Write};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::Instant;

/// Consecutive capture failures tolerated (a busy compositor can fail one grab) before giving up.
const MAX_FAILURES: u32 = 10;

#[derive(Debug, Clone, PartialEq)]
pub struct Opts {
    pub target: Target,
    pub fps: u32,
    pub max_width: Option<u32>,
    pub qscale: u8,
}

pub fn parse_args(args: &[String]) -> Result<Opts, String> {
    let mut o = Opts { target: Target::Default, fps: 15, max_width: None, qscale: 8 };
    let (mut monitor, mut region) = (None, None);
    let mut it = args.iter();
    while let Some(a) = it.next() {
        let mut val = || it.next().cloned().ok_or_else(|| format!("{a} needs a value"));
        let num = |v: String, (lo, hi): (u32, u32)| -> Result<u32, String> {
            v.parse::<u32>().ok().filter(|n| (lo..=hi).contains(n)).ok_or_else(|| format!("{a} must be {lo}–{hi}"))
        };
        match a.as_str() {
            "--monitor" => monitor = Some(val()?).filter(|m| !m.is_empty() && m.len() <= 512),
            "--region" => {
                let v = val()?;
                let p: Vec<i32> = v.split(',').map(|s| s.trim().parse::<i32>()).collect::<Result<_, _>>().map_err(|_| "bad --region")?;
                match p[..] {
                    [x, y, w, h] if w > 0 && h > 0 => region = Some(Rect { x, y, w, h }),
                    _ => return Err("--region is x,y,w,h with a positive size".into()),
                }
            }
            "--fps" => o.fps = num(val()?, FPS_RANGE)?,
            "--max-width" => o.max_width = Some(num(val()?, MAX_WIDTH_RANGE)?),
            "--quality" => o.qscale = num(val()?, (QSCALE_RANGE.0 as u32, QSCALE_RANGE.1 as u32))? as u8,
            other => return Err(format!("unknown argument {other}")),
        }
    }
    o.target = match (monitor, region) {
        (_, Some(r)) => Target::Region(r),
        (Some(m), None) => Target::Monitor(m),
        (None, None) => Target::Default,
    };
    Ok(o)
}

fn exit_code(e: &Error) -> i32 {
    match e.code {
        Code::Permission => 3,
        Code::NotFound => 4,
        Code::Unsupported => 5,
        Code::BadRequest => 2,
        _ => 1,
    }
}

pub fn main(args: &[String]) -> i32 {
    let opts = match parse_args(args) {
        Ok(o) => o,
        Err(e) => {
            eprintln!("tiphys-desktop stream: {e}");
            return 2;
        }
    };
    let b = backend::detect();
    if !b.capabilities().contains(&CAP_STREAM) {
        eprintln!("tiphys-desktop stream: not supported by the {} backend", b.name());
        return 5;
    }
    let fail = |e: Error| {
        eprintln!("tiphys-desktop stream: {}", e.message);
        exit_code(&e)
    };
    // A region is clipped to the monitor it was given with (when both are given), so a window target stays on it.
    let rect = match (&opts.target, args.iter().position(|a| a == "--monitor")) {
        (Target::Region(r), Some(i)) => {
            let m = Target::Monitor(args[i + 1].clone());
            match backend::target_rect(&*b, &m) {
                Ok(mr) => mr.intersect(r).ok_or_else(|| Error::bad("the region is outside the monitor")),
                Err(e) => Err(e),
            }
        }
        (t, _) => backend::target_rect(&*b, t),
    };
    let rect = match rect {
        Ok(r) => r,
        Err(e) => return fail(e),
    };
    let stop = Arc::new(AtomicBool::new(false));
    let s = stop.clone();
    thread::spawn(move || {
        let mut sink = [0u8; 256];
        let mut stdin = io::stdin().lock();
        while matches!(stdin.read(&mut sink), Ok(n) if n > 0) {}
        s.store(true, Ordering::SeqCst);
    });
    let mut out = io::stdout().lock();
    match run_loop(|| b.capture(rect), &opts, &mut out, &stop, None) {
        Ok(_) => 0,
        Err(e) => fail(e),
    }
}

/// Captures at `opts.fps` until `stop` is set, the writer fails (reader gone → Ok) or `max_frames` were written.
pub fn run_loop(
    mut capture: impl FnMut() -> Res<Frame>,
    opts: &Opts,
    out: &mut impl Write,
    stop: &AtomicBool,
    max_frames: Option<u64>,
) -> Res<u64> {
    let interval = frame_interval(opts.fps);
    let quality = frame::mjpeg_quality(opts.qscale);
    let mut last = None;
    let mut written = 0u64;
    let mut failures = 0;
    let mut next = Instant::now();
    while !stop.load(Ordering::SeqCst) && max_frames.is_none_or(|m| written < m) {
        match capture() {
            Ok(f) => {
                failures = 0;
                let fp = f.fingerprint();
                if last != Some(fp) {
                    let jpg = frame::encode_jpeg(&frame::to_rgb(&f, opts.max_width), quality)?;
                    drop(f);
                    if out.write_all(&jpg).and_then(|_| out.flush()).is_err() {
                        return Ok(written);
                    }
                    last = Some(fp);
                    written += 1;
                }
            }
            Err(e) if matches!(e.code, Code::Permission | Code::Unsupported | Code::NotFound) => return Err(e),
            Err(e) => {
                failures += 1;
                if failures >= MAX_FAILURES {
                    return Err(e);
                }
            }
        }
        next += interval;
        let now = Instant::now();
        if next > now {
            thread::sleep(next - now);
        } else {
            next = now; // fell behind: don't try to catch up with a burst
        }
    }
    Ok(written)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::frame::PixelFormat;

    fn a(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn args() {
        assert_eq!(
            parse_args(&a(&["--monitor", "DP-1", "--fps", "30", "--max-width", "1280", "--quality", "8"])),
            Ok(Opts { target: Target::Monitor("DP-1".into()), fps: 30, max_width: Some(1280), qscale: 8 })
        );
        assert_eq!(
            parse_args(&a(&["--region", "-10,0,100,50"])).unwrap().target,
            Target::Region(Rect { x: -10, y: 0, w: 100, h: 50 })
        );
        assert_eq!(parse_args(&[]).unwrap(), Opts { target: Target::Default, fps: 15, max_width: None, qscale: 8 });
        for bad in [
            &["--fps", "0"][..],
            &["--fps", "61"],
            &["--quality", "1"],
            &["--quality", "32"],
            &["--max-width", "63"],
            &["--region", "1,2,3"],
            &["--region", "0,0,0,5"],
            &["--monitor"],
            &["--bogus"],
        ] {
            assert!(parse_args(&a(bad)).is_err(), "{bad:?}");
        }
    }

    /// Splits an MJPEG byte stream into frames the way the agent does (SOI … EOI).
    fn split(mut b: &[u8]) -> Vec<&[u8]> {
        let mut out = Vec::new();
        while !b.is_empty() {
            assert_eq!(&b[..2], &[0xff, 0xd8], "frame starts with SOI");
            let end = b.windows(2).position(|w| w == [0xff, 0xd9]).unwrap() + 2;
            out.push(&b[..end]);
            b = &b[end..];
        }
        out
    }

    #[test]
    fn mjpeg_framing() {
        let mut n = 0u8;
        let capture = || {
            n += 1;
            // Frames 1 and 2 are identical (skipped), then every frame differs.
            let shade = if n <= 2 { 10 } else { n * 20 };
            Frame::new(32, 16, 32 * 3, PixelFormat::Rgb, vec![shade; 32 * 16 * 3])
        };
        let opts = Opts { target: Target::Default, fps: 60, max_width: Some(16), qscale: 4 };
        let mut out = Vec::new();
        let stop = AtomicBool::new(false);
        let written = run_loop(capture, &opts, &mut out, &stop, Some(3)).unwrap();
        assert_eq!(written, 3);
        let frames = split(&out);
        assert_eq!(frames.len(), 3);
        for f in frames {
            let mut d = zune_jpeg::JpegDecoder::new(std::io::Cursor::new(f));
            d.decode().unwrap();
            let info = d.info().unwrap();
            assert_eq!((info.width, info.height), (16, 8));
        }
    }

    #[test]
    fn stops_and_reports() {
        let opts = Opts { target: Target::Default, fps: 60, max_width: None, qscale: 8 };
        let stop = AtomicBool::new(true);
        assert_eq!(run_loop(|| unreachable!(), &opts, &mut Vec::new(), &stop, None), Ok(0));
        let stop = AtomicBool::new(false);
        let r = run_loop(|| Err(Error::permission("Screen Recording")), &opts, &mut Vec::new(), &stop, None);
        assert_eq!(exit_code(&r.unwrap_err()), 3);
        let r = run_loop(|| Err(Error::failed("flaky")), &opts, &mut Vec::new(), &stop, None);
        assert_eq!(exit_code(&r.unwrap_err()), 1);
        // A closed reader ends the stream quietly.
        struct Closed;
        impl Write for Closed {
            fn write(&mut self, _: &[u8]) -> io::Result<usize> {
                Err(io::ErrorKind::BrokenPipe.into())
            }
            fn flush(&mut self) -> io::Result<()> {
                Ok(())
            }
        }
        let f = || Frame::new(8, 8, 24, PixelFormat::Rgb, vec![0; 192]);
        assert_eq!(run_loop(f, &opts, &mut Closed, &stop, None), Ok(0));
    }
}
