// Redaction of secrets in text that leaves the agent's own process (incident logs and context, later analysis input).
// Pattern based (PLAN.md §13.0): JWTs, Bearer/Basic credentials, key=value pairs whose key names a secret, passwords in
// URIs, PEM private keys and well-known API key formats. Known secret values (13.3: the stacks' .env values) can be
// registered with setKnownSecrets and are replaced by `[GİZLİ:<KEY>]`. Every quantifier is bounded, so hostile input
// can't make a pattern backtrack for long.

const MASK = "[GİZLİ]";

/** Known values: source → [{key, value}]. Values shorter than MIN_KNOWN are ignored (too many false hits). */
const known = new Map<string, Array<{ key: string; value: string }>>();
const MIN_KNOWN = 6;
const KNOWN_KEY = /^[A-Za-z_][A-Za-z0-9_.]{0,127}$/;

export type KnownSecret = { key: string; value: string };

const usable = (entries: KnownSecret[]) => entries.filter((e) => e.value.length >= MIN_KNOWN && KNOWN_KEY.test(e.key));

/** Registers (or with an empty list, clears) the known secret values of one source, e.g. a stack's .env file. */
export function setKnownSecrets(source: string, entries: KnownSecret[]): void {
  const list = usable(entries);
  if (list.length) known.set(source, list);
  else known.delete(source);
}

const escapeRe = (s: string) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

/**
 * The value as it may appear in text: as is, URL-encoded (in URIs, query strings) and base64 (with and without
 * padding). Short (< 8) or purely alphabetic values (postgres, admin, changeme) are only replaced as a whole word, so
 * they don't mask parts of ordinary words.
 */
const patterns = new Map<string, RegExp>();
function knownPattern(value: string): RegExp {
  const hit = patterns.get(value);
  if (hit) return hit;
  if (patterns.size > 2000) patterns.clear();
  const forms = new Set([value, encodeURIComponent(value)]);
  const b64 = Buffer.from(value, "utf8").toString("base64");
  forms.add(b64);
  forms.add(b64.replace(/=+$/, ""));
  const alt = [...forms].filter((f) => f.length >= MIN_KNOWN).sort((a, b) => b.length - a.length).map(escapeRe).join("|");
  const wordy = value.length < 8 || /^[A-Za-z]+$/.test(value);
  const re = new RegExp(wordy ? `(?<![A-Za-z0-9_])(?:${alt})(?![A-Za-z0-9_])` : `(?:${alt})`, "g");
  patterns.set(value, re);
  return re;
}

function replaceKnown(text: string, extra: KnownSecret[]): string {
  const all = [...[...known.values()].flat(), ...usable(extra)].sort((a, b) => b.value.length - a.value.length);
  for (const { key, value } of all) text = text.replace(knownPattern(value), `[GİZLİ:${key}]`);
  return text;
}

// Same names configfiles/classify.ts treats as secret (PASS, *_KEY, DSN, SECRET, TOKEN, CREDENTIAL…); PASS, KEY and DSN
// only as a whole name component (DB_PASS, SIGNING_KEY, SENTRY_DSN), not inside words (passed, keyboard, monkey).
const SECRET_KEY = String.raw`[A-Za-z0-9_.-]{0,40}?(?:passw(?:or)?d|pwd|secret|token|api[_-]?key|apikey|access[_-]?key|private[_-]?key|credentials?|auth[_-]?key|session[_-]?id|cookie|(?<![A-Za-z])pass(?:phrase)?(?![A-Za-z])|[_.-]key(?![A-Za-z])|(?<![A-Za-z])dsn(?![A-Za-z]))[A-Za-z0-9_.-]{0,40}`;

/** One base64 line of a PEM body, optionally after a log timestamp. */
const PEM_LINE = /^[0-9TZ:.+ -]{0,40}[A-Za-z0-9+/=]{16,76}[ \t\r]*$/;
const PEM_BEGIN = /-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----/;
const PEM_END = /-----END [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----/;
const PEM_MAX_LINES = 200;

/**
 * A PEM block cut at either end (log tail, line limit): BEGIN + the base64 lines after it, or the base64 lines before
 * an END line. Line based and bounded (a regex over the joined text would be quadratic on long base64 runs).
 */
function redactPem(text: string): string {
  if (!text.includes("PRIVATE KEY-----")) return text;
  const lines = text.split("\n");
  const out: string[] = [];
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i]!;
    const begin = PEM_BEGIN.exec(l);
    if (begin) {
      out.push(l.slice(0, begin.index) + "[GİZLİ:PEM]");
      let n = 0;
      while (n < PEM_MAX_LINES && i + 1 < lines.length && PEM_LINE.test(lines[i + 1]!)) (i++, n++);
      continue;
    }
    const end = PEM_END.exec(l);
    if (end) {
      let n = 0;
      while (n < PEM_MAX_LINES && out.length && PEM_LINE.test(out.at(-1)!)) (out.pop(), n++);
      out.push("[GİZLİ:PEM]" + l.slice(end.index + end[0].length));
      continue;
    }
    out.push(l);
  }
  return out.join("\n");
}

const RULES: Array<[RegExp, string | ((...m: string[]) => string)]> = [
  // PEM private keys across lines (callers redact joined text, not line by line); blocks cut at either end: redactPem.
  [/-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----[\s\S]{0,20000}?-----END [A-Z0-9 ]{0,40}PRIVATE KEY(?: BLOCK)?-----/g, "[GİZLİ:PEM]"],
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

/**
 * Returns the text with secrets replaced. `extra`: known values for this call only (e.g. the incident container's
 * secret environment values), on top of the registered ones.
 */
export function redact(text: string, extra: KnownSecret[] = []): string {
  let out = known.size || extra.length ? replaceKnown(text, extra) : text;
  for (const [re, rep] of RULES) out = out.replace(re, rep as never);
  return redactPem(out);
}
