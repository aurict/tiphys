// Backup restore tests (PLAN.md §13.2, D-4) with a fake docker script (test/fake_docker_restore.mjs): config validation,
// argv exactness, streaming (plain and gz), sanity evaluation, cleanup on failure/timeout/shutdown, retention,
// notifications, routes.
import { mkdir, readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { gzipSync } from "node:zlib";
import { describe, expect, it } from "vitest";
import { restoreTestSchema } from "../src/config.ts";
import { dbRoutes } from "../src/db/routes.ts";
import { checkSanitySql, RESULTS_PER_TEST, type RestoreService } from "../src/db/restore.ts";
import { testApp } from "./helpers.ts";

const FAKE = join(import.meta.dirname, "fake_docker_restore.mjs");

interface Env {
  app: Awaited<ReturnType<typeof testApp>>;
  restore: RestoreService;
  dumps: string;
  log: string;
  cfg: (c: Record<string, unknown>) => Promise<void>;
  calls: () => Promise<Array<{ argv: string[]; [k: string]: unknown }>>;
  call: (method: "GET" | "POST" | "PATCH" | "DELETE", url: string, payload?: object) => Promise<{ status: number; body: any }>;
}

async function setup(opts: { restore?: Record<string, unknown>; connections?: boolean } = {}): Promise<Env> {
  let restore!: RestoreService;
  const app = await testApp(
    (c) => {
      c.features.databases = true;
      return c;
    },
    [dbRoutes({ restore: { dockerBin: FAKE, readyIntervalMs: 5, diskPath: "/", ...opts.restore }, onRestore: (r) => (restore = r), restoreTimer: false })],
  );
  const dumps = join(app.dir, "dumps");
  await mkdir(dumps);
  app.store.get().allowedRoots = [app.dir];
  const log = join(app.dir, "docker.log");
  const cfgFile = join(app.dir, "docker-cfg.json");
  await writeFile(log, "");
  await writeFile(cfgFile, "{}");
  process.env.FAKE_DOCKER_LOG = log;
  process.env.FAKE_DOCKER_CFG = cfgFile;
  return {
    app,
    restore,
    dumps,
    log,
    cfg: (c) => writeFile(cfgFile, JSON.stringify(c)),
    calls: async () =>
      (await readFile(log, "utf8"))
        .split("\n")
        .filter(Boolean)
        .map((l) => JSON.parse(l)),
    call: async (method, url, payload) => {
      const r = await app.app.inject({ method, url, headers: app.auth, ...(payload ? { payload } : {}) });
      return { status: r.statusCode, body: r.body ? JSON.parse(r.body) : {} };
    },
  };
}

const base = (e: Env, extra: Record<string, unknown> = {}) => ({
  id: "notes",
  name: "Notes DB",
  engine: "postgres",
  image: "postgres:16-alpine",
  dumpGlob: join(e.dumps, "*.sql"),
  format: "sql",
  sanity: [{ sql: "SELECT count(*) FROM notes", expect: { op: ">", value: 0 } }],
  schedule: { kind: "daily", time: "03:30" },
  ...extra,
});

const runAndWait = async (e: Env, id = "notes") => {
  const r = await e.call("POST", `/v1/db/restore-tests/${id}/run`);
  expect(r.status).toBe(202);
  await e.restore.idle();
  return (await e.call("GET", `/v1/db/restore-tests/${id}/results`)).body.results[0];
};

describe("restoreTests yapılandırma doğrulaması", () => {
  const ok = { id: "t", name: "T", engine: "postgres", image: "postgres:16-alpine", dumpGlob: "/x/*.sql", format: "sql" };
  it("görüntü başvurusu: yalnız resmi postgres/mysql/mariadb ve açık etiket", () => {
    for (const image of ["postgres:16", "postgres:16.4-alpine", "postgres:17.0_x"]) expect(restoreTestSchema.safeParse({ ...ok, image }).success, image).toBe(true);
    for (const image of ["postgres", "postgres:latest", "evil/postgres:16", "ghcr.io/x/postgres:16", "postgres:16@sha256:abc", "postgres:16 --privileged", "postgres:", "mysql:8", "POSTGRES:16", "postgres:16;rm", "-v/:/x:postgres:1"]) {
      expect(restoreTestSchema.safeParse({ ...ok, image }).success, image).toBe(false);
    }
    expect(restoreTestSchema.safeParse({ ...ok, engine: "mysql", image: "mysql:8.4" }).success).toBe(true);
    expect(restoreTestSchema.safeParse({ ...ok, engine: "mariadb", image: "mysql:8.4" }).success).toBe(false);
  });
  it("biçim ve joker kuralları", () => {
    expect(restoreTestSchema.safeParse({ ...ok, engine: "mysql", image: "mysql:8", format: "custom" }).success).toBe(false);
    expect(restoreTestSchema.safeParse({ ...ok, dumpGlob: "/x/*/a.sql" }).success).toBe(false);
    expect(restoreTestSchema.safeParse({ ...ok, dumpGlob: "/x/../etc/*.sql" }).success).toBe(false);
    expect(restoreTestSchema.safeParse({ ...ok, schedule: { kind: "interval", everyMinutes: 5 } }).success).toBe(false);
    expect(restoreTestSchema.safeParse({ ...ok, extra: 1 }).success).toBe(false);
    expect(restoreTestSchema.safeParse({ ...ok, sanity: [{ sql: "select 1", expect: { op: "!=", value: 1 } }] }).success).toBe(false);
  });
  it("sanity SQL: yalnız tek okuma ifadesi", () => {
    expect(checkSanitySql("SELECT count(*) FROM t", "postgres").ok).toBe(true);
    expect(checkSanitySql("with a as (select 1) select * from a", "postgres").ok).toBe(true);
    for (const sql of ["DELETE FROM t", "SELECT 1; DROP TABLE t", "COPY (select 1) TO PROGRAM 'x'", "SELECT pg_read_file('/etc/passwd')", "UPDATE t SET a=1", "SET x=1"]) {
      expect(checkSanitySql(sql, "postgres").ok, sql).toBe(false);
    }
    expect(checkSanitySql("SELECT 1 INTO OUTFILE '/tmp/x'", "mysql").ok).toBe(false);
  });
});

describe("restoreTests uçları ve doğrulama", () => {
  it("CRUD: kökler dışındaki dumpGlob, sembolik bağ, bilinmeyen bağlantı, yazma deyimi reddedilir", async () => {
    const e = await setup();
    expect((await e.call("POST", "/v1/db/restore-tests", base(e, { dumpGlob: "/etc/*.sql" }))).body.error.code).toBe("agent.db.dumpOutsideRoots");
    expect((await e.call("POST", "/v1/db/restore-tests", base(e, { dumpGlob: `${e.dumps}/../../etc/*.sql` }))).status).toBe(400);
    expect((await e.call("POST", "/v1/db/restore-tests", base(e, { connectionId: "yok" }))).body.error.code).toBe("agent.db.connectionNotFound");
    const bad = await e.call("POST", "/v1/db/restore-tests", base(e, { sanity: [{ sql: "DELETE FROM notes", expect: { op: ">", value: 0 } }] }));
    expect(bad.body.error).toMatchObject({ code: "agent.db.sanityNotAllowed", params: { index: 0 } });
    const made = await e.call("POST", "/v1/db/restore-tests", base(e));
    expect(made.status).toBe(201);
    expect(made.body.anchorAt).toBeTruthy();
    expect((await e.call("POST", "/v1/db/restore-tests", base(e))).body.error.code).toBe("agent.db.restoreTestExists");
    const patched = await e.call("PATCH", "/v1/db/restore-tests/notes", { name: "Yeni", schedule: null });
    expect(patched.body).toMatchObject({ name: "Yeni", schedule: null, sanity: made.body.sanity });
    expect((await e.call("PATCH", "/v1/db/restore-tests/notes", { dumpGlob: "/etc/*.sql" })).body.error.code).toBe("agent.db.dumpOutsideRoots");
    expect((await e.call("PATCH", "/v1/db/restore-tests/notes", { image: "mysql:8" })).status).toBe(400);
    const view = (await e.call("GET", "/v1/db/restore-tests")).body;
    expect(view.tests).toHaveLength(1);
    expect(view.tests[0]).toMatchObject({ id: "notes", last: null, running: false, nextRunAt: null });
    expect((await e.call("DELETE", "/v1/db/restore-tests/notes")).body).toEqual({ ok: true });
    expect((await e.call("POST", "/v1/db/restore-tests/notes/run")).status).toBe(404);
    await e.app.app.close();
  });

  it("yedek denetiminin dizini de kök sayılır; zamanlanmış testin sonraki çalışma zamanı verilir", async () => {
    const e = await setup();
    await e.app.store.update((c) => {
      c.allowedRoots = [join(e.app.dir, "yok")];
      c.backups.checks.push({ id: "pg", name: "pg", kind: "file", path: join(e.dumps, "*.sql"), maxAgeHours: 26, minBytes: 0 });
      return c;
    });
    expect((await e.call("POST", "/v1/db/restore-tests", base(e))).status).toBe(201);
    expect((await e.call("GET", "/v1/db/restore-tests")).body.tests[0].nextRunAt).toMatch(/T\d\d:\d\d:00\.000Z$/);
    await e.app.app.close();
  });
});

describe("restore testi çalıştırma", () => {
  it("başarı: argv birebir, parola ortamdan, döküm stdin'den, hazır bekleme, temizlik, bildirim", async () => {
    const e = await setup();
    await writeFile(join(e.dumps, "old.sql"), "OLD");
    await new Promise((r) => setTimeout(r, 20));
    await writeFile(join(e.dumps, "new.sql"), "CREATE TABLE notes(id int); INSERT INTO notes VALUES (1);");
    await e.cfg({ sanity: { "SELECT count(*) FROM notes": "7" }, readyFailures: 2 });
    await e.call("POST", "/v1/db/restore-tests", base(e));
    const res = await runAndWait(e);
    expect(res).toMatchObject({ ok: true, reason: null, rowsChecked: 1, failures: [], dumpFile: "new.sql", image: "postgres:16-alpine", trigger: "manual" });
    expect(res.durations.totalMs).toBeGreaterThanOrEqual(0);
    const calls = await e.calls();
    const run = calls.find((c) => c.argv[0] === "run")!;
    const name = run.argv[run.argv.indexOf("--name") + 1]!;
    expect(name).toMatch(/^tiphys-restore-notes-[a-f0-9]{8}$/);
    expect(run.argv).toEqual([
      "run", "-d", "--rm", "--network", "none", "--memory", "1g", "--memory-swap", "1g", "--cpus", "1", "--pids-limit", "256",
      "--cap-drop", "ALL", "--cap-add", "CHOWN", "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "DAC_OVERRIDE", "--cap-add", "FOWNER",
      "--security-opt", "no-new-privileges", "--tmpfs", "/var/lib/postgresql/data:size=2g", "--label", "tiphys.restore=1",
      "-e", "POSTGRES_PASSWORD", "--name", name, "postgres:16-alpine",
    ]);
    expect(run.env).toEqual({ pg: "set" });
    expect(JSON.stringify(calls)).not.toMatch(/POSTGRES_PASSWORD=/);
    expect(calls.filter((c) => c.tool === "pg_isready")).toHaveLength(3);
    expect(calls.find((c) => c.tool === "pg_isready")!.argv).toEqual(["exec", name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres"]);
    const restore = calls.find((c) => c.stdin !== undefined)!;
    expect(restore.argv).toEqual(["exec", "-i", name, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"]);
    expect(restore.stdin).toContain("CREATE TABLE notes");
    expect(restore.stdin).not.toContain("OLD");
    const sanity = calls.find((c) => c.sql)!;
    expect(sanity.argv).toEqual([
      "exec", "-e", "PGOPTIONS=-c default_transaction_read_only=on", name, "psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-c",
      "SELECT count(*) FROM notes",
    ]);
    expect(calls.at(-1)!.argv).toEqual(["rm", "-f", name]);
    expect(e.app.sent).toContainEqual(expect.objectContaining({ key: "db.restoreTest.ok", params: { host: "test", name: "Notes DB" } }));
    await e.app.app.close();
  });

  it("gz: Node gunzip eder; pg_restore ve mysql argv; postgres 18 veri dizini", async () => {
    const e = await setup();
    await writeFile(join(e.dumps, "a.sql.gz"), gzipSync("SELECT 'PLAIN-SQL';"));
    await e.call("POST", "/v1/db/restore-tests", base(e, { dumpGlob: join(e.dumps, "*.gz"), format: "gz", image: "postgres:18" }));
    expect((await runAndWait(e)).ok).toBe(true);
    let calls = await e.calls();
    expect(calls.find((c) => c.stdin !== undefined)!.stdin).toBe("SELECT 'PLAIN-SQL';");
    expect(calls.find((c) => c.argv[0] === "run")!.argv).toContain("/var/lib/postgresql:size=2g");
    expect(calls.find((c) => c.argv[0] === "run")!.argv).not.toContain("/var/lib/postgresql/data:size=2g");

    await writeFile(join(e.dumps, "c.dump"), "PGDMP-binary");
    await e.call("POST", "/v1/db/restore-tests", base(e, { id: "cust", dumpGlob: join(e.dumps, "*.dump"), format: "custom", sanity: [] }));
    await writeFile(e.log, "");
    expect((await runAndWait(e, "cust")).ok).toBe(true);
    calls = await e.calls();
    const name = calls.find((c) => c.argv[0] === "run")!.argv.at(-2)!;
    expect(calls.find((c) => c.stdin !== undefined)!.argv).toEqual(["exec", "-i", name, "pg_restore", "-U", "postgres", "-d", "postgres", "--no-owner", "--exit-on-error"]);

    await writeFile(join(e.dumps, "m.sql"), "CREATE TABLE t(a int);");
    await e.call("POST", "/v1/db/restore-tests", base(e, { id: "my", engine: "mariadb", image: "mariadb:11", dumpGlob: join(e.dumps, "m.sql"), sanity: [{ sql: "SELECT 1", expect: { op: "=", value: 1 } }] }));
    await writeFile(e.log, "");
    expect((await runAndWait(e, "my")).ok).toBe(true);
    calls = await e.calls();
    const mname = calls.find((c) => c.argv[0] === "run")!.argv.at(-2)!;
    expect(calls.find((c) => c.argv[0] === "run")!.argv).toEqual([
      "run", "-d", "--rm", "--network", "none", "--memory", "1g", "--memory-swap", "1g", "--cpus", "1", "--pids-limit", "256",
      "--cap-drop", "ALL", "--cap-add", "CHOWN", "--cap-add", "SETUID", "--cap-add", "SETGID", "--cap-add", "DAC_OVERRIDE", "--cap-add", "FOWNER",
      "--security-opt", "no-new-privileges", "--tmpfs", "/var/lib/mysql:size=2g", "--label", "tiphys.restore=1", "-e", "MARIADB_ROOT_PASSWORD", "--name", mname, "mariadb:11",
    ]);
    expect(calls.find((c) => c.tool === "mariadb-admin")!.argv).toEqual(["exec", "-e", "MYSQL_PWD", mname, "mariadb-admin", "-h", "127.0.0.1", "-uroot", "--silent", "ping"]);
    expect(calls.find((c) => c.stdin !== undefined)!.argv).toEqual(["exec", "-i", "-e", "MYSQL_PWD", mname, "mariadb", "-h", "127.0.0.1", "-uroot"]);
    expect(calls.find((c) => c.sql)!.argv).toEqual(["exec", "-e", "MYSQL_PWD", mname, "mariadb", "-h", "127.0.0.1", "-uroot", "-N", "-B", "-e", "SET SESSION TRANSACTION READ ONLY; SELECT 1"]);
    expect(calls.find((c) => c.tool === "mariadb")!.env).toEqual({ my: "set" });
    await e.app.app.close();
  });

  it("bozuk döküm: restoreFailed + temizlik + bildirim; bozuk gz: dumpCorrupt", async () => {
    const e = await setup();
    await writeFile(join(e.dumps, "bad.sql"), "CORRUPT garbage");
    await e.call("POST", "/v1/db/restore-tests", base(e));
    const res = await runAndWait(e);
    expect(res).toMatchObject({ ok: false, reason: "restoreFailed", rowsChecked: 0 });
    expect(res.detail).toContain("syntax error");
    const calls = await e.calls();
    expect(calls.at(-1)!.argv[0]).toBe("rm");
    expect(calls.some((c) => c.sql)).toBe(false);
    expect(e.app.sent).toContainEqual(expect.objectContaining({ key: "db.restoreTest.failed", params: expect.objectContaining({ host: "test", name: "Notes DB", reason: expect.stringContaining("restoreFailed") }) }));

    await writeFile(join(e.dumps, "bad.sql"), "not gzip at all");
    await e.call("PATCH", "/v1/db/restore-tests/notes", { format: "gz" });
    expect(await runAndWait(e)).toMatchObject({ ok: false, reason: "dumpCorrupt" });
    expect((await e.calls()).at(-1)!.argv[0]).toBe("rm");
    await e.app.app.close();
  });

  it("sanity değerlendirme: işleçler, sorgu hatası, sayı olmayan çıktı", async () => {
    const e = await setup();
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    const q = (sql: string, op: string, value: number) => ({ sql, expect: { op, value } });
    await e.cfg({ sanity: { "select 's1'": "5", "select 's2'": "5", "select 's3'": "5", "select 's4'": "5", "select 's5'": "5" } });
    await e.call("POST", "/v1/db/restore-tests", base(e, {
      sanity: [q("select 's1'", ">", 4), q("select 's2'", "=", 5), q("select 's3'", ">=", 5), q("select 's4'", "<", 6), q("select 's5'", "<=", 5)],
    }));
    expect(await runAndWait(e)).toMatchObject({ ok: true, rowsChecked: 5 });
    await e.cfg({ sanity: { "select 'a'": "3", "select 'b'": "x", "select 'c'": "10" }, sanityFail: ["select 'd'"] });
    await e.call("PATCH", "/v1/db/restore-tests/notes", { sanity: [q("select 'a'", ">", 3), q("select 'b'", "=", 1), q("select 'c'", "<", 10), q("select 'd'", ">", 0)] });
    const res = await runAndWait(e);
    expect(res).toMatchObject({ ok: false, reason: "sanityFailed", rowsChecked: 2 });
    expect(res.failures).toEqual([
      { index: 0, reason: "expectation", actual: 3, expected: "> 3" },
      { index: 1, reason: "notNumeric", expected: "= 1" },
      { index: 2, reason: "expectation", actual: 10, expected: "< 10" },
      { index: 3, reason: "queryFailed", expected: "> 0" },
    ]);
    expect(res.detail).toContain("does not exist");
    await e.app.app.close();
  });

  it("dockerFailed, dump yok, disk yetersiz, sürüm uyuşmazlığı: kapsayıcı başlamadan/temizlenerek biter", async () => {
    const e = await setup({ restore: { freeBytes: async () => 100 } });
    await e.call("POST", "/v1/db/restore-tests", base(e));
    expect(await runAndWait(e)).toMatchObject({ ok: false, reason: "noDump", dumpFile: null });
    expect((await e.calls()).some((c) => c.argv[0] === "run")).toBe(false);

    await writeFile(join(e.dumps, "a.sql"), "x".repeat(60));
    expect(await runAndWait(e)).toMatchObject({ ok: false, reason: "insufficientDisk", dumpBytes: 60 });
    expect((await e.calls()).some((c) => c.argv[0] === "run")).toBe(false);

    const e2 = await setup({ restore: { freeBytes: async () => 120 } });
    await writeFile(join(e2.dumps, "a.sql"), "x".repeat(60));
    await e2.call("POST", "/v1/db/restore-tests", base(e2, { sanity: [] }));
    expect((await runAndWait(e2)).ok).toBe(true); // 2 × 60 = 120: exactly enough
    await e2.cfg({ runFail: true });
    expect(await runAndWait(e2)).toMatchObject({ ok: false, reason: "dockerFailed", detail: expect.stringContaining("pull access denied") });
    expect((await e2.calls()).at(-1)!.argv[0]).toBe("rm");

    await e2.app.store.update((c) => {
      c.databases.connections.push({ id: "src", name: "src", engine: "postgres", target: { container: "src-db" }, readCredential: { user: "u", password: "p" } });
      return c;
    });
    await e2.cfg({ sourceImage: "postgres:15-alpine" });
    await e2.call("PATCH", "/v1/db/restore-tests/notes", { connectionId: "src" });
    expect(await runAndWait(e2)).toMatchObject({ ok: false, reason: "imageVersionMismatch" });
    await e2.cfg({ sourceImage: "postgres:16.2" });
    expect((await runAndWait(e2)).ok).toBe(true);
    await e.app.app.close();
    await e2.app.app.close();
  });

  it("dump kökler dışına sembolik bağ ile kaçamaz", async () => {
    const e = await setup();
    const { symlink } = await import("node:fs/promises");
    await writeFile(join(e.app.dir, "outside.sql"), "SELECT 1;");
    await symlink(join(e.app.dir, "outside.sql"), join(e.dumps, "link.sql"));
    await e.app.store.update((c) => ({ ...c, allowedRoots: [e.dumps] }));
    await e.call("POST", "/v1/db/restore-tests", base(e));
    expect(await runAndWait(e)).toMatchObject({ ok: false, reason: "dumpOutsideRoots" });
    expect((await e.calls()).some((c) => c.argv[0] === "run")).toBe(false);
    await e.app.app.close();
  });

  it("zaman aşımı: kapsayıcı kaldırılır, sonuç timeout", async () => {
    const e = await setup({ restore: { timeoutMs: 400 } });
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    await e.cfg({ hang: true });
    await e.call("POST", "/v1/db/restore-tests", base(e));
    const res = await runAndWait(e);
    expect(res).toMatchObject({ ok: false, reason: "timeout" });
    const calls = await e.calls();
    const name = calls.find((c) => c.argv[0] === "run")!.argv.at(-2)!;
    expect(calls.at(-1)!.argv).toEqual(["rm", "-f", name]);
    expect(e.app.sent).toContainEqual(expect.objectContaining({ key: "db.restoreTest.failed" }));
    await e.app.app.close();
  });

  it("ajan kapanırken çalışan test iptal edilir ve kapsayıcı kaldırılır", async () => {
    const e = await setup();
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    await e.cfg({ hang: true });
    await e.call("POST", "/v1/db/restore-tests", base(e));
    expect((await e.call("POST", "/v1/db/restore-tests/notes/run")).status).toBe(202);
    for (let i = 0; i < 200 && !(await e.calls()).some((c) => c.stdin !== undefined); i++) await new Promise((r) => setTimeout(r, 25));
    await e.app.app.close(); // onClose → stop()
    const calls = await e.calls();
    const name = calls.find((c) => c.argv[0] === "run")!.argv.at(-2)!;
    expect(calls.at(-1)!.argv).toEqual(["rm", "-f", name]);
    const saved = JSON.parse(await readFile(join(e.app.dir, "db-restore-results.json"), "utf8"));
    expect(saved.notes[0]).toMatchObject({ ok: false, reason: "shutdown" });
  });

  it("aynı anda tek test: ikincisi 409; çalışırken silinemez", async () => {
    const e = await setup();
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    await e.cfg({ hang: true });
    await e.call("POST", "/v1/db/restore-tests", base(e));
    await e.call("POST", "/v1/db/restore-tests", base(e, { id: "other" }));
    expect((await e.call("POST", "/v1/db/restore-tests/notes/run")).status).toBe(202);
    expect((await e.call("POST", "/v1/db/restore-tests/other/run")).body.error.code).toBe("agent.db.restoreBusy");
    expect((await e.call("DELETE", "/v1/db/restore-tests/notes")).status).toBe(409);
    expect((await e.call("GET", "/v1/db/restore-tests")).body.tests.find((t: { id: string }) => t.id === "notes").running).toBe(true);
    await e.restore.stop();
    await e.app.app.close();
  });

  it("sonuçlar: test başına son 20, 0600, silinince temizlenir", async () => {
    const e = await setup();
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    await e.call("POST", "/v1/db/restore-tests", base(e, { sanity: [] }));
    const ids: string[] = [];
    for (let i = 0; i < RESULTS_PER_TEST + 2; i++) ids.push((await runAndWait(e)).id);
    const results = (await e.call("GET", "/v1/db/restore-tests/notes/results")).body.results;
    expect(results).toHaveLength(RESULTS_PER_TEST);
    expect(results[0].id).toBe(ids.at(-1));
    expect(results.map((r: { id: string }) => r.id)).not.toContain(ids[0]);
    const file = join(e.app.dir, "db-restore-results.json");
    expect((await stat(file)).mode & 0o777).toBe(0o600);
    expect((await e.call("GET", "/v1/db/restore-tests")).body.tests[0].last.id).toBe(ids.at(-1));
    await e.call("DELETE", "/v1/db/restore-tests/notes");
    expect(JSON.parse(await readFile(file, "utf8"))).toEqual({});
    await e.app.app.close();
  }, 30_000); // 22 runs through the fake docker: slow on two pinned cores

  it("zamanlayıcı: zamanı gelen etkin test çalışır, kapalı olan çalışmaz, meşgulken atlanır", async () => {
    let now = new Date(2026, 10, 17, 3, 29, 30).getTime();
    const e = await setup({ restore: { now: () => now } });
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    await e.call("POST", "/v1/db/restore-tests", base(e, { sanity: [] }));
    await e.call("POST", "/v1/db/restore-tests", base(e, { id: "off", enabled: false, sanity: [] }));
    e.restore.tick();
    await e.restore.idle();
    expect(await e.calls()).toEqual([]);
    now = new Date(2026, 10, 17, 3, 30, 10).getTime();
    e.restore.tick();
    await e.restore.idle();
    const calls = await e.calls();
    expect(calls.filter((c) => c.argv[0] === "run")).toHaveLength(1);
    expect(calls.find((c) => c.argv[0] === "run")!.argv.some((a) => a.startsWith("tiphys-restore-notes-"))).toBe(true);
    expect((await e.call("GET", "/v1/db/restore-tests/notes/results")).body.results[0]).toMatchObject({ trigger: "schedule", ok: true });
    e.restore.tick(); // same minute: not run again
    await e.restore.idle();
    expect((await e.calls()).filter((c) => c.argv[0] === "run")).toHaveLength(1);
    await e.app.app.close();
  });

  it("uçlar yalnız cihaz belirteciyle; gövde yankılanmaz", async () => {
    const e = await setup();
    const noAuth = await e.app.app.inject({ method: "GET", url: "/v1/db/restore-tests" });
    expect(noAuth.statusCode).toBe(401);
    const r = await e.call("POST", "/v1/db/restore-tests", { ...base(e), image: "postgres:latest" });
    expect(r.status).toBe(400);
    expect(JSON.stringify(r.body)).not.toContain("postgres:latest");
    await e.app.app.close();
  });
});

describe("§13 review: restore hardening and scheduler", () => {
  it("S6: failure detail is redacted (URI password, PEM across lines, the run's own password) and ≤200 chars", async () => {
    const e = await setup();
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    await e.call("POST", "/v1/db/restore-tests", base(e));
    await e.cfg({ restoreStderr: `psql:dump.sql:3: ERROR: at or near "postgres://app:Sup3rS3cretPw99@db/app" ${"x".repeat(400)}\n` });
    const r1 = await runAndWait(e);
    expect(r1).toMatchObject({ ok: false, reason: "restoreFailed" });
    expect(r1.detail).not.toContain("Sup3rS3cretPw99");
    expect(r1.detail.length).toBeLessThanOrEqual(200);
    await e.cfg({ restoreStderr: `ERROR: bad line -----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7\n-----END PRIVATE KEY-----\n` });
    const r2 = await runAndWait(e);
    expect(r2.detail).not.toContain("MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC7");
    await writeFile(join(e.dumps, "m.sql"), "SELECT 1;");
    await e.call("POST", "/v1/db/restore-tests", base(e, { id: "my", engine: "mariadb", image: "mariadb:11", dumpGlob: join(e.dumps, "m.sql"), sanity: [{ sql: "SELECT 1", expect: { op: "=", value: 1 } }] }));
    await e.cfg({ sanityFail: ["SET SESSION TRANSACTION READ ONLY; SELECT 1"], sanityStderr: "ERROR 1045: denied for root using password $PWD\n" });
    const r3 = await runAndWait(e, "my");
    expect(r3).toMatchObject({ ok: false, reason: "sanityFailed" });
    expect(r3.detail).toContain("[GİZLİ");
    expect(r3.detail).toMatch(/^ERROR 1045: denied for root using password \[GİZLİ/);
    for (const n of e.app.sent) expect(JSON.stringify(n)).not.toContain("Sup3rS3cretPw99");
    await e.app.app.close();
  });

  it("C8: a test due while another runs is queued, not dropped", async () => {
    let now = new Date(2026, 10, 17, 3, 29, 30).getTime();
    const e = await setup({ restore: { now: () => now } });
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    await e.call("POST", "/v1/db/restore-tests", base(e, { sanity: [] }));
    await e.call("POST", "/v1/db/restore-tests", base(e, { id: "second", sanity: [] }));
    now = new Date(2026, 10, 17, 3, 30, 10).getTime();
    e.restore.tick();
    await e.restore.idle();
    expect((await e.call("GET", "/v1/db/restore-tests/notes/results")).body.results).toMatchObject([{ trigger: "schedule", ok: true }]);
    expect((await e.call("GET", "/v1/db/restore-tests/second/results")).body.results).toMatchObject([{ trigger: "schedule", ok: true }]);
    await e.app.app.close();
  });

  it("C8: minutes missed by a stalled timer are made up within the grace window", async () => {
    let now = new Date(2026, 10, 17, 3, 20, 0).getTime();
    const e = await setup({ restore: { now: () => now } });
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    await e.call("POST", "/v1/db/restore-tests", base(e, { sanity: [] }));
    e.restore.tick();
    now = new Date(2026, 10, 17, 3, 45, 0).getTime(); // 15 minutes without a tick
    e.restore.tick();
    await e.restore.idle();
    expect((await e.call("GET", "/v1/db/restore-tests/notes/results")).body.results).toHaveLength(1);
    await e.app.app.close();
  });

  it("C8: the repeated wall-clock hour when DST ends runs a daily test once", async () => {
    const tz = process.env.TZ;
    process.env.TZ = "Europe/Berlin";
    try {
      // 2026-10-25: 03:00 CEST → 02:00 CET, so 02:30 comes at 00:30Z and again at 01:30Z.
      let now = Date.parse("2026-10-25T00:20:00Z");
      const e = await setup({ restore: { now: () => now } });
      await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
      await e.call("POST", "/v1/db/restore-tests", base(e, { sanity: [], schedule: { kind: "daily", time: "02:30" } }));
      for (const t of ["2026-10-25T00:30:10Z", "2026-10-25T00:50:00Z", "2026-10-25T01:10:00Z", "2026-10-25T01:30:10Z", "2026-10-25T01:45:00Z"]) {
        now = Date.parse(t);
        e.restore.tick();
        await e.restore.idle();
      }
      expect((await e.call("GET", "/v1/db/restore-tests/notes/results")).body.results).toHaveLength(1);
      await e.app.app.close();
    } finally {
      if (tz === undefined) delete process.env.TZ;
      else process.env.TZ = tz;
    }
  });

  it("C8: stop() doesn't hang on a docker run that never returns (image pull)", async () => {
    const e = await setup();
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    await e.cfg({ runHang: true });
    await e.call("POST", "/v1/db/restore-tests", base(e));
    expect((await e.call("POST", "/v1/db/restore-tests/notes/run")).status).toBe(202);
    for (let i = 0; i < 200 && !(await e.calls()).some((c) => c.argv[0] === "run"); i++) await new Promise((r) => setTimeout(r, 25));
    const t0 = Date.now();
    await e.restore.stop();
    expect(Date.now() - t0).toBeLessThan(3000);
    const saved = JSON.parse(await readFile(join(e.app.dir, "db-restore-results.json"), "utf8"));
    expect(saved.notes[0]).toMatchObject({ ok: false, reason: "shutdown" });
    await e.app.app.close();
  }, 15_000);

  it("C8: runs wait for the leftover sweep (begin) so it can't remove their container", async () => {
    const e = await setup();
    await writeFile(join(e.dumps, "a.sql"), "SELECT 1;");
    await e.cfg({ psDelayMs: 600 });
    await e.call("POST", "/v1/db/restore-tests", base(e, { sanity: [] }));
    e.restore.begin(3_600_000);
    expect((await e.call("POST", "/v1/db/restore-tests/notes/run")).status).toBe(202);
    await e.restore.idle();
    const verbs = (await e.calls()).map((c) => c.argv[0]);
    expect(verbs.indexOf("ps")).toBeGreaterThanOrEqual(0);
    expect(verbs.indexOf("ps")).toBeLessThan(verbs.indexOf("run"));
    await e.app.app.close();
  });
});
