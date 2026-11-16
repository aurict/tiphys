#!/usr/bin/env bash
# Installs/updates the Tiphys agent on a remote Linux server (systemd user service).
# Usage: tools/deploy-agent.sh <ssh-target> <name> <features> [ssh-key]
#   e.g.  tools/deploy-agent.sh user@100.64.0.2 atlas system,services,docker,uptime,watch ~/.ssh/id_ed25519
# Features: system services docker power homepage claude uptime wake watch git desktop control ports transcribe alerts backups
#   (control: endpoints that change the desktop; requires desktop, works only with a timed control session opened on the phone)
#   (the event stream /v1/events is always on; no feature flag)
# Optional on first install: TIPHYS_TAILSCALE_LOGIN=you@example.com (only this Tailscale user's devices can connect).
set -euo pipefail
cd "$(dirname "$0")/../agent"
TARGET=$1 NAME=$2 FEATURES=$3 KEY=${4:-}
SSH=(ssh -o BatchMode=yes ${KEY:+-i "$KEY"} "$TARGET")

npm run -s build
STAGE=$(mktemp -d)
cp -r dist helpers package.json package-lock.json "$STAGE/"  # helpers/: AT-SPI helper (11.4)
find "$STAGE/helpers" -name __pycache__ -prune -exec rm -rf {} +
(cd "$STAGE" && npm ci --omit=dev --omit=optional --ignore-scripts --no-audit --no-fund >/dev/null)
if find "$STAGE/node_modules" -name '*.node' | grep -q .; then
  echo "yerel (native) modül var; başka mimariye kopyalanamaz" >&2; exit 1
fi

"${SSH[@]}" 'command -v node >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null; mkdir -p ~/tiphys-agent'
tar -C "$STAGE" -czf - . | "${SSH[@]}" 'rm -rf ~/tiphys-agent/dist ~/tiphys-agent/helpers ~/tiphys-agent/node_modules && tar -C ~/tiphys-agent -xzf -'
rm -rf "$STAGE"

"${SSH[@]}" bash -s -- "$NAME" "$FEATURES" "${TIPHYS_TAILSCALE_LOGIN:-}" <<'REMOTE'
set -euo pipefail
NAME=$1 FEATURES=$2 LOGIN=${3:-}
cd ~/tiphys-agent
[ -f ~/.config/tiphys/agent.json ] || node dist/cli.js init --name "$NAME" --features "$FEATURES" ${LOGIN:+--tailscale-login "$LOGIN"}
node dist/cli.js init --name "$NAME" --features "$FEATURES" >/dev/null
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/tiphys-agent.service <<UNIT
[Unit]
Description=Tiphys Ajanı
After=network-online.target

[Service]
WorkingDirectory=%h/tiphys-agent
ExecStart=$(command -v node) %h/tiphys-agent/dist/cli.js serve
Restart=on-failure
RestartSec=5
# No memory/CPU limit: Claude sessions and commands started from the phone should run like a terminal on the PC
# (one Claude process ~500 MB; the old 512M limit killed the whole agent on the first chat).
# If system memory runs out, only the largest process is killed and the agent stays up.
OOMPolicy=continue
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
UNIT
sudo loginctl enable-linger "$USER"
export XDG_RUNTIME_DIR=/run/user/$(id -u)
systemctl --user daemon-reload
systemctl --user enable tiphys-agent.service >/dev/null 2>&1
systemctl --user restart tiphys-agent.service
sleep 3
systemctl --user is-active tiphys-agent.service
curl -s http://127.0.0.1:7443/v1/health; echo
sudo tailscale serve --bg --https=7443 http://127.0.0.1:7443 >/dev/null && echo "serve :7443 tamam"
REMOTE
