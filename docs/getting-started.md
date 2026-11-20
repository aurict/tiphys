# Getting started

The shortest path from a fresh checkout to a phone that controls your PC (`argo` in the examples). Your tailnet is
written as `my-tailnet.ts.net`. Replace these names with your own.

Every step links to the full **[setup guide](setup-guide.md)**, which also covers servers, every feature flag, all
settings, upgrades, backups and the security checklist.

## 1. Tailscale

Install Tailscale on the phone and the PC and log both into the same tailnet. In the admin console (DNS page)
enable **MagicDNS** and **HTTPS Certificates**. Optionally let your user run `tailscale serve` without sudo:

```sh
sudo tailscale set --operator=$USER
```

Details: [setup guide › Prerequisites](setup-guide.md#2-prerequisites).

## 2. Agent on the PC

### The easy way: one command

```sh
curl -fsSL https://raw.githubusercontent.com/aurict/tiphys/main/install.sh | sh
```

Windows (PowerShell): `irm https://raw.githubusercontent.com/aurict/tiphys/main/install.ps1 | iex`

It downloads the newest signed release (with its own Node.js), checks its signature, installs it for your user,
starts it as a service, turns on the features this machine supports (risky ones such as `claude`, `control` and
`power` stay off and are listed as suggestions), publishes it in your tailnet with `tailscale serve` and shows the
pairing QR code (step 4). If anything looks wrong later: `tiphys-agent doctor`. Re-run the command to update.
Options and details: [setup guide › One-command install](setup-guide.md#one-command-install-recommended).

Turn on more features when you need them, then restart the agent:

```sh
tiphys-agent init --features claude,control
systemctl --user restart tiphys-agent
```

On macOS restart it with `launchctl kickstart -k gui/$(id -u)/com.tiphys.agent`; on Windows sign out and in, or see
`tiphys-agent doctor` for the command.

**macOS and Windows:** the server features (system info, processes, ports, services, Docker, power, git, Wake-on-LAN
relay) work there too; see [System › Platforms](features/system.md#platforms) for what differs. Notes:

- Settings live in `~/.config/tiphys/agent.json` on macOS and in `%APPDATA%\Tiphys\agent.json` on Windows.
- Docker means Docker Desktop: it must be running (`doctor` reports `dockerUnreachable` otherwise).
- macOS: the first **Restart**/**Shut down** from the phone makes macOS ask once whether the agent may control
  "System Events" (System Settings › Privacy & Security › Automation).
- Windows: most services need an administrator to start or stop, and **Sleep** hibernates instead when hibernation
  is turned on (`powercfg /h off` to get real sleep).

### From a git checkout

Needs Linux with systemd and Node.js 22 or newer (desktop features also need Hyprland and the
[desktop tools](setup-guide.md#desktop-tools-pc-only-for-desktop-and-control)).

```sh
git clone https://github.com/aurict/tiphys.git ~/tiphys
cd ~/tiphys/agent
npm ci && npm run build
node dist/cli.js init --name argo --detect --features git,claude
```

`--detect` turns on the safe features this machine supports; `--features` adds to the list (`--set-features` is an
exact list that turns everything else off).

Create `~/.config/systemd/user/tiphys-agent.service` (adjust the paths to your checkout and to `command -v node`):

```ini
[Unit]
Description=Tiphys agent
After=network-online.target

[Service]
WorkingDirectory=%h/tiphys/agent
ExecStart=/usr/bin/node %h/tiphys/agent/dist/cli.js serve
Restart=on-failure
RestartSec=5
OOMPolicy=continue
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
```

```sh
systemctl --user daemon-reload
systemctl --user enable --now tiphys-agent.service
tailscale serve --bg --https=7443 http://127.0.0.1:7443
curl -s https://argo.my-tailnet.ts.net:7443/v1/health
```

Details: [setup guide › Agent on the PC](setup-guide.md#3-agent-on-the-pc). Servers:
[setup guide › Agent on a server](setup-guide.md#4-agent-on-a-server) (`tools/deploy-agent.sh`, or the installer;
Docker: [packaging/README.md](../packaging/README.md)).

## 3. Build the app

```sh
tools/setup-dev.sh && source ~/opt/tiphys-env.sh       # Flutter 3.47.9, JDK 17, Android SDK 36 under ~/opt
cd app && flutter pub get
flutter build apk --release --target-platform android-arm64 --obfuscate --split-debug-info=build/symbols
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Create a release signing key first (`~/.config/tiphys/release/key.properties`), otherwise the APK is signed with
the debug key. On a desktop you are using, wrap the build in `tools/limited.sh`. Details:
[setup guide › Build and install the app](setup-guide.md#6-build-and-install-the-app).

## 4. Pair the phone

**Setup wizard:** on first launch without a host, the app opens a wizard that walks through all of this: the
Tailscale requirement, the install command for the computer's OS (copy or share it), scanning the installer's QR
code (or pasting its text: the address and `tph_` token printed below the QR), the agent's health check with
copyable fixes, and which features are on and what the risky ones would allow. It can be skipped at every step and
is also under *Settings › Set up a computer*. Desktop builds (and iOS) can always paste the code instead of
scanning.

The installer already showed a QR code. Another phone, or a checkout install:

```sh
tiphys-agent pair --name Phone        # or, from a checkout: tools/pair.sh local
```

The address is taken from Tailscale (pass `--url https://argo.my-tailnet.ts.net:7443` to override). No restart is
needed. In the app, add the host under *Settings › Hosts* and use *Pair with QR code*. Details:
[setup guide › Pair the phone](setup-guide.md#7-pair-the-phone).

## 5. First run

Set a PIN under *Settings › Security*, add your SSH key and hosts, then turn on notifications and the features you
need:

- [First run in the app](setup-guide.md#8-first-run-in-the-app)
- [Feature flags](setup-guide.md#9-feature-flags) and [setting up each feature](setup-guide.md#10-setting-up-each-feature)
  (Claude, desktop control, live screen, Firefox bridge, mobile view, notifications, monitoring, Wake-on-LAN,
  research, Telegram)
- [Security checklist](setup-guide.md#12-security-checklist)
- [Troubleshooting](troubleshooting.md)
