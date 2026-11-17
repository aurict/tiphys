// Database console service (PLAN.md §13.2): connections in agent.json (credentials never leave the agent), discovery,
// connection test, schema browser, table preview and read-only queries with limits (D-1); saved queries, CSV export
// and MySQL/MariaDB (D-2); the write mode — preview in a rolled-back transaction, then commit with a preview token
// only if the row count is unchanged — and the read-only role helper (D-3).
import { createHash, randomBytes } from "node:crypto";
import { dirname, join } from "node:path";
import type { ConfigStore, DbConnection } from "../config.ts";
import { dbConnectionSchema } from "../config.ts";
import { AppError } from "../errors.ts";
import { run as execRun } from "../exec.ts";
import { allowedPath } from "../paths.ts";
import { PreviewTokens } from "../preview.ts";
import { discover, resolveContainer, type Runner } from "./docker.ts";
import { mysqlPreview, mysqlQuery, mysqlSchema, mysqlStream, mysqlTest, mysqlWrite, type MyEndpoint } from "./mysql.ts";
import { pgPreview, pgQuery, pgSchema, pgStream, pgTest, pgWrite, type PgEndpoint } from "./pg.ts";
import { SavedQueries } from "./queries.ts";
import {
  checkReadStatement,
  checkWriteStatement,
  columnKinds,
  dialectOf,
  quoteIdent,
  statements,
  type Engine,
  type RowSink,
  type RowsResult,
  type SchemaResult,
  type WriteOutcome,
} from "./sql.ts";
import { sqliteAvailable, sqlitePreview, sqliteQuery, sqliteSchema, sqliteStream, sqliteTest } from "./sqlite.ts";
import { WriteLog } from "./writelog.ts";

export const QUERIES_PER_MIN = 30;
export const EXPORTS_PER_MIN = 3;
export const WRITES_PER_WINDOW = 10;
export const WRITE_WINDOW_MS = 10 * 60_000;
/** Write previews per device per WRITE_WINDOW_MS (a MySQL preview still runs the statement before rolling back). */
export const WRITE_PREVIEWS_PER_WINDOW = 30;
export const MAX_CONCURRENT = 2;
const DEFAULT_PORT = { postgres: 5432, mysql: 3306 } as const;
const WRITE_KIND = "db.write";

type Credential = NonNullable<DbConnection["readCredential"]>;
type Param = string | number | boolean | null;

export const sqlSha256 = (sql: string) => createHash("sha256").update(sql).digest("hex");

function publicCredential(cred: Credential | undefined) {
  if (!cred) return null;
  if ("fromContainerEnv" in cred) return { mode: "fromContainerEnv" as const };
  return { mode: "password" as const, user: cred.user, hasPassword: cred.password !== undefined };
}

/** What the API returns for a connection: never a password. */
export function publicConnection(c: DbConnection) {
  const fromEnv = !!c.readCredential && "fromContainerEnv" in c.readCredential;
  return {
    id: c.id,
    name: c.name,
    engine: c.engine,
    target: c.target,
    database: c.database ?? null,
    readCredential: publicCredential(c.readCredential),
    writeCredential: publicCredential(c.writeCredential),
    readRole: c.readRole ?? null,
    allowSuperuserReads: c.allowSuperuserReads === true,
    // The container's POSTGRES_USER / MySQL root is a superuser: only the transaction-level layers protect the data.
    warnings: fromEnv ? ["superuserCredential"] : [],
  };
}

type CredentialInput = { user: string; password?: string | null } | { fromContainerEnv: true };

export interface CreateInput {
  id?: string;
  name: string;
  engine: Engine;
  target: DbConnection["target"];
  database?: string;
  readCredential?: CredentialInput;
  writeCredential?: CredentialInput;
  readRole?: string;
  allowSuperuserReads?: boolean;
}

export interface PatchInput {
  name?: string;
  target?: DbConnection["target"];
  database?: string | null;
  readCredential?: CredentialInput;
  /** null removes the separate write credential (the write mode then uses the read credential). */
  writeCredential?: CredentialInput | null;
  /** null removes the read role. */
  readRole?: string | null;
  allowSuperuserReads?: boolean;
}

const sameTarget = (a: DbConnection["target"], b: DbConnection["target"]) => JSON.stringify(a) === JSON.stringify(b);

function credentialOf(input: CredentialInput | undefined): Credential | undefined {
  if (!input) return undefined;
  if ("fromContainerEnv" in input) return { fromContainerEnv: true };
  return { user: input.user, ...(typeof input.password === "string" ? { password: input.password } : {}) };
}

/**
 * PATCH of one credential: omitted → kept; a user without a password keeps the stored password only while the target
 * stays the same (a stored password is never sent to a new address); `password: null` removes it.
 */
function mergeCredential(old: Credential | undefined, input: CredentialInput | undefined, moved: boolean): Credential | undefined {
  const oldPassword = old && "password" in old ? old.password : undefined;
  if (!input) {
    if (moved && oldPassword !== undefined) throw new AppError("agent.db.passwordRequired", 400, {});
    return old;
  }
  const cred = credentialOf(input);
  const pw = "user" in input ? input.password : null;
  if (cred && "user" in cred && pw === undefined && oldPassword !== undefined) {
    if (moved) throw new AppError("agent.db.passwordRequired", 400, {});
    return { ...cred, password: oldPassword };
  }
  return cred;
}

/** Engine drivers (replaceable in tests). */
export interface Drivers {
  pg: {
    query: typeof pgQuery;
    preview: typeof pgPreview;
    schema: typeof pgSchema;
    test: typeof pgTest;
    stream: typeof pgStream;
    write: typeof pgWrite;
  };
  mysql: {
    query: typeof mysqlQuery;
    preview: typeof mysqlPreview;
    schema: typeof mysqlSchema;
    test: typeof mysqlTest;
    stream: typeof mysqlStream;
    write: typeof mysqlWrite;
  };
}

const DRIVERS: Drivers = {
  pg: { query: pgQuery, preview: pgPreview, schema: pgSchema, test: pgTest, stream: pgStream, write: pgWrite },
  mysql: { query: mysqlQuery, preview: mysqlPreview, schema: mysqlSchema, test: mysqlTest, stream: mysqlStream, write: mysqlWrite },
};

type Endpoint = { family: "pg"; ep: PgEndpoint } | { family: "mysql"; ep: MyEndpoint };

interface PendingWrite {
  conn: string;
  sql: string;
  stmt: string;
  check: { kind: "dml" | "ddl"; verb: string; returning: boolean };
  count: number | null;
  timeoutMs: number;
  expiresAt: number;
}

export interface DbServiceOpts {
  store: ConfigStore;
  run?: Runner;
  now?: () => number;
  drivers?: { pg?: Partial<Drivers["pg"]>; mysql?: Partial<Drivers["mysql"]> };
  /** Preview token lifetime (default 120 s). */
  previewTtlMs?: number;
}

export class DbService {
  #store: ConfigStore;
  #run: Runner;
  #now: () => number;
  #drivers: Drivers;
  #rates = new Map<string, number[]>();
  #busy = new Map<string, number>();
  #previews: PreviewTokens;
  #pending = new Map<string, PendingWrite>();
  readonly queries: SavedQueries;
  readonly writes: WriteLog;

  constructor(o: DbServiceOpts) {
    this.#store = o.store;
    this.#run = o.run ?? execRun;
    this.#now = o.now ?? Date.now;
    this.#drivers = { pg: { ...DRIVERS.pg, ...o.drivers?.pg }, mysql: { ...DRIVERS.mysql, ...o.drivers?.mysql } };
    this.#previews = new PreviewTokens({ now: this.#now, ...(o.previewTtlMs ? { ttlMs: o.previewTtlMs } : {}) });
    const dir = dirname(o.store.path);
    this.queries = new SavedQueries(join(dir, "db-queries.json"), this.#now);
    this.writes = new WriteLog(join(dir, "db-writes.jsonl"));
  }

  async engines() {
    return { postgres: true, mysql: true, mariadb: true, sqlite: await sqliteAvailable() };
  }

  list() {
    return this.#store.get().databases.connections.map(publicConnection);
  }

  get(id: string): DbConnection {
    const c = this.#store.get().databases.connections.find((x) => x.id === id);
    if (!c) throw new AppError("agent.db.connectionNotFound", 404, { id });
    return c;
  }

  async create(input: CreateInput) {
    const id = input.id ?? `db-${randomBytes(4).toString("hex")}`;
    const conn = this.#validate({
      id,
      name: input.name,
      engine: input.engine,
      target: input.target,
      ...(input.database ? { database: input.database } : {}),
      ...(input.readCredential ? { readCredential: credentialOf(input.readCredential) } : {}),
      ...(input.writeCredential ? { writeCredential: credentialOf(input.writeCredential) } : {}),
      ...(input.readRole ? { readRole: input.readRole } : {}),
      ...(input.allowSuperuserReads !== undefined ? { allowSuperuserReads: input.allowSuperuserReads } : {}),
    });
    await this.#store.update((c) => {
      if (c.databases.connections.some((x) => x.id === id)) throw new AppError("agent.db.connectionExists", 409, { id });
      c.databases.connections.push(conn);
      return c;
    });
    return publicConnection(conn);
  }

  /** Omitted fields are kept; see mergeCredential for passwords. */
  async patch(id: string, p: PatchInput) {
    let out: DbConnection | undefined;
    await this.#store.update((c) => {
      const i = c.databases.connections.findIndex((x) => x.id === id);
      if (i < 0) throw new AppError("agent.db.connectionNotFound", 404, { id });
      const old = c.databases.connections[i]!;
      const target = p.target ?? old.target;
      const moved = !sameTarget(target, old.target);
      const read = mergeCredential(old.readCredential, p.readCredential, moved);
      const write = p.writeCredential === null ? undefined : mergeCredential(old.writeCredential, p.writeCredential, moved);
      const database = p.database === null ? undefined : (p.database ?? old.database);
      const readRole = p.readRole === null ? undefined : (p.readRole ?? old.readRole);
      const allowSuperuserReads = p.allowSuperuserReads ?? old.allowSuperuserReads;
      out = this.#validate({
        id,
        name: p.name ?? old.name,
        engine: old.engine,
        target,
        ...(database ? { database } : {}),
        ...(read ? { readCredential: read } : {}),
        ...(write ? { writeCredential: write } : {}),
        ...(readRole ? { readRole } : {}),
        ...(allowSuperuserReads !== undefined ? { allowSuperuserReads } : {}),
      });
      c.databases.connections[i] = out;
      return c;
    });
    return publicConnection(out!);
  }

  async remove(id: string) {
    await this.#store.update((c) => {
      const n = c.databases.connections.length;
      c.databases.connections = c.databases.connections.filter((x) => x.id !== id);
      if (c.databases.connections.length === n) throw new AppError("agent.db.connectionNotFound", 404, { id });
      return c;
    });
  }

  #validate(raw: unknown): DbConnection {
    const r = dbConnectionSchema.safeParse(raw);
    if (!r.success) {
      throw new AppError("agent.request.invalid", 400, { issues: r.error.issues.map((i) => ({ path: i.path.map(String).join("."), message: i.code === "custom" ? i.message : i.code })) });
    }
    return r.data;
  }

  discover() {
    return discover(this.#run);
  }

  #limit(key: string, max: number, windowMs: number, code: string, params: Record<string, number>) {
    const now = this.#now();
    const recent = (this.#rates.get(key) ?? []).filter((t) => now - t < windowMs);
    if (recent.length >= max) throw new AppError(code, 429, params);
    recent.push(now);
    this.#rates.set(key, recent);
  }

  /** Rate limit for SQL-running calls (query, preview, saved query run, write preview), per device. */
  checkRate(device: string) {
    this.#limit(`q:${device}`, QUERIES_PER_MIN, 60_000, "agent.db.rateLimited", { perMinute: QUERIES_PER_MIN });
  }

  checkExportRate(device: string) {
    this.#limit(`x:${device}`, EXPORTS_PER_MIN, 60_000, "agent.db.exportRateLimited", { perMinute: EXPORTS_PER_MIN });
  }

  checkWritePreviewRate(device: string) {
    this.#limit(`wp:${device}`, WRITE_PREVIEWS_PER_WINDOW, WRITE_WINDOW_MS, "agent.db.writePreviewRateLimited", { perTenMinutes: WRITE_PREVIEWS_PER_WINDOW });
  }

  checkWriteRate(device: string) {
    this.#limit(`w:${device}`, WRITES_PER_WINDOW, WRITE_WINDOW_MS, "agent.db.writeRateLimited", { perTenMinutes: WRITES_PER_WINDOW });
  }

  /** At most MAX_CONCURRENT database calls per connection at once. */
  async #exclusive<T>(id: string, fn: () => Promise<T>): Promise<T> {
    const n = this.#busy.get(id) ?? 0;
    if (n >= MAX_CONCURRENT) throw new AppError("agent.db.busy", 429, { maxConcurrent: MAX_CONCURRENT });
    this.#busy.set(id, n + 1);
    try {
      return await fn();
    } finally {
      const left = (this.#busy.get(id) ?? 1) - 1;
      if (left > 0) this.#busy.set(id, left);
      else this.#busy.delete(id);
    }
  }

  /** Host, port and credentials; container IP and env are read now, never stored. */
  async #endpoint(c: DbConnection, which: "read" | "write" = "read"): Promise<Endpoint> {
    const t = c.target;
    const cred = which === "write" ? (c.writeCredential ?? c.readCredential!) : c.readCredential!;
    if ("path" in t) throw new AppError("agent.request.invalid", 400, {});
    const family = dialectOf(c.engine) === "mysql" ? "mysql" : "postgres";
    const fromEnv = "fromContainerEnv" in cred;
    let host: string;
    let env: { user: string; password?: string; database?: string } | undefined;
    if ("container" in t) {
      const r = await resolveContainer(this.#run, t.container, t.network, fromEnv, family);
      host = r.host;
      env = r.env;
    } else host = t.host;
    const port = t.port ?? DEFAULT_PORT[family];
    const pc = fromEnv ? env! : (cred as { user: string; password?: string });
    const base = { host, port, user: pc.user, ...(pc.password !== undefined ? { password: pc.password } : {}) };
    if (family === "mysql") {
      const database = c.database ?? (fromEnv ? env!.database : undefined);
      return { family: "mysql", ep: { ...base, ...(database ? { database } : {}) } };
    }
    const guard = which === "read" ? { ...(c.readRole ? { readRole: c.readRole } : {}), ...(c.allowSuperuserReads ? { allowSuperuserReads: true } : {}) } : {};
    return { family: "pg", ep: { ...base, database: c.database ?? (fromEnv ? env!.database : undefined) ?? "postgres", ...guard } };
  }

  async #sqlitePath(c: DbConnection): Promise<string> {
    if (!("path" in c.target)) throw new AppError("agent.request.invalid", 400, {});
    return allowedPath(this.#store.get(), c.target.path);
  }

  async test(id: string, timeoutMs: number) {
    const c = this.get(id);
    return this.#exclusive(id, async () => {
      const started = this.#now();
      if (c.engine === "sqlite") {
        const r = await sqliteTest(await this.#sqlitePath(c), timeoutMs);
        return { ok: true, engine: c.engine, ...r, latencyMs: this.#now() - started, warnings: [] as string[] };
      }
      const e = await this.#endpoint(c);
      const r = e.family === "pg" ? await this.#drivers.pg.test(e.ep, timeoutMs) : await this.#drivers.mysql.test(e.ep, timeoutMs);
      const warnings = [...publicConnection(c).warnings];
      if (r.superuser && !warnings.includes("superuserCredential")) warnings.push("superuserCredential");
      // PostgreSQL: user SQL reads are refused until a read role is set or superuser reads are acknowledged.
      if (e.family === "pg" && r.superuser && !c.readRole && !c.allowSuperuserReads) warnings.push("superuserReadsDisabled");
      return { ok: true, engine: c.engine, ...r, latencyMs: this.#now() - started, warnings };
    });
  }

  async schema(id: string, timeoutMs: number): Promise<SchemaResult & { engine: Engine }> {
    const c = this.get(id);
    return this.#exclusive(id, async () => {
      if (c.engine === "sqlite") return { engine: c.engine, ...(await sqliteSchema(await this.#sqlitePath(c), timeoutMs)) };
      const e = await this.#endpoint(c);
      return { engine: c.engine, ...(e.family === "pg" ? await this.#drivers.pg.schema(e.ep, timeoutMs) : await this.#drivers.mysql.schema(e.ep, timeoutMs)) };
    });
  }

  async preview(id: string, schema: string, table: string, limit: number, timeoutMs: number): Promise<RowsResult> {
    const c = this.get(id);
    return this.#exclusive(id, async () => {
      if (c.engine === "sqlite") {
        if (schema !== "main") throw new AppError("agent.db.tableNotFound", 404, {});
        return sqlitePreview(await this.#sqlitePath(c), table, limit, timeoutMs);
      }
      const e = await this.#endpoint(c);
      return e.family === "pg" ? this.#drivers.pg.preview(e.ep, schema, table, limit, timeoutMs) : this.#drivers.mysql.preview(e.ep, schema, table, limit, timeoutMs);
    });
  }

  #checkRead(c: DbConnection, sql: string) {
    const check = checkReadStatement(sql, c.engine);
    if (!check.ok) {
      const { ok: _ok, code, ...params } = check;
      throw new AppError(code, 400, params);
    }
  }

  async query(id: string, sql: string, params: Param[], limit: number, timeoutMs: number): Promise<RowsResult> {
    const c = this.get(id);
    this.#checkRead(c, sql);
    return this.#exclusive(id, async () => {
      if (c.engine === "sqlite") return sqliteQuery(await this.#sqlitePath(c), sql, params, limit, timeoutMs);
      const e = await this.#endpoint(c);
      return e.family === "pg" ? this.#drivers.pg.query(e.ep, sql, params, limit, timeoutMs) : this.#drivers.mysql.query(e.ep, sql, params, limit, timeoutMs);
    });
  }

  /** CSV export source: the read-only path, streamed to the sink. The caller applies the row/byte caps. */
  async export(id: string, sql: string, params: Param[], timeoutMs: number, sink: RowSink): Promise<void> {
    const c = this.get(id);
    this.#checkRead(c, sql);
    return this.#exclusive(id, async () => {
      if (c.engine === "sqlite") return sqliteStream(await this.#sqlitePath(c), sql, params, timeoutMs, sink);
      const e = await this.#endpoint(c);
      return e.family === "pg" ? this.#drivers.pg.stream(e.ep, sql, params, timeoutMs, sink) : this.#drivers.mysql.stream(e.ep, sql, params, timeoutMs, sink);
    });
  }

  // --- Saved queries (D-2) ------------------------------------------------------------------------------------------

  /** A saved query must name an existing connection and pass the read allowlist of its engine. */
  validateSaved(connectionId: string, sql: string) {
    this.#checkRead(this.get(connectionId), sql);
  }

  async runSaved(qid: string, o: { params?: Param[]; limit: number; timeoutMs: number }) {
    const q = await this.queries.get(qid);
    const res = await this.query(q.connectionId, q.sql, o.params ?? q.params, o.limit, o.timeoutMs);
    const kinds = columnKinds(res.columns, res.rows);
    return { query: { id: q.id, name: q.name, chart: q.chart }, conn: q.connectionId, ...res, columns: res.columns.map((col, i) => ({ ...col, kind: kinds[i]! })) };
  }

  // --- Write mode (D-3) ---------------------------------------------------------------------------------------------

  #checkWrite(c: DbConnection, sql: string) {
    if (c.engine === "sqlite") throw new AppError("agent.db.writeUnsupported", 400, { engine: c.engine });
    const check = checkWriteStatement(sql, c.engine);
    if (!check.ok) {
      const { ok: _ok, code, ...params } = check;
      throw new AppError(code, 400, params);
    }
    return { check: { kind: check.kind, verb: check.verb, returning: check.returning }, stmt: statements(sql, c.engine)[0]! };
  }

  async #runWrite(c: DbConnection, p: Pick<PendingWrite, "stmt" | "check" | "timeoutMs">, sample: boolean, decide: (count: number | null) => Promise<boolean>): Promise<WriteOutcome> {
    return this.#exclusive(c.id, async () => {
      const e = await this.#endpoint(c, "write");
      return e.family === "pg" ? this.#drivers.pg.write(e.ep, p.stmt, p.check, p.timeoutMs, { sample, decide }) : this.#drivers.mysql.write(e.ep, p.stmt, p.timeoutMs, { decide });
    });
  }

  /**
   * Runs the statement with the write credential (the read credential when there is none) in a transaction that is
   * always rolled back, and returns the affected row count, sample rows (PostgreSQL DML) and a preview token bound to
   * (device, connection, SQL hash, count).
   */
  async writePreview(device: string, id: string, sql: string, timeoutMs: number) {
    const c = this.get(id);
    const { check, stmt } = this.#checkWrite(c, sql);
    const out = await this.#runWrite(c, { stmt, check, timeoutMs }, true, async () => false);
    const warnings: string[] = [];
    if (!c.writeCredential) warnings.push("readCredentialUsed");
    const cred = c.writeCredential ?? c.readCredential;
    if (out.superuser || (cred && "fromContainerEnv" in cred)) warnings.push("superuserCredential");
    const now = this.#now();
    for (const [t, p] of this.#pending) if (p.expiresAt <= now) this.#pending.delete(t);
    const token = this.#previews.issue(device, WRITE_KIND, { conn: id, sqlSha256: sqlSha256(sql), count: out.count });
    this.#pending.set(token.previewToken, { conn: id, sql, stmt, check, count: out.count, timeoutMs, expiresAt: Date.parse(token.expiresAt) });
    return {
      conn: id,
      kind: check.kind,
      statement: check.verb,
      count: out.count,
      ...(out.sample ? { sample: out.sample } : {}),
      credential: c.writeCredential ? ("write" as const) : ("read" as const),
      warnings,
      ...token,
    };
  }

  /**
   * Re-runs the previewed statement; COMMIT only if the count is the previewed one (else ROLLBACK + 409
   * agent.db.countChanged). The rate limit is checked before the token is spent. Every attempt that ran is logged in
   * db-writes.jsonl before COMMIT (a log failure rolls back).
   */
  async writeCommit(device: string, id: string, previewToken: string, onRun?: (sqlSha: string, rows: number | null) => void) {
    const c = this.get(id);
    this.checkWriteRate(device);
    const p = this.#pending.get(previewToken);
    this.#pending.delete(previewToken);
    this.#previews.consume(previewToken, device, WRITE_KIND, p ? { conn: id, sqlSha256: sqlSha256(p.sql), count: p.count } : { conn: id, invalid: true });
    const pw = p!;
    onRun?.(sqlSha256(pw.sql), null);
    const entry = (count: number | null) => ({ at: new Date(this.#now()).toISOString(), device, conn: id, engine: c.engine, sql: pw.sql, sqlSha256: sqlSha256(pw.sql), count });
    let ran: number | null | undefined;
    let logged = false;
    try {
      const out = await this.#runWrite(c, pw, false, async (count) => {
        ran = count;
        onRun?.(sqlSha256(pw.sql), count);
        if (count !== pw.count) {
          await this.writes.append({ ...entry(count), outcome: "countChanged", expected: pw.count });
          throw new AppError("agent.db.countChanged", 409, { expected: pw.count, actual: count });
        }
        await this.writes.append({ ...entry(count), outcome: "committed" });
        logged = true;
        return true;
      });
      return { conn: id, committed: out.committed, count: out.count };
    } catch (e) {
      // Logged as committed, then COMMIT (or the connection) failed: record that too.
      if (logged) await this.writes.append({ ...entry(ran ?? null), outcome: "commitFailed" }).catch(() => {});
      throw e;
    }
  }

  /**
   * SQL for a dedicated read-only account, with a fresh random password, for the user to review. PostgreSQL (14+):
   * one CREATE ROLE … IN ROLE pg_read_all_data statement, runnable through the write mode. MySQL/MariaDB: CREATE USER +
   * GRANT SELECT, SHOW VIEW (on the connection's database, else all); account statements commit implicitly and can't be
   * previewed, so they are for the mysql client.
   */
  readonlyRoleSql(id: string, role: string) {
    const c = this.get(id);
    if (c.engine === "sqlite") throw new AppError("agent.db.writeUnsupported", 400, { engine: c.engine });
    const password = randomBytes(18).toString("base64url");
    if (c.engine === "postgres") {
      return {
        conn: id,
        engine: c.engine,
        role,
        password,
        statements: [`CREATE ROLE ${quoteIdent(role)} LOGIN PASSWORD '${password}' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5 IN ROLE pg_read_all_data`],
        runVia: "writeMode" as const,
        requires: "PostgreSQL 14+",
      };
    }
    const scope = c.database ? `${quoteIdent(c.database, "mysql")}.*` : "*.*";
    return {
      conn: id,
      engine: c.engine,
      role,
      password,
      statements: [`CREATE USER '${role}'@'%' IDENTIFIED BY '${password}' WITH MAX_USER_CONNECTIONS 5`, `GRANT SELECT, SHOW VIEW ON ${scope} TO '${role}'@'%'`],
      runVia: "client" as const,
      requires: null,
    };
  }
}
