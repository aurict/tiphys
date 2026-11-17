// §13 review fixes (incident room, redaction, stacks, runTool): S4, S5, C1, C2, C3, C9, C10, C11. S3 is covered in
// incidents_deploys.test.ts (tag names, tracker-verified rollback, shared image reference warning).
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { AnalysisQueue } from "../src/analysis/jobs.ts";
import { ConfigStore, type AgentConfig } from "../src/config.ts";
import { buildBundle } from "../src/incidents/bundle.ts";
import { boundLines, type Runner } from "../src/incidents/context.ts";
import { DeployTracker } from "../src/incidents/deploys.ts";
import { IncidentService } from "../src/incidents/service.ts";
import { IncidentStore } from "../src/incidents/store.ts";
import type { Incident } from "../src/incidents/types.ts";
import { runTool } from "../src/llm/claude_print.ts";
import { Notifier, type Notice } from "../src/notify.ts";
import { redact, setKnownSecrets } from "../src/redact.ts";
import { readStack, stackForProject, type Stack } from "../src/stacks.ts";

const T0 = Date.parse("2026-11-17T10:00:00Z");
afterEach(() => setKnownSecrets("test", []));

// ---- a stub docker (no processes) ----

type World = { containers: Record<string, unknown>; logs: Record<string, string[]>; block?: Partial<Record<string, () => Promise<void>>>; calls: string[][] };

function stubRun(w: World): Runner {
  return (async (cmd: string, args: string[]) => {
    w.calls.push([cmd, ...args]);
    const ok = (stdout = "") => ({ code: 0, stdout, stderr: "" });
    if (cmd !== "docker") return ok();
    const [c, ...rest] = args;
    await w.block?.[c!]?.();
    if (c === "inspect") {
      const found = rest.filter((a, i) => !a.startsWith("-") && rest[i - 1] !== "--type").map((n) => w.containers[n]).filter(Boolean);
      return found.length ? ok(JSON.stringify(found)) : { code: 1, stdout: "[]", stderr: "No such object" };
    }
    if (c === "logs") return ok((w.logs[rest.at(-1)!] ?? []).map((l) => `2026-11-17T10:00:00.000000000Z ${l}`).join("\n") + "\n");
    if (c === "ps") return ok(Object.keys(w.containers).join("\n") + "\n");
    return ok();
  }) as Runner;
}

const ctr = (name: string, env: string[] = [], labels: Record<string, string> = {}) => ({
  Name: `/${name}`,
  Created: "2026-11-01T00:00:00Z",
  Image: "sha256:" + "a".repeat(64),
  RestartCount: 0,
  State: { Status: "exited", Running: false, ExitCode: 1, OOMKilled: false },
  Config: { Image: "nginx:1", Labels: labels, Env: env },
  HostConfig: { RestartPolicy: { Name: "no" } },
});

async function setup(o: { world?: World; stacks?: Stack[]; analysis?: Partial<AgentConfig["incidents"]["analysis"]>; queue?: AnalysisQueue; contextDelayMs?: number; dir?: string } = {}) {
  const dir = o.dir ?? (await mkdtemp(join(tmpdir(), "tiphys-review-b-")));
  const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "atlas");
  await store.update((c) => {
    c.features.incidents = true;
    c.incidents.analysis = { ...c.incidents.analysis, mode: "off", ...o.analysis } as AgentConfig["incidents"]["analysis"];
    return c;
  });
  const notifier = new Notifier(() => store.get(), () => {});
  const world = o.world ?? { containers: {}, logs: {}, calls: [] };
  const svc: IncidentService = await IncidentService.open({
    store,
    notifier,
    dir: join(dir, "incidents"),
    now: () => T0,
    run: stubRun(world),
    contextDelayMs: o.contextDelayMs ?? 0,
    postCheckDelayMs: 3600_000,
    discover: async () => o.stacks ?? [],
    analysisDelayMs: 3600_000,
    ...(o.queue ? { analysisQueue: () => o.queue! } : {}),
  });
  notifier.observe(svc.observe);
  const send = async (n: Notice) => {
    await notifier.send(n);
    await svc.idle();
  };
  return { dir, store, notifier, svc, world, send };
}

const died = (name: string, ctx: Record<string, string> = {}): Notice => ({
  key: "docker.died",
  params: { host: "atlas", container: name, code: 1 },
  link: "tiphys://system",
  priority: "high",
  context: ctx,
});

const gate = () => {
  let release!: () => void;
  let reached!: () => void;
  const hit = new Promise<void>((r) => (reached = r));
  const open = new Promise<void>((r) => (release = r));
  return { hit, release, wait: () => (reached(), open) };
};

// ---- S5: redaction ----

describe("S5 redaction", () => {
  it("masks PASS, *_KEY and DSN names like configfiles/classify.ts, but not words containing them", () => {
    for (const [input, secret] of [
      ["DB_PASS=hunter2x", "hunter2x"],
      ["MYSQL_ROOT_PASS: hunter2x", "hunter2x"],
      ["SIGNING_KEY=abcdef123", "abcdef123"],
      ["encryption.key = abcdef123", "abcdef123"],
      ["SENTRY_DSN=https://abc@o1.ingest.sentry.io/1", "o1.ingest"],
      ["dsn: https://abc@o1.ingest.sentry.io/1", "o1.ingest"],
      ["APP_SECRET_VALUE=xyzxyz", "xyzxyz"],
    ]) {
      expect(redact(input!), input).not.toContain(secret);
    }
    for (const l of ["passed: 12", "bypass=on", "keyboard=us", "monkey: 3", "compass: north", "passenger=4"]) expect(redact(l)).toBe(l);
  });

  it("masks URL-encoded and base64 forms of known values", () => {
    const v = "p@ss/w0rd!x9";
    setKnownSecrets("test", [{ key: "DB_PASSWORD", value: v }]);
    expect(redact(`url=postgres://u:${encodeURIComponent(v)}@db/x`)).not.toContain(encodeURIComponent(v));
    const b64 = Buffer.from(v).toString("base64");
    expect(redact(`header ${b64} end`)).toBe("header [GİZLİ:DB_PASSWORD] end");
    expect(redact(`raw ${b64.replace(/=+$/, "")}.`)).toBe("raw [GİZLİ:DB_PASSWORD].");
  });

  it("short or dictionary values only as whole words; long random ones anywhere", () => {
    setKnownSecrets("test", [
      { key: "PG_PASSWORD", value: "postgres" },
      { key: "ADMIN_PASSWORD", value: "admin1" },
      { key: "TOKEN", value: "k9Xq2Lm7Zp" },
    ]);
    expect(redact("connected to postgres as postgres_user via postgresql")).toBe("connected to [GİZLİ:PG_PASSWORD] as postgres_user via postgresql");
    expect(redact("user admin1x and admin1 ok")).toBe("user admin1x and [GİZLİ:ADMIN_PASSWORD] ok");
    expect(redact("id=abck9Xq2Lm7Zpdef")).toBe("id=abc[GİZLİ:TOKEN]def");
  });

  it("redacts a PEM block spread over log lines (boundLines) and blocks cut at either end", () => {
    const ts = "2026-11-17T10:00:00.000000000Z ";
    const body = ["MIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0tRgeLezV6ffAt0gun", "VTLw7onLRnrq0/IzW7yWR7QkrmBL7jTKEn5u+qKhbwKfBstIs+bMY2Zkp18gnTxK", "LxoS2tFczGkPLPgizskuemMghRniWaoLcyehkd3qqGElvW/VDL5AaWTg0nLVkjRo", "9z+40RQzuVaE8AkAFmxZzow3x+VJYKdjykkJ0iT9wCS0DRTXu269V264Vf/3jvre", "dZiKRkgwlL9xNAwxXFg0x3XFw005UWVRIkdgcKWTjpBP2dPwVZ4WWC+9aGVd+Gyn", "1o0CLelf4rEjGoXbAAEgAqeGUxrcIlbjXfbcmw=="];
    const lines = ["starting", "-----BEGIN RSA PRIVATE KEY-----", ...body, "-----END RSA PRIVATE KEY-----", "listening on :80"].map((l) => ts + l);
    const out = boundLines(lines).lines.join("\n");
    for (const b of body) expect(out).not.toContain(b.slice(0, 20));
    expect(out).toContain("[GİZLİ:PEM]");
    expect(out).toContain("listening on :80");
    // the tail cut off the BEGIN line: the body before END still goes
    const tail = boundLines([...body, "-----END RSA PRIVATE KEY-----", "ready"].map((l) => ts + l)).lines.join("\n");
    for (const b of body) expect(tail).not.toContain(b.slice(0, 20));
    expect(tail).toContain("ready");
    // no END (line limit): BEGIN + base64 lines go, the next ordinary line stays
    const head = redact(["-----BEGIN PRIVATE KEY-----", body[0], body[1], "connection refused"].join("\n"));
    expect(head).toBe("[GİZLİ:PEM]\nconnection refused");
  });

  it("buildBundle redacts log lines joined and with the bundle's own secrets", () => {
    const inc = {
      id: "inc-000000000001", status: "open", severity: "critical", host: "atlas", kind: "docker.died", target: "c-1", parts: [], openedAt: "2026-11-17T10:00:00Z",
      updatedAt: "2026-11-17T10:00:00Z", lastSignalAt: "2026-11-17T10:00:00Z", signalCount: 1, signals: [], timeline: [], hints: [],
      context: { collectedAt: "x", logs: { source: "docker", target: "c-1", truncated: false, lines: ["-----BEGIN PRIVATE KEY-----", "MIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0", "-----END PRIVATE KEY-----", "login with Zx81-secret-value ok"] } },
    } as unknown as Incident;
    const text = JSON.stringify(buildBundle(inc, [], [], "tr", [{ key: "API_PASSWORD", value: "Zx81-secret-value" }]).evidence);
    expect(text).not.toContain("MIIEowIBAAKCAQEAu1SU1");
    expect(text).not.toContain("Zx81-secret-value");
    expect(text).toContain("[GİZLİ:API_PASSWORD]");
  });

  it("the incident container's secret env values are redacted from its logs and bundle (not stored)", async () => {
    const world: World = {
      containers: { "c-1": ctr("c-1", ["DB_PASSWORD=Hx7-not-in-any-env-file", "PATH=/usr/bin", "MODE=production"]) },
      logs: { "c-1": ["db login Hx7-not-in-any-env-file failed", "mode production"] },
      calls: [],
    };
    const t = await setup({ world });
    await t.send(died("c-1"));
    const id = t.svc.list()[0]!.id;
    const inc = await t.svc.get(id);
    expect(inc.context?.logs?.lines.join("\n")).toContain("[GİZLİ:DB_PASSWORD]");
    expect(inc.context?.logs?.lines.join("\n")).toContain("mode production");
    const file = await readFile(join(t.dir, "incidents", `${id}.json`), "utf8");
    expect(file).not.toContain("Hx7-not-in-any-env-file");
    // a context collected before (unredacted) still doesn't leave via the bundle
    inc.context!.logs!.lines.push("again Hx7-not-in-any-env-file");
    expect(JSON.stringify(await t.svc.bundle(id))).not.toContain("Hx7-not-in-any-env-file");
    await t.svc.close();
  });
});

// ---- S4: container → stack ----

describe("S4 container stack matching", () => {
  const stack = (id: string, project: string, dir: string): Stack => ({ id, project, dir, root: "/srv", composeFiles: [`${dir}/compose.yaml`], envFiles: [], services: ["app"] });
  // directory "web" runs project "prod"; directory "other" runs project "web"
  const stacks = [stack("web", "prod", "/srv/web"), stack("other", "web", "/srv/other")];

  it("matches by project label only and requires the working directory label to be the stack's directory", async () => {
    const t = await setup({ stacks });
    await t.send(died("a-1", { project: "web", service: "app", workingDir: "/srv/other" }));
    await t.send(died("b-1", { project: "web", service: "app", workingDir: "/elsewhere/web" }));
    await t.send(died("c-1", { project: "prod", service: "app" }));
    const byTarget = new Map(await Promise.all(t.svc.list().map(async (s) => [s.target, await t.svc.get(s.id)] as const)));
    expect(byTarget.get("a-1")!.stack).toBe("other");
    expect(byTarget.get("b-1")!.stack).toBeUndefined();
    expect(byTarget.get("c-1")!.stack).toBe("web");
    const kinds = (await t.svc.actions(byTarget.get("b-1")!.id)).actions.map((a) => a.kind);
    expect(kinds).toEqual(["container.restart"]);
    await t.svc.close();
  });

  it("stackForProject: ambiguous without a working directory → none", () => {
    const two = [stack("a", "p", "/srv/a"), stack("b", "p", "/srv/b")];
    expect(stackForProject(two, "p")).toBeUndefined();
    expect(stackForProject(two, "p", "/srv/b/")?.id).toBe("b");
    expect(stackForProject(stacks, "web")?.id).toBe("other");
  });
});

// ---- C1, C2: analysis state ----

describe("C1/C2 analysis state", () => {
  it("C1: a queued/running analysis loaded from disk becomes unavailable/lost and a new one can start", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-review-b-"));
    const t1 = await setup({ dir });
    await t1.send(died("c-1"));
    const id = t1.svc.list()[0]!.id;
    const inc = await t1.svc.get(id);
    inc.analysis = { status: "running", mode: "local", by: "auto", requestedAt: "2026-11-17T10:00:00Z", jobId: "aj-x" };
    await t1.svc.db.save(inc);
    await t1.svc.close();

    const run = vi.fn(async () => ({}));
    const queue = new AnalysisQueue({ run });
    const t2 = await setup({ dir, analysis: { mode: "local" }, queue });
    const loaded = await t2.svc.get(id);
    expect(loaded.analysis).toMatchObject({ status: "unavailable", reason: "lost" });
    const state = await t2.svc.analyze(id, "device:phone");
    expect(state.status).toBe("queued");
    await t2.svc.idle();
    expect(run).toHaveBeenCalledTimes(1);
    await t2.svc.close();
    await queue.close();
  });

  it("C1: also for an older (not live) incident read later", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-review-b-"));
    const store = new IncidentStore(join(dir, "incidents"));
    await store.load();
    const old = "2026-11-01T10:00:00.000Z";
    const inc = { id: "inc-0000000000aa", status: "resolved", severity: "critical", host: "atlas", kind: "docker.died", target: "c-1", parts: [], openedAt: old, updatedAt: old, lastSignalAt: old, resolvedAt: old, signalCount: 1, signals: [], timeline: [], hints: [], analysis: { status: "queued", mode: "local", by: "auto", requestedAt: old } } as unknown as Incident;
    await store.save(inc);
    await store.flush();
    const t = await setup({ dir });
    expect(t.svc.live.has(inc.id)).toBe(false);
    expect((await t.svc.get(inc.id)).analysis).toMatchObject({ status: "unavailable", reason: "lost" });
    await t.svc.close();
  });

  it("C2: concurrent analyze calls start one job", async () => {
    const g = gate();
    const run = vi.fn(async () => {
      await g.wait();
      return {};
    });
    const queue = new AnalysisQueue({ run });
    const t = await setup({ analysis: { mode: "local" }, queue });
    await t.send(died("c-1"));
    const id = t.svc.list()[0]!.id;
    const [a, b] = await Promise.all([t.svc.analyze(id, "device:a"), t.svc.analyze(id, "device:b")]);
    expect(a.status).toBe("queued");
    expect(b.status).toBe("queued");
    await g.hit;
    g.release();
    await t.svc.idle();
    expect(run).toHaveBeenCalledTimes(1);
    expect((await t.svc.get(id)).timeline.filter((e) => e.type === "analysis")).toHaveLength(1);
    await t.svc.close();
    await queue.close();
  });
});

// ---- C3: deleted incidents stay deleted ----

describe("C3 deletion", () => {
  it("a context collection still running when the incident is deleted doesn't bring it back", async () => {
    const g = gate();
    const world: World = { containers: { "c-1": ctr("c-1") }, logs: { "c-1": ["x"] }, calls: [], block: {} };
    const t = await setup({ world, contextDelayMs: 3600_000 });
    await t.send(died("c-1"));
    const id = t.svc.list()[0]!.id;
    world.block!.logs = () => g.wait();
    const p = t.svc.collect(id);
    await g.hit;
    await t.svc.remove(id);
    g.release();
    await p;
    await t.svc.idle();
    expect(t.svc.list()).toEqual([]);
    expect(t.svc.live.has(id)).toBe(false);
    await expect(stat(join(t.dir, "incidents", `${id}.json`))).rejects.toThrow();
    expect(JSON.parse(await readFile(join(t.dir, "incidents", "index.json"), "utf8"))).toEqual([]);
    await t.svc.close();
  });
});

// ---- C9: tick overlap ----

describe("C9 tick", () => {
  it("a tick still running makes the next one a no-op", async () => {
    const g = gate();
    const world: World = { containers: { "c-1": ctr("c-1") }, logs: {}, calls: [], block: {} };
    const t = await setup({ world });
    await t.send(died("c-1"));
    world.calls.length = 0;
    world.block!.inspect = () => g.wait();
    const first = t.svc.tick();
    await g.hit;
    await t.svc.tick();
    g.release();
    await first;
    expect(world.calls.filter((c) => c[1] === "inspect")).toHaveLength(1);
    await t.svc.close();
  });
});

// ---- C10: deploy tracker ----

describe("C10 deploy snapshots", () => {
  const A = "sha256:" + "a".repeat(64);
  const B = "sha256:" + "b".repeat(64);
  const svcCtr = (image: string) => ({ ...ctr("web-app-1", [], { "com.docker.compose.project": "web", "com.docker.compose.service": "app" }), Image: image, Created: "2026-11-17T09:00:00Z" });

  it("a failed append leaves the change unrecorded, so the next snapshot records it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-review-b-"));
    const world: World = { containers: { "web-app-1": svcCtr(A) }, logs: {}, calls: [] };
    const file = join(dir, "deploys.jsonl");
    const t = new DeployTracker({ file, run: stubRun(world), now: () => T0 });
    await t.load();
    await mkdir(file); // appendFile → EISDIR
    await expect(t.snapshot()).rejects.toThrow();
    expect(t.lastKnown("web", "app")).toBeUndefined();
    await rm(file, { recursive: true });
    expect((await t.snapshot()).map((r) => r.kind)).toEqual(["seen"]);
  });

  it("a failed `docker tag` isn't recorded; the next snapshot tags and records it", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-review-b-"));
    const world: World = { containers: { "web-app-1": svcCtr(A) }, logs: {}, calls: [] };
    let tagFails = true;
    const base = stubRun(world);
    const run = (async (cmd: string, args: string[], o: object) => {
      if (args[0] === "image" && args[1] === "inspect") return { code: 0, stdout: `${A} 2026-11-01T00:00:00Z\n`, stderr: "" };
      if (args[0] === "tag" && tagFails) return { code: 1, stdout: "", stderr: "daemon busy" };
      return base(cmd, args, o);
    }) as Runner;
    const t = new DeployTracker({ file: join(dir, "deploys.jsonl"), run, now: () => T0 });
    await t.load();
    await t.snapshot();
    world.containers["web-app-1"] = svcCtr(B);
    expect(await t.snapshot()).toEqual([]);
    expect(t.lastKnown("web", "app")?.imageId).toBe(A);
    tagFails = false;
    const [r] = await t.snapshot();
    expect(r).toMatchObject({ kind: "changed", imageId: B, prevImageId: A });
    expect(r!.rollbackTag).toMatch(/^tiphys-rollback\/web-app-[a-f0-9]{8}:prev$/);
  });
});

// ---- C11: storage ----

describe("C11 incident storage", () => {
  const inc = (id: string) => ({ id, status: "open", severity: "critical", host: "atlas", kind: "docker.died", target: "c", parts: [], openedAt: "2026-11-17T10:00:00.000Z", updatedAt: "2026-11-17T10:00:00.000Z", lastSignalAt: "2026-11-17T10:00:00.000Z", signalCount: 1, signals: [], timeline: [], hints: [] }) as unknown as Incident;

  it("index.json corrupt or missing → rebuilt from the incident files", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-review-b-"));
    const s1 = new IncidentStore(dir);
    await s1.load();
    await s1.save(inc("inc-000000000001"));
    await s1.save(inc("inc-000000000002"));
    await s1.flush();
    await writeFile(join(dir, "index.json"), "{not json");
    await writeFile(join(dir, "inc-000000000003.json"), "{also broken");
    const s2 = new IncidentStore(dir);
    await s2.load();
    await s2.flush();
    expect([...s2.index.keys()].sort()).toEqual(["inc-000000000001", "inc-000000000002"]);
    expect(JSON.parse(await readFile(join(dir, "index.json"), "utf8"))).toHaveLength(2);
    await rm(join(dir, "index.json"));
    const s3 = new IncidentStore(dir);
    await s3.load();
    expect(s3.index.size).toBe(2);
  });

  it("an orphan index entry is dropped; a corrupt incident can still be deleted", async () => {
    const t = await setup();
    await t.send(died("c-1"));
    await t.send(died("c-2"));
    const [a, b] = t.svc.list().map((s) => s.id);
    await t.svc.close();
    await rm(join(t.dir, "incidents", `${a}.json`));
    await writeFile(join(t.dir, "incidents", `${b}.json`), "{corrupt");
    const t2 = await setup({ dir: t.dir });
    await t2.svc.idle();
    expect(t2.svc.list().map((s) => s.id)).toEqual([b]);
    await expect(t2.svc.get(b!)).rejects.toThrow("agent.incident.notFound");
    await t2.svc.remove(b!);
    await t2.svc.idle();
    expect(t2.svc.list()).toEqual([]);
    expect(JSON.parse(await readFile(join(t.dir, "incidents", "index.json"), "utf8"))).toEqual([]);
    await t2.svc.close();
  });
});

describe("C11 readStack", () => {
  it("COMPOSE_PROJECT_NAME and COMPOSE_FILE from the stack's .env win; YAML merge keys apply", async () => {
    const root = await mkdtemp(join(tmpdir(), "tiphys-review-b-stacks-"));
    const dir = join(root, "shop");
    await mkdir(join(dir, "deploy"), { recursive: true });
    await writeFile(join(dir, ".env"), "COMPOSE_PROJECT_NAME=shop-prod\nCOMPOSE_FILE=deploy/base.yml:deploy/prod.yml\n");
    await writeFile(join(dir, "compose.yaml"), "name: ignored\nservices:\n  wrong: {image: x}\n");
    await writeFile(join(dir, "deploy", "base.yml"), "x-common: &common\n  env_file: app.env\nservices:\n  api:\n    <<: *common\n    image: api\n");
    await writeFile(join(dir, "deploy", "prod.yml"), "services:\n  worker: {image: w}\n");
    await writeFile(join(dir, "app.env"), "A=1\n");
    const s = (await readStack(root, dir))!;
    expect(s.project).toBe("shop-prod");
    expect(s.composeFiles).toEqual([join(dir, "deploy", "base.yml"), join(dir, "deploy", "prod.yml")]);
    expect(s.services).toEqual(["api", "worker"]);
    expect(s.envFiles).toEqual([join(dir, ".env"), join(dir, "app.env")]);
    // a COMPOSE_FILE outside the root is refused
    await writeFile(join(dir, ".env"), "COMPOSE_FILE=../../etc/compose.yml\n");
    expect(await readStack(root, dir)).toBeNull();
  });
});

// ---- C11: runTool ----

describe("C11 runTool", () => {
  it("doesn't send the delayed SIGKILL to a process group that's already gone", async () => {
    const kill = vi.spyOn(process, "kill");
    try {
      const err = await runTool("sh", ["-c", "sleep 5"], { cwd: tmpdir(), signal: new AbortController().signal, timeoutMs: 100, killGraceMs: 300, errorPrefix: "agent.test" }).catch((e) => e);
      expect(String(err?.code)).toBe("agent.test.timeout");
      await new Promise((r) => setTimeout(r, 500));
      const groups = new Set(kill.mock.calls.filter(([pid, sig]) => sig === "SIGTERM" && pid < 0).map(([pid]) => pid));
      expect(groups.size).toBeGreaterThan(0);
      expect(kill.mock.calls.some(([pid, sig]) => sig === "SIGKILL" && groups.has(pid))).toBe(false);
    } finally {
      kill.mockRestore();
    }
  });
});
