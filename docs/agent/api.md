# Agent API reference

> **Internal and unstable.** This API exists for the Tiphys app and is versioned together with it. The app expects an agent of the **same release**: it reads `version` from `/v1/health` and warns when the two don't match. Paths, shapes and error codes can change in any release without notice. Don't build third-party clients on it.

Source of truth: `agent/src/server.ts` (registration), `agent/src/routes/*.ts`, `agent/src/claude/*.ts`, `agent/src/control.ts`, `agent/src/atspi.ts`, and the other modules linked below. Configuration and feature flags are described in [configuration.md](configuration.md); the security model is in [Security](../security.md).

## Contents

- [Conventions](#conventions)
- [Authentication](#authentication)
- [Control sessions](#control-sessions)
- [Errors](#errors)
- [Endpoints](#endpoints)
  - [Always available](#always-available)
  - [system](#system) · [services](#services) · [docker](#docker) · [power](#power) · [wake](#wake) · [ports](#ports) · [transcribe](#transcribe) · [git](#git) · [homepage](#homepage)
  - [desktop](#desktop): [clipboard, screenshot, open](#clipboard-screenshot-open) · [media](#media) · [windows and apps](#windows-and-apps) · [Sunshine](#sunshine) · [Firefox bridge](#firefox-bridge) · [mobile view](#mobile-view-at-spi) · [live screen](#live-screen)
  - [claude](#claude) · [watch](#watch) · [alerts](#alerts) · [backups](#backups) · [uptime](#uptime)
- [Protocols](#protocols)
  - [Live screen WebSocket](#live-screen-websocket)
  - [Claude session WebSocket](#claude-session-websocket)
  - [Server-sent events](#server-sent-events)
  - [Firefox native messaging](#firefox-native-messaging)
  - [AT-SPI helper](#at-spi-helper)

## Conventions

- **Base URL**: whatever `tailscale serve` exposes, for example `https://argo.my-tailnet.ts.net`. The agent itself listens on `127.0.0.1:7443` by default.
- **Bodies**: JSON. The maximum request body is 32 MB, and the maximum WebSocket message is 1 MB.
- **Validation**: zod. Unknown keys are ignored unless the schema is marked *strict* below.
- **Confirmation**: destructive endpoints require `{"confirm": true}` in the body and fail with a dedicated `…confirmRequired` code without it.
- **Feature column**: the routes exist only when that flag is on. Otherwise they return `404 agent.route.notFound`.
- **Audit**: every non-GET request is recorded in `audit.jsonl` as `{at, device, method, path, status}`. The body and query string are never logged.

## Authentication

| Mechanism | Applies to | Details |
| --- | --- | --- |
| Device token | every route except `GET /v1/health` | `Authorization: Bearer tph_…`. Created by `tiphys-agent pair`; only its SHA-256 hash is stored, and comparison is constant-time. For WebSockets the token may also be sent as the `?token=` query parameter. |
| Tailscale identity | every route except `GET /v1/health` | When `requireTailscaleLogin` is set, the `Tailscale-User-Login` header (added by `tailscale serve`) must equal it. Otherwise `403 agent.auth.tailnetUserNotAllowed`. |
| Control token | mutating desktop routes, live screen, Firefox tabs, mobile view, Sunshine actions, Claude PC sessions | `X-Tiphys-Control: tpc_…`, obtained from `POST /v1/desktop/control/session`. It must belong to the calling device and not be expired, and the `control` feature must be on. |

Failure codes: `401 agent.auth.missingToken`, `401 agent.auth.invalidToken`, `403 agent.auth.tailnetUserNotAllowed`, `403 agent.control.sessionRequired`, `403 agent.control.disabled`.

## Control sessions

Endpoints that change the PC require an open **control session** (`agent/src/control.ts`). Rules:

- **One session at a time.** If another device holds it, opening returns `409 agent.control.busy` with `{device}`. The same device re-opening gets a fresh token, and its old token stops working.
- **Timed.** The default is 15 minutes, `minutes` can be 1–60, and the remaining time (including extensions) can never exceed 60 minutes. The session closes by itself when it expires.
- **Visible on the PC.** While the session is open, Hyprland's active border turns red-orange (at least 3 px) and a critical `notify-send` notification is shown. If this indicator can't be turned on, the session is **not** opened (`503 agent.control.indicatorFailed`). The previous border is restored when the session closes, or on the next start after a crash.
- **Closing is always allowed**: any paired device can call `DELETE`, and no control token is needed.
- **Ends immediately** when the session expires, is stopped, the agent shuts down, or `features.control` is set to `false`. Live streams and SSE streams that depend on the session are closed (WebSocket close code `4401`).
- **Events.** Start and end are written to the event log as `control.started` / `control.ended`, with the device, duration and reason.

| Method | Path | Body | Response | Rate limit |
| --- | --- | --- | --- | --- |
| POST | `/v1/desktop/control/session` | `{minutes?}` | `{token, expiresAt}` | 5 / min per device |
| POST | `/v1/desktop/control/session/extend` | `{minutes?}` + control token | `{expiresAt}` | - |
| DELETE | `/v1/desktop/control/session` | - | `{ended: bool}` | - |

These routes are registered when `desktop` is on. Opening and extending also require `control`.

Each group of control-gated endpoints has its own sliding-window rate limit, counted per session device. Exceeding it returns `429 agent.control.rateLimited`.

| Group | Limit |
| --- | --- |
| Desktop panel (window actions, workspace, DPMS, launch) | 10 / 5 s |
| Firefox bridge | 20 / 5 s |
| Mobile view (AT-SPI) | 30 / 5 s |
| Sunshine start/stop/pair | 6 / min |
| Live screen input events | 60 / s |
| Live screen quality changes | 6 / 10 s |
| Claude PC tools | 4 / s |

## Errors

Every error has the same envelope. The agent sends codes, never sentences; the app translates them into the user's language.

```json
{ "error": { "code": "agent.git.notRepo", "params": { "path": "~/src/x" } } }
```

- Validation errors: `400 agent.request.invalid`, `params.issues = [{path, message}]`.
- Unknown route: `404 agent.route.notFound`, `params.url`.
- Unhandled error: `500 agent.internal` (details are logged on the agent only).

| Code | HTTP | Meaning |
| --- | --- | --- |
| `agent.request.invalid` | 400 | Body, query or parameter failed validation |
| `agent.route.notFound` | 404 | No such route (or its feature is off) |
| `agent.internal` | 500 | Unexpected error |
| `agent.auth.missingToken` | 401 | No bearer token |
| `agent.auth.invalidToken` | 401 | Unknown token |
| `agent.auth.tailnetUserNotAllowed` | 403 | Tailscale login mismatch |
| `agent.path.notFound` / `agent.path.notAllowed` | 404 / 403 | Path missing / outside `allowedRoots` |
| `agent.exec.commandMissing` | 500 | Required binary not installed (`params.command`) |
| `agent.exec.failed` | 502 | Command exited non-zero (`command`, `code`, `stderr`) |
| `agent.exec.timeout` | 504 | Command timed out |
| `agent.config.passwordRequired` | 400 | Secret needed because the URL changed (`params.field`) |
| `agent.device.notFound` | 404 | Unknown device id |
| `agent.devices.confirmRequired` | 400 | `revoke-all` without `confirm: true` |
| `agent.processes.confirmRequired` / `.self` / `.notFound` / `.permissionDenied` | 400 / 400 / 404 / 403 | Process signal errors |
| `agent.services.actionFailed` / `.permissionDenied` | 502 / 403 | `systemctl` failed / polkit denied |
| `agent.power.confirmRequired` | 400 | Missing confirmation |
| `agent.wake.target.notFound` | 404 | Unknown wake target |
| `agent.ports.reserved` / `.notListening` / `.alreadyPublic` / `.shareFailed` | 400 / 404 / 409 / 502 | Port sharing |
| `agent.transcribe.failed` | 502 | Transcription command failed |
| `agent.git.notRepo` | 404 | Not inside a git repository |
| `agent.git.failed` | 502 | Git command failed (`args`, `stderr`) |
| `agent.git.confirmRequired` | 400 | Discard without confirmation |
| `agent.git.newFilesNeedConfirm` | 409 | Discard to HEAD would delete new files (`params.files`) |
| `agent.git.nothingToCommit` | 409 | Nothing to commit |
| `agent.git.noUpstream` / `.noRemote` | 409 | Push/pull needs an upstream or remote |
| `agent.git.authFailed` / `.pushRejected` | 502 | Credentials missing / non-fast-forward |
| `agent.git.pushFailed` / `.pullFailed` / `.fetchFailed` | 502 | Other remote failures |
| `agent.homepage.fileNotFound` / `.invalidFile` / `.serviceExists` | 404 / 500 / 409 | Homepage `services.yaml` |
| `agent.backup.notFound` | 404 | Unknown backup check |
| `agent.uptime.notConnected` / `.rejected` / `.timeout` / `agent.uptime.monitor.notFound` | 503 / 400 / 504 / 404 | Uptime Kuma bridge |
| `agent.control.disabled` | 403 | `control` feature is off |
| `agent.control.sessionRequired` | 403 | Missing, expired or foreign control token |
| `agent.control.busy` | 409 | Another device holds control (`params.device`) |
| `agent.control.indicatorFailed` | 503 | PC indicator couldn't be shown; session not opened |
| `agent.control.rateLimited` | 429 | Rate limit exceeded |
| `agent.desktop.noDisplay` / `.noHyprland` | 503 | No Wayland display / Hyprland not reachable |
| `agent.desktop.hyprctlFailed` | 502 | `hyprctl` returned unusable output |
| `agent.desktop.badAddress` / `.windowNotFound` / `.windowNotVisible` | 400 / 404 / 409 | Window address errors |
| `agent.desktop.monitorNotFound` | 404 | Unknown monitor name |
| `agent.desktop.appNotFound` / `.iconNotFound` | 404 | Unknown `.desktop` app / no icon |
| `agent.desktop.thumbFailed` / `.screenshotFailed` / `.clipboardFailed` | 502 | Capture or clipboard failed |
| `agent.desktop.badUrl` | 400 | Only http(s), max 4096 characters, no spaces or control characters |
| `agent.desktop.badKey` / `.badText` / `.inputFailed` | 400 / 400 / 502 | Input rejected or `ydotool`/`wtype` failed |
| `agent.desktop.streamFailed` | - | Live screen capture failed (WebSocket message only) |
| `agent.media.noPlayer` / `.noArt` / `.failed` / `.volumeFailed` | 404 / 404 / 502 / 502 | Media control |
| `agent.sunshine.notInstalled` | 404 | Sunshine not found |
| `agent.sunshine.noCredentials` / `.setupRequired` / `.unauthorized` / `.forbidden` / `.noPendingPairing` | 409 | Sunshine state or credential problems |
| `agent.sunshine.badPin` / `.badRequest` / `.pairFailed` | 400 | Pairing input or result |
| `agent.sunshine.unreachable` / `.apiFailed` / `.certMismatch` / `.unitFailed` | 502 | Sunshine API or unit failure |
| `agent.sunshine.timeout` | 504 | Sunshine API timeout |
| `agent.browser.notConnected` | 503 | Firefox extension not connected |
| `agent.browser.timeout` | 504 | Extension didn't reply within 5 s |
| `agent.browser.permissionRequired` | 403 | Optional "page content" permission not granted |
| `agent.browser.tabNotFound` / `.noMedia` / `.noInput` / `.noArticle` | 404 | Page operation target missing |
| `agent.browser.badUrl` / `.badRequest` | 400 | Invalid input |
| `agent.browser.passwordField` | 409 | Refused to type into a password field |
| `agent.browser.unsupported` | 422 | Privileged or non-web page |
| `agent.browser.failed` | 502 | Other extension error |
| `agent.ui.helperMissing` | 503 | `python3-gi` / AT-SPI not available |
| `agent.ui.a11yBus` | 503 | Accessibility bus not reachable |
| `agent.ui.helperFailed` / `.failed` | 502 | Helper crashed / operation failed |
| `agent.ui.timeout` | 504 | Helper request took longer than 5 s |
| `agent.ui.stale` | 409 | Snapshot generation outdated: fetch a new snapshot |
| `agent.ui.unsupported` | 422 | No accessibility tree (or a private browsing window) |
| `agent.ui.confirmRequired` | 409 | Typing into a password field needs `confirm: true` |
| `agent.ui.noAction` | 400 | The node has no matching action |
| `agent.claude.session.notFound` / `.permission.notFound` / `.schedule.notFound` | 404 | Unknown id |
| `agent.claude.unknownProfile` | 400 | Profile id not in `claude.profiles` |
| `agent.claude.folderNotFound` / `.folderNotAllowed` | 404 / 403 | Working directory |
| `agent.claude.notGitRepo` / `.worktreeFailed` | 400 / 502 | `worktree: true` errors |
| `agent.claude.sessionStopped` | 409 | Session no longer running |
| `agent.claude.bypassNeedsNewSession` | 400 | `bypassPermissions` can't be switched on in a running session |
| `agent.claude.pcModeFixed` / `.notPcSession` / `.pcUnavailable` | 400 / 400 / 403 | PC session errors |
| `agent.claude.confirmRequired` | 400 | Takeover without confirmation |
| `agent.claude.terminalNotFound` / `.terminalBusy` / `.terminalStuck` | 404 / 409 / 504 | Terminal takeover |
| `agent.claude.historyNotFound` / `.shotNotFound` | 404 | Transcript / screenshot missing |
| `agent.claude.tooManySchedules` / `.scheduleRunning` | 400 / 409 | Schedules (max 50) |

## Endpoints

Shapes are summarized. The zod schemas in the linked source files are authoritative.

### Always available

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| GET | `/v1/health` | **none** | `{name, version, features}`. Also used by `watch`. |
| GET | `/v1/agent/status` | token | `{version, startedAt, uptimeSeconds, memory: {agentBytes, childrenBytes}, unexpectedRestarts24h, lastUnexpectedAt}` |
| GET | `/v1/config` | token | Redacted config (see [configuration.md](configuration.md#editing-from-the-app)) |
| PATCH | `/v1/config` | token | Strict partial update → `{config, restartRequired}` |
| GET | `/v1/devices` | token | `{devices: [{id, name, createdAt}]}` |
| DELETE | `/v1/devices/:id` | token | Revoke one device and its push endpoint |
| POST | `/v1/devices/revoke-all` | token | `{confirm: true}`. Revokes **every** device, including the caller. |
| PUT | `/v1/push/endpoint` | token | `{url, pubKey?, auth?}`. Registers this device's push endpoint (replaces any previous one). |
| POST | `/v1/push/test` | token | Sends `push.test` → `{sent: n}` |
| GET | `/v1/events?since=ISO&limit=1..500` | token | `{events: [{id, at, key, params, link, source, device?}]}`, newest first |
| POST | `/v1/events` | token | Strict `{key, params?, link?}` → `{event}`. Used by the app to log actions it performs over SSH (`source: "app"`). `key` looks like `area.name`; at most 16 params, string values up to 500 characters; `link` must be a `tiphys://` URL. |
| GET | `/v1/audit?limit=1..1000` | token | `{entries: [{at, device, method, path, status}]}`, newest first |

### system

Feature `system` (`routes/system.ts`, `routes/processes.ts`).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/system` | `{hostname, os, kernel, uptimeSeconds, cpu, memory, disks[], gpus[]}`, cached for 2 s |
| GET | `/v1/processes?sort=cpu\|mem&limit=1..500` | `{total, processes: [{pid, ppid, user, cpuPercent, memPercent, rssBytes, elapsedSeconds, name, command}]}` |
| POST | `/v1/processes/:pid/signal` | `{signal: TERM\|KILL\|INT\|HUP, confirm: true}`. PID must be ≥ 2 and not the agent itself. |

### services

Feature `services` (`routes/services.ts`). `:scope` is `user` or `system`.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/services/:scope` | `{scope, units: [{unit, load, active, sub, description}]}`, `.service` units only |
| POST | `/v1/services/:scope/:unit/:action` | `action`: `start`, `stop` or `restart` |
| GET | `/v1/services/:scope/:unit/logs?lines=1..2000` | `{unit, entries: [{timeUs, priority, message}]}` from `journalctl` |

### docker

Feature `docker` (`routes/docker.ts`).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/docker/containers` | `{containers: [{id, name, image, state, status, project, cpuPercent, memory}]}` |
| POST | `/v1/docker/containers/:id/:action` | `start`, `stop` or `restart` |
| GET | `/v1/docker/containers/:id/logs?tail=1..5000` | `{id, lines: [{time, stream, message}]}` (stdout and stderr merged by timestamp) |

Compose operations are done by the app over SSH, not through this API. See [System](../features/system.md).

### power

Feature `power`. `POST /v1/power/:action` with `{confirm: true}`, where `action` is `reboot`, `poweroff` or `suspend`. Responds `{ok, action}` first; `systemctl` runs 1.5 s after the response has been sent.

### wake

Feature `wake`. `GET /v1/wake` returns `{targets: [{hostId}]}`. `POST /v1/wake/:hostId` sends the magic packet.

### ports

Feature `ports` (`routes/ports.ts`).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/ports` | `{host, ports: [{port, address, process, pid, localOnly, shared, url, reserved}]}` |
| POST | `/v1/ports/:port/share` | Localhost-only port → `tailscale serve --bg --https=PORT`. Returns `{ok, url}`. |
| DELETE | `/v1/ports/:port/share` | Removes the share |

### transcribe

Feature `transcribe`. `POST /v1/transcribe` with `{data: base64 (≤ 30 MB), ext: m4a|aac|mp3|wav|ogg|opus|webm, language?: tr|en, model?: small|large-v3}` → `{text}`. Timeout 10 minutes.

### git

Feature `git` (`routes/git.ts`). Every `path` must resolve inside `allowedRoots`, and the same check is applied to the repository root. Git runs with `GIT_TERMINAL_PROMPT=0`, so a missing credential fails at once instead of hanging.

| Method | Path | Body / query | Response |
| --- | --- | --- | --- |
| GET | `/v1/git/status` | `path` | `{root, branch, upstream, ahead, behind, head, files: [{path, origPath, index, worktree, untracked, conflicted}]}` |
| GET | `/v1/git/diff` | `path, file?, staged?, head?, commit?` | `{diff, truncated}` (max 512 KB) |
| GET | `/v1/git/log` | `path, limit?` | `{commits[]}` |
| GET | `/v1/git/branches` | `path` | `{branches: [{name, current, remote, upstream, date}]}` |
| POST | `/v1/git/stage` | `{path, files[], stage: bool}` | `{ok}` |
| POST | `/v1/git/discard` | `{confirm: true, path, files[], source?: index\|head, deleteNew?}` | `{ok, restored?, deleted?}` |
| POST | `/v1/git/commit` | `{path, message, all?, files?}` | `{ok, hash}`, plus a `git.committed` event |
| POST | `/v1/git/push` · `/pull` · `/fetch` | `{path, setUpstream?}` | `{ok, output}`. Pull is `--ff-only`. Push logs a `git.pushed` event. |
| POST | `/v1/git/checkout` | `{path, branch, create?}` | `{ok}` |

### homepage

Feature `homepage` (`routes/homepage.ts`).

- `GET /v1/homepage` returns `{checkedAt, groups: [{name, services: [{…, status, responseMs}], groups}]}`. Results are cached for 30 s.
- `POST /v1/homepage/services` takes `{group, name, href, description?, icon?, siteMonitor?}` and appends the service to `services.yaml`, keeping comments and layout.

### desktop

Feature `desktop`. These endpoints target a Wayland session; window management requires Hyprland. Endpoints marked **C** also need the `control` feature and an `X-Tiphys-Control` token.

#### Clipboard, screenshot, open

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/desktop/clipboard` | `{text}` (`wl-paste`, text only, at most 1 MB) |
| PUT | `/v1/desktop/clipboard` | `{text}` (`wl-copy`). Text that arrived from the phone is not echoed back as a sync notification. |
| GET | `/v1/desktop/screenshot?scale=0.1..1` | `image/png` (`grim`) |
| POST | `/v1/desktop/open` | `{url}`. Opens a new tab through the Firefox bridge if it is connected, otherwise `xdg-open`. Only http(s) URLs are allowed. |

#### Media

`routes/media.ts`. Uses `playerctl` (MPRIS) and `wpctl` (PipeWire).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/media?player=` | Player state. If no player is running, the response is 200 with an empty player list, not an error. |
| POST | `/v1/media/:action` | `play-pause`, `play`, `pause`, `next`, `previous`, `seek` or `position`. Body `{player?, seconds?}`. Returns the new state. |
| GET / PUT | `/v1/media/volume` | `{percent: 0..150, muted}` |
| GET | `/v1/media/art?player=` | Local (`file://`) cover art, at most 5 MB. Strict query: no path parameter is accepted. |

#### Windows and apps

`routes/hypr.ts`.

| Method | Path | C | Description |
| --- | --- | --- | --- |
| GET | `/v1/desktop/windows` | | `{hyprland, activeWorkspace, monitors[], workspaces[], windows: [{address, class, title, workspace, at, size, floating, fullscreen, pinned, focused, visible, appId}]}` |
| GET | `/v1/desktop/windows/:address/thumb?w=64..800` | | WebP (or PNG) thumbnail of a visible window |
| GET | `/v1/desktop/apps?lang=tr\|en` | | Launchable `.desktop` apps |
| GET | `/v1/desktop/apps/:id/icon?size=48..256` | | PNG or SVG icon |
| POST | `/v1/desktop/windows/:address/:action` | C | `focus`, `close`, `fullscreen`, `float`, `pin` or `move-to-workspace` (body `{workspace: 1..100}`) |
| POST | `/v1/desktop/workspace/:n` | C | Switch to workspace 1–100 |
| POST | `/v1/desktop/dpms/:state` | C | `on` or `off` |
| POST | `/v1/desktop/apps/:id/launch` | C | Launch a listed app through Hyprland (`gtk-launch` must be installed) |

#### Sunshine

`routes/sunshine.ts`.

- `GET /v1/desktop/sunshine` returns the status: `installed`, `unit`, `enabled`, running state, `capture`, `encoder`, `credentials`, `api`, `pairedClients`, `pendingPairings`, `hostName`. It needs `desktop` only.
- `POST /v1/desktop/sunshine/:action` (C) takes `start`, `stop` or `pair`. `pair` takes `{pin: "dddd", name?}` and sends the Moonlight PIN to Sunshine's web API. The PIN is never logged or included in error params.

#### Firefox bridge

`routes/browser.ts`. All routes except the status route are **C**: tab titles and URLs count as browsing history. The `page.*` operations also need the extension's optional "page content" permission. See [Firefox bridge](../features/firefox-bridge.md).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/desktop/browser` | `{connected, version, ext, permissions: {content}}` |
| GET | `/v1/desktop/browser/tabs` | `{tabs: [{id, windowId, index, title, url, pinned, audible, muted, active, lastAccessed, favicon}]}` |
| POST | `/v1/desktop/browser/tabs` | `{url}` → `{ok, id, focused}` |
| POST | `/v1/desktop/browser/tabs/close` | `{ids: [..≤200]}` |
| POST | `/v1/desktop/browser/tabs/:id/:action` | `activate`, `close`, `reload`, `back`, `forward`, `pin` (toggle) or `mute` (toggle). `activate` also raises the Firefox window and returns `focused`. |
| POST | `/v1/desktop/browser/restore` | Reopen the last closed tab or window |
| GET | `/v1/desktop/browser/tabs/:id/reader` | Reader-mode article (Readability) |
| POST | `/v1/desktop/browser/tabs/:id/media` | `{action: play\|pause\|toggle\|seek\|rate, seconds?, rate?: 0.25..4}` |
| POST | `/v1/desktop/browser/tabs/:id/scroll` | `{fraction: -10..10}` (in viewport heights) |
| POST | `/v1/desktop/browser/tabs/:id/text` | `{text: ≤10000}`, typed into the focused field (never a password field) |
| GET | `/v1/desktop/browser/events` | SSE: `status`, `tabs` (see [SSE](#server-sent-events)) |

#### Mobile view (AT-SPI)

`atspi.ts`. All routes except `DELETE` are **C**. The window must be visible. Node ids are only valid together with the `gen` of the snapshot they came from; a mismatch returns `409 agent.ui.stale`. See [Remotes and mobile view](../features/remotes-and-mobile-view.md).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/desktop/ui?address=0x…` | Snapshot `{address, class, gen, title, partial, nodes: [{id, parent, depth, role, name, desc, states, value, text, password?, actions}]}` |
| DELETE | `/v1/desktop/ui` | Close the view → `{closed}` (no control token needed) |
| POST | `/v1/desktop/ui/act` | `{address, gen, id, op?: action\|focus\|select, action?}` |
| POST | `/v1/desktop/ui/text` | `{address, gen, id, text, confirm?}` → `{ok, typed}`. `typed: true` means the agent used the keyboard fallback after confirming focus. Password fields need `confirm: true`. |
| POST | `/v1/desktop/ui/value` | `{address, gen, id, value}` (sliders, spin buttons) |
| GET | `/v1/desktop/ui/events?address=` | SSE: `changed`, `closed` |

#### Live screen

`GET /v1/desktop/stream` (WebSocket, **C**). The feature, the control token and the query are all checked **before** the upgrade, so failures come back as normal HTTP errors. Protocol: [Live screen WebSocket](#live-screen-websocket).

### claude

Feature `claude` (`claude/routes.ts`, `claude/schedules.ts`). See [Claude](../features/claude.md).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/claude/sessions?profileId=` | `{live: [summary], terminal: [...], history: [...]}`. `terminal` lists sessions running in a terminal outside Tiphys. |
| POST | `/v1/claude/sessions` | Strict `{cwd, prompt?, images?: [{mediaType, data}] (≤10), profileId?, model?, effort?: low\|medium\|high\|xhigh\|max, permissionMode?: default\|acceptEdits\|plan\|bypassPermissions, resume?: uuid, worktree?, kind?: code\|pc}` → summary. `kind: "pc"` requires a control token. |
| GET | `/v1/claude/sessions/:id?after=SEQ` | `{session, events}` |
| POST | `/v1/claude/sessions/:id/messages` | Strict `{text, images?, clientId?}` → `{ok, duplicate}`. `clientId` makes retries idempotent. |
| POST | `/v1/claude/sessions/:id/interrupt` | Stop the current turn |
| POST | `/v1/claude/sessions/:id/permissions/:requestId` | Strict `{allow, message?}`. Answers a permission request; this is also what the notification action buttons call. |
| POST | `/v1/claude/sessions/:id/mode` | `{permissionMode}` → summary |
| POST | `/v1/claude/sessions/:id/control` | Rebind a PC session to the caller's current control token |
| DELETE | `/v1/claude/sessions/:id` | Close the session |
| GET | `/v1/claude/sessions/:id/stream?after=SEQ` | WebSocket, see [below](#claude-session-websocket) |
| POST | `/v1/claude/terminal/:sessionId/takeover` | Strict `{confirm: true, profileId?, model?, effort?, permissionMode?}`. Only works while the terminal session is idle. Stops the terminal `claude` and resumes the same session in the agent. |
| GET | `/v1/claude/history/:sdkSessionId?profileId=&skip=&limit=` | Transcript page (limit ≤ 1000) |
| GET | `/v1/claude/commands?cwd=&profileId=` | `{commands: [{name, description, argumentHint}]}`, cached for 10 minutes |
| GET | `/v1/claude/shots/:shotId` | PC session screenshot (`image/jpeg`) |
| GET | `/v1/fs/dirs?path=` | Folder picker inside `allowedRoots`: `{path, home, dirs: [{name, path}]}` |
| GET / POST | `/v1/claude/schedules` | List / create. Body: strict `{name, cwd, prompt, when, permissionMode?, model?, effort?, profileId?, enabled?}`. |
| PUT / DELETE | `/v1/claude/schedules/:id` | Update / delete |
| POST | `/v1/claude/schedules/:id/run` | Run now → `{schedule, sessionId}` |

`when` takes one of three forms: `{kind: "daily", time: "HH:MM"}`, `{kind: "weekly", time, days: [1..7]}` (1 = Monday) or `{kind: "interval", everyMinutes: ≥15}`.

A session summary has these fields: `{id, epoch, sdkSessionId, cwd, title, status: starting|running|waiting|idle|error|stopped, model, permissionMode, profileId, costUsd, contextTokens, contextWindow, createdAt, lastActivity, pendingPermissions, live, kind, control?}`.

For PC sessions, only the device holding the bound control session may send messages, answer permissions or change the mode.

### watch

Feature `watch`. `GET /v1/watch` returns `{hosts: [{hostId, online, lastOk, since}]}`.

### alerts

Feature `alerts`. `GET /v1/alerts` returns `{active: ["disk:/", "service:user/foo.service", "grafana:Name", …]}`.

### backups

Feature `backups` (`backups.ts`).

- `GET /v1/backups` returns `{intervalMinutes: 15, checks: [{…check, state: {status, lastAt, sizeBytes, target, detail, running, checkedAt}}]}`.
- `POST /v1/backups/:id/check` re-evaluates one check immediately.

### uptime

Feature `uptime` (`uptime/bridge.ts`). The agent keeps a Socket.IO connection to Uptime Kuma and serves plain REST to the app.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/uptime/state` | `{connected, loggedIn, error}` |
| GET | `/v1/uptime/monitors` | `{state, monitors}` |
| GET | `/v1/uptime/monitors/:id` | Monitor detail |
| GET | `/v1/uptime/monitors/:id/beats?hours=1..2160` | `{beats: [{status: 0 down\|1 up\|2 pending\|3 maintenance, time, msg, ping}]}` |
| POST | `/v1/uptime/monitors` | Strict `{name, type?: http\|keyword\|ping\|port, url?, hostname?, port?, keyword?, interval?, alertAfterSeconds?, timeout?, acceptedStatusCodes?, certExpiry?}` → `{id}` |
| PATCH / DELETE | `/v1/uptime/monitors/:id` | Edit (partial) / delete |
| POST | `/v1/uptime/monitors/:id/pause` · `/resume` | Pause / resume |
| GET / POST | `/v1/uptime/maintenance` | List / create `{title, monitorIds, start, end}` |
| DELETE | `/v1/uptime/maintenance/:id` | Delete |

## Protocols

### Live screen WebSocket

`GET /v1/desktop/stream` (`routes/stream.ts`, `h264.ts`, `desktop_input.ts`, `focus.ts`). The client sends the device token and the `X-Tiphys-Control` header with the upgrade request.

**Query parameters**

| Name | Default | Range | Meaning |
| --- | --- | --- | --- |
| `codec` | `mjpeg` | `mjpeg`, `h264` | H.264 uses `h264_nvenc` (NVIDIA). If no keyframe arrives within 4 s, the stream falls back to MJPEG. |
| `fps` | 12 | 1–30 | MJPEG is capped at 20. |
| `scale` | 0.6 | 0.25–1 | Output width is capped at 2560 px; dimensions are rounded to even numbers. |
| `q` | 70 | 10–95 | MJPEG quality |
| `kbps` | 2000 | 100–20000 | H.264 target bitrate |
| `monitor` | focused monitor | name | Monitor to capture |
| `window` | - | `0x…` address | Capture a single visible window (clipped to its monitor) |

Capture runs `wf-recorder` (wlr-screencopy). If it is missing or produces no frames, the agent falls back to a `grim` loop (at most 4 fps, MJPEG only) and sends a notice. Only one stream per device can be open; a new one closes the old one with code `4409`.

**Binary frames (server → client)**: a 16-byte big-endian header followed by the payload.

| Offset | Size | Field |
| --- | --- | --- |
| 0 | 1 | `flags`: `0x10` H.264, `0x01` keyframe (IDR), `0x02` config (SPS+PPS). `0` means a JPEG frame. |
| 1 | 3 | `seq`, 24-bit frame counter |
| 4 | 8 | `ts`, float64 milliseconds since the Unix epoch |
| 12 | 2 | `width` |
| 14 | 2 | `height` |
| 16 | … | Payload: one complete JPEG, or one H.264 access unit in Annex-B with 4-byte start codes |

For H.264, a separate config message (`0x12`) is sent before every IDR. Frames are skipped while the socket buffer is full; for H.264, nothing more is sent until the next IDR. MJPEG frames identical to the previous one (static screen) are not sent.

**Text messages (server → client)**

| `type` | Fields |
| --- | --- |
| `hello` | `width, height, region {x,y,w,h}, monitor, fps, scale, q, codec, kbps, source: wf-recorder\|grim, cursor {x,y}\|null`. Sent again after each restart triggered by a quality change. |
| `focus` | `address, class, initialClass, title, pid, workspace, appId`. Sent after `hello` and whenever the focused window changes; the app uses it to pick a remote profile. |
| `stats` | `codec, sent, skipped, dropped, bytes, waited`, sent periodically |
| `notice` | `code: agent.desktop.codecFallback` (`codec: "mjpeg"`) or `agent.desktop.streamFallback` (`fps`) |
| `error` | `code` (for example `agent.request.invalid`, `agent.desktop.badKey`, `agent.control.rateLimited`, `agent.desktop.inputFailed`) |
| `pong` | `t` (echo of the client's value), `at` |

**Text messages (client → server)**

| Message | Meaning |
| --- | --- |
| `{type:"ping", t}` | Latency probe |
| `{type:"keyframe"}` | H.264: request an IDR. Waits for the next one, or restarts the encoder if it is far away. |
| `{type:"quality", fps?, scale?, q?, kbps?, codec?}` | Restarts capture with the new values. At most 6 per 10 s. |
| `{type:"move", x, y, w?, h?}` | Move the pointer. `x`/`y` are image pixels; `w`/`h` give the frame size they refer to. |
| `{type:"click", button?: left\|right\|middle, count?: 1..3, x?, y?, w?, h?}` | Click, moving first if coordinates are given |
| `{type:"down"\|"up", button?}` | Press or release a button. Buttons still held when the socket closes are released. |
| `{type:"scroll", dx?, dy?}` | Wheel, -20..20; `dy > 0` scrolls down |
| `{type:"key", key, mods?: [ctrl, alt, shift, super]}` | Key from the allowed table only: Esc, Tab, Enter, Backspace, Delete, Insert, Space, arrow keys, Home/End/PageUp/PageDown, F1–F12, Super, PrintScreen, KPPlus, KPMinus. Letters and digits are allowed only with Ctrl, Alt or Super. |
| `{type:"text", text}` | Typed with `wtype` (layout-independent), at most 2000 characters; no control characters except `\n` and `\t` |
| `{type:"wait", ms: 0..1000}` | Pause inside an input sequence. Input events run in order. |

Every input event re-checks the control token and counts toward the 60/s limit. Keystrokes and text are never logged.

**Close codes**

| Code | Meaning |
| --- | --- |
| `4400` | Start failed (an `error` message is sent first) |
| `4401` | Control session ended, token changed, or `control` turned off |
| `4409` | Replaced by a newer stream from the same device |
| `4502` | Capture failed |
| `4503` | No display |
| `1001` | Agent shutting down |

### Claude session WebSocket

`GET /v1/claude/sessions/:id/stream?after=SEQ`. The first message is `{kind:"hello", seq:0, epoch, lastSeq}`. If `epoch` differs from what the app remembers, the agent has restarted and the app reloads the session. After that come the buffered events with `seq > after`, then live events, each as one JSON text message `{seq, at, kind, …}`:

`user`, `text`, `delta` (streaming text), `thinking`, `tool_use {id, name, input}`, `tool_result {toolUseId, text, isError, shot?}`, `init {model, cwd, permissionMode, slashCommands}`, `result {ok, subtype, text, costUsd, turns, durationMs, contextTokens, contextWindow}`, `permission {requestId, toolName, input, reason}`, `permissionResolved {requestId, allow}`, `control {active, expiresAt, reason}` (PC sessions), `status {status}`, `error {message}`, `restored`, `compacted`.

The server pings every 25 s. An unknown session closes with code `4404`.

### Server-sent events

Both streams use the standard `event:` / `data:` format with keep-alive comments (`: ping`) every 25 s. Both close when the control session ends, the token changes, or `control` is turned off.

- **`/v1/desktop/browser/events`**: `event: status` (data: the bridge status object) and `event: tabs` (data: `{tabs: [...]}`). If the client reads slowly (more than 256 KB buffered), intermediate tab lists are dropped and only the latest is sent. The connection is cut when the buffer reaches 2 MB.
- **`/v1/desktop/ui/events`**: `event: changed` (data `{}`; the client fetches a new snapshot) and `event: closed` (data `{}`, sent when the view closes). Page content is never sent over this stream.

### Firefox native messaging

Components: the extension (`firefox/src/background.js`, `firefox/src/lib/protocol.js`), a native host started by Firefox (`agent/src/firefox_host.ts`), and the agent's socket (`agent/src/browser_bridge.ts`).

```
Firefox extension ⇄ (stdio) native host "dev.tiphys.bridge" ⇄ (unix socket) agent
                                                  $XDG_RUNTIME_DIR/tiphys/firefox.sock
```

- **Framing** (`firefox_frame.ts`): a 4-byte length in **native byte order**, followed by UTF-8 JSON. The same framing is used on both legs, and the host forwards payloads without parsing them. The maximum is 1 MB per message: the host skips oversized messages from Firefox, and an oversized message from the agent breaks the connection.
- **Socket security**: the directory has mode `0700` and must be owned by the user and not be a symlink; the socket has mode `0600`. If another live agent already holds the socket, the bridge is not started.
- **Host → extension**: `{type:"host", agent: true|false}` when the agent socket connects or disconnects. While it is disconnected, the host retries every 5 s and drops messages from the extension.
- **Handshake**: within 5 s of connecting, the extension sends `{type:"hello", version: 1, ext, permissions: {content}}`. If the version is wrong, the agent replies `{type:"error", code:"version", supported: 1}`. If another extension connection is already live, it replies `{type:"error", code:"busy"}` and keeps the existing one. After a rejection the extension retries with a backoff from 5 s up to 10 min.
- **Requests** (agent → extension): `{type:"req", id, op, args}`. Ops: `tabs.list`, `tabs.create {url}`, `tabs.activate|reload|back|forward|pin|mute {id}`, `tabs.close {ids}`, `sessions.restore`, `page.reader {id}`, `page.media {id, action, seconds?, rate?}`, `page.scroll {id, fraction}`, `page.text {id, text}`.
- **Responses**: `{type:"res", id, ok: true, result}` or `{type:"res", id, ok: false, error: code}`. The error codes are `tabNotFound`, `badUrl`, `permissionRequired`, `passwordField`, `noMedia`, `noInput`, `noArticle`, `unsupported`, `badRequest` and `failed`; the agent maps them to `agent.browser.<code>`. The agent waits 5 s for a reply before returning `agent.browser.timeout`.
- **Events** (extension → agent): `{type:"event", name:"tabs", tabs}` (tab changes are coalesced over 300 ms; the list is shrunk to stay under 900 KB) and `{type:"permissions", permissions: {content}}`.
- **Privacy**: private-window tabs are never listed or touched. Only http, https, file and about URLs are reported. Remote favicons are not fetched. Form values are not read. URLs, titles and page text pass only through memory and are never logged.

### AT-SPI helper

`agent/helpers/atspi_helper.py` is run with `python3 -I` and needs PyGObject with the Atspi typelib. Protocol version 1 uses JSON lines on stdin/stdout, with a maximum of 4 MB per line on the agent side. The helper runs only while a mobile view (or a Claude PC session's `ui_*` tool) is active; it is stopped after 60 s idle, when control ends, and when the agent shuts down. Each request times out after 5 s, and a timeout kills the helper. If the helper crashes, it is restarted once.

- **Events (helper → agent)**: `{"event":"hello","version":1}` on startup; `{"event":"changed"}` (coalesced over 300 ms); `{"event":"fatal","code":"helperMissing"}` when Atspi isn't available (the helper then exits).
- **Requests**: `{"id": n, "cmd": "snapshot", "pid", "title"}`; `{"id", "cmd": "act", "gen", "node", "action"}`; `{"id", "cmd": "set_text", "gen", "node", "text", "confirm", "typing"}`; and `focus`, `select`, `set_value {value}`, `is_focused`, each with `{gen, node}`. `node` is a path of child indices from the window root (for example `"3.0.1"`).
- **Responses**: `{"id": n, "ok": true, …}` or `{"id": n, "error": {"code": "stale|unsupported|confirmRequired|noAction|badRequest|failed"}}`.
  - `snapshot` returns `{gen, title, partial, nodes}`. A snapshot is capped at 1500 nodes, depth 40 and 1.5 s; only showing and visible nodes are included, and text is clipped to 200 characters.
  - `set_text` returns `{needsTyping}`.
  - `is_focused` returns `{focused}`.
- **Agent rules**: the generation number the client sees is the agent's own, so it stays valid across helper restarts. Before an action, the agent checks that the window is still visible. Firefox private windows are refused. While a view is open, `org.a11y.Status.IsEnabled` is set to true, and the previous value is saved in `a11y-state.json`.
- **Privacy**: password-field text is never read. Snapshots are never written to disk or logs; only `ui.opened {class}` goes to the event log.
