# Agent configuration

The Tiphys agent (`tiphys-agent`) runs once per machine (for example on the PC `argo` and on the server `atlas`). Everything it does is controlled by one JSON file, `agent.json`, plus a small set of CLI commands. This page is the reference for both.

For first-time setup see [Getting started](../getting-started.md). The HTTP API is documented in [api.md](api.md), and the threat model in [Security](../security.md).

## Location

| Source | Path |
| --- | --- |
| Default | `~/.config/tiphys/agent.json` |
| Environment | `TIPHYS_AGENT_CONFIG=/path/to/agent.json` |
| CLI flag | `tiphys-agent <command> --config /path/to/agent.json` (overrides both) |

The file is always written atomically (temp file and rename) with mode `0600`. Its directory is created with mode `0700`. The agent writes its state files to the same directory (see [Files on disk](#files-on-disk)).

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
| `serviceTokens` | array | `[]` | Scoped tokens for other agents: `{id, name, scopes: ["research" | "analysis"], tokenHash, createdAt, lastUsedAt?}`. Only the hash is stored; `lastUsedAt` is updated at most hourly. Managed by `service-token` and the app. A service token can call only routes of its scopes (see [api.md](api.md#authentication)). |
| `allowedRoots` | string[] | `["~"]` | Directories that path-based features may touch: git, the Claude working directory and the folder picker. Paths are resolved with `realpath` (symlinks followed) before the check. `~` is expanded. |
| `claude` | object | see [claude](#claude) | Claude Code profiles. |
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
| `stacks` | object | `{roots: ["~/stack"]}` | Where compose stacks are discovered. See [stacks](#stacks). |
| `incidents` | object | `{links: [], analysis: {mode: "off", language: "tr"}}` | Incident room options (links, AI analysis). See [incidents](#incidents). |
| `configFiles` | object | `{extraPaths: []}` | Extra `.env` files for the config editor. See [configFiles](#configfiles). |
| `databases` | object | `{connections: [], restoreTests: []}` | Database console connections (credentials stay here; saved queries in `db-queries.json`, write log in `db-writes.jsonl`). See [databases](#databases). |

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
| `analysis` | `false` | Incident analysis jobs (`/v1/analysis/jobs`) for another agent holding an `analysis` service token (a server's incident room in `remote` mode): a tool-less `claude -p` (no built-in tools, no MCP, no user settings) reads the redacted bundle; output is schema-checked. Turn on only where Claude Code is installed. See [Incidents › AI analysis](../features/incidents.md#ai-analysis-i-3). | low (spends the user's Claude subscription; the model can't act) |
| `research` | `false` | Web research jobs (`/v1/research/jobs`) run with `agy` (Gemini) and `claude` for another agent holding a `research` service token. The tools may only use the searxng/firecrawl MCP servers and write in the job's work directory; shell commands are denied. See [Research](../features/research.md). | medium (spends the user's AI subscriptions) |

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
| `clipboardSync` | `true` | When the PC clipboard changes, send its text to the phone as a silent, end-to-end encrypted `clipboard.pc` notification. Only text up to 3000 bytes is sent. Password-manager content is skipped, and the notification is sent only to endpoints that have WebPush keys. The agent rereads this setting on every check, so changes need no restart. |

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

## Editing from the app

The app reads the redacted config with `GET /v1/config` and changes it with `PATCH /v1/config` (agent settings screens).

**Redaction.** Secrets never come back to the phone:

- token hashes are dropped, and devices are returned as `{id, name, createdAt}` only
- `push.endpoints` is reduced to `{deviceId}`, and `push.token` becomes `hasToken`
- for `uptimeKuma`, `sunshine` and `alerts.grafana`, the password or token becomes `hasPassword` / `hasToken`
- `telegram` becomes `{configured, username}` and `research` becomes `{url, wakeHostId, hasToken}`
- `incidents.analysis` becomes `{mode, url, language, hasToken}`
- `databases` is left out (connections are read through `/v1/db/connections`, without passwords)

**Patchable fields:** `name`, `features` (partial), `allowedRoots`, `claude`, `homepage`, `pushToken` (string or `null`), `uptimeKuma`, `sunshine`, `wake`, `watch`, `alerts`, `transcribe`, `desktop`, `backups`, `research` (`{url, token?, wakeHostId?}` or `null`), `stacks` (`{roots}`), `incidents` (`{links?, analysis?: {mode, url? (null clears), token?, language?}}`; an omitted part is kept), `configFiles` (`{extraPaths}`). The bot token has its own route (`PUT /v1/telegram/bot`). Unknown keys are rejected. The phone **cannot** change `listen`, `requireTailscaleLogin`, `devices`, `serviceTokens` or push endpoints this way (service tokens have their own routes, `/v1/service-tokens`; they are not part of `GET /v1/config`).

**Password fields.** For `uptimeKuma.password`, `sunshine.password`, `alerts.grafana.token`, `research.token` and `incidents.analysis.token`, an omitted value keeps the stored secret, but only if the URL is unchanged. If the URL changes and no new secret is sent, the request fails with `agent.config.passwordRequired`, so an old secret is never sent to a new host. Sending `null` for the section removes it.

**Restart.** The response is `{config, restartRequired}`. `restartRequired` is `true` when the patch contained `features` or `alerts`. The agent does not restart itself. Restart the service, for example `systemctl --user restart tiphys-agent` if you installed it as a user unit. In practice, these settings take effect as follows:

| Setting | Takes effect |
| --- | --- |
| `name`, `allowedRoots`, `claude`, `homepage`, `pushToken`, `wake`, `transcribe`, `sunshine`, `desktop.clipboardSync`, `backups.checks`, `research`, `stacks`, `incidents`, `configFiles` | Immediately (read on each use) |
| `features.control = false` | Immediately. The open control session ends at once. |
| other `features`, `alerts` | After restart (`restartRequired: true`) |
| `uptimeKuma`, `watch` | After restart. The bridge and watcher read these only at startup, but the response does **not** set `restartRequired` for them. |

## CLI

The binary is `tiphys-agent`, which is `node agent/dist/cli.js` after `npm run build`. Every command accepts `--config PATH`.

| Command | Description |
| --- | --- |
| `tiphys-agent serve` | Runs the agent in the foreground (use a systemd user unit in production). Opens the Firefox bridge socket when `desktop` is on. If the previous run ended without a clean shutdown, it sends an `agent.restarted` notification. Stops cleanly on `SIGTERM`/`SIGINT`. |
| `tiphys-agent init [--name NAME] [--features a,b,c] [--tailscale-login LOGIN]` | Creates the config file if it is missing, then applies the options. `--features` is an **exact list**: listed flags are turned on and **every other flag is turned off**. |
| `tiphys-agent pair --name "Phone" [--url https://argo.my-tailnet.ts.net]` | Adds a device and prints a QR code. The QR holds `{"v":1,"type":"tiphys-pair","agent","url","token"}`. The address and token are also printed for manual entry. The token (`tph_…`) is shown only once. Scan it in the app's agent pairing screen. **Always pass `--url`**: the default is `http://<listen.host>:<listen.port>`, which is a loopback address the phone cannot reach. |
| `tiphys-agent devices` | Lists paired devices (`id`, `name`, `createdAt`, tab-separated). |
| `tiphys-agent revoke <device-id>` | Removes a device and its push endpoint. |
| `tiphys-agent service-token create --name NAME --scope research\|analysis` | Creates a scoped service token (`tps_…`) and prints it **once**; only its hash is stored. Give it to the other agent (e.g. atlas's `research.token`, a server's `incidents.analysis.token`). |
| `tiphys-agent service-token list` | Lists service tokens (`id`, `name`, `scopes`, `createdAt`, `lastUsedAt`, tab-separated). |
| `tiphys-agent service-token revoke <id>` | Revokes a service token. |
| `tiphys-agent run -- CMD [ARGS…]` | Runs a command with inherited stdio. When it exits, sends `command.done` (exit 0) or `command.failed` with the duration and exit code, then exits with the same code. Only the program name of the command is written to the event log; the notification shows up to 120 characters of the full command line. |
| `tiphys-agent schema` | Prints the JSON Schema of the app's `.tiphys.json` profile file (`npm run schema` writes it to `schema/tiphys.schema.json`). This is the app profile, not `agent.json`. |
| `tiphys-agent firefox install` | Registers the Firefox native-messaging host. It writes the manifest `~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json` and the launcher `$XDG_DATA_HOME/tiphys/firefox-host`, and prints the path of the newest unsigned XPI in `firefox/dist/` if one exists. Needs a built agent (`npm run build`). See [Firefox bridge](../features/firefox-bridge.md). |
| `tiphys-agent vscode-a11y install` / `remove` | Adds or removes `--force-renderer-accessibility` in a user copy of the Flatpak VS Code launcher (`~/.local/share/applications/com.visualstudio.code.desktop`). VS Code then exposes its accessibility tree to the mobile view. Files it did not write are left alone. See [Remotes and mobile view](../features/remotes-and-mobile-view.md). |

Pairing and revoking can also be done from the app: `DELETE /v1/devices/:id` and "lock everything" (`POST /v1/devices/revoke-all`).

## Files on disk

All state files sit next to `agent.json` (by default in `~/.config/tiphys/`) and are written with mode `0600`.

| File | Written by | Content |
| --- | --- | --- |
| `agent.json` | config store | The configuration. |
| `events.jsonl` | always | Event log: every notification (except sensitive ones such as clipboard text) and non-notifying events such as Docker restarts, git commits/pushes, control session start/end and `ui.opened`. Rotated to `events.jsonl.1` above 2 MB. |
| `audit.jsonl` | always | One line for every non-GET request: `{at, device, method, path, status}`. Bodies and query strings are never logged. Rotated to `audit.jsonl.1` above 1 MB. |
| `agent-runs.json` | `serve` | The last 50 start/stop records, used to detect unexpected restarts. |
| `control-indicator.json` | `desktop` | The Hyprland border colour and width saved while a control session is open. Restored and deleted on the next start if the agent crashed. |
| `a11y-state.json` | `desktop` + mobile view | The previous `org.a11y.Status.IsEnabled` value. Restored when the last view closes or on startup. |
| `claude-sessions.json` | `claude` | Live Claude sessions, restored after an agent restart. |
| `claude-schedules.json` | `claude` | Scheduled Claude tasks. |
| `telegram-state.json` | `telegram` | Recipients (chat id, names, status, subscriptions), invites, feeds, the `getUpdates` offset and the newsletter archive (last 60 issues per feed with items, rendered parts and deliveries). No tokens. A corrupt file is moved aside to `telegram-state.json.corrupt-<time>` and the agent starts empty (event `telegram.stateCorrupt`). |
| `incidents/` | `incidents` | Directory (`0700`): `index.json` (summaries) and `<id>.json` per incident (redacted logs, inspect summary, git log/status, metrics, deploys, timeline, notes). Atomic writes, `0600`. Resolved incidents are deleted after 90 days; at most 500 are kept (oldest resolved first). `deploys.jsonl` (`incidents` + `docker`, `0600`): compose service image changes (ids, references, container names; no env); rotated at 1 MB to `deploys.jsonl.1`. |
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
