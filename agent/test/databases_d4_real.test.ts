// Real restore test (D-4): needs TIPHYS_REAL=1 and a local docker. A throwaway postgres:16-alpine source container
// (random name/password, no published port) gets a table; pg_dump writes a dump into a temp dir; the restore test must
// pass; a corrupted dump must fail with a clear reason. Everything created here is removed afterwards.
import { randomBytes } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { dbRoutes } from "../src/db/routes.ts";
import type { RestoreService } from "../src/db/restore.ts";
import { run } from "../src/exec.ts";
import { testApp } from "./helpers.ts";

const real = process.env.TIPHYS_REAL === "1";
const src = `tiphys-d4-src-${randomBytes(4).toString("hex")}`;
let dir = "";

const docker = (args: string[], timeoutMs = 120_000, env?: NodeJS.ProcessEnv) => run("docker", args, { timeoutMs, ...(env ? { env } : {}) });

describe.skipIf(!real)("D-4 gerçek geri yükleme testi", () => {
  beforeAll(async () => {
    dir = await mkdtemp(join(tmpdir(), "tiphys-d4-real-"));
    await docker(["run", "-d", "--rm", "--network", "none", "-e", "POSTGRES_PASSWORD", "--name", src, "postgres:16-alpine"], 300_000, { POSTGRES_PASSWORD: randomBytes(12).toString("hex") });
    for (let i = 0; i < 60; i++) {
      const r = await run("docker", ["exec", src, "pg_isready", "-h", "127.0.0.1", "-U", "postgres"], { allowFail: true });
      if (r.code === 0) break;
      await new Promise((r) => setTimeout(r, 1000));
    }
    await docker(["exec", src, "psql", "-X", "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-c", "CREATE TABLE notes(id int primary key, body text); INSERT INTO notes SELECT g, 'n' || g FROM generate_series(1,25) g;"]);
  }, 400_000);

  afterAll(async () => {
    await run("docker", ["rm", "-f", src], { allowFail: true }).catch(() => {});
    if (dir) await rm(dir, { recursive: true, force: true });
  });

  it("geçerli döküm geçer; bozuk döküm açık nedenle kalır; kapsayıcı kalmaz", async () => {
    let restore!: RestoreService;
    const app = await testApp((c) => ({ ...c, features: { ...c.features, databases: true }, allowedRoots: [dir] }), [dbRoutes({ onRestore: (r) => (restore = r), restoreTimer: false })]);
    const dump = join(dir, "notes.sql");
    const out = await docker(["exec", src, "pg_dump", "-U", "postgres", "--no-owner", "postgres"]);
    await writeFile(dump, out.stdout);
    const call = async (method: "GET" | "POST", url: string, payload?: object) => {
      const r = await app.app.inject({ method, url, headers: app.auth, ...(payload ? { payload } : {}) });
      return { status: r.statusCode, body: r.body ? JSON.parse(r.body) : {} };
    };
    const made = await call("POST", "/v1/db/restore-tests", {
      id: "real", name: "Real", engine: "postgres", image: "postgres:16-alpine", dumpGlob: join(dir, "*.sql"), format: "sql",
      sanity: [{ sql: "SELECT count(*) FROM notes", expect: { op: "=", value: 25 } }],
    });
    expect(made.status).toBe(201);
    expect((await call("POST", "/v1/db/restore-tests/real/run")).status).toBe(202);
    await restore.idle();
    const ok = (await call("GET", "/v1/db/restore-tests/real/results")).body.results[0];
    expect(ok, JSON.stringify(ok)).toMatchObject({ ok: true, rowsChecked: 1, failures: [] });

    await writeFile(dump, (await readFile(dump, "utf8")).replace("CREATE TABLE public.notes", "CREATE TABEL public.notes"));
    await call("POST", "/v1/db/restore-tests/real/run");
    await restore.idle();
    const bad = (await call("GET", "/v1/db/restore-tests/real/results")).body.results[0];
    expect(bad, JSON.stringify(bad)).toMatchObject({ ok: false, reason: "restoreFailed" });
    expect(bad.detail).toMatch(/syntax error/i);
    expect(app.sent.map((n) => (n as { key: string }).key).filter((k) => k.startsWith("db.restoreTest"))).toEqual(["db.restoreTest.ok", "db.restoreTest.failed"]);

    const left = await run("docker", ["ps", "-aq", "--filter", "name=tiphys-restore-real-"], {});
    expect(left.stdout.trim()).toBe("");
    await app.app.close();
  }, 400_000);
});
