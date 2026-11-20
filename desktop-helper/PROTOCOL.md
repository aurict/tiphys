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
