// PostgreSQL driver of the database console (PLAN.md §13.2, D-1 reads, D-2 export, D-3 write mode). Read layers: the session starts with
// default_transaction_read_only=on, every request runs in BEGIN READ ONLY with SET LOCAL statement_timeout
// (set_config(…, true)), user SQL goes through pg-cursor (extended protocol: Parse/Bind/Execute, so the server refuses
// more than one statement), rows are fetched in batches up to the limit, and the transaction always ends in ROLLBACK.
// One connection per request (no pool). pg/pg-cursor are imported on first use. Write mode (pgWrite): a read-write
// transaction with statement and lock timeouts; the statement runs once, its row count (and for DML up to 20 rows
// through RETURNING *) is taken, and the transaction rolls back (preview) or commits only if the caller agrees.
import type { Client as PgClient, ClientConfig, FieldDef } from "pg";
import type CursorT from "pg-cursor";
import { AppError } from "../errors.ts";
import { redact } from "../redact.ts";
import { buildSchema, LIMITS, quoteIdent, RowCollector, SCHEMA_CAPS, type RowSink, type RowsResult, type SchemaResult, type SchemaTable, type WriteOutcome } from "./sql.ts";

export interface PgEndpoint {
  host: string;
  port: number;
  user: string;
  password?: string;
  database: string;
}

const CONNECT_TIMEOUT_MS = 10_000;
/** Past the statement timeout, the socket is dropped if the server still hasn't answered. */
const BACKSTOP_MS = 5_000;
const BATCH = 500;

let mods: Promise<{ Client: typeof PgClient; Cursor: typeof CursorT; getTypeParser: (oid: number, format?: string) => (v: string) => unknown }> | undefined;
function load() {
  return (mods ??= (async () => {
    const pg = (await import("pg")).default;
    const Cursor = (await import("pg-cursor")).default;
    return { Client: pg.Client, Cursor, getTypeParser: pg.types.getTypeParser as never };
  })());
}

/** Date/time types stay as the server's text (no time zone conversion); the rest uses pg's parsers. */
const RAW_TEXT = new Set([1082, 1083, 1114, 1184, 1266, 1186]);

const TYPE_NAMES: Record<number, string> = {
  16: "bool", 17: "bytea", 18: "char", 19: "name", 20: "int8", 21: "int2", 23: "int4", 25: "text", 26: "oid", 114: "json",
  142: "xml", 650: "cidr", 700: "float4", 701: "float8", 790: "money", 829: "macaddr", 869: "inet", 1042: "bpchar",
  1043: "varchar", 1082: "date", 1083: "time", 1114: "timestamp", 1184: "timestamptz", 1186: "interval", 1266: "timetz",
  1560: "bit", 1562: "varbit", 1700: "numeric", 2950: "uuid", 3802: "jsonb", 3614: "tsvector",
  1000: "bool[]", 1005: "int2[]", 1007: "int4[]", 1016: "int8[]", 1009: "text[]", 1015: "varchar[]", 2951: "uuid[]",
};
const typeName = (f: FieldDef) => TYPE_NAMES[f.dataTypeID] ?? `oid:${f.dataTypeID}`;

/** Maps a pg/network error to agent.db.*; driver text goes through redact. */
export function pgError(e: unknown): AppError {
  if (e instanceof AppError) return e;
  const err = e as { code?: string; message?: string; position?: string };
  const message = redact(String(err.message ?? "")).slice(0, 500);
  const code = err.code ?? "";
  if (code === "57014") return new AppError("agent.db.timeout", 504, {});
  if (code === "25006") return new AppError("agent.db.readOnly", 409, { message });
  if (code === "28P01" || code === "28000") return new AppError("agent.db.authFailed", 401, { sqlState: code });
  if (code === "3D000") return new AppError("agent.db.databaseNotFound", 404, { sqlState: code });
  if (code === "42601" && /multiple commands/i.test(message)) return new AppError("agent.db.multipleStatements", 400, {});
  if (code === "42501") return new AppError("agent.db.permissionDenied", 403, { message });
  if (/^[0-9A-Z]{5}$/.test(code)) {
    return new AppError("agent.db.queryFailed", 400, { sqlState: code, message, ...(err.position ? { position: Number(err.position) } : {}) });
  }
  if (["ECONNREFUSED", "ETIMEDOUT", "EHOSTUNREACH", "ENETUNREACH", "ENOTFOUND", "EAI_AGAIN", "ECONNRESET"].includes(code) || /timeout expired|Connection terminated/i.test(message)) {
    return new AppError("agent.db.unreachable", 502, { reason: code || "timeout" });
  }
  return new AppError("agent.db.failed", 502, { message });
}

interface SessionOpts {
  timeoutMs: number;
  /** Read-only session and transaction (default) or the write mode's read-write transaction. */
  write?: boolean;
  /** Wall clock past which the socket is dropped (default: connect + statement timeout + 5 s). */
  backstopMs?: number;
}

/**
 * Connects, opens a transaction (read-only unless `write`) with the statement timeout, runs fn, and rolls back and
 * closes. When fn calls `tx.commit()`, the transaction ends with COMMIT instead (a failing COMMIT throws).
 * standard_conforming_strings is pinned on, so the agent's lexer reads '…' strings the way the server does.
 */
export async function withSession<T>(ep: PgEndpoint, o: SessionOpts, fn: (c: PgClient, m: Awaited<ReturnType<typeof load>>, tx: { commit(): void }) => Promise<T>): Promise<T> {
  const m = await load();
  const timeoutMs = o.timeoutMs;
  const session = o.write
    ? `-c lock_timeout=${timeoutMs}`
    : "-c default_transaction_read_only=on";
  const config: ClientConfig = {
    host: ep.host,
    port: ep.port,
    user: ep.user,
    database: ep.database,
    ...(ep.password !== undefined ? { password: ep.password } : {}),
    application_name: "tiphys",
    connectionTimeoutMillis: CONNECT_TIMEOUT_MS,
    ssl: false,
    // Session defaults: read-only transactions (reads), the request's statement timeout, no lingering idle transaction.
    options: `${session} -c standard_conforming_strings=on -c statement_timeout=${timeoutMs} -c idle_in_transaction_session_timeout=${timeoutMs + 60_000}`,
    types: { getTypeParser: ((oid: number, format?: string) => (RAW_TEXT.has(oid) && format !== "binary" ? (v: string) => v : m.getTypeParser(oid, format))) as never },
  };
  const client = new m.Client(config);
  // A late socket error must not crash the agent; the pending call rejects on its own.
  client.on("error", () => {});
  let timer: NodeJS.Timeout | undefined;
  const backstop = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      (client as unknown as { connection?: { stream?: { destroy(): void } } }).connection?.stream?.destroy();
      reject(new AppError("agent.db.timeout", 504, {}));
    }, o.backstopMs ?? CONNECT_TIMEOUT_MS + timeoutMs + BACKSTOP_MS);
  });
  const work = (async () => {
    try {
      await client.connect();
    } catch (e) {
      throw pgError(e);
    }
    let commit = false;
    let ended = false;
    try {
      await client.query(o.write ? "BEGIN READ WRITE" : "BEGIN READ ONLY");
      await client.query({ text: "SELECT set_config('statement_timeout', $1, true)", values: [String(timeoutMs)], queryMode: "extended" } as never);
      const out = await fn(client, m, { commit: () => (commit = true) });
      if (commit) {
        ended = true;
        await client.query("COMMIT");
      }
      return out;
    } catch (e) {
      throw pgError(e);
    } finally {
      if (!ended) await client.query("ROLLBACK").catch(() => {});
    }
  })();
  try {
    return await Promise.race([work, backstop]);
  } finally {
    clearTimeout(timer);
    work.catch(() => {});
    await Promise.race([client.end().catch(() => {}), new Promise((r) => setTimeout(r, 2000))]);
  }
}

/** Connects, opens a read-only transaction with the statement timeout, runs fn, and always rolls back and closes. */
export function withReadOnly<T>(ep: PgEndpoint, timeoutMs: number, fn: (c: PgClient, m: Awaited<ReturnType<typeof load>>) => Promise<T>): Promise<T> {
  return withSession(ep, { timeoutMs }, (c, m) => fn(c, m));
}

/** Runs one statement through a cursor; at most `limit` rows (truncated when there were more). */
async function cursorRows(client: PgClient, Cursor: typeof CursorT, sql: string, params: unknown[], limit: number): Promise<RowsResult> {
  const cursor = client.query(new Cursor(sql, params, { rowMode: "array" }));
  const out = new RowCollector(limit);
  let fields: FieldDef[] | undefined;
  try {
    for (;;) {
      const want = Math.min(BATCH, limit + 1 - out.rows.length);
      const rows = await new Promise<unknown[][]>((resolve, reject) =>
        cursor.read(Math.max(1, want), (err, r, result) => {
          if (result?.fields) fields ??= result.fields;
          if (err) reject(err);
          else resolve(r);
        }),
      );
      let full = false;
      for (const r of rows) if (!out.add(r)) full = true;
      if (full || rows.length < want) break;
    }
  } finally {
    await cursor.close().catch(() => {});
  }
  fields ??= cursor._result?.fields ?? [];
  return {
    columns: fields.map((f) => ({ name: f.name, type: typeName(f) })),
    rows: out.rows,
    rowCount: out.rows.length,
    truncated: out.truncated,
    cellsTruncated: out.cellsTruncated,
  };
}

export async function pgQuery(ep: PgEndpoint, sql: string, params: unknown[], limit: number, timeoutMs: number): Promise<RowsResult> {
  return withReadOnly(ep, timeoutMs, (c, m) => cursorRows(c, m.Cursor, sql, params, limit));
}

const RELKINDS: Record<string, SchemaTable["kind"]> = { r: "table", p: "partitionedTable", v: "view", m: "materializedView", f: "foreignTable" };
const USER_SCHEMAS = `n.nspname NOT IN ('pg_catalog', 'information_schema') AND n.nspname NOT LIKE 'pg\\_toast%' AND n.nspname NOT LIKE 'pg\\_temp\\_%'`;

/** The table must exist in the catalog (relation kinds above); returns its schema and name as the catalog has them. */
export async function pgPreview(ep: PgEndpoint, schema: string, table: string, limit: number, timeoutMs: number): Promise<RowsResult> {
  return withReadOnly(ep, timeoutMs, async (c, m) => {
    const found = await c.query({
      text: `SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r','p','v','m','f')`,
      values: [schema, table],
      queryMode: "extended",
    } as never);
    const row = (found as unknown as { rows: Array<{ nspname: string; relname: string }> }).rows[0];
    if (!row) throw new AppError("agent.db.tableNotFound", 404, {});
    return cursorRows(c, m.Cursor, `SELECT * FROM ${quoteIdent(row.nspname)}.${quoteIdent(row.relname)} LIMIT $1`, [limit + 1], limit);
  });
}

export async function pgSchema(ep: PgEndpoint, timeoutMs: number): Promise<SchemaResult> {
  return withReadOnly(ep, timeoutMs, async (c) => {
    const q = async <R>(text: string, values: unknown[] = []) =>
      ((await c.query({ text, values, queryMode: "extended" } as never)) as unknown as { rows: R[] }).rows;
    const tables = await q<{ s: string; t: string; k: string; est: string | null }>(
      `SELECT n.nspname AS s, c.relname AS t, c.relkind AS k, CASE WHEN c.reltuples < 0 THEN NULL ELSE c.reltuples::bigint END AS est
       FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE c.relkind IN ('r','p','v','m','f') AND ${USER_SCHEMAS} AND NOT c.relispartition
       ORDER BY 1, 2 LIMIT $1`,
      [SCHEMA_CAPS.tables + 1],
    );
    const columns = await q<{ s: string; t: string; name: string; type: string; notnull: boolean; def: string | null; pk: boolean }>(
      `SELECT n.nspname AS s, c.relname AS t, a.attname AS name, format_type(a.atttypid, a.atttypmod) AS type, a.attnotnull AS notnull,
              pg_get_expr(d.adbin, d.adrelid) AS def,
              EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = c.oid AND i.indisprimary AND a.attnum = ANY (i.indkey)) AS pk
       FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid JOIN pg_namespace n ON n.oid = c.relnamespace
       LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
       WHERE a.attnum > 0 AND NOT a.attisdropped AND c.relkind IN ('r','p','v','m','f') AND ${USER_SCHEMAS} AND NOT c.relispartition
       ORDER BY 1, 2, a.attnum LIMIT $1`,
      [SCHEMA_CAPS.columns + 1],
    );
    const indexes = await q<{ s: string; t: string; name: string; uniq: boolean; prim: boolean; def: string }>(
      `SELECT n.nspname AS s, t.relname AS t, i.relname AS name, x.indisunique AS uniq, x.indisprimary AS prim, pg_get_indexdef(x.indexrelid) AS def
       FROM pg_index x JOIN pg_class i ON i.oid = x.indexrelid JOIN pg_class t ON t.oid = x.indrelid JOIN pg_namespace n ON n.oid = t.relnamespace
       WHERE ${USER_SCHEMAS} ORDER BY 1, 2, 3 LIMIT $1`,
      [SCHEMA_CAPS.indexes + 1],
    );
    const truncated = tables.length > SCHEMA_CAPS.tables || columns.length > SCHEMA_CAPS.columns || indexes.length > SCHEMA_CAPS.indexes;
    return buildSchema(
      tables.slice(0, SCHEMA_CAPS.tables).map((r) => ({ schema: r.s, table: r.t, kind: RELKINDS[r.k] ?? "table", estimatedRows: r.est === null ? null : Number(r.est) })),
      columns.slice(0, SCHEMA_CAPS.columns).map((r) => ({ schema: r.s, table: r.t, name: r.name, type: r.type, nullable: !r.notnull, default: r.def, primaryKey: r.pk })),
      indexes.slice(0, SCHEMA_CAPS.indexes).map((r) => ({ schema: r.s, table: r.t, name: r.name, unique: r.uniq, primary: r.prim, definition: r.def })),
      truncated,
    );
  });
}

export interface PgTestResult {
  serverVersion: string;
  user: string;
  database: string;
  superuser: boolean;
  readOnlyDefault: boolean;
}

export async function pgTest(ep: PgEndpoint, timeoutMs: number): Promise<PgTestResult> {
  return withReadOnly(ep, timeoutMs, async (c) => {
    const r = (await c.query({
      text: `SELECT current_setting('server_version') AS v, current_user AS u, current_database() AS d,
                    COALESCE((SELECT rolsuper FROM pg_roles WHERE rolname = current_user), false) AS su,
                    current_setting('default_transaction_read_only') AS ro`,
      queryMode: "extended",
    } as never)) as unknown as { rows: Array<{ v: string; u: string; d: string; su: boolean; ro: string }> };
    const row = r.rows[0]!;
    return { serverVersion: row.v, user: row.u, database: row.d, superuser: row.su, readOnlyDefault: row.ro === "on" };
  });
}

/** CSV export: streams every row of one statement to the sink (read-only, the export's wall clock as backstop). */
export async function pgStream(ep: PgEndpoint, sql: string, params: unknown[], timeoutMs: number, sink: RowSink): Promise<void> {
  await withSession(ep, { timeoutMs, backstopMs: LIMITS.exportWallMs }, async (client, m) => {
    const cursor = client.query(new m.Cursor(sql, params, { rowMode: "array" }));
    let started = false;
    try {
      for (;;) {
        const rows = await new Promise<{ rows: unknown[][]; fields?: FieldDef[] }>((resolve, reject) =>
          cursor.read(BATCH, (err, r, result) => (err ? reject(err) : resolve({ rows: r, fields: result?.fields }))),
        );
        if (!started) {
          started = true;
          const fields = rows.fields ?? cursor._result?.fields ?? [];
          sink.columns(fields.map((f) => ({ name: f.name, type: typeName(f) })));
        }
        for (const r of rows.rows) if (!(await sink.row(r))) return;
        if (rows.rows.length < BATCH) return;
      }
    } finally {
      await cursor.close().catch(() => {});
    }
  });
}

/** SQL states where `… RETURNING *` inside a CTE can't work for this statement: syntax/semantics (42…), unsupported (0A…). */
const NO_SAMPLE = /^(42|0A)/;

/**
 * Write mode: runs one checked statement in a read-write transaction. With `sample` (preview of INSERT/UPDATE/DELETE)
 * it runs as `WITH tiphys_w AS (<stmt> RETURNING *) SELECT count(*) OVER (), * FROM tiphys_w LIMIT 20` inside a
 * savepoint, falling back to the plain statement when that form is refused. `decide(count)` says whether to COMMIT;
 * otherwise (and on any error) the transaction rolls back. DDL runs inside the transaction too (count null).
 */
export async function pgWrite(
  ep: PgEndpoint,
  stmt: string,
  w: { kind: "dml" | "ddl"; verb: string; returning: boolean },
  timeoutMs: number,
  o: { sample: boolean; decide(count: number | null): Promise<boolean> },
): Promise<WriteOutcome> {
  return withSession(ep, { timeoutMs, write: true }, async (c, _m, tx) => {
    const su = (await c.query({ text: "SELECT COALESCE((SELECT rolsuper FROM pg_roles WHERE rolname = current_user), false) AS su", queryMode: "extended" } as never)) as unknown as { rows: Array<{ su: boolean }> };
    let count: number | null = null;
    let sample: WriteOutcome["sample"];
    let done = false;
    if (o.sample && w.kind === "dml" && w.verb !== "merge") {
      await c.query("SAVEPOINT tiphys_sample");
      try {
        const r = (await c.query({
          text: `WITH tiphys_w AS (\n${stmt}\n${w.returning ? "" : "RETURNING *"}\n) SELECT count(*) OVER (), * FROM tiphys_w LIMIT ${LIMITS.writeSampleRows}`,
          rowMode: "array",
          queryMode: "extended",
        } as never)) as unknown as { rows: unknown[][]; fields: FieldDef[] };
        count = r.rows.length ? Number(r.rows[0]![0]) : 0;
        const out = new RowCollector(LIMITS.writeSampleRows);
        for (const row of r.rows) out.add(row.slice(1));
        sample = { columns: r.fields.slice(1).map((f) => ({ name: f.name, type: typeName(f) })), rows: out.rows, cellsTruncated: out.cellsTruncated };
        done = true;
      } catch (e) {
        if (!NO_SAMPLE.test(String((e as { code?: string }).code ?? ""))) throw e;
        await c.query("ROLLBACK TO SAVEPOINT tiphys_sample");
      }
    }
    if (!done) {
      const r = (await c.query({ text: stmt, queryMode: "extended" } as never)) as unknown as { rowCount: number | null };
      count = typeof r.rowCount === "number" && w.kind === "dml" ? r.rowCount : w.kind === "dml" ? 0 : null;
    }
    const commit = await o.decide(count);
    if (commit) tx.commit();
    return { count, ...(sample ? { sample } : {}), superuser: su.rows[0]?.su === true, committed: commit };
  });
}
