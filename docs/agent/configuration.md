# Agent configuration

The Tiphys agent (`tiphys-agent`) runs once per machine (for example on the PC `argo` and on the server `atlas`). Everything it does is controlled by one JSON file, `agent.json`, plus a small set of CLI commands. This page is the reference for both.

For first-time setup see [Getting started](../getting-started.md). The HTTP API is documented in [api.md](api.md), and the threat model in [Security](../security.md).

## Location

| Source | Path |
| --- | --- |
| Default (Linux, macOS) | `~/.config/tiphys/agent.json` |
| Default (Windows) | `%APPDATA%\Tiphys\agent.json`; an older install's `%USERPROFILE%\.config\tiphys\agent.json` is kept and used if it exists |
| Environment | `TIPHYS_AGENT_CONFIG=/path/to/agent.json` |
| CLI flag | `tiphys-agent <command> --config /path/to/agent.json` (overrides both) |

macOS deliberately uses `~/.config/tiphys` too (not `~/Library/Application Support`): the same path as Linux in docs,
scripts and the installer.

The file is always written atomically (temp file and rename) with mode `0600`. Its directory is created with mode `0700`.
On Windows the mode bits have no effect: the file is protected only by the default ACL of your user profile
(`%APPDATA%` is readable by your account, administrators and SYSTEM). The agent sets no extra ACL. The agent writes its state files to the same directory (see [Files on disk](#files-on-disk)).

The file is validated with a zod schema (`agent/src/config.ts`) when it loads. If a field is invalid, the agent refuses to start. Missing optional sections get their defaults.

## Minimal example

`tiphys-agent init` writes a file like this one (all defaults filled in, no devices yet):

```json
{
  "version": 1,
  "name": "argo",
  "listen": { "host": "127.0.0.1", "port": 7443 },
  "requireTailscaleLogin": "you@example.com",
  "features": {
    "system": true, "services": true, "docker": true, "power": true,
    "homepage": false, "claude": true, "uptime": false, "wake": false,
    "watch": false, "git": true, "desktop": true, "control": true,
    "ports": false, "transcribe": false, "alerts": true, "backups": false,
    "research": false, "telegram": false, "analysis": false
  },
  "devices": [],
  "allowedRoots": ["~"]
}
```

## Top-level fields

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `version` | `1` | required | Schema version. Must be `1`. |
| `name` | string (1–80) | required (`init` uses the hostname) | Display name. Used in notifications (`host` parameter) and returned by `/v1/health`. |
| `listen.host` | string | `127.0.0.1` | Bind address. Keep it on loopback and publish the agent with `tailscale serve` (see [Getting started](../getting-started.md)). |
| `listen.port` | int | `7443` | Bind port. `7443` is also reserved in the port-sharing feature, so it can never be re-shared. |
| `requireTailscaleLogin` | string or `null` | `null` | If set, every authenticated request must carry a `Tailscale-User-Login` header equal to this value. `tailscale serve` adds that header. `null` disables the check. |
| `features` | object | see below | Feature flags. Routes for a disabled feature are not registered at all. |
| `devices` | array | `[]` | Paired devices: `{id, name, tokenHash, createdAt}`. Only the SHA-256 hash of each token is stored. Managed by `pair`/`revoke`. Do not edit by hand. |
| `serviceTokens` | array | `[]` | Scoped tokens for other agents: `{id, name, scopes: ["research" | "analysis" | "security-report" | "blackbox" | "lockdown" | "gamemode" | "screen"], tokenHash, createdAt, lastUsedAt?}`. Only the hash is stored; `lastUsedAt` is updated at most hourly. Managed by `service-token` and the app. A service token can call only routes of its scopes (see [api.md](api.md#authentication)). |
| `allowedRoots` | string[] | `["~"]` | Directories that path-based features may touch: git, the Claude working directory and the folder picker. Paths are resolved with `realpath` (symlinks followed) before the check. `~` is expanded. |
| `claude` | object | see [claude](#claude) | Claude Code profiles. |
| `securityFix` | object | `{"targets": [], "sudoCacheMinutes": 15}` | Machines Claude may fix security findings on, and the sudo password cache time. See [securityFix](#securityfix). |
| `homepage` | object | see [homepage](#homepage) | Homepage dashboard integration. |
| `push` | object | see [push](#push) | Push notification endpoints and the ntfy token. |
| `uptimeKuma` | object or `null` | `null` | Uptime Kuma login. |
| `wake` | object | `{targets: []}` | Wake-on-LAN targets. |
| `watch` | object | `{hosts: []}` | Other agents to watch for being online. |
| `alerts` | object | see [alerts](#alerts) | Local alerts and Grafana. |
| `backups` | object | `{checks: []}` | Backup freshness checks. |
| `sunshine` | object or `null` | `null` | Sunshine web UI credentials (Moonlight pairing). |
| `desktop` | object | `{clipboardSync: true}` | Desktop options. |
| `transcribe` | object | see [transcribe](#transcribe) | Voice-to-text command. |
| `telegram` | object or `null` | `null` | Telegram bot (`{botToken, botUsername, botId}`). Set with `PUT /v1/telegram/bot`; the token is never returned. See [telegram](#telegram-and-research). |
| `research` | object or `null` | `null` | The PC agent that runs research jobs for the `telegram` feature. See [telegram](#telegram-and-research). |
| `screen` | object | see [screen](#screen) | Screen modes (Game, Work, Focus): source agents (URL + `screen` service token, never returned), placement and per-mode settings and layouts. Was `gamemode` (moved automatically, see [screen](#screen)). |
| `stacks` | object | `{roots: ["~/stack"]}` | Where compose stacks are discovered. See [stacks](#stacks). |
| `incidents` | object | `{links: [], analysis: {mode: "off", language: "tr"}}` | Incident room options (links, AI analysis). See [incidents](#incidents). |
| `configFiles` | object | `{extraPaths: []}` | Extra `.env` files for the config editor. See [configFiles](#configfiles). |
| `databases` | object | `{connections: [], restoreTests: []}` | Database console connections (credentials stay here; saved queries in `db-queries.json`, write log in `db-writes.jsonl`). See [databases](#databases). |
| `security` | object | `{self: {role: "server", allowedPorts: [], sudo: false}, hosts: [], intervalMinutes: 15, traps, blackbox, recovery, lockdownTargets, exposure, cloudflare, alerts, scanners}` (the later keys have the defaults shown in [security](#security)) | Security center: this machine's audit policy, other audited hosts (SSH key or another agent), the check interval, and the settings of the scanners, traps, black box, lockdown, outside view, Cloudflare attack detection and alerts. Host tokens and other secrets stay here; the app edits it through `/v1/security/*` routes, never `PATCH /v1/config`. See [security](#security). |

> **Security:** `requireTailscaleLogin` relies on a header. It only means something when the agent is reachable solely through `tailscale serve` (`listen.host` on loopback). If you bind to a tailnet or LAN address, any client can send that header itself. See [Security](../security.md).

## Feature flags

Each flag turns one group of endpoints on or off. Disabled features add no routes, and the heavy modules (Claude SDK, Uptime Kuma, watchers) are not loaded at all. **Changing a flag requires an agent restart**, with one exception: `control` is also checked on every request, so turning it off takes effect immediately and ends any open control session.

Risk levels below are a guide to how much a holder of a device token can do with the feature enabled:

- **low**: read-only, or the only side effect is sending a notification.
- **medium**: changes state on the machine within narrow limits.
- **high**: can run code, change files, cut power or drive the desktop.

| Flag | Default | Enables | Risk |
| --- | --- | --- | --- |
| `system` | `true` | `/v1/system` (CPU, memory, disks, NVIDIA GPU via `nvidia-smi`, uptime) and `/v1/processes` (top processes, plus sending `TERM`/`KILL`/`INT`/`HUP` to a PID after confirmation). | medium (process signals) |
| `services` | `true` | systemd services, user and system scope: list them, start/stop/restart, read the journal. System units obey polkit (`--no-ask-password`). | medium |
| `docker` | `true` | Docker containers: list with stats, start/stop/restart, logs. If `alerts` is also on, it watches `docker events` for crashes and OOM kills. | medium |
| `power` | `true` | `reboot`, `poweroff`, `suspend` via `systemctl`, each with explicit confirmation. | high |
| `homepage` | `false` | Reads the [Homepage](https://gethomepage.dev) `services.yaml`, health-checks each service, and adds new services to it. | low |
| `claude` | `false` | Claude Code sessions, history, slash commands, schedules and the folder picker. PC-control sessions also need `desktop` and `control`. See [Claude](../features/claude.md). | high |
| `securityFix` | `false` | Claude **security fix sessions** (`kind: "security"`): Claude fixes the findings you selected in the security center on pinned machines over SSH (or on this machine), only through the in-process `tiphys_sec` tools, in a permission mode you choose; the sudo password is typed on the phone and kept in memory only. Needs `claude` on the same agent (the routes live in the Claude module) and at least one target in [securityFix](#securityfix). The monitoring server that produces the brief needs `security`. See [Security fix sessions](../features/claude.md#security-fix-sessions) and [Security](../security.md#claude-security-fix-sessions). | **high** (with *Don't ask* Claude runs any command that passes the denylist on the pinned machines without asking, as the SSH user and, with the sudo password, as root) |
| `agy` | `false` | Antigravity CLI (`agy`) sessions from the phone: one `agy acp` process per session (Agent Client Protocol), agy's own permission prompts answered from the phone, resuming earlier conversations. Needs `agy` installed and logged in on this machine; folders must lie inside `allowedRoots`. Starts no process until a session is opened. See [agy](../features/agy.md). | high |
| `uptime` | `false` | Uptime Kuma bridge: monitors, heartbeats, maintenance windows (read and write). Needs `uptimeKuma`. | low |
| `wake` | `false` | Sends Wake-on-LAN magic packets to the configured `wake.targets`. | low |
| `watch` | `false` | Polls other agents' `/v1/health` and notifies `host.offline` / `host.online`. | low |
| `git` | `false` | Git status, diff, log, branches, stage, discard, commit, push/pull/fetch and checkout, for repositories inside `allowedRoots`. | medium |
| `desktop` | `false` | Read/low-impact desktop endpoints (Wayland/Hyprland): clipboard read/write and clipboard sync, screenshot, open URL on the PC, media (MPRIS/volume), window and app list, Sunshine status, and Firefox bridge status. Also creates the Firefox bridge socket. Every *mutating* desktop endpoint additionally needs `control`. | medium |
| `control` | `false` | Remote control: window actions, workspace, DPMS, app launch, live screen with input, Firefox tab control, mobile view (AT-SPI), Sunshine start/stop/pair, and Claude PC sessions. Requires `desktop` and an open [control session](api.md#control-sessions). | high |
| `ports` | `false` | Lists listening TCP ports. Can share a localhost-only port to the tailnet with `tailscale serve --https=<port>`, and unshare it. | medium |
| `transcribe` | `false` | `/v1/transcribe`: runs the configured transcription command on uploaded audio. | low |
| `alerts` | `false` | Background checks: disk usage, failed systemd units, Grafana firing alerts, and Docker crash/OOM events (needs `docker`). Sends notifications. | low |
| `backups` | `false` | Evaluates `backups.checks` every 15 minutes and notifies on state changes. | low |
| `telegram` | `false` | Telegram newsletters: bot, invite-only recipients, feeds on a schedule, research on another agent (`research` section), approval, delivery and archive. Outbound HTTPS only (`api.telegram.org`, the PC agent, link checks); no webhook. See [Telegram newsletters](../features/telegram.md). | low (sends messages to people you invited) |
| `incidents` | `false` | Incident room: alert notifications (alerts, Docker events, watch, backups, Uptime Kuma) become incidents with context (logs, inspect, git, metrics, events, deploys, config changes), rule hints and confirmed actions (container restart, compose recreate, unit restart, compose rollback, disk cleanup). Turns on the `uptime.down/up`, `docker.unhealthy` and `docker.restartLoop` notifications. Local signals need `alerts` (and `docker`); with `docker` on it also tags previous images `tiphys-rollback/*:prev`. See [Incidents](../features/incidents.md). | medium (restarts/rolls back containers, prunes Docker data after confirmation) |
| `configfiles` | `false` | Config and secrets: view and edit the stacks' `.env` / `env_file` files and `configFiles.extraPaths` with masked values, reveal (rate limited), masked diff preview → confirmed atomic save (optionally recreating the affected compose services with `up -d --no-deps`), backups and restore, secret rotation metadata, a daily rotation reminder (`secret.rotationDue`). Known secret values of all discovered files (rescanned every 10 minutes and on each save) are redacted from incident context. See [Config files and secrets](../features/config-files.md). | high (writes service secrets after confirmation) |
| `databases` | `false` | Database console: discover database containers; PostgreSQL, MySQL/MariaDB and SQLite connections, schema browser, table preview and read-only queries (layered: statement allowlist + function denylist, read-only session + transaction, statement timeout, single statement, always rolled back; SQLite opened read-only in a child process); saved queries with chart hints, CSV export; write mode (PostgreSQL, MySQL/MariaDB: preview in a rolled-back transaction → confirmed commit if the row count is unchanged, logged in `db-writes.jsonl`). Loads `pg`/`pg-cursor`/`mysql2` only when on. See [Database console](../features/databases.md). | high (reads any data the configured roles can read; writes after preview and confirmation) |
| `security` | `false` | Security center: audits this machine, hosts without an agent (restricted SSH key) and other agents (`security-report` service token); findings, score, baseline and changes, host firewall evaluation from `nft`, notifications `security.change/accepted/unreachable/reachable`, a *security* incident kind. Serves `GET /v1/security/raw` to a monitoring server. Read-only: nothing on an audited host is changed. Also hosts the S-2 to S-5 features, each off until configured: Trivy and gitleaks scans (they start Docker containers), decoy tokens and files, the black box, the recovery-code lockdown (which can revoke every token), the outside view and Cloudflare attack detection (which can create and delete Cloudflare IP access rules with a block token). See [Security center](../features/security.md). | low for the audit (read-only; with `security.self.sudo` it runs the root-owned audit script through `sudo -n`); medium once the scanners, Cloudflare blocking or lockdown targets are configured (Docker, outbound API tokens, a path that revokes access on other agents) |
| `analysis` | `false` | Incident analysis jobs (`/v1/analysis/jobs`) for another agent holding an `analysis` service token (a server's incident room in `remote` mode): a tool-less `claude -p` (no built-in tools, no MCP, no user settings) reads the redacted bundle; output is schema-checked. Turn on only where Claude Code is installed. See [Incidents › AI analysis](../features/incidents.md#ai-analysis-i-3). | low (spends the user's Claude subscription; the model can't act) |
| `update` | `false` | Self-update from signed GitHub releases: `POST /v1/update/apply` (`GET /v1/update` and `GET /v1/doctor` are always on). Works only for installs made by `install.sh` / `install.ps1` (the `versions/<v>` + `current` layout); `init --detect` turns it on there. A git checkout, a package or the Docker image never updates itself. See [Security › Releases](../security.md#releases-installer-and-self-update). | medium (replaces the agent's code, but only with a release signed by the release key) |
| `research` | `false` | Web research jobs (`/v1/research/jobs`) run with `agy` (Gemini) and `claude` for another agent holding a `research` service token. The tools may only use the searxng/firecrawl MCP servers and write in the job's work directory; shell commands are denied. See [Research](../features/research.md). | medium (spends the user's AI subscriptions) |
| `screen` | `false` | Screen modes (Linux; was `gamemode`, the old name is still accepted by `init --features` and `PATCH /v1/config` and reported by `/v1/health` for one release): as a **source**, `WS /v1/screen/feed` for another agent holding a `screen` (or older `gamemode`) service token, producing only the subscribed topics (Velour state and lyrics, a `pw-record` spectrum of the default output while music plays, ETS2 telemetry; for Work and Focus: system, jobs, git, code city, Claude sessions, approval diffs only with `screen.share.code`, servers) plus the ETS2 plugin installer; as a **display**, a Firefox kiosk in one transient `systemd-run --user` unit with temporary Hyprland window rules (and for the `scratch` placement a temporary keybind), an idle/sleep inhibitor and the backlight setting, started, switched and stopped from the phone. No control session (see [Security](../security.md#screen-modes)). Guide: [Screen modes](../features/screen-modes.md). Starts no process until a topic is subscribed or a mode is started. See [api.md](api.md#screen). | medium (shows a fullscreen window, binds a key while running and changes the backlight on the display host; reads music and game state, and for Work the project's file names (masked unless `share.code`), Claude activity and jobs on the source) |

Endpoints that are always on, whatever the flags: health, config, devices, push endpoint registration, events, audit log and agent status. See [api.md](api.md#always-available).

## Section reference

### claude

```json
"claude": {
  "profiles": { "personal": "~/.claude", "work": "~/.claude-work" },
  "defaultProfile": "personal"
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `profiles` | `{"personal": "~/.claude"}` | Map of profile id (kebab-case) to a Claude config directory. Any directory other than `~/.claude` is passed to Claude Code as `CLAUDE_CONFIG_DIR`, so each profile can be logged in to a different account. |
| `defaultProfile` | `personal` | Profile used when a request doesn't name one. |

The working directory of every session has to be inside `allowedRoots`.

### securityFix

Feature `securityFix` (with `claude`). The machines a [security fix session](../features/claude.md#security-fix-sessions)
may work on. Managed from the app (*Settings › Hosts › (host) › Agent settings › Fix targets*) through
`GET`/`PUT /v1/claude/security/targets`, not through `PATCH /v1/config` (`GET /v1/config` leaves this section out).
Read on each use, so changes need no restart (the feature flag itself does).

```json
"securityFix": {
  "targets": [
    { "host": "atlas", "name": "atlas", "ssh": "admin@atlas.my-tailnet.ts.net" },
    { "host": "orion", "name": "orion (alt port)", "ssh": "admin@orion", "port": 2222 },
    { "host": "self", "name": "This PC", "ssh": null }
  ],
  "sudoCacheMinutes": 15
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `targets` | `[]` | At most 20 entries, unique by `host`. A session starts only with targets that are listed here **and** named in the brief. |
| `targets[].host` | required | The machine's id in the security center of the monitoring server (`[a-z0-9][a-z0-9-]{0,62}`, for example `atlas` or `self`). It is how the brief's machines are matched to targets. |
| `targets[].name` | required | Display name, 1 to 80 characters. |
| `targets[].ssh` | required | `user@host` or a bare host or ssh alias: matching `^(?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}@)?[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}$`, so no spaces, no options and no leading `-`. `null` means **this machine**: commands run locally with `sh -c`, without SSH. |
| `targets[].port` | none | SSH port, 1 to 65535. Passed as `-p`; leave it out for a local target. |
| `sudoCacheMinutes` | `15` | How long the agent remembers a sudo password per machine and session, 1 to 120. Memory only; see [Security](../security.md#claude-security-fix-sessions). |

Entries are strict: an unknown key is rejected. Remote targets use the agent user's own SSH setup (keys, agent,
`~/.ssh/config`, `known_hosts`) and the agent never learns a host key (`StrictHostKeyChecking=yes`), so connect to each
machine once by hand as the agent user before adding it. The remote machine needs `/bin/sh`, `base64` and `timeout`.
A session **copies** its targets when it starts and resolves each SSH destination once with `ssh -G`; later
connections use `-F /dev/null` and only the resolved values, so editing `~/.ssh/config` mid-session changes nothing
(a `Match exec` there runs once, at the start). A destination that uses `ProxyCommand`, `ProxyJump`, `LocalCommand` or
`KnownHostsCommand` is refused: the session does not start (`agent.claude.securitySshConfig`). Removing a target, or
changing its destination or port, later makes that machine unusable for the running session (its tools refuse it).
On a target with `ssh: null` (this PC) Claude may never write under `~/.ssh`, `~/.config`, `~/.claude`, `~/.local`,
`~/.cache`, shell startup files, the agent's own folder and the systemd user unit folders; see
[Claude](../features/claude.md#targets).

### homepage

| Field | Default | Meaning |
| --- | --- | --- |
| `servicesPath` | `~/homepage/homepage/services.yaml` | Path to Homepage's `services.yaml`. |
| `checkTimeoutMs` | `5000` (500–30000) | Timeout of each health check. |

### push

| Field | Default | Meaning |
| --- | --- | --- |
| `endpoints` | `[]` | One entry per device: `{deviceId, url, pubKey?, auth?}`. The app registers it through `PUT /v1/push/endpoint`. When `pubKey` and `auth` are present, payloads are WebPush-encrypted (RFC 8291, `aes128gcm`). |
| `token` | `null` | Optional bearer token sent to the push server (for example an ntfy access token). |

See [Notifications](../features/notifications.md).

### uptimeKuma

`{"url": "https://uptime.my-tailnet.ts.net", "username": "...", "password": "..."}`, or `null`. The agent logs in over Socket.IO when it starts. The password never leaves the agent.

### wake

```json
"wake": { "targets": [ { "hostId": "argo", "mac": "aa:bb:cc:dd:ee:ff", "broadcast": "255.255.255.255", "port": 9 } ] }
```

`broadcast` defaults to `255.255.255.255` and `port` to `9`. The packet is a LAN broadcast, so configure this on an agent that is **on the same LAN** as the target (typically the server `atlas` wakes the PC `argo`).

### watch

```json
"watch": { "hosts": [ { "hostId": "argo", "url": "https://argo.my-tailnet.ts.net/v1/health", "intervalSeconds": 60, "offlineAfterSeconds": 180 } ] }
```

| Field | Default | Meaning |
| --- | --- | --- |
| `hostId` | required | Name used in notifications. |
| `url` | required | URL polled with GET. Any 2xx response counts as online. Point it at the other agent's `/v1/health`, which needs no token. |
| `intervalSeconds` | `60` (min 15) | Poll interval. |
| `offlineAfterSeconds` | `180` (min 30) | How long a host must stay unreachable before `host.offline` is sent. |

### alerts

| Field | Default | Meaning |
| --- | --- | --- |
| `intervalSeconds` | `300` (min 30) | Check interval. |
| `diskFullPercent` | `90` (50–100) | Threshold for `disk.full`. `/snap*` and `/boot*` mounts are ignored. |
| `failedServices` | `true` | Notify about failed systemd units (user and system). |
| `grafana` | `null` | `{url, token, datasourceUids: []}`. Polls Grafana-managed alerts (`/api/prometheus/grafana/api/v1/alerts`) and, for each UID listed, that data source's alert endpoint. Only `firing` alerts count. |

Each condition is notified once when it appears and once when it clears. Conditions that already exist on the first round after startup are recorded without a notification.

### backups

```json
"backups": {
  "checks": [
    { "id": "notes", "name": "Notes backup", "kind": "file", "path": "~/backups/notes/*.json.gz", "maxAgeHours": 26, "minBytes": 1024 },
    { "id": "restic", "name": "Restic", "kind": "unit", "unit": "restic-backup.service" }
  ]
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `id` | required | Unique, kebab-case. At most 50 checks. |
| `name` | required | Display name. |
| `kind` | required | `file` checks the newest file that matches `path`. `unit` checks the last run of a systemd unit (user scope first, then system). |
| `path` | required for `file` | `*` and `?` wildcards are allowed **only in the last path segment**. |
| `unit` | required for `unit` | Unit name. |
| `maxAgeHours` | `26` | Older than this means `stale`. |
| `minBytes` | `0` | For `file`, a smaller file means `failed` (`too-small`). |

Each check has one of four states: `ok`, `stale`, `failed` or `missing`. When the state changes, `backup.ok`, `backup.stale` or `backup.failed` is sent; `missing` is reported as failed. See [Monitoring](../features/monitoring.md).

### sunshine

`{"url": "https://127.0.0.1:47990", "username": "...", "password": "..."}`, or `null`. `url` must be `https` and defaults to the local web UI. A self-signed certificate is accepted **only** on a loopback address, and it is pinned to Sunshine's own certificate file when that file is readable. See [Desktop control](../features/desktop-control.md).

### desktop

| Field | Default | Meaning |
| --- | --- | --- |
| `clipboardSync` | `true` | When the PC clipboard changes, send its text to the phone as a silent, end-to-end encrypted `clipboard.pc` notification. Only text up to 3000 bytes is sent. Password-manager content is skipped, and the notification is sent only to endpoints that have WebPush keys. The agent rereads this setting on every check, so changes need no restart. Needs `wl-paste` on a Wayland session (not available through the helper). |
| `backend` | absent (= `"auto"`) | `"auto"`, `"hyprland"` or `"helper"`. `auto` uses Hyprland when a Hyprland instance is found (a socket under `$XDG_RUNTIME_DIR/hypr`), otherwise the native helper `tiphys-desktop` when its binary is found, otherwise Hyprland (whose endpoints then answer `agent.desktop.noHyprland`, as before). `helper` forces the helper even on Hyprland (useful for testing). Read once at startup: restart after changing it. Config file only; `PATCH /v1/config` can't set it. |
| `helperPath` | absent | Absolute path of the `tiphys-desktop` binary. Absent: `desktop-helper/target/release/tiphys-desktop` next to the agent (the repository build), then `tiphys-desktop` on `PATH`. Only an executable regular file counts; a configured path that isn't one is not replaced by the others. Config file only. |

The two new fields are omitted (not filled with defaults) so `GET /v1/config` stays as before; `PATCH {desktop: {clipboardSync}}` keeps them.

### transcribe

| Field | Default | Meaning |
| --- | --- | --- |
| `command` | `~/.local/bin/transcribe` | Executable called as `command FILE -m MODEL [-l LANG]`. It must print the text on stdout and exit 0. |
| `model` | `small` | `small` or `large-v3`. Requests can override it. |

### telegram and research

Used by the `telegram` feature (the agent that sends the newsletters, e.g. atlas).

| Field | Meaning |
| --- | --- |
| `telegram.botToken` | BotFather token. Set only through `PUT /v1/telegram/bot` (validated with `getMe`). Never returned, logged or written to the event log. |
| `telegram.botUsername`, `telegram.botId` | From `getMe`; used for invite links. |
| `research.url` | Base URL of the PC agent with the `research` feature, e.g. `https://pc.my-tailnet.ts.net`. |
| `research.token` | Service token with the `research` scope from that agent (`tiphys-agent service-token create --name atlas --scope research`). Returned only as `hasToken`. |
| `research.wakeHostId` | Optional `wake.targets[].hostId`. When the PC can't be reached at run time, one Wake-on-LAN packet is sent to it and the run keeps retrying until the feed's deadline. Without it an unreachable PC fails the run at once. The `wake` feature flag is not needed for this. |

Example: `"research": {"url": "https://pc.my-tailnet.ts.net", "token": "tps_…", "wakeHostId": "pc"}`.

### screen

```json
"screen": {
  "sources": { "main": { "url": "https://pc.my-tailnet.ts.net", "token": "tps_…" } },
  "placement": "fullscreen", "scratchBind": "SUPER,grave", "lastMode": "work",
  "share": { "code": false }, "batterySaver": true,
  "modes": {
    "game":  { "scene": "auto", "lyrics": true, "spectrum": true, "motion": "normal", "brightness": null, "clock24": true, "dimIdleMinutes": 10,
               "layout": { "template": "game", "cards": [{ "kind": "map", "source": "main", "enabled": true }, …] } },
    "work":  { "project": "auto", "city": "3d", "diff": true, "ci": false, "motion": "normal", "brightness": null, "dimIdleMinutes": 10, "clock24": true, "layout": { … } },
    "focus": { "focusMin": 25, "shortMin": 5, "longMin": 15, "longEvery": 4, "ambient": "off", "ambientVolume": 30, "chime": true, "quietPhone": true, "motion": "normal", "brightness": null, "clock24": true, "layout": { … } }
    "sleep": { "join": true, "side": "left", "distance": "mid", "volume": 35,
               "brightness": { "start": 25, "night": 3, "morning": 70 }, "ddc": { "bus": null, "min": 0 },
               "quietPower": false, "holdVolume": null, "leds": false, "group": null,
               "times": { "settleMin": 3, "fadeMin": 30, "soundFadeMin": 45, "nightSound": "hum" }, "layers": { … },
               "velour": { … }, "alarm": { … }, "notify": { … }, "reminder": { … } }
  }
}
```

| Field | Default | Meaning |
| --- | --- | --- |
| `sources` | `{}` | Named source agents (`[a-z0-9-]{1,32}`; `self` = this host, reserved): base URL (`http`/`https`) and a service token with the `screen` scope from it (`tiphys-agent service-token create --name laptop --scope screen`; an older `gamemode` token gets only the Game mode topics). Set with `PUT /v1/screen`; the token is never returned. |
| `placement` | `"fullscreen"` | `fullscreen`: the mode's own named workspace (`yol` / `is` / `odak`), focused at start. `scratch`: the Hyprland special workspace `special:tiphys`, shown and hidden with `scratchBind` while the mode runs. Read at start. |
| `scratchBind` | `"SUPER,grave"` | Temporary keybind of the `scratch` placement in classic form `MODS,key`. A combination already bound refuses the start (`409 agent.screen.bindTaken`). |
| `lastMode` | `"work"` | Mode of a start without one; updated on each start/switch. |
| `modes.game` | | The Game mode kiosk settings: `scene` (`auto`/`drive`/`music`), `lyrics`, `spectrum` (frames relayed only when on), `motion` (`low`/`normal`/`high`), `brightness` (5–100 while running, restored on stop; `null` = untouched), `clock24`, `dimIdleMinutes` (0–120). |
| `modes.work` | | `project`: `"auto"` (the last active Claude session's repo, else the focused terminal's) or `{path}` (absolute, inside `allowedRoots` on the source); `ci` (`false`): CI dot from `gh run list` every 5 min on the source (needs `gh`, logged in; otherwise no dot, see `doctor`). `city` (`"3d"`): the code city drawn in WebGL or as a flat 2D map (also the fallback without WebGL). `diff` (`true`): the approval preview (diff card) on the kiosk; off = only the "waiting" banner. Plus `motion`, `brightness`, `dimIdleMinutes`, `clock24`. |
| `modes.focus` | | Timer (`POST /v1/screen/focus`): `focusMin` (25), `shortMin` (5), `longMin` (15), each 5–120 minutes; `longEvery` (4, 2–8): a long break after every this many rounds; changes apply from the next phase. `ambient` (`"off"`, `brown`, `pink`, `rain`): noise synthesized in the kiosk page (no files, no network), playing only while a focus round runs and the page is shown, unveiled and Velour isn't playing; `ambientVolume` (30, 0–100). `chime` (`true`): a soft synthesized bell when a phase ends by itself. `quietPhone` (`true`): read by the app (only critical Tiphys notifications during Focus). Plus `motion` (`low`: the background is repainted only on a phase change), `brightness`, `clock24`. |
| `modes.sleep` | | Sleep mode ([api.md](api.md#sleep-mode); set with `PUT /v1/sleep`, not `PUT /v1/screen`). Per machine: `join` (`true`), `side` (`left`/`right`/`foot`/`head`), `distance` (`near`/`mid`/`far`), `volume` (35, 0–100), `brightness.start` (25, 1–100) / `.night` (3, 0–30) / `.morning` (70, 10–100) in percent of full brightness, `ddc.bus` (`null` = detect once with `ddcutil detect` and store it here) and `ddc.min` (0, the lowest VCP 0x10 percent used), `quietPower` (`false`: `powerprofilesctl set power-saver` while sleeping), `holdVolume` (`null` or 0–100: system volume while sleeping, unmuted), `leds` (`false`: plain lit LEDs off). Group-wide (the phone writes the same values to every member): `group` (`null` or `{members, leader}`; S3), `times.settleMin` (3, 1–30), `fadeMin` (30, 10–120), `soundFadeMin` (45, 10–180), `nightSound` (`hum`/`off`), `layers` (`hum`, `crackle`, `logs` on; `wind`, `rain` off), `velour` (`playlistId`, `volume` 30, `fadeMin` 30; S5), `alarm` (`enabled` false, `time` `"07:00"`, `days` `once`/`weekdays`/`daily`/`[0..6]`, `sunriseMin` 25 (10–45), `sound` `birds`/`chime`/`velour`, `velourTrack`, `rampMin` 3 (1–10), `snoozeMin` 9 (1–30), `autoStopMin` 20 (5–60), `morningScreen` false; S4), `notify` (`critical`: `hostDown`, `securityTrap`, `incident`, `diskFull`; `morningSummary` true; S5), `reminder` (`enabled` false, `time` `"22:30"`; S6). Brightness and `volume`/`layers` changes apply while running; `times` at the next start. Test only: `TIPHYS_SLEEP_SCALE=N` (1–1000, unset = 1) in the agent's environment divides every sleep phase length by N (e.g. 60: settle 3 s, fade 30 s); hardware rate limits are not scaled. |
| `modes.*.layout` | per mode | `{template, cards: [{kind, source, enabled}]}`; `source` is `self` or a `sources` name. The display subscribes each source to the topics of the cards it serves. |
| `share.code`, `batterySaver` | `false`, `true` | `share.code`: this host as a source sends real file names in the code city and the Claude brain (off: every path segment is an opaque token; read when the city starts) and approval diffs of Tiphys Claude sessions (off: no `diff` at all; read per permission). `batterySaver` (`true`): on a display host running on battery below 30 % the kiosk drops to motion `low` and the flat city until it is on mains or at ≥ 35 %; read live. Test only: the environment variable `TIPHYS_SCREEN_POWER_DIR=/abs/dir` (unset by default) makes the agent read batteries from a directory of fake `power_supply` entries (`<name>/type`, `capacity`, `status`) instead of `/sys/class/power_supply`. |

**Migration from `gamemode` (once, at the first start of this version; the file is rewritten without the old keys):**
`features.gamemode` → `features.screen`; `gamemode.source` → `screen.sources.main` with the Game cards reading `main`;
`gamemode.display` → `screen.modes.game`; `lastMode` becomes `game`. Values already under `screen` win.

The source host needs nothing here: the flag plus a service token for the display host. Map data for the page lives in
`~/.local/share/tiphys/gamemode/map/` (program data, not a trace). Settings are read on every use; only the flag needs
a restart.

### stacks

```json
"stacks": { "roots": ["~/stack"] }
```

Every directory directly under a root that holds `compose.yaml`, `compose.yml`, `docker-compose.yaml` or `docker-compose.yml` is a stack `{id (directory name), project, dir, composeFiles (+ override file), envFiles (.env and the services' env_file), services, gitRepo?}`. All paths are resolved with `realpath` and must stay inside the root: symlinked directories, compose files or env files pointing outside are skipped. This list is separate from `allowedRoots`. Missing roots are ignored. Read on each use (the incident room refreshes every 5 minutes).

### incidents

```json
"incidents": { "links": [{ "uptimeMonitor": "Nextcloud", "stack": "nextcloud", "service": "app" }] }
```

`links` ties an Uptime Kuma monitor (by name) to a stack id and optionally a compose service: its downtime is grouped with that stack's container signals, and a `compose.recreate` action is offered. Read on each use.

`analysis` (I-3) chooses where the AI analysis runs:

| Field | Meaning |
| --- | --- |
| `analysis.mode` | `off` (default: rule hints only), `local` (tool-less `claude -p` in this agent: the PC), `remote` (jobs on the PC agent below: servers, which have no Claude) |
| `analysis.url` | Base URL of the PC agent with the `analysis` feature, e.g. `https://pc.my-tailnet.ts.net:7443` (required for `remote`) |
| `analysis.token` | Service token with the `analysis` scope from that agent. Returned only as `hasToken`; kept on PATCH while the URL stays the same, required again when it changes. |
| `analysis.language` | `tr` (default) or `en`: the language the model writes in |

Setting up a server (e.g. atlas) against the PC:

1. On the PC: turn on the `analysis` feature (`PATCH /v1/config {"features": {"analysis": true}}` or `agent.json`, then restart) and create a token: `tiphys-agent service-token create --name atlas --scope analysis` (or `POST /v1/service-tokens {"name": "atlas", "scopes": ["analysis"]}` from the app). The token is printed once.
2. On the server: `PATCH /v1/config {"incidents": {"analysis": {"mode": "remote", "url": "https://pc.my-tailnet.ts.net:7443", "token": "tps_…"}}}`. No restart needed.

Example: `"incidents": {"links": [], "analysis": {"mode": "remote", "url": "https://pc.my-tailnet.ts.net:7443", "token": "tps_…", "language": "tr"}}`. When the PC is off or asleep the analysis is marked `unavailable` and the rule hints stay; the PC is never woken for it. The bundle is redacted on the server before it is sent.

With `docker` also on, the incident room tracks deploys (no setting): every 5 minutes and after each container start it records compose services whose image changed in `incidents/deploys.jsonl` and tags the previous image `tiphys-rollback/<project>-<service>:prev` (one tag per service). These tags keep old images out of `docker image prune` (dangling only); `docker image prune -a` or `docker rmi` still removes them. Remove a tag by hand with `docker image rm tiphys-rollback/<name>:prev`.

### configFiles

```json
"configFiles": { "extraPaths": ["~/apps/bot/.env"] }
```

`.env` files to offer besides the ones found in [stacks](#stacks). Each must be a regular file whose real path is in the configured file's own directory (a symlink to another directory is refused), owned by the agent user, at most 256 KB, and named `.env`, `*.env` or `.env.*`. The same rules apply to stack files (their real path must stay inside the stack root). Files that don't qualify are listed under `skipped` with a reason. Read on each use.

### databases

```json
"databases": {
  "connections": [
    { "id": "app", "name": "App DB", "engine": "postgres", "target": { "container": "app-db-1" }, "database": "app",
      "readCredential": { "user": "tiphys_ro", "password": "…" } },
    { "id": "app-env", "name": "App DB (container env)", "engine": "postgres", "target": { "container": "app-db-1", "network": "app_default" },
      "readCredential": { "fromContainerEnv": true } },
    { "id": "remote", "name": "Remote", "engine": "postgres", "target": { "host": "10.0.0.5", "port": 5432 }, "readCredential": { "user": "ro", "password": "…" },
      "writeCredential": { "user": "app_writer", "password": "…" } },
    { "id": "shop", "name": "Shop", "engine": "mariadb", "target": { "container": "shop-db-1" }, "database": "shop",
      "readCredential": { "user": "tiphys_ro", "password": "…" } },
    { "id": "notes", "name": "Notes", "engine": "sqlite", "target": { "path": "~/apps/notes/notes.db" } }
  ]
}
```

Managed from the app through `/v1/db/connections` (not `PATCH /v1/config`; `GET /v1/config` leaves this section out). Read on each use. Fields: `id` (`[a-z0-9-]`, unique), `name`, `engine` (`postgres`, `mysql`, `mariadb` or `sqlite`; `mysql` and `mariadb` share the driver and the flavor is detected from the server), `target`, `database` (PostgreSQL default: `POSTGRES_DB` with `fromContainerEnv`, else `postgres`; MySQL: `MYSQL_DATABASE`/`MARIADB_DATABASE` with `fromContainerEnv`, else none), `readCredential`, `writeCredential` (optional; the write mode uses it, else the read credential with a `readCredentialUsed` warning).

- **target** `{container, network?, port?}`: the container's IP is read with `docker inspect` on every connect (the given network's, else the first one with an IP; `127.0.0.1` for host networking); port default 5432 (PostgreSQL) / 3306 (MySQL). `{host, port?}`: a fixed address. `{path}` (SQLite): resolved with `realpath` on every use and must be inside `allowedRoots`.
- **readCredential** / **writeCredential** `{user, password?}` is stored here and never returned. `{fromContainerEnv: true}` (container targets only) reads the image's variables from `docker inspect` at connect time and stores nothing: PostgreSQL `POSTGRES_USER` (default `postgres`), `POSTGRES_PASSWORD`, `POSTGRES_DB`; MySQL/MariaDB (`MARIADB_*` before `MYSQL_*`) root with `*_ROOT_PASSWORD` (or an allowed empty root password), else `*_USER` + `*_PASSWORD`, and `*_DATABASE`. That user is usually a **superuser**, so the connection shows the `superuserCredential` warning. Prefer a separate read-only role; `GET /v1/db/connections/:id/readonly-role-sql` generates the SQL with a random password (PostgreSQL: runnable through the write mode):

```sql
-- PostgreSQL 14+ (or GRANT CONNECT/USAGE/SELECT per schema on older versions)
CREATE ROLE tiphys_ro LOGIN PASSWORD '…' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5 IN ROLE pg_read_all_data;
-- MySQL/MariaDB (run with the mysql client: account statements can't be previewed)
CREATE USER 'tiphys_ro'@'%' IDENTIFIED BY '…' WITH MAX_USER_CONNECTIONS 5;
GRANT SELECT, SHOW VIEW ON `shop`.* TO 'tiphys_ro'@'%';
```

**Restore tests** (`databases.restoreTests[]`, up to 20; managed through `/v1/db/restore-tests`, not `PATCH /v1/config`):

```json
"restoreTests": [
  { "id": "app-db", "name": "App DB dump", "connectionId": "app", "engine": "postgres", "image": "postgres:16-alpine",
    "dumpGlob": "~/backups/app/*.sql.gz", "format": "gz",
    "sanity": [{ "sql": "SELECT count(*) FROM users", "expect": { "op": ">", "value": 0 } }],
    "schedule": { "kind": "weekly", "days": [7], "time": "04:00" }, "enabled": true }
]
```

Fields are described in [api.md](api.md#databases) (restore test). The newest dump is streamed into a throwaway container (`docker run -d --rm --network none --memory 1g --tmpfs <data dir> --label tiphys.restore=1`, random password via the environment), then removed. Results: `db-restore-results.json` next to `agent.json` (0600, last 20 per test). Needs `docker` for the agent user and free space of at least twice the dump size. Read on each use.

Next to `agent.json` (both mode 0600): `db-queries.json` holds the saved queries (`{version: 1, queries: [{id, connectionId, name, sql, params, chart, createdAt, updatedAt}]}`, at most 500; managed through `/v1/db/queries`), and `db-writes.jsonl` the write log (one line per commit attempt with the full SQL — a role password literal masked — row count, device, connection and time; kept as `db-writes.jsonl.1` past 5 MB).

### security

```json
"security": {
  "self": { "role": "server", "allowedPorts": ["tcp/22"], "sudo": false },
  "hosts": [
    { "id": "orion", "name": "orion", "role": "server", "allowedPorts": [],
      "source": { "kind": "ssh", "host": "orion.my-tailnet.ts.net", "user": "tiphys-audit", "port": 22, "keyPath": "~/.config/tiphys/security-audit-key" } },
    { "id": "argo", "name": "argo", "role": "desktop", "allowedPorts": [],
      "source": { "kind": "agent", "url": "https://argo.my-tailnet.ts.net", "token": "tps_…" } }
  ],
  "intervalMinutes": 15,
  "scanners": { "trivy": true, "gitleaks": true, "javaDb": false,
    "registryAuth": [{ "registry": "ghcr.io", "username": "example-user", "token": "…" }],
    "github": { "owners": ["example-org"], "token": null },
    "loki": { "container": "loki", "port": 3100 },
    "localRoots": [], "nightHours": [2, 6] },
  "traps": { "tokens": [], "files": [], "dbUsers": ["app_backup"] },
  "blackbox": { "mode": "local", "url": null, "token": null },
  "recovery": null,
  "lockdownTargets": [{ "id": "argo", "name": "argo", "url": "https://argo.my-tailnet.ts.net", "token": "tps_…" }],
  "exposure": { "enabled": true, "intervalDays": 7, "extraPorts": [],
    "targets": [{ "id": "atlas-ip", "kind": "ip", "value": "203.0.113.10", "expectedPorts": [80, 443] },
                { "id": "site", "kind": "domain", "value": "example.org", "expectedPorts": [] }] },
  "cloudflare": { "readToken": null, "blockToken": null, "block": false, "blockHours": 24, "zones": [], "allowIps": ["198.51.100.7"] },
  "alerts": { "telegramRecipient": null }
}
```

Managed from the app through `/v1/security/*` routes (not `PATCH /v1/config`; `GET /v1/config` leaves this section out, so tokens never come back). Read on each use, so changes need no restart (the `security` feature flag itself does, and so does `blackbox.mode`). The sub-sections below are in the order of the phases.

| Field | Default | Meaning |
| --- | --- | --- |
| `self.role` | `server` | `server` or `desktop`. A server is also expected to have automatic updates, `auditd` and AppArmor, and a missing firewall is a low finding instead of a medium one. |
| `self.allowedPorts` | `[]` | Exposed listeners that are expected, `tcp/22` or `udp/53` (≤100). They raise no `port.exposed` finding. `udp/41641`, `udp/68`, `udp/546` and `udp/5353` are always expected. |
| `self.sudo` | `false` | Run this machine's audit as root: `sudo -n /usr/local/lib/tiphys/audit.sh <mode>`. Needs the root-owned installed copy (checked on every run: a regular file, owned by root, not writable by group or others, else `agent.security.scriptMissing` / `scriptUnsafe`) and passwordless sudo for the agent user. The agent's own `helpers/audit.sh` is never run with `sudo`, because the agent user can change that file. See the [setup guide](../setup-guide.md#security-center). |
| `hosts` | `[]` | Up to 20 other audited hosts; `id` (`[a-z0-9-]`, unique, not `self` and not one of the screen names the app uses: `settings`, `vulns`, `secrets`, `scanners`, `traps`, `exposure`, `attacks`, `cloudflare`, `blackbox`, `recovery`, `lockdown`), `name` (1–80), `role` (`server`), `allowedPorts` (`[]`) and `source`. |
| `hosts[].source` (`ssh`) | | `{kind: "ssh", host, user, port (22), keyPath}`: a host without an agent, reached with the restricted audit key at `keyPath` (private key on this machine). `host` is a name or an address (no leading `-`, no user part); `user` is normally `tiphys-audit`. The host key must be pinned in `security-known-hosts`. |
| `hosts[].source` (`agent`) | | `{kind: "agent", url, token}`: another agent with `security` on. `url` must be `https`; `token` is a service token (`tps_…`) with the `security-report` scope. The token is never returned by the API (`hasToken` only). |
| `hosts[].traps` | `false` | SSH hosts only: poll the host's decoy-file events (`traps` request, every 30 s). Needs the audit rule on the host (`tools/install-audit.sh --trap`) and the current `audit.sh` (one that has the `traps` request). |
| `intervalMinutes` | `15` | Minutes between checks of each machine (5–1440). A full report (with the SUID scan) runs at most once per 24 hours per machine. |

**Scanners (S-2)**, `security.scanners`, edited with `PATCH /v1/security/scanners`. Off by default; the scanners need Docker on the agent's machine. Tokens come back only as `hasToken`.

| Field | Default | Meaning |
| --- | --- | --- |
| `trivy` | `false` | Scan the images of running containers (Trivy, pinned digest, 2 GB / 2 CPUs, read-only). |
| `gitleaks` | `false` | Scan GitHub repositories and Loki logs (gitleaks, pinned digest, no network). The local scan does not need it. |
| `javaDb` | `false` | Download Trivy's Java DB (about 1 GB) and scan `*.jar`, `*.war` and `*.ear` files. **Off: those archives are skipped**, so Java libraries inside them are not checked. |
| `registryAuth` | `[]` | Up to 10 `{registry, username, token}` for private images (read-only tokens, for example `read:packages` on `ghcr.io`). Matched by the registry name of the image's digest reference; a registry listed here is also allowed as a remote source (otherwise only `docker.io`, `ghcr.io`, `gcr.io`, `quay.io`, `registry.k8s.io`, `public.ecr.aws`, `mcr.microsoft.com`, `registry.gitlab.com`, `lscr.io` and `codeberg.org` are contacted); handed to Trivy only in the environment of its `docker` process, never on a command line. |
| `github` | `{owners: [], token: null}` | `owners`: up to 20 GitHub user or organization names whose non-fork repositories (at most 200) are scanned. `token`: a fine-grained token with `contents: read` for private repositories; without it only public ones. Passed to `git` only through its environment. |
| `loki` | `null` | Where the log scan and the decoy database users look: `{container, port (3100)}` (a Loki container on this machine; its address is looked up with `docker inspect` each time) or `{url}`. No authentication is sent. |
| `localRoots` | `[]` | Up to 20 paths inside `allowedRoots`: a git repository or a folder of repositories scanned on this machine for tracked `.env` files and well-known key formats. Works on any agent. |
| `nightHours` | `[2, 6]` | Local hours `[from, to)` for heavy work (image scans, the nightly secret scan, the outside view, SSH image saves). `from > to` wraps over midnight; `[0, 24]` is always. |

**Traps and alerts (S-3)**, `security.traps` and `security.alerts`.

| Field | Default | Meaning |
| --- | --- | --- |
| `traps.tokens` | `[]` | Up to 20 decoy tokens `{id, name, tokenHash, createdAt}`; the token itself is not stored. Created with `POST /v1/security/traps/tokens` (and by `env` decoy files). |
| `traps.files` | `[]` | Up to 20 decoy files `{id, path, kind: env\|sshkey, createdAt}`, watched by access time. Created with `POST /v1/security/traps/files`; the agent never overwrites an existing file, and the limit is checked before the file is written. |
| `traps.dbUsers` | `[]` | Up to 10 decoy database user names that exist only in decoy files; a failed login with one in the Loki logs raises the alarm. |
| `alerts.telegramRecipient` | `null` | A recipient id of the `telegram` feature that receives the titles of critical security notices (and the nightly black box anchor). |

**Black box and lockdown (S-4)**, `security.blackbox`, `security.recovery`, `security.lockdownTargets`.

| Field | Default | Meaning |
| --- | --- | --- |
| `blackbox.mode` | `off` | `local`: this agent keeps the hash chain and accepts pushed records (the monitoring server). `push`: send this agent's records to another agent's chain. `off`. **Read at start**: `PUT /v1/blackbox/settings` answers `restartRequired`. |
| `blackbox.url`, `blackbox.token` | `null` | `push` only: the monitoring server's `https` URL and a service token (`tps_…`) with the `blackbox` scope created there. The token is never returned (`hasToken`) and is kept only while the URL stays the same. |
| `recovery` | `null` | `{salt, hash, createdAt}`: scrypt (`N=2^15, r=8, p=1`) of the recovery code. The code itself is shown once and never stored. Set by `POST /v1/security/recovery`. |
| `lockdownTargets` | `[]` | Up to 20 agents `{id, name, url (https), token (tps_…)}` that a lockdown on this agent also locks. The token is a service token with the `lockdown` scope created on that agent; never returned by the API. |

**Outside view and Cloudflare (S-5)**, `security.exposure` and `security.cloudflare`.

| Field | Default | Meaning |
| --- | --- | --- |
| `exposure.enabled` | `false` | Run the outside view on schedule (at night, every `intervalDays`). *Run now* works regardless. |
| `exposure.targets` | `[]` | Up to 30 `{id, kind: ip\|domain, value, expectedPorts}`; `value` is an IPv4 address or a host name. `expectedPorts` (≤50) are the ports of an `ip` target that are meant to be open. |
| `exposure.extraPorts` | `[]` | Up to 100 ports added to the built-in list of 64 common ports. |
| `exposure.intervalDays` | `7` | Days between scheduled runs (1–30). |
| `cloudflare.readToken` | `null` | API token with Zone › Analytics › Read and Zone › Zone › Read. Without it attack detection does not run. Never returned (`hasReadToken`). |
| `cloudflare.blockToken` | `null` | API token with Zone › Firewall Services › Edit, only for blocking. Never returned (`hasBlockToken`). |
| `cloudflare.block` | `false` | Create expiring IP Access Rules (note `tiphys:<expiry>`) for offenders. Needs `blockToken`. |
| `cloudflare.blockHours` | `24` | Lifetime of a block (1–720). |
| `cloudflare.zones` | `[]` | Zone names to watch; empty = every zone the read token can read (first 50). |
| `cloudflare.allowIps` | `[]` | Up to 50 addresses never blocked (in addition to the always-protected private, Tailscale and loopback ranges). |

## Editing from the app

The app reads the redacted config with `GET /v1/config` and changes it with `PATCH /v1/config` (agent settings screens).

**Redaction.** Secrets never come back to the phone:

- token hashes are dropped, and devices are returned as `{id, name, createdAt}` only
- `push.endpoints` is reduced to `{deviceId}`, and `push.token` becomes `hasToken`
- for `uptimeKuma`, `sunshine` and `alerts.grafana`, the password or token becomes `hasPassword` / `hasToken`
- `telegram` becomes `{configured, username}` and `research` becomes `{url, wakeHostId, hasToken}`
- `incidents.analysis` becomes `{mode, url, language, hasToken}`
- `databases` is left out (connections are read through `/v1/db/connections`, without passwords)
- `securityFix` is left out (read through `GET /v1/claude/security/targets`)
- `security` is left out (hosts are read through `/v1/security/hosts`, the scanners, Cloudflare, traps, black box and lockdown targets through their own `/v1/security/*` and `/v1/blackbox/*` routes; tokens come back only as `hasToken`)

**Patchable fields:** `name`, `features` (partial), `allowedRoots`, `claude`, `homepage`, `pushToken` (string or `null`), `uptimeKuma`, `sunshine`, `wake`, `watch`, `alerts`, `transcribe`, `desktop`, `backups`, `research` (`{url, token?, wakeHostId?}` or `null`), `stacks` (`{roots}`), `incidents` (`{links?, analysis?: {mode, url? (null clears), token?, language?}}`; an omitted part is kept), `configFiles` (`{extraPaths}`). `databases`, `security` and `securityFix` are not patchable here (`/v1/db/*`, `/v1/security/*`, `/v1/blackbox/settings`, `/v1/claude/security/targets`). The bot token has its own route (`PUT /v1/telegram/bot`). Unknown keys are rejected. The phone **cannot** change `listen`, `requireTailscaleLogin`, `devices`, `serviceTokens` or push endpoints this way (service tokens have their own routes, `/v1/service-tokens`; they are not part of `GET /v1/config`).

**Password fields.** For `uptimeKuma.password`, `sunshine.password`, `alerts.grafana.token`, `research.token` and `incidents.analysis.token`, an omitted value keeps the stored secret, but only if the URL is unchanged. If the URL changes and no new secret is sent, the request fails with `agent.config.passwordRequired`, so an old secret is never sent to a new host. Sending `null` for the section removes it.

**Restart.** The response is `{config, restartRequired}`. `restartRequired` is `true` when the patch contained `features` or `alerts`. The agent does not restart itself. Restart the service, for example `systemctl --user restart tiphys-agent` if you installed it as a user unit. In practice, these settings take effect as follows:

| Setting | Takes effect |
| --- | --- |
| `name`, `allowedRoots`, `claude`, `homepage`, `pushToken`, `wake`, `transcribe`, `sunshine`, `desktop.clipboardSync`, `backups.checks`, `research`, `stacks`, `incidents`, `configFiles`, `security` (through the `/v1/security/*` routes; except `blackbox.mode`) | Immediately (read on each use) |
| `features.control = false` | Immediately. The open control session ends at once. |
| other `features`, `alerts`, `security.blackbox.mode` | After restart (`restartRequired: true`; for the black box, in the `PUT /v1/blackbox/settings` answer) |
| `uptimeKuma`, `watch` | After restart. The bridge and watcher read these only at startup, but the response does **not** set `restartRequired` for them. |

## CLI

The binary is `tiphys-agent`, which is `node agent/dist/cli.js` after `npm run build`. Every command accepts `--config PATH`.

| Command | Description |
| --- | --- |
| `tiphys-agent serve` | Runs the agent in the foreground (use a systemd user unit in production). Opens the Firefox bridge socket when `desktop` is on. If the previous run ended without a clean shutdown, it sends an `agent.restarted` notification. Stops cleanly on `SIGTERM`/`SIGINT`. |
| `tiphys-agent init [--name NAME] [--detect] [--features a,b] [--set-features a,b] [--disable a,b] [--tailscale-login LOGIN]` | Creates the config file if it is missing, then applies the options (see [init and feature lists](#init-and-feature-lists)). `--features` **adds** to the current list, `--set-features` is an exact list, `--disable` turns flags off, `--detect` turns on the safe features this machine supports. Prints what changed. Unknown names fail with exit code 2 before anything is written. |
| `tiphys-agent pair --name "Phone" [--url https://argo.my-tailnet.ts.net:7443]` | Adds a device and prints a QR code. The QR holds `{"v":1,"type":"tiphys-pair","agent","url","token"}`. The address and token are also printed for manual entry. The token (`tph_…`) is shown only once. Scan it in the app's agent pairing screen. Without `--url` the address comes from Tailscale: `https://<MagicDNS name>:<port>`, where the port is the `tailscale serve` HTTPS port that proxies to the agent (7443 if none does yet; then it also prints the `tailscale serve` command). If Tailscale is missing, stopped or has no DNS name it exits with an explanation and asks for `--url`. The running agent accepts the new device **without a restart**; `pair` checks that and says so. |
| `tiphys-agent doctor [--json]` | Checks the install: Tailscale installed/running/logged in, `tailscale serve` → agent port, agent answering, `agent.json` permissions and owner, clock sync, disk space, Node.js version, tools missing for enabled features, push, latest release. Prints each check with a suggested fix command (never run by itself); exits 1 if a check fails. `--json` prints the same report as `GET /v1/doctor`. See [api.md › Doctor](api.md#doctor). |
| `tiphys-agent devices` | Lists paired devices (`id`, `name`, `createdAt`, tab-separated). |
| `tiphys-agent revoke <device-id>` | Removes a device and its push endpoint. |
| `tiphys-agent service-token create --name NAME --scope research\|analysis\|security-report\|blackbox\|lockdown` | Creates a scoped service token (`tps_…`) and prints it **once**; only its hash is stored. Give it to the other agent (e.g. atlas's `research.token`, a server's `incidents.analysis.token`, the token of an `agent` host in atlas's `security.hosts`, a `blackbox` token as the PC's `security.blackbox.token`, or a `lockdown` token as an entry of atlas's `security.lockdownTargets`). `--scope` may be repeated. |
| `tiphys-agent lockdown --url https://atlas.my-tailnet.ts.net` | Lost phone: reads the **recovery code from standard input** (not from the command line), calls `POST /v1/security/lockdown` on that agent (no token needed), and prints which agents it also locked. Revokes all devices, service tokens and push endpoints there and on its `lockdownTargets`. Needs no config file. Afterwards pair again with `tiphys-agent pair`. See [Lost phone](../features/security.md#lost-phone). |
| `tiphys-agent service-token list` | Lists service tokens (`id`, `name`, `scopes`, `createdAt`, `lastUsedAt`, tab-separated). |
| `tiphys-agent service-token revoke <id>` | Revokes a service token. |
| `tiphys-agent run -- CMD [ARGS…]` | Runs a command with inherited stdio. When it exits, sends `command.done` (exit 0) or `command.failed` with the duration and exit code, then exits with the same code. Only the program name of the command is written to the event log; the notification shows up to 120 characters of the full command line. |
| `tiphys-agent schema` | Prints the JSON Schema of the app's `.tiphys.json` profile file (`npm run schema` writes it to `schema/tiphys.schema.json`). This is the app profile, not `agent.json`. |
| `tiphys-agent firefox install` | Registers the Firefox native-messaging host. It writes the manifest `~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json` and the launcher `$XDG_DATA_HOME/tiphys/firefox-host`, and prints the path of the newest unsigned XPI in `firefox/dist/` if one exists. Needs a built agent (`npm run build`). See [Firefox bridge](../features/firefox-bridge.md). |
| `tiphys-agent vscode-a11y install` / `remove` | Adds or removes `--force-renderer-accessibility` in a user copy of the Flatpak VS Code launcher (`~/.local/share/applications/com.visualstudio.code.desktop`). VS Code then exposes its accessibility tree to the mobile view. Files it did not write are left alone. See [Remotes and mobile view](../features/remotes-and-mobile-view.md). |

Pairing and revoking can also be done from the app: `DELETE /v1/devices/:id` and "lock everything" (`POST /v1/devices/revoke-all`).

### init and feature lists

> **Changed:** `--features` used to be an exact list that turned every unlisted flag **off**, which silently disabled
> features you had turned on in the app. It now only **adds**. Scripts that relied on the old meaning should use
> `--set-features`. `tools/deploy-agent.sh` uses `--set-features` on the first install and `--features` afterwards
> (`TIPHYS_EXACT_FEATURES=1` restores the exact list).

| Option | Effect |
| --- | --- |
| `--features a,b` | Turns `a` and `b` on. Nothing is turned off. |
| `--set-features a,b` | Exactly `a` and `b` on, every other flag off. Cannot be combined with `--features`. |
| `--disable a,b` | Turns `a` and `b` off. A flag in both lists is an error. |
| `--detect` | Looks at the machine and turns on the **safe** features it supports: `system`; `services` (systemd user manager reachable); `docker` (socket readable and writable); `git` (`git` on PATH); `desktop` (a Hyprland, Sway, GNOME, KDE, Wayland or X11 session in the environment); `ports` (Tailscale installed); `transcribe` (the configured `transcribe.command` exists); `update` (an `install.sh` install). It also reports PipeWire (`wpctl`), `playerctl`, Velour's socket directory, Firefox, the Claude CLI and Tailscale. On an **existing** file it only adds. On a file it **creates**, the list starts empty, so the schema defaults `power` and an inaccessible `docker` stay off. |

`--detect` never turns on `control`, `claude`, `power`, `securityFix`, `databases`, `research`, `agy`, `analysis`,
`configfiles`, `security`, `telegram`, `incidents`, `wake`, `homepage`, `uptime`, `watch`, `alerts` or `backups`:
they run code, drive the desktop, cut power, read secrets or reach other machines. Where they would work (e.g. the
Claude CLI is installed, a desktop session exists) it prints the `init --features …` command to enable them.

The running agent re-reads `agent.json` when another process changes it (a file watcher, plus a re-read when an
unknown token arrives, at most once a second), so new devices work at once. Feature changes still need a restart.

## Files on disk

All state files sit next to `agent.json` (by default in `~/.config/tiphys/`) and are written with mode `0600`. `security-known-hosts` and the SSH audit key are the files you create yourself (use `0600` for the key; the agent flags group/other permissions of its own files under `files.agentPerms`).

| File | Written by | Content |
| --- | --- | --- |
| `agent.json` | config store | The configuration. Saves are serialized and each goes through its own temporary file, then a rename. |
| `events.jsonl` | always | Event log: every notification (except sensitive ones such as clipboard text) and non-notifying events such as Docker restarts, git commits/pushes, control session start/end and `ui.opened`. Rotated to `events.jsonl.1` above 2 MB. |
| `audit.jsonl` | always | One line for every non-GET request: `{at, device, method, path, status}`. Bodies and query strings are never logged. Security fix sessions add one line per tool step with method `TOOL`, see [Security](../security.md#claude-security-fix-sessions). Rotated to `audit.jsonl.1` above 1 MB. |
| `agent-runs.json` | `serve` | The last 50 start/stop records, used to detect unexpected restarts. |
| `control-indicator.json` | `desktop` | The Hyprland border colour and width saved while a control session is open. Restored and deleted on the next start if the agent crashed. |
| `a11y-state.json` | `desktop` + mobile view | The previous `org.a11y.Status.IsEnabled` value. Restored when the last view closes or on startup. |
| `claude-sessions.json` | `claude` | Live Claude sessions, restored after an agent restart. A security fix session also keeps its pinned targets, mode, data-block nonce, backup list and rollback timers here (never a password). |
| `claude-schedules.json` | `claude` | Scheduled Claude tasks. |
| `telegram-state.json` | `telegram` | Recipients (chat id, names, status, subscriptions), invites, feeds, the `getUpdates` offset and the newsletter archive (last 60 issues per feed with items, rendered parts and deliveries). No tokens. A corrupt file is moved aside to `telegram-state.json.corrupt-<time>` and the agent starts empty (event `telegram.stateCorrupt`). |
| `incidents/` | `incidents` | Directory (`0700`): `index.json` (summaries) and `<id>.json` per incident (redacted logs, inspect summary, git log/status, metrics, deploys, timeline, notes). Atomic writes, `0600`. Resolved incidents are deleted after 90 days; at most 500 are kept (oldest resolved first). `deploys.jsonl` (`incidents` + `docker`, `0600`): compose service image changes (ids, references, container names; no env); rotated at 1 MB to `deploys.jsonl.1`. |
| `security-state.json` | `security` | Per host: the last parsed report, findings, score, the baseline snapshot and its time, the list of changes (with the ids already notified), and the last error. No tokens. Atomic writes. A corrupt file is moved aside to `security-state.json.corrupt-<time>` and the next report starts a new baseline silently. State of a host removed from `security.hosts` is dropped. |
| `security-vulns.json` | `security` + `scanners.trivy` | Per image id: refs, hosts and containers, status, source, error code, scan time, OS, counts and the findings (id, package, versions, severity, title, target; ≤300), plus the per-date count of SSH image saves. No registry credentials. Atomic writes; corrupt file moved aside as `.corrupt-<time>`. |
| `security-secrets.json` | `security` + secret scan | Findings (location and rule only, **never the secret**, with first-seen time and the dismissed flag), per GitHub repository the scanned head commit, and the last run per source. Atomic writes; corrupt file moved aside. |
| `security-exposure.json` | `security` + outside view | The last 12 outside-view runs (targets, open ports, findings). Atomic writes. |
| `security-attacks.json` | `security` + Cloudflare | Offenders of the last 7 days (address, country, counts, paths, block expiry), the day each was announced, and the last run. Atomic writes. |
| `blackbox/chain.jsonl` | `security` + `blackbox.mode: local` | The hash-chained black box, one JSON record per line. Directory `0700`, file `0600`, append-only writes, never rotated; at 1 GiB nothing more is appended (`blackbox.broken`, reason `full`). Optionally protect it with `chattr +a` as root. |
| `blackbox/head.json` | `security` + `blackbox.mode: local` | `{count, hash}` of the last record written (`0600`). A chain shorter than this after a restart is reported as `truncated`. |
| `blackbox/anchors.jsonl` | `security` + `blackbox.mode: local` | One line per nightly anchor `{date, count, hash, telegram, at}` (`0600`). |
| `blackbox-queue.jsonl` | `security` + `blackbox.mode: push` | Records not yet delivered to the monitoring server (at most 10 000, oldest dropped first); `0600`, rewritten atomically after each change. |
| `security-known-hosts` | you (`security` + SSH hosts) | OpenSSH `known_hosts` file with the **pinned host keys** of the SSH hosts. Not written by the agent: you add the entries after checking the fingerprint (see the [setup guide](../setup-guide.md#security-center)). Without it SSH checks fail with `agent.security.knownHostsMissing`; the agent uses `StrictHostKeyChecking=yes` and never learns keys on its own. |
| `secrets-meta.json` | `configfiles` | Per file and key: `{fingerprint (HMAC-SHA256 with secrets-hmac.key), firstSeenAt, lastChangedAt, changedBy, maxAgeDays?, mark?}`; per file `rotationNotifiedOn` (local date of the last rotation reminder). No values. Atomic writes. |
| `secrets-hmac.key` | `configfiles` | 32 random bytes (hex) keying the fingerprints. Never leaves the agent. |
| `research-jobs.json` | `research` | Research jobs of the last 24 h with their results (public news; no tokens, no MCP settings). |
| `claude-shots/` | `claude` + PC sessions | JPEG screenshots taken by PC sessions. The last 60 are kept. |

Other locations:

| Path | Purpose |
| --- | --- |
| `$XDG_RUNTIME_DIR/tiphys/firefox.sock` | Unix socket for the Firefox bridge (directory `0700`, socket `0600`). Override with `TIPHYS_FIREFOX_SOCKET`. |
| `~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json`, `$XDG_DATA_HOME/tiphys/firefox-host` | Written by `firefox install`. |
| `~/.local/share/applications/com.visualstudio.code.desktop` | Written by `vscode-a11y install`. |
| `$XDG_RUNTIME_DIR/tiphys/research/<job-id>/` (fallback `~/.cache/tiphys/research/`) | Research job work directory (`0700`): `draft.schema.json`, `draft.json`, `notes.md` (no MCP config: it is passed to Claude inline). Deleted 24 h after the job ends. |
| `$XDG_RUNTIME_DIR/tiphys/llm/run-*/` (fallback `~/.cache/tiphys/llm/`) | Empty `0700` working directory of a tool-less `claude -p` run (incident analysis, I-3); removed after the run. |
| `~/.local/state/tiphys/config-backups/<fileId>/<time>` (`$XDG_STATE_HOME` if set) | `configfiles`: the previous version of a config file before each save or restore (directories `0700`, files `0600`, last 10 per file). These are copies of the `.env` file, secrets included. |
| `.<name>.tiphys-<random>.tmp` next to a config file | `configfiles`: temp file of an atomic save; removed on failure, renamed over the file on success. |
| `/usr/local/lib/tiphys/audit.sh` | Root-owned installed copy of `agent/helpers/audit.sh`: used with `security.self.sudo`, and on hosts audited over SSH (installed there by `tools/install-audit.sh`). Version 2 added the `traps` and `image-save` requests, version 3 (current) NUL-safe file names in the SUID and world-writable lists, logins only from `sshd`, and traps limited to the last 10 minutes (the file's `VERSION=` line); update an installed copy by installing again. |
| `/etc/audit/rules.d/tiphys-trap.rules` (SSH host) | Written by `tools/install-audit.sh --trap`: one `-w <decoy> -p r -k tiphys_trap` line per decoy file; `--untrap` removes the line and the file. |
| Docker volume `tiphys-trivy-cache` | Trivy's vulnerability database (and Java DB when `javaDb` is on), on the monitoring server. |
| `$TMPDIR/tiphys-trivy-*`, `$TMPDIR/tiphys-gitleaks-*` | Temporary directories of a scan (a saved image tar, a bare clone of a repository); removed when the scan ends. |
| `~/.config/tiphys/security-audit-key` (+ `.pub`) | Conventional location of the restricted SSH audit key on the monitoring server (`security.hosts[].source.keyPath`). |
| `$TMPDIR/tiphys-voice-*` | Temporary audio for `/v1/transcribe`, deleted after each request. |
| `services.yaml` (`homepage.servicesPath`) | Rewritten in place when a service is added from the app. |

## Environment

| Variable | Used for |
| --- | --- |
| `TIPHYS_AGENT_CONFIG` | Config path. |
| `TIPHYS_FIREFOX_SOCKET` | Firefox bridge socket path. Must match between the agent and the native host. |
| `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, `HYPRLAND_INSTANCE_SIGNATURE`, `DBUS_SESSION_BUS_ADDRESS` | Desktop features. If they are missing from the service environment, the agent finds them under `$XDG_RUNTIME_DIR`. |
| `YDOTOOL_SOCKET` | `ydotool` daemon socket used for input. |
| `TZ` | Time zone for Claude schedules and Telegram feed schedules (also the date and time shown in newsletters). |
