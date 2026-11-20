# System

The **System** tab manages a host through its agent: metrics, power, services, containers, processes, ports and desktop tools. Compose stacks and log search work over SSH, without an agent. Choose a host at the top of the tab. Hosts without an agent only show Wake-on-LAN, quick actions and the SSH-based pages.

Each feature below depends on an agent feature flag (`features` in `agent.json`, see [../agent/configuration.md](../agent/configuration.md)). To change a flag, use either:

- **Settings › Hosts › (host) › Agent settings › Features**;
- `tiphys-agent init --features a,b,…` (the agent CLI).

**Feature changes take effect after the agent restarts.** If a feature is off, its routes don't exist and the app shows an error for that section.

| Feature | Default | Enables |
|---|---|---|
| `system` | on | System info, processes |
| `services` | on | systemd services |
| `docker` | on | Docker containers |
| `power` | on | Restart / shut down / sleep |
| `ports` | off | Ports + Tailscale sharing |
| `wake` | off | Wake-on-LAN relay |
| `desktop` | off | Clipboard, screenshot, media, open-on-PC (and [desktop-control.md](desktop-control.md)) |
| `transcribe` | off | Speech-to-text |

These are always on: the audit log, the event log and agent health.

API reference for all routes: [../agent/api.md](../agent/api.md).

## Platforms

The agent is developed on Linux; the server features below also run on macOS and Windows, with the same API. What an
OS can't do answers `501 agent.feature.unsupported` and is listed as `unsupported` in `GET /v1/health`.

| Feature | Linux | macOS | Windows |
|---|---|---|---|
| System info | `systeminformation`; CPU temperature; NVIDIA GPUs | `vm_stat`, `sysctl`, `df`, `mount`; no temperature | CIM (PowerShell); no temperature; NVIDIA GPUs |
| Processes | `ps`; `TERM`/`KILL`/`INT`/`HUP` | `ps`; all four signals | CIM, no user column; `TERM` = `taskkill` (fails for processes without a window), `KILL` = `taskkill /F`; `INT`/`HUP` unsupported |
| Ports | `ss` | `netstat` + `lsof` (process names only for the agent's own user) | `Get-NetTCPConnection` |
| Port sharing | `tailscale serve` | `tailscale serve` | `tailscale serve` |
| Services | systemd, user + system | launchd: user agents + system daemons (actions on daemons need root) | Windows services (`system` scope only; most need an administrator) |
| Service logs | `journalctl` | the job's `StandardOutPath`/`StandardErrorPath` file, no timestamps | unsupported |
| Docker | `docker` CLI | Docker Desktop (must be running) | Docker Desktop (must be running) |
| Power | `systemctl` | `pmset sleepnow`; restart/shut down through System Events | `shutdown.exe`; sleep via `SetSuspendState` (hibernates if hibernation is on) |
| Wake-on-LAN relay, git, Homepage, transcription | yes | yes | yes (the transcription command must be an executable, not a shell script) |
| Velour, Firefox bridge (`desktop`) | yes | socket only, untested | unsupported (Unix sockets) |

Everything else (Claude, desktop control, security center, incidents, backups, databases, …) is developed and tested
on Linux only. The desktop on macOS and Windows goes through the native helper, see
[desktop-control.md](desktop-control.md).

CI runs the platform tests, a build and a start-up smoke test (`/v1/health`, `/v1/system` with a paired token) on
macOS and Windows; the full test suite runs on Linux.

## System info

Shows CPU load, core count and temperature, memory and swap, disks, OS, kernel and uptime. For NVIDIA GPUs it also shows name, temperature, utilisation and VRAM, using `nvidia-smi`; without it the GPU list is empty. On Linux the data comes from the `systeminformation` library (macOS and Windows: see [Platforms](#platforms)) and is cached for 2 s.

- **Requires:** `system`.

## Services

Lists systemd `.service` units in the **user** or **system** scope (launchd jobs on macOS, Windows services on Windows, see [Platforms](#platforms)). You can start, stop and restart a unit, and view its last journal lines (default 200).

- **Requires:** `services`, plus `systemctl` and `journalctl`.
- **Limitation:** commands run as the agent's user with `--no-ask-password`. Changing system units needs polkit or sudo rules that allow it. Otherwise you get a "permission denied" error.

## Docker containers

Lists all containers with state, Compose project, CPU and memory (`docker stats --no-stream`). You can start, stop or restart a container, and view the last 300 log lines, with stdout and stderr merged by time.

- **Requires:** `docker`, plus the `docker` CLI usable by the agent's user (for example, membership in the `docker` group).
- **Security:** access to the Docker socket is effectively root on that host.

## Compose stacks (SSH)

**System › Compose stacks** works over SSH on every SSH host and doesn't need the agent.

- It searches the subfolders of each host's **compose roots** (default `~/stack`) for these files, in this order: `compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`.
- For each stack it shows container status, and offers:
  - **update check**: `pull`, then compare image IDs;
  - **update**: `up -d`, only for services running an outdated image (a force option recreates everything);
  - restart, stop/start, and recent logs.
- Output streams live.
- The update result is recorded as an event, on the host's agent or, if it has none, on the first agent host.

## Log search (SSH)

**System › Log search** searches the systemd journal (system and user) and the logs of running containers on the selected hosts at the same time. It works over SSH. See [monitoring.md](monitoring.md).

## Processes

Under **Tools › Processes**: the top processes by CPU or memory, read from `ps`. You can send `TERM`, `KILL`, `INT` or `HUP`. Every signal asks for confirmation, and the agent refuses to signal itself or PID 1.

- **Requires:** `system`.
- **Limitation:** you can only signal processes that the agent's user is allowed to signal.

## Ports

Under **Tools › Ports**: lists listening TCP ports with their process (`ss -ltnpH`).

- A port that listens only on localhost can be **shared to the tailnet** with `tailscale serve --bg --https=<port>`. The app then opens it at `https://argo.my-tailnet.ts.net:<port>`.
- Sharing can be turned off again. Ports that are already public can't be shared.
- Port 7443 (the agent's default port) is reserved.

- **Requires:** `ports`, plus `ss` and `tailscale`. The agent's user must be allowed to run `tailscale serve`, for example as the Tailscale operator.
- **Security:** a shared port is reachable only inside your tailnet, not publicly. Anyone on the tailnet with access to the PC can reach it.

## Power

The **Power** section offers **Sleep**, **Restart** and **Shut down**.

- Each action asks for confirmation in the app, and the API requires `{"confirm": true}`.
- The agent runs `systemctl --no-ask-password <suspend|reboot|poweroff>` 1.5 s after it answers (macOS and Windows: see [Platforms](#platforms)).
- **Requires:** `power`, and permission for the agent's user to run these actions (polkit normally allows this for a local active session).

## Wake-on-LAN

**Wake up (Wake-on-LAN)** sends a magic packet. You set it up in **Settings › Hosts › (host) › Wake-on-LAN**:

- **MAC address**
- **Send from**, with two options:
  - **This phone (same Wi-Fi)**: the phone broadcasts the packet itself (to `255.255.255.255:9`, three times). This only works while the phone is on the sleeping machine's local network.
  - **an agent host**, for example `atlas` running all the time on the same LAN: the app calls `POST /v1/wake/<hostId>` on that agent.

For the agent to relay the packet:

- The relaying agent needs the `wake` feature.
- It needs a matching entry in `wake.targets` in its `agent.json`. The app doesn't send the MAC to the agent.

```json
"wake": { "targets": [ { "hostId": "argo", "mac": "AA:BB:CC:DD:EE:FF", "broadcast": "255.255.255.255", "port": 9 } ] }
```

In this example:

- `hostId` must equal the host's ID in the app profile.
- `broadcast` and `port` are optional.

The relaying agent must be on the **same local network** as the machine you want to wake.

## Desktop tools (`desktop` feature)

These tools assume a **Wayland** session. If `WAYLAND_DISPLAY` isn't set (for example, when the agent runs as a systemd user service), the agent finds the `wayland-N` socket under `$XDG_RUNTIME_DIR`. If no session is running, the agent returns `agent.desktop.noDisplay`.

### Clipboard

**Tools › Clipboard**: **Get from PC**, then **Copy to phone**; or **Paste from phone**, then **Send to PC**. This uses `wl-paste` and `wl-copy` (the `wl-clipboard` package). The text limit is 1 MB.

### Clipboard sync

There are two independent directions.

- **PC → phone.** Turn on **Clipboard sync (PC → phone)** in **Agent settings**. The setting is `desktop.clipboardSync`, default `true`, and changing it needs no restart.
  - The agent watches the clipboard with `wl-paste --watch`. When the text changes, it sends a silent, low-priority `clipboard.pc` notification. Its **Copy** button puts the text on the phone clipboard without opening the app.
  - These are skipped:
    - content that a password manager marks as sensitive (`x-kde-passwordManagerHint`, or wl-clipboard's `sensitive` state);
    - anything that isn't text;
    - text over 3 KB;
    - the clipboard content at the moment watching starts;
    - text that just came from the phone.
  - Requires the push setup in [notifications.md](notifications.md).
- **Phone → PC.** Turn on **Sync clipboard to PC** under **Settings › Notifications**, and choose the **PC to sync with** (default: the Claude host, otherwise the first agent host).
  - Android doesn't allow reading the clipboard in the background. The app therefore reads it only when it comes to the foreground, and sends it if it changed.
  - These are never sent:
    - copies that Android marks as sensitive (if the app can't tell, it treats the copy as sensitive);
    - a vault password that hasn't been cleared yet.

**Privacy:** clipboard text is never written to the event log, the audit log or the agent's logs.

### Screenshot

**Tools › Screenshot**: a PNG of the PC screen taken with `grim`, scaled to 60% by the app (the API allows 0.1–1). Needs a wlroots-based compositor that `grim` supports.

### Media control

**Tools › Media** controls MPRIS players through `playerctl`, and system volume through `wpctl` (PipeWire). It offers:

- play/pause, previous/next, ±10 s, and drag-to-seek;
- a player picker;
- volume (0–150%) and mute;
- cover art. Local `file://` art is served through the agent, at most 5 MB and image files only. The file path is never exposed.

The home screen's "Now playing" card uses the same data.

- **Requires:** `playerctl`, `wpctl`, and the session D-Bus. The agent falls back to `$XDG_RUNTIME_DIR/bus`.

### Open on PC

**Open on PC** opens a link in the PC's browser. You can trigger it in two places:

- **Tools › Open on PC** uses the first link on the phone clipboard;
- the share sheet ([terminal-files-git.md](terminal-files-git.md#share-to-pc-android-share-menu)).

Only `http`/`https` URLs up to 4096 characters, without whitespace or control characters, are accepted.

- If the Tiphys Firefox extension is connected, the link opens as a new Firefox tab and Firefox is focused ([firefox-bridge.md](firefox-bridge.md)).
- Otherwise the agent runs `xdg-open`.

The URL isn't written to the event log.

## Transcription

`POST /v1/transcribe` takes a phone recording (base64, up to about 30 MB; m4a/aac/mp3/wav/ogg/opus/webm), writes it to a temporary file (mode 600), and runs the configured command. The temporary file is deleted afterwards. Used by **Dictate** in quick notes ([vault-and-notes.md](vault-and-notes.md)) and by voice input in Claude ([claude.md](claude.md)).

- **Requires:** `transcribe`, and a command in `transcribe.command` (default `~/.local/bin/transcribe`). It is called as:
  `<command> <file> -m <model> [-l tr|en]`
  and must print the text to stdout.
- The model is `small` or `large-v3` (default `transcribe.model`, `small`). The app can override it from **Settings › Integrations › Scriberr**. The command is typically a wrapper script around a Whisper server such as Scriberr.
- **Limitation:** 10-minute timeout. Only `tr` and `en` can be passed as language hints; otherwise the language is auto-detected.

## Audit log

Every request that changes something (any method other than GET/HEAD/OPTIONS) is appended to `audit.jsonl`, next to `agent.json`. Each entry records:

- the time;
- the device ID (`null` if the request wasn't authenticated);
- the method and path, without the query string;
- the HTTP status.

Request bodies are never logged. When the file passes 1 MB it is renamed to `audit.jsonl.1`. View the log in **Tools › Activity log** (last 300 entries). Always on.

## Event log

`events.jsonl` (next to `agent.json`; renamed to `.1` when it passes 2 MB) records:

- every notification the agent sends, even if no push endpoint is registered;
- events that don't trigger a notification, such as git commits and pushes;
- small events reported by the app, such as Compose updates done over SSH.

**System › Events** merges all agent hosts into one timeline. Tapping an event opens the screen its notification would open. Always on. See [notifications.md](notifications.md).

## Agent health

The **Agent** section shows:

- the agent version, with a warning if it is behind the app;
- uptime;
- memory used by the agent and its child processes (for example Claude sessions);
- unexpected restarts in the last 24 hours.

How restarts are detected: each start is recorded in `agent-runs.json` (last 50 runs), and a clean shutdown (SIGTERM/SIGINT) marks the record. If the previous run has no mark, the agent crashed or was killed, and the phone receives a high-priority "agent restarted" notification. Data comes from `GET /v1/agent/status`. Always on.

## Security notes

- Every route except `/v1/health` needs a paired device token. See [../security.md](../security.md).
- The agent runs as your user. Services, Docker, process signals and power actions can do whatever that user is allowed to do. Turn off the features you don't need.
- Destructive endpoints (power, process signals, git discard) require an explicit `confirm: true`, and the app asks before sending it.
