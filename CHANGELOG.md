# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Tiphys has no binary releases. Versions below refer to the **agent version** reported by `GET /v1/health`
(`agent/src/version.ts`), which the app checks. The app is `1.0.0+1` in `app/pubspec.yaml` and the Firefox
extension is `0.1.0`.

## [Unreleased]

### Added

**Second feature round**

- Event timeline: every agent records notifications and notable actions (`events.jsonl`, `GET /v1/events`). The
  app shows a merged timeline across hosts and a "recent events" home card.
- Backup checks (`backups` feature): newest file age/size by glob, or last result of a systemd unit, with
  stale/ok notifications.
- Docker Compose stacks over SSH on every host: status, update check, update only the services with new images,
  restart, stop, logs.
- Scheduled Claude tasks (daily, weekly, interval) with run-now and last-run links.
- Review Claude's changes on the phone: per-file diffs, commit and push only the session's files (with upstream
  setup), revert with confirmation.
- Two-way clipboard sync: PC → phone as an encrypted, silent notification with a Copy button; phone → PC
  optional, while the app is in the foreground.
- Obsidian quick notes via `obsidian://` (new note or daily note), from Claude answers, logs and the terminal, so
  LiveSync's end-to-end encryption is preserved.
- Media control (MPRIS via `playerctl`, volume via `wpctl`) and a "now playing" home card.
- "Open on PC" for shared or copied links.
- Cross-host log search over SSH (journald and Docker logs) with "ask Claude" and "save to Obsidian".
- Password vault on the phone: re-authentication, auto-lock, `FLAG_SECURE`, sensitive clipboard with auto-clear,
  generator, import from Markdown tables, included in the encrypted profile export.

**Using the PC from the phone**

- Desktop panel for Hyprland: workspaces, window thumbnails, focus/close/fullscreen/float/pin/move, app launcher
  with icons, DPMS.
- Control sessions (`control` feature, off by default): time-limited token, one session at a time, visible PC
  indicator (critical notification + border colour, restored after crashes), rate limits, start/end events.
- Live screen: MJPEG via `wf-recorder` with a `grim` fallback, direct-touch and touchpad modes, keyboard bar, adaptive
  quality; hardware H.264 via NVENC and Android MediaCodec with automatic fallback to MJPEG.
- High-quality mode with Sunshine/Moonlight: status, start/stop, and Moonlight PIN pairing from the app.
- Claude "Use the PC" sessions: in-process MCP tools (screenshot, click, type, key, scroll, windows, launch app,
  confirm) bound to a control session, a live strip in the chat, and a persistent notification with Stop/Extend.
- Support for Hyprland's Lua configuration (`hyprland.lua`, 0.55+) alongside the classic config, detected
  automatically.

**App-aware phone interface**

- Focused-app context from Hyprland's event socket, and an app-aware remote strip with built-in profiles for
  Firefox, VS Code, Zed, kitty, Nautilus, Dolphin, mpv, VLC, Mousepad and a generic profile. You can add your own
  buttons (`desktopRemotes` in the profile, schema version 2).
- Firefox bridge extension (MV3, native messaging): tab list and actions, send a tab to the phone, reader view
  (Mozilla Readability), page media, scrolling and typing behind an optional permission.
  `tiphys-agent firefox install`.
- Mobile view: the focused window's AT-SPI accessibility tree rendered as native controls (Python helper), with
  password-field protection. `tiphys-agent vscode-a11y install|remove` for VS Code.
- Claude PC tools for Firefox tabs and page text, and for the accessibility tree (`ui_tree`, `ui_press`,
  `ui_set_text`, `ui_set_value`), with approval for destructive-looking controls, terminal input and unfamiliar URLs.

**Project**

- English documentation (`docs/`), security policy, contributing guide, CI workflow, issue and PR templates.

### Changed

- Live-screen input accepts a `wait` event so key/text sequences keep their order.
- `tools/sinirli.sh` was renamed to `tools/limited.sh` (`LIMIT_GB`; `SINIR_GB` still accepted).
- Code comments translated to English.

### Security

- Review fixes for the desktop features. PC Claude sessions accept messages and approvals only from the device holding
  control. Turning `control` off ends open sessions immediately. Stored Uptime Kuma, Grafana and Sunshine passwords
  are not reused when their URL changes. Sunshine TLS is pinned on loopback. The AT-SPI helper matches windows by
  exact title only and refuses private windows. Destructive-word detection normalises Unicode.
- The Firefox bridge rejects a second connection instead of replacing the first, and limits SSE backpressure.

### Known gaps

Verified with tests and fakes but not yet on every real device/app combination: shortcut behaviour on non-US layouts,
MediaCodec latency on real phones, a full real Claude PC session, the mobile view on GTK4 apps, and long-lived SSE
connections over Tailscale.

## [0.3.0] - 2026-11-14

### Added

- Allow/Deny buttons for Claude permission requests directly in the notification, also when the app is closed.
- Messages carry a client id, and the agent ignores duplicates, so retries never send twice.
- Offline outbox: messages written without a connection are kept on disk and sent in order later.
- Agent status endpoint (version, uptime, memory including Claude processes, unexpected restarts in 24 h) and a
  push notification after an unclean restart.
- The app warns when an agent is older than the version it expects.
- "While you were away" summary when returning to a Claude session.
- Session changes view: files edited by the session with their diffs, and a shortcut to the Git screen.
- History is paged from the end of the Claude transcript, with "Load earlier messages".

## Initial version - 2026-11-14

### Added

- Flutter Android app and Node.js/TypeScript agent, connected over Tailscale with QR pairing and per-device tokens.
- Claude Code sessions from the phone: live streaming, permission cards, slash commands, photo and voice input,
  cost/context usage, worktree sessions, read-only terminal sessions with takeover. Sessions survive agent
  restarts.
- SSH terminal with tmux, SFTP file browser and editor, share-to-PC.
- Git: status, diff, stage, commit, push/pull, branches, history.
- System: metrics, services, Docker, processes, port sharing, clipboard, screenshots, Wake-on-LAN, power, audit log.
- Monitoring: Grafana dashboards, alerts and explore; Dozzle logs; Uptime Kuma sites and maintenance windows;
  Homepage.
- Notifications through UnifiedPush/ntfy with WebPush encryption. Long-command notifications via
  `tiphys-agent run`.
- Profile export/import (`.tiphys.json`), plain or passphrase-encrypted. App lock with PIN/biometrics. English and
  Turkish UI.

[Unreleased]: https://github.com/aurict/tiphys/compare/e6fe332...HEAD
[0.3.0]: https://github.com/aurict/tiphys/compare/7b1a693...e6fe332
