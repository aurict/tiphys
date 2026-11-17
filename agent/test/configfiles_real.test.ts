// Real docker on this machine (PLAN.md §13.3 C-2): a temporary compose stack whose service loads an env_file; a value
// changed through the API with restart: "affected" must be in the recreated container's environment. Needs
// TIPHYS_REAL=1, a local docker with compose and the alpine image (never pulled). Only touches what it creates (project
// tiphys-c2test in a temp dir); everything is removed afterwards.
import { mkdir, mkdtemp, readFile, realpath, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { hashToken, newToken } from "../src/auth.ts";
import { ConfigStore } from "../src/config.ts";
import { configFilesRoutes } from "../src/configfiles/routes.ts";
import { run } from "../src/exec.ts";
import { Notifier } from "../src/notify.ts";
import { buildApp } from "../src/server.ts";

const real = process.env.TIPHYS_REAL === "1";
const P = "tiphys-c2test";
const OLD = "c2-old-Test-Value-1111";
const NEW = "c2-new-Test-Value-2222";

const docker = (args: string[], cwd?: string) => run("docker", args, { allowFail: true, timeoutMs: 120_000, ...(cwd ? { cwd } : {}) });
const envOf = async (container: string) => {
  const r = await docker(["inspect", "--format", "{{json .Config.Env}}", container]);
  return r.code === 0 ? (JSON.parse(r.stdout) as string[]) : null;
};

describe.skipIf(!real)("restart affected with real docker", () => {
  it(
    "a saved env_file value reaches the recreated container",
    async () => {
      const dir = await realpath(await mkdtemp(join(tmpdir(), "tiphys-c2-real-")));
      const stackDir = join(dir, "stack", P);
      await mkdir(stackDir, { recursive: true });
      await writeFile(
        join(stackDir, "compose.yaml"),
        `services:\n  app:\n    image: alpine\n    pull_policy: never\n    command: ["sleep", "3600"]\n    init: true\n    env_file: app.env\n`,
      );
      await writeFile(join(stackDir, "app.env"), `C2_TEST_TOKEN=${OLD}\nPLAIN=1\n`, { mode: 0o600 });
      let app: Awaited<ReturnType<typeof buildApp>> | undefined;
      try {
        const up = await docker(["compose", "up", "-d"], stackDir);
        expect(up.code, up.stderr).toBe(0);
        const name = `${P}-app-1`;
        expect(await envOf(name)).toContain(`C2_TEST_TOKEN=${OLD}`);

        const store = await ConfigStore.loadOrCreate(join(dir, "cfg", "agent.json"), "test-pc");
        const token = newToken();
        await store.update((c) => {
          c.features.configfiles = true;
          c.stacks.roots = [join(dir, "stack")];
          c.devices.push({ id: "phone", name: "Telefon", tokenHash: hashToken(token), createdAt: new Date().toISOString() });
          return c;
        });
        app = await buildApp({ store, notifier: new Notifier(() => store.get(), () => {}), extraRoutes: [configFilesRoutes({ stateDir: join(dir, "state"), jobs: false })] });
        const auth = { authorization: `Bearer ${token}` };
        const call = async (method: "GET" | "POST" | "PUT", url: string, payload?: object) => {
          const res = await app!.inject({ method, url, headers: auth, ...(payload ? { payload } : {}) });
          return { status: res.statusCode, body: res.json() as Record<string, any> };
        };
        const files = (await call("GET", "/v1/config-files")).body.files as Array<{ fileId: string; file: string }>;
        const id = files.find((f) => f.file === `${P}/app.env`)!.fileId;
        const d = await call("GET", `/v1/config-files/${id}`);
        const p = await call("POST", `/v1/config-files/${id}/preview`, { baseHash: d.body.hash, ops: [{ op: "set", key: "C2_TEST_TOKEN", value: NEW }], restart: "affected" });
        expect(p.status).toBe(200);
        expect(p.body.restartPlan).toEqual([{ stack: P, project: P, services: ["app"], argv: ["docker", "compose", "-f", join(stackDir, "compose.yaml"), "up", "-d", "--no-deps", "app"] }]);
        const s = await call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true, restart: "affected" });
        expect(s.status).toBe(200);
        expect(s.body.recreate.ok, JSON.stringify(s.body.recreate.services)).toBe(true);
        expect(s.body.recreate.services).toEqual([{ stack: P, service: "app", ok: true, state: "running" }]);
        expect(JSON.stringify(s.body)).not.toContain(NEW);
        const env = await envOf(name);
        expect(env).toContain(`C2_TEST_TOKEN=${NEW}`);
        expect(env).not.toContain(`C2_TEST_TOKEN=${OLD}`);
        expect(await readFile(join(stackDir, "app.env"), "utf8")).toBe(`C2_TEST_TOKEN=${NEW}\nPLAIN=1\n`);
      } finally {
        await app?.close();
        await docker(["compose", "down", "--remove-orphans", "--timeout", "1"], stackDir);
        await rm(dir, { recursive: true, force: true });
      }
    },
    180_000,
  );
});
