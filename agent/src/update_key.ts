// Public half of the release signing key (ed25519, SPKI PEM). `tools/release-keygen.sh` creates the key pair on the
// release PC (private key: ~/.config/tiphys/release/update-signing.key, never committed) and writes the public key
// here and into install.sh / install.ps1. Until then this is a placeholder and self-update refuses to run.
// BEGIN TIPHYS UPDATE KEY
export const UPDATE_PUBLIC_KEY = `-----BEGIN PUBLIC KEY-----
MCowBQYDK2VwAyEARrrX7fMCJXSF0JVUQVoAmbhDLcCYSQo6UdBloCXJ9/A=
-----END PUBLIC KEY-----`;
// END TIPHYS UPDATE KEY

export function isPlaceholderKey(key: string): boolean {
  return !key.includes("BEGIN PUBLIC KEY");
}
