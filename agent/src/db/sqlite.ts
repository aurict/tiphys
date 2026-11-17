// SQLite driver of the database console (PLAN.md §13.2, D-1). node:sqlite is synchronous: a slow query would block the
// agent's event loop and can't be interrupted, so each request runs in a child Node process (CHILD below, plain JS so
// it runs from the sources and from dist alike) that the parent kills at the timeout. The child opens the file
// read-only, sets query_only, keeps extension loading off and installs an authorizer that refuses ATTACH/DETACH and
// non-catalog pragmas; it pre-cuts long text and turns blobs into "<n bayt>", and the parent applies the exact caps.
// Needs node:sqlite (Node ≥ 22.13 unflagged); without it every call fails with agent.db.sqliteUnavailable.
import { spawn } from "node:child_process";
import { stat } from "node:fs/promises";
import { AppError } from "../errors.ts";
import { redact } from "../redact.ts";
import { buildSchema, LIMITS, quoteIdent, RowCollector, SCHEMA_CAPS, type RowSink, type RowsResult, type SchemaResult } from "./sql.ts";

type Param = string | number | boolean | null;

interface ChildRequest {
  path: string;
  queries: Array<{ sql: string; params: Param[]; limit: number }>;
  cellChars: number;
  resultChars: number;
}

interface ChildResult {
  columns: Array<{ name: string; type: string | null }>;
  rows: unknown[][];
  truncated: boolean;
}

type ChildResponse = { ok: true; results: ChildResult[] } | { ok: false; error: { message: string; errcode?: number } };

let available: Promise<boolean> | undefined;
/** node:sqlite loads without flags (Node ≥ 22.13; checked once). */
export function sqliteAvailable(): Promise<boolean> {
  return (available ??= import("node:sqlite").then(
    (m) => typeof (m as { DatabaseSync?: unknown }).DatabaseSync === "function",
    () => false,
  ));
}

// Authorizer codes (sqlite3.h): OK 0, DENY 1, PRAGMA 19, ATTACH 24, DETACH 25.
const CHILD = String.raw`
import { DatabaseSync } from "node:sqlite";
const READ_PRAGMAS = new Set(["table_info", "table_xinfo", "index_list", "index_info", "index_xinfo", "foreign_key_list"]);
function run(req) {
  const db = new DatabaseSync(req.path, { readOnly: true });
  try {
    db.exec("PRAGMA query_only = ON");
    if (typeof db.setAuthorizer === "function") {
      db.setAuthorizer((action, a) => {
        if (action === 24 || action === 25) return 1;
        if (action === 19) return READ_PRAGMAS.has(String(a).toLowerCase()) ? 0 : 1;
        return 0;
      });
    }
    return req.queries.map((q) => {
      const stmt = db.prepare(q.sql);
      if (stmt.setReadBigInts) stmt.setReadBigInts(true);
      const arrays = typeof stmt.setReturnArrays === "function";
      if (arrays) stmt.setReturnArrays(true);
      let columns = stmt.columns ? stmt.columns().map((c) => ({ name: c.name, type: c.type ?? null })) : null;
      const rows = [];
      let chars = 0;
      let truncated = false;
      for (const row of stmt.iterate(...q.params)) {
        if (rows.length > q.limit || chars > req.resultChars) { truncated = true; break; }
        if (!columns) columns = Object.keys(row).map((name) => ({ name, type: null }));
        const values = (arrays ? row : Object.values(row)).map((v) => {
          if (v instanceof Uint8Array) { chars += 16; return "<" + v.byteLength + " bayt>"; }
          if (typeof v === "string") { const s = v.length > req.cellChars ? v.slice(0, req.cellChars + 1) : v; chars += s.length; return s; }
          chars += 16;
          return v;
        });
        rows.push(values);
      }
      return { columns: columns ?? [], rows, truncated };
    });
  } finally {
    db.close();
  }
}
process.once("message", (req) => {
  let res;
  try { res = { ok: true, results: run(req) }; }
  catch (e) { res = { ok: false, error: { message: String(e && e.message || e), ...(typeof (e && e.errcode) === "number" ? { errcode: e.errcode } : {}) } }; }
  process.send(res, undefined, undefined, () => process.disconnect());
});
`;

const SPAWN_GRACE_MS = 3_000;

/** Maps a SQLite error (child) to agent.db.*; the message goes through redact. */
export function sqliteError(e: { message: string; errcode?: number }): AppError {
  const message = redact(e.message).slice(0, 500);
  const primary = (e.errcode ?? 0) & 0xff;
  if (primary === 8 || /readonly database|query_only/i.test(message)) return new AppError("agent.db.readOnly", 409, { message });
  if (primary === 23 || /not authorized/i.test(message)) return new AppError("agent.db.permissionDenied", 403, { message });
  if (primary === 14 || /unable to open database/i.test(message)) return new AppError("agent.db.unreachable", 502, { reason: "open" });
  return new AppError("agent.db.queryFailed", 400, { message, ...(e.errcode !== undefined ? { sqliteCode: e.errcode } : {}) });
}

export async function runChild(path: string, queries: ChildRequest["queries"], timeoutMs: number, caps: { cellBytes: number; resultBytes: number } = { cellBytes: LIMITS.cellBytes, resultBytes: LIMITS.resultBytes }): Promise<RowsResult[]> {
  if (!(await sqliteAvailable())) throw new AppError("agent.db.sqliteUnavailable", 501, { node: process.versions.node });
  const st = await stat(path).catch(() => null);
  if (!st?.isFile()) throw new AppError("agent.db.fileNotFound", 404, {});
  const req: ChildRequest = { path, queries, cellChars: caps.cellBytes, resultChars: caps.resultBytes };
  const results = await new Promise<ChildResult[]>((resolve, reject) => {
    const child = spawn(process.execPath, ["--no-warnings", "--max-old-space-size=256", "--input-type=module", "-e", CHILD], {
      stdio: ["ignore", "ignore", "ignore", "ipc"],
      serialization: "advanced",
      env: { PATH: process.env.PATH ?? "/usr/bin:/bin", LC_ALL: "C.UTF-8" },
    });
    let done = false;
    const finish = (fn: () => void) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      if (child.exitCode === null) child.kill("SIGKILL");
      fn();
    };
    const timer = setTimeout(() => finish(() => reject(new AppError("agent.db.timeout", 504, {}))), timeoutMs + SPAWN_GRACE_MS);
    child.once("message", (m) => {
      const res = m as ChildResponse;
      finish(() => (res.ok ? resolve(res.results) : reject(sqliteError(res.error))));
    });
    child.once("error", () => finish(() => reject(new AppError("agent.db.failed", 502, { reason: "child" }))));
    child.once("exit", (code, signal) => finish(() => reject(new AppError("agent.db.failed", 502, { reason: "childExit", code, signal }))));
    child.send(req);
  });
  return results.map((r, i) => {
    const out = new RowCollector(queries[i]!.limit, caps);
    for (const row of r.rows) if (!out.add(row)) break;
    return { columns: r.columns, rows: out.rows, rowCount: out.rows.length, truncated: out.truncated || r.truncated, cellsTruncated: out.cellsTruncated };
  });
}

export async function sqliteQuery(path: string, sql: string, params: Param[], limit: number, timeoutMs: number): Promise<RowsResult> {
  return (await runChild(path, [{ sql, params, limit }], timeoutMs))[0]!;
}

/**
 * CSV export: node:sqlite has no cursor across processes, so the child collects up to the export caps (rows, bytes)
 * and the rows are then handed to the sink; the response itself still streams.
 */
export async function sqliteStream(path: string, sql: string, params: Param[], timeoutMs: number, sink: RowSink): Promise<void> {
  const [r] = await runChild(path, [{ sql, params, limit: LIMITS.exportRows }], timeoutMs, { cellBytes: LIMITS.exportBytes, resultBytes: LIMITS.exportBytes });
  sink.columns(r!.columns);
  for (const row of r!.rows) if (!(await sink.row(row))) return;
}

const TABLES = `SELECT name, type FROM sqlite_master WHERE type IN ('table', 'view') AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY name LIMIT ?`;

export async function sqlitePreview(path: string, table: string, limit: number, timeoutMs: number): Promise<RowsResult> {
  const [found] = await runChild(path, [{ sql: `SELECT name FROM sqlite_master WHERE type IN ('table', 'view') AND name = ?`, params: [table], limit: 1 }], timeoutMs);
  const name = found?.rows[0]?.[0];
  if (typeof name !== "string") throw new AppError("agent.db.tableNotFound", 404, {});
  return sqliteQuery(path, `SELECT * FROM main.${quoteIdent(name)} LIMIT ?`, [limit + 1], limit, timeoutMs);
}

export async function sqliteSchema(path: string, timeoutMs: number): Promise<SchemaResult> {
  const [tables, columns, indexes] = await runChild(
    path,
    [
        { sql: TABLES, params: [SCHEMA_CAPS.tables + 1], limit: SCHEMA_CAPS.tables + 1 },
        {
          sql: `SELECT m.name, p.name, p.type, p."notnull", p.dflt_value, p.pk FROM sqlite_master m JOIN pragma_table_info(m.name) p
                WHERE m.type IN ('table', 'view') AND m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY m.name, p.cid LIMIT ?`,
          params: [SCHEMA_CAPS.columns + 1],
          limit: SCHEMA_CAPS.columns + 1,
        },
        {
          sql: `SELECT m.name, il.name, il."unique", il.origin, s.sql FROM sqlite_master m JOIN pragma_index_list(m.name) il
                LEFT JOIN sqlite_master s ON s.type = 'index' AND s.name = il.name
                WHERE m.type = 'table' AND m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\' ORDER BY m.name, il.name LIMIT ?`,
          params: [SCHEMA_CAPS.indexes + 1],
          limit: SCHEMA_CAPS.indexes + 1,
        },
    ],
    timeoutMs,
  );
  const str = (v: unknown) => (v === null || v === undefined ? null : String(v));
  const truncated = tables!.rows.length > SCHEMA_CAPS.tables || columns!.rows.length > SCHEMA_CAPS.columns || indexes!.rows.length > SCHEMA_CAPS.indexes;
  return buildSchema(
    tables!.rows.slice(0, SCHEMA_CAPS.tables).map((r) => ({ schema: "main", table: String(r[0]), kind: r[1] === "view" ? ("view" as const) : ("table" as const), estimatedRows: null })),
    columns!.rows
      .slice(0, SCHEMA_CAPS.columns)
      .map((r) => ({ schema: "main", table: String(r[0]), name: String(r[1]), type: String(r[2] ?? ""), nullable: !r[3], default: str(r[4]), primaryKey: Number(r[5]) > 0 })),
    indexes!.rows
      .slice(0, SCHEMA_CAPS.indexes)
      .map((r) => ({ schema: "main", table: String(r[0]), name: String(r[1]), unique: !!r[2], primary: r[3] === "pk", definition: str(r[4]) })),
    truncated,
  );
}

export async function sqliteTest(path: string, timeoutMs: number): Promise<{ serverVersion: string }> {
  const [r] = await runChild(path, [{ sql: "SELECT sqlite_version()", params: [], limit: 1 }], timeoutMs);
  return { serverVersion: String(r?.rows[0]?.[0] ?? "") };
}
