# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Binary releases (signed agent bundles and the APK) are made with `tools/release.sh`. Versions below refer to the **agent version** reported by `GET /v1/health`
(`agent/src/version.ts`), which the app checks. The app is `1.0.0+1` in `app/pubspec.yaml` and the Firefox
extension is `0.1.0`.

## [Unreleased]

### Added

**Easy install**

- One-command install: `install.sh` (Linux, macOS) and `install.ps1` (Windows). Downloads the release bundle for the
  OS/CPU (agent + Node.js 24), verifies the ed25519 signature of `SHA256SUMS` (key embedded in the installer,
  checked with `openssl`; refuses otherwise unless `--insecure-skip-signature`) and the SHA-256, installs to
  `versions/<v>` with a `current` link, sets up a user service (systemd user unit, launchd agent, Windows logon
  entry), runs `init --detect`, `tailscale serve` and pairing. Re-running updates; `--uninstall [--purge]`.
- Signed releases: `tools/release.sh <version> [--publish]` builds per-platform bundles (linux-x64/arm64,
  darwin-arm64/x64, win-x64) with the matching Claude Agent SDK package and the checksum-verified Node.js runtime,
  the signed APK, `SHA256SUMS` + `SHA256SUMS.sig`; `tools/release-keygen.sh` creates the release key once.
  CI (`release-check.yml`) builds the bundles with a throwaway key and runs the installer in ubuntu:24.04 and
  debian:12.
- Packaging: nfpm `.deb`/`.rpm`, AUR, Homebrew and winget drafts, and a server Docker image (non-root, read-only
  root file system, health check). See `packaging/README.md`.
- `tiphys-agent doctor` and `GET /v1/doctor`: coded checks (Tailscale, `tailscale serve`, service, config
  permissions, clock, disk, Node.js, tools for enabled features, push, latest release) with suggested fixes.
- Self-update (`update` feature, installs from `install.sh` only): `GET /v1/update`, `POST /v1/update/apply`.
  Signed releases only, no downgrades, automatic rollback when the new version fails to start.
- `tiphys-agent init --detect`: turns on the safe features the machine supports, lists risky ones as suggestions.
- `tiphys-agent pair` finds its address from Tailscale when `--url` is missing, and a paired device works without
  restarting the agent (it re-reads `agent.json` changed by another process).

**macOS and Windows agent**

- The server features run on macOS and Windows with the same API: system info (`vm_stat`/`sysctl`/`df`; CIM via
  PowerShell), processes and signals (`ps`; CIM + `taskkill`), listening ports (`netstat` + `lsof`;
  `Get-NetTCPConnection`) with Tailscale sharing, services (launchd jobs; Windows services), power (`pmset` and
  System Events; `shutdown.exe`), Docker Desktop. Linux behaviour is unchanged. See `docs/features/system.md#platforms`.
- `GET /v1/health` returns `unsupported`: what this OS can't do (Windows: per-user services, service logs,
  `INT`/`HUP` signals, Velour and the Firefox bridge). Those routes answer `501 agent.feature.unsupported`
  `{feature, platform}`. `init --detect` and `doctor` are platform aware (launchd / Windows services, Docker Desktop
  daemon check `doctor.feature.dockerUnreachable`, `doctor.feature.unsupported`).
- CI runs the platform tests, the build, the module load check and a start-up smoke test (`serve`, `pair`,
  `/v1/health`, `/v1/system`) on macOS and Windows; parser tests with recorded command outputs run on every OS.

### Changed

- Windows: the agent's settings move to `%APPDATA%\Tiphys\agent.json`; an existing
  `%USERPROFILE%\.config\tiphys\agent.json` (earlier `install.ps1`) keeps being used. macOS keeps `~/.config/tiphys`.
- The launchd agent written by `install.sh` (and the Homebrew service) gets a `PATH` with Homebrew and Docker
  Desktop, so `docker` and other tools are found.
- **`init --features` now adds** to the current list instead of turning every unlisted feature off. Use
  `--set-features` for an exact list and `--disable` to turn features off. `tools/deploy-agent.sh` adds features on
  re-deploys (`TIPHYS_EXACT_FEATURES=1` for the old behaviour).
- `tools/pair.sh` no longer restarts the agent; the address argument is optional.

**Earlier in this release**


- Velour remote as a music app: Home (mixes, quick picks), Explore, Search and Library tabs with a mini player; a
  full-screen player in the cover's colour with swipe and double-tap gestures, karaoke lyrics, up next and a PC panel
  (Velour and system volume, audio output, equalizer, sleep timer with screen off / PC sleep, screen off, show Velour
  on the PC). Live state over `GET /v1/velour/events`; lock-screen and notification controls and the volume buttons
  on Android. Agent: `GET /v1/media/outputs`, `PUT /v1/media/output`, `POST /v1/velour/sleep`, `POST /v1/velour/show`.
  Needs Velour 2026-11-20 or later for live state, sleep timer, equalizer and Explore.

- Velour remote (*System › Media*, `desktop` feature): for the [Velour](https://github.com/mikailustuner/velour)
  YouTube Music player, search with suggestions, the queue (jump, remove, reorder, clear), synced lyrics, like,
  shuffle/repeat, the library (playlists, albums, artists, liked, history) with album/playlist/artist pages, play
  next, add to queue, radio, and add to or create a playlist. Agent `POST /v1/velour` forwards to Velour's local
  control socket.

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
