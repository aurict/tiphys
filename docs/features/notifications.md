# Notifications

Agents send push notifications to the phone when something needs your attention: Claude finished or wants
approval, a host went offline, a disk is full, a service or container crashed, a backup is late, a long command
finished. Delivery uses **UnifiedPush** with the **ntfy** Android app as distributor and your own ntfy server. No
Google or Firebase services are involved.

Payloads are encrypted end to end with WebPush (RFC 8291, `aes128gcm`), so the ntfy server only relays ciphertext.
The agent sends a language-neutral key plus parameters, and the app renders the text in the language you selected.

Every notification is also written to the agent's **event log**, which the app shows under **System › Events**.

## Requirements

- An ntfy server you control, reachable by the agents and the phone (for example over Tailscale).
- The ntfy Android app on the phone, with its default server set to your ntfy server and signed in.
- At least one paired agent. Push itself needs no feature flag; individual notifications come from features such as
  `claude`, `watch`, `alerts`, `backups` and `desktop` (see [Agent configuration](../agent/configuration.md)).

## Setup

1. In the ntfy app: set the default server to your server and sign in (ntfy Settings › Manage users).
2. In Tiphys: **Settings › Notifications › This phone** › **Turn on notifications**, then choose the ntfy app under
   **Deliver through**. Android asks for notification permission.
3. The app registers its UnifiedPush endpoint and WebPush public keys with every host that has an agent
   (`PUT /v1/push/endpoint`). The section shows *Registered with: …* or which hosts failed; tap the row to retry.
   Registration is repeated automatically when the endpoint changes.
4. **Send a test notification** sends `push.test` through each agent.

On Xiaomi/Redmi phones set ntfy's battery saver to *No restrictions* and allow autostart, or notifications arrive
late.

### ntfy access token

If your ntfy server requires authentication for publishing, store a token on each agent. The agent sends it as
`Authorization: Bearer <token>` with every push. The app does not have a field for it; set it in the agent config
(`push.token` in `agent.json`) or through `PATCH /v1/config` with `pushToken`. The token is never returned by the
API (only `hasToken`). See [Agent configuration](../agent/configuration.md).

### Other ntfy topics

Uptime Kuma site alerts are not sent by the agent. Configure Uptime Kuma's own ntfy notification to a topic on your
server, and add that topic under **Settings › Integrations › ntfy** (*Topics to follow*). The notifications screen
then offers a *Subscribe in ntfy* shortcut for it. See [Monitoring](monitoring.md).

## Choosing what you receive

**Settings › Notifications** filters on the phone (the agent still sends and logs everything):

| Setting | Keys | Default |
| --- | --- | --- |
| Claude › When a session finishes | `claude.done` | on |
| Claude › When it needs my approval | `claude.waiting`, `claude.pcExpiring`, `claude.sudo` | on |
| Claude › When it fails | `claude.error`, `claude.scheduleFailed`, `claude.pcEnded` | on |
| System › PC goes offline | `host.offline`, `host.online` | on |
| System › A service crashes | `service.*`, `docker.*`, `agent.restarted` | on |
| System › Grafana alerts | `grafana.*` | on |
| System › Backup alerts | `backup.*` | on |
| Tell me when a long command finishes | `command.done` only if it ran at least this long; `command.failed` always (Off disables both) | 60 s |
| Clipboard › Notify when something is copied on the PC | `clipboard.pc` | on |
| Telegram › Approval requests and failures | `telegram.approval`, `telegram.failed`, `telegram.pcUnreachable` | on |
| Telegram › When a newsletter is sent | `telegram.sent` | on |

Disk alerts (`disk.full`, `disk.ok`) are always shown. The disk threshold and the alert interval are set per agent
under **Settings › Hosts › (host) › Agent settings** (see [Monitoring](monitoring.md)).

## Notification keys

Priority `high` uses the urgent Android channel (*Tiphys · acil*); others use the normal channel. The deep link is
the screen opened when you tap the notification.

| Key | Sent when | Deep link | Priority |
| --- | --- | --- | --- |
| `claude.done` | A Claude session finishes a turn (summary, files changed, cost, duration) | Claude session | normal |
| `claude.waiting` | Claude asks for permission to use a tool (`pc: 1` for a PC session, `security: 1` for a security fix session) | Claude session | high |
| `claude.sudo` | A Claude security fix session needs the sudo password of a machine (`title`, `host` name; data: `sessionId`, `requestId`, `host`). The password is typed in the app; the notification has no buttons | Claude session | high |
| `agy.done` | An agy session finished a turn | agy session | low |
| `agy.waiting` | agy asks for permission (data: `sessionId`, `requestId`, for notification buttons) | agy session | high |
| `agy.error` | An agy turn failed | agy session | normal |
| `claude.error` | A Claude turn fails or the Claude process dies | Claude session | normal |
| `claude.pcEnded` | Desktop control ended for a Claude PC session (shown only if Claude was working and you did not stop it) | Claude session | high if working |
| `claude.pcExpiring` | A Claude PC session's control expires within 2 minutes | Claude session | high |
| `claude.scheduleFailed` | A scheduled Claude task could not start | Claude schedules | high |
| `host.offline` | A watched host has not answered for `offlineAfterSeconds` | System | high |
| `host.online` | A watched host that was reported offline is back | System | normal |
| `agent.restarted` | The agent started after a crash or unclean exit | System | high |
| `disk.full` | A filesystem reaches `alerts.diskFullPercent` | System | high |
| `disk.ok` | That filesystem is below the threshold again | none | normal |
| `service.failed` | A systemd unit (user or system) enters `failed` | System | high |
| `service.recovered` | That unit is no longer failed | none | normal |
| `grafana.alert` | A Grafana or Prometheus alert starts firing | Grafana | high |
| `grafana.resolved` | That alert stops firing | none | normal |
| `docker.died` | A container exits with a non-zero code without a recent stop/kill | System | high |
| `docker.oom` | A container is killed for running out of memory | System | high |
| `backup.stale` | A backup check becomes stale (older than `maxAgeHours`) | Backups | high |
| `backup.failed` | A backup check fails (missing, too small, unit failed or never ran) | Backups | high |
| `db.restoreTest.ok` | A backup restore test restored the newest dump and passed its sanity queries | Databases | default |
| `db.restoreTest.failed` | A restore test failed (reason: no dump, restore error, corrupt dump, sanity check, timeout…) | Databases | high |
| `backup.ok` | A backup check is OK again | Backups | normal |
| `command.done` | A command run with `tiphys-agent run` exits with code 0 | Terminal | normal |
| `command.failed` | That command exits with a non-zero code | Terminal | normal |
| `clipboard.pc` | Text is copied on the PC (sensitive, see below) | none | low, silent |
| `push.test` | You tap *Send a test notification* | none | normal |
| `telegram.approval` | A Telegram newsletter issue waits for your approval (**Gönder** / **Vazgeç**) | Issue preview | high |
| `telegram.sent` | A newsletter issue was sent (item and recipient counts) | Issue | normal |
| `telegram.failed` | A newsletter run failed or its approval expired (`reason` code) | Issue | high (normal if expired) |
| `telegram.pcUnreachable` | The research PC could not be reached before the feed's deadline | Issue | high |

Notifications on the same topic replace each other (for example `host.offline` is replaced by `host.online`, and
`disk.full` by `disk.ok`). When a Claude session finishes or fails, its outstanding approval notifications are
removed.

### Event-only keys

These are written to the event log but never pushed:

| Key | Recorded when |
| --- | --- |
| `docker.restarted` | Docker restarts a container (restart policy) |
| `claude.scheduled`, `claude.scheduleSkipped` | A scheduled Claude task started, or was skipped because the previous run is still going |
| `git.committed`, `git.pushed` | A commit or push is made from the app |
| `control.started`, `control.ended` | A desktop control session opens or closes |
| `ui.opened` | The mobile view opens a window |
| `telegram.started`, `telegram.skipped`, `telegram.missed`, `telegram.recipientAdded`, … | Telegram newsletter activity (ids and counts only; see [Telegram newsletters](telegram.md)) |
| `compose.updated`, `compose.failed` | Reported by the app after a Compose stack update over SSH (`POST /v1/events`) |

## Notification actions

Some notifications have buttons that work without opening the app (the app's background handler calls the agent
with the stored device token):

- **Allow / Deny** on `claude.waiting`: answers the Claude permission request. If the agent cannot be reached you
  get *Could not send your decision* and should open the app. See [Claude](claude.md).
- **Allow / Deny** for `agy.waiting` are meant to work the same way: the agent sends the session and request ids with the notice, and an answer goes to `POST /v1/agy/sessions/:id/permissions/:requestId`. See [agy](agy.md).
- **Extend** on `claude.pcExpiring`: extends the desktop control session by 15 minutes.
- **Stop** on the ongoing *Claude is using the PC* notification: interrupts Claude and ends the control session.
- **Copy** on `clipboard.pc`: puts the PC's text on the phone clipboard.

Approval notifications for Claude PC sessions, the *Extend* notification and clipboard notifications are hidden
from the lock screen (Android "secret" visibility), because their buttons act on the PC. The same goes for
`claude.waiting` with `security: 1` (a security fix session changes machines over SSH) and for `claude.sudo`. A sudo
password is never entered from a notification: tap it to open the session and type it in the app. See
[Fixing findings with Claude](security.md#fixing-findings-with-claude) and
[Security fix sessions](claude.md#security-fix-sessions).

## Sensitive notifications

A notification can be marked sensitive; currently only `clipboard.pc` is. Sensitive notifications:

- are not written to the event log;
- are sent only to endpoints that registered WebPush keys, so their content never reaches ntfy unencrypted.

Clipboard sync is controlled by `desktop.clipboardSync` on the agent (*Clipboard sync (PC → phone)* in Agent
settings) and by the phone setting above. Password manager content and text over about 3 KB are not sent. See
[Desktop control](desktop-control.md).

## Long-running commands

Wrap a command with `tiphys-agent run` to be notified when it ends:

```sh
tiphys-agent run -- rsync -a ~/photos atlas:/srv/backup/photos
```

The command runs in the foreground with your terminal attached; signals are forwarded to it, and the wrapper exits
with the command's exit code. When it ends the agent sends `command.done` or `command.failed` with the command
line (first 120 characters), the duration and the exit code. On the phone, successful commands are shown only if
they ran at least as long as the *Tell me when a long command finishes* threshold.

The event log keeps only the program name, not the full command line, because arguments may contain passwords.

## Event log

Every notification (pushed or not, even with no registered phone) and the event-only keys above are appended to
`events.jsonl` next to the agent config file. The file is rotated to `events.jsonl.1` above 2 MB. Text parameters
are capped at 500 characters.

- **System › Events** shows the events of all agent hosts on one timeline, with the same text as the
  notifications. Tapping an event opens the screen its link points to. The home screen's *Recent events* card uses
  the same data.
- API: `GET /v1/events?since=<ISO time>&limit=<1-500>` (newest first) and `POST /v1/events` for app-reported
  events. See [Agent API](../agent/api.md).

The event log is always on; there is no feature flag.

## Security notes

- Payloads are encrypted for each phone's WebPush key. An endpoint registered without keys gets plain JSON; the
  current app always registers keys.
- Each device has one endpoint. Revoking a device (`tiphys-agent revoke <id>`, the app's device list, or *Lock
  everything*) also removes its push endpoint.
- Notification text contains host names, Claude session titles and summaries, container and unit names. Keep that
  in mind for lock-screen visibility.
- Push requests time out after 10 seconds; failures are logged by the agent and do not block anything else.

See also [Security](../security.md) and [Troubleshooting](../troubleshooting.md).

## Notifications without ntfy

Push needs UnifiedPush, which exists only on Android. Without it (no ntfy app on the phone, on iOS, and in the
desktop app) Tiphys still shows notifications **while the app is open**: every 20 seconds it asks each agent for new
events (`GET /v1/events?since=…`, the same event log as **System › Events**) and shows each new one as a local
notification, with the same texts, filters (**Settings › Notifications**), channels and replacement rules as a push.

- Only hosts that push does not reach are polled: when the phone has a UnifiedPush endpoint that a host accepted,
  that host is skipped, so nothing is shown twice.
- The first look at a host only notes where its log stands; older events are not replayed. Events the app reported
  itself (work done over SSH) are not shown. At most 10 notifications per host and round.
- Polling stops when the app goes to the background. **Notifications while the app is closed need ntfy.**
- Foreground notifications have no action buttons (Allow/Deny, Copy, Send); tapping one opens the related screen.
  Approvals are answered in the app.

**Settings › Notifications › While the app is open** explains this and links here.

### iOS

iOS has no UnifiedPush, so today the iOS app gets only the foreground notifications above and registers no push
endpoint with the agents.

The planned option for notifications while the app is closed is your ntfy server plus the ntfy iOS app's way of
waking a phone: ntfy forwards to Apple's push service (APNs) through the `ntfy.sh` relay (or your server's
`upstream-base-url`) only a "poll request" with the message id, never the message; the phone then fetches the
message from your server. Combined with the WebPush encryption the agents already use (RFC 8291; the agent encrypts
whenever the endpoint has a public key), the relay sees only "new message" pings and the content stays end-to-end
encrypted. This needs an iOS notification service extension in Tiphys that holds the keys and decrypts; it is not
built yet. Don't register a keyless endpoint as a workaround: the agent would then send plain JSON through ntfy.

## Limitations

- Notifications while the app is closed: Android only; requires a UnifiedPush distributor (tested with ntfy). Other
  platforms get notifications only while the app is open (see above).
- The desktop app on Linux needs a notification daemon (D-Bus) to show them; without one the app works without
  notifications.
- The ntfy token cannot be set from the app.
- Filtering happens on the phone: disabled notifications are still sent and logged by the agent.
- Encrypted pushes are sent with a 24-hour WebPush TTL; how long ntfy holds messages for an offline phone also
  depends on your ntfy server's cache settings.
