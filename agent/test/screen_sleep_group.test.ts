// Sleep group, S3 (PLAN.md §21): the clock offset estimator on noisy Wi-Fi samples (lowest RTT, not the median), the
// group messages both ways (hello, keepalive, members, stop/snooze relay, unknown/ended sessions), member down and
// reconnect, and two real agents in one process (leader + member over the leader's /v1/screen/feed): start on both,
// the member's link and offset, stop propagation both ways, a dropped link, restart adoption and the state files.
// No real Hyprland, Firefox, backlight or network.
import { existsSync } from "node:fs";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { ExecResult } from "../src/exec.ts";
import { displayRoutes, headlessArgs, headlessBrowser, type DisplayIo, type Upstream } from "../src/screen/display.ts";
import { type SleepFile, type SleepSession } from "../src/screen/sleep.ts";
import {
  ALIVE_MS, appliedOffset, CLOCK_EVERY_MS, CLOCK_GAP_MS, CLOCK_PINGS, estimateOffset, LeaderGroup, leaderSource, MEMBER_DOWN, MemberGroup, parseGroupMessage,
  PEER_TIMEOUT_MS, type ClockSample,
} from "../src/screen/sleep_group.ts";
import { sourceRoutes, type SourceIo } from "../src/screen/source.ts";
import { testApp } from "./helpers.ts";

const cleanups: Array<() => unknown> = [];
afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
});
const flush = async (n = 6) => {
  for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r));
};
const until = async (f: () => boolean | Promise<boolean>, ms = 4000) => {
  const end = Date.now() + ms;
  while (!(await f())) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
};

function fakeClock(start = 1_700_000_000_000) {
  let now = start;
  let seq = 0;
  const timers = new Map<number, { at: number; fn: () => void }>();
  return {
    now: () => now,
    setTimeout: (fn: () => void, ms: number) => (timers.set(++seq, { at: now + ms, fn }), seq),
    clearTimeout: (h: unknown) => void timers.delete(h as number),
    get pending() {
      return timers.size;
    },
    async advance(ms: number) {
      const end = now + ms;
      for (;;) {
        let next: [number, { at: number; fn: () => void }] | null = null;
        for (const e of timers) if (e[1].at <= end && (!next || e[1].at < next[1].at)) next = e;
        if (!next) break;
        timers.delete(next[0]);
        now = next[1].at;
        next[1].fn();
      }
      now = end;
    },
  };
}

const SESSION: SleepSession = {
  id: "group-0001",
  seed: 7,
  t0: 1_700_000_000_000,
  members: [{ host: "theloth", side: "left", distance: "mid" }, { host: "laptop", side: "right", distance: "near" }],
  leader: "theloth",
};

// ---------------------------------------------------------------- clock

describe("clock offset", () => {
  /** A sample with the member `skew` ms ahead of the leader, `up`/`down` ms on the wire. */
  const sample = (at: number, skew: number, up: number, down: number): ClockSample => ({ send: at + skew, peer: at + up, recv: at + up + down + skew });

  it("uses the lowest-RTT samples: noisy Wi-Fi (2–81 ms, asymmetric) gives the true offset where the median doesn't", () => {
    // The laptop is 9.7 ms ahead (S0): the leader's clock − ours = −9.7. A busy uplink makes most samples lopsided.
    const wires: Array<[number, number]> = [[1.0, 1.2], [60, 4], [40, 6], [50, 31], [1.1, 1.0], [45, 2], [70, 11], [30, 30]];
    const samples = wires.map(([u, d], i) => sample(1000 * i, 9.7, u, d));
    const e = estimateOffset(samples)!;
    expect(e.rttMs).toBeCloseTo(2.1, 5);
    expect(e.used).toBe(2);
    expect(Math.abs(e.offsetMs - -9.7)).toBeLessThan(0.2);
    // What a median of all samples would have said: far off.
    const all = samples.map((s) => s.peer - (s.send + s.recv) / 2).sort((a, b) => a - b);
    expect(Math.abs((all[3]! + all[4]!) / 2 - -9.7)).toBeGreaterThan(10);
    // Fewer samples: the single best one.
    expect(estimateOffset(samples.slice(0, 3))).toMatchObject({ used: 1, offsetMs: -9.8 });
    // Even the best RTT too long → no estimate (the error could be half of it); reversed times are dropped.
    expect(estimateOffset([sample(0, 0, 100, 90)])).toBeNull();
    expect(estimateOffset([{ send: 10, recv: 5, peer: 7 }])).toBeNull();
    expect(estimateOffset([])).toBeNull();
  });

  it("the page gets it only beyond 20 ms", () => {
    expect(appliedOffset(null)).toBe(0);
    expect(appliedOffset(-9.7)).toBe(0);
    expect(appliedOffset(20)).toBe(0);
    expect(appliedOffset(-20.6)).toBe(-21);
    expect(appliedOffset(35.2)).toBe(35);
  });
});

// ---------------------------------------------------------------- messages

describe("group messages", () => {
  it("parse: type, session id, action, host; members and phase sanitized", () => {
    const base = { type: "sleepGroup", sessionId: "group-0001", action: "hello", host: "laptop" };
    expect(parseGroupMessage(base)).toMatchObject({ sessionId: "group-0001", action: "hello", host: "laptop", members: [] });
    expect(parseGroupMessage({ ...base, action: "unknown", host: undefined })).toMatchObject({ action: "unknown", host: null });
    expect(parseGroupMessage({ ...base, action: "members", members: [{ host: "a", state: "down" }, { host: "bad host", state: "down" }, { host: "b", state: "x" }] })!.members).toEqual([{ host: "a", state: "down" }]);
    expect(parseGroupMessage({ ...base, action: "phase", phase: "ring", at: 5 })).toMatchObject({ phase: "ring", at: 5 });
    for (const bad of [{ ...base, type: "x" }, { ...base, sessionId: "short" }, { ...base, action: "nope" }, { ...base, host: "a b" }, { ...base, host: undefined }, null, "x"]) {
      expect(parseGroupMessage(bad)).toBeNull();
    }
  });

  it("which source reaches the leader: by name, else by the URL's first host label", () => {
    const s = { main: { url: "https://theloth.example.ts.net:7443" }, nas: { url: "http://nas.example:7443" } };
    expect(leaderSource(s, "theloth")).toBe("main");
    expect(leaderSource({ ...s, theloth: { url: "http://x:1" } }, "TheLoth")).toBe("theloth");
    expect(leaderSource(s, "laptop")).toBeNull();
    expect(leaderSource({}, "theloth")).toBeNull();
  });

  /** A leader and a member over a fake link with `lat()` ms each way; the member's clock `skew` ms ahead. */
  function pair(o: { skew?: number; lat?: () => [number, number] } = {}) {
    const clock = fakeClock();
    const skew = o.skew ?? 0;
    const lat = o.lat ?? (() => [2, 2]);
    const got = { leaderStops: [] as string[], memberStops: [] as string[], events: [] as string[], offsets: [] as number[] };
    let up = false;
    const leader = new LeaderGroup({ session: SESSION, me: "theloth", onStop: (f) => got.leaderStops.push(f), onEvent: (a, _at, f) => got.events.push(`leader:${a}:${f}`), now: clock.now, setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout });
    const later = (ms: number, fn: () => void) => clock.setTimeout(fn, ms);
    let member!: MemberGroup;
    // The member's socket as the leader sees it (its replies travel back with the down latency).
    const sock = { send: (d: string) => later(lat()[1], () => up && member.message(JSON.parse(d))) };
    member = new MemberGroup({
      session: SESSION, me: "laptop",
      send: (m) => {
        if (!up) return false;
        const [u] = lat();
        const msg = m as Record<string, unknown>;
        later(u, () => {
          if (!up) return;
          if (msg.type === "clockPing") return void sock.send(JSON.stringify({ type: "clockPong", t: msg.t, peer: clock.now() }));
          const g = parseGroupMessage(msg);
          if (g) leader.message(sock, g);
        });
        return true;
      },
      onStop: (f) => got.memberStops.push(f),
      onEvent: (a, _at, f) => got.events.push(`member:${a}:${f}`),
      onOffset: (ms) => got.offsets.push(ms),
      now: () => clock.now() + skew, setTimeout: clock.setTimeout, clearTimeout: clock.clearTimeout,
    });
    const connect = () => ((up = true), member.linkUp());
    const drop = () => ((up = false), member.linkDown(), leader.gone(sock));
    return { clock, leader, member, sock, got, connect, drop };
  }

  it("hello → members, keepalive every 5 s, a ping burst gives the offset (applied only beyond 20 ms), again every 10 min", async () => {
    const p = pair({ skew: 30 });
    expect(p.member.status()).toMatchObject({ role: "member", link: "connecting", members: [{ host: "theloth", state: "connecting" }, { host: "laptop", state: "running" }] });
    expect(p.leader.status().members.map((m) => m.state)).toEqual(["running", "connecting"]);
    p.connect();
    await p.clock.advance(10);
    expect(p.leader.status()).toMatchObject({ role: "leader", error: null, members: [{ host: "theloth", leader: true, state: "running" }, { host: "laptop", side: "right", distance: "near", leader: false, state: "running" }] });
    await p.clock.advance(CLOCK_PINGS * CLOCK_GAP_MS + 100);
    const st = p.member.status();
    expect(st).toMatchObject({ link: "ok", rttMs: 4, appliedOffsetMs: -30, error: null, members: [{ host: "theloth", state: "running" }, { host: "laptop", state: "running" }] });
    expect(st.offsetMs).toBeCloseTo(-30, 5);
    expect(p.got.offsets).toEqual([-30]);
    // Keepalives keep the leader's view fresh well past the 15 s timeout.
    await p.clock.advance(PEER_TIMEOUT_MS * 3);
    expect(p.leader.status().members[1]!.state).toBe("running");
    // The next burst after 10 min: same offset, no new page message.
    const synced = p.member.status().syncedAt!;
    await p.clock.advance(CLOCK_EVERY_MS);
    expect(p.member.status().syncedAt!).toBeGreaterThan(synced);
    expect(p.got.offsets).toEqual([-30]);
    p.member.close();
    p.leader.close();
    expect(p.member.armed).toBe(false);
  });

  it("small offsets stay 0 on the page; a burst with only long RTTs keeps the old value", async () => {
    let slow = false;
    const p = pair({ skew: 9.7, lat: () => (slow ? [120, 90] : [1, 1]) });
    p.connect();
    await p.clock.advance(3000);
    expect(p.member.status().offsetMs).toBeCloseTo(-9.7, 5);
    expect(p.member.status().appliedOffsetMs).toBe(0);
    expect(p.got.offsets).toEqual([]);
    slow = true;
    await p.clock.advance(CLOCK_EVERY_MS + 5000);
    expect(p.member.status().offsetMs).toBeCloseTo(-9.7, 5);
  });

  it("stop both ways: the member's goes to the leader (relayed to the others), the leader's to every member", async () => {
    const p = pair();
    // A third member's socket on the leader.
    const third: string[] = [];
    const s3 = { send: (d: string) => third.push(d) };
    p.connect();
    await p.clock.advance(10);
    p.leader.message(s3, parseGroupMessage({ type: "sleepGroup", sessionId: SESSION.id, action: "hello", host: "laptop" })!);
    third.length = 0;
    p.member.user("snooze");
    await p.clock.advance(10);
    expect(p.got.events).toEqual(["leader:snooze:laptop"]);
    p.member.user("stop");
    await p.clock.advance(10);
    expect(p.got.leaderStops).toEqual(["laptop"]);
    expect(third.map((d) => JSON.parse(d) as { action: string; host: string })).toEqual([expect.objectContaining({ action: "snooze", host: "laptop" }), expect.objectContaining({ action: "stop", host: "laptop" })]);
    expect(p.got.memberStops).toEqual([]); // not echoed back to the sender
    p.leader.user("stop");
    await p.clock.advance(10);
    expect(p.got.memberStops).toEqual(["theloth"]);
    // Messages of another session or a bad shape are ignored.
    p.member.message({ type: "sleepGroup", sessionId: "other-00001", action: "stop", host: "theloth" });
    p.member.message({ type: "sleepGroup", sessionId: SESSION.id, action: "stop" });
    expect(p.got.memberStops).toEqual(["theloth"]);
  });

  it("member down: the member carries on alone (memberDown), the leader marks it down after 15 s; reconnect resumes", async () => {
    const p = pair();
    p.connect();
    await p.clock.advance(3000);
    p.drop();
    expect(p.member.status()).toMatchObject({ link: "down", error: MEMBER_DOWN, members: [{ host: "theloth", state: "down" }, { state: "running" }] });
    expect(p.member.armed).toBe(false); // no keepalive or ping while down
    await p.clock.advance(PEER_TIMEOUT_MS + 1);
    expect(p.leader.status()).toMatchObject({ error: MEMBER_DOWN, members: [{ state: "running" }, { host: "laptop", state: "down" }] });
    // Sends while down are refused (the page's stop then reaches nobody: the phone stops every member anyway).
    p.member.user("stop");
    await p.clock.advance(10);
    expect(p.got.leaderStops).toEqual([]);
    p.connect();
    await p.clock.advance(10);
    expect(p.member.status()).toMatchObject({ link: "ok", error: null });
    expect(p.leader.status().error).toBeNull();
    await p.clock.advance(ALIVE_MS * 2);
    p.member.user("stop");
    await p.clock.advance(10);
    expect(p.got.leaderStops).toEqual(["laptop"]);
  });

  it("a leader that doesn't run the session answers unknown: the member keeps running, the leader shown stopped", () => {
    const p = pair();
    p.connect();
    p.member.message({ type: "sleepGroup", sessionId: SESSION.id, action: "unknown" });
    expect(p.member.status()).toMatchObject({ link: "ok", error: null, members: [{ host: "theloth", state: "stopped" }, { state: "running" }] });
    // Only the leader's hello/members count; a member's own events are ignored when echoed.
    p.member.message({ type: "sleepGroup", sessionId: SESSION.id, action: "members", host: "other", members: [] });
    expect(p.member.status().members[0]!.state).toBe("stopped");
    p.member.message({ type: "sleepGroup", sessionId: SESSION.id, action: "stop", host: "laptop" });
    expect(p.got.memberStops).toEqual([]);
  });
});

// ---------------------------------------------------------------- two agents

/** The member's Upstream: a WebSocket injected into the leader app (`blocked`: the network is gone). */
class Bridge implements Upstream {
  readyState = 0;
  binaryType = "blob";
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: unknown }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  ws: { send(d: string): void; terminate(): void; on(ev: string, fn: (...a: never[]) => void): void } | null = null;
  constructor(open: () => Promise<Bridge["ws"]>) {
    void open().then(
      (ws) => {
        if (this.readyState === 3) return ws?.terminate();
        this.ws = ws;
        this.readyState = 1;
        ws!.on("close", () => this.#closed());
        ws!.on("message", (d: Buffer, bin: boolean) => this.onmessage?.({ data: bin ? d : d.toString() }));
        this.onopen?.();
      },
      () => this.#closed(),
    );
  }
  #closed() {
    if (this.readyState === 3) return;
    this.readyState = 3;
    this.onclose?.();
  }
  send(d: string) {
    this.ws?.send(d);
  }
  close() {
    this.readyState = 3;
    this.ws?.terminate();
  }
}

async function host(name: string, o: { runtime?: string; leader?: Awaited<ReturnType<typeof host>>; restarting?: () => boolean } = {}) {
  const runtime = o.runtime ?? (await mkdtemp(join(tmpdir(), `tiphys-group-${name}-`)));
  const calls: string[] = [];
  const exec = async (cmd: string, args: string[]): Promise<ExecResult> => {
    calls.push(`${cmd} ${args.join(" ")}`);
    const ok = (stdout = "") => ({ stdout, stderr: "", code: 0 });
    if (cmd === "hyprctl") return ok(args[0] === "-j" ? JSON.stringify({ id: 1, name: "1" }) : args.join(" ") === "eval return 1" ? "eval is only supported with the lua config manager" : "ok");
    if (cmd === "systemctl" && args[1] === "is-active") return ok("active\n");
    return ok("");
  };
  const net = { blocked: false, bridges: [] as Bridge[] };
  const io: DisplayIo = {
    exec,
    runtimeDir: runtime,
    hyprEnv: async () => ({ XDG_RUNTIME_DIR: runtime, HYPRLAND_INSTANCE_SIGNATURE: "sig" }),
    waylandEnv: async () => ({ WAYLAND_DISPLAY: "wayland-1", XDG_RUNTIME_DIR: runtime }),
    busEnv: () => ({}),
    which: (c) => ["firefox", "systemd-run"].includes(c),
    connect: (url, token) => {
      const l = o.leader;
      const b = new Bridge(async () => {
        if (!l || net.blocked) throw new Error("unreachable");
        return (await l.app.injectWS(new URL(url).pathname, { headers: { authorization: `Bearer ${token}` } })) as unknown as Bridge["ws"];
      });
      net.bridges.push(b);
      return b;
    },
    fetch,
    ...(o.restarting ? { restarting: async () => o.restarting!() } : {}),
  };
  const sio: SourceIo = { velour: async () => ({}), exec, spawn: () => { throw new Error("no"); }, telemetry: async () => ({ running: false, buf: null }) };
  const t = await testApp(
    (c) => {
      c.name = name;
      if (o.leader) c.screen.sources = { main: { url: "http://theloth.example:7443", token: o.leader.token } };
      return c;
    },
    [
      async (a, ctx) => {
        const feed = sourceRoutes(a, ctx, { io: sio, heartbeatMs: 50 });
        await displayRoutes(a, ctx, { io, feed, displayDir: null, mapDir: runtime, backoff: [0.05], idleMs: 400, watchMs: 60_000, power: { dir: join(runtime, "none") }, sleep: { scale: 1, ledsDir: join(runtime, "no-leds") } });
      },
    ],
  );
  const closed = { done: false };
  cleanups.push(() => (closed.done ? undefined : t.app.close()));
  await t.app.ready();
  const req = (method: "GET" | "POST", url: string, payload?: object) => t.app.inject({ method, url, headers: t.auth, ...(payload ? { payload } : {}) });
  const sleep = async () => (await req("GET", "/v1/sleep")).json() as Record<string, any>;
  const events = async () => (await readFile(join(t.dir, "events.jsonl"), "utf8").catch(() => "")).trim().split("\n").filter(Boolean).map((l) => (JSON.parse(l) as { key: string }).key);
  /** Network gone: the open link dies, new ones fail (no FIN reaches the leader: it notices by silence). */
  const block = (on: boolean) => {
    net.blocked = on;
    if (on) for (const b of net.bridges) b.close();
  };
  const page = async () => {
    const html = await readFile(join(runtime, "tiphys-screen", "start.html"), "utf8");
    const token = /#t=([a-f0-9]{64})/.exec(html)![1]!;
    const got: Array<Record<string, any>> = [];
    const ws = await t.app.injectWS(`/v1/screen/live?t=${token}`, {}, { onInit: (w) => w.on("message", (d: Buffer) => got.push(JSON.parse(d.toString()) as Record<string, any>)) });
    return { ws, got };
  };
  return { ...t, runtime, calls, req, sleep, events, block, page, close: async () => ((closed.done = true), await t.app.close()) };
}

const groupSession = (): SleepSession => ({ ...SESSION, id: `grp-${Date.now().toString(36)}`, t0: Date.now() });

describe("sleep group: two agents", () => {
  it("start on both → linked (members running, offset measured), state files; a member's stop stops the leader", async () => {
    const leader = await host("theloth");
    const member = await host("laptop", { leader });
    const s = groupSession();
    expect((await leader.req("POST", "/v1/sleep/start", { session: s })).json()).toMatchObject({ running: true, group: { role: "leader" } });
    const started = (await member.req("POST", "/v1/sleep/start", { session: s })).json();
    expect(started).toMatchObject({ running: true, session: { id: s.id, leader: "theloth" }, group: { role: "member" } });
    await until(async () => (await member.sleep()).group.link === "ok" && (await member.sleep()).group.syncedAt !== null);
    const m = await member.sleep();
    expect(m.members).toEqual([
      { host: "theloth", side: "left", distance: "mid", leader: true, state: "running" },
      { host: "laptop", side: "right", distance: "near", leader: false, state: "running" },
    ]);
    // Same process, same clock: the offset is ~0 and the page keeps 0.
    expect(Math.abs(m.group.offsetMs)).toBeLessThan(5);
    expect(m.group).toMatchObject({ appliedOffsetMs: 0, error: null });
    await until(async () => (await leader.sleep()).members[1].state === "running");
    expect((await leader.sleep()).group).toMatchObject({ role: "leader", error: null });
    // The page gets the whole layout and its own id.
    const p = await member.page();
    await until(() => p.got.some((x) => x.type === "sleep"));
    expect(p.got.find((x) => x.type === "sleep")).toMatchObject({ me: "laptop", offsetMs: 0, session: { id: s.id, leader: "theloth", members: ["theloth", "laptop"], layout: [{ id: "theloth", side: "left" }, { id: "laptop", side: "right", distance: "near" }] } });
    // The state file holds the session with the layout; nothing else of the group.
    const f = JSON.parse(await readFile(join(member.runtime, "tiphys-screen", "sleep.json"), "utf8")) as SleepFile;
    expect(f).toMatchObject({ me: "laptop", session: { id: s.id, members: s.members } });
    // The page's Esc hold on the member: both stop.
    p.ws.send(JSON.stringify({ type: "stop" }));
    await until(async () => !(await leader.sleep()).running);
    await until(async () => !(await member.sleep()).running);
    for (const h of [leader, member]) {
      await until(() => !existsSync(join(h.runtime, "tiphys-screen"))); // the stop finishes after `running` is false
      await until(async () => (await h.events()).length === 2);
      expect(await h.events()).toEqual(["sleep.started", "sleep.stopped"]);
    }
  });

  it("the leader's API stop reaches the member; a member that comes late to a stopped session stops at once", async () => {
    const leader = await host("theloth");
    const member = await host("laptop", { leader });
    const s = groupSession();
    await leader.req("POST", "/v1/sleep/start", { session: s });
    await member.req("POST", "/v1/sleep/start", { session: s });
    await until(async () => (await member.sleep()).group.link === "ok" && (await leader.sleep()).members[1].state === "running");
    await leader.req("POST", "/v1/sleep/stop");
    await until(async () => !(await member.sleep()).running);
    // A second session: the leader stops before the member's link is up (network down) → the late hello gets `stop`.
    const s2 = groupSession();
    s2.id = `${s2.id}b`;
    await leader.req("POST", "/v1/sleep/start", { session: s2 });
    member.block(true);
    await member.req("POST", "/v1/sleep/start", { session: s2 });
    await until(async () => (await member.sleep()).group?.link === "down");
    expect((await member.sleep())).toMatchObject({ running: true, group: { error: MEMBER_DOWN }, members: [{ host: "theloth", state: "down" }, { state: "running" }] });
    await leader.req("POST", "/v1/sleep/stop");
    member.block(false);
    await until(async () => !(await member.sleep()).running);
  });

  it("network drop: the member goes on alone (memberDown); reconnect resumes; the leader's agent going away is no group stop", async () => {
    const leader = await host("theloth");
    const member = await host("laptop", { leader });
    const s = groupSession();
    await leader.req("POST", "/v1/sleep/start", { session: s });
    await member.req("POST", "/v1/sleep/start", { session: s });
    await until(async () => (await member.sleep()).group.link === "ok");
    member.block(true);
    await until(async () => (await member.sleep()).group.error === MEMBER_DOWN);
    expect((await member.sleep()).running).toBe(true);
    member.block(false);
    await until(async () => (await member.sleep()).group.link === "ok" && (await member.sleep()).members[0].state === "running");
    await until(async () => (await leader.sleep()).group.error === null);
    // The leader's agent exits (not a user stop): the member carries on alone.
    await leader.close();
    await until(async () => (await member.sleep()).group.error === MEMBER_DOWN);
    expect((await member.sleep()).running).toBe(true);
    await member.req("POST", "/v1/sleep/stop");
    expect((await member.sleep()).running).toBe(false);
  });

  it("start refused: not a member; no source to the leader; a member restart adopts the run and relinks", async () => {
    const leader = await host("theloth");
    const lonely = await host("laptop");
    const s = groupSession();
    expect((await lonely.req("POST", "/v1/sleep/start", { session: s })).json()).toMatchObject({ error: { code: "agent.sleep.noGroup", params: { reason: "noLeaderSource", leader: "theloth" } } });
    expect((await leader.req("POST", "/v1/sleep/start", { session: { ...s, members: [s.members[1]!, { host: "desk", side: "left" }], leader: "desk" } })).json()).toMatchObject({ error: { code: "agent.sleep.noGroup", params: { reason: "notMember", host: "theloth" } } });
    expect((await lonely.sleep()).running).toBe(false);
    // Restart of the member's agent: adopted from sleep.json, the link comes back.
    await leader.req("POST", "/v1/sleep/start", { session: s });
    const member = await host("laptop", { leader, restarting: () => true });
    await member.req("POST", "/v1/sleep/start", { session: s });
    await until(async () => (await member.sleep()).group.link === "ok");
    await member.close();
    const again = await host("laptop", { leader, runtime: member.runtime });
    await until(async () => (await again.sleep()).running && (await again.sleep()).group?.link === "ok");
    expect((await again.sleep()).session.id).toBe(s.id);
    await again.req("POST", "/v1/sleep/stop");
    await until(async () => !(await leader.sleep()).running);
  });
});

describe("sleep group: the alarm (S4)", () => {
  it("the leader's plan reaches a member started without one; both ring; snooze on the leader's API → both snoozed; the member page's dismiss → both morning → both end; one push per transition, from the leader", async () => {
    const leader = await host("theloth");
    const member = await host("laptop", { leader });
    const s = groupSession();
    const R = s.t0 + 900;
    const plan = {
      t0: s.t0, settleMs: 20, fadeMs: 20, soundFadeMs: 20, nightSound: "hum", sunriseAt: R - 100, ringAt: R, rampMs: 200, alarmSound: "birds",
      snoozeMs: 400, autoStopMs: 60_000, morningMs: 300, snoozes: [], dismissedAt: null,
    };
    const started = (await leader.req("POST", "/v1/sleep/start", { session: { ...s, plan } })).json();
    expect(started.session.plan).toMatchObject({ ringAt: R });
    // The S3 shape on the member (an old phone): its own plan (no alarm here), then the leader's through hello.
    expect((await member.req("POST", "/v1/sleep/start", { session: s })).json().session.plan.ringAt).toBeNull();
    await until(async () => (await member.sleep()).session.plan.ringAt === R);
    const p = await member.page();
    await until(() => p.got.some((x) => x.type === "sleep" && x.plan.ringAt === R));
    await until(async () => (await leader.sleep()).phase === "ring" && (await member.sleep()).phase === "ring");
    const pushes = (h: typeof leader) => (h.sent as Array<{ key: string; params: { state: string } }>).filter((n) => n.key === "sleep.alarm").map((n) => n.params.state);
    expect(pushes(leader)).toEqual(["ringing"]);
    expect(pushes(member)).toEqual([]);
    expect((await leader.req("POST", "/v1/sleep/alarm", { action: "snooze" })).json()).toMatchObject({ phase: "snoozed" });
    await until(async () => (await member.sleep()).phase === "snoozed");
    const [ls, ms] = [await leader.sleep(), await member.sleep()];
    expect(ms.session.plan.snoozes).toEqual(ls.session.plan.snoozes); // the same moment on both
    expect(ms.alarm.snoozedUntil).toBe(ls.alarm.snoozedUntil);
    await until(async () => (await leader.sleep()).phase === "ring" && (await member.sleep()).phase === "ring");
    // The laptop's Esc hold while it rings: both dismissed → morning → the mode ends on both by itself.
    p.ws.send(JSON.stringify({ type: "alarm", action: "dismiss" }));
    await until(async () => (await leader.sleep()).phase === "morning");
    expect((await leader.sleep()).session.plan.dismissedAt).toBe((await member.sleep()).session.plan.dismissedAt);
    await until(async () => !(await leader.sleep()).running && !(await member.sleep()).running);
    expect(pushes(leader)).toEqual(["ringing", "snoozed", "ringing", "dismissed"]);
    expect(pushes(member)).toEqual([]);
    for (const h of [leader, member]) {
      await until(async () => (await h.events()).includes("sleep.stopped"));
      expect((await h.events()).filter((k) => k === "sleep.alarm")).toHaveLength(3); // rang, rang, dismissed
    }
  });
});

describe("headless test kiosk", () => {
  it("off unless an absolute browser path is given; its own unit, muted, autoplay", () => {
    expect(headlessBrowser(undefined)).toBeNull();
    expect(headlessBrowser("chromium")).toBeNull();
    expect(headlessBrowser("/x; rm")).toBeNull();
    expect(headlessBrowser("/opt/chrome/chrome-headless-shell")).toBe("/opt/chrome/chrome-headless-shell");
    const a = headlessArgs({ browser: "/b", profile: "/p", url: "file:///s.html" });
    expect(a).toContain("--unit=tiphys-screen-headless");
    expect(a).toContain("--mute-audio");
    expect(a.slice(-3)).toEqual(["--no-default-browser-check", "--user-data-dir=/p", "file:///s.html"]);
  });

  it("a headless sleep: no Hyprland, no hardware, its own work dir; recover leaves the real kiosk's dir alone", async () => {
    const runtime = await mkdtemp(join(tmpdir(), "tiphys-headless-"));
    const calls: string[] = [];
    const exec = async (cmd: string, args: string[]): Promise<ExecResult> => {
      calls.push(`${cmd} ${args.join(" ")}`);
      return { stdout: cmd === "systemctl" && args[1] === "is-active" ? "active\n" : "", stderr: "", code: 0 };
    };
    const io: DisplayIo = {
      exec, runtimeDir: runtime, hyprEnv: async () => ({}), waylandEnv: async () => { throw new Error("no display"); }, busEnv: () => ({}),
      which: () => true, connect: () => { throw new Error("no"); }, fetch,
    };
    // A real kiosk's state in the same runtime dir must stay untouched.
    const { mkdir, writeFile } = await import("node:fs/promises");
    await mkdir(join(runtime, "tiphys-screen"), { recursive: true });
    await writeFile(join(runtime, "tiphys-screen", "state.json"), JSON.stringify({ mode: "work", token: "a".repeat(64) }));
    const t = await testApp((c) => c, [async (a, ctx) => void (await displayRoutes(a, ctx, { io, headless: "/opt/hs/chrome-headless-shell", displayDir: null, mapDir: runtime, watchMs: 60_000, power: { dir: join(runtime, "none") }, sleep: { scale: 1000 } }))]);
    cleanups.push(() => t.app.close());
    await t.app.ready();
    const r = await t.app.inject({ method: "POST", url: "/v1/sleep/start", headers: t.auth, payload: {} });
    expect(r.json()).toMatchObject({ running: true, brightness: { dimming: "content" }, warning: "agent.sleep.ddcUnavailable" });
    expect(calls.some((c) => c.startsWith("hyprctl") || c.startsWith("brightnessctl") || c.startsWith("ddcutil"))).toBe(false);
    expect(calls.find((c) => c.startsWith("systemd-run"))).toContain("--unit=tiphys-screen-headless");
    expect(existsSync(join(runtime, "tiphys-screen-headless", "sleep.json"))).toBe(true);
    await t.app.inject({ method: "POST", url: "/v1/sleep/stop", headers: t.auth });
    expect(existsSync(join(runtime, "tiphys-screen-headless"))).toBe(false);
    expect(existsSync(join(runtime, "tiphys-screen", "state.json"))).toBe(true);
    expect(calls.some((c) => c.includes("stop tiphys-screen.service"))).toBe(false);
  });
});
