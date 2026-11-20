//! `serve` mode: one request per stdin line, answers (possibly out of order) and events on stdout.
//!
//! - Input ops (pointer, click, button, scroll, key, text) share a 60/s budget and run in order on one thread, so a
//!   drag (button down, moves, up) keeps its sequence. A full queue answers `busy`.
//! - Everything else runs on short-lived threads, at most [`MAX_INFLIGHT`] at once (more → `busy`), so a slow
//!   screenshot or a portal permission dialog doesn't hold up input.
//! - stdin closing ends the process (the agent stopped or crashed).

use crate::backend::{self, Backend};
use crate::frame;
use crate::protocol::{self, Error, ImageFormat, RateLimiter, Request, Res, Window};
use serde_json::{Value, json};
use std::io::{self, BufRead, Write};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{SyncSender, TrySendError, sync_channel};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

const MAX_INFLIGHT: usize = 8;
const INPUT_QUEUE: usize = 120;
const FOCUS_POLL: Duration = Duration::from_millis(250);

/// stdout shared by all threads; a failed write means the agent is gone.
struct Out(Mutex<io::Stdout>);

impl Out {
    fn line(&self, s: &str) {
        let mut o = self.0.lock().unwrap_or_else(|e| e.into_inner());
        if writeln!(o, "{s}").and_then(|_| o.flush()).is_err() {
            std::process::exit(0);
        }
    }
    fn answer(&self, id: &Value, r: Res<Value>) {
        match r {
            Ok(v) => self.line(&protocol::ok_line(id, v)),
            Err(e) => self.line(&protocol::err_line(id, &e)),
        }
    }
}

struct Job {
    id: Value,
    request: Request,
}

pub fn run(backend: Box<dyn Backend>) -> ! {
    let backend: Arc<dyn Backend> = backend.into();
    let caps = backend.capabilities();
    let out = Arc::new(Out(Mutex::new(io::stdout())));
    out.line(&protocol::hello_line(backend.name(), &caps));
    eprintln!("tiphys-desktop: backend {} ({})", backend.name(), caps.join(","));

    let input = input_worker(backend.clone(), out.clone());
    let inflight = Arc::new(AtomicUsize::new(0));
    let subscribed = Arc::new(AtomicBool::new(false));
    let mut limiter = RateLimiter::new(protocol::MAX_INPUT_PER_SEC, Instant::now());
    let mut stdin = io::stdin().lock();
    let mut buf = Vec::with_capacity(1024);

    loop {
        let line = match read_line(&mut stdin, &mut buf) {
            Ok(Line::Eof) | Err(_) => break,
            Ok(Line::TooLong) => {
                out.answer(&Value::Null, Err(Error::bad("request line too long")));
                continue;
            }
            Ok(Line::Ok) => match std::str::from_utf8(&buf) {
                Ok(s) => s.trim(),
                Err(_) => {
                    out.answer(&Value::Null, Err(Error::bad("request is not UTF-8")));
                    continue;
                }
            },
        };
        if line.is_empty() {
            continue;
        }
        let parsed = protocol::parse_line(line);
        let id = parsed.id;
        let request = match parsed.request {
            Ok(r) => r,
            Err(e) => {
                out.answer(&id, Err(e));
                continue;
            }
        };
        if let Some(cap) = backend::required_capability(&request)
            && !caps.contains(&cap)
        {
            out.answer(&id, Err(Error::unsupported(format!("{cap} is not available on this desktop"))));
            continue;
        }
        match request {
            Request::Ping => out.answer(&id, Ok(json!({}))),
            Request::SubscribeFocus => {
                if !subscribed.swap(true, Ordering::SeqCst) {
                    focus_poller(backend.clone(), out.clone());
                }
                out.answer(&id, Ok(json!({})));
            }
            r if r.is_input() => {
                if !limiter.allow(Instant::now()) {
                    out.answer(&id, Err(Error::busy("more than 60 input requests per second")));
                    continue;
                }
                match input.try_send(Job { id, request: r }) {
                    Ok(()) => {}
                    Err(TrySendError::Full(j)) => out.answer(&j.id, Err(Error::busy("input queue is full"))),
                    Err(TrySendError::Disconnected(j)) => out.answer(&j.id, Err(Error::failed("input worker stopped"))),
                }
            }
            r => {
                if inflight.fetch_add(1, Ordering::SeqCst) >= MAX_INFLIGHT {
                    inflight.fetch_sub(1, Ordering::SeqCst);
                    out.answer(&id, Err(Error::busy("too many requests at once")));
                    continue;
                }
                let (b, o, n) = (backend.clone(), out.clone(), inflight.clone());
                thread::spawn(move || {
                    o.answer(&id, execute_guarded(&*b, r));
                    n.fetch_sub(1, Ordering::SeqCst);
                });
            }
        }
    }
    std::process::exit(0)
}

fn input_worker(backend: Arc<dyn Backend>, out: Arc<Out>) -> SyncSender<Job> {
    let (tx, rx) = sync_channel::<Job>(INPUT_QUEUE);
    thread::spawn(move || {
        for job in rx {
            out.answer(&job.id, execute_guarded(&*backend, job.request));
        }
    });
    tx
}

fn focus_poller(backend: Arc<dyn Backend>, out: Arc<Out>) {
    thread::spawn(move || {
        let key = |w: &Option<Window>| w.as_ref().map(|w| w.id.clone());
        let mut last = backend.focused().ok().and_then(|w| w);
        loop {
            thread::sleep(FOCUS_POLL);
            let Ok(now) = backend.focused() else { continue };
            if key(&now) != key(&last) {
                out.line(&protocol::focus_event_line(now.as_ref()));
                last = now;
            }
        }
    });
}

enum Line {
    Ok,
    TooLong,
    Eof,
}

/// Reads one line into `buf` (without the newline); longer than MAX_LINE → the rest is skipped.
fn read_line(r: &mut impl BufRead, buf: &mut Vec<u8>) -> io::Result<Line> {
    buf.clear();
    let mut too_long = false;
    loop {
        let chunk = r.fill_buf()?;
        if chunk.is_empty() {
            return Ok(if too_long {
                Line::TooLong
            } else if buf.is_empty() {
                Line::Eof
            } else {
                Line::Ok
            });
        }
        let (part, done) = match chunk.iter().position(|&b| b == b'\n') {
            Some(i) => (&chunk[..i], Some(i + 1)),
            None => (chunk, None),
        };
        if !too_long {
            if buf.len() + part.len() > protocol::MAX_LINE {
                too_long = true;
                buf.clear();
            } else {
                buf.extend_from_slice(part);
            }
        }
        let used = done.unwrap_or(chunk.len());
        r.consume(used);
        if done.is_some() {
            return Ok(if too_long { Line::TooLong } else { Line::Ok });
        }
    }
}

fn execute_guarded(b: &dyn Backend, r: Request) -> Res<Value> {
    catch_unwind(AssertUnwindSafe(|| execute(b, r))).unwrap_or_else(|_| Err(Error::failed("internal error")))
}

fn to_json<T: serde::Serialize>(v: T) -> Res<Value> {
    serde_json::to_value(v).map_err(|e| Error::failed(e.to_string()))
}

fn execute(b: &dyn Backend, r: Request) -> Res<Value> {
    let done = || Ok(json!({}));
    match r {
        Request::Windows => to_json(b.windows()?),
        Request::Focused => to_json(b.focused()?),
        Request::Window { id, action } => b.window_action(id, action).and_then(|_| done()),
        Request::Workspaces => to_json(b.workspaces()?),
        Request::Workspace { id } => b.switch_workspace(&id).and_then(|_| done()),
        Request::MoveToWorkspace { window, workspace } => b.move_to_workspace(window, &workspace).and_then(|_| done()),
        Request::Monitors => to_json(b.monitors()?),
        Request::Screenshot { target, max_width, format, quality } => {
            let rect = backend::target_rect(b, &target)?;
            let f = b.capture(rect)?;
            let rgb = frame::to_rgb(&f, max_width);
            drop(f);
            let (name, bytes) = match format {
                ImageFormat::Png => ("png", frame::encode_png(&rgb)?),
                ImageFormat::Jpeg => ("jpeg", frame::encode_jpeg(&rgb, quality)?),
            };
            Ok(json!({"format": name, "width": rgb.width, "height": rgb.height, "data": frame::base64(&bytes)}))
        }
        Request::Pointer { x, y } => b.pointer(x, y).and_then(|_| done()),
        Request::Click { button, at, double } => b.click(button, at, double).and_then(|_| done()),
        Request::Button { button, down } => b.button(button, down).and_then(|_| done()),
        Request::Scroll { dx, dy } => {
            if dx == 0 && dy == 0 {
                return done();
            }
            b.scroll(dx, dy).and_then(|_| done())
        }
        Request::Key { keys } => b.key(&keys).and_then(|_| done()),
        Request::Text { text } => {
            if text.is_empty() {
                return done();
            }
            b.text(&text).and_then(|_| done())
        }
        Request::Apps { lang } => to_json(b.apps(lang.as_deref())?),
        Request::Launch { id } => b.launch(&id).and_then(|_| done()),
        Request::Dpms { on } => b.dpms(on).and_then(|_| done()),
        Request::ClipboardGet => Ok(json!({"text": b.clipboard_get()?})),
        Request::ClipboardSet { text } => b.clipboard_set(&text).and_then(|_| done()),
        Request::Volume => to_json(b.volume()?),
        Request::SetVolume { percent, muted } => to_json(b.set_volume(percent, muted)?),
        Request::Outputs => to_json(b.outputs()?),
        Request::SetOutput { id } => to_json(b.set_output(&id)?),
        Request::Ping => done(),
        Request::SubscribeFocus => done(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lines() {
        let long = "x".repeat(protocol::MAX_LINE + 10);
        let input = format!("a\n\n{long}\nb\r\nlast");
        let mut r = io::BufReader::with_capacity(16, input.as_bytes());
        let mut buf = Vec::new();
        let mut got = Vec::new();
        loop {
            match read_line(&mut r, &mut buf).unwrap() {
                Line::Eof => break,
                Line::TooLong => got.push("<long>".to_string()),
                Line::Ok => got.push(String::from_utf8(buf.clone()).unwrap()),
            }
        }
        assert_eq!(got, vec!["a", "", "<long>", "b\r", "last"]);
    }
}
