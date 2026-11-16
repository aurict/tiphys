# Monitoring

Tiphys gathers the state of your machines and self-hosted services in the **System › Monitoring** section of the
app, and turns problems into [notifications](notifications.md). It works in two ways:

- **Agent-side checks** run continuously on a host (`argo`, `atlas`, …) and push a notification when something
  changes: local alerts (disk, failed services, crashed containers), Grafana alerts, host watch and backup checks.
- **App-side views** show data when you open them: Uptime Kuma sites, Grafana dashboards and alerts, Dozzle
  container logs, Homepage services, cross-host log search.

| Feature | Runs on | Agent feature flag | Config |
| --- | --- | --- | --- |
| Local alerts (disk, systemd, Docker) | agent | `alerts` (`docker` for container events) | `alerts` |
| Grafana alert notifications | agent | `alerts` | `alerts.grafana` |
| Host watch | agent | `watch` | `watch.hosts` |
| Backup checks | agent | `backups` | `backups.checks` |
| Uptime Kuma (Sites) | agent bridge | `uptime` | `uptimeKuma` |
| Homepage | agent | `homepage` | `homepage` |
| Grafana dashboards and alert list | app, direct | none | app integration |
| Dozzle | app, direct | none | app integration |
| Log search | app, over SSH | none | SSH hosts |

Feature flags and config keys are documented in [Agent configuration](../agent/configuration.md). Most of them can
be edited from the app under **Settings › Hosts › (host) › Agent settings**. Changes to features or alerts need an
agent restart (the app says *Saved. Restart the agent to apply feature changes.*); backup checks apply without a
restart.

## Local alerts

With the `alerts` feature (*Alerts (disk, services, Grafana)*), the agent checks every `alerts.intervalSeconds`
(default 300, minimum 30):

- **Disk full**: any mounted filesystem at or above `alerts.diskFullPercent` (default 90, range 50 to 100).
  `/boot*` and `/snap*` mounts are ignored. Sends `disk.full`, later `disk.ok`.
- **Failed services**: systemd units in the `failed` state, both user and system units
  (`alerts.failedServices`, default on). Sends `service.failed`, later `service.recovered`.
- **Docker containers** (only if the `docker` feature is also on): the agent follows `docker events`.
  - A container that exits with a non-zero code, without a `stop`/`kill` in the previous 60 seconds, sends
    `docker.died` with the exit code.
  - An out-of-memory kill sends `docker.oom`.
  - Restarts by a restart policy are recorded as `docker.restarted` in the event log only.
  - The same container and event type is reported at most once every 15 minutes, to keep crash loops quiet.

Each condition is reported once when it starts and once when it clears. Conditions already present when the agent
starts are recorded silently, so a restart does not repeat old alerts. `GET /v1/alerts` lists the active ones.

In the app, set the threshold, interval and *Notify when a systemd service fails* in Agent settings (visible when
the Alerts feature is on).

## Grafana

### Alert notifications (agent)

Under *Grafana alerts* in Agent settings, give the agent a Grafana URL, a service account token and optionally
Prometheus data source UIDs. On each alert check the agent reads:

- Grafana-managed alerts (always), and
- alerts of each listed Prometheus data source (through Grafana's data source proxy).

Alerts in the `firing` state send `grafana.alert` (with severity, from the `severity` label); when they stop firing,
`grafana.resolved`. If Grafana is unreachable, that round is skipped. *Use Grafana from my profile* copies the URL
and token from the app's Grafana integration.

### Dashboards and alert list (app)

**System › Monitoring › Grafana** talks to Grafana directly from the phone, using the Grafana integration in
**Settings › Integrations** (several instances are supported). It shows dashboards (favorites first) in a single
column layout with variables, time range and auto refresh; stat, time series, table and log panels are drawn in the
app. **Alerts** lists all alert rules, firing ones first; tap a rule to see its summary, query and since when it is
active. A Grafana notification opens this screen.

## Host watch

With the `watch` feature (*Watch hosts (offline alerts)*), an agent polls other hosts and reports when they stop
answering. A typical setup is the always-on server `atlas` watching the PC `argo`.

Configure `watch.hosts` in the agent config (there is no editor in the app yet):

```json
"watch": {
  "hosts": [
    { "hostId": "argo", "url": "https://argo.my-tailnet.ts.net/v1/health", "intervalSeconds": 60, "offlineAfterSeconds": 180 }
  ]
}
```

- `hostId`: the name used in notifications (match the host ID in your app profile).
- `url`: any URL that returns 2xx when the host is up. The agent's `/v1/health` endpoint is public, so no token
  is needed.
- `intervalSeconds` (min 15, default 60) and `offlineAfterSeconds` (min 30, default 180).

After `offlineAfterSeconds` without a successful answer the agent sends `host.offline` (with how many minutes it has
been down); when the host answers again, `host.online`. Each request times out after 10 seconds.
`GET /v1/watch` returns the current state. The host list is read at agent start: restart the agent after editing it.

## Backup checks

With the `backups` feature (*Backup status*), the agent evaluates each configured check every 15 minutes. Add and
remove checks under *Backup checks* in Agent settings; changes apply on save.

Two kinds of check:

- **File**: the newest file matching a path pattern (wildcards `*` and `?` only in the last part, for example
  `~/backups/notes/*.tar.gz`).
  - No match: missing.
  - Smaller than `minBytes`: failed (too small).
  - Older than `maxAgeHours` (default 26): stale.
- **Unit**: the last run of a systemd unit, for example `notes-backup.service`. The user unit is tried first, then
  the system unit.
  - Unit not found or never ran: missing.
  - Last result not `success`: failed.
  - Last finish older than `maxAgeHours`: stale.

When a check's status changes, the agent sends `backup.stale`, `backup.failed` (missing counts as failed) or
`backup.ok`. The first evaluation of a check is silent.

**System › Monitoring › Backups** shows each check's status, last backup time and size across all agents, with
**Check now**.

## Uptime Kuma (Sites)

Uptime Kuma has no official REST API; its web UI uses Socket.IO. With the `uptime` feature, the agent keeps a
logged-in Socket.IO connection, caches monitors and heartbeats, and offers a plain REST API to the phone. The Uptime
Kuma username and password stay on the agent.

1. In Agent settings of the host that can reach Uptime Kuma, fill in the **Uptime Kuma** URL, username and password,
   turn on the Uptime Kuma feature and restart the agent.
2. In **Settings › Integrations › Uptime Kuma**, choose that host.

**System › Monitoring › Sites (Uptime Kuma)** then shows:

- the monitor list with status, 24 h / 30 day uptime, average response time and certificate expiry;
- a detail view with a response time chart and outages;
- add, edit, pause, resume and delete for HTTP, keyword, ping and port monitors. New monitors get Uptime Kuma's
  default notifications. Optionally a new site is also added to Homepage;
- **Maintenance** windows that silence alerts for selected sites for a chosen duration, starting now.

The agent does not push site-down notifications itself. Configure an ntfy notification in Uptime Kuma, and follow
its topic in the ntfy app (see [Notifications](notifications.md#other-ntfy-topics)).

## Homepage

With the `homepage` feature, the agent reads the [Homepage](https://gethomepage.dev) `services.yaml` file
(`homepage.servicesPath`, default `~/homepage/homepage/services.yaml`; editable in Agent settings) and checks each
service's `siteMonitor` URL. Like Homepage, any response below 500 counts as up. Each check times out after
`homepage.checkTimeoutMs` (default 5000 ms), and results are cached for 30 seconds. Services without an `href` are
not listed.

Choose the host in **Settings › Integrations › Homepage**. **System › Monitoring › Homepage** shows the groups, each
service's status and response time, and opens services in the browser; a button on top opens the real Homepage.

Adding a site from the Sites screen can also add it to `services.yaml`. Comments and layout in the file are
preserved, and the file is replaced atomically.

## Dozzle

**System › Monitoring › Dozzle** connects directly to one or more [Dozzle](https://dozzle.dev) instances (v11)
configured in **Settings › Integrations › Dozzle** (optional basic auth; the password is kept in the phone's secret
store). It offers:

- the container list;
- live logs with pause, search, level colors and JSON folding;
- up to 8 containers merged into one time-ordered stream;
- start, stop and restart for a single container, only if Dozzle runs with `DOZZLE_ENABLE_ACTIONS=true`;
- long-press a line for **Ask Claude**: it starts a Claude session with the line and up to 30 lines before it (see
  [Claude](claude.md)).

The home screen can show a Dozzle card with running and stopped/unhealthy container counts.

## Log search

**System › Monitoring › Log search** searches the logs of several hosts at once over SSH. It needs no agent, so it
works on any host in your profile. On each selected host it searches:

- the systemd journal (system and user), and
- the logs of running Docker containers.

Matching is plain text and case-insensitive (not a regex). Ranges are 15 minutes, 1, 6 or 24 hours. Results from all
hosts are merged by time with matches highlighted, and can be filtered by host and source. Long-press a line to
copy it, ask Claude about it (with earlier matches from the same source), or save it to Obsidian (see
[Vault and notes](vault-and-notes.md)).

If the SSH user is not in the `adm` or `systemd-journal` group, only the user journal is searched, and the result
says so. Output is capped per host; very broad searches are marked as possibly incomplete. SSH setup is covered in
[Terminal, files and Git](terminal-files-git.md).

## Events

All agent notifications and event-only records (container restarts, Compose updates, commits, and so on) appear in
**System › Monitoring › Events**. See [Notifications › Event log](notifications.md#event-log).

## Security notes

- Secrets for agent-side checks (Grafana token, Uptime Kuma password, ntfy token) are stored only in the agent's
  config file (`0600`) and are never returned by the API. The app shows *stored safely* instead. Changing the
  Grafana or Uptime Kuma URL requires re-entering the secret, so an old secret is never sent to a new address.
- Grafana and Dozzle credentials used by the app are kept in the phone's secret store (Android Keystore) and are
  sent directly to those services.
- Use a Grafana service account with the Viewer role; Tiphys only reads alerts and dashboards.
- Container start/stop/restart in Dozzle depends on Dozzle's own setting.
- Log search runs a read-only script over your existing SSH connection; search text is passed as a fixed string.

See also [Security](../security.md).

## Limitations

- Local alerts only cover disk usage, failed systemd units and Docker container events; CPU, memory and temperature
  are shown in [System](system.md) but not alerted on.
- Uptime Kuma site alerts are delivered by Uptime Kuma, not by the agent.
- Host watch has no app editor, and its host list and the Uptime Kuma login are read only at agent start.
- Grafana alert notifications use the alert name as the identity: two alerts with the same name are treated as one.
- Troubleshooting: [Troubleshooting](../troubleshooting.md).
