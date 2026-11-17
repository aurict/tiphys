// secrets-meta.json (PLAN.md §13.3), next to agent.json, 0600: per file and key the rotation data of secrets —
// {fingerprint = HMAC-SHA256(agent-local key, value), firstSeenAt, lastChangedAt, changedBy, maxAgeDays?, mark?}.
// No values are stored. The HMAC key (secrets-hmac.key, 0600, 32 random bytes) never leaves the agent. A changed
// fingerprint on a read means the value was changed outside Tiphys. Per file, `rotationNotifiedOn` (local date) keeps the
// rotation reminder (C-2) to one notification per file per day across restarts.
import { createHmac, randomBytes } from "node:crypto";
import { chmod, mkdir, open, readFile, rename, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { join } from "node:path";

export interface KeyMeta {
  fingerprint?: string;
  firstSeenAt?: string;
  lastChangedAt?: string;
  changedBy?: "tiphys" | "external";
  maxAgeDays?: number;
  /** The user's classification; overrides the automatic one. */
  mark?: boolean;
}

interface FileMeta {
  file: string;
  keys: Record<string, KeyMeta>;
  /** Local date (YYYY-MM-DD) of the last secret.rotationDue notification for this file. */
  rotationNotifiedOn?: string;
}

interface MetaDoc {
  version: 1;
  files: Record<string, FileMeta>;
}

const isPolicy = (k: KeyMeta) => k.maxAgeDays !== undefined || k.mark !== undefined;

export class SecretsMeta {
  readonly path: string;
  #key: Buffer;
  #doc: MetaDoc;
  #chain: Promise<void> = Promise.resolve();
  #now: () => number;

  private constructor(path: string, key: Buffer, doc: MetaDoc, now: () => number) {
    this.path = path;
    this.#key = key;
    this.#doc = doc;
    this.#now = now;
  }

  static async open(dir: string, now: () => number = Date.now): Promise<SecretsMeta> {
    await mkdir(dir, { recursive: true, mode: 0o700 });
    const keyPath = join(dir, "secrets-hmac.key");
    let key: Buffer | null = null;
    const existing = await readFile(keyPath, "utf8").catch(() => null);
    if (existing && /^[a-f0-9]{64}\s*$/.test(existing)) key = Buffer.from(existing.trim(), "hex");
    if (!key) {
      key = randomBytes(32);
      const fh = await open(keyPath, constants.O_WRONLY | constants.O_CREAT | constants.O_TRUNC | constants.O_NOFOLLOW, 0o600);
      await fh.writeFile(key.toString("hex") + "\n");
      await fh.chmod(0o600);
      await fh.close();
    }
    const path = join(dir, "secrets-meta.json");
    let doc: MetaDoc = { version: 1, files: {} };
    const raw = await readFile(path, "utf8").catch(() => null);
    if (raw) {
      try {
        const d = JSON.parse(raw) as MetaDoc;
        if (d && d.version === 1 && d.files && typeof d.files === "object") doc = d;
      } catch {
        // A corrupt file starts over; fingerprints are re-learned on the next read.
      }
    }
    return new SecretsMeta(path, key, doc, now);
  }

  fingerprint(value: string): string {
    return createHmac("sha256", this.#key).update(value, "utf8").digest("hex");
  }

  keys(fileId: string): Record<string, KeyMeta> {
    return this.#doc.files[fileId]?.keys ?? {};
  }

  files(): Array<{ fileId: string; file: string; keys: Record<string, KeyMeta>; rotationNotifiedOn?: string }> {
    return Object.entries(this.#doc.files).map(([fileId, f]) => ({ fileId, file: f.file, keys: f.keys, ...(f.rotationNotifiedOn ? { rotationNotifiedOn: f.rotationNotifiedOn } : {}) }));
  }

  setRotationNotified(fileId: string, day: string): void {
    const f = this.#doc.files[fileId];
    if (f) f.rotationNotifiedOn = day;
  }

  #file(fileId: string, file: string): FileMeta {
    const f = (this.#doc.files[fileId] ??= { file, keys: {} });
    f.file = file;
    return f;
  }

  /**
   * Records the current entries of a file: secrets get a fingerprint (a change counts as `by`), non-secrets lose
   * theirs, keys gone from the file are dropped. `changed`: something changed (then flush()); `external`: secret keys
   * whose known fingerprint changed while `by` is "external" (the value was changed outside Tiphys).
   */
  observe(fileId: string, file: string, entries: Array<{ key: string; value: string; secret: boolean }>, by: "tiphys" | "external"): { changed: boolean; external: string[] } {
    const external: string[] = [];
    const before = JSON.stringify(this.#doc.files[fileId] ?? null);
    const f = this.#file(fileId, file);
    const now = new Date(this.#now()).toISOString();
    const present = new Set(entries.map((e) => e.key));
    for (const k of Object.keys(f.keys)) if (!present.has(k)) delete f.keys[k];
    for (const e of entries) {
      const cur = f.keys[e.key];
      if (!e.secret) {
        if (cur && isPolicy(cur)) f.keys[e.key] = { ...(cur.maxAgeDays !== undefined ? { maxAgeDays: cur.maxAgeDays } : {}), ...(cur.mark !== undefined ? { mark: cur.mark } : {}) };
        else if (cur) delete f.keys[e.key];
        continue;
      }
      const fp = this.fingerprint(e.value);
      if (!cur?.fingerprint) {
        f.keys[e.key] = { ...cur, fingerprint: fp, firstSeenAt: cur?.firstSeenAt ?? now, ...(by === "tiphys" ? { lastChangedAt: now, changedBy: by } : {}) };
      } else if (cur.fingerprint !== fp) {
        f.keys[e.key] = { ...cur, fingerprint: fp, lastChangedAt: now, changedBy: by };
        if (by === "external") external.push(e.key);
      }
    }
    if (!Object.keys(f.keys).length) delete this.#doc.files[fileId];
    return { changed: JSON.stringify(this.#doc.files[fileId] ?? null) !== before, external };
  }

  rename(fileId: string, from: string, to: string): void {
    const f = this.#doc.files[fileId];
    if (!f?.keys[from]) return;
    f.keys[to] = f.keys[from]!;
    delete f.keys[from];
  }

  /** maxAgeDays / mark: a value sets it, null clears it, undefined leaves it. */
  setPolicy(fileId: string, file: string, key: string, p: { maxAgeDays?: number | null; mark?: boolean | null }): void {
    const f = this.#file(fileId, file);
    const k: KeyMeta = { ...f.keys[key] };
    if (p.maxAgeDays === null) delete k.maxAgeDays;
    else if (p.maxAgeDays !== undefined) k.maxAgeDays = p.maxAgeDays;
    if (p.mark === null) delete k.mark;
    else if (p.mark !== undefined) k.mark = p.mark;
    f.keys[key] = k;
  }

  /** Writes the file atomically (0600); writes are serialized. A failed write rejects only its own call. */
  flush(): Promise<void> {
    const body = JSON.stringify(this.#doc, null, 1) + "\n";
    const p = this.#chain.then(async () => {
      const tmp = `${this.path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
      await writeFile(tmp, body, { mode: 0o600 });
      await chmod(tmp, 0o600);
      await rename(tmp, this.path);
    });
    this.#chain = p.catch(() => {});
    return p;
  }
}
