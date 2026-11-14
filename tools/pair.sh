#!/usr/bin/env bash
# Telefonu bir Tiphys ajanıyla eşler: QR basar, sonra ajanı yeniden başlatır (yeni cihazı tanısın diye).
# Kullanım:
#   tools/pair.sh local  <ajan-adresi> [cihaz-adı]                 # bu makinedeki ajan
#   tools/pair.sh <ssh-hedefi> <ajan-adresi> [cihaz-adı] [ssh-anahtarı]   # uzak sunucudaki ajan (~/tiphys-agent)
#   ör. tools/pair.sh local https://argo.example.ts.net:7443 Phone
#       tools/pair.sh user@100.64.0.2 https://atlas.example.ts.net:7443 Phone ~/.ssh/id_ed25519
set -euo pipefail
target=${1:?kullanım: tools/pair.sh local|<ssh-hedefi> <ajan-adresi> [cihaz-adı] [ssh-anahtarı]}
url=${2:?ajan adresi gerekli, ör. https://argo.example.ts.net:7443}
name=${3:-Phone}
key=${4:-}
if [ "$target" = local ]; then
  node "$(dirname "$0")/../agent/dist/cli.js" pair --name "$name" --url "$url"
  systemctl --user restart tiphys-agent
else
  ssh -t ${key:+-i "$key"} "$target" \
    "cd ~/tiphys-agent && node dist/cli.js pair --name '$name' --url '$url' && systemctl --user restart tiphys-agent"
fi
echo "Ajan yeniden başlatıldı; QR'ı Tiphys'te Ayarlar › Hostlar › <host> › QR ile eşle ekranından okut."
