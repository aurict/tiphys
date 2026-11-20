# tiphys-desktop protocol (version 1)

`tiphys-desktop` is a small native helper (Rust) that the Tiphys agent starts **only while a desktop feature is in
use** and stops when idle. It does the platform-specific work on desktops other than Hyprland (which the agent
handles itself): Sway, X11, GNOME/KDE (Wayland through xdg-desktop-portal), Windows and macOS.

The agent talks to it in two ways:

1. `tiphys-desktop serve` — requests and answers as JSON lines on stdin/stdout.
2. `tiphys-desktop stream …` — writes a continuous MJPEG stream (concatenated JPEG images, nothing else) to stdout,
   exactly like `wf-recorder -c mjpeg -m mjpeg -f pipe:1`, so the agent's existing frame splitter is reused.

stderr is free-form diagnostics (the agent logs it, never shows it). Nothing typed, no clipboard text and no window
titles are ever written to stderr.

## Common rules

- Coordinates are **global logical pixels** (the desktop's coordinate space; on HiDPI the same units the window
  manager uses). `monitors` gives each monitor's rectangle and scale.
- Window ids are strings `0x<lowercase hex>` (≤ 16 hex digits), whatever the platform uses underneath (Sway con_id,
  X11 window id, Windows HWND, macOS window number). The agent validates them with `^0x[0-9a-f]{1,16}$`.
- Limits the helper enforces too: text ≤ 4000 characters, at most 60 input requests per second (excess → `busy`),
  screenshot `maxWidth` 64–3840, stream fps 1–60, quality 2–31.

## serve mode

On start the helper prints one line:

```json
{"hello":{"protocol":1,"version":"0.1.0","backend":"sway","capabilities":["windows","windowActions","workspaces","monitors","screenshot","stream","input","text","apps","launch","dpms","clipboard","audio"]}}
```

`backend` is one of `sway`, `x11`, `portal` (GNOME/KDE Wayland), `windows`, `macos`, `none`. `capabilities` lists only
what really works here (e.g. `portal` may lack `windows`; macOS lacks `dpms` unless permitted). The agent hides
everything else. When nothing works (`backend: "none"`), every request fails with `unsupported`.

Requests: `{"id": <number>, "op": "<name>", ...fields}` — one per line. Answers, possibly out of order:
`{"id": n, "ok": true, "result": …}` or `{"id": n, "ok": false, "error": {"code": "…", "message": "…"}}`.
Error codes: `badRequest`, `unsupported`, `notFound`, `permission` (OS permission missing, e.g. macOS Accessibility /
Screen Recording; `message` says which), `busy`, `failed`.

| op | fields | result |
|---|---|---|
| `windows` | | `[{id, title, appId, pid, workspace, monitor, x, y, w, h, focused, minimized, fullscreen, floating}]` (most recently focused first; `workspace` a string or null) |
| `window` | `id`, `action`: `focus` \| `close` \| `minimize` \| `maximize` \| `fullscreen` \| `float` | `{}` |
| `workspaces` | | `[{id, name, focused, monitor}]` |
| `workspace` | `id` (string) | `{}` — switch to it |
| `move-to-workspace` | `window`, `workspace` | `{}` |
| `monitors` | | `[{id, name, x, y, w, h, scale, primary}]` |
| `screenshot` | `monitor?`, `window?`, `region?` `{x,y,w,h}`, `maxWidth?`, `format`: `png` \| `jpeg`, `quality?` (1–100, jpeg) | `{format, width, height, data}` (base64) |
| `pointer` | `x`, `y` | `{}` — move |
| `click` | `button`: `left` \| `right` \| `middle`, `x?`, `y?`, `double?` | `{}` |
| `button` | `button`, `down` (bool) | `{}` — press/release (drag) |
| `scroll` | `dx`, `dy` (notches, ±20) | `{}` |
| `key` | `keys`: e.g. `["ctrl","shift","t"]` (modifiers first; names below) | `{}` |
| `text` | `text` | `{}` — types Unicode text (any keyboard layout) |
| `apps` | `lang?` | `[{id, name, icon?}]` launchable apps (Windows Start menu, macOS /Applications, Linux .desktop) |
| `launch` | `id` (from `apps`) | `{}` |
| `dpms` | `on` (bool) | `{}` — screen(s) on/off |
| `clipboard-get` | | `{text}` (text only; `null` if not text) |
| `clipboard-set` | `text` | `{}` |
| `volume` | | `{percent, muted}` |
| `set-volume` | `percent?` (0–150), `muted?` | `{percent, muted}` |
| `outputs` | | `[{id, name, default}]` audio outputs |
| `set-output` | `id` | same list |
| `focused` | | the focused window (same shape as in `windows`) or `null` |
| `ping` | | `{}` |

Key names: `ctrl`, `shift`, `alt`, `super`, `enter`, `escape`, `tab`, `backspace`, `delete`, `insert`, `home`, `end`,
`pageup`, `pagedown`, `up`, `down`, `left`, `right`, `space`, `f1`…`f12`, `printscreen`, `volumeup`, `volumedown`,
`mute`, `playpause`, `next`, `previous`, and single letters/digits `a`…`z`, `0`…`9` (only together with a modifier;
plain text goes through `text`).

Events (no `id`), only after `{"id":n,"op":"subscribe","events":["focus"]}`:
`{"event":"focus","window":{…}}` when the focused window changes.

The helper exits when stdin closes (the agent stopped or crashed).

## stream mode

```
tiphys-desktop stream --monitor <id> [--region x,y,w,h] --fps 15 --max-width 1280 --quality 8
```

Writes JPEG frames back to back to stdout until stdin closes or it is killed. Frames whose content didn't change may
be skipped. `quality` uses the MJPEG scale of the existing stream (2 best … 31 worst). Exit code 3 = permission
missing (message on stderr), 4 = monitor not found, 5 = unsupported here.

## Platform notes

| Backend | windows / actions | input | capture | other |
|---|---|---|---|---|
| sway | IPC (`$SWAYSOCK`) | wlr virtual pointer/keyboard protocols, or `ydotool` if present | wlr-screencopy | |
| x11 | EWMH (`_NET_CLIENT_LIST`, `_NET_ACTIVE_WINDOW`) | XTest | `GetImage` / XShm | DPMS extension |
| portal | GNOME Shell / KWin D-Bus where available, else not offered | RemoteDesktop portal (asks the user once) | ScreenCast portal (PipeWire) | |
| windows | `EnumWindows`, `SetForegroundWindow`, `ShowWindow` | `SendInput` (Unicode for text) | Windows Graphics Capture, GDI fallback | `SendMessage(SC_MONITORPOWER)`, WASAPI/IMMDevice for audio |
| macos | `CGWindowListCopyWindowInfo` + AX API | `CGEvent` (Accessibility permission) | ScreenCaptureKit / `CGWindowListCreateImage` (Screen Recording permission) | CoreAudio |

## Clarifications (implementation of version 1)

These pin down details the tables above leave open. They change no shape except the first point, which the table
above can't be implemented as written.

- **Target ids aren't called `id`.** A request's own `id` is its number, and a second `id` key in the same JSON
  object would overwrite it (an object can't hold two). The ops listed with an `id` field take it under the name of
  what it identifies, as `move-to-workspace` already does:
  `{"id":7,"op":"window","window":"0x1a2b","action":"focus"}`, `{"id":8,"op":"workspace","workspace":"2"}`,
  `{"id":9,"op":"launch","app":"firefox.desktop"}`, `{"id":10,"op":"set-output","output":"57"}`.
  A request with a second `id` is answered with `id: null`, `badRequest`.
- A line that isn't JSON, has no numeric `id`, or is longer than 64 KiB is answered with `"id": null` and
  `badRequest`. Unknown extra fields are ignored.
- `ping` always answers `{}`, even with backend `none`. Every other op that isn't in `capabilities` answers
  `unsupported` without being tried. Validation comes first, so a malformed request is `badRequest` even then.
- Ids of monitors, workspaces and outputs are strings. Monitor ids are output names where the platform has them
  (`DP-1`, X11 RandR names, Windows `DISPLAY1`); on macOS they're the CGDirectDisplayID in decimal. The same id goes
  to `screenshot.monitor` and `stream --monitor`.
- `screenshot` with no target captures the primary monitor (the focused output on sway). `region` and
  `stream --region` are global logical coordinates; given both `--monitor` and `--region`, the region is clipped to
  that monitor. `width`/`height` in the answer are the encoded image's size: on HiDPI the capture has physical pixels
  before `maxWidth` scales it down (never up). `quality` defaults to 80.
- `scroll` takes integers: `dy > 0` scrolls down and `dx > 0` right (as in the agent's ydotool path). `0,0` is a
  no-op.
- `key`: zero or more modifiers followed by at most one other key. A combo of only modifiers (`["super"]`) is
  allowed. Letters and digits need at least one modifier. Duplicates, more than 8 names or unknown names →
  `badRequest`. A key the platform can't produce (e.g. media keys on macOS) → `unsupported`.
- `text`: `\n` and `\t` are typed as Enter and Tab, and `\r` is dropped. `clipboard-set` has the same
  4000-character limit.
- Input requests (`pointer`, `click`, `button`, `scroll`, `key`, `text`) run strictly in the order they arrive.
  Other requests run concurrently (at most 8 at a time, more → `busy`), which is why answers may arrive out of order.
  The 60/s input budget is a token bucket (bursts up to 60).
- `windows` lists the `focused` window first. `workspace` is null where the platform has no workspaces or the window
  is on all of them; `pid` may be null.
- `set-volume` above 100 is clamped where the platform has no boost (Windows, macOS).
- `subscribe` needs the `windows` capability. Focus is polled every 250 ms, and an event is sent when the focused
  window's id changes (`window` is null when nothing is focused).
- Stream mode: `--monitor` may be omitted (primary monitor). Defaults are `--fps 15 --quality 8` with no
  `--max-width`. Exit codes: 0 when stdin closed or the reader went away, 1 when capture kept failing, 2 for bad
  arguments, and 3/4/5 as above.
- Only the portal backend keeps state: the RemoteDesktop restore token in
  `$XDG_STATE_HOME/tiphys/portal-restore-token` (mode 0600), so the permission dialog appears once.

In some places the mechanism actually used differs from the platform table above: on sway the pointer goes through
`seat - cursor` IPC commands, keys through `wtype` and capture through `grim`; the portal backend captures through
the Screenshot portal; Windows uses GDI; macOS uses `CGWindowListCreateImage`. See README.md.
