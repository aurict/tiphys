#!/usr/bin/env bash
# Tiphys ajanını uzak bir Linux sunucuya kurar/günceller (systemd kullanıcı servisi).
# Kullanım: tools/deploy-agent.sh <ssh-hedefi> <ad> <özellikler> [ssh-anahtarı]
#   ör.   tools/deploy-agent.sh user@100.64.0.2 atlas system,services,docker,uptime,watch ~/.ssh/id_ed25519
# İlk kurulumda isteğe bağlı: TIPHYS_TAILSCALE_LOGIN=sen@example.com (yalnız bu Tailscale kullanıcısının cihazları bağlanır).
set -euo pipefail
cd "$(dirname "$0")/../agent"
TARGET=$1 NAME=$2 FEATURES=$3 KEY=${4:-}
SSH=(ssh -o BatchMode=yes ${KEY:+-i "$KEY"} "$TARGET")

npm run -s build
STAGE=$(mktemp -d)
cp -r dist package.json package-lock.json "$STAGE/"
(cd "$STAGE" && npm ci --omit=dev --omit=optional --ignore-scripts --no-audit --no-fund >/dev/null)
if find "$STAGE/node_modules" -name '*.node' | grep -q .; then
  echo "yerel (native) modül var; başka mimariye kopyalanamaz" >&2; exit 1
fi

"${SSH[@]}" 'command -v node >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nodejs >/dev/null; mkdir -p ~/tiphys-agent'
tar -C "$STAGE" -czf - . | "${SSH[@]}" 'rm -rf ~/tiphys-agent/dist ~/tiphys-agent/node_modules && tar -C ~/tiphys-agent -xzf -'
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
# Bellek/CPU sınırı yok: telefondan açılan Claude oturumları ve komutları PC'deki terminal gibi çalışsın
# (bir Claude süreci ~500 MB; eski 512M sınırı ilk sohbette tüm ajanı öldürüyordu).
# Sistem belleği biterse yalnız en büyük süreç kapanır, ajan ayakta kalır.
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
