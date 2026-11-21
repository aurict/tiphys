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

## Sleep mode (in progress)

A fourth mode, started with `POST /v1/sleep/start` (the app comes later): very dim fireplace embers and synthesized
crackles on the bedroom screens, a slow fade to a night light. It always runs full screen on its own workspace
(`uyku`). The agent dims the **hardware** along the curve, the laptop backlight with `brightnessctl` (at most every 2 s)
or a desktop monitor over **DDC/CI** with `ddcutil` (at most every 15 s), and the page dims the **content** in
between. Every previous value (brightness, and the optional power profile, system volume and LEDs) is saved before
it is changed and put back exactly at stop or after a crash. API: [api.md › Sleep mode](../agent/api.md#sleep-mode).

**Two screens, one scene:** the phone sends the same session (seed, start time, the members with their place in the
room, the leader) to every machine. Each computes the same sparks and crackles by itself, so a spark leaving one
screen's edge enters the other's, and its sound moves with it. The laptop talks to the leader over its existing
source connection (no new token): it measures the clock difference (lowest round-trip pings; corrected only above
20 ms) and passes stops both ways, so Esc held on either machine, or a stop from the phone, ends both. The laptop
needs a source for the leader (named like it, or whose address starts with its name), else the start fails with
`agent.sleep.noGroup`. If the link drops, each machine carries on alone and the phone sees `agent.sleep.memberDown`.

**Alarm (sunrise):** with `alarm.enabled`, the screens brighten like a sunrise for `sunriseMin` (25) before the
alarm time, from the night light up to the morning brightness, then the alarm rings: birds (or a soft chime) whose
every chirp is a small point of light on the screen, its volume rising over `rampMin` (3). **Space** snoozes it
(`snoozeMin`, 9: the screens stay bright and quiet), **Esc held 1 second** turns it off; the same from the phone
(`POST /v1/sleep/alarm`). Either acts on both machines. Nobody answers: the sound stops after `autoStopMin` (20),
the screens stay bright and the phone is told. After turning it off, an optional morning screen (clock and date) for
10 minutes, then the mode ends by itself. With `sound: "velour"` the leader plays the chosen song on Velour (the
other screen adds quiet birds). If Firefox crashed during the night, the agent plays a short alarm sound itself
(`pw-play`) and starts the kiosk again. The alarm only exists while the sleep mode runs; the phone keeps its own
backup alarm. The alarm time is the machine's local time; the leader's settings decide for the group.

**Night notifications and the morning summary:** while the mode runs, each machine sends only the kinds chosen as
critical (`notify.critical`: a host down, a security trap, a new incident, a full disk); the rest wait. The waiting
ones are kept in memory only (count and three short titles) and still appear in the event history as usual. When
the alarm is turned off (or the mode is stopped, if there was no alarm) every machine reports its night to the
leader, and the leader sends **one** morning notification: how long the night was, the jobs that finished, backups
(ok / failed), new incidents, and how many notifications waited with the first three. The phone opens it as a
summary card (`GET /v1/sleep/summary`, kept 12 hours); the morning screen shows the same. A machine that was
unreachable is counted as missing. Notifications on the PC desktop itself (Quickshell bubbles) are not touched.

**Velour sleep playlist:** with a playlist chosen (`velour.playlistId`), the leader starts it on Velour at the
beginning (unless Velour is already playing something: then it is left alone), at `velour.volume`, fades it out over
`velour.fadeMin` and lets Velour's own sleep timer stop it; the fireplace sounds sit 12 dB lower while it plays. The
Velour alarm and the playlist share one saved volume: whatever Velour's volume was before the night is what it gets
back, once, at the end (also after a crash). Needs the "desktop" feature on the leader; otherwise the playlist is
skipped and the sleep status says so.

**DDC/CI on a desktop monitor:** install `ddcutil` (its udev rule gives the logged-in user the I²C device) and turn
DDC/CI on in the monitor's own menu. `tiphys-agent doctor` warns with `doctor.sleep.ddcUnavailable` when `ddcutil
detect` finds no working display; the mode still runs and the page dims alone. With the NVIDIA proprietary driver the
hardware I²C often fails ("DDC communication failed"); the usual fix is the driver's software I²C, set in
`/etc/modprobe.d/nvidia-ddc.conf` as `options nvidia NVreg_RegistryDwords=RMUseSwI2c=0x01;RMI2cSpeed=100`, then
`sudo update-initramfs -u` and a reboot.

## Stopping leaves nothing behind

Stop from the phone (home card or screen), hold **Esc for 1 second** on the display host, or close Firefox (not in the
sleep mode: there the alarm must still ring, so a closed or crashed kiosk is started again at sunrise). Every side
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
| Source (PC) | Tiphys Claude permission → `diff` message | a few ms in the agent | diff card < 500 ms |
| Display (laptop, Firefox + agent) | Work, idle (steady state) | 1.0–1.6 % + 0.9 % of one core | < 5 % |
| Display (laptop) | Work, the first minute after start (page load, first layout) | ~15 % + 1 % | |
| Display (laptop) | Work, one edit (glow + camera, 14 s window) | 18.0 % + 1.2 % | < 20 % |
| Display (laptop) | Work, an edit every 3 s plus commits, sustained | 32.7 % + 1.9 % | over budget, see below |
| Display (laptop) | Work, a Claude session running / waiting for approval | 2.2 % / 3.2 % + 1.0 % | < 5 % |
| Display (laptop) | Focus ready / counting / paused / veiled / ambient sound on | 1.3 / 3.0 / 0.5 / 0.1 / ~10.7 % | |
| Display (laptop) | Firefox memory (8 processes, PSS) | 530–590 MB | < 700 MB |
| Display (laptop) | Game, visible / hidden | 62 % / 0–1 % of one core (0.5.0: ~61 %) | unchanged |

A sustained stream of edits keeps the 3D city animating all the time (one 3D frame costs ~15 ms of CPU on the laptop's
Iris Xe at 2160×1440); the slow parts of an effect already run at 10 fps. Use the 2D city or motion *low* if the
display host is weak; the battery saver does this by itself on battery.

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
