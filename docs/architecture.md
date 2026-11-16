# Architecture

## Components

| Component | Where it runs | Role |
|---|---|---|
| **Tiphys app** (`app/`) | Android phone | The whole UI. It holds settings, secrets, the SSH client and integration clients (Grafana, Dozzle, Uptime Kuma via agent, Homepage, Obsidian links). It receives push and talks to agents. |
| **Agent** (`agent/`) | Each Linux machine you want to control | Fastify HTTP/WebSocket/SSE service. Runs Claude sessions, reads system state, controls the desktop, sends notifications. Each machine enables only the features it needs. |
| **Firefox bridge** (`firefox/`) | Firefox on the PC | MV3 extension. Exposes tabs and (with optional permission) page content to the local agent over native messaging. Makes no network requests. |
| **AT-SPI helper** (`agent/helpers/atspi_helper.py`) | PC, started on demand by the agent | Reads the accessibility tree of one window and performs actions on it, for the mobile view and Claude's `ui_*` tools. |
| **Your services** (optional) | Anywhere in the tailnet | ntfy (push), Grafana, Dozzle, Uptime Kuma, Homepage, Sunshine, Scriberr/Whisper (voice). |

The phone reaches agents and services directly over Tailscale. Terminal, file browser, Compose stacks and log
search use SSH from the phone, so they also work on hosts without an agent and while the PC is off.

## Repository layout

```
agent/
  src/cli.ts              CLI entry point: serve, init, pair, devices, revoke, schema, run, firefox, vscode-a11y
  src/server.ts           Fastify app: auth hook, error mapping, route registration per feature flag
  src/modules.ts          heavy/optional modules loaded only when their flag is on (claude, watch, alerts, backups, uptime)
  src/config.ts           agent.json schema (Zod) and atomic store
  src/auth.ts             device tokens (tph_…), SHA-256 hashes, Tailscale login check
  src/control.ts          control sessions: token, expiry, PC indicator, rate limits
  src/claude/             Claude Agent SDK sessions, PC tools (pc.ts), schedules, terminal sessions, transcripts
  src/routes/             one file per area (system, git, desktop, hypr, stream, sunshine, browser, media, ports, …)
  src/stream / h264.ts    live screen (MJPEG / H.264 Annex-B parsing)
  src/atspi.ts            mobile view service around the Python helper
  src/browser_bridge.ts   unix socket for the Firefox bridge; firefox_host.ts is the native-messaging host
  src/profile/schema.ts   Zod definition of the phone's profile file (→ schema/tiphys.schema.json)
  helpers/                atspi_helper.py
  test/                   vitest suites (+ test/py for the Python helper)
app/
  lib/core/               agent client, SSH, profile codec/merge, secrets, push, vault, integrations
  lib/features/           one folder per screen area (claude, desktop, terminal, files, git, system, monitoring, …)
  lib/l10n/               app_en.arb, app_tr.arb (+ generated code in gen/)
  packages/tiphys_native/ small Android plugin: H.264 MediaCodec decoder, sensitive clipboard, FLAG_SECURE, intents
  test/                   unit, widget and golden tests; test/integration = real-server tests (tag "real")
firefox/
  src/                    manifest.json, background.js, lib/protocol.js, content/page.js, popup/, vendor/Readability.js
  scripts/                vendor.mjs (copies + verifies Readability), build.mjs (deterministic unsigned XPI)
schema/tiphys.schema.json profile JSON Schema (generated)
tiphys.example.json       example profile
tools/                    deploy-agent.sh, pair.sh, setup-dev.sh, limited.sh, sync-schema.sh, logo/, uptime-kuma/
```

## Request and authentication flow

```
phone ──HTTPS──▶ tailscale serve (:7443, tailnet only) ──HTTP──▶ agent 127.0.0.1:7443
                 adds Tailscale-User-Login header             │
                                                              ├─ onRequest hook (all routes except /v1/health):
                                                              │    1. if requireTailscaleLogin is set: header must match
                                                              │    2. Bearer token (or ?token= for WebSocket/SSE) → SHA-256
                                                              │       → constant-time compare with stored device hashes
                                                              ├─ route is registered only if its feature flag is on
                                                              ├─ desktop-changing routes: + X-Tiphys-Control session token
                                                              └─ onResponse: non-GET requests → audit.jsonl
```

- Errors are returned as **codes**, not text: `{"error": {"code": "agent.git.noUpstream", "params": {…}}}`. The app
  translates them into the selected language. The same applies to notifications: the agent sends a key and
  parameters, and the phone renders the text.
- Flags are read when the agent starts. Changing a feature flag requires a restart. Exception: `control` is
  also checked live, so turning it off ends an open control session immediately.
- The app compares the agent's `version` from `/v1/health` with the version it expects and warns when an agent is
  older.

## Control sessions

Desktop-changing endpoints (window actions, workspace, DPMS, app launch, live-screen input, Sunshine start/stop/pair,
Firefox tabs, mobile view, Claude PC sessions) need:

1. the `desktop` and `control` feature flags,
2. a control session opened by the phone (`POST /v1/desktop/control/session`) after a biometric/PIN unlock,
3. the session token in `X-Tiphys-Control` on every request (re-checked on every WebSocket input event).

A session lasts 15 minutes by default. It can be extended, but never to more than 60 minutes remaining. Only one
session can exist at a time; another device gets `409`. Any paired device may stop it. While a session is open,
the agent shows a critical `notify-send` notification and switches the Hyprland active border to a red/orange
gradient. The previous border is saved to `control-indicator.json` and restored when the session ends, and also
on the next start after a crash. If the indicator cannot be set, the session is refused. Details:
[security.md](security.md#control-sessions).

## Profile file and sync

All app settings form one **profile**: hosts, keys (references only), integrations, Claude defaults, terminal,
files, quick actions, home layout, notifications, desktop remotes, and optionally a copy of each agent's
configuration (`agentConfigs`).

- On the phone it lives as `profile.json` in the app documents folder. Secret values are stored separately in
  Android Keystore-backed secure storage, and the profile refers to them as `secret:<id>`.
- Export/import uses `.tiphys.json` (`"format": "tiphys-profile"`, `schemaVersion`). The app migrates older
  versions forward and refuses newer ones. Partial files are valid and merge only the sections they contain.
  Import shows a preview of added/changed/removed items, then merges or replaces.
- **Plain export** contains no secrets. **Encrypted export** adds `encryptedSecrets`: the referenced secrets and the
  password vault, sealed with a passphrase (Argon2id → XChaCha20-Poly1305).
- The JSON Schema is generated from the agent's Zod definitions (`agent/src/profile/schema.ts` →
  `schema/tiphys.schema.json`) and copied into the app (`app/assets/profile/`) by `tools/sync-schema.sh`. Both sides
  validate the same format. The agent's own settings are not part of the phone profile. They live in `agent.json` on
  each machine and are edited through the agent API.

## Notifications pipeline

```
agent Notifier.send({key, params, link, priority, data})
  ├─ append to events.jsonl (unless "sensitive"; command lines reduced to the program name)
  └─ for each registered device endpoint:
       encrypt JSON with the phone's WebPush keys (RFC 8291, aes128gcm)   [sensitive notices: only to endpoints with keys]
       POST to the UnifiedPush endpoint on your ntfy server (Bearer push.token if set)
ntfy server ─▶ ntfy Android app (UnifiedPush distributor) ─▶ Tiphys (also wakes it in the background)
  └─ decrypt, render title/body in the selected language, show local notification with deep link (tiphys://…)
     action buttons: Allow/Deny for Claude permissions, Copy for PC clipboard, Stop/Extend for Claude PC sessions
```

The phone registers its endpoint and keys with every paired agent (`PUT /v1/push/endpoint`). No Google/Firebase
service is involved. Uptime Kuma sends its own plain ntfy notifications to a topic you subscribe to in the ntfy app.
See [features/notifications.md](features/notifications.md).

## Live screen pipeline

```
wf-recorder (wlr-screencopy) ──pipe──▶ agent ──WebSocket /v1/desktop/stream──▶ app
  MJPEG:  -c mjpeg, fps+scale filter    split into JPEG frames, drop identical frames (SHA-1)  → decoded to ui.Image
  H.264:  -c h264_nvenc, VBR, GOP 2 s   split Annex-B access units; SPS/PPS sent before IDR    → MediaCodec (tiphys_native) → Texture
  fallback: grim + ffmpeg loop (≤ 4 fps) when wf-recorder is missing; MJPEG when NVENC fails
input (same WebSocket, JSON): cursor via hyprctl, clicks/wheel via ydotool, keys via ydotool (allow-listed table), text via wtype
```

Each binary message has a 16-byte header (flags, sequence, timestamp, width, height). Under backpressure the agent
skips frames instead of queueing them. For H.264 it then waits for the next keyframe. The client reports quality
changes, and "Automatic" quality steps down on dropped frames or high round-trip time. While the stream is open the
agent also sends `focus` messages (the focused window's class, title and pid from Hyprland's event socket), which
drive the app-aware remote strip. See [features/desktop-control.md](features/desktop-control.md).

## Claude sessions

- Built on `@anthropic-ai/claude-agent-sdk`. Each session is one long-lived `query()` with a message queue, so new
  messages are queued while Claude is working. Sessions run in the agent, so closing the app does not stop them.
- Session metadata is saved to `claude-sessions.json`. After an agent restart, sessions come back idle with their
  history. The Claude process starts only with the first message. History is read from Claude Code's own transcript
  (`<config dir>/projects/…`) from the end, page by page.
- The live stream is a WebSocket with sequence numbers and an `epoch`. The app resumes from the last sequence it saw
  and reloads when the epoch changes. Messages carry a client id, and the agent ignores duplicates, so retries never
  send twice.
- **Offline outbox (app):** messages written without a connection are stored as
  `claude-outbox-<session>.json` in the app documents folder and sent in order when the connection returns.
- **Profiles:** `claude.profiles` maps names to Claude config folders (default `personal → ~/.claude`), so you can use
  several Claude accounts. Working folders must be inside `allowedRoots`.
- **Worktree sessions** run in a new git worktree next to the repository (`<repo>-tiphys-<id>`, branch `tiphys/…`).
- **Terminal sessions:** Claude Code processes running in a PC terminal are discovered via the config folder's
  `sessions/` files and `/proc`. They are shown read-only and can be taken over: the agent stops the terminal
  process and resumes the same session through the SDK.
- **Scheduled tasks** (`claude-schedules.json`): daily, weekly or interval schedules in the agent's local time zone.
  Missed runs are not made up.
- **PC sessions** (`kind: "pc"`) use an in-process MCP server (`tiphys_pc`) with screenshot, input, window, app,
  browser and accessibility tools only, bound to a control session. See
  [features/claude.md](features/claude.md) and [security.md](security.md#claude-pc-sessions).

## Firefox bridge

```
Firefox extension ⇄ native messaging (stdin/stdout, 4-byte length + JSON) ⇄ firefox-host (node dist/firefox_host.js)
  ⇄ unix socket $XDG_RUNTIME_DIR/tiphys/firefox.sock (dir 0700, socket 0600) ⇄ agent ⇄ /v1/desktop/browser… ⇄ app
```

Firefox starts the host itself. The manifest allows only the extension id `bridge@tiphys.dev`. There is no network
listener. Messages are limited to 1 MB.

## Data storage

**On each agent machine** (`~/.config/tiphys/`, next to `agent.json`; a different `--config` path moves all of them):

| File | Contents |
|---|---|
| `agent.json` (0600) | name, listen address, feature flags, device token **hashes**, push endpoints and ntfy token, integration credentials (Uptime Kuma, Grafana, Sunshine), allowed roots, Claude profiles |
| `audit.jsonl` (0600) | every non-GET request: time, device id, method, path, status. Rotated at 1 MB to `.1` |
| `events.jsonl` | event timeline (notifications, control sessions, backups, schedules, compose updates). Rotated at 2 MB |
| `agent-runs.json` | start/stop records used to detect unclean restarts |
| `claude-sessions.json`, `claude-schedules.json` | Claude session metadata and schedules |
| `claude-shots/` | screenshots taken by Claude PC sessions (last 60) |
| `control-indicator.json`, `a11y-state.json` | saved Hyprland border and accessibility-bus state, for crash recovery |

Other locations: `$XDG_RUNTIME_DIR/tiphys/firefox.sock`,
`~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json`, `~/.local/share/tiphys/firefox-host`. Claude Code keeps
its own transcripts in the profile's config folder (e.g. `~/.claude/projects`). They include screenshots from PC
sessions.

**On the phone:** `profile.json` and Claude outbox files in the app documents folder. Tokens, SSH keys, passwords and
the vault are kept in `flutter_secure_storage` (Android Keystore). Android backup and device-to-device transfer are
disabled. Moving to a new phone requires the encrypted profile export.

**On the build machine:** the release signing key in `~/.config/tiphys/release/`.
