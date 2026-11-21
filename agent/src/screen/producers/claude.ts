// `claude` and `diff` topics (PLAN.md §20 A-2): the Claude sessions of this host for the Work mode's brain, and the
// approval preview of a Tiphys session's pending permission.
// - Tiphys sessions ("code" kind): the manager's events (ClaudeManager.observers): status, tool uses, permission
//   requests and their resolution. Nothing is polled.
// - Terminal sessions: ONE non-recursive fs.watch per `<config>/sessions/` (Claude Code writes `<pid>.json` with
//   `status` busy|idle|waiting and `waitingFor`); the pid is checked against /proc (start time) on every change and
//   every 10 s (a dead session's file may stay). Recent tool uses come from the session's transcript `.jsonl`, of
//   which ONLY the appended bytes are read (per-file offset; the first read takes the last 64 KB; truncation or a new
//   inode starts over at the tail). Decision 4: a terminal session never yields a diff, only "waiting + tool + file".
// - Sent per subscriber (its project root from the git topic's selection): sessions with id, name, project basename,
//   status idle|running|waiting, the last 5 tool uses (tool + path relative to the root, never content) and what a
//   waiting session waits for. A path outside the root is dropped; without `screen.share.code` a path is masked with
//   the root's city tokens (the same building is hit without revealing a name), or dropped when no city runs.
// - `diff` only while `screen.share.code` is on, only for Tiphys sessions, only for files inside the root (Bash and
//   other tools have no path). `diffResolved` when the permission resolves or the session ends.
// - `touch.by`: an Edit/Write/MultiEdit/NotebookEdit tool use (or its allowed permission) in the last 30 s on the
//   same file names the session in the city's touch (attribute()).
import { constants, watch as fsWatch } from "node:fs";
import { open, readdir, stat } from "node:fs/promises";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import type { ClaudeEvent } from "../../claude/manager.ts";
import { readTerminalSession, type TerminalSession } from "../../claude/terminal.ts";
import { findTranscript } from "../../claude/transcript.ts";
import type { Sock } from "../source.ts";
import { bashPreview, FILE_TOOLS, fileToolDiff, langOf, toolPath, toolSummary, type DiffBody } from "./diff.ts";

export type Status = "idle" | "running" | "waiting";
type Kind = "read" | "edit" | null;

export interface ToolUse {
  tool: string;
  /** Absolute path (resolved against the session's cwd); null for tools without one. */
  abs: string | null;
  at: number;
}

export const EDIT_TOOLS: ReadonlySet<string> = new Set(Object.keys(FILE_TOOLS));
const READ_TOOLS: ReadonlySet<string> = new Set(["Read", "Grep", "Glob"]);
export const toolKind = (tool: string): Kind => (EDIT_TOOLS.has(tool) ? "edit" : READ_TOOLS.has(tool) ? "read" : null);
const KNOWN_TOOL = /\b(MultiEdit|NotebookEdit|Edit|Write|Bash|Read|Grep|Glob|WebFetch|WebSearch|Task|Agent)\b/;

/** Small async file access (fake in tests). Nothing throws. */
export interface ClaudeIo {
  session(file: string): Promise<TerminalSession | null>;
  list(dir: string): Promise<string[]>;
  /** Non-recursive watch; null when the path can't be watched. */
  watch(path: string, fn: (name: string | null) => void): { close(): void } | null;
  transcript(configDir: string, sessionId: string): Promise<string | null>;
  stat(file: string): Promise<{ size: number; ino: number } | null>;
  /** Bytes [start, start+len) (fewer at the end of the file); null on error. */
  range(file: string, start: number, len: number): Promise<Buffer | null>;
  /** A regular file's text (≤ maxBytes, symlinks not followed); null otherwise. */
  text(file: string, maxBytes: number): Promise<string | null>;
}

export function realClaudeIo(procRoot = "/proc"): ClaudeIo {
  return {
    session: (f) => readTerminalSession(f, procRoot),
    list: (d) => readdir(d).catch(() => []),
    watch: (p, fn) => {
      try {
        const w = fsWatch(p, { persistent: false }, (_e, f) => fn(typeof f === "string" ? f : null));
        w.on("error", () => w.close());
        return w;
      } catch {
        return null;
      }
    },
    transcript: (dir, id) => findTranscript(dir, id).catch(() => null),
    stat: (f) => stat(f).then((s) => (s.isFile() ? { size: s.size, ino: s.ino } : null), () => null),
    range: async (f, start, len) => {
      const fh = await open(f, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK).catch(() => null);
      if (!fh) return null;
      try {
        const buf = Buffer.allocUnsafe(len);
        const { bytesRead } = await fh.read(buf, 0, len, start);
        return buf.subarray(0, bytesRead);
      } catch {
        return null;
      } finally {
        await fh.close().catch(() => {});
      }
    },
    text: async (f, max) => {
      const fh = await open(f, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK).catch(() => null);
      if (!fh) return null;
      try {
        const st = await fh.stat();
        if (!st.isFile() || st.size > max) return null;
        return await fh.readFile("utf8");
      } catch {
        return null;
      } finally {
        await fh.close().catch(() => {});
      }
    },
  };
}

type Row = Record<string, unknown>;

/**
 * Append-only reader of a transcript: each read() returns the rows of the bytes added since the last one. The first
 * read (and a read after truncation or replacement, i.e. a smaller size or another inode) starts at the last
 * `initialBytes`; more than `maxRead` new bytes at once → only the last `maxRead`. A partial last line waits for the
 * next read; a partial first line (reading from the middle of the file) is skipped.
 */
export class TranscriptTail {
  readonly file: string;
  readonly #io: ClaudeIo;
  readonly #initial: number;
  readonly #max: number;
  #offset = -1;
  #ino = -1;
  #rest: Buffer = Buffer.alloc(0);

  constructor(file: string, io: ClaudeIo, o: { initialBytes?: number; maxRead?: number } = {}) {
    this.file = file;
    this.#io = io;
    this.#initial = o.initialBytes ?? 64 * 1024;
    this.#max = o.maxRead ?? 256 * 1024;
  }

  /** Bytes consumed so far (tests). */
  get offset() {
    return this.#offset;
  }

  async read(): Promise<Row[]> {
    const st = await this.#io.stat(this.file);
    if (!st) return [];
    let start = this.#offset;
    let mid = false;
    if (start < 0 || st.ino !== this.#ino || st.size < start) {
      this.#ino = st.ino;
      this.#rest = Buffer.alloc(0);
      start = Math.max(0, st.size - this.#initial);
      mid = start > 0;
    }
    if (st.size - start > this.#max) {
      start = st.size - this.#max;
      this.#rest = Buffer.alloc(0);
      mid = true;
    }
    if (st.size === start) {
      this.#offset = start;
      return [];
    }
    // From the middle: one byte earlier, so a line that starts exactly at `start` isn't taken for a partial one.
    const from = mid ? start - 1 : start;
    const buf = await this.#io.range(this.file, from, st.size - from);
    if (!buf) return [];
    this.#offset = from + buf.length;
    let data = this.#rest.length ? Buffer.concat([this.#rest, buf]) : buf;
    if (mid) {
      const nl = data.indexOf(10);
      data = nl < 0 ? Buffer.alloc(0) : data.subarray(nl + 1);
    }
    const last = data.lastIndexOf(10);
    const tail = data.subarray(last + 1);
    this.#rest = tail.length > 4 * 1024 * 1024 ? Buffer.alloc(0) : Buffer.from(tail); // a runaway line is dropped
    const rows: Row[] = [];
    for (const line of data.subarray(0, last + 1).toString("utf8").split("\n")) {
      if (!line) continue;
      try {
        const r = JSON.parse(line) as unknown;
        if (r && typeof r === "object") rows.push(r as Row);
      } catch {}
    }
    return rows;
  }
}

/** Transcript rows → tool uses (assistant tool_use blocks) and finished tool ids (user tool_result blocks). */
export function rowTools(rows: Row[], cwd: string | null, now = Date.now()): { uses: Array<ToolUse & { id: string }>; done: string[] } {
  const uses: Array<ToolUse & { id: string }> = [];
  const done: string[] = [];
  for (const r of rows) {
    const msg = r.message && typeof r.message === "object" ? (r.message as Row) : null;
    const content = Array.isArray(msg?.content) ? (msg!.content as Row[]) : [];
    const at = typeof r.timestamp === "string" ? Date.parse(r.timestamp) || now : now;
    for (const b of content) {
      if (!b || typeof b !== "object") continue;
      if (r.type === "assistant" && b.type === "tool_use" && typeof b.name === "string" && typeof b.id === "string") {
        uses.push({ id: b.id, tool: b.name.slice(0, 40), abs: absOf(toolPath(b.name, b.input), cwd), at });
      } else if (r.type === "user" && b.type === "tool_result" && typeof b.tool_use_id === "string") done.push(b.tool_use_id);
    }
  }
  return { uses, done };
}

const absOf = (p: string | null, cwd: string | null) => (p === null ? null : isAbsolute(p) ? resolve(p) : cwd ? resolve(cwd, p) : null);

/** A path for the page: relative to the root and inside it, masked when names aren't shared; null otherwise. */
export function pagePath(abs: string | null, root: string | null, out: ((rel: string) => string) | null): string | null {
  if (!abs || !root) return null;
  const rel = relative(root, abs);
  if (!rel || rel.startsWith("..") || isAbsolute(rel) || rel.split(/[\\/]/).some((s) => s === "" || s === "." || s === "..")) return null;
  return out ? out(rel) : null;
}

const MAX_RECENT = 5;
const shortName = (s: string | null | undefined, max = 40) => {
  const t = (s ?? "").replace(/\s+/g, " ").trim();
  return t.length > max ? `${t.slice(0, max - 1)}…` : t;
};

/** The LiveSession surface used (manager.ts). */
export interface TiphysLike {
  readonly id: string;
  readonly cwd: string;
  readonly title: string;
  readonly status: string;
  readonly kind: string;
  readonly sdkSessionId: string | null;
  readonly events: readonly ClaudeEvent[];
  readonly pending: ReadonlyMap<string, unknown>;
}
export interface ManagerLike {
  readonly sessions: ReadonlyMap<string, TiphysLike>;
  readonly observers: Set<(s: TiphysLike, e: ClaudeEvent) => void>;
}

interface Pending {
  requestId: string;
  tool: string;
  input: unknown;
  reason: string | null;
  abs: string | null;
  at: number;
  /** File tools: the diff once computed (null: not yet / not a file tool). */
  diff: DiffBody | null;
  /** Write of a file that doesn't exist yet. */
  created: boolean;
  ready: boolean;
}

interface Session {
  id: string;
  origin: "tiphys" | "terminal";
  name: string;
  cwd: string | null;
  status: Status;
  recent: ToolUse[];
  /** Tiphys: open permission requests. */
  pending: Map<string, Pending>;
  /** Terminal: what a waiting session waits for (tool + file), from its open tool use or `waitingFor`. */
  waiting: { tool: string | null; abs: string | null; since: number } | null;
}

interface Term {
  file: string;
  configDir: string;
  t: TerminalSession;
  s: Session;
  tail: TranscriptTail | null;
  w: { close(): void } | null;
  open: Map<string, ToolUse>;
  busy: boolean;
  again: boolean;
}

export interface ClaudeDeps {
  manager(): ManagerLike | null;
  /** Claude config dirs whose `sessions/` hold terminal sessions (~/.claude and the profiles). */
  configDirs(): string[];
  io: ClaudeIo;
  /** This host shares code (`screen.share.code`): read when a permission arrives. */
  share(): boolean;
  opts?: { debounceMs?: number; livenessMs?: number; attributeMs?: number; maxFileBytes?: number };
}

/** Where a subscriber's paths go: its root (undefined = not resolved yet) and that root's city masking. */
export interface ClaudePlace {
  rootOf(sock: Sock): string | null | undefined;
  /** The root's running city: its path mapping (masked tokens or the plain path). */
  cityOf(root: string): { out(rel: string): string } | null;
}

const send = (sock: Sock, data: string) => {
  if (sock.readyState === 1) sock.send(data);
};

const STATUS: Record<string, Status> = { starting: "running", running: "running", waiting: "waiting", busy: "running", idle: "idle", error: "idle" };

/** The claude and diff topics: one shared state, rendered per subscriber (root, masking). */
export class ClaudeTopic {
  readonly #d: ClaudeDeps;
  readonly #place: ClaudePlace;
  readonly #subs = new Map<Sock, { want: Set<"claude" | "diff">; last: string | null; diffs: Set<string> }>();
  readonly #sessions = new Map<string, Session>();
  readonly #terms = new Map<string, Term>();
  #dirWatches: Array<{ close(): void }> = [];
  #observer: ((s: TiphysLike, e: ClaudeEvent) => void) | null = null;
  #mgr: ManagerLike | null = null;
  #timer: NodeJS.Timeout | null = null;
  #live: NodeJS.Timeout | null = null;
  #edits: Array<{ abs: string; id: string; at: number }> = [];
  #running = false;
  readonly #o: Required<NonNullable<ClaudeDeps["opts"]>>;

  constructor(d: ClaudeDeps, place: ClaudePlace) {
    this.#d = d;
    this.#place = place;
    this.#o = { debounceMs: 150, livenessMs: 10_000, attributeMs: 30_000, maxFileBytes: 2 * 1024 * 1024, ...d.opts };
  }

  get active() {
    return this.#running || this.#dirWatches.length > 0 || this.#terms.size > 0 || this.#timer !== null || this.#live !== null;
  }

  has(t: "claude" | "diff") {
    return [...this.#subs.values()].some((s) => s.want.has(t));
  }

  /** Open fs watchers (tests). */
  get watchCount() {
    return this.#dirWatches.length + [...this.#terms.values()].filter((t) => t.w).length;
  }

  /** The subscriber's claude/diff topics (empty = none). */
  set(sock: Sock, want: ReadonlyArray<"claude" | "diff">) {
    const old = this.#subs.get(sock);
    if (!want.length) {
      if (old) this.#subs.delete(sock);
      if (!this.#subs.size) this.#stop();
      return;
    }
    const sub = old ?? { want: new Set(), last: null, diffs: new Set<string>() };
    const added = want.filter((t) => !sub.want.has(t));
    sub.want = new Set(want);
    if (!sub.want.has("diff")) sub.diffs.clear();
    if (!sub.want.has("claude")) sub.last = null;
    this.#subs.set(sock, sub);
    if (!this.#running) void this.#start();
    else {
      if (added.includes("claude")) this.#flushSock(sock);
      if (added.includes("diff")) for (const s of this.#sessions.values()) for (const p of s.pending.values()) this.#sendDiff(s, p, sock);
    }
  }

  /** The subscriber's root changed: its sessions' paths (and diffs) follow. */
  refresh(sock: Sock) {
    const sub = this.#subs.get(sock);
    if (!sub || !this.#running) return;
    this.#flushSock(sock);
    if (sub.want.has("diff")) for (const s of this.#sessions.values()) for (const p of s.pending.values()) this.#sendDiff(s, p, sock);
  }

  /** The session (short id) whose file tool touched `abs` in the last 30 s; null if none. */
  attribute(abs: string): string | null {
    const now = Date.now();
    this.#edits = this.#edits.filter((e) => now - e.at <= this.#o.attributeMs);
    for (let i = this.#edits.length - 1; i >= 0; i--) if (this.#edits[i]!.abs === abs) return this.#edits[i]!.id;
    return null;
  }

  stop() {
    this.#subs.clear();
    this.#stop();
  }

  // ---- lifecycle

  async #start() {
    this.#running = true;
    const m = this.#d.manager();
    if (m) {
      this.#mgr = m;
      this.#observer = (s, e) => this.#onTiphys(s, e);
      m.observers.add(this.#observer);
      for (const s of m.sessions.values()) this.#adoptTiphys(s);
    }
    for (const dir of new Set(this.#d.configDirs())) this.#watchConfig(dir);
    this.#live = setInterval(() => {
      for (const t of [...this.#terms.values()]) void this.#readTerm(t);
    }, this.#o.livenessMs);
    this.#live.unref?.();
    this.#changed();
  }

  #stop() {
    if (!this.#running) return;
    this.#running = false;
    if (this.#mgr && this.#observer) this.#mgr.observers.delete(this.#observer);
    this.#mgr = this.#observer = null;
    for (const w of this.#dirWatches) w.close();
    this.#dirWatches = [];
    for (const t of this.#terms.values()) t.w?.close();
    this.#terms.clear();
    this.#sessions.clear();
    this.#edits = [];
    if (this.#timer) clearTimeout(this.#timer);
    if (this.#live) clearInterval(this.#live);
    this.#timer = this.#live = null;
  }

  // ---- Tiphys sessions

  #adoptTiphys(s: TiphysLike) {
    if (s.kind !== "code" || s.status === "stopped") return;
    const x = this.#tiphys(s);
    const uses = s.events.filter((e): e is Extract<ClaudeEvent, { kind: "tool_use" }> => e.kind === "tool_use").slice(-MAX_RECENT);
    x.recent = uses.map((e) => ({ tool: e.name, abs: absOf(toolPath(e.name, e.input), s.cwd), at: Date.parse(e.at) || Date.now() }));
    for (const e of s.events) {
      if (e.kind === "permission" && s.pending.has(e.requestId)) this.#ask(s, x, e.requestId, e.toolName, e.input, e.reason, Date.parse(e.at) || Date.now());
    }
  }

  #tiphys(s: TiphysLike): Session {
    let x = this.#sessions.get(s.id);
    if (!x) {
      x = { id: s.id.slice(0, 8), origin: "tiphys", name: shortName(s.title) || basename(s.cwd), cwd: s.cwd, status: STATUS[s.status] ?? "idle", recent: [], pending: new Map(), waiting: null };
      this.#sessions.set(s.id, x);
    }
    return x;
  }

  #onTiphys(s: TiphysLike, e: ClaudeEvent) {
    if (!this.#running || s.kind !== "code") return;
    if (e.kind === "delta" || e.kind === "text" || e.kind === "thinking") return; // the busy path: nothing to show
    if (e.kind === "status" && e.status === "stopped") {
      const x = this.#sessions.get(s.id);
      if (!x) return;
      for (const p of [...x.pending.values()]) this.#resolved(x, p.requestId, false);
      this.#sessions.delete(s.id);
      return this.#changed();
    }
    const x = this.#tiphys(s);
    const dup = s.sdkSessionId ? [...this.#terms.values()].filter((t) => t.t.sdkSessionId === s.sdkSessionId) : [];
    for (const t of dup) this.#dropTerm(t);
    x.name = shortName(s.title) || basename(s.cwd);
    if (e.kind === "status") x.status = STATUS[e.status] ?? "idle";
    else if (e.kind === "tool_use") {
      const u = { tool: e.name.slice(0, 40), abs: absOf(toolPath(e.name, e.input), s.cwd), at: Date.now() };
      this.#use(x, u);
    } else if (e.kind === "permission") {
      this.#ask(s, x, e.requestId, e.toolName, e.input, e.reason, Date.now());
      x.status = "waiting";
    } else if (e.kind === "permissionResolved") {
      const p = x.pending.get(e.requestId);
      if (p && e.allow && EDIT_TOOLS.has(p.tool) && p.abs) this.#edits.push({ abs: p.abs, id: x.id, at: Date.now() });
      this.#resolved(x, e.requestId, e.allow);
    } else if (!dup.length) return;
    this.#changed();
  }

  #use(x: Session, u: ToolUse) {
    x.recent.push(u);
    if (x.recent.length > MAX_RECENT) x.recent.splice(0, x.recent.length - MAX_RECENT);
    if (u.abs && EDIT_TOOLS.has(u.tool)) this.#edits.push({ abs: u.abs, id: x.id, at: u.at });
    if (this.#edits.length > 200) this.#edits.splice(0, this.#edits.length - 200);
  }

  #ask(s: TiphysLike, x: Session, requestId: string, tool: string, input: unknown, reason: string | null, at: number) {
    if (x.pending.has(requestId)) return;
    const p: Pending = { requestId, tool: tool.slice(0, 60), input, reason, abs: absOf(toolPath(tool, input), s.cwd), at, diff: null, created: false, ready: false };
    x.pending.set(requestId, p);
    const file = FILE_TOOLS[tool] !== undefined;
    // Code leaves only with share.code on: the file isn't even read otherwise.
    if (!this.#d.share()) return void (p.ready = true);
    if (!file || !p.abs) {
      p.ready = true;
      return this.#sendDiffAll(x, p);
    }
    void (tool === "NotebookEdit" ? Promise.resolve(null) : this.#d.io.text(p.abs, this.#o.maxFileBytes)).then((cur) => {
      if (!x.pending.has(requestId)) return;
      p.diff = fileToolDiff(tool, input, cur);
      p.created = tool === "Write" && cur === null;
      p.ready = true;
      this.#sendDiffAll(x, p);
    });
  }

  #resolved(x: Session, requestId: string, allow: boolean) {
    if (!x.pending.delete(requestId)) return;
    const msg = JSON.stringify({ type: "diffResolved", requestId, allow });
    for (const [sock, sub] of this.#subs) if (sub.diffs.delete(requestId)) send(sock, msg);
  }

  #sendDiffAll(x: Session, p: Pending) {
    for (const sock of this.#subs.keys()) this.#sendDiff(x, p, sock);
  }

  /** The diff of one request for one subscriber (once; never without share.code; file tools only inside its root). */
  #sendDiff(x: Session, p: Pending, sock: Sock) {
    const sub = this.#subs.get(sock);
    if (!sub?.want.has("diff") || sub.diffs.has(p.requestId) || !p.ready || x.origin !== "tiphys" || !this.#d.share()) return;
    const base = { type: "diff", sessionId: x.id, session: x.name, requestId: p.requestId, tool: p.tool, at: p.at };
    let msg: Record<string, unknown>;
    if (FILE_TOOLS[p.tool] !== undefined) {
      const root = this.#place.rootOf(sock);
      const path = pagePath(p.abs, root ?? null, (rel) => rel);
      if (!path || !p.diff) return;
      const { hunks, added, removed, truncated, more, binary } = p.diff;
      msg = { ...base, path, lang: langOf(path), added, removed, hunks, truncated, more, binary, created: p.created };
    } else if (p.tool === "Bash") msg = { ...base, ...bashPreview(p.input, p.reason) };
    else msg = { ...base, summary: toolSummary(p.input) };
    sub.diffs.add(p.requestId);
    send(sock, JSON.stringify(msg));
  }

  // ---- terminal sessions

  #watchConfig(dir: string) {
    const sessions = join(dir, "sessions");
    const w = this.#d.io.watch(sessions, (name) => {
      if (name === null) void this.#scan(sessions, dir);
      else if (/^\d+\.json$/.test(name)) void this.#onFile(join(sessions, name), dir);
    });
    if (w) {
      this.#dirWatches.push(w);
      void this.#scan(sessions, dir);
      return;
    }
    // No sessions/ yet: watch the config dir until it appears.
    const parent = this.#d.io.watch(dir, (name) => {
      if (name !== "sessions" || !this.#running) return;
      parent?.close();
      this.#dirWatches = this.#dirWatches.filter((x) => x !== parent);
      this.#watchConfig(dir);
    });
    if (parent) this.#dirWatches.push(parent);
  }

  async #scan(sessions: string, dir: string) {
    for (const n of await this.#d.io.list(sessions)) if (/^\d+\.json$/.test(n)) await this.#onFile(join(sessions, n), dir);
  }

  async #onFile(file: string, configDir: string) {
    if (!this.#running) return;
    const known = this.#terms.get(file);
    if (known) return this.#readTerm(known);
    const t = await this.#d.io.session(file);
    if (!t || !this.#running || this.#terms.has(file)) return;
    if (this.#ours(t.sdkSessionId)) return;
    const s: Session = { id: t.sdkSessionId.slice(0, 8), origin: "terminal", name: "", cwd: t.cwd, status: "idle", recent: [], pending: new Map(), waiting: null };
    const term: Term = { file, configDir, t, s, tail: null, w: null, open: new Map(), busy: false, again: false };
    this.#terms.set(file, term);
    this.#sessions.set(`t:${file}`, s);
    this.#apply(term, t);
    const tr = await this.#d.io.transcript(configDir, t.sdkSessionId);
    if (!this.#running || this.#terms.get(file) !== term) return;
    if (tr) {
      term.tail = new TranscriptTail(tr, this.#d.io);
      term.w = this.#d.io.watch(tr, () => void this.#tailTerm(term));
      await this.#tailTerm(term);
    }
    this.#changed();
  }

  /** Re-reads the session file: gone/dead → dropped; else status and waiting updated. */
  async #readTerm(term: Term) {
    const t = await this.#d.io.session(term.file);
    if (!this.#running || this.#terms.get(term.file) !== term) return;
    if (!t || t.sdkSessionId !== term.t.sdkSessionId || this.#ours(t.sdkSessionId)) {
      this.#dropTerm(term);
      this.#changed();
      if (t) void this.#onFile(term.file, term.configDir); // the pid file now holds another session
      return;
    }
    this.#apply(term, t);
    this.#changed();
  }

  /**
   * The SDK's own process (a Tiphys session) writes a session file too, and with the real SDK it does so before the
   * manager learns the session's id: such a file is shown once, as the Tiphys session, and dropped as soon as the id
   * is known (the next Tiphys event or re-read of the file).
   */
  #ours(sdkSessionId: string) {
    return [...(this.#mgr?.sessions.values() ?? [])].some((s) => s.sdkSessionId === sdkSessionId);
  }

  #dropTerm(term: Term) {
    term.w?.close();
    this.#terms.delete(term.file);
    this.#sessions.delete(`t:${term.file}`);
  }

  #apply(term: Term, t: TerminalSession) {
    term.t = t;
    const s = term.s;
    s.name = shortName(t.name) || (t.cwd ? basename(t.cwd) : "terminal");
    s.cwd = t.cwd;
    s.status = STATUS[t.status ?? ""] ?? "idle";
    if (s.status === "waiting") {
      const open = [...term.open.values()].pop() ?? null;
      const named = KNOWN_TOOL.exec(t.waitingFor ?? "")?.[1] ?? null;
      s.waiting = { tool: open?.tool ?? named, abs: open?.abs ?? null, since: s.waiting?.since ?? Date.now() };
    } else s.waiting = null;
  }

  async #tailTerm(term: Term) {
    if (!term.tail) return;
    if (term.busy) return void (term.again = true);
    term.busy = true;
    try {
      do {
        term.again = false;
        const rows = await term.tail.read();
        if (!this.#running || this.#terms.get(term.file) !== term) return;
        const { uses, done } = rowTools(rows, term.t.cwd);
        for (const u of uses) {
          term.open.set(u.id, u);
          this.#use(term.s, { tool: u.tool, abs: u.abs, at: u.at });
        }
        for (const id of done) term.open.delete(id);
        while (term.open.size > 20) term.open.delete(term.open.keys().next().value!);
        if (uses.length || done.length) {
          this.#apply(term, term.t);
          this.#changed();
        }
      } while (term.again);
    } finally {
      term.busy = false;
    }
  }

  // ---- messages

  #changed() {
    if (!this.#running || this.#timer) return;
    this.#timer = setTimeout(() => {
      this.#timer = null;
      for (const sock of this.#subs.keys()) this.#flushSock(sock);
    }, this.#o.debounceMs);
    this.#timer.unref?.();
  }

  /** The claude message for one subscriber (sent only when it differs from the last one). */
  #flushSock(sock: Sock) {
    const sub = this.#subs.get(sock);
    if (!sub?.want.has("claude")) return;
    const root = this.#place.rootOf(sock) ?? null;
    const city = root ? this.#place.cityOf(root) : null;
    const share = this.#d.share();
    const out = city ? (rel: string) => city.out(rel) : share ? (rel: string) => rel : null;
    const p = (abs: string | null) => pagePath(abs, root, out);
    const sessions = [...this.#sessions.values()].map((s) => {
      const firstPending = [...s.pending.values()][0];
      const waiting =
        s.origin === "tiphys"
          ? firstPending && s.status === "waiting" ? { tool: firstPending.tool, path: p(firstPending.abs), since: firstPending.at } : null
          : s.waiting ? { tool: s.waiting.tool, path: p(s.waiting.abs), since: s.waiting.since } : null;
      return {
        id: s.id,
        name: s.name,
        project: s.cwd ? basename(s.cwd) : null,
        status: s.status,
        origin: s.origin,
        recent: s.recent.map((u) => ({ tool: u.tool, path: p(u.abs), kind: toolKind(u.tool), at: u.at })),
        waiting,
        pending: [...s.pending.keys()],
      };
    });
    const msg = JSON.stringify({ type: "claude", sessions });
    if (msg === sub.last) return;
    sub.last = msg;
    send(sock, msg);
  }
}
