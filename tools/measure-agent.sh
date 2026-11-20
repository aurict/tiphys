#!/usr/bin/env bash
# Usage: [MAX_MB=n] tools/measure-agent.sh [features]   (after npm run build in agent/; NODE_OPTIONS is passed through)
# Measures a throwaway agent's resident memory: temp config, port 17999, only the given features. Never touches the
# real agent (its config, port and sockets).
set -euo pipefail
cd "$(dirname "$0")/../agent"
FEATURES=${1:-system}
T=$(mktemp -d /tmp/tiphys-measure-XXXX)
export TIPHYS_AGENT_CONFIG=$T/agent.json
node dist/cli.js init --name measure --features "$FEATURES" >/dev/null
python3 - "$T/agent.json" <<'PY'
import json,sys; p=sys.argv[1]; c=json.load(open(p)); c['listen']={'host':'127.0.0.1','port':17999}; json.dump(c,open(p,'w'))
PY
node dist/cli.js serve >"$T/log" 2>&1 &
PID=$!
for i in $(seq 1 40); do curl -s -o /dev/null http://127.0.0.1:17999/v1/health && break; sleep 0.25; done
sleep 3
for i in 1 2 3 4 5; do curl -s -o /dev/null http://127.0.0.1:17999/v1/health; done
sleep 1
RSS=$(( $(awk '/^VmRSS:/ {print $2}' /proc/$PID/status) / 1024 ))
echo "features=$FEATURES rss_mb=$RSS"
kill $PID; wait $PID 2>/dev/null || true
rm -rf "$T"
# MAX_MB: fail above this budget (CI).
if [ -n "${MAX_MB:-}" ] && [ "$RSS" -gt "$MAX_MB" ]; then echo "over budget ($MAX_MB MB)" >&2; exit 1; fi
