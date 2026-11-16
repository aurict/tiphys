# Getting started

This guide takes you from a fresh checkout to a phone that controls your PC (`argo` in the examples) and a
server (`atlas`). Your tailnet is written as `my-tailnet.ts.net`. Replace these names with your own.

Contents:

1. [Tailscale](#1-tailscale)
2. [Agent on the PC](#2-agent-on-the-pc)
3. [Agent on a server](#3-agent-on-a-server)
4. [Build the app](#4-build-the-app)
5. [Pair the phone](#5-pair-the-phone)
6. [First run in the app](#6-first-run-in-the-app)
7. [Enabling features](#7-enabling-features)
8. [Optional pieces](#8-optional-pieces)

## 1. Tailscale

1. Install Tailscale on the phone and on every machine, and log all of them into the same tailnet.
2. In the Tailscale admin console, enable **MagicDNS** and **HTTPS certificates** (DNS page).
   `tailscale serve` needs both to give each machine a valid `https://<machine>.my-tailnet.ts.net` certificate.
   The Android app only talks to agents over HTTPS: cleartext HTTP is blocked by Android's default network policy.
3. Optional but recommended: let your Linux user manage `tailscale serve` without sudo. The agent's
   "share a port" feature runs `tailscale serve` itself.

   ```sh
   sudo tailscale set --operator=$USER
   ```

The agent never listens on a public interface. It binds to `127.0.0.1:7443`, and `tailscale serve` publishes it
on port 7443 inside the tailnet only.

## 2. Agent on the PC

Requirements: Linux with systemd, Node.js 22 or newer (24 recommended), `git`. Desktop features additionally
need Hyprland. See [requirements in the README](../README.md#requirements) and
[desktop control](features/desktop-control.md) for the list of desktop tools.

### Build

```sh
git clone https://github.com/aurict/tiphys.git
cd tiphys/agent
npm ci
npm run build          # compiles src/ to dist/
```

`npm ci` also installs the Claude Code binary for your platform. The Claude Agent SDK ships it as an optional
dependency, so do not use `--omit=optional` on a machine where you want the `claude` feature.

### Create the configuration

```sh
node dist/cli.js init --name argo --features system,services,docker,power,git,claude
```

`init` creates `~/.config/tiphys/agent.json` with mode 0600, or updates it if it already exists. Override the
path with `--config PATH` or the `TIPHYS_AGENT_CONFIG` environment variable. Flags:

| Flag | Meaning |
|---|---|
| `--name NAME` | Name the agent reports (defaults to the hostname). |
| `--features a,b,c` | Turns on exactly these features and turns **all others off**. |
| `--tailscale-login LOGIN` | Only accept requests whose `Tailscale-User-Login` header (added by `tailscale serve`) equals this login, e.g. `you@example.com`. |

Available features: `system services docker power homepage claude uptime wake watch git desktop control ports
transcribe alerts backups`. On a newly created file `system`, `services`, `docker` and `power` are on and
everything else is off. `--features` overrides that. Start small and add features later
([section 7](#7-enabling-features)). The full option reference is in
[agent/configuration.md](agent/configuration.md).

### Expose it inside the tailnet

```sh
tailscale serve --bg --https=7443 http://127.0.0.1:7443     # prefix with sudo if you are not the operator
curl -s https://argo.my-tailnet.ts.net:7443/v1/health      # works once the agent is running
```

`/v1/health` is the only endpoint that works without a token. It returns the name, version and feature flags.

### Run it as a systemd user service

`tools/pair.sh` and the in-app restart hints assume a user unit called `tiphys-agent.service`. Create
`~/.config/systemd/user/tiphys-agent.service` (adjust the two paths to your checkout and to `command -v node`):

```ini
[Unit]
Description=Tiphys agent
After=network-online.target

[Service]
WorkingDirectory=%h/tiphys/agent
ExecStart=/usr/bin/node %h/tiphys/agent/dist/cli.js serve
Restart=on-failure
RestartSec=5
# No memory/CPU limits: Claude sessions started from the phone run like a terminal session (~500 MB each).
# If memory runs out, only the largest process is killed and the agent stays up.
OOMPolicy=continue
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
```

The unit has the same contents that `tools/deploy-agent.sh` writes on servers. Enable it:

```sh
systemctl --user daemon-reload
systemctl --user enable --now tiphys-agent.service
journalctl --user -u tiphys-agent -f          # logs
```

For desktop features the agent must run in your graphical session's user manager. It finds `WAYLAND_DISPLAY`
and the Hyprland instance under `$XDG_RUNTIME_DIR` by itself, so the unit needs no extra environment.
On a headless server, run `sudo loginctl enable-linger $USER` so the user service starts at boot.

You can also run it in the foreground for a first test: `node dist/cli.js serve`.

### Other CLI commands

```text
node dist/cli.js serve                          start the agent
node dist/cli.js init [--name] [--features] [--tailscale-login]
node dist/cli.js pair --name "Phone" [--url https://argo.my-tailnet.ts.net:7443]
node dist/cli.js devices                        list paired devices
node dist/cli.js revoke <device-id>             revoke one device
node dist/cli.js schema                         print the profile JSON Schema
node dist/cli.js run -- COMMAND [args…]         run a command, push a notification when it ends
node dist/cli.js firefox install                register the Firefox native-messaging host
node dist/cli.js vscode-a11y install|remove     add/remove --force-renderer-accessibility for VS Code (flatpak)
```

All commands accept `--config PATH`. The package also declares a `tiphys-agent` binary, so after `npm link` (or
a global install) you can write `tiphys-agent pair …` instead of `node dist/cli.js pair …`.

## 3. Agent on a server

`tools/deploy-agent.sh` builds the agent locally, copies `dist/`, `helpers/` and the production dependencies to
`~/tiphys-agent` on the server, and on the server it:

- runs `init` (the first time only, the optional Tailscale login is applied),
- re-applies the feature list on every run,
- installs and restarts the `tiphys-agent` systemd user service,
- enables lingering,
- runs `sudo tailscale serve --bg --https=7443 http://127.0.0.1:7443`.

```sh
# usage: tools/deploy-agent.sh <ssh-target> <name> <features> [ssh-key]
TIPHYS_TAILSCALE_LOGIN=you@example.com \
  tools/deploy-agent.sh user@atlas atlas system,services,docker,alerts,backups,watch ~/.ssh/id_ed25519
```

Notes:

- SSH runs in batch mode (key authentication, no prompts). The script uses `sudo` on the server for
  `loginctl enable-linger`, `tailscale serve` and, if Node.js is missing, `apt-get install nodejs`. Passwordless
  sudo is needed, or run those steps by hand beforehand. Check that the server's Node.js is 22 or newer.
- Dependencies are installed with `--omit=optional`, so the Claude Code binary is **not** deployed. The `claude`
  feature is meant for the machine that runs the agent from a full checkout (your PC).
- The script refuses to continue if any dependency contains a native module. A build from x86-64 can then still be
  copied to an arm64 server.
- Re-running the script updates the agent and resets the feature list to exactly what you pass.

## 4. Build the app

### Toolchain

The app is built with **Flutter 3.47.9 (stable)**, **JDK 17** and Android SDK platform 36 / build-tools 36.0.0.
If you do not have them, `tools/setup-dev.sh` installs exactly these versions under `~/opt` without sudo, with
checksum verification and without an emulator. It writes an environment file you source in each shell:

```sh
tools/setup-dev.sh
source ~/opt/tiphys-env.sh
```

### Signing

Release builds read the signing configuration from `~/.config/tiphys/release/key.properties`, or from the file
named in `TIPHYS_KEY_PROPERTIES`. The file is kept outside the repository:

```properties
storeFile=/home/you/.config/tiphys/release/tiphys-release.jks
storePassword=…
keyAlias=tiphys
keyPassword=…
```

Create a keystore once, for example:

```sh
mkdir -p ~/.config/tiphys/release && chmod 700 ~/.config/tiphys/release
keytool -genkeypair -v -keystore ~/.config/tiphys/release/tiphys-release.jks \
  -alias tiphys -keyalg RSA -keysize 4096 -validity 10000
```

Use an absolute `storeFile` path. **Back this folder up.** Without the same key you cannot install updates over
an existing installation. If the file is missing, the release build is signed with the debug key and Gradle prints
a warning.

### Build

```sh
cd app
flutter pub get
flutter build apk --release --target-platform android-arm64 --obfuscate --split-debug-info=build/symbols
# → app/build/app/outputs/flutter-apk/app-release.apk
```

Only arm64 is packaged. Keep `build/symbols` if you want to decode crash stack traces later
(`flutter symbolize`).

Android builds can use a lot of memory. On a desktop you are using, wrap the build with `tools/limited.sh`. It
runs the command on two CPU cores at low priority, tracks every child process (including Gradle daemons) and kills
the job if their total memory exceeds `LIMIT_GB` (default 4; the old name `SINIR_GB` is still accepted):

```sh
LIMIT_GB=4 tools/limited.sh bash -c 'cd app && flutter build apk --release --target-platform android-arm64 --obfuscate --split-debug-info=build/symbols'
```

Install the APK with `adb install app/build/app/outputs/flutter-apk/app-release.apk`, or copy it to the phone and
open it.

## 5. Pair the phone

Pairing creates a new device entry on the agent and shows a QR code with the agent URL and a one-time token. The
token is printed once. The agent stores only its SHA-256 hash.

```sh
# Agent on this machine (restarts the tiphys-agent user service afterwards):
tools/pair.sh local https://argo.my-tailnet.ts.net:7443 Phone

# Agent on a server deployed with deploy-agent.sh (runs in ~/tiphys-agent over SSH):
tools/pair.sh user@atlas https://atlas.my-tailnet.ts.net:7443 Phone ~/.ssh/id_ed25519
```

`tools/pair.sh` wraps `node dist/cli.js pair --name NAME --url URL` and then restarts the agent, because a running
agent only sees new devices after a restart. Always pass the HTTPS tailnet URL with `--url`. Without it, the QR
contains the local listen address (`http://127.0.0.1:7443`), which the phone cannot reach.

In the app, open *Settings › Hosts › (host) › Pair with QR code* and scan the code. If scanning is not possible,
enter the address and token shown below the QR code by hand in the host's agent fields.

## 6. First run in the app

1. **Lock:** *Settings › Security*: set a PIN (at least 6 digits) and, if you like, fingerprint unlock and an
   auto-lock delay. The vault, control sessions and Claude PC sessions require a lock.
2. **Hosts:** *Settings › Hosts*: add one host per machine with name, colour, Tailscale address, SSH port/user and
   key, and agent address + token (or pair with QR).
3. **SSH keys:** *Settings › Keys & secrets*: import a key or generate an ed25519 key on the phone, then add the
   public key to each host's `~/.ssh/authorized_keys`. The app can do that over an existing connection. Terminal,
   files, Compose and log search use SSH directly and work even on hosts without an agent.
4. **Integrations:** *Settings › Integrations*: Grafana, Dozzle, Homepage, Uptime Kuma, ntfy, Scriberr and
   Obsidian (vault name for quick notes).
5. **Profile:** *Settings › Profile file* exports or imports the whole configuration as a `.tiphys.json` file. Use the
   encrypted export to move secrets to a new phone. Android cloud backup and device transfer are disabled for
   Tiphys. `tiphys.example.json` in the repository shows the format.

The home screen shows each host as online once its agent's `/v1/health` (or, without an agent, its SSH port)
answers.

## 7. Enabling features

Every feature is a flag in `agent.json`. You can change flags in two ways:

- **In the app:** *Settings › Hosts › (host) › Agent settings › Features*. The app saves the change and tells you
  to restart the agent.
- **On the machine:** `node dist/cli.js init --features …` (lists the complete set), or edit `agent.json`.

Then restart: `systemctl --user restart tiphys-agent`.

Some flags depend on others or need extra software:

| Feature | Needs |
|---|---|
| `claude` | A Claude Code login on the machine (`claude` CLI login; profiles map to config folders such as `~/.claude`). Folders are limited to `allowedRoots` (default `~`). |
| `desktop` | Hyprland, `grim`, `wl-clipboard`; optional `playerctl`, `wpctl`, `ffmpeg`, `gtk-launch`. |
| `control` | `desktop`, plus `ydotool` (with `ydotoold` running), `wtype`, `notify-send`; `wf-recorder` for the live screen; `python3-gi` + `gir1.2-atspi-2.0` for the mobile view. Off by default. |
| `ports` | `tailscale serve` usable by your user (see [section 1](#1-tailscale)). |
| `transcribe` | A command that takes an audio file (`FILE -m MODEL [-l LANG]`) and prints the text; default `~/.local/bin/transcribe`. |
| `uptime`, `alerts`, `watch`, `wake`, `backups`, `homepage` | Their own sections in `agent.json`. See [agent/configuration.md](agent/configuration.md). |

What each feature does is described in [docs/features/](features/claude.md) and the security implications in
[security.md](security.md).

## 8. Optional pieces

### Push notifications (ntfy + UnifiedPush)

1. Run your own [ntfy](https://docs.ntfy.sh) server, reachable from the phone (for example inside the tailnet).
2. Install the **ntfy** Android app, set its default server to yours, and sign in if your server requires users.
   On phones with aggressive battery management, exempt ntfy from battery optimisation.
3. In Tiphys: *Settings › Notifications › Turn on notifications*, choose ntfy as the distributor, then *Send a test
   notification*. Tiphys registers its UnifiedPush endpoint and WebPush keys with every paired agent.
4. If your ntfy server requires authentication for publishing, put an ntfy access token that may write to the
   UnifiedPush topics (`up*`) into `push.token` in each agent's `agent.json` and restart the agent.

Payloads are encrypted with the phone's WebPush key (aes128gcm). The ntfy server only sees ciphertext. Details:
[features/notifications.md](features/notifications.md).

For long commands on a machine, use `node dist/cli.js run -- make release` (or put it in a terminal snippet). You
get a notification when the command finishes.

### Sunshine / Moonlight (high-quality live screen)

Install [Sunshine](https://github.com/LizardByte/Sunshine) from its release packages, set the web UI credentials
(`sunshine --creds USER PASSWORD`), and add to `~/.config/sunshine/sunshine.conf`:

```ini
capture = wlr
encoder = nvenc
```

Use `capture = kms` if the picture is black. Enter the same web credentials in *Agent settings › Sunshine*. Do **not** enable the Sunshine service permanently. Start it from Tiphys when you need it, which
requires a control session, and stop it afterwards: Moonlight-paired devices can connect while Sunshine runs, and
the PC indicator does not show that. Install Moonlight on the phone, add your PC's tailnet address with **+**,
and enter the PIN Moonlight shows in Tiphys under *Desktop › High quality (Moonlight)*.

### Firefox bridge

```sh
cd firefox && npm ci && npm run build          # → firefox/dist/tiphys-bridge-<version>.xpi
cd ../agent && node dist/cli.js firefox install
```

`firefox install` writes the native-messaging manifest `~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json`
and the launcher `~/.local/share/tiphys/firefox-host`, and prints the XPI path. Then, in Firefox:

1. `about:config` → set `xpinstall.signatures.required` to `false`. Only Firefox ESR, Developer Edition and
   Nightly honour this. Release Firefox always requires signed add-ons. It also allows *any* unsigned add-on,
   see [security.md](security.md#firefox-extension).
2. `about:addons` → gear menu → *Install Add-on From File…* → choose the XPI.
3. Optional: click the extension icon → grant page access, for the reader view, page media, scrolling and typing.

The agent opens the bridge socket only when `desktop` is enabled. Restart the agent after installing. More:
[features/firefox-bridge.md](features/firefox-bridge.md).

### Mobile view

Install the AT-SPI Python bindings (`python3-gi` and `gir1.2-atspi-2.0` on Debian/Ubuntu). GTK and Firefox
windows work out of the box. The agent turns on the accessibility bus flag while a mobile view is open and
restores it afterwards. For VS Code (flatpak), run once:

```sh
node dist/cli.js vscode-a11y install     # copies the launcher with --force-renderer-accessibility
node dist/cli.js vscode-a11y remove      # undo
```

and restart VS Code. More: [features/remotes-and-mobile-view.md](features/remotes-and-mobile-view.md).
