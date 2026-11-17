// Incident room, PLAN.md §13.1 I-2: deploy history + rollback tags, compose.rollback, disk.cleanup, deploys route.
import { chmod, mkdir, mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { hashToken, newToken } from "../src/auth.ts";
import { ConfigStore } from "../src/config.ts";
import { EventLog, eventsPath } from "../src/events.ts";
import { DeployTracker, MAX_DEPLOY_BYTES, rollbackRepo, rollbackTag, servicesFromInspect } from "../src/incidents/deploys.ts";
import { estimateCleanup, parseDockerSize, parseJournalSize, parseSystemDf, probeUserJournal, type JournalProbe } from "../src/incidents/disk_cleanup.ts";
import { incidentRoutes } from "../src/incidents/routes.ts";
import { IncidentService } from "../src/incidents/service.ts";
import { Notifier, type Notice } from "../src/notify.ts";
import { buildApp } from "../src/server.ts";
import type { Stack } from "../src/stacks.ts";

const FAKE = new URL("./fake_ops_tool.mjs", import.meta.url).pathname;
const origPath = process.env.PATH;
let bin = "";
let ops = "";
const T0 = Date.parse("2026-11-17T10:00:00Z");

const A = "sha256:" + "a".repeat(64);
const B = "sha256:" + "b".repeat(64);
const C = "sha256:" + "c".repeat(64);
const X = "sha256:" + "e".repeat(64);
const Y = "sha256:" + "d".repeat(64);
const REF = "registry.example/web:latest";
const PREV = "tiphys-rollback/web-app:prev";

beforeAll(async () => {
  bin = await mkdtemp(join(tmpdir(), "tiphys-fakeops-"));
  ops = await mkdtemp(join(tmpdir(), "tiphys-opsstate-"));
  for (const tool of ["docker", "systemctl", "journalctl", "git"]) {
    await writeFile(join(bin, tool), `#!/bin/sh\nexec "${process.execPath}" "${FAKE}" ${tool} "$@"\n`);
    await chmod(join(bin, tool), 0o755);
  }
  process.env.PATH = `${bin}:${origPath}`;
  process.env.FAKE_OPS_DIR = ops;
});

afterAll(() => {
  process.env.PATH = origPath;
  delete process.env.FAKE_OPS_DIR;
});

type Images = Record<string, { Created: string; tags: string[]; Containers?: number }>;
async function opsState(s: Record<string, unknown>) {
  await writeFile(join(ops, "state.json"), JSON.stringify(s));
  await writeFile(join(ops, "calls.jsonl"), "");
}
const readState = async () => JSON.parse(await readFile(join(ops, "state.json"), "utf8")) as { images: Images; containers: Record<string, { Image: string }> };
async function calls(tool?: string): Promise<Array<{ tool: string; argv: string[]; cwd: string }>> {
  const text = await readFile(join(ops, "calls.jsonl"), "utf8").catch(() => "");
  return text.split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((c) => !tool || c.tool === tool);
}

const ctr = (name: string, image: string, o: Partial<{ created: string; running: boolean; project: string; service: string; ref: string; oneoff: boolean }> = {}) => ({
  Id: name,
  Name: `/${name}`,
  Created: o.created ?? "2026-11-17T09:50:00Z",
  Image: image,
  RestartCount: 0,
  State: { Status: o.running === false ? "exited" : "running", Running: o.running !== false, ExitCode: o.running === false ? 1 : 0, OOMKilled: false },
  Config: {
    Image: o.ref ?? REF,
    Labels: { "com.docker.compose.project": o.project ?? "web", "com.docker.compose.service": o.service ?? "app", ...(o.oneoff ? { "com.docker.compose.oneoff": "True" } : {}) },
  },
  HostConfig: { RestartPolicy: { Name: "unless-stopped" } },
});

const webStack = (dir: string): Stack => ({
  id: "web",
  project: "web",
  dir: join(dir, "stack", "web"),
  root: join(dir, "stack"),
  composeFiles: [join(dir, "stack", "web", "compose.yaml")],
  envFiles: [],
  services: ["app", "db"],
});

const noJournal = async (): Promise<JournalProbe> => ({ dirs: ["/var/log/journal/x"], writable: false, vacuumBytes: 5_000_000 });

async function setup(o: { diskUsage?: number } = {}) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-i2-"));
  await mkdir(join(dir, "stack", "web"), { recursive: true });
  const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "atlas");
  const token = newToken();
  await store.update((c) => {
    c.features.incidents = true;
    c.devices.push({ id: "phone", name: "Telefon", tokenHash: hashToken(token), createdAt: new Date().toISOString() });
    return c;
  });
  const notifier = new Notifier(() => store.get(), () => {}, new EventLog(eventsPath(store.path)));
  const clock = { now: T0 };
  const deploys = new DeployTracker({ file: join(dir, "incidents", "deploys.jsonl"), now: () => clock.now });
  await deploys.load();
  const svc = await IncidentService.open({
    store,
    notifier,
    dir: join(dir, "incidents"),
    now: () => clock.now,
    contextDelayMs: 0,
    postCheckDelayMs: 0,
    discover: async () => [webStack(dir)],
    deploys,
    journalProbe: noJournal,
    diskUsage: async () => o.diskUsage ?? 80,
  });
  const app = await buildApp({ store, notifier, extraRoutes: [incidentRoutes(svc)] });
  const auth = { authorization: `Bearer ${token}` };
  const send = async (n: Notice) => {
    await notifier.send(n);
    await svc.idle();
  };
  const req = (method: "GET" | "POST", url: string, payload?: unknown) => app.inject({ method, url, headers: auth, ...(payload ? { payload } : {}) });
  return { dir, store, notifier, svc, app, deploys, clock, send, req };
}

const died = (name = "web-app-1"): Notice => ({
  key: "docker.died",
  params: { host: "atlas", container: name, code: 1 },
  link: "tiphys://system",
  priority: "high",
  context: { project: "web", service: "app" },
});

describe("deploy tracking", () => {
  it("rollback repository names are valid docker references and distinct per service", () => {
    expect(rollbackRepo("web", "app")).toBe("tiphys-rollback/web-app");
    expect(rollbackTag("web", "app")).toBe(PREV);
    const repoRe = /^tiphys-rollback\/[a-z0-9]+(?:-[a-z0-9]+)*$/;
    const odd = ["My_Proj", "api.v2", "a__b", "-x-", "ÇALIŞAN", "x".repeat(300)];
    for (const p of odd) for (const s of odd) expect(rollbackRepo(p, s)).toMatch(repoRe);
    expect(rollbackRepo("a_b", "c")).not.toBe(rollbackRepo("a-b", "c"));
    expect(rollbackRepo("a", "b-c")).not.toBe(rollbackRepo("a", "b_c"));
    expect(rollbackRepo("x".repeat(300), "y").length).toBeLessThan(140);
  });

  it("keeps the newest container per service and skips one-off and non-compose containers", () => {
    const list = [
      ctr("web-app-1", A, { created: "2026-11-17T09:00:00Z" }),
      ctr("web-app-2", B, { created: "2026-11-17T09:30:00Z" }),
      ctr("web-app-run-x", C, { created: "2026-11-17T09:59:00Z", oneoff: true }),
      { ...ctr("plain", A), Config: { Image: "x", Labels: {} } },
      ctr("web-db-1", "not-an-id", { service: "db" }),
    ];
    expect(servicesFromInspect(list).map((s) => [s.service, s.container, s.imageId])).toEqual([["app", "web-app-2", B]]);
  });

  it("records changes only, tags the previous image :prev, moves the tag, drops stale tags (not in-use ones)", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-deploys-"));
    const clock = { now: T0 };
    const t = new DeployTracker({ file: join(dir, "deploys.jsonl"), now: () => clock.now });
    await t.load();
    const images: Images = {
      [A]: { Created: "2026-11-01T00:00:00Z", tags: [] },
      [B]: { Created: "2026-11-10T00:00:00Z", tags: [] },
      [C]: { Created: "2026-11-17T09:00:00Z", tags: [REF] },
      [X]: { Created: "2026-10-01T00:00:00Z", tags: ["tiphys-rollback/web-app:inuse"] },
      [Y]: { Created: "2026-09-01T00:00:00Z", tags: ["tiphys-rollback/web-app:old"] },
    };
    await opsState({ psNames: ["web-app-1", "web-db-1"], containers: { "web-app-1": ctr("web-app-1", A), "web-db-1": ctr("web-db-1", X, { service: "db", ref: "postgres:16" }) }, images });
    const first = await t.snapshot();
    expect(first.map((r) => [r.kind, r.service, r.imageId, r.rollbackTag])).toEqual([
      ["seen", "app", A, null],
      ["seen", "db", X, null],
    ]);
    expect((await calls("docker")).some((c) => c.argv[0] === "tag")).toBe(false);
    expect(await t.snapshot()).toEqual([]);
    expect((await stat(t.file)).mode & 0o777).toBe(0o600);

    // deploy 1: app A → B
    clock.now += 60_000;
    const s = await readState();
    s.containers["web-app-1"] = ctr("web-app-1", B, { created: "2026-11-17T10:00:30Z" }) as never;
    await opsState(s);
    const [ch] = await t.snapshot();
    expect(ch).toMatchObject({ kind: "changed", service: "app", imageId: B, prevImageId: A, prevImageRef: REF, rollbackTag: PREV, createdAt: "2026-11-17T10:00:30Z" });
    const docker = (await calls("docker")).map((c) => c.argv);
    expect(docker).toContainEqual(["tag", A, PREV]);
    // the stale tag goes; the tag on the image the running db container uses stays
    expect(docker).toContainEqual(["image", "rm", "--no-prune", "tiphys-rollback/web-app:old"]);
    expect(docker.some((a) => a[0] === "image" && a[1] === "rm" && a.includes("tiphys-rollback/web-app:inuse"))).toBe(false);
    let st = await readState();
    expect(st.images[A]!.tags).toEqual([PREV]);

    // deploy 2: B → C: the tag moves (one per service)
    st.containers["web-app-1"] = ctr("web-app-1", C, { created: "2026-11-17T10:05:00Z" }) as never;
    await opsState(st);
    expect((await t.snapshot())[0]).toMatchObject({ prevImageId: B, rollbackTag: PREV });
    st = await readState();
    expect(st.images[A]!.tags).toEqual([]);
    expect(st.images[B]!.tags).toEqual([PREV]);

    // previous image already gone → recorded without a tag
    delete st.images[C];
    st.containers["web-app-1"] = ctr("web-app-1", A, { created: "2026-11-17T10:10:00Z" }) as never;
    await opsState(st);
    expect((await t.snapshot())[0]).toMatchObject({ imageId: A, prevImageId: C, rollbackTag: null });

    // a new tracker on the same file knows the last images: no duplicate records
    const t2 = new DeployTracker({ file: t.file, now: () => clock.now });
    await t2.load();
    expect(t2.lastKnown("web", "app")?.imageId).toBe(A);
    expect(await t2.snapshot()).toEqual([]);
    const h = await t2.history({ service: "app" });
    expect(h.map((r) => r.imageId)).toEqual([A, C, B, A]);
  });

  it("rotates deploys.jsonl at 1 MB and reads both files", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-deploys-"));
    const file = join(dir, "deploys.jsonl");
    const old = { at: "2026-11-01T00:00:00.000Z", kind: "seen", project: "web", service: "app", container: "web-app-1", imageId: A, imageRef: REF, createdAt: "x", prevImageId: null, prevImageRef: null, rollbackTag: null };
    const filler = { ...old, project: "filler", service: "s", container: "p".repeat(500) };
    const lines = [JSON.stringify(old)];
    while (lines.join("\n").length < MAX_DEPLOY_BYTES) lines.push(JSON.stringify(filler));
    await writeFile(file, lines.join("\n") + "\n", { mode: 0o600 });
    const t = new DeployTracker({ file, now: () => T0 });
    await t.load();
    expect(t.lastKnown("web", "app")?.imageId).toBe(A);
    await opsState({ psNames: ["web-app-1"], containers: { "web-app-1": ctr("web-app-1", B) }, images: { [A]: { Created: "x", tags: [] }, [B]: { Created: "y", tags: [REF] } } });
    await t.snapshot();
    expect((await stat(`${file}.1`)).size).toBeGreaterThanOrEqual(MAX_DEPLOY_BYTES);
    expect((await readFile(file, "utf8")).trim().split("\n")).toHaveLength(1);
    expect((await stat(file)).mode & 0o777).toBe(0o600);
    expect((await t.history({ project: "web" })).map((r) => r.imageId)).toEqual([B, A]);
  });
});

describe("compose.rollback", () => {
  const rollbackState = (extra: Partial<{ ref: string; noPrev: boolean }> = {}) => ({
    psNames: ["web-app-1"],
    containers: { "web-app-1": ctr("web-app-1", B, { ref: extra.ref ?? REF, running: false }) },
    images: {
      [A]: { Created: "2026-11-10T08:00:00Z", tags: extra.noPrev ? [] : [PREV] },
      [B]: { Created: "2026-11-17T09:45:00Z", tags: [extra.ref ?? REF] },
    },
    logs: { "web-app-1": [] },
  });

  it("is offered only with a :prev tag and a re-taggable reference", async () => {
    for (const [st, offered] of [
      [rollbackState({ noPrev: true }), false],
      [rollbackState({ ref: "registry.example/web@sha256:" + "f".repeat(64) }), false],
      [rollbackState(), true],
    ] as const) {
      const t = await setup();
      await opsState(st);
      await t.send(died());
      const kinds = (await t.svc.actions(t.svc.list()[0]!.id)).actions.map((a) => a.kind);
      expect(kinds.includes("compose.rollback"), JSON.stringify(st.containers)).toBe(offered);
      await t.app.close();
    }
  });

  it("preview shows both images and the warning; execute runs the exact argv; post-check sees the previous image", async () => {
    const t = await setup();
    await opsState(rollbackState());
    await t.send(died());
    const id = t.svc.list()[0]!.id;
    const { actions } = (await t.req("GET", `/v1/incidents/${id}/actions`)).json();
    const rb = actions.find((a: { kind: string }) => a.kind === "compose.rollback");
    expect(rb).toMatchObject({ target: { stack: "web", service: "app" }, risk: "medium" });
    const pv = (await t.req("POST", `/v1/incidents/${id}/actions/${rb.id}/preview`)).json();
    const stackDir = join(t.dir, "stack", "web");
    expect(pv.steps).toEqual([
      { argv: ["docker", "tag", A, REF] },
      { argv: ["docker", "compose", "-f", join(stackDir, "compose.yaml"), "up", "-d", "--no-deps", "--pull", "never", "app"], cwd: stackDir },
    ]);
    expect(pv.details).toEqual({
      rollback: { tag: PREV, imageRef: REF, current: { imageId: B, created: "2026-11-17T09:45:00Z" }, previous: { imageId: A, created: "2026-11-10T08:00:00Z" } },
      warnings: ["dbMigrationsNotReverted"],
    });
    await opsState({ ...(await readState()) });
    const ex = await t.req("POST", `/v1/incidents/${id}/actions/${rb.id}/execute`, { previewToken: pv.previewToken, confirm: true });
    expect(ex.json()).toEqual({ ok: true, code: 0 });
    await t.svc.idle();
    const mutating = (await calls("docker")).map((c) => ({ argv: c.argv, cwd: c.cwd })).filter((c) => c.argv[0] === "tag" || c.argv[0] === "compose");
    expect(mutating).toEqual([
      { argv: ["tag", A, REF], cwd: expect.any(String) },
      { argv: ["compose", "-f", join(stackDir, "compose.yaml"), "up", "-d", "--no-deps", "--pull", "never", "app"], cwd: stackDir },
    ]);
    expect((await readState()).containers["web-app-1"]!.Image).toBe(A);
    const inc = await t.svc.get(id);
    expect(inc.timeline.find((e) => e.type === "postCheck")?.data).toMatchObject({ action: "compose.rollback", ok: true, state: "running" });
    expect(inc.workedAction).toBe("compose.rollback");
    await t.app.close();
  });

  it("post-check fails when the service doesn't run the previous image; a changed :prev voids the token", async () => {
    const t = await setup();
    await opsState(rollbackState());
    await t.send(died());
    const id = t.svc.list()[0]!.id;
    const rb = (await t.svc.actions(id)).actions.find((a) => a.kind === "compose.rollback")!;
    // :prev moves to another image between preview and execute → 409
    const pv1 = await t.svc.preview(id, rb.id, "phone");
    const st = await readState();
    st.images[C] = { Created: "2026-11-12T00:00:00Z", tags: [PREV] };
    st.images[A]!.tags = [];
    await opsState(st);
    await expect(t.svc.execute(id, rb.id, "phone", pv1.previewToken)).rejects.toThrow("agent.preview.invalid");
    // compose leaves the container on the new image → the post-check fails (otherImage) and the failure is notified
    const pv2 = await t.svc.preview(id, rb.id, "phone");
    expect(pv2.steps[0]!.argv).toEqual(["docker", "tag", C, REF]);
    await opsState({ ...(await readState()), composeNoop: true });
    expect(await t.svc.execute(id, rb.id, "phone", pv2.previewToken)).toEqual({ ok: true, code: 0 });
    await t.svc.idle();
    const inc = await t.svc.get(id);
    expect(inc.timeline.find((e) => e.type === "postCheck")?.data).toMatchObject({ action: "compose.rollback", ok: false, state: "exited/otherImage" });
    expect(inc.workedAction).toBeUndefined();
    await t.app.close();
  });
});

describe("disk.cleanup", () => {
  it("parses docker and journal sizes and both `docker system df` formats", () => {
    expect(parseDockerSize("635.1MB (23%)")).toBe(635_100_000);
    expect(parseDockerSize("40.96kB")).toBe(40_960);
    expect(parseDockerSize("0B")).toBe(0);
    expect(parseDockerSize("2.698GB")).toBe(2_698_000_000);
    expect(parseDockerSize("1.5GiB")).toBe(1.5 * 1024 ** 3);
    expect(parseDockerSize("N/A")).toBeNull();
    expect(parseJournalSize("Archived and active journals take up 449.2M in the file system.")).toBe(Math.round(449.2 * 1024 ** 2));
    expect(parseJournalSize("… take up 8.0K in the file system.")).toBe(8192);
    const json = [
      '{"Active":"7","Reclaimable":"635.1MB (23%)","Size":"2.698GB","TotalCount":"9","Type":"Images"}',
      '{"Active":"3","Reclaimable":"40.96kB (0%)","Size":"107.2MB","TotalCount":"7","Type":"Containers"}',
      '{"Active":"2","Reclaimable":"8.165MB (0%)","Size":"3.161GB","TotalCount":"3","Type":"Local Volumes"}',
      '{"Active":"0","Reclaimable":"1.2GB","Size":"1.5GB","TotalCount":"12","Type":"Build Cache"}',
    ].join("\n");
    const table = [
      "TYPE            TOTAL     ACTIVE    SIZE      RECLAIMABLE",
      "Images          9         7         2.698GB   635.1MB (23%)",
      "Containers      7         3         107.2MB   40.96kB (0%)",
      "Local Volumes   3         2         3.161GB   8.165MB (0%)",
      "Build Cache     12        0         1.5GB     1.2GB",
    ].join("\n");
    const want = {
      images: { size: 2_698_000_000, reclaimable: 635_100_000 },
      containers: { size: 107_200_000, reclaimable: 40_960 },
      volumes: { size: 3_161_000_000, reclaimable: 8_165_000 },
      buildCache: { size: 1_500_000_000, reclaimable: 1_200_000_000 },
    };
    expect(parseSystemDf(json)).toEqual(want);
    expect(parseSystemDf(table)).toEqual(want);
  });

  it("probes the user journal: archived files older than 7 days; a directory the agent can't write → needsRoot", async () => {
    const base = await mkdtemp(join(tmpdir(), "tiphys-journal-"));
    const mid = "0123456789abcdef0123456789abcdef";
    const d = join(base, mid);
    await mkdir(d);
    const now = Date.now();
    await writeFile(join(d, "user-1000.journal"), Buffer.alloc(100));
    await writeFile(join(d, "user-1000@abc-1.journal"), Buffer.alloc(300));
    await writeFile(join(d, "user-1000@abc-2.journal"), Buffer.alloc(50));
    await writeFile(join(d, "system@abc.journal"), Buffer.alloc(999));
    await writeFile(join(d, "user-1001@abc.journal"), Buffer.alloc(999));
    const { utimes } = await import("node:fs/promises");
    const old = new Date(now - 10 * 86400_000);
    await utimes(join(d, "user-1000@abc-1.journal"), old, old);
    await utimes(join(d, "system@abc.journal"), old, old);
    await utimes(join(d, "user-1001@abc.journal"), old, old);
    const p = await probeUserJournal({ bases: [base], machineId: mid, uid: 1000, now });
    expect(p).toEqual({ dirs: [d], writable: true, vacuumBytes: 300 });
    if (process.getuid?.() !== 0) {
      await chmod(d, 0o555);
      expect((await probeUserJournal({ bases: [base], machineId: mid, uid: 1000, now })).writable).toBe(false);
      await chmod(d, 0o755);
    }
    expect((await probeUserJournal({ bases: [base], machineId: mid, uid: 4242, now })).dirs).toEqual([]);
  });

  it("estimates per option; no docker → docker options unavailable", async () => {
    await opsState({
      systemDf: '{"Reclaimable":"40.96kB (0%)","Size":"107.2MB","Type":"Containers"}\n{"Reclaimable":"1.2GB","Size":"1.5GB","Type":"Build Cache"}\n',
      danglingJson: [{ Size: "482MB", Containers: "1" }, { Size: "10MB", Containers: "0" }, { Size: "5MB", Containers: "N/A" }],
      journalUsage: "Archived and active journals take up 449.2M in the file system.\n",
    });
    const e = await estimateCleanup(undefined, noJournal);
    expect(e).toEqual([
      { option: "userJournal", available: false, reason: "needsRoot", reclaimableBytes: 5_000_000, usageBytes: Math.round(449.2 * 1024 ** 2) },
      { option: "systemJournal", available: false, reason: "needsRoot", reclaimableBytes: null, usageBytes: null },
      { option: "builder", available: true, reclaimableBytes: 1_200_000_000, usageBytes: 1_500_000_000 },
      { option: "images", available: true, reclaimableBytes: 15_000_000, usageBytes: null },
      { option: "containers", available: true, reclaimableBytes: 40_960, usageBytes: 107_200_000 },
    ]);
    await opsState({ noDocker: true });
    const e2 = await estimateCleanup(undefined, async () => ({ dirs: ["/x"], writable: true, vacuumBytes: 7 }));
    expect(e2.filter((x) => x.available).map((x) => x.option)).toEqual(["userJournal"]);
    expect(e2.find((x) => x.option === "images")).toMatchObject({ available: false, reason: "noDocker" });
  });

  it("preview → execute runs the chosen prunes only; tiphys-rollback images survive; post-check reads the disk", async () => {
    const t = await setup({ diskUsage: 81.5 });
    const images: Images = {
      [A]: { Created: "x", tags: [PREV] },
      [B]: { Created: "y", tags: [] },
      [C]: { Created: "z", tags: [], Containers: 1 },
      [X]: { Created: "w", tags: [REF] },
    };
    await opsState({ systemDf: '{"Reclaimable":"1.2GB","Size":"1.5GB","Type":"Build Cache"}\n', danglingJson: [{ Size: "10MB", Containers: "0" }], images });
    await t.send({ key: "disk.full", params: { host: "atlas", mount: "/", percent: 97 }, link: "tiphys://system", priority: "high" });
    const id = t.svc.list()[0]!.id;
    const { actions } = (await t.req("GET", `/v1/incidents/${id}/actions`)).json();
    expect(actions.map((a: { kind: string }) => a.kind)).toEqual(["disk.cleanup"]);
    const aid = actions[0].id;
    const pv = (await t.req("POST", `/v1/incidents/${id}/actions/${aid}/preview`)).json();
    expect(pv.details.cleanup.selected).toEqual(["builder", "images", "containers"]);
    expect(pv.details.cleanup.options.map((o: { option: string; available: boolean }) => [o.option, o.available])).toEqual([
      ["userJournal", false],
      ["systemJournal", false],
      ["builder", true],
      ["images", true],
      ["containers", true],
    ]);
    expect(pv.steps).toEqual([
      { argv: ["docker", "builder", "prune", "-f"] },
      { argv: ["docker", "image", "prune", "-f"] },
      { argv: ["docker", "container", "prune", "-f", "--filter", "until=24h"] },
    ]);
    // never an "all images" prune
    for (const s of pv.steps) expect(s.argv.some((a: string) => a === "-a" || a === "--all")).toBe(false);
    // unavailable options are refused, unknown ones are a validation error
    expect((await t.req("POST", `/v1/incidents/${id}/actions/${aid}/preview`, { options: ["systemJournal"] })).json().error.code).toBe("agent.incident.cleanupOptionUnavailable");
    expect((await t.req("POST", `/v1/incidents/${id}/actions/${aid}/preview`, { options: ["userJournal"] })).statusCode).toBe(409);
    expect((await t.req("POST", `/v1/incidents/${id}/actions/${aid}/preview`, { options: ["volumes"] })).statusCode).toBe(400);
    // a token for one selection doesn't run another
    const one = (await t.req("POST", `/v1/incidents/${id}/actions/${aid}/preview`, { options: ["images", "images"] })).json();
    expect(one.steps).toEqual([{ argv: ["docker", "image", "prune", "-f"] }]);
    const bad = await t.req("POST", `/v1/incidents/${id}/actions/${aid}/execute`, { previewToken: one.previewToken, confirm: true, options: ["builder"] });
    expect(bad.json().error.code).toBe("agent.preview.invalid");
    const one2 = (await t.req("POST", `/v1/incidents/${id}/actions/${aid}/preview`, { options: ["images"] })).json();
    await writeFile(join(ops, "calls.jsonl"), "");
    const ex = await t.req("POST", `/v1/incidents/${id}/actions/${aid}/execute`, { previewToken: one2.previewToken, confirm: true, options: ["images"] });
    expect(ex.json()).toEqual({ ok: true, code: 0 });
    await t.svc.idle();
    const mutating = (await calls("docker")).map((c) => c.argv).filter((a) => a.includes("prune") || a[0] === "rmi" || a[1] === "rm");
    expect(mutating).toEqual([["image", "prune", "-f"]]);
    const after = (await readState()).images;
    expect(Object.keys(after).sort()).toEqual([A, C, X].sort()); // only the unused dangling image went
    expect(after[A]!.tags).toEqual([PREV]);
    const inc = await t.svc.get(id);
    expect(inc.timeline.find((e) => e.type === "postCheck")?.data).toMatchObject({ action: "disk.cleanup", ok: true, state: "81.5%" });
    await t.app.close();
  });

  it("post-check fails while the disk stays full", async () => {
    const t = await setup({ diskUsage: 97 });
    await opsState({ systemDf: "" });
    await t.send({ key: "disk.full", params: { host: "atlas", mount: "/", percent: 97 }, link: "tiphys://system", priority: "high" });
    const id = t.svc.list()[0]!.id;
    const [c] = (await t.svc.actions(id)).actions;
    const pv = await t.svc.preview(id, c!.id, "phone", { options: ["containers"] });
    await t.svc.execute(id, c!.id, "phone", pv.previewToken, { options: ["containers"] });
    await t.svc.idle();
    const inc = await t.svc.get(id);
    expect(inc.timeline.find((e) => e.type === "postCheck")?.data).toMatchObject({ ok: false, state: "97%" });
    await t.app.close();
  });
});

describe("deploys in context and the route", () => {
  it("adds deploy history, the recentDeploy hint and config changes (key names) to the context; GET /v1/incidents/deploys", async () => {
    const t = await setup();
    await opsState({ psNames: ["web-app-1"], containers: { "web-app-1": ctr("web-app-1", A, { created: "2026-11-16T00:00:00Z" }) }, images: { [A]: { Created: "x", tags: [] }, [B]: { Created: "y", tags: [REF] } } });
    await t.deploys.snapshot();
    const st = await readState();
    st.containers["web-app-1"] = ctr("web-app-1", B, { created: "2026-11-17T09:50:00Z", running: false }) as never;
    await opsState({ ...st, logs: { "web-app-1": [] } });
    const ev = t.notifier.events!;
    await ev.record({ key: "config.saved", params: { file: "web/.env", keys: "DB_PASSWORD,PORT", backupId: "b1" }, device: "phone" });
    await ev.record({ key: "config.restored", params: { file: "other/.env", keys: "X", backupId: "b2" }, device: "phone" });
    await t.send(died());
    const inc = await t.svc.get(t.svc.list()[0]!.id);
    expect(inc.context?.deploys?.map((r) => [r.kind, r.imageId])).toEqual([
      ["changed", B],
      ["seen", A],
    ]);
    expect(inc.hints.find((h) => h.code === "recentDeploy")).toEqual({
      code: "recentDeploy",
      params: { service: "app", created: "2026-11-17T09:50:00Z", image: REF, imageId: B, prevImageId: A },
      evidence: ["deploys"],
    });
    expect(inc.context?.configChanges).toEqual([{ at: expect.any(String), key: "config.saved", file: "web/.env", keys: ["DB_PASSWORD", "PORT"] }]);

    const r = await t.req("GET", "/v1/incidents/deploys?stack=web&service=app&limit=1");
    expect(r.json().deploys.map((d: { imageId: string }) => d.imageId)).toEqual([B]);
    expect((await t.req("GET", "/v1/incidents/deploys")).json().deploys).toHaveLength(2);
    expect((await t.req("GET", "/v1/incidents/deploys?stack=nope")).json().deploys).toEqual([]);
    expect((await t.req("GET", "/v1/incidents/deploys?stack=../x")).statusCode).toBe(400);
    expect((await t.app.inject({ method: "GET", url: "/v1/incidents/deploys" })).statusCode).toBe(401);
    await t.app.close();
  });

  it("an old deploy (or only a first sighting) gives no recentDeploy hint", async () => {
    const t = await setup();
    await opsState({ psNames: ["web-app-1"], containers: { "web-app-1": ctr("web-app-1", A, { created: "2026-11-17T09:50:00Z", running: false }) }, images: {}, logs: { "web-app-1": [] } });
    await t.send(died());
    const inc = await t.svc.get(t.svc.list()[0]!.id);
    expect(inc.context?.deploys?.map((r) => r.kind)).toEqual(["seen"]);
    expect(inc.hints.map((h) => h.code)).not.toContain("recentDeploy");
    await t.app.close();
  });
});
