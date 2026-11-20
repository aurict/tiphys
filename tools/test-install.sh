#!/usr/bin/env bash
# End-to-end test of install.sh in throwaway containers (PLAN K2), against a release built by tools/release.sh.
#   tools/test-install.sh release/<version> [image ...]      default images: ubuntu:24.04 debian:12
# The release directory must hold a linux-x64 bundle, SHA256SUMS(.sig) and the install.sh with the matching key
# (tools/release.sh copies it there). Files are served as file:// URLs (TIPHYS_RELEASE_URL). Containers are removed;
# systemd isn't running in them, so the service step must be skipped with a message (tested).
set -euo pipefail
REL=$(cd "${1:?usage: tools/test-install.sh <release dir> [image ...]}" && pwd)
shift
IMAGES=("$@")
[ ${#IMAGES[@]} -gt 0 ] || IMAGES=(ubuntu:24.04 debian:12)
VERSION=$(cat "$REL/VERSION")
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Served layout: <base>/download/v<version>/<file>, <base>/latest/download/VERSION.
mkdir -p "$WORK/srv/download/v$VERSION" "$WORK/srv/latest/download" "$WORK/bad/download/v$VERSION" "$WORK/bad/latest/download"
for f in "$REL"/*; do
  [ -f "$f" ] || continue
  ln "$f" "$WORK/srv/download/v$VERSION/" 2>/dev/null || cp "$f" "$WORK/srv/download/v$VERSION/"
done
cp "$REL/VERSION" "$WORK/srv/latest/download/"
# A tampered release: one changed byte in SHA256SUMS (the signature no longer matches).
for f in "$WORK/srv/download/v$VERSION"/*; do ln -s "/srv/download/v$VERSION/$(basename "$f")" "$WORK/bad/download/v$VERSION/"; done
rm "$WORK/bad/download/v$VERSION/SHA256SUMS"
sed '1s/^./0/' "$REL/SHA256SUMS" > "$WORK/bad/download/v$VERSION/SHA256SUMS"
cp "$REL/VERSION" "$WORK/bad/latest/download/"
cp "$REL/install.sh" "$WORK/install.sh"
# The same installer without a key (like the repo's before tools/release-keygen.sh).
awk '/^# BEGIN TIPHYS UPDATE KEY/{print; print "PUBKEY='\''TIPHYS-PLACEHOLDER-PUBLIC-KEY'\''"; skip=1; next} /^# END TIPHYS UPDATE KEY/{skip=0} !skip' "$REL/install.sh" > "$WORK/install-nokey.sh"

cat > "$WORK/inside.sh" <<'INSIDE'
#!/bin/sh
# Runs in the container as root: prepares a user, then runs the scenarios as that user.
set -eu
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq --no-install-recommends curl >/dev/null
useradd -m t
as_t() { su t -c "cd ~ && $1"; }
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; tail -15 /tmp/o 2>/dev/null; exit 1; }
R=file:///srv

if ! command -v openssl >/dev/null; then
  as_t "TIPHYS_RELEASE_URL=$R sh /w/install.sh --no-pair" > /tmp/o 2>&1 && fail "installed without openssl"
  grep -q "openssl with ed25519 support is needed" /tmp/o && [ ! -e /home/t/.local/share/tiphys-agent/current ] || fail "no-openssl message"
  pass "refuses without openssl"
  apt-get install -y -qq openssl >/dev/null
fi

as_t "TIPHYS_RELEASE_URL=file:///bad sh /w/install.sh --no-pair" > /tmp/o 2>&1 && fail "installed a release with a bad signature"
grep -q "SIGNATURE CHECK FAILED" /tmp/o && [ ! -e /home/t/.local/share/tiphys-agent/current ] || fail "bad-signature message"
pass "bad signature refused, nothing installed"

as_t "TIPHYS_RELEASE_URL=$R sh /w/install-nokey.sh --no-pair" > /tmp/o 2>&1 && fail "keyless installer installed without the flag"
grep -q "no release signing key" /tmp/o || fail "keyless message"
pass "keyless installer refuses without --insecure-skip-signature"

as_t "TIPHYS_RELEASE_URL=$R sh /w/install.sh --name box" > /tmp/o 2>&1 || { cat /tmp/o; fail "install"; }
cat /tmp/o
grep -q "signature: ok" /tmp/o && grep -q "sha256: ok" /tmp/o || fail "verification lines"
grep -q "systemd user services are not available" /tmp/o || fail "service step not skipped"
grep -q "Tailscale is not installed" /tmp/o || fail "missing Tailscale message"
P=/home/t/.local/share/tiphys-agent
[ "$(readlink $P/current)" = "versions/$VERSION" ] && [ -f $P/guard.sh ] && [ -x /home/t/.local/bin/tiphys-agent ] || fail "layout"
pass "installed: current -> versions/$VERSION, guard.sh, ~/.local/bin/tiphys-agent"
[ "$(stat -c %a /home/t/.config/tiphys/agent.json)" = 600 ] || fail "config mode"
as_t "grep -q '\"name\": \"box\"' .config/tiphys/agent.json" || fail "name"
as_t "grep -q '\"power\": false' .config/tiphys/agent.json && grep -q '\"update\": true' .config/tiphys/agent.json" || fail "detected features (power off, update on for a managed install)"
pass "init --detect: risky power off, update on"

# Start it by hand (no systemd here), pair without --url failing cleanly, then pair with --url: accepted live.
as_t "nohup .local/bin/tiphys-agent serve > agent.log 2>&1 &"
i=0; until curl -fsS http://127.0.0.1:7443/v1/health >/dev/null 2>&1; do i=$((i+1)); [ $i -lt 30 ] || fail "agent did not start"; sleep 1; done
pass "agent answers /v1/health"
as_t ".local/bin/tiphys-agent pair --name P" > /tmp/o 2>&1 && fail "pair without Tailscale should fail"
grep -q "Tailscale is not installed" /tmp/o || fail "pair message"
pass "pair without --url explains the missing Tailscale"
as_t ".local/bin/tiphys-agent pair --name P --url https://box.example.ts.net:7443" > /tmp/o 2>&1 || fail "pair"
grep -q "accepts the new device; no restart needed" /tmp/o || { tail -25 /home/t/agent.log; fail "new device not accepted live"; }
pass "paired device accepted by the running agent without a restart"
as_t ".local/bin/tiphys-agent doctor --json" > /tmp/d 2>/dev/null || true
grep -q '"doctor.agent.listening"' /tmp/d && grep -q '"doctor.tailscale.missing"' /tmp/d || { cat /tmp/d; fail "doctor --json"; }
pass "doctor --json (agent listening, Tailscale missing)"
pkill -u t -f "dist/cli.js serve" || true
sleep 1

as_t "TIPHYS_RELEASE_URL=$R sh /w/install.sh --no-pair" > /tmp/o 2>&1 || { cat /tmp/o; fail "re-run"; }
grep -q "Settings exist" /tmp/o || fail "re-run"
pass "re-run keeps settings"
as_t "sh /w/install.sh --uninstall" > /tmp/o 2>&1 || fail "uninstall"
[ ! -e $P ] && [ ! -e /home/t/.local/bin/tiphys-agent ] && [ -f /home/t/.config/tiphys/agent.json ] || fail "uninstall"
pass "uninstall keeps config"
as_t "sh /w/install.sh --uninstall --purge" > /tmp/o 2>&1 || fail "purge"
[ ! -e /home/t/.config/tiphys ] || fail "purge"
pass "purge removes config"

as_t "TIPHYS_RELEASE_URL=$R sh /w/install-nokey.sh --insecure-skip-signature --no-pair --no-service" > /tmp/o 2>&1 || { cat /tmp/o; fail "insecure install"; }
grep -q "signature: NOT CHECKED" /tmp/o || fail "insecure message"
pass "--insecure-skip-signature installs and says so"
echo "ALL PASSED"
INSIDE

chmod -R a+rX "$WORK"
rc=0
for img in "${IMAGES[@]}"; do
  echo "=== $img"
  name="tiphys-install-test-$$-${img//[:.\/]/-}"
  if ! docker run --rm --name "$name" -e VERSION="$VERSION" -v "$WORK:/w:ro" -v "$WORK/srv:/srv:ro" -v "$WORK/bad:/bad:ro" "$img" sh /w/inside.sh; then
    echo "=== $img: FAILED"; rc=1
  fi
done
exit $rc
