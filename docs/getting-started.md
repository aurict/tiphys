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

Needs Linux with systemd and Node.js 22 or newer (desktop features also need Hyprland and the
[desktop tools](setup-guide.md#desktop-tools-pc-only-for-desktop-and-control)).

```sh
git clone https://github.com/aurict/tiphys.git ~/tiphys
cd ~/tiphys/agent
npm ci && npm run build
node dist/cli.js init --name argo --features system,services,docker,power,git,claude
```

`--features` is an exact list: everything not listed is turned off.

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
[setup guide › Agent on a server](setup-guide.md#4-agent-on-a-server) (`tools/deploy-agent.sh`).

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

```sh
tools/pair.sh local https://argo.my-tailnet.ts.net:7443 Phone
```

In the app, add the host under *Settings › Hosts* and use *Pair with QR code*. If you run `node dist/cli.js pair`
yourself, always pass `--url` and restart the agent afterwards. Details:
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
