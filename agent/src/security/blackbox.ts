// Black box (PLAN.md §15 S-4): an append-only, hash-chained record of what was done through the agents.
//   local (monitoring server): <config dir>/blackbox/chain.jsonl (dir 0700, file 0600, opened with O_APPEND only).
//     Every record: {seq, at, source, kind, data, prev, hash}, hash = sha256(prev + "\n" + JSON of {seq, at, source,
//     kind, data}). Sources: this agent's audit entries and notices (not "sensitive" ones), and records other agents
//     push with a "blackbox" service token (their source is the token's name, never what they claim).
//   push (other agents): records are queued in blackbox-queue.jsonl (0600) and sent every 30 s; nothing is lost while
//     the monitoring server is unreachable (the queue is capped at 10 000 records; the oldest go first, counted).
// Every night the chain's head (count + hash) goes to the owner's Telegram as an outside anchor and to anchors.jsonl;
// a verification walks the whole file. With `chattr +a` (root, once) even this agent's user can't rewrite it.
import { createHash } from "node:crypto";
import { createReadStream } from "node:fs";
import { appendFile, chmod, mkdir, open, readFile, rename, stat, writeFile } from "node:fs/promises";

/** Chain file size limit: past it nothing more is appended (blackbox.full); records must never fill the disk. */
export const MAX_CHAIN_BYTES = 1024 ** 3;
import { dirname, join } from "node:path";
import { createInterface } from "node:readline";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import type { Fetch } from "./collect.ts";

export const GENESIS = "0".repeat(64);
const MAX_DATA_CHARS = 4000;
const QUEUE_MAX = 10_000;

export interface BoxRecord {
  seq: number;
  at: string;
  source: string;
  kind: "audit" | "event" | "lockdown";
  data: Record<string, unknown>;
  prev: string;
  hash: string;
}

export function recordHash(prev: string, r: Pick<BoxRecord, "seq" | "at" | "source" | "kind" | "data">): string {
  return createHash("sha256")
    .update(`${prev}\n${JSON.stringify({ seq: r.seq, at: r.at, source: r.source, kind: r.kind, data: r.data })}`)
    .digest("hex");
}

/** Bounds a record's data (string lengths, depth) so a pushed record can't blow up the chain. */
export function boundData(d: unknown, depth = 0): unknown {
  if (typeof d === "string") return d.slice(0, 500);
  if (typeof d === "number" || typeof d === "boolean" || d === null) return d;
  if (depth > 3) return null;
  if (Array.isArray(d)) return d.slice(0, 50).map((x) => boundData(x, depth + 1));
  if (typeof d === "object") return Object.fromEntries(Object.entries(d as object).slice(0, 30).map(([k, v]) => [k.slice(0, 60), boundData(v, depth + 1)]));
  return null;
}

export class BlackBox {
  readonly dir: string;
  readonly file: string;
  readonly anchorsFile: string;
  /** Last head written next to the chain: after a restart a chain shorter than it was is "truncated". */
  readonly headFile: string;
  #seq = 0;
  #damaged: string | null = null;
  #full = false;
  #head = GENESIS;
  #chain: Promise<void> = Promise.resolve();
  #loaded = false;
  #now: () => number;

  constructor(configPath: string, now: () => number = Date.now) {
    this.dir = join(dirname(configPath), "blackbox");
    this.file = join(this.dir, "chain.jsonl");
    this.anchorsFile = join(this.dir, "anchors.jsonl");
    this.headFile = join(this.dir, "head.json");
    this.#now = now;
  }

  get head() {
    return { count: this.#seq, hash: this.#head };
  }

  get damaged() {
    return this.#damaged;
  }

  /**
   * Reads the last complete record (tail of the file) to continue the chain. A torn last line (crash mid-write) is
   * closed with a newline so later records start clean; verification will flag it. Never throws on content.
   */
  async load() {
    await mkdir(this.dir, { recursive: true, mode: 0o700 });
    await chmod(this.dir, 0o700).catch(() => {});
    const s = await stat(this.file).catch(() => null);
    if (s && s.size > 0) {
      const fh = await open(this.file, "r");
      let endsClean = true;
      try {
        const len = Math.min(s.size, 256 * 1024);
        const buf = Buffer.alloc(len);
        await fh.read(buf, 0, len, s.size - len);
        const text = buf.toString("utf8");
        endsClean = text.endsWith("\n");
        const lines = text.split("\n").filter(Boolean);
        for (let i = lines.length - 1; i >= 0; i--) {
          try {
            const r = JSON.parse(lines[i]!) as BoxRecord;
            if (typeof r.seq === "number" && typeof r.hash === "string") {
              this.#seq = r.seq;
              this.#head = r.hash;
              break;
            }
          } catch {
            this.#damaged = "torn";
          }
        }
      } finally {
        await fh.close();
      }
      if (!endsClean) {
        this.#damaged = "torn";
        await appendFile(this.file, "\n", { mode: 0o600, flag: "a" }).catch(() => {});
      }
      this.#full = s.size >= MAX_CHAIN_BYTES;
    }
    const saved = await readFile(this.headFile, "utf8").then((t) => JSON.parse(t) as { count: number; hash: string }, () => null);
    if (saved && saved.count > this.#seq) this.#damaged = "truncated";
    this.#loaded = true;
  }

  append(source: string, kind: BoxRecord["kind"], data: Record<string, unknown>, at?: string): Promise<BoxRecord> {
    const p = this.#chain.then(async () => {
      if (!this.#loaded) await this.load();
      if (this.#full) throw new AppError("agent.blackbox.full", 507);
      let bounded = boundData(data) as Record<string, unknown>;
      if (JSON.stringify(bounded).length > MAX_DATA_CHARS) bounded = { truncated: true };
      const rec = { seq: this.#seq + 1, at: at ?? new Date(this.#now()).toISOString(), source: source.slice(0, 100), kind, data: bounded };
      const full: BoxRecord = { ...rec, prev: this.#head, hash: recordHash(this.#head, rec) };
      // "a" = O_APPEND; works with chattr +a.
      const line = JSON.stringify(full) + "\n";
      await appendFile(this.file, line, { mode: 0o600, flag: "a" });
      this.#seq = full.seq;
      this.#head = full.hash;
      await writeFile(this.headFile, JSON.stringify({ count: full.seq, hash: full.hash }), { mode: 0o600 }).catch(() => {});
      const st = await stat(this.file).catch(() => null);
      if (st && st.size >= MAX_CHAIN_BYTES) this.#full = true;
      return full;
    });
    this.#chain = p.then(
      () => {},
      () => {},
    );
    return p;
  }

  /**
   * Walks the whole chain up to the head at the start of the call (records appended meanwhile don't count).
   * brokenAt = first seq whose prev/hash/seq doesn't fit. Anchors on file must match the record of their count; an
   * anchor past the end of the chain means the chain was cut.
   */
  async verify(): Promise<{ ok: boolean; count: number; head: string; brokenAt: number | null; reason: string | null; anchorMismatch: string[]; torn: number }> {
    await this.#chain;
    const target = { seq: this.#seq, head: this.#head };
    const anchors = await this.anchors(Infinity);
    const want = new Map(anchors.map((a) => [a.count, a]));
    const mismatch = new Set<string>();
    let torn = 0;
    const done = (ok: boolean, count: number, head: string, brokenAt: number | null, reason: string | null) => {
      for (const a of anchors) if (a.count > count) mismatch.add(a.date);
      return { ok: ok && mismatch.size === 0, count, head, brokenAt, reason: reason ?? (mismatch.size ? "anchor" : null), anchorMismatch: [...mismatch], torn };
    };
    if (this.#damaged === "truncated") return done(false, target.seq, target.head, target.seq + 1, "truncated");
    const s = await stat(this.file).catch(() => null);
    if (!s) return done(target.seq === 0, 0, GENESIS, target.seq === 0 ? null : 1, target.seq === 0 ? null : "truncated");
    let prev = GENESIS;
    let seq = 0;
    const rl = createInterface({ input: createReadStream(this.file, "utf8"), crlfDelay: Infinity });
    for await (const line of rl) {
      if (seq >= target.seq) break;
      if (!line) continue;
      let r: BoxRecord;
      try {
        r = JSON.parse(line) as BoxRecord;
      } catch {
        // A torn line (crash mid-write) holds no record; the chain still has to link across it, so skipping it can't
        // hide a change. Counted and shown.
        torn++;
        continue;
      }
      const bad = r.seq !== seq + 1 ? "sequence" : r.prev !== prev ? "link" : recordHash(prev, r) !== r.hash ? "hash" : null;
      if (bad) {
        rl.close();
        return done(false, seq, prev, seq + 1, bad);
      }
      prev = r.hash;
      seq = r.seq;
      const a = want.get(seq);
      if (a && a.hash !== prev) mismatch.add(a.date);
    }
    rl.close();
    // The in-memory head must match what the file holds (a truncated file would be valid but shorter).
    if (seq !== target.seq || prev !== target.head) return done(false, seq, prev, seq + 1, "truncated");
    return done(true, seq, prev, null, null);
  }

  async recent(limit: number): Promise<BoxRecord[]> {
    await this.#chain;
    const s = await stat(this.file).catch(() => null);
    if (!s) return [];
    const fh = await open(this.file, "r");
    try {
      const len = Math.min(s.size, 2 * 1024 * 1024);
      const buf = Buffer.alloc(len);
      await fh.read(buf, 0, len, s.size - len);
      const lines = buf.toString("utf8").split("\n").filter(Boolean);
      if (len < s.size) lines.shift(); // first line may be cut
      return lines
        .slice(-limit)
        .reverse()
        .flatMap((l) => {
          try {
            return [JSON.parse(l) as BoxRecord];
          } catch {
            return []; // a torn line holds no record
          }
        });
    } finally {
      await fh.close();
    }
  }

  async addAnchor(a: { date: string; count: number; hash: string; telegram: boolean }) {
    await appendFile(this.anchorsFile, JSON.stringify({ ...a, at: new Date(this.#now()).toISOString() }) + "\n", { mode: 0o600, flag: "a" });
  }

  async anchors(limit = 60): Promise<Array<{ date: string; count: number; hash: string; telegram: boolean; at: string }>> {
    const t = await readFile(this.anchorsFile, "utf8").catch(() => "");
    return t
      .split("\n")
      .filter(Boolean)
      .flatMap((l) => {
        try {
          return [JSON.parse(l)];
        } catch {
          return [];
        }
      })
      .reverse()
      .slice(0, limit);
  }
}

/** Push side: a persistent queue sent to another agent's /v1/blackbox/append. */
export class BlackBoxPusher {
  readonly file: string;
  #queue: Array<{ n: number; at: string; kind: BoxRecord["kind"]; data: Record<string, unknown> }> = [];
  #next = 1;
  #dropped = 0;
  #ctx: Ctx;
  #fetch: Fetch;
  #flushing = false;
  #save: Promise<void> = Promise.resolve();
  lastError: string | null = null;
  lastSentAt: string | null = null;

  constructor(ctx: Ctx, f: Fetch = fetch) {
    this.#ctx = ctx;
    this.#fetch = f;
    this.file = join(dirname(ctx.store.path), "blackbox-queue.jsonl");
  }

  get pending() {
    return this.#queue.length;
  }

  async load() {
    const t = await readFile(this.file, "utf8").catch(() => "");
    this.#queue = t
      .split("\n")
      .filter(Boolean)
      .flatMap((l) => {
        try {
          return [JSON.parse(l)];
        } catch {
          return [];
        }
      })
      .map((x, i) => ({ ...x, n: i + 1 }));
    this.#next = this.#queue.length + 1;
  }

  #persist() {
    const data = this.#queue.map((x) => JSON.stringify(x)).join("\n") + (this.#queue.length ? "\n" : "");
    this.#save = this.#save
      .then(async () => {
        const tmp = `${this.file}.tmp`;
        await writeFile(tmp, data, { mode: 0o600 });
        await rename(tmp, this.file);
      })
      .catch(() => {});
    return this.#save;
  }

  push(kind: BoxRecord["kind"], data: Record<string, unknown>) {
    this.#queue.push({ n: this.#next++, at: new Date().toISOString(), kind, data: boundData(data) as Record<string, unknown> });
    if (this.#queue.length > QUEUE_MAX) {
      this.#dropped += this.#queue.length - QUEUE_MAX;
      this.#queue.splice(0, this.#queue.length - QUEUE_MAX);
    }
    void this.#persist();
  }

  async flush(): Promise<number> {
    const b = this.#ctx.store.get().security.blackbox;
    if (this.#flushing || b.mode !== "push" || !b.url || !b.token || !this.#queue.length) return 0;
    this.#flushing = true;
    let sent = 0;
    try {
      while (this.#queue.length) {
        const batch = this.#queue.slice(0, 200);
        const lastN = batch[batch.length - 1]!.n;
        const body = { entries: batch.map(({ n: _, ...e }) => e), ...(this.#dropped ? { dropped: this.#dropped } : {}) };
        const res = await this.#fetch(new URL("/v1/blackbox/append", b.url).toString(), {
          method: "POST",
          headers: { authorization: `Bearer ${b.token}`, "content-type": "application/json" },
          body: JSON.stringify(body),
          signal: AbortSignal.timeout(20_000),
          redirect: "error",
        }).catch(() => null);
        if (!res || !res.ok) {
          this.lastError = res ? `http ${res.status}` : "unreachable";
          break;
        }
        // Remove exactly what was sent (the queue may have been trimmed at the front meanwhile).
        this.#queue = this.#queue.filter((x) => x.n > lastN);
        this.#dropped = 0;
        sent += batch.length;
        this.lastError = null;
        this.lastSentAt = new Date().toISOString();
      }
      await this.#persist();
    } finally {
      this.#flushing = false;
    }
    return sent;
  }
}

export function assertLocal(ctx: Ctx) {
  if (ctx.store.get().security.blackbox.mode !== "local") throw new AppError("agent.blackbox.notLocal", 409);
}
