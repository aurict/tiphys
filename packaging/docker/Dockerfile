# Tiphys agent for servers (PLAN K3). Build from the repository root:
#   docker build -f packaging/docker/Dockerfile -t tiphys-agent .
# Runs as the unprivileged "node" user, keeps all state in /config, works with --read-only (plus a /tmp tmpfs).
# Only server features: no Claude SDK binary, no desktop tools. See packaging/README.md for run examples and the
# docker socket trade-off.

FROM node:24-bookworm-slim AS build
WORKDIR /src
COPY agent/package.json agent/package-lock.json ./
RUN npm ci --include=dev --ignore-scripts --no-audit --no-fund
COPY agent/tsconfig.json agent/tsconfig.build.json ./
COPY agent/src ./src
# Production dependencies only, without optional packages (the Claude Agent SDK's ~300 MB native binary).
RUN npm run build && find dist -name '*.map' -delete && npm prune --omit=dev --omit=optional --ignore-scripts --no-audit --no-fund

# Docker CLI only (the "docker" feature runs `docker ps/stats/logs/...` against a mounted socket).
FROM docker:29-cli AS dockercli

FROM node:24-bookworm-slim
ENV NODE_ENV=production \
    TIPHYS_AGENT_CONFIG=/config/agent.json \
    HOME=/config
COPY --from=dockercli /usr/local/bin/docker /usr/local/bin/docker
WORKDIR /app
COPY --from=build /src/package.json ./
COPY --from=build /src/dist ./dist
COPY --from=build /src/node_modules ./node_modules
COPY agent/helpers/audit.sh ./helpers/audit.sh
COPY --chmod=755 packaging/docker/entrypoint.sh /usr/local/bin/tiphys-entrypoint
RUN printf '#!/bin/sh\nexec node /app/dist/cli.js "$@"\n' > /usr/local/bin/tiphys-agent && chmod 755 /usr/local/bin/tiphys-agent \
    && mkdir -p /config && chown node:node /config && chmod 700 /config
USER node
VOLUME ["/config"]
EXPOSE 7443
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["node", "-e", "fetch('http://127.0.0.1:7443/v1/health').then(r=>process.exit(r.ok?0:1),()=>process.exit(1))"]
ENTRYPOINT ["tiphys-entrypoint"]
CMD ["serve"]
