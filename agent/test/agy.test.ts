// agy (Antigravity CLI) sessions over ACP, against a fake `agy acp` (test/fake_agy_acp.mjs).
import { spawn } from "node:child_process";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import type { Spawn } from "../src/agy/acp.ts";
import { AgyManager, shq } from "../src/agy/manager.ts";
import { agyRoutes } from "../src/agy/routes.ts";
import { testApp } from "./helpers.ts";

const FAKE = fileURLToPath(new URL("./fake_agy_acp.mjs", import.meta.url));
const fakeSpawn: Spawn = (_cmd, args, o) => spawn(process.execPath, [FAKE, ...args.slice(1)], { cwd: o.cwd, stdio: ["pipe", "pipe", "pipe"], detached: true });
const fakeWith = (mode: string): Spawn => (_cmd, args, o) =>
  spawn(process.execPath, [FAKE, ...args.slice(1)], { cwd: o.cwd, stdio: ["pipe", "pipe", "pipe"], detached: true, env: { ...process.env, FAKE_AGY_MODE: mode } });

async function setup() {
  const root = await mkdtemp(join(tmpdir(), "tiphys-agy-"));
  const t = await testApp(
    (c) => {
      c.allowedRoots = [root];
      return c;
    },
    [agyRoutes({ spawn: fakeSpawn })],
  );
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const r = (method: string, url: string, payload?: unknown): Promise<any> =>
    t.app.inject({ method: method as "GET", url, headers: t.auth, ...(payload !== undefined ? { payload: payload as object } : {}) });
  type Ev = Record<string, unknown> & { eid: number; seq: number; kind: string };
  /** Polls like the app: after = highest seq seen, events merged by eid. */
  const wait = async (id: string, pred: (b: { session: { status: string }; events: Ev[] }) => boolean) => {
    const byEid = new Map<number, Ev>();
    let after = 0;
    for (let i = 0; i < 60; i++) {
      const b = (await r("GET", `/v1/agy/sessions/${id}?after=${after}&wait=200`)).json() as { session: { status: string }; events: Ev[] };
      for (const e of b.events) {
        byEid.set(e.eid, e);
        after = Math.max(after, e.seq);
      }
      const all = { session: b.session, events: [...byEid.values()].sort((x, y) => x.eid - y.eid) };
      if (pred(all)) return all;
    }
    throw new Error("timeout");
  };
  return { t, root, r, wait };
}

describe("agy", () => {
  it("new session: streams merged chunks with stable ids, title, usage, done notice, resume command", async () => {
    const { t, root, r, wait } = await setup();
    let res = await r("POST", "/v1/agy/sessions", { cwd: root, prompt: "say hello" });
    expect(res.statusCode).toBe(200);
    const s = res.json();
    expect(s).toMatchObject({ conversationId: "s-new-0001", modeId: "default", model: "gemini-4-neon" });
    expect(s.modes.map((m: { id: string }) => m.id)).toEqual(["default", "auto", "plan"]);
    expect(s.resumeCommand).toBe(`cd ${shq(root)} && agy --conversation 's-new-0001'`);
    const b = await wait(s.id, (x) => x.events.some((e) => e.kind === "turnEnd"));
    const agent = b.events.filter((e) => e.kind === "agent");
    expect(agent).toHaveLength(1);
    expect(agent[0]!.text).toBe("hello");
    expect(b.session).toMatchObject({ status: "idle", title: "Fake title", usage: { used: 10, size: 100 } });
    expect(b.events.map((e) => e.kind)).toEqual(["user", "thought", "agent", "turnEnd"]);
    // Polling with after=<last seq> returns nothing new.
    const last = Math.max(...b.events.map((e) => e.seq));
    res = await r("GET", `/v1/agy/sessions/${s.id}?after=${last}`);
    expect(res.json().events).toEqual([]);
    expect(t.sent.some((n) => (n as { key: string }).key === "agy.done")).toBe(true);
    await new Promise((x) => setTimeout(x, 100)); // the audit line is written after the response
    const audit = await readFile(join(t.dir, "audit.jsonl"), "utf8");
    expect(audit).toContain("/v1/agy/sessions");
    expect(audit).not.toContain("say hello");
  });

  it("permission request: high-priority notice with buttons data; allow/deny answered; busy while waiting", async () => {
    const { t, root, r, wait } = await setup();
    const s = (await r("POST", "/v1/agy/sessions", { cwd: root })).json();
    expect((await r("POST", `/v1/agy/sessions/${s.id}/messages`, { text: "please run it" })).statusCode).toBe(200);
    const b = await wait(s.id, (x) => x.session.status === "waiting");
    const perm = b.events.find((e) => e.kind === "permission")!;
    expect(perm).toMatchObject({ command: "echo hi", toolKind: "execute", options: [{ optionId: "allow" }, { optionId: "deny" }] });
    const notice = t.sent.find((n) => (n as { key: string }).key === "agy.waiting") as { priority: string; data: Record<string, string> };
    expect(notice.priority).toBe("high");
    expect(notice.data).toEqual({ sessionId: s.id, requestId: perm.requestId });
    expect((await r("POST", `/v1/agy/sessions/${s.id}/messages`, { text: "again" })).statusCode).toBe(409);
    expect((await r("POST", `/v1/agy/sessions/${s.id}/permissions/${perm.requestId}`, { optionId: "bogus" })).statusCode).toBe(400);
    expect((await r("POST", `/v1/agy/sessions/${s.id}/permissions/${perm.requestId}`, { optionId: "allow" })).statusCode).toBe(200);
    const done = await wait(s.id, (x) => x.events.some((e) => e.kind === "turnEnd"));
    expect(done.events.filter((e) => e.kind === "agent").map((e) => e.text)).toEqual(["ran it"]);
    expect(done.events.some((e) => e.kind === "toolUpdate" && e.status === "completed")).toBe(true);
  });

  it("cancel while waiting answers the prompt as cancelled", async () => {
    const { root, r, wait } = await setup();
    const s = (await r("POST", "/v1/agy/sessions", { cwd: root })).json();
    await r("POST", `/v1/agy/sessions/${s.id}/messages`, { text: "run something" });
    await wait(s.id, (x) => x.session.status === "waiting");
    await r("POST", `/v1/agy/sessions/${s.id}/cancel`, {});
    const b = await wait(s.id, (x) => x.events.some((e) => e.kind === "turnEnd"));
    expect(b.events.find((e) => e.kind === "turnEnd")!.stopReason).toBe("cancelled");
    expect(b.session.status).toBe("idle");
  });

  it("resume replays history (marked), mode and model switch, list, close; only folders inside allowedRoots", async () => {
    const { root, r, wait } = await setup();
    const list = (await r("GET", `/v1/agy/conversations?cwd=${encodeURIComponent(root)}`)).json();
    expect(list.conversations).toEqual([expect.objectContaining({ sessionId: "s-old-0002", title: "Old one", liveId: null })]);
    const s = (await r("POST", "/v1/agy/sessions", { cwd: root, resume: "s-old-0002", modeId: "plan", model: "gemini-3.8-flash" })).json();
    expect(s).toMatchObject({ conversationId: "s-old-0002", modeId: "plan", model: "gemini-3.8-flash" });
    const b = await wait(s.id, (x) => x.events.length >= 2);
    expect(b.events.filter((e) => e.replay).map((e) => `${e.kind}:${e.text}`)).toEqual(["user:old question", "agent:old answer"]);
    expect((await r("POST", "/v1/agy/sessions", { cwd: root, resume: "s-old-0002" })).json().error.code).toBe("agent.agy.alreadyOpen");
    expect((await r("GET", `/v1/agy/conversations?cwd=${encodeURIComponent(root)}`)).json().conversations[0].liveId).toBe(s.id);
    expect((await r("POST", `/v1/agy/sessions/${s.id}/mode`, { modeId: "yolo" })).json().error.code).toBe("agent.agy.unknownMode");
    expect((await r("POST", `/v1/agy/sessions/${s.id}/mode`, { modeId: "auto" })).json().modeId).toBe("auto");
    expect((await r("DELETE", `/v1/agy/sessions/${s.id}`)).statusCode).toBe(200);
    expect((await r("GET", `/v1/agy/sessions/${s.id}`)).json().session.status).toBe("ended");
    expect((await r("POST", "/v1/agy/sessions", { cwd: "/etc" })).statusCode).toBe(403);
    expect((await r("POST", "/v1/agy/sessions", { cwd: root, resume: "../../etc" })).statusCode).toBe(400);
  });

  it("review fixes: late request after close doesn't crash; double resume; oversize line cancels; bad ids; no command in the push", async () => {
    const sent: Array<{ key: string; params: Record<string, unknown> }> = [];
    const notifier = { send: async (n: { key: string; params: Record<string, unknown> }) => (sent.push(n), 1) } as never;
    const late = new AgyManager(notifier, fakeWith("late"));
    const a = await late.start({ cwd: tmpdir() });
    await late.close(a.id);
    await new Promise((x) => setTimeout(x, 200)); // the fake writes its request after SIGTERM: must be ignored
    late.shutdown();

    const m = new AgyManager(notifier, fakeSpawn);
    const both = await Promise.allSettled([m.start({ cwd: tmpdir(), resume: "s-old-0002" }), m.start({ cwd: tmpdir(), resume: "s-old-0002" })]);
    expect(both.map((x) => x.status).sort()).toEqual(["fulfilled", "rejected"]);
    const live = m.list().find((x) => x.status === "idle")!;
    expect(live.resumeCommand).toBe(`cd ${shq(tmpdir())} && agy --conversation 's-old-0002'`);

    void m.send(live.id, "please run");
    for (let i = 0; i < 50 && !sent.some((n) => n.key === "agy.waiting"); i++) await new Promise((x) => setTimeout(x, 50));
    expect(sent.find((n) => n.key === "agy.waiting")!.params.tool).toBe("execute");
    expect(JSON.stringify(sent)).not.toContain("echo hi");
    m.cancel(live.id);

    const big = await m.start({ cwd: tmpdir() });
    await m.send(big.id, "huge please");
    expect(big.events.some((e) => e.kind === "error" && e.text === "agent.agy.oversize")).toBe(true);
    expect(big.events.find((e) => e.kind === "turnEnd")!.stopReason).toBe("cancelled");
    m.shutdown();

    const evil = new AgyManager(notifier, fakeWith("evilid"));
    await expect(evil.start({ cwd: tmpdir() })).rejects.toMatchObject({ code: "agent.agy.startFailed" });
    expect(evil.list()[0]!.status).toBe("error");
    evil.shutdown();
  }, 30_000);

  it("feature off: no routes; missing agy binary → 501", async () => {
    const t = await testApp();
    expect((await t.app.inject({ method: "GET", url: "/v1/agy/sessions", headers: t.auth })).statusCode).toBe(404);
    const root = await mkdtemp(join(tmpdir(), "tiphys-agy-"));
    const t2 = await testApp((c) => ((c.allowedRoots = [root]), c), [agyRoutes({ spawn: (_c, a, o) => spawn("/nonexistent/agy", a, { cwd: o.cwd, stdio: ["pipe", "pipe", "pipe"] }) })]);
    const res = await t2.app.inject({ method: "POST", url: "/v1/agy/sessions", headers: t2.auth, payload: { cwd: root } });
    expect(res.statusCode).toBe(501);
    expect(res.json().error.code).toBe("agent.agy.missing");
  });
});
