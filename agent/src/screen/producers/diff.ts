// `diff` topic payloads (PLAN.md §20 A-2 "diff"): the approval preview of a Tiphys Claude session's pending
// permission. Pure functions: Edit/MultiEdit/Write → a unified diff of the file as it is now against the file the tool
// would leave (context 3, at most 400 lines / 64 KB of hunk text, `truncated` + `more` = lines left out); a new file
// is all-added; NotebookEdit's new cell source is shown as text; Bash → command + reason; any other tool → its name
// and a short summary of its non-secret input fields. Everything textual goes through redact(). The caller decides
// whether a diff may be produced at all (screen.share.code on this host, Tiphys sessions only, path inside the root).
import { redact } from "../../redact.ts";

export interface Hunk {
  oldStart: number;
  newStart: number;
  /** " ctx", "+add", "-del" */
  lines: string[];
}

export interface DiffBody {
  hunks: Hunk[];
  added: number;
  removed: number;
  truncated: boolean;
  /** Diff lines left out by the limits. */
  more: number;
  binary: boolean;
}

export interface DiffLimits {
  context?: number;
  maxLines?: number;
  maxBytes?: number;
  /** Longer lines are cut (with "…"). */
  maxLineLen?: number;
  /** Middle parts longer than this (lines, either side) aren't aligned: all removed, then all added. */
  maxAlign?: number;
}

/** A NUL in the first 8000 characters = binary (same rule as the city's line counter). */
export const isBinary = (s: string) => s.slice(0, 8000).includes("\0");

/** Text → lines (a final newline doesn't make an extra empty line). */
export function splitLines(s: string): string[] {
  if (s === "") return [];
  const l = s.split(/\r?\n/);
  if (l[l.length - 1] === "") l.pop();
  return l;
}

type Op = [" " | "+" | "-", string];

/** Myers O(ND) edit script of a → b; null when more than maxD edits are needed (the trace is O(maxD²) ints). */
function myers(a: string[], b: string[], maxD: number): Op[] | null {
  const n = a.length, m = b.length, max = Math.min(n + m, maxD);
  const off = max + 1;
  const v = new Int32Array(2 * max + 3);
  const trace: Int32Array[] = [];
  for (let d = 0; d <= max; d++) {
    trace.push(v.slice());
    for (let k = -d; k <= d; k += 2) {
      let x = k === -d || (k !== d && v[off + k - 1]! < v[off + k + 1]!) ? v[off + k + 1]! : v[off + k - 1]! + 1;
      let y = x - k;
      while (x < n && y < m && a[x] === b[y]) x++, y++;
      v[off + k] = x;
      if (x >= n && y >= m) {
        // Walk the trace back.
        const ops: Op[] = [];
        let cx = n, cy = m;
        for (let dd = d; dd > 0; dd--) {
          const pv = trace[dd]!;
          const kk = cx - cy;
          const prevK = kk === -dd || (kk !== dd && pv[off + kk - 1]! < pv[off + kk + 1]!) ? kk + 1 : kk - 1;
          const px = pv[off + prevK]!, py = px - prevK;
          while (cx > px && cy > py) ops.push([" ", a[--cx]!]), cy--;
          if (cx === px) ops.push(["+", b[--cy]!]);
          else ops.push(["-", a[--cx]!]);
        }
        while (cx > 0 && cy > 0) ops.push([" ", a[--cx]!]), cy--;
        return ops.reverse();
      }
    }
  }
  return null;
}

/** Line edit script: common head/tail trimmed first (edits are local), the middle aligned with Myers. */
export function editScript(a: string[], b: string[], maxAlign = 3000): Op[] {
  let h = 0;
  while (h < a.length && h < b.length && a[h] === b[h]) h++;
  let t = 0;
  while (t < a.length - h && t < b.length - h && a[a.length - 1 - t] === b[b.length - 1 - t]) t++;
  const am = a.slice(h, a.length - t), bm = b.slice(h, b.length - t);
  const mid =
    (am.length <= maxAlign && bm.length <= maxAlign ? myers(am, bm, 500) : null) ??
    [...am.map((x): Op => ["-", x]), ...bm.map((x): Op => ["+", x])];
  return [...a.slice(0, h).map((x): Op => [" ", x]), ...mid, ...a.slice(a.length - t).map((x): Op => [" ", x])];
}

/** Unified diff of two texts within the limits. */
export function unifiedDiff(oldText: string, newText: string, o: DiffLimits = {}): DiffBody {
  const context = o.context ?? 3, maxLines = o.maxLines ?? 400, maxBytes = o.maxBytes ?? 64 * 1024, maxLen = o.maxLineLen ?? 400;
  if (isBinary(oldText) || isBinary(newText)) return { hunks: [], added: 0, removed: 0, truncated: false, more: 0, binary: true };
  const ops = editScript(splitLines(oldText), splitLines(newText), o.maxAlign);
  let added = 0, removed = 0;
  for (const [s] of ops) if (s === "+") added++; else if (s === "-") removed++;
  // Hunk ranges: changed lines ± context, merged when they touch.
  const ranges: Array<[number, number]> = [];
  ops.forEach(([s], i) => {
    if (s === " ") return;
    const lo = Math.max(0, i - context), hi = Math.min(ops.length - 1, i + context);
    const last = ranges[ranges.length - 1];
    if (last && lo <= last[1] + 1) last[1] = Math.max(last[1], hi);
    else ranges.push([lo, hi]);
  });
  // Line numbers at each op index.
  const oldAt = new Int32Array(ops.length + 1), newAt = new Int32Array(ops.length + 1);
  let on = 1, nn = 1;
  ops.forEach(([s], i) => {
    oldAt[i] = on;
    newAt[i] = nn;
    if (s !== "+") on++;
    if (s !== "-") nn++;
  });
  const hunks: Hunk[] = [];
  let lines = 0, bytes = 0, total = 0, truncated = false;
  for (const [lo, hi] of ranges) {
    total += hi - lo + 1;
    if (truncated) continue;
    const h: Hunk = { oldStart: oldAt[lo]!, newStart: newAt[lo]!, lines: [] };
    for (let i = lo; i <= hi; i++) {
      const [s, text] = ops[i]!;
      const line = s + redact(text.length > maxLen ? `${text.slice(0, maxLen - 1)}…` : text);
      if (lines >= maxLines || bytes + line.length + 1 > maxBytes) {
        truncated = true;
        break;
      }
      h.lines.push(line);
      lines++;
      bytes += line.length + 1;
    }
    if (h.lines.length) hunks.push(h);
  }
  return { hunks, added, removed, truncated, more: truncated ? total - lines : 0, binary: false };
}

const LANG: Record<string, string> = {
  ts: "ts", tsx: "ts", js: "ts", mjs: "ts", cjs: "ts", jsx: "ts", dart: "dart", py: "py", sh: "sh", bash: "sh", zsh: "sh",
  json: "json", jsonc: "json", yaml: "json", yml: "json", css: "css", scss: "css", go: "go", rs: "rust",
};

/** Language of the page's tokenizer from the file extension ("text" when it has none for it). */
export function langOf(path: string): string {
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? (LANG[name.slice(dot + 1).toLowerCase()] ?? "text") : "text";
}

type Rec = Record<string, unknown>;
const str = (v: unknown) => (typeof v === "string" ? v : null);

/** Tools whose preview is a file diff, and the input field holding the file. */
export const FILE_TOOLS: Readonly<Record<string, string>> = { Edit: "file_path", Write: "file_path", MultiEdit: "file_path", NotebookEdit: "notebook_path" };

/** The file path a tool works on (file tools, Read, Grep/Glob's `path`); null for others. */
export function toolPath(tool: string, input: unknown): string | null {
  const i = (input && typeof input === "object" ? input : {}) as Rec;
  return str(i[FILE_TOOLS[tool] ?? (tool === "Read" ? "file_path" : tool === "Grep" || tool === "Glob" ? "path" : "")]) ?? null;
}

/** Replaces old → new once (or every time); null when `old` isn't in the text (the edit would fail anyway). */
function replace(text: string, old: string, next: string, all: boolean): string | null {
  if (old === "") return null;
  const i = text.indexOf(old);
  if (i < 0) return null;
  return all ? text.split(old).join(next) : text.slice(0, i) + next + text.slice(i + old.length);
}

/**
 * The file diff of a file tool's input. `current` = the file's text now (null: it doesn't exist / can't be read).
 * Edits whose old_string isn't found fall back to a diff of the strings themselves (line numbers from 1).
 */
export function fileToolDiff(tool: string, input: unknown, current: string | null, o: DiffLimits = {}): DiffBody {
  const i = (input && typeof input === "object" ? input : {}) as Rec;
  if (tool === "Write") return unifiedDiff(current ?? "", str(i.content) ?? "", o);
  if (tool === "NotebookEdit") return unifiedDiff("", str(i.new_source) ?? "", o);
  const edits: Array<{ old: string; next: string; all: boolean }> =
    tool === "MultiEdit"
      ? (Array.isArray(i.edits) ? i.edits : []).slice(0, 200).map((e: unknown) => {
          const x = (e && typeof e === "object" ? e : {}) as Rec;
          return { old: str(x.old_string) ?? "", next: str(x.new_string) ?? "", all: x.replace_all === true };
        })
      : [{ old: str(i.old_string) ?? "", next: str(i.new_string) ?? "", all: i.replace_all === true }];
  if (current !== null && !isBinary(current)) {
    let text: string | null = current;
    for (const e of edits) {
      text = text === null ? null : replace(text, e.old, e.next, e.all);
    }
    if (text !== null) return unifiedDiff(current, text, o);
  }
  return unifiedDiff(edits.map((e) => e.old).join("\n"), edits.map((e) => e.next).join("\n"), o);
}

const SECRET_KEY = /pass|secret|token|key|auth|cookie|credential|env/i;

/** Other tools: their non-secret scalar input fields, redacted, ≤ 240 characters. */
export function toolSummary(input: unknown): string {
  const i = (input && typeof input === "object" ? input : {}) as Rec;
  const out: Rec = {};
  for (const [k, v] of Object.entries(i).slice(0, 12)) {
    if (SECRET_KEY.test(k)) continue;
    if (typeof v === "string") out[k] = v.length > 80 ? `${v.slice(0, 79)}…` : v;
    else if (typeof v === "number" || typeof v === "boolean") out[k] = v;
  }
  const s = redact(JSON.stringify(out));
  return s.length > 240 ? `${s.slice(0, 239)}…` : s;
}

/** Bash: the command (≤ 2000) and the reason (the tool's description, else the permission's reason), redacted. */
export function bashPreview(input: unknown, reason: string | null): { command: string; reason: string | null } {
  const i = (input && typeof input === "object" ? input : {}) as Rec;
  const cmd = str(i.command) ?? "";
  const why = str(i.description) ?? reason;
  return { command: redact(cmd.length > 2000 ? `${cmd.slice(0, 1999)}…` : cmd), reason: why ? redact(why.slice(0, 500)) : null };
}
