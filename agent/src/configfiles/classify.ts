// Secret classification of .env entries (PLAN.md §13.3): the key name, a password inside a URI, a random-looking
// value, or the user's own mark (secrets-meta.json) — the mark wins. Erring on the side of "secret" only costs a tap.

export type SecretReason = "mark" | "name" | "uriPassword" | "entropy";

const NAME = /PASS|PWD|SECRET|TOKEN|KEY|PRIVATE|CREDENTIAL|DSN/i;
/** Names that point at a secret rather than hold one (POSTGRES_PASSWORD_FILE=/run/secrets/db). */
const NAME_EXEMPT = /_(?:FILE|PATH|DIR)$/i;
const URI_PASSWORD = /^[a-z][a-z0-9+.-]{1,20}:\/\/[^\s/@:]*:[^\s/@]+@/i;
const TOKEN_CHARS = /^[A-Za-z0-9+/=_.~-]+$/;

/** Shannon entropy in bits per character. */
export function entropy(s: string): number {
  const counts = new Map<string, number>();
  for (const c of s) counts.set(c, (counts.get(c) ?? 0) + 1);
  let h = 0;
  for (const n of counts.values()) {
    const p = n / s.length;
    h -= p * Math.log2(p);
  }
  return h;
}

/** A generated token: long, token characters only, mixed case + digits (or long hex), high entropy. */
export function looksRandom(v: string): boolean {
  if (v.length < 20 || v.length > 4096 || !TOKEN_CHARS.test(v) || /^[/~.]/.test(v)) return false;
  const hex = /^[a-f0-9]{32,}$/i.test(v);
  const mixed = /[a-z]/.test(v) && /[A-Z]/.test(v) && /[0-9]/.test(v);
  return (hex || mixed) && entropy(v) >= 3.5;
}

export function classify(key: string, value: string, mark?: boolean): { secret: boolean; reason: SecretReason | null } {
  if (mark !== undefined) return { secret: mark, reason: "mark" };
  if (NAME.test(key) && !NAME_EXEMPT.test(key)) return { secret: true, reason: "name" };
  if (URI_PASSWORD.test(value)) return { secret: true, reason: "uriPassword" };
  if (looksRandom(value)) return { secret: true, reason: "entropy" };
  return { secret: false, reason: null };
}
