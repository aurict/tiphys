//! Drives a `tiphys-desktop serve` process over stdio.

#![allow(dead_code)]

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, channel};
use std::time::{Duration, Instant};

pub const BIN: &str = env!("CARGO_BIN_EXE_tiphys-desktop");

pub struct Helper {
    pub child: Child,
    stdin: Option<ChildStdin>,
    lines: Receiver<String>,
    next_id: u64,
    /// Lines that arrived while waiting for something else (events, other answers).
    pub pending: Vec<Value>,
    pub hello: Value,
}

impl Helper {
    pub fn start(env: &[(&str, &str)]) -> Helper {
        let mut cmd = Command::new(BIN);
        cmd.arg("serve").stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit());
        for (k, v) in env {
            cmd.env(k, v);
        }
        let mut child = cmd.spawn().expect("start helper");
        let stdout = child.stdout.take().unwrap();
        let (tx, lines) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let stdin = child.stdin.take();
        let mut h = Helper { child, stdin, lines, next_id: 1, pending: Vec::new(), hello: Value::Null };
        let hello = h.next_line(Duration::from_secs(10)).expect("hello line");
        h.hello = hello["hello"].clone();
        assert!(h.hello.is_object(), "first line is hello: {hello}");
        h
    }

    pub fn capabilities(&self) -> Vec<String> {
        self.hello["capabilities"].as_array().unwrap().iter().map(|c| c.as_str().unwrap().to_string()).collect()
    }

    pub fn has(&self, cap: &str) -> bool {
        self.capabilities().iter().any(|c| c == cap)
    }

    pub fn next_line(&mut self, timeout: Duration) -> Option<Value> {
        let line = self.lines.recv_timeout(timeout).ok()?;
        Some(serde_json::from_str(&line).unwrap_or_else(|e| panic!("bad JSON line {line:?}: {e}")))
    }

    pub fn send_raw(&mut self, line: &str) {
        let s = self.stdin.as_mut().expect("stdin open");
        s.write_all(line.as_bytes()).unwrap();
        s.write_all(b"\n").unwrap();
        s.flush().unwrap();
    }

    /// Sends a request (the id is added) and returns its id.
    pub fn send(&mut self, mut req: Value) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        req["id"] = json!(id);
        self.send_raw(&req.to_string());
        id
    }

    pub fn wait(&mut self, id: u64) -> Value {
        if let Some(i) = self.pending.iter().position(|v| v["id"] == json!(id)) {
            return self.pending.remove(i);
        }
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let left = deadline.saturating_duration_since(Instant::now());
            let v = self.next_line(left).unwrap_or_else(|| panic!("no answer to request {id}"));
            if v["id"] == json!(id) {
                return v;
            }
            self.pending.push(v);
        }
    }

    pub fn call(&mut self, req: Value) -> Value {
        let id = self.send(req);
        self.wait(id)
    }

    /// The result of a request that must succeed.
    pub fn ok(&mut self, req: Value) -> Value {
        let a = self.call(req.clone());
        assert_eq!(a["ok"], json!(true), "{req} → {a}");
        a["result"].clone()
    }

    /// The error code of a request that must fail.
    pub fn err(&mut self, req: Value) -> String {
        let a = self.call(req.clone());
        assert_eq!(a["ok"], json!(false), "{req} → {a}");
        a["error"]["code"].as_str().unwrap().to_string()
    }

    /// Waits for an event line (no id).
    pub fn event(&mut self, timeout: Duration) -> Option<Value> {
        if let Some(i) = self.pending.iter().position(|v| v.get("event").is_some()) {
            return Some(self.pending.remove(i));
        }
        let deadline = Instant::now() + timeout;
        loop {
            let v = self.next_line(deadline.saturating_duration_since(Instant::now()))?;
            if v.get("event").is_some() {
                return Some(v);
            }
            self.pending.push(v);
        }
    }

    /// Resident memory of the helper in KiB (Linux).
    pub fn rss_kib(&self) -> Option<u64> {
        let s = std::fs::read_to_string(format!("/proc/{}/status", self.child.id())).ok()?;
        s.lines().find_map(|l| l.strip_prefix("VmRSS:")).and_then(|v| v.trim().trim_end_matches(" kB").trim().parse().ok())
    }

    /// Closes stdin and waits for the exit status.
    pub fn close(mut self) -> std::process::ExitStatus {
        drop(self.stdin.take());
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(s) = self.child.try_wait().unwrap() {
                return s;
            }
            assert!(Instant::now() < deadline, "helper did not exit after stdin closed");
            std::thread::sleep(Duration::from_millis(20));
        }
    }
}

impl Drop for Helper {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// Splits concatenated JPEGs at SOI/EOI (the agent's splitter also walks segments; plain search suffices for
/// baseline JPEGs whose entropy data byte-stuffs 0xFF).
pub fn split_jpegs(mut b: &[u8]) -> Vec<Vec<u8>> {
    let mut out = Vec::new();
    while b.len() >= 4 {
        assert_eq!(&b[..2], &[0xff, 0xd8], "frame starts with SOI");
        let Some(end) = b.windows(2).position(|w| w == [0xff, 0xd9]) else { break };
        out.push(b[..end + 2].to_vec());
        b = &b[end + 2..];
    }
    out
}
