// Write log of the database console (PLAN.md §13.2, D-3): db-writes.jsonl next to agent.json, 0600, one line per
// commit attempt with the full SQL, the row count, device, connection and time (the audit log only has a hash). Past
// 5 MB the file is kept as db-writes.jsonl.1. A password literal in CREATE ROLE/USER is masked; no result values.
import { appendFile, chmod, rename, stat } from "node:fs/promises";

export const WRITE_LOG_MAX_BYTES = 5 * 1024 * 1024;

export interface WriteLogEntry {
  at: string;
  device: string;
  conn: string;
  engine: string;
  sql: string;
  sqlSha256: string;
  /** Rows the statement affected in this run (null for DDL). */
  count: number | null;
  /** committed; countChanged (rolled back, `expected` was previewed); commitFailed (COMMIT itself failed). */
  outcome: "committed" | "countChanged" | "commitFailed";
  expected?: number | null;
}

/** `PASSWORD '…'` (also E'…') in role statements → `PASSWORD '[GİZLİ]'`. */
export const maskPasswords = (sql: string) => sql.replace(/(\b(?:password|identified\s+by)\s+)(E?'(?:[^'\\]|''|\\.)*'?)/gi, "$1'[GİZLİ]'");

export class WriteLog {
  readonly path: string;
  #chain: Promise<void> = Promise.resolve();

  constructor(path: string) {
    this.path = path;
  }

  /** Appends one entry (serialized); rejects when the file can't be written. */
  append(e: WriteLogEntry): Promise<void> {
    const line = JSON.stringify({ ...e, sql: maskPasswords(e.sql) }) + "\n";
    const p = this.#chain.then(async () => {
      const size = await stat(this.path).then((s) => s.size, () => 0);
      if (size >= WRITE_LOG_MAX_BYTES) await rename(this.path, `${this.path}.1`);
      await appendFile(this.path, line, { mode: 0o600 });
      await chmod(this.path, 0o600);
    });
    this.#chain = p.catch(() => {});
    return p;
  }
}
