# Security

Tiphys lets a phone run commands, read files, drive Claude Code and control the desktop of your machines. That is
a lot of power. This document describes what Tiphys assumes, how each protection works, and where it stops.

To report a vulnerability, see [SECURITY.md](../SECURITY.md).

## Threat model

**Trusted:**

- You. Tiphys is single-user: every paired device belongs to the same person and has the same rights.
- Your Tailscale tailnet and its access controls. The agent is reachable only through `tailscale serve`.
- The machines that run the agent, including the local user account it runs as, root, and the software installed
  there (Hyprland, Claude Code, Firefox, …).
- Your phone while it is unlocked and Tiphys is unlocked.

**In scope (what Tiphys tries to protect against):**

- Other devices or users in the same tailnet that have no paired token, or that log in with a different Tailscale
  identity when `requireTailscaleLogin` is set.
- Anyone on the public internet. The agent never listens on a non-loopback interface.
- Mistakes and over-reach: accidental power-off, deleting files, Claude doing something destructive on the desktop,
  a long-forgotten remote-control session.
- A lost or stolen phone that is **locked**: tokens are in Keystore-backed storage, and the app has its own lock.
- Notification servers: the ntfy server sees only encrypted payloads.

**Out of scope / not protected:**

- **A paired device token plus tailnet access is full access** to every enabled feature of that agent. There are
  no per-device permissions. Anyone who extracts a token from an unlocked, compromised phone, and can reach your
  tailnet, can do what you can do. Revoke the device (see below).
- Local users or malware on the agent machine. They can read `agent.json` (as your user), talk to the loopback port
  with a stolen token, or use the Firefox bridge socket as your user.
- A compromised Tailscale account or coordination server.
- Claude Code itself. Normal (`code`) Claude sessions run with Claude Code's own permission system and the
  permission mode you choose, in folders you allow. `bypassPermissions` means exactly that.
- Denial of service from inside the tailnet.

## Network exposure

- The agent binds to `127.0.0.1:7443` by default (`listen` in `agent.json`). `tailscale serve --https=7443` publishes it
  with a valid TLS certificate to tailnet members only. Do not change `listen.host` to a LAN or public address.
- The agent trusts `X-Forwarded-*` headers only from `127.0.0.1` (Fastify `trustProxy`).
- The Android app refuses cleartext HTTP, so agents must be reached over HTTPS.
- **Tailscale identity check (optional):** with `--tailscale-login you@example.com` (`requireTailscaleLogin`), every
  request must carry the `Tailscale-User-Login` header that `tailscale serve` adds for the connecting user, and it
  must match. Other users in a shared tailnet are rejected with `agent.auth.tailnetUserNotAllowed`. The check relies
  on `tailscale serve` setting that header. Requests from tagged devices carry no user login and are rejected.
- Use Tailscale ACLs to limit which of your devices can reach port 7443 at all.

## Pairing and device tokens

- `tiphys-agent pair` creates a 256-bit random token with prefix `tph_` and shows it once (QR + text). The agent
  stores only `sha256(token)`, and lookups use a constant-time comparison.
- The phone stores the token in `flutter_secure_storage` (Android Keystore). The profile file holds only a
  reference to it.
- Every endpoint except `GET /v1/health` requires `Authorization: Bearer <token>`. As a fallback for clients that
  cannot set headers on WebSockets, `?token=` is accepted. The Tiphys app always uses the header. Query strings can
  end up in request logs, so avoid the fallback.
- `/v1/health` is unauthenticated and reveals the agent name, version and feature flags to anyone who can reach the
  port, meaning tailnet members.
- **Revocation:** `tiphys-agent revoke <id>` or *Agent settings › Paired devices › Revoke*. *Lock everything*
  (`POST /v1/devices/revoke-all` with `{"confirm": true}`) revokes all devices, including the phone sending the
  request. Push endpoints of revoked devices are removed too. Run `tiphys-agent pair` again to get back in.
- The QR code contains the token in clear text. Treat it like a password: do not screenshot or share it.

## Feature flags

Each area of functionality is a flag in `agent.json`. If a flag is off, its routes are not registered and heavy
modules such as the Claude SDK are not even loaded. On a new configuration only `system`, `services`, `docker` and
`power` are on. Everything that runs code on your behalf or touches the desktop (`claude`, `agy`, `git`, `desktop`,
`control`, `ports`, `transcribe`, `wake`, `watch`, `uptime`, `alerts`, `backups`, `homepage`, `security`) must be enabled
explicitly. Enable only what a machine needs. A server usually needs no `claude`, `agy`, `desktop` or `control`.

## Path restrictions

File, git and Claude folder operations resolve symlinks (`realpath`) and must stay inside `allowedRoots` (default
`["~"]`). Anything outside returns `agent.path.notAllowed`. The default allows your whole home directory. Narrow it
if you want Claude sessions confined to, for example, `~/code`.

## Confirmations for dangerous actions

The agent rejects certain requests unless the body contains an explicit `confirm: true`. The app sets that flag only
after asking you. This covers power actions (reboot, power-off, suspend), killing processes, taking over terminal
Claude sessions, discarding git changes (deleting new files needs a separate confirmation), revoking all devices, and
typing into password fields in the mobile view. An existing Claude session cannot be switched into `bypassPermissions`
mode; that requires starting a new session.

## App lock and on-device secrets

- Optional app lock with a PIN (at least 6 digits) and/or fingerprint, with configurable auto-lock when the app goes
  to the background.
- SSH keys, tokens, passwords and the vault live in Keystore-backed storage. Android cloud backup and
  device-to-device transfer are disabled for the app. The only way to move secrets is the passphrase-encrypted
  profile export (Argon2id + XChaCha20-Poly1305).
- **Vault:** opening it always asks for the app lock again, and it cannot be used without a lock configured. It locks
  after 2 minutes of inactivity, when the app goes to the background, and when you leave it. Vault screens set
  `FLAG_SECURE`, which blocks screenshots and the recents preview. Copied passwords are marked sensitive for Android
  and cleared from the clipboard after 30 seconds.
- Starting a control session or a Claude PC session asks for the app lock every time.

## Control sessions

Everything that changes the desktop requires the `desktop` **and** `control` flags **and** a valid control session
token in `X-Tiphys-Control`. This covers window actions, workspaces, DPMS, app launch, live-screen input,
Sunshine start/stop/pair, Firefox tabs and page access, the mobile view, and Claude PC sessions. Read-only
endpoints such as the window list, thumbnails and Sunshine status need only `desktop`.

| Property | Value |
|---|---|
| Duration | 15 min by default; extendable, never more than 60 min remaining |
| Concurrency | one session per agent; a second device gets `agent.control.busy` (409); any paired device may stop it |
| Token | random, bound to the device that opened it, kept in agent memory only |
| PC indicator | critical `notify-send` + Hyprland active border switched to a red/orange gradient (at least 3 px). If the indicator cannot be set, the session is refused (`agent.control.indicatorFailed`) |
| Phone | biometric/PIN to open; for the desktop panel and live screen the session ends when you leave the screen or after 60 s in the background |
| Rate limits | opening: 5/min per device; panel actions: 10 per 5 s; live input: 60 events/s; mobile view: 30 per 5 s; Claude PC actions: 4/s; Sunshine pairing: 6/min |
| Logging | `control.started` / `control.ended` events (device, duration, reason). Keystrokes, typed text and screen content are never logged |
| Turning off `control` | ends the open session immediately; open live streams and SSE streams are closed within ~2 s |

Window, workspace and app-launch actions use a fixed list of Hyprland dispatches with validated arguments, never
free-form commands. App launch is limited to `.desktop` entries the agent has listed. In Lua-config mode, client
strings are escaped or validated before they reach `hyprctl eval`. Key input goes through an allow-listed key table.

**Limits:**

- If the Hyprland config is reloaded during a session, the border indicator disappears until the session ends.
- The indicator is visual only. Someone not looking at the PC will not notice it.
- Live-screen frames and mobile-view snapshots are not stored, but window thumbnails and the window list need only
  pairing, not a control session.

## Claude PC sessions

A Claude session of kind `pc` can see and operate the desktop. It is bound to a control session and has these
code-enforced restrictions:

- **No built-in tools:** no shell, file, edit, web or sub-agent tools. Built-in tools are removed
  (`tools: []`), dangerous ones are also on the disallowed list, any tool outside the 22 Tiphys PC tools is denied,
  no user/project settings or other MCP servers are loaded, and the permission mode is fixed to `default`.
- **Control binding:** every tool call re-checks the control session. When the session ends, Claude is interrupted
  and its tools stop working. Only the device holding the session can message the session or answer its approvals.
- **Blocked shortcuts:** Super+M, Ctrl+Alt+Delete/Backspace/F1–F12, and any key combination that your Hyprland
  config binds to exit, DPMS, power, lock, `systemctl` or `pkill`.
- **Needs your approval** (permission card + notification with Allow/Deny): Alt+F4, Ctrl+Q, Ctrl+Shift+Q/W and keys
  bound to closing windows; the first input into a terminal window (once per window), launching a terminal;
  pressing UI elements whose name, description or text matches destructive words (delete, send, pay, buy, publish,
  close, uninstall, … in English and Turkish, normalised against invisible characters and mixed scripts); unnamed
  elements and any element inside a web page; buttons in dialogs whose title is destructive; closing browser tabs;
  opening URLs after reading page text or a UI tree, long query strings, or domains not already open; and an
  explicit `confirm` tool Claude must use for anything else risky.
- **Password fields:** Claude can never type into them. The AT-SPI helper never reads their content.
- **Phone side:** the session can keep running while the phone is in your pocket. A persistent notification ("Claude is
  using the PC") shows the remaining time and has a Stop button that works without opening the app. You get a
  warning 2 minutes before the control session expires.

**Limits:** the destructive-word list is a heuristic. Claude can still click on screen coordinates, and a harmful
action that is not named like one (for example an icon-only button outside a web page that Claude clicks by
coordinates) will not be caught. Watch the session, keep it short, and stop it when in doubt. Screenshots are kept
in `claude-shots/` (last 60) and in Claude Code's own transcript.

## agy sessions

The `agy` feature ([agy](features/agy.md)) lets a paired phone start and drive Antigravity CLI sessions on the PC. Like
a Claude code session, **an agy session runs code on the PC**: agy reads and edits files and runs shell commands as the
agent's user, steered by whoever holds a device token. Treat the `agy` flag as `claude`: high risk, off on servers.
What protects it:

- **Device tokens only.** No service token reaches any `/v1/agy` route, and the routes don't exist unless the flag is
  on.
- **Folders inside `allowedRoots`.** A session's working folder (and the folder used to list earlier conversations) is
  resolved with `realpath` and must lie inside `allowedRoots`, as for Claude sessions (`agent.path.notAllowed`).
  Narrow the roots if you don't want agy to start in your whole home directory. agy itself is not confined to that
  folder: once running, it can touch anything the agent's user can, subject to its own permission prompts.
- **agy asks, the phone answers.** The agent never starts `agy` with `--dangerously-skip-permissions`. In the
  `default` mode agy asks before edits and commands, and each question is shown on the phone (and as a notification
  with buttons). The modes `accept-edits` and `auto` loosen that on purpose; choosing one is the holder's decision, as
  with Claude's *Accept edits*. No mode answers a prompt by itself on the agent's side: an unanswered prompt waits.
- **Few, short-lived processes.** One `agy acp` process per session, at most 6 live sessions, an idle session is closed
  after 2 hours, start and conversation-list calls are rate limited per device, and the processes are killed when the
  agent stops.
- **No file system or terminal handed to agy.** The agent offers agy no file-system or terminal capability over the
  protocol; any other request from agy is refused.
- **Audit log.** Starting, answering a prompt, switching mode or model, cancelling and closing are written to
  `audit.jsonl` with the session id, folder, mode or chosen option; never the prompt text.
- **Not a boundary against the holder of a token.** Anyone with a paired device token can start an agy session and,
  by approving prompts or choosing `auto`, run commands on the PC. Revoke lost devices at once (*Lock everything*).
  agy talks to Google's services with your account: your prompts and the files it reads leave the PC the same way
  they do when you run `agy` in a terminal.

## Mobile view (AT-SPI)

- Only the window you choose is read, and only if it is visible on the active workspace. The window title must match
  exactly one accessible window. Private-browsing Firefox windows are refused.
- The helper runs only while a view is open. It stops when the control session ends, after 60 s idle, and when the
  agent stops.
- Password field content is never read. Writing to a password field requires an explicit confirmation from the phone.
- While a view is open, the agent sets the session accessibility bus flag (`org.a11y.Status.IsEnabled`). That also
  makes other applications expose their accessibility tree for that time. The previous value is restored afterwards,
  including after a crash.
- Snapshots are not written to disk. The event log records only "mobile view opened" with the window class.

## Firefox extension

- No network permission, strict CSP, `incognito: not_allowed` (private windows are invisible to it). Required
  permissions: `tabs`, `sessions`, `nativeMessaging`. Page access (`<all_urls>` + `scripting`) is optional and
  granted by you from the extension popup.
- Firefox starts the native-messaging host itself. The host manifest allows only `bridge@tiphys.dev`. The agent
  socket is in a 0700 directory with mode 0600, and its ownership is checked.
- Reading pages is refused when a password field is focused or filled. Form field values are removed from the copy
  that is read.
- The tab list (which reveals browsing history) requires a control session. The audit log records only the method
  and path, never URLs or titles.
- **The extension is not signed by Mozilla.** Installing it requires `xpinstall.signatures.required=false`, which
  lets *any* unsigned extension be installed into that Firefox profile. Only Firefox ESR, Developer Edition and
  Nightly allow this. The only third-party code in the extension is Mozilla Readability 0.6.0. It is pinned, and
  the build re-checks its SHA-256 hash.
- Any process running as your user can connect to the native-messaging host or the agent socket, just as it could
  drive Firefox directly.

## Velour remote

`POST /v1/velour` (`desktop` flag, paired device; like the MPRIS media remote it needs no control session) forwards one
validated operation to the Velour player's local socket, `$XDG_RUNTIME_DIR/velour/control.sock`.

- Velour keeps the socket off until you turn on *Settings → Desktop → Remote control*. It creates the directory
  `0700` and the socket `0600`, and refuses a directory that is a symlink or belongs to another user. The agent
  connects only to a socket owned by its own user.
- Every operation is checked against a fixed schema (Zod) before it is sent: a closed list of ops, bounded strings,
  at most 2000 tracks, watch targets only for playback. Velour validates again on its side.
- Search queries, library contents and lyrics travel in the POST body, so they don't appear in request logs, and
  they are not written to logs or events.
- Account-changing ops are limited to liking songs, adding songs to a playlist and creating a playlist. Removing
  songs from a playlist, renaming and deleting playlists are not available remotely.

## Sunshine / Moonlight

- Sunshine's web credentials are stored only in `agent.json`. The app never gets the password back. TLS to Sunshine
  accepts a self-signed certificate only on loopback, pinned to Sunshine's own certificate when that is readable.
- Starting, stopping and PIN pairing need a control session.
- **Moonlight streaming is independent of Tiphys control sessions.** Once a Moonlight client is paired with Sunshine,
  it can connect whenever Sunshine is running, with full input and **without** the Tiphys PC indicator. Do not
  enable Sunshine at boot. Start it from Tiphys when needed and stop it afterwards. Unpair clients in Sunshine's
  web UI.

## Security center audit key

The [Security center](features/security.md) audits a host that has no agent through an SSH key that can do exactly
one thing. The design goal: the monitoring server must not become a way to run code on the audited host.

- **Forced command.** The key's line in `authorized_keys` is
  `restrict,from="<monitoring server's Tailscale IP>",command="sudo -n /usr/local/lib/tiphys/audit.sh \"$SSH_ORIGINAL_COMMAND\"" ssh-ed25519 …`.
  Whatever the client asks for, sshd runs that command; the client's text arrives only as **one quoted argument**
  (`$SSH_ORIGINAL_COMMAND`), never interpreted by a shell as a command line. The script accepts `report`,
  `report-full`, `traps` and `image-save sha256:<64 hex>` (the two added for the
  [later phases](#security-center-scanners-traps-black-box-and-lockdown)) and exits with status 2 on anything else,
  without running anything. `image-save` is checked again on the host: exactly `sha256:` and 64 lowercase hex
  characters, the image used by a running container, at most 3 GB.
- **`restrict` and `from=`.** `restrict` turns off port, agent and X11 forwarding, tunnels and the terminal; `from=`
  makes the key useless from any other address, so a copy stolen from the monitoring server is not usable from
  elsewhere. The monitoring side also connects with `IdentitiesOnly`, no agent, `ClearAllForwardings` and a
  pinned host key (below).
- **Root-owned, not editable by the audit user.** The `tiphys-audit` account's home directory, its `.ssh` directory
  and `authorized_keys` belong to root, so the account cannot add keys or loosen the restrictions. The script
  (`/usr/local/lib/tiphys/audit.sh`, `root:root 0755`, installed with a SHA-256 check) cannot be changed by it either.
  The account has a locked password (`*`), no extra groups and is **not** in the `docker` group, which is
  root-equivalent.
- **Single-command sudo.** `/etc/sudoers.d/tiphys-audit` allows only `tiphys-audit ALL=(root) NOPASSWD:
  /usr/local/lib/tiphys/audit.sh`, validated with `visudo` before it is installed. It has no `Defaults` lines, so it
  also works with `sudo-rs`. Root is needed for `sshd -T`, `nft`, `/etc/shadow` status, sudoers hashes, other users'
  `authorized_keys`, the SUID scan and `ss -p`.
- **`AllowUsers`.** If (and only if) the host's sshd already restricts logins with `AllowUsers`, the installer adds
  `tiphys-audit` with a drop-in (`/etc/ssh/sshd_config.d/05-tiphys-audit.conf`); it checks `sshd -t` before reloading.
- **No trust on first use.** The monitoring server connects with `StrictHostKeyChecking=yes` and only the file
  `security-known-hosts`; you pin the host key yourself after comparing its fingerprint over another channel.
- **Why Lynis is not streamed.** Piping a scanner over SSH and running it as root would turn the restricted key into a
  channel for running arbitrary code as root on the audited host, which defeats the restriction, and it would leave
  files behind. The audit script contains a fixed subset of checks instead, and the scoring happens on the monitoring
  server.
- **`security.self.sudo`.** On the monitoring server's own machine the same script runs through `sudo -n`, but only
  the root-owned copy at `/usr/local/lib/tiphys/audit.sh`, which the agent checks on every run (root-owned, not
  group/other writable). The agent's own copy in `helpers/` is never run as root: the agent user can change it.

**What the monitoring server can do on the audited host:** run the audit script as root with `report`,
`report-full`, `traps` or `image-save`, and nothing else; it receives the script's text output (and, for
`image-save`, the tar of an image that a running container uses). **What it cannot do:** run another command,
get a shell or a terminal, forward ports, change a file, add a key or read a file other than through the script's fixed
checks. The report does contain names and paths (users, container and image names, mount paths, published ports,
login sources) and fingerprints and hashes, but no secrets: no environment, key material, password hashes or file
contents (see [what it never prints](features/security.md#what-it-never-prints)). Anyone who can change the root-owned
script on the host can of course run code as root there; that is root's own power. If the monitoring server is
compromised, an attacker can read these reports and can try the key only from the allowed address; remove the host
with `tools/install-audit.sh --uninstall` to cut it off.

Between agents, `GET /v1/security/raw` hands the same report text to a holder of a `security-report` service token (or
any device token). That service token can call no other route. If the audited agent has `security.self.sudo` on, the
text is a root-level report, so treat the token like a read-only credential for that report.

## Security center: scanners, traps, black box and lockdown

The [audit](#security-center-audit-key) looks at machines from inside. The later phases add detection and response.
They rest on the same trust assumptions as the rest of Tiphys (you, your tailnet, the machines the agents run on) and
add the following to the threat model. Each one is off until you set it up, and each has limits that are listed here
so you don't trust it for more than it does.

**What they add**

- **A way to notice a break-in that is already happening.** Decoy tokens, decoy files and decoy database users are
  things no legitimate user touches, so a touch means an intruder, a stolen backup, or a tool that reads everything. The
  alarm goes to the phone and, as a title only, to your Telegram.
- **A record that is hard to rewrite quietly.** The black box chains every audited action through the agents with
  hashes and puts the chain's head outside the machine (Telegram) every night. The ordinary `audit.jsonl` and
  `events.jsonl` are editable by the agent's user; the chain is evidence that notices edits.
- **A response that doesn't need the lost thing.** The recovery code locks the monitoring server and every agent it knows
  without a paired phone.
- **Findings before an attacker uses them:** known vulnerabilities in running images, secrets in repositories, logs
  and tracked `.env` files, what the internet can reach, and who is scanning your sites at Cloudflare.

**What new access exists**

| Where | What it can do | Why it is acceptable |
| --- | --- | --- |
| `audit.sh` `image-save` on an SSH host | `docker save` of one image that a running container uses, up to 3 GB, as a tar stream to the monitoring server | The key still runs only the script; the request is validated (exactly `sha256:` and 64 hex characters), the image must be in use and not huge. The tar can contain **anything in the image**, including secrets baked into layers, and it travels to the monitoring server and is scanned and deleted there. It is also load on the production Docker daemon, hence night only, 2 a night. |
| `audit.sh` `traps` | Reads the last 10 minutes of auditd events for the key `tiphys_trap` as root | Read-only, capped at 256 KiB and the newest 500 lines. |
| `tools/install-audit.sh --trap` | An admin (with `sudo`, once) adds a decoy file and an audit rule on an SSH host | It is a separate, explicit command and is undone by `--untrap`; the audit key itself can never change files. The installer runs as root, so it refuses to write through anything another user controls: an existing path or a symlink at the decoy's path, a symlink among the directories on the way, a directory owned by a user other than root or the admin running it, or one writable by group or others. The file is created exclusively (`O_EXCL`); existing directories keep their mode. |
| Trivy and gitleaks containers | Run as Docker containers on the monitoring server | Pinned by digest, memory/CPU limited, read-only root file system, `no-new-privileges`; gitleaks has **no network**. Trivy has network (it downloads its database and fetches images from registries). The registries are limited to a fixed list of well-known public ones plus those you configured credentials for, because the image names come from an audited host's report, and a crafted name must not make the monitoring server fetch from an arbitrary address such as a cloud metadata endpoint. Starting containers means the agent user is in the `docker` group, which is root-equivalent: another reason to scan on the monitoring server and not on a machine you care less about. |
| GitHub token | `contents: read` on the repositories you pick (fine-grained) | It reaches GitHub's API as a bearer header and `git` through its **process environment**, never a URL or a command line; it sits in `agent.json` (`0600`). Anyone who can read that file or the agent's process environment while a scan runs has the token. Don't give it write rights. |
| Registry credentials | Pull rights for private images | Same: in `agent.json`, in a Docker client's environment only during a scan; read-only tokens. |
| Cloudflare tokens | Read: analytics of your zones. Block (optional): create and delete IP Access Rules in those zones | A separate block token with only *Firewall Services: Edit*; blocks expire; hand-made rules are never deleted. A leaked block token can lock real users out of your site (it can't read or change anything else); a leaked read token shows traffic metadata. |
| `blackbox` service token | Append records to the monitoring server's chain | It can call that one route (10 requests a minute) and nothing else. Unauthenticated requests that were rejected (401, 403, 429) are never written to the chain, so a stranger can't fill it. A holder can **add** false records (their `source` is the token's name, so it is labelled) but cannot change or delete earlier ones. |
| `lockdown` service token | Revoke **everything** on the agent that issued it | It is as powerful as *Lock everything*: anyone who gets it can lock out all your devices on that agent (a denial of service for you, not access to the machine). Guard it like the recovery code. Stored in `lockdownTargets` on the monitoring server. |
| The recovery code | Calls the unauthenticated `POST /v1/security/lockdown` | The code (about 125 bits) is the credential; only the route's own limits apply (5 well-formed attempts per address per 10 minutes, 30 an hour in total, one check at a time; a malformed code is free), and the Tailscale-login check applies to it like to every route. See the limits below. |

**Limits: what these do not protect against**

- **Detection is not prevention.** Traps tell you after someone touched a decoy; the scans tell you about weaknesses,
  they fix nothing. A quiet attacker who avoids the decoys is not caught by them.
- **A decoy file is a read, not a login.** It fires on any read of the file, including your own backup, an indexer or
  a recursive `grep`; on a `noatime` file system it can never fire (the agent reports `noatime`); a read while the
  agent is down is not seen. A decoy **token** only fires if the intruder presents it to the agent that issued it. Decoy
  database users depend on the database logging failed logins to Loki.
- **The black box does not survive root on the monitoring server by itself.** Someone who becomes root there can
  rewrite the whole file with consistent hashes, or stop the agent. What remains is the nightly **anchor in
  Telegram** (an older anchor with a record count that the current chain doesn't reach, or a hash it doesn't have, is
  proof; `verify` checks every anchor on file against the whole chain, including anchors past its end, but anchors on
  file sit next to the chain, so the Telegram copies are the ones to trust) and, if you applied it, `chattr +a`, which only root can undo. `chattr +a` is **not enabled by default** (a root
  step and a file you can then not rotate or delete); without it, the user the agent runs as (and malware running
  as that user) can rewrite or truncate the chain. A cut made while the agent was stopped is found after the restart by
  comparing the chain with `head.json` kept next to it, but someone who can write to the chain can also remove that
  file, so again the anchors are what remains. The chain stops at 1 GiB (`blackbox.broken`, reason `full`) instead of
  filling the disk; a crash can leave a torn last line, which verification skips and counts without hiding a change. If the monitoring server is compromised, anything
  after the point of compromise on it is untrustworthy. Records of other agents are labelled by the token that sent
  them, but an agent that is itself compromised can send false records.
- **What the black box records is what the agents did through their API.** Not what happened on the machine outside
  Tiphys, not `GET` requests, not bodies. Anything an intruder does with a shell is not in it unless it touches Tiphys.
- **The lockdown can be abused to lock you out.** The endpoint takes no token. A malformed code is refused for
  free; a well-formed one counts against 5 per address per 10 minutes and 30 an hour in total (in memory, reset by an
  agent restart), and only one check runs at a time. The per-address limit keeps one peer from spending the shared budget
  quickly, but a peer in the tailnet that keeps trying can still use it up and make a real lockdown wait (a **denial of
  service** for the owner, not a break-in); a correct code cannot be guessed at that rate. Reaching the endpoint needs the
  tailnet, and the Tailscale-login check still applies: with `requireTailscaleLogin` set, only requests that carry your
  login get as far as the code. A lockdown's notice is sent after the revoke, so it reaches your Telegram rather than
  the lost phone. It revokes tokens; it does not stop processes, close
  sessions on the machine or remove SSH keys. Telegram recipients, trap tokens, the recovery code and the agents' own
  outbound tokens are not revoked. If the agent has been taken over, the attacker has the config file; re-pairing
  from the same machine is only meaningful once the machine itself is clean.
- **The recovery code is a bearer secret.** Whoever has the code can lock everything; store it outside the phone and
  not in the same place as other recovery material. Creating a new one replaces the old one.
- **Telegram sees titles, not content,** but it is a third party, and the bot token sits in `agent.json`: someone who
  has it can send messages as the bot. The alert and the anchor are only as trustworthy as that chat; messages are
  best-effort and a failed send is not retried.
- **Scans have blind spots.** Trivy finds only published vulnerabilities in packages it understands (and no Java
  archive unless the Java DB is on); a remote scan covers the registry's image for the digest the host reports, not a
  look inside the running container. gitleaks and the local patterns find well-known
  formats and entropy, not every secret, and gitleaks scans only the default branch; the Loki scan sees the last 24
  hours of what is logged. A finding stores no value, so dismissing it doesn't make the secret safe: rotate it.
- **The outside view is one vantage point and a fixed list.** It tests 64 ports plus yours and twelve paths from one
  machine, at one time. A machine probing its own public address may not pass its cloud firewall, so the result is
  too good. It tells you what answers, not what is vulnerable. It must only be pointed at things you own.
- **Attack detection depends on Cloudflare and is unvalidated.** It sees only traffic through Cloudflare (a site
  reachable directly by IP is invisible to it), only 4xx/5xx responses, and decides on simple rules; a patient
  scanner under the thresholds isn't flagged. It has **not yet been run against the live Cloudflare API**: until you
  have set a token and watched the first runs, don't rely on it, and don't turn on blocking blindly. Blocking a shared
  address (a company or mobile network) blocks everyone behind it, for the block time.

## Notifications and clipboard

- Payloads are encrypted end-to-end with the phone's WebPush keys (RFC 8291, aes128gcm). The ntfy server sees
  ciphertext, sizes and timing, not content. Without keys (older registrations) payloads are plain JSON over HTTPS.
- Sensitive notices such as the PC clipboard text are sent only to endpoints with WebPush keys and are never written
  to the event log.
- PC clipboard sync skips content marked by password managers (`x-kde-passwordManagerHint`) and is limited to short
  text. Phone-to-PC clipboard sync is off by default and never sends vault copies.
- Command lines in long-command notifications appear in full in the notification, but only the program name is
  written to the event log.

## Audit and events

- `audit.jsonl`: every non-GET request (device id, method, path, status). No bodies, no query strings. Visible in the
  app under *System › Tools › Activity log*.
- `events.jsonl`: notifications and notable actions (control sessions, compose updates, git commits/pushes,
  schedules, backups, "mobile view opened"). URLs, typed text and clipboard content are excluded.
- Both are files in your config folder, readable and editable by your user. They are not tamper-proof. For a record
  that notices edits, turn on the [black box](features/security.md#black-box); its limits are described
  [above](#security-center-scanners-traps-black-box-and-lockdown).

## Recommendations

- Set `--tailscale-login` on every agent and restrict port 7443 with Tailscale ACLs.
- Keep `control`, `claude` and `ports` off where not needed. Narrow `allowedRoots`.
- Set an app lock. Revoke a phone right away if it is lost.
- Keep Sunshine stopped when not in use.
- Pin SSH host keys for the security audit yourself, install the audit script root-owned, and keep the audit key
  `0600` on the monitoring server only.
- If you use the later security phases: keep the recovery code outside the phone and test the lockdown once; give the
  GitHub, registry and Cloudflare tokens only the permissions listed in the [setup guide](setup-guide.md#security-center);
  set up the Telegram alert and the nightly black box anchor so evidence lives outside the monitoring server; consider
  `chattr +a` on the black box chain; plant decoys where only an intruder looks; and don't treat a clean scan as proof.
- Use a dedicated Firefox profile (or ESR installation) for the bridge if you are uncomfortable disabling signature
  checks in your main profile.
