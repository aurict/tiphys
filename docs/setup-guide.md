# Setup guide

This guide covers the whole installation in one place: every machine, every feature flag and every setting. If you
only want the shortest path to a working phone and PC, use the [quick start](getting-started.md) and come back here
for the details.

The examples use these names. Replace them with your own:

| Example | Meaning |
|---|---|
| `argo` | your PC (Linux desktop with Hyprland), runs an agent |
| `atlas` | an always-on server, runs an agent |
| `orion` | a host you only reach over SSH, no agent |
| `my-tailnet.ts.net` | your tailnet's MagicDNS suffix |
| `user` | your Linux user name |
| `~/tiphys` | your checkout of this repository on `argo` |

Commands that start with `node dist/cli.js` run in `~/tiphys/agent` on the PC, or in `~/tiphys-agent` on a server
deployed with `tools/deploy-agent.sh`. After `npm link` (or a global install) the same CLI is available as
`tiphys-agent`. Every CLI command accepts `--config PATH`.

Contents:

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Agent on the PC](#3-agent-on-the-pc)
4. [Agent on a server](#4-agent-on-a-server)
5. [Running the agent: CLI, config edits, logs, upgrades, removal](#5-running-the-agent-cli-config-edits-logs-upgrades-removal)
6. [Build and install the app](#6-build-and-install-the-app)
7. [Pair the phone](#7-pair-the-phone)
8. [First run in the app](#8-first-run-in-the-app)
9. [Feature flags](#9-feature-flags)
10. [Setting up each feature](#10-setting-up-each-feature)
11. [Settings reference](#11-settings-reference)
12. [Security checklist](#12-security-checklist)
13. [Troubleshooting](#13-troubleshooting)

## 1. Overview

```
                               your tailnet (my-tailnet.ts.net)
 ┌──────────────┐
 │ Phone        │  HTTPS/WSS :7443   ┌──────────────────────────────────────────────┐
 │ Tiphys app   │───────────────────▶│ argo (PC)  tailscale serve :7443             │
 │ ntfy app     │                    │            └▶ agent 127.0.0.1:7443           │
 │ Moonlight    │                    │ Hyprland, Firefox + bridge, Claude Code, agy │
 │ (optional)   │                    └──────────────────────────────────────────────┘
 │              │  HTTPS/WSS :7443   ┌──────────────────────────────────────────────┐
 │              │───────────────────▶│ atlas (server)  tailscale serve :7443        │
 │              │                    │                 └▶ agent 127.0.0.1:7443      │
 │              │                    │ docker, alerts, watch, wake, telegram, …     │
 │              │  SSH / SFTP        └──────────────────────────────────────────────┘
 │              │───────────────────▶ argo, atlas, orion (any SSH host, no agent needed)
 │              │  HTTPS             
 │              │───────────────────▶ Grafana · Dozzle · Uptime Kuma · Homepage · ntfy
 └──────────────┘
 agents ──WebPush (encrypted)──▶ your ntfy server ──▶ ntfy app ──UnifiedPush──▶ Tiphys
 atlas ──service token──▶ argo /v1/research/jobs        (Telegram newsletters, optional)
 atlas ──Wake-on-LAN broadcast──▶ argo                  (same LAN, optional)
```

What runs where:

| Machine | Runs | Typical features |
|---|---|---|
| Phone | Tiphys (Android 8.0+, arm64), Tailscale, ntfy app (push), optional Moonlight | everything in the UI; SSH, SFTP, Grafana and Dozzle are spoken to directly |
| PC (`argo`) | agent from a full checkout, optional Firefox bridge, optional Sunshine | `claude`, `git`, `desktop`, `control`, `transcribe`, `research`, `ports` |
| Server (`atlas`) | agent deployed with `tools/deploy-agent.sh` | `system`, `services`, `docker`, `alerts`, `backups`, `watch`, `wake`, `uptime`, `homepage`, `telegram` |
| SSH-only host (`orion`) | nothing from Tiphys, just `sshd` (and `tmux` for persistent terminals) | terminal, files, Compose stacks, log search |

Why the split: the PC agent needs the Claude Code binary, the desktop tools and the AI CLIs, so it runs from a full
`npm ci` in your checkout. Servers get a slim copy without optional dependencies, which also means **no `claude`
feature on servers** (see [section 4](#4-agent-on-a-server)).

Each agent listens only on `127.0.0.1:7443`. `tailscale serve` publishes it as
`https://<machine>.my-tailnet.ts.net:7443` to your tailnet with a valid certificate. Nothing is exposed to the
internet. More on the components: [architecture.md](architecture.md).

## 2. Prerequisites

### Tailscale (every machine and the phone)

1. Install Tailscale on the phone and every machine and log them into the same tailnet (`sudo tailscale up` on
   Linux).
2. In the admin console (DNS page) enable **MagicDNS** and **HTTPS Certificates**. `tailscale serve --https=…` needs
   both. The app only talks to agents over HTTPS with a valid certificate, and the certificate is valid only for the
   `*.ts.net` name, not for the `100.x.y.z` address.
3. Optional, recommended on the PC: make your user the Tailscale operator, so you (and the agent's `ports`
   feature) can run `tailscale serve` without `sudo`:

   ```sh
   sudo tailscale set --operator=$USER
   ```

4. Optional: use Tailscale ACLs/grants to limit which of your devices may reach port 7443.

### Node.js (every agent machine)

The agent needs **Node.js 22 or newer** (`engines` in `agent/package.json`); CI and development use Node.js 24.

```sh
node --version     # must print v22.x or newer
```

Many long-term-support distributions ship an older Node.js in their default repositories. Install a current
release from your distribution's newer stream or from [NodeSource](https://github.com/nodesource/distributions)
before you deploy. `tools/deploy-agent.sh` installs the distribution's `nodejs` package only when `node` is missing
entirely, and it does not check the version.

### Linux and systemd

- The agent is Linux-only (systemd, `/proc`) and runs as a **systemd user service** of the user whose machine it
  controls.
- On servers, user services must start without a login: `sudo loginctl enable-linger user` (the deploy script does
  this).
- Package names below are given for Arch (where Hyprland is most common) and Debian/Ubuntu. Other distributions
  use similar names.
- **ARM servers (arm64)** work. The agent's production dependencies are pure JavaScript, and
  `tools/deploy-agent.sh` refuses to deploy if any native module (`*.node`) shows up, so a build made on an x86-64
  PC can be copied to an arm64 server. Install an arm64 Node.js 22+ on the server.

### Desktop tools (PC only, for `desktop` and `control`)

Desktop features need **Hyprland** (Wayland; classic `hyprland.conf` or Lua `hyprland.lua` config) and the agent
running as the logged-in user.

| Tool | Arch package | Debian/Ubuntu package | Needed for |
|---|---|---|---|
| `hyprctl` | `hyprland` | `hyprland` (where packaged) or a source build | everything on the desktop |
| `grim` | `grim` | `grim` | screenshots, window thumbnails, slow-mode live screen |
| `wl-paste`, `wl-copy` | `wl-clipboard` | `wl-clipboard` | clipboard read/write and PC → phone sync |
| `wf-recorder` | `wf-recorder` | `wf-recorder` | fast live screen (MJPEG; H.264 via NVENC). Without it: `grim` loop at ≤ 4 fps |
| `ffmpeg` | `ffmpeg` | `ffmpeg` | WebP thumbnails, Claude screenshots, NVENC encoding |
| `ydotool` + `ydotoold` | `ydotool` | `ydotool` (check it is 1.x with `ydotoold`) | clicks, wheel, special keys |
| `wtype` | `wtype` | `wtype` | typing text (any Unicode, layout independent) |
| `gtk-launch` | `gtk3` | `libgtk-3-bin` | launching apps |
| `notify-send` | `libnotify` | `libnotify-bin` | PC-side control-session notice (optional; the red border is shown anyway) |
| `playerctl`, `wpctl` | `playerctl`, `wireplumber` | `playerctl`, `wireplumber` | media and volume (optional) |
| `rsvg-convert` | `librsvg` | `librsvg2-bin` | SVG app icons (optional) |
| `python3` + GObject + AT-SPI | `python-gobject`, `at-spi2-core` | `python3-gi`, `gir1.2-atspi-2.0`, `at-spi2-core` | mobile view |
| `busctl` | `systemd` | `systemd` | mobile view (toggles the accessibility bus flag) |
| Sunshine | release package or Flatpak | release package or Flatpak | optional high-quality stream |
| Firefox **ESR**, Developer Edition or Nightly (140+) | `firefox-esr` (AUR), `firefox-developer-edition` | `firefox-esr` | optional Firefox bridge (unsigned add-on) |

**ydotoold.** `ydotool` only works while its daemon runs and your user can write to `/dev/uinput`. The agent looks
for the socket in `$YDOTOOL_SOCKET`, else `$XDG_RUNTIME_DIR/.ydotool_socket`. Run the daemon as a user service
(the Arch package ships one; the unit name may differ elsewhere):

```sh
systemctl --user enable --now ydotool.service
ls -l "$XDG_RUNTIME_DIR/.ydotool_socket"    # must exist
ydotool mousemove -x 10 -y 0                # pointer should move
```

If the daemon cannot open `/dev/uinput`, give your user access, for example with a udev rule
(`KERNEL=="uinput", GROUP="input", MODE="0660"`) and membership in the `input` group, then log in again. If your
daemon uses a different socket path, set `Environment=YDOTOOL_SOCKET=…` in the agent's unit (see
[the drop-in below](#environment-drop-in)).

**NVENC (optional).** The H.264 live screen uses `wf-recorder -c h264_nvenc`, so it needs an NVIDIA GPU and an
`ffmpeg`/`wf-recorder` built with NVENC. Everything else falls back to MJPEG automatically.

### AI tools (PC only, optional)

| Tool | For | Notes |
|---|---|---|
| Claude Code login | `claude` feature | `npm ci` in `agent/` installs the Claude Code binary used by the agent (an optional dependency of the Agent SDK). You still log in once with the `claude` CLI on that machine as the same user. |
| `claude` CLI on the agent's `PATH` | `research` feature (editor step) | The research editor runs the `claude` executable it finds on `PATH`. |
| `agy` (Antigravity CLI, Gemini) on the agent's `PATH` | `research` feature (draft step) | Log in once interactively. |
| `npx` | `research` feature | Starts the pinned searxng/firecrawl MCP servers for the editor. Comes with Node.js. |
| a searxng instance and a Firecrawl instance or API key | `research` feature | Reached through the `searxng` and `firecrawl` MCP servers. |
| a transcription command | `transcribe` feature | Your own script, see [Transcription](#transcription). |

### Build machine (for the app and the Firefox extension)

Flutter 3.47.9 (stable), JDK 17, Android SDK platform 36 and build-tools 36.0.0, on x86-64 Linux.
`tools/setup-dev.sh` installs exactly these without sudo (see [section 6](#6-build-and-install-the-app)). The
Firefox extension build needs only Node.js.

## 3. Agent on the PC

### Build

```sh
git clone https://github.com/aurict/tiphys.git ~/tiphys
cd ~/tiphys/agent
npm ci              # full install: also brings the Claude Code binary (optional dependency)
npm run build       # src/ → dist/
```

Do not use `--omit=optional` on the PC if you want the `claude` feature.

### Create the configuration

```sh
node dist/cli.js init --name argo --features system,services,docker,power,git,claude
```

- `init` creates `~/.config/tiphys/agent.json` (directory `0700`, file `0600`) or updates an existing one. The path
  can be changed with `--config PATH` or `TIPHYS_AGENT_CONFIG`.
- `--name NAME`: the name shown in the app and in notifications (default: the hostname on first creation).
- `--features a,b,c`: **an exact list**. Listed flags are turned on and **every other flag is turned off**. Without
  `--features`, an existing file keeps its flags. A brand-new file without `--features` gets `system`, `services`,
  `docker` and `power` on and everything else off.
- `--tailscale-login LOGIN`: accept only requests whose `Tailscale-User-Login` header (set by `tailscale serve`)
  equals `LOGIN`, for example `you@example.com`. `init` can set it but not clear it; to remove the check, set
  `"requireTailscaleLogin": null` in `agent.json` (see [Changing agent.json safely](#changing-agentjson-safely)).

Start small. You can add features later from the app or the CLI ([section 9](#9-feature-flags)).

### Run it as a systemd user service

`tools/pair.sh` and the app's restart hints assume a user unit named `tiphys-agent.service`. Create
`~/.config/systemd/user/tiphys-agent.service` (adjust the checkout path and the Node.js path from
`command -v node`):

```ini
[Unit]
Description=Tiphys agent
After=network-online.target

[Service]
WorkingDirectory=%h/tiphys/agent
ExecStart=/usr/bin/node %h/tiphys/agent/dist/cli.js serve
Restart=on-failure
RestartSec=5
# No memory/CPU limits: Claude sessions started from the phone use ~500 MB each.
# If memory runs out, only the largest process is killed and the agent stays up.
OOMPolicy=continue
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
```

This is the same unit that `tools/deploy-agent.sh` writes on servers. Do not add `MemoryMax=` or
`OOMPolicy=stop`: the first Claude session could then take the whole agent down.

```sh
systemctl --user daemon-reload
systemctl --user enable --now tiphys-agent.service
systemctl --user status tiphys-agent
```

The agent must run in your graphical session's user manager. It finds `WAYLAND_DISPLAY`, the Hyprland instance and
the session bus under `$XDG_RUNTIME_DIR` on its own, so the unit needs no display variables. Desktop features work
while you are logged in to Hyprland. If you want the PC agent to be reachable right after a Wake-on-LAN boot, before
you log in (for example for [research](#research-pc) jobs), also enable lingering: `sudo loginctl enable-linger $USER`.

#### Environment drop-in

A user service does not get your shell's `PATH`. If tools live in `~/.local/bin` (typical for `agy`, `claude` and
a `transcribe` script) or you need a time zone or ydotool socket override, add a drop-in:

```sh
systemctl --user edit tiphys-agent
```

```ini
[Service]
Environment=PATH=%h/.local/bin:/usr/local/bin:/usr/bin:/bin
# Optional:
# Environment=TZ=Area/City                       schedules use the agent's local time zone
# Environment=YDOTOOL_SOCKET=/run/user/1000/.ydotool_socket
```

Then `systemctl --user restart tiphys-agent`.

### Publish it in the tailnet

```sh
tailscale serve --bg --https=7443 http://127.0.0.1:7443     # prefix with sudo if you are not the operator
tailscale serve status
```

`--bg` makes the setting persistent across reboots.

### Check it

```sh
curl -s http://127.0.0.1:7443/v1/health                      # on argo
curl -s https://argo.my-tailnet.ts.net:7443/v1/health        # from any tailnet machine
```

`/v1/health` is the only endpoint that works without a token. It returns the agent name, version and feature flags.
For a quick foreground test instead of the unit: `node dist/cli.js serve`.

## 4. Agent on a server

### What `tools/deploy-agent.sh` does

```text
tools/deploy-agent.sh <ssh-target> <name> <features> [ssh-key]
```

| Argument | Meaning |
|---|---|
| `ssh-target` | `user@host` for `ssh`, e.g. `user@atlas` or a tailnet address |
| `name` | agent name (`init --name`) |
| `features` | comma-separated, **complete** feature list (`init --features`) |
| `ssh-key` | optional private key passed to `ssh -i` |
| `TIPHYS_TAILSCALE_LOGIN` (env) | optional; applied as `--tailscale-login` **only when `agent.json` does not exist yet** |

On your PC, the script:

1. builds the agent (`npm run build`);
2. stages `dist/`, `helpers/`, `package.json` and `package-lock.json`, and installs production dependencies with
   `npm ci --omit=dev --omit=optional --ignore-scripts`. This leaves out the Claude Code binary;
3. aborts if any native module was installed;
4. copies everything over SSH (batch mode: key authentication only, no prompts) into `~/tiphys-agent`, replacing
   `dist/`, `helpers/` and `node_modules/` there.

On the server, it:

1. installs the distribution's `nodejs` with `sudo apt-get` if `node` is missing (Debian/Ubuntu only);
2. runs `init` with the name, features and optional login if `~/.config/tiphys/agent.json` does not exist;
3. runs `init --name NAME --features FEATURES` **every time**, which resets the feature set to exactly your list;
4. writes `~/.config/systemd/user/tiphys-agent.service`, enables lingering (`sudo loginctl enable-linger`), enables
   and restarts the service;
5. prints `active`, the `/v1/health` answer, and runs `sudo tailscale serve --bg --https=7443 http://127.0.0.1:7443`.

The server needs **passwordless sudo** for `loginctl enable-linger`, `tailscale serve` and (only if Node.js is
missing) `apt-get`, because SSH runs without a terminal. If you do not want that, run those three steps by hand
once before deploying and let the `sudo` lines fail harmlessly, or grant `NOPASSWD` for just those commands.

### First deploy

```sh
cd ~/tiphys
TIPHYS_TAILSCALE_LOGIN=you@example.com \
  tools/deploy-agent.sh user@atlas atlas system,services,docker,alerts,backups,watch ~/.ssh/id_ed25519
```

Then pair the phone with it ([section 7](#7-pair-the-phone)).

### Updating and changing features on a server

Re-run the script to update the agent. Because step 3 above re-applies your list, **list every feature you want to
keep**, including ones you turned on later from the app. Check the current set first:

```sh
curl -s https://atlas.my-tailnet.ts.net:7443/v1/health \
  | jq -r '.features | to_entries | map(select(.value).key) | join(",")'
# e.g. system,services,docker,power,watch,alerts,backups,telegram
```

Paste that list (plus or minus what you want to change) as the third argument:

```sh
tools/deploy-agent.sh user@atlas atlas system,services,docker,power,watch,alerts,backups,telegram ~/.ssh/id_ed25519
```

Everything else in `agent.json` (devices, push endpoints, sections such as `wake` or `telegram`) is kept. To
change only features without redeploying, use the app ([section 9](#9-feature-flags)).

Notes:

- No `claude` on servers: the binary is not deployed. `research` also does not belong on a server; it needs `agy`
  and `claude` logged in on that machine.
- No Firefox bridge on servers: the XPI is not copied and `firefox install` is meant for the PC checkout.
- The health check in the script uses port 7443; if you changed `listen.port`, adjust it.

### SSH-only hosts

A host without an agent (`orion`) needs only `sshd`, your phone's public key in `~/.ssh/authorized_keys`, and
ideally `tmux`. Add it in the app with SSH settings and leave the agent fields empty. Terminal, files, Compose
stacks and log search work over SSH; the home screen shows it online when its SSH port answers.

## 5. Running the agent: CLI, config edits, logs, upgrades, removal

### CLI reference

| Command | Purpose |
|---|---|
| `serve` | Run the agent in the foreground (the systemd unit does this). |
| `init [--name N] [--features a,b] [--tailscale-login L]` | Create or update `agent.json`. `--features` is an exact list. |
| `pair --name "Phone" --url https://argo.my-tailnet.ts.net:7443` | Add a device, print the QR code and the one-time token. |
| `devices` | List paired devices (`id`, `name`, `createdAt`). |
| `revoke <device-id>` | Remove a device and its push endpoint. |
| `service-token create --name atlas --scope research` | Create a scoped token (`tps_…`), printed once. |
| `service-token list` / `service-token revoke <id>` | List / revoke service tokens. |
| `run -- CMD [ARGS…]` | Run a command and send a "done/failed" push when it ends. |
| `firefox install` | Register the Firefox native-messaging host (PC). |
| `vscode-a11y install` / `remove` | Make Flatpak VS Code expose its accessibility tree (PC). |
| `schema` | Print the JSON Schema of the app's `.tiphys.json` profile (not of `agent.json`). |

Full reference: [agent/configuration.md › CLI](agent/configuration.md#cli).

### Changing agent.json safely

The running agent reads `agent.json` **once at start** and keeps it in memory. It writes the whole file back
whenever it changes something itself (the phone saves settings or registers for push, a service token is used, a
device is revoked from the app, …). Two consequences:

- **After every CLI command that changes the file** (`init`, `pair`, `revoke`, `service-token create|revoke`),
  restart the agent right away: `systemctl --user restart tiphys-agent`. Until then the running agent does not see
  the change (a new device is rejected, a revoked one still works), and its next write can undo the change.
  `tools/pair.sh` restarts for you.
- **To edit `agent.json` by hand**, stop the agent first, edit, check the JSON, start it again:

  ```sh
  systemctl --user stop tiphys-agent
  $EDITOR ~/.config/tiphys/agent.json
  node -e 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8"))' ~/.config/tiphys/agent.json
  systemctl --user start tiphys-agent
  journalctl --user -u tiphys-agent -n 30      # an invalid field stops the agent with a zod error here
  ```

Changes made from the app go through the running agent and need no stop/start (some need a restart to take effect,
see [section 11](#11-settings-reference)).

### Logs

```sh
journalctl --user -u tiphys-agent -f          # follow
journalctl --user -u tiphys-agent -n 200      # last 200 lines
journalctl --user -u tiphys-agent -b          # since boot
```

On a server: `ssh user@atlas journalctl --user -u tiphys-agent -n 100`. If `journalctl --user` shows nothing on a
server, the user journal may not be persistent; check `journalctl _SYSTEMD_USER_UNIT=tiphys-agent.service`.

Besides the journal, the agent keeps `events.jsonl` (notifications and notable actions) and `audit.jsonl` (every
non-GET request) next to `agent.json`. Both are visible in the app (*System › Events*, *System › Tools › Activity
log*).

### Upgrading

The app warns when an agent's version differs from the one it expects, so update the agent and the app from the
same commit.

PC:

```sh
cd ~/tiphys && git pull
cd agent && npm ci && npm run build
systemctl --user restart tiphys-agent
# Firefox bridge, if used: rebuild the XPI when firefox/ changed and reinstall it in about:addons;
# re-run `node dist/cli.js firefox install` if you moved the checkout or changed the Node.js installation.
```

Servers: re-run `tools/deploy-agent.sh` from the updated checkout with the full feature list
([above](#updating-and-changing-features-on-a-server)).

App: rebuild and install over the existing app with the same signing key ([section 6](#6-build-and-install-the-app)).

### Uninstalling

```sh
systemctl --user disable --now tiphys-agent
rm ~/.config/systemd/user/tiphys-agent.service && systemctl --user daemon-reload
tailscale serve --https=7443 off                  # sudo if you are not the operator
# Shared ports from the Ports screen are separate serve entries: `tailscale serve status`, then `--https=<port> off`.
node ~/tiphys/agent/dist/cli.js vscode-a11y remove   # PC, if you used it
rm -f ~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json ~/.local/share/tiphys/firefox-host
rm -rf ~/.config/tiphys          # config, devices, state. On the build PC this also holds release/ (your signing key!)
rm -rf ~/tiphys-agent            # servers
```

Remove the Tiphys Bridge add-on in `about:addons` and set `xpinstall.signatures.required` back to `true`.
Lingering can be turned off with `sudo loginctl disable-linger user` if nothing else needs it.

## 6. Build and install the app

There are no prebuilt APKs; you build and sign the app yourself.

### Toolchain

```sh
tools/setup-dev.sh            # JDK 17, Flutter 3.47.9, Android cmdline-tools, platform 36, build-tools 36.0.0
source ~/opt/tiphys-env.sh    # in every shell you build from
flutter doctor
```

The script installs into `~/opt` without sudo, verifies checksums, skips the emulator, accepts the SDK licences and
writes `~/opt/tiphys-env.sh` (`JAVA_HOME`, `ANDROID_HOME`, `PATH`, `GRADLE_OPTS` limited to 2 workers / 2 GB). It
downloads x86-64 Linux packages. On a desktop you are using, run it with low priority:
`taskset -c 0,1 nice -n 10 ionice -c2 -n7 tools/setup-dev.sh`.

### Signing key

Release builds are signed with the key described in `~/.config/tiphys/release/key.properties`, or in the file
named by `TIPHYS_KEY_PROPERTIES`. Keep it outside the repository (`*.jks`, `*.keystore` and `key.properties` are
git-ignored anyway).

```sh
mkdir -p ~/.config/tiphys/release && chmod 700 ~/.config/tiphys/release
keytool -genkeypair -v -keystore ~/.config/tiphys/release/tiphys-release.jks \
  -alias tiphys -keyalg RSA -keysize 4096 -validity 10000
```

`~/.config/tiphys/release/key.properties` (mode `0600`, absolute `storeFile`):

```properties
storeFile=/home/user/.config/tiphys/release/tiphys-release.jks
storePassword=…
keyAlias=tiphys
keyPassword=…
```

If the file is missing, the release build is **signed with the debug key** and Gradle prints a warning that starts
with `Tiphys:`. An APK signed with a different key cannot be installed over an existing installation. **Back up
this folder** (outside the machine); losing it means uninstalling the app (and its on-device secrets) to update.

### Build

```sh
cd ~/tiphys/app
flutter pub get
flutter build apk --release --target-platform android-arm64 --obfuscate --split-debug-info=build/symbols
# → app/build/app/outputs/flutter-apk/app-release.apk
```

- Only arm64 is packaged.
- `--obfuscate` renames Dart symbols; `--split-debug-info=build/symbols` keeps the symbol files out of the APK.
  Keep `build/symbols` for each release you install if you want to decode stack traces later
  (`flutter symbolize -i <trace> -d build/symbols/app.android-arm64.symbols`).
- The Android release build also runs R8 minification (`isMinifyEnabled`).

Android builds can use a lot of memory. On a desktop you are working on, wrap the build with `tools/limited.sh`. It
runs the command on two cores at low CPU and I/O priority, tracks all child processes (including detached Gradle
daemons) and kills them all if their combined memory exceeds `LIMIT_GB` (default 4; the old name `SINIR_GB` still
works). It prints the peak memory at the end.

```sh
LIMIT_GB=4 tools/limited.sh bash -c 'cd app && flutter build apk --release --target-platform android-arm64 --obfuscate --split-debug-info=build/symbols'
```

### Verify the signature

```sh
APK=app/build/app/outputs/flutter-apk/app-release.apk
"$ANDROID_HOME/build-tools/36.0.0/apksigner" verify --print-certs "$APK"
keytool -list -v -keystore ~/.config/tiphys/release/tiphys-release.jks -alias tiphys | grep SHA256
```

The `SHA-256 digest` printed by `apksigner` must match the keystore's `SHA256` fingerprint (ignore the colons).
If it shows `CN=Android Debug`, the release key was not found.

### Install and update

```sh
adb install -r app/build/app/outputs/flutter-apk/app-release.apk
```

or copy the APK to the phone and open it (allow installs from that source). Updates install over the existing app
as long as the signing key is the same. Requirements: Android 8.0 (API 26) or newer, arm64.

## 7. Pair the phone

Pairing adds a device to an agent and gives the phone a random token (`tph_…`, 256 bits). The token is shown
**once**, as a QR code and as text; the agent stores only its SHA-256 hash.

### With `tools/pair.sh` (recommended)

```text
tools/pair.sh local       <agent-url> [device-name]              agent on this machine
tools/pair.sh <ssh-target> <agent-url> [device-name] [ssh-key]   agent in ~/tiphys-agent on a server
```

```sh
tools/pair.sh local https://argo.my-tailnet.ts.net:7443 Phone
tools/pair.sh user@atlas https://atlas.my-tailnet.ts.net:7443 Phone ~/.ssh/id_ed25519
```

The script runs `pair --name NAME --url URL` and then restarts the `tiphys-agent` user service, so the running agent
accepts the new token. The device name defaults to `Phone`.

### With the CLI directly

```sh
node dist/cli.js pair --name "Phone" --url https://argo.my-tailnet.ts.net:7443
systemctl --user restart tiphys-agent
```

**Always pass `--url`** with the tailnet HTTPS address and port. Without it the QR contains the listen address
`http://127.0.0.1:7443`, which the phone cannot reach.

### In the app

*Settings › Hosts › (host) › Pair with QR code*, then scan. The scan fills in the agent address and stores the token
in the phone's Keystore-backed storage. Without a camera, type the printed address and token into the host's
**Agent address** and **Agent token** fields.

### Several phones

Pair each device separately with its own name (`Phone`, `Tablet`, …). Each gets its own token, push registration
and audit entries, and can be revoked on its own. All paired devices have the same rights; there are no roles.
An encrypted profile export carries the tokens to another phone, so it is meant for **replacing** a phone; a second
phone in daily use should be paired on its own so the agent can tell the devices apart.

### List and revoke

| Where | How |
|---|---|
| Agent CLI | `node dist/cli.js devices`, then `node dist/cli.js revoke <device-id>` and **restart the agent** |
| App | *Settings › Hosts › (host) › Agent settings › Paired devices › Revoke* (takes effect immediately) |
| App, everything | *Agent settings › Lock everything*: revokes **all** devices including this phone, all service tokens and all push endpoints. Pair again on the machine to get back in. |

Revoking also removes the device's push endpoint.

## 8. First run in the app

1. **Security**: *Settings › Security*: set a **PIN** (at least 6 digits), optionally **Unlock with fingerprint**
   and **Auto-lock**. The vault, control sessions and Claude PC sessions require a lock.
2. **Keys**: *Settings › Keys & secrets*: import an SSH key or generate an ed25519 key on the phone. Add the public
   key to `~/.ssh/authorized_keys` on each host (the app can do this over an existing connection).
3. **Hosts**: *Settings › Hosts › Add host*, one per machine:
   - **Name**, **ID** (lowercase, e.g. `argo`; other settings refer to it, see [Wake-on-LAN](#host-watch-and-wake-on-lan)),
     **Colour**, **Address** (MagicDNS name such as `argo.my-tailnet.ts.net`);
   - **SSH**: user, port, key or password, optional **tmux session**, **Compose folders**;
   - **Tiphys agent**: **Agent address** `https://argo.my-tailnet.ts.net:7443` and **Agent token**, or
     **Pair with QR code**;
   - **Wake-on-LAN**: MAC address and **Send from** (this phone or an agent host);
   - **Tags**.
4. **Integrations**: *Settings › Integrations*: Grafana, Dozzle, Homepage, Uptime Kuma, ntfy, Scriberr, Obsidian
   (see [section 10](#10-setting-up-each-feature)).
5. **Claude**: *Settings › Claude*: **Agent that runs Claude** (usually `argo`) and the defaults.
6. **Notifications**: *Settings › Notifications* ([Notifications](#notifications)).

A host shows as online on the home screen when its agent's `/v1/health` (or, without an agent, its SSH port)
answers.

**Profile file.** *Settings › Profile file* exports and imports the whole phone configuration as a `.tiphys.json`
file:

- **Export › Without secrets**: safe to share; keys and tokens are left out.
- **Export › Encrypted backup**: includes keys and tokens, encrypted with a passphrase (at least 10 characters;
  Argon2id + XChaCha20-Poly1305).
- **Import**: shows *Will be added / Will change / Will be removed* first. **Merge** overwrites same IDs and adds new
  ones; **Replace all** makes everything exactly what is in the file. Secrets missing from the file are listed so you
  can enter them again.
- **Reset everything** deletes all settings and secrets on the phone.

Android cloud backup and device transfer are disabled for Tiphys, so the encrypted export is the only way to move
secrets. The format is shown in [`tiphys.example.json`](../tiphys.example.json) and validated against
[`schema/tiphys.schema.json`](../schema/tiphys.schema.json). The export also contains a copy of each agent's
settings as last saved from the app (secrets redacted); importing it does **not** change any agent.

## 9. Feature flags

Every feature is a boolean in `features` in `agent.json`. Routes of a disabled feature are not registered, and
heavy modules (Claude SDK, Uptime Kuma bridge, watchers) are not loaded.

| Flag | Default | Enables | Requires | Risk |
|---|---|---|---|---|
| `system` | on | CPU/RAM/GPU/disk info, top processes, sending signals to a PID (with confirmation) | `nvidia-smi` for GPU (optional) | medium |
| `services` | on | systemd user and system units: list, start/stop/restart, journal | polkit for system units | medium |
| `docker` | on | containers: list with stats, start/stop/restart, logs; crash/OOM alerts with `alerts` | `docker` usable by the agent's user (e.g. `docker` group) | medium |
| `power` | on | reboot, power-off, suspend (with confirmation) | polkit allowing `systemctl reboot` etc. for the user | high |
| `homepage` | off | reads Homepage `services.yaml`, health-checks services, adds services | `homepage.servicesPath` readable/writable | low |
| `claude` | off | Claude Code sessions, history, slash commands, schedules, folder picker | full `npm ci`, Claude Code login, `allowedRoots` | high |
| `uptime` | off | Uptime Kuma bridge (monitors, heartbeats, maintenance) | `uptimeKuma` login | low |
| `wake` | off | sends Wake-on-LAN packets to `wake.targets` | agent on the target's LAN | low |
| `watch` | off | polls other agents' `/v1/health`, notifies offline/online | `watch.hosts` | low |
| `git` | off | status, diff, stage, discard, commit, push/pull/fetch, branches inside `allowedRoots` | `git`; credentials for push | medium |
| `desktop` | off | clipboard, screenshot, open URL, media/volume, window and app list, Sunshine status, Firefox bridge socket | Hyprland, `grim`, `wl-clipboard` | medium |
| `control` | off | everything that changes the desktop: window actions, apps, live screen input, Firefox tabs, mobile view, Sunshine start/stop/pair, Claude PC sessions | `desktop`, `ydotool`+`ydotoold`, `wtype`, app lock on the phone | high |
| `ports` | off | list listening ports, share a localhost port to the tailnet | `ss`, `tailscale serve` as your user (operator) | medium |
| `transcribe` | off | `/v1/transcribe` for voice input | a transcription command | low |
| `alerts` | off | disk full, failed units, Docker crash/OOM, Grafana firing alerts | `alerts` section | low |
| `backups` | off | backup freshness checks every 15 min | `backups.checks` | low |
| `research` | off | web research jobs for another agent with a service token | `agy`, `claude`, searxng and firecrawl MCP servers | medium (spends your AI subscriptions) |
| `telegram` | off | Telegram newsletters: bot, invites, feeds, approval, delivery | bot token, `research` link to a PC | low (messages people you invited) |

Risk is a guide to what a holder of a device token can do: **low** = read-only or notification only, **medium** =
narrow state changes, **high** = run code, change files, cut power or drive the desktop.

**Restart.** Every flag change needs an agent restart, with one exception: turning `control` **off** takes effect
immediately and ends any open control session. Restart after turning it on as well, as the app tells you.

How to change flags:

- **App:** *Settings › Hosts › (host) › Agent settings › Features*, toggle, **Save**, then restart the agent. The
  app shows *Saved. Restart the agent to apply feature changes.* You can restart from a terminal on the phone
  (`systemctl --user restart tiphys-agent` over SSH).
- **CLI:** `node dist/cli.js init --features <complete list>`, then restart. Remember it turns everything not
  listed off.
- **Servers:** the app, or re-run `tools/deploy-agent.sh` with the complete list.

## 10. Setting up each feature

### Claude

Agent side (`argo`):

1. Log in to Claude Code once as the agent's user: run `claude` in a terminal and sign in.
2. Turn on `claude` (and usually `git` for the *Changes* view and worktree sessions). Restart.
3. **Allowed folders** (`allowedRoots`, default `["~"]`): sessions, git and the folder picker stay inside these
   (symlinks are resolved first). Narrow it, e.g. to `~/code`, in *Agent settings › Allowed folders* (one per line;
   applies immediately).
4. **Profiles** (separate Claude accounts or setups) are defined **in `agent.json`** (no app editor on the agent
   side):

   ```json
   "claude": {
     "profiles": { "personal": "~/.claude", "work": "~/.claude-work" },
     "defaultProfile": "personal"
   }
   ```

   Profile ids are lowercase (`a-z0-9-`). A folder other than `~/.claude` is passed to Claude Code as
   `CLAUDE_CONFIG_DIR`. Log in to each extra profile once: `CLAUDE_CONFIG_DIR=~/.claude-work claude`. Edit with the
   [stop/edit/start procedure](#changing-agentjson-safely).

App side (*Settings › Claude*):

- **Agent that runs Claude**: the host with the `claude` feature.
- **Model**, **Thinking effort**, **Permission mode** (*Ask every time*, *Accept edits, ask for commands*, *Plan
  first*, *Don't ask (bypass permissions)*): defaults for new sessions.
- **Profiles**: one per line as `id = config folder`. The ids must match the agent's `claude.profiles` keys; the
  agent rejects unknown ids (`agent.claude.unknownProfile`). The picker appears only with more than one profile.
- **Favourite folders** and **Pinned slash commands**.

**Use the PC** sessions additionally need `desktop` and `control`, Hyprland and an app lock. Voice input needs
`transcribe`. Scheduled tasks use the agent's local time zone (`TZ`). Details: [features/claude.md](features/claude.md).

### Desktop and remote control

1. Install the [desktop tools](#desktop-tools-pc-only-for-desktop-and-control) and get `ydotoold` running.
2. Turn on **Desktop (clipboard, screenshot)** (`desktop`) and **Remote control (windows, opening apps)**
   (`control`), restart.
3. Set an app lock on the phone.

**Control sessions.** Everything that changes the desktop needs a control session. The app opens one when you enter
the desktop panel or live screen and asks for the PIN/fingerprint. A session lasts 15 minutes by default, can be
extended but never beyond 60 minutes remaining, and only one device can hold it. For the desktop panel and the live
screen it ends when you leave the screen or after 60 s in the background. Opening is limited to 5 per minute per
device.

**PC indicator.** While a session is open the PC shows it: Hyprland's active border switches to a red/orange
gradient (at least 3 px) and, if `notify-send` and a notification daemon exist, a critical notification appears. If
the border cannot be set, the session is refused (`agent.control.indicatorFailed`). The previous border is restored
afterwards, also after a crash (`control-indicator.json`). The indicator is not configurable.

**Clipboard sync** (*Agent settings › Clipboard sync (PC → phone)*, `desktop.clipboardSync`, default on, no
restart): text copied on the PC (≤ 3000 bytes, not from a password manager) arrives as a silent, end-to-end
encrypted notification. The phone → PC direction is set on the phone: *Settings › Notifications › Clipboard › Sync
clipboard to PC* and **PC to sync with**.

**App controls** (*Settings › App controls*): your own live-screen buttons per window class.

More: [features/desktop-control.md](features/desktop-control.md).

### Live screen, Sunshine and Moonlight

The built-in live screen needs `desktop` + `control` and `wf-recorder` (otherwise a slow `grim` fallback). H.264
needs NVENC and a hardware H.264 decoder on the phone; choose *Codec: JPEG* to stop trying.

High-quality mode (optional, 60 fps through Moonlight):

1. Install [Sunshine](https://github.com/LizardByte/Sunshine) from its release packages or Flatpak. Do **not**
   enable it at boot.
2. Create its web user: `sunshine --creds USER PASSWORD`.
3. In `~/.config/sunshine/sunshine.conf`:

   ```ini
   capture = wlr
   encoder = nvenc
   ```

   Use `capture = kms` if Moonlight shows a black picture.
4. In *Agent settings › Sunshine (Moonlight)* (shown when `desktop` is on) enter the same user name and password.
   The URL defaults to `https://127.0.0.1:47990`; a self-signed certificate is accepted only on loopback. The
   password stays on the agent; leave the field empty to keep the stored one.
5. Install Moonlight on the phone and add the PC's tailnet address with **+**.
6. In Tiphys open *Desktop › Tools › High quality (Moonlight)*: **Start Sunshine** (runs `systemctl --user` on
   `app-dev.lizardbyte.app.Sunshine.service` or `sunshine.service`; needs a control session), tap the PC in
   Moonlight, then **Enter Moonlight PIN** in Tiphys.

Stop Sunshine when done. A Moonlight client paired with Sunshine can connect whenever Sunshine runs, with full
input and **without** the Tiphys PC indicator. Unpair old clients in Sunshine's web UI.

### Firefox bridge

Requirements: `desktop` on the PC agent (the bridge socket `$XDG_RUNTIME_DIR/tiphys/firefox.sock` is created at
agent start), `control` for everything except the connection status, and Firefox 140+ that allows unsigned add-ons
(**ESR, Developer Edition or Nightly**; release and beta Firefox ignore the preference).

```sh
cd ~/tiphys/firefox && npm ci && npm run build       # → firefox/dist/tiphys-bridge-<version>.xpi
cd ../agent && node dist/cli.js firefox install
systemctl --user restart tiphys-agent
```

`firefox install` writes the launcher `~/.local/share/tiphys/firefox-host` (`$XDG_DATA_HOME`; it stores the
absolute paths of `node` and `agent/dist/firefox_host.js`) and the manifest
`~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json` (allows only `bridge@tiphys.dev`), and prints the newest
XPI. It does not touch your Firefox profile. Then in Firefox:

1. `about:config` → `xpinstall.signatures.required` = `false`. This allows **any** unsigned add-on in that
   profile; consider a dedicated ESR installation or profile.
2. `about:addons` → gear → **Install Add-on From File…** → the XPI.
3. Optional: click the Tiphys Bridge toolbar icon and grant the **page content** permission (button labelled
   "Sayfa içeriği iznini ver"). It is needed for the reader view, page media, scrolling and typing; without it those
   actions return `agent.browser.permissionRequired`. The same popup shows whether the helper and the agent are
   connected, and can revoke the permission.

Re-run `firefox install` after moving the checkout or changing the Node.js installation. Only one Firefox instance
can be connected at a time. More: [features/firefox-bridge.md](features/firefox-bridge.md).

### Mobile view and VS Code

The mobile view renders the focused window's AT-SPI accessibility tree as phone controls. It needs `desktop` +
`control`, a control session, `python3` with GObject and AT-SPI bindings, `at-spi2-core` and `busctl`
([package table](#desktop-tools-pc-only-for-desktop-and-control)). GTK apps and Firefox work out of the box; the
agent switches the accessibility bus flag on while a view is open and restores it afterwards (`a11y-state.json`).

For **VS Code (Flatpak)**:

```sh
node dist/cli.js vscode-a11y install     # user copy of the launcher with --force-renderer-accessibility
node dist/cli.js vscode-a11y remove      # undo (only removes a file it wrote)
```

Restart VS Code afterwards. Qt apps may need `QT_LINUX_ACCESSIBILITY_ALWAYS_ON=1`. More:
[features/remotes-and-mobile-view.md](features/remotes-and-mobile-view.md).

### Notifications

Delivery is UnifiedPush through the **ntfy** app and your own ntfy server, encrypted end to end with WebPush. No
Google services.

1. **ntfy server**: run your own ([docs.ntfy.sh](https://docs.ntfy.sh)), reachable by the phone **and** every agent
   (for example inside the tailnet).
2. **Publishing auth** (only if your server denies anonymous writes): agents publish to the phone's UnifiedPush
   topic (`up…`). Either allow anonymous write access to `up*` topics on the server (ntfy documents this for
   UnifiedPush), or give every agent an ntfy access token that may write to `up*`. The token goes into
   `push.token` in each `agent.json` (no app field; [stop/edit/start](#changing-agentjson-safely)):

   ```json
   "push": { "endpoints": [], "token": "tk_…" }
   ```

   Keep the existing `endpoints` array as it is. Without the token the agent logs `… 401/403` for each push.
3. **ntfy app** on the phone (the UnifiedPush distributor): set the default server to yours and sign in
   (*Settings › Manage users* in ntfy).
4. **Battery**: exempt ntfy (and Tiphys) from battery optimisation. On Xiaomi/Redmi/POCO also set ntfy's battery
   saver to *No restrictions* and allow autostart; Samsung, Huawei and OnePlus have similar settings.
5. **Tiphys**: *Settings › Notifications › This phone › Turn on notifications*, choose ntfy under **Deliver
   through**, allow the Android permission. The app registers its endpoint and WebPush keys with every agent host
   (*Registered with: …*; tap the row to retry failed hosts). Then **Send a test notification**.
6. **What you receive**: the switches on the same screen (Claude, System, Telegram, long commands, clipboard). They
   filter on the phone; agents still send and log everything.
7. **Uptime Kuma site alerts** do not go through the agent. Configure an ntfy notification in Uptime Kuma, add the
   topic under *Settings › Integrations › ntfy › Topics to follow*, and use **Subscribe in ntfy**.

After re-pairing or reinstalling ntfy, turn notifications off and on again in Tiphys so every agent gets the new
endpoint. Long commands: `node dist/cli.js run -- make release` sends a push when the command ends.
More: [features/notifications.md](features/notifications.md).

### Monitoring

**Local alerts** (`alerts`, on any agent): *Agent settings › Alerts (disk, services, Grafana)*: **Disk full
threshold (%)** (50–100, default 90), **Check every (seconds)** (min 30, default 300), **Notify when a systemd
service fails**. Docker crash/OOM alerts also need `docker`. Changes to `alerts` need a restart.

**Grafana alert notifications** (same card, *Grafana alerts*): Grafana URL, a **service account token** (Viewer role
is enough), and optional **Prometheus datasource UIDs** (comma separated; Grafana-managed alerts are always
included). *Use Grafana from my profile* copies URL and token from the app integration. Changing the URL requires
entering the token again.

**Grafana dashboards** (app only): *Settings › Integrations › Grafana*: URL, token, default dashboard, refresh, time
range. Several instances are possible.

**Uptime Kuma** (`uptime`, on the agent that can reach Uptime Kuma): *Agent settings › Uptime Kuma*: URL, user name,
password (kept on the agent). Turn on the feature and restart (the login is read at start). Then *Settings ›
Integrations › Uptime Kuma*: choose that host and the check defaults. `tools/uptime-kuma/seed.mjs` can do a
first-time Uptime Kuma setup with an ntfy notification and a list of sites (`UK_URL`, `UK_USER`, `UK_PASS`,
`NTFY_TOKEN`; sites from `sites.json`, see `sites.example.json`).

**Homepage** (`homepage`): *Agent settings › Homepage › services.yaml path* (default
`~/homepage/homepage/services.yaml`), then *Settings › Integrations › Homepage* to pick the host.

**Dozzle** (app only): *Settings › Integrations › Dozzle*: URL and optional basic auth. Container actions need
`DOZZLE_ENABLE_ACTIONS=true` on Dozzle.

More: [features/monitoring.md](features/monitoring.md).

### Backup checks

Turn on `backups` (*Backup status*), restart, then add checks in *Agent settings › Backup checks* (applies on save,
no restart):

- **file**: newest file matching a path (`*`/`?` only in the last segment), with `maxAgeHours` (default 26) and
  `minBytes`;
- **unit**: last run of a systemd unit (user first, then system).

Checks run every 15 minutes; a state change sends `backup.ok`, `backup.stale` or `backup.failed`.
Format: [agent/configuration.md › backups](agent/configuration.md#backups).

### Host watch and Wake-on-LAN

Typical setup: the always-on server `atlas` watches the PC `argo` and wakes it.

**Host watch** (`watch` on `atlas`, configured in `agent.json` only, read at start):

```json
"watch": { "hosts": [
  { "hostId": "argo", "url": "https://argo.my-tailnet.ts.net:7443/v1/health", "intervalSeconds": 60, "offlineAfterSeconds": 180 }
] }
```

Include the `:7443` port: the agent is published only there. `/v1/health` needs no token (and is not subject to the
Tailscale login check). Restart after editing.

**Wake-on-LAN.** First make sure the PC can be woken:

```sh
ip -br link                                    # find the wired interface (e.g. enp5s0) and its MAC
sudo ethtool enp5s0 | grep -i wake-on
#   Supports Wake-on: pumbg
#   Wake-on: g            ← "g" = magic packet enabled, "d" = disabled
sudo ethtool -s enp5s0 wol g                   # enable (not persistent across reboots)
```

Make it persistent with NetworkManager
(`nmcli connection modify "<connection name>" 802-3-ethernet.wake-on-lan magic`) or with `WakeOnLan=magic` in a
systemd `.link` file (`man systemd.link`). Also enable Wake-on-LAN / "power on by PCI-E" in the firmware setup and
disable deep power-saving modes (ErP) that cut power to the NIC. Wake-on-LAN over Wi-Fi rarely works; use a cable.

Then, on the relaying agent (`atlas`, on the **same LAN** as `argo`):

```json
"wake": { "targets": [ { "hostId": "argo", "mac": "aa:bb:cc:dd:ee:ff", "broadcast": "255.255.255.255", "port": 9 } ] }
```

`hostId` must equal the PC's host **ID** in the app. `broadcast` (default `255.255.255.255`) and `port` (default 9)
are optional; if the server has several interfaces, use the LAN's broadcast address (e.g. `192.168.1.255`). Turn on
`wake`, restart (or stop/edit/start). In the app: *Settings › Hosts › argo › Wake-on-LAN*: MAC and **Send from:
atlas**. "This phone (same Wi-Fi)" works only when the phone is on the PC's network.

The `telegram` feature uses the same `wake.targets` to wake the PC for research (it does not need the `wake` flag).
More: [features/system.md › Wake-on-LAN](features/system.md#wake-on-lan).

### Transcription

The agent runs a command of your choice (`transcribe.command`, default `~/.local/bin/transcribe`; `~` is expanded)
as:

```text
<command> <audio-file> -m <small|large-v3> [-l tr|en]
```

It must print the text on stdout and exit 0 within 10 minutes. The repository does not ship such a script; a
typical one calls a Whisper server such as Scriberr. Set `transcribe` in `agent.json` (no app editor on the agent
side; [stop/edit/start](#changing-agentjson-safely)), make sure the command is on the service's `PATH` or use an
absolute path, and turn on `transcribe`:

```json
"transcribe": { "command": "~/.local/bin/transcribe", "model": "small" }
```

Voice input (Claude chat and quick-note dictation) is sent to the host chosen under *Settings › Claude › Agent that
runs Claude*, so turn `transcribe` on there. *Settings › Integrations › Scriberr* chooses the language and model the
app asks for.

### Git and ports

- **Git** (`git`): repositories must be inside `allowedRoots`. Push and pull use the agent user's own git
  credentials (SSH agent keys or a credential helper available to the service).
- **Ports** (`ports`): sharing a localhost port runs `tailscale serve --bg --https=<port>` as your user, so run
  `sudo tailscale set --operator=$USER` once. Port 7443 is reserved.

### Research (PC)

The PC runs web research jobs for another agent (the Telegram newsletters on `atlas`).

1. **Log in to the tools** on `argo`, as the agent's user: run `agy` once and sign in, and make sure `claude` is
   logged in. Both must be on the **service's** `PATH` ([drop-in](#environment-drop-in)); otherwise jobs fail with
   `agent.research.toolMissing`.
2. **MCP servers**, named exactly `searxng` and `firecrawl`:
   - for Gemini: add both with `agy mcp add` (see `agy mcp add --help` for the syntax of your version). Use the
     same pinned packages the agent uses for Claude: `mcp-searxng@2.10.1` and `firecrawl-mcp@3.40.0`;
   - for Claude: user-scope entries in `~/.claude.json`, for example:

     ```sh
     claude mcp add --scope user searxng -e SEARXNG_URL=https://search.my-tailnet.ts.net -- npx -y mcp-searxng@2.10.1
     claude mcp add --scope user firecrawl -e FIRECRAWL_API_URL=https://firecrawl.my-tailnet.ts.net -e FIRECRAWL_API_KEY=… -- npx -y firecrawl-mcp@3.40.0
     ```

     The agent uses only the `env` of these two entries and starts the pinned packages itself; a missing entry
     fails the job with `agent.research.mcpMissing`. It always uses the default `~/.claude` login, not other
     profiles.
3. Turn on `research`, restart.
4. **Connect atlas** (recommended, from the app): open *System › argo › Tools › Research › Connect to a Telegram
   agent*, pick `atlas` (it lists agents with the `telegram` feature) and confirm. The app creates a service token on
   `argo`, stores `research: {url, token, wakeHostId}` on `atlas` and tests the link. The token never touches the
   phone's storage; no restart is needed. `wakeHostId` is filled in when `atlas` has a `wake.targets` entry for
   `argo` (or the profile wakes `argo` through `atlas`).

   By hand instead:

   ```sh
   # on argo
   node dist/cli.js service-token create --name atlas --scope research    # prints tps_… once
   systemctl --user restart tiphys-agent
   ```

   and on `atlas` (stop/edit/start):

   ```json
   "research": { "url": "https://argo.my-tailnet.ts.net:7443", "token": "tps_…", "wakeHostId": "argo" }
   ```

   Include the `:7443` port in `url`. `wakeHostId` is optional and must name an entry in **atlas's**
   `wake.targets`.
5. **Test**: *Research › Test the connection*. The same screen lists service tokens (revoke) and recent jobs.

Notes:

- If `argo` has `requireTailscaleLogin` set and `atlas` is a **tagged** Tailscale device, atlas's requests carry no
  user login and are rejected (atlas then reports `agent.telegram.research.unauthorized`). Either leave the server
  untagged under your user, or don't set the login check on `argo`.
- One job runs at a time, up to 5 wait; each job is limited to 20 minutes. Tools are sandboxed (no shell, only the
  four searxng/firecrawl web tools, writes only in the job directory). Details:
  [features/research.md](features/research.md).

### Telegram newsletters (server)

Run this on an always-on agent (`atlas`). It needs outbound HTTPS to `api.telegram.org`; there is no webhook and no
open port.

1. Turn on `telegram` on `atlas`, restart. Set the server's time zone (or `TZ` in the unit): feed schedules use the
   agent's local time.
2. **Bot**: in Telegram, talk to **@BotFather**, `/newbot`, and copy the token. In Tiphys open *System › atlas ›
   Tools › Telegram*, paste it and **Save and check**. The agent validates it with `getMe` and keeps it only in
   `agent.json`; it is never returned or logged, and the phone does not store it.
3. **Research link**: connect the PC as in [Research](#research-pc). For runs while the PC is off, add a
   `wake.targets` entry for it on `atlas` and set `wakeHostId`; one Wake-on-LAN packet is sent and the run keeps
   retrying until the deadline. Without a wake target an unreachable PC fails the run at once
   (`telegram.pcUnreachable`). Enable lingering on the PC so its agent starts at boot.
4. **Feeds** (*Newsletters › New newsletter*, from the two templates or blank, at most 20):

   | Field | Default | Meaning |
   |---|---|---|
   | schedule (`when`) | template: daily 08:00 / Monday 09:00 | daily, weekly or interval, agent's local time |
   | topic, instructions | — | what to research |
   | `windowHours` | 24 | how far back news may be (1–720) |
   | `minItems` / `maxItems` | 5 / 8 | item range (1–20); fewer than `minItems` but ≥ 1 is still sent |
   | `maxSourcesPerItem` | 3 | 1–3 |
   | allow / block domains | none | enforced again on the server |
   | `skipIfNothingNew` | on | skip silently when nothing new was found |
   | approval | `firstN`, `n` = 3 | `auto` (send), `ask` (always ask), `firstN` (ask for the first *n* issues) |
   | `deadlineMinutes` | 30 | 5–360; research must finish by slot + deadline. Raise it if the PC has to boot first (a job alone may take up to 20 min) |

   Newsletters are written in Turkish (the only supported `language`).
5. **People**: *People › Add person* creates a one-time `t.me` invite link (valid 24 h, at most 20 pending) with
   preselected feeds; share it. The person taps it and sends `/start`. `/stop` unsubscribes them for good (only a
   new invite brings them back). Pause/resume and per-feed switches are on the person's page; groups and channels
   are never served.
6. **Approval**: an issue that needs approval sends a `telegram.approval` push with **Gönder** (send) / **Vazgeç**
   (cancel) buttons; without a decision by deadline + 2 h it expires. Use *Preview* and *Send as a test…* before
   real runs.

Bot messages are not end-to-end encrypted; newsletters are built from public information only. More:
[features/telegram.md](features/telegram.md).

## 11. Settings reference

### Agent settings: app or agent.json

The app edits an agent through `GET`/`PATCH /v1/config`. Secrets are never sent back; the app shows *stored safely*
instead, and leaving a password field empty keeps the stored value as long as the URL is unchanged.

| Setting (`agent.json`) | Where to change it | Takes effect |
|---|---|---|
| `features` | app: *Agent settings › Features*; CLI `init --features` | after restart (turning `control` off: immediately) |
| `allowedRoots` | app: *Allowed folders* | immediately |
| `homepage.servicesPath` | app: *Homepage* | immediately |
| `homepage.checkTimeoutMs` | `agent.json` only (the app resets it to 5000 when it saves) | immediately |
| `uptimeKuma` | app: *Uptime Kuma* | after restart |
| `alerts` (interval, disk %, failed services, Grafana) | app: *Alerts* card (shown when `alerts` is on) | after restart |
| `desktop.clipboardSync` | app: *Clipboard sync* (when `desktop` is on) | immediately |
| `sunshine` | app: *Sunshine (Moonlight)* (when `desktop` is on) | immediately |
| `backups.checks` | app: *Backup checks* (when `backups` is on) | immediately |
| `research` (on the Telegram agent) | app: *Research › Connect to a Telegram agent* | immediately |
| `telegram` (bot token) | app: *Telegram › Bot* | immediately |
| devices | CLI `pair` / `revoke`; app: *Paired devices*, *Lock everything* | CLI: after restart; app: immediately |
| `serviceTokens` | CLI `service-token`; app: *Research* screen | CLI: after restart; app: immediately |
| `name` | `agent.json` or `init --name` | after restart |
| `claude.profiles`, `claude.defaultProfile` | `agent.json` | immediately |
| `wake.targets` | `agent.json` | immediately |
| `watch.hosts` | `agent.json` | after restart |
| `transcribe` | `agent.json` | immediately |
| `push.token` | `agent.json` | immediately |
| `listen`, `requireTailscaleLogin` | `agent.json` (`init --tailscale-login` can set the login) | after restart |
| push endpoints | registered by the app automatically | immediately |

"`agent.json`" means: stop the agent, edit, start ([procedure](#changing-agentjson-safely)). Every field, type and
default is listed in [agent/configuration.md](agent/configuration.md).

### App settings (phone)

These live in the phone's profile (export/import as `.tiphys.json`), not on any agent:

| Screen | Contents |
|---|---|
| *Hosts* | name, ID, colour, address, SSH (user, port, key/password, tmux session, Compose folders), agent address and token, Wake-on-LAN (MAC, send from), tags; link to *Agent settings* |
| *Keys & secrets* | SSH keys, API tokens, passwords (Android Keystore) |
| *Claude* | agent that runs Claude, model, thinking effort, permission mode, profiles, favourite folders, pinned slash commands |
| *Integrations* | Grafana (several), Dozzle (several), Homepage host, Uptime Kuma host and defaults, ntfy topics, Scriberr language/model, Obsidian vault/folder/daily note |
| *Terminal* | font size, extra keys bar, snippets (one per line: name, command, optional host) |
| *Files* | bookmarks (`host:path`), hidden files |
| *Quick actions* | your own one-tap commands, optional confirmation |
| *Notifications* | push on/off, distributor, test, per-category switches, long-command threshold, clipboard sync |
| *App controls* | custom live-screen buttons per app |
| *Home screen* | layout, cards, shortcuts |
| *Appearance* | theme, language (English/Turkish) |
| *Security* | PIN, fingerprint, auto-lock |
| *Profile file* | export (plain/encrypted), import (merge/replace), reset |

### Where files live

| Machine | Path | Mode | Contents |
|---|---|---|---|
| every agent | `~/.config/tiphys/` | `0700` | config directory (`TIPHYS_AGENT_CONFIG` moves it) |
| every agent | `agent.json` | `0600` | configuration, device and service-token **hashes**, secrets (bot token, ntfy/Grafana tokens, Uptime Kuma/Sunshine passwords, research token) |
| every agent | `events.jsonl`, `audit.jsonl` (+ `.1`) | `0600` | event and audit logs, rotated at 2 MB / 1 MB |
| every agent | `agent-runs.json` | `0600` | start/stop records (unexpected-restart detection) |
| `claude` | `claude-sessions.json`, `claude-schedules.json`, `claude-shots/` | `0600` | sessions, schedules, PC-session screenshots (last 60) |
| `desktop` | `control-indicator.json`, `a11y-state.json` | `0600` | values to restore after a crash |
| `telegram` | `telegram-state.json` | `0600` | recipients, invites, feeds, archive (no tokens) |
| `research` | `research-jobs.json`; work dirs in `$XDG_RUNTIME_DIR/tiphys/research/` | `0600` / `0700` | last 24 h of jobs |
| PC | `~/.config/systemd/user/tiphys-agent.service` (+ `.d/` drop-in) | | the unit |
| server | `~/tiphys-agent/` | | deployed `dist/`, `helpers/`, `node_modules/` |
| PC (bridge) | `~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json`, `~/.local/share/tiphys/firefox-host`, `$XDG_RUNTIME_DIR/tiphys/firefox.sock` | `0644` / `0755` / `0600` | Firefox bridge |
| PC (VS Code) | `~/.local/share/applications/com.visualstudio.code.desktop` | | from `vscode-a11y install` |
| build PC | `~/.config/tiphys/release/` (`key.properties`, `*.jks`) | `0700` dir | APK signing key |
| build PC | `~/opt/` (`tiphys-env.sh`) | | toolchain from `setup-dev.sh` |
| phone | Android Keystore-backed storage | | tokens, keys, passwords, vault |

Logs go to the user journal (`journalctl --user -u tiphys-agent`).

### Backing up and restoring

- **Agents**: back up `~/.config/tiphys/` on each machine (it holds secrets: store the backup encrypted). Restoring
  it, with the agent stopped, brings back devices (the phone's tokens keep working), service tokens, push endpoints,
  sections, Claude sessions/schedules and Telegram state. Also keep your unit file and drop-ins. Claude Code's own
  data is in `~/.claude*`.
- **Signing key**: back up `~/.config/tiphys/release/` separately and off the machine. It cannot be recreated.
- **Phone**: *Settings › Profile file › Export › Encrypted backup*. On a new phone, install Tiphys, import with
  **Replace all**, then turn notifications on again.
- **Firefox bridge, VS Code launcher, Tailscale serve**: re-create with the commands above; they hold no state.

## 12. Security checklist

Off by default on a new `agent.json`: everything except `system`, `services`, `docker` and `power`. Go through this
list on every new install:

- [ ] The agent listens on `127.0.0.1` (`listen.host`) and is published only with `tailscale serve`. Never bind it to
      a LAN or public address: the Tailscale login check relies on the header that `tailscale serve` sets.
- [ ] `--tailscale-login you@example.com` is set on each agent (mind tagged servers, see [Research](#research-pc)),
      and Tailscale ACLs limit who can reach port 7443.
- [ ] Only the features this machine needs are on. Servers: no `claude`, `desktop`, `control`. Consider turning
      `power` off where a remote power-off would hurt.
- [ ] `allowedRoots` is narrowed if you don't want Claude and git to reach your whole home directory.
- [ ] `control` is on only on the PC you sit at; the phone has an app lock (required for control sessions).
- [ ] Sunshine is not enabled at boot; old Moonlight clients are unpaired.
- [ ] The Firefox bridge runs in ESR/Developer/Nightly with signature checks off **only** in that profile.
- [ ] Tokens and keys are not in git: `agent.json` lives outside the repository; `key.properties`, `*.jks`,
      `*.keystore`, `*.env` and `*.local.json` are git-ignored. Don't paste pairing QR codes or tokens into chats or
      screenshots.
- [ ] `~/.config/tiphys/` is `0700` and its files `0600` (`ls -la ~/.config/tiphys`).
- [ ] Pairing used `--url` with the HTTPS tailnet name.

Read [security.md](security.md) for the full threat model.

### Rotating tokens and secrets

| Secret | Rotate |
|---|---|
| Phone device token | revoke the device (app: immediately; CLI: then restart), pair again. Lost phone: revoke it at once, or *Lock everything*. |
| Service token (research) | app: *Research* screen › revoke, then *Connect to a Telegram agent* again. CLI: `service-token revoke <id>` + restart, create a new one, update `research.token` on the Telegram agent. |
| Telegram bot token | in @BotFather: `/revoke` (choose the bot) to get a new token, then *Telegram › Replace bot token* in the app. The old token stops working immediately. |
| ntfy publish token | create a new token on the ntfy server, put it into `push.token` on each agent (stop/edit/start), then delete the old token on the server. |
| Grafana service account token | create a new token in Grafana, enter it in *Agent settings › Grafana alerts* (and *Settings › Integrations › Grafana*), delete the old one. |
| Uptime Kuma / Sunshine passwords | change them in the service, then enter the new ones in *Agent settings*. |
| Everything on one agent | *Lock everything* revokes all devices, all service tokens and all push endpoints. Then pair again, reconnect research and re-enable notifications. |
| APK signing key | cannot be rotated in place; a new key means uninstalling the app (export an encrypted profile first). |

## 13. Troubleshooting

Start with:

```sh
systemctl --user status tiphys-agent
journalctl --user -u tiphys-agent -n 100
curl -s https://argo.my-tailnet.ts.net:7443/v1/health
tailscale serve status
```

Most problems are covered in [troubleshooting.md](troubleshooting.md); error codes are listed in
[agent/api.md › Errors](agent/api.md#errors). Setup problems that are easy to hit:

| Symptom / code | Cause and fix |
|---|---|
| New phone rejected right after `pair` (`agent.auth.invalidToken`) | The agent was not restarted after the CLI wrote `agent.json`. Use `tools/pair.sh` or restart. |
| Revoked device still works / CLI change disappeared | The running agent kept its copy and wrote it back. Restart after CLI commands; stop the agent before hand edits ([details](#changing-agentjson-safely)). |
| Agent does not start after a hand edit | Look for the zod validation error in the journal; fix the field. |
| QR points to `http://127.0.0.1:7443` | Paired without `--url`. Pair again with the HTTPS tailnet URL, or fix *Agent address*. |
| "Secure connection failed" | HTTPS certificates or MagicDNS not enabled, or an IP address instead of the `*.ts.net` name. |
| Feature missing after enabling it (`agent.route.notFound`) | Restart the agent. On servers, a later `deploy-agent.sh` run with a shorter list turned it off again. |
| `agent.config.passwordRequired` on save | You changed a URL (Uptime Kuma, Sunshine, Grafana, research) without re-entering its secret. |
| `deploy-agent.sh` stops at `sudo` | The server needs passwordless sudo for those steps, or run them by hand first. |
| Agent fails with a syntax/engine error on a server | Node.js older than 22 (often the distribution's `nodejs`). Install Node.js 22+. |
| Claude sessions fail on a server | The deploy omits the Claude Code binary; run Claude on the PC agent. |
| `agent.research.toolMissing` | `agy` or `claude` not on the service's `PATH`; add the [drop-in](#environment-drop-in). |
| `agent.research.mcpMissing` | No `searxng`/`firecrawl` entry in `~/.claude.json` (`claude mcp add --scope user …`). |
| `agent.research.toolFailed`, `invalidOutput` | A tool needed approval it was not given, is not logged in, or produced no valid result; run `agy` / `claude` once by hand as the agent's user. |
| `agent.research.busy` | One job runs and 5 wait; try later. |
| `agent.telegram.research.notConfigured` | No `research` link on the Telegram agent; use *Connect to a Telegram agent*. |
| `agent.telegram.research.unreachable` / `telegram.pcUnreachable` | PC off or URL without `:7443`. Add a wake target and `wakeHostId`, raise `deadlineMinutes`, enable lingering on the PC. |
| `agent.telegram.research.unauthorized` | Service token revoked, or the PC's Tailscale login check rejects a tagged server. |
| `agent.telegram.invalidToken` | The pasted bot token is wrong or was revoked in @BotFather. |
| `agent.telegram.noRecipients` | No active subscriber for that feed. |
| `agent.uptime.notConnected` | Wrong Uptime Kuma URL/login, or the agent was not restarted after setting it. |
| `agent.homepage.fileNotFound` | Wrong `services.yaml` path in *Agent settings › Homepage*. |
| `agent.ports.shareFailed` | Run `sudo tailscale set --operator=$USER`. |
| `agent.services.permissionDenied` | System units need polkit permission; user units always work. |
| Clicks/keys do nothing (`agent.desktop.inputFailed`) | `ydotoold` not running or socket path differs; see [ydotoold](#desktop-tools-pc-only-for-desktop-and-control). |
| Release APK will not install over the old one | Different signing key (often the debug key because `key.properties` was missing). [Verify the signature](#verify-the-signature). |
| The desktop freezes during the APK build | Use `tools/limited.sh`. |
