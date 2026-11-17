// MySQL/MariaDB driver of the database console (PLAN.md §13.2, D-2 reads/export, D-3 write mode), through mysql2
// (imported on first use). One connection per request, no pool. Connection: multipleStatements off and the
// MULTI_STATEMENTS and LOCAL_FILES client flags removed (no LOAD DATA LOCAL), no infile stream factory, no generated
// parser code (disableEval). Session: sql_mode without NO_BACKSLASH_ESCAPES/ANSI_QUOTES/ANSI (so the agent's lexer reads
// strings as the server does), statement timeout (MariaDB max_statement_time, all statements; MySQL MAX_EXECUTION_TIME,
// SELECT only), and for reads SET SESSION TRANSACTION READ ONLY + START TRANSACTION READ ONLY, always rolled back. User
// SQL goes through server-side prepared statements (one statement only; real parameters). Past the timeout the
// socket is dropped and the statement is killed (KILL QUERY on a second connection), which rolls the transaction back.
import { AppError } from "../errors.ts";
import { redact } from "../redact.ts";
import { buildSchema, LIMITS, MYSQL_SYSTEM_SCHEMAS, quoteIdent, RowCollector, SCHEMA_CAPS, type RowSink, type RowsResult, type SchemaResult, type WriteOutcome } from "./sql.ts";

export interface MyEndpoint {
  host: string;
  port: number;
  user: string;
  password?: string;
  database?: string;
}

/** The part of a mysql2 command (Query/Execute) the driver uses. */
export interface MyCmd {
  on(ev: string, fn: (...a: any[]) => void): MyCmd;
}
/** The part of a mysql2 connection the driver uses (a fake one in tests). */
export interface MyConn {
  threadId: number | null;
  connect(cb: (err: unknown) => void): void;
  query(o: { sql: string; values?: unknown[] }, cb?: (err: unknown, rows: any, fields: any) => void): MyCmd;
  execute(o: { sql: string; values?: unknown[] }, cb?: (err: unknown, rows: any, fields: any) => void): MyCmd;
  pause(): void;
  resume(): void;
  destroy(): void;
  end(cb?: (err?: unknown) => void): void;
  on(ev: "error", fn: (e: unknown) => void): unknown;
}
export interface MyDriver {
  createConnection(o: Record<string, unknown>): MyConn;
}

let mod: Promise<MyDriver> | undefined;
let testDriver: MyDriver | undefined;
/** Tests: replace mysql2 with a fake (undefined restores it). */
export function setMysqlDriverForTests(d: MyDriver | undefined): void {
  testDriver = d;
}
function load(): Promise<MyDriver> {
  if (testDriver) return Promise.resolve(testDriver);
  return (mod ??= import("mysql2").then((m) => ((m as { default?: unknown }).default ?? m) as unknown as MyDriver));
}

const CONNECT_TIMEOUT_MS = 10_000;
const BACKSTOP_MS = 5_000;

export function connectionOptions(ep: MyEndpoint): Record<string, unknown> {
  return {
    host: ep.host,
    port: ep.port,
    user: ep.user,
    ...(ep.password !== undefined ? { password: ep.password } : {}),
    ...(ep.database ? { database: ep.database } : {}),
    connectTimeout: CONNECT_TIMEOUT_MS,
    multipleStatements: false,
    flags: ["-MULTI_STATEMENTS", "-LOCAL_FILES"],
    rowsAsArray: true,
    dateStrings: true,
    supportBigNumbers: true,
    bigNumberStrings: true,
    decimalNumbers: false,
    charset: "utf8mb4",
    disableEval: true,
  };
}

/** Maps a mysql2/network error to agent.db.*; driver text goes through redact. */
export function mysqlError(e: unknown): AppError {
  if (e instanceof AppError) return e;
  const err = e as { errno?: number; code?: string; sqlState?: string; sqlMessage?: string; message?: string };
  const message = redact(String(err.sqlMessage ?? err.message ?? "")).slice(0, 500);
  const errno = typeof err.errno === "number" ? err.errno : undefined;
  const code = err.code ?? "";
  // 3024 MySQL max execution time, 1969 MariaDB max_statement_time, 1317 killed (our KILL QUERY), 1205 lock wait.
  if (errno === 3024 || errno === 1969 || errno === 1317 || errno === 1205) return new AppError("agent.db.timeout", 504, {});
  // 1792 read-only transaction, 1836 read-only server.
  if (errno === 1792 || errno === 1836) return new AppError("agent.db.readOnly", 409, { message });
  if (errno === 1045 || errno === 1698) return new AppError("agent.db.authFailed", 401, { sqlState: err.sqlState ?? "28000" });
  if (errno === 1049) return new AppError("agent.db.databaseNotFound", 404, { sqlState: err.sqlState ?? "42000" });
  if (errno === 1044 || errno === 1142 || errno === 1143 || errno === 1227 || errno === 1370) return new AppError("agent.db.permissionDenied", 403, { message });
  if (errno !== undefined && errno < 2000) return new AppError("agent.db.queryFailed", 400, { errno, ...(err.sqlState ? { sqlState: err.sqlState } : {}), message });
  if (["ECONNREFUSED", "ETIMEDOUT", "EHOSTUNREACH", "ENETUNREACH", "ENOTFOUND", "EAI_AGAIN", "ECONNRESET", "PROTOCOL_CONNECTION_LOST"].includes(code)) {
    return new AppError("agent.db.unreachable", 502, { reason: code });
  }
  return new AppError("agent.db.failed", 502, { message });
}

function q<T = unknown[][]>(conn: MyConn, sql: string, values?: unknown[]): Promise<T> {
  return new Promise((resolve, reject) => {
    conn.query({ sql, ...(values ? { values } : {}) }, (err, rows) => (err ? reject(err) : resolve(rows as T)));
  });
}

async function row1<T extends unknown[]>(conn: MyConn, sql: string): Promise<T> {
  const rows = await q<T[]>(conn, sql);
  if (!rows[0]) throw new AppError("agent.db.failed", 502, { reason: "noRow" });
  return rows[0];
}

export interface MySession {
  conn: MyConn;
  mariadb: boolean;
  version: string;
}

interface SessionOpts {
  timeoutMs: number;
  write?: boolean;
  backstopMs?: number;
}

/** Best effort: stops the statement still running on threadId (a second, short-lived connection). */
async function killQuery(m: MyDriver, ep: MyEndpoint, threadId: number | null): Promise<void> {
  if (!threadId) return;
  const k = m.createConnection({ ...connectionOptions(ep), connectTimeout: 5000 });
  k.on("error", () => {});
  const t = setTimeout(() => k.destroy(), 5000);
  try {
    await new Promise<void>((res, rej) => k.connect((e) => (e ? rej(e) : res())));
    await q(k, `KILL QUERY ${Number(threadId)}`);
  } catch {
    // The statement may have ended already, or the user can't kill: the dropped socket still ends the transaction.
  } finally {
    clearTimeout(t);
    k.destroy();
  }
}

/**
 * Connects, prepares the session (sql_mode, timeouts, read-only unless `write`), starts a transaction, runs fn and
 * rolls back (or commits when fn calls `tx.commit()`). A streamed read that stops early destroys the connection
 * (`tx.drop()`), which also ends the transaction.
 */
export async function withMysql<T>(ep: MyEndpoint, o: SessionOpts, fn: (s: MySession, tx: { commit(): void; drop(): void }) => Promise<T>): Promise<T> {
  const m = await load();
  const conn = m.createConnection(connectionOptions(ep));
  conn.on("error", () => {});
  let dead = false;
  let timer: NodeJS.Timeout | undefined;
  const backstop = new Promise<never>((_, reject) => {
    timer = setTimeout(() => {
      dead = true;
      const id = conn.threadId;
      conn.destroy();
      void killQuery(m, ep, id);
      reject(new AppError("agent.db.timeout", 504, {}));
    }, o.backstopMs ?? CONNECT_TIMEOUT_MS + o.timeoutMs + BACKSTOP_MS);
  });
  const work = (async () => {
    try {
      await new Promise<void>((res, rej) => conn.connect((e) => (e ? rej(e) : res())));
    } catch (e) {
      throw mysqlError(e);
    }
    let commit = false;
    let ended = false;
    try {
      const [version, sqlMode] = await row1<[string, string]>(conn, "SELECT VERSION(), @@SESSION.sql_mode");
      const mariadb = /mariadb/i.test(String(version));
      const mode = String(sqlMode ?? "")
        .split(",")
        .filter((x) => x && !["NO_BACKSLASH_ESCAPES", "ANSI_QUOTES", "ANSI"].includes(x.toUpperCase()))
        .join(",");
      await q(conn, "SET SESSION sql_mode = ?", [mode]);
      const ms = Math.max(1, Math.floor(o.timeoutMs));
      if (mariadb) await q(conn, `SET SESSION max_statement_time = ${(ms / 1000).toFixed(3)}`);
      else await q(conn, `SET SESSION MAX_EXECUTION_TIME = ${ms}`);
      if (o.write) await q(conn, `SET SESSION innodb_lock_wait_timeout = ${Math.max(1, Math.ceil(ms / 1000))}`).catch(() => {});
      else await q(conn, "SET SESSION TRANSACTION READ ONLY");
      await q(conn, o.write ? "START TRANSACTION READ WRITE" : "START TRANSACTION READ ONLY");
      const out = await fn({ conn, mariadb, version: String(version) }, {
        commit: () => (commit = true),
        drop: () => {
          dead = true;
          conn.destroy();
        },
      });
      if (commit && !dead) {
        ended = true;
        await q(conn, "COMMIT");
      }
      return out;
    } catch (e) {
      throw mysqlError(e);
    } finally {
      if (!ended && !dead) await q(conn, "ROLLBACK").catch(() => {});
    }
  })();
  try {
    return await Promise.race([work, backstop]);
  } finally {
    clearTimeout(timer);
    work.catch(() => {});
    if (!dead) await Promise.race([new Promise<void>((r) => conn.end(() => r())), new Promise((r) => setTimeout(r, 2000))]);
    conn.destroy();
  }
}

const TYPES: Record<number, string> = {
  0: "decimal", 1: "tinyint", 2: "smallint", 3: "int", 4: "float", 5: "double", 6: "null", 7: "timestamp", 8: "bigint",
  9: "mediumint", 10: "date", 11: "time", 12: "datetime", 13: "year", 14: "date", 15: "varchar", 16: "bit", 245: "json",
  246: "decimal", 247: "enum", 248: "set", 249: "blob", 250: "blob", 251: "blob", 252: "blob", 253: "varchar", 254: "char", 255: "geometry",
};
type Field = { name: string; columnType?: number; type?: number; characterSet?: number };
function typeName(f: Field): string {
  const t = f.columnType ?? f.type ?? -1;
  const name = TYPES[t] ?? `type:${t}`;
  return name === "blob" && f.characterSet !== 63 ? "text" : name;
}
const columnsOf = (fields: Field[] | undefined) => (fields ?? []).map((f) => ({ name: f.name, type: typeName(f) }));

/**
 * Runs one statement as a prepared statement and streams its rows to the sink; a sink returning false ends the read
 * (the connection is dropped). Statements the server can't prepare (1295) and that have no parameters run as text.
 * Resolves to the result header for statements without rows (affectedRows).
 */
function streamStatement(s: MySession, tx: { drop(): void }, sql: string, params: unknown[], sink: { fields(f: Field[]): void; row(r: unknown[]): boolean | Promise<boolean> }): Promise<{ affectedRows?: number }> {
  const once = (prepared: boolean) =>
    new Promise<{ affectedRows?: number; unsupported?: boolean }>((resolve, reject) => {
      let settled = false;
      let stopped = false;
      let header: { affectedRows?: number } = {};
      let chain = Promise.resolve();
      let inflight = 0;
      let gotFields = false;
      const settle = (fn: () => void) => {
        if (settled) return;
        settled = true;
        fn();
      };
      const stop = () => {
        if (stopped) return;
        stopped = true;
        tx.drop();
        settle(() => resolve(header));
      };
      const cmd = prepared ? s.conn.execute({ sql, values: params }) : s.conn.query({ sql });
      cmd.on("fields", (f: Field[] | undefined) => {
        gotFields = true;
        if (!stopped) sink.fields(f ?? []);
      });
      cmd.on("result", (row: unknown) => {
        if (stopped) return;
        if (!Array.isArray(row)) {
          header = row as { affectedRows?: number };
          return;
        }
        inflight++;
        if (inflight > 200) s.conn.pause();
        chain = chain.then(async () => {
          if (stopped) return;
          let cont: boolean;
          try {
            cont = await sink.row(row);
          } catch (e) {
            stopped = true;
            tx.drop();
            settle(() => reject(e));
            return;
          }
          inflight--;
          if (!cont) stop();
          else if (inflight === 0) s.conn.resume();
        });
      });
      cmd.on("error", (e: { errno?: number }) => {
        if (prepared && e?.errno === 1295 && !gotFields && params.length === 0) settle(() => resolve({ unsupported: true }));
        else settle(() => reject(e));
      });
      cmd.on("end", () => void chain.then(() => settle(() => resolve(header))));
    });
  return once(true).then((r) => (r.unsupported ? once(false) : r));
}

async function readRows(s: MySession, tx: { drop(): void }, sql: string, params: unknown[], limit: number): Promise<RowsResult> {
  const out = new RowCollector(limit);
  let columns: RowsResult["columns"] = [];
  await streamStatement(s, tx, sql, params, { fields: (f) => (columns = columnsOf(f)), row: (r) => out.add(r) });
  return { columns, rows: out.rows, rowCount: out.rows.length, truncated: out.truncated, cellsTruncated: out.cellsTruncated };
}

export function mysqlQuery(ep: MyEndpoint, sql: string, params: unknown[], limit: number, timeoutMs: number): Promise<RowsResult> {
  return withMysql(ep, { timeoutMs }, (s, tx) => readRows(s, tx, sql, params, limit));
}

/** CSV export: streams every row to the sink (read-only, the export's wall clock as backstop). */
export async function mysqlStream(ep: MyEndpoint, sql: string, params: unknown[], timeoutMs: number, sink: RowSink): Promise<void> {
  await withMysql(ep, { timeoutMs, backstopMs: LIMITS.exportWallMs }, async (s, tx) => {
    let started = false;
    const start = (f: Field[]) => {
      if (started) return;
      started = true;
      sink.columns(columnsOf(f));
    };
    await streamStatement(s, tx, sql, params, { fields: start, row: (r) => sink.row(r) });
    start([]);
  });
}

const SYSTEM_SCHEMAS = `('mysql', 'information_schema', 'performance_schema', 'sys')`;
const str = (v: unknown) => (v === null || v === undefined ? null : Buffer.isBuffer(v) ? v.toString() : String(v));

/** The table must exist in information_schema; the query uses the catalog's names, backtick-quoted. */
export function mysqlPreview(ep: MyEndpoint, schema: string, table: string, limit: number, timeoutMs: number): Promise<RowsResult> {
  return withMysql(ep, { timeoutMs }, async (s, tx) => {
    const found = await q<unknown[][]>(s.conn, "SELECT TABLE_SCHEMA, TABLE_NAME FROM information_schema.TABLES WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?", [schema, table]);
    const row = found[0];
    if (!row) throw new AppError("agent.db.tableNotFound", 404, {});
    return readRows(s, tx, `SELECT * FROM ${quoteIdent(str(row[0])!, "mysql")}.${quoteIdent(str(row[1])!, "mysql")} LIMIT ${Number(limit) + 1}`, [], limit);
  });
}

export function mysqlSchema(ep: MyEndpoint, timeoutMs: number): Promise<SchemaResult> {
  return withMysql(ep, { timeoutMs }, async (s) => {
    const tables = await q<unknown[][]>(
      s.conn,
      `SELECT TABLE_SCHEMA, TABLE_NAME, TABLE_TYPE, TABLE_ROWS FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ${SYSTEM_SCHEMAS} ORDER BY 1, 2 LIMIT ${SCHEMA_CAPS.tables + 1}`,
    );
    const columns = await q<unknown[][]>(
      s.conn,
      `SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY FROM information_schema.COLUMNS
       WHERE TABLE_SCHEMA NOT IN ${SYSTEM_SCHEMAS} ORDER BY TABLE_SCHEMA, TABLE_NAME, ORDINAL_POSITION LIMIT ${SCHEMA_CAPS.columns + 1}`,
    );
    const indexes = await q<unknown[][]>(
      s.conn,
      `SELECT TABLE_SCHEMA, TABLE_NAME, INDEX_NAME, MIN(NON_UNIQUE), GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ', ') FROM information_schema.STATISTICS
       WHERE TABLE_SCHEMA NOT IN ${SYSTEM_SCHEMAS} GROUP BY TABLE_SCHEMA, TABLE_NAME, INDEX_NAME ORDER BY 1, 2, 3 LIMIT ${SCHEMA_CAPS.indexes + 1}`,
    );
    const truncated = tables.length > SCHEMA_CAPS.tables || columns.length > SCHEMA_CAPS.columns || indexes.length > SCHEMA_CAPS.indexes;
    return buildSchema(
      tables.slice(0, SCHEMA_CAPS.tables).map((r) => ({ schema: str(r[0])!, table: str(r[1])!, kind: str(r[2]) === "VIEW" ? ("view" as const) : ("table" as const), estimatedRows: r[3] === null || r[3] === undefined ? null : Number(r[3]) })),
      columns.slice(0, SCHEMA_CAPS.columns).map((r) => ({ schema: str(r[0])!, table: str(r[1])!, name: str(r[2])!, type: str(r[3]) ?? "", nullable: str(r[4]) === "YES", default: str(r[5]), primaryKey: str(r[6]) === "PRI" })),
      indexes.slice(0, SCHEMA_CAPS.indexes).map((r) => ({ schema: str(r[0])!, table: str(r[1])!, name: str(r[2])!, unique: Number(r[3]) === 0, primary: str(r[2]) === "PRIMARY", definition: r[4] === null ? null : `(${str(r[4])})` })),
      truncated,
    );
  });
}

/** SUPER or FILE privilege of the current account (FILE allows INTO OUTFILE / LOAD_FILE). */
async function privileged(conn: MyConn): Promise<boolean> {
  const [n] = await row1<[unknown]>(
    conn,
    `SELECT COUNT(*) FROM information_schema.USER_PRIVILEGES WHERE PRIVILEGE_TYPE IN ('SUPER', 'FILE')
     AND GRANTEE = CONCAT('''', SUBSTRING_INDEX(CURRENT_USER(), '@', 1), '''@''', SUBSTRING_INDEX(CURRENT_USER(), '@', -1), '''')`,
  );
  return Number(n) > 0;
}

export interface MyTestResult {
  serverVersion: string;
  flavor: "mysql" | "mariadb";
  user: string;
  database: string | null;
  superuser: boolean;
  readOnlyDefault: boolean;
}

export function mysqlTest(ep: MyEndpoint, timeoutMs: number): Promise<MyTestResult> {
  return withMysql(ep, { timeoutMs }, async (s) => {
    const [user, database] = await row1<[string, string | null]>(s.conn, "SELECT CURRENT_USER(), DATABASE()");
    const [ro] = await row1<[unknown]>(s.conn, "SELECT @@SESSION.transaction_read_only").catch(() => row1<[unknown]>(s.conn, "SELECT @@SESSION.tx_read_only"));
    return { serverVersion: s.version, flavor: s.mariadb ? "mariadb" : "mysql", user: String(user), database: str(database), superuser: await privileged(s.conn), readOnlyDefault: Number(ro) === 1 };
  });
}

/** Engines whose changes a ROLLBACK undoes. A preview on any other engine would really write. */
const TRANSACTIONAL = `('INNODB', 'NDBCLUSTER', 'NDB', 'ROCKSDB', 'TOKUDB')`;

/**
 * Write mode (DML only; DDL commits implicitly and never gets here). Refuses when any user base table uses a
 * non-transactional engine (MyISAM, Aria, MEMORY…): a preview could not be rolled back there. The statement runs
 * once; `decide(affectedRows)` says whether to COMMIT, else ROLLBACK. affectedRows counts matched rows (FOUND_ROWS).
 */
export function mysqlWrite(ep: MyEndpoint, stmt: string, timeoutMs: number, o: { decide(count: number | null): Promise<boolean> }): Promise<WriteOutcome> {
  return withMysql(ep, { timeoutMs, write: true }, async (s, tx) => {
    // Unqualified names resolve in the default database: refuse when that is a system schema (the statement check
    // refuses qualified system names).
    const [db] = await row1<[unknown]>(s.conn, "SELECT DATABASE()");
    const dbName = str(db)?.toLowerCase();
    if (dbName && (MYSQL_SYSTEM_SCHEMAS as readonly string[]).includes(dbName)) throw new AppError("agent.db.systemSchema", 400, { schema: dbName });
    const nt = await q<unknown[][]>(
      s.conn,
      `SELECT TABLE_SCHEMA, TABLE_NAME, ENGINE FROM information_schema.TABLES WHERE TABLE_TYPE = 'BASE TABLE' AND TABLE_SCHEMA NOT IN ${SYSTEM_SCHEMAS}
       AND ENGINE IS NOT NULL AND UPPER(ENGINE) NOT IN ${TRANSACTIONAL} ORDER BY 1, 2 LIMIT 11`,
    );
    if (nt.length) {
      throw new AppError("agent.db.nonTransactionalTables", 409, { tables: nt.slice(0, 10).map((r) => `${str(r[0])}.${str(r[1])} (${str(r[2])})`), more: nt.length > 10 });
    }
    const superuser = await privileged(s.conn);
    const header = await streamStatement(s, tx, stmt, [], { fields: () => {}, row: () => true });
    const count = typeof header.affectedRows === "number" ? header.affectedRows : 0;
    const commit = await o.decide(count);
    if (commit) tx.commit();
    return { count, superuser, committed: commit };
  });
}
