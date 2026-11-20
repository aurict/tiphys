# tiphys-desktop

A small native helper (Rust) that the Tiphys agent starts only while a desktop feature is in use. It does the
platform-specific work on desktops other than Hyprland, which the agent handles itself: Sway, X11, GNOME/KDE on
Wayland (through xdg-desktop-portal), Windows and macOS. The wire format is in [PROTOCOL.md](PROTOCOL.md).

- One binary, about 3.4 MB (release build, Linux x64). Idle RSS is about 4 MB on every backend measured.
- Plain threads, no async runtime. zbus (portal backend only) brings its own small executor, and only when that
  backend is chosen.
- Unsafe code only in the Windows and macOS backends (FFI). The crate denies it everywhere else.

## Build

```sh
cargo build --release          # target/release/tiphys-desktop
cargo build --release --no-default-features   # without the portal backend (no zbus)
cargo test                     # unit tests + serve over stdio; the x11 test starts its own private Xvfb
```

CI (`.github/workflows/desktop-helper.yml`) runs fmt, clippy `-D warnings` and the tests on Linux, Windows and macOS.
It also builds release binaries for linux-x64, linux-arm64, windows-x64, macos-arm64 and macos-x64.

## Run

```sh
tiphys-desktop serve                         # JSON lines on stdin/stdout; exits when stdin closes
tiphys-desktop stream --monitor DP-1 --fps 15 --max-width 1280 --quality 8 > frames.mjpeg
tiphys-desktop --version
```

The backend is detected in this order: Windows, macOS, `$SWAYSOCK` → sway, `$WAYLAND_DISPLAY` on GNOME/KDE → portal,
any other Wayland session → none (XWayland would only see X clients), `$DISPLAY` → x11, else none.
`TIPHYS_DESKTOP_BACKEND=sway|x11|portal|none` overrides the detection. stderr carries diagnostics only. Typed text,
clipboard contents and window titles never go there, and text reaches helper tools through stdin, never argv.

## What each backend does

`hello.capabilities` always lists exactly what works on the running system. The agent hides everything else.

| | x11 | sway | portal (GNOME/KDE) | windows | macos |
|---|---|---|---|---|---|
| windows, focused, focus events | EWMH (root children without a WM) | IPC tree, focus order | — (no unprivileged API) | EnumWindows (Alt+Tab-like filter) | CGWindowList, on-screen only |
| window actions | focus, close, minimize, maximize, fullscreen via EWMH; float → unsupported | focus, close (kill), minimize (scratchpad), fullscreen, float; maximize → unsupported | — | focus, close, minimize, maximize; fullscreen/float → unsupported | AX: raise+frontmost, close/zoom buttons, minimize, fullscreen; float → unsupported |
| workspaces | `_NET_*_DESKTOP*` (only if the WM has them) | IPC | — | — | — (Spaces have no API) |
| monitors | RandR 1.5 monitors (scale 1) | outputs | Mutter DisplayConfig / `kscreen-doctor -j` / one "desktop" | EnumDisplayMonitors, DPI scale | CGDisplay, points + scale |
| screenshot, stream | GetImage (24/32-bit TrueColor) | `grim` (if installed) | Screenshot portal (a few fps at best) | GDI BitBlt | CGWindowListCreateImage |
| input (pointer/buttons/scroll/keys) | XTest | pointer via `seat - cursor` IPC; keys need `wtype` | RemoteDesktop portal | SendInput | CGEvent |
| text | XTest, unknown chars via a borrowed keycode | `wtype` | RemoteDesktop keysyms | KEYEVENTF_UNICODE | CGEvent Unicode strings |
| apps, launch | `.desktop` files | `.desktop` files | `.desktop` files | Start menu `.lnk` | `/Applications` etc. `.app` |
| dpms | DPMS extension (if present) | `output * power` | Mutter PowerSaveMode / `kscreen-doctor --dpms` | SC_MONITORPOWER / mouse nudge | `pmset displaysleepnow` / `caffeinate -u` |
| clipboard | arboard (served while the helper runs) | `wl-copy`/`wl-paste` | `wl-copy`/`wl-paste` | arboard | arboard |
| audio | `wpctl` (if installed) | `wpctl` | `wpctl` | WASAPI; set-output via IPolicyConfig | `osascript`; outputs via `system_profiler`; set-output needs `SwitchAudioSource` |

## Permissions per OS

- **X11**: none. Note that any X client can do all of this.
- **Sway**: none for IPC. `wtype` uses the virtual-keyboard protocol, which sway allows by default.
- **GNOME/KDE (portal)**: the first input request opens the RemoteDesktop dialog, which needs the user's consent at
  the screen. With RemoteDesktop v2 the grant is remembered (restore token in
  `$XDG_STATE_HOME/tiphys/portal-restore-token`). Screenshots go through the Screenshot portal non-interactively.
  Depending on the desktop's permission store, a one-time prompt may appear.
- **Windows**: none. Windows of elevated (administrator) processes can't receive input from a non-elevated helper
  (UIPI). This is answered with `permission`. Capture fails on the secure desktop (UAC prompt, lock screen).
- **macOS**: input and window actions need **Accessibility**, capture and other apps' window titles need **Screen
  Recording** (System Settings → Privacy & Security). The permission goes to the app that starts the helper, or to
  the helper binary itself. Without it the answer is `permission` with the setting's name, and macOS is asked to
  show its prompt once. On macOS 15+ the system may periodically confirm that screen access should continue.

## Layout

- `src/main.rs` is the CLI. `src/serve.rs` holds the request loop (ordered input worker, concurrent other ops, focus
  poller). `src/stream.rs` holds the MJPEG loop.
- `src/protocol.rs` holds the wire types, validation and limits, and the rate limiter. `src/keys.rs` maps key names
  to X11 keysyms, Windows VKs and macOS keycodes.
- `src/frame.rs` handles scaling, JPEG/PNG encoding and base64. `src/apps.rs` holds the app lists. `src/util.rs`
  runs subprocesses with timeouts.
- `src/backend/{x11,sway,portal,windows,macos,none}.rs` are the backends. `linux.rs` holds wpctl/wl-clipboard
  helpers shared on Linux. `macos_parse.rs` holds macOS command-output parsers, tested on every host.
