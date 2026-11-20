//! Small process helpers: find a binary on PATH, run one with a timeout, start an app detached.

#![allow(dead_code)] // each backend uses a different subset

use crate::protocol::{Error, Res};
use std::ffi::OsStr;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// Commands that don't answer in this time are killed.
pub const RUN_TIMEOUT: Duration = Duration::from_secs(10);
/// Output beyond this is cut (a screenshot is the largest legitimate output).
const MAX_OUTPUT: u64 = 256 * 1024 * 1024;

pub fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).find_map(|dir| {
        let p = dir.join(name);
        if p.is_file() {
            return Some(p);
        }
        #[cfg(windows)]
        {
            let exe = dir.join(format!("{name}.exe"));
            if exe.is_file() {
                return Some(exe);
            }
        }
        None
    })
}

pub struct Output {
    pub status: Option<i32>,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

impl Output {
    pub fn success(&self) -> bool {
        self.status == Some(0)
    }
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.stdout).into_owned()
    }
    /// First stderr line, for error messages (never contains what was typed: input goes via stdin or argv only).
    pub fn reason(&self) -> String {
        let s = String::from_utf8_lossy(&self.stderr);
        let line = s.lines().find(|l| !l.trim().is_empty()).unwrap_or("").trim();
        line.chars().take(200).collect()
    }
}

/// Runs a command, feeding `input` to stdin; kills it after `timeout`.
pub fn run<S: AsRef<OsStr>>(cmd: &str, args: &[S], input: Option<&[u8]>, timeout: Duration) -> Res<Output> {
    let mut child = Command::new(cmd)
        .args(args)
        .stdin(if input.is_some() { Stdio::piped() } else { Stdio::null() })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| Error::failed(format!("{cmd}: {e}")))?;
    if let (Some(data), Some(mut stdin)) = (input, child.stdin.take()) {
        let data = data.to_vec();
        thread::spawn(move || {
            let _ = stdin.write_all(&data);
        });
    }
    let read = |r: Option<Box<dyn Read + Send>>| {
        thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(r) = r {
                let _ = r.take(MAX_OUTPUT).read_to_end(&mut buf);
            }
            buf
        })
    };
    let out = read(child.stdout.take().map(|s| Box::new(s) as Box<dyn Read + Send>));
    let err = read(child.stderr.take().map(|s| Box::new(s) as Box<dyn Read + Send>));
    let deadline = Instant::now() + timeout;
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if Instant::now() < deadline => thread::sleep(Duration::from_millis(5)),
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(Error::failed(format!("{cmd} timed out")));
            }
            Err(e) => return Err(Error::failed(format!("{cmd}: {e}"))),
        }
    };
    Ok(Output { status: status.code(), stdout: out.join().unwrap_or_default(), stderr: err.join().unwrap_or_default() })
}

/// Runs a command and fails with its stderr reason unless it exits 0.
pub fn run_ok<S: AsRef<OsStr>>(cmd: &str, args: &[S], input: Option<&[u8]>) -> Res<Output> {
    let out = run(cmd, args, input, RUN_TIMEOUT)?;
    if out.success() { Ok(out) } else { Err(Error::failed(format!("{cmd} failed: {}", out.reason()))) }
}

/// Starts a program that outlives the helper (own process group, no inherited stdio).
pub fn spawn_detached<S: AsRef<OsStr>>(cmd: &OsStr, args: &[S]) -> Res<()> {
    let mut c = Command::new(cmd);
    c.args(args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        c.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const DETACHED_PROCESS: u32 = 0x0000_0008;
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        c.creation_flags(DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP);
    }
    let mut child = c.spawn().map_err(|e| Error::failed(format!("could not start: {e}")))?;
    // Reap it in the background so it doesn't linger as a zombie while we run.
    thread::spawn(move || {
        let _ = child.wait();
    });
    Ok(())
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn runs_and_times_out() {
        let out = run("sh", &["-c", "cat; echo err >&2; exit 3"], Some(b"hi"), RUN_TIMEOUT).unwrap();
        assert_eq!((out.status, out.text().as_str(), out.reason().as_str()), (Some(3), "hi", "err"));
        let t = Instant::now();
        assert!(run("sleep", &["5"], None, Duration::from_millis(100)).is_err());
        assert!(t.elapsed() < Duration::from_secs(2));
        assert!(run_ok("false", &[] as &[&str], None).is_err());
        assert!(which("sh").is_some());
        assert!(which("surely-not-a-binary-xyz").is_none());
    }
}
