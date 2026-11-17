// Redaction of secrets in text that leaves the agent's own process (incident logs and context, later analysis input).
// Pattern based (PLAN.md §13.0): JWTs, Bearer/Basic credentials, key=value pairs whose key names a secret, passwords in
// URIs, PEM private keys and well-known API key formats. Known secret values (13.3: the stacks' .env values) can be
// registered with setKnownSecrets and are replaced by `[GİZLİ:<KEY>]`. Every quantifier is bounded, so hostile input
// can't make a pattern backtrack for long.

const MASK = "[GİZLİ]";

/** Known values: source → [{key, value}]. Values shorter than MIN_KNOWN are ignored (too many false hits). */
const known = new Map<string, Array<{ key: string; value: string }>>();
const MIN_KNOWN = 6;

/** Registers (or with an empty list, clears) the known secret values of one source, e.g. a stack's .env file. */
export function setKnownSecrets(source: string, entries: Array<{ key: string; value: string }>): void {
  const list = entries.filter((e) => e.value.length >= MIN_KNOWN && /^[A-Za-z_][A-Za-z0-9_.]{0,127}$/.test(e.key));
  if (list.length) known.set(source, list);
  else known.delete(source);
}

function replaceKnown(text: string): string {
  const all = [...known.values()].flat().sort((a, b) => b.value.length - a.value.length);
  for (const { key, value } of all) {
    if (text.includes(value)) text = text.split(value).join(`[GİZLİ:${key}]`);
  }
  return text;
}

const SECRET_KEY = String.raw`[A-Za-z0-9_.-]{0,40}?(?:passw(?:or)?d|pwd|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|credentials?|auth[_-]?key|session[_-]?id|cookie)[A-Za-z0-9_.-]{0,40}`;

const RULES: Array<[RegExp, string | ((...m: string[]) => string)]> = [
  // PEM private keys (also a truncated block with no END line: the rest of the text goes).
  [/-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----[\s\S]*?(?:-----END [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----|$)/g, "[GİZLİ:PEM]"],
  // user:password@ in URIs (postgres://, redis://, https://, amqp://…).
  [/\b([a-z][a-z0-9+.-]{1,20}:\/\/[^\s:/@]{0,200}:)([^\s@/]{1,500})(@)/gi, (_m, a, _p, c) => `${a}${MASK}${c}`],
  // JWT (header.payload[.signature]).
  [/\beyJ[A-Za-z0-9_-]{5,4000}\.eyJ[A-Za-z0-9_-]{5,8000}(?:\.[A-Za-z0-9_-]{0,2000})?/g, "[GİZLİ:JWT]"],
  // Well-known key formats.
  [/\b(?:AKIA|ASIA|AGPA|AIDA|AROA)[0-9A-Z]{16}\b/g, "[GİZLİ:AWS]"],
  [/\b(?:gh[pousr]_[A-Za-z0-9]{30,255}|github_pat_[A-Za-z0-9_]{22,255})\b/g, "[GİZLİ:GITHUB]"],
  [/\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,255}\b|\bwhsec_[A-Za-z0-9]{10,255}\b/g, "[GİZLİ:STRIPE]"],
  [/\bxox[abposr]-[A-Za-z0-9-]{10,255}/g, "[GİZLİ:SLACK]"],
  [/\bAIza[0-9A-Za-z_-]{35}\b/g, "[GİZLİ:GOOGLE]"],
  [/\bsk-(?:ant-)?[A-Za-z0-9_-]{20,255}/g, "[GİZLİ:APIKEY]"],
  [/\bt(?:ph|ps|pv|pc)_[A-Za-z0-9_-]{20,100}/g, "[GİZLİ:TIPHYS]"],
  // Authorization header values and bare Bearer/Basic credentials.
  [/\b(authorization\s{0,3}[:=]\s{0,3})("?)(?:(?:bearer|basic|token|digest)\s{1,3})?[^\s",;]{1,4000}/gi, (_m, a, q) => `${a}${q}${MASK}`],
  [/\b(bearer|basic)(\s{1,3})[A-Za-z0-9._~+/=-]{8,4000}/gi, (_m, a, s) => `${a}${s}${MASK}`],
  // CLI flags: --password x, --token=x, -pSECRET (mysql style, only directly after "mysql"/"mariadb"/"mysqldump").
  [/(--?(?:password|passwd|pass|token|secret|api-key|apikey)(?:=|\s{1,3}))("[^"\n]{0,500}"|'[^'\n]{0,500}'|[^\s"']{1,500})/gi, (_m, a) => `${a}${MASK}`],
  [/\b((?:mysql|mariadb|mysqldump)\b[^\n]{0,200}?\s-p)([^\s]{1,500})/g, (_m, a) => `${a}${MASK}`],
  // key=value, key: value, "key": "value" where the key names a secret.
  [
    new RegExp(String.raw`(?<![A-Za-z0-9_])(${SECRET_KEY})(\s{0,3}["']?\s{0,3}[=:]\s{0,3})("[^"\n]{0,2000}"|'[^'\n]{0,2000}'|[^\s"'&,;]{1,2000})`, "gi"),
    (_m, k, sep, v) => {
      if (v.startsWith("[GİZLİ")) return `${k}${sep}${v}`;
      const q = v.startsWith('"') || v.startsWith("'") ? v[0]! : "";
      if (q && v.slice(1, 7) === "[GİZLİ") return `${k}${sep}${v}`;
      return `${k}${sep}${q}${MASK}${q}`;
    },
  ],
];

/** Returns the text with secrets replaced. */
export function redact(text: string): string {
  let out = known.size ? replaceKnown(text) : text;
  for (const [re, rep] of RULES) out = out.replace(re, rep as never);
  return out;
}
