# Incidents

The incident room turns the agent's alert notifications into **incidents**: one record per problem, with the
context you need to understand it (recent logs, container state, recent commits of the stack, metrics, other events)
and a short list of safe actions you can run after a preview and a confirmation.

Phases I-1 to I-3 (this release) cover signals, grouping, context, rule-based hints, the lifecycle, restart/recreate
actions, deploy tracking, compose rollback, disk cleanup and the AI analysis (local or on the PC), similar incidents and
"Claude ile incele". Prometheus/Telegram (I-4) come later.

API reference: [../agent/api.md#incidents](../agent/api.md#incidents). Configuration: feature flag `incidents`
(default off), the [`stacks`](../agent/configuration.md#stacks) and
[`incidents`](../agent/configuration.md#incidents) sections.

## Setup

1. Turn on `incidents` and restart the agent. Local signals come from the existing monitors, so also turn on
   `alerts` (disk, failed units, Grafana, Docker events; Docker events need `docker`), and as needed `watch`,
   `backups` and `uptime`.
2. Keep compose stacks under `~/stack/<name>/compose.yaml`, or set `stacks.roots`.
3. Optional: link Uptime Kuma monitors to stacks with `incidents.links`.
4. Optional: AI analysis, see [AI analysis](#ai-analysis-i-3).
5. Try it: `POST /v1/incidents/test {"kind": "docker.died"}` sends a test notification for a fake container
   `tiphys-test`; it opens a test incident (no actions are offered for test incidents).

## Signals

The incident room doesn't poll anything itself. It observes notifications as they are sent:

| Opens | Clears | Target |
| --- | --- | --- |
| `disk.full` | `disk.ok` | mount |
| `service.failed` | `service.recovered` | unit |
| `grafana.alert` | `grafana.resolved` | alert name |
| `docker.died`, `docker.oom`, `docker.unhealthy`, `docker.restartLoop` | (the container runs, healthy, again) | container |
| `host.offline` | `host.online` | watched host |
| `backup.failed`, `backup.stale` | `backup.ok` | backup check |
| `uptime.down` | `uptime.up` | monitor |

With `incidents` on, three new notifications exist: `uptime.down` / `uptime.up` (an Uptime Kuma *important* beat that
flips down↔up; the first state after connecting is recorded silently), `docker.unhealthy` (Docker
`health_status: unhealthy`) and `docker.restartLoop` (3 or more unexpected exits of one container in 10 minutes). With
the feature off, existing notifications behave exactly as before.

Each signal has a fingerprint `kind|host|target`:

- a signal whose fingerprint belongs to an open or acknowledged incident is added to it;
- a signal matching an incident resolved less than 30 minutes ago reopens it;
- a signal on the same host and the same stack (compose project, or a linked monitor) within 5 minutes of that
  incident's last signal joins it; without a stack, the same target joins;
- otherwise a new incident opens.

The source notification itself carries the incident: `link: tiphys://incidents/<id>` and `data.incidentId`. There is
no extra "incident opened" notification.

## Lifecycle

`open → acknowledged → resolved`, by hand (`ack`, `resolve` with an optional note, `reopen`), or automatically: when
every part of an incident has cleared (closing notification, or the container running and healthy again) and stays so
for 10 minutes with no new signal, the incident resolves itself and an `incident.resolved` notification goes out.

## Context

About 5 seconds after an incident opens (or reopens), the agent collects, within 60 seconds:

- the target's last 300 log lines (at most 60 KB), from `docker logs` or the journal, **redacted**;
- a `docker inspect` summary: image, created/started/finished times, exit code, OOM kill, restart count and policy,
  health, compose labels;
- for a stack in a git repository: `git log --since=48.hours -n 10` and `git status --porcelain`;
- host and container metrics around the incident from an in-memory ring (host every 30 s, `docker stats` every
  60 s, 2 hours kept);
- the deploy history of the incident's compose project (last 7 days; see [Deploys](#deploys));
- `config.saved` / `config.restored` events of the last 48 hours for the stack's files (key names only);
- the host's events of the last 2 hours, and similar incidents of the last 90 days (resolution note and the action
  that worked).

Rule-based hints point at likely causes: out of memory (OOM kill or exit 137), non-zero exit, restart loop, failing
health check, an image change of the service within the hour before the incident (recent deploy, from the deploy
history), a disk at 95 % or more, a port in use, a
refused connection.

## Deploys

With `incidents` and `docker` on, the agent snapshots its compose containers every 5 minutes and a few seconds after
each Docker `start` event: per compose service, the newest container's image id, image reference and creation time.
When a service's image id differs from the last one seen, a record goes to `incidents/deploys.jsonl` (`0600`, rotated
at 1 MB) and the **previous** image is tagged `tiphys-rollback/<project>-<service>:prev` (names lowercased, other
characters turned into `-`; a short hash is added when the name had to change, so two services never share a tag).
There is one tag per service: it moves to the newer previous image on the next deploy, and other tags in that
repository are removed unless a running container uses their image.

Why: `docker compose pull` or a rebuild leaves the old image untagged, and `docker image prune` would delete it. A
tagged image is not dangling, so it survives the usual prune (not `docker image prune -a`). If the previous image was
already gone, the record has `rollbackTag: null`. A rollback is itself an image change, so afterwards the image you
rolled back from becomes `:prev`.

The app reads the history with `GET /v1/incidents/deploys?stack=&service=`.

## Actions

The agent builds the candidates from the incident itself; nothing in the logs (or, later, model output) can add or
change one:

| Kind | Command (no shell) | When |
| --- | --- | --- |
| `container.restart` | `docker restart <container>` | container signals |
| `compose.recreate` | `docker compose -f <files> up -d --no-deps <service>` in the stack directory | the container's compose project is a discovered stack with that service. Unlike `compose restart`, this applies `.env` changes. |
| `unit.restart` | `systemctl [--user] --no-ask-password restart <unit>` | failed units (system units obey polkit) |
| `compose.rollback` | `docker tag <previous image id> <image reference>`, then `docker compose -f <files> up -d --no-deps --pull never <service>` in the stack directory | the service has a `tiphys-rollback/…:prev` image different from the running one, and its image reference is a tag (not a digest). The preview shows both image ids and creation times and warns that **database migrations are not rolled back**. |
| `disk.cleanup` | the chosen options (below) | disk signals, or a `diskFull` hint |

`disk.cleanup` options, each with an estimate of the space it frees in the preview:

| Option | Command | Notes |
| --- | --- | --- |
| `builder` | `docker builder prune -f` | unused build cache |
| `images` | `docker image prune -f` | dangling images only, never `-a`: `tiphys-rollback/*` images are tagged and stay |
| `containers` | `docker container prune -f --filter until=24h` | stopped containers older than a day (a fresh crash stays for inspection) |
| `userJournal` | `journalctl --user --vacuum-time=7d` | only when the agent user may delete the journal files; the usual persistent journal (`/var/log/journal`) belongs to root, so it is reported unavailable (`needsRoot`) |
| `systemJournal` | — | always unavailable: needs root |

Volumes are never pruned.

Running one is two steps: *preview* returns the exact commands and a preview token (120 s, single use, bound to your
device and that action), and *execute* needs the token and `confirm: true`. At most 6 executions per minute per
device and one running action per incident. 60 seconds after the command, a post-check (container running and not
unhealthy — for a rollback also on the previous image id —, unit active, or for disk cleanup the mount below 95 %) is
written to the timeline; a failed command or post-check sends `incident.actionFailed`.

## AI analysis (I-3)

Rule hints are always there. On top of them a model can read the incident and suggest causes and actions:

- **Where it runs** (`incidents.analysis.mode`): `local` runs a tool-less `claude -p` inside this agent (the PC);
  `remote` sends the bundle to the PC agent's `analysis` feature (`POST /v1/analysis/jobs` with a service token of
  the `analysis` scope) and polls it; `off` (default) keeps rule hints only. Setup for a server:
  [configuration › incidents](../agent/configuration.md#incidents).
- **When**: about 10 seconds after the context of a new or reopened incident is collected (debounced; not for test
  incidents), and on demand with `POST /v1/incidents/:id/analyze` (3 per 10 minutes per incident, automatic runs
  included). The result is stored in the incident (`analysis`) with timeline entries `analysis` / `analysisResult`.
- **The bundle** is built on the incident's host and **redacted there, before it leaves** (the patterns plus the
  known secret values of the stacks' `.env` files, again at build time). Every line has an evidence id
  (`log:<source>#<line>`, `deploy:<n>`, `event:<n>`, `metric:<name>`, `signal:<n>`, `inspect:container`,
  `git:<hash>`, `config:<n>`); per-section budgets keep it under 120 KB (the oldest lines go first). It also carries the
  rule hints, the action candidates and similar past incidents (same fingerprint, 90 days) that were resolved with a
  note or a working action.
- **The model** (`claude -p --tools "" --strict-mcp-config --setting-sources ""`, Sonnet, in an empty 0700 directory,
  allowlisted environment) gets the bundle on stdin inside random-nonce markers `<<<VERI-<nonce> BAŞ …>>>` …
  `<<<VERI-<nonce> SON …>>>`, and is told that everything between them is data, never instructions. Its output is
  bound to a JSON schema whose `candidateId` is an enum of the bundle's candidates.
- **Validation** (on the PC and again on the incident's host): unknown candidate ids are dropped; evidence refs that
  aren't in the bundle are dropped and a hypothesis left without any is flagged `unsupported` ("kanıtsız"); summary
  ≤600, cause/why ≤300 characters; plain text only (markdown, HTML, links and control/bidi characters removed). The
  model can only *point at* a candidate: running it still needs the normal preview and confirmation.
- **PC unavailable**: if the PC can't be reached (or refuses, is busy, or doesn't answer within 5 minutes) the
  analysis is `unavailable` with a reason; the rule hints stay, the app offers "Yeniden dene", and the PC is never woken.
- **Notification**: `incident.analyzed {host, incidentId, summary ≤140}`, priority low, meant to silently replace the
  incident's source notification: `data.replaceKey` / `data.replaceParams` give the source notification's key and
  params, from which the app derives the same notification id. It is sent only to end-to-end encrypted endpoints and
  not written to the event stream (the summary is model text about logs).
- **"Claude ile incele"**: `GET /v1/incidents/:id/bundle?redacted=1` returns the redacted bundle as text (same markers
  and framing) for the app to start a normal Claude session on the PC. Only the redacted form exists; 10 calls per
  10 minutes per device.
- **Similar incidents**: `GET /v1/incidents/:id` also returns `similar`, recomputed on every read (same fingerprint,
  last 90 days, resolved-with-note/action first).

## Security

- Device tokens only: service tokens (including the `analysis` scope) can't reach these routes. The `analysis` scope
  opens only the PC's `/v1/analysis/jobs` routes, and a token sees only the jobs it started.
- The analysis model has no tools, its output is schema-bound and validated, and actions run only from agent-made
  candidate ids after a preview and a confirmation (see [AI analysis](#ai-analysis-i-3)).
- Logs and other text are redacted before they are stored: JWTs, Bearer/Basic credentials, `password=`/`token=`-style
  pairs, passwords in URIs, PEM private keys, and AWS/GitHub/Stripe/Slack/Google/Anthropic-style keys.
- Notifications carry ids and names only, never log content (the one exception, the analysis summary of
  `incident.analyzed`, goes only to end-to-end encrypted endpoints).
- Targets are validated with the same patterns as the Docker and services routes, and stack paths are confined to
  `stacks.roots` with `realpath`.
- The audit log records ids, the action and counts (`detail`), never note text or values.
- Files: `incidents/` next to `agent.json`, directory `0700`, files `0600`, atomic writes; resolved incidents are kept
  90 days, at most 500 incidents.
