#!/usr/bin/env bash
# Pairs the phone with a Tiphys agent: prints a QR code. The running agent picks up the new device by itself
# (it re-reads agent.json), so no restart is needed. Agents deployed before that change still need one; the CLI
# says so when the agent did not confirm the device.
# Usage:
#   tools/pair.sh local  [agent-address|auto] [device-name]                     # agent on this machine
#   tools/pair.sh <ssh-target> [agent-address|auto] [device-name] [ssh-key]     # agent on a remote server (~/tiphys-agent)
#   e.g. tools/pair.sh local                                   (address from Tailscale: https://<machine>.<tailnet>.ts.net:7443)
#       tools/pair.sh local https://argo.example.ts.net:7443 Phone
#       tools/pair.sh user@100.64.0.2 auto Phone ~/.ssh/id_ed25519
set -euo pipefail
target=${1:?kullanım: tools/pair.sh local|<ssh-hedefi> [ajan-adresi|auto] [cihaz-adı] [ssh-anahtarı]}
url=${2:-auto}
name=${3:-Phone}
key=${4:-}
urlarg=()
[ "$url" = auto ] || urlarg=(--url "$url")
if [ "$target" = local ]; then
  node "$(dirname "$0")/../agent/dist/cli.js" pair --name "$name" "${urlarg[@]}"
else
  # shellcheck disable=SC2029 # expanded on purpose on this side
  ssh -t ${key:+-i "$key"} "$target" "cd ~/tiphys-agent && node dist/cli.js pair --name '$name' ${urlarg[*]:+--url '$url'}"
fi
echo "QR'ı Tiphys'te Ayarlar › Hostlar › <host> › QR ile eşle ekranından okut."
echo "Uygulama bağlanamazsa (eski ajan): systemctl --user restart tiphys-agent"
