// Config & secrets, PLAN.md §13.3 C-2: recreating the affected services (argv, token binding incl. the restart choice,
// failure keeps the file, post-check, rate limit), rotation reminder + dedupe, external-change events, redaction of
// stack secrets in incident context, and the leak check over every output.
import { mkdir, mkdtemp, readdir, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { hashToken, newToken } from "../src/auth.ts";
import { ConfigStore } from "../src/config.ts";
import { runRestart, stepsFor } from "../src/configfiles/restart.ts";
import { configFilesRoutes } from "../src/configfiles/routes.ts";
import { RESTART_LIMIT, type ConfigFilesService } from "../src/configfiles/service.ts";
import { AppError } from "../src/errors.ts";
import type { ExecResult } from "../src/exec.ts";
import type { Runner } from "../src/incidents/context.ts";
import { incidentRoutes } from "../src/incidents/routes.ts";
import { IncidentService } from "../src/incidents/service.ts";
import { Notifier, type Notice } from "../src/notify.ts";
import { redact } from "../src/redact.ts";
import { buildApp } from "../src/server.ts";
import type { Stack } from "../src/stacks.ts";

const COMPOSE = `services:
  app:
    image: nginx
    env_file: db.env
    environment:
      DATABASE_URL: postgres://u:\${DB_PASSWORD}@db/x
  db:
    image: postgres
    environment:
      - POSTGRES_PASSWORD=\${DB_PASSWORD:-x}
  worker:
    image: busybox
    command: echo $$HOME \${OTHER}
  cache:
    image: redis
    env_file:
      - path: ./db.env
        required: false
`;
const S1 = "S1-original-Secret-Value-4821";
const ENV = `# web stack\nDB_PASSWORD=${S1}\nOTHER=plain\nAPI_TOKEN='tok-Alpha-Bravo-9931'\n`;
const T0 = Date.parse("2026-11-17T10:00:00Z");
const DAY = 86_400_000;

// --- Fake docker ------------------------------------------------------------------------------------------------------

interface FakeContainer {
  status?: string;
  health?: string;
  restartCount?: number;
}

interface Fake {
  calls: Array<{ cmd: string; args: string[]; cwd?: string; timeoutMs?: number }>;
  compose: (args: string[]) => ExecResult;
  /** project, service → container state (undefined → no container). */
  container: (project: string, service: string, nth: number) => FakeContainer | undefined;
  logs: string[];
  run: Runner;
}

function fakeDocker(): Fake {
  const f: Fake = {
    calls: [],
    compose: () => ({ code: 0, stdout: "", stderr: " Container web-app-1  Recreated\n" }),
    container: () => ({ status: "running" }),
    logs: [],
    run: async (cmd, args, opts = {}) => {
      f.calls.push({ cmd, args, cwd: opts.cwd, timeoutMs: opts.timeoutMs });
      if (cmd !== "docker") return { code: 1, stdout: "", stderr: "" };
      if (args[0] === "compose") return f.compose(args);
      const label = (k: string) => args.find((a) => a.startsWith(`label=com.docker.compose.${k}=`))?.split("=").pop();
      if (args[0] === "ps") {
        const p = label("project");
        const s = label("service");
        if (!p || !s) return { code: 0, stdout: "", stderr: "" };
        return { code: 0, stdout: f.container(p, s, 0) ? `${p}-${s}-1\n` : "", stderr: "" };
      }
      if (args[0] === "inspect") {
        const name = args.at(-1)!;
        const m = /^(.+)-([^-]+)-1$/.exec(name);
        const n = f.calls.filter((c) => c.args[0] === "inspect" && c.args.at(-1) === name).length - 1;
        const c = m ? f.container(m[1]!, m[2]!, n) : undefined;
        if (!c) return { code: 1, stdout: "[]", stderr: "No such object" };
        const status = c.status ?? "running";
        return {
          code: 0,
          stderr: "",
          stdout: JSON.stringify([
            {
              Name: `/${name}`,
              Image: "sha256:abc",
              RestartCount: c.restartCount ?? 0,
              State: { Status: status, Running: status === "running", ExitCode: status === "exited" ? 1 : 0, ...(c.health ? { Health: { Status: c.health } } : {}) },
              Config: { Image: "nginx", Labels: m ? { "com.docker.compose.project": m[1], "com.docker.compose.service": m[2] } : {} },
            },
          ]),
        };
      }
      if (args[0] === "logs") return { code: 0, stdout: f.logs.map((l) => `2026-11-17T10:00:00.000000000Z ${l}`).join("\n") + "\n", stderr: "" };
      return { code: 1, stdout: "", stderr: "unknown" };
    },
  };
  return f;
}

// --- Harness -----------------------------------------------------------------------------------------------------------

async function setup(o: { clock?: { now: number }; fake?: Fake; jobs?: boolean; dir?: string; postCheckMs?: number } = {}) {
  const fresh = !o.dir;
  const dir = o.dir ?? (await realpath(await mkdtemp(join(tmpdir(), "tiphys-c2-"))));
  const web = join(dir, "stack", "web");
  if (fresh) {
    await mkdir(web, { recursive: true });
    await writeFile(join(web, "compose.yaml"), COMPOSE);
    await writeFile(join(web, ".env"), ENV, { mode: 0o600 });
    await writeFile(join(web, "db.env"), "POSTGRES_DB=app\n", { mode: 0o600 });
    await mkdir(join(dir, "extra"));
    await writeFile(join(dir, "extra", "app.env"), "X_TOKEN=extra-Secret-Value-55\n", { mode: 0o600 });
  }
  const store = await ConfigStore.loadOrCreate(join(dir, "cfg", "agent.json"), "atlas");
  const token = newToken();
  await store.update((c) => {
    c.features.configfiles = true;
    c.stacks.roots = [join(dir, "stack")];
    c.configFiles.extraPaths = [join(dir, "extra", "app.env")];
    c.devices.push({ id: "phone", name: "Telefon", tokenHash: hashToken(token), createdAt: new Date().toISOString() });
    return c;
  });
  const clock = o.clock ?? { now: T0 };
  const fake = o.fake ?? fakeDocker();
  const logs: string[] = [];
  const notifier = new Notifier(() => store.get(), () => {});
  const sent: Notice[] = [];
  notifier.observe((n) => void sent.push(n));
  let svc!: ConfigFilesService;
  const app = await buildApp(
    {
      store,
      notifier,
      extraRoutes: [
        configFilesRoutes({
          stateDir: join(dir, "state"),
          now: () => clock.now,
          run: fake.run,
          restart: { postCheckMs: o.postCheckMs ?? 0, pollMs: 5 },
          jobs: o.jobs ?? false,
          onService: (s) => (svc = s),
        }),
      ],
    },
    { logger: true, logStream: { write: (l: string) => void logs.push(l) } },
  );
  const auth = { authorization: `Bearer ${token}` };
  const responses: string[] = [];
  const call = async (method: "GET" | "POST" | "PUT", url: string, payload?: unknown) => {
    const res = await app.inject({ method, url, headers: auth, ...(payload === undefined ? {} : { payload: payload as object }) });
    responses.push(res.body);
    return { status: res.statusCode, body: res.json() as Record<string, any> };
  };
  const idOf = async (label: string) => ((await call("GET", "/v1/config-files")).body.files as Array<{ fileId: string; file: string }>).find((f) => f.file.endsWith(label))!.fileId;
  const preview = async (id: string, ops: unknown[], restart?: "none" | "affected") => {
    const d = await call("GET", `/v1/config-files/${id}`);
    return call("POST", `/v1/config-files/${id}/preview`, { baseHash: d.body.hash, ops, ...(restart ? { restart } : {}) });
  };
  const events = async () => (await notifier.events!.list()).map((e) => ({ key: e.key, params: e.params }));
  return { dir, web, app, store, notifier, sent, fake, clock, logs, call, idOf, preview, events, responses, svc: () => svc };
}

const composeCalls = (f: Fake) => f.calls.filter((c) => c.args[0] === "compose");

// --- Restart -------------------------------------------------------------------------------------------------------------

describe("restart: affected", () => {
  it("runs exactly `docker compose -f … up -d --no-deps <services>` in the stack dir after the write", async () => {
    const t = await setup();
    const id = await t.idOf("web/.env");
    const S2 = "S2-new-Secret-Value-forty-chars-long-xyz";
    const p = await t.preview(id, [{ op: "set", key: "DB_PASSWORD", value: S2 }, { op: "set", key: "OTHER", value: "o2" }], "affected");
    expect(p.status, JSON.stringify(p.body)).toBe(200);
    const compose = join(t.web, "compose.yaml");
    expect(p.body).toMatchObject({
      restart: "affected",
      affected: [{ stack: "web", project: "web", services: ["app", "db", "worker"] }],
      restartPlan: [{ stack: "web", project: "web", services: ["app", "db", "worker"], argv: ["docker", "compose", "-f", compose, "up", "-d", "--no-deps", "app", "db", "worker"] }],
    });
    expect(composeCalls(t.fake)).toEqual([]);
    const s = await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true, restart: "affected" });
    expect(s.status, JSON.stringify(s.body)).toBe(200);
    expect(await readFile(join(t.web, ".env"), "utf8")).toContain(`DB_PASSWORD=${S2}`);
    expect(composeCalls(t.fake)).toEqual([{ cmd: "docker", args: ["compose", "-f", compose, "up", "-d", "--no-deps", "app", "db", "worker"], cwd: t.web, timeoutMs: 180_000 }]);
    expect(s.body).toMatchObject({
      restart: "affected",
      recreate: {
        ok: true,
        stacks: [{ stack: "web", project: "web", services: ["app", "db", "worker"], ok: true, code: 0, stderr: "Container web-app-1  Recreated" }],
        services: [
          { stack: "web", service: "app", ok: true, state: "running" },
          { stack: "web", service: "db", ok: true, state: "running" },
          { stack: "web", service: "worker", ok: true, state: "running" },
        ],
      },
    });
    expect(s.body.restore).toBeUndefined();
    // Post-check looked up the containers by compose labels, excluding one-off `compose run` containers.
    expect(t.fake.calls.find((c) => c.args[0] === "ps")!.args).toEqual([
      "ps", "-a", "--filter", "label=com.docker.compose.project=web", "--filter", "label=com.docker.compose.service=app", "--filter", "label=com.docker.compose.oneoff=False", "--format", "{{.Names}}",
    ]);
    const ev = (await t.events()).find((e) => e.key === "config.saved");
    expect(ev!.params).toEqual({ file: "web/.env", keys: "DB_PASSWORD,OTHER", backupId: s.body.backupId, restart: "ok", services: "app,db,worker" });
    const audit = (await readFile(join(t.dir, "cfg", "audit.jsonl"), "utf8")).split("\n").filter(Boolean).map((l) => JSON.parse(l));
    expect(audit.find((e) => e.method === "PUT" && e.status === 200).detail).toMatchObject({ file: "web/.env", restart: "ok" });
    // env_file → the services loading it
    const db = await t.idOf("web/db.env");
    const p2 = await t.preview(db, [{ op: "set", key: "POSTGRES_DB", value: "x" }], "affected");
    const s2 = await t.call("PUT", `/v1/config-files/${db}`, { previewToken: p2.body.previewToken, confirm: true, restart: "affected" });
    expect(s2.status).toBe(200);
    expect(composeCalls(t.fake).at(-1)!.args).toEqual(["compose", "-f", compose, "up", "-d", "--no-deps", "app", "cache"]);
    // A file outside any stack has nothing to restart.
    const extra = await t.idOf("extra/app.env");
    expect((await t.preview(extra, [{ op: "set", key: "X_TOKEN", value: "y" }], "affected")).body.error.code).toBe("agent.configfiles.nothingToRestart");
    await t.app.close();
  });

  it("binds the restart choice to the token: none ↔ affected can't be swapped, and the token is spent", async () => {
    const t = await setup();
    const id = await t.idOf("web/.env");
    const ops = [{ op: "set", key: "OTHER", value: "x1" }];
    const a = await t.preview(id, ops);
    const r1 = await t.call("PUT", `/v1/config-files/${id}`, { previewToken: a.body.previewToken, confirm: true, restart: "affected" });
    expect(r1.status).toBe(409);
    expect(r1.body.error.code).toBe("agent.preview.invalid");
    expect((await t.call("PUT", `/v1/config-files/${id}`, { previewToken: a.body.previewToken, confirm: true })).body.error.code).toBe("agent.preview.invalid");
    const b = await t.preview(id, ops, "affected");
    expect((await t.call("PUT", `/v1/config-files/${id}`, { previewToken: b.body.previewToken, confirm: true, restart: "none" })).body.error.code).toBe("agent.preview.invalid");
    expect((await t.call("PUT", `/v1/config-files/${id}`, { previewToken: b.body.previewToken, confirm: true, restart: "affected" })).body.error.code).toBe("agent.preview.invalid");
    expect(await readFile(join(t.web, ".env"), "utf8")).toBe(ENV);
    expect(composeCalls(t.fake)).toEqual([]);
    // Restore: same binding.
    const c = await t.preview(id, ops);
    expect((await t.call("PUT", `/v1/config-files/${id}`, { previewToken: c.body.previewToken, confirm: true })).status).toBe(200);
    const backupId = (await t.call("GET", `/v1/config-files/${id}/backups`)).body.backups[0].id;
    const rp = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId });
    expect((await t.call("POST", `/v1/config-files/${id}/restore`, { backupId, previewToken: rp.body.previewToken, confirm: true, restart: "affected" })).body.error.code).toBe("agent.preview.invalid");
    const rp2 = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId, restart: "affected" });
    expect(rp2.body.restartPlan[0].services).toEqual(["worker"]);
    const rr = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId, previewToken: rp2.body.previewToken, confirm: true, restart: "affected" });
    expect(rr.status).toBe(200);
    expect(rr.body.recreate.ok).toBe(true);
    expect(composeCalls(t.fake).map((x) => x.args.slice(-4))).toEqual([["up", "-d", "--no-deps", "worker"]]);
    expect((await t.events()).find((e) => e.key === "config.restored")!.params).toMatchObject({ restart: "ok", services: "worker", backupId });
    await t.app.close();
  });

  it("failure keeps the file saved, returns the backup to restore, redacts stderr and notifies (names only)", async () => {
    const fake = fakeDocker();
    const S2 = "S2-failing-Secret-Value-Zq81";
    fake.compose = () => ({ code: 1, stdout: "", stderr: `\x1b[31merror\x1b[0m: service "app" refused value ${S2}\n` });
    const t = await setup({ fake });
    const id = await t.idOf("web/.env");
    const p = await t.preview(id, [{ op: "set", key: "DB_PASSWORD", value: S2 }], "affected");
    const s = await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true, restart: "affected" });
    expect(s.status).toBe(200);
    expect(await readFile(join(t.web, ".env"), "utf8")).toContain(`DB_PASSWORD=${S2}`);
    expect(s.body.recreate).toMatchObject({ ok: false, stage: "command", stacks: [{ ok: false, code: 1 }] });
    expect(s.body.recreate.stacks[0].stderr).toBe('error: service "app" refused value [GİZLİ:DB_PASSWORD]');
    expect(s.body.recreate.services.map((x: { service: string; state: string }) => `${x.service}:${x.state}`)).toEqual(["app:notRun", "db:notRun"]);
    expect(s.body.restore).toEqual({ route: `POST /v1/config-files/${id}/restore`, backupId: s.body.backupId });
    expect(await readFile(join(t.dir, "state", "config-backups", id, s.body.backupId), "utf8")).toBe(ENV);
    expect(JSON.stringify(s.body)).not.toContain(S2);
    await new Promise((r) => setTimeout(r, 10));
    expect(t.sent.map((n) => ({ key: n.key, params: n.params, data: n.data }))).toEqual([
      { key: "config.restartFailed", params: { host: "atlas", file: "web/.env", services: "app,db", stage: "command", backupId: s.body.backupId }, data: { fileId: id, backupId: s.body.backupId } },
    ]);
    expect((await t.events()).find((e) => e.key === "config.saved")!.params).toMatchObject({ restart: "failed", stage: "command", failed: "app,db" });
    // The hint works: restoring that backup brings the old value back.
    const rp = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: s.body.backupId });
    const rr = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: s.body.backupId, previewToken: rp.body.previewToken, confirm: true });
    expect(rr.status).toBe(200);
    expect(await readFile(join(t.web, ".env"), "utf8")).toBe(ENV);
    await t.app.close();
  });

  it("post-check: exited, unhealthy and restarting fail; healthy passes early; a missing container fails", async () => {
    const fake = fakeDocker();
    const t = await setup({ fake, postCheckMs: 200 });
    const id = await t.idOf("web/.env");
    const states: Record<string, (n: number) => FakeContainer | undefined> = {
      app: () => ({ status: "exited" }),
      db: () => ({ status: "running", health: "unhealthy" }),
      worker: (n) => ({ status: "running", restartCount: n }),
    };
    fake.container = (_p, s, n) => states[s]?.(n);
    const p = await t.preview(id, [{ op: "set", key: "DB_PASSWORD", value: "S3-postcheck-Value-1234" }, { op: "set", key: "OTHER", value: "o" }], "affected");
    const s = await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true, restart: "affected" });
    expect(s.body.recreate).toMatchObject({ ok: false, stage: "postCheck", stacks: [{ ok: true }] });
    expect(s.body.recreate.services).toEqual([
      { stack: "web", service: "app", ok: false, state: "exited" },
      { stack: "web", service: "db", ok: false, state: "running/unhealthy" },
      { stack: "web", service: "worker", ok: false, state: "restarting" },
    ]);
    expect(s.body.restore.backupId).toBe(s.body.backupId);
    // Healthy passes before the window ends; no container at all fails at the end.
    const steps = [{ stack: "web", project: "web", services: ["app"], argv: ["docker", "compose", "up"], cwd: t.web }];
    fake.container = () => ({ status: "running", health: "healthy" });
    let t0 = Date.now();
    expect((await runRestart(steps, { run: fake.run, postCheckMs: 5000, pollMs: 10 })).services).toEqual([{ stack: "web", service: "app", ok: true, state: "running/healthy" }]);
    expect(Date.now() - t0).toBeLessThan(2000);
    fake.container = () => ({ status: "running", health: "starting" });
    t0 = Date.now();
    expect((await runRestart(steps, { run: fake.run, postCheckMs: 100, pollMs: 10 })).services[0]).toMatchObject({ ok: true, state: "running/starting" });
    expect(Date.now() - t0).toBeGreaterThanOrEqual(90);
    fake.container = () => undefined;
    expect((await runRestart(steps, { run: fake.run, postCheckMs: 50, pollMs: 10 })).services[0]).toMatchObject({ ok: false, state: "missing" });
    // A timeout is a command failure: nothing is checked.
    const timeout = await runRestart(steps, { run: async () => Promise.reject(new AppError("agent.exec.timeout", 504)) });
    expect(timeout).toMatchObject({ ok: false, stage: "command", stacks: [{ ok: false, code: -1, stderr: "agent.exec.timeout" }], services: [{ service: "app", ok: false, state: "notRun" }] });
    await t.app.close();
  });

  it("bounds services to the plan, the stack and the current computation", async () => {
    const stack: Stack = { id: "web", project: "web", dir: "/s/web", root: "/s", composeFiles: ["/s/web/compose.yaml", "/s/web/compose.override.yaml"], envFiles: [], services: ["app", "db", "-x"] };
    const plan = [{ stack: "web", project: "web", services: ["app", "db", "evil;rm", "-x", "gone"] }, { stack: "other", project: "other", services: ["app"] }];
    const now = [{ stack: "web", project: "web", services: ["app", "-x", "gone", "evil;rm"] }];
    expect(stepsFor(plan, [stack], now)).toEqual([
      { stack: "web", project: "web", services: ["app"], argv: ["docker", "compose", "-f", "/s/web/compose.yaml", "-f", "/s/web/compose.override.yaml", "up", "-d", "--no-deps", "app"], cwd: "/s/web" },
    ]);
    expect(stepsFor(plan, [stack], [])).toEqual([]);
  });

  it("services no longer affected at save time are skipped and reported", async () => {
    const t = await setup();
    const id = await t.idOf("web/.env");
    const p = await t.preview(id, [{ op: "set", key: "OTHER", value: "z" }], "affected");
    expect(p.body.restartPlan[0].services).toEqual(["worker"]);
    await writeFile(join(t.web, "compose.yaml"), COMPOSE.replace("command: echo $$HOME ${OTHER}", "command: echo hi"));
    const s = await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true, restart: "affected" });
    expect(s.body.recreate).toMatchObject({ ok: false, stage: "command", stacks: [], services: [], skipped: [{ stack: "web", services: ["worker"] }] });
    expect(composeCalls(t.fake)).toEqual([]);
    await t.app.close();
  });

  it(`rate limits restarts to ${RESTART_LIMIT} per 10 minutes per device, before the token is spent`, async () => {
    const clock = { now: T0 };
    const t = await setup({ clock });
    const id = await t.idOf("web/.env");
    for (let i = 0; i < RESTART_LIMIT; i++) {
      const p = await t.preview(id, [{ op: "set", key: "OTHER", value: `r${i}` }], "affected");
      expect((await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true, restart: "affected" })).status).toBe(200);
    }
    clock.now = T0 + 9 * 60_000;
    const p = await t.preview(id, [{ op: "set", key: "OTHER", value: "late" }], "affected");
    const r = await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true, restart: "affected" });
    expect(r.status).toBe(429);
    expect(r.body.error).toEqual({ code: "agent.configfiles.restartRateLimited", params: { limit: RESTART_LIMIT, windowSeconds: 600 } });
    expect(await readFile(join(t.web, ".env"), "utf8")).toContain(`OTHER=r${RESTART_LIMIT - 1}`);
    // Saves without restart aren't limited.
    const q = await t.preview(id, [{ op: "set", key: "API_TOKEN", value: "tok-new-Value-8812" }]);
    expect((await t.call("PUT", `/v1/config-files/${id}`, { previewToken: q.body.previewToken, confirm: true })).status).toBe(200);
    // Once the window has passed the same token is still live (the 429 didn't spend it; within its 120 s): the save
    // gets as far as the hash check, which fails only because of the save above (conflict, not preview.invalid).
    clock.now = T0 + 10 * 60_000 + 1000;
    const again = await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true, restart: "affected" });
    expect(again.body.error.code).toBe("agent.configfiles.conflict");
    expect(composeCalls(t.fake)).toHaveLength(RESTART_LIMIT);
    await t.app.close();
  });
});

// --- Rotation ------------------------------------------------------------------------------------------------------------

describe("rotation tracking", () => {
  it("notifies due secrets once per file per day (also across restarts), names only", async () => {
    const clock = { now: T0 };
    const t = await setup({ clock });
    const id = await t.idOf("web/.env");
    expect((await t.call("PUT", "/v1/secrets/meta", { updates: [{ fileId: id, key: "DB_PASSWORD", maxAgeDays: 30 }, { fileId: id, key: "API_TOKEN", maxAgeDays: 60 }] })).status).toBe(200);
    expect(await t.svc().checkRotation()).toEqual([]);
    clock.now = T0 + 31 * DAY;
    expect(await t.svc().checkRotation()).toEqual([{ fileId: id, file: "web/.env", keys: ["DB_PASSWORD"] }]);
    expect(await t.svc().checkRotation()).toEqual([]);
    expect(t.sent.map((n) => ({ key: n.key, params: n.params, data: n.data }))).toEqual([
      { key: "secret.rotationDue", params: { host: "atlas", file: "web/.env", keys: "DB_PASSWORD", count: 1 }, data: { fileId: id } },
    ]);
    await t.app.close();
    // Restarted the same day: the startup check doesn't repeat it.
    const t2 = await setup({ clock, dir: t.dir, jobs: true });
    await new Promise((r) => setTimeout(r, 100));
    expect(t2.sent).toEqual([]);
    await t2.app.close();
    // Next day, at startup: both keys due now.
    clock.now = T0 + 61 * DAY;
    const t3 = await setup({ clock, dir: t.dir, jobs: true });
    for (let i = 0; i < 50 && !t3.sent.length; i++) await new Promise((r) => setTimeout(r, 20));
    expect(t3.sent.map((n) => n.params)).toEqual([{ host: "atlas", file: "web/.env", keys: "API_TOKEN,DB_PASSWORD", count: 2 }]);
    const meta = JSON.parse(await readFile(join(t.dir, "cfg", "secrets-meta.json"), "utf8"));
    expect(meta.files[id].rotationNotifiedOn).toMatch(/^2027-01-1[67]$/);
    await t3.app.close();
  });

  it("detects values changed outside Tiphys: lastChangedAt resets, event with names only, no longer due", async () => {
    const clock = { now: T0 };
    const t = await setup({ clock });
    const id = await t.idOf("web/.env");
    await t.call("PUT", "/v1/secrets/meta", { updates: [{ fileId: id, key: "DB_PASSWORD", maxAgeDays: 30 }] });
    clock.now = T0 + 40 * DAY;
    const ROTATED = "rotated-by-hand-Value-77";
    await writeFile(join(t.web, ".env"), ENV.replace(S1, ROTATED));
    expect(await t.svc().checkRotation()).toEqual([]);
    expect(t.sent).toEqual([]);
    const ev = (await t.events()).filter((e) => e.key === "secret.changedExternally");
    expect(ev).toEqual([{ key: "secret.changedExternally", params: { file: "web/.env", keys: "DB_PASSWORD", count: 1 } }]);
    const m = (await t.call("GET", "/v1/secrets/meta")).body.files.find((f: { fileId: string }) => f.fileId === id);
    expect(m.keys.find((k: { key: string }) => k.key === "DB_PASSWORD")).toMatchObject({ changedBy: "external", lastChangedAt: new Date(clock.now).toISOString(), due: false });
    // Seen once: another scan doesn't repeat the event; a save through Tiphys isn't "external".
    await t.svc().scanAll();
    const p = await t.preview(id, [{ op: "set", key: "DB_PASSWORD", value: "via-tiphys-Value-99" }]);
    await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true });
    expect((await t.events()).filter((e) => e.key === "secret.changedExternally")).toHaveLength(1);
    await t.app.close();
  });
});

// --- Redaction -----------------------------------------------------------------------------------------------------------

describe("redaction integration", () => {
  it("incident context has the stack's current secret values replaced (after a save and a rescan too)", async () => {
    const fake = fakeDocker();
    const t = await setup({ fake });
    const NEW = "Fresh-Saved-Secret-Value-6610";
    const EXT = "External-Edit-Secret-Value-3377";
    const id = await t.idOf("web/.env");
    const p = await t.preview(id, [{ op: "set", key: "API_TOKEN", value: NEW }]);
    expect((await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true })).status).toBe(200);
    // A value changed by hand is picked up by the periodic rescan.
    await writeFile(join(t.dir, "extra", "app.env"), `X_TOKEN=${EXT}\n`);
    await t.svc().scanAll();
    fake.logs = [`db auth failed for password ${S1}`, `token=${NEW} rejected`, `ext ${EXT} used`, "plain line"];
    fake.container = () => ({ status: "exited" });
    const store = t.store;
    const inc = await IncidentService.open({
      store,
      notifier: t.notifier,
      dir: join(t.dir, "incidents"),
      contextDelayMs: 0,
      postCheckDelayMs: 0,
      run: fake.run,
      discover: async () => [],
    });
    const app2 = await buildApp({ store, notifier: t.notifier, extraRoutes: [incidentRoutes(inc)] });
    await t.notifier.send({ key: "docker.died", params: { host: "atlas", container: "web-app-1", code: 1 }, context: { project: "web", service: "app" } });
    await inc.idle();
    const got = await inc.get(inc.list()[0]!.id);
    const lines = got.context?.logs?.lines.join("\n") ?? "";
    expect(lines).toContain("[GİZLİ:DB_PASSWORD]");
    expect(lines).toContain("[GİZLİ:API_TOKEN]");
    expect(lines).toContain("[GİZLİ:X_TOKEN]");
    for (const v of [S1, NEW, EXT]) expect(JSON.stringify(got)).not.toContain(v);
    // A file that disappears stops being a source.
    await rm(join(t.dir, "extra", "app.env"));
    await t.svc().scanAll();
    expect(redact(`ext ${EXT}`)).toBe(`ext ${EXT}`);
    await app2.close();
    await inc.close();
    await t.app.close();
  });
});

// --- Leak ------------------------------------------------------------------------------------------------------------------

describe("LEAK (C-2)", () => {
  it("a secret is never in logs, events, audit, notifications or responses through restart, failure and rotation", async () => {
    const SECRET = "LeakCanary-C2-9vQ4Lm7Tx3Hd";
    const fake = fakeDocker();
    fake.compose = (args) => ({ code: args.includes("app") ? 1 : 0, stdout: `env DB_PASSWORD=${SECRET}\n`, stderr: `warning: value ${SECRET} looks weak\n` });
    const clock = { now: T0 };
    const t = await setup({ fake, clock });
    const id = await t.idOf("web/.env");
    await t.call("PUT", "/v1/secrets/meta", { updates: [{ fileId: id, key: "DB_PASSWORD", maxAgeDays: 1 }] });
    const p = await t.preview(id, [{ op: "set", key: "DB_PASSWORD", value: SECRET }], "affected");
    const s = await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true, restart: "affected" });
    expect(s.body.recreate.ok).toBe(false);
    // Changed by hand to the secret again after a rotation in between, then due.
    const p2 = await t.preview(id, [{ op: "set", key: "DB_PASSWORD", value: "intermediate-Value-11" }, { op: "set", key: "OTHER", value: "q" }], "affected");
    await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p2.body.previewToken, confirm: true, restart: "affected" });
    const text = await readFile(join(t.web, ".env"), "utf8");
    await writeFile(join(t.web, ".env"), text.replace("intermediate-Value-11", SECRET));
    clock.now = T0 + 3 * DAY;
    await t.svc().checkRotation();
    clock.now = T0 + 5 * DAY;
    expect((await t.svc().checkRotation()).length).toBe(1);
    const rp = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: s.body.backupId, restart: "affected" });
    await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: s.body.backupId, previewToken: rp.body.previewToken, confirm: true, restart: "affected" });
    await new Promise((r) => setTimeout(r, 30));
    await t.app.close();

    const keys = t.sent.map((n) => n.key);
    expect(keys).toEqual(expect.arrayContaining(["config.restartFailed", "secret.rotationDue"]));
    expect(JSON.stringify(t.sent)).not.toContain(SECRET);
    for (const r of t.responses) expect(r).not.toContain(SECRET);
    expect(t.logs.join("")).not.toContain(SECRET);
    const scan = async (d: string): Promise<string[]> => {
      const out: string[] = [];
      for (const e of await readdir(d, { withFileTypes: true })) {
        const q = join(d, e.name);
        if (q === join(t.web, ".env") || q.startsWith(join(t.dir, "state", "config-backups"))) continue;
        if (e.isDirectory()) out.push(...(await scan(q)));
        else if (e.isFile()) out.push(q);
      }
      return out;
    };
    const all = await scan(t.dir);
    expect(all).toEqual(expect.arrayContaining([join(t.dir, "cfg", "audit.jsonl"), join(t.dir, "cfg", "events.jsonl"), join(t.dir, "cfg", "secrets-meta.json")]));
    for (const f of all) expect(await readFile(f, "utf8"), f).not.toContain(SECRET.slice(0, 14));
    const events = await readFile(join(t.dir, "cfg", "events.jsonl"), "utf8");
    for (const k of ["config.saved", "config.restored", "config.restartFailed", "secret.rotationDue", "secret.changedExternally"]) expect(events, k).toContain(`"${k}"`);
  });
});
