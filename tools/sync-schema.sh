#!/usr/bin/env bash
# Generates the profile schema from the agent's Zod definition and copies it into the app.
set -euo pipefail
cd "$(dirname "$0")/.."
(cd agent && npm run -s build && node dist/cli.js schema > ../schema/tiphys.schema.json)
cp schema/tiphys.schema.json app/assets/profile/tiphys.schema.json
cp tiphys.example.json app/assets/profile/example.json
echo "şema eşitlendi"
