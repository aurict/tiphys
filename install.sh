#!/bin/sh
# Tiphys agent installer for Linux and macOS (PLAN K2).
#
#   curl -fsSL https://raw.githubusercontent.com/aurict/tiphys/main/install.sh | sh
#   curl -fsSL https://raw.githubusercontent.com/aurict/tiphys/main/install.sh | sh -s -- --version 0.4.0
#
# What it does: downloads the release bundle for this OS/CPU (agent + its own Node.js runtime), verifies the ed25519
# signature of SHA256SUMS with the public key embedded below and the bundle's SHA-256, installs it to
# ~/.local/share/tiphys-agent/versions/<version> with a `current` link, sets up a user service (systemd user unit or
# a launchd LaunchAgent), turns on the safe features this machine supports (`init --detect`), publishes the agent in
# your tailnet with `tailscale serve`, and prints the pairing QR code. Re-running it updates.
#
# Options:
#   --version V                 install this version (default: latest release)
#   --name NAME                 agent name shown in the app (default: host name; first install only)
#   --no-service                don't create/start the user service
#   --no-serve                  don't run `tailscale serve`
#   --no-pair                   don't print a pairing QR code
#   --uninstall                 remove the service and the program files (keeps ~/.config/tiphys)
#   --purge                     with --uninstall: also delete ~/.config/tiphys (settings, paired devices, logs)
#   --insecure-skip-signature   install even if the signature can't be checked (no openssl with ed25519, or a build
#                               without a release key). The SHA-256 still has to match, but that only proves the
#                               download is intact, not that it was published by the Tiphys maintainer.
# Environment: TIPHYS_RELEASE_URL (default https://github.com/aurict/tiphys/releases), TIPHYS_PREFIX.
set -eu

RELEASES=${TIPHYS_RELEASE_URL:-https://github.com/aurict/tiphys/releases}
PREFIX=${TIPHYS_PREFIX:-$HOME/.local/share/tiphys-agent}
BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/tiphys"
PORT=7443

# The release signing key (written by tools/release-keygen.sh). A placeholder means: no signed releases yet.
# BEGIN TIPHYS UPDATE KEY
PUBKEY='-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEARrrX7fMCJXSF0JVUQVoAmbhDLcCYSQo6UdBloCXJ9/A=
-----END PUBLIC KEY-----'
# END TIPHYS UPDATE KEY

VERSION='' NAME='' NO_SERVICE='' NO_SERVE='' NO_PAIR='' UNINSTALL='' PURGE='' SKIP_SIG=''
while [ $# -gt 0 ]; do
  case $1 in
    --version) VERSION=${2:?--version needs a value}; shift ;;
    --name) NAME=${2:?--name needs a value}; shift ;;
    --no-service) NO_SERVICE=1 ;;
    --no-serve) NO_SERVE=1 ;;
    --no-pair) NO_PAIR=1 ;;
    --uninstall) UNINSTALL=1 ;;
    --purge) PURGE=1 ;;
    --insecure-skip-signature) SKIP_SIG=1 ;;
    -h|--help) sed -n '2,30p' "$0" 2>/dev/null || echo "see https://github.com/aurict/tiphys/blob/main/docs/getting-started.md"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

OS=$(uname -s)
case $OS in
  Linux) OS=linux ;;
  Darwin) OS=darwin ;;
  *) die "unsupported system $OS (Linux and macOS only; Windows: install.ps1)" ;;
esac
case $(uname -m) in
  x86_64|amd64) ARCH=x64 ;;
  aarch64|arm64) ARCH=arm64 ;;
  *) die "unsupported CPU $(uname -m) (x86_64 and arm64 only)" ;;
esac

# systemd user services are usable (not in most containers, not over a plain `su`).
systemd_user() { [ "$OS" = linux ] && have systemctl && systemctl --user show-environment >/dev/null 2>&1; }
UNIT="$HOME/.config/systemd/user/tiphys-agent.service"
PLIST="$HOME/Library/LaunchAgents/com.tiphys.agent.plist"

stop_service() {
  if [ "$OS" = linux ]; then
    if systemd_user; then systemctl --user disable --now tiphys-agent.service >/dev/null 2>&1 || true; fi
  else
    launchctl bootout "gui/$(id -u)/com.tiphys.agent" >/dev/null 2>&1 || true
  fi
}

if [ -n "$UNINSTALL" ]; then
  step "Removing the Tiphys agent"
  stop_service
  rm -f "$UNIT" "$PLIST" "$BIN_DIR/tiphys-agent"
  if systemd_user; then systemctl --user daemon-reload || true; fi
  rm -rf "$PREFIX"
  if [ -n "$PURGE" ]; then rm -rf "$CONFIG_DIR"; say "Deleted $CONFIG_DIR (settings, paired devices)."
  else say "Kept your settings in $CONFIG_DIR (delete with --uninstall --purge)."; fi
  say "If you published the agent with tailscale serve, remove it with: tailscale serve --https=$PORT off"
  exit 0
fi

# ---- download ------------------------------------------------------------------------------------------------------
if have curl; then fetch() { curl -fsSL --retry 2 -o "$2" "$1"; }
elif have wget; then fetch() { wget -q -O "$2" "$1"; }
else die "curl or wget is needed"; fi
have tar || die "tar is needed"
if have sha256sum; then sha256() { sha256sum "$1" | cut -d' ' -f1; }
elif have shasum; then sha256() { shasum -a 256 "$1" | cut -d' ' -f1; }
else die "sha256sum or shasum is needed"; fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT INT TERM

if [ -z "$VERSION" ]; then
  fetch "$RELEASES/latest/download/VERSION" "$TMP/VERSION" || die "could not reach $RELEASES (no internet, or no release yet)"
  VERSION=$(tr -d ' \r\n' < "$TMP/VERSION")
fi
case $VERSION in
  v*) VERSION=${VERSION#v} ;;
esac
echo "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || die "bad version: $VERSION"

FILE="tiphys-agent-$VERSION-$OS-$ARCH.tar.gz"
BASE="$RELEASES/download/v$VERSION"
step "Downloading Tiphys agent $VERSION ($OS-$ARCH)"
fetch "$BASE/SHA256SUMS" "$TMP/SHA256SUMS" || die "release v$VERSION not found at $BASE"
fetch "$BASE/SHA256SUMS.sig" "$TMP/SHA256SUMS.sig" || die "SHA256SUMS.sig missing (unsigned release)"
fetch "$BASE/$FILE" "$TMP/$FILE" || die "no bundle $FILE in release v$VERSION"

# ---- verify --------------------------------------------------------------------------------------------------------
# openssl can verify ed25519 (OpenSSL 3, or 1.1.1 with -rawin). Probed with a throwaway key: macOS's LibreSSL may not.
openssl_ed25519() {
  have openssl || return 1
  d=$(mktemp -d)
  printf probe > "$d/m"
  r=1
  if openssl genpkey -algorithm ed25519 -out "$d/k" >/dev/null 2>&1 &&
    openssl pkey -in "$d/k" -pubout -out "$d/p" >/dev/null 2>&1 &&
    openssl pkeyutl -sign -inkey "$d/k" -rawin -in "$d/m" -out "$d/s" >/dev/null 2>&1 &&
    openssl pkeyutl -verify -pubin -inkey "$d/p" -rawin -in "$d/m" -sigfile "$d/s" >/dev/null 2>&1; then r=0; fi
  rm -rf "$d"
  return $r
}

step "Verifying"
case $PUBKEY in
  *"BEGIN PUBLIC KEY"*)
    if openssl_ed25519; then
      printf '%s\n' "$PUBKEY" > "$TMP/pub.pem"
      openssl pkeyutl -verify -pubin -inkey "$TMP/pub.pem" -rawin -in "$TMP/SHA256SUMS" -sigfile "$TMP/SHA256SUMS.sig" >/dev/null 2>&1 ||
        die "SIGNATURE CHECK FAILED: SHA256SUMS was not signed by the Tiphys release key. Nothing was installed."
      say "signature: ok (ed25519, release key)"
    elif [ -n "$SKIP_SIG" ]; then
      say "signature: NOT CHECKED (openssl with ed25519 support not found; --insecure-skip-signature given)"
    else
      die "can't check the release signature: openssl with ed25519 support is needed (Linux: install openssl; macOS: brew install openssl and put it first on PATH). To install anyway, re-run with --insecure-skip-signature."
    fi ;;
  *)
    [ -n "$SKIP_SIG" ] || die "this installer has no release signing key yet, so the download can't be verified. Re-run with --insecure-skip-signature only if you trust where it came from."
    say "signature: NOT CHECKED (installer without a release key; --insecure-skip-signature given)" ;;
esac
want=$(awk -v f="$FILE" '$2 == f || $2 == "*" f { print $1 }' "$TMP/SHA256SUMS")
[ -n "$want" ] || die "$FILE is not listed in SHA256SUMS"
[ "$(sha256 "$TMP/$FILE")" = "$want" ] || die "SHA-256 mismatch for $FILE (damaged or tampered download). Nothing was installed."
say "sha256: ok"

# ---- install -------------------------------------------------------------------------------------------------------
step "Installing to $PREFIX/versions/$VERSION"
mkdir -p "$PREFIX/versions"
NEW="$PREFIX/versions/.new-$VERSION"
rm -rf "$NEW"
mkdir -p "$NEW"
tar -xzf "$TMP/$FILE" -C "$NEW"
TOP="$NEW/tiphys-agent-$VERSION-$OS-$ARCH"
if ! { [ -f "$TOP/dist/cli.js" ] && [ -x "$TOP/node/bin/node" ]; }; then die "bundle content is not what was expected"; fi
OLD=
if [ -L "$PREFIX/current" ]; then OLD=$(basename "$(readlink "$PREFIX/current")"); fi
if [ "$OLD" = "$VERSION" ]; then stop_service; fi
rm -rf "$PREFIX/versions/$VERSION"
mv "$TOP" "$PREFIX/versions/$VERSION"
rm -rf "$NEW"
ln -sfn "versions/$VERSION" "$PREFIX/current"
rm -f "$PREFIX/update-pending"
# Keep the previous version for a rollback; remove older ones.
for v in "$PREFIX"/versions/*; do
  b=$(basename "$v")
  [ "$b" = "$VERSION" ] || [ "$b" = "$OLD" ] || rm -rf "$v"
done

# Update guard (K8): runs before every start. After a self-update the new version removes update-pending once it has
# been up for 15 s; if it fails to start 3 times in a row, `current` goes back to the previous version.
cat > "$PREFIX/guard.sh" <<'GUARD'
# BEGIN GUARD
root=${1:?usage: guard.sh <install root>}
m="$root/update-pending"
[ -f "$m" ] || exit 0
from=$(sed -n 's/^from=//p' "$m")
to=$(sed -n 's/^to=//p' "$m")
n=$(sed -n 's/^attempts=//p' "$m")
case $n in ''|*[!0-9]*) n=0 ;; esac
n=$((n + 1))
if [ "$n" -gt 3 ] && echo "$from" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' && [ -d "$root/versions/$from" ]; then
  ln -sfn "versions/$from" "$root/current"
  rm -f "$m"
  echo "tiphys guard: $to did not start $((n - 1)) times; rolled back to $from" >&2
  exit 0
fi
printf 'from=%s\nto=%s\nattempts=%s\n' "$from" "$to" "$n" > "$m.tmp" && mv -f "$m.tmp" "$m"
exit 0
# END GUARD
GUARD

NODE="$PREFIX/current/node/bin/node"
CLI="$PREFIX/current/dist/cli.js"
mkdir -p "$BIN_DIR"
rm -f "$BIN_DIR/tiphys-agent"
cat > "$BIN_DIR/tiphys-agent" <<EOF
#!/bin/sh
exec "$NODE" "$CLI" "\$@"
EOF
chmod 755 "$BIN_DIR/tiphys-agent"
case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) say "note: $BIN_DIR is not on your PATH; add it, or run $BIN_DIR/tiphys-agent" ;;
esac
agent() { "$NODE" "$CLI" "$@"; }

# ---- settings ------------------------------------------------------------------------------------------------------
if [ ! -f "$CONFIG_DIR/agent.json" ]; then
  step "Creating settings (detecting what this machine has)"
  if [ -n "$NAME" ]; then agent init --detect --name "$NAME"; else agent init --detect; fi
else
  say "Settings exist ($CONFIG_DIR/agent.json); features unchanged. Change them with: tiphys-agent init --features ..."
fi

# ---- service -------------------------------------------------------------------------------------------------------
STARTED=
if [ -n "$NO_SERVICE" ]; then
  say "Skipping the service (--no-service). Start the agent with: tiphys-agent serve"
elif [ "$OS" = linux ]; then
  if systemd_user; then
    step "Setting up the systemd user service"
    mkdir -p "$(dirname "$UNIT")"
    cat > "$UNIT" <<EOF
[Unit]
Description=Tiphys agent
After=network-online.target

[Service]
ExecStartPre=/bin/sh "$PREFIX/guard.sh" "$PREFIX"
ExecStart="$NODE" --max-semi-space-size=1 "$CLI" serve
# always: a self-update ends the process on purpose and expects to be started again.
Restart=always
RestartSec=5
OOMPolicy=continue
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload
    systemctl --user enable tiphys-agent.service >/dev/null 2>&1
    systemctl --user restart tiphys-agent.service
    STARTED=1
    if have loginctl && [ "$(loginctl show-user "$(id -un)" -p Linger --value 2>/dev/null)" != yes ]; then
      say "To keep the agent running while you are logged out (servers): sudo loginctl enable-linger $(id -un)"
    fi
  else
    say "systemd user services are not available here (container, or no user session)."
    say "Skipping the service. Start the agent yourself: tiphys-agent serve"
  fi
else
  step "Setting up the launchd agent"
  mkdir -p "$(dirname "$PLIST")" "$HOME/Library/Logs"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.tiphys.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/sh</string><string>-c</string>
    <string>/bin/sh "\$0/guard.sh" "\$0"; exec "\$0/current/node/bin/node" --max-semi-space-size=1 "\$0/current/dist/cli.js" serve</string>
    <string>$PREFIX</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>EnvironmentVariables</key><dict><key>NODE_ENV</key><string>production</string><key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:$HOME/.docker/bin:/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/tiphys-agent.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/tiphys-agent.log</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$(id -u)/com.tiphys.agent" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  STARTED=1
fi

if [ -n "$STARTED" ]; then
  i=0
  until fetch "http://127.0.0.1:$PORT/v1/health" /dev/null 2>/dev/null; do
    i=$((i + 1))
    [ $i -lt 20 ] || { say "The agent did not answer on 127.0.0.1:$PORT yet. Check: tiphys-agent doctor"; break; }
    sleep 1
  done
  [ $i -lt 20 ] && say "Agent is running on 127.0.0.1:$PORT."
fi

# ---- tailscale serve (K10) -----------------------------------------------------------------------------------------
TS=tailscale
[ "$OS" = darwin ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ] && ! have tailscale && TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale
SERVE_ARGS="serve --bg --https=$PORT http://127.0.0.1:$PORT"
if [ -n "$NO_SERVE" ]; then
  :
elif ! have "$TS"; then
  step "Tailscale"
  say "Tailscale is not installed. The phone reaches this agent only through your tailnet:"
  say "  1. install it: https://tailscale.com/download   (Linux: curl -fsSL https://tailscale.com/install.sh | sh)"
  say "  2. log in:      sudo tailscale up"
  say "  3. publish:     sudo tailscale $SERVE_ARGS"
  say "  4. pair:        tiphys-agent pair"
  NO_PAIR=1
elif "$TS" serve status --json 2>/dev/null | grep -q "127.0.0.1:$PORT\""; then
  say "tailscale serve already publishes the agent."
else
  step "Publishing the agent in your tailnet (tailscale serve)"
  if "$TS" serve --bg "--https=$PORT" "http://127.0.0.1:$PORT" >/dev/null 2>&1; then
    say "ok: https://<this machine>:$PORT inside your tailnet"
  elif [ "$OS" = linux ] && have sudo && [ -r /dev/tty ] && [ -w /dev/tty ]; then
    say "This needs root once: sudo tailscale $SERVE_ARGS"
    # shellcheck disable=SC2024 # the redirects are meant for sudo itself (password prompt on the terminal)
    sudo "$TS" serve --bg "--https=$PORT" "http://127.0.0.1:$PORT" < /dev/tty >/dev/null || say "Failed. Run it yourself: sudo tailscale $SERVE_ARGS"
  else
    SUDO=; [ "$OS" = linux ] && SUDO="sudo "
    say "Could not run it. Run it yourself: ${SUDO}tailscale $SERVE_ARGS"
  fi
fi

# ---- pair ----------------------------------------------------------------------------------------------------------
if [ -z "$NO_PAIR" ] && [ -f "$CONFIG_DIR/agent.json" ] && [ -z "$(agent devices 2>/dev/null)" ]; then
  step "Pair your phone"
  agent pair --name Phone || say "Pair later with: tiphys-agent pair"
fi

step "Done: Tiphys agent $VERSION"
say "Check the install any time: tiphys-agent doctor"
say "Update: run this installer again.  Remove: sh install.sh --uninstall"
