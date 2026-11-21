# Agent API reference

> **Internal and unstable.** This API exists for the Tiphys app and is versioned together with it. The app expects an agent of the **same release**: it reads `version` from `/v1/health` and warns when the two don't match. Paths, shapes and error codes can change in any release without notice. Don't build third-party clients on it.

Source of truth: `agent/src/server.ts` (registration), `agent/src/routes/*.ts`, `agent/src/claude/*.ts`, `agent/src/control.ts`, `agent/src/atspi.ts`, and the other modules linked below. Configuration and feature flags are described in [configuration.md](configuration.md); the security model is in [Security](../security.md).

## Contents

- [Conventions](#conventions)
- [Authentication](#authentication)
- [Control sessions](#control-sessions)
- [Errors](#errors)
- [Platforms](#platforms)
- [Endpoints](#endpoints)
  - [Always available](#always-available)
  - [system](#system) · [services](#services) · [docker](#docker) · [power](#power) · [wake](#wake) · [ports](#ports) · [transcribe](#transcribe) · [git](#git) · [homepage](#homepage)
  - [desktop](#desktop): [clipboard, screenshot, open](#clipboard-screenshot-open) · [media](#media) · [windows and apps](#windows-and-apps) · [Sunshine](#sunshine) · [Firefox bridge](#firefox-bridge) · [mobile view](#mobile-view-at-spi) · [live screen](#live-screen)
  - [claude](#claude) · [agy](#agy) · [watch](#watch) · [alerts](#alerts) · [backups](#backups) · [uptime](#uptime) · [research](#research) · [analysis](#analysis) · [telegram](#telegram) · [incidents](#incidents) · [configfiles](#configfiles) · [databases](#databases) · [security](#security) · [screen](#screen) · [gamemode](#gamemode)
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
| Service token | only routes that declare its scope (today: `research` → `POST /v1/research/jobs`, `GET`/`DELETE /v1/research/jobs/:id`; `analysis` → `POST /v1/analysis/jobs`, `GET`/`DELETE /v1/analysis/jobs/:id`; `security-report` → `GET /v1/security/raw`; `blackbox` → `POST /v1/blackbox/append`; `lockdown` → `POST /v1/security/lockdown/remote`; `screen` → `WS /v1/screen/feed` (every topic); `gamemode` → `WS /v1/screen/feed` (music, spectrum and truck topics only) and `WS /v1/gamemode/feed`) | `Authorization: Bearer tps_…` (header only, never `?token=`). Issued for another agent with `tiphys-agent service-token create` or `POST /v1/service-tokens`; shown once, stored as a SHA-256 hash. Any other route, including unknown paths, returns `403 agent.auth.scopeDenied`. The Tailscale identity check applies as for devices. The audit log records the caller as `service:<id>`. A request with an unknown `tps_`/`tph_` token on any route is the same `401 agent.auth.invalidToken`, and if the token is a security-center decoy it also raises an alarm (see [traps](#traps-and-alerts)). |
| None (own credential) | `POST /v1/security/lockdown` only (route config `public`) | Needs no token, because the phone and its token are lost: the body's recovery code is the credential (see [lost phone](#lost-phone-and-lockdown)). The Tailscale-login check **still applies** (`403 agent.auth.tailnetUserNotAllowed` when `requireTailscaleLogin` is set and the header differs). Rate limited per address and in total, see the error table. |
| Display token (screen mode kiosk) | `WS /v1/screen/live`, `GET /v1/screen/art`, static `GET /screen/*` and their `/v1/gamemode/live`, `/v1/gamemode/art`, `/gamemode/*` aliases (route config `kiosk`) | The local kiosk Firefox reaches the agent on `127.0.0.1` without Tailscale headers, so these routes skip the device-token **and** Tailscale-identity checks. Static files hold no secrets. The live socket and the art proxy need `?t=<display token>`: 32 random bytes (hex), made at each start, in memory only, invalid after stop. See [screen](#screen). |
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
- Not possible on this operating system: `501 agent.feature.unsupported`, `params: {feature, platform}`. `feature` is a
  feature or a part of one (`services.logs`, `processes.signal.INT`, …); `platform` is Node's name (`linux`,
  `darwin`, `win32`). `GET /v1/health` lists them as `unsupported` (see [Platforms](#platforms)).

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
| `agent.update.disabled` | 403 | `POST /v1/update/apply` while the `update` feature is off |
| `agent.update.notManaged` | 409 | Not an `install.sh` install (git checkout, package, Docker): update it the way it was installed |
| `agent.update.confirmRequired` | 400 | Body is not `{version: "x.y.z", confirm: true}` |
| `agent.update.badVersion` | 400 | `version` is not `x.y.z` (`params.version`) |
| `agent.update.notNewer` | 409 | `version` is not newer than the running one (`params.current`, `params.version`); downgrades are refused |
| `agent.update.unsupportedPlatform` | 409 | No release bundle for this OS/CPU (`params.platform`, `params.arch`) |
| `agent.update.noKey` | 503 | This build has no release signing key (placeholder in `update_key.ts`); self-update is impossible |
| `agent.update.busy` | 409 | Another update is being applied |
| `agent.update.unreachable` | 502 | Release server not reachable or answered with an error (`params.status`) |
| `agent.update.missingAsset` | 502 | `SHA256SUMS`, its signature, or this platform's bundle is missing in the release (`params.file`) |
| `agent.update.badSignature` | 502 | `SHA256SUMS.sig` is not a valid signature of the release key; nothing was changed |
| `agent.update.badChecksum` | 502 | The bundle's SHA-256 differs from `SHA256SUMS`; nothing was changed |
| `agent.update.badBundle` | 502 | The bundle is not the requested version or is incomplete (`params.reason`: `content`, `tooLarge`) |
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
| `agent.screen.noSource` | 409 | Start or mode switch whose layout reads a source that isn't configured (`params.sources`) |
| `agent.screen.noDisplay` | 503 | Screen mode start without a Hyprland session |
| `agent.screen.startFailed` | 502 | `systemd-run` could not start the kiosk unit (`params.stderr`) |
| `agent.screen.bindTaken` | 409 | `scratch` placement: `screen.scratchBind` is already bound in Hyprland (`params.bind`); nothing was changed |
| `agent.screen.notFocus` | 409 | `POST /v1/screen/focus` while the Focus mode isn't running |
| `agent.screen.notRunning` | 409 | `POST /v1/screen/veil` while no screen mode runs |
| `agent.screen.badLayout` | 400 | A layout whose template doesn't belong to the mode, or a card kind the template can't hold or twice (`params.mode`, `template`, `kind`) |
| `agent.screen.noArt` | 404 | As `agent.gamemode.noArt`, on `/v1/screen/art` |
| `agent.gamemode.noSource` | 409 | Game mode start without a source agent configured |
| `agent.gamemode.noDisplay` | 503 | Game mode start without a Hyprland session |
| `agent.gamemode.startFailed` | 502 | `systemd-run` could not start the kiosk unit (`params.stderr`) |
| `agent.gamemode.noArt` | 404 | No such cover: not the current song, not https, too large, not an image, or a wrong display token |
| `agent.gamemode.noGame` | 404 | No Linux ETS2 found in the Steam libraries |
| `agent.gamemode.pluginDownloadFailed` | 502 | The pinned ETS2 plugin release could not be downloaded |
| `agent.gamemode.pluginHashMismatch` | 502 | The download or the plugin inside does not match the pinned SHA-256 |
| `agent.gamemode.pluginBadArchive` | 502 | The release zip does not hold the plugin file |
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
| `agent.security.hostNotFound` | 404 | Unknown host id (`params.id`) |
| `agent.security.hostExists` | 409 | `POST /v1/security/hosts` with an id in use, or `self`, or an id the app uses as a screen name (`settings`, `vulns`, `secrets`, `scanners`, `traps`, `exposure`, `attacks`, `cloudflare`, `blackbox`, `recovery`, `lockdown`); `POST /v1/security/lockdown/targets` with an id in use (`params.id`) |
| `agent.security.tooManyHosts` | 409 | More than 20 additional hosts (or 20 lockdown targets) |
| `agent.security.selfPermanent` | 409 | `DELETE /v1/security/hosts/self` |
| `agent.security.tokenRequired` | 400 | An `agent` source without a token (on create, or on `PATCH` when the URL changed); a `registryAuth` entry that is new and has no token; `block: true` without a Cloudflare block token; black box `push` without URL or token |
| `agent.security.noReport` | 409 | Accept baseline for a host that has no report yet |
| `agent.security.changesMoved` | 409 | Accept baseline: the list changed since the user looked (`params.expected`, `current`) |
| `agent.security.rateLimited` | 429 | More than 6 checks per 10 minutes per device (`/check`), 10 raw reports per 10 minutes per caller (`/raw`), 3 scan/run calls per 10 minutes per device (images, secrets, exposure and attack runs share the limit), 10 black box appends per minute per token, or a recovery-code lockdown over its limits: 5 well-formed attempts per address per 10 minutes, 30 an hour in total, one check at a time (a malformed code is `401 badRecoveryCode` and counts against none of them) |
| `agent.security.scriptMissing` / `agent.security.scriptUnsafe` | 409 | `security.self.sudo` is on but `/usr/local/lib/tiphys/audit.sh` is missing, or isn't a regular file owned by root and not writable by group/others (`params.path`) |
| `agent.security.knownHostsMissing` | 409 | SSH source, but `security-known-hosts` doesn't exist next to `agent.json` |
| `agent.security.sshFailed` | 502 | `ssh` exited with 255: connection, key or pinned-host-key failure (`params.code`, `params.stderr`, cut to 500 characters) |
| `agent.security.collectFailed` | 502 | The audit script (or the remote command) exited non-zero (`params.code`, `params.stderr`) |
| `agent.security.timeout` | 504 | The collector ran into its time limit (90 s ordinary / 300 s full, +20 s for SSH and agent pulls) |
| `agent.security.reportTooLarge` | 502 | The report is over 2 MiB (an agent source's JSON answer: over 4 MiB, checked while it streams in) |
| `agent.security.unreachable` | 502 | Agent source: connection failed |
| `agent.security.unauthorized` | 502 | Agent source answered 401/403 (`params.status`): token revoked or missing the `security-report` scope |
| `agent.security.busy` | 502 | Agent source answered 429 (its raw rate limit) |
| `agent.security.agentFailed` | 502 | Agent source answered another error or an unreadable body (`params.status`) |
| `agent.security.badReport` | 502 | The output isn't a complete audit report (wrong header, no final `@@end`, or a section header that appears twice); also stored as the host's `lastError.code` |
| `agent.security.imageNotFound` | 404 | Unknown image id, or an image no running container uses any more |
| `agent.security.scannerOff` | 409 | `POST /v1/security/vulns/scan` while `scanners.trivy` is off (`params.scanner`) |
| `agent.security.scanBusy` | 409 | A scan of that kind is already running (images, secrets, outside view, Cloudflare run); also a scan of a single image while the image batch runs |
| `agent.security.findingNotFound` | 404 | Unknown secret finding id |
| `agent.security.briefRateLimited` | 429 | More than 10 `POST /v1/security/brief` per device per 10 minutes (`params.limit`, `params.windowSeconds`) |
| `agent.security.itemNotFound` | 404 | `POST /v1/security/brief` where **no** item resolved. As a per-item `error` in a 200 answer: that finding, change, image CVE, secret or outside-view finding no longer exists |
| `agent.security.imageTooLarge` | 502 | Image save over 3 GB (recorded as the image's `error`) |
| `agent.security.scanFailed` | 502 | gitleaks on log data failed (recorded in `lastRun.loki`) |
| `agent.security.lokiUnavailable` | 409 / 502 | No `scanners.loki` configured (409), or the Loki container has no address (502) |
| `agent.security.lokiFailed` | 502 | Loki answered an error (`params.status`) |
| `agent.security.githubUnauthorized` / `agent.security.githubFailed` | 502 | GitHub answered 401/403, or another error, when listing repositories (`params.status`; recorded in `lastRun.github`) |
| `agent.security.tooManyTraps` | 409 | 20 decoy tokens or 20 decoy files exist already (checked before anything is written) |
| `agent.security.trapExists` | 409 | The decoy file path already exists (never overwritten) |
| `agent.security.trapCreateFailed` | 409 | The decoy file could not be created |
| `agent.security.trapNotFound` | 404 | Unknown decoy token or file id |
| `agent.security.badRecoveryCode` | 401 | Wrong, missing or malformed recovery code (also when none is set) |
| `agent.blackbox.full` | 507 | The black box chain reached its size limit (1 GiB); nothing more is appended (`POST /v1/blackbox/append`) |
| `agent.security.cloudflareNotConfigured` | 409 | `POST /v1/security/attacks/run` without a read token |
| `agent.security.cloudflareUnauthorized` / `agent.security.cloudflareFailed` | 502 | Cloudflare answered 401/403, or an error or GraphQL errors (`params.status`; recorded in `lastRun.error`) |
| `agent.blackbox.notLocal` | 409 | A black box route that needs `mode: local` on an agent in another mode |
| `agent.exec.commandMissing` | 500 | Required binary not installed (`params.command`) |
| `agent.exec.failed` | 502 | Command exited non-zero (`command`, `code`, `stderr`) |
| `agent.exec.timeout` | 504 | Command timed out |
| `agent.config.passwordRequired` | 400 | Secret needed because the URL changed (`params.field`) |
| `agent.device.notFound` | 404 | Unknown device id |
| `agent.devices.confirmRequired` | 400 | `revoke-all` without `confirm: true` |
| `agent.feature.unsupported` | 501 | Not possible on this OS (`params.feature`, `params.platform`), see [Platforms](#platforms) |
| `agent.processes.confirmRequired` / `.self` / `.notFound` / `.permissionDenied` | 400 / 400 / 404 / 403 | Process signal errors |
| `agent.processes.signalFailed` | 502 | Windows: `taskkill` could not close the process (`TERM` on a process without a window; use `KILL`). `pid`, `signal`, `stderr` |
| `agent.services.actionFailed` / `.permissionDenied` | 502 / 403 | `systemctl` / `launchctl` / the Windows service manager failed / permission denied (polkit; root for macOS system jobs; an administrator for most Windows services) |
| `agent.services.notFound` / `.logsUnavailable` | 404 / 404 | macOS logs: no such launchd job / the job has no `StandardOutPath`/`StandardErrorPath` (`params.unit`) |
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
| `agent.desktop.unsupported` | 501 | Not available on this desktop backend (helper capability missing, or a Hyprland-only feature such as the mobile view or Sunshine). `params.capability` / `.op` / `.action` say which |
| `agent.desktop.permission` | 403 | The OS refused a permission the helper needs (`params.permission`, e.g. macOS Accessibility or Screen Recording) |
| `agent.desktop.helperFailed` | 502 | The desktop helper failed, timed out or crashed (`params.op`, `params.reason?`) |
| `agent.desktop.helperMissing` | 500 | Helper backend selected but no `tiphys-desktop` binary was found |
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
| `agent.claude.securityFixDisabled` | 403 | Feature `securityFix` is off (start of a `security` session, `…/security/targets`) |
| `agent.claude.securityRequired` | 400 | `kind: "security"` without `security`, or `security` without `kind: "security"` |
| `agent.claude.securityNoTargets` | 400 | None of `security.hosts` is a configured fix target (`params.hosts`) |
| `agent.claude.securitySshConfig` | 400 | A pinned target's SSH destination cannot be used: `ssh -G` failed, it sets `ProxyCommand`, `ProxyJump`, `LocalCommand` or `KnownHostsCommand`, or a resolved value is unusable (`params.host`, `params.reason`, at most 300 characters) |
| `agent.claude.securityInvestigateReadOnly` | 400 | An investigate session started or switched to a mode other than `plan` |
| `agent.claude.notSecuritySession` | 400 | A `…/security` or `…/sudo` route on a session that is not a security session |
| `agent.claude.securityOwnerOnly` | 403 | A security session's message, permission answer, mode change, sudo answer or rollback from a device other than the one that started it |
| `agent.claude.securityHostNotPinned` | 400 | Rollback of a host that is not pinned to the session (`params.host`) |
| `agent.claude.securityTargetGone` | 409 | Rollback of a host whose fix target was removed or changed since the session started (`params.host`) |
| `agent.claude.sudo.notFound` | 404 | No open sudo request with that id (`params.requestId`): already answered, timed out or cancelled |
| `agent.claude.confirmRequired` | 400 | Takeover without confirmation |
| `agent.claude.terminalNotFound` / `.terminalBusy` / `.terminalStuck` | 404 / 409 / 504 | Terminal takeover |
| `agent.claude.historyNotFound` / `.shotNotFound` | 404 | Transcript / screenshot missing |
| `agent.claude.tooManySchedules` / `.scheduleRunning` | 400 / 409 | Schedules (max 50) |
| `agent.agy.missing` | 501 | The `agy` binary is not on the agent's `PATH` |
| `agent.agy.exited` | 502 | The `agy acp` process ended (`params.code`: its exit code, -1 when unknown) |
| `agent.agy.timeout` | 504 | agy did not answer a protocol request in time (`params.method`; 60 s for most, 120 s for loading a conversation, 30 s for list/mode/model) |
| `agent.agy.rpcError` | 502 | agy answered with a protocol error (`params.code`, `params.message` cut to 300 characters) |
| `agent.agy.startFailed` | 502 | Starting the session failed for another reason (also recorded as an `error` event) |
| `agent.agy.rateLimited` | 429 | More than 6 session starts per minute, or 10 conversation lists per minute, per device |
| `agent.agy.sessionNotFound` | 404 | Unknown, or long ended and removed, session id (`params.id`) |
| `agent.agy.tooManySessions` | 409 | Already 6 live sessions (`params.max`) |
| `agent.agy.alreadyOpen` | 409 | `resume` names a conversation that is open in a live session of this agent |
| `agent.agy.busy` | 409 | A message while a turn is running, a permission is pending or the session is starting |
| `agent.agy.sessionEnded` | 409 | The session has ended or failed to start |
| `agent.agy.permissionNotFound` | 404 | Unknown or already answered permission request |
| `agent.agy.unknownMode` / `agent.agy.unknownModel` | 400 | Not one of the session's `modes` / `models` (`params.modeId` / `params.model`) |

## Platforms

Linux is the reference platform. The server features (`system`, `services`, `docker`, `power`, `ports`, `git`,
`homepage`, `transcribe`, `wake`) also run on macOS and Windows with the same request and response shapes; the
macOS/Windows code is in `src/platform/` and loads only there. What an OS can't do is listed in
`src/platform/support.ts`, returned by `GET /v1/health` as `unsupported` and answered with
`501 agent.feature.unsupported {feature, platform}`:

| Platform | `unsupported` |
| --- | --- |
| Linux | `[]` |
| macOS | `gamemode` |
| Windows | `services.user`, `services.logs`, `processes.signal.INT`, `processes.signal.HUP`, `desktop.velour`, `desktop.firefoxBridge` (Unix sockets), `gamemode` |

`tiphys-agent init --detect` and `doctor` never turn on or recommend a whole feature that is listed. The per-feature
overview is in [System › Platforms](../features/system.md#platforms).

## Endpoints

Shapes are summarized. The zod schemas in the linked source files are authoritative.

### Always available

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| GET | `/v1/health` | **none** | `{name, version, features, unsupported}`. `unsupported`: features or parts of features this OS can't do (empty on Linux and macOS), see [Platforms](#platforms). Also used by `watch`. |
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
| GET | `/v1/doctor` | device | Health checks of the install (`doctor.ts`, same as `tiphys-agent doctor --json`), see [doctor](#doctor) |
| GET | `/v1/update` | device | `{current, latest, available, managed, notesUrl, error?}`, see [self-update](#self-update) |
| POST | `/v1/update/apply` | device | Feature `update`. `{version, confirm: true}` → `{ok, version, restarting: true}`, then the agent exits and its service manager starts the new version |

#### Doctor

`GET /v1/doctor` → `{version, checks: [{id, status, code, params, fix?}]}`. `status` is `ok`, `warn` or `fail`;
`code` is translated by the app; `fix` is a shell command **suggestion** for the user (the agent never runs it).
The report holds paths, ports, versions, feature and tool names, never tokens or passwords. Checks run in parallel
and take at most a few seconds (Tailscale CLI 5 s, release check 5 s, own health 2 s).

| `id` | Codes |
| --- | --- |
| `tailscale` | `doctor.tailscale.ok` (`dnsName`), `.missing`, `.loggedOut`, `.stopped` (`state`) |
| `tailscale.serve` | `doctor.tailscale.served` (`port`, `httpsPorts`), `.notServed` (`port`; fix: `sudo tailscale serve --bg --https=7443 http://127.0.0.1:7443`), `.serveUnknown` |
| `agent` | `doctor.agent.listening` / `.notListening` (`host`, `port`) |
| `config` | `doctor.config.ok`, `.missing`, `.permissions` (`mode`; must be 600), `.wrongOwner` (`uid`) — all with `path` |
| `time` | `doctor.time.synced`, `.notSynced` (`timedatectl`), `.unchecked` |
| `disk` | `doctor.disk.ok`, `.low` (< 2 GB or < 5 %), `.full` (< 512 MB), `.unchecked` — `freeMb`, `totalMb` |
| `node` | `doctor.node.ok`, `.old` (< 24), `.tooOld` (< 22) — `node` |
| `feature.<name>` | only for problems: `doctor.feature.toolsMissing` (`feature`, `tools`; e.g. `desktop` without `hyprctl` or the desktop helper, `git`, `claude`, `services`), `.dockerDenied` (`socket`), `.dockerUnreachable` (macOS/Windows: Docker Desktop's daemon does not answer `docker version`), `.unsupported` (`feature`, `platform`: turned on but listed as unsupported on this OS), `.transcribeMissing` (`command`) |
| `push` | `doctor.push.ok` (`endpoints`), `.notConfigured` (warn) |
| `version` | `doctor.version.latest`, `.outdated` (`current`, `latest`, `managed`), `.unchecked` |

#### Self-update

`GET /v1/update` asks the release server for the newest version (`<releases>/latest/download/VERSION`, 5 s
timeout, cached for an hour, 5 minutes after a failure). `managed` is true only when the agent runs from an
`install.sh` layout (`…/tiphys-agent/versions/<v>` with `current` pointing at it); a git checkout, a package
or the Docker image reports `false` and never updates itself. `notesUrl` links to the GitHub release page.

`POST /v1/update/apply` (device token, feature `update`, `managed`) downloads `SHA256SUMS`, `SHA256SUMS.sig` and
this platform's bundle from the **fixed** release location (GitHub, or `TIPHYS_RELEASE_URL` from the agent's own
environment; never from the request), checks the ed25519 signature with the public key built into the agent and the
bundle's SHA-256, checks that the bundle is the requested version, unpacks it to `versions/<version>`, switches
`current` atomically and writes `update-pending`. It answers, then exits; `Restart=always` (systemd), `KeepAlive`
(launchd) or the Windows loop starts the new version. The new version removes `update-pending` after 15 s of
uptime; if it fails to start three times, the guard that runs before each start switches `current` back. Event
`agent.updated` (`host`, `version`). See [Security › Releases and updates](../security.md#releases-installer-and-self-update).

### system

Feature `system` (`routes/system.ts`, `routes/processes.ts`).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/system` | `{hostname, os, kernel, uptimeSeconds, cpu, memory, disks[], gpus[]}`, cached for 2 s |
| GET | `/v1/processes?sort=cpu\|mem&limit=1..500` | `{total, processes: [{pid, ppid, user, cpuPercent, memPercent, rssBytes, elapsedSeconds, name, command}]}` |
| POST | `/v1/processes/:pid/signal` | `{signal: TERM\|KILL\|INT\|HUP, confirm: true}`. PID must be ≥ 2 and not the agent itself. Windows: `TERM` = `taskkill /PID` (asks the window to close), `KILL` = `taskkill /PID /F`, `INT`/`HUP` → 501. |

The same shapes on every OS. macOS: `vm_stat`, `sysctl vm.swapusage`, `df -k` + `mount`, `ps -axo`; Windows: CIM via
PowerShell (`Win32_OperatingSystem`, `Win32_LogicalDisk`, `Win32_Process` + per-process CPU counters). There,
`cpu.temperatureC` is `null`, the CPU load is measured with `os.cpus()`, and Windows processes have `user: ""`.

### services

Feature `services` (`routes/services.ts`). `:scope` is `user` or `system`.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/services/:scope` | `{scope, units: [{unit, load, active, sub, description}]}`, `.service` units only |
| POST | `/v1/services/:scope/:unit/:action` | `action`: `start`, `stop` or `restart` |
| GET | `/v1/services/:scope/:unit/logs?lines=1..2000` | `{unit, entries: [{timeUs, priority, message}]}` from `journalctl` |

- **macOS:** launchd jobs. `user` = the GUI session's agents (`launchctl list`), `system` = system daemons
  (`launchctl print system`); `unit` is the job label. `active` is `active` (has a PID), `failed` (last exit code > 0)
  or `inactive`; `description` is empty. start = `launchctl kickstart`, restart = `kickstart -k`, stop =
  `launchctl kill SIGTERM` (a `KeepAlive` job starts again). System jobs need root (`403 permissionDenied`). Logs
  are the last lines of the job's `StandardOutPath`/`StandardErrorPath` files (`timeUs: 0`, no timestamps).
- **Windows:** `system` = Windows services (`Get-Service`; `unit` = service name, `description` = display name,
  `load: disabled` for disabled services), actions via `Start-Service`/`Stop-Service`/`Restart-Service`. `user` and
  `logs` answer `501 agent.feature.unsupported`. Service names outside `A–Z a–z 0–9 @ . _ : -` can't be controlled.

### docker

Feature `docker` (`routes/docker.ts`).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/docker/containers` | `{containers: [{id, name, image, state, status, project, cpuPercent, memory}]}` |
| POST | `/v1/docker/containers/:id/:action` | `start`, `stop` or `restart` |
| GET | `/v1/docker/containers/:id/logs?tail=1..5000` | `{id, lines: [{time, stream, message}]}` (stdout and stderr merged by timestamp) |

Compose operations are done by the app over SSH, not through this API. See [System](../features/system.md).

### power

Feature `power`. `POST /v1/power/:action` with `{confirm: true}`, where `action` is `reboot`, `poweroff` or `suspend`. Responds `{ok, action}` first; the command runs 1.5 s after the response has been sent: `systemctl --no-ask-password <action>` (Linux); `pmset sleepnow` / `osascript -e 'tell application "System Events" to restart|shut down'` (macOS); `rundll32.exe powrprof.dll,SetSuspendState 0,1,0` / `shutdown.exe /r|/s /t 0` (Windows).

### wake

Feature `wake`. `GET /v1/wake` returns `{targets: [{hostId}]}`. `POST /v1/wake/:hostId` sends the magic packet.

### ports

Feature `ports` (`routes/ports.ts`).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/ports` | `{host, ports: [{port, address, process, pid, localOnly, shared, url, reserved}]}`. Linux `ss -ltnpH`; macOS `netstat -an -p tcp` + `lsof -nP -iTCP -sTCP:LISTEN` (processes of the agent's own user only); Windows `Get-NetTCPConnection -State Listen`. |
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

Feature `desktop`. Endpoints marked **C** also need the `control` feature and an `X-Tiphys-Control` token.

The agent picks a desktop backend at startup (`desktop.backend`, see [configuration](configuration.md#desktop)): on
Hyprland it drives the desktop itself (the tools named below); on other desktops (Sway, X11, GNOME/KDE, Windows,
macOS) the same endpoints go through the native helper `tiphys-desktop` (`routes/desktop_portable.ts`, protocol in
`desktop-helper/PROTOCOL.md`). Whatever the helper can't do on that platform answers `501 agent.desktop.unsupported`.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/desktop/capabilities` | `{backend: "hyprland" \| "helper", capabilities: [...], platform?, version?, error?}`. Capabilities: `windows`, `windowActions`, `workspaces`, `monitors`, `thumbnails`, `screenshot`, `stream`, `input`, `text`, `apps`, `launch`, `dpms`, `clipboard`, `clipboardSync`; Hyprland adds `h264`, `mobileView`, `sunshine`, `pcTools`, `browserFocus`. On the helper backend `platform` is the helper's (`sway`, `x11`, `portal`, `windows`, `macos`, `none`); the call starts the helper if needed. If it can't start, `capabilities` is empty (or only the Wayland clipboard ones) and `error` holds the code. The app hides what isn't listed. |

On the helper backend: `GET /v1/desktop/windows` has `hyprland: false, backend: "helper"`, helper workspace names get
Hyprland-style numbers (a numeric name keeps its number, the others get the next free one), `pinned` is always false,
`minimize`/`maximize` are extra window actions and `pin` answers 501; thumbnails are JPEG; app ids are the helper's
(e.g. `firefox.desktop`; apps have no `genericName`/`categories`); the live screen is MJPEG only (`codec=h264` gives
MJPEG, `hello.source` is `helper`, `hello.cursor` null). The clipboard uses `wl-paste`/`wl-copy` (with sync) on a
Wayland session that has them, otherwise the helper (GET/PUT only, no sync). The control session has no border
indicator on the PC. Mobile view and Sunshine answer 501, Claude's PC tools `agent.claude.pcUnavailable`.

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
| GET | `/v1/media/outputs` | Audio outputs (PipeWire sinks from `pw-dump`): `{outputs: [{id, name, default}]}` |
| PUT | `/v1/media/output` | `{id}`: makes that output the default (`wpctl set-default`); only an id from the list. Returns the new list. |

#### Velour

`routes/velour.ts`. Forwards to the [Velour](https://github.com/mikailustuner/velour) player's local control socket
(protocol 1, see Velour's `docs/remote-control.md`). Velour errors come back as `agent.velour.<code>`; no socket is
`agent.velour.unavailable` (503).

| Method | Path | C | Description |
| --- | --- | --- | --- |
| POST | `/v1/velour` | | `{op, …}`: one validated operation (state, queue, lyrics, controls, queue edits, play, search, pages, library, likes, playlists, `wait`, `explore`, `eq`/`set-eq`, `sleep`, `show`, `save-queue`, `save-to-library`, `remove-from-playlist`). Returns `{result}`. |
| GET | `/v1/velour/events` | | SSE: `state` each time Velour's `rev` changes (long-polls `wait`; an older Velour is polled every 2 s), `error {code}` while Velour is unreachable (retried every 3 s), a ping every 15 s. |
| POST | `/v1/velour/sleep` | ✓¹ | `{minutes? 1..720 \| endOfTrack?, then: none\|screenOff\|suspend, confirm?}`: Velour's sleep timer plus what the PC does when it fires; no length cancels. `screenOff` needs a control session, `suspend` the `power` feature (`agent.velour.powerDisabled`) and `confirm: true`. The pending action shows in the state as `sleep.then`; it is kept in memory only. |
| POST | `/v1/velour/show` | ✓ | Velour's window to the front and focused. |

¹ only with `then: "screenOff"`.

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
| POST | `/v1/claude/sessions` | Strict `{cwd, prompt?, images?: [{mediaType, data}] (≤10), profileId?, model?, effort?: low\|medium\|high\|xhigh\|max, permissionMode?: default\|acceptEdits\|plan\|bypassPermissions, resume?: uuid, worktree?, kind?: code\|pc\|security, security?}` → summary. `kind: "pc"` requires a control token. `kind: "security"` goes with `security` (below). |
| GET | `/v1/claude/sessions/:id?after=SEQ` | `{session, events}` |
| POST | `/v1/claude/sessions/:id/messages` | Strict `{text, images?, clientId?}` → `{ok, duplicate}`. `clientId` makes retries idempotent. |
| POST | `/v1/claude/sessions/:id/interrupt` | Stop the current turn |
| POST | `/v1/claude/sessions/:id/permissions/:requestId` | Strict `{allow, message?}`. Answers a permission request; this is also what the notification action buttons call. |
| POST | `/v1/claude/sessions/:id/mode` | `{permissionMode}` → summary. Security sessions: see [rules](#security-fix-sessions) below. |
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
| GET | `/v1/claude/security/targets` | Feature `securityFix`. `{targets: [{host, name, ssh: string\|null, port?}], sudoCacheMinutes}`: the [`securityFix`](configuration.md#securityfix) section. `403 agent.claude.securityFixDisabled`. |
| PUT | `/v1/claude/security/targets` | Feature `securityFix`. Strict `{targets (≤20, unique `host`), sudoCacheMinutes (1–120, default 15)}`; **replaces** the section and returns it. Target: strict `{host: [a-z0-9][a-z0-9-]{0,62}, name: 1–80, ssh: string matching the ssh destination pattern \| null, port?: 1–65535}`. Audit `{targets: [host ids]}`. Same errors, plus `400 agent.request.invalid`. |
| GET | `/v1/claude/sessions/:id/security` | State of a security session (below). `400 agent.claude.notSecuritySession`. Works with the feature off, so a restored session with backups can still be rolled back. |
| POST | `/v1/claude/sessions/:id/security/rollback` | Strict `{host}` (id of a pinned machine). Restores every file the session changed on that host and reloads what `safe_apply` reloaded; no approval card. Open permission and sudo requests of the session are denied first so it does not queue behind them; a running command is waited for. Returns `{host, restored: [path], failed: [{path, error}], reloaded: ["sshd: ok", "nft: failed"…]}`. `400 agent.claude.securityHostNotPinned`, `403 agent.claude.securityOwnerOnly`, `409 agent.claude.securityTargetGone`. Audit `{host}`. |
| POST | `/v1/claude/sessions/:id/sudo` | Answers a `sudo` event: strict `{requestId: uuid, password: 1–1024 chars}` or `{requestId, deny: true}` → `{ok: true}`. The body is never logged and no audit detail is set. `404 agent.claude.sudo.notFound`, `403 agent.claude.securityOwnerOnly`. |
| DELETE | `/v1/claude/sessions/:id/sudo` | Open to any device. Cancels the session's open sudo prompts (the waiting tool gets no password), then forgets the cached sudo passwords and recorded denials → `{ok: true}`. Claude asks again when it needs root. |

`when` takes one of three forms: `{kind: "daily", time: "HH:MM"}`, `{kind: "weekly", time, days: [1..7]}` (1 = Monday) or `{kind: "interval", everyMinutes: ≥15}`.

A session summary has these fields: `{id, epoch, sdkSessionId, cwd, title, status: starting|running|waiting|idle|error|stopped, model, permissionMode, profileId, costUsd, contextTokens, contextWindow, createdAt, lastActivity, pendingPermissions, live, resumeCommand, kind: code\|pc\|security, control?, security?}`.

**`resumeCommand`** ("Continue on the PC"): `cd '<cwd>' && claude --resume <sdkSessionId>`, ready to paste into a terminal on the PC, or `null` while the session has no `sdkSessionId` yet. `cwd` is single-quoted for a POSIX shell (a `'` inside it is written `'\''`). Close the session on the phone first so the conversation isn't open in two places. `claude --resume` without an id lists only the sessions of the *current folder*, and a session started from the phone is saved under the folder chosen on the phone, hence the `cd`. See [Claude › Continue on the PC](../features/claude.md#continue-on-the-pc).

For PC sessions, only the device holding the bound control session may send messages, answer permissions or change the mode.

#### Security fix sessions

Feature `securityFix` (and `claude`). See [Security fix sessions](../features/claude.md#security-fix-sessions) and
[Fixing findings with Claude](../features/security.md#fixing-findings-with-claude).

**Start**: `POST /v1/claude/sessions` with `kind: "security"` and

```json
{
  "cwd": "~", "prompt": "leave port 8080 open", "permissionMode": "default",
  "kind": "security",
  "security": { "brief": "# Tiphys security brief…", "hosts": ["atlas"], "investigate": false, "origin": { "agentHostId": "atlas", "refs": ["finding:atlas:ssh.passwordAuth"] } }
}
```

- `security` is strict: `brief` (the `text` of [`POST /v1/security/brief`](#security), 1 byte to 120 KiB), `hosts` (1–20 host ids), `investigate: boolean`, `origin` (any JSON, at most 4096 bytes; optional).
- `cwd` must still be present but is ignored (the working directory is the home folder). `prompt` is the user's own note (trusted, may be empty); the brief is put into a nonce-delimited data block. `images` and `worktree` are ignored.
- The session pins the hosts that are in `security.hosts` **and** configured in [`securityFix.targets`](configuration.md#securityfix), copied at start. None: `400 agent.claude.securityNoTargets`. Each SSH destination is resolved once with `ssh -G` (10 s limit) and the result is stored with the session; every later connection uses `-F /dev/null` and only these values. A destination that uses `ProxyCommand`, `ProxyJump`, `LocalCommand` or `KnownHostsCommand` fails the start: `400 agent.claude.securitySshConfig {host, reason}`.
- `permissionMode` defaults to `plan` when `investigate` is true and to `default` otherwise. `investigate: true` with any other mode: `400 agent.claude.securityInvestigateReadOnly`.
- Errors: `403 agent.claude.securityFixDisabled`, `400 agent.claude.securityRequired`, `400 agent.claude.securitySshConfig`, `400 agent.request.invalid` (`security.brief` over 120 KB, `origin` over 4 KB, bad host ids).
- The session starts working at once. Its `kind` is `security`, and its summary has an extra field `security: {hosts: [{host, name}], investigate, origin}` (`origin` as sent, `null` if none).

**Mode changes** (`POST …/mode`) in a security session: an investigate session accepts only `plan` (`400 agent.claude.securityInvestigateReadOnly`); `bypassPermissions` can only be set when the session starts (`400 agent.claude.bypassNeedsNewSession`; a session that left bypass cannot return to it); every other switch is allowed and takes effect for the next tool call. The mode is enforced inside the tools, not by the SDK.

**Owner**: messages (`…/messages`), permission answers (`…/permissions/:requestId`), mode changes, sudo answers and rollbacks must come from the device that started the session (`403 agent.claude.securityOwnerOnly`). Interrupting, reading the session and `DELETE …/sudo` (a panic button) are open to any device token.

**`GET /v1/claude/sessions/:id/security`** returns `{hosts: [{host, name, ssh, port}], mode, investigate, origin, backups: [{host, path, backup, existed, sudo, at}], changed: [{host, path}], timers: [{host, unit, kind: "sshd"\|"nft", expiresAt}], sudoCached: [host ids]}`. `backups` holds one entry per file and session (the state before the first change; `existed: false` means rolling back deletes the file); `timers` lists the `safe_apply` rollback timers that have not expired; `sudoCached` names the hosts whose sudo password is in memory (never the password).

**Session events** (WebSocket and `GET …/:id`), in addition to the list [below](#claude-session-websocket):

- `sudo {requestId, host, attempt, investigate?: true}`: a tool needs the sudo password of `host`. `attempt` is 1 to 3 (2 and 3 after a wrong password); `investigate: true` is present when the session is an investigation (the app warns). The session status becomes `waiting`, and a `claude.sudo` notification is sent. Answer with `POST …/sudo`. A request that is not answered is cancelled after 10 minutes, on interrupt, and when the session closes.
- `sudoResolved {requestId, provided}`: the request ended; `provided` is true when a password arrived (it is never in the event).
- Permission cards of a security session use `permission` events as usual; `toolName` is `mcp__tiphys_sec__<tool>` and the notification is `claude.waiting` with `security: 1`. `input` is the tool's input; a step that runs as root (outside `bypassPermissions`, in every other mode, `plan` included) adds `asRoot: true` and its `reason` starts with `As root`. A `write_file` card carries `diff` (against the current file, at most 8000 characters) or, when the SSH user cannot read the current file, `content` (the new content, at most 8000 characters) instead.

**Audit.** The routes above are audited like any other non-GET request. In addition each `run`, `write_file`, `safe_apply`, `confirm_apply` and `rollback` tool step (and each refused `run`) is written to `audit.jsonl` and the black box as `{at, device, method: "TOOL", path: "/v1/claude/sessions/<id>/security/<tool>", status: 200|500, detail: {session, host, tool, summary}}`, where `summary` is at most 160 characters (the command line or path, never contents or output) and `device` is the device that started the session.


### agy

Feature `agy` (`agy/acp.ts`, `agy/manager.ts`, `agy/routes.ts`), device tokens only. Antigravity CLI sessions from the phone, one `agy acp` process per session over the Agent Client Protocol. See [agy](../features/agy.md). Session ids are `agy-` plus 12 hex characters. Working folders are resolved like Claude's and must be inside `allowedRoots` (`agent.path.notAllowed` / `agent.path.notFound`).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/agy/conversations?cwd=` | `{conversations: [{sessionId, cwd, title, updatedAt: string\|null, liveId: string\|null}]}`, newest first: agy's own list of earlier conversations (including ones started in a terminal; at most 5 pages of agy's answer). `cwd` defaults to `~` and must be inside `allowedRoots`. `liveId` is the id of the live session that has the conversation open, else `null`. Starts a short-lived `agy acp` for the call. 10 per minute per device (`agent.agy.rateLimited`). |
| GET | `/v1/agy/sessions` | `{sessions: [summary]}`: every session this agent holds, ended ones included until they are removed (2 hours after they ended). |
| POST | `/v1/agy/sessions` | Strict `{cwd: ≤1024, prompt?: ≤100000, resume?: conversation id (8–80 of A–Z a–z 0–9 -), modeId?: [a-z-]{1,40}, model?: [A-Za-z0-9._-]{1,80}}` → summary (status `idle`, or `running` when a `prompt` was sent). Starts the process and waits for agy to be ready (up to 60 s; 120 s when `resume` loads a conversation). `resume` replays the conversation's history as events marked `replay: true`. `modeId` and `model` are applied after the start. 6 per minute per device. `409 agent.agy.tooManySessions` (6 live), `409 agent.agy.alreadyOpen`, `501 agent.agy.missing`, `502 agent.agy.startFailed` / `agent.agy.rpcError` / `agent.agy.exited`, `504 agent.agy.timeout`. Audit `{session, cwd, resume?}` (never the prompt). |
| GET | `/v1/agy/sessions/:id?after=SEQ&wait=MS` | `{session: summary, events: [event]}`: long poll, see below. `after` (default 0) is the highest `seq` the client has seen; `wait` 0–25000 ms (default 0). |
| POST | `/v1/agy/sessions/:id/messages` | Strict `{text: 1–100000}` → `{ok: true}` at once; the turn runs in the background and its progress arrives as events. `409 agent.agy.busy` while the session is starting, running or waiting for a permission, `409 agent.agy.sessionEnded`. Audit `{session}`. |
| POST | `/v1/agy/sessions/:id/cancel` | Body `{}`. Answers pending permission requests as cancelled and sends `session/cancel` to agy; the turn then ends with `stopReason: "cancelled"`. → `{ok: true}`; no effect on an ended session. Audit `{session}`. |
| POST | `/v1/agy/sessions/:id/permissions/:requestId` | Strict `{optionId: 1–80}`. Answers agy's permission request (`requestId`: 12 hex, from the `permission` event or `pendingPermissions`) with one of its `options`; this is also what the notification buttons call. → `{ok: true}`. `404 agent.agy.permissionNotFound`, `400 agent.request.invalid` for an `optionId` that isn't one of the options. Audit `{session, option}`. |
| POST | `/v1/agy/sessions/:id/mode` | Strict `{modeId}` → summary. `400 agent.agy.unknownMode` unless it is one of the session's `modes`. Audit `{session, mode}`. |
| POST | `/v1/agy/sessions/:id/model` | Strict `{model}` → summary. `400 agent.agy.unknownModel` unless it is one of the session's `models` (when agy listed any). Audit `{session, model}`. |
| DELETE | `/v1/agy/sessions/:id` | Cancels, closes the conversation in agy, kills the process and marks the session `ended` → `{ok: true}`. The conversation stays in agy and can be resumed. Audit `{session}`. |

**summary**: `{id, conversationId, cwd, title, status: starting|idle|running|waiting|ended|error, modeId, modes: [{id, name, description?}], model: string|null, models: [{value, name}], usage: {used, size}|null (context tokens), commands: [{name, description}] (agy's slash commands), createdAt, lastActivity, pendingPermissions: [{requestId, options: [{optionId, name, kind}]}], resumeCommand}`. `title` starts as `agy` and follows agy's own title. `waiting` means a permission request is pending. `resumeCommand` is `cd '<cwd>' && agy --conversation <conversationId>` ("Continue on the PC"; close the session on the phone first, see [agy](../features/agy.md#continue-on-the-pc)), or `null` while `conversationId` is empty.

**event**: `{eid, seq, at, kind, replay?: true, …}`; `kind` and its fields:

| `kind` | Fields |
| --- | --- |
| `user`, `agent`, `thought` | `text` (what you sent / agy's answer / its reasoning; consecutive chunks of one kind are merged into one event, ≤100000 characters) |
| `tool` | `toolCallId, title, toolKind, status, paths: [≤10], command?` (a shell command line, ≤2000 characters) |
| `toolUpdate` | `toolCallId, status, title?` |
| `plan` | `entries: [{content, status, priority}]` |
| `permission` | `requestId, options: [{optionId, name, kind}], title, toolKind, toolCallId, command?` |
| `permissionResolved` | `requestId, optionId` (`cancelled` when cancelled) |
| `mode` | `modeId` (the mode changed) |
| `error` | `text` (an `agent.agy.*` code, or `agy exited`) |
| `turnEnd` | `stopReason` |

**Long poll, `eid` and `seq`.** `eid` is an event's **identity** and stays the same for its whole life; `seq` is its **version**, a counter per session that moves on whenever *any* event is created or changed. A streamed answer is one event whose `text` grows: every added chunk gives that same `eid` a new, higher `seq`. The client keeps `after` = the highest `seq` it has received (0 at the start) and **upserts by `eid`**: an event with a known `eid` replaces the stored one, a new `eid` is added; display in `eid` order. The agent returns every event whose `seq` is greater than `after`, so a merged event reappears in full each time it grows. If there are none and `wait` > 0, the call waits up to `wait` ms and returns as soon as an event changes or the session's status changes (the `events` array may then be empty, so read `session.status` too); it never waits on an `ended` session. Poll again at once after every answer. The agent keeps the last 3000 events of a session in memory (the oldest are dropped; the conversation itself stays in agy). `replay: true` marks events that came from loading an earlier conversation.

**Notifications** (all link to `tiphys://agy/<session id>`):

| Key | Params | Notes |
| --- | --- | --- |
| `agy.waiting` | `title` (session title), `tool` (the tool's title, ≤120 characters) | priority high. Sent for every permission request. `data: {sessionId, requestId}` is what the notification buttons need to answer through `POST …/permissions/:requestId`. |
| `agy.done` | `title` | priority low. A turn ended normally. |
| `agy.error` | `title` | A turn failed (an `error` event carries the code); the session stays usable. |

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

### security

Feature `security` (`security/*.ts`), device tokens only, except `GET /v1/security/raw` (also a service token with the `security-report` scope), `POST /v1/blackbox/append` (service token with the `blackbox` scope only), `POST /v1/security/lockdown/remote` (service token with the `lockdown` scope, or a device token) and `POST /v1/security/lockdown` (no token, recovery code). The monitoring server collects reports of its own machine and of other hosts, evaluates findings and a score, and keeps baselines and changes (S-1, the tables above). The sections below it cover the later phases: scanners (S-2), traps and alerts (S-3), the black box and lockdown (S-4), outside view and attack detection (S-5). See [Security center](../features/security.md).

`:id` is a host id (`[a-z0-9][a-z0-9-]{0,62}`); `self` is this machine and always exists.

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/security/overview` | `{intervalMinutes, hosts: [summary]}`: `self` first, then the configured hosts. |
| GET | `/v1/security/hosts/:id` | Host `detail` (below). `404 agent.security.hostNotFound`. Before the first report: empty findings and changes, `report: null`. |
| POST | `/v1/security/hosts/:id/check` | Strict `{full?: boolean (false)}`. Runs a check now (joins one that is already running) and returns the host `detail`. `full: true` also runs the SUID and world-writable scans. 6 per 10 minutes per device (`agent.security.rateLimited`, checked before the check starts). A failed check returns the collector's error (`agent.security.*`, or `agent.exec.commandMissing` when `ssh`/`sudo`/`sh` is missing) and records it as `lastError`. |
| POST | `/v1/security/hosts/:id/baseline` | Strict `{confirm: true, expected?: <number of changes the user saw>}`; with `expected` set and more (or fewer) changes listed now, `409 agent.security.changesMoved {expected, current}` and nothing is accepted. Anything else is `400 agent.request.invalid`; there is no dedicated `confirmRequired` code). Accepts the current state as the new baseline: clears the changes and sends `security.accepted`. Returns `{accepted: <number of changes cleared>, …detail}`. `409 agent.security.noReport` without a report. |
| GET | `/v1/security/hosts` | `{self: {role, allowedPorts, sudo}, hosts: [host]}`: the settings (not the reports). A `host` is `{id, name, role, allowedPorts, source, traps}`; an `agent` source is returned as `{kind, url, hasToken: true}`, never with its token. |
| POST | `/v1/security/hosts` | Strict `{id, name (1–80), role?: server\|desktop (server), allowedPorts?: ["tcp/22", …] (≤100), source, traps?: boolean (false)}` → `201 {host}`. `source` is `{kind: "ssh", host, user, port? (22), keyPath}` (`keyPath`: the private key on this machine, `~` is expanded) or `{kind: "agent", url (https), token (tps_…)}`. `409 agent.security.hostExists` (also for `self`), `409 agent.security.tooManyHosts`, `400 agent.security.tokenRequired`. |
| PATCH | `/v1/security/hosts/:id` | Strict, all optional: `{name?, role?, allowedPorts?, source?, traps?}` → `{host}`. `traps: true` makes the agent poll that SSH host's decoy-file events (see [traps](#traps-and-alerts)); it has no effect for other source kinds. For an `agent` source the token may be omitted while the URL stays the same (kept); with a new URL it is required (`agent.security.tokenRequired`), so a stored token never goes to a new address. For `self`: strict `{role?, allowedPorts?, sudo?: boolean}` → `{self}`. The stored report is re-evaluated at once with the new role/ports. |
| DELETE | `/v1/security/hosts/:id` | `{ok: true}`; also deletes the host's stored report and baseline. `409 agent.security.selfPermanent` for `self`. |
| POST | `/v1/security/brief` | Strict `{items: [item] (1–30), language?: tr\|en (tr)}`, where an item is `{type: "finding", host, id}`, `{type: "change", host, id}` (`id` is the change's `category\|item`), `{type: "vuln", image: "sha256:<64 hex>", cve}`, `{type: "secret", id: <24 hex>}` or `{type: "exposure", id}`. Device tokens only (`403 agent.auth.scopeDenied` for a service token); 10 per device per 10 minutes (`429 agent.security.briefRateLimited`). Returns the sanitized brief `{text, bytes, truncated, investigate, hosts: [{id, name, role, root: boolean\|null, source}], items: [{ref, type, host: string\|null, mode: "fix"\|"investigate"} \| {ref, type, error}]}`. `text` is at most 120 KB; items are kept in request order, duplicates dropped. A per-item `error` is `agent.security.hostNotFound`, `agent.security.itemNotFound` or `agent.security.briefTruncated`; the call fails with `404 agent.security.itemNotFound` only when **no** item resolved. `ref` is the raw item reference (`finding:<host>:<id>`, `vuln:<image>:<cve>`, …) and is data for the caller; it is never used in the text. `investigate` is true when any item has the mode `investigate`. Audit `{finding?, change?, vuln?, secret?, exposure?: counts per type, bytes}`. See [Fixing findings with Claude](../features/security.md#fixing-findings-with-claude). |
| GET | `/v1/security/raw?mode=report\|report-full` | `{text}`: the raw audit output of **this** machine (the same text `audit.sh` prints, plus an `agentfiles` section with the modes of the agent's own files). It runs with this agent's `security.self.sudo` setting. For the monitoring server of another host. Device token or service token with scope `security-report`; 10 per 10 minutes per caller (device id or `service:<id>`). |

Host settings live in their own routes, not in `GET`/`PATCH /v1/config` (the `security` section isn't part of the redacted config), so source tokens never travel back.

**summary**: `{id, name, role: server|desktop, source: local|ssh|agent, score (0–100, null before the first report), counts: {critical, high, medium, low}, changes (number), lastOkAt, lastAttemptAt, lastFullAt, lastError: {code, at} | null, stale (no success for more than 3 intervals), running}`.

**detail**: `{host: summary, policy: {role, allowedPorts}, findings: [{id, rule, severity: critical|high|medium|low, params}], changes: [{id: "category|item", category, item, kind: added|removed|changed, firstSeenAt}], baselineAt, report}`. Findings are sorted by severity, then id. `rule` is translated by the app; rule names, severities and params are listed in [Security center](../features/security.md#score-and-findings). `report` is `null` until the first successful report, otherwise `{mode: report|report-full, root, meta: {hostname, kernel, arch, os, uptimeSec, time, ipv6Global}, listen: [{proto, addr, iface, port, scope: loopback|tailscale|wildcard|private|linklocal|public, process, firewall?: open|filtered}] | null, firewall: {source: "nft", defaultDeny, inputChains} | null, sshd: {mode: effective|config, settings: {key: [values]}} | null, users: [{name, uid, gid, shell}], passwords: [{name, status: empty|set}] | null, groups: {group: [members]}, sudoers: [{path, sha256}] | null, authKeys: [{user, path, bits, fingerprint, comment, type}], cron: [{path, sha256}], timers: [{scope: system|user, name, unit}], autostart: [{path, sha256}] | null, updates: {pending, security, unattended, listsUpdatedAt, rebootRequiredSince}, services: {name: {active, enabled}}, sysctl: {key: value}, logins: [{user, tty, from, raw}], docker: {version, containers: [{name, image, imageId, privileged, networkMode, pidMode, readOnlyRootfs, user, capAdd, mounts: [{source, destination, rw}], ports: [{hostIp, hostPort, container}], project, service}], images: [{id, tags, digests, size, created}]} | null, suid: [{mode, owner, path}] | null (the last full report's list), worldWritable: [{mode, owner, path}] | null (the last full report's list, carried over like `suid`), agentFiles: [{path, mode}] | null, unavailable: [section names]}`. `null` marks "not readable" (e.g. needs root), never "empty".

**Collectors.** `self` runs `sh <agent>/helpers/audit.sh <mode>` as the agent user, or, with `security.self.sudo`, `sudo -n /usr/local/lib/tiphys/audit.sh <mode>` (the installed copy; never the agent's own file). `ssh` hosts run `ssh -T -F /dev/null -i <key> -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o StrictHostKeyChecking=yes -o UserKnownHostsFile=<security-known-hosts> -o GlobalKnownHostsFile=/dev/null -o ClearAllForwardings=yes -l <user> -- <host> <mode>`: only the mode word is sent; the key's forced command decides what runs. `agent` hosts call `GET <url>/v1/security/raw?mode=<mode>` with the bearer token (no redirects). The output of all three goes through the same parser.

**Check scheduling.** A machine is due when `security.intervalMinutes` passed since its last attempt; an ordinary report is requested, except the first one and one per 24 hours (and `full: true`), which are full. An unreadable report is not a "change": the host keeps its last report and baseline. After 6 hours without a success a host that worked before sends `security.unreachable` once; its first success afterwards sends `security.reachable`.

**Notifications.** All carry `link: tiphys://security/<hostId>`. `agent` is the name of the agent that ran the check (the app uses it to pick the right agent).

| Key | Params | Notes |
| --- | --- | --- |
| `security.change` | `host, hostId, agent, count, categories (comma-separated), severity: warning\|critical` | New changes against the baseline, each announced once. `critical` (priority high) when a `users`, `passwords`, `sudoers`, `authKeys`, `ports` or `sshd` item was added or changed, else `warning` (priority default). Opens/joins the host's *security* incident (critical when `severity` is `critical`). |
| `security.accepted` | `host, hostId, agent, count` | priority low. Closing signal of that incident. |
| `security.unreachable` | `host, hostId, agent, hours, code` | priority default. `code` is the host's last error code. |
| `security.reachable` | `host`, `hostId`, `agent` | priority low. |

**Audit** (`audit.jsonl` `detail`): check `{host, full}`, accept baseline `{host, accepted}`, add host `{host, source: ssh|agent}`, change `self` `{host: "self"}`, change another host `{host, source?}`, delete `{host}`. Tokens, key paths and addresses are never logged. The `GET` routes (including `/raw`) are not audited.

**Limits**: 20 additional hosts; 100 expected ports per host; report ≤ 2 MiB; `intervalMinutes` 5–1440 (default 15).

#### Vulnerability scan and secret scan (S-2)

All routes are for device tokens. Scanning needs Docker on the agent and runs on the monitoring server. State:
`security-vulns.json`, `security-secrets.json`. Behaviour: [Container vulnerability scan](../features/security.md#container-vulnerability-scan) and [Secret scan](../features/security.md#secret-scan).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/security/vulns` | `{enabled (scanners.trivy), running, images: [image]}`. Refreshes the list from the hosts' latest reports first (images no longer running are dropped). Sorted by critical, then high count. |
| GET | `/v1/security/vulns/:id` | `{image}` with the full `vulns` list. `:id` is the image id **without** the `sha256:` prefix (64 hex; anything else is `400 agent.request.invalid`). `404 agent.security.imageNotFound`. |
| POST | `/v1/security/vulns/scan` | Strict `{imageId?: "sha256:<64 hex>"}`. Without `imageId`: starts a background run over all **due** images (forced: ignores the night window, but an SSH save still only happens at night) and returns `202 {started: true}`. With `imageId`: scans that one image and returns `{image}` **when done** (up to 15 minutes; use a long client timeout). `409 agent.security.scannerOff` (`params.scanner: "trivy"`), `409 agent.security.scanBusy` (a run is going; whole-run form only), `404 agent.security.imageNotFound`, `429 agent.security.rateLimited` (3 per 10 minutes per device, shared with the other scan routes). Audit `{image: <12 hex>}` or `{all: true}`. |
| GET | `/v1/security/secrets` | `{lastRun: {at, github, loki, local} \| null, running, repos: [{repo, head, scannedAt, error?}], findings: [finding]}`. Each `lastRun` source is `null` (ok or not run) or an error code. Findings: open ones first, then newest first. |
| POST | `/v1/security/secrets/scan` | No body needed. Runs the configured sources (GitHub and Loki when `scanners.gitleaks` is on, local roots when `localRoots` is not empty) in the background: `202 {started: true}`. `409 agent.security.scanBusy`, `429`. Audit `{all: true}`. |
| POST | `/v1/security/secrets/:id/dismiss` | `:id` is the finding id (24 hex). Strict `{dismissed: boolean}` → `{finding}`. `404 agent.security.findingNotFound`. Audit `{finding, dismissed}`. |
| GET | `/v1/security/scanners` | `{scanners}` (below). Tokens are never returned. |
| PATCH | `/v1/security/scanners` | Strict, all optional: `{trivy?, gitleaks?, javaDb?: boolean, registryAuth?: [{registry, username, token?}] (≤10), github?: {owners: [names] (≤20), token?: string\|null}, loki?: {container, port? (3100)} \| {url} \| null, localRoots?: [paths] (≤20), nightHours?: [from 0–23, to 0–24]}` → `{scanners}`. `registryAuth` **replaces the whole list**: an entry keeps its stored token when `registry` and `username` match one already stored and `token` is omitted (a new entry without a token is `400 agent.security.tokenRequired`). `github.owners` replaces the list; `github.token` omitted = keep, `null` = remove, string = replace. `loki: null` clears. Changes apply at once. Audit `{fields: [names of the keys sent]}`. |

**image**: `{imageId: "sha256:…", refs: [tags, or repositories of the digests], hosts: [{hostId, host, containers: [names]}], status: ok\|failed\|needsCredentials\|notAvailable\|pending, source: remote\|local\|ssh\|null, error: string\|null, scannedAt, os: string\|null, counts: {critical, high, fixable}, truncated}`; the detail adds `vulns: [{id, pkg, installed, fixed: string\|null, severity: CRITICAL\|HIGH, title, target}]` (≤300). `error` is a short code, not a message: `noSource`, `notFound`, `nightOnly`, `saveLimit`, `badOutput`, `scanFailed`, `saveFailed`, `imageTooLarge`, `knownHostsMissing`, an `agent.security.*` code, or the registry name for `needsCredentials`.

**finding**: `{id (24 hex), source: github\|loki\|local, rule, where, file, line, commit (12 characters), stream, at, firstSeenAt, dismissed}`. `where` is `owner/repo` (github), the Loki `host` label (loki) or the repository folder relative to the home directory (local); fields that don't apply are `null`. There is never a secret value in it.

**scanners**: `{trivy, gitleaks, javaDb, registryAuth: [{registry, username, hasToken: true}], github: {owners, hasToken}, loki, localRoots, nightHours}`.

**Notifications.**

| Key | Params | Notes |
| --- | --- | --- |
| `security.vulns` | `host (names of the hosts running the image, comma-separated), image (first tag, or 12 hex of the id), critical, high, agent` | priority default. Only when the image has critical findings and it is the first scan or the critical count rose. Link `tiphys://security/vulns/<64 hex image id>`. |
| `security.secretFound` | `host, agent, count (new findings), sources (comma-separated), where (up to 3 locations, ≤140 characters)` | priority high; also to the owner's Telegram. One per run. Link `tiphys://security/secrets`. |

#### Traps and alerts

Device tokens only. Behaviour: [Traps](../features/security.md#traps), [Alerts](../features/security.md#alerts-to-the-owners-telegram).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/security/traps` | `{tokens: [{id, name, createdAt}], files: [{id, path, kind: env\|sshkey, createdAt, status: armed\|noatime\|missing, lastTriggeredAt}], dbUsers: [names], auditHosts: [{id, status: ok\|unavailable\|error\|pending, at: string\|null}] (the hosts with traps on and how their last `traps` poll went; `unavailable` = the host has no auditd or the script isn't root there)}`. Token hashes are never returned. `lastTriggeredAt` and `status` live in memory (a restart resets them). |
| POST | `/v1/security/traps/tokens` | Strict `{name: 1–80, trimmed}` → `201 {id, token}`. The `tps_…` token is shown **once**; only its hash is stored. `409 agent.security.tooManyTraps` (20). Audit `{trap: id}`. |
| DELETE | `/v1/security/traps/tokens/:id` | `{ok: true}`. `404 agent.security.trapNotFound`. Audit `{trap: id}`. |
| POST | `/v1/security/traps/files` | Strict `{path: ≤1024, kind: env\|sshkey}` → `201 {id, path (resolved), status}`. The directory must be inside `allowedRoots` (`agent.path.notAllowed` / `agent.path.notFound`); an existing path is `409 agent.security.trapExists`; other failures `409 agent.security.trapCreateFailed`. `env` also creates a decoy token. Up to 20 files and 20 decoy tokens (`409 agent.security.tooManyTraps`, checked before the file is written). Audit `{trap: id, kind}`. |
| DELETE | `/v1/security/traps/files/:id` | `{ok: true}`. Stops watching; the file stays on disk. `404 agent.security.trapNotFound`. Audit `{trap: id}`. |
| PUT | `/v1/security/traps/db-users` | Strict `{users: [≤10 names, [a-z_][a-z0-9_]{2,62}]}` → the `GET /v1/security/traps` answer. Replaces the list. Audit `{count}`. |
| POST | `/v1/security/traps/test` | `{ok: true}`; sends a `security.trap` notice with `trap: "test"`. Audit `{test: true}`. |
| GET | `/v1/security/alerts` | `{telegramRecipient: string\|null}` (an id from `telegram-state.json`). |
| PUT | `/v1/security/alerts` | Strict `{telegramRecipient: string (1–64) \| null}` → the same shape. Audit `{telegram: boolean}`. |

**Notification** `security.trap` (priority high, link `tiphys://security/traps`; also to the owner's Telegram). Common params: `host` (this agent's name, except where noted), `agent`, `trap`. By `trap`:

| `trap` | More params |
| --- | --- |
| `token` | `name` (the decoy's name), `from` (client address, ≤64), `path` (request path, ≤120). At most once a minute per decoy. |
| `file` | `path` |
| `fileMissing` | `path` (once while it is missing, also when the agent starts and finds it gone; a file that comes back is armed without an alarm) |
| `audit` | `host` (the audited host's *name*), `who` (`auid/uid`), `how` (program), `object` (path), `at` (audit time) of the newest new event, and `count` (new events found in that poll: **one alarm per host and poll**). Events of the last 10 minutes, each announced once, also in the first poll after a start. |
| `db` | `user` (the decoy user), `host` (the log's `host` label), `stream` (container or unit) |
| `test` | none |

#### Black box

Behaviour, record format and verification: [Black box](../features/security.md#black-box).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/blackbox/status` | `{mode: off\|local\|push (the mode the agent **started** with), head: {count, hash} \| null (local), pending: number \| null (push: queued records), lastError: string \| null (push: "http 401", "unreachable", …), lastSentAt, url}`. |
| GET | `/v1/blackbox/verify` | Local only (`409 agent.blackbox.notLocal`). Verifies the chain up to the head it had when the call started: `{ok, count, head, brokenAt: seq\|null, reason: sequence\|link\|hash\|truncated\|anchor\|null, anchors: [{date, count, hash, telegram, at}] (latest 60), anchorMismatch: [dates], torn: number}`. `torn` counts lines that hold no record (a crash mid-write); they are skipped and don't make `ok` false. All anchors on file are checked against the whole chain, and an anchor for a count past the chain's end is a mismatch (`reason: "anchor"`); a chain shorter than the `head.json` kept next to it is `truncated`, also after a restart. A failure sends `blackbox.broken` (once). |
| GET | `/v1/blackbox/recent?limit=` | Local only. `{records: [record]}`, newest first. `limit` 1–500 (100); reads at most the last 2 MiB of the file. |
| POST | `/v1/blackbox/anchor` | Local only. Verifies, and if today's anchor doesn't exist yet, sends it to the owner's Telegram and records it. → `{anchors}`. Audit `{anchor: true}`. |
| PUT | `/v1/blackbox/settings` | Strict `{mode: off\|local\|push, url?: https URL\|null, token?: "tps_…"\|null}` → `{mode, url, hasToken, restartRequired}`. `push` needs a URL and token (`400 agent.security.tokenRequired`). The stored token is kept only while the URL stays the same (a new URL without a token drops it). `restartRequired: true` when `mode` differs from the running one. Audit `{mode}`. |
| POST | `/v1/blackbox/append` | **Service token with the `blackbox` scope** (a device token is `403 agent.auth.scopeDenied`); body limit 1 MiB; 10 per minute per token (`429 agent.security.rateLimited`); local only; `507 agent.blackbox.full` at the size limit. Strict `{entries: [{at: string ≤40, kind: audit\|event\|lockdown, data: object}] (≤200), dropped?: integer}` → `{accepted, head: {count, hash}}`. Each entry is appended with `source: "service:<token name>"` and `data.sentAt = at`; `dropped` adds a `blackbox.dropped` event. |

**record**: `{seq, at, source, kind: audit\|event\|lockdown, data, prev, hash}`, `hash = hex(SHA-256(prev + "\n" + JSON.stringify({seq, at, source, kind, data})))`, first `prev` 64 zeros. `audit` data is the audit entry (`{at, device, method, path, status, detail?}`; requests that never authenticated, with status 401, 403 or 429 and no device, are not recorded), `event` data is `{key, params}`, `lockdown` data is `{action: recoveryCodeCreated\|badRecoveryCode\|lockdown, …}` (`lockdown` adds `by`, `ip` and the fan-out result `targets: ["name:ok", "name:502", "name:unreachable"]`).

**Notification** `blackbox.broken`: params `host, agent, at (first bad seq; the record count for `full`), reason (a verify reason, or `full` when the 1 GiB limit was reached)`; priority high; link `tiphys://security/blackbox`; also to the owner's Telegram.

#### Lost phone and lockdown

Behaviour: [Lost phone](../features/security.md#lost-phone).

| Method | Path | Description |
| --- | --- | --- |
| POST | `/v1/security/recovery` | Device token. Strict `{confirm: true}` → `{code: "XXXXX-XXXXX-XXXXX-XXXXX-XXXXX", createdAt}`. The code is shown **once**; only a scrypt hash (`N=2^15, r=8, p=1`, 16-byte salt) is stored, replacing any earlier code. Audit `{recovery: "created"}` and a black box `lockdown` record. |
| GET | `/v1/security/recovery` | `{configured, createdAt}`. |
| POST | `/v1/security/lockdown` | **No token** (route config `public`; the Tailscale-login check **still applies**). Body limit 4 KiB. `{code}` → `{ok: true, targets: [{id, name, ok, status: number\|null}]}`. Order: the code shape is checked (`401 agent.security.badRecoveryCode` for a malformed one, no limit is used up), then the limits (`429 agent.security.rateLimited`: **5 attempts per address per 10 minutes, 30 an hour in total, one check at a time**; in memory), then the code, fan-out to `lockdownTargets`, revoke-all here, and **last** the `security.lockdown` notice (`by: "recovery"`), so that it reaches the owner's Telegram and not the revoked phone. A well-formed wrong code is `401` and is also written to the black box with the caller's address. Audit (success) `{lockdown: true, targets: n, failed: n}`; the entry's device is `null`. |
| POST | `/v1/security/lockdown/remote` | Service token with the **`lockdown`** scope, or a device token. Strict `{confirm: true}` → `{ok: true}`. Records `{action: "lockdown", by: "service:<name>" \| "device:<id>"}` in the black box, revokes all here, then sends `security.lockdown` (`by: "remote"`). Audit `{lockdown: true}`. |
| GET | `/v1/security/lockdown/targets` | `{targets: [{id, name, url, hasToken: true}]}`. |
| POST | `/v1/security/lockdown/targets` | Strict `{id, name (1–80), url (https), token ("tps_…")}` → `201 {target}`. `409 agent.security.hostExists`, `409 agent.security.tooManyHosts` (20). Audit `{target: id}`. |
| DELETE | `/v1/security/lockdown/targets/:id` | `{ok: true}`. Audit `{target: id}`. |

*Revoke all* empties `devices`, `serviceTokens` and `push.endpoints` in `agent.json` (the same as `POST /v1/devices/revoke-all`). The fan-out calls each target with `Authorization: Bearer <target token>`, body `{"confirm": true}`, 15 s timeout, no redirects, all in parallel; a failure is reported in `targets`, never aborts the lockdown. CLI: `tiphys-agent lockdown --url https://atlas.my-tailnet.ts.net` (the code is read from standard input).

**Notification** `security.lockdown`: params `host, agent, by: recovery\|remote`; priority high; link `tiphys://security`; also to the owner's Telegram.

#### Outside view and attack detection (S-5)

Device tokens only. Behaviour: [Outside view](../features/security.md#outside-view), [Attack detection from Cloudflare](../features/security.md#attack-detection-from-cloudflare).

| Method | Path | Description |
| --- | --- | --- |
| GET | `/v1/security/exposure` | `{config: {enabled, targets: [{id, kind: ip\|domain, value, expectedPorts}], extraPorts, intervalDays}, running, last: run \| null, history: [{at, findings: count}] (≤12)}`. |
| PUT | `/v1/security/exposure` | Strict `{enabled: boolean, targets: [{id, kind, value, expectedPorts?: [ports] (≤50)}] (≤30), extraPorts?: [ports] (≤100), intervalDays?: 1–30 (7)}` → `{config}`. `targets` replaces the list (a host name or an IPv4 address as `value`); an omitted `extraPorts` or `intervalDays` is kept. Audit `{enabled, targets: n}`. |
| POST | `/v1/security/exposure/run` | Runs now (also when `enabled` is off): `202 {started: true}`. `409 agent.security.scanBusy`, `429`. Audit `{exposure: true}`. |
| GET | `/v1/security/attacks` | `{configured (a read token is set), lastRun: {at, zones, error: string\|null} \| null, offenders: [{zone, ip, country, errors, scannerHits, paths: [≤10], firstSeenAt, lastSeenAt, blockedUntil: string\|null}]}`, newest sighting first. Offenders are kept 7 days. |
| POST | `/v1/security/attacks/run` | Runs one pass **synchronously** → `{offenders (new today), blocked (blocked now)}`. `409 agent.security.cloudflareNotConfigured`, `502 agent.security.cloudflareUnauthorized` / `cloudflareFailed`, `409 agent.security.scanBusy`, `429`. Audit `{cloudflare: true}`. |
| GET | `/v1/security/cloudflare` | `{hasReadToken, hasBlockToken, block, blockHours, zones, allowIps}`. |
| PUT | `/v1/security/cloudflare` | Strict, all optional: `{readToken?: string (≤200)\|null, blockToken?: same, block?: boolean, blockHours?: 1–720 (24), zones?: [zone names] (≤50), allowIps?: [IP addresses] (≤50)}` → the `GET` shape. Tokens: omitted = keep, `null` = remove, string = replace. `block: true` without a block token (stored or sent) is `400 agent.security.tokenRequired`. Audit `{fields: [names]}`. |

**run**: `{at, targets: [{id, kind, value, openPorts?: [ports] (ip), error?: "failed" (domain)}], findings: [{id, rule, severity: critical\|high\|medium\|low, target, params}]}`. Rules: `exposure.openPort` (high, `port`), `exposure.leakPath` (critical, `path`), `exposure.tlsExpiry` (high, critical under 3 days, `days`; the certificate is read without verifying it, so an expired one is reported with a negative `days` rather than as unreachable), `exposure.noHttps` (medium, `status`), `exposure.noHsts` (low), `exposure.headers` (low, `missing`), `exposure.unreachable` (medium, `what: tls\|https`).

**Notifications.**

| Key | Params | Notes |
| --- | --- | --- |
| `security.exposure` | `host, agent, count (new findings), targets (up to 3, comma-separated)` | priority high; link `tiphys://security/exposure`. First run: critical findings and expiring certificates (`exposure.tlsExpiry`) only; later runs: new open ports, leaking paths, expiring certificates and critical findings. |
| `security.attack` | `host, agent, count (new offenders), zones (up to 3), blocked (blocks made in that run)` | priority default; link `tiphys://security/attacks`. At most once per address and zone per day. Not an incident. |

#### Notifications (S-2 to S-5)

Overview of the keys above, all sent by the monitoring server's agent (or whichever agent runs the feature): `security.vulns`, `security.secretFound`, `security.trap`, `security.exposure`, `security.attack`, `blackbox.broken`, `security.lockdown`. `security.trap`, `security.secretFound`, `blackbox.broken`, `security.lockdown` and `security.change` with `severity: critical` are relayed to the owner's Telegram as a title only (`🚨 Tiphys güvenlik · <host> · <title>`, Turkish text). Notices that are not `sensitive` are also appended to the black box as `event` records.

### screen

Feature `screen` (`screen/*.ts`; Linux only; was `gamemode`, PLAN.md §20). One kiosk framework for the screen modes
`game`, `work` and `focus` (`sleep` is reserved). A **display host** shows a mode in a Firefox kiosk; a **source host**
produces the data. One host can be both: its display reads its own producer in-process as the source `self` (no
network, no token). Nothing runs until a mode is started (display) or a topic is subscribed (source).

**Display host**

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| GET | `/v1/screen` | device | `{running, mode\|null, startedAt\|null, placement, visible\|null, settings: {placement, scratchBind, lastMode, batterySaver, share, modes}, sources: [{name, url\|null, state: off\|connecting\|ok\|down, topics}], veil, focus: {phase: idle\|focus\|short\|long, endsAt\|null, pausedLeft\|null, total\|null, round, longEvery, task\|null, now}, map: {present}, live: {music\|null, truck\|null, claude: {sessions, waiting}\|null, jobs\|null}}`. `sources` starts with `self`. `live.claude`/`live.jobs`: counts from the latest relayed `claude`/`jobs` messages (summed over sources; null when no source sent one), for the phone's one-line summary. `visible` is whether the kiosk is on screen (false = the page is paused). `veil`: the privacy veil is on. `focus`: the Focus timer (idle unless the Focus mode runs); times in ms since the epoch (`now` = the agent's clock, for skew), `pausedLeft`/`total` in ms, `round` = the current focus round (in a break the one just finished; 0 idle). Tokens are never returned. |
| PUT | `/v1/screen` | device | Strict `{settings?: {placement?, scratchBind?, lastMode?, batterySaver?, share?: {code}, modes?: {game?, work?, focus?: partial settings incl. layout}}, sources?: {<name>: {url, token}\|null}}` → same as GET. Only the fields sent change; `null` removes a source. A layout is checked (`400 agent.screen.badLayout`). While running: the page gets `settings` (or `layout`), the backlight follows, a changed source reconnects, subscriptions follow. |
| POST | `/v1/screen/start` | device | `{mode?}` (default `lastMode`) → same as GET. Idempotent; while running a different mode is a switch. `409 agent.screen.noSource`, `409 agent.screen.bindTaken`, `503 agent.screen.noDisplay`, `502 agent.screen.startFailed` (everything done so far is undone). |
| POST | `/v1/screen/mode` | device | `{mode}` → same as GET. Hot switch: the page gets a `layout` message (and the latest data again), the source subscriptions and the backlight follow; Firefox is not restarted. Not running: only `lastMode` is stored. |
| POST | `/v1/screen/stop` | device | Idempotent → same as GET. |
| POST | `/v1/screen/focus` | device | Strict `{action?: start\|pause\|resume\|skip\|reset, task?: string(≤ 80, one line)\|null}` (at least one) → `{focus}` (as in GET). Only while the Focus mode runs (`409 agent.screen.notFocus`). `start`: idle → focus round 1, in a break → the next round now, a paused round → resume; `pause`/`resume` keep the time left; `skip`: focus → short (or every `longEvery`-th round long) break, break → next round; `reset`: idle. A phase that ends starts the next one by itself. `task` alone sets the task line; `""`/`null` clears it. A phase change sends the page `focus` and records/pushes `screen.focus.phase {phase, from, round, cause: timer\|action}` (never the task); the push's `data` (sent, never recorded) has `agent` (this agent's name), `quiet` (`"1"` when `modes.focus.quietPhone`) and `endsAt` (ms, while ticking), for the phone's ongoing notification and its quiet filter. When the mode stops or switches away with a running timer, one more push `{phase: idle, from, round, cause: stop}`. |
| POST | `/v1/screen/veil` | device | `{on}` → same as GET. Privacy veil: the page drops its view for a dim clock at once; until it is lifted the agent sends the page no layout or topic message (their state is kept and replayed when it lifts). Kept across an agent restart, gone with the mode. `409 agent.screen.notRunning` when no mode runs. |
| WS | `/v1/screen/live?t=<display token>` | display token | Kiosk page socket. On connect: `layout`, every source's `source` state, the latest relayed messages, `focus` in Focus mode, `pause` if hidden (veiled: only `veil` and `pause`). Then relayed messages and binary spectrum frames. Page → agent: `{"type":"stop"}`. Closed with `4410` on stop, `1012` when the agent restarts (the page reconnects with the same token). |
| GET | `/v1/screen/art?t=…&id=…` | display token | Cover proxy, as `/v1/gamemode/art` below. |
| GET | `/screen/`, `/screen/<file>`, `/screen/map/<file>` | none (kiosk) | The kiosk page and map data, as `/gamemode/…` below. |

Kiosk messages (agent → page): `{type:"layout", mode, template, cards:[{kind, source, enabled}], settings}`,
`{type:"settings", ...}`, `{type:"source", name, state, retryInSec?}`, `{type:"pause"}`, `{type:"resume"}`,
`{type:"focus", ...GET's focus, cause: "timer"\|"action"\|null}` (`timer`: the phase ended by itself → chime),
`{type:"veil", on}`, and relayed
topic messages with their source added as `src` (`{"src":"main","type":"music",…}`); spectrum frames are binary.

Lifecycle: as described for Game mode below, with the unit, app id, rule and tmpfs dir `tiphys-screen`
(`$XDG_RUNTIME_DIR/tiphys-screen/`), `--why=Tiphys Ekran Modu`, the page at `/screen/`, and these additions:
- **Light Firefox profile:** one content process, no Fission, no process prelaunch, 32 MB memory cache and no disk
  cache (the profile is on tmpfs), no prefetching, telemetry/updates/studies off.
- **Placement** (`screen.placement`, read at start): `fullscreen` puts the window on the mode's named workspace
  (`yol` / `is` / `odak` for the mode it was started in) and focuses it; `scratch` sends it silently to `special:tiphys`
  (rule `workspace special:tiphys silent`) and binds `screen.scratchBind` to `togglespecialworkspace tiphys`
  (classic: `hyprctl keyword bind MODS,key,togglespecialworkspace,tiphys`; Lua: `hyprctl eval 'hl.bind("MODS + key",
  hl.dsp.workspace.toggle_special("tiphys"))'`) after checking `hyprctl -j binds` (taken → `409 agent.screen.bindTaken`).
  When the page first connects the window is moved there if needed (`movetoworkspacesilent special:tiphys,address:…`)
  and the workspace is shown once. Stop: unbind (`keyword unbind MODS,key` / `hl.unbind("MODS + key")`), rule off.
- **Visibility:** while running, the Hyprland event socket is watched (workspace, special workspace and monitor
  events → `hyprctl -j monitors`). Not on screen (scratch hidden, another workspace in front, DPMS off) → `pause` to
  the page, which stops all drawing, timers and CSS animations, and the pausable topics (spectrum) are unsubscribed;
  `resume` when shown again.
- **State file:** every side effect (unit, work dir, rule, keybind, previous workspace, backlight) is written before it
  is made; stop and the next agent start after a crash undo it. A 0.5 Game mode left in `tiphys-gamemode/` is cleaned
  up the same way. Events: `screen.started {mode}`, `screen.stopped` and `screen.focus.phase` (above).
- **Agent restart:** when the agent's own systemd unit is being restarted (a `restart` job in `systemctl list-jobs`
  for the unit named in `/proc/self/cgroup`), a running mode is left as it is and the next agent adopts it from the
  state file (which also holds the display token, 0600 on tmpfs like `start.html`) if `tiphys-screen.service` is
  still active; the page reconnects with the same token. The same adoption follows a crash while Firefox still runs.
  Any other stop of the agent stops the mode. The Focus timer's times (not the task) are in `focus.json` in the work
  dir; a phase that ended meanwhile is caught up. The task line is memory only and is lost on a restart.
- **Autoplay:** the kiosk profile allows media/WebAudio autoplay (`media.autoplay.default=0`,
  `media.autoplay.blocking_policy=0`, `media.autoplay.block-webaudio=false`) for the Focus ambient sound and chime.
- **Sources:** for the running mode's layout the display sums the topics of the enabled cards the page draws, per
  source, and keeps one connection per remote source with a non-empty topic set (none for `self`, which subscribes
  in-process). On open, and whenever the set changes, it sends `{"type":"subscribe","topics":[…]}`. A source that
  never opens `/v1/screen/feed` (an older agent) is tried on `/v1/gamemode/feed` next (all Game topics, no subscribe).
  Reconnect after 1, 2, 4, 8, 15, 30 s; a feed silent for 15 s is reconnected. Messages of topics not subscribed are
  dropped.

**Source host**

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| WS | `/v1/screen/feed` | service (`screen`; `gamemode` = music, spectrum, truck only) or device | Client → source: `{"type":"subscribe","topics":[…],"project"?:"auto"\|<absolute path>,"ci"?:bool}` replaces the topic set (`project`/`ci` only matter for `git` and `city`; a fixed path must be inside `allowedRoots`) (unknown or not allowed topics are dropped; ≤ 4 KB). Starts with no topics. A topic's producer starts with its first subscriber and stops with its last; a subscriber adding a topic gets its latest messages at once. `{"type":"hb"}` every 5 s. |
| GET | `/v1/screen/game/source` | device | As `/v1/gamemode/source`. |
| POST | `/v1/screen/game/plugin` | device | As `/v1/gamemode/plugin`. |

Topics (`screen/topics.ts`): `music` (messages `music`, `lyrics`), `spectrum` (binary frames, only while Velour plays;
dropped while the kiosk is hidden), `truck` (`truck`, `event`). Card kinds → topics: `map`, `cockpit` → truck;
`lyrics` → music; `music` → music (+ spectrum in Game mode when `spectrum` is on); `system`, `jobs`, `git`,
`servers` → the topic of the same name; `city` → city, claude and (with `modes.work.diff` on) diff. A `gamemode`
token never gets `claude` or `diff`. Templates: `game` (map, cockpit, music, lyrics), `work` (city, day,
system, jobs, git, music, servers), `focus` (focus, task, day, music, servers). `focus` → claude and servers (only
for its critical pills: Claude waiting for approval, a server down); `task` → nothing (the task comes with `focus`).
`system` is dropped while the kiosk is hidden; while it is
hidden the display host also drops `touch` events (the city state keeps following).

Work topics (`screen/producers/*.ts`; each starts with its first subscriber, stops with its last, sends only changes):
- `system` (every 2 s from `/proc` and `/sys`, no process per sample; NVIDIA through one long-lived
  `nvidia-smi -lms 2000`, Intel from the GT idle residency): `{type:"system", cpu (0..1), cores, mem:{used,total}
  (bytes), temp|null (°C), gpu:{util, temp|null, memUsed|null, memTotal|null}|null, battery:{level, charging}|null}`.
- `jobs` (every 3 s: `run-*.scope` user cgroups, `tools/limited.sh` jobs and known build/test processes older than
  30 s; environments are never read): `{type:"jobs", running:[{id, name, cmd (≤120, paths cut to their last part,
  redacted), dir (basename)|null, startedAt (ms), cpu (cores), mem (bytes), kind: scope|proc|limited}]}`;
  `{type:"jobDone", id, name, cmd, dir, kind, durationSec, exitCode: null}`.
- `git` (non-recursive `fs.watch` on the git dir and refs, 500 ms debounce, one `git status` + `git log -3`; working
  tree changes come from the `city` watchers of the same project (≤ 1 s), without a city a 60 s refresh;
  `gh run list` every 5 min only with `ci`): `{type:"git", root (basename), branch|null, head, upstream,
  ahead, behind, changed, untracked, conflicts, commits:[{hash7, subject (≤80), at}], ci:{state, at}|null}` or
  `{type:"git", root|null, none: noProject|notRepo|notAllowed}`. `auto` = the most recently active Claude session's
  working directory (Tiphys or terminal), else the focused terminal's shell, walked up to the git root.
- `city` (same project selection as `git`; `git ls-files -t --cached --others --exclude-standard` + a streamed line
  count per file, binaries/> 2 MB/symlinks skipped; above 20 000 files aggregated per folder with lines estimated
  from size; one non-recursive `fs.watch` per directory holding listed files, at most 5000, never `.git`,
  `node_modules`, `build`, `dist`, `.dart_tool`, `target`; all closed with the last subscriber):
  `{type:"city", root (basename), files:[[path, lines, kind]], truncated, total? (with truncated), masked}` or
  `{type:"city", root|null, none: noProject|notRepo|notAllowed}`; then `{type:"cityPatch", upsert:[[path, lines,
  kind]], remove:[path]}`, `{type:"touch", path, kind: edit|create|delete, by: null}` (≤ 1 per file per second, ≤ 50
  per second) and `{type:"commit", hash7, subject}` (a new HEAD whose parent was the old one). `kind`: code, dart,
  docs, config, web, other. Paths are relative to the project root; without `screen.share.code` on the source every
  path segment is an opaque 8-hex token (`masked: true`). The display host folds `cityPatch` into the `city` it replays
  to a new page; a `city` message may be up to 16 MB (others 1 MB).
- `servers` (uptime bridge + incident room, compared every 5 s in memory): `{type:"servers", available, hosts:[{name,
  up, since|null}], incidents}`.
- `claude` (Tiphys `code` sessions from the manager's events; terminal sessions from one non-recursive `fs.watch` per
  `<claude config dir>/sessions/` (the pid checked against `/proc` on every change and every 10 s) and only the
  appended bytes of their transcript): `{type:"claude", sessions:[{id (8), name (≤40), project (basename)|null,
  status: idle|running|waiting, origin: tiphys|terminal, recent:[{tool, path|null, kind: read|edit|null, at}] (≤5),
  waiting:{tool|null, path|null, since}|null, pending:[requestId]}]}` (sent when it changes, ≤ every 150 ms). Paths
  are relative to the subscriber's project root (same selection as `git`); outside it `null`; without
  `screen.share.code` they are the city's masked tokens (or `null` without a city). A city `touch` after a session's
  Edit/Write/MultiEdit/NotebookEdit of that file (≤ 30 s) carries `by: <session id>`.
- `diff` (only with `screen.share.code` on the source, only Tiphys sessions; terminal sessions never get one):
  `{type:"diff", sessionId, session, requestId, tool, at, path, lang, added, removed, hunks:[{oldStart, newStart,
  lines}], truncated, more, binary, created}` for Edit/MultiEdit/Write/NotebookEdit of a file inside the project
  (unified, context 3, ≤ 400 lines / 64 KB, `more` = lines left out, redacted), `{…, tool:"Bash", command, reason}`,
  or `{…, tool, summary}` (non-secret scalar input fields, redacted); `{type:"diffResolved", requestId, allow}` when
  the permission is answered or the session ends. The display host replays pending diffs to a new page. Approval
  stays on the phone; the kiosk page has no approval route.

**Compatibility (one release):** `/v1/gamemode`, `/v1/gamemode/{start,stop,live,art,feed,source,plugin}` and
`/gamemode/*` keep the 0.5 shapes and `agent.gamemode.*` error codes; their "source" is `screen.sources.main`
(`PUT /v1/gamemode {source}` also points the Game cards at it). `/v1/health` and `GET /v1/config` report
`features.gamemode` (= `screen`); `PATCH /v1/config` and `init --features` accept `gamemode` for `screen`.

### gamemode

> The routes below are the 0.5 Game mode API, kept as aliases for one release; the feature is now `screen` (see
> [screen](#screen)). Where this section says `gamemode` unit/dir/events, read `tiphys-screen` / `screen.*`.

Feature `gamemode` (now `screen`, `screen/*.ts`; Linux only). The laptop next to the PC becomes an ambient second screen: the
song playing in Velour (cover colours, spectrum, synced lyrics), the ETS2 cockpit and the truck's position. Both sides
load with the flag; which one a machine plays depends on use: the **source** (PC) serves the feed, the **display**
(laptop) runs the kiosk and relays the feed. Nothing runs until a feed subscriber connects (source) or the mode is
started (display).

**Display host (laptop)**

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| GET | `/v1/gamemode` | device | `{running, startedAt\|null, settings, source: {configured, url\|null, state: off\|connecting\|ok\|down}, map: {present}, live: {music: {title, artist, playing}\|null, truck: {state, from\|null, to\|null, speedKmh\|null}\|null}}`. `live` is filled only while the mode runs (the upstream connection exists only then). The source token is never returned. |
| PUT | `/v1/gamemode` | device | Strict `{settings?: Partial<settings>, source?: {url, token}\|null}` → same as GET. A partial `settings` changes only the fields sent; the open kiosk page gets a `settings` message at once. A new backlight value is applied at once while running. A new source reconnects the relay. |
| POST | `/v1/gamemode/start` | device | Idempotent → same as GET. `409 agent.gamemode.noSource` when no source is set, `503 agent.gamemode.noDisplay` without a Hyprland session, `502 agent.gamemode.startFailed` when `systemd-run` fails (everything done so far is undone). |
| POST | `/v1/gamemode/stop` | device | Idempotent → same as GET. |
| WS | `/v1/gamemode/live?t=<display token>` | display token | Kiosk page socket. On connect: the latest `settings`, `source`, `music`, `lyrics`, `truck`; then every relayed message and binary spectrum frame (frames only while `settings.spectrum`). Page → agent: `{"type":"stop"}` (Esc held 1 s) stops the mode. Closed with `4410` on stop. A wrong or old token is `401` before the upgrade. |
| GET | `/v1/gamemode/art?t=<display token>&id=<artId>` | display token | The cover of the **current** `music` message only: its `artUrl` must be https; ≤ 5 MB, image magic bytes, 10 s timeout, 8 covers cached in memory. Anything else `404 agent.gamemode.noArt`. |
| GET | `/gamemode/`, `/gamemode/<file>` | none (kiosk) | The kiosk page from the repo's `display/` folder (resolved as `../display` next to the agent's `dist/`, then the repo root's `display/`). |
| GET | `/gamemode/map/<file>` | none (kiosk) | Map data from `~/.local/share/tiphys/gamemode/map/` (`$XDG_DATA_HOME` respected) with single-range requests (`206`, `416`). |

Static path rules: each URL segment is decoded once; empty, `.`, `..`, hidden (`.x`) segments, `/`, `\` or NUL after
decoding, more than 8 segments and unknown extensions (allowed: html, js, mjs, css, json, svg, png, webp, jpg, woff2,
woff, ttf, otf, wasm, pbf, pmtiles) are `404`; the resolved real path (symlinks followed) must stay inside the root;
no directory listing. `Cache-Control: no-cache`, `X-Content-Type-Options: nosniff`.

Settings (`config.gamemode.display`): `{scene: auto|drive|music, lyrics, spectrum, motion: low|normal|high,
brightness: 5..100|null (null = don't touch the backlight), clock24, dimIdleMinutes: 0..120 (0 = never)}`.

Start, in order: tmpfs work dir `$XDG_RUNTIME_DIR/tiphys-gamemode/` (0700) with an empty Firefox profile (`user.js`: no
session restore, telemetry, updates, first-run pages or fullscreen warning; WebRender and hardware acceleration on)
and a state file; a leftover `tiphys-gamemode` unit is stopped first; the active workspace is remembered; the named
window rule `tiphys-gamemode` for the app id `tiphys-gamemode` (workspace `name:yol`, fullscreen, border 0, no shadow,
rounding 0, no animation) is set with `hyprctl keyword windowrule[tiphys-gamemode]:…` (classic config) or
`hyprctl eval 'hl.window_rule({…})'` (Lua config); the backlight is saved and set (`brightnessctl`; no permission =
untouched); workspace `name:yol` is focused; then:

```
systemd-run --user --unit=tiphys-gamemode --collect -p StandardOutput=null -p StandardError=null \
  --setenv=WAYLAND_DISPLAY=… --setenv=XDG_RUNTIME_DIR=… --setenv=HYPRLAND_INSTANCE_SIGNATURE=… \
  --setenv=DBUS_SESSION_BUS_ADDRESS=… --setenv=MOZ_ENABLE_WAYLAND=1 -- \
  systemd-inhibit --what=idle:sleep "--why=Tiphys Oyun Modu" \
  firefox --kiosk --no-remote --name tiphys-gamemode --profile <work dir>/profile file://<work dir>/start.html
```

`start.html` (0600, tmpfs) forwards to `http://127.0.0.1:<port>/gamemode/#t=<display token>`, so the token is never on
a command line. Stop (phone, page, Firefox gone — the unit is checked every 5 s — or agent shutdown): `systemctl --user
stop tiphys-gamemode.service` (the whole cgroup), the work dir is removed, the rule is disabled
(`windowrule[tiphys-gamemode]:enable false` / `enabled = false`), the previous workspace is focused again if you are
still on `yol`, the backlight is restored, the token dies, page sockets and the upstream close. If the agent crashed
while the mode ran, the next start finds the state file and does the same. The event log gets only
`gamemode.started` / `gamemode.stopped`.

Relay: the display agent opens `wss://<source>/v1/gamemode/feed` with `Authorization: Bearer <source token>` only while
the mode runs; reconnects after 1, 2, 4, 8, 15, 30 s (`source {state: "down", retryInSec}`); a feed silent for 15 s is
reconnected. Known JSON messages (`music`, `lyrics`, `truck`, `event`) and 25-byte spectrum frames are relayed
verbatim; anything else is dropped. `truck` messages and frames are skipped for a page with more than 256 KB queued.

**Source host (PC)**

| Method | Path | Auth | Description |
| --- | --- | --- | --- |
| WS | `/v1/gamemode/feed` | service (`gamemode`) or device | The feed (messages below). One shared producer for all subscribers, started by the first and stopped by the last (Velour long-poll ends, `pw-record` is killed). A new subscriber gets the latest `music`, `lyrics` and `truck` at once. Nothing is accepted from subscribers. |
| GET | `/v1/gamemode/source` | device | `{velour: bool, audio: bool, ets2: {gameDir\|null, plugin: installed\|missing\|outdated, version\|null, running: bool, telemetry: ok\|unsupported\|none}}` |
| POST | `/v1/gamemode/plugin` | device | Strict `{action: install\|remove}` → same as GET source. `404 agent.gamemode.noGame` without a Linux ETS2 in the Steam libraries, `502 agent.gamemode.pluginDownloadFailed`, `502 agent.gamemode.pluginHashMismatch`, `502 agent.gamemode.pluginBadArchive`. CLI: `tiphys-agent gamemode install-plugin\|remove-plugin`. |

Producers: **music** long-polls Velour's `wait` and sends `music` when `rev` changes, `lyrics` on a track change, `next`
from `queue` when the track or `queueRev` changes; Velour unreachable → `{type: "music", none: true}`, retried every
3 s. **Spectrum** runs only while Velour plays: `pw-record --target <default sink node.name> -P '{ stream.capture.sink=true
node.name=tiphys-gamemode-spectrum }' --rate 16000 --channels 1 --format s16 --latency 20ms --raw -` (the output's
monitor, never the microphone), Hann-windowed 1024-point FFT, 24 log bands 40 Hz–7.6 kHz, 48 dB range under a moving
ceiling, attack/release smoothing, 30 fps. **Truck** reads ETS2's shared memory 20 times a second while driving, once
a second otherwise. Titles, lyrics and job details are never logged.

ETS2: [truckermudgeon/scs-sdk-plugin](https://github.com/truckermudgeon/scs-sdk-plugin) v1.12.1 (MIT), release asset
`build-ubuntu-latest.zip` (SHA-256 `ac2f9871e2fa14edbf6c6c9c408fada04376545bdf83838d9fb59652e9b50a7e`) holding
`libscs-telemetry.so` (SHA-256 `ca18a9b32b99c79942f5cdd35e0236b070a5ff10fe3d17b3edf8ac2436b2aecc`), written to
`<game>/bin/linux_x64/plugins/`. The game directory comes from Steam's `libraryfolders.vdf` (native, `~/.steam`,
Flatpak and Snap Steam). The plugin's shared memory `/SCSTelemetry` (layout revision 12) is read from
`/dev/shm/SCSTelemetry`, or for Flatpak Steam from `/proc/<eurotrucks2 pid>/root/dev/shm/SCSTelemetry`. Another
revision → `telemetry: "unsupported"` and only `state: "none"` truck messages. States: no game process → `none`
(`reason: "noGame"`); game running without the shared memory (plugin missing or not loaded) → `none` (`reason:
"noPlugin"`); another layout revision → `none` (`reason: "unsupported"`); SDK inactive or paused before a profile is
loaded → `menu`; paused → `paused`; else `driving`. `timeScale` is the game's time compression from the telemetry
(game seconds per real second; 19 on roads, lower on ferries and trains), left out when the game reports none (the
page then assumes 19).

Messages (JSON text, `type` first, SI units unless named; binary frames: byte 0 = `0x01`, bytes 1–24 = bands 0–255):

```
{type:"settings", ...settings}                                  // display agent only
{type:"source", state:"connecting"|"ok"|"down", retryInSec?}    // display agent only
{type:"music", playing, title, artist, album|null, artId|null, artUrl|null, duration, position, at, next:[{title, artist}]}
  | {type:"music", none:true}
{type:"lyrics", artId|null, title, kind:"synced"|"plain"|"none", lines:[{t, text}]}
{type:"truck", state:"none"|"menu"|"paused"|"driving", at, speed, speedLimit|null, rpm, rpmMax, gear, gears, fuel, fuelCap,
  fuelRange, cruise, parkingBrake, lowBeam, highBeam, beacon, blinkerL, blinkerR, wear, cargoDamage|null, x, z, heading,
  gameTime, timeScale?, restMinutes|null, job:{from, to, toCityId, toCompanyId, cargo, income, currency,
  deadlineGameTime|null}|null, nav:{distance, time}|null}
  // state "none" → only {type, state, reason, at}, reason: "noGame"|"noPlugin"|"unsupported"
{type:"event", kind:"fine"|"ferry"|"train"|"toll"|"delivered"|"cancelled"|"fuelLow"|"rest", amount?, currency?, detail?}
```

`artUrl` (the https cover from Velour, `null` otherwise) is the one addition to the plan's contract: the display agent
needs it for the art proxy. `artId` is the first 12 hex characters of its SHA-256. Events: each flip of the plugin's
gameplay-event flags is one event (`amount` and `currency` EUR/USD from the event fields; `detail`: the fine offence,
or the ferry/train target); `fuelLow` once when fuel/capacity drops below 0.15 (re-armed above 0.17); `rest` once when
the next rest stop drops below 60 game minutes; the first sample after the game appears only sets the baseline.

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

Capture runs `wf-recorder` (wlr-screencopy). If it is missing or produces no frames, the agent falls back to a `grim` loop (at most 4 fps, MJPEG only) and sends a notice. On the helper backend capture is `tiphys-desktop stream` (MJPEG, at most 20 fps, no fallback; exit codes map to `agent.desktop.permission`, `.monitorNotFound`, `.unsupported`) and input goes through the helper (same key allow-list; `KPPlus`/`KPMinus` aren't available there). Only one stream per device can be open; a new one closes the old one with code `4409`.

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

`user`, `text`, `delta` (streaming text), `thinking`, `tool_use {id, name, input}`, `tool_result {toolUseId, text, isError, shot?}`, `init {model, cwd, permissionMode, slashCommands}`, `result {ok, subtype, text, costUsd, turns, durationMs, contextTokens, contextWindow}`, `permission {requestId, toolName, input, reason}`, `permissionResolved {requestId, allow}`, `sudo {requestId, host, attempt, investigate?}` and `sudoResolved {requestId, provided}` (security sessions), `control {active, expiresAt, reason}` (PC sessions), `status {status}`, `error {message}`, `restored`, `compacted`.

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
