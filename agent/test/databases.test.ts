// Database console, PLAN.md §13.2 D-1 (D-2/D-3 in databases_d23.test.ts): statement lexer and allowlist, identifier handling, cell caps, credential
// redaction (GET, errors, logs, audit), discovery with a fake docker, fromContainerEnv (never stored), SQLite full flow
// on a temp file (read-only), limits/truncation, timeout, rate and concurrency limits, schema shape.
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { DatabaseSync } from "node:sqlite";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { hashToken, newServiceToken, newToken } from "../src/auth.ts";
import { ConfigStore } from "../src/config.ts";
import { discoveredFromInspect, engineOfImage, parseImage, resolveContainer, type Runner } from "../src/db/docker.ts";
import { pgError } from "../src/db/pg.ts";
import { dbRoutes, sqlSha256 } from "../src/db/routes.ts";
import { QUERIES_PER_MIN } from "../src/db/service.ts";
import { buildSchema, checkReadStatement, firstKeyword, quoteIdent, statements, toCell } from "../src/db/sql.ts";
import { AppError } from "../src/errors.ts";
import { Notifier } from "../src/notify.ts";
import { buildApp } from "../src/server.ts";

const SECRET = "Sup3r-S3cret-pw-Q9";
const ENV_SECRET = "envOnly-pw-7Zx2kQ";

// --- Lexer, allowlist, identifiers, cells ---------------------------------------------------------------------------

describe("statement lexer", () => {
  it("splits on semicolons outside quotes, comments and dollar quotes", () => {
    expect(statements("SELECT 1", "postgres")).toEqual(["SELECT 1"]);
    expect(statements("SELECT 1;", "postgres")).toEqual(["SELECT 1"]);
    expect(statements("SELECT 1; -- done\n", "postgres")).toHaveLength(1);
    expect(statements("SELECT 1; /* c */ ;;", "postgres")).toHaveLength(1);
    expect(statements("SELECT 1; DROP TABLE t", "postgres")).toHaveLength(2);
    expect(statements("SELECT ';' AS a, \"x;y\" FROM t", "postgres")).toHaveLength(1);
    expect(statements("SELECT 'it''s; fine'", "postgres")).toHaveLength(1);
    expect(statements("SELECT E'a\\'; DROP TABLE t; --'", "postgres")).toHaveLength(1);
    // Without E the backslash is literal: the quote ends at \' and what follows is a second statement.
    expect(statements("SELECT 'a\\'; DROP TABLE t", "postgres")).toHaveLength(2);
    expect(statements("SELECT $$;$$, $tag$ ; $$ ; $tag$", "postgres")).toHaveLength(1);
    expect(statements("SELECT $1; DROP TABLE t", "postgres")).toHaveLength(2);
    expect(statements("SELECT 1 /* outer /* inner; */ still; */", "postgres")).toHaveLength(1);
    // SQLite block comments don't nest: the first */ ends it.
    expect(statements("SELECT 1 /* a /* b */ ; DROP TABLE t", "sqlite")).toHaveLength(2);
    expect(statements("SELECT [a;b], `c;d` FROM t", "sqlite")).toHaveLength(1);
    expect(statements("  ;  -- only a comment", "sqlite")).toHaveLength(0);
  });

  it("finds the first keyword past comments and parentheses", () => {
    expect(firstKeyword("  /* x */ -- y\n ((SELECT 1))")).toBe("select");
    expect(firstKeyword("WITH a AS (SELECT 1) SELECT * FROM a")).toBe("with");
    expect(firstKeyword("/* unterminated")).toBe("");
  });

  it("allows reads (and DML, which the database refuses) and nothing else", () => {
    for (const sql of ["SELECT 1", "with x as (select 1) select * from x", "VALUES (1)", "TABLE t", "EXPLAIN SELECT 1", "SHOW server_version", "INSERT INTO t VALUES (1)"]) {
      expect(checkReadStatement(sql, "postgres")).toEqual({ ok: true });
    }
    const refused = [
      ["COPY (SELECT 1) TO PROGRAM 'id'", "copy"],
      ["DO $$ BEGIN END $$", "do"],
      ["LOAD 'x'", "load"],
      ["CALL p()", "call"],
      ["SET ROLE postgres", "set"],
      ["CREATE TABLE x (a int)", "create"],
      ["DROP TABLE t", "drop"],
      ["ALTER SYSTEM SET x = 1", "alter"],
      ["VACUUM", "vacuum"],
      ["BEGIN", "begin"],
      ["COMMIT", "commit"],
    ] as const;
    for (const [sql, kw] of refused) expect(checkReadStatement(sql, "postgres")).toMatchObject({ ok: false, code: "agent.db.statementNotAllowed", keyword: kw });
    for (const sql of ["ATTACH DATABASE '/tmp/x' AS x", "VACUUM INTO '/tmp/copy.db'", "PRAGMA writable_schema = 1", "SHOW x", "TABLE t"]) {
      expect(checkReadStatement(sql, "sqlite")).toMatchObject({ ok: false, code: "agent.db.statementNotAllowed" });
    }
    expect(checkReadStatement("SELECT 1; DROP TABLE t", "postgres")).toMatchObject({ ok: false, code: "agent.db.multipleStatements", count: 2 });
    expect(checkReadStatement(" -- nothing\n ; ", "postgres")).toMatchObject({ ok: false, code: "agent.db.emptyStatement" });
  });

  it("quotes identifiers with doubled quotes", () => {
    expect(quoteIdent("users")).toBe('"users"');
    expect(quoteIdent('a"; DROP TABLE t; --')).toBe('"a""; DROP TABLE t; --"');
    expect(() => quoteIdent("a\0b")).toThrow();
  });

  it("converts cells: bytes, long text, bigint, dates, json", () => {
    expect(toCell(Buffer.from("abc")).value).toBe("<3 bayt>");
    expect(toCell(new Uint8Array(10)).value).toBe("<10 bayt>");
    const long = toCell("ğ".repeat(5000));
    expect(long.cut).toBe(true);
    expect(Buffer.byteLength(String(long.value))).toBeLessThanOrEqual(4096 + 3);
    expect(String(long.value).endsWith("…")).toBe(true);
    expect(String(long.value)).not.toContain("�");
    expect(toCell(12n).value).toBe(12);
    expect(toCell(2n ** 70n).value).toBe("1180591620717411303424");
    expect(toCell(new Date("2026-01-02T03:04:05Z")).value).toBe("2026-01-02T03:04:05.000Z");
    expect(toCell({ a: [1, 2] }).value).toBe('{"a":[1,2]}');
    expect(toCell(Number.NaN).value).toBe("NaN");
    expect(toCell(null).value).toBe(null);
  });

  it("nests catalog rows into schemas", () => {
    const s = buildSchema(
      [{ schema: "public", table: "t", kind: "table", estimatedRows: 3 }],
      [{ schema: "public", table: "t", name: "id", type: "integer", nullable: false, default: null, primaryKey: true }, { schema: "public", table: "other", name: "x", type: "int", nullable: true, default: null, primaryKey: false }],
      [{ schema: "public", table: "t", name: "t_pkey", unique: true, primary: true, definition: "CREATE UNIQUE INDEX …" }],
      false,
    );
    expect(s).toEqual({
      schemas: [{ name: "public", tables: [{ name: "t", kind: "table", estimatedRows: 3, columns: [{ name: "id", type: "integer", nullable: false, default: null, primaryKey: true }], indexes: [{ name: "t_pkey", unique: true, primary: true, definition: "CREATE UNIQUE INDEX …" }] }] }],
      truncated: false,
    });
  });

  it("maps driver errors to codes and redacts their text", () => {
    expect(pgError({ code: "57014", message: "canceling statement due to statement timeout" })).toMatchObject({ code: "agent.db.timeout", status: 504 });
    expect(pgError({ code: "25006", message: "cannot execute INSERT in a read-only transaction" })).toMatchObject({ code: "agent.db.readOnly" });
    expect(pgError({ code: "42601", message: "cannot insert multiple commands into a prepared statement" })).toMatchObject({ code: "agent.db.multipleStatements" });
    expect(pgError({ code: "28P01", message: `password authentication failed for user "x"` }).params).toEqual({ sqlState: "28P01" });
    const e = pgError({ code: "22P02", message: `invalid input: postgres://app:${SECRET}@db/x password=${SECRET}` });
    expect(e.code).toBe("agent.db.queryFailed");
    expect(JSON.stringify(e.params)).not.toContain(SECRET);
    expect(pgError({ code: "ECONNREFUSED", message: "connect ECONNREFUSED" })).toMatchObject({ code: "agent.db.unreachable" });
  });
});

// --- Discovery and container resolution (fake docker) ---------------------------------------------------------------

const INSPECT = [
  {
    Id: "a".repeat(64),
    Name: "/app-db-1",
    Config: { Image: "postgres:16-alpine", Env: [`POSTGRES_PASSWORD=${ENV_SECRET}`, "POSTGRES_USER=app", "POSTGRES_DB=appdb", "PATH=/usr/bin"], Labels: { "com.docker.compose.project": "app" } },
    State: { Status: "running" },
    NetworkSettings: { Networks: { app_default: { IPAddress: "127.0.0.1" }, other: { IPAddress: "" } }, Ports: { "5432/tcp": null } },
  },
  {
    Id: "b".repeat(64),
    Name: "/maria",
    Config: { Image: "docker.io/library/mariadb:11@sha256:" + "c".repeat(64), Env: ["MARIADB_ROOT_PASSWORD=x"] },
    State: { Status: "running" },
    NetworkSettings: { Networks: { bridge: { IPAddress: "172.17.0.3" } }, Ports: { "3306/tcp": [{ HostIp: "127.0.0.1", HostPort: "13306" }] } },
  },
  { Id: "d".repeat(64), Name: "/cache", Config: { Image: "valkey/valkey:8", Env: [] }, State: { Status: "running" }, NetworkSettings: { Networks: {} } },
  { Id: "e".repeat(64), Name: "/web", Config: { Image: "nginx:1.27", Env: ["SECRET_KEY=zzz"] }, State: { Status: "running" }, NetworkSettings: { Networks: {} } },
  { Id: "f".repeat(64), Name: "/gis", Config: { Image: "ghcr.io/x/postgis:16-3.4", Env: ["POSTGRES_PASSWORD_FILE=/run/secrets/pw"] }, State: { Status: "running" }, NetworkSettings: { Networks: { n: { IPAddress: "10.0.0.2" } } } },
];

function fakeDocker(calls: string[][] = []): Runner {
  return (async (cmd: string, args: string[]) => {
    calls.push([cmd, ...args]);
    if (cmd !== "docker") throw new Error("unexpected " + cmd);
    if (args[0] === "ps") return { stdout: INSPECT.map((c) => c.Id).join("\n") + "\n", stderr: "", code: 0 };
    if (args[0] === "inspect") {
      const names = args.slice(3);
      const found = INSPECT.filter((c) => names.some((n) => n === c.Id || n === c.Name.slice(1)));
      if (!found.length) throw new AppError("agent.exec.failed", 502, { command: "docker", code: 1, stderr: "No such container" });
      return { stdout: JSON.stringify(found), stderr: "", code: 0 };
    }
    throw new Error("unexpected docker " + args.join(" "));
  }) as Runner;
}

describe("discovery", () => {
  it("recognises database images", () => {
    expect(parseImage("ghcr.io/x/postgis:16-3.4@sha256:abc")).toEqual({ repo: "postgis", tag: "16-3.4" });
    expect(parseImage("localhost:5000/postgres")).toEqual({ repo: "postgres", tag: null });
    expect(engineOfImage("timescale/timescaledb-ha:pg16")).toBe("postgres");
    expect(engineOfImage("bitnami/postgresql:16")).toBe("postgres");
    expect(engineOfImage("mysql:8.4")).toBe("mysql");
    expect(engineOfImage("mariadb:11")).toBe("mariadb");
    expect(engineOfImage("redis:7")).toBe("redis");
    expect(engineOfImage("nginx:1")).toBe(null);
    expect(engineOfImage("postgres-exporter:1")).toBe(null);
  });

  it("lists engine, version, networks, ports and env names only", () => {
    const list = discoveredFromInspect(INSPECT as Parameters<typeof discoveredFromInspect>[0]);
    expect(list.map((d) => [d.container, d.engine, d.version, d.supported])).toEqual([
      ["app-db-1", "postgres", "16-alpine", true],
      ["cache", "redis", "8", false],
      ["gis", "postgres", "16-3.4", true],
      ["maria", "mariadb", "11", true],
    ]);
    const pg = list[0]!;
    expect(pg).toMatchObject({ project: "app", containerEnvCredential: true, envNames: ["PATH", "POSTGRES_DB", "POSTGRES_PASSWORD", "POSTGRES_USER"] });
    expect(pg.networks).toEqual([{ name: "app_default", ip: "127.0.0.1" }, { name: "other", ip: null }]);
    expect(list[3]!.ports).toEqual([{ port: "3306/tcp", hostIp: "127.0.0.1", hostPort: "13306" }]);
    expect(JSON.stringify(list)).not.toContain(ENV_SECRET);
  });

  it("resolves a container's IP and env credentials at connect time", async () => {
    const run = fakeDocker();
    expect(await resolveContainer(run, "app-db-1", undefined, false)).toEqual({ host: "127.0.0.1" });
    expect(await resolveContainer(run, "app-db-1", "app_default", true)).toEqual({ host: "127.0.0.1", env: { user: "app", password: ENV_SECRET, database: "appdb" } });
    await expect(resolveContainer(run, "app-db-1", "nope", false)).rejects.toMatchObject({ code: "agent.db.networkNotFound" });
    await expect(resolveContainer(run, "missing", undefined, false)).rejects.toMatchObject({ code: "agent.db.containerNotFound" });
    await expect(resolveContainer(run, "gis", undefined, true)).rejects.toMatchObject({ code: "agent.db.credentialUnavailable", params: { reason: "passwordFile" } });
  });
});

// --- API --------------------------------------------------------------------------------------------------------------

async function setup(o: { run?: Runner; now?: () => number; feature?: boolean } = {}) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-db-"));
  const store = await ConfigStore.loadOrCreate(join(dir, "cfg", "agent.json"), "atlas");
  const token = newToken();
  const service = newServiceToken();
  await store.update((c) => {
    c.features.databases = o.feature ?? true;
    c.allowedRoots = [join(dir, "data")];
    c.devices.push({ id: "phone", name: "Telefon", tokenHash: hashToken(token), createdAt: new Date().toISOString() });
    c.serviceTokens.push({ id: "atlas", name: "atlas", scopes: ["research", "analysis"], tokenHash: hashToken(service), createdAt: new Date().toISOString() });
    return c;
  });
  const logs: string[] = [];
  const notifier = new Notifier(() => store.get(), () => {});
  const extra = o.feature === false ? [] : [dbRoutes({ run: o.run ?? fakeDocker(), now: o.now })];
  const app = await buildApp({ store, notifier, extraRoutes: extra }, { logger: true, logStream: { write: (l: string) => void logs.push(l) } });
  const auth = { authorization: `Bearer ${token}` };
  const responses: string[] = [];
  const call = async (method: "GET" | "POST" | "PATCH" | "DELETE", url: string, payload?: unknown, headers: Record<string, string> = auth) => {
    const res = await app.inject({ method, url, headers, ...(payload === undefined ? {} : { payload: payload as object }) });
    responses.push(res.body);
    return { status: res.statusCode, body: res.json() as Record<string, any> };
  };
  const audit = async () => {
    await new Promise((r) => setTimeout(r, 50));
    return readFile(join(dirname(store.path), "audit.jsonl"), "utf8").catch(() => "");
  };
  return { dir, app, store, auth, service, logs, call, responses, audit };
}

/** Writable SQLite file with test data (the agent itself only opens it read-only). */
async function makeSqlite(file: string, rows = 25) {
  const { mkdir } = await import("node:fs/promises");
  await mkdir(dirname(file), { recursive: true });
  const db = new DatabaseSync(file);
  db.exec(`CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT NOT NULL DEFAULT 'x', big TEXT, data BLOB, n INTEGER);
           CREATE UNIQUE INDEX t_name ON t(name);
           CREATE TABLE "we""ird" (a TEXT);
           INSERT INTO "we""ird" VALUES ('quoted ok');
           CREATE VIEW v AS SELECT id, name FROM t;`);
  const ins = db.prepare("INSERT INTO t (id, name, big, data, n) VALUES (?, ?, ?, ?, ?)");
  for (let i = 1; i <= rows; i++) ins.run(i, `name-${i}`, i === 1 ? "é".repeat(6000) : null, i === 2 ? new Uint8Array(3000) : null, i === 3 ? 2n ** 62n : i);
  db.close();
}

describe("database console API", () => {
  let t: Awaited<ReturnType<typeof setup>>;
  let dbFile: string;

  beforeAll(async () => {
    t = await setup();
    dbFile = join(t.dir, "data", "app.db");
    await makeSqlite(dbFile);
  });
  afterAll(async () => t.app.close());

  it("keeps credentials on the agent: GET, PATCH, errors, logs, audit", async () => {
    const created = await t.call("POST", "/v1/db/connections", {
      id: "pg-main",
      name: "Main",
      engine: "postgres",
      target: { host: "127.0.0.1", port: 1 },
      database: "app",
      readCredential: { user: "reader", password: SECRET },
    });
    expect(created.status).toBe(201);
    expect(created.body).toEqual({
      id: "pg-main",
      name: "Main",
      engine: "postgres",
      target: { host: "127.0.0.1", port: 1 },
      database: "app",
      readCredential: { mode: "password", user: "reader", hasPassword: true },
      writeCredential: null,
      warnings: [],
    });
    expect((await t.call("POST", "/v1/db/connections", { id: "pg-main", name: "x", engine: "postgres", target: { host: "h" }, readCredential: { user: "u" } })).body.error.code).toBe("agent.db.connectionExists");

    // PATCH without password keeps it; the stored config still has it.
    const renamed = await t.call("PATCH", "/v1/db/connections/pg-main", { name: "Main DB", readCredential: { user: "reader2" } });
    expect(renamed.body.readCredential).toEqual({ mode: "password", user: "reader2", hasPassword: true });
    expect(t.store.get().databases.connections[0]!.readCredential).toEqual({ user: "reader2", password: SECRET });
    // A new target without a password is refused (the stored one is never sent to a new address).
    expect((await t.call("PATCH", "/v1/db/connections/pg-main", { target: { host: "10.9.9.9" } })).body.error.code).toBe("agent.db.passwordRequired");
    expect((await t.call("PATCH", "/v1/db/connections/pg-main", { database: null })).body.database).toBe(null);

    // Connection error: unreachable, nothing secret in the response.
    const test = await t.call("POST", "/v1/db/connections/pg-main/test");
    expect(test.status).toBe(502);
    expect(test.body.error.code).toBe("agent.db.unreachable");
    const q = await t.call("POST", "/v1/db/connections/pg-main/query", { sql: `SELECT '${SECRET}'` });
    expect(q.body.error.code).toBe("agent.db.unreachable");

    for (const r of [(await t.call("GET", "/v1/db/connections")).body, (await t.call("GET", "/v1/db/connections/pg-main")).body, (await t.call("GET", "/v1/config")).body]) {
      expect(JSON.stringify(r)).not.toContain(SECRET);
    }
    expect(t.responses.join("\n")).not.toContain(SECRET);
    expect(t.logs.join("\n")).not.toContain(SECRET);
    const audit = await t.audit();
    expect(audit).not.toContain(SECRET);
    expect(audit).toContain(`"sqlSha256":"${sqlSha256(`SELECT '${SECRET}'`)}"`);
    expect(audit).not.toContain("SELECT");
  });

  it("fromContainerEnv: warning, credentials read at connect time and never stored", async () => {
    const created = await t.call("POST", "/v1/db/connections", { id: "pg-env", name: "Env", engine: "postgres", target: { container: "app-db-1", port: 1 }, readCredential: { fromContainerEnv: true } });
    expect(created.body).toMatchObject({ readCredential: { mode: "fromContainerEnv" }, warnings: ["superuserCredential"] });
    // Docker gives 127.0.0.1 and the env password; port 1 refuses the connection.
    expect((await t.call("POST", "/v1/db/connections/pg-env/test")).body.error.code).toBe("agent.db.unreachable");
    const file = await readFile(t.store.path, "utf8");
    expect(file).not.toContain(ENV_SECRET);
    expect(t.responses.join("\n")).not.toContain(ENV_SECRET);
    expect(t.logs.join("\n")).not.toContain(ENV_SECRET);
    expect((await t.call("POST", "/v1/db/connections", { name: "bad", engine: "postgres", target: { host: "h" }, readCredential: { fromContainerEnv: true } })).status).toBe(400);
    expect((await t.call("POST", "/v1/db/connections", { name: "bad", engine: "sqlite", target: { path: "/x" }, readCredential: { user: "u" } })).status).toBe(400);
  });

  it("discovers database containers with env names only", async () => {
    const r = await t.call("GET", "/v1/db/discover");
    expect(r.status).toBe(200);
    const pg = r.body.containers.find((c: { container: string }) => c.container === "app-db-1");
    expect(pg).toMatchObject({ engine: "postgres", version: "16-alpine", connections: ["pg-env"] });
    expect(JSON.stringify(r.body)).not.toContain(ENV_SECRET);
  });

  it("sqlite: test, schema, preview, query; read-only and refused statements", async () => {
    expect((await t.call("POST", "/v1/db/connections", { id: "lite", name: "Lite", engine: "sqlite", target: { path: dbFile } })).status).toBe(201);
    const list = await t.call("GET", "/v1/db/connections");
    expect(list.body.engines).toEqual({ postgres: true, mysql: true, mariadb: true, sqlite: true });

    const test = await t.call("POST", "/v1/db/connections/lite/test");
    expect(test.body).toMatchObject({ ok: true, engine: "sqlite", warnings: [] });
    expect(test.body.serverVersion).toMatch(/^3\./);

    const schema = await t.call("GET", "/v1/db/connections/lite/schema");
    expect(schema.body.engine).toBe("sqlite");
    expect(schema.body.truncated).toBe(false);
    const main = schema.body.schemas[0];
    expect(main.name).toBe("main");
    expect(main.tables.map((x: { name: string; kind: string }) => [x.name, x.kind])).toEqual([["t", "table"], ["v", "view"], ['we"ird', "table"]]);
    const tt = main.tables[0];
    expect(tt.columns[0]).toEqual({ name: "id", type: "INTEGER", nullable: true, default: null, primaryKey: true });
    expect(tt.columns[1]).toEqual({ name: "name", type: "TEXT", nullable: false, default: "'x'", primaryKey: false });
    expect(tt.indexes).toEqual([{ name: "t_name", unique: true, primary: false, definition: "CREATE UNIQUE INDEX t_name ON t(name)" }]);
    expect(tt.estimatedRows).toBe(null);

    const q = await t.call("POST", "/v1/db/connections/lite/query", { sql: "SELECT id, name, big, data, n FROM t WHERE id <= ? ORDER BY id", params: [3] });
    expect(q.status).toBe(200);
    expect(q.body.columns.map((c: { name: string }) => c.name)).toEqual(["id", "name", "big", "data", "n"]);
    expect(q.body.rowCount).toBe(3);
    expect(q.body.truncated).toBe(false);
    expect(q.body.cellsTruncated).toBe(1);
    expect(String(q.body.rows[0][2]).endsWith("…")).toBe(true);
    expect(Buffer.byteLength(q.body.rows[0][2])).toBeLessThanOrEqual(4096 + 3);
    expect(q.body.rows[1][3]).toBe("<3000 bayt>");
    expect(q.body.rows[2][4]).toBe("4611686018427387904");

    // Read-only at the database level: DML reaches SQLite and fails.
    for (const sql of ["INSERT INTO t (id, name) VALUES (999, 'new')", "WITH x AS (SELECT 1) INSERT INTO t (id, name) VALUES (998, 'w')", "DELETE FROM t", "UPDATE t SET n = 0"]) {
      const r = await t.call("POST", "/v1/db/connections/lite/query", { sql });
      expect(r.status, sql).toBe(409);
      expect(r.body.error.code).toBe("agent.db.readOnly");
    }
    // Refused before the database.
    for (const [sql, code] of [
      ["SELECT 1; DROP TABLE t", "agent.db.multipleStatements"],
      ["DROP TABLE t", "agent.db.statementNotAllowed"],
      [`ATTACH DATABASE '${join(t.dir, "data", "x.db")}' AS x`, "agent.db.statementNotAllowed"],
      [`VACUUM INTO '${join(t.dir, "data", "copy.db")}'`, "agent.db.statementNotAllowed"],
      ["PRAGMA query_only = OFF", "agent.db.statementNotAllowed"],
    ] as const) {
      const r = await t.call("POST", "/v1/db/connections/lite/query", { sql });
      expect(r.body.error.code, sql).toBe(code);
    }
    // Pragmas other than the catalog ones are refused by the authorizer inside a SELECT too.
    expect((await t.call("POST", "/v1/db/connections/lite/query", { sql: "SELECT * FROM pragma_table_info('t')" })).status).toBe(200);
    expect((await t.call("POST", "/v1/db/connections/lite/query", { sql: "SELECT * FROM pragma_database_list" })).body.error.code).toBe("agent.db.permissionDenied");
    // Driver error text comes back (redacted).
    const bad = await t.call("POST", "/v1/db/connections/lite/query", { sql: "SELECT nope FROM t" });
    expect(bad.body.error).toMatchObject({ code: "agent.db.queryFailed" });
    expect(bad.body.error.params.message).toContain("no such column");

    // Data unchanged.
    const check = new DatabaseSync(dbFile, { readOnly: true });
    expect(check.prepare("SELECT count(*) AS c FROM t").get()).toEqual({ c: 25 });
    check.close();
    const audit = await t.audit();
    expect(audit).toMatch(/"detail":\{"conn":"lite","sqlSha256":"[a-f0-9]{64}","rows":3,"truncated":false\}/);
  });

  it("limits: rows, truncation, bounds", async () => {
    const q = (body: object) => t.call("POST", "/v1/db/connections/lite/query", body);
    const ten = await q({ sql: "SELECT id FROM t ORDER BY id", limit: 10 });
    expect(ten.body).toMatchObject({ rowCount: 10, truncated: true, limit: 10 });
    const all = await q({ sql: "SELECT id FROM t", limit: 25 });
    expect(all.body).toMatchObject({ rowCount: 25, truncated: false });
    const def = await q({ sql: "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 6000) SELECT x FROM c" });
    expect(def.body).toMatchObject({ rowCount: 500, truncated: true, limit: 500 });
    const max = await q({ sql: "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 6000) SELECT x FROM c", limit: 5000 });
    expect(max.body).toMatchObject({ rowCount: 5000, truncated: true });
    expect((await q({ sql: "SELECT 1", limit: 5001 })).status).toBe(400);
    expect((await q({ sql: "SELECT 1", timeoutMs: 60_001 })).status).toBe(400);
    expect((await q({ sql: "SELECT 1", unknown: 1 })).status).toBe(400);
    expect((await q({ sql: "x".repeat(100_001) })).status).toBe(400);
  });

  it("preview: identifiers must exist in the catalog", async () => {
    const p = await t.call("GET", "/v1/db/connections/lite/tables/main/t/preview?limit=5");
    expect(p.body).toMatchObject({ schema: "main", table: "t", rowCount: 5, truncated: true });
    const weird = await t.call("GET", `/v1/db/connections/lite/tables/main/${encodeURIComponent('we"ird')}/preview`);
    expect(weird.body.rows).toEqual([["quoted ok"]]);
    for (const name of ['t"; DROP TABLE t; --', "t; DROP TABLE t", "t WHERE 1=1", "sqlite_master", "../t", "T2"]) {
      const r = await t.call("GET", `/v1/db/connections/lite/tables/main/${encodeURIComponent(name)}/preview`);
      expect(r.status, name).toBe(404);
      expect(r.body.error.code).toBe("agent.db.tableNotFound");
    }
    expect((await t.call("GET", "/v1/db/connections/lite/tables/other/t/preview")).body.error.code).toBe("agent.db.tableNotFound");
    const check = new DatabaseSync(dbFile, { readOnly: true });
    expect(check.prepare("SELECT count(*) AS c FROM t").get()).toEqual({ c: 25 });
    check.close();
  });

  it("sqlite paths must be inside allowedRoots", async () => {
    const outside = join(t.dir, "outside.db");
    await makeSqlite(outside, 1);
    await t.call("POST", "/v1/db/connections", { id: "outside", name: "Out", engine: "sqlite", target: { path: outside } });
    expect((await t.call("POST", "/v1/db/connections/outside/query", { sql: "SELECT 1" })).body.error.code).toBe("agent.path.notAllowed");
    await writeFile(join(t.dir, "data", "not-a-db.db"), "plain text, not sqlite\n".repeat(10));
    await t.call("POST", "/v1/db/connections", { id: "notdb", name: "Not", engine: "sqlite", target: { path: join(t.dir, "data", "not-a-db.db") } });
    expect((await t.call("POST", "/v1/db/connections/notdb/query", { sql: "SELECT 1 FROM sqlite_master" })).body.error.code).toBe("agent.db.queryFailed");
    expect((await t.call("DELETE", "/v1/db/connections/notdb")).body).toEqual({ ok: true });
    expect((await t.call("DELETE", "/v1/db/connections/notdb")).status).toBe(404);
  });

  it("timeout kills a runaway query; at most 2 at once per connection", async () => {
    // Fresh agent: the shared one has used up this minute's query budget.
    const t = await setup();
    await makeSqlite(join(t.dir, "data", "app.db"), 1);
    await t.call("POST", "/v1/db/connections", { id: "lite", name: "Lite", engine: "sqlite", target: { path: join(t.dir, "data", "app.db") } });
    const slow = { sql: "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c", timeoutMs: 1000 };
    const started = Date.now();
    const runs = [t.call("POST", "/v1/db/connections/lite/query", slow), t.call("POST", "/v1/db/connections/lite/query", slow)];
    await new Promise((r) => setTimeout(r, 200));
    const third = await t.call("POST", "/v1/db/connections/lite/query", { sql: "SELECT 1" });
    expect(third.status).toBe(429);
    expect(third.body.error.code).toBe("agent.db.busy");
    for (const r of await Promise.all(runs)) expect(r.body.error.code).toBe("agent.db.timeout");
    expect(Date.now() - started).toBeLessThan(10_000);
    expect((await t.call("POST", "/v1/db/connections/lite/query", { sql: "SELECT 1" })).status).toBe(200);
    await t.app.close();
  }, 20_000);
});

describe("database console guards", () => {
  it("rate limit: 30 SQL calls per minute per device", async () => {
    let now = 1_000_000;
    const t = await setup({ now: () => now });
    await t.call("POST", "/v1/db/connections", { id: "lite", name: "Lite", engine: "sqlite", target: { path: join(t.dir, "data", "none.db") } });
    // Refused statements are counted too (no database work needed for this check).
    for (let i = 0; i < QUERIES_PER_MIN; i++) expect((await t.call("POST", "/v1/db/connections/lite/query", { sql: "DROP TABLE t" })).status).toBe(400);
    const over = await t.call("POST", "/v1/db/connections/lite/query", { sql: "SELECT 1" });
    expect(over.status).toBe(429);
    expect(over.body.error).toEqual({ code: "agent.db.rateLimited", params: { perMinute: 30 } });
    expect((await t.call("GET", "/v1/db/connections/lite/tables/main/t/preview")).status).toBe(429);
    now += 60_001;
    expect((await t.call("POST", "/v1/db/connections/lite/query", { sql: "DROP TABLE t" })).status).toBe(400);
    await t.app.close();
  });

  it("device tokens only; routes absent with the feature off", async () => {
    const t = await setup();
    const svc = await t.call("GET", "/v1/db/connections", undefined, { authorization: `Bearer ${t.service}` });
    expect(svc.status).toBe(403);
    await t.app.close();
    const off = await setup({ feature: false });
    expect((await off.call("GET", "/v1/db/connections")).body.error.code).toBe("agent.route.notFound");
    await off.app.close();
  });
});
