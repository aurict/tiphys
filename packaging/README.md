# Packaging

Other ways to install the agent besides `install.sh` / `install.ps1` (PLAN K3). All of them install the same
release bundle (`tiphys-agent-<version>-<platform>`, built by `tools/release.sh`), which carries its own Node.js.
Package installs are updated by their package manager; the agent's own self-update (`update` feature) works only for
`install.sh` installs and stays off here.

| Path | Status | Publishing needs |
|---|---|---|
| `nfpm.yaml` → `.deb` / `.rpm` | built in CI (`release-check.yml`, nfpm container) | attach to the GitHub release, or host an apt/rpm repository (your choice and account) |
| `aur/PKGBUILD` (`tiphys-agent-bin`) | draft; `tools/release.sh` fills in version and checksums | an AUR account and SSH key |
| `homebrew/tiphys-agent.rb` | draft; filled in by `tools/release.sh` | a tap repository, e.g. `aurict/homebrew-tiphys` |
| `winget/*.yaml` | draft, **not submittable yet**: winget needs an `.exe` entry point; the bundle starts `node\node.exe dist\cli.js`. Add a small `tiphys-agent.exe` launcher to the Windows bundle first | a fork of `microsoft/winget-pkgs` and a PR |
| `docker/Dockerfile` | builds locally and in CI | a registry (e.g. GHCR) if you want to publish the image |

Rendered drafts land in `release/<version>/packaging/` (checksums come from the signed `SHA256SUMS`).

## .deb / .rpm

```sh
# from the repo root, after tools/release.sh <version> --platforms linux-x64 [--unsigned]
mkdir -p /tmp/b && tar -xzf release/<v>/tiphys-agent-<v>-linux-x64.tar.gz -C /tmp/b
sed -e 's/@VERSION@/<v>/' -e 's/@ARCH@/amd64/' -e 's#@BUNDLE@#/tmp/b/tiphys-agent-<v>-linux-x64#' packaging/nfpm.yaml > /tmp/nfpm.yaml
docker run --rm -v "$PWD:/repo" -v /tmp:/tmp -w /repo goreleaser/nfpm package -f /tmp/nfpm.yaml -p deb -t release/<v>/
```

Files: `/opt/tiphys-agent` (agent + Node.js), `/usr/bin/tiphys-agent`, the user unit
`/usr/lib/systemd/user/tiphys-agent.service`. After installing, as your user:
`tiphys-agent init --detect && systemctl --user enable --now tiphys-agent && tiphys-agent pair`.

## Docker (servers)

```sh
docker build -f packaging/docker/Dockerfile -t tiphys-agent .

# Recommended: host network, so `tailscale serve` on the host reaches 127.0.0.1:7443 and nothing else can.
docker run -d --name tiphys --restart unless-stopped --network host \
  --read-only --tmpfs /tmp \
  -v tiphys-config:/config \
  -v /var/run/docker.sock:/var/run/docker.sock --group-add "$(stat -c %g /var/run/docker.sock)" \
  -e TIPHYS_NAME=atlas tiphys-agent
sudo tailscale serve --bg --https=7443 http://127.0.0.1:7443
docker exec -it tiphys tiphys-agent pair --url https://atlas.<tailnet>.ts.net:7443
```

- **User and file system:** runs as `node` (uid 1000), not root. All state (`agent.json`, events, audit log) is in
  the `/config` volume; the image works with `--read-only` plus a `/tmp` tmpfs.
- **Features:** first start creates `agent.json` with `TIPHYS_FEATURES` (default `system,docker,watch,alerts`).
  No Claude, desktop or systemd features: the image has no Claude binary, no desktop tools and no systemd.
  `system` shows what the container can see (host CPU/memory, container processes).
- **Bridge network instead of host:** add `-e TIPHYS_LISTEN_HOST=0.0.0.0 -p 127.0.0.1:7443:7443`. Never publish
  the port on all interfaces; the agent is meant to be reachable only through `tailscale serve`.
- **`tailscale serve` and pairing:** Tailscale runs on the host, so `pair` inside the container can't find the
  address by itself: pass `--url`.
- **Health:** the image's `HEALTHCHECK` calls `/v1/health` (no token needed, returns name/version/features only).

### The docker socket trade-off

The `docker` feature needs `/var/run/docker.sock`. Whoever can use that socket is effectively **root on the host**
(they can start a privileged container that mounts `/`). Mounting it into this container means a compromise of the
agent, or of a paired phone, is a host compromise. Options, from most to least exposed:

1. Mount the socket (above): full Docker features from the phone.
2. Mount a filtering proxy instead, e.g. `tecnativa/docker-socket-proxy` with only `CONTAINERS=1` (and `POST=1` only
   if you want start/stop/restart), and point the agent at it with `-e DOCKER_HOST=tcp://docker-proxy:2375`.
3. Don't mount it, and leave `docker` out of `TIPHYS_FEATURES`.

## Who publishes what

Nothing here is published automatically: GitHub releases are created by `tools/release.sh --publish` on the
release PC; AUR, Homebrew, winget and container registries need the maintainer's own accounts.
