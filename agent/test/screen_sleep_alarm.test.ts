// Sleep mode alarm, S4 (PLAN.md §21): the next alarm in local time (days, once, past times, midnight, DST), the alarm
// phases (sunrise, ring, snooze cycles, auto-stop, dismiss → morning → end) and their merge, the run's transitions and
// sunrise brightening with a fake clock (once per transition, also across an adopting agent), the effects (push once
// from the leader, events, `once`, WAV fallback on a stale page and its cleanup, Velour on the leader only), and the
// routes on a fake display (snooze/dismiss over the API and the page, kiosk focus and relaunch, files gone).
// No real backlight, Hyprland, Firefox, PipeWire or Velour.
import { existsSync } from "node:fs";
import { mkdtemp, readFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { sleepSettingsSchema, type SleepSettings } from "../src/config.ts";
import type { ExecResult } from "../src/exec.ts";
import { displayRoutes, type DisplayIo } from "../src/screen/display.ts";
import {
  alarmAt, applyAlarm, endOf, levelAt, mergePlans, parsePlan, parseSleepFile, phaseAt, phasesOf, planOf, sessionSchema, SleepRun, soundingAt,
  type AlarmTransition, type SleepFile, type SleepPlan, type SleepSession,
} from "../src/screen/sleep.ts";
import { AlarmEffects, alarmWav, MEMBER_GAIN, nextAlarm, STALE_MS, VELOUR_START, WAV_GAP_MS, type AlarmDeps } from "../src/screen/sleep_alarm.ts";
import { Hardware } from "../src/screen/sleep_hw.ts";
import { testApp } from "./helpers.ts";

const MIN = 60_000;
const H = 60 * MIN;
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
const defaults = (): SleepSettings => sleepSettingsSchema.parse({});

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

/** The plan of a night started at t0 with the alarm `ringIn` later (default lengths: 25/3/9/20 min, morning 10). */
function alarmPlan(t0: number, ringIn = 8 * H, o: Partial<SleepPlan> = {}): SleepPlan {
  return {
    t0, settleMs: 3 * MIN, fadeMs: 30 * MIN, soundFadeMs: 45 * MIN, nightSound: "hum", sunriseAt: t0 + ringIn - 25 * MIN, ringAt: t0 + ringIn, rampMs: 3 * MIN,
    alarmSound: "birds", snoozeMs: 9 * MIN, autoStopMs: 20 * MIN, morningMs: 10 * MIN, snoozes: [], dismissedAt: null, ...o,
  };
}

// ---------------------------------------------------------------- next alarm

describe("next alarm (local time)", () => {
  const withTz = (tz: string, fn: () => void) => {
    const old = process.env.TZ;
    process.env.TZ = tz;
    try {
      fn();
    } finally {
      if (old === undefined) delete process.env.TZ;
      else process.env.TZ = old;
    }
  };
  const local = (y: number, mo: number, d: number, h: number, mi = 0) => new Date(y, mo - 1, d, h, mi).getTime();
  const show = (t: number | null) => {
    if (t === null) return null;
    const d = new Date(t);
    return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")} ${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  };

  it("days: weekdays skip the weekend, daily, once, chosen days; a time already past today → the next valid day; strictly after", () => {
    withTz("Europe/Istanbul", () => {
      const fri2330 = local(2026, 11, 20, 23, 30); // Friday
      expect(show(nextAlarm({ time: "07:00", days: "weekdays" }, fri2330))).toBe("2026-11-23 07:00"); // Monday
      expect(show(nextAlarm({ time: "07:00", days: "daily" }, fri2330))).toBe("2026-11-21 07:00");
      expect(show(nextAlarm({ time: "07:00", days: "once" }, fri2330))).toBe("2026-11-21 07:00");
      expect(show(nextAlarm({ time: "07:00", days: [0] }, fri2330))).toBe("2026-11-22 07:00"); // Sunday
      expect(show(nextAlarm({ time: "07:00", days: [5] }, fri2330))).toBe("2026-11-27 07:00"); // next Friday
      // Today's 07:00 is gone at 08:00; exactly at the time → the next one.
      expect(show(nextAlarm({ time: "07:00", days: "daily" }, local(2026, 11, 20, 8)))).toBe("2026-11-21 07:00");
      expect(show(nextAlarm({ time: "07:00", days: "daily" }, local(2026, 11, 20, 7)))).toBe("2026-11-21 07:00");
      expect(show(nextAlarm({ time: "07:00", days: "once" }, local(2026, 11, 20, 6, 59)))).toBe("2026-11-20 07:00");
      // Across midnight: started 23:50, alarm 00:10.
      expect(show(nextAlarm({ time: "00:10", days: "daily" }, local(2026, 11, 20, 23, 50)))).toBe("2026-11-21 00:10");
      expect(show(nextAlarm({ time: "00:10", days: "weekdays" }, local(2026, 11, 20, 23, 50)))).toBe("2026-11-23 00:10");
      expect(nextAlarm({ time: "7:00", days: "daily" }, fri2330)).toBeNull();
    });
  });

  it("DST: a time in the spring gap rings at the first valid minute after it; autumn's doubled hour rings once (the first); real lengths follow", () => {
    withTz("Europe/Berlin", () => {
      // 2026-03-29 02:00 → 03:00.
      const sat2300 = local(2026, 3, 28, 23);
      const gap = nextAlarm({ time: "02:30", days: "daily" }, sat2300)!;
      expect(show(gap)).toBe("2026-03-29 03:30");
      expect(gap - sat2300).toBe(3.5 * H);
      const seven = nextAlarm({ time: "07:00", days: "daily" }, sat2300)!;
      expect(show(seven)).toBe("2026-03-29 07:00");
      expect(seven - sat2300).toBe(7 * H); // one hour less of night
      // 2026-10-25 03:00 → 02:00.
      const oct = local(2026, 10, 24, 23);
      const late = nextAlarm({ time: "07:00", days: "daily" }, oct)!;
      expect(show(late)).toBe("2026-10-25 07:00");
      expect(late - oct).toBe(9 * H);
      const twice = nextAlarm({ time: "02:30", days: "daily" }, oct)!;
      expect(new Date(twice).toISOString()).toBe("2026-10-25T00:30:00.000Z"); // 02:30 CEST, the first of the two
      // Weekday of the asked day, even on a DST Sunday.
      expect(show(nextAlarm({ time: "02:30", days: [0] }, sat2300))).toBe("2026-03-29 03:30");
    });
  });

  it("planOf: ring at the next alarm after t0, sunrise before it; the test scale shortens lengths, never the alarm's clock time", () => {
    withTz("Europe/Istanbul", () => {
      const s = defaults();
      s.alarm = { ...s.alarm, enabled: true, time: "07:30", days: "daily", sunriseMin: 25, morningScreen: true };
      const t0 = local(2026, 11, 20, 23, 30);
      const p = planOf(t0, s);
      expect(show(p.ringAt)).toBe("2026-11-21 07:30");
      expect(p).toMatchObject({ sunriseAt: p.ringAt! - 25 * MIN, rampMs: 3 * MIN, snoozeMs: 9 * MIN, autoStopMs: 20 * MIN, morningMs: 10 * MIN, snoozes: [], dismissedAt: null });
      const fast = planOf(t0, s, 60);
      expect(fast).toMatchObject({ ringAt: p.ringAt, sunriseAt: p.ringAt! - 25_000, rampMs: 3000, snoozeMs: 9000, autoStopMs: 20_000, morningMs: 10_000 });
      expect(planOf(t0, defaults())).toMatchObject({ ringAt: null, sunriseAt: null, morningMs: 0 });
    });
  });
});

// ---------------------------------------------------------------- phases

describe("alarm phases", () => {
  const t0 = 1_000_000_000;
  const R = t0 + 8 * H;

  it("night → sunrise (alarm − 25 min) → ring; the ring sounds until its auto-stop, the light stays", () => {
    const p = alarmPlan(t0);
    expect(phasesOf(p).map((x) => [x.phase, x.startedAt - t0, x.endsAt === null ? null : x.endsAt - t0])).toEqual([
      ["settle", 0, 3 * MIN], ["fade", 3 * MIN, 33 * MIN], ["night", 33 * MIN, 8 * H - 25 * MIN], ["sunrise", 8 * H - 25 * MIN, 8 * H], ["ring", 8 * H, null],
    ]);
    expect(soundingAt(p, R - 1)).toBe(false);
    expect(soundingAt(p, R)).toBe(true);
    expect(soundingAt(p, R + 20 * MIN - 1)).toBe(true);
    expect(soundingAt(p, R + 20 * MIN)).toBe(false);
    expect(phaseAt(p, R + 5 * H).phase).toBe("ring");
    expect(alarmAt(p, R + 21 * MIN)).toMatchObject({ next: R, ringing: false, silenced: true });
    expect(alarmAt(p, t0 + H)).toMatchObject({ next: R, sunriseAt: R - 25 * MIN, ringing: false, snoozedUntil: null });
    // Brightness: night level flat, eased in over the sunrise (slow first), morning from the ring on.
    const b = { start: 25, night: 3, morning: 70 };
    expect(levelAt(p, b, R - 26 * MIN)).toBe(3);
    const quarter = levelAt(p, b, R - 25 * MIN + 6.25 * MIN), half = levelAt(p, b, R - 12.5 * MIN);
    expect(quarter - 3).toBeLessThan((half - 3) / 2);
    expect(levelAt(p, b, R)).toBe(70);
    expect(levelAt(p, b, R + 30 * MIN)).toBe(70);
  });

  it("snooze cycles: ring → snoozed 9 min → ring (its own ramp and auto-stop) …; dismiss → morning 10 min → end", () => {
    let p = alarmPlan(t0);
    expect(applyAlarm(p, "snooze", R - MIN)).toBeNull(); // not ringing yet
    p = applyAlarm(p, "snooze", R + 2 * MIN)!;
    expect(applyAlarm(p, "snooze", R + 2 * MIN + 500)).toBeNull(); // the same press twice
    expect(applyAlarm(p, "snooze", R + 5 * MIN)).toBeNull(); // snoozed: nothing to snooze
    expect(phaseAt(p, R + 3 * MIN)).toEqual({ phase: "snoozed", startedAt: R + 2 * MIN, endsAt: R + 11 * MIN });
    expect(alarmAt(p, R + 3 * MIN)).toMatchObject({ ringing: false, snoozedUntil: R + 11 * MIN, next: R + 11 * MIN, snoozes: 1 });
    expect(phaseAt(p, R + 11 * MIN)).toEqual({ phase: "ring", startedAt: R + 11 * MIN, endsAt: null });
    expect(soundingAt(p, R + 30 * MIN)).toBe(true); // 19 min into the second ring
    expect(soundingAt(p, R + 31 * MIN)).toBe(false);
    // A snooze after the auto-stop still works (the light is still on).
    p = applyAlarm(p, "snooze", R + 40 * MIN)!;
    expect(phaseAt(p, R + 49 * MIN).phase).toBe("ring");
    p = applyAlarm(p, "dismiss", R + 50 * MIN)!;
    expect(applyAlarm(p, "dismiss", R + 50 * MIN + 10)).toBeNull();
    expect(applyAlarm(p, "snooze", R + 51 * MIN)).toBeNull();
    expect(phasesOf(p).slice(-3).map((x) => [x.phase, x.startedAt - R, x.endsAt! - R])).toEqual([["snoozed", 40 * MIN, 49 * MIN], ["ring", 49 * MIN, 50 * MIN], ["morning", 50 * MIN, 60 * MIN]]);
    expect(endOf(p)).toBe(R + 60 * MIN);
    expect(alarmAt(p, R + 55 * MIN)).toMatchObject({ next: null, ringing: false, dismissedAt: R + 50 * MIN });
  });

  it("dismiss during sunrise (woke up early) or snooze; no morning screen → the end is the dismiss; a short night shortens sunrise, then the fade", () => {
    const p = alarmPlan(t0, 8 * H, { morningMs: 0 });
    const early = applyAlarm(p, "dismiss", R - 10 * MIN)!;
    expect(phasesOf(early).at(-1)).toEqual({ phase: "sunrise", startedAt: R - 25 * MIN, endsAt: R - 10 * MIN });
    expect(endOf(early)).toBe(R - 10 * MIN);
    expect(soundingAt(early, R + MIN)).toBe(false);
    // The sunrise curve before the dismiss is unchanged by it (the past never changes).
    const b = { start: 25, night: 3, morning: 70 };
    expect(levelAt(early, b, R - 15 * MIN)).toBe(levelAt(p, b, R - 15 * MIN));
    expect(applyAlarm(p, "dismiss", R - 30 * MIN)).toBeNull(); // night: nothing to dismiss (stop is the mode's)
    // Alarm 20 min after the start: settle, fade cut at the ring (its curve unchanged), no night, no sunrise.
    const short = alarmPlan(t0, 20 * MIN);
    expect(phasesOf(short).map((x) => x.phase)).toEqual(["settle", "fade", "ring"]);
    expect(levelAt(short, b, t0 + 10 * MIN)).toBe(levelAt(alarmPlan(t0), b, t0 + 10 * MIN));
    // 45 min: sunrise from the fade's end (shortened), ring on time.
    const mid = alarmPlan(t0, 45 * MIN);
    expect(phasesOf(mid).map((x) => [x.phase, x.startedAt - t0])).toEqual([["settle", 0], ["fade", 3 * MIN], ["sunrise", 33 * MIN], ["ring", 45 * MIN]]);
  });

  it("merge: the leader's base with both sides' events replayed in order; plans parsed strictly (S3 files get defaults)", () => {
    const base = alarmPlan(t0);
    const mine = applyAlarm(base, "snooze", R + MIN)!;
    const leader = applyAlarm(base, "dismiss", R + 15 * MIN)!;
    expect(mergePlans(mine, leader)).toMatchObject({ snoozes: [R + MIN], dismissedAt: R + 15 * MIN });
    // A dismiss that came first makes a later snooze invalid.
    const lateSnooze = applyAlarm(applyAlarm(base, "snooze", R + MIN)!, "snooze", R + 20 * MIN)!;
    expect(mergePlans(lateSnooze, applyAlarm(base, "dismiss", R + 2 * MIN)!)).toMatchObject({ snoozes: [R + MIN], dismissedAt: R + 2 * MIN });
    expect(mergePlans(base, base)).toEqual(base);
    // parsePlan: a full plan round-trips; an S3 plan (no alarm fields) gets the defaults; nonsense is refused.
    expect(parsePlan(JSON.parse(JSON.stringify(leader)))).toEqual(leader);
    const s3 = { t0, settleMs: 1, fadeMs: 2, soundFadeMs: 3, nightSound: "off", sunriseAt: null, ringAt: null, rampMs: 4, alarmSound: "birds" };
    expect(parsePlan(s3)).toEqual({ ...s3, snoozeMs: 9 * MIN, autoStopMs: 20 * MIN, morningMs: 0, snoozes: [], dismissedAt: null });
    for (const bad of [null, [], { ...s3, t0: -1 }, { ...s3, ringAt: t0 - 1 }, { ...s3, ringAt: t0 + 3 * 24 * H }, { ...s3, settleMs: "1" }, { ...leader, snoozes: ["x"] }, { ...leader, sunriseAt: R + 1 }]) {
      expect(parsePlan(bad)).toBeNull();
    }
    // The session carries it (t0 must match).
    const now = Date.now();
    const sess = { id: "abcdefgh12", seed: 1, t0: now, members: ["a"], leader: "a" };
    expect(sessionSchema.parse({ ...sess, plan: alarmPlan(now, H) }).plan).toEqual(alarmPlan(now, H));
    expect(sessionSchema.safeParse({ ...sess, plan: alarmPlan(now + 1, H) }).success).toBe(false);
    expect(sessionSchema.safeParse({ ...sess, plan: { nope: 1 } }).success).toBe(false);
    expect(sessionSchema.parse(sess).plan).toBeUndefined(); // the S3 shape still works
  });
});

// ---------------------------------------------------------------- the run

function laptop(c: ReturnType<typeof fakeClock>) {
  const st = { raw: 48_000 };
  const sets: Array<{ pct: number; at: number }> = [];
  const exec = async (cmd: string, args: string[]): Promise<ExecResult> => {
    const a = args.join(" ");
    if (cmd === "brightnessctl" && a === "-m -c backlight") return { stdout: `intel_backlight,backlight,${st.raw},50%,96000\n`, stderr: "", code: 0 };
    const m = /^-q -d intel_backlight set (\d+)(%?)$/.exec(a);
    if (cmd === "brightnessctl" && m) {
      st.raw = m[2] ? Math.round((Number(m[1]) * 96000) / 100) : Number(m[1]);
      if (m[2]) sets.push({ pct: Number(m[1]), at: c.now() });
      return { stdout: "", stderr: "", code: 0 };
    }
    return { stdout: "", stderr: "", code: 1 };
  };
  return { st, sets, hw: new Hardware({ exec, which: (x) => x === "brightnessctl", ledsDir: "/nonexistent" }) };
}

function runDeps(c: ReturnType<typeof fakeClock>, hw: Hardware) {
  const files: SleepFile[] = [];
  const sent: Array<Record<string, any>> = [];
  const alarms: AlarmTransition[] = [];
  let ended = 0;
  return {
    files, sent, alarms,
    get ended() {
      return ended;
    },
    deps: {
      hw, settings: defaults, log: () => {},
      save: async (f: SleepFile) => void files.push(JSON.parse(JSON.stringify(f)) as SleepFile),
      send: (s: string) => void sent.push(JSON.parse(s) as Record<string, any>),
      onAlarm: (t: AlarmTransition) => void alarms.push(t),
      onEnd: () => void ended++,
      alarmGain: () => 0.4,
      now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout,
    },
  };
}
const sess = (t0: number, plan: SleepPlan): SleepSession => ({ id: "sess-0004", seed: 4, t0, members: [{ host: "laptop", side: "left", distance: "mid" }], leader: "laptop", plan });

describe("SleepRun with an alarm", () => {
  it("sunrise brightens the backlight (eased in, ≤ 1 call / 2 s) to the morning level at the ring; snooze, re-ring, auto-stop, dismiss → morning → end", async () => {
    const c = fakeClock();
    const t0 = c.now();
    const R = t0 + H;
    const m = laptop(c);
    const d = runDeps(c, m.hw);
    const run = await SleepRun.begin(d.deps, sess(t0, alarmPlan(t0, H)), "laptop", 1);
    expect(run.file.plan.ringAt).toBe(R);
    expect(d.sent.find((x) => x.type === "sleep") ?? null).toBeNull(); // the card asks for it on connect
    expect(JSON.parse(run.sleepMessage())).toMatchObject({ plan: { ringAt: R, snoozes: [] }, alarm: { gain: 0.4 } });
    await c.advance(R - 25 * MIN - c.now() - 1);
    expect(m.sets.at(-1)!.pct).toBe(3);
    expect(d.alarms).toEqual([]);
    await c.advance(1);
    expect(d.alarms.map((x) => x.kind)).toEqual(["sunrise"]);
    await c.advance(25 * MIN);
    const sun = m.sets.filter((x) => x.at >= R - 25 * MIN);
    for (let i = 1; i < sun.length; i++) {
      expect(sun[i]!.at - sun[i - 1]!.at).toBeGreaterThanOrEqual(2000);
      expect(sun[i]!.pct).toBeGreaterThan(sun[i - 1]!.pct);
    }
    // Ease-in: the first half of the sunrise climbs less than the second.
    const atHalf = sun.filter((x) => x.at <= R - 12.5 * MIN).at(-1)!.pct;
    expect(atHalf - 3).toBeLessThan(70 - atHalf);
    expect(m.sets.at(-1)!.pct).toBe(70);
    expect(d.alarms.map((x) => [x.kind, x.at, x.count])).toEqual([["sunrise", R - 25 * MIN, 0], ["ring", R, 1]]);
    expect(run.status()).toMatchObject({ phase: "ring", alarm: { ringing: true, next: R } });
    // Snooze 2 min in: snoozed for 9, then rings again (count 2), the page gets the new plan.
    await c.advance(2 * MIN);
    expect(run.alarm("snooze", c.now())).toBe(true);
    expect(run.alarm("snooze", c.now())).toBe(false);
    expect(d.sent.filter((x) => x.type === "sleep").at(-1)).toMatchObject({ plan: { snoozes: [R + 2 * MIN] } });
    expect(d.alarms.at(-1)).toMatchObject({ kind: "snoozed", at: R + 2 * MIN, count: 1 });
    expect(run.status()).toMatchObject({ phase: "snoozed", alarm: { ringing: false, snoozedUntil: R + 11 * MIN } });
    await c.advance(9 * MIN);
    expect(d.alarms.at(-1)).toMatchObject({ kind: "ring", at: R + 11 * MIN, count: 2 });
    // Nobody wakes: quiet after 20 min (the screen stays bright).
    await c.advance(20 * MIN);
    expect(d.alarms.at(-1)).toMatchObject({ kind: "silenced", at: R + 31 * MIN });
    expect(run.status()).toMatchObject({ phase: "ring", alarm: { ringing: false, silenced: true } });
    expect(m.sets.at(-1)!.pct).toBe(70);
    // Dismiss → morning 10 min → the end.
    await c.advance(MIN);
    expect(run.alarm("dismiss", c.now())).toBe(true);
    expect(d.alarms.at(-1)).toMatchObject({ kind: "dismissed" });
    expect(run.status().phase).toBe("morning");
    expect(d.ended).toBe(0);
    await c.advance(10 * MIN);
    expect(d.ended).toBe(1);
    expect(d.alarms.map((x) => x.kind)).toEqual(["sunrise", "ring", "snoozed", "ring", "silenced", "dismissed"]);
    await run.stop();
    expect(m.st.raw).toBe(48_000);
    expect(c.pending).toBe(0);
  });

  it("an adopting agent doesn't report a transition again; the leader's plan merges in (a snooze from the group)", async () => {
    const c = fakeClock();
    const t0 = c.now();
    const R = t0 + H;
    const m = laptop(c);
    const d = runDeps(c, m.hw);
    const run = await SleepRun.begin(d.deps, sess(t0, alarmPlan(t0, H)), "laptop", 1);
    await c.advance(H + MIN);
    expect(d.alarms.map((x) => x.kind)).toEqual(["sunrise", "ring"]);
    run.detach();
    const file = parseSleepFile(d.files.at(-1))!;
    expect(file.reported).toBe(`ring:${R}`);
    const d2 = runDeps(c, m.hw);
    const again = SleepRun.adopt(d2.deps, file);
    await flush();
    expect(d2.alarms).toEqual([]);
    // The leader's plan with a snooze this host missed.
    again.setPlan(applyAlarm(file.plan, "snooze", R + 30_000)!);
    expect(d2.alarms.map((x) => [x.kind, x.at])).toEqual([["snoozed", R + 30_000]]);
    expect(again.file.plan.snoozes).toEqual([R + 30_000]);
    again.setPlan(alarmPlan(t0 + 1, H)); // another session's plan: ignored
    expect(again.file.plan.snoozes).toEqual([R + 30_000]);
    await again.stop();
  });
});

// ---------------------------------------------------------------- effects

function effects(o: { role?: "leader" | "member"; link?: boolean; plan?: SleepPlan; settings?: Partial<SleepSettings["alarm"]>; age?: () => number; velourFails?: boolean } = {}) {
  const c = fakeClock();
  const s = defaults();
  s.volume = 50;
  s.alarm = { ...s.alarm, enabled: true, ...o.settings };
  const t0 = c.now() - 8 * H;
  let plan = o.plan ?? alarmPlan(t0);
  const log = { pushes: [] as Array<{ state: string; data: Record<string, number>; high: boolean }>, records: [] as string[], once: 0, relaunch: 0, gain: 0, wav: [] as string[], velour: [] as string[] };
  const vstate = { volume: 33, playing: true };
  let saved: { volume: number } | null = null;
  const deps: AlarmDeps = {
    plan: () => plan,
    role: () => o.role ?? "leader",
    linkUp: () => o.link ?? true,
    settings: () => s,
    push: (state, data, high) => void log.pushes.push({ state, data, high }),
    record: (state) => void log.records.push(state),
    disableOnce: () => void log.once++,
    heartbeatAge: o.age ?? (() => 5000),
    restartKiosk: async () => void log.relaunch++,
    gainChanged: () => void log.gain++,
    wav: {
      write: async (b) => void log.wav.push(`write ${b.length}`),
      play: async (v) => (log.wav.push(`play ${v}`), true),
      remove: async () => void log.wav.push("remove"),
    },
    velour: async (op) => {
      log.velour.push(JSON.stringify(op));
      if (o.velourFails) throw new Error("unavailable");
      if (op.op === "state") return { ...vstate };
      if (op.op === "toggle") vstate.playing = !vstate.playing;
      if (op.op === "play-target") vstate.playing = true;
      if (op.op === "volume") vstate.volume = op.percent as number;
      return { ...vstate };
    },
    velourSaved: { get: () => saved, set: (v) => void (saved = v) },
    log: () => {},
    now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout,
  };
  const fx = new AlarmEffects(deps);
  const R = plan.ringAt!;
  const ring = (at = R, count = 1): AlarmTransition => ({ kind: "ring", at, count, plan });
  const next = (p: SleepPlan) => void (plan = p);
  return { c, fx, log, vstate, ring, R, next, get plan() {
    return plan;
  }, get saved() {
    return saved;
  } };
}

describe("alarm effects", () => {
  it("push: once from the leader (ringing high, numbers only), none from a linked member, the member's own while its link is down; events; once switches off", () => {
    const l = effects({ settings: { days: "once" } });
    l.fx.on(l.ring());
    expect(l.log.pushes).toEqual([{ state: "ringing", data: { at: l.R, count: 1, snoozeMin: 9, ringAt: l.R }, high: true }]);
    expect(l.log.records).toEqual(["rang"]);
    expect(l.log.once).toBe(1);
    l.fx.on({ kind: "snoozed", at: l.R + MIN, count: 1, plan: l.plan });
    l.fx.on(l.ring(l.R + 10 * MIN, 2));
    expect(l.log.once).toBe(1); // only at the first ring
    l.fx.on({ kind: "silenced", at: l.R + 30 * MIN, count: 2, plan: l.plan });
    l.fx.on({ kind: "dismissed", at: l.R + 31 * MIN, count: 1, plan: l.plan });
    expect(l.log.pushes.map((p) => [p.state, p.high])).toEqual([["ringing", true], ["snoozed", false], ["ringing", true], ["autoStopped", true], ["dismissed", false]]);
    expect(l.log.pushes[1]!.data).toEqual({ at: l.R + MIN, snoozeMin: 9, snoozedUntil: l.R + 10 * MIN });
    expect(l.log.records).toEqual(["rang", "rang", "autoStopped", "dismissed"]);
    const m = effects({ role: "member" });
    m.fx.on(m.ring());
    expect(m.log.pushes).toEqual([]);
    expect(m.log.records).toEqual(["rang"]);
    expect(m.log.once).toBe(0); // weekdays
    const alone = effects({ role: "member", link: false });
    alone.fx.on(alone.ring());
    expect(alone.log.pushes.map((p) => p.state)).toEqual(["ringing"]);
  });

  it("WAV fallback: a stale page at the ring → the WAV written, played in a loop with pauses (ramped), the kiosk relaunched; snooze stops it, the heartbeat stops it, stop deletes it", async () => {
    let age = STALE_MS + 1;
    const e = effects({ age: () => age });
    e.fx.on({ kind: "sunrise", at: e.R - 25 * MIN, count: 0, plan: e.plan });
    expect(e.log.relaunch).toBe(1);
    e.fx.on(e.ring());
    await flush();
    expect(e.log.wav[0]).toMatch(/^write \d+$/);
    expect(e.log.relaunch).toBe(2);
    await e.c.advance(WAV_GAP_MS * 4);
    const plays = e.log.wav.filter((x) => x.startsWith("play")).map((x) => Number(x.split(" ")[1]));
    expect(plays.length).toBe(5);
    expect(plays.every((v, i) => i === 0 || v >= plays[i - 1]!)).toBe(true);
    expect(plays[0]).toBeCloseTo(0.25 * 0.15, 2); // volume 50 → 0.25, ramp starts at 0.15
    expect(e.fx.wavActive).toBe(true);
    e.fx.on({ kind: "snoozed", at: e.c.now(), count: 1, plan: e.plan });
    await e.c.advance(WAV_GAP_MS * 4);
    expect(e.log.wav.filter((x) => x.startsWith("play")).length).toBe(5);
    expect(e.fx.wavActive).toBe(false);
    // The next ring: still stale → again (the file is written once); the page comes back → it stops.
    e.fx.on(e.ring(e.c.now(), 2));
    await e.c.advance(WAV_GAP_MS);
    expect(e.log.wav.filter((x) => x.startsWith("write")).length).toBe(1);
    age = 1000;
    e.fx.heartbeat();
    const n = e.log.wav.length;
    await e.c.advance(WAV_GAP_MS * 3);
    expect(e.log.wav.length).toBe(n);
    await e.fx.stop();
    expect(e.log.wav.at(-1)).toBe("remove");
    expect(e.fx.armed).toBe(false);
    // A live page: no WAV, no relaunch.
    const ok = effects();
    ok.fx.on(ok.ring());
    await ok.c.advance(WAV_GAP_MS * 3);
    expect(ok.log.wav).toEqual([]);
    expect(ok.log.relaunch).toBe(0);
    expect(alarmWav("birds").subarray(0, 4).toString()).toBe("RIFF");
    expect(alarmWav("chime").length).toBe(44 + 3 * 24_000 * 2);
  });

  it("Velour: the leader plays the track (ramped from low), pauses on snooze, plays on at the next ring, puts the volume back; members play quiet birds; failure → birds", async () => {
    const plan = alarmPlan(1_700_000_000_000 - 8 * H, 8 * H, { alarmSound: "velour", rampMs: 10_000 });
    const l = effects({ plan, settings: { sound: "velour", velourTrack: "abcDEF12345" }, age: () => STALE_MS + 1 });
    expect(l.fx.gain()).toBe(0); // the song is the alarm here
    l.fx.on(l.ring(l.c.now()));
    await flush();
    expect(l.log.velour.slice(0, 3)).toEqual(['{"op":"state"}', `{"op":"volume","percent":${VELOUR_START}}`, '{"op":"play-target","target":{"kind":"watch","videoId":"abcDEF12345"}}']);
    expect(l.saved).toEqual({ volume: 33 });
    expect(l.log.wav).toEqual([]); // Velour plays: no WAV even with a stale page
    await l.c.advance(12_000);
    const vols = l.log.velour.filter((x) => x.includes('"volume"')).map((x) => (JSON.parse(x) as { percent: number }).percent);
    expect(vols.at(-1)).toBe(50); // the sleep volume setting
    expect(vols.every((v, i) => i === 0 || v >= vols[i - 1]!)).toBe(true);
    l.fx.on({ kind: "snoozed", at: l.c.now(), count: 1, plan: l.plan });
    await flush();
    expect(l.vstate.playing).toBe(false);
    expect(l.saved).toEqual({ volume: 33 }); // kept until the end
    l.next(applyAlarm(plan, "snooze", plan.ringAt! + 1000)!);
    l.fx.on(l.ring(l.c.now(), 2));
    await flush();
    expect(l.vstate.playing).toBe(true);
    expect(l.log.velour.filter((x) => x.includes("play-target")).length).toBe(1); // played on, not restarted
    l.fx.on({ kind: "dismissed", at: l.c.now(), count: 1, plan: l.plan });
    await flush();
    expect(l.vstate).toEqual({ volume: 33, playing: false });
    expect(l.saved).toBeNull();
    await l.fx.stop();
    expect(l.fx.armed).toBe(false);
    // A member: birds at 0.4, never Velour.
    const m = effects({ plan, role: "member", settings: { sound: "velour", velourTrack: "abcDEF12345" } });
    expect(m.fx.gain()).toBe(MEMBER_GAIN);
    m.fx.on(m.ring());
    await flush();
    expect(m.log.velour).toEqual([]);
    // Velour unreachable on the leader: the page's birds at full gain.
    const f = effects({ plan, settings: { sound: "velour", velourTrack: "abcDEF12345" }, velourFails: true });
    f.fx.on(f.ring());
    await flush();
    expect(f.fx.gain()).toBe(1);
    expect(f.log.gain).toBe(1);
    // No track chosen: birds too.
    expect(effects({ plan, settings: { sound: "velour", velourTrack: null } }).fx.gain()).toBe(1);
  });
});

// ---------------------------------------------------------------- routes

async function alarmApp(o: { active?: () => boolean; days?: SleepSettings["alarm"]["days"] } = {}) {
  const runtime = await mkdtemp(join(tmpdir(), "tiphys-sleep-alarm-"));
  const calls: string[] = [];
  const exec = async (cmd: string, args: string[]): Promise<ExecResult> => {
    calls.push(`${cmd} ${args.join(" ")}`);
    const ok = (stdout = "") => ({ stdout, stderr: "", code: 0 });
    if (cmd === "brightnessctl") return args.join(" ") === "-m -c backlight" ? ok("intel_backlight,backlight,48000,50%,96000\n") : ok("");
    if (cmd === "hyprctl") {
      const a = args.join(" ");
      if (a === "eval return 1") return ok("eval is only supported with the lua config manager");
      if (a === "-j activeworkspace") return ok(JSON.stringify({ id: 3, name: "3" }));
      if (a === "-j clients") return ok(JSON.stringify([{ address: "0x5a17", class: "tiphys-screen", workspace: { name: "uyku" } }]));
      return ok("ok");
    }
    if (cmd === "systemctl" && args[1] === "is-active") return ok((o.active?.() ?? true) ? "active\n" : "inactive\n");
    return ok("");
  };
  const tools = ["brightnessctl", "firefox", "systemd-run", "pw-play"];
  const io: DisplayIo = {
    exec, runtimeDir: runtime,
    hyprEnv: async () => ({ XDG_RUNTIME_DIR: runtime, HYPRLAND_INSTANCE_SIGNATURE: "sig" }),
    waylandEnv: async () => ({ WAYLAND_DISPLAY: "wayland-1", XDG_RUNTIME_DIR: runtime }),
    busEnv: () => ({}),
    which: (c) => tools.includes(c),
    connect: () => {
      throw new Error("no sources");
    },
    fetch,
  };
  const t = await testApp(
    (c) => {
      c.screen.modes.sleep.alarm = { ...c.screen.modes.sleep.alarm, enabled: true, days: o.days ?? "weekdays" };
      return c;
    },
    [async (a, ctx) => void (await displayRoutes(a, ctx, { io, displayDir: null, mapDir: runtime, watchMs: 50, power: { dir: join(runtime, "none") }, sleep: { scale: 1, ledsDir: join(runtime, "no-leds"), staleMs: 150 } }))],
  );
  cleanups.push(() => t.app.close());
  await t.app.ready();
  const req = (method: "GET" | "POST", url: string, payload?: object) => t.app.inject({ method, url, headers: t.auth, ...(payload ? { payload } : {}) });
  const sleep = async () => (await req("GET", "/v1/sleep")).json() as Record<string, any>;
  const page = async () => {
    const html = await readFile(join(runtime, "tiphys-screen", "start.html"), "utf8");
    const token = /#t=([a-f0-9]{64})/.exec(html)![1]!;
    const got: Array<Record<string, any>> = [];
    const ws = await t.app.injectWS(`/v1/screen/live?t=${token}`, {}, { onInit: (w) => w.on("message", (d: Buffer) => got.push(JSON.parse(d.toString()) as Record<string, any>)) });
    return { ws, got };
  };
  const events = async () => (await readFile(join(t.dir, "events.jsonl"), "utf8").catch(() => "")).trim().split("\n").filter(Boolean).map((l) => JSON.parse(l) as { key: string; params?: Record<string, string> });
  const pushes = () => (t.sent as Array<{ key: string; params: { state: string }; priority?: string; transient?: boolean; data: Record<string, string> }>).filter((n) => n.key === "sleep.alarm");
  return { ...t, runtime, calls, req, sleep, page, events, pushes };
}

/** A session whose alarm rings `ringIn` ms from now (sunrise just before it; short snooze and morning). */
function soonSession(ringIn: number, o: Partial<SleepPlan> = {}) {
  const t0 = Date.now();
  const plan = alarmPlan(t0, ringIn, { settleMs: 20, fadeMs: 20, soundFadeMs: 20, sunriseAt: t0 + ringIn - 100, rampMs: 200, snoozeMs: 300, autoStopMs: 60_000, morningMs: 300, ...o });
  return { id: `alarm-${t0.toString(36)}`, seed: 9, t0, members: [{ host: "test", side: "left" as const }], leader: "test", plan };
}

describe("alarm routes", () => {
  it("rings on time; the page gets the plan, the kiosk gets the focus; snooze (API) → snoozed → rings again; dismiss (the page's Esc) → morning → the mode ends; one push per transition, events without content", async () => {
    const t = await alarmApp({ days: "once" });
    expect((await t.sleep()).alarm).toMatchObject({ next: expect.any(Number), ringing: false });
    expect((await t.req("POST", "/v1/sleep/alarm", { action: "snooze" })).json()).toMatchObject({ error: { code: "agent.screen.notRunning" } });
    const s = soonSession(400);
    const started = (await t.req("POST", "/v1/sleep/start", { session: s })).json();
    expect(started).toMatchObject({ running: true, session: { id: s.id, plan: { ringAt: s.plan.ringAt } }, alarm: { next: s.plan.ringAt, ringing: false } });
    expect((await t.req("POST", "/v1/sleep/alarm", { action: "snooze" })).json()).toMatchObject({ error: { code: "agent.sleep.notRinging", params: { phase: expect.any(String) } } });
    expect((await t.req("POST", "/v1/sleep/alarm", { action: "wake" })).statusCode).toBe(400);
    const p = await t.page();
    await until(() => p.got.some((x) => x.type === "sleep"));
    expect(p.got.find((x) => x.type === "sleep")).toMatchObject({ plan: { ringAt: s.plan.ringAt, snoozeMs: 300 }, alarm: { gain: 1 } });
    p.ws.send(JSON.stringify({ type: "heartbeat" }));
    // The page connected: the kiosk window is focused (keys reach it).
    await until(() => t.calls.includes("hyprctl dispatch focuswindow address:0x5a17"));
    await until(async () => (await t.sleep()).phase === "ring");
    expect((await t.sleep()).alarm).toMatchObject({ ringing: true, next: s.plan.ringAt });
    expect(t.pushes()).toHaveLength(1);
    expect(t.pushes()[0]).toMatchObject({ params: { state: "ringing", at: s.plan.ringAt, count: 1, snoozeMin: 0 }, priority: "high", transient: true, data: { agent: "test", session: s.id } });
    expect(t.store.get().screen.modes.sleep.alarm.enabled).toBe(false); // once
    const sn = (await t.req("POST", "/v1/sleep/alarm", { action: "snooze" })).json();
    expect(sn).toMatchObject({ phase: "snoozed", alarm: { ringing: false, snoozedUntil: expect.any(Number) } });
    await until(() => p.got.some((x) => x.type === "sleep" && x.plan.snoozes.length === 1));
    await until(async () => (await t.sleep()).phase === "ring");
    expect(t.pushes().map((n) => n.params.state)).toEqual(["ringing", "snoozed", "ringing"]);
    p.ws.send(JSON.stringify({ type: "alarm", action: "dismiss" }));
    await until(async () => (await t.sleep()).phase === "morning");
    await until(async () => !(await t.sleep()).running);
    await until(() => !existsSync(join(t.runtime, "tiphys-screen"))); // the stop finishes after `running` is false
    expect(t.pushes().map((n) => n.params.state)).toEqual(["ringing", "snoozed", "ringing", "dismissed"]);
    await until(async () => (await t.events()).some((e) => e.key === "sleep.stopped"));
    const ev = await t.events();
    expect(ev.map((e) => (e.key === "sleep.alarm" ? `alarm:${e.params!.state}` : e.key))).toEqual(["sleep.started", "alarm:rang", "alarm:rang", "alarm:dismissed", "sleep.stopped"]);
    // No content anywhere: just the state.
    for (const e of ev.filter((x) => x.key === "sleep.alarm")) expect(Object.keys(e.params!)).toEqual(["state"]);
    const snz = t.pushes()[1]!.params as unknown as Record<string, number>;
    expect(snz.snoozedUntil! - snz.at!).toBe(300);
  });

  it("the kiosk died: the mode goes on; at the ring the WAV plays (pw-play from the work dir) and the kiosk is relaunched; dismiss without a morning ends it, nothing left", async () => {
    let active = true;
    const t = await alarmApp({ active: () => active });
    const s = soonSession(600, { morningMs: 0 });
    await t.req("POST", "/v1/sleep/start", { session: s });
    active = false; // Firefox crashed, no page beats
    await new Promise((r) => setTimeout(r, 200));
    expect((await t.sleep()).running).toBe(true); // the unit watch (50 ms) left it running
    await until(async () => (await t.sleep()).phase === "ring");
    const wav = join(t.runtime, "tiphys-screen", "alarm.wav");
    await until(() => t.calls.some((c) => c.startsWith("pw-play ")));
    expect(t.calls.find((c) => c.startsWith("pw-play"))).toMatch(new RegExp(`^pw-play --volume 0\\.\\d+ ${wav.replace(/[.]/g, "\\.")}$`));
    expect(existsSync(wav)).toBe(true);
    expect((await readFile(wav)).subarray(0, 4).toString()).toBe("RIFF");
    expect((await t.sleep()).alarm).toMatchObject({ ringing: true, fallback: true });
    await until(() => t.calls.filter((c) => c.startsWith("systemd-run")).length === 2); // relaunched
    expect(t.calls).toContain("systemctl --user reset-failed tiphys-screen.service");
    expect(existsSync(join(t.runtime, "tiphys-screen", "profile", "user.js"))).toBe(true); // a fresh profile
    expect(t.pushes().map((n) => n.params.state)).toEqual(["ringing"]);
    await t.req("POST", "/v1/sleep/alarm", { action: "dismiss" });
    await until(async () => !(await t.sleep()).running);
    await until(() => !existsSync(join(t.runtime, "tiphys-screen"))); // the stop finishes after `running` is false
    const plays = t.calls.filter((c) => c.startsWith("pw-play")).length;
    await new Promise((r) => setTimeout(r, 300));
    expect(t.calls.filter((c) => c.startsWith("pw-play")).length).toBe(plays); // the loop is over
  });
});
