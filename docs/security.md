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
`power` are on. Everything that runs code on your behalf or touches the desktop (`claude`, `git`, `desktop`,
`control`, `ports`, `transcribe`, `wake`, `watch`, `uptime`, `alerts`, `backups`, `homepage`) must be enabled
explicitly. Enable only what a machine needs. A server usually needs no `claude`, `desktop` or `control`.

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

## Sunshine / Moonlight

- Sunshine's web credentials are stored only in `agent.json`. The app never gets the password back. TLS to Sunshine
  accepts a self-signed certificate only on loopback, pinned to Sunshine's own certificate when that is readable.
- Starting, stopping and PIN pairing need a control session.
- **Moonlight streaming is independent of Tiphys control sessions.** Once a Moonlight client is paired with Sunshine,
  it can connect whenever Sunshine is running, with full input and **without** the Tiphys PC indicator. Do not
  enable Sunshine at boot. Start it from Tiphys when needed and stop it afterwards. Unpair clients in Sunshine's
  web UI.

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
- Both are files in your config folder, readable and editable by your user. They are not tamper-proof.

## Recommendations

- Set `--tailscale-login` on every agent and restrict port 7443 with Tailscale ACLs.
- Keep `control`, `claude` and `ports` off where not needed. Narrow `allowedRoots`.
- Set an app lock. Revoke a phone right away if it is lost.
- Keep Sunshine stopped when not in use.
- Use a dedicated Firefox profile (or ESR installation) for the bridge if you are uncomfortable disabling signature
  checks in your main profile.
