# Tiphys

**Control your PC and servers from your phone — over your own Tailscale network.**

Tiphys is a native Android app (Flutter) plus a small agent (Node.js) that runs on each machine you want to
reach. Nothing goes through a third-party cloud: the phone talks to your machines directly over
[Tailscale](https://tailscale.com), and every device has to be paired before the agent accepts it.

*Named after Tiphys, the helmsman of the Argo.* · Interface: Turkish and English.

## What it does

| | |
|---|---|
| **Claude Code from the phone** | Start sessions in any folder, stream answers live, approve tool permissions (also straight from the notification), photo and voice input, slash commands, cost and context usage, git worktree sessions. Sessions survive agent restarts. Sessions running in a PC terminal are listed read-only and can be **taken over** on the phone. |
| **Terminal** | One-tap SSH with tmux, extra-key bar, snippets, automatic reconnect. |
| **Files** | SFTP browser, text editor, upload/download, share from any Android app to the PC. |
| **Git** | Status, diff, stage, commit, push/pull, branches, history. |
| **System** | CPU/RAM/GPU/disk, services, Docker, processes, open ports (share a localhost port to your tailnet in one tap), clipboard, screenshot, Wake-on-LAN, sleep/reboot/shutdown, audit log. |
| **Monitoring** | Native Grafana dashboards, alert rules and query explorer; Dozzle logs; Uptime Kuma sites and maintenance windows; Homepage services. |
| **Notifications** | Via your own [ntfy](https://ntfy.sh) server (UnifiedPush): Claude finished / waiting, site down, disk full, failed services, Grafana alerts, long commands. |
| **Settings** | Everything editable in the app; export/import as a single `.tiphys.json` profile (secrets only ever leave the device encrypted). |

## How it works

```
 phone (Tiphys)  ──Tailscale──▶  agent on your PC      (Claude, files, git, power…)
                 ──Tailscale──▶  agent on a server     (system, docker, Uptime Kuma…)
                 ──SSH────────▶  any host               (terminal, SFTP)
```

- **app/** — Flutter app (Riverpod, go_router, dartssh2, xterm).
- **agent/** — Fastify + TypeScript service, one per machine; features are switched on per host.
- **schema/** — JSON Schema of the profile file, generated from the agent's Zod definitions.
- **tools/** — deploy, pairing, logo and resource-limited build helpers.

## Getting started

Requirements: a Tailscale network, Node.js 24 on each machine running the agent, Flutter 3.x to build the app.

1. **Agent** (on each machine):
   ```sh
   cd agent && npm ci && npm run build
   node dist/cli.js init --name argo --features system,services,docker,claude,git
   tailscale serve --bg --https=7443 http://127.0.0.1:7443   # expose only inside your tailnet
   node dist/cli.js serve                                    # or install as a systemd user service
   ```
   For a remote Linux server: `tools/deploy-agent.sh user@host atlas system,services,docker`.
2. **App:** `cd app && flutter build apk --release` and install the APK.
3. **Pair:** `tools/pair.sh local https://argo.<your-tailnet>.ts.net:7443` prints a QR code; scan it in
   *Settings › Hosts › (host) › Pair with QR*.
4. Optionally import a profile (`tiphys.example.json` shows the format).

## Development

```sh
cd agent && npx vitest run                 # agent tests
cd app && flutter analyze && flutter test --exclude-tags real   # app tests + golden screenshots
```

Tests tagged `real` run against real hosts described in `~/.config/tiphys/real-test.json`
(see `app/test/integration/real-test.example.json`); they are skipped by default.

## Security notes

- The agent listens on localhost and is exposed only through `tailscale serve`; it can additionally require
  a specific Tailscale login.
- Every request needs a per-device token (stored hashed on the agent, in Android Keystore on the phone).
- Dangerous actions (power, killing processes, taking over sessions, discarding changes) ask for confirmation.

## License

[MIT](LICENSE)
