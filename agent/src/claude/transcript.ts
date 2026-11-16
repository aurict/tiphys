// Reads the Claude Code session transcript (<config>/projects/<folder>/<session>.jsonl) and turns it into phone events.
// The SDK's getSessionMessages returned the first N messages from the start and stopped at the compaction (compact)
// boundary: long sessions looked "stuck" on the phone at an old point, with a half-finished command. Here the
// chain is followed back from the latest message, compaction boundaries are crossed via logicalParentUuid,
// and the LAST events are returned.
import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";

export type HistoryEvent = Record<string, unknown> & { kind: string };

type Row = {
  type?: string;
  subtype?: string;
  uuid?: string;
  parentUuid?: string | null;
  logicalParentUuid?: string | null;
  isSidechain?: boolean;
  isMeta?: boolean;
  isCompactSummary?: boolean;
  message?: { role?: string; content?: unknown };
};

/** Path of the session transcript: which folder under projects it lives in is unknown, so it is searched. */
export async function findTranscript(configDir: string, sessionId: string): Promise<string | null> {
  const projects = join(configDir, "projects");
  let dirs: string[];
  try {
    dirs = await readdir(projects);
  } catch {
    return null;
  }
  for (const d of dirs) {
    const f = join(projects, d, `${sessionId}.jsonl`);
    if (await stat(f).then((s) => s.isFile(), () => false)) return f;
  }
  return null;
}

/** Simplifies command wrappers: "<command-name>/review</command-name>…" → "/review". null if it should be hidden. */
function userText(t: string): string | null {
  const cmd = /<command-name>([^<]*)<\/command-name>/.exec(t);
  if (cmd) {
    const args = /<command-args>([^<]*)<\/command-args>/.exec(t)?.[1]?.trim();
    return args ? `${cmd[1]} ${args}` : cmd[1]!;
  }
  if (t.startsWith("<local-command-") || t.startsWith("<system-reminder>") || t.startsWith("Caveat:")) return null;
  return t;
}

function rowEvents(r: Row): HistoryEvent[] {
  const out: HistoryEvent[] = [];
  const c = r.message?.content;
  const blocks = typeof c === "string" ? [{ type: "text", text: c }] : Array.isArray(c) ? (c as Array<Record<string, unknown>>) : [];
  for (const b of blocks) {
    if (r.type === "user" && b.type === "text") {
      const t = userText(String(b.text ?? ""));
      if (t) out.push({ kind: "user", text: t, images: blocks.filter((x) => x.type === "image").length });
    } else if (r.type === "user" && b.type === "tool_result") {
      const v = b.content;
      const text = typeof v === "string" ? v : Array.isArray(v) ? v.map((x) => (x as { text?: string }).text ?? "").join("") : "";
      out.push({ kind: "tool_result", toolUseId: b.tool_use_id, text: text.slice(0, 20000), isError: b.is_error === true });
    } else if (r.type === "assistant" && b.type === "text") out.push({ kind: "text", text: String(b.text ?? "").slice(0, 20000) });
    else if (r.type === "assistant" && b.type === "tool_use") out.push({ kind: "tool_use", id: b.id, name: b.name, input: b.input });
  }
  return out;
}

let cache: { file: string; key: string; rows: Row[] } | null = null;

async function rowsOf(file: string): Promise<Row[]> {
  const s = await stat(file);
  const key = `${s.size}:${s.mtimeMs}`;
  if (cache && cache.file === file && cache.key === key) return cache.rows;
  const rows: Row[] = [];
  for (const line of (await readFile(file, "utf8")).split("\n")) {
    if (!line) continue;
    try {
      rows.push(JSON.parse(line) as Row);
    } catch {
      // the last line being written may be incomplete
    }
  }
  cache = { file, key, rows };
  return rows;
}

/** The transcript's last `limit` events (chronological). Compaction points get a {kind:"compacted"} marker. */
export async function transcriptEvents(file: string, limit = 400): Promise<HistoryEvent[]> {
  return (await transcriptPage(file, limit, 0)).events;
}

/**
 * Skipping `skip` events from the end, the `limit` events before them (chronological). `more`: whether older ones exist.
 * As the phone scrolls up it requests older messages with skip = the number of events it has.
 */
export async function transcriptPage(file: string, limit: number, skip: number): Promise<{ events: HistoryEvent[]; more: boolean }> {
  const rows = await rowsOf(file);
  const byUuid = new Map<string, Row>();
  for (const r of rows) if (r.uuid) byUuid.set(r.uuid, r);
  let cur: Row | undefined;
  for (let i = rows.length - 1; i >= 0; i--) {
    const r = rows[i]!;
    if ((r.type === "user" || r.type === "assistant") && !r.isSidechain && r.uuid) {
      cur = r;
      break;
    }
  }
  // From end to start: each line's events are collected in reverse order, and all are converted at the end.
  const rev: HistoryEvent[] = [];
  const seen = new Set<string>();
  const want = limit + skip;
  while (cur && rev.length < want) {
    if (cur.uuid) {
      if (seen.has(cur.uuid)) break; // guard against cycles
      seen.add(cur.uuid);
    }
    if (cur.type === "system" && cur.subtype === "compact_boundary") rev.push({ kind: "compacted" });
    else if (!cur.isMeta && !cur.isCompactSummary && !cur.isSidechain) rev.push(...rowEvents(cur).reverse());
    const next: string | null | undefined = cur.parentUuid ?? cur.logicalParentUuid;
    cur = next ? byUuid.get(next) : undefined;
  }
  const more = cur !== undefined || rev.length > want;
  const page = rev.slice(skip, want).reverse();
  return { events: page.map((e, i) => ({ ...e, seq: i + 1 })), more };
}
