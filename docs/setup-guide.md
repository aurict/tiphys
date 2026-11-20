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

4. Optional: use Tailscale ACLs/grants to limit which of your devices may reach port 7443. Example in
   [Security › Network exposure](security.md#network-exposure); Headscale notes are there too.

### Node.js (every agent machine)

Not needed with the one-command installer (the release bundle carries Node.js 24). From a checkout, the agent
needs **Node.js 22 or newer** (`engines` in `agent/package.json`); CI and development use Node.js 24.

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
| `agy` (Antigravity CLI, Gemini) on the agent's `PATH` | `agy` feature (sessions), `research` feature (draft step) | Log in once interactively. |
| `npx` | `research` feature | Starts the pinned searxng/firecrawl MCP servers for the editor. Comes with Node.js. |
| a searxng instance and a Firecrawl instance or API key | `research` feature | Reached through the `searxng` and `firecrawl` MCP servers. |
| a transcription command | `transcribe` feature | Your own script, see [Transcription](#transcription). |

### Build machine (for the app and the Firefox extension)

Flutter 3.47.9 (stable), JDK 17, Android SDK platform 36 and build-tools 36.0.0, on x86-64 Linux.
`tools/setup-dev.sh` installs exactly these without sudo (see [section 6](#6-build-and-install-the-app)). The
Firefox extension build needs only Node.js.

## 3. Agent on the PC

### One-command install (recommended)

```sh
curl -fsSL https://raw.githubusercontent.com/aurict/tiphys/main/install.sh | sh
```

Windows (PowerShell, no administrator rights needed):
`irm https://raw.githubusercontent.com/aurict/tiphys/main/install.ps1 | iex`.

The installer downloads the newest release for your OS and CPU (Linux and macOS on x64/arm64, Windows x64; the
bundle carries its own Node.js 24), **verifies its ed25519 signature and SHA-256** (needs `openssl`; see
[Security › Releases](security.md#releases-installer-and-self-update)), installs it to
`~/.local/share/tiphys-agent/versions/<version>` with a `current` link and a `tiphys-agent` command in
`~/.local/bin`, creates a systemd user service (macOS: a LaunchAgent; Windows: a logon entry with a restart loop),
runs `tiphys-agent init --detect`, publishes the agent with `tailscale serve` (asks for `sudo` once on Linux, or
prints the command), and shows the pairing QR code.

| Option | Meaning |
|---|---|
| `--version X.Y.Z` | A specific release instead of the newest |
| `--name NAME` | Agent name (first install only; default: host name) |
| `--no-service` / `--no-serve` / `--no-pair` | Skip that step |
| `--uninstall [--purge]` | Remove service and program files; `--purge` also deletes `~/.config/tiphys` |
| `--insecure-skip-signature` | Install although the signature can't be checked. Read [what this means](security.md#releases-installer-and-self-update) first |

Pass options with `curl … | sh -s -- --version 0.4.0`. Re-running the installer updates; settings and paired
devices are kept, and features are not changed on updates. When systemd user services are not available (a
container, a plain `su` session) the service step is skipped with a message; start the agent with
`tiphys-agent serve`. On servers, keep it running after logout with `sudo loginctl enable-linger $USER`.

Afterwards: `tiphys-agent doctor` checks everything (Tailscale, `tailscale serve`, the service, permissions, tools
for enabled features) and prints a fix for each problem. Turn on more features with
`tiphys-agent init --features claude,control` and `systemctl --user restart tiphys-agent`. Other install paths
(`.deb`/`.rpm`, AUR, Homebrew, Docker for servers): [packaging/README.md](../packaging/README.md).

Updates: re-run the installer, or let the agent update itself from the app (`update` feature, on by default for
installs made this way; signed releases only, see [api.md › Self-update](agent/api.md#self-update)).

The rest of this section is the manual path from a git checkout (needed for development and for features that are
not in the release bundles yet, such as the Firefox extension).

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
node dist/cli.js init --name argo --detect --features git,claude
```

- `init` creates `~/.config/tiphys/agent.json` (directory `0700`, file `0600`) or updates an existing one. The path
  can be changed with `--config PATH` or `TIPHYS_AGENT_CONFIG`.
- `--name NAME`: the name shown in the app and in notifications (default: the hostname on first creation).
- `--detect`: turns on the safe features this machine supports (`system`, `services`, `docker` if the socket is
  usable, `git`, `desktop` in a desktop session, `ports`, `transcribe` if configured) and prints risky ones
  (`claude`, `control`, `power`, …) as suggestions instead of enabling them.
  See [init and feature lists](agent/configuration.md#init-and-feature-lists).
- `--features a,b,c`: turns these on and **keeps** everything else. (Before this release it was an exact list that
  turned every other flag off.) `--set-features a,b,c` is the exact list; `--disable a,b` turns flags off.
  A brand-new file without any of these gets `system`, `services`, `docker` and `power` on and everything else off
  (with `--detect`: only what was detected).
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
| `features` | comma-separated feature list: the exact list on the first install (`init --set-features`), **added** on later runs (`init --features`); `TIPHYS_EXACT_FEATURES=1` makes it exact again |
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
3. on later runs, runs `init --name NAME --features FEATURES`, which **adds** your list and keeps features you turned
   on from the app (with `TIPHYS_EXACT_FEATURES=1`: `--set-features`, exactly your list);
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

Re-run the script to update the agent. Your list is **added** to the current features, so features turned on from
the app stay on. To turn one off, use the app or
`ssh user@atlas 'cd ~/tiphys-agent && node dist/cli.js init --disable FEATURE'`. To make the list exact again, set
`TIPHYS_EXACT_FEATURES=1` and list every feature you want to keep. Check the current set first:

```sh
curl -s https://atlas.my-tailnet.ts.net:7443/v1/health \
  | jq -r '.features | to_entries | map(select(.value).key) | join(",")'
# e.g. system,services,docker,power,watch,alerts,backups,telegram
```

With `TIPHYS_EXACT_FEATURES=1`, paste that list (plus or minus what you want to change) as the third argument:

```sh
TIPHYS_EXACT_FEATURES=1 tools/deploy-agent.sh user@atlas atlas system,services,docker,power,watch,alerts,backups,telegram ~/.ssh/id_ed25519
```

A server can also use the one-command installer instead (it brings its own Node.js and can update itself).

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
| `init [--name N] [--detect] [--features a,b] [--set-features a,b] [--disable a,b] [--tailscale-login L]` | Create or update `agent.json`. `--features` adds, `--set-features` is exact, `--detect` enables safe detected features. |
| `pair --name "Phone" [--url https://argo.my-tailnet.ts.net:7443]` | Add a device, print the QR code and the one-time token. Without `--url` the address comes from Tailscale. |
| `doctor [--json]` | Check the install and print a fix for each problem; exit code 1 if something fails. |
| `devices` | List paired devices (`id`, `name`, `createdAt`). |
| `revoke <device-id>` | Remove a device and its push endpoint. |
| `service-token create --name atlas --scope research` | Create a scoped token (`tps_…`), printed once. Scopes: `research`, `analysis`, `security-report`. |
| `service-token list` / `service-token revoke <id>` | List / revoke service tokens. |
| `run -- CMD [ARGS…]` | Run a command and send a "done/failed" push when it ends. |
| `firefox install` | Register the Firefox native-messaging host (PC). |
| `vscode-a11y install` / `remove` | Make Flatpak VS Code expose its accessibility tree (PC). |
| `schema` | Print the JSON Schema of the app's `.tiphys.json` profile (not of `agent.json`). |

Full reference: [agent/configuration.md › CLI](agent/configuration.md#cli).

### Changing agent.json safely

The running agent keeps `agent.json` in memory and **re-reads it when another process changes it** (a file
watcher, and a re-read before rejecting an unknown token). Before it writes the file itself (the phone saves
settings, a service token is used, …) it first picks up such changes, so a CLI change is not overwritten. So:

- `pair`, `revoke` and `service-token create|revoke` take effect **without a restart** (within about a second).
  `pair` checks that the running agent accepts the new device and tells you if it does not (an agent from before
  this change: restart it once).
- **Feature changes** made with `init` still need `systemctl --user restart tiphys-agent`, like other settings
  that are read at start ([section 11](#11-settings-reference)).
- An invalid file is ignored by the running agent (it keeps the old settings) but stops the next start. When
  editing by hand, it is still safest to stop the agent first, edit, check the JSON, start it again:

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

Servers: re-run `tools/deploy-agent.sh` from the updated checkout
([above](#updating-and-changing-features-on-a-server)).

Installed with `install.sh` / `install.ps1`: run the installer again, or update from the app (*agent settings ›
update*, `POST /v1/update/apply`; needs the `update` feature). Package installs update with their package manager.

App: rebuild and install over the existing app with the same signing key ([section 6](#6-build-and-install-the-app)).

### Uninstalling

Installed with `install.sh`: `curl -fsSL https://raw.githubusercontent.com/aurict/tiphys/main/install.sh | sh -s -- --uninstall`
(add `--purge` to delete `~/.config/tiphys` too), then `tailscale serve --https=7443 off`. Windows:
`install.ps1 -Uninstall`. From a checkout:

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
tools/pair.sh local       [agent-url|auto] [device-name]              agent on this machine
tools/pair.sh <ssh-target> [agent-url|auto] [device-name] [ssh-key]   agent in ~/tiphys-agent on a server
```

```sh
tools/pair.sh local
tools/pair.sh user@atlas https://atlas.my-tailnet.ts.net:7443 Phone ~/.ssh/id_ed25519
```

The script runs `pair --name NAME [--url URL]`. The running agent accepts the new token without a restart; the
script no longer restarts it. If the agent on that machine predates this change, the CLI says it did not confirm
the device: restart it once (`systemctl --user restart tiphys-agent`). The device name defaults to `Phone`.

### With the CLI directly

```sh
tiphys-agent pair --name "Phone"                                   # install.sh installs
node dist/cli.js pair --name "Phone" --url https://argo.my-tailnet.ts.net:7443
```

Without `--url`, the address is `https://<MagicDNS name of this machine>:<port>`, where the port is the
`tailscale serve` HTTPS port that forwards to the agent (7443 if there is none yet; the command to create it is
printed). If Tailscale is not installed, not running or has no DNS name, `pair` stops and asks for `--url`. Pass
`--url` when the phone should use another name (e.g. Headscale, a custom domain).

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
| Agent CLI | `node dist/cli.js devices`, then `node dist/cli.js revoke <device-id>` (the running agent picks it up within about a second) |
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
| `agy` | off | Antigravity CLI (`agy`) sessions from the phone over its Agent Client Protocol; resume earlier conversations | `agy` installed and logged in on the PC, `allowedRoots` | high |
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
| `security` | off | security audit of this machine, SSH-only hosts and other agents: findings, score, baseline changes, firewall evaluation, notifications, incident link | `ss`, `ssh` (SSH hosts), root-owned `audit.sh` + passwordless sudo for the agent user for a root-level audit | low |

Risk is a guide to what a holder of a device token can do: **low** = read-only or notification only, **medium** =
narrow state changes, **high** = run code, change files, cut power or drive the desktop.

**Restart.** Every flag change needs an agent restart, with one exception: turning `control` **off** takes effect
immediately and ends any open control session. Restart after turning it on as well, as the app tells you.

How to change flags:

- **App:** *Settings › Hosts › (host) › Agent settings › Features*, toggle, **Save**, then restart the agent. The
  app shows *Saved. Restart the agent to apply feature changes.* You can restart from a terminal on the phone
  (`systemctl --user restart tiphys-agent` over SSH).
- **CLI:** `tiphys-agent init --features a,b` (adds) or `--disable a,b` (turns off), then restart.
  `--set-features <complete list>` turns everything not listed off.
- **Servers:** the app, or re-run `tools/deploy-agent.sh` (adds the listed features).

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

### agy (Antigravity CLI)

Agent side (`argo`):

1. Install `agy` on the PC so that it is on the `PATH` of the agent's service (check `systemctl --user show
   tiphys-agent -p Environment`, or the unit's `PATH`; a login shell's `PATH` is not enough), and **log in once** as
   the agent's user: run `agy` in a terminal and sign in. Check with `agy --version`.
2. Turn on `agy` (it is a high-risk flag, like `claude`: a session runs code on the PC; leave it off on servers) and
   restart. Nothing runs until a session is started; each session is one `agy acp` process, at most 6 at a time.
3. **Allowed folders** (`allowedRoots`) apply as for Claude: a session's folder, and the folder you list earlier
   conversations for, must be inside them. Narrow them if you want agy confined to, for example, `~/code` as the place
   it starts in (agy itself can still reach anything the agent's user can).
4. Start a session in the app, or with `POST /v1/agy/sessions {"cwd": "~/code/my-project"}`. Pick the mode: `default`
   asks for edits and commands, `accept-edits`, `auto` and `plan` ask less or plan first (see
   [agy](features/agy.md#modes)). `--dangerously-skip-permissions` is never used. Permission questions come to the
   phone and as notifications.
5. To carry on in a terminal on the PC, **close the session on the phone first**, then run the session's
   `resumeCommand`, `cd <folder> && agy --conversation <id>`. A conversation open in a terminal and on the phone at
   the same time forks.

Troubleshooting: `agent.agy.missing` (501): `agy` is not on the agent's `PATH`. A session that ends at once: run
`agy acp` by hand as the agent's user to see why (for example, not logged in). Details:
[features/agy.md](features/agy.md).

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

### Security center

The security center audits machines read-only and shows score, findings and changes in the app (what it checks and
how: [features/security.md](features/security.md)). One agent is the **monitoring server** (`atlas`): it collects
the reports of its own machine, of SSH-only hosts and of other agents. Do these parts as needed: a to c are the audit
itself; d to h (scanners, traps, black box, lost phone, outside view and Cloudflare) are optional additions, each off
until you set it up. The checkout
(`~/tiphys`) must be the same release as the agents: the installed audit script is copied from it.

#### a. The monitoring server (`atlas`)

1. Turn on `security` on `atlas` and restart the agent. Open *System › Security* in the app (Turkish UI: *Sistem ›
   Güvenlik*): `atlas` is listed as *This machine*. The first check runs about 30 seconds after the start and the
   first good report becomes the baseline silently. Set its role (`server` or `desktop`) and the ports that are
   meant to be open (*Audit settings › Expected open ports*, e.g. `tcp/22`).
2. This already works without root, but some sections are then unavailable (the host firewall, password status,
   sudoers, SUID, other users' keys). For the **root-level audit** of `atlas` itself, install the script as a
   root-owned file, outside anything the agent user can write. The agent user on `atlas` already has passwordless
   sudo (as `tools/deploy-agent.sh` needs), so no extra sudoers entry is required:

   ```bash
   # on atlas, from the deployed agent (tools/deploy-agent.sh puts helpers/ in ~/tiphys-agent)
   sudo install -d -o root -g root -m 0755 /usr/local/lib/tiphys
   sudo install -o root -g root -m 0755 ~/tiphys-agent/helpers/audit.sh /usr/local/lib/tiphys/audit.sh
   ```

   Then turn on **Check with sudo** (*Audit settings › This machine*),
   or `PATCH /v1/security/hosts/self {"sudo": true}`, or `"security": {"self": {"sudo": true}}` in `agent.json`.
   The next report is a root report, so it starts a **new baseline** silently (when changes are still waiting for
   acceptance, the switch is listed as one more change, `audit.root`, and the old baseline stays until you accept).

   **Why the agent's own copy is never run with sudo:** `~/tiphys-agent/helpers/audit.sh` belongs to the agent's
   user, who could change it; running a file the agent user can write as root would hand that user (and anything
   that compromises the agent) root. The agent therefore runs only `/usr/local/lib/tiphys/audit.sh`, and before every
   run checks that it is a regular file owned by root and not writable by group or others
   (`agent.security.scriptMissing` / `scriptUnsafe` otherwise). Copy it again after every upgrade of the agent
   (step 2's `install` line) so the installed script and the parser stay in step.

#### b. A host without an agent (`orion`)

The monitoring server logs in with a restricted key that can only run the audit script (design:
[security.md](security.md#security-center-audit-key)). You need an admin login with passwordless `sudo` on `orion`
once, for the installation; `atlas` and `orion` must both be in your tailnet.

1. **Key** (on `atlas`, as the agent user; no passphrase, because the agent connects non-interactively):

   ```bash
   ssh-keygen -t ed25519 -N '' -C tiphys-audit -f ~/.config/tiphys/security-audit-key
   chmod 600 ~/.config/tiphys/security-audit-key
   tailscale ip -4        # atlas's Tailscale address: the only address the key will be accepted from
   ```

   Copy `security-audit-key.pub` to the machine you install from.
2. **Install** (from the checkout on `argo`, which has the script and the installer):

   ```bash
   cd ~/tiphys
   tools/install-audit.sh admin@orion.my-tailnet.ts.net <atlas-tailscale-ip> ~/security-audit-key.pub [admin-key]
   ```

   `admin@…` is the admin login with passwordless sudo; `[admin-key]` is its private key if it isn't the default.
   The script installs `/usr/local/lib/tiphys/audit.sh` (hash-checked), the user `tiphys-audit` (locked password, no
   groups, not in `docker`), a sudoers entry for that one script, a root-owned `authorized_keys` with
   `restrict,from="<atlas IP>",command="sudo -n …"`, and, only if sshd already uses `AllowUsers`, a drop-in
   `/etc/ssh/sshd_config.d/05-tiphys-audit.conf` that adds the user (`sshd -t` must pass before the reload). The
   sudoers entry has no `Defaults` lines, so it also works with `sudo-rs`. Re-run it to update the script after an
   upgrade; an installed script from before the scanners and traps (`VERSION=1`) has no `traps` and `image-save`
   requests, so install again before using parts d and e on that host. The current script is `VERSION=3` (file names
   in the SUID list can no longer inject report lines, logins are taken only from `sshd`, traps cover the last 10
   minutes): install again on every audited host after an upgrade. It prints `installed <sha256>` on success.
3. **Pin the host key** (no trust on first use). `atlas` will connect with `StrictHostKeyChecking=yes` and a file
   that only you fill. On `atlas`:

   ```bash
   ssh-keyscan -t ed25519 orion.my-tailnet.ts.net > /tmp/orion.key      # -p PORT for a non-standard port
   ssh-keygen -lf /tmp/orion.key                                        # note the SHA256:… fingerprint
   ```

   On `orion`, over a channel you trust (your own admin session, the console):

   ```bash
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

   Only if the two fingerprints are identical:

   ```bash
   cat /tmp/orion.key >> ~/.config/tiphys/security-known-hosts && chmod 600 ~/.config/tiphys/security-known-hosts
   rm /tmp/orion.key
   ```

   The name in the file must be the one you give as the SSH address in step 4 (for a non-standard port the entry
   reads `[host]:port`). Without the file the check fails with `agent.security.knownHostsMissing`; with a wrong or
   changed key the SSH check fails (`agent.security.sshFailed`).
4. **Add the host** in the app (*Security › Audit settings › Add machine*: ID `orion`, name, source *SSH*, address
   `orion.my-tailnet.ts.net`, user `tiphys-audit`, port, key file `~/.config/tiphys/security-audit-key`), or:

   ```bash
   curl -sS -X POST https://atlas.my-tailnet.ts.net/v1/security/hosts \
     -H "Authorization: Bearer tph_…" -H 'content-type: application/json' \
     -d '{"id":"orion","name":"orion","role":"server","source":{"kind":"ssh","host":"orion.my-tailnet.ts.net","user":"tiphys-audit","port":22,"keyPath":"~/.config/tiphys/security-audit-key"}}'
   ```

   Press *Check now* on the machine's screen: a first report within a minute or so. Test the restriction from `atlas`
   if you like: `ssh -i ~/.config/tiphys/security-audit-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o
   UserKnownHostsFile=~/.config/tiphys/security-known-hosts tiphys-audit@orion.my-tailnet.ts.net id` must **not**
   print an id (the script answers `tiphys-audit: unsupported request`).
5. **Remove** it: `tools/install-audit.sh --uninstall admin@orion.my-tailnet.ts.net [admin-key]` deletes the sudoers
   entry, the sshd drop-in, the user, its home and `/usr/local/lib/tiphys`; then delete the host in the app and the
   line in `security-known-hosts`.

#### c. Another agent (`argo`)

1. On `argo`: turn on `security` and restart the agent. It needs no root and no setup: it serves its own raw report
   to the monitoring server (`GET /v1/security/raw`). The PC audit is rootless (no firewall ruleset, no password or
   SUID checks).
2. On `argo`, create a service token for `atlas`:

   ```bash
   node dist/cli.js service-token create --name atlas-security --scope security-report   # prints tps_… once
   ```

   then restart the agent (CLI changes apply after a restart). The token can call only `GET /v1/security/raw`.
3. On `atlas`: add `argo` as a machine with source *Agent*: agent URL `https://argo.my-tailnet.ts.net` and the token,
   in the app (*Audit settings › Add machine*) or with `POST /v1/security/hosts` and
   `"source": {"kind": "agent", "url": "https://argo.my-tailnet.ts.net", "token": "tps_…"}`, role `desktop`.
   Expected ports for `argo` are set on `atlas` (they apply to the monitoring server's evaluation).

   When `argo` is off or asleep, its last known state stays (marked stale); the PC is never woken for this. If it
   stays unreachable for 6 hours, a `security.unreachable` notification is sent once.

**Check.** *System › Security* lists `atlas` (and `orion`, `argo`) with a score. Make a harmless change (for example
add a throwaway user or open a test port), wait for the next check or press *Check now*: the machine shows a change,
you get a `security.change` push and an incident of kind *security* opens; *Accept this state* clears it.
Troubleshooting codes are in [Troubleshooting](#13-troubleshooting).

#### d. Vulnerability and secret scanners (`atlas`)

The scanners run Docker containers on `atlas` (the agent user must be allowed to run `docker`, which `atlas` already
needs for the `docker` feature) and are off by default. **Pull nothing by hand**: Docker fetches the pinned Trivy and
gitleaks images the first time they are needed (about 60 MB and 25 MB), and Trivy downloads its vulnerability
database (about 140 MB) into the volume `tiphys-trivy-cache`. The calls below use a device token (`tph_…`) of `atlas`;
the app screens for these features are still being added, the API works regardless.

1. **Enable** the scanners you want. Heavy work happens only in the night window (default 02:00 to 06:00 local):

   ```bash
   curl -sS -X PATCH https://atlas.my-tailnet.ts.net/v1/security/scanners \
     -H "Authorization: Bearer tph_…" -H 'content-type: application/json' \
     -d '{"trivy": true, "gitleaks": true}'
   ```

   Change the window with `{"nightHours": [1, 5]}`. Images of `atlas` itself are scanned from the first night on; an
   image on `orion` that no registry has needs the **current audit script** there (`VERSION=2` or higher; `3` is current): run
   `tools/install-audit.sh` again for `orion` (step b.2) so `image-save` exists. It is the only thing the scanner
   asks `orion` to do beyond the report, and it puts load on that host's Docker daemon, so it happens only at night,
   2 images a night at most, 3 GB each.
2. **Private images.** For a private registry add a **read-only** credential, for example `ghcr.io` with a token that
   has only `read:packages`:

   ```bash
   curl -sS -X PATCH https://atlas.my-tailnet.ts.net/v1/security/scanners \
     -H "Authorization: Bearer tph_…" -H 'content-type: application/json' \
     -d '{"registryAuth": [{"registry": "ghcr.io", "username": "example-user", "token": "ghp_…"}]}'
   ```

   `registryAuth` replaces the whole list; to keep an entry's token, send its `registry` and `username` without a
   `token`. An image that needs a login shows `needsCredentials` with the registry name. Trivy contacts only well-known
   public registries (`docker.io`, `ghcr.io`, `gcr.io`, `quay.io`, `registry.k8s.io`, `public.ecr.aws`,
   `mcr.microsoft.com`, `registry.gitlab.com`, `lscr.io`, `codeberg.org`) and registries you add here; an image from
   any other registry is only scanned if it can be saved locally or over SSH.
3. **Java images.** Trivy skips `*.jar`, `*.war` and `*.ear` files unless you send `{"javaDb": true}`; that
   downloads a database of about 1 GB on the first scan. Without it, a "clean" Java application image says nothing
   about its Java libraries.
4. **GitHub secret scan.** Add the owners to scan (`{"github": {"owners": ["example-org"]}}`). Without a token only
   public repositories are scanned. For private ones create a **fine-grained personal access token** limited to those
   repositories with only `Contents: read` (and the implicit `Metadata: read`), and send it with
   `{"github": {"owners": ["example-org"], "token": "github_pat_…"}}` (to remove it later send `"token": null`).
5. **Logs in Loki.** If the host logs go to a Loki container on `atlas` with a `host` label, send
   `{"loki": {"container": "loki", "port": 3100}}` (the container name from `docker ps`; the agent looks up its address
   each time) or `{"loki": {"url": "http://127.0.0.1:3100"}}`. The same setting is used by the decoy database users
   (part e).
6. **Run once** instead of waiting for the night, and read the result:

   ```bash
   curl -sS -X POST https://atlas.my-tailnet.ts.net/v1/security/vulns/scan   -H "Authorization: Bearer tph_…"
   curl -sS -X POST https://atlas.my-tailnet.ts.net/v1/security/secrets/scan -H "Authorization: Bearer tph_…"
   curl -sS https://atlas.my-tailnet.ts.net/v1/security/vulns   -H "Authorization: Bearer tph_…"
   curl -sS https://atlas.my-tailnet.ts.net/v1/security/secrets -H "Authorization: Bearer tph_…"
   ```

   Both start in the background (`202`). Images need minutes each; `status` goes from `pending` to `ok`, `failed`,
   `needsCredentials` or `notAvailable`. In the secret result, `lastRun` names the error of any source that failed.
7. **The PC scans its own code** without any server: on `argo`, with `security` on, send
   `{"localRoots": ["~/code"]}` to `argo`'s `/v1/security/scanners` (the folder must be inside `allowedRoots`). It looks
   for git-tracked `.env` files and well-known key formats; nothing leaves `argo` but the location, and `argo` sends
   its own `security.secretFound` push.

#### e. Traps and Telegram alerts (`atlas`, `orion`)

1. **Telegram alerts** (optional but recommended, they work when the phone doesn't). Turn on the `telegram` feature
   with a bot and make yourself a recipient ([Telegram newsletters](#telegram-newsletters-server)). Take your
   recipient's `id` from `GET /v1/telegram/recipients`, then:

   ```bash
   curl -sS -X PUT https://atlas.my-tailnet.ts.net/v1/security/alerts \
     -H "Authorization: Bearer tph_…" -H 'content-type: application/json' \
     -d '{"telegramRecipient": "<recipient id>"}'
   curl -sS -X POST https://atlas.my-tailnet.ts.net/v1/security/traps/test -H "Authorization: Bearer tph_…"
   ```

   The second call is the test alarm: a push **and** a Telegram message `🚨 Tiphys güvenlik · atlas · deneme uyarısı`
   must arrive.
2. **Decoy token.** `POST /v1/security/traps/tokens` with `{"name": "backup notes"}` returns a `tps_…` token once.
   Put it where an intruder would look, for example in a note or a `.env.bak` on a server. Anyone who presents it
   gets an ordinary `401` and you get an alarm. Test: `curl -H "Authorization: Bearer <the decoy>"
   https://atlas.my-tailnet.ts.net/v1/security/overview` (a `401`, and the alarm within seconds).
3. **Decoy database user** (needs the Loki setting of part d.5, and database logs in Loki): choose a name that exists
   nowhere, for example `{"users": ["svc_pgbackup"]}`, with `PUT /v1/security/traps/db-users`. Do this **before** the
   next step so the decoy `.env` contains that user.
4. **Decoy file on `atlas`**: `POST /v1/security/traps/files` with `{"path": "~/backup/.env.bak", "kind": "env"}`
   (inside `allowedRoots`; `kind: "sshkey"` for a decoy private key). Check `GET /v1/security/traps`: the file's
   `status` must be `armed`. `noatime` means the file system never updates access times and the trap can't work:
   pick another location. Read the file yourself once (`cat`) and the alarm comes within 30 seconds. Don't put it
   in a folder your backup tool reads.
5. **Decoy file on `orion`** (an SSH-only host, with `auditd` installed there). Write something that looks like a
   secret but isn't, then, from the checkout:

   ```bash
   printf 'DATABASE_URL=postgres://svc_pgbackup:not-a-real-password@db:5432/app\n' > /tmp/decoy.txt
   tools/install-audit.sh --trap admin@orion.my-tailnet.ts.net /srv/backup/.env.bak /tmp/decoy.txt [admin-key]
   curl -sS -X PATCH https://atlas.my-tailnet.ts.net/v1/security/hosts/orion \
     -H "Authorization: Bearer tph_…" -H 'content-type: application/json' -d '{"traps": true}'
   ```

   (The audit script on `orion` must be `VERSION=2` or higher, `3` is current: part b.2, "install again".) The
   installer refuses to continue when the path already exists or is a symlink, or when a directory on the way is a
   symlink, belongs to a user other than root or you (the admin running it), or is writable by group or others; missing
   directories are created and an existing one keeps its mode. Read the file on `orion` once and an alarm with the
   reader's user and program arrives within about a minute (one alarm per poll, with a count, however many reads). A
   missing `auditd` or `ausearch` no longer fails silently: `GET /v1/security/traps` shows the host under `auditHosts`
   with status `unavailable`. Still test it. Remove it with `tools/install-audit.sh --untrap
   admin@orion.my-tailnet.ts.net /srv/backup/.env.bak [admin-key]` (rule and file).

#### f. Black box (`atlas` and `argo`)

1. **On `atlas`**: `PUT /v1/blackbox/settings` with `{"mode": "local"}` and **restart the agent** (the answer says
   `restartRequired: true`). `GET /v1/blackbox/status` then shows the `head` (record count and hash), and
   `GET /v1/blackbox/verify` must say `ok: true`. The chain is `~/.config/tiphys/blackbox/chain.jsonl`.
2. **Optional hardening (root, once).** Make the file append-only so not even the agent's user can rewrite it:

   ```bash
   sudo chattr +a ~/.config/tiphys/blackbox/chain.jsonl
   ```

   This is **not on by default** and Tiphys doesn't do it for you; undo it with `chattr -a`. A file with the flag
   can't be deleted or replaced without root (the chain isn't rotated, so it only grows).
3. **Nightly anchor.** With the alerts of part e.1 set up, the head of the chain goes to your Telegram every night
   at 03:xx and into `blackbox/anchors.jsonl`. Try it at once with `POST /v1/blackbox/anchor`. Verification checks every
   anchor against the whole chain, and an anchor past the chain's end counts as a cut. The chain stops growing at
   1 GiB (you get `blackbox.broken` with reason `full`); `blackbox/head.json` next to it lets the agent notice after a
   restart that the chain was cut while it was stopped, so keep the three files together.
4. **The PC (`argo`) pushes its records to `atlas`.** On `atlas` create a token only for that:

   ```bash
   node dist/cli.js service-token create --name argo-blackbox --scope blackbox     # on atlas; prints tps_… once
   ```

   restart `atlas`'s agent (CLI changes apply after a restart), then on `argo`:

   ```bash
   curl -sS -X PUT https://argo.my-tailnet.ts.net/v1/blackbox/settings \
     -H "Authorization: Bearer tph_…" -H 'content-type: application/json' \
     -d '{"mode": "push", "url": "https://atlas.my-tailnet.ts.net", "token": "tps_…"}'
   ```

   and restart `argo`'s agent. `GET /v1/blackbox/status` on `argo` shows `pending` (queued records, normally 0) and
   `lastError` (`null` when it works). Records from `argo` appear on `atlas` with `source: "service:argo-blackbox"`
   (`GET /v1/blackbox/recent`).

#### g. Lost phone: recovery code and lockdown

1. **Create the code** on `atlas`: in the app, or `POST /v1/security/recovery` with `{"confirm": true}`. The answer
   shows `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX` **once**. Store it somewhere that does not depend on the phone (a password
   manager, a printout in a safe place). It replaces any earlier code.
2. **Let `atlas` lock the other agents too.** On `argo` create a token that can only lock `argo`, and give it to
   `atlas`:

   ```bash
   node dist/cli.js service-token create --name atlas-lockdown --scope lockdown      # on argo; prints tps_… once
   # restart argo's agent, then:
   curl -sS -X POST https://atlas.my-tailnet.ts.net/v1/security/lockdown/targets \
     -H "Authorization: Bearer tph_…" -H 'content-type: application/json' \
     -d '{"id": "argo", "name": "argo", "url": "https://argo.my-tailnet.ts.net", "token": "tps_…"}'
   ```

   An SSH-only host like `orion` has no agent to lock; its audit key is revoked with `tools/install-audit.sh
   --uninstall`.
3. **If the phone is lost**, from any machine in the tailnet that has the agent built:

   ```bash
   node dist/cli.js lockdown --url https://atlas.my-tailnet.ts.net      # asks for the code (standard input)
   ```

   It prints which agents were locked. Afterwards pair again on each machine (`tiphys-agent pair --name "New phone"
   --url …`, [section 7](#7-pair-the-phone)) and create the service tokens again (`security-report`, `blackbox`,
   `lockdown`, `research`, …): they were revoked too. Make a new recovery code. **Test the whole thing once** on a
   throwaway setup before you rely on it: a lockdown can't be undone except by pairing again. The request must still
   pass the Tailscale-login check (`requireTailscaleLogin`), so run it from a machine whose Tailscale login is the
   allowed one. Wrong or malformed codes are limited (5 well-formed attempts per address per 10 minutes, 30 an hour in
   total); the notice about the lockdown is sent after the revoke, so it arrives in Telegram, not on the lost phone.

#### h. Outside view and Cloudflare attack detection (`atlas`)

1. **Outside view.** List what to look at and turn it on:

   ```bash
   curl -sS -X PUT https://atlas.my-tailnet.ts.net/v1/security/exposure \
     -H "Authorization: Bearer tph_…" -H 'content-type: application/json' \
     -d '{"enabled": true, "targets": [
           {"id": "orion-ip", "kind": "ip", "value": "198.51.100.20", "expectedPorts": [443]},
           {"id": "site", "kind": "domain", "value": "example.org"}]}'
   curl -sS -X POST https://atlas.my-tailnet.ts.net/v1/security/exposure/run -H "Authorization: Bearer tph_…"
   curl -sS https://atlas.my-tailnet.ts.net/v1/security/exposure -H "Authorization: Bearer tph_…"
   ```

   Use the **public address of the other machine**, not the one the server runs on: a machine that connects to its
   own public address may not pass its cloud firewall, so the result would look better than it is. Only list targets
   that are yours. `expectedPorts` are the ports that are meant to be open. The run is gentle (a connect to each of
   about 64 ports, 8 at a time, and one request a second to a domain). If a site redirects (`www` to the bare domain),
   list the bare domain too. The first run only announces critical findings and expiring certificates.
2. **Cloudflare attack detection** (optional). In the Cloudflare dashboard create an **API token** with **Zone › Analytics
   › Read** and **Zone › Zone › Read** for your zones. Then:

   ```bash
   curl -sS -X PUT https://atlas.my-tailnet.ts.net/v1/security/cloudflare \
     -H "Authorization: Bearer tph_…" -H 'content-type: application/json' \
     -d '{"readToken": "…", "zones": ["example.org"], "allowIps": ["203.0.113.10"]}'
   curl -sS -X POST https://atlas.my-tailnet.ts.net/v1/security/attacks/run -H "Authorization: Bearer tph_…"
   ```

   Put your own and your servers' public addresses in `allowIps`. **This part hasn't been checked against the live
   Cloudflare API yet**: run it by hand once and read `GET /v1/security/attacks` (`lastRun.error` is
   `agent.security.cloudflareUnauthorized` for a token problem, `cloudflareFailed` for an API or query problem).
   To block offenders create a **second** token with only **Zone › Firewall Services › Edit** and send
   `{"blockToken": "…", "block": true, "blockHours": 24}`; blocks are IP Access Rules with a `tiphys:<expiry>` note that
   the agent deletes again when they expire. Look at the offenders for a few days before you turn blocking on.

**Check (parts d to h).** Send the test alarm (`POST /v1/security/traps/test`), read a decoy file, present the decoy token: each gives
a high-priority notification (and, with part e.1, a Telegram message).

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
| `security` (role, expected ports, sudo, audited machines) | app: *Security › Audit settings* (`/v1/security/hosts`) or `agent.json` | immediately |
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
| `security` | `security-state.json` | `0600` | last report, findings, baseline and changes per audited machine (no tokens) |
| `security` (SSH hosts) | `security-known-hosts`, `security-audit-key` | `0600` | pinned host keys (you fill it) and the restricted audit key's private half |
| root-level audit | `/usr/local/lib/tiphys/audit.sh` | `0755`, root-owned | the audit script, on `atlas` (with `security.self.sudo`) and on SSH-audited hosts |
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
- [ ] Only the features this machine needs are on. Servers: no `claude`, `agy`, `desktop`, `control`. Consider turning
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
- [ ] Security center: SSH host keys are pinned by hand (fingerprints compared out of band); the audit key is `0600`, used only
      by the monitoring server, and `from=`-restricted to its Tailscale IP; `/usr/local/lib/tiphys/audit.sh` is root-owned
      (`ls -l`) and `security.self.sudo` is on only with that copy; the `security-report` token is held only by the
      monitoring server.
- [ ] Security center, scanners and traps: the GitHub token is fine-grained with `Contents: read` only, for the
      repositories you scan; registry credentials are read-only (`read:packages`); the Cloudflare **read** token has only
      Zone › Analytics › Read and Zone › Zone › Read, and a **block** token (Zone › Firewall Services › Edit) exists only
      if you use blocking, with your own addresses in `allowIps`; `~/.config/tiphys/` stays `0700` (these tokens sit in
      `agent.json`).
- [ ] Security center, black box and lockdown: `security.blackbox.mode` is `local` on the monitoring server and the PC
      pushes with a token of the `blackbox` scope only; `GET /v1/blackbox/verify` says `ok`; the nightly anchor reaches
      Telegram; `chattr +a` on `blackbox/chain.jsonl` is applied if you accepted the root step; a **recovery code** exists,
      is stored outside the phone, and `lockdownTargets` hold `lockdown`-scoped tokens only; the test alarm reached both
      push and Telegram.
- [ ] Security center, outside view: the targets are yours, an `ip` target is the *other* machine's public address, and
      `expectedPorts` match what is meant to be open.

Read [security.md](security.md) for the full threat model.

### Rotating tokens and secrets

| Secret | Rotate |
|---|---|
| Phone device token | revoke the device (app: immediately; CLI: then restart), pair again. Lost phone: revoke it at once, or *Lock everything*. |
| Service token (research) | app: *Research* screen › revoke, then *Connect to a Telegram agent* again. CLI: `service-token revoke <id>` + restart, create a new one, update `research.token` on the Telegram agent. |
| Telegram bot token | in @BotFather: `/revoke` (choose the bot) to get a new token, then *Telegram › Replace bot token* in the app. The old token stops working immediately. |
| SSH audit key (security center) | on the monitoring server: `ssh-keygen` a new key, run `tools/install-audit.sh` again for each host with the new `.pub` (it replaces the root-owned `authorized_keys` line), point the host's key file at the new key, delete the old key. A host whose key may be exposed: `--uninstall`. |
| Service token (`security-report`) | `service-token revoke <id>` on the audited agent + restart, create a new one, enter it in the host's settings on the monitoring server (*Audit settings*). |
| GitHub token (secret scan) | create a new fine-grained token (`Contents: read`), send it with `PATCH /v1/security/scanners {"github": {"owners": […], "token": "…"}}`, delete the old one on GitHub. To stop private scans, send `"token": null`. |
| Registry token (image scan) | create a new read-only token at the registry, send `registryAuth` with the same `registry` and `username` and the new `token`, delete the old token. |
| Cloudflare tokens (attack detection) | create new tokens in the Cloudflare dashboard, `PUT /v1/security/cloudflare` with `readToken` / `blockToken` (`null` removes one), delete the old tokens there. Existing `tiphys:` access rules stay and still expire; the old block token is needed to delete them, so rotate after they expired or remove them by hand. |
| Service tokens (`blackbox`, `lockdown`) | `service-token revoke <id>` on the agent that issued it + restart, create a new one. `blackbox`: enter it as the pushing agent's token (`PUT /v1/blackbox/settings`, then restart). `lockdown`: delete and add the target again on the monitoring server (`/v1/security/lockdown/targets`). A pushing agent whose token is revoked keeps queueing (up to 10 000 records) and delivers after the new token is set. |
| Recovery code | `POST /v1/security/recovery` makes a new one and replaces the old at once (shown once). Do it when the code may have been seen, and after every lockdown you triggered. |
| Decoy tokens | `DELETE /v1/security/traps/tokens/:id` and create another where the old one was planted; a decoy that was used is burnt. |
| ntfy publish token | create a new token on the ntfy server, put it into `push.token` on each agent (stop/edit/start), then delete the old token on the server. |
| Grafana service account token | create a new token in Grafana, enter it in *Agent settings › Grafana alerts* (and *Settings › Integrations › Grafana*), delete the old one. |
| Uptime Kuma / Sunshine passwords | change them in the service, then enter the new ones in *Agent settings*. |
| Everything on one agent | *Lock everything* revokes all devices, all service tokens and all push endpoints. Then pair again, reconnect research and re-enable notifications. The recovery-code lockdown does the same on the monitoring server and on every `lockdownTarget` at once. |
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
| `agent.security.knownHostsMissing` / `agent.security.sshFailed` | No `security-known-hosts` next to `agent.json`, or the host key doesn't match the pinned one (host reinstalled? compare the fingerprint again), the key isn't accepted (`from=` must be the address `atlas` connects from: its Tailscale IP), `orion` is down, or sshd's `AllowUsers` lacks `tiphys-audit`. `params.stderr` has the ssh message. |
| `agent.security.scriptMissing` / `agent.security.scriptUnsafe` | `security.self.sudo` is on but `/usr/local/lib/tiphys/audit.sh` is missing or isn't root-owned and not group/other-writable. Install it as in [Security center](#security-center), or turn *Check with sudo* off. |
| `agent.security.collectFailed` with `sudo: a password is required` in `stderr` | The agent user has no passwordless `sudo` on this machine (`sudo -n` is used). |
| `agent.security.unauthorized` | The `security-report` token of an agent host was revoked, or its Tailscale login check rejects the monitoring server. |
| Image status `needsCredentials` / `notAvailable` / `pending` (`GET /v1/security/vulns`) | `needsCredentials`: add `registryAuth` for the registry named in `error`. `notAvailable` (`noSource`): the image has no registry digest and no save route (an image on another agent). `pending` with `nightOnly` or `saveLimit`: an image of an SSH host is saved only at night, 2 a night. `failed` with `knownHostsMissing`, `sshFailed` or `saveFailed`: the SSH side (pinned key, `audit.sh` still `VERSION=1`: install again). |
| `agent.security.githubUnauthorized` / `lokiUnavailable` / `lokiFailed` in `lastRun` of `GET /v1/security/secrets` | The GitHub token is expired or lacks `Contents: read`; no `scanners.loki` is set, the Loki container isn't running or has no address; Loki returned an error. |
| A decoy file shows `noatime`, or a trap never fires | The file system is mounted `noatime` (move the decoy), the agent was restarted since the last arming (it re-arms within 30 s), or on an SSH host `auditd`/`ausearch` is missing or `audit.sh` is `VERSION=1` (`auditHosts` in `GET /v1/security/traps` shows `unavailable` or `error`; read the decoy yourself to test). |
| `blackbox.broken` push, or `verify` says `ok: false` | `reason` and `brokenAt` say what and where: `hash`/`link`/`sequence` (a record was changed, removed or inserted), `truncated` (the file is shorter than what was written, also detected after a restart through `head.json`), `anchor` (an anchor disagrees with the chain or lies past its end; `anchorMismatch` lists the dates), `full` (the 1 GiB limit was reached; sent once, nothing more is appended). A line that isn't JSON (a crash mid-write) is skipped and counted in `torn` and doesn't make `ok` false. Compare with the anchors in Telegram before you trust the rest; the file is evidence, so copy it before touching anything. |
| `agent.blackbox.notLocal` | The route needs `mode: local`, or the agent was not restarted after `PUT /v1/blackbox/settings` (`restartRequired`). A pusher shows `lastError: "http 401"` when its `blackbox` token was revoked, `"http 409"` when the server is not in `local` mode. |
| `agent.security.badRecoveryCode` / `429` on lockdown | Wrong code (five groups of five, case and dashes don't matter), or no code was ever created (`401`; a malformed code costs nothing against the limits). `429`: 5 well-formed attempts per address per 10 minutes, 30 an hour in total, or another check is running; the counters reset when the agent restarts. A `403 agent.auth.tailnetUserNotAllowed` means the Tailscale-login check rejected the request. |
| `agent.security.cloudflareUnauthorized` / `cloudflareFailed` | The read token is missing a permission or doesn't cover the zone, or Cloudflare's API or GraphQL answered an error (not yet validated against the live API). |
| The outside view reports an open port you know is closed | The server probed its own public address, or a NAT/hairpin route answers locally. A target is probed by the agent it is configured on, so configure the address on an agent that runs on a *different* machine (for example `argo` probing `atlas`'s public address). |
| `agent.uptime.notConnected` | Wrong Uptime Kuma URL/login, or the agent was not restarted after setting it. |
| `agent.homepage.fileNotFound` | Wrong `services.yaml` path in *Agent settings › Homepage*. |
| `agent.ports.shareFailed` | Run `sudo tailscale set --operator=$USER`. |
| `agent.services.permissionDenied` | System units need polkit permission; user units always work. |
| Clicks/keys do nothing (`agent.desktop.inputFailed`) | `ydotoold` not running or socket path differs; see [ydotoold](#desktop-tools-pc-only-for-desktop-and-control). |
| Release APK will not install over the old one | Different signing key (often the debug key because `key.properties` was missing). [Verify the signature](#verify-the-signature). |
| The desktop freezes during the APK build | Use `tools/limited.sh`. |
