#!/bin/sh
# First start: creates /config/agent.json with server features only (TIPHYS_FEATURES, default system,docker,watch,alerts).
# TIPHYS_LISTEN_HOST=0.0.0.0 is needed with bridge networking (publish it as -p 127.0.0.1:7443:7443 only);
# with --network host keep the default 127.0.0.1 and run `tailscale serve` on the host.
set -eu
cfg=${TIPHYS_AGENT_CONFIG:-/config/agent.json}
if [ "${1:-serve}" = serve ] && [ ! -f "$cfg" ]; then
  node /app/dist/cli.js init --name "${TIPHYS_NAME:-$(hostname)}" --set-features "${TIPHYS_FEATURES:-system,docker,watch,alerts}"
  if [ -n "${TIPHYS_LISTEN_HOST:-}" ]; then
    node -e 'const fs=require("fs");const [p,h]=process.argv.slice(1);const c=JSON.parse(fs.readFileSync(p,"utf8"));c.listen.host=h;fs.writeFileSync(p,JSON.stringify(c,null,2)+"\n",{mode:0o600})' "$cfg" "$TIPHYS_LISTEN_HOST"
  fi
fi
if [ "${1:-serve}" = serve ]; then
  exec node --max-semi-space-size=1 /app/dist/cli.js serve
fi
exec node /app/dist/cli.js "$@"
