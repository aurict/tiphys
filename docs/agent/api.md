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
  - [claude](#claude) · [watch](#watch) · [alerts](#alerts) · [backups](#backups) · [uptime](#uptime) · [research](#research) · [analysis](#analysis) · [telegram](#telegram) · [incidents](#incidents) · [configfiles](#configfiles) · [databases](#databases)
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
- **Audit**: every non-GET request is recorded in `audit.jsonl` as `{at, device, method, path, status, detail?}`. The body and query string are never logged. `detail` is set by some routes (`req.auditDetail`: ids, key names, counts, hashes; never values), at most 16 keys and 200 characters per string.
- **Preview tokens**: risky operations are previewed first. The preview returns `{previewToken: "tpv_…", expiresAt}`, bound to the calling device, the operation kind and a SHA-256 of the operation's input, valid for 120 s and usable once (in memory only). The execute route takes `{previewToken, confirm: true}`; a missing, expired, used or mismatched token is `409 agent.preview.invalid` (presenting a token spends it, even on a mismatch).

## Authentication

| Mechanism | Applies to | Details |
| --- | --- | --- |
| Service token | only routes that declare its scope (today: `research` → `POST /v1/research/jobs`, `GET`/`DELETE /v1/research/jobs/:id`; `analysis` → `POST /v1/analysis/jobs`, `GET`/`DELETE /v1/analysis/jobs/:id`) | `Authorization: Bearer tps_…` (header only, never `?token=`). Issued for another agent with `tiphys-agent service-token create` or `POST /v1/service-tokens`; shown once, stored as a SHA-256 hash. Any other route, including unknown paths, returns `403 agent.auth.scopeDenied`. The Tailscale identity check applies as for devices. The audit log records the caller as `service:<id>`. |
| Device token | every route except `GET /v1/health` | `Authorization: Bearer tph_…`. Created by `tiphys-agent pair`; only its SHA-256 hash is stored, and comparison is constant-time. For WebSockets the token may also be sent as the `?token=` query parameter. |
| Tailscale identity | every route except `GET /v1/health` | When `requireTailscaleLogin` is set, the `Tailscale-User-Login` header (added by `tailscale serve`) must equal it. Otherwise `403 agent.auth.tailnetUserNotAllowed`. |
| Control token | mutating desktop routes, live screen, Firefox tabs, mobile view, Sunshine actions, Claude PC sessions | `X-Tiphys-Control: tpc_…`, obtained from `POST /v1/desktop/control/session`. It must belong to the calling device and not be expired, and the `control` feature must be on. |

Failure codes: `401 agent.auth.missingToken`, `401 agent.auth.invalidToken`, `403 agent.auth.scopeDenied`, `403 agent.auth.tailnetUserNotAllowed`, `403 agent.control.sessionRequired`, `403 agent.control.disabled`.

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
| `agent.auth.scopeDenied` | 403 | Service token used on a route outside its scopes |
| `agent.serviceToken.notFound` | 404 | Unknown service token id |
| `agent.preview.invalid` | 409 | Preview token missing, expired, already used, or for another device/operation/input |
| `agent.incident.notFound` / `agent.incident.action.notFound` | 404 | Unknown incident / action candidate |
| `agent.incident.badState` | 409 | Lifecycle change not allowed from the current status (`params.status`) |
| `agent.incident.confirmRequired` | 400 | Action execute without `confirm: true` |
| `agent.incident.actionRunning` | 409 | Another action of this incident is still running |
| `agent.incident.actionUnavailable` | 409 | The candidate can't be run any more (e.g. its stack is gone) |
| `agent.incident.rateLimited` | 429 | More than 6 action executions per minute from this device |
| `agent.incident.analysisOff` | 409 | `/analyze` while `incidents.analysis.mode` is `off` |
| `agent.incident.analysisRateLimited` | 429 | More than 3 analyses of this incident per 10 minutes (manual and automatic together; `params: {limit, windowSeconds}`) |
| `agent.incident.redactedOnly` | 400 | `/bundle` without `?redacted=1` (the unredacted bundle is never served) |
| `agent.incident.bundleRateLimited` | 429 | More than 10 `/bundle` calls per 10 minutes from this device |
| `agent.analysis.notFound` | 404 | Unknown analysis job, or one another service token started |
| `agent.analysis.busy` | 429 | 1 analysis job runs and 3 wait (`params.waiting`) |
| `agent.analysis.bundleTooLarge` | 413 | Serialized job body over 192 KB |
| `agent.config.urlRequired` | 400 | `incidents.analysis.mode: "remote"` without a URL (`params.field`) |
| `agent.configfiles.notFound` | 404 | Unknown `fileId` (not a discovered config file) |
| `agent.configfiles.notEditable` | 409 | The file exists but breaks a file rule (`params.reason`: `notRegular`, `notOwner`, `tooLarge`, `badName`, `outsideRoot`, `missing`) |
| `agent.configfiles.fileChanged` | 409 | The file moved, was replaced or stopped qualifying between checks (`params.reason`); nothing was written |
| `agent.configfiles.conflict` | 409 | `baseHash` no longer matches the file (`params.hash` = current hash); preview again |
| `agent.configfiles.notText` | 409 | The file isn't valid UTF-8 |
| `agent.configfiles.keyNotFound` / `agent.configfiles.keyExists` | 404 / 409 | `unset`/`rename`/meta on a missing key; `rename` onto an existing key (`params.key`) |
| `agent.configfiles.unterminatedQuote` | 409 | The file has an unterminated quote (`params.line`); edits are refused because compose would read the lines below into it |
| `agent.configfiles.noChange` | 400 | The ops leave the file unchanged |
| `agent.configfiles.tooLarge` | 400 | The result would exceed 256 KB |
| `agent.configfiles.confirmRequired` | 400 | Save/restore without `confirm: true` |
| `agent.configfiles.nothingToRestart` | 409 | Preview with `restart: "affected"` for a file no service is affected by (e.g. an extra path) |
| `agent.configfiles.restartRateLimited` | 429 | More than 6 saves/restores with `restart: "affected"` per 10 minutes from this device (`params: {limit, windowSeconds}`); checked before the preview token is spent |
| `agent.configfiles.rateLimited` | 429 | More than 10 reveal calls per minute from this device |
| `agent.configfiles.backupNotFound` | 404 | Unknown backup id |
| `agent.db.connectionNotFound` / `agent.db.connectionExists` | 404 / 409 | Unknown connection id; `POST /v1/db/connections` with an id in use (`params.id`) |
| `agent.db.passwordRequired` | 400 | `PATCH` changes the target without a new password while one is stored (a stored password is never sent to a new address) |
| `agent.db.containerNotFound` / `agent.db.containerNotRunning` / `agent.db.networkNotFound` / `agent.db.containerNoAddress` | 404 / 409 / 404 / 409 | A `{container}` target can't be resolved (`params.container`, `state`, `network`) |
| `agent.db.credentialUnavailable` | 409 | `fromContainerEnv`, but the container env has no usable credential (`params.reason`: `passwordFile` for `*_PASSWORD_FILE`, `noPassword`, e.g. a random MySQL root password without MYSQL_USER/PASSWORD) |
| `agent.db.unreachable` | 502 | Can't connect (`params.reason`: `ECONNREFUSED`, `ETIMEDOUT`, `timeout`, …; SQLite: `open`) |
| `agent.db.authFailed` / `agent.db.databaseNotFound` | 401 / 404 | Login refused / database missing (`params.sqlState`) |
| `agent.db.emptyStatement` / `agent.db.multipleStatements` | 400 | No statement / more than one (`params.count`); checked by the agent and by the server (PostgreSQL extended protocol, MySQL prepared statements without MULTI_STATEMENTS) |
| `agent.db.statementNotAllowed` | 400 | Statement outside the read or write allowlist, or a refused name inside it (`params.keyword`, e.g. `copy`, `do`, `set`, `create`, `attach`, `vacuum`, `pragma`, `load`, `into`, `outfile`, `/*!`, `pg_read_file`, `lo_import`, `alter system`, `create function`, `create role superuser`, `with select`) |
| `agent.db.readOnly` | 409 | The database refused a write (read-only transaction / read-only SQLite handle; MySQL 1792); `params.message` (redacted driver text) |
| `agent.db.permissionDenied` | 403 | The role lacks the privilege, or the SQLite authorizer refused (non-catalog pragma); `params.message` |
| `agent.db.queryFailed` | 400 | Any other database error: `params.message` (driver text, redacted, ≤500 chars), `sqlState` (PostgreSQL, MySQL), `errno` (MySQL) or `sqliteCode`, `position?` |
| `agent.db.timeout` | 504 | The statement timeout hit (PostgreSQL `statement_timeout`/`lock_timeout`; MySQL `MAX_EXECUTION_TIME`, MariaDB `max_statement_time`, lock wait, or the agent's backstop + `KILL QUERY`; SQLite: the child process was killed) |
| `agent.db.tableNotFound` | 404 | Preview of a schema/table that isn't in the catalog |
| `agent.db.fileNotFound` | 404 | SQLite target path isn't a regular file |
| `agent.db.sqliteUnavailable` | 501 | This Node has no unflagged `node:sqlite` (needs Node ≥ 22.13; `params.node`) |
| `agent.db.busy` | 429 | Already 2 database calls running on this connection (`params.maxConcurrent`) |
| `agent.db.rateLimited` | 429 | More than 30 queries/previews/saved query runs/write previews per minute from this device (`params.perMinute`) |
| `agent.db.exportRateLimited` | 429 | More than 3 CSV exports per minute from this device (`params.perMinute`) |
| `agent.db.writeRateLimited` | 429 | More than 10 write commits per 10 minutes from this device (`params.perTenMinutes`); checked before the preview token is spent |
| `agent.db.queryNotFound` / `agent.db.tooManyQueries` | 404 / 409 | Unknown saved query (`params.id`) / already 500 saved queries (`params.max`) |
| `agent.db.writeUnsupported` | 400 | Write mode or the read-only role helper on a SQLite connection |
| `agent.db.ddlNotPreviewable` | 400 | MySQL/MariaDB DDL or account statement in the write mode (`params.keyword`): it commits implicitly, so it can't be previewed |
| `agent.db.nonTransactionalTables` | 409 | MySQL/MariaDB write mode while a user table uses a non-transactional engine (`params.tables: ["schema.table (ENGINE)"]` ≤10, `more`) |
| `agent.db.countChanged` | 409 | Write commit: the statement now affects a different number of rows than previewed (`params.expected`, `actual`); rolled back |
| `agent.db.failed` | 502 | Unexpected driver/child failure (`params.reason` or `message`) |
| `agent.research.busy` | 429 | Research queue full (1 running + 5 waiting) |
| `agent.research.notFound` | 404 | Unknown research job (or another service token's job) |
| `agent.telegram.notConfigured` | 409 | No bot token stored yet (`PUT /v1/telegram/bot`) |
| `agent.telegram.invalidToken` | 400 | Bot token malformed or rejected by Telegram (`getMe`) |
| `agent.telegram.blocked` | 502 | The recipient blocked the bot (Telegram 403); the recipient becomes `unreachable` |
| `agent.telegram.unreachable` / `.timeout` / `.apiFailed` / `.badRequest` / `.badResponse` / `.apiRateLimited` | 502 / 429 | Telegram API errors (`params.description` for `badRequest`) |
| `agent.telegram.rateLimited` | 429 | Too many requests to `/v1/telegram/*` from this device |
| `agent.telegram.feed.notFound` / `.recipient.notFound` / `.invite.notFound` / `.issue.notFound` | 404 | Unknown id |
| `agent.telegram.feedRunning` | 409 | The feed already has a run in progress (or is sending) |
| `agent.telegram.noRecipients` | 409 | Run now on a feed with no active subscriber |
| `agent.telegram.recipientStopped` | 409 | The recipient sent `/stop`; only they can rejoin (new invite) |
| `agent.telegram.issueNotAwaiting` / `.issueExpired` / `.issueNotRendered` | 409 | Approval or test on an issue in the wrong state |
| `agent.telegram.tooManyFeeds` / `.tooManyInvites` | 400 | At most 20 feeds / 20 pending invites |
| `agent.telegram.research.notConfigured` | 409 | `research` (PC URL + service token) is not set in the config |
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
| POST | `/v1/devices/revoke-all` | token | `{confirm: true}`. Revokes **every** device, including the caller, and every service token. |
| GET | `/v1/service-tokens` | device | `{tokens: [{id, name, scopes, createdAt, lastUsedAt?}]}` (never the token or its hash) |
| POST | `/v1/service-tokens` | device | Strict `{name, scopes: ["research"]}` → `201 {token, serviceToken: {id, name, scopes, createdAt}}`. The `tps_…` token is returned only here. Event `serviceToken.created`. |
| DELETE | `/v1/service-tokens/:id` | device | Revokes it → `{ok: true}`. Event `serviceToken.revoked`. |
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

### research

Feature `research` (`routes/research.ts`, `research/*.ts`). Web research for another agent (atlas's Telegram digests): Gemini via `agy` drafts, Claude edits. See [Research](../features/research.md) for the pipeline and its sandboxing.

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| POST | `/v1/research/jobs` | service (`research`) or device | Strict body (below) → `202 {id}`. `429 agent.research.busy` when 1 job runs and 5 wait. |
| GET | `/v1/research/jobs/:id` | service (`research`) or device | `{id, status: queued\|running\|done\|failed, createdAt, startedAt?, finishedAt?, error?: {code, params}, result?}`. A service token sees only jobs it started. |
| GET | `/v1/research/jobs` | device | Recent jobs for the app, newest first: `{jobs: [{id, status, createdAt, startedAt, finishedAt, error, topic, editor, requestedBy, itemCount, sourceCount, timings}]}` |
| DELETE | `/v1/research/jobs/:id` | service (`research`) or device | Cancels a queued or running job (kills its processes) → `{cancelled, job}`. `cancelled: false` if it had already finished. A service token can cancel only jobs it started. |

Request body: `{topic (1–500), instructions? (≤4000), windowHours (1–720), language? ("tr"), minItems? (1–20, default 1), maxItems (1–20, ≥ minItems), maxSourcesPerItem? (1–5, default 3), allowDomains? (≤50 hostnames), blockDomains? (≤50), excludeUrls? (≤500 http(s) URLs, ≤100 000 characters in total), editor? (default true)}`.

`result`: `{items: [{headline, summary, published?, sources: [{title, url}]}], seenUrls: [...] (only URLs from successful searxng/firecrawl tool outputs, never model-written text; normalized: no fragment, no utm_*, no trailing slash, same as source URLs; ≤5000), models: {research: "gemini-4-argon-high", editor?: "claude-sonnet"}, timings: {researchSec, editorSec?}}`. The agent enforces the rules on the final items itself: only http(s) sources, allow/block lists, at most `maxSourcesPerItem` sources and `maxItems` items, no story whose source is in `excludeUrls`, no duplicate stories.

Job `error.code` values: `agent.research.toolMissing` (`params.tool`: `agy`/`claude` not on `PATH`), `agent.research.mcpMissing` (`params.server`: no `searxng`/`firecrawl` entry in `~/.claude.json`), `agent.research.toolFailed` (`params.tool`, `status` or `exitCode`), `agent.research.invalidOutput` (`params.tool`), `agent.research.timeout` (20 min per job), `agent.research.cancelled`, `agent.research.interrupted` (the agent stopped). Jobs and their results are kept for 24 h.

### telegram

Feature `telegram` (`telegram/*.ts`). Telegram newsletters: the bot, recipients (invite only), feeds, the scheduler, research on the PC (via [research](#research) with a service token), validation, approval and the archive. See [Telegram newsletters](../features/telegram.md). Mutating routes are rate-limited per device (30/min; runs, previews and test messages also 10 per 10 min) with `429 agent.telegram.rateLimited`.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/telegram/status` | `{bot: {configured, username, id}, research: {configured, url, wakeHostId, reachable}, pendingInvites, polling}`. `reachable` probes the PC's `/v1/health` (3 s); `null` if not configured. |
| PUT | `/v1/telegram/bot` | Strict `{token}` → `{bot: {username, id}}`. Validated with `getMe`, stored in `agent.json`, never returned. |
| DELETE | `/v1/telegram/bot` | Removes the token |
| GET | `/v1/telegram/recipients` | `{recipients: [{id, chatId, firstName, lastName?, username?, addedAt, status: active\|paused\|stopped\|unreachable, statusAt?, subscriptions: [feedId]}]}` |
| PATCH | `/v1/telegram/recipients/:id` | Strict `{status?: active\|paused, subscriptions?: [feedId]}`. A `stopped` recipient can't be re-activated (`recipientStopped`); `unreachable` can. |
| DELETE | `/v1/telegram/recipients/:id` | Remove |
| POST | `/v1/telegram/recipients/:id/test` | Sends a short Turkish test message → `{ok, messageIds}` |
| GET | `/v1/telegram/recipients/:id/deliveries?limit=` | Newsletter deliveries to this recipient, newest first: `[{issueId, feedId, recipientId, status: sent\|failed\|unreachable, messageIds, error?, at, test?}]` |
| GET | `/v1/telegram/invites` | `{invites: [{id, label, feedIds, createdAt, expiresAt, status: pending\|used\|expired\|revoked, recipientId, code?, link?}]}` (`code`/`link` only while pending) |
| POST | `/v1/telegram/invites` | Strict `{label?, feedIds?}` → `{invite}` with `link: https://t.me/<bot>?start=<code>`; one use, 24 h. While an invite is pending the agent long-polls `getUpdates`. |
| DELETE | `/v1/telegram/invites/:id` | Revoke → `{invite}` |
| GET | `/v1/telegram/templates` | `{templates: [{id: daily-tech-ai\|weekly-tech-ai, feed: <feed input>}]}`: post `feed` (with the user's time) to create one |
| GET / POST | `/v1/telegram/feeds` | List / create. Body: strict feed input (below) → `{feed}` |
| GET / PUT / DELETE | `/v1/telegram/feeds/:id` | Get / replace (full input) / delete (also its issues; `409 feedRunning` while running) |
| POST | `/v1/telegram/feeds/:id/run` | Run now → `202 {issue}` (summary, status `researching`); sends (or asks for approval) when done |
| POST | `/v1/telegram/feeds/:id/preview` | Same pipeline, sends nothing → issue ends as `preview` |
| GET | `/v1/telegram/issues?feedId=&limit=` | Archive, newest first: issue summaries `{id, feedId, kind, createdAt, slotAt?, deadlineAt, expiresAt?, status, stats?, models?, error?, finishedAt?, itemCount, partCount, deliveryCounts: {sent, failed, tests}}` |
| GET | `/v1/telegram/issues/:id` | Full issue: summary fields + `items: [{headline, summary, sources: [{title, url}]}]`, `renderedParts` (Telegram HTML), `deliveries` |
| POST | `/v1/telegram/issues/:id/approve` | `awaiting_approval` → sending (background) → `{issue}`. Called by the notification's *Gönder* button. |
| POST | `/v1/telegram/issues/:id/reject` | `awaiting_approval` → `rejected`. The *Vazgeç* button. |
| POST | `/v1/telegram/issues/:id/test` | Strict `{recipientId}`: sends the issue's rendered parts to one recipient (any subscription) → `{delivery}` (`test: true`) |

**Feed input** (strict; limits match the research job input): `{name (1–80), enabled? (true), when (same as Claude schedules: daily / weekly / interval), topic (1–500), instructions? (≤4000), windowHours? (1–720, 24), language? ("tr"), minItems? (1–20, 5), maxItems? (1–20, 8, ≥ minItems), maxSourcesPerItem? (1–3, 3), allowDomains? / blockDomains? (≤50 hostnames), skipIfNothingNew? (true), approval? ({mode: auto|ask|firstN, n} = {firstN, 3}), deadlineMinutes? (5–360, 30)}`. A feed adds `{id, createdAt, anchorAt, lastSlotAt, approval.sentCount, running, nextRun, recipientIds}`.

**Issue status**: `researching → awaiting_approval → sending → sent`, or `skipped` (nothing new), `failed` (`error` code), `expired` (no decision by deadline + 2 h), `rejected`, `preview`. Issue `error` codes: `agent.telegram.research.unreachable` (PC down; after Wake-on-LAN if configured), `.research.timeout` (deadline), `.research.failed` (`params.error` = the PC job's code), `.research.unauthorized`, `.research.rejected`, `.research.badResponse`, `.research.notConfigured`, `agent.telegram.noItems`, `agent.telegram.deliveryFailed` (every recipient failed), `agent.telegram.notConfigured`, `agent.telegram.interrupted` (agent restarted mid-run).

**Notifications** (keys and params for the app; `link` opens the issue `tiphys://telegram/issues/<issueId>`):

| Key | Params | Notes |
| --- | --- | --- |
| `telegram.approval` | `feed, feedId, issueId, items, recipients` | priority high; `data: {feedId, issueId}`; actions **Gönder** (`POST …/approve`), **Vazgeç** (`POST …/reject`), tap = preview |
| `telegram.sent` | `feed, feedId, issueId, items, recipients, failed` | `recipients` = successful deliveries |
| `telegram.failed` | `feed, feedId, issueId, reason` | priority high (except `reason: agent.telegram.approvalExpired`) |
| `telegram.pcUnreachable` | `feed, feedId, issueId` | priority high; the PC couldn't be reached before the deadline |

Event-only keys (ids and counts, never content or names): `telegram.started`, `.skipped` (`reason: nothingNew|noRecipients|running`), `.missed` (`slotAt`), `.previewReady`, `.previewFailed`, `.approved`, `.rejected`, `.testSent`, `.wakeSent`, `.recipientAdded`, `.recipientStopped`, `.recipientRemoved`, `.recipientUnreachable`, `.inviteCreated`, `.groupLeft`, `.botSet`, `.botRemoved`.

### analysis

Feature `analysis` (`analysis/*.ts`), on the PC that has Claude Code. Incident analysis jobs for a server's incident room (`incidents.analysis.mode: "remote"`): a tool-less `claude -p` reads the redacted bundle and returns structured output. See [Incidents › AI analysis](../features/incidents.md#ai-analysis-i-3).

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| POST | `/v1/analysis/jobs` | service (`analysis`) or device | Strict `{bundle}` (below, ≤192 KB) → `202 {id: "aj-<16 hex>", status}`. `429 agent.analysis.busy` when 1 job runs and 3 wait. |
| GET | `/v1/analysis/jobs/:id` | service (`analysis`) or device | `{id, status: queued\|running\|done\|failed, createdAt, startedAt?, finishedAt?, durationSec?, error?: {code, params}, result?}`. A service token sees only jobs it started (others: `404 agent.analysis.notFound`). |
| GET | `/v1/analysis/jobs` | device | `{jobs: [{id, status, createdAt, startedAt, finishedAt, durationSec, error, requestedBy, incidentId, hypothesisCount}]}`, newest first |
| DELETE | `/v1/analysis/jobs/:id` | service (`analysis`) or device | Cancels a queued or running job → `{cancelled, job}` |

Jobs live in memory only (the bundle is dropped when the job ends; results are kept 24 h); 3 min per job; this queue is separate from the research queue, so an analysis never waits behind a research job. Job `error.code`: `agent.analysis.toolMissing` / `.toolFailed` / `.invalidOutput` / `.timeout` / `.cancelled` / `.interrupted` / `.failed`.

**Bundle** (built and redacted by the incident's agent): `{v: 1, language: tr|en, incident: {id, host, kind, target, severity, status, openedAt, stack?, service?, parts: [{kind, target, firstAt, lastAt, recoveredAt?}]}, hints: [{code, params}], evidence: [{id, section, text (≤4000)}] (≤1500), candidates: [{id, kind, target, risk}] (≤20), similar: [{id, kind, openedAt, resolvedAt, resolutionNote, workedAction}] (≤5), truncated: [section]}`. Evidence ids: `log:<source>#<line>` (line number within the collected excerpt), `signal:<n>`, `inspect:container`, `deploy:<n>`, `event:<n>`, `metric:<name>` (e.g. `metric:host.memPct`, `metric:disk:/`, `metric:container.cpu`), `git:<hash>` / `git:status`, `config:<n>`; sections `signals, inspect, logs, deploys, events, metrics, git, config`.

**Result** (validated against the bundle; the incident's agent validates it again): `{summary (≤600), hypotheses: [{cause (≤300), confidence 0..1, evidenceRefs: [evidence id], unsupported}] (≤5), suggestedActions: [{candidateId, kind, why (≤300)}] (≤5), questions: [string ≤200] (≤5), dropped: {actions, refs}}`. Unknown candidate ids and evidence refs not in the bundle are dropped (counted in `dropped`); a hypothesis left without a valid ref is `unsupported: true` ("kanıtsız"). All text is plain: markdown, HTML, links (replaced by `[link]`) and control/bidi characters are removed.

### incidents

Feature `incidents` (`incidents/*.ts`), device tokens only. The incident room groups alert notifications into incidents, collects context and offers confirmed actions. See [Incidents](../features/incidents.md).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/incidents?status=open\|acknowledged\|resolved\|active&limit=1..500` | `{incidents: [summary]}`, newest first. `active` = open + acknowledged. |
| GET | `/v1/incidents/deploys?stack=&service=&limit=1..500` | `{deploys: [deploy record]}`, newest first (default 100). `stack` is a stack id (or a compose project name when no stack has that id); both filters optional. Empty without the `docker` feature. |
| GET | `/v1/incidents/:id` | `{incident, similar}` (full record, below; `similar` is recomputed on every read: same fingerprint, last 90 days, ≤5, `[{id, kind, status, openedAt, resolvedAt, resolutionNote, workedAction}]`, the ones resolved with a note or a working action first) |
| POST | `/v1/incidents/:id/ack` | open → acknowledged → `{incident}` (`409 agent.incident.badState` otherwise) |
| POST | `/v1/incidents/:id/resolve` | `{note? (≤2000)}`; open/acknowledged → resolved → `{incident}` |
| POST | `/v1/incidents/:id/reopen` | resolved → open → `{incident}` |
| POST | `/v1/incidents/:id/notes` | Strict `{text (1–2000)}` → `{incident}` (timeline entry `note`) |
| POST | `/v1/incidents/:id/analyze` | Starts an AI analysis (I-3) → `202 {analysis}` (state below). A queued/running analysis is returned instead of starting another. 3 per 10 min per incident (`429 agent.incident.analysisRateLimited`); `409 agent.incident.analysisOff` when `incidents.analysis.mode` is `off`. Poll `GET /v1/incidents/:id` for the result. |
| GET | `/v1/incidents/:id/bundle?redacted=1` | "Claude ile incele": `{text, bytes, evidenceCount, truncated}` — the redacted bundle as text with the same nonce markers and "data, not instructions" framing, for a normal Claude session the app starts on the PC. `?redacted=1` is required (`400 agent.incident.redactedOnly`); 10 per 10 min per device (`429 agent.incident.bundleRateLimited`). |
| GET | `/v1/incidents/:id/actions` | `{actions: [candidate], running: candidateId \| null}` |
| POST | `/v1/incidents/:id/actions/:aid/preview` | Optional strict body `{options?: [cleanup option]}` (disk.cleanup only). → `{candidate, steps: [{argv, cwd?}], risk: low\|medium, details?, previewToken, expiresAt}`. `details` for `compose.rollback`: `{rollback: {tag, imageRef, current: {imageId, created}, previous: {imageId, created}}, warnings: ["dbMigrationsNotReverted"]}`; for `disk.cleanup`: `{cleanup: {options: [estimate], selected: [option]}}` (default selection: every available option). An unavailable option → `409 agent.incident.cleanupOptionUnavailable {option}`. |
| POST | `/v1/incidents/:id/actions/:aid/execute` | `{previewToken, confirm: true, options?}` (disk.cleanup: the same `options` as the preview; another selection → `409 agent.preview.invalid`) → `{ok, code, stderr?}` after the command finished (stderr redacted, ≤1000 chars). 6 per minute per device, one running action per incident. A post-check runs 60 s later and is written to the timeline. |
| POST | `/v1/incidents/test` | Strict `{kind: docker.died\|docker.unhealthy\|service.failed\|disk.full\|uptime.down}`: sends that notification for target `tiphys-test` through the normal path → `{incident: summary}` (`test: true`, no action candidates) |
| DELETE | `/v1/incidents/:id` | Deletes the record → `{ok: true}` |

**Summary**: `{id: "inc-<12 hex>", status: open|acknowledged|resolved, severity: critical|warning, host, kind (key of the first signal, e.g. docker.died), target, stack, service, openedAt, updatedAt, lastSignalAt, resolvedAt, signalCount, fingerprints, resolutionNote, workedAction, test}`.

**Incident** adds: `parts: [{fingerprint, kind, target, targetType: container|unit|mount|host|backup|monitor|alert, unitScope?, firstAt, lastAt, recoveredAt?}]`, `acknowledgedAt?`, `resolvedBy?` (`device:<id>` or `auto`), `recoveredAt?`, `signals: [{at, key, params}]` (last 50), `timeline: [{at, type, by?, key?, text?, data?}]` (≤300; types `opened, signal, merged, recovered, acknowledged, resolved, reopened, note, context, action, actionResult, postCheck, analysis` (`by`, `data: {status: queued, mode}`), `analysisResult` (`data: {status, hypotheses?, actions?, droppedActions?, code?}`)), `hints: [{code, params, evidence}]`, `analysis?` (below), and `context`:

- `logs: {source: docker|journal, target, lines (≤300, ≤60 KB, redacted), truncated}`
- `inspect: {name, image, imageId, created, startedAt, finishedAt, status, running, exitCode, oomKilled, restartCount, restartPolicy, health, project, service}`
- `git: {repo, log: [{hash, date, subject}], status: [porcelain lines]}` (stack repository; last 48 h, ≤10 commits)
- `metrics: {host: [{t, cpu, load1, memPct, swapPct, disks: [{mount, pct}]}], container?: {name, samples: [{t, cpu, memPct, memBytes}]}}` (±30 min around the opening, from the in-memory ring)
- `deploys: [deploy record]` (the incident's compose project, last 7 days, ≤20, newest first; a snapshot is taken first)
- `configChanges: [{at, key: config.saved|config.restored, file, keys: [name]}]` (last 48 h; the stack's files when the stack is known; key names only, ≤50)
- `events: [{at, key, params}]` (same host, last 2 h, ≤100), `similar: [{id, kind, status, openedAt, resolvedAt, resolutionNote, workedAction}]` (same fingerprint, 90 days, ≤5, resolved-with-note/action first; `kind`/`status` missing in records from before I-3), `errors?: {section: code}`, `collectedAt`

Hint codes (rule based, translated by the app as `incident.hint.<code>`): `oom`, `exitCode` (`exitCode`), `restartLoop` (`restartCount`), `unhealthy`, `recentDeploy` (`service`, `created`, `image`, `imageId`, `prevImageId?`: an image change of the incident's service within the hour before it opened, from the deploy history), `diskFull` (`mount`, `percent`), `portInUse`, `portUnreachable`. `evidence` names context sections (`inspect`, `logs`, `metrics`, `signals`, `deploys`).

**Analysis** (`incident.analysis`, I-3): `{status: queued|running|done|failed|unavailable, mode: local|remote, by: "device:<id>"|"auto", requestedAt, finishedAt?, jobId?, result? (the analysis result above), error?: {code, params}, reason?}`. `failed`: the model or validation failed (`error.code` from the job, e.g. `agent.analysis.invalidOutput`). `unavailable`: remote mode couldn't get an answer, `reason` `unreachable` (also 502/503/504), `unauthorized`, `busy`, `rejected`, `badResponse`, `timeout` (5 min), `lost` (the PC forgot the job or the agent stopped); `error.code` is `agent.incident.analysis.<reason>`. The PC is never woken; the rule hints stay. With mode `local`/`remote`, an analysis starts by itself ~10 s after the context of a new or reopened incident is collected (not for test incidents).

**Candidates**: `{id: "c-<12 hex>", kind, target, risk}`, derived by the agent from the incident only: `container.restart {container}` → `docker restart <c>`; `compose.recreate {stack, service}` → `docker compose -f <files…> up -d --no-deps <service>` in the stack directory (only for a discovered stack that has the service); `unit.restart {scope: user|system, unit}` → `systemctl [--user] --no-ask-password restart <unit>`; `compose.rollback {stack, service}` (only when `tiphys-rollback/<project>-<service>:prev` exists, differs from the running image and the service's image reference is a tag, not a digest) → `docker tag <previous image id> <image reference>`, then `docker compose -f <files…> up -d --no-deps --pull never <service>` in the stack directory; `disk.cleanup {mount}` (disk signals or a `diskFull` hint) → the selected commands: `builder` `docker builder prune -f`, `images` `docker image prune -f` (dangling only, never `-a`), `containers` `docker container prune -f --filter until=24h`, `userJournal` `journalctl --user --vacuum-time=7d`. No shell is involved. Post-checks: rollback also requires the service's container to run the previous image id (`state` `…/otherImage` otherwise); disk.cleanup reads the mount's usage (`state: "<pct>%"`, ok below 95 %).

**Deploy record**: `{at, kind: seen|changed, project, service, container, imageId, imageRef, createdAt (container creation), prevImageId, prevImageRef, rollbackTag (tag set on the previous image or null)}`. `seen` = first sighting of the service.

**Cleanup estimate**: `{option: userJournal|systemJournal|builder|images|containers, available, reason?: needsRoot|noUserJournal|noDocker, reclaimableBytes (estimate or null), usageBytes}`. `systemJournal` is always `needsRoot`; `userJournal` is `needsRoot` when the journal directory holding the user's files isn't writable by the agent user (the usual persistent journal). `images` sums the unused dangling images (shared layers make it an upper bound); `builder`/`containers` use `docker system df`.

**Notifications.** The source notification of a signal (`docker.died`, `disk.full`, …) gets `link: tiphys://incidents/<id>` and `data: {incidentId}`; there is no separate "incident opened" notification. New keys:

| Key | Params | Notes |
| --- | --- | --- |
| `incident.resolved` | `host, kind, target, incidentId` | Auto-resolve only (10 stable minutes); `data: {incidentId}` |
| `incident.analyzed` | `host, incidentId, summary (≤140)` | priority low, `data: {incidentId, silent: "1", replaceKey, replaceParams}`. Meant to **replace the incident's source notification silently**: the app derives notification ids from key + params (`noticeId`), so it should use `noticeId(replaceKey, jsonDecode(replaceParams))` as the id and show it without sound/vibration. `replaceKey`/`replaceParams` are the key and params of the incident's first source notification (e.g. `docker.died` + `{host, container, code}`). Sent as `sensitive` (model text about logs): only to endpoints with a WebPush key (end-to-end encrypted), not written to the event stream. |
| `incident.actionFailed` | `host, target, action, stage: command\|postCheck, incidentId` | priority high; `data: {incidentId}` |
| `uptime.down` / `uptime.up` | `host, monitor, monitorId` | Uptime Kuma important beat flipping down↔up (only with `incidents` on); `down` is priority high |
| `docker.unhealthy` | `host, container` | Health check turned unhealthy (only with `incidents` on), priority high |
| `docker.restartLoop` | `host, container, count` | ≥3 unexpected exits within 10 min (only with `incidents` on), priority high |

### configfiles

Feature `configfiles` (`configfiles/*.ts`), device tokens only (service tokens get `403 agent.auth.scopeDenied`). View and edit the `.env` / `env_file` files of the compose stacks and `configFiles.extraPaths`, with masked diffs, backups and restore. Routes take a `fileId` (`cf-<24 hex>`, a hash of the real path), never a path. Validation errors on these routes carry only `{path, message: <issue code>}` and never echo the request (a malformed JSON body gives `params.reason` only). See [Config files and secrets](../features/config-files.md).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/config-files` | `{files: [{fileId, file, source: stack\|extra, stack, size, modifiedAt, keys, secrets, worldReadable}], skipped: [{fileId, file, reason}]}` |
| GET | `/v1/config-files/:fileId` | `{fileId, file, source, stack, hash, size, modifiedAt, mode: "0640", warnings: [worldReadable], entries: [entry], issues: [{line, reason: syntax\|unterminatedQuote\|trailingText}]}` |
| POST | `/v1/config-files/:fileId/reveal` | Strict `{keys: [1–10 key names]}` → `{fileId, file, values: {KEY: value}, missing: [key]}`. 10 calls per minute per device. Event `secrets.revealed {file, keys (comma separated), count}` with the device; no values. |
| POST | `/v1/config-files/:fileId/preview` | Strict `{fileId?, baseHash, ops: [1–100 op], restart?: none (default)\|affected}` → `{fileId, file, baseHash, changes: [change], otherLinesChanged, affected: [{stack, project, services}], keys, restart, restartPlan?: [{stack, project, services, argv}], previewToken, expiresAt}`. `restartPlan` (with `affected`) shows the exact commands; no affected service → `409 agent.configfiles.nothingToRestart`. |
| PUT | `/v1/config-files/:fileId` | `{previewToken, confirm: true, restart: none (default)\|affected}` → `{fileId, file, hash, backupId, warnings, affected, keys, restart, recreate?: result, restore?: {route, backupId}}`. `restart` must equal the preview's (else `409 agent.preview.invalid`, token spent). With `affected` the request lasts up to ~3.5 min (command ≤3 min + 30 s post-check): clients should allow ≥240 s. `restore` is present when the recreate failed: the file stays saved, and restoring `backupId` undoes it. Event `config.saved {file, keys, backupId, restart: none\|ok\|failed, services?, stage?, failed?}`. |
| GET | `/v1/config-files/:fileId/backups` | `{fileId, file, backups: [{id, at, size}]}`, newest first (last 10 kept) |
| POST | `/v1/config-files/:fileId/restore` | `{backupId, restart?}` → preview (current → backup): same shape as `/preview` plus `backupId`. `{backupId, previewToken, confirm: true, restart?}` (same `restart` as the preview) → `{fileId, file, hash, restoredFrom, backupId (backup of the replaced version), warnings, affected, keys, restart, recreate?, restore?}`. Event `config.restored` (same params as `config.saved`; `backupId` = the restored one). |
| GET | `/v1/secrets/meta` | `{files: [{fileId, file, keys: [{key, firstSeenAt?, lastChangedAt?, changedBy?: tiphys\|external, maxAgeDays?, mark?, ageDays?, due?}]}]}` (no fingerprints) |
| PUT | `/v1/secrets/meta` | Strict `{updates: [1–100 {fileId, key, maxAgeDays?: 1–3650\|null, secret?: boolean\|null}]}` → same as GET. `secret` is the user's mark (overrides the automatic classification); `null` clears. The key must exist in the file. |

**Entry**: `{key, line, secret, reason: name|uriPassword|entropy|mark|null, masked: "••••<length>", length, value? (non-secrets only), inherited (bare KEY), quote: ""|"'"|"\"", duplicate (an earlier occurrence; the last one wins), …key meta}`. Values are what compose reads before `${VAR}` interpolation (double-quoted `\$` reads as `$$`).

**Op**: `{op: "set", key, value (≤64 KB)}` (changes the last occurrence or appends), `{op: "unset", key}` (all occurrences), `{op: "rename", key, newKey}`. Keys match `^[A-Za-z_][A-Za-z0-9_.]*$`. Untouched lines are kept byte for byte; an edited line keeps its indentation, `export`, quoting (when it can hold the value) and inline comment; new values are written literally (plain, `'single'`, or `"double"` with `\$`).

**Change**: `{key, change: added|removed|changed|renamed, from? (renamed), secret, line?, oldLine?, before?: {length, value?, inherited?}, after?: {…}}`; `value` only for non-secrets.

**Flow.** `GET` gives `hash` → `preview {baseHash, ops, restart?}` → show the masked diff (and `restartPlan`) → `PUT {previewToken, confirm: true, restart}`. The token (120 s, single use, bound to device + file + baseHash + ops + restart choice + the previewed services) carries the ops; the save re-reads the file and returns `409 agent.configfiles.conflict` if it changed. **Affected services**: services whose `env_file` is the file; for the stack's root `.env`, services whose definition references a changed key as `${KEY}`/`$KEY`.

**Recreate** (`restart: "affected"`, after the atomic write succeeded): per stack `docker compose -f <compose files…> up -d --no-deps <services…>` in the stack directory, no shell, 3 min timeout. Services are those of the preview that are still affected now and defined in the stack (validated names); the rest are reported in `skipped`. Then a post-check of up to 30 s, every 2 s: each container of a service (compose labels, one-off containers excluded) must be running and not unhealthy; exited/dead/unhealthy, a missing container or a growing restart count fail early, `healthy` passes early, otherwise it is judged at the end. **Result**: `{ok, stage?: command|postCheck, stacks: [{stack, project, services, ok, code, stderr? (last 2000 chars, ANSI stripped, redacted incl. the values the save replaced)}], services: [{stack, service, ok, state: running|running/healthy|running/starting|exited|running/unhealthy|restarting|missing|notRun}], skipped?: [{stack, project, services}]}`. On failure also the notification `config.restartFailed`. Audit detail `restart`: `none`, `ok`, `failed:command` or `failed:postCheck`.

**Background jobs.** At startup and then daily: a rescan of all files plus the rotation reminder; every 10 minutes a rescan (current secret values for redaction, external changes).

**Events and notifications** (key names only, never values):

| Key | Kind | Params | Notes |
| --- | --- | --- | --- |
| `config.saved` / `config.restored` | event | `file, keys, backupId, restart: none\|ok\|failed, services?, stage?: command\|postCheck, failed?` | With the device |
| `secret.changedExternally` | event | `file, keys (comma separated), count` | A known secret's HMAC fingerprint changed while Tiphys didn't write it (any read or rescan); its `lastChangedAt` is reset |
| `secret.rotationDue` | notification | `host, file, keys (comma separated), count` | Secrets older than their `maxAgeDays` (age from `lastChangedAt`, else `firstSeenAt`); at most one per file per local day (persisted as `rotationNotifiedOn` in `secrets-meta.json`, so a restart doesn't repeat it); `data: {fileId}` |
| `config.restartFailed` | notification | `host, file, services (failed, comma separated), stage: command\|postCheck, backupId` | priority high; `data: {fileId, backupId}`; `backupId` restores the version before the save |

### databases

Feature `databases` (`db/*.ts`; `pg` + `pg-cursor`, `mysql2` and `node:sqlite` loaded only when on), device tokens only (service tokens get `403 agent.auth.scopeDenied`). Database console: connections, discovery, schema browser, table preview and **read-only** queries for PostgreSQL, MySQL/MariaDB and SQLite (D-1, D-2); saved queries with chart hints and CSV export (D-2); the write mode — preview in a rolled-back transaction, then commit with a token — for PostgreSQL and MySQL/MariaDB (D-3). Like `configfiles`, validation errors carry only `{path, message: <issue code>}` and never echo the request. See [Database console](../features/databases.md).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/db/discover` | Running containers whose image is a database: `{containers: [{container, id, engine: postgres\|mysql\|mariadb\|redis, supported (all but redis), image, version (tag), state, project, networks: [{name, ip}], ports: [{port, hostIp?, hostPort?}], envNames: [names only], containerEnvCredential (POSTGRES_PASSWORD; MYSQL_/MARIADB_ROOT_PASSWORD, USER+PASSWORD or an allowed empty root password), connections: [ids targeting it]}]}` |
| GET | `/v1/db/connections` | `{connections: [connection], engines: {postgres: true, mysql: true, mariadb: true, sqlite: boolean}}` |
| GET | `/v1/db/connections/:id` | `connection` |
| POST | `/v1/db/connections` | Strict `{id?, name, engine: postgres\|mysql\|mariadb\|sqlite, target, database?, readCredential?, writeCredential?}` → `201 connection`. `id` defaults to `db-<8 hex>`. postgres/mysql/mariadb: `{container, network?, port?}` or `{host, port?}` target + `readCredential` (`writeCredential` optional); sqlite: `{path}` target, no credentials. `mysql` and `mariadb` use the same driver (the server flavor is detected). |
| PATCH | `/v1/db/connections/:id` | Strict `{name?, target?, database? (null clears), readCredential?, writeCredential? (null removes it)}` → `connection`. Omitted fields are kept; for each credential an omitted password (credential absent, or `{user}` without `password`) is kept only if the target is unchanged, else `400 agent.db.passwordRequired`; `password: null` removes it. The engine can't change. |
| DELETE | `/v1/db/connections/:id` | `{ok: true}` (its saved queries stay; running them gives `404 agent.db.connectionNotFound`) |
| POST | `/v1/db/connections/:id/test` | postgres: `{ok, engine, serverVersion, user, database, superuser, readOnlyDefault, latencyMs, warnings}`; mysql/mariadb: same plus `flavor: mysql\|mariadb` (`superuser`: SUPER or FILE privilege; `database` may be null); sqlite: `{ok, engine, serverVersion (SQLite version), latencyMs, warnings: []}` |
| GET | `/v1/db/connections/:id/schema` | `{conn, engine, schemas: [{name, tables: [{name, kind: table\|view\|materializedView\|foreignTable\|partitionedTable, estimatedRows (PostgreSQL planner estimate, MySQL TABLE_ROWS; null if unknown and for SQLite), columns: [{name, type, nullable, default, primaryKey}], indexes: [{name, unique, primary, definition}]}]}], truncated}`. User schemas only (no `pg_catalog`, `information_schema`, `pg_toast*`, `pg_temp_*`, partitions; MySQL: no `mysql`, `information_schema`, `performance_schema`, `sys`; index `definition` is `(col, …)`); caps 2000 tables, 30000 columns, 10000 indexes (`truncated`). SQLite: one schema `main`. |
| GET | `/v1/db/connections/:id/tables/:schema/:table/preview?limit=&timeoutMs=` | `rows` result plus `{schema, table}`; `limit` 1–5000 (default 100). Schema and table must exist in the catalog (else `404 agent.db.tableNotFound`); the query is built from the catalog's names, quoted (`"…"` / MySQL `` `…` ``, quote doubled). Counts toward the query rate limit. |
| POST | `/v1/db/connections/:id/query` | Strict `{sql (≤100000 chars), params?: [≤100 string\|number\|boolean\|null], limit?: 1–5000 (500), timeoutMs?: 1000–60000 (15000)}` → `rows` result. Placeholders: PostgreSQL `$1…`, MySQL/SQLite `?`. |
| POST | `/v1/db/connections/:id/export` | Strict `{sql, params?, timeoutMs?}` → CSV stream (see **CSV export**). |
| GET | `/v1/db/queries?connectionId=` | `{queries: [savedQuery]}` (optionally of one connection) |
| GET | `/v1/db/queries/:id` | `savedQuery` |
| POST | `/v1/db/queries` | Strict `{connectionId, name (≤80), sql, params?: [values], chart?: {type: table\|stat\|line\|bar, x?: column, y?: [≤8 columns]}}` → `201 savedQuery`. The connection must exist and the SQL must pass that engine's read allowlist (`400 agent.db.statementNotAllowed` etc.). At most 500 (`409 agent.db.tooManyQueries`). |
| PATCH | `/v1/db/queries/:id` | Strict `{connectionId?, name?, sql?, params?, chart?}` → `savedQuery` (re-validated) |
| DELETE | `/v1/db/queries/:id` | `{ok: true}` |
| POST | `/v1/db/queries/:id/run` | Strict `{params? (overrides the saved ones), limit?, timeoutMs?}` → `rows` result plus `query: {id, name, chart}` and each column's `kind: number\|datetime\|boolean\|text` (from the driver type, else from the values). Read-only path; counts toward the query rate limit. |
| POST | `/v1/db/queries/:id/export` | Strict `{params?, timeoutMs?}` → CSV stream of the saved query |
| POST | `/v1/db/connections/:id/write/preview` | Strict `{sql, timeoutMs?: 1000–60000 (15000)}` → `{conn, kind: dml\|ddl, statement (e.g. "update", "create table"), count (affected rows; null for DDL), sample?: {columns, rows (≤20), cellsTruncated} (PostgreSQL INSERT/UPDATE/DELETE), credential: write\|read, warnings: ["readCredentialUsed"?, "superuserCredential"?], previewToken, expiresAt, elapsedMs}`. Runs the statement with the write credential (else the read one) in a transaction that is always rolled back. Counts toward the query rate limit. |
| POST | `/v1/db/connections/:id/write/commit` | Strict `{previewToken, confirm: true}` → `{conn, committed: true, count, elapsedMs}`. Re-runs the previewed SQL in a transaction; COMMIT only if the count equals the previewed count, else ROLLBACK + `409 agent.db.countChanged {expected, actual}`. The token is bound to device, connection, SQL hash and count, valid 120 s, single use (`409 agent.preview.invalid`). 10 commits per 10 minutes per device (`429 agent.db.writeRateLimited`, checked before the token is spent). |
| GET | `/v1/db/connections/:id/readonly-role-sql?role=` | `role` `[a-z_][a-z0-9_]{0,62}` (default `tiphys_ro`) → `{conn, engine, role, password (fresh, random), statements: [sql], runVia: writeMode\|client, requires}`. PostgreSQL: `CREATE ROLE … LOGIN PASSWORD … NOSUPERUSER … CONNECTION LIMIT 5 IN ROLE pg_read_all_data` (14+), runnable through the write mode. MySQL/MariaDB: `CREATE USER …` + `GRANT SELECT, SHOW VIEW ON <database>.* (or *.*)` — account statements commit implicitly and can't be previewed, so `runVia: "client"` (mysql CLI). Nothing is executed or stored by this call. |
| GET | `/v1/db/restore-tests` | `{running: {testId, runId} \| null, tests: [{…test, running, last: result \| null, nextRunAt: ISO \| null}]}` |
| POST | `/v1/db/restore-tests` | Strict test (below) without `anchorAt` → `201 test`. Errors: `409 agent.db.restoreTestExists`, `404 agent.db.connectionNotFound`, `400 agent.db.restoreEngineMismatch` (connection engine differs), `400 agent.db.sanityNotAllowed {index, keyword}`, `400 agent.db.dumpOutsideRoots`. |
| PATCH | `/v1/db/restore-tests/:id` | Any subset of the test fields (`connectionId: null` clears); merged and validated as a whole. A changed `schedule` restarts the interval slots. |
| DELETE | `/v1/db/restore-tests/:id` | `{ok: true}` (also deletes its results); `409 agent.db.restoreBusy` while it runs |
| POST | `/v1/db/restore-tests/:id/run` | `202 {started: true, testId, runId}`; the run continues in the background. `409 agent.db.restoreBusy` when any test is running (one at a time), `404 agent.db.restoreTestNotFound`. |
| GET | `/v1/db/restore-tests/:id/results` | `{testId, results: [result]}`, newest first, last 20 |

**restore test** (D-4): `{id (a-z0-9-), name, connectionId?, engine: postgres\|mysql\|mariadb, image, dumpGlob, format: sql\|custom\|gz, sanity: [{sql, expect: {op: ">"\|"="\|">="\|"<"\|"<=", value: number}}] (≤20), schedule: {kind: daily\|weekly\|interval, …} (same `when` shape as Claude schedules) \| null, enabled, anchorAt}`. `image` must be an official `postgres:`, `mysql:` or `mariadb:` image with an explicit tag (no `latest`, digest or registry prefix) of the engine; `custom` is PostgreSQL only; `gz` is gzipped SQL. `dumpGlob`: absolute (`~` allowed), wildcards only in the last segment, no `..`, its directory inside `allowedRoots` or the directory of a `backups` file check; the newest matching file is restored (its real path is checked again on every run, so symlinks can't leave the roots). Each `sanity.sql` is one read statement (`SELECT`/`WITH`/`VALUES`/`TABLE`/`SHOW`, same denylist as the console) returning one number in its first column; it runs in a read-only session.

**restore result**: `{id: "r-<12 hex>", testId, trigger: manual\|schedule, startedAt, finishedAt, ok, reason, detail, image, dumpFile (base name), dumpBytes, dumpModifiedAt, rowsChecked (sanity queries that returned a number), failures: [{index, reason: queryFailed\|notNumeric\|expectation, actual?, expected: "> 0"}], durations: {startMs, readyMs, restoreMs, sanityMs, totalMs}}`. `reason` (null when ok): `noDump`, `dumpOutsideRoots`, `insufficientDisk` (free space below 2× the dump), `imageVersionMismatch` (the connection's container image major differs), `dockerFailed`, `notReady`, `restoreFailed` (client exit ≠ 0; `detail` = first error line), `dumpCorrupt` (gz stream error), `sanityFailed`, `timeout` (30 min), `shutdown`. Results are kept in `db-restore-results.json` (0600, last 20 per test). Notifications `db.restoreTest.ok {host, name}` and `db.restoreTest.failed {host, name, reason}` (link `tiphys://system/backups`). The scheduler checks every 20 s; a due test is skipped while another one runs. Audit detail `{restoreTest}`.

**connection**: `{id, name, engine, target, database (null = default), readCredential, writeCredential, warnings: ["superuserCredential"] (read credential fromContainerEnv: the container's POSTGRES_USER / MySQL root is a superuser, so only the transaction-level protections apply)}`; each credential is `{mode: "password", user, hasPassword} | {mode: "fromContainerEnv"} | null`. Passwords are never returned; `GET /v1/config` doesn't include databases at all.

**savedQuery**: `{id: "q-<12 hex>", connectionId, name, sql, params, chart: {type, x?, y?}, createdAt, updatedAt}` (stored in `db-queries.json` next to `agent.json`, mode 0600).

**rows result**: `{conn, columns: [{name, type}], rows: [[cell]], rowCount, truncated, cellsTruncated, limit, elapsedMs}`. `type` is the PostgreSQL type name (`int4`, `text`, `timestamptz`, …, `oid:<n>` for others), the MySQL type (`int`, `bigint`, `decimal`, `varchar`, `datetime`, `blob`/`text`, `json`, …) or SQLite's declared type (may be null). A cell is a string, number, boolean or null: `int8`/`numeric`/MySQL `BIGINT`/`DECIMAL` and integers beyond 2^53 come as strings, date/time types as the server's text, `bytea`/BLOB as `"<n bayt>"`, JSON/arrays as JSON text; text over 4 KB (UTF-8) is cut and ends in `…` (counted in `cellsTruncated`). `truncated`: more rows than `limit`, or the whole result passed 8 MB of cell data.

**CSV export**: `200 text/csv; charset=utf-8`, `content-disposition: attachment; filename="<conn|query id>-<UTC time>.csv"`, UTF-8 BOM, header row, CRLF, RFC 4180 quoting; text cells starting with `=`, `+`, `-`, `@`, tab or CR get a leading `'` (formula-injection guard; plain numbers like `-12.5` are left alone); cells are not cut at 4 KB. Read-only path; caps 100 000 rows and 50 MB of CSV and 5 min wall clock; past a cap the export just ends. Headers `x-tiphys-max-rows`, `x-tiphys-max-bytes`; HTTP trailers `x-tiphys-rows`, `x-tiphys-truncated` (a proxy may drop trailers: treat exactly 100 000 rows as possibly truncated). Errors before the first row are normal JSON errors; a failure mid-stream aborts the response. 3 exports per minute per device (`429 agent.db.exportRateLimited`). SQLite results are collected in the child (up to the caps) before streaming.

**Read-only layers**: (1) the agent accepts one statement whose first keyword is a read kind — PostgreSQL `SELECT`, `WITH`, `VALUES`, `TABLE`, `EXPLAIN`, `SHOW`; MySQL also `DESCRIBE`/`DESC`; SQLite `SELECT`, `WITH`, `VALUES`, `EXPLAIN` — or DML (`INSERT`/`UPDATE`/`DELETE`/`MERGE`, MySQL/SQLite `REPLACE`), which then fails in the database; everything else is `agent.db.statementNotAllowed` — a superuser's `COPY … TO PROGRAM`, `DO`, `LOAD`, MySQL `LOAD DATA`, `SET GLOBAL`, `HANDLER` are not stopped by a read-only transaction. The lexer knows each dialect's quotes and comments (PostgreSQL dollar quotes and nested comments; MySQL backslash escapes, `#` and `-- ` comments). Also refused anywhere (read and write): MySQL executable comments and optimizer hints (`/*! */`, `/*M! */`, `/*+ */`, `params.keyword: "/*!"`), MySQL `INTO` in read statements (`INTO OUTFILE/DUMPFILE/@var`), `LOAD_FILE`, `OUTFILE`, `DUMPFILE`; PostgreSQL server-file/program/remote/admin functions (`pg_read_file`, `pg_read_binary_file`, `pg_ls_*`, `pg_stat_file`, `lo_import`/`lo_export`/`lo_*` writers, `dblink*`, `query_to_xml*`, `pg_terminate_backend`, `pg_reload_conf`, replication slot/origin functions …), quoted or not; `params.keyword` names it. PostgreSQL: (2) session `default_transaction_read_only=on` and `standard_conforming_strings=on`, (3) `BEGIN READ ONLY` + `set_config('statement_timeout', …, true)`, (4) the statement runs through a cursor (extended protocol: the server refuses multiple statements), (5) always `ROLLBACK`, one connection per request. MySQL/MariaDB: no multi statements and no `LOCAL_FILES` client flag; `sql_mode` without `NO_BACKSLASH_ESCAPES`/`ANSI_QUOTES`/`ANSI`; MariaDB `max_statement_time` (every statement) or MySQL `MAX_EXECUTION_TIME` (SELECT only); `SET SESSION TRANSACTION READ ONLY` + `START TRANSACTION READ ONLY`; the statement is a server-side prepared statement (one statement, real parameters); always rolled back (or the connection dropped once enough rows came); past the timeout + 5 s the socket is dropped and `KILL QUERY` is sent. SQLite: a child process opens the file read-only with `query_only`, an authorizer refusing `ATTACH`/`DETACH`/non-catalog pragmas, and is killed at the timeout (+3 s grace); the path must be inside `allowedRoots`.

**Write mode** (PostgreSQL, MySQL/MariaDB; SQLite → `400 agent.db.writeUnsupported`): one statement from the write allowlist, plus the function denylist above. PostgreSQL: `INSERT`, `UPDATE`, `DELETE`, `MERGE` (also after `WITH`), `CREATE`/`ALTER`/`DROP` `TABLE`/`INDEX`/`VIEW`/`MATERIALIZED VIEW`, and `CREATE ROLE|USER` with only safe attributes (`LOGIN`, `PASSWORD`, `NOSUPERUSER`…, `CONNECTION LIMIT`, `VALID UNTIL`, `IN ROLE pg_read_all_data`). Never `COPY` (to/from program or file), `DO`, `CALL`, `SET`, `ALTER SYSTEM`, `ALTER ROLE`, `GRANT`/`REVOKE`, `TRUNCATE`, `CREATE FUNCTION/PROCEDURE/TRIGGER/EXTENSION` (no function definitions in any language, trusted or not), `DROP ROLE/DATABASE`. The transaction is `BEGIN READ WRITE` with `statement_timeout` and `lock_timeout` = `timeoutMs`; DDL runs inside it (rolled back on preview). Preview of INSERT/UPDATE/DELETE runs as `WITH tiphys_w AS (<stmt> RETURNING *) SELECT count(*) OVER (), * FROM tiphys_w LIMIT 20` in a savepoint (falls back to the plain statement when that form is refused, e.g. MERGE on PostgreSQL 16 → count only). MySQL/MariaDB: `INSERT`, `UPDATE`, `DELETE`, `REPLACE` (also after `WITH`); DDL/account statements (`CREATE`, `ALTER`, `DROP`, `RENAME`, `TRUNCATE`, `GRANT`, `REVOKE`) commit implicitly → `400 agent.db.ddlNotPreviewable`; `START TRANSACTION READ WRITE`, `innodb_lock_wait_timeout`, MariaDB `max_statement_time` (MySQL has no server-side DML timeout: the socket is dropped + `KILL QUERY`); count = matched rows. If any user base table uses a non-transactional engine (MyISAM, Aria, MEMORY, …) the write mode refuses (`409 agent.db.nonTransactionalTables {tables: ["schema.table (ENGINE)"], more}`), since a preview could not be rolled back there. Every commit attempt is appended to `db-writes.jsonl` before COMMIT.

**Limits**: rows default 500, max 5000; cell 4 KB; result 8 MB; timeout default 15 s, max 60 s (schema: 60 s; test: 15 s); ≤2 concurrent calls per connection (`agent.db.busy`); 30 queries + previews + saved query runs + write previews per minute per device (`agent.db.rateLimited`); 3 exports per minute; 10 write commits per 10 minutes. Driver error text is passed through `redact` and cut at 500 characters.

**Audit**: connection changes and tests `{conn}` (PATCH also `fields`); queries `{conn, sqlSha256, rows, truncated}`; saved query changes `{query, conn, sqlSha256}`, runs `{query, conn, sqlSha256, rows, truncated}`; exports `{conn, sqlSha256, rows, truncated, bytes}` (or `failed: <code>`); write previews `{conn, sqlSha256, rows (-1 for DDL), preview: true}`; commits `{conn, sqlSha256, rows, write: true}` — never the SQL text or result values. GET routes (schema, preview, discover, saved query list, role helper) are not audited. **Write log** `db-writes.jsonl` (next to `agent.json`, 0600, kept as `.1` past 5 MB): one line per commit attempt that ran, `{at, device, conn, engine, sql (full text; a role password literal is masked), sqlSha256, count, outcome: committed|countChanged|commitFailed, expected?}`.

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
