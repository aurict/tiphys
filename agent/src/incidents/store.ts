// Incident storage: incidents/index.json (summaries) + incidents/<id>.json (full record). Directory 0700, files 0600,
// every write atomic (temp file + rename). Retention: resolved incidents older than 90 days go, and at most 500 are
// kept (oldest resolved first). A missing or unreadable index.json is rebuilt from the incident files; an index entry
// whose file is missing is dropped when read.
import { chmod, mkdir, readdir, readFile, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { summaryOf, type Incident, type IncidentSummary } from "./types.ts";

export const RETENTION_MS = 90 * 24 * 3600_000;
export const MAX_INCIDENTS = 500;
export const ID_RE = /^inc-[a-f0-9]{12}$/;

async function writeAtomic(path: string, data: string) {
  const tmp = `${path}.${process.pid}.${Math.random().toString(36).slice(2)}.tmp`;
  await writeFile(tmp, data, { mode: 0o600 });
  await chmod(tmp, 0o600);
  await rename(tmp, path);
}

export class IncidentStore {
  readonly dir: string;
  readonly index = new Map<string, IncidentSummary>();
  #chain: Promise<void> = Promise.resolve();
  /** Deleted ids (random, never reused): a late save of one is ignored. */
  #removed = new Set<string>();
  #log: (msg: string, err?: unknown) => void;

  constructor(dir: string, log: (msg: string, err?: unknown) => void = () => {}) {
    this.dir = dir;
    this.#log = log;
  }

  async load(): Promise<void> {
    await mkdir(this.dir, { recursive: true, mode: 0o700 });
    await chmod(this.dir, 0o700);
    const raw = await readFile(join(this.dir, "index.json"), "utf8").catch(() => null);
    try {
      if (raw === null) throw null;
      const list = JSON.parse(raw) as IncidentSummary[];
      if (!Array.isArray(list)) throw new Error("not a list");
      for (const s of list) if (s && typeof s === "object" && typeof s.id === "string" && ID_RE.test(s.id)) this.index.set(s.id, s);
    } catch (err) {
      if (raw !== null) this.#log("olay dizini okunamadı, dosyalardan yeniden kuruluyor", err);
      await this.#rebuild();
    }
  }

  /** Rebuilds the index from incidents/<id>.json (unreadable files are skipped and logged). */
  async #rebuild() {
    const names = (await readdir(this.dir).catch(() => [])).filter((n) => n.endsWith(".json") && ID_RE.test(n.slice(0, -5)));
    for (const n of names) {
      try {
        const inc = JSON.parse(await readFile(join(this.dir, n), "utf8")) as Incident;
        if (inc && inc.id === n.slice(0, -5)) this.index.set(inc.id, summaryOf(inc));
      } catch (err) {
        this.#log(`olay dosyası okunamadı: ${n}`, err);
      }
    }
    if (names.length) await this.#queue(() => this.#writeIndex());
  }

  removed(id: string): boolean {
    return this.#removed.has(id);
  }

  async read(id: string): Promise<Incident | null> {
    if (!ID_RE.test(id) || !this.index.has(id)) return null;
    await this.#chain;
    const raw = await readFile(join(this.dir, `${id}.json`), "utf8").catch((e: NodeJS.ErrnoException) => (e.code === "ENOENT" ? undefined : null));
    if (raw === undefined) {
      // Orphan index entry (file gone): dropped.
      if (this.index.delete(id)) void this.#queue(() => this.#writeIndex());
      return null;
    }
    if (!raw) return null;
    try {
      return JSON.parse(raw) as Incident;
    } catch {
      // Corrupt: the entry stays listed so it can be deleted.
      return null;
    }
  }

  /** Queues a write of the incident and the index. */
  save(i: Incident): Promise<void> {
    if (this.#removed.has(i.id)) return this.#chain;
    this.index.set(i.id, summaryOf(i));
    const body = JSON.stringify(i);
    return this.#queue(async () => {
      await writeAtomic(join(this.dir, `${i.id}.json`), body);
      await this.#writeIndex();
    });
  }

  remove(id: string): Promise<void> {
    this.#removed.add(id);
    this.index.delete(id);
    return this.#queue(async () => {
      await rm(join(this.dir, `${id}.json`), { force: true });
      await this.#writeIndex();
    });
  }

  /** Applies retention; returns the removed ids. Active incidents are never removed by age. */
  prune(now: number): string[] {
    const removed: string[] = [];
    for (const s of this.index.values()) {
      if (s.status === "resolved" && s.resolvedAt && now - Date.parse(s.resolvedAt) > RETENTION_MS) removed.push(s.id);
    }
    const rest = [...this.index.values()].filter((s) => !removed.includes(s.id));
    if (rest.length > MAX_INCIDENTS) {
      const byAge = (a: IncidentSummary, b: IncidentSummary) => a.updatedAt.localeCompare(b.updatedAt);
      const order = [...rest.filter((s) => s.status === "resolved").sort(byAge), ...rest.filter((s) => s.status !== "resolved").sort(byAge)];
      removed.push(...order.slice(0, rest.length - MAX_INCIDENTS).map((s) => s.id));
    }
    for (const id of removed) void this.remove(id);
    return removed;
  }

  /** Resolves once every queued write has finished. */
  flush(): Promise<void> {
    return this.#chain;
  }

  #queue(fn: () => Promise<void>): Promise<void> {
    this.#chain = this.#chain.then(fn).catch((err) => this.#log("olay kaydı yazılamadı", err));
    return this.#chain;
  }

  async #writeIndex() {
    const list = [...this.index.values()].sort((a, b) => b.openedAt.localeCompare(a.openedAt));
    await writeAtomic(join(this.dir, "index.json"), JSON.stringify(list));
  }
}
