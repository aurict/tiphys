# App remotes and mobile view

When you use the [live screen](desktop-control.md#live-screen), Tiphys knows which window is focused on the PC and
adapts to it in two ways:

- the **remote strip** offers ready-made controls for that app (plus your own buttons),
- the **mobile view** draws the app's real controls (buttons, fields, menus, tabs) as native phone widgets, read
  from the Linux accessibility tree (AT-SPI).

## Requirements

- Agent features `desktop` and `control`, Hyprland, and an open control session. The phone opens the session
  automatically and asks for the app lock. See [Desktop control](desktop-control.md#requirements).
- Remote strip: the same input tools the live screen uses (`ydotool` + `ydotoold`, `wtype`).
- Mobile view: `python3` with the `python3-gi` and `gir1.2-atspi-2.0` packages, the AT-SPI bus (`at-spi2-core`),
  and `busctl`.

## App-aware remote strip

The agent sends a `focus` message each time the focused window changes. The phone matches the window's Hyprland
`class` (then `initialClass`), case-insensitively. Reverse-domain classes also match on their last part, so
`com.visualstudio.code` matches `code`. The strip shows, in order:

1. **Mobile view**, the first button for any window,
2. your own buttons for that app,
3. the built-in profile.

Scroll the strip sideways, or tap **…** (*All controls*) for the full sheet. You can hide it (*Hide app controls*);
that choice is saved on the phone.

### Built-in profiles

| Profile | Window classes | Controls |
|---|---|---|
| Firefox | `firefox`, `firefox-esr`, `org.mozilla.firefox`, `firefox-developer-edition`, `librewolf` | Address / search (Ctrl+L, then text), Tabs\*, Open on phone\*, Back, Forward, Reload (F5), New tab, Close tab (confirm), Reopen closed tab, Next/Previous tab, Find, Zoom in/out (Ctrl+Num +/−), Actual size, Full screen (F11), Reader view (Ctrl+Alt+R), Scroll down/up, To top |
| VS Code | `code`, `code-oss`, `code-url-handler`, `codium`, `vscodium`, `com.visualstudio.code` | Command palette (text), Go to file (text), Save, Terminal†, Find, Replace, Go to line, Undo, Redo, Toggle comment†, Sidebar (Ctrl+B) |
| Zed | `dev.zed.zed`, `zed`, `dev.zed.zed-preview` | same as VS Code, using Zed's palette commands |
| kitty | `kitty` | Interrupt (Ctrl+C), End input (Ctrl+D), Tab, Previous command (Up), New tab, Next/Previous tab, Copy/Paste (Ctrl+Shift+C/V) |
| Nautilus | `org.gnome.nautilus`, `nautilus` | Parent folder, Back, Type a path, Rename (F2), Copy, Cut, Paste, New folder (Ctrl+Shift+N), Delete (confirm), Show hidden |
| Dolphin | `org.kde.dolphin`, `dolphin` | same as Nautilus, with New folder on F10 |
| mpv | `mpv`, `io.mpv.mpv` | Media\*, Play / pause, Rewind/Fast forward (arrows), Volume down/up (`9`/`0`), Mute (`m`), Full screen (`f`), Subtitles (`v`) |
| VLC | `vlc`, `org.videolan.vlc` | same as mpv, with Alt+Left/Right to seek and Ctrl+Down/Up for volume |
| Mousepad | `org.xfce.mousepad`, `mousepad` | Save, Find, Replace (Ctrl+R), Go to line (Ctrl+L), Undo, Redo (Ctrl+Y), Select all, Copy, Paste |
| *(any other app)* | — | Copy, Paste, Cut, Undo, Select all, Esc, Enter, Switch window (Alt+Tab), Close window\* (confirm) |

- \* Native buttons that call an agent endpoint or open a phone screen instead of sending keys:
  - Tabs and Open on phone use the [Firefox bridge](firefox-bridge.md),
  - Media opens the media card,
  - Close window uses the agent's close endpoint, because Hyprland has no default Alt+F4.
- † Sent as a command-palette sequence, for example Ctrl+Shift+P, then `View: Toggle Terminal`, then Enter. This
  avoids punctuation shortcuts that depend on the keyboard layout.

Buttons send ordinary live-screen input events, so the control session and the agent's rate limit apply as usual.
**Confirm** buttons ask on the phone first. If the focused window changes while a confirmation or text prompt is
open, nothing is sent (*Focus moved to another window; nothing was sent.*).

### Custom remotes

*Settings › App controls* lets you add your own buttons per window class. They are stored in the profile's
`desktopRemotes` section, so backup and sync carry them. The format is defined in
`agent/src/profile/schema.ts` and published as `app/assets/profile/tiphys.schema.json`.

```json
"desktopRemotes": [
  {
    "id": "firefox-github",
    "windowClass": "firefox",
    "name": "GitHub",
    "icon": "globe",
    "action": { "kind": "sequence", "steps": [{ "combo": "ctrl+l" }, { "text": "github.com" }, { "combo": "Enter" }] },
    "confirm": false
  }
]
```

| Field | Values |
|---|---|
| `windowClass` | Hyprland class, case-insensitive. A button also shows for other classes that map to the same built-in profile (a `firefox` button also appears in `firefox-esr`) |
| `name` | 1–40 characters |
| `icon` | `zap` (default), `star`, `play`, `search`, `save`, `copy`, `refresh`, `close`, `plus`, `folder`, `terminal`, `globe` |
| `action.kind` | `combo` (one shortcut), `sequence` (1–10 steps, each `{combo}` or `{text}` up to 500 characters), `prompt` (optional `combo`, then text typed on the phone, then Enter if `submit` is true, which is the default), `scroll` (`dy` −20…20, non-zero; positive scrolls down) |
| `confirm` | ask on the phone before sending (default `false`) |

Shortcuts use the agent's key rules:

- modifiers are `ctrl`, `alt`, `shift`, `super`, followed by one key: a letter, a digit, F1–F12, Esc, Tab, Enter,
  Backspace, Delete, Insert, Space, the arrows, Home/End, PageUp/PageDown, PrintScreen, KPPlus/KPMinus or Super;
- letters and digits need Ctrl, Alt or Super;
- punctuation keys aren't allowed.

Invalid buttons are rejected in the editor and hidden if they come from an imported profile.

## Mobile view

Open it with the **Mobile view** button on the remote strip. The phone shows:

- a small preview of the window: the live stream, or a thumbnail every 5 s,
- search over the controls,
- toolbars and menu bars as chips, open menus as cards, and tabs as a segmented control,
- text fields, sliders and spin buttons, list rows and links,
- headings and labels as context,
- web page content as its own section.

Tapping a control runs its own accessibility action (*Click*, *Press*, *Toggle*, *Follow link*, *Switch to tab*…),
not a pixel click. Long press shows the other actions and *Focus*. The view refreshes when the app reports a
change, and follows focus to other windows when it was opened from the live screen.

### How it works

- The agent starts `agent/helpers/atspi_helper.py` with `python3 -I`. It speaks JSON lines and only runs while a view
  is open. It stops after 60 s without a subscriber, when the view closes, when control ends, or when the agent
  shuts down. Each request has 5 s; the tree walk stops at depth 40, 1500 nodes or 1.5 s, and the result is then
  marked *Partial*.
- The window must be visible on the active workspace. Node ids include a generation number, so an action on an
  outdated id is refused (`agent.ui.stale`) and the phone silently re-reads.
- Firefox only exposes its tree while `org.a11y.Status.IsEnabled` is true. When the first view opens, the agent sets
  it with `busctl`. The previous value is saved in `a11y-state.json`, and it is restored when the last view closes
  or, after a crash, on the next agent start.
- If a field has no editable-text interface, the phone falls back to typing. The agent focuses the field, raises
  the window, re-checks focus, then types with `wtype`. Claude's `ui_set_text` never uses this fallback.
- Mobile view endpoints are limited to 30 requests per 5 seconds. See [API](../agent/api.md).

### What works

The helper reads any app that exposes AT-SPI. In practice:

| App or toolkit | Status |
|---|---|
| GTK 3 and GTK 4 apps (Mousepad, Nautilus, Pavucontrol…) | work |
| Firefox (Gecko): browser UI and page content | works. The agent switches AT-SPI on while the view is open. **Private windows are refused** |
| Electron / Chromium apps | only expose a tree when started with `--force-renderer-accessibility` |
| VS Code (Flatpak) | run `tiphys-agent vscode-a11y install` (see below) |
| Qt apps | may expose a tree while AT-SPI is enabled. Tiphys does not set `QT_LINUX_ACCESSIBILITY_ALWAYS_ON` |
| Terminals (kitty…), games, Steam | no tree. The app suggests the live screen and the remote strip |

### VS Code

```sh
tiphys-agent vscode-a11y install   # or: remove
```

This copies the VS Code Flatpak launcher (`com.visualstudio.code.desktop`, taken from the user or system Flatpak
exports) into `~/.local/share/applications/`, where it shadows the original, and adds
`--force-renderer-accessibility` to each `Exec` line. VS Code's own settings are not changed, and no other app is
affected. The file is marked as written by Tiphys; a launcher you wrote yourself is never overwritten or removed.
Restart VS Code afterwards. Only the Flatpak build is handled.

## Limitations

- Only windows on a visible workspace. Large windows may be partial; use search or the live screen.
- Apps without an accessibility tree aren't supported (see the table above).
- Built-in remote profiles cover the apps listed above. Everything else gets the generic profile plus your custom
  buttons.

## Security notes

- Every mobile-view endpoint needs the control-session token, except closing the view, which is always safe.
- Snapshots stay in memory and are never written to disk or logs. The event log only records `ui.opened` with the
  window class.
- The **text of password fields is never read**, even by the helper. Typing into a password field requires an
  explicit confirmation on the phone (*Send password*). Claude can never type into one.
- Private Firefox windows are never read, either by the phone or by Claude.

Related: [Claude's `ui_*` tools](claude.md#tools-and-guardrails), [Firefox bridge](firefox-bridge.md),
[Security](../security.md).
