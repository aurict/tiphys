// §13 review fixes (configfiles + analysis queue): per-caller analysis cap, secrets-meta flush chain recovery, reads
// serialized with writes (no false external change), backup only after the write's preconditions, rotation flag only
// after a successful send, `$` in values written so compose reads it literally.
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it, vi } from "vitest";

const gate = vi.hoisted(() => ({ armed: false, release: Promise.resolve() as Promise<unknown> }));
vi.mock("../src/configfiles/files.ts", async (orig) => {
  const m = await orig<typeof import("../src/configfiles/files.ts")>();
  return {
    ...m,
    // The next service-level read, once armed, holds its result until `release` (simulates a slow reader).
    readChecked: async (f: Parameters<typeof m.readChecked>[0]) => {
      const r = await m.readChecked(f);
      if (gate.armed) {
        gate.armed = false;
        await gate.release;
      }
      return r;
    },
  };
});

import { AnalysisQueue } from "../src/analysis/jobs.ts";
import { bundleSchema, type AnalysisBundle } from "../src/analysis/schema.ts";
import { ConfigStore } from "../src/config.ts";
import { applyOps, effective, parseEnv } from "../src/configfiles/dotenv.ts";
import { backupDir } from "../src/configfiles/files.ts";
import { SecretsMeta } from "../src/configfiles/meta.ts";
import { ConfigFilesService } from "../src/configfiles/service.ts";
import type { EventLog } from "../src/events.ts";
import type { Notifier, Notice } from "../src/notify.ts";

const ENV = "DB_PASSWORD=S1-original-Secret-Value-4821\nOTHER=plain\n";

async function setup(o: { notifier?: Notifier; now?: () => number } = {}) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-cf-review-"));
  const web = join(dir, "stack", "web");
  await mkdir(web, { recursive: true });
  await writeFile(join(web, "compose.yaml"), "services:\n  app:\n    image: nginx\n");
  await writeFile(join(web, ".env"), ENV, { mode: 0o600 });
  const store = await ConfigStore.loadOrCreate(join(dir, "cfg", "agent.json"), "atlas");
  await store.update((c) => {
    c.features.configfiles = true;
    c.stacks.roots = [join(dir, "stack")];
    return c;
  });
  const meta = await SecretsMeta.open(join(dir, "cfg"), o.now);
  const events: Array<{ key: string; params?: Record<string, unknown> }> = [];
  const stateDir = join(dir, "state");
  const svc = new ConfigFilesService({
    store,
    meta,
    stateDir,
    events: { record: async (e: { key: string; params?: Record<string, unknown> }) => void events.push(e) } as unknown as EventLog,
    notifier: o.notifier,
    now: o.now,
  });
  const id = (await svc.list()).files.find((f) => f.file === "web/.env")!.fileId;
  return { dir, web, store, svc, meta, events, stateDir, id, done: () => rm(dir, { recursive: true, force: true }) };
}

describe("analysis queue: per-caller cap (S7)", () => {
  const bundle = (): AnalysisBundle =>
    bundleSchema.parse({
      v: 1,
      incident: { id: "inc-000000000001", host: "atlas", kind: "docker.died", target: "c-1", severity: "critical", status: "open", openedAt: "2026-11-17T10:00:00Z", parts: [] },
      hints: [],
      evidence: [{ id: "log:c-1#1", section: "logs", text: "x" }],
      candidates: [],
      similar: [],
      truncated: [],
    });

  it("allows one waiting job per caller; others still get queue slots", async () => {
    const q = new AnalysisQueue({ run: (_b, o) => new Promise((_, reject) => o.signal.addEventListener("abort", () => reject(o.signal.reason))) });
    q.submit(bundle(), "service:a"); // runs
    q.submit(bundle(), "service:a"); // waits
    expect(() => q.submit(bundle(), "service:a")).toThrow(expect.objectContaining({ code: "agent.analysis.busy", status: 429, params: expect.objectContaining({ reason: "callerWaiting" }) }));
    expect(q.submit(bundle(), "service:b").status).toBe("queued");
    await q.close();
  });
});

describe("secrets meta flush (C4)", () => {
  it("a failed write doesn't make every later flush fail", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-cf-meta-"));
    const meta = await SecretsMeta.open(dir);
    // rename() onto a non-empty directory fails.
    await mkdir(join(meta.path, "x"), { recursive: true });
    await expect(meta.flush()).rejects.toThrow();
    await rm(meta.path, { recursive: true });
    await expect(meta.flush()).resolves.toBeUndefined();
    await rm(dir, { recursive: true, force: true });
  });
});

describe("config files service", () => {
  it("a read racing a save doesn't analyze stale content after it (C6)", async () => {
    const t = await setup();
    let saved!: () => void;
    gate.release = new Promise<void>((r) => (saved = r));
    let reader: Promise<unknown> | undefined;
    const svc = new ConfigFilesService({
      store: t.store,
      meta: t.meta,
      stateDir: t.stateDir,
      events: { record: async (e: { key: string }) => void t.events.push(e) } as unknown as EventLog,
      hooks: {
        beforeRename: async () => {
          // A list() that starts while the save is writing (it would read the old content).
          gate.armed = true;
          reader = svc.list();
          await new Promise((r) => setTimeout(r, 50));
        },
      },
    });
    const d = await svc.get(t.id);
    const p = await svc.preview(t.id, d.hash, [{ op: "set", key: "DB_PASSWORD", value: "S2-new-Secret-Value-77aa31" }], "phone");
    await svc.save(t.id, p.previewToken, "phone");
    saved();
    await reader;
    gate.armed = false;
    await svc.get(t.id);
    expect(t.events.filter((e) => e.key === "secret.changedExternally")).toEqual([]);
    expect(t.meta.keys(t.id).DB_PASSWORD!.changedBy).toBe("tiphys");
    await t.done();
  });

  it("writes no backup when the write is rejected before commit (C11)", async () => {
    const t = await setup();
    const d = await t.svc.get(t.id);
    // Preview accepts it; the write's own size check rejects it.
    const p = await t.svc.preview(t.id, d.hash, [{ op: "set", key: "OTHER", value: "x".repeat(300 * 1024) }], "phone");
    await expect(t.svc.save(t.id, p.previewToken, "phone")).rejects.toMatchObject({ code: "agent.configfiles.tooLarge" });
    expect(await readdir(backupDir(t.stateDir, t.id)).catch(() => [])).toEqual([]);
    // A successful save still keeps the previous content.
    const p2 = await t.svc.preview(t.id, d.hash, [{ op: "set", key: "OTHER", value: "y" }], "phone");
    const r = await t.svc.save(t.id, p2.previewToken, "phone");
    expect(await readdir(backupDir(t.stateDir, t.id))).toEqual([r.backupId]);
    await t.done();
  });

  it("marks the rotation day only after a successful send (C11)", async () => {
    const DAY = 86_400_000;
    const clock = { now: Date.parse("2026-11-17T10:00:00Z") };
    let fail = true;
    const sent: Notice[] = [];
    const notifier = {
      send: async (n: Notice) => {
        if (fail) throw new Error("push down");
        sent.push(n);
        return 1;
      },
    } as unknown as Notifier;
    const t = await setup({ notifier, now: () => clock.now });
    await t.svc.putMeta([{ fileId: t.id, key: "DB_PASSWORD", maxAgeDays: 30 }]);
    clock.now += 31 * DAY;
    expect(await t.svc.checkRotation()).toEqual([]);
    expect(t.meta.files().find((f) => f.fileId === t.id)!.rotationNotifiedOn).toBeUndefined();
    fail = false;
    expect(await t.svc.checkRotation()).toEqual([{ fileId: t.id, file: "web/.env", keys: ["DB_PASSWORD"] }]);
    expect(sent).toHaveLength(1);
    expect(await t.svc.checkRotation()).toEqual([]);
    await t.done();
  });
});

describe("dotenv: `$` in values (C11)", () => {
  const set = (text: string, key: string, value: string) => applyOps(parseEnv(text), [{ op: "set", key, value }]);

  it("writes a plain `$` literally into unquoted/double-quoted entries, keeps explicit interpolation", () => {
    expect(set("A=old\n", "A", "pa$word")).toBe("A='pa$word'\n");
    expect(set('A="old" # c\n', "A", "pa$word")).toBe("A='pa$word' # c\n");
    expect(set("A=old\n", "A", "it's $x")).toBe('A="it\'s \\$x"\n');
    expect(set("A=old\n", "A", "${OTHER}/x")).toBe("A=${OTHER}/x\n");
    expect(set('A="old"\n', "A", "a$$b")).toBe('A="a$$b"\n');
    // Read back: literal `\$` in double quotes is `$$` in the value model (compose's escape).
    for (const v of ["pa$word", "${OTHER}/x"]) expect(effective(parseEnv(set("A=old\n", "A", v))).get("A")!.value).toBe(v);
    expect(effective(parseEnv(set("A=old\n", "A", "it's $x"))).get("A")!.value).toBe("it's $$x");
  });

  let compose = false;
  try {
    execFileSync("docker", ["compose", "version"], { stdio: "ignore", timeout: 5000 });
    compose = true;
  } catch {}

  it.skipIf(!compose)("docker compose reads the written values as intended (no containers)", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-cf-compose-"));
    let env = "OTHER=xyz\nA=old\nB=\"old\"\nC=old\n";
    env = set(env, "A", "pa$word");
    env = set(env, "B", "pa$word");
    env = set(env, "C", "${OTHER}/x");
    await writeFile(join(dir, ".env"), env);
    await writeFile(join(dir, "compose.yaml"), "services:\n  s:\n    image: busybox\n    environment:\n      A: ${A}\n      B: ${B}\n      C: ${C}\n");
    const out = execFileSync("docker", ["compose", "config", "--format", "json"], { cwd: dir, encoding: "utf8", timeout: 20_000 });
    const envOut = JSON.parse(out).services.s.environment;
    // compose's config output escapes a literal `$` as `$$`.
    expect(envOut).toEqual({ A: "pa$$word", B: "pa$$word", C: "xyz/x" });
    await rm(dir, { recursive: true, force: true });
  });
});
