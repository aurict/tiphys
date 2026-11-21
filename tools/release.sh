#!/usr/bin/env bash
# Builds a Tiphys release on the release PC (PLAN K1). No secret leaves this machine: the APK is signed by Gradle
# with ~/.config/tiphys/release/key.properties and SHA256SUMS with ~/.config/tiphys/release/update-signing.key.
#
#   tools/release.sh <version> [options]          dry run: everything goes to release/<version>/ (gitignored)
#   tools/release.sh <version> --publish          ... and creates the GitHub release v<version> with `gh`
#
# Options:
#   --platforms a,b        default linux-x64,linux-arm64,darwin-arm64,darwin-x64,win-x64
#   --desktop-helpers DIR  prebuilt desktop helpers named tiphys-desktop-<platform>[.exe] (from the helper's CI);
#                          each is copied into that bundle's helpers/ (optional)
#   --no-apk               skip the APK (always skipped with --unsigned)
#   --unsigned             no signatures at all (CI build check); cannot be combined with --publish
#
# Bundle tiphys-agent-<version>-<platform>.tar.gz (win: .zip) holds tiphys-agent-<version>-<platform>/ with dist/,
# production node_modules for that OS/CPU (incl. the matching Claude Agent SDK binary package), helpers/,
# display/ (the Game mode kiosk page with its vendor/ and fonts/; the agent serves it from ../display next to dist/),
# package.json and node/ (the official Node.js 24 runtime, checked against nodejs.org's SHASUMS256.txt).
# Env: TIPHYS_NODE_VERSION (default: newest 24.x), SOURCE_DATE_EPOCH (default: last commit time).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIMITED="$ROOT/tools/limited.sh"
KEY="$HOME/.config/tiphys/release/update-signing.key"

VERSION=${1:-}
[[ $VERSION =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: tools/release.sh <x.y.z> [--publish] [--platforms …] [--desktop-helpers DIR] [--no-apk] [--unsigned]" >&2; exit 2; }
shift
PUBLISH='' UNSIGNED='' NO_APK='' HELPERS=''
PLATFORMS=linux-x64,linux-arm64,darwin-arm64,darwin-x64,win-x64
while [ $# -gt 0 ]; do
  case $1 in
    --publish) PUBLISH=1 ;;
    --unsigned) UNSIGNED=1; NO_APK=1 ;;
    --no-apk) NO_APK=1 ;;
    --platforms) PLATFORMS=${2:?}; shift ;;
    --desktop-helpers) HELPERS=$(cd "${2:?}" && pwd); shift ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done
die() { echo "release: $*" >&2; exit 1; }
[ -n "$PUBLISH" ] && [ -n "$UNSIGNED" ] && die "--publish needs signatures (drop --unsigned)"

# ---- preconditions -------------------------------------------------------------------------------------------------
src_version=$(sed -n 's/^export const VERSION = "\(.*\)";/\1/p' "$ROOT/agent/src/version.ts")
pkg_version=$(node -p 'require(process.argv[1]).version' "$ROOT/agent/package.json")
[ "$src_version" = "$VERSION" ] && [ "$pkg_version" = "$VERSION" ] ||
  die "agent/src/version.ts ($src_version) and agent/package.json ($pkg_version) must both be $VERSION — bump them (and kExpectedAgentVersion in the app if needed) and commit first"
[ -f "$ROOT/display/index.html" ] && [ -d "$ROOT/display/vendor" ] && [ -d "$ROOT/display/fonts" ] ||
  die "display/ (Game mode kiosk page with vendor/ and fonts/) is incomplete"
if [ -z "$UNSIGNED" ]; then
  [ -f "$KEY" ] || die "no signing key at $KEY — run tools/release-keygen.sh once (or use --unsigned for a build check)"
  grep -q "BEGIN PUBLIC KEY" "$ROOT/agent/src/update_key.ts" || die "agent/src/update_key.ts still holds the placeholder key (tools/release-keygen.sh writes it)"
  # The key in the repo (agent, install.sh, install.ps1) must be the public half of the private key used here.
  # shellcheck disable=SC2016 # JavaScript, not shell
  node --input-type=module -e '
    import { createPrivateKey, createPublicKey } from "node:crypto";
    import { readFileSync } from "node:fs";
    const [key, root] = process.argv.slice(1);
    const want = createPublicKey(createPrivateKey(readFileSync(key))).export({ type: "spki", format: "pem" }).toString().trim();
    for (const f of ["agent/src/update_key.ts", "install.sh", "install.ps1"]) {
      const text = readFileSync(`${root}/${f}`, "utf8").replace(/\r/g, "");
      if (!text.includes(want)) { console.error(`release: ${f} does not contain the public key of ${key}`); process.exit(1); }
    }' "$KEY" "$ROOT"
fi
if [ -n "$PUBLISH" ]; then
  command -v gh >/dev/null || die "gh (GitHub CLI) is needed for --publish"
  [ -z "$(git -C "$ROOT" status --porcelain)" ] || die "the working tree is not clean"
  ! git -C "$ROOT" rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || die "tag v$VERSION already exists"
  [ -z "$NO_APK" ] || die "--publish includes the APK (drop --no-apk)"
  notes=$(awk -v v="$VERSION" 'index($0, "## [" v "]") == 1 {f=1; next} /^## \[/ {f=0} f' "$ROOT/CHANGELOG.md")
  [ -n "$notes" ] || die "CHANGELOG.md has no \"## [$VERSION]\" section"
fi

OUT="$ROOT/release/$VERSION"
CACHE="$ROOT/release/.cache"
STAGE="$OUT/stage"
rm -rf "$OUT"
mkdir -p "$OUT" "$CACHE" "$STAGE"
export SOURCE_DATE_EPOCH=${SOURCE_DATE_EPOCH:-$(git -C "$ROOT" log -1 --format=%ct)}

# ---- agent build ---------------------------------------------------------------------------------------------------
echo "==> building the agent"
(cd "$ROOT/agent" && "$LIMITED" npm ci --include=dev --no-audit --no-fund >/dev/null && "$LIMITED" npm run -s build)

# ---- Node.js runtime -----------------------------------------------------------------------------------------------
NODE_VERSION=${TIPHYS_NODE_VERSION:-}
if [ -z "$NODE_VERSION" ]; then
  NODE_VERSION=$(curl -fsSL https://nodejs.org/dist/latest-v24.x/SHASUMS256.txt | sed -n 's/.*node-v\(24\.[0-9]*\.[0-9]*\)-linux-x64\.tar\.xz$/\1/p' | head -1)
  [ -n "$NODE_VERSION" ] || die "could not find the newest Node.js 24"
fi
echo "==> Node.js $NODE_VERSION"
SUMS="$CACHE/node-v$NODE_VERSION-SHASUMS256.txt"
[ -s "$SUMS" ] || curl -fsSL -o "$SUMS" "https://nodejs.org/dist/v$NODE_VERSION/SHASUMS256.txt"

node_runtime() { # <platform> <dest dir> — official runtime, checksum-verified; only the node binary and its license
  local p=$1 dest=$2 file
  case $p in
    linux-*) file="node-v$NODE_VERSION-$p.tar.xz" ;;
    darwin-*) file="node-v$NODE_VERSION-$p.tar.gz" ;;
    win-*) file="node-v$NODE_VERSION-$p.zip" ;;
  esac
  if [ ! -s "$CACHE/$file" ]; then
    curl -fsSL -o "$CACHE/$file.part" "https://nodejs.org/dist/v$NODE_VERSION/$file"
    mv "$CACHE/$file.part" "$CACHE/$file"
  fi
  local want got
  want=$(awk -v f="$file" '$2 == f { print $1 }' "$SUMS")
  got=$(sha256sum "$CACHE/$file" | cut -d' ' -f1)
  [ -n "$want" ] && [ "$want" = "$got" ] || { rm -f "$CACHE/$file"; die "checksum mismatch for $file"; }
  local x; x=$(mktemp -d)
  case $file in
    *.zip) python3 -I -m zipfile -e "$CACHE/$file" "$x" ;;
    *) tar -xf "$CACHE/$file" -C "$x" ;;
  esac
  local top="$x/${file%.tar.*}"; top=${top%.zip}
  mkdir -p "$dest"
  if [[ $p == win-* ]]; then
    cp "$top/node.exe" "$top/LICENSE" "$dest/"
  else
    mkdir -p "$dest/bin"
    cp "$top/bin/node" "$dest/bin/node"
    cp "$top/LICENSE" "$dest/"
  fi
  rm -rf "$x"
}

# ---- bundles -------------------------------------------------------------------------------------------------------
IFS=, read -r -a PLATS <<< "$PLATFORMS"
for p in "${PLATS[@]}"; do
  case $p in
    linux-x64|linux-arm64|darwin-arm64|darwin-x64|win-x64) ;;
    *) die "unknown platform $p" ;;
  esac
  os=${p%-*} cpu=${p#*-}
  npm_os=$os; [ "$os" = win ] && npm_os=win32
  name="tiphys-agent-$VERSION-$p"
  dir="$STAGE/$name"
  echo "==> $name"
  mkdir -p "$dir"
  cp -r "$ROOT/agent/dist" "$ROOT/agent/helpers" "$ROOT/agent/package.json" "$ROOT/agent/package-lock.json" "$dir/"
  cp -r "$ROOT/display" "$dir/display"  # Game mode kiosk page (defaultDisplayDir(): ../display next to dist/)
  find "$dir" -name '*.map' -delete
  find "$dir/helpers" -name __pycache__ -prune -exec rm -rf {} +
  # Production dependencies for the target OS/CPU: npm picks the optional packages (the Claude Agent SDK's native
  # binary) by --os/--cpu/--libc instead of this machine's.
  libc=(); [ "$os" = linux ] && libc=(--libc=glibc)
  (cd "$dir" && "$LIMITED" npm ci --omit=dev --os="$npm_os" --cpu="$cpu" "${libc[@]}" --ignore-scripts --no-audit --no-fund >/dev/null)
  sdk="@anthropic-ai/claude-agent-sdk-$npm_os-$cpu"
  [ -d "$dir/node_modules/$sdk" ] || die "$sdk missing in $name"
  for other in "$dir"/node_modules/@anthropic-ai/claude-agent-sdk-*; do
    [ "$(basename "$other")" = "claude-agent-sdk-$npm_os-$cpu" ] || die "foreign SDK package $(basename "$other") in $name"
  done
  natives=$(find "$dir/node_modules" -name '*.node' | sed "s#$dir/##")
  [ -z "$natives" ] || echo "    note: native addons in $name: $natives"
  rm -f "$dir/package-lock.json"
  node_runtime "$p" "$dir/node"
  if [ -n "$HELPERS" ]; then
    exe=; [ "$os" = win ] && exe=.exe
    if [ -f "$HELPERS/tiphys-desktop-$p$exe" ]; then
      install -m 755 "$HELPERS/tiphys-desktop-$p$exe" "$dir/helpers/tiphys-desktop$exe"
      echo "    + desktop helper"
    fi
  fi
  if [ "$os" = win ]; then
    (cd "$STAGE" && find "$name" -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} + && python3 -I -m zipfile -c "$OUT/$name.zip" "$name")
  else
    tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" -C "$STAGE" -cf - "$name" | gzip -n -9 > "$OUT/$name.tar.gz"
  fi
  rm -rf "$dir"
done
rm -rf "$STAGE"

# ---- APK -----------------------------------------------------------------------------------------------------------
if [ -z "$NO_APK" ]; then
  echo "==> APK"
  [ -f "$HOME/.config/tiphys/release/key.properties" ] || die "no APK signing key (~/.config/tiphys/release/key.properties); see docs/setup-guide.md › Signing key"
  # shellcheck disable=SC1091 # Flutter/JDK paths from tools/setup-dev.sh
  [ -f "$HOME/opt/tiphys-env.sh" ] && . "$HOME/opt/tiphys-env.sh"
  (cd "$ROOT/app" && "$LIMITED" flutter build apk --release --target-platform android-arm64 --obfuscate --split-debug-info=build/symbols)
  cp "$ROOT/app/build/app/outputs/flutter-apk/app-release.apk" "$OUT/tiphys-$VERSION.apk"
fi

# ---- checksums, signature, packaging -------------------------------------------------------------------------------
echo "$VERSION" > "$OUT/VERSION"
cp "$ROOT/install.sh" "$ROOT/install.ps1" "$OUT/"
(cd "$OUT" && find . -maxdepth 1 -type f ! -name 'SHA256SUMS*' -printf '%f\n' | LC_ALL=C sort | xargs sha256sum > SHA256SUMS)
if [ -z "$UNSIGNED" ]; then
  # shellcheck disable=SC2016 # JavaScript, not shell
  node --input-type=module -e '
    import { createPrivateKey, createPublicKey, sign, verify } from "node:crypto";
    import { readFileSync, writeFileSync } from "node:fs";
    const [key, sums, out] = process.argv.slice(1);
    const priv = createPrivateKey(readFileSync(key));
    const data = readFileSync(sums);
    const sig = sign(null, data, priv);
    if (!verify(null, data, createPublicKey(priv), sig)) process.exit(1);
    writeFileSync(out, sig);' "$KEY" "$OUT/SHA256SUMS" "$OUT/SHA256SUMS.sig"
  # Same check install.sh does, with the key embedded in install.sh.
  sed -n "/^PUBKEY='/,/'$/p" "$ROOT/install.sh" | sed "s/^PUBKEY='//; s/'$//" > "$OUT/.pub.pem"
  openssl pkeyutl -verify -pubin -inkey "$OUT/.pub.pem" -rawin -in "$OUT/SHA256SUMS" -sigfile "$OUT/SHA256SUMS.sig" >/dev/null || die "signature does not verify with install.sh's key"
  rm -f "$OUT/.pub.pem"
  echo "==> signed SHA256SUMS"
fi
# Package manager drafts with this release's checksums (not uploaded; see packaging/README.md).
mkdir -p "$OUT/packaging"
sum() { awk -v f="$1" '$2 == f { print $1 }' "$OUT/SHA256SUMS"; }
for t in "$ROOT"/packaging/aur/PKGBUILD "$ROOT"/packaging/homebrew/tiphys-agent.rb "$ROOT"/packaging/winget/*.yaml; do
  sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@SHA_LINUX_X64@/$(sum "tiphys-agent-$VERSION-linux-x64.tar.gz")/g" \
    -e "s/@SHA_LINUX_ARM64@/$(sum "tiphys-agent-$VERSION-linux-arm64.tar.gz")/g" \
    -e "s/@SHA_DARWIN_ARM64@/$(sum "tiphys-agent-$VERSION-darwin-arm64.tar.gz")/g" \
    -e "s/@SHA_DARWIN_X64@/$(sum "tiphys-agent-$VERSION-darwin-x64.tar.gz")/g" \
    -e "s/@SHA_WIN_X64@/$(sum "tiphys-agent-$VERSION-win-x64.zip")/g" "$t" > "$OUT/packaging/$(basename "$t")"
done

echo "==> release/$VERSION:"
ls -la "$OUT"

if [ -n "$PUBLISH" ]; then
  mapfile -t assets < <(find "$OUT" -maxdepth 1 -type f | LC_ALL=C sort)
  gh release create "v$VERSION" --repo aurict/tiphys --target "$(git -C "$ROOT" rev-parse HEAD)" --title "Tiphys $VERSION" --notes "$notes" "${assets[@]}"
  echo "published v$VERSION"
else
  echo "dry run: nothing uploaded (add --publish)"
fi
