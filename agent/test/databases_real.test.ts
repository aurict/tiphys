// Real PostgreSQL (PLAN.md §13.2 D-1): a throwaway postgres:16-alpine container with a random password on a random
// free port bound to 127.0.0.1; the API must run reads, refuse multiple statements, writes (read-only), COPY … TO
// PROGRAM, and time out pg_sleep. Needs TIPHYS_REAL=1 and a local docker; the container is removed afterwards. Never
// touches any other database.
import { randomBytes } from "node:crypto";
import { mkdtemp } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { hashToken, newToken } from "../src/auth.ts";
import { ConfigStore } from "../src/config.ts";
import { pgQuery, type PgEndpoint } from "../src/db/pg.ts";
import { dbRoutes } from "../src/db/routes.ts";
import { run } from "../src/exec.ts";
import { Notifier } from "../src/notify.ts";
import { buildApp } from "../src/server.ts";

const real = process.env.TIPHYS_REAL === "1";
const NAME = `tiphys-dbtest-${randomBytes(4).toString("hex")}`;
const PASSWORD = randomBytes(18).toString("base64url");
const READER_PASSWORD = randomBytes(18).toString("base64url");

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

const psql = (sql: string) => run("docker", ["exec", NAME, "psql", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-c", sql], { timeoutMs: 30_000 });

describe.skipIf(!real)("database console against a real PostgreSQL", () => {
  let port = 0;
  let ep: PgEndpoint;
  let app: Awaited<ReturnType<typeof buildApp>>;
  let auth: Record<string, string>;
  const call = async (method: "GET" | "POST", url: string, payload?: object) => {
    const res = await app.inject({ method, url, headers: auth, ...(payload ? { payload } : {}) });
    return { status: res.statusCode, body: res.json() as Record<string, any>, raw: res.body };
  };
  const query = (sql: string, extra: object = {}, conn = "pg") => call("POST", `/v1/db/connections/${conn}/query`, { sql, ...extra });

  beforeAll(async () => {
    port = await freePort();
    await run(
      "docker",
      ["run", "-d", "--rm", "--name", NAME, "-e", `POSTGRES_PASSWORD=${PASSWORD}`, "-p", `127.0.0.1:${port}:5432`, "postgres:16-alpine"],
      { timeoutMs: 300_000 },
    );
    ep = { host: "127.0.0.1", port, user: "postgres", password: PASSWORD, database: "postgres", allowSuperuserReads: true };
    // The image restarts the server once after init: wait until a real query works twice in a row.
    let ok = 0;
    for (let i = 0; i < 120 && ok < 2; i++) {
      const r = await pgQuery(ep, "SELECT 1", [], 1, 2000).then(() => true, () => false);
      ok = r ? ok + 1 : 0;
      await new Promise((r2) => setTimeout(r2, 500));
    }
    expect(ok).toBe(2);
    await psql(
      `CREATE TABLE t (id int PRIMARY KEY, name text NOT NULL, payload bytea, big text);
       INSERT INTO t SELECT g, 'n' || g, CASE WHEN g = 1 THEN decode('deadbeef', 'hex') END, CASE WHEN g = 2 THEN repeat('x', 9000) END FROM generate_series(1, 20) g;
       CREATE INDEX t_name ON t (name);
       ANALYZE t;
       CREATE ROLE reader LOGIN PASSWORD '${READER_PASSWORD}';
       GRANT pg_read_all_data TO reader;`,
    );

    const dir = await mkdtemp(join(tmpdir(), "tiphys-db-real-"));
    const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "test-pc");
    const token = newToken();
    await store.update((c) => {
      c.features.databases = true;
      c.devices.push({ id: "phone", name: "Telefon", tokenHash: hashToken(token), createdAt: new Date().toISOString() });
      c.databases.connections = [
        { id: "pg", name: "Superuser", engine: "postgres", target: { host: "127.0.0.1", port }, database: "postgres", readCredential: { user: "postgres", password: PASSWORD }, allowSuperuserReads: true },
        { id: "su-off", name: "Superuser, not acknowledged", engine: "postgres", target: { host: "127.0.0.1", port }, database: "postgres", readCredential: { user: "postgres", password: PASSWORD } },
        { id: "su-role", name: "Superuser via read role", engine: "postgres", target: { host: "127.0.0.1", port }, database: "postgres", readCredential: { user: "postgres", password: PASSWORD }, readRole: "reader" },
        { id: "reader", name: "Reader", engine: "postgres", target: { host: "127.0.0.1", port }, database: "postgres", readCredential: { user: "reader", password: READER_PASSWORD } },
        { id: "env", name: "From container", engine: "postgres", target: { container: NAME }, readCredential: { fromContainerEnv: true }, allowSuperuserReads: true },
      ];
      return c;
    });
    app = await buildApp({ store, notifier: new Notifier(() => store.get(), () => {}), extraRoutes: [dbRoutes()] });
    auth = { authorization: `Bearer ${token}` };
  }, 400_000);

  afterAll(async () => {
    await app?.close();
    await run("docker", ["rm", "-f", NAME], { allowFail: true, timeoutMs: 60_000 });
  });

  it("test: version, superuser flag, read-only session default", async () => {
    const su = await call("POST", "/v1/db/connections/pg/test");
    expect(su.body).toMatchObject({ ok: true, engine: "postgres", user: "postgres", database: "postgres", superuser: true, readOnlyDefault: true, warnings: ["superuserCredential"] });
    expect(su.body.serverVersion).toMatch(/^16\./);
    const rd = await call("POST", "/v1/db/connections/reader/test");
    expect(rd.body).toMatchObject({ ok: true, user: "reader", superuser: false, warnings: [] });
    // fromContainerEnv: the container's IP (bridge network) and POSTGRES_* env, read now.
    const env = await call("POST", "/v1/db/connections/env/test");
    expect(env.body).toMatchObject({ ok: true, user: "postgres", database: "postgres", superuser: true, warnings: ["superuserCredential"] });
    expect(env.raw).not.toContain(PASSWORD);
  });

  it("§13 review S1: superuser reads need a read role or an acknowledgement; U& and SQL-text functions refused", async () => {
    expect((await call("POST", "/v1/db/connections/su-off/test", {})).body.warnings).toEqual(["superuserCredential", "superuserReadsDisabled"]);
    const off = await query("SELECT 1", {}, "su-off");
    expect(off.status).toBe(403);
    expect(off.body.error.code).toBe("agent.db.superuserReadsDisabled");
    const viaRole = await query("SELECT current_user, session_user, (SELECT count(*) FROM t)", {}, "su-role");
    expect(viaRole.body.rows).toEqual([["reader", "postgres", "20"]]);
    // The read role can't be undone from user SQL.
    expect((await query("SELECT pg_catalog.set_config('role', 'postgres', true)", {}, "su-role")).body.error.code).toBe("agent.db.statementNotAllowed");
    for (const sql of [String.raw`SELECT U&"pg_read_fil\0065"('/etc/passwd')`, `SELECT * FROM ts_stat($q$SELECT to_tsvector(pg_read_file('/etc/passwd'))$q$)`]) {
      expect((await query(sql)).body.error.code, sql).toBe("agent.db.statementNotAllowed");
    }
  });

  it("reads with params, limits and cell caps", async () => {
    const r = await query("SELECT id, name, payload, big, now() AS at, 9007199254740993::int8 AS i8 FROM t WHERE id <= $1 ORDER BY id", { params: [3] });
    expect(r.status).toBe(200);
    expect(r.body.columns.map((c: { name: string; type: string }) => `${c.name}:${c.type}`)).toEqual(["id:int4", "name:text", "payload:bytea", "big:text", "at:timestamptz", "i8:int8"]);
    expect(r.body.rows[0].slice(0, 3)).toEqual([1, "n1", "<4 bayt>"]);
    expect(r.body.rows[1][3]).toHaveLength(4097);
    expect(r.body.rows[0][5]).toBe("9007199254740993");
    expect(r.body.cellsTruncated).toBe(1);
    expect((await query("SELECT * FROM t", { limit: 5 })).body).toMatchObject({ rowCount: 5, truncated: true });
    expect((await query("SELECT g FROM generate_series(1, 6000) g")).body).toMatchObject({ rowCount: 500, truncated: true });
    expect((await query("SHOW transaction_read_only")).body.rows).toEqual([["on"]]);
  });

  it("refuses multiple statements, in the agent and on the server", async () => {
    const r = await query("SELECT 1; DROP TABLE t");
    expect(r.body.error.code).toBe("agent.db.multipleStatements");
    // The driver alone (no agent-side check): extended protocol, the server refuses.
    await expect(pgQuery(ep, "SELECT 1; DROP TABLE t", [], 10, 5000)).rejects.toMatchObject({ code: "agent.db.multipleStatements" });
    expect((await psql("SELECT count(*) FROM t")).stdout).toContain("20");
  });

  it("writes fail: read-only transaction", async () => {
    for (const sql of ["INSERT INTO t VALUES (100, 'x')", "UPDATE t SET name = 'y'", "WITH d AS (DELETE FROM t RETURNING *) SELECT count(*) FROM d"]) {
      const r = await query(sql);
      expect(r.status, sql).toBe(409);
      expect(r.body.error.code).toBe("agent.db.readOnly");
    }
    // Even trying to switch the transaction to read-write inside a statement.
    expect((await query("SELECT set_config('transaction_read_only', 'off', true)")).body.error).toBeDefined();
    expect((await psql("SELECT count(*) FROM t")).stdout).toContain("20");
  });

  it("COPY … TO PROGRAM is refused", async () => {
    const r = await query("COPY (SELECT 1) TO PROGRAM 'touch /tmp/tiphys-probe'");
    expect(r.body.error).toEqual({ code: "agent.db.statementNotAllowed", params: { keyword: "copy" } });
    expect((await run("docker", ["exec", NAME, "test", "-e", "/tmp/tiphys-probe"], { allowFail: true })).code).toBe(1);
  });

  it("pg_sleep times out at the limit", async () => {
    let started = Date.now();
    const r = await query("SELECT pg_sleep(100)", { timeoutMs: 2000 });
    expect(r.body.error.code).toBe("agent.db.timeout");
    expect(Date.now() - started).toBeLessThan(6000);
    // Turning the timeout off inside the statement is refused up front: set_config is denylisted (it could also reset
    // the read role, §13 review S1).
    const r2 = await query("SELECT set_config('statement_timeout', '0', true), pg_sleep(100)", { timeoutMs: 2000 });
    expect(r2.body.error.code).toBe("agent.db.statementNotAllowed");
  }, 30_000);

  it("schema and preview", async () => {
    const s = await call("GET", "/v1/db/connections/reader/schema");
    expect(s.status).toBe(200);
    const pub = s.body.schemas.find((x: { name: string }) => x.name === "public");
    const t = pub.tables.find((x: { name: string }) => x.name === "t");
    expect(t).toMatchObject({ kind: "table", estimatedRows: 20 });
    expect(t.columns.map((c: { name: string; type: string; primaryKey: boolean; nullable: boolean }) => [c.name, c.type, c.primaryKey, c.nullable])).toEqual([
      ["id", "integer", true, false],
      ["name", "text", false, false],
      ["payload", "bytea", false, true],
      ["big", "text", false, true],
    ]);
    expect(t.indexes.map((i: { name: string; primary: boolean }) => [i.name, i.primary])).toEqual([["t_name", false], ["t_pkey", true]]);
    const p = await call("GET", "/v1/db/connections/reader/tables/public/t/preview?limit=3");
    expect(p.body).toMatchObject({ rowCount: 3, truncated: true });
    for (const bad of ['t"; DROP TABLE t; --', "t; DROP TABLE t", "pg_authid"]) {
      expect((await call("GET", `/v1/db/connections/reader/tables/public/${encodeURIComponent(bad)}/preview`)).body.error.code).toBe("agent.db.tableNotFound");
    }
    expect((await psql("SELECT count(*) FROM t")).stdout).toContain("20");
  });
});
