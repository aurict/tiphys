//! tiphys-desktop — native desktop helper for the Tiphys agent (see PROTOCOL.md).
//!
//! - `serve`: JSON lines on stdin/stdout until stdin closes.
//! - `stream --monitor <id> [--region x,y,w,h] [--fps N] [--max-width N] [--quality 2-31]`: MJPEG on stdout.
//!
//! Unsafe code lives only in the Windows/macOS backends (FFI), each block with a SAFETY note.

#![deny(unsafe_code)]

mod apps;
mod backend;
mod frame;
mod keys;
mod protocol;
mod serve;
mod stream;
mod util;

const USAGE: &str = "usage: tiphys-desktop serve
       tiphys-desktop stream [--monitor <id>] [--region x,y,w,h] [--fps 1-60] [--max-width 64-3840] [--quality 2-31]
       tiphys-desktop --version
env:   TIPHYS_DESKTOP_BACKEND=sway|x11|portal|none overrides detection";

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("serve") if args.len() == 1 => serve::run(backend::detect()),
        Some("stream") => std::process::exit(stream::main(&args[1..])),
        Some("--version" | "-V") if args.len() == 1 => {
            println!("tiphys-desktop {} (protocol {})", env!("CARGO_PKG_VERSION"), protocol::PROTOCOL);
        }
        Some("--help" | "-h") => println!("{USAGE}"),
        _ => {
            eprintln!("{USAGE}");
            std::process::exit(2);
        }
    }
}
