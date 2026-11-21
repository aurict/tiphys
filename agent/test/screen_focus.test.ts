// Focus timer state machine (PLAN.md §20 W5) with a fake clock: actions, the long-break cadence, catch-up after a
// gap, the saved times (never the task), restore of a paused timer, and invalid saved state.
import { describe, expect, it } from "vitest";
import { applyAction, catchUp, FocusClock, IDLE, nextPhase, parseTimes, type FocusTimes } from "../src/screen/focus_timer.ts";

const D = { focusMin: 25, shortMin: 5, longMin: 15, longEvery: 4 };
const MIN = 60_000;

/** A fake clock with one pending timeout at a time (what FocusClock uses). */
function fakeClock(start = 1_000_000) {
  let now = start;
  let pending: { at: number; fn: () => void } | null = null;
  return {
    now: () => now,
    setTimeout: (fn: () => void, ms: number) => ((pending = { at: now + ms, fn }), pending),
    clearTimeout: (h: unknown) => {
      if (h === pending) pending = null;
    },
    /** Moves the clock, firing the timeout when its time comes. */
    advance(ms: number) {
      const end = now + ms;
      while (pending && pending.at <= end) {
        const p = pending;
        pending = null;
        now = p.at;
        p.fn();
      }
      now = end;
    },
    get pending() {
      return pending;
    },
  };
}

describe("focus timer state machine", () => {
  it("start, pause, resume, skip, reset", () => {
    const t0 = 1000;
    const s = applyAction(IDLE, "start", D, t0)!;
    expect(s).toEqual({ phase: "focus", endsAt: t0 + 25 * MIN, pausedLeft: null, total: 25 * MIN, round: 1 });
    expect(applyAction(s, "start", D, t0 + 5)).toBeNull(); // already focusing
    expect(applyAction(s, "resume", D, t0 + 5)).toBeNull();
    const p = applyAction(s, "pause", D, t0 + 10 * MIN)!;
    expect(p).toMatchObject({ endsAt: null, pausedLeft: 15 * MIN });
    expect(applyAction(p, "pause", D, t0 + 11 * MIN)).toBeNull();
    // A paused focus round: start = resume.
    expect(applyAction(p, "start", D, t0 + 20 * MIN)).toMatchObject({ endsAt: t0 + 35 * MIN, pausedLeft: null });
    const r = applyAction(p, "resume", D, t0 + 30 * MIN)!;
    expect(r).toMatchObject({ phase: "focus", endsAt: t0 + 45 * MIN, pausedLeft: null, round: 1 });
    const brk = applyAction(r, "skip", D, t0 + 31 * MIN)!;
    expect(brk).toMatchObject({ phase: "short", endsAt: t0 + 36 * MIN, total: 5 * MIN, round: 1 });
    // Start in a break: the next round at once; skip a paused break: the next phase runs.
    expect(applyAction(brk, "start", D, t0 + 32 * MIN)).toMatchObject({ phase: "focus", round: 2, endsAt: t0 + 57 * MIN });
    expect(applyAction(applyAction(brk, "pause", D, t0 + 32 * MIN)!, "skip", D, t0 + 33 * MIN)).toMatchObject({ phase: "focus", round: 2, pausedLeft: null });
    expect(applyAction(brk, "reset", D, t0)).toEqual(IDLE);
    expect(applyAction(IDLE, "reset", D, t0)).toBeNull();
    expect(applyAction(IDLE, "skip", D, t0)).toBeNull();
    expect(applyAction(IDLE, "pause", D, t0)).toBeNull();
  });

  it("long break after every longEvery-th round", () => {
    let s: FocusTimes = applyAction(IDLE, "start", D, 0)!;
    const seen: string[] = [];
    for (let i = 0; i < 16; i++) {
      seen.push(`${s.phase}${s.round}`);
      s = nextPhase(s, D, s.endsAt!);
    }
    expect(seen).toEqual(["focus1", "short1", "focus2", "short2", "focus3", "short3", "focus4", "long4", "focus5", "short5", "focus6", "short6", "focus7", "short7", "focus8", "long8"]);
    expect(nextPhase({ phase: "focus", endsAt: 0, pausedLeft: null, total: 1, round: 2 }, { ...D, longEvery: 2 }, 0).phase).toBe("long");
  });

  it("catches up phases that ended while nobody watched", () => {
    const s = applyAction(IDLE, "start", D, 0)!;
    // 25 focus + 5 short + 10 into round 2.
    expect(catchUp(s, D, 40 * MIN)).toMatchObject({ phase: "focus", round: 2, endsAt: 55 * MIN });
    expect(catchUp(s, D, 10 * MIN)).toBe(s);
    const paused = applyAction(s, "pause", D, MIN)!;
    expect(catchUp(paused, D, 999 * MIN)).toBe(paused); // a paused timer doesn't move
  });

  it("saved times are validated", () => {
    expect(parseTimes({ phase: "focus", endsAt: 5, pausedLeft: null, total: 25 * MIN, round: 2 })).toMatchObject({ phase: "focus", round: 2 });
    expect(parseTimes({ phase: "idle", round: 0 })).toEqual(IDLE);
    for (const bad of [null, "x", { phase: "nap", round: 1 }, { phase: "focus", endsAt: 5, pausedLeft: 5, total: MIN, round: 1 },
      { phase: "focus", endsAt: null, pausedLeft: null, total: MIN, round: 1 }, { phase: "short", endsAt: 5, pausedLeft: null, total: 999 * MIN, round: 1 },
      { phase: "short", endsAt: null, pausedLeft: 9 * MIN, total: 5 * MIN, round: 1 }, { phase: "focus", endsAt: 5, pausedLeft: null, total: MIN, round: -1 }]) {
      expect(parseTimes(bad)).toBeNull();
    }
  });
});

describe("FocusClock", () => {
  it("runs on its own: phase ends fire 'timer' changes; the file never holds the task", async () => {
    const c = fakeClock();
    const saved: Array<FocusTimes | null> = [];
    const changes: Array<[string, string | null, string]> = [];
    const clock = new FocusClock({
      durations: () => ({ ...D, longEvery: 2 }),
      save: async (t) => void saved.push(t),
      onChange: (t, cause, from) => changes.push([`${t.phase}${t.round}`, cause, from]),
      now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout,
    });
    expect(clock.armed).toBe(false);
    clock.act(undefined, "  Ekran modları W5  ");
    expect(clock.task).toBe("Ekran modları W5");
    expect(changes).toEqual([["idle0", null, "idle"]]); // task only: a change without a phase change
    clock.act("start", "x".repeat(200));
    expect(clock.task).toHaveLength(80);
    c.advance(25 * MIN);
    c.advance(5 * MIN);
    c.advance(25 * MIN); // round 2 ends: long break (every 2nd)
    expect(changes.slice(1)).toEqual([["focus1", "action", "idle"], ["short1", "timer", "focus"], ["focus2", "timer", "short"], ["long2", "timer", "focus"]]);
    expect(clock.times).toMatchObject({ phase: "long", endsAt: c.now() + 15 * MIN });
    expect(JSON.stringify(saved)).not.toMatch(/Ekran|xxxx|task/);
    clock.act("reset");
    expect(saved.at(-1)).toBeNull(); // idle: the file is removed
    expect(clock.armed).toBe(false);
    clock.act("start");
    expect(clock.armed).toBe(true);
    clock.stop();
    expect(clock.armed).toBe(false);
    expect(clock.task).toBeNull();
    expect(clock.act("start").phase).toBe("focus"); // stopped: no change
  });

  it("a paused timer restored after a restart keeps its time left; a running one catches up", () => {
    const c = fakeClock(10 * MIN);
    const o = { durations: () => D, save: async () => {}, onChange: () => {}, now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout };
    const paused = new FocusClock(o, { phase: "focus", endsAt: null, pausedLeft: 7 * MIN, total: 25 * MIN, round: 3 });
    expect(paused.times).toMatchObject({ phase: "focus", pausedLeft: 7 * MIN, round: 3 });
    expect(paused.armed).toBe(false);
    paused.act("resume");
    expect(paused.times.endsAt).toBe(17 * MIN);
    paused.stop();
    // Ended 1 min ago (round 4 → long break with longEvery 4) while the agent was down.
    const running = new FocusClock(o, { phase: "focus", endsAt: 9 * MIN, pausedLeft: null, total: 25 * MIN, round: 4 });
    expect(running.times).toMatchObject({ phase: "long", endsAt: 24 * MIN, round: 4 });
    expect(running.armed).toBe(true);
    running.stop();
  });
});
