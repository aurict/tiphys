// Scheduled Claude tasks: fake query + manually advanced clock (no real API calls and no waiting).
import { mkdtemp, mkdir, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Options, Query, SDKMessage, SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { describe, expect, it } from "vitest";
import { claudeRoutes } from "../src/claude/routes.ts";
import { dueAt, nextRun, type ClaudeScheduler } from "../src/claude/schedules.ts";
import { testApp } from "./helpers.ts";

const result = (text: string) =>
  ({ type: "result", subtype: "success", is_error: false, result: text, total_cost_usd: 0.05, num_turns: 1, duration_ms: 2000, session_id: "22222222-2222-4222-8222-222222222222" }) as unknown as SDKMessage;

/** Fake query that answers every user message with `reply`; if `gate` is given, the answer comes after it. */
function fakeQuery(reply: (text: string) => Promise<SDKMessage[]>) {
  const calls: Options[] = [];
  const fn = (p: { prompt: AsyncIterable<SDKUserMessage>; options: Options }): Query => {
    calls.push(p.options);
    async function* gen() {
      yield { type: "system", subtype: "init", session_id: "22222222-2222-4222-8222-222222222222", model: "m", cwd: p.options.cwd, permissionMode: p.options.permissionMode, slash_commands: [] } as unknown as SDKMessage;
      for await (const m of p.prompt) {
        const c = m.message.content as Array<{ type: string; text?: string }>;
        for (const out of await reply(c.find((b) => b.type === "text")?.text ?? "")) yield out;
      }
    }
    const g = gen() as unknown as Query;
    Object.assign(g, { interrupt: async () => {}, setPermissionMode: async () => {}, supportedCommands: async () => [], close: () => {} });
    return g;
  };
  return { fn, calls };
}

/** Monday, 16 November 2026 in local time (the agent's time zone). */
const local = (day: number, h: number, m: number) => new Date(2026, 10, day, h, m, 5);

async function setup(reply: (text: string) => Promise<SDKMessage[]> = async (t) => [result(`Bitti: ${t}`)]) {
  const root = await mkdtemp(join(tmpdir(), "tiphys-sched-"));
  await mkdir(join(root, "proje"));
  const claudeDir = await mkdtemp(join(tmpdir(), "tiphys-sched-config-"));
  const clock = { now: local(16, 2, 50) };
  let sched!: ClaudeScheduler;
  const fq = fakeQuery(reply);
  const t = await testApp(
    (c) => ({ ...c, allowedRoots: [root], features: { ...c.features, claude: true }, claude: { ...c.claude, profiles: { ...c.claude.profiles, [c.claude.defaultProfile]: claudeDir } }, push: { endpoints: [{ deviceId: "phone", url: "http://127.0.0.1:9/up" }], token: null } }),
    [claudeRoutes(fq.fn, { now: () => clock.now, onScheduler: (s) => (sched = s) })],
  );
  const at = async (d: Date) => {
    clock.now = d;
    await sched.tick();
  };
  return { ...t, root, fq, clock, at, sched: () => sched };
}

async function waitFor<T>(fn: () => Promise<T | undefined>, ms = 3000): Promise<T> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v !== undefined) return v;
    await new Promise((r) => setTimeout(r, 15));
  }
  throw new Error("zaman aşımı");
}

describe("zaman hesabı", () => {
  const anchorAt = local(16, 10, 7).toISOString();
  it("günlük, haftalık ve aralıklı görevin zamanı geldi mi", () => {
    expect(dueAt({ when: { kind: "daily", time: "03:00" }, anchorAt }, local(16, 3, 0))).toBe(true);
    expect(dueAt({ when: { kind: "daily", time: "03:00" }, anchorAt }, local(16, 3, 1))).toBe(false);
    // Monday 16 November 2026 (1), Sunday 22 November (7)
    const weekly = { when: { kind: "weekly" as const, time: "09:30", days: [1, 7] }, anchorAt };
    expect(dueAt(weekly, local(16, 9, 30))).toBe(true);
    expect(dueAt(weekly, local(17, 9, 30))).toBe(false);
    expect(dueAt(weekly, local(22, 9, 30))).toBe(true);
    const every = { when: { kind: "interval" as const, everyMinutes: 30 }, anchorAt };
    expect(dueAt(every, local(16, 10, 7))).toBe(false); // not the minute it was created
    expect(dueAt(every, local(16, 10, 37))).toBe(true);
    expect(dueAt(every, local(16, 11, 7))).toBe(true);
    expect(dueAt(every, local(16, 11, 8))).toBe(false);
  });

  it("yaz saati geçişleri (Europe/Berlin): ilkbaharda atlanan saat geçişten sonra çalışır", () => {
    const oldTz = process.env.TZ;
    process.env.TZ = "Europe/Berlin";
    try {
      const daily = { when: { kind: "daily" as const, time: "02:30" }, anchorAt };
      // 29 March 2026: 02:00 → 03:00. The minute after 01:59 (UTC 00:59) is 03:00 (UTC 01:00); 02:30 never exists.
      expect(dueAt(daily, new Date("2026-03-29T00:59:00Z"))).toBe(false);
      expect(dueAt(daily, new Date("2026-03-29T01:00:00Z"))).toBe(true);
      expect(dueAt(daily, new Date("2026-03-29T01:01:00Z"))).toBe(false);
      // Ordinary day: only on the exact minute
      expect(dueAt(daily, new Date("2026-03-30T00:30:00Z"))).toBe(true);
      // 25 October 2026: 03:00 → 02:00; 02:30 matches twice (UTC 00:30 and 01:30), tick() skips the second
      expect(dueAt(daily, new Date("2026-10-25T00:30:00Z"))).toBe(true);
      expect(dueAt(daily, new Date("2026-10-25T01:30:00Z"))).toBe(true);
    } finally {
      if (oldTz === undefined) delete process.env.TZ;
      else process.env.TZ = oldTz;
    }
  });

  it("sonraki çalışma zamanı", () => {
    expect(nextRun({ when: { kind: "daily", time: "03:00" }, anchorAt }, local(16, 3, 0))).toEqual(new Date(2026, 10, 17, 3, 0));
    expect(nextRun({ when: { kind: "weekly", time: "09:30", days: [7] }, anchorAt }, local(16, 12, 0))).toEqual(new Date(2026, 10, 22, 9, 30));
    expect(nextRun({ when: { kind: "interval", everyMinutes: 45 }, anchorAt }, local(16, 10, 7))).toEqual(new Date(2026, 10, 16, 10, 52));
    expect(nextRun({ when: { kind: "interval", everyMinutes: 45 }, anchorAt }, local(16, 12, 0))).toEqual(new Date(2026, 10, 16, 12, 22));
  });
});

describe("zamanlanmış görevler", () => {
  it("ekle/düzenle/sil; geçersiz zaman ve izin dışı klasör reddedilir", async () => {
    const { app, auth, root } = await setup();
    const body = { name: "Gece raporu", cwd: join(root, "proje"), prompt: "Durumu özetle", when: { kind: "daily", time: "03:00" }, permissionMode: "acceptEdits", effort: "high" };
    const res = await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: body });
    expect(res.statusCode).toBe(200);
    const s = res.json().schedule;
    expect(s).toMatchObject({ name: "Gece raporu", enabled: true, lastRun: null, running: false, nextRun: new Date(2026, 10, 16, 3, 0).toISOString() });

    expect((await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: { ...body, when: { kind: "interval", everyMinutes: 5 } } })).statusCode).toBe(400);
    expect((await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: { ...body, when: { kind: "daily", time: "25:00" } } })).statusCode).toBe(400);
    const outside = await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: { ...body, cwd: "/etc" } });
    expect(outside.statusCode).toBe(403);
    expect(outside.json().error.code).toBe("agent.claude.folderNotAllowed");

    const put = await app.inject({ method: "PUT", url: `/v1/claude/schedules/${s.id}`, headers: auth, payload: { ...body, enabled: false } });
    expect(put.json().schedule).toMatchObject({ enabled: false, nextRun: null });
    expect((await app.inject({ url: "/v1/claude/schedules", headers: auth })).json().schedules).toHaveLength(1);
    expect((await app.inject({ method: "DELETE", url: `/v1/claude/schedules/${s.id}`, headers: auth })).statusCode).toBe(200);
    expect((await app.inject({ method: "DELETE", url: `/v1/claude/schedules/${s.id}`, headers: auth })).statusCode).toBe(404);
  });

  it("zamanı gelince oturum açar (başlık ⏰ ad), bitince son çalışma + bildirim + olay; kalıcı", async () => {
    const { app, auth, root, at, sent, fq, store } = await setup();
    const s = (
      await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: { name: "Gece raporu", cwd: join(root, "proje"), prompt: "Durumu özetle", when: { kind: "daily", time: "03:00" }, permissionMode: "bypassPermissions", effort: "low" } })
    ).json().schedule;

    await at(local(16, 2, 59));
    expect(fq.calls).toHaveLength(0);
    await at(local(16, 3, 0));
    expect(fq.calls).toHaveLength(1);
    expect(fq.calls[0]).toMatchObject({ cwd: join(root, "proje"), permissionMode: "bypassPermissions", effort: "low" });
    await at(local(16, 3, 0)); // the same minute does not run twice
    expect(fq.calls).toHaveLength(1);

    const view = await waitFor(async () => {
      const v = (await app.inject({ url: "/v1/claude/schedules", headers: auth })).json().schedules[0];
      return v.lastRun?.ok === true ? v : undefined;
    });
    expect(view.lastRun).toMatchObject({ live: true, sdkSessionId: "22222222-2222-4222-8222-222222222222" });
    const session = (await app.inject({ url: `/v1/claude/sessions/${view.lastRun.sessionId}`, headers: auth })).json().session;
    expect(session.title).toBe("⏰ Gece raporu");
    expect(sent).toContainEqual(expect.objectContaining({ key: "claude.done", params: expect.objectContaining({ title: "⏰ Gece raporu", summary: "Bitti: Durumu özetle" }) }));
    const events = (await app.inject({ url: "/v1/events", headers: auth })).json().events;
    expect(events).toContainEqual(expect.objectContaining({ key: "claude.scheduled", params: { name: "Gece raporu", id: s.id }, link: `tiphys://claude/${view.lastRun.sessionId}` }));

    const file = JSON.parse(await readFile(join(store.path, "..", "claude-schedules.json"), "utf8"));
    expect(file[0]).toMatchObject({ id: s.id, lastRun: { ok: true } });
  });

  it("kaçırılan zaman telafi edilmez; kısa takılma (≤ 2 dk) edilir", async () => {
    const { app, auth, root, at, fq } = await setup();
    await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: { name: "A", cwd: join(root, "proje"), prompt: "x", when: { kind: "daily", time: "03:00" } } });
    await at(local(16, 2, 50));
    await at(local(16, 3, 10)); // the agent was "down" at 03:00
    expect(fq.calls).toHaveLength(0);
    await at(local(17, 2, 59));
    await at(local(17, 3, 1)); // the tick was one minute late
    expect(fq.calls).toHaveLength(1);
  });

  it("önceki çalışma sürüyorsa yenisi atlanır; elle çalıştırma 409", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const { app, auth, root, at, fq } = await setup(async (t) => {
      await gate;
      return [result(t)];
    });
    const s = (await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: { name: "Sık", cwd: join(root, "proje"), prompt: "x", when: { kind: "interval", everyMinutes: 15 } } })).json().schedule;
    await at(local(16, 3, 5)); // created at 02:50 → slots 03:05, 03:20…
    expect(fq.calls).toHaveLength(1);
    expect((await app.inject({ url: "/v1/claude/schedules", headers: auth })).json().schedules[0].running).toBe(true);
    await at(local(16, 3, 20));
    expect(fq.calls).toHaveLength(1);
    const run = await app.inject({ method: "POST", url: `/v1/claude/schedules/${s.id}/run`, headers: auth });
    expect(run.statusCode).toBe(409);
    expect(run.json().error.code).toBe("agent.claude.scheduleRunning");
    const events = (await app.inject({ url: "/v1/events", headers: auth })).json().events;
    expect(events.map((e: { key: string }) => e.key)).toContain("claude.scheduleSkipped");

    release();
    await waitFor(async () => ((await app.inject({ url: "/v1/claude/schedules", headers: auth })).json().schedules[0].running ? undefined : true));
    const manual = await app.inject({ method: "POST", url: `/v1/claude/schedules/${s.id}/run`, headers: auth });
    expect(manual.statusCode).toBe(200);
    expect(manual.json()).toMatchObject({ sessionId: expect.any(String), schedule: { lastRun: { manual: true } } });
    expect(fq.calls).toHaveLength(2);
  });

  it("sonbaharda tekrar eden saat (Europe/Berlin 31 Ekim 2027 02:30): günlük görev bir kez çalışır", async () => {
    const oldTz = process.env.TZ;
    process.env.TZ = "Europe/Berlin";
    try {
      const { app, auth, root, at, fq } = await setup();
      await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: { name: "Gece", cwd: join(root, "proje"), prompt: "x", when: { kind: "daily", time: "02:30" } } });
      await at(new Date("2027-10-31T00:30:00Z")); // first 02:30 (CEST)
      expect(fq.calls).toHaveLength(1);
      await waitFor(async () => ((await app.inject({ url: "/v1/claude/schedules", headers: auth })).json().schedules[0].running ? undefined : true));
      await at(new Date("2027-10-31T01:30:00Z")); // second 02:30 (CET)
      expect(fq.calls).toHaveLength(1);
      await at(new Date("2027-11-01T01:30:00Z")); // next day 02:30 is normal
      expect(fq.calls).toHaveLength(2);
    } finally {
      if (oldTz === undefined) delete process.env.TZ;
      else process.env.TZ = oldTz;
    }
  });

  it("kayıt dosyası yazılamazsa çalışan görev ikinci kez başlamaz; yazım düzelince kayıt sürer", async () => {
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const { app, auth, root, at, fq, dir } = await setup(async (t) => {
      await gate;
      return [result(t)];
    });
    const s = (await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: { name: "Sık", cwd: join(root, "proje"), prompt: "x", when: { kind: "interval", everyMinutes: 15 } } })).json().schedule;
    // A folder in place of the temp file: writeFile fails with EISDIR (instead of disk full / permission error)
    const tmp = join(dir, "claude-schedules.json.tmp");
    await mkdir(tmp);
    await at(local(16, 3, 5));
    expect(fq.calls).toHaveLength(1);
    const view = async () => (await app.inject({ url: "/v1/claude/schedules", headers: auth })).json().schedules[0];
    expect((await view()).running).toBe(true); // session started; the write error was not counted as "failed to start"
    await at(local(16, 3, 20));
    expect(fq.calls).toHaveLength(1); // did not start a second time
    await rm(tmp, { recursive: true });
    release();
    await waitFor(async () => ((await view()).running ? undefined : true));
    // The chain is not permanently broken: an edit is saved
    expect((await app.inject({ method: "PUT", url: `/v1/claude/schedules/${s.id}`, headers: auth, payload: { name: "Yeni ad", cwd: join(root, "proje"), prompt: "x", when: { kind: "interval", everyMinutes: 15 } } })).statusCode).toBe(200);
    await waitFor(async () => ((await readFile(join(dir, "claude-schedules.json"), "utf8").catch(() => "")).includes("Yeni ad") ? true : undefined));
  });

  it("klasör silinmişse çalışma başarısız sayılır ve bildirilir; kapalı görev çalışmaz", async () => {
    const { app, auth, root, at, fq, sent } = await setup();
    await mkdir(join(root, "gecici"));
    await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: { name: "Kayıp", cwd: join(root, "gecici"), prompt: "x", when: { kind: "daily", time: "03:00" } } });
    await app.inject({ method: "POST", url: "/v1/claude/schedules", headers: auth, payload: { name: "Kapalı", cwd: join(root, "proje"), prompt: "x", when: { kind: "daily", time: "03:00" }, enabled: false } });
    await rm(join(root, "gecici"), { recursive: true });
    await at(local(16, 3, 0));
    expect(fq.calls).toHaveLength(0);
    expect(sent).toContainEqual(expect.objectContaining({ key: "claude.scheduleFailed", params: expect.objectContaining({ name: "Kayıp", reason: "agent.claude.folderNotFound" }) }));
    const list = (await app.inject({ url: "/v1/claude/schedules", headers: auth })).json().schedules;
    expect(list[0].lastRun).toMatchObject({ ok: false, sessionId: null, error: "agent.claude.folderNotFound" });
    expect(list[1].lastRun).toBeNull();
  });
});
