// Sleep mode S5 (PLAN.md §21 A-5, A-6, A-7): the night filter (critical kinds pass, the rest held in memory only:
// nothing written but the usual event record), the night collector and the morning summary (merge across members, a
// member down, one transient push from the leader, GET /v1/sleep/summary and its 12 h expiry, the morning screen's
// `morning`), and Velour on the leader (one owner of its volume across the playlist fade, the alarm, stop, crash
// recovery and adoption; the sleep timer; ducking messages to the pages and the members). Fake Velour, fake jobs, no
// real hardware or network.
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readdir, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { AgentConfig } from "../src/config.ts";
import { EventLog } from "../src/events.ts";
import type { ExecResult } from "../src/exec.ts";
import { Notifier, type Notice } from "../src/notify.ts";
import { displayRoutes, type DisplayIo, type NightJobs, type Upstream } from "../src/screen/display.ts";
import type { SleepPlan, SleepSession } from "../src/screen/sleep.ts";
import { parseGroupMessage } from "../src/screen/sleep_group.ts";
import {
  criticalKinds, mergeNights, MorningWait, NightLog, parseNight, parseSummary, passesAtNight, summaryParams, SUMMARY_KEEP_MS, titleOf, type NightCounts,
} from "../src/screen/sleep_night.ts";
import { parseVelourHeld, restoreVelour, SleepPlaylist, VELOUR_UNAVAILABLE, VelourVolume, type VelourHeld } from "../src/screen/sleep_velour.ts";
import { AlarmEffects, type AlarmDeps } from "../src/screen/sleep_alarm.ts";
import { sleepSettingsSchema } from "../src/config.ts";
import { sourceRoutes, type SourceIo } from "../src/screen/source.ts";
import { testApp } from "./helpers.ts";

const MIN = 60_000;
const H = 60 * MIN;
const cleanups: Array<() => unknown> = [];
afterEach(async () => {
  vi.unstubAllGlobals();
  for (const c of cleanups.splice(0).reverse()) await c();
});
const flush = async (n = 8) => {
  for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r));
};
const until = async (f: () => boolean | Promise<boolean>, ms = 5000) => {
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
        await flush();
      }
      now = end;
      await flush();
    },
  };
}

/** A fake Velour: its state, and every op sent. */
function fakeVelour(o: { playing?: boolean; volume?: number; fail?: boolean } = {}) {
  const state = { volume: o.volume ?? 60, playing: o.playing ?? false, sleep: null as number | null };
  const ops: Array<Record<string, unknown>> = [];
  const call = async (op: Record<string, unknown>) => {
    ops.push(op);
    if (o.fail) throw new Error("unavailable");
    if (op.op === "toggle") state.playing = !state.playing;
    if (op.op === "play-target") state.playing = true;
    if (op.op === "volume") state.volume = op.percent as number;
    if (op.op === "sleep") state.sleep = typeof op.minutes === "number" ? op.minutes : null;
    return { ...state };
  };
  return { state, ops, call, names: () => ops.map((x) => x.op) };
}

// ---------------------------------------------------------------- night filter

const n = (key: string, params: Record<string, string | number> = {}, extra: Partial<Notice> = {}): Notice => ({ key, params, ...extra });

describe("night filter", () => {
  it("critical kinds: host down, security trap/alarm, a new incident, disk full; the mode's own pushes always pass", () => {
    expect(criticalKinds(n("host.offline", { host: "nas" }))).toEqual(["hostDown"]);
    expect(criticalKinds(n("uptime.down", { monitor: "web" }))).toEqual(["hostDown"]);
    expect(criticalKinds(n("security.trap", { host: "x" }))).toEqual(["securityTrap"]);
    expect(criticalKinds(n("security.change", { severity: "warning" }))).toEqual([]);
    expect(criticalKinds(n("security.change", { severity: "critical" }))).toEqual(["securityTrap"]);
    expect(criticalKinds(n("disk.full", { mount: "/" }, { data: { incidentId: "i1" } }))).toEqual(["incident", "diskFull"]);
    expect(criticalKinds(n("docker.died", { container: "db" }, { data: { incidentId: "i2" } }))).toEqual(["incident"]);
    expect(criticalKinds(n("docker.died", { container: "db" }))).toEqual([]); // no incident room: not an incident
    expect(criticalKinds(n("claude.waiting"))).toEqual([]);
    const all = ["hostDown", "securityTrap", "incident", "diskFull"];
    expect(passesAtNight(n("backup.failed", { name: "nas" }), all)).toBe(false);
    expect(passesAtNight(n("disk.full", { mount: "/" }), ["hostDown"])).toBe(false);
    expect(passesAtNight(n("disk.full", { mount: "/" }, { data: { incidentId: "i" } }), ["incident"])).toBe(true);
    expect(passesAtNight(n("sleep.alarm"), [])).toBe(true);
    expect(passesAtNight(n("push.test"), [])).toBe(true);
  });

  it("titles: key + subject, redacted, no text of a sensitive notification", () => {
    expect(titleOf(n("backup.stale", { host: "nas", name: "daily", hours: 30 }))).toBe("backup.stale · daily");
    expect(titleOf(n("claude.done"))).toBe("claude.done");
    expect(titleOf(n("clipboard.pc", { text: "secret" }, { sensitive: true }))).toBe("clipboard.pc");
    expect(titleOf(n("service.failed", { unit: "x password=hunter2hunter2" }))).not.toContain("hunter2");
  });

  it("Notifier gate: held = recorded like before but not sent; critical sent; nothing else written; gate off → all sent", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-night-"));
    const sent: string[] = [];
    vi.stubGlobal("fetch", async (_url: string, init: { body: string }) => {
      sent.push((JSON.parse(init.body) as { key: string }).key);
      return new Response(null, { status: 200 });
    });
    const cfg = { push: { endpoints: [{ deviceId: "phone", url: "https://push.example/t" }], token: null } } as unknown as AgentConfig;
    const events = new EventLog(join(dir, "events.jsonl"));
    const notifier = new Notifier(() => cfg, () => {}, events);
    const night = new NightLog(Date.now());
    notifier.setGate((x) => {
      night.seen(x);
      if (passesAtNight(x, ["hostDown", "diskFull"])) return false;
      night.hold(x);
      return true;
    });
    expect(await notifier.send(n("backup.failed", { host: "h", name: "nas", id: "b1" }))).toBe(0);
    expect(await notifier.send(n("claude.waiting", { session: "s" }))).toBe(0);
    expect(await notifier.send(n("host.offline", { host: "nas", minutes: 3 }))).toBe(1);
    expect(await notifier.send(n("clipboard.pc", { text: "x" }, { sensitive: true }))).toBe(0);
    expect(sent).toEqual(["host.offline"]);
    expect(night.held).toBe(3);
    expect(night.counts().titles).toEqual(["backup.failed · nas", "claude.waiting", "clipboard.pc"]);
    expect(night.counts()).toMatchObject({ backupsFailed: 1, held: 3 });
    const recorded = (await readFile(join(dir, "events.jsonl"), "utf8")).trim().split("\n").map((l) => (JSON.parse(l) as { key: string }).key);
    expect(recorded).toEqual(["backup.failed", "claude.waiting", "host.offline"]); // the history as always; not the sensitive one
    expect(await readdir(dir)).toEqual(["events.jsonl"]); // the held ones live in memory only
    notifier.setGate(null);
    expect(await notifier.send(n("claude.waiting"))).toBe(1);
  });
});

// ---------------------------------------------------------------- collector and merge

const counts = (o: Partial<NightCounts> = {}): NightCounts => ({ jobs: 0, jobsFailed: 0, backups: 0, backupsFailed: 0, incidents: 0, held: 0, titles: [], jobList: [], ...o });

describe("night collector and morning summary", () => {
  it("counts jobs, backups (checks that ran in the night, failures from notices), incidents (room list, else openers), held", () => {
    const t0 = 1_700_000_000_000;
    const log = new NightLog(t0);
    log.jobDone({ type: "jobDone", name: "cargo", durationSec: 1200, exitCode: null });
    log.jobDone({ type: "jobDone", name: "flutter", durationSec: 60, exitCode: 2 });
    log.jobDone({ type: "jobs", running: [] });
    log.seen(n("backup.stale", { id: "b2", name: "photos" }));
    log.seen(n("docker.died", { container: "db" }, { data: { incidentId: "i1" } }));
    log.seen(n("docker.oom", { container: "db" }, { data: { incidentId: "i1" } }));
    const iso = (t: number) => new Date(t).toISOString();
    const c = log.counts({ backups: () => [{ id: "b1", status: "ok", lastAt: iso(t0 + H) }, { id: "b2", status: "stale", lastAt: iso(t0 - 30 * H) }, { id: "b3", status: "ok", lastAt: iso(t0 - H) }] }, t0 + 8 * H);
    expect(c).toMatchObject({ jobs: 2, jobsFailed: 1, backups: 1, backupsFailed: 1, incidents: 1 });
    expect(c.jobList).toEqual([{ name: "cargo", durationSec: 1200, exitCode: null }, { name: "flutter", durationSec: 60, exitCode: 2 }]);
    const withRoom = log.counts({ incidents: () => [{ id: "a", openedAt: iso(t0 + H), test: false }, { id: "b", openedAt: iso(t0 + H), test: true }, { id: "c", openedAt: iso(t0 - H), test: false }] }, t0 + 8 * H);
    expect(withRoom.incidents).toBe(1);
    log.end(t0 + 8 * H);
    log.jobDone({ type: "jobDone", name: "late", durationSec: 1, exitCode: 0 });
    log.hold(n("x"));
    expect(log.counts()).toMatchObject({ jobs: 2, held: 0 }); // over at the dismiss
  });

  it("a member's counts are validated; merge: sums, titles ≤ 3 leader first, jobs with their host, a missing member counted", () => {
    expect(parseNight("x")).toBeNull();
    expect(parseNight({ jobs: -3, held: 2.5, titles: ["a", 5, "b", "c", "d"], jobList: [{ name: "x", durationSec: 9, exitCode: 1 }, { durationSec: 1 }] })).toEqual({
      jobs: 0, jobsFailed: 0, backups: 0, backupsFailed: 0, incidents: 0, held: 0, titles: ["a", "b"], jobList: [{ name: "x", durationSec: 9, exitCode: 1 }],
    });
    const t0 = 1_700_000_000_000;
    const reports = new Map([["laptop", counts({ jobs: 2, jobsFailed: 1, held: 4, titles: ["l1", "l2", "l3"], jobList: [{ name: "vitest", durationSec: 30, exitCode: null }] })]]);
    const s = mergeNights({ session: "sess-0001", t0, end: t0 + 455 * MIN, at: t0 + 456 * MIN, me: "theloth", members: ["theloth", "laptop", "desk"], own: counts({ jobs: 1, backups: 2, held: 1, titles: ["t1"], incidents: 1 }), reports });
    expect(s).toMatchObject({ minutes: 455, jobs: 3, jobsFailed: 1, backups: 2, backupsFailed: 0, incidents: 1, held: 5, titles: ["t1", "l1", "l2"], members: 3, missing: 1 });
    expect(s.jobList).toEqual([{ name: "vitest", durationSec: 30, exitCode: null, host: "laptop" }]);
    expect(summaryParams(s)).toMatchObject({ minutes: 455, titles: "t1\nl1\nl2", missing: 1, members: 3 });
    expect(Object.values(summaryParams(s)).every((v) => typeof v === "string" || typeof v === "number")).toBe(true);
    expect(parseSummary(JSON.parse(JSON.stringify(s)))).toEqual(s);
    expect(parseSummary({ ...s, session: "bad id!" })).toBeNull();
  });

  it("MorningWait: reports before the leader's end count; done at once when all reported, else after the wait (missing); once", async () => {
    const c = fakeClock();
    const done: unknown[] = [];
    const w = new MorningWait({ session: "sess-0001", me: "theloth", members: ["theloth", "laptop"], waitMs: 5000, now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout });
    w.report("laptop", counts({ held: 2 }));
    w.report("stranger", counts({ held: 9 }));
    w.finish(c.now() - H, c.now(), counts({ held: 1 }), (s) => done.push(s));
    expect(done).toHaveLength(1);
    expect(done[0]).toMatchObject({ held: 3, missing: 0, minutes: 60 });
    w.finish(c.now() - H, c.now(), counts(), (s) => done.push(s));
    expect(done).toHaveLength(1);
    const w2 = new MorningWait({ session: "sess-0002", me: "theloth", members: ["theloth", "laptop"], waitMs: 5000, now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout });
    w2.finish(c.now() - H, c.now(), counts({ jobs: 1 }), (s) => done.push(s));
    await c.advance(4999);
    expect(done).toHaveLength(1);
    await c.advance(1);
    expect(done[1]).toMatchObject({ jobs: 1, missing: 1, members: 2 });
    w2.report("laptop", counts({ jobs: 5 })); // too late
    expect(done).toHaveLength(2);
    expect(c.pending).toBe(0);
  });

  it("group messages: night (member → leader), music and summary (leader → member) parse", () => {
    expect(parseGroupMessage({ type: "sleepGroup", sessionId: "sess-0001", action: "night", host: "laptop", night: { jobs: 1 } })).toMatchObject({ action: "night", night: { jobs: 1 } });
    expect(parseGroupMessage({ type: "sleepGroup", sessionId: "sess-0001", action: "music", host: "theloth", on: true })).toMatchObject({ action: "music", music: true });
    expect(parseGroupMessage({ type: "sleepGroup", sessionId: "sess-0001", action: "hello", host: "theloth", members: [], music: false })).toMatchObject({ music: false });
    expect(parseGroupMessage({ type: "sleepGroup", sessionId: "sess-0001", action: "state", host: "laptop" })).toMatchObject({ music: null });
  });
});

// ---------------------------------------------------------------- Velour volume owner and playlist

function velourParts(o: { playing?: boolean; volume?: number; fail?: boolean; fadeMs?: number; playlistId?: string | null } = {}) {
  const c = fakeClock();
  const v = fakeVelour(o);
  let held: VelourHeld | null = null;
  const writes: Array<VelourHeld | null> = [];
  const volume = new VelourVolume({ call: v.call, get: () => held, set: (x) => void (held = x, writes.push(x)), log: () => {} });
  const ducks: boolean[] = [];
  const settings = { playlistId: o.playlistId === undefined ? "PLsleep123" : o.playlistId, volume: 30, fadeMin: 30 };
  const playlist = new SleepPlaylist({ call: v.call, volume, settings: () => settings, fadeMs: o.fadeMs ?? 30 * MIN, duck: (on) => void ducks.push(on), log: () => {}, now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout });
  return { c, v, volume, playlist, ducks, writes, get held() {
    return held;
  }, set held(x: VelourHeld | null) {
    held = x;
  } };
}

describe("Velour: one owner of the volume, the sleep playlist", () => {
  it("playlist: plays at its volume, Velour's sleep timer = the fade, the volume fades to 0, then released (volume back, paused), the pages duck meanwhile", async () => {
    const p = velourParts({ volume: 60 });
    await p.playlist.begin();
    expect(p.v.ops.slice(0, 4)).toEqual([{ op: "state" }, { op: "volume", percent: 30 }, { op: "play-target", target: { kind: "watch", playlistId: "PLsleep123" } }, { op: "sleep", minutes: 30 }]);
    expect(p.held).toMatchObject({ volume: 60, users: ["playlist"], started: ["playlist"], playlistEnds: p.c.now() + 30 * MIN });
    expect(p.ducks).toEqual([true]);
    expect(p.playlist.status()).toMatchObject({ state: "playing", warning: null });
    await p.c.advance(15 * MIN);
    expect(p.v.state.volume).toBe(15); // halfway
    const vols = p.v.ops.filter((x) => x.op === "volume").map((x) => x.percent as number);
    expect(vols.slice(1).every((x, i) => i === 0 || x <= vols[i]!)).toBe(true);
    await p.c.advance(15 * MIN + 10);
    expect(p.ducks).toEqual([true, false]);
    expect(p.v.state).toMatchObject({ volume: 60, playing: false, sleep: null }); // back as it was; timer cancelled
    expect(p.held).toBeNull();
    expect(p.playlist.armed).toBe(false);
    expect(p.c.pending).toBe(0);
  });

  it("the user's own music is never touched; no Velour / unreachable → skipped with a warning; no playlist → off", async () => {
    const busy = velourParts({ playing: true });
    await busy.playlist.begin();
    expect(busy.v.names()).toEqual(["state"]);
    expect(busy.playlist.state).toBe("busy");
    expect(busy.held).toBeNull();
    await busy.playlist.stop();
    expect(busy.v.state.playing).toBe(true);
    const down = velourParts({ fail: true });
    await down.playlist.begin();
    expect(down.playlist.status()).toMatchObject({ state: "unavailable", warning: VELOUR_UNAVAILABLE });
    expect(down.ducks).toEqual([]);
    const none = velourParts({ playlistId: null });
    await none.playlist.begin();
    expect(none.v.ops).toEqual([]);
    expect(none.playlist.state).toBe("off");
    const v = fakeVelour();
    const nocall = new SleepPlaylist({ call: null, volume: new VelourVolume({ call: null, get: () => null, set: () => {}, log: () => {} }), settings: () => ({ playlistId: "PL1", volume: 30, fadeMin: 30 }), fadeMs: MIN, duck: () => {}, log: () => {} });
    await nocall.begin();
    expect(nocall.status().warning).toBe(VELOUR_UNAVAILABLE);
    expect(v.ops).toEqual([]);
  });

  it("alarm while the playlist still holds: the saved volume is the evening's (not the faded one), put back once at the end; snooze pauses only", async () => {
    const p = velourParts({ volume: 60 });
    await p.playlist.begin();
    await p.c.advance(20 * MIN); // faded to 10
    expect(p.v.state.volume).toBe(10);
    // The alarm takes Velour (as sleep_alarm.ts does at a ring) while the playlist is still a user.
    p.volume.take("alarm", p.v.state.volume);
    p.volume.started("alarm");
    expect(p.held).toMatchObject({ volume: 60, users: ["playlist", "alarm"] });
    await p.playlist.end(); // sunrise: the playlist's turn is over
    expect(p.held).toMatchObject({ volume: 60, users: ["alarm"] });
    expect(p.v.ops.filter((x) => x.op === "volume" && x.percent === 60)).toHaveLength(0); // not yet
    await p.volume.pause("alarm");
    expect(p.held).not.toBeNull();
    await p.volume.release("alarm");
    expect(p.v.state).toMatchObject({ volume: 60, playing: false });
    expect(p.v.ops.filter((x) => x.op === "volume" && x.percent === 60)).toHaveLength(1);
    expect(p.held).toBeNull();
  });

  it("the S4 alarm on the owner after a finished playlist: it saves the volume the playlist put back", async () => {
    const p = velourParts({ volume: 55, fadeMs: 2 * MIN });
    await p.playlist.begin();
    await p.c.advance(2 * MIN + 10);
    expect(p.held).toBeNull();
    const s = sleepSettingsSchema.parse({});
    s.alarm = { ...s.alarm, enabled: true, sound: "velour", velourTrack: "trk12345678" };
    const plan: SleepPlan = { t0: p.c.now() - 8 * H, settleMs: 0, fadeMs: 0, soundFadeMs: 0, nightSound: "hum", sunriseAt: p.c.now() - MIN, ringAt: p.c.now(), rampMs: 10_000, alarmSound: "velour", snoozeMs: 9 * MIN, autoStopMs: 20 * MIN, morningMs: 0, snoozes: [], dismissedAt: null };
    const deps: AlarmDeps = {
      plan: () => plan, role: () => "leader", linkUp: () => true, settings: () => s, push: () => {}, record: () => {}, disableOnce: () => {}, heartbeatAge: () => 0,
      restartKiosk: async () => {}, gainChanged: () => {}, wav: null, velour: p.v.call, velourVolume: p.volume, log: () => {}, now: p.c.now, setTimeout: p.c.setTimeout, clearTimeout: p.c.clearTimeout,
    };
    const fx = new AlarmEffects(deps);
    fx.on({ kind: "ring", at: p.c.now(), count: 1, plan });
    await flush();
    expect(p.held).toMatchObject({ volume: 55, users: ["alarm"], started: ["alarm"] });
    await fx.stop();
    expect(p.v.state).toMatchObject({ volume: 55, playing: false });
    expect(p.held).toBeNull();
  });

  it("stop mid-fade: the timer off, paused (the mode started it), the volume back; adoption carries the fade on; crash recovery from the file; an S4 file", async () => {
    const p = velourParts({ volume: 70 });
    await p.playlist.begin();
    await p.c.advance(10 * MIN);
    const file = JSON.parse(JSON.stringify(p.held)) as unknown;
    // Adoption: a new playlist object on the same held state goes on fading.
    p.playlist.detach();
    const ducks: boolean[] = [];
    const again = new SleepPlaylist({ call: p.v.call, volume: p.volume, settings: () => ({ playlistId: "PLsleep123", volume: 30, fadeMin: 30 }), fadeMs: 30 * MIN, duck: (on) => void ducks.push(on), log: () => {}, now: p.c.now, setTimeout: p.c.setTimeout, clearTimeout: p.c.clearTimeout });
    again.adopt();
    expect(ducks).toEqual([true]);
    await p.c.advance(5 * MIN);
    expect(p.v.state.volume).toBe(15);
    await again.stop();
    expect(p.v.state).toMatchObject({ volume: 70, playing: false, sleep: null });
    expect(ducks).toEqual([true, false]);
    // Crash recovery: only the state file.
    const v2 = fakeVelour({ playing: true, volume: 12 });
    await restoreVelour(v2.call, parseVelourHeld(file)!, () => {});
    expect(v2.names()).toEqual(["sleep", "state", "toggle", "volume"]);
    expect(v2.state).toMatchObject({ volume: 70, playing: false });
    // Nothing started by the mode (the alarm took the volume, never played): never paused.
    const v3 = fakeVelour({ playing: true });
    await restoreVelour(v3.call, { volume: 40, users: ["alarm"], started: [], playlistEnds: null }, () => {});
    expect(v3.state).toMatchObject({ volume: 40, playing: true });
    expect(parseVelourHeld({ volume: 33 })).toEqual({ volume: 33, users: ["alarm"], started: [], playlistEnds: null }); // S4 file
    expect(parseVelourHeld({ volume: 33, users: ["x"], started: ["alarm"] })).toEqual({ volume: 33, users: [], started: [], playlistEnds: null });
    expect(parseVelourHeld({ volume: "a" })).toBeNull();
  });
});

// ---------------------------------------------------------------- agents

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

interface HostOpts {
  runtime?: string;
  leader?: Awaited<ReturnType<typeof host>>;
  velour?: ReturnType<typeof fakeVelour> | null;
  desktop?: boolean;
  playlist?: string | null;
  skew?: { ms: number };
  active?: () => boolean;
  restarting?: () => boolean;
  critical?: string[];
}

async function host(name: string, o: HostOpts = {}) {
  const runtime = o.runtime ?? (await mkdtemp(join(tmpdir(), `tiphys-night-${name}-`)));
  const exec = async (cmd: string, args: string[]): Promise<ExecResult> => {
    const ok = (stdout = "") => ({ stdout, stderr: "", code: 0 });
    if (cmd === "hyprctl") return ok(args[0] === "-j" ? JSON.stringify({ id: 1, name: "1" }) : args.join(" ") === "eval return 1" ? "eval is only supported with the lua config manager" : "ok");
    if (cmd === "systemctl" && args[1] === "is-active") return ok((o.active?.() ?? true) ? "active\n" : "inactive\n");
    return ok("");
  };
  const net = { blocked: false, bridges: [] as Bridge[] };
  const io: DisplayIo = {
    exec, runtimeDir: runtime,
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
  let emit: ((m: Record<string, unknown>) => void) | null = null;
  const jobs: NightJobs = { start: (e) => void (emit = e), stop: async () => void (emit = null) };
  const sio: SourceIo = { velour: async () => ({}), exec, spawn: () => { throw new Error("no"); }, telemetry: async () => ({ running: false, buf: null }) };
  const skew = o.skew ?? { ms: 0 };
  const t = await testApp(
    (c) => {
      c.name = name;
      c.features.desktop = o.desktop ?? true;
      if (o.leader) c.screen.sources = { main: { url: "http://theloth.example:7443", token: o.leader.token } };
      if (o.playlist !== undefined) c.screen.modes.sleep.velour.playlistId = o.playlist;
      if (o.critical) c.screen.modes.sleep.notify.critical = o.critical as typeof c.screen.modes.sleep.notify.critical;
      return c;
    },
    [
      async (a, ctx) => {
        const feed = sourceRoutes(a, ctx, { io: sio, heartbeatMs: 50 });
        await displayRoutes(a, ctx, {
          io, feed, displayDir: null, mapDir: runtime, backoff: [0.05], idleMs: 400, watchMs: 60_000, power: { dir: join(runtime, "none") },
          sleep: { scale: 1, ledsDir: join(runtime, "no-leds"), jobs: () => jobs, morningWaitMs: 400, velour: o.velour === undefined ? null : (o.velour?.call ?? null), now: () => Date.now() + skew.ms },
        });
      },
    ],
  );
  const closed = { done: false };
  cleanups.push(() => (closed.done ? undefined : t.app.close()));
  await t.app.ready();
  const req = (method: "GET" | "POST", url: string, payload?: object) => t.app.inject({ method, url, headers: t.auth, ...(payload ? { payload } : {}) });
  const sleep = async () => (await req("GET", "/v1/sleep")).json() as Record<string, any>;
  const summary = async () => ((await req("GET", "/v1/sleep/summary")).json() as { summary: Record<string, any> | null }).summary;
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
  const mornings = () => (t.sent as Notice[]).filter((x) => x.key === "sleep.morning");
  const job = (name: string, exitCode: number | null = null) => emit?.({ type: "jobDone", name, durationSec: 600, exitCode });
  return { ...t, runtime, req, sleep, summary, block, page, mornings, job, skew, close: async () => ((closed.done = true), await t.app.close()) };
}

function groupSession(o: Partial<SleepPlan> | null = null): SleepSession {
  const t0 = Date.now();
  const id = `nite-${t0.toString(36)}${Math.floor(Math.random() * 1e6).toString(36)}`;
  const s: SleepSession = { id, seed: 11, t0, members: [{ host: "theloth", side: "left", distance: "mid" }, { host: "laptop", side: "right", distance: "near" }], leader: "theloth" };
  if (o) {
    const R = t0 + 800;
    s.plan = { t0, settleMs: 20, fadeMs: 20, soundFadeMs: 20, nightSound: "hum", sunriseAt: R - 100, ringAt: R, rampMs: 200, alarmSound: "birds", snoozeMs: 300, autoStopMs: 60_000, morningMs: 400, snoozes: [], dismissedAt: null, ...o };
  }
  return s;
}

describe("night and morning on agents", () => {
  it("alone, no alarm: held vs sent, the stop makes ONE transient summary push; GET summary; 12 h later gone; nothing held after the stop", async () => {
    const h = await host("test", { critical: ["diskFull"] });
    expect((await h.summary())).toBeNull();
    await h.req("POST", "/v1/sleep/start", {});
    const st = await h.sleep();
    expect(st.night).toEqual({ held: 0, filtering: true });
    expect(st.velour).toEqual({ state: "off", endsAt: null, warning: null }); // no playlist chosen
    await h.notifier.send(n("backup.failed", { host: "test", name: "nas", id: "b1" }));
    await h.notifier.send(n("claude.done", { title: "x" }));
    await h.notifier.send(n("disk.full", { host: "test", mount: "/", percent: 97 }));
    h.job("cargo");
    expect((await h.sleep()).night.held).toBe(2);
    await h.req("POST", "/v1/sleep/stop");
    await until(() => h.mornings().length === 1);
    const push = h.mornings()[0]!;
    expect(push).toMatchObject({ transient: true, data: { agent: "test" }, params: { jobs: 1, backupsFailed: 1, held: 2, titles: "backup.failed · nas\nclaude.done", members: 1, missing: 0 } });
    expect(push.data!.session).toMatch(/^[A-Za-z0-9_-]+$/);
    const s = await h.summary();
    expect(s).toMatchObject({ jobs: 1, held: 2, titles: ["backup.failed · nas", "claude.done"], jobList: [{ name: "cargo", durationSec: 600, exitCode: null, host: "test" }] });
    // Not recorded (transient); the held ones are in the history like before the sleep mode.
    const keys = async () => (await readFile(join(h.dir, "events.jsonl"), "utf8")).trim().split("\n").map((l) => (JSON.parse(l) as { key: string }).key);
    await until(async () => (await keys()).includes("sleep.stopped"));
    const ev = await keys();
    expect(ev).not.toContain("sleep.morning");
    expect(ev).toEqual(expect.arrayContaining(["backup.failed", "claude.done", "disk.full", "sleep.started", "sleep.stopped"]));
    // The filter is gone with the mode.
    const before = h.sent.length;
    await h.notifier.send(n("claude.done"));
    expect((await h.sleep()).night).toBeNull();
    expect(h.sent.length).toBe(before + 1);
    h.skew.ms = SUMMARY_KEEP_MS + 1000;
    expect(await h.summary()).toBeNull();
    // morningSummary off: no push.
    h.skew.ms = 0;
    await h.app.inject({ method: "PUT", url: "/v1/sleep", headers: h.auth, payload: { settings: { notify: { morningSummary: false } } } });
    await h.req("POST", "/v1/sleep/start", {});
    await h.req("POST", "/v1/sleep/stop");
    await new Promise((r) => setTimeout(r, 100));
    expect(h.mornings()).toHaveLength(1);
  });

  it("group with an alarm: the member's held notifications and jobs reach the leader at the dismiss; ONE push from the leader with the merged numbers; both morning screens get it", async () => {
    const leader = await host("theloth");
    const member = await host("laptop", { leader });
    const s = groupSession({});
    const started = (await leader.req("POST", "/v1/sleep/start", { session: s })).json();
    await member.req("POST", "/v1/sleep/start", { session: started.session });
    await until(async () => (await member.sleep()).group.link === "ok");
    const lp = await leader.page();
    const mp = await member.page();
    await member.notifier.send(n("claude.waiting", { session: "abc" }));
    await member.notifier.send(n("backup.failed", { host: "laptop", name: "home", id: "h1" }));
    await member.notifier.send(n("host.offline", { host: "nas" })); // critical: sent at once
    member.job("flutter", 1);
    member.job("vitest", 0);
    await leader.notifier.send(n("git.pushed", { repo: "tiphys" }));
    leader.job("cargo");
    expect((await member.sleep()).night.held).toBe(2);
    await until(async () => (await leader.sleep()).phase === "ring");
    mp.ws.send(JSON.stringify({ type: "alarm", action: "dismiss" }));
    await until(() => leader.mornings().length === 1);
    const p = leader.mornings()[0]!;
    expect(p).toMatchObject({ transient: true, data: { agent: "theloth", session: s.id }, params: { jobs: 3, jobsFailed: 1, backupsFailed: 1, held: 3, members: 2, missing: 0 } });
    expect(String(p.params!.titles).split("\n")).toEqual(["git.pushed", "claude.waiting", "backup.failed · home"]);
    expect(member.mornings()).toEqual([]);
    // The morning screens: the leader's and (relayed) the member's.
    await until(() => lp.got.some((x) => x.type === "sleep" && x.morning?.held === 3));
    await until(() => mp.got.some((x) => x.type === "sleep" && x.morning?.held === 3));
    expect((await member.summary())).toMatchObject({ session: s.id, held: 3 });
    await until(async () => !(await leader.sleep()).running && !(await member.sleep()).running);
    await new Promise((r) => setTimeout(r, 600));
    expect(leader.mornings()).toHaveLength(1); // once (no second at the end of the morning)
  });

  it("a member down at the dismiss: the leader doesn't wait forever, the summary says one is missing", async () => {
    const leader = await host("theloth");
    const member = await host("laptop", { leader });
    const s = groupSession();
    await leader.req("POST", "/v1/sleep/start", { session: s });
    await member.req("POST", "/v1/sleep/start", { session: s });
    await until(async () => (await member.sleep()).group.link === "ok");
    await member.notifier.send(n("claude.done"));
    member.block(true);
    await until(async () => (await member.sleep()).group.link === "down");
    await leader.req("POST", "/v1/sleep/stop");
    await until(() => leader.mornings().length === 1);
    expect(leader.mornings()[0]!.params).toMatchObject({ held: 0, members: 2, missing: 1 });
    expect(await member.summary()).toBeNull();
    await member.req("POST", "/v1/sleep/stop");
    expect(member.mornings()).toEqual([]);
  });

  it("Velour playlist on the leader: playing, pages duck (leader's and member's), stop puts Velour back; feature off → skipped with a warning", async () => {
    const v = fakeVelour({ volume: 64 });
    const leader = await host("theloth", { velour: v, playlist: "PLsleep123" });
    const member = await host("laptop", { leader });
    const s = groupSession();
    await leader.req("POST", "/v1/sleep/start", { session: s });
    await member.req("POST", "/v1/sleep/start", { session: s });
    await until(async () => (await leader.sleep()).velour?.state === "playing");
    expect(v.ops.slice(0, 4).map((x) => x.op)).toEqual(["state", "volume", "play-target", "sleep"]);
    expect((await leader.sleep()).music).toBe(true);
    const lp = await leader.page();
    await until(() => lp.got.some((x) => x.type === "sleep" && x.music === true));
    await until(async () => (await member.sleep()).music === true);
    const mp = await member.page();
    await until(() => mp.got.some((x) => x.type === "sleep" && x.music === true));
    const file = JSON.parse(await readFile(join(leader.runtime, "tiphys-screen", "sleep.json"), "utf8")) as { velour: VelourHeld };
    expect(file.velour).toMatchObject({ volume: 64, users: ["playlist"], started: ["playlist"] });
    await leader.req("POST", "/v1/sleep/stop");
    await until(() => v.state.volume === 64 && !v.state.playing);
    expect(v.state.sleep).toBeNull();
    await until(async () => !(await member.sleep()).running);
    // The desktop feature off: Velour is not touched.
    const v2 = fakeVelour();
    const off = await host("solo", { velour: v2, playlist: "PLsleep123", desktop: false });
    await off.req("POST", "/v1/sleep/start", {});
    await until(async () => (await off.sleep()).velour?.state === "unavailable");
    expect((await off.sleep()).velour).toMatchObject({ warning: "agent.sleep.velourUnavailable" });
    expect(v2.ops).toEqual([]);
    await off.req("POST", "/v1/sleep/stop");
  });

  it("crash recovery: the next agent finds the state file without its kiosk → Velour paused and its volume back; adoption keeps the playlist going", async () => {
    const v = fakeVelour({ volume: 48 });
    let active = true;
    const a = await host("test", { velour: v, playlist: "PLsleep123", active: () => active, restarting: () => true });
    await a.req("POST", "/v1/sleep/start", {});
    await until(async () => (await a.sleep()).velour?.state === "playing");
    await a.close(); // restart: the mode is left for the next agent
    expect(v.state.playing).toBe(true);
    // Adoption (the kiosk still up): the playlist keeps its hold, no new play.
    const b = await host("test", { velour: v, playlist: "PLsleep123", runtime: a.runtime, active: () => active, restarting: () => true });
    await until(async () => (await b.sleep()).running && (await b.sleep()).velour?.state === "playing");
    expect(v.ops.filter((x) => x.op === "play-target")).toHaveLength(1);
    await b.close();
    // Crash with the kiosk gone: recovery restores from sleep.json.
    active = false;
    const c = await host("test", { velour: v, playlist: "PLsleep123", runtime: a.runtime, active: () => active });
    await until(() => v.state.volume === 48 && !v.state.playing);
    await until(() => !existsSync(join(a.runtime, "tiphys-screen")));
    expect((await c.sleep()).running).toBe(false);
  });
});

it("helper sanity: a state dir written by hand is restored once", async () => {
  // Guards restoreVelour's use from #cleanup: an unreadable velour block is ignored, the rest still cleaned.
  const runtime = await mkdtemp(join(tmpdir(), "tiphys-night-raw-"));
  await mkdir(join(runtime, "tiphys-screen"), { recursive: true });
  await writeFile(join(runtime, "tiphys-screen", "state.json"), JSON.stringify({ mode: "sleep", token: "b".repeat(64) }));
  await writeFile(join(runtime, "tiphys-screen", "sleep.json"), JSON.stringify({ saved: {}, velour: { volume: "x" } }));
  const v = fakeVelour();
  const h = await host("test", { velour: v, runtime, active: () => false });
  await until(() => !existsSync(join(runtime, "tiphys-screen")));
  expect(v.ops).toEqual([]);
  expect((await h.sleep()).running).toBe(false);
});
