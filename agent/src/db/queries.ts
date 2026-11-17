// Saved queries of the database console (PLAN.md §13.2, D-2): db-queries.json next to agent.json, 0600, written
// atomically. Each query belongs to one connection and only ever runs through the read-only path; `chart` tells the
// app how to draw the result (table, a single stat, line or bar with x and y columns).
import { randomBytes } from "node:crypto";
import { chmod, readFile, rename, writeFile } from "node:fs/promises";
import { z } from "zod";
import { AppError } from "../errors.ts";
import { LIMITS } from "./sql.ts";

export const MAX_SAVED_QUERIES = 500;

const column = z.string().min(1).max(128);
export const chartSchema = z.strictObject({
  type: z.enum(["table", "stat", "line", "bar"]),
  x: column.optional(),
  y: z.array(column).max(8).optional(),
});
export const paramValue = z.union([z.string().max(64 * 1024), z.number(), z.boolean(), z.null()]);

export const savedQuerySchema = z.strictObject({
  id: z.string().regex(/^q-[a-f0-9]{8,32}$/),
  connectionId: z.string().regex(/^[a-z0-9][a-z0-9-]{0,62}$/),
  name: z.string().min(1).max(80),
  sql: z.string().min(1).max(LIMITS.maxSqlChars),
  params: z.array(paramValue).max(LIMITS.maxParams).default([]),
  chart: chartSchema.default({ type: "table" }),
  createdAt: z.string(),
  updatedAt: z.string(),
});
export type SavedQuery = z.infer<typeof savedQuerySchema>;

const fileSchema = z.object({ version: z.literal(1), queries: z.array(savedQuerySchema).max(MAX_SAVED_QUERIES) });

export type SavedQueryInput = Pick<SavedQuery, "connectionId" | "name" | "sql"> & Partial<Pick<SavedQuery, "params" | "chart">>;

export class SavedQueries {
  readonly path: string;
  #list: SavedQuery[] = [];
  #loaded = false;
  #chain: Promise<void> = Promise.resolve();
  #now: () => number;

  constructor(path: string, now: () => number = Date.now) {
    this.path = path;
    this.#now = now;
  }

  async #load(): Promise<void> {
    if (this.#loaded) return;
    const text = await readFile(this.path, "utf8").catch((e: NodeJS.ErrnoException) => {
      if (e.code === "ENOENT") return null;
      throw e;
    });
    // A corrupt file is an error, not an empty list (saving would overwrite it).
    this.#list = text === null ? [] : fileSchema.parse(JSON.parse(text)).queries;
    this.#loaded = true;
  }

  /** Serializes changes: load, change, write (tmp + rename, 0600). */
  #mutate<T>(fn: (list: SavedQuery[]) => T): Promise<T> {
    const p = this.#chain.then(async () => {
      await this.#load();
      const next = this.#list.map((x) => ({ ...x }));
      const out = fn(next);
      const body = JSON.stringify({ version: 1, queries: next }, null, 1) + "\n";
      const tmp = `${this.path}.${process.pid}.${randomBytes(4).toString("hex")}.tmp`;
      await writeFile(tmp, body, { mode: 0o600 });
      await chmod(tmp, 0o600);
      await rename(tmp, this.path);
      this.#list = next;
      return out;
    });
    this.#chain = p.then(() => {}, () => {});
    return p;
  }

  async list(connectionId?: string): Promise<SavedQuery[]> {
    await this.#chain;
    await this.#load();
    return this.#list.filter((x) => !connectionId || x.connectionId === connectionId);
  }

  async get(id: string): Promise<SavedQuery> {
    const q = (await this.list()).find((x) => x.id === id);
    if (!q) throw new AppError("agent.db.queryNotFound", 404, { id });
    return q;
  }

  create(input: SavedQueryInput): Promise<SavedQuery> {
    return this.#mutate((list) => {
      if (list.length >= MAX_SAVED_QUERIES) throw new AppError("agent.db.tooManyQueries", 409, { max: MAX_SAVED_QUERIES });
      const at = new Date(this.#now()).toISOString();
      const q = savedQuerySchema.parse({ id: `q-${randomBytes(6).toString("hex")}`, ...input, createdAt: at, updatedAt: at });
      list.push(q);
      return q;
    });
  }

  patch(id: string, p: Partial<SavedQueryInput>): Promise<SavedQuery> {
    return this.#mutate((list) => {
      const i = list.findIndex((x) => x.id === id);
      if (i < 0) throw new AppError("agent.db.queryNotFound", 404, { id });
      const q = savedQuerySchema.parse({ ...list[i], ...p, updatedAt: new Date(this.#now()).toISOString() });
      list[i] = q;
      return q;
    });
  }

  remove(id: string): Promise<void> {
    return this.#mutate((list) => {
      const i = list.findIndex((x) => x.id === id);
      if (i < 0) throw new AppError("agent.db.queryNotFound", 404, { id });
      list.splice(i, 1);
    });
  }
}
