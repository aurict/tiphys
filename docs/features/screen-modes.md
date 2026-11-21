# Screen modes

A laptop next to your PC (or the PC itself) becomes a second screen that you pick, start, adjust and stop from the
phone. Three modes share one kiosk framework:

| Mode | What it shows |
|---|---|
| **Work** (*Çalışma*) | The **code city** of the project you are working on, with the **Claude brain** floating over it, and cards for the day (clock), PC resources, long-running jobs, git, music and servers. When a Tiphys Claude session asks to edit a file, a **diff card** shows the change on the big screen before you approve it on the phone. |
| **Focus** (*Odak*) | A big focus timer (pomodoro rounds and breaks), one line "what I'm doing now", a small clock and music, optional synthesized ambient noise. Only critical notices. |
| **Game** (*Oyun*) | The ETS2 cockpit, live map, the Velour song and lyrics while you play. See [Game mode](game-mode.md) for everything Game-specific (ETS2 plugin, map data, route line). |

Switching between modes happens on the page (about 0.6 s), without restarting the browser. When a mode stops, no
process, file, window rule, keybind or setting is left behind on any machine.

API: [api.md › screen](../agent/api.md#screen). Settings: [configuration.md › screen](../agent/configuration.md#screen).
Security rationale: [Security › Screen modes](../security.md#screen-modes).

## How it fits together

```
phone ─ GET/PUT /v1/screen, POST /v1/screen/{start,stop,mode,focus,veil} ─▶ display host agent (laptop)
display agent ─ systemd-run --user (one unit) ─▶ systemd-inhibit ─▶ firefox --kiosk (temporary profile on tmpfs)
   firefox ─ WS /v1/screen/live (display token) ─▶ display agent
display agent ─ WS /v1/screen/feed {topics} (service token, scope screen) ─▶ source agent(s) (PC)
                 (the display host itself is the source "self": in-process, no network, no token)
```

- **Display host:** the machine whose screen shows the mode (usually the laptop). Each display host has its own
  settings and its own layout per mode.
- **Source:** the agent that produces the data: `self` (the display host itself) or a named remote source (URL + a
  `screen` service token). A display host can read several sources; every card picks its own.
- **Mirroring:** the mode chooser's ready layouts are *Mirror <source>* (every card reads the PC, e.g. you code on
  the PC and the laptop shows it) and *This machine itself* (every card reads `self`, e.g. you work on the laptop itself).
  You can also set each card's source on the mode's *Layout* tab.
- **Topics:** the display subscribes each source only to the topics its enabled cards need (`system`, `jobs`, `git`,
  `city`, `claude`, `diff`, `servers`, `music`, `spectrum`, `truck`). A producer starts with its first subscriber and
  stops with its last; a card that is off starts nothing.

## Placements

- **Full screen** (`fullscreen`, the default): the mode gets its own named workspace (`is` for Work, `odak` for
  Focus, `yol` for Game) and is focused at start; stop returns to the previous workspace.
- **Shortcut** (`scratch`): the window lives on the Hyprland special workspace `special:tiphys` and a temporary
  keybind (default `SUPER,grave`, i.e. Super+`) shows and hides it. Meant for a single-monitor PC. The bind is added at
  start only if it is free (otherwise the start is refused with *shortcut taken*) and removed at stop.

While the page is not visible (special workspace hidden, another workspace in front, screen off) the agent tells the
page to pause: it stops all drawing, timers, sound and animations, and the agent drops the topics that only matter
on screen (system, spectrum, city touches).

## Work mode

- **Code city:** every tracked (and untracked, not ignored) file of the project is a building; folders are districts
  (squarified treemap), height follows the line count, colour the file kind. A saved file lights its roof, a new file
  rises, a deleted one collapses, a commit sends a burst over the city. 3D (WebGL, Three.js) or a flat 2D map (setting,
  or automatically without WebGL). Repositories above 20 000 files are drawn per folder with a note.
- **Project:** *Automatic* follows the most recently active Claude session's folder (Tiphys or terminal), else the
  focused terminal's working directory, walked up to the git root; or a fixed folder inside the source's
  `allowedRoots`.
- **Claude brain:** each Claude session in the project is a glowing sphere over the city: a slow pulse while it
  works, beams to the buildings it reads (faint) or edits (bright), orange when it waits for approval. Tiphys sessions
  and terminal Claude Code sessions both appear; a terminal session waiting for approval shows only a banner
  ("waiting for approval · tool · file · on the phone"), never a diff.
- **Diff card (approval preview):** when a **Tiphys** Claude session asks permission for Edit, Write, MultiEdit or
  NotebookEdit on a file inside the project, the city blurs and a unified diff (line numbers, light syntax colouring,
  ≤ 400 lines / 64 KB, then "… N more lines") opens; Bash permissions show the command and the reason. Several pending
  requests rotate as tabs. **You approve or deny on the phone only:** the kiosk page has no approval route. When the
  permission is answered the card closes within a second. Needs code sharing on the source (below) and the *Diff
  preview* setting.
- **Cards:** Day (clock and date), Resources (CPU/RAM/GPU rings, temperature, battery), Jobs (`arkaplan` scopes,
  `tools/limited.sh` jobs and build/test processes running longer than 30 s; finished ones stay 2 minutes), Git
  (branch, ahead/behind, changed/untracked/conflicts, last 3 commits, optional CI dot from `gh`), Music (Velour),
  Servers (Uptime Kuma hosts and open incidents; grows only when something is wrong).
- **Pills:** short notices for a finished or failed job, a commit, a server going down or coming back, Claude waiting
  for approval and Claude finished.

### Code sharing (consent)

File names and diffs are code. By default a source sends **neither**: with `screen.share.code` off every path
segment is replaced by an opaque token (the city still has its shape and beams still hit the right building, but
labels are hidden and a note says *File names hidden*), and no `diff` message is ever produced. Code sharing is
turned on **on the source**, by you, after a separate confirmation: in the setup wizard's code sharing step or with
*Turn on at source* on the Work tab. Cancelling sends nothing. Turn it off the same way (or set
`screen.share.code: false` on the source).

## Focus mode

- A big ring with the time left and round dots, the task line under it, a small clock in the top right corner, the
  round in the top left, music bottom left. While focusing everything else is dimmed; breaks turn the background warm
  with a "stand up, drink water" card.
- **Timer** (on the display host, survives an agent restart): focus 25 min, short break 5, long break 15 (each
  5–120), a long break every 4 rounds (2–8). Start, pause, skip and reset from the phone's hero card (and, on
  Android, from the ongoing notification's *Pause* button). A phase that ends starts the next one and plays a soft
  chime (setting).
- **Task line:** one line, ≤ 80 characters, kept in memory only; it is never written to a file, log, event or push.
- **Ambient sound** (off by default): brown or pink noise or rain, synthesized in the page (no files, no network),
  only during a focus round while the page is visible and Velour isn't playing; volume setting.
- **Quiet phone:** with *Quiet Tiphys notifications* on, the app shows only critical Tiphys notifications during a
  focus round (server/service down, Claude or agy waiting for approval, a failed job, command or backup, security
  alarms) and counts the rest; when the mode ends you get one summary. PC (Quickshell) notifications are left alone.
- Only critical pills appear on the page (a server down, Claude waiting for approval).

## Privacy veil

*Hide the screen* (on the hero card) turns the page into a dim clock at once, for when someone walks up to the laptop.
While veiled the agent sends the page no layout and no data at all (it keeps the state and replays it when the veil
lifts). The veil survives an agent restart and ends with the mode.

## Session summary

When a mode that ran for at least 2 minutes stops, the phone gets **one** notification: duration, modes used,
focus rounds completed, commits, jobs finished (and failed), Claude sessions seen and approval waits. Numbers and mode
names only: no file names, task, commit subjects or session names. It is counted in the display agent's memory from
the messages it relays (so a count appears only if the card that receives it was on) and is never recorded: not in
the event log, the black box or any file. Tapping it opens the *Last session* card on the screen mode screen (kept
12 hours in memory). If Focus muted notifications, the held count is merged into this one notification.

## Battery saver

With *Battery saver* on (default), a display host running on battery below 30 % drops the page to low motion and the
flat 2D city and shows a small *Battery saver* chip; on mains or at 35 % it returns to your settings. The battery is
read from `/sys/class/power_supply` every 30 s (no process).

## Stopping leaves nothing behind

Stop from the phone (home card or screen), hold **Esc for 1 second** on the display host, or close Firefox. Every side
effect is written to a state file in `$XDG_RUNTIME_DIR/tiphys-screen/` **before** it is made, and undone on stop:
the Firefox unit and its temporary profile (tmpfs), window rules, the temporary keybind, the workspace and
brightness, the source subscriptions (producers, file watches and the `nvidia-smi` child stop with their last
subscriber) and the Focus timer file. After a crash the next agent start undoes whatever is left. An agent
*restart* (e.g. an update) keeps a running mode: the new agent adopts it and the page reconnects. The event log gets
only `screen.started {mode}` and `screen.stopped`; diffs, file paths and the task are never written anywhere,
including logs.

## Resource use

Design rules: nothing runs without a subscriber, events instead of polling (`fs.watch`, the Hyprland socket), nothing
is redrawn unless it changed (no continuous `requestAnimationFrame`; the 3D city draws only during an effect, at most
a 1 fps "breath" when idle), everything stops while hidden.

Measured (2026-11-21):

| Where | Situation | Measured | Budget |
|---|---|---|---|
| Source (8-core PC) | Work: city + claude + git + jobs + system, idle, 120 s | 0.04 % of all cores (0.33 % of one core), +1 MB | < 1 %, < 30 MB |
| Source (8-core PC) | 40 file writes per second for 30 s | 1.8 % of all cores, +4 MB | < 3 % |
| Source (PC) | Tiphys Claude permission → `diff` message | ≤ 3 ms in the agent | diff card < 500 ms |
| Display (laptop, Firefox + agent) | Work, idle | ~1.4 % + 0.8 % of one core | < 5 % |
| Display (laptop) | Work, a burst of reads / a running session's pulse | 5.6 % / 2.2 % of one core | < 20 % |
| Display (laptop) | Work, a session waiting for approval (blinking label) | see below | < 5 % |
| Display (laptop) | Focus counting / paused / veiled / ambient sound on | 3.0 / 0.5 / 0.1 / ~10.7 % of one core | |
| Display (laptop) | Firefox memory (8 processes, PSS) | 540–560 MB | < 700 MB |
| Display (laptop) | Game, visible / hidden | ~61 % / 0–1 % of one core (unchanged from 0.5.0) | |

<!-- W8 laptop numbers are filled in below when measured. -->

## Requirements

| Host | Need | Used for |
|---|---|---|
| Both | Linux, the agent with the **`screen`** feature on | the routes (the flag is off on macOS/Windows) |
| Display host | Hyprland (classic or Lua config), the agent running as the logged-in user | workspaces, window rules, the shortcut, visibility |
| Display host | Firefox (`firefox` or `firefox-esr`) | the kiosk page |
| Display host | `systemd-run`, `systemd-inhibit` (systemd user session) | one transient unit; no idle/sleep while a mode runs |
| Display host | `brightnessctl` (optional) | the brightness setting |
| Source host | `git` | git card and code city |
| Source host | NVIDIA: `nvidia-smi` (optional); Intel: nothing extra | the GPU ring |
| Source host | `gh`, logged in (optional) | the CI dot (setting, off by default) |
| Source host | the `claude` feature (optional) | Tiphys Claude sessions in the brain and the diff card |
| Source host | Velour, PipeWire `pw-record` | music (and Game's spectrum) |

`tiphys-agent doctor` checks the display tools (a failure on a display host with sources, a warning otherwise),
`brightnessctl`, `pw-record`, and reports as information when `gh` is missing or not logged in.

## Setup

1. **Turn on `screen`** on the display host and on each source (it is a risky feature, so `init --detect` never turns
   it on): in the app *Settings › Hosts › (host) › Agent settings › Features › Screen mode*, or
   `tiphys-agent init --features screen`, then restart the agent. An agent from 0.5 with `gamemode` on is migrated
   automatically (`gamemode` → `screen`, its source becomes `main`).
2. **Connect a source:** on the screen mode screen, *Connections › Add a source*: pick the display host and the
   source(s). The app creates a `screen` service token on the source, hands it to the display agent (never stored on
   the phone) and tests the link. A Work mode that only shows the display host itself (`self`) needs no source.
3. **Code sharing** (Work, optional): the wizard's separate step or *Turn on at source*; see above.
4. **Start:** tap the **Screen mode** home card, pick Work, Focus or Game, the display host and *Mirror <source>* or
   *This machine itself*, then **Start**. While running, the same sheet switches modes; the card's button stops it.
5. **Placement** (optional): *Appearance › Placement* — full screen, or shortcut (Super+`) on a single-monitor PC.

## Compatibility

The 0.5 names keep working for one release: the `gamemode` feature name and service-token scope (a `gamemode` token
gets only the Game topics), the `/v1/gamemode/*` and `/gamemode/*` routes and the app 1.2's Game mode screen. The app
falls back to `/v1/gamemode/*` for Game on an agent older than the screen modes (Work and Focus then ask you to update
the agent).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| *Screen mode is off on this host* | The `screen` flag is off (or the agent was not restarted). |
| *No source is set up yet* (`agent.screen.noSource`) | A card reads a source that isn't configured: add it under *Connections* or pick *This machine itself*. |
| *Shortcut taken* (`agent.screen.bindTaken`) | Another bind uses the shortcut: pick another one in *Appearance* or use full screen. |
| Card says *Source unreachable* | The PC is off/asleep, its agent is down or has `screen` off, or the token was revoked. The card keeps its last data, dimmed; it reconnects by itself. |
| City says *No project selected* | No Claude session or focused terminal in a git repository yet; open one or pick a fixed project. |
| *File names hidden* | Code sharing is off on the source (by design). |
| No diff card, only a banner | The waiting session is a terminal session (never a diff, by decision), code sharing is off on the source, the file is outside the project, or *Diff preview* is off. |
| No CI dot | `ci` is off, or `gh` is missing / not logged in on the source (`doctor` says which). |
| The page stays still | It is paused because it isn't visible (shortcut placement hidden, another workspace in front, screen off), or the battery saver / low motion is on. |
