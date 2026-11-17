// Real databases for D-2 + D-3 (PLAN.md §13.2): throwaway postgres:16-alpine and mariadb:11 containers with random
// names and passwords on random free ports bound to 127.0.0.1. PostgreSQL: write preview → commit, countChanged when
// another session changes rows in between, DDL inside the transaction, the read-only role helper, saved query + CSV.
// MariaDB: read-only enforced, INTO OUTFILE refused, multiple statements refused, max_statement_time, schema/preview,
// DDL not previewable, DML write flow, non-transactional tables refused, fromContainerEnv. Needs TIPHYS_REAL=1 and a
// local docker; both containers are removed afterwards. Never touches any other database.
import { randomBytes } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { hashToken, newToken } from "../src/auth.ts";
import { ConfigStore, type DbConnection } from "../src/config.ts";
import { mysqlQuery, type MyEndpoint } from "../src/db/mysql.ts";
import { pgQuery, type PgEndpoint } from "../src/db/pg.ts";
import { dbRoutes } from "../src/db/routes.ts";
import { run } from "../src/exec.ts";
import { Notifier } from "../src/notify.ts";
import { buildApp } from "../src/server.ts";

const real = process.env.TIPHYS_REAL === "1";
const tag = randomBytes(4).toString("hex");

function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const s = createServer();
    s.once("error", reject);
    s.listen(0, "127.0.0.1", () => {
      const port = (s.address() as { port: number }).port;
      s.close(() => resolve(port));
    });
  });
}

async function apiFor(connections: DbConnection[]) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-db23-real-"));
  const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "test-pc");
  const token = newToken();
  await store.update((c) => {
    c.features.databases = true;
    c.devices.push({ id: "phone", name: "Telefon", tokenHash: hashToken(token), createdAt: new Date().toISOString() });
    c.databases.connections = connections;
    return c;
  });
  const app = await buildApp({ store, notifier: new Notifier(() => store.get(), () => {}), extraRoutes: [dbRoutes()] });
  const call = async (method: "GET" | "POST" | "PATCH", url: string, payload?: object) => {
    const res = await app.inject({ method, url, headers: { authorization: `Bearer ${token}` }, ...(payload ? { payload } : {}) });
    let body: Record<string, any> = {};
    try {
      body = res.json();
    } catch {
      // CSV
    }
    return { status: res.statusCode, body, raw: res.body };
  };
  return { app, call, store };
}

async function waitReady(probe: () => Promise<unknown>) {
  let ok = 0;
  for (let i = 0; i < 180 && ok < 2; i++) {
    ok = (await probe().then(() => true, () => false)) ? ok + 1 : 0;
    await new Promise((r) => setTimeout(r, 500));
  }
  expect(ok).toBe(2);
}

// --- PostgreSQL -------------------------------------------------------------------------------------------------------

describe.skipIf(!real)("D-2/D-3 against a real PostgreSQL", () => {
  const NAME = `tiphys-dbtest-pg-${tag}`;
  const PASSWORD = randomBytes(18).toString("base64url");
  let api: Awaited<ReturnType<typeof apiFor>>;
  let port = 0;
  const psql = (sql: string) => run("docker", ["exec", NAME, "psql", "-At", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-c", sql], { timeoutMs: 30_000 });
  const preview = (sql: string, conn = "pg", extra: object = {}) => api.call("POST", `/v1/db/connections/${conn}/write/preview`, { sql, ...extra });
  const commit = (token: string, conn = "pg") => api.call("POST", `/v1/db/connections/${conn}/write/commit`, { previewToken: token, confirm: true });

  beforeAll(async () => {
    port = await freePort();
    await run("docker", ["run", "-d", "--rm", "--name", NAME, "-e", `POSTGRES_PASSWORD=${PASSWORD}`, "-p", `127.0.0.1:${port}:5432`, "postgres:16-alpine"], { timeoutMs: 300_000 });
    const ep: PgEndpoint = { host: "127.0.0.1", port, user: "postgres", password: PASSWORD, database: "postgres" };
    await waitReady(() => pgQuery(ep, "SELECT 1", [], 1, 2000));
    await psql(`CREATE TABLE w (id int PRIMARY KEY, name text NOT NULL, amount numeric(10,2));
                INSERT INTO w SELECT g, 'n' || g, g * 1.5 FROM generate_series(1, 20) g;`);
    api = await apiFor([{ id: "pg", name: "Superuser", engine: "postgres", target: { host: "127.0.0.1", port }, database: "postgres", readCredential: { user: "postgres", password: PASSWORD } }]);
  }, 400_000);

  afterAll(async () => {
    await api?.app.close();
    await run("docker", ["rm", "-f", NAME], { allowFail: true, timeoutMs: 60_000 });
  });

  it("preview counts and samples without changing data; commit applies", async () => {
    const pre = await preview("UPDATE w SET name = 'changed' WHERE id > 15");
    expect(pre.status).toBe(200);
    expect(pre.body).toMatchObject({ kind: "dml", statement: "update", count: 5, credential: "read", warnings: ["readCredentialUsed", "superuserCredential"] });
    expect(pre.body.sample.columns.map((c: { name: string }) => c.name)).toEqual(["id", "name", "amount"]);
    expect(pre.body.sample.rows).toHaveLength(5);
    expect(pre.body.sample.rows[0][1]).toBe("changed");
    expect((await psql("SELECT count(*) FROM w WHERE name = 'changed'")).stdout.trim()).toBe("0");
    const ok = await commit(pre.body.previewToken);
    expect(ok.body).toMatchObject({ committed: true, count: 5 });
    expect((await psql("SELECT count(*) FROM w WHERE name = 'changed'")).stdout.trim()).toBe("5");
    // Only 20 sample rows, but the full count.
    const big = await preview("UPDATE w SET amount = amount");
    expect(big.body).toMatchObject({ count: 20 });
    expect(big.body.sample.rows).toHaveLength(20);
    // RETURNING given by the user; INSERT … ON CONFLICT; MERGE (no sample on PG 16, count only).
    expect((await preview("DELETE FROM w WHERE id = 1 RETURNING id")).body).toMatchObject({ count: 1, sample: { columns: [{ name: "id" }], rows: [[1]] } });
    expect((await preview("INSERT INTO w VALUES (1, 'dup', 0) ON CONFLICT (id) DO NOTHING")).body).toMatchObject({ count: 0 });
    const merge = await preview("MERGE INTO w USING (SELECT 2 AS id) s ON w.id = s.id WHEN MATCHED THEN UPDATE SET name = 'm'");
    expect(merge.body).toMatchObject({ count: 1 });
    expect(merge.body).not.toHaveProperty("sample");
    expect((await psql("SELECT count(*) FROM w")).stdout.trim()).toBe("20");
  });

  it("countChanged when another session changes rows in between", async () => {
    const pre = await preview("DELETE FROM w WHERE id > 10");
    expect(pre.body.count).toBe(10);
    await psql("INSERT INTO w VALUES (21, 'late', 1)");
    const r = await commit(pre.body.previewToken);
    expect(r.status).toBe(409);
    expect(r.body.error).toEqual({ code: "agent.db.countChanged", params: { expected: 10, actual: 11 } });
    expect((await psql("SELECT count(*) FROM w")).stdout.trim()).toBe("21");
  });

  it("DDL runs inside the transaction: preview leaves nothing, commit creates", async () => {
    const pre = await preview("CREATE TABLE ddl_t (a int)");
    expect(pre.body).toMatchObject({ kind: "ddl", statement: "create table", count: null });
    expect((await psql("SELECT to_regclass('public.ddl_t') IS NULL")).stdout.trim()).toBe("t");
    const drop = await preview("DROP TABLE w");
    expect(drop.body.kind).toBe("ddl");
    expect((await psql("SELECT to_regclass('public.w') IS NOT NULL")).stdout.trim()).toBe("t");
    expect((await commit(pre.body.previewToken)).body).toMatchObject({ committed: true, count: null });
    expect((await psql("SELECT to_regclass('public.ddl_t') IS NOT NULL")).stdout.trim()).toBe("t");
  });

  it("refuses COPY TO PROGRAM and file functions; statement timeout", async () => {
    expect((await preview("COPY w TO PROGRAM 'touch /tmp/tiphys-probe'")).body.error.code).toBe("agent.db.statementNotAllowed");
    expect((await preview("INSERT INTO w SELECT 99, pg_read_file('/etc/passwd'), 0")).body.error.params.keyword).toBe("pg_read_file");
    expect((await run("docker", ["exec", NAME, "test", "-e", "/tmp/tiphys-probe"], { allowFail: true })).code).toBe(1);
    const started = Date.now();
    const slow = await preview("UPDATE w SET name = pg_sleep(30)::text WHERE id = 2", "pg", { timeoutMs: 1500 });
    expect(slow.body.error.code).toBe("agent.db.timeout");
    expect(Date.now() - started).toBeLessThan(8000);
  }, 30_000);

  it("read-only role helper: created through write mode, reads but can't write", async () => {
    const h = await api.call("GET", "/v1/db/connections/pg/readonly-role-sql?role=tiphys_ro");
    const pre = await preview(h.body.statements[0]);
    expect(pre.body).toMatchObject({ kind: "ddl", statement: "create role" });
    expect((await commit(pre.body.previewToken)).body.committed).toBe(true);
    await api.call("POST", "/v1/db/connections", { id: "ro", name: "RO", engine: "postgres", target: { host: "127.0.0.1", port }, database: "postgres", readCredential: { user: "tiphys_ro", password: h.body.password }, writeCredential: { user: "tiphys_ro", password: h.body.password } });
    const t = await api.call("POST", "/v1/db/connections/ro/test");
    expect(t.body).toMatchObject({ ok: true, user: "tiphys_ro", superuser: false, warnings: [] });
    expect((await api.call("POST", "/v1/db/connections/ro/query", { sql: "SELECT count(*) FROM w" })).body.rows).toEqual([["21"]]);
    expect((await preview("UPDATE w SET name = 'x'", "ro")).body.error.code).toBe("agent.db.permissionDenied");
  });

  it("saved query run (chart kinds) and CSV export", async () => {
    const q = await api.call("POST", "/v1/db/queries", { connectionId: "pg", name: "Tutar", sql: "SELECT id, amount, now()::date AS day FROM w WHERE id <= $1 ORDER BY id", params: [3], chart: { type: "bar", x: "id", y: ["amount"] } });
    const r = await api.call("POST", `/v1/db/queries/${q.body.id}/run`, {});
    expect(r.body.columns.map((c: { name: string; kind: string }) => `${c.name}:${c.kind}`)).toEqual(["id:number", "amount:number", "day:datetime"]);
    expect(r.body.rows[0].slice(0, 2)).toEqual([1, "1.50"]);
    const csv = await api.call("POST", "/v1/db/connections/pg/export", { sql: "SELECT id, name FROM w WHERE id IN (2, 3) ORDER BY id" });
    expect(csv.raw).toBe("﻿id,name\r\n2,n2\r\n3,n3\r\n");
  });
});

// --- MariaDB ------------------------------------------------------------------------------------------------------------

describe.skipIf(!real)("D-2/D-3 against a real MariaDB", () => {
  const NAME = `tiphys-dbtest-maria-${tag}`;
  const PASSWORD = randomBytes(18).toString("base64url");
  let api: Awaited<ReturnType<typeof apiFor>>;
  let ep: MyEndpoint;
  const sh = (sql: string) => run("docker", ["exec", "-e", `MYSQL_PWD=${PASSWORD}`, NAME, "mariadb", "-uroot", "-N", "-B", "app", "-e", sql], { timeoutMs: 30_000 });
  const query = (sql: string, extra: object = {}, conn = "maria") => api.call("POST", `/v1/db/connections/${conn}/query`, { sql, ...extra });
  const preview = (sql: string) => api.call("POST", "/v1/db/connections/maria/write/preview", { sql });

  beforeAll(async () => {
    const port = await freePort();
    await run(
      "docker",
      ["run", "-d", "--rm", "--name", NAME, "-e", `MARIADB_ROOT_PASSWORD=${PASSWORD}`, "-e", "MARIADB_DATABASE=app", "-p", `127.0.0.1:${port}:3306`, "mariadb:11"],
      { timeoutMs: 300_000 },
    );
    ep = { host: "127.0.0.1", port, user: "root", password: PASSWORD, database: "app" };
    await waitReady(() => mysqlQuery(ep, "SELECT 1", [], 1, 2000));
    await sh(`CREATE TABLE t (id INT PRIMARY KEY, name VARCHAR(50) NOT NULL, big BIGINT, price DECIMAL(10,2), data BLOB, at DATETIME) ENGINE=InnoDB;
              INSERT INTO t SELECT seq, CONCAT('n', seq), 9007199254740993, seq * 1.25, IF(seq = 1, X'DEADBEEF', NULL), '2026-01-02 03:04:05' FROM seq_1_to_20;
              CREATE INDEX t_name ON t (name);`);
    api = await apiFor([
      { id: "maria", name: "Root", engine: "mariadb", target: { host: "127.0.0.1", port }, database: "app", readCredential: { user: "root", password: PASSWORD } },
      { id: "env", name: "Env", engine: "mariadb", target: { container: NAME }, readCredential: { fromContainerEnv: true } },
    ]);
  }, 400_000);

  afterAll(async () => {
    await api?.app.close();
    await run("docker", ["rm", "-f", NAME], { allowFail: true, timeoutMs: 60_000 });
  });

  it("test: flavor, privileges, read-only session; fromContainerEnv through the container IP", async () => {
    const r = await api.call("POST", "/v1/db/connections/maria/test");
    expect(r.body).toMatchObject({ ok: true, engine: "mariadb", flavor: "mariadb", database: "app", superuser: true, readOnlyDefault: true, warnings: ["superuserCredential"] });
    expect(r.body.serverVersion).toMatch(/^11\..*MariaDB/);
    const env = await api.call("POST", "/v1/db/connections/env/test");
    expect(env.body).toMatchObject({ ok: true, flavor: "mariadb", database: "app", warnings: ["superuserCredential"] });
    expect(env.raw).not.toContain(PASSWORD);
  });

  it("reads with params and types", async () => {
    const r = await query("SELECT id, name, big, price, data, at FROM t WHERE id <= ? ORDER BY id", { params: [2] });
    expect(r.status).toBe(200);
    expect(r.body.columns.map((c: { name: string; type: string }) => `${c.name}:${c.type}`)).toEqual(["id:int", "name:varchar", "big:bigint", "price:decimal", "data:blob", "at:datetime"]);
    expect(r.body.rows[0]).toEqual([1, "n1", "9007199254740993", "1.25", "<4 bayt>", "2026-01-02 03:04:05"]);
    expect((await query("SELECT * FROM t", { limit: 5 })).body).toMatchObject({ rowCount: 5, truncated: true });
    expect((await query("SELECT @@SESSION.transaction_read_only")).body.rows).toEqual([["1"]]);
  });

  it("read-only is enforced by the server", async () => {
    for (const sql of ["INSERT INTO t (id, name) VALUES (100, 'x')", "UPDATE t SET name = 'y'", "DELETE FROM t"]) {
      const r = await query(sql);
      expect(r.status, sql).toBe(409);
      expect(r.body.error.code).toBe("agent.db.readOnly");
    }
    expect((await sh("SELECT COUNT(*) FROM t WHERE name LIKE 'n%'")).stdout.trim()).toBe("20");
  });

  it("INTO OUTFILE and multiple statements are refused", async () => {
    const out = `/tmp/tiphys-probe-${tag}`;
    expect((await query(`SELECT * FROM t INTO OUTFILE '${out}'`)).body.error).toEqual({ code: "agent.db.statementNotAllowed", params: { keyword: "outfile" } });
    expect((await query(`SELECT 1 /*! INTO OUTFILE '${out}' */`)).body.error.params.keyword).toBe("/*!");
    expect((await run("docker", ["exec", NAME, "sh", "-c", `ls ${out} /var/lib/mysql/app/tiphys-probe-${tag} 2>/dev/null | wc -l`])).stdout.trim()).toBe("0");
    expect((await query("SELECT 1; DROP TABLE t")).body.error.code).toBe("agent.db.multipleStatements");
    // The driver alone (no agent check): prepared statements and no MULTI_STATEMENTS → the server refuses.
    await expect(mysqlQuery(ep, "SELECT 1; DROP TABLE t", [], 10, 5000)).rejects.toMatchObject({ code: "agent.db.queryFailed" });
    expect((await sh("SELECT COUNT(*) FROM t")).stdout.trim()).toBe("20");
  });

  it("max_statement_time stops a long statement", async () => {
    const started = Date.now();
    const r2 = await query("SELECT COUNT(*) FROM seq_1_to_1000000000 a JOIN seq_1_to_1000 b ON a.seq % 7 = b.seq", { timeoutMs: 2000 });
    expect(r2.body.error?.code, JSON.stringify(r2.body)).toBe("agent.db.timeout");
    expect(Date.now() - started).toBeLessThan(8000);
  }, 30_000);

  it("schema and preview with backtick quoting", async () => {
    const s = await api.call("GET", "/v1/db/connections/maria/schema");
    const app = s.body.schemas.find((x: { name: string }) => x.name === "app");
    const t = app.tables.find((x: { name: string }) => x.name === "t");
    expect(t.columns.map((c: { name: string; primaryKey: boolean }) => [c.name, c.primaryKey]).slice(0, 2)).toEqual([["id", true], ["name", false]]);
    expect(t.indexes.map((i: { name: string; primary: boolean; definition: string }) => [i.name, i.primary, i.definition])).toEqual([["PRIMARY", true, "(id)"], ["t_name", false, "(name)"]]);
    expect((await api.call("GET", "/v1/db/connections/maria/tables/app/t/preview?limit=3")).body).toMatchObject({ rowCount: 3, truncated: true });
    for (const bad of ["t`; DROP TABLE t; --", "user"]) {
      expect((await api.call("GET", `/v1/db/connections/maria/tables/app/${encodeURIComponent(bad)}/preview`)).body.error.code).toBe("agent.db.tableNotFound");
    }
  });

  it("write: DDL is not previewable; DML preview → commit; non-transactional tables refused", async () => {
    const ddl = await preview("CREATE TABLE made (a INT)");
    expect(ddl.body.error).toEqual({ code: "agent.db.ddlNotPreviewable", params: { keyword: "create" } });
    expect((await sh("SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_NAME = 'made'")).stdout.trim()).toBe("0");
    const pre = await preview("UPDATE t SET name = 'w' WHERE id > 17");
    expect(pre.body).toMatchObject({ kind: "dml", count: 3, credential: "read", warnings: ["readCredentialUsed", "superuserCredential"] });
    expect((await sh("SELECT COUNT(*) FROM t WHERE name = 'w'")).stdout.trim()).toBe("0");
    expect((await api.call("POST", "/v1/db/connections/maria/write/commit", { previewToken: pre.body.previewToken, confirm: true })).body).toMatchObject({ committed: true, count: 3 });
    expect((await sh("SELECT COUNT(*) FROM t WHERE name = 'w'")).stdout.trim()).toBe("3");
    // countChanged on MariaDB too.
    const pre2 = await preview("DELETE FROM t WHERE id > 18");
    await sh("INSERT INTO t (id, name) VALUES (30, 'late')");
    const r = await api.call("POST", "/v1/db/connections/maria/write/commit", { previewToken: pre2.body.previewToken, confirm: true });
    expect(r.body.error).toEqual({ code: "agent.db.countChanged", params: { expected: 2, actual: 3 } });
    expect((await sh("SELECT COUNT(*) FROM t")).stdout.trim()).toBe("21");
    // A MyISAM table anywhere: a preview could not be rolled back there, so the write mode refuses.
    await sh("CREATE TABLE logs (a INT) ENGINE=MyISAM");
    const nt = await preview("UPDATE t SET name = 'z' WHERE id = 1");
    expect(nt.body.error).toEqual({ code: "agent.db.nonTransactionalTables", params: { tables: ["app.logs (MyISAM)"], more: false } });
    await sh("DROP TABLE logs");
    // CSV export.
    const csv = await api.call("POST", "/v1/db/connections/maria/export", { sql: "SELECT id, name FROM t WHERE id IN (1, 2) ORDER BY id" });
    expect(csv.raw).toBe("﻿id,name\r\n1,n1\r\n2,n2\r\n");
  });
});
