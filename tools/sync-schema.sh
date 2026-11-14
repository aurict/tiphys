#!/usr/bin/env bash
# Profil şemasını ajandaki Zod tanımından üretir ve uygulamaya kopyalar.
set -euo pipefail
cd "$(dirname "$0")/.."
(cd agent && npm run -s build && node dist/cli.js schema > ../schema/tiphys.schema.json)
cp schema/tiphys.schema.json app/assets/profile/tiphys.schema.json
cp tiphys.example.json app/assets/profile/example.json
echo "şema eşitlendi"
