// Database console, PLAN.md §13.2 D-2 + D-3: CSV escaping, formula guard and export limits; saved queries (CRUD, run,
// file mode); MySQL/MariaDB lexer and allowlists and the driver's session setup (fake mysql2); write mode (preview →
// commit, countChanged, token binding/expiry, rate limit) with a fake PostgreSQL write driver; write allowlist
// refusals; db-writes.jsonl content, mode and rotation; credential redaction for write credentials.
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { EventEmitter } from "node:events";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { hashToken, newToken } from "../src/auth.ts";
import { ConfigStore } from "../src/config.ts";
import { csvCell, csvLine } from "../src/db/csv.ts";
import { resolveContainer, type Runner } from "../src/db/docker.ts";
import { mysqlError, mysqlQuery, mysqlWrite, setMysqlDriverForTests, type MyDriver } from "../src/db/mysql.ts";
import { dbRoutes, sqlSha256 } from "../src/db/routes.ts";
import type { DbServiceOpts } from "../src/db/service.ts";
import { checkReadStatement, checkWriteStatement, columnKinds, LIMITS, statements, type RowSink, type WriteOutcome } from "../src/db/sql.ts";
import { maskPasswords, WriteLog, WRITE_LOG_MAX_BYTES } from "../src/db/writelog.ts";
import { Notifier } from "../src/notify.ts";
import { buildApp } from "../src/server.ts";

const SECRET = "Wr1te-S3cret-pw-K7";
const READ_SECRET = "R3ad-S3cret-pw-M2";

// --- CSV ------------------------------------------------------------------------------------------------------------

describe("CSV", () => {
  it("escapes per RFC 4180 and guards against formulas", () => {
    expect(csvCell(null)).toBe("");
    expect(csvCell(true)).toBe("true");
    expect(csvCell(-12.5)).toBe("-12.5");
    expect(csvCell("plain")).toBe("plain");
    expect(csvCell('a "q", b')).toBe('"a ""q"", b"');
    expect(csvCell("line1\nline2")).toBe('"line1\nline2"');
    expect(csvCell("cr\r")).toBe('"cr\r"');
    for (const f of ["=1+1", "+cmd|' /C calc'!A0", "-2+3", "@SUM(A1)", "\tx", "\r=x"]) expect(csvCell(f).replace(/^"/, "").startsWith("'")).toBe(true);
    expect(csvCell('=HYPERLINK("http://x","y")')).toBe(`"'=HYPERLINK(""http://x"",""y"")"`);
    // Plain numbers in text form (int8, numeric) are not formulas.
    expect(csvCell("-12.50")).toBe("-12.50");
    expect(csvCell("+3e5")).toBe("+3e5");
    expect(csvCell("-")).toBe("'-");
    expect(csvLine(["a", 1, null, false])).toBe("a,1,,false\r\n");
  });

  it("column kinds for charts", () => {
    const kinds = columnKinds(
      [{ name: "a", type: "int8" }, { name: "b", type: null }, { name: "c", type: null }, { name: "d", type: "timestamptz" }, { name: "e", type: null }, { name: "f", type: "text" }],
      [["1", "2.5", "2026-01-02", "x", true, "a"], ["2", null, "2026-01-03 10:00:00", "y", false, "b"]],
    );
    expect(kinds).toEqual(["number", "number", "datetime", "datetime", "boolean", "text"]);
  });
});

// --- MySQL lexer and allowlists ----------------------------------------------------------------------------------------

describe("MySQL/MariaDB statements", () => {
  it("lexes MySQL comments and strings", () => {
    expect(statements("SELECT 1 -- x; DROP TABLE t", "mysql")).toHaveLength(1);
    // "--1" is not a comment in MySQL (no space): the ; ends the first statement.
    expect(statements("SELECT 1 --1; DROP TABLE t", "mysql")).toHaveLength(2);
    expect(statements("SELECT 1 # c; DROP\n", "mysql")).toHaveLength(1);
    expect(statements("SELECT 'a\\'; DROP TABLE t'", "mysql")).toHaveLength(1);
    expect(statements('SELECT "a\\"; b"', "mariadb")).toHaveLength(1);
    expect(statements("SELECT `a;b` FROM t", "mysql")).toHaveLength(1);
  });

  it("read allowlist refuses file access, server settings and executable comments", () => {
    for (const sql of ["SELECT 1", "WITH a AS (SELECT 1) SELECT * FROM a", "SHOW TABLES", "DESC t", "DESCRIBE t", "EXPLAIN SELECT 1", "TABLE t", "VALUES ROW(1)", "INSERT INTO t VALUES (1)", "SELECT 'into outfile' AS s"]) {
      expect(checkReadStatement(sql, "mysql"), sql).toEqual({ ok: true });
    }
    const refused: Array<[string, string]> = [
      ["SELECT * FROM t INTO OUTFILE '/tmp/x'", "outfile"],
      ["SELECT * INTO DUMPFILE '/tmp/x' FROM t", "dumpfile"],
      ["SELECT 1 INTO @v", "into"],
      ["SELECT LOAD_FILE('/etc/passwd')", "load_file"],
      ["SELECT `load_file`('/etc/passwd')", "load_file"],
      ["LOAD DATA INFILE '/etc/passwd' INTO TABLE t", "load"],
      ["LOAD DATA LOCAL INFILE '/etc/passwd' INTO TABLE t", "load"],
      ["SET GLOBAL read_only = 0", "set"],
      ["SET SESSION MAX_EXECUTION_TIME = 0", "set"],
      ["SET STATEMENT max_statement_time=0 FOR SELECT SLEEP(100)", "set"],
      ["/*!50000 DROP TABLE t */", "/*!"],
      ["SELECT 1 /*! INTO OUTFILE '/tmp/x' */", "/*!"],
      ["SELECT /*+ SET_VAR(max_execution_time=0) */ SLEEP(100)", "/*!"],
      ["SELECT 1 /*M! , 2 */", "/*!"],
      ["HANDLER t OPEN", "handler"],
      ["DO SLEEP(1)", "do"],
      ["CALL p()", "call"],
      ["GRANT ALL ON *.* TO x", "grant"],
      ["CREATE TABLE x (a int)", "create"],
      ["USE mysql", "use"],
      ["PREPARE s FROM 'SELECT 1'", "prepare"],
      ["XA START 'x'", "xa"],
    ];
    for (const [sql, kw] of refused) expect(checkReadStatement(sql, "mysql"), sql).toMatchObject({ ok: false, code: "agent.db.statementNotAllowed", keyword: kw });
    expect(checkReadStatement("SELECT 1; SELECT 2", "mariadb")).toMatchObject({ code: "agent.db.multipleStatements" });
  });

  it("write allowlist: DML only, DDL not previewable", () => {
    expect(checkWriteStatement("UPDATE t SET a = 1 WHERE id > 3", "mysql")).toMatchObject({ ok: true, kind: "dml", verb: "update" });
    expect(checkWriteStatement("REPLACE INTO t VALUES (1)", "mariadb")).toMatchObject({ ok: true, verb: "replace" });
    expect(checkWriteStatement("WITH x AS (SELECT 1 AS id) DELETE t FROM t JOIN x USING (id)", "mysql")).toMatchObject({ ok: true, verb: "delete" });
    for (const kw of ["CREATE TABLE x (a int)", "ALTER TABLE t ADD c int", "DROP TABLE t", "TRUNCATE t", "RENAME TABLE a TO b", "GRANT SELECT ON *.* TO x", "REVOKE ALL ON *.* FROM x"]) {
      expect(checkWriteStatement(kw, "mysql"), kw).toMatchObject({ ok: false, code: "agent.db.ddlNotPreviewable" });
    }
    for (const sql of ["LOAD DATA INFILE '/x' INTO TABLE t", "SELECT 1", "SET GLOBAL x = 1", "INSERT INTO t SELECT LOAD_FILE('/etc/shadow')", "UPDATE t SET a = 1 /*! , b = 2 */", "CALL p()"]) {
      expect(checkWriteStatement(sql, "mysql"), sql).toMatchObject({ ok: false, code: "agent.db.statementNotAllowed" });
    }
  });
});

// --- PostgreSQL write allowlist -----------------------------------------------------------------------------------------

describe("PostgreSQL write allowlist", () => {
  it("accepts DML and table/index/view DDL", () => {
    expect(checkWriteStatement("UPDATE t SET a = 1", "postgres")).toEqual({ ok: true, kind: "dml", verb: "update", returning: false });
    expect(checkWriteStatement("DELETE FROM t WHERE id = 1 RETURNING id;", "postgres")).toMatchObject({ ok: true, verb: "delete", returning: true });
    expect(checkWriteStatement("WITH old AS (SELECT id FROM t WHERE x) DELETE FROM t USING old WHERE t.id = old.id", "postgres")).toMatchObject({ ok: true, verb: "delete" });
    expect(checkWriteStatement("MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE", "postgres")).toMatchObject({ ok: true, verb: "merge" });
    for (const sql of [
      "CREATE TABLE w (a int)",
      "CREATE UNLOGGED TABLE IF NOT EXISTS w (a int)",
      "CREATE UNIQUE INDEX w_a ON w (a)",
      "CREATE OR REPLACE VIEW v AS SELECT 1",
      "CREATE MATERIALIZED VIEW m AS SELECT 1",
      "ALTER TABLE w ADD COLUMN b text",
      "ALTER MATERIALIZED VIEW m RENAME TO m2",
      "DROP TABLE w",
      "DROP INDEX w_a",
      "DROP VIEW v",
      "CREATE ROLE \"tiphys_ro\" LOGIN PASSWORD 'x' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS CONNECTION LIMIT 5 IN ROLE pg_read_all_data",
    ]) {
      expect(checkWriteStatement(sql, "postgres"), sql).toMatchObject({ ok: true, kind: "ddl" });
    }
  });

  it("refuses programs, files, code and privilege changes", () => {
    const refused: Array<[string, string]> = [
      ["COPY t TO PROGRAM 'id'", "copy"],
      ["COPY t FROM PROGRAM 'id'", "copy"],
      ["DO $$ BEGIN PERFORM 1; END $$", "do"],
      ["CALL p()", "call"],
      ["SET ROLE postgres", "set"],
      ["ALTER SYSTEM SET archive_command = 'x'", "alter system"],
      ["ALTER ROLE x SUPERUSER", "alter role"],
      ["CREATE FUNCTION f() RETURNS int LANGUAGE plpython3u AS $$ import os $$", "create function"],
      ["CREATE OR REPLACE PROCEDURE p() LANGUAGE sql AS $$ SELECT 1 $$", "create procedure"],
      ["CREATE TRIGGER x AFTER INSERT ON t EXECUTE FUNCTION f()", "create trigger"],
      ["CREATE EXTENSION adminpack", "create extension"],
      ["CREATE ROLE x SUPERUSER", "create role superuser"],
      ["CREATE ROLE x LOGIN IN ROLE pg_execute_server_program", "create role pg_execute_server_program"],
      ["CREATE USER x CREATEROLE", "create role createrole"],
      ["GRANT pg_execute_server_program TO x", "grant"],
      ["DROP ROLE x", "drop role"],
      ["DROP DATABASE x", "drop database"],
      ["TRUNCATE t", "truncate"],
      ["SELECT 1", "select"],
      ["WITH x AS (DELETE FROM t RETURNING *) SELECT * FROM x", "with select"],
      ["INSERT INTO t SELECT pg_read_file('/etc/passwd')", "pg_read_file"],
      ['INSERT INTO t SELECT "pg_read_file"(\'/etc/passwd\')', "pg_read_file"],
      ["INSERT INTO t SELECT pg_catalog.pg_read_binary_file('/etc/passwd')", "pg_read_binary_file"],
      ["CREATE TABLE x AS SELECT lo_import('/etc/passwd')", "lo_import"],
      ["UPDATE t SET a = lo_export(1, '/tmp/x')", "lo_export"],
      ["INSERT INTO t SELECT * FROM dblink_exec('host=x', 'COPY t TO PROGRAM ''id''')", "dblink_exec"],
      ["INSERT INTO t SELECT query_to_xml('SELECT 1', true, true, '')", "query_to_xml"],
      ["UPDATE t SET a = pg_terminate_backend(1)", "pg_terminate_backend"],
    ];
    for (const [sql, kw] of refused) expect(checkWriteStatement(sql, "postgres"), sql).toMatchObject({ ok: false, code: "agent.db.statementNotAllowed", keyword: kw });
    expect(checkWriteStatement("UPDATE t SET a = 1; DROP TABLE t", "postgres")).toMatchObject({ code: "agent.db.multipleStatements" });
    expect(checkWriteStatement("DELETE FROM t", "sqlite")).toMatchObject({ ok: false });
    // The read path refuses the denylisted functions too.
    expect(checkReadStatement("SELECT pg_read_file('/etc/passwd')", "postgres")).toMatchObject({ code: "agent.db.statementNotAllowed", keyword: "pg_read_file" });
    expect(checkReadStatement("SELECT * FROM dblink('x', 'y') AS t(a int)", "postgres")).toMatchObject({ keyword: "dblink" });
    // Strings and comments don't count.
    expect(checkWriteStatement("UPDATE t SET note = 'pg_read_file' /* lo_import */", "postgres")).toMatchObject({ ok: true });
  });

  it("masks role passwords for the write log", () => {
    expect(maskPasswords("CREATE ROLE r LOGIN PASSWORD 'abc''d' IN ROLE pg_read_all_data")).toBe("CREATE ROLE r LOGIN PASSWORD '[GİZLİ]' IN ROLE pg_read_all_data");
    expect(maskPasswords("CREATE USER 'r'@'%' IDENTIFIED BY 'p\\'w'")).toBe("CREATE USER 'r'@'%' IDENTIFIED BY '[GİZLİ]'");
  });
});

// --- mysql2 fake: session setup ----------------------------------------------------------------------------------------

interface FakeLog {
  options: Array<Record<string, unknown>>;
  calls: Array<{ kind: "query" | "execute"; sql: string; values?: unknown[] }>;
  destroyed: number;
}

function fakeMysql(o: { version: string; sqlMode?: string; rows?: unknown[][]; header?: { affectedRows: number }; error?: { errno: number; sqlMessage: string }; nonTransactional?: unknown[][] }): { driver: MyDriver; log: FakeLog } {
  const log: FakeLog = { options: [], calls: [], destroyed: 0 };
  const respond = (sql: string): unknown[][] => {
    if (sql.startsWith("SELECT VERSION()")) return [[o.version, o.sqlMode ?? "STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES,ANSI_QUOTES"]];
    if (sql.includes("USER_PRIVILEGES")) return [[0]];
    if (sql.includes("information_schema.TABLES") && sql.includes("ENGINE")) return o.nonTransactional ?? [];
    return [];
  };
  const driver: MyDriver = {
    createConnection(options) {
      log.options.push(options);
      return {
        threadId: 7,
        connect: (cb) => setImmediate(() => cb(null)),
        query(q, cb) {
          log.calls.push({ kind: "query", sql: q.sql, ...(q.values ? { values: q.values } : {}) });
          const em = new EventEmitter();
          setImmediate(() => cb?.(null, respond(q.sql), []));
          return em as never;
        },
        execute(q) {
          log.calls.push({ kind: "execute", sql: q.sql, values: q.values });
          const em = new EventEmitter();
          setImmediate(() => {
            if (o.error) {
              em.emit("error", o.error);
              em.emit("end");
              return;
            }
            if (o.header) em.emit("result", o.header);
            else {
              em.emit("fields", [{ name: "a", columnType: 8 }, { name: "b", columnType: 252, characterSet: 63 }]);
              for (const r of o.rows ?? []) em.emit("result", r);
            }
            em.emit("end");
          });
          return em as never;
        },
        pause() {},
        resume() {},
        destroy() {
          log.destroyed++;
        },
        end: (cb) => cb?.(),
        on() {},
      };
    },
  };
  return { driver, log };
}

describe("MySQL driver session (fake mysql2)", () => {
  afterEach(() => setMysqlDriverForTests(undefined));
  const ep = { host: "127.0.0.1", port: 3306, user: "u", password: READ_SECRET, database: "app" };

  it("MySQL: no multi statements, no LOCAL INFILE, read-only transaction, MAX_EXECUTION_TIME, rollback", async () => {
    const { driver, log } = fakeMysql({ version: "8.4.3", rows: [["9007199254740993", Buffer.from("xy")], ["2", null]] });
    setMysqlDriverForTests(driver);
    const r = await mysqlQuery(ep, "SELECT a, b FROM t WHERE id > ?", [1], 500, 15_000);
    expect(r).toMatchObject({ columns: [{ name: "a", type: "bigint" }, { name: "b", type: "blob" }], rows: [["9007199254740993", "<2 bayt>"], ["2", null]], truncated: false });
    expect(log.options[0]).toMatchObject({ multipleStatements: false, flags: ["-MULTI_STATEMENTS", "-LOCAL_FILES"], disableEval: true, rowsAsArray: true });
    expect(log.options[0]).not.toHaveProperty("infileStreamFactory");
    expect(log.calls.map((c) => c.sql)).toEqual([
      "SELECT VERSION(), @@SESSION.sql_mode",
      "SET SESSION sql_mode = ?",
      "SET SESSION MAX_EXECUTION_TIME = 15000",
      "SET SESSION TRANSACTION READ ONLY",
      "START TRANSACTION READ ONLY",
      "SELECT a, b FROM t WHERE id > ?",
      "ROLLBACK",
    ]);
    // The lexer's assumptions are pinned: no NO_BACKSLASH_ESCAPES / ANSI_QUOTES.
    expect(log.calls[1]!.values).toEqual(["STRICT_TRANS_TABLES"]);
    expect(log.calls[5]).toMatchObject({ kind: "execute", values: [1] });
  });

  it("MariaDB: max_statement_time; a full result drops the connection", async () => {
    const { driver, log } = fakeMysql({ version: "11.8.3-MariaDB-ubu2404", rows: [[1, null], [2, null], [3, null], [4, null]] });
    setMysqlDriverForTests(driver);
    const r = await mysqlQuery(ep, "SELECT a, b FROM t", [], 2, 2500);
    expect(r).toMatchObject({ rowCount: 2, truncated: true });
    expect(log.calls.map((c) => c.sql)).toContain("SET SESSION max_statement_time = 2.500");
    expect(log.calls.map((c) => c.sql)).not.toContain("ROLLBACK");
    expect(log.destroyed).toBeGreaterThan(0);
  });

  it("maps errors and redacts their text", async () => {
    expect(mysqlError({ errno: 1792, sqlMessage: "Cannot execute statement in a READ ONLY transaction." })).toMatchObject({ code: "agent.db.readOnly" });
    expect(mysqlError({ errno: 3024, sqlMessage: "maximum statement execution time exceeded" })).toMatchObject({ code: "agent.db.timeout" });
    expect(mysqlError({ errno: 1969, sqlMessage: "Query execution was interrupted (max_statement_time exceeded)" })).toMatchObject({ code: "agent.db.timeout" });
    expect(mysqlError({ errno: 1045, sqlState: "28000", sqlMessage: "Access denied for user 'u'" })).toMatchObject({ code: "agent.db.authFailed", params: { sqlState: "28000" } });
    expect(mysqlError({ code: "ECONNREFUSED", message: "connect ECONNREFUSED" })).toMatchObject({ code: "agent.db.unreachable" });
    const e = mysqlError({ errno: 1064, sqlMessage: `near 'mysql://u:${SECRET}@h/x' password=${SECRET}` });
    expect(e.code).toBe("agent.db.queryFailed");
    expect(JSON.stringify(e.params)).not.toContain(SECRET);
    const { driver } = fakeMysql({ version: "8.4.3", error: { errno: 1792, sqlMessage: "read only" } });
    setMysqlDriverForTests(driver);
    await expect(mysqlQuery(ep, "INSERT INTO t VALUES (1)", [], 10, 1000)).rejects.toMatchObject({ code: "agent.db.readOnly" });
  });

  it("write: read-write transaction, refuses non-transactional tables, commits only when told", async () => {
    let fake = fakeMysql({ version: "8.4.3", header: { affectedRows: 3 } });
    setMysqlDriverForTests(fake.driver);
    const pre = await mysqlWrite(ep, "UPDATE t SET a = 1", 5000, { decide: async () => false });
    expect(pre).toEqual({ count: 3, superuser: false, committed: false });
    expect(fake.log.calls.map((c) => c.sql)).toContain("START TRANSACTION READ WRITE");
    expect(fake.log.calls.map((c) => c.sql)).not.toContain("SET SESSION TRANSACTION READ ONLY");
    expect(fake.log.calls.at(-1)!.sql).toBe("ROLLBACK");
    fake = fakeMysql({ version: "8.4.3", header: { affectedRows: 3 } });
    setMysqlDriverForTests(fake.driver);
    expect(await mysqlWrite(ep, "UPDATE t SET a = 1", 5000, { decide: async (n) => n === 3 })).toMatchObject({ committed: true });
    expect(fake.log.calls.at(-1)!.sql).toBe("COMMIT");
    fake = fakeMysql({ version: "11.8.3-MariaDB", header: { affectedRows: 3 }, nonTransactional: [["app", "logs", "MyISAM"]] });
    setMysqlDriverForTests(fake.driver);
    await expect(mysqlWrite(ep, "UPDATE t SET a = 1", 5000, { decide: async () => true })).rejects.toMatchObject({ code: "agent.db.nonTransactionalTables", params: { tables: ["app.logs (MyISAM)"] } });
    expect(fake.log.calls.some((c) => c.sql.startsWith("UPDATE"))).toBe(false);
  });

  it("fromContainerEnv for mysql/mariadb images", async () => {
    const inspect = (env: string[]) =>
      (async () => ({ stdout: JSON.stringify([{ Name: "/m", Config: { Env: env }, State: { Status: "running" }, NetworkSettings: { Networks: { b: { IPAddress: "172.17.0.9" } } } }]), stderr: "", code: 0 })) as unknown as Runner;
    expect(await resolveContainer(inspect(["MARIADB_ROOT_PASSWORD=" + SECRET, "MARIADB_DATABASE=app"]), "m", undefined, true, "mysql")).toEqual({ host: "172.17.0.9", env: { user: "root", password: SECRET, database: "app" } });
    expect(await resolveContainer(inspect(["MYSQL_USER=app", "MYSQL_PASSWORD=pw", "MYSQL_RANDOM_ROOT_PASSWORD=yes"]), "m", undefined, true, "mysql")).toEqual({ host: "172.17.0.9", env: { user: "app", password: "pw" } });
    expect(await resolveContainer(inspect(["MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1"]), "m", undefined, true, "mysql")).toEqual({ host: "172.17.0.9", env: { user: "root" } });
    await expect(resolveContainer(inspect(["MYSQL_ROOT_PASSWORD_FILE=/run/secrets/x"]), "m", undefined, true, "mysql")).rejects.toMatchObject({ params: { reason: "passwordFile" } });
    await expect(resolveContainer(inspect(["MARIADB_RANDOM_ROOT_PASSWORD=1"]), "m", undefined, true, "mysql")).rejects.toMatchObject({ params: { reason: "noPassword" } });
  });
});

// --- API --------------------------------------------------------------------------------------------------------------

interface FakePg {
  rows: number;
  commits: number;
  lastEp?: { user: string; password?: string };
  sampleCols?: boolean;
}

function fakePgDrivers(state: FakePg, extra: Partial<NonNullable<DbServiceOpts["drivers"]>["pg"]> = {}): DbServiceOpts["drivers"] {
  return {
    pg: {
      write: async (ep, _stmt, w, _t, o): Promise<WriteOutcome> => {
        state.lastEp = ep;
        const count = w.kind === "ddl" ? null : state.rows;
        const commit = await o.decide(count);
        if (commit) state.commits++;
        return { count, superuser: false, committed: commit, ...(o.sample && w.kind === "dml" ? { sample: { columns: [{ name: "id", type: "int4" }], rows: [[1], [2]], cellsTruncated: 0 } } : {}) };
      },
      ...extra,
    },
  };
}

async function setup(o: { now?: () => number; drivers?: DbServiceOpts["drivers"]; previewTtlMs?: number } = {}) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-db23-"));
  const store = await ConfigStore.loadOrCreate(join(dir, "cfg", "agent.json"), "atlas");
  const token = newToken();
  const other = newToken();
  await store.update((c) => {
    c.features.databases = true;
    c.allowedRoots = [join(dir, "data")];
    c.devices.push({ id: "phone", name: "Telefon", tokenHash: hashToken(token), createdAt: new Date().toISOString() });
    c.devices.push({ id: "tablet", name: "Tablet", tokenHash: hashToken(other), createdAt: new Date().toISOString() });
    c.databases.connections = [
      { id: "pg", name: "PG", engine: "postgres", target: { host: "127.0.0.1", port: 1 }, readCredential: { user: "reader", password: READ_SECRET }, writeCredential: { user: "writer", password: SECRET } },
      { id: "pg2", name: "PG2", engine: "postgres", target: { host: "127.0.0.1", port: 1 }, readCredential: { user: "reader", password: READ_SECRET } },
      { id: "my", name: "Maria", engine: "mariadb", target: { host: "127.0.0.1", port: 1 }, database: "app", readCredential: { user: "reader", password: READ_SECRET } },
      { id: "lite", name: "Lite", engine: "sqlite", target: { path: join(dir, "data", "app.db") } },
    ];
    return c;
  });
  const logs: string[] = [];
  const notifier = new Notifier(() => store.get(), () => {});
  const app = await buildApp({ store, notifier, extraRoutes: [dbRoutes({ now: o.now, drivers: o.drivers, previewTtlMs: o.previewTtlMs })] }, { logger: true, logStream: { write: (l: string) => void logs.push(l) } });
  const responses: string[] = [];
  const call = async (method: "GET" | "POST" | "PATCH" | "DELETE", url: string, payload?: unknown, tok = token) => {
    const res = await app.inject({ method, url, headers: { authorization: `Bearer ${tok}` }, ...(payload === undefined ? {} : { payload: payload as object }) });
    responses.push(res.body);
    const json = (() => {
      try {
        return res.json() as Record<string, any>;
      } catch {
        return {} as Record<string, any>;
      }
    })();
    return { status: res.statusCode, body: json, raw: res.body, headers: res.headers, trailers: (res as unknown as { trailers: Record<string, string> }).trailers };
  };
  const audit = async () => {
    await new Promise((r) => setTimeout(r, 50));
    return readFile(join(dirname(store.path), "audit.jsonl"), "utf8").catch(() => "");
  };
  const cfgDir = dirname(store.path);
  return { dir, cfgDir, app, store, logs, call, responses, audit, other };
}

async function makeSqlite(file: string) {
  const { mkdir } = await import("node:fs/promises");
  await mkdir(dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  db.exec(`CREATE TABLE sales (day TEXT, amount INTEGER, note TEXT);`);
  const ins = db.prepare("INSERT INTO sales VALUES (?, ?, ?)");
  ins.run("2026-01-01", 10, "=1+1");
  ins.run("2026-01-02", -5, 'say "hi", ok');
  ins.run("2026-01-03", 7, "line1\nline2");
  db.close();
}

describe("saved queries", () => {
  it("CRUD, run with chart kinds, 0600 file, read-only path only", async () => {
    const t = await setup();
    await makeSqlite(join(t.dir, "data", "app.db"));
    const bad = await t.call("POST", "/v1/db/queries", { connectionId: "lite", name: "x", sql: "DELETE FROM sales" });
    expect(bad.status).toBe(201); // DML is allowed to be saved: it fails read-only at run time
    expect((await t.call("POST", "/v1/db/queries", { connectionId: "lite", name: "x", sql: "ATTACH DATABASE 'x' AS y" })).body.error).toMatchObject({ code: "agent.db.statementNotAllowed", params: { keyword: "attach" } });
    expect((await t.call("POST", "/v1/db/queries", { connectionId: "nope", name: "x", sql: "SELECT 1" })).body.error.code).toBe("agent.db.connectionNotFound");
    expect((await t.call("POST", "/v1/db/queries", { connectionId: "lite", name: "x", sql: "SELECT 1", chart: { type: "pie" } })).status).toBe(400);

    const created = await t.call("POST", "/v1/db/queries", { connectionId: "lite", name: "Günlük satış", sql: "SELECT day, amount FROM sales WHERE amount > ? ORDER BY day", params: [0], chart: { type: "line", x: "day", y: ["amount"] } });
    expect(created.status).toBe(201);
    const id = created.body.id as string;
    expect(id).toMatch(/^q-[a-f0-9]{12}$/);
    const file = join(t.cfgDir, "db-queries.json");
    expect((await stat(file)).mode & 0o777).toBe(0o600);
    expect(JSON.parse(await readFile(file, "utf8")).queries.map((q: { name: string }) => q.name)).toEqual(["x", "Günlük satış"]);

    expect((await t.call("GET", "/v1/db/queries?connectionId=lite")).body.queries).toHaveLength(2);
    expect((await t.call("GET", "/v1/db/queries?connectionId=pg")).body.queries).toHaveLength(0);
    const run = await t.call("POST", `/v1/db/queries/${id}/run`, {});
    expect(run.status).toBe(200);
    expect(run.body).toMatchObject({
      query: { id, name: "Günlük satış", chart: { type: "line", x: "day", y: ["amount"] } },
      conn: "lite",
      columns: [{ name: "day", kind: "datetime" }, { name: "amount", kind: "number" }],
      rows: [["2026-01-01", 10], ["2026-01-03", 7]],
      rowCount: 2,
    });
    // Param override.
    expect((await t.call("POST", `/v1/db/queries/${id}/run`, { params: [-100] })).body.rowCount).toBe(3);
    // The DML one runs read-only and fails there.
    expect((await t.call("POST", `/v1/db/queries/${bad.body.id}/run`, {})).body.error.code).toBe("agent.db.readOnly");

    const patched = await t.call("PATCH", `/v1/db/queries/${id}`, { name: "Satış", chart: { type: "bar", x: "day", y: ["amount"] } });
    expect(patched.body).toMatchObject({ name: "Satış", chart: { type: "bar" }, sql: created.body.sql });
    expect((await t.call("PATCH", `/v1/db/queries/${id}`, { sql: "PRAGMA writable_schema = 1" })).body.error.code).toBe("agent.db.statementNotAllowed");
    expect((await t.call("DELETE", `/v1/db/queries/${id}`)).body).toEqual({ ok: true });
    expect((await t.call("POST", `/v1/db/queries/${id}/run`, {})).body.error.code).toBe("agent.db.queryNotFound");
    const audit = await t.audit();
    expect(audit).not.toContain("SELECT day");
    expect(audit).toContain(`"sqlSha256":"${sqlSha256("SELECT day, amount FROM sales WHERE amount > ? ORDER BY day")}"`);
    await t.app.close();
  });
});

describe("CSV export", () => {
  it("streams escaped, formula-guarded CSV; 3 per minute", async () => {
    let now = 1_000_000;
    const t = await setup({ now: () => now });
    await makeSqlite(join(t.dir, "data", "app.db"));
    const r = await t.call("POST", "/v1/db/connections/lite/export", { sql: "SELECT * FROM sales ORDER BY day" });
    expect(r.status).toBe(200);
    expect(r.headers["content-type"]).toBe("text/csv; charset=utf-8");
    expect(r.headers["content-disposition"]).toMatch(/^attachment; filename="lite-.*\.csv"$/);
    expect(r.raw).toBe("﻿day,amount,note\r\n2026-01-01,10,'=1+1\r\n2026-01-02,-5,\"say \"\"hi\"\", ok\"\r\n2026-01-03,7,\"line1\nline2\"\r\n");
    expect(r.trailers).toMatchObject({ "x-tiphys-rows": "3", "x-tiphys-truncated": "false" });
    // Errors before the first row are JSON.
    expect((await t.call("POST", "/v1/db/connections/lite/export", { sql: "VACUUM INTO '/tmp/x'" })).body.error.code).toBe("agent.db.statementNotAllowed");
    expect((await t.call("POST", "/v1/db/connections/lite/export", { sql: "SELECT * FROM missing" })).body.error.code).toBe("agent.db.queryFailed");
    expect((await t.call("POST", "/v1/db/connections/lite/export", { sql: "SELECT 1" })).body.error.code).toBe("agent.db.exportRateLimited");
    now += 61_000;
    // Saved query export.
    const q = await t.call("POST", "/v1/db/queries", { connectionId: "lite", name: "n", sql: "SELECT amount FROM sales WHERE amount < ?", params: [0] });
    const e = await t.call("POST", `/v1/db/queries/${q.body.id}/export`, {});
    expect(e.raw).toBe("﻿amount\r\n-5\r\n");
    const audit = await t.audit();
    expect(audit).toMatch(/"path":"\/v1\/db\/connections\/lite\/export","status":200,"detail":\{"conn":"lite","sqlSha256":"[a-f0-9]{64}","rows":3,"truncated":false/);
    expect(audit).not.toContain("SELECT * FROM sales");
    await t.app.close();
  });

  it("caps rows and bytes", async () => {
    let mode: "rows" | "bytes" = "rows";
    const stream = async (_ep: unknown, _sql: string, _p: unknown[], _t: number, sink: RowSink) => {
      sink.columns([{ name: "v", type: "text" }]);
      if (mode === "rows") {
        for (let i = 0; i < LIMITS.exportRows + 50; i++) if (!(await sink.row([i]))) return;
      } else {
        const mb = "x".repeat(1024 * 1024);
        for (let i = 0; i < 80; i++) if (!(await sink.row([mb]))) return;
      }
    };
    const t = await setup({ drivers: { pg: { stream } } });
    const rows = await t.call("POST", "/v1/db/connections/pg/export", { sql: "SELECT v FROM t" });
    expect(rows.raw.split("\r\n").length - 2).toBe(LIMITS.exportRows);
    expect(rows.trailers).toMatchObject({ "x-tiphys-rows": String(LIMITS.exportRows), "x-tiphys-truncated": "true" });
    mode = "bytes";
    const bytes = await t.call("POST", "/v1/db/connections/pg/export", { sql: "SELECT v FROM t" });
    expect(Buffer.byteLength(bytes.raw)).toBeLessThanOrEqual(LIMITS.exportBytes);
    expect(bytes.trailers).toMatchObject({ "x-tiphys-rows": "49", "x-tiphys-truncated": "true" });
    await t.app.close();
  });
});

describe("write mode", () => {
  it("preview → commit with the write credential; log, audit, no secrets", async () => {
    const state: FakePg = { rows: 5, commits: 0 };
    const t = await setup({ drivers: fakePgDrivers(state) });
    const sql = "UPDATE t SET flag = true WHERE id > 15";
    const pre = await t.call("POST", "/v1/db/connections/pg/write/preview", { sql });
    expect(pre.status).toBe(200);
    expect(pre.body).toMatchObject({ conn: "pg", kind: "dml", statement: "update", count: 5, credential: "write", warnings: [], sample: { columns: [{ name: "id" }], rows: [[1], [2]] } });
    expect(pre.body.previewToken).toMatch(/^tpv_/);
    expect(state.lastEp).toMatchObject({ user: "writer", password: SECRET });
    expect(state.commits).toBe(0);
    // confirm must be true.
    expect((await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: pre.body.previewToken })).status).toBe(400);
    const ok = await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: pre.body.previewToken, confirm: true });
    expect(ok.body).toMatchObject({ conn: "pg", committed: true, count: 5 });
    expect(state.commits).toBe(1);
    // Single use.
    expect((await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: pre.body.previewToken, confirm: true })).body.error.code).toBe("agent.preview.invalid");

    const logFile = join(t.cfgDir, "db-writes.jsonl");
    expect((await stat(logFile)).mode & 0o777).toBe(0o600);
    const entries = (await readFile(logFile, "utf8")).trim().split("\n").map((l) => JSON.parse(l));
    expect(entries).toEqual([{ at: expect.any(String), device: "phone", conn: "pg", engine: "postgres", sql, sqlSha256: sqlSha256(sql), count: 5, outcome: "committed" }]);
    const audit = await t.audit();
    expect(audit).toContain(`"detail":{"conn":"pg","sqlSha256":"${sqlSha256(sql)}","rows":5,"write":true}`);
    expect(audit).not.toContain("SET flag");
    for (const text of [t.responses.join("\n"), t.logs.join("\n"), audit, await readFile(logFile, "utf8"), (await t.call("GET", "/v1/db/connections")).raw]) {
      expect(text).not.toContain(SECRET);
      expect(text).not.toContain(READ_SECRET);
    }
    // No write credential: the read one, with a warning.
    const pre2 = await t.call("POST", "/v1/db/connections/pg2/write/preview", { sql });
    expect(pre2.body).toMatchObject({ credential: "read", warnings: ["readCredentialUsed"] });
    expect(state.lastEp).toMatchObject({ user: "reader" });
    await t.app.close();
  });

  it("countChanged: rolled back, logged, 409", async () => {
    const state: FakePg = { rows: 5, commits: 0 };
    const t = await setup({ drivers: fakePgDrivers(state) });
    const pre = await t.call("POST", "/v1/db/connections/pg/write/preview", { sql: "DELETE FROM t WHERE old" });
    state.rows = 6;
    const r = await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: pre.body.previewToken, confirm: true });
    expect(r.status).toBe(409);
    expect(r.body.error).toEqual({ code: "agent.db.countChanged", params: { expected: 5, actual: 6 } });
    expect(state.commits).toBe(0);
    const entries = (await readFile(join(t.cfgDir, "db-writes.jsonl"), "utf8")).trim().split("\n").map((l) => JSON.parse(l));
    expect(entries).toMatchObject([{ outcome: "countChanged", count: 6, expected: 5, sql: "DELETE FROM t WHERE old" }]);
    await t.app.close();
  });

  it("tokens are bound to device, connection, SQL and count, and expire", async () => {
    let now = 5_000_000;
    const state: FakePg = { rows: 2, commits: 0 };
    const t = await setup({ now: () => now, drivers: fakePgDrivers(state) });
    const preview = async (conn = "pg") => (await t.call("POST", `/v1/db/connections/${conn}/write/preview`, { sql: "UPDATE t SET a = 1" })).body.previewToken as string;
    // Other device.
    expect((await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: await preview(), confirm: true }, t.other)).body.error.code).toBe("agent.preview.invalid");
    // Other connection.
    expect((await t.call("POST", "/v1/db/connections/pg2/write/commit", { previewToken: await preview(), confirm: true })).body.error.code).toBe("agent.preview.invalid");
    // Unknown token.
    expect((await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: "tpv_nope", confirm: true })).body.error.code).toBe("agent.preview.invalid");
    // Expired (120 s).
    const old = await preview();
    now += 121_000;
    expect((await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: old, confirm: true })).body.error.code).toBe("agent.preview.invalid");
    expect(state.commits).toBe(0);
    // Fresh one works.
    expect((await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: await preview(), confirm: true })).body.committed).toBe(true);
    await t.app.close();
  });

  it("10 commits per 10 minutes per device; the token is not spent by a 429", async () => {
    let now = 9_000_000;
    const state: FakePg = { rows: 1, commits: 0 };
    const t = await setup({ now: () => now, drivers: fakePgDrivers(state), previewTtlMs: 3_600_000 });
    for (let i = 0; i < 10; i++) {
      now += 1000;
      const tok = (await t.call("POST", "/v1/db/connections/pg/write/preview", { sql: `UPDATE t SET a = ${i}` })).body.previewToken;
      expect((await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: tok, confirm: true })).body.committed).toBe(true);
    }
    now += 61_000;
    const tok = (await t.call("POST", "/v1/db/connections/pg/write/preview", { sql: "UPDATE t SET a = 99" })).body.previewToken;
    const limited = await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: tok, confirm: true });
    expect(limited.status).toBe(429);
    expect(limited.body.error).toEqual({ code: "agent.db.writeRateLimited", params: { perTenMinutes: 10 } });
    // Another device has its own budget.
    const otherTok = (await t.call("POST", "/v1/db/connections/pg/write/preview", { sql: "UPDATE t SET a = 98" }, t.other)).body.previewToken;
    expect((await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: otherTok, confirm: true }, t.other)).body.committed).toBe(true);
    now += 10 * 60_000;
    expect((await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: tok, confirm: true })).body.committed).toBe(true);
    expect(state.commits).toBe(12);
    await t.app.close();
  });

  it("refuses statements outside the write allowlist, MySQL DDL and SQLite", async () => {
    const state: FakePg = { rows: 1, commits: 0 };
    const t = await setup({ drivers: fakePgDrivers(state) });
    const pre = (conn: string, sql: string) => t.call("POST", `/v1/db/connections/${conn}/write/preview`, { sql });
    expect((await pre("pg", "COPY t TO PROGRAM 'id'")).body.error).toEqual({ code: "agent.db.statementNotAllowed", params: { keyword: "copy" } });
    expect((await pre("pg", "DO $$ BEGIN END $$")).body.error.params.keyword).toBe("do");
    expect((await pre("pg", "ALTER SYSTEM SET x = 1")).body.error.params.keyword).toBe("alter system");
    expect((await pre("pg", "INSERT INTO t SELECT pg_read_file('/etc/passwd')")).body.error.params.keyword).toBe("pg_read_file");
    expect((await pre("pg", "UPDATE t SET a = 1; DROP TABLE t")).body.error.code).toBe("agent.db.multipleStatements");
    expect((await pre("my", "CREATE TABLE x (a int)")).body.error).toEqual({ code: "agent.db.ddlNotPreviewable", params: { keyword: "create" } });
    expect((await pre("my", "LOAD DATA INFILE '/etc/passwd' INTO TABLE t")).body.error.code).toBe("agent.db.statementNotAllowed");
    expect((await pre("lite", "DELETE FROM t")).body.error.code).toBe("agent.db.writeUnsupported");
    expect(state.lastEp).toBeUndefined();
    // PG DDL is previewable (count null) and commits.
    const ddl = await pre("pg", "CREATE TABLE w (a int)");
    expect(ddl.body).toMatchObject({ kind: "ddl", statement: "create table", count: null });
    expect(ddl.body).not.toHaveProperty("sample");
    expect((await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: ddl.body.previewToken, confirm: true })).body).toMatchObject({ committed: true, count: null });
    await t.app.close();
  });

  it("read-only role helper: SQL that the write mode accepts; password masked in the write log", async () => {
    const state: FakePg = { rows: 0, commits: 0 };
    const t = await setup({ drivers: fakePgDrivers(state) });
    const h = await t.call("GET", "/v1/db/connections/pg/readonly-role-sql?role=tiphys_ro");
    expect(h.body).toMatchObject({ engine: "postgres", role: "tiphys_ro", runVia: "writeMode", requires: "PostgreSQL 14+" });
    expect(h.body.statements).toHaveLength(1);
    expect(h.body.statements[0]).toContain(`PASSWORD '${h.body.password}'`);
    expect(h.body.statements[0]).toContain("IN ROLE pg_read_all_data");
    expect(checkWriteStatement(h.body.statements[0], "postgres")).toMatchObject({ ok: true, verb: "create role" });
    const pre = await t.call("POST", "/v1/db/connections/pg/write/preview", { sql: h.body.statements[0] });
    await t.call("POST", "/v1/db/connections/pg/write/commit", { previewToken: pre.body.previewToken, confirm: true });
    const log = await readFile(join(t.cfgDir, "db-writes.jsonl"), "utf8");
    expect(log).toContain("PASSWORD '[GİZLİ]'");
    expect(log).not.toContain(h.body.password);
    const my = await t.call("GET", "/v1/db/connections/my/readonly-role-sql");
    expect(my.body).toMatchObject({ engine: "mariadb", role: "tiphys_ro", runVia: "client" });
    expect(my.body.statements[1]).toBe("GRANT SELECT, SHOW VIEW ON `app`.* TO 'tiphys_ro'@'%'");
    expect((await t.call("GET", "/v1/db/connections/pg/readonly-role-sql?role=Bad-Name")).status).toBe(400);
    expect((await t.call("GET", "/v1/db/connections/lite/readonly-role-sql")).body.error.code).toBe("agent.db.writeUnsupported");
    await t.app.close();
  });

  it("write credential: hidden, kept on PATCH, removable, refused on a new target", async () => {
    const t = await setup();
    const get = await t.call("GET", "/v1/db/connections/pg");
    expect(get.body.writeCredential).toEqual({ mode: "password", user: "writer", hasPassword: true });
    expect(get.raw).not.toContain(SECRET);
    const p = await t.call("PATCH", "/v1/db/connections/pg", { writeCredential: { user: "writer2" } });
    expect(p.body.writeCredential).toEqual({ mode: "password", user: "writer2", hasPassword: true });
    expect(t.store.get().databases.connections[0]!.writeCredential).toEqual({ user: "writer2", password: SECRET });
    expect((await t.call("PATCH", "/v1/db/connections/pg", { target: { host: "10.1.1.1" }, readCredential: { user: "reader", password: "new" } })).body.error.code).toBe("agent.db.passwordRequired");
    expect((await t.call("PATCH", "/v1/db/connections/pg", { writeCredential: null })).body.writeCredential).toBe(null);
    expect(t.store.get().databases.connections[0]!.writeCredential).toBeUndefined();
    const created = await t.call("POST", "/v1/db/connections", { id: "my2", name: "M", engine: "mysql", target: { host: "h" }, readCredential: { user: "r", password: READ_SECRET }, writeCredential: { user: "w", password: SECRET } });
    expect(created.status).toBe(201);
    expect(created.raw).not.toContain(SECRET);
    expect((await t.call("POST", "/v1/db/connections", { id: "l2", name: "L", engine: "sqlite", target: { path: "/x" }, writeCredential: { user: "w" } })).status).toBe(400);
    expect(t.logs.join("\n")).not.toContain(SECRET);
    await t.app.close();
  });
});

describe("db-writes.jsonl", () => {
  it("appends with mode 0600 and rotates past 5 MB", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-wlog-"));
    const file = join(dir, "db-writes.jsonl");
    await writeFile(file, "x".repeat(WRITE_LOG_MAX_BYTES), { mode: 0o644 });
    const log = new WriteLog(file);
    await log.append({ at: "t", device: "d", conn: "c", engine: "postgres", sql: "DELETE FROM t", sqlSha256: "h", count: 1, outcome: "committed" });
    expect((await stat(`${file}.1`)).size).toBe(WRITE_LOG_MAX_BYTES);
    expect((await stat(file)).mode & 0o777).toBe(0o600);
    expect(JSON.parse(await readFile(file, "utf8"))).toMatchObject({ sql: "DELETE FROM t", count: 1 });
  });
});
