// Lossless .env parser/serializer (PLAN.md §13.3). Follows Docker Compose's .env syntax (compose-go dotenv): comments,
// blank lines, `export ` prefix, spaces around `=`, unquoted values with ` #` inline comments, single quotes (literal,
// `\'` escapes the quote), double quotes (escape sequences, may span lines), and a bare `KEY` (inherited from the
// environment). Every line keeps its raw text: serialize(parse(text)) === text, and an edit only rewrites the lines of
// the keys it touches. Lines this parser can't read (other key characters, `KEY: value`, unterminated quotes, text after
// a closing quote) are kept verbatim as "invalid" nodes and are not editable.
//
// Value model: what compose reads before `${VAR}` interpolation. Double-quoted escapes are resolved (`\$` becomes
// `$$`, compose's own escape for a literal `$`); single-quoted values are literal. An edit keeps the entry's quoting
// when it can, so an unquoted or double-quoted value keeps its interpolation (`${VAR}`, `$$`); new entries, and values
// with any other `$`, are written literally.

export const KEY_RE = /^[A-Za-z_][A-Za-z0-9_.]*$/;
/** Longest quoted value scanned across lines; past it the opening line counts as unterminated. */
const MAX_QUOTED = 64 * 1024;
/** compose-go's isSpace: whitespace other than a line break. */
const SP = "[ \\t\\f\\v\\r\\u0085\\u00a0]";

export type Quote = "" | "'" | '"';

export interface EntryNode {
  type: "entry";
  /** Exact source text, including the line break(s). */
  raw: string;
  /** 1-based first line. */
  line: number;
  key: string;
  value: string;
  /** `KEY` without `=`: compose takes the value from its own environment. */
  inherited: boolean;
  quote: Quote;
  /** Indentation and `export ` prefix. */
  head: string;
  /** Text after the value on its last line (spaces, inline comment); no line break. */
  trailer: string;
  /** Line break ending the entry ("" at the end of a file without one). */
  eol: string;
}

export interface OtherNode {
  type: "blank" | "comment" | "invalid";
  raw: string;
  line: number;
  /** invalid only: syntax | unterminatedQuote | trailingText */
  reason?: string;
}

export type EnvNode = EntryNode | OtherNode;

export interface EnvDoc {
  nodes: EnvNode[];
  /** Line break used for new lines: the first one in the file. */
  eol: "\n" | "\r\n";
}

function splitEol(raw: string): [string, string] {
  if (raw.endsWith("\r\n")) return [raw.slice(0, -2), "\r\n"];
  if (raw.endsWith("\n")) return [raw.slice(0, -1), "\n"];
  return [raw, ""];
}

const CTRL: Record<string, string> = { a: "\x07", b: "\b", f: "\f", n: "\n", r: "\r", t: "\t", v: "\v", '"': '"', "\\": "\\", $: "$$" };

/** compose-go expandEscapes: \a \b \f \n \r \t \v \" \\ \$ (→ $$) and \0ooo octal; anything else stays as written. */
function expandEscapes(s: string): string {
  return s.replace(/\\(?:[abcfnrtv$"\\]|0\d{0,3})/g, (m) => {
    const c = m[1]!;
    if (c === "0") return /^\\0[0-7]{3}$/.test(m) ? String.fromCharCode(parseInt(m.slice(2), 8)) : m;
    return CTRL[c] ?? m;
  });
}

const HEAD_KEY = new RegExp(`^(${SP}*(?:export[ \\t]+)?)([A-Za-z_][A-Za-z0-9_.]*)`);
const ONLY_SPACE = new RegExp(`^${SP}*$`);
const EQ = new RegExp(`^${SP}*=${SP}*`);
const TRAILER_OK = new RegExp(`^${SP}*(?:#.*)?$`);

export function parseEnv(text: string): EnvDoc {
  const lines = text.match(/[^\n]*\n|[^\n]+$/g) ?? [];
  const nodes: EnvNode[] = [];
  const first = lines[0] ?? "";
  const eol: EnvDoc["eol"] = first.endsWith("\r\n") ? "\r\n" : "\n";
  for (let i = 0; i < lines.length; ) {
    const raw = lines[i]!;
    const [body, le] = splitEol(raw);
    const line = i + 1;
    if (/^\s*$/.test(body)) {
      nodes.push({ type: "blank", raw, line });
      i++;
      continue;
    }
    if (/^\s*#/.test(body)) {
      nodes.push({ type: "comment", raw, line });
      i++;
      continue;
    }
    const m = HEAD_KEY.exec(body);
    const after = m ? body.slice(m[0].length) : "";
    const eq = m ? EQ.exec(after) : null;
    if (!m || (!eq && !ONLY_SPACE.test(after))) {
      nodes.push({ type: "invalid", raw, line, reason: "syntax" });
      i++;
      continue;
    }
    const head = m[1]!;
    const key = m[2]!;
    if (!eq) {
      nodes.push({ type: "entry", raw, line, key, value: "", inherited: true, quote: "", head, trailer: after, eol: le });
      i++;
      continue;
    }
    const v = after.slice(eq[0].length);
    const q = v[0];
    if (q !== '"' && q !== "'") {
      const cut = v.indexOf(" #");
      const value = (cut >= 0 ? v.slice(0, cut) : v).trimEnd();
      nodes.push({ type: "entry", raw, line, key, value, inherited: false, quote: "", head, trailer: v.slice(value.length), eol: le });
      i++;
      continue;
    }
    // Quoted: scan like compose-go, continuing on the next lines until the closing quote.
    let s = v + le;
    let j = i;
    let pos = 1;
    let esc = false;
    let chars = "";
    let closed = -1;
    for (;;) {
      for (; pos < s.length; pos++) {
        const c = s[pos]!;
        if (c !== q) {
          if (!esc && c === "\\") {
            esc = true;
            continue;
          }
          if (esc) {
            esc = false;
            chars += "\\";
          }
          chars += c;
          continue;
        }
        if (esc) {
          esc = false;
          chars += c;
          continue;
        }
        closed = pos;
        break;
      }
      if (closed >= 0 || j + 1 >= lines.length || s.length > MAX_QUOTED) break;
      j++;
      s += lines[j]!;
    }
    if (closed < 0) {
      nodes.push({ type: "invalid", raw, line, reason: "unterminatedQuote" });
      i++;
      continue;
    }
    const [trailer, lastEol] = splitEol(s.slice(closed + 1));
    const fullRaw = lines.slice(i, j + 1).join("");
    if (!TRAILER_OK.test(trailer)) {
      // compose would read the rest as another statement; keep the whole span as-is and don't offer it for editing.
      nodes.push({ type: "invalid", raw: fullRaw, line, reason: "trailingText" });
    } else {
      const value = q === '"' ? expandEscapes(chars) : chars;
      nodes.push({ type: "entry", raw: fullRaw, line, key, value, inherited: false, quote: q, head, trailer, eol: lastEol });
    }
    i = j + 1;
  }
  return { nodes, eol };
}

export function serializeEnv(doc: EnvDoc): string {
  return doc.nodes.map((n) => n.raw).join("");
}

export const entries = (doc: EnvDoc) => doc.nodes.filter((n): n is EntryNode => n.type === "entry");

/** Effective entries: the last occurrence of each key wins (as in compose), in file order of that occurrence. */
export function effective(doc: EnvDoc): Map<string, EntryNode> {
  const out = new Map<string, EntryNode>();
  for (const e of entries(doc)) {
    out.delete(e.key);
    out.set(e.key, e);
  }
  return out;
}

// --- Encoding values ------------------------------------------------------------------------------------------------

const SAFE_UNQUOTED = /^[A-Za-z0-9_./:@%+,=-]*$/;
const fitsUnquoted = (v: string) => !/[\r\n]/.test(v) && v === v.trim() && !/^['"]/.test(v) && !v.includes(" #");
const fitsSingle = (v: string) => !/['\r\n]/.test(v) && !v.endsWith("\\");

function doubleQuoted(v: string, literal: boolean): string {
  let s = v.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r");
  if (literal) s = s.replace(/\$/g, "\\$");
  return `"${s}"`;
}

/**
 * Text written for a value. An existing entry keeps its quoting when that can hold the value (so interpolation
 * semantics don't change); otherwise, and for new entries: unquoted if plain, single quotes (literal) if possible,
 * else double quotes. Double quotes replacing a literal (new or single-quoted) value escape `$`.
 * A value with a `$` but no explicit compose syntax (`${…}`, `$$`) is written literally even into an unquoted or
 * double-quoted entry: compose would read `pa$word` there as `pa` + $word (a mangled secret).
 */
export function encodeValue(value: string, existing?: EntryNode): string {
  let style = existing && !existing.inherited ? existing.quote : null;
  if ((style === "" || style === '"') && value.includes("$") && !/\$\{|\$\$/.test(value)) style = null;
  if (style === "" && fitsUnquoted(value)) return value;
  if (style === "'" && fitsSingle(value)) return `'${value}'`;
  if (style === '"' || style === "") return doubleQuoted(value, false);
  if (SAFE_UNQUOTED.test(value)) return value;
  if (fitsSingle(value)) return `'${value}'`;
  return doubleQuoted(value, true);
}

// --- Edits ----------------------------------------------------------------------------------------------------------

export type EnvOp = { op: "set"; key: string; value: string } | { op: "unset"; key: string } | { op: "rename"; key: string; newKey: string };

export class EnvEditError extends Error {
  readonly code: "keyNotFound" | "keyExists" | "unterminatedQuote";
  /** The key, or for unterminatedQuote the line number. */
  readonly key: string;
  constructor(code: EnvEditError["code"], key: string) {
    super(code);
    this.code = code;
    this.key = key;
  }
}

/** Applies the ops in order and returns the new file text. Untouched lines are kept byte for byte. */
export function applyOps(doc: EnvDoc, ops: EnvOp[]): string {
  // compose reads an unterminated quote up to the next quote anywhere below: an edit could change what it swallows.
  const open = doc.nodes.find((n) => n.type === "invalid" && n.reason === "unterminatedQuote");
  if (open) throw new EnvEditError("unterminatedQuote", String(open.line));
  const nodes: EnvNode[] = doc.nodes.map((n) => ({ ...n }));
  const find = (key: string) => nodes.flatMap((n, i) => (n.type === "entry" && n.key === key ? [i] : []));
  for (const op of ops) {
    const at = find(op.key);
    if (op.op === "set") {
      const idx = at[at.length - 1];
      if (idx !== undefined) {
        const old = nodes[idx] as EntryNode;
        const trailer = old.inherited ? "" : old.trailer && !/^\s/.test(old.trailer) ? ` ${old.trailer}` : old.trailer;
        let enc = encodeValue(op.value, old);
        // `KEY= # c` would read as the value "# c".
        if (enc === "" && trailer.includes("#")) enc = '""';
        nodes[idx] = { ...old, raw: `${old.head}${old.key}=${enc}${trailer}${old.eol}`, value: op.value, inherited: false, quote: (enc[0] === '"' || enc[0] === "'" ? enc[0] : "") as Quote, trailer };
      } else {
        const last = nodes[nodes.length - 1];
        if (last && !last.raw.endsWith("\n")) {
          last.raw += doc.eol;
          if (last.type === "entry") last.eol = doc.eol;
        }
        const enc = encodeValue(op.value);
        nodes.push({ type: "entry", raw: `${op.key}=${enc}${doc.eol}`, line: 0, key: op.key, value: op.value, inherited: false, quote: (enc[0] === '"' || enc[0] === "'" ? enc[0] : "") as Quote, head: "", trailer: "", eol: doc.eol });
      }
    } else if (op.op === "unset") {
      if (!at.length) throw new EnvEditError("keyNotFound", op.key);
      for (const idx of at.reverse()) nodes.splice(idx, 1);
    } else {
      if (!at.length) throw new EnvEditError("keyNotFound", op.key);
      if (op.newKey !== op.key && find(op.newKey).length) throw new EnvEditError("keyExists", op.newKey);
      for (const idx of at) {
        const e = nodes[idx] as EntryNode;
        nodes[idx] = { ...e, key: op.newKey, raw: e.head + op.newKey + e.raw.slice(e.head.length + e.key.length) };
      }
    }
  }
  return nodes.map((n) => n.raw).join("");
}
