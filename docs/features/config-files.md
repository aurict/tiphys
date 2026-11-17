# Config files and secrets

The config editor lets you view and change the `.env` files of your compose stacks from the phone, without ever
sending a secret value anywhere it doesn't need to go. Secrets are masked; showing one is a separate, rate-limited
request. Every save is previewed as a masked diff, confirmed, backed up and written atomically.

Phases C-1 and C-2 cover discovery, masked reading, reveal, preview → save, backups and restore, recreating the
affected services after a save, rotation metadata and the rotation reminder. Compose `environment:` editing comes in
C-3.

API reference: [../agent/api.md#configfiles](../agent/api.md#configfiles). Configuration: feature flag `configfiles`
(default off), the [`stacks`](../agent/configuration.md#stacks) and
[`configFiles`](../agent/configuration.md#configfiles) sections.

## Setup

1. Turn on `configfiles` and restart the agent.
2. Keep compose stacks under `~/stack/<name>/compose.yaml`, or set `stacks.roots`. Their `.env` and the services'
   `env_file` files are offered automatically.
3. Optional: add other `.env` files with `configFiles.extraPaths`.

## Which files

Only files the agent found itself are reachable; the app refers to a file by its `fileId` (a hash of its real path)
and no route accepts a path. A file qualifies when:

- its real path stays inside its root (the stack root; for an extra path, its own directory): a symlink pointing
  elsewhere is refused;
- it is a regular file owned by the user the agent runs as;
- it is at most 256 KB and valid UTF-8;
- it is named `.env`, `*.env` or `.env.*`.

Other files are listed under `skipped` with the reason, so you can see why something is missing.

## Reading

Each entry comes with its line number and a classification. An entry is a **secret** when its name contains `PASS`,
`PWD`, `SECRET`, `TOKEN`, `KEY`, `PRIVATE`, `CREDENTIAL` or `DSN` (but not names ending in `_FILE`, `_PATH`, `_DIR`,
which point at a secret), when its value is a URI with a password, or when the value looks generated (long, token
characters, mixed case and digits or long hex, high entropy). You can override the classification per key
(`PUT /v1/secrets/meta`, `secret: true|false`).

Secret values are never returned by the read routes: you get `masked: "••••32"` and the length. `POST …/reveal`
returns up to 10 values per call, at most 10 calls per minute per device, and records a `secrets.revealed` event with
the key names only. The app asks for the device lock before revealing and masks the value again after 30 seconds.

The parser follows Docker Compose's `.env` syntax: comments, blank lines, `export`, spaces around `=`, inline
` # comments` on unquoted values, single quotes (literal), double quotes (escapes, may span lines) and bare `KEY`
lines (taken from compose's environment). Lines it can't read are kept verbatim and listed under `issues`. A file with
an unterminated quote can't be edited (compose would read the lines below into the value).

## Saving

1. `GET` the file: it returns `hash`.
2. `POST …/preview` with `{baseHash, ops}` (`set`, `unset`, `rename`). The answer is a key-level diff with lengths
   only for secrets ("changed, 32 → 40 characters"), the services that use the changed keys, and a preview token.
3. `PUT …` with `{previewToken, confirm: true}`. The agent re-reads the file; if it changed since the preview, the
   save fails with `409 agent.configfiles.conflict` and nothing is written.

Untouched lines are kept byte for byte. An edited line keeps its indentation, `export`, quoting (when the new value
fits it, so `${VAR}` interpolation behaves as before) and inline comment. New values are written literally, and so is
any value with a `$` that isn't compose syntax (`${…}` or `$$`): compose would read `pa$word` in an unquoted or
double-quoted entry as `pa` (checked with `docker compose config`), so such a value gets single quotes (or `\$` inside
double quotes).

The write is atomic: the new content goes to a temp file in the same directory, is fsynced, and only after the size
and hash checks pass is the previous version copied to `~/.local/state/tiphys/config-backups/<fileId>/<time>`
(`0600`, last 10 kept); the temp file gets the original mode and group, and is renamed over the file. Right before the
rename the agent checks again that the path still resolves to the same regular file with the same content, so a file
swapped for a symlink in the meantime is never written through. If the original file is readable by everyone, the
save answers with the warning `worldReadable`.

**Affected services**: services that load the file with `env_file`, and, for a stack's root `.env`, services whose
definition references a changed key as `${KEY}` or `$KEY`.

## Recreating the affected services

`docker compose restart` doesn't reload `.env`, so the services have to be recreated. Ask for it in the preview with
`restart: "affected"`: the answer adds `restartPlan`, the exact command per stack:

```
docker compose -f <stack>/compose.yaml [-f <override>] up -d --no-deps <service…>
```

and the save must repeat `restart: "affected"`. The choice is part of what the preview token is bound to, so a token
previewed without a restart can't run one and vice versa (`409 agent.preview.invalid`).

After the file is written, the agent runs the command in the stack directory (no shell, 3 minute timeout), only for
services that were in the preview, are still affected and are defined in the stack. Then it watches them for up to 30
seconds: every container must be running and not unhealthy; an exit, `unhealthy`, a missing container or a growing
restart count fails early, `healthy` passes early. The answer lists each service with its state and the last part of
compose's error output (secrets masked, including the value the save replaced).

If recreating fails the **file stays saved**. The answer then contains `restore: {backupId}` (the version before the
save), you get a `config.restartFailed` notification, and `POST …/restore` with that backup undoes the change. A
restore can recreate the affected services the same way. Recreating is limited to 6 per 10 minutes per device. The
whole request can take about three and a half minutes.

Every save and restore records `config.saved` / `config.restored` with the key names, the backup id and the restart
outcome (`none`, `ok`, `failed`).

## Backups and restore

`GET …/backups` lists the kept versions. `POST …/restore {backupId}` previews the restore as a masked diff;
`POST …/restore {backupId, previewToken, confirm: true}` restores it, after backing up the current version.

## Rotation metadata

`secrets-meta.json` (next to `agent.json`, `0600`) keeps, per secret key, an HMAC fingerprint of the value (keyed by
`secrets-hmac.key`, which never leaves the agent), when it was first seen, when it last changed and whether the change
was made through Tiphys or outside it (noticed on the next read), plus an optional `maxAgeDays` and your mark.
`GET /v1/secrets/meta` returns the age and a `due` flag; there is no default policy (the app suggests 90 days).

**Reminder.** At startup and then daily the agent rescans every file and sends `secret.rotationDue` {host, file, keys,
count} for each file with secrets older than their `maxAgeDays` (age from the last change, or from when the agent first
saw the value). At most one notification per file per day, also across agent restarts. Key names only.

**Changes outside Tiphys.** Whenever a file is read (by the app, a save or the rescan every 10 minutes) a secret whose
fingerprint changed counts as rotated: `lastChangedAt` is reset, `changedBy` becomes `external` and the event
`secret.changedExternally` {file, keys, count} is recorded.

## Security notes

- Values never go to logs, the event stream, the audit log, notifications or error responses. The audit log records
  `{file, keys, restart}` with key names only; validation errors carry only field paths and issue codes. A test
  runs a full flow with a known value and searches all of them for it.
- The only copies are the file itself and its backups.
- While the feature is on, the agent keeps the current secret values of all discovered files in memory (refreshed at
  startup, on every read and save, and every 10 minutes; files that disappear are dropped) so the incident room can
  replace them with `[GİZLİ:KEY]` in collected logs and context.
- Device tokens only: service tokens are refused on every route.
