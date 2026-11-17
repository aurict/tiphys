# Telegram newsletters

A one-way Telegram bot that sends sourced news digests to people you invite. The server agent (atlas, always on)
owns the bot, the recipients, the schedule, approval, delivery and the archive. The research itself runs on the PC
(Gemini via `agy` drafts, Claude edits), through the PC agent's [research](research.md) feature. Nothing received
from Telegram is ever executed.

API reference: [../agent/api.md#telegram](../agent/api.md#telegram). Configuration: feature flag `telegram`
(default off) and the `telegram` / `research` sections in
[../agent/configuration.md](../agent/configuration.md#telegram-and-research).

## Setup

1. On the PC agent: turn on `research` and create a service token for atlas
   (`tiphys-agent service-token create --name atlas --scope research`). See [Research](research.md).
2. On atlas: turn on `telegram` and restart the agent. Set the research PC in agent settings
   (`PATCH /v1/config` with `research: {url, token, wakeHostId?}`). `wakeHostId` names a `wake.targets` entry to wake
   the PC with Wake-on-LAN when it is off at run time.
3. Create a bot with BotFather and store its token: `PUT /v1/telegram/bot {token}`. The agent checks it with `getMe`
   and keeps it only in `agent.json` (mode `0600`). It is never returned, logged or written to events.
4. Create feeds (from the two templates or from scratch) and invite people.

## Using it in the app

**System › (atlas) › Tools › Telegram** appears when the agent reports the `telegram` feature.

- **Bot**: without a bot the page shows a token field (obscured) and *Save and check* (`PUT /v1/telegram/bot`). The
  token is sent once and never shown again; the phone does not store it. With a bot: `@username`, the research PC
  (host, reachable or not, Wake-on-LAN; tap to check again), *Replace bot token* and *Remove bot*. A note reminds you
  that bot messages are not end-to-end encrypted.
- **People**: each recipient with status (active, paused, stopped, unreachable) and subscribed feeds as chips.
  *Add person* creates an invite (optional label, feeds preselected) and shows the `t.me` link with *Copy* and
  *Share* (Android share sheet). There is no QR code. Pending invites are listed with *Revoke*. A recipient's page
  has *Receive newsletters* (pause/resume), a switch per feed, the recent deliveries, *Send a test message* and
  *Remove person*.
- **Newsletters**: name, schedule and next run, last issue status and recipient count. *New newsletter* offers the
  two templates or a blank feed. The editor covers every feed field (the schedule picker is the one used for
  Claude schedules) plus the recipients; recipients are saved as their subscriptions (`PATCH
  /v1/telegram/recipients/:id`). A feed's page has *Preview*, *Run now* (asks first; it sends unless approval is
  needed), and the archive.
- **Issue**: status, validation stats and error, *Send* / *Cancel* while it awaits approval, a Telegram-like preview
  of the rendered parts, the items with their source links, deliveries per recipient and *Send as a test…*. The page
  refreshes every 5 s while the issue is researching or sending. The preview parses only `<b>`, `<i>` and
  `<a href>`. Anything else is shown as text, and only http(s) links open, in the browser.
- **PC › Tools › Research** (`research` feature): *Connect to a Telegram agent* lists agents with the `telegram`
  feature. After you confirm, it creates a service token on the PC (`POST /v1/service-tokens {name: <host name>,
  scopes: ["research"]}`) and stores `research: {url, token, wakeHostId}` on that agent (`PATCH /v1/config`).
  `wakeHostId` is the PC's host id when atlas's `wake.targets` has it or the profile wakes the PC through atlas.
  If storing fails, the new token is revoked. The token is only held in memory during the transfer. *Test the
  connection* reads `GET /v1/telegram/status`. The same page lists service tokens (revoke) and recent research jobs
  (status, duration, items, requesting token, error; cancel while queued or running).
- **Notifications**: `telegram.approval` has **Gönder** / **Vazgeç** buttons that work without opening the app and
  are hidden on the lock screen (approving messages other people). The push doesn't name the agent, so the phone
  tries agents in turn, starting with the ones whose saved settings have `telegram` on. Issue ids are random, so a
  wrong agent can only answer "not found". Tapping opens the issue. *Settings › Notifications › Telegram* has two
  switches: *Approval requests and failures* (`approval`, `failed`, `pcUnreachable`) and *When a newsletter is
  sent*.

## Recipients and invites

- **Invite**: `POST /v1/telegram/invites {label?, feedIds?}` returns a one-time link
  `https://t.me/<bot>?start=<code>` valid for 24 hours. Share it (Android share sheet / QR in the app).
- The agent long-polls `getUpdates` (25 s) while an invite is pending (5 s gap) or any recipient is active or paused
  and so may send `/stop` (60 s gap unless updates keep coming). With no invite and no such recipient it doesn't
  poll. There is no webhook and no open port.
- `/start <valid code>` in a private chat adds the person (chat id, first/last name, username), subscribes them to
  the invite's feeds and replies with a short Turkish welcome. A missing, wrong, used or expired code gets a short
  "private bot" reply and nothing is stored.
- `/stop` sets the recipient to `stopped` and confirms. Only a new invite can bring them back; the app cannot
  re-activate a stopped recipient.
- If the bot is blocked (Telegram 403), the recipient becomes `unreachable`. The app may set them `active` again.
- Groups, supergroups and channels are never served: the bot leaves them.
- Recipient statuses: `active`, `paused` (set from the app), `stopped`, `unreachable`. Only `active` recipients
  subscribed to a feed receive it.

## Feeds

A feed has a name, a schedule (`when`: daily, weekly or interval, as for Claude schedules, in the agent's local
time zone), a topic and optional instructions, a time window (`windowHours`), item limits (`minItems`/`maxItems`),
up to 3 sources per item, allowed/blocked domains, *skip if nothing new*, an approval mode and a deadline
(`deadlineMinutes`, default 30).

Two templates (`GET /v1/telegram/templates`) are offered but not created automatically:

| Template | Window | Items | Default time |
| --- | --- | --- | --- |
| *Günlük teknoloji ve yapay zekâ* | 24 h | 5–8 | every day 08:00 |
| *Haftalık teknoloji ve yapay zekâ özeti* | 168 h | 10–12 | Monday 09:00 |

## A run, step by step

1. **Trigger**: the schedule, *run now*, or *preview*. A scheduled run's deadline is slot time + `deadlineMinutes`.
   Scheduled runs with no active subscriber are skipped (event `telegram.skipped`, `reason: noRecipients`).
2. **Research on the PC**: `POST /v1/research/jobs` with the feed's rules and `excludeUrls` (sources sent by this
   feed in the last 14 days), then `GET` every 10 s until done or failed, or the deadline. If the PC can't be reached
   and a wake target is configured, one Wake-on-LAN packet is sent and the agent keeps retrying until the deadline;
   without a wake target the run fails at once with `telegram.pcUnreachable`.
3. **Validation on atlas** (the PC's output is not trusted):
   - only `http`/`https` URLs on public host names (no localhost, private, CGNAT/Tailscale, `.local`, `.ts.net`);
   - each source must appear in the job's `seenUrls` (what the search tools actually returned; fragments and
     tracking parameters such as `utm_*` are stripped, host + path compared), otherwise it is treated as made up;
   - each source must be reachable: `HEAD` (or `GET` if `HEAD` is refused), 8 s, at most 3 redirects, each redirect
     target checked again. 2xx/3xx count, and so do 401/403/429 (news sites answer bots that way, and the URL was
     already seen by the tools); 404/410/5xx and network/DNS errors don't;
   - allow/block domain lists are enforced again; at most `maxSourcesPerItem` sources per item;
   - dedupe against this feed's issues sent in the last 14 days and within the issue: same normalized URL, or a
     similar headline (token Jaccard ≥ 0.8);
   - items without a source are dropped; at most `maxItems` items; length caps keep each item well inside one
     Telegram message.
4. **Count check**: 0 items → *skip if nothing new* skips silently (event only); otherwise the run fails
   (`agent.telegram.noItems`). Fewer than `minItems` but at least one → sent anyway.
5. **Render**: Telegram HTML with strict escaping (`&`, `<`, `>`, `"`), link previews off: a title line (📰 daily /
   🗞️ weekly, feed name, date in Turkish), numbered items (bold headline, summary, `Kaynak: site1 · site2` links), and
   a footer such as *Tiphys · Gemini 4 Argon + Claude · 08:00*. Long issues are split between items, each part under
   4096 characters.
6. **Approval** (mode `ask`, or `firstN` until `n` issues were sent; default *first 3*): the issue waits as
   `awaiting_approval` and the phone gets `telegram.approval` with **Gönder** / **Vazgeç** buttons and a link to the
   preview. Without a decision by deadline + 2 h the issue expires and nothing is sent.
7. **Delivery** through the send queue: at most 1 message per second per chat and 25 per second overall; on 429 the
   agent waits Telegram's `retry_after`; at most 3 attempts; 403 marks the recipient `unreachable`. Each recipient's
   delivery (message ids, status, error) is stored with the issue. The phone gets `telegram.sent` with counts, or
   `telegram.failed` with a reason code.

*Preview* runs steps 1–5 and stores the result as an issue with status `preview`; nothing is sent. Any rendered
issue can be sent to a single recipient as a test (`POST /v1/telegram/issues/:id/test`).

## Schedule and restarts

The scheduler checks every 20 s. When the agent starts, a slot missed while it was off still runs if the deadline
has not passed; otherwise it is skipped with event `telegram.missed`. Daylight saving time is handled as for Claude
schedules (a slot in the skipped spring hour runs right after the switch; the repeated autumn hour runs once). A run
cut short by a restart is marked failed (`agent.telegram.interrupted`); issues waiting for approval survive restarts.
Shutdown cancels the long poll and any waiting.

## Archive and privacy

- `telegram-state.json` (next to `agent.json`, mode `0600`, atomic writes) holds recipients, invites, feeds, the
  update offset and the last 60 issues per feed with their items, rendered parts and deliveries.
- The event log records only ids and counts (`telegram.started`, `.skipped`, `.missed`, `.recipientAdded`, …),
  never newsletter text or recipient names.
- Telegram bot messages are not end-to-end encrypted. Newsletters are built only from public information.
