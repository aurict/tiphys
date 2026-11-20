#!/usr/bin/env bash
# Creates the release signing key pair (ed25519) ONCE, on the release PC (PLAN K1/K8).
#   private: ~/.config/tiphys/release/update-signing.key  (0600; never commit, never copy to CI; back it up offline)
#   public:  written into agent/src/update_key.ts, install.sh and install.ps1 (commit these three files)
# Refuses to overwrite an existing key: a new key means installs from older installers/agents can no longer
# verify new releases (they would need a manual reinstall).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
KEY="$HOME/.config/tiphys/release/update-signing.key"
[ ! -e "$KEY" ] || { echo "$KEY already exists; not overwriting (delete it yourself only if you really mean to rotate)" >&2; exit 1; }
mkdir -p "$(dirname "$KEY")"
chmod 700 "$(dirname "$KEY")"
umask 077
# shellcheck disable=SC2016 # JavaScript, not shell
node --input-type=module -e '
  import { generateKeyPairSync } from "node:crypto";
  import { readFileSync, writeFileSync } from "node:fs";
  const [key, root] = process.argv.slice(1);
  const { publicKey, privateKey } = generateKeyPairSync("ed25519");
  writeFileSync(key, privateKey.export({ type: "pkcs8", format: "pem" }), { mode: 0o600, flag: "wx" });
  const pem = publicKey.export({ type: "spki", format: "pem" }).toString().trim();
  const put = (file, re, value) => {
    const p = `${root}/${file}`;
    const text = readFileSync(p, "utf8");
    if (!re.test(text)) throw new Error(`key markers not found in ${file}`);
    writeFileSync(p, text.replace(re, (_, a, b) => a + value + b));
  };
  put("agent/src/update_key.ts", /(\/\/ BEGIN TIPHYS UPDATE KEY\n)[\s\S]*?(\n\/\/ END TIPHYS UPDATE KEY)/, `export const UPDATE_PUBLIC_KEY = \`${pem}\`;`);
  put("install.sh", /(# BEGIN TIPHYS UPDATE KEY\n)[\s\S]*?(\n# END TIPHYS UPDATE KEY)/, `PUBKEY=\x27${pem}\x27`);
  put("install.ps1", /(# BEGIN TIPHYS UPDATE KEY\r?\n)[\s\S]*?(\r?\n# END TIPHYS UPDATE KEY)/, `$PubKey = @\x27\n${pem}\n\x27@`);
  console.log(pem);' "$KEY" "$ROOT"
echo
echo "Private key: $KEY (keep it secret; back it up offline)."
echo "Public key written to agent/src/update_key.ts, install.sh and install.ps1 — review and commit them."
