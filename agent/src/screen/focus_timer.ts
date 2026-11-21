// Focus mode timer (PLAN.md §20 A-3): idle → focus → short/long break → focus … on the display agent. Time-based, not
// tick-based: a running phase is its `endsAt` (ms), a paused one its `pausedLeft` (ms); one timeout waits for the
// next end. The state without the task goes to a file in the mode's tmpfs work dir (removed with the mode), so an
// agent restart continues where it was; phases that ended meanwhile are caught up from the saved times. The task
// line (≤ 80 chars) is memory only: never written to the file, the event log or the log.

export const FOCUS_PHASES = ["idle", "focus", "short", "long"] as const;
export type FocusPhase = (typeof FOCUS_PHASES)[number];
export const FOCUS_ACTIONS = ["start", "pause", "resume", "skip", "reset"] as const;
export type FocusAction = (typeof FOCUS_ACTIONS)[number];
export const TASK_MAX = 80;

export interface FocusDurations {
  focusMin: number;
  shortMin: number;
  longMin: number;
  longEvery: number;
}

/** The timer without the task (what the state file holds). */
export interface FocusTimes {
  phase: FocusPhase;
  /** Running phase: when it ends (ms since the epoch). */
  endsAt: number | null;
  /** Paused phase: what is left (ms). */
  pausedLeft: number | null;
  /** Length of the current phase (ms), for the ring. */
  total: number | null;
  /** The current focus round (during a break: the one just finished); 0 = idle. */
  round: number;
}

export const IDLE: FocusTimes = { phase: "idle", endsAt: null, pausedLeft: null, total: null, round: 0 };
const MIN = 60_000;

/** The phase after `t` ends (or is skipped), starting at `at`. */
export function nextPhase(t: FocusTimes, d: FocusDurations, at: number): FocusTimes {
  if (t.phase === "focus") {
    const phase = t.round % d.longEvery === 0 ? "long" : "short";
    const total = (phase === "long" ? d.longMin : d.shortMin) * MIN;
    return { phase, endsAt: at + total, pausedLeft: null, total, round: t.round };
  }
  const total = d.focusMin * MIN;
  return { phase: "focus", endsAt: at + total, pausedLeft: null, total, round: t.round + 1 };
}

/** Phases that ended by `now` are followed (each next phase starts at the previous end). */
export function catchUp(t: FocusTimes, d: FocusDurations, now: number): FocusTimes {
  let s = t;
  for (let i = 0; s.endsAt !== null && s.endsAt <= now && i < 10_000; i++) s = nextPhase(s, d, s.endsAt);
  return s;
}

/** An action → the new times; null when it changes nothing (e.g. pause while paused). */
export function applyAction(t: FocusTimes, action: FocusAction, d: FocusDurations, now: number): FocusTimes | null {
  switch (action) {
    case "start":
      // From idle: round 1. In a break: the next focus round now. A focus round already running: nothing.
      if (t.phase === "focus") return t.pausedLeft !== null ? applyAction(t, "resume", d, now) : null;
      return nextPhase(t.phase === "idle" ? { ...IDLE, phase: "short" } : t, d, now);
    case "pause":
      if (t.endsAt === null) return null;
      return { ...t, endsAt: null, pausedLeft: Math.max(0, t.endsAt - now) };
    case "resume":
      if (t.pausedLeft === null) return null;
      return { ...t, endsAt: now + t.pausedLeft, pausedLeft: null };
    case "skip":
      return t.phase === "idle" ? null : nextPhase(t, d, now);
    case "reset":
      return t.phase === "idle" ? null : { ...IDLE };
  }
}

/** A state file's content → valid times, or null. */
export function parseTimes(v: unknown): FocusTimes | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const num = (x: unknown) => (typeof x === "number" && Number.isFinite(x) && x >= 0 ? x : null);
  if (!FOCUS_PHASES.includes(o.phase as FocusPhase)) return null;
  const phase = o.phase as FocusPhase;
  const round = typeof o.round === "number" && Number.isInteger(o.round) && o.round >= 0 && o.round < 1e6 ? o.round : null;
  if (round === null) return null;
  if (phase === "idle") return { ...IDLE };
  const endsAt = num(o.endsAt), pausedLeft = num(o.pausedLeft), total = num(o.total);
  if ((endsAt === null) === (pausedLeft === null) || total === null || total > 120 * MIN || (pausedLeft ?? 0) > total) return null;
  return { phase, endsAt, pausedLeft, total, round: Math.max(1, round) };
}

export interface FocusClockOpts {
  durations: () => FocusDurations;
  /** Saves the times (null: remove the file). Errors are the caller's to log. */
  save: (t: FocusTimes | null) => Promise<void>;
  /** Every change; `cause` is set when the phase changed ("timer": it ended by itself). */
  onChange: (t: FocusTimes, cause: "timer" | "action" | null, from: FocusPhase) => void;
  now?: () => number;
  setTimeout?: (fn: () => void, ms: number) => unknown;
  clearTimeout?: (h: unknown) => void;
}

/** The running timer of one Focus mode run. */
export class FocusClock {
  readonly #o: FocusClockOpts;
  readonly #now: () => number;
  #t: FocusTimes = { ...IDLE };
  #task: string | null = null;
  #timer: unknown = null;
  #stopped = false;

  constructor(o: FocusClockOpts, restored: FocusTimes | null = null) {
    this.#o = o;
    this.#now = o.now ?? Date.now;
    if (restored) {
      this.#t = catchUp(restored, o.durations(), this.#now());
      void this.#save();
      this.#arm();
    }
  }

  get times(): FocusTimes {
    return this.#t;
  }

  get task(): string | null {
    return this.#task;
  }

  /** Any timeout pending (tests: leak check). */
  get armed(): boolean {
    return this.#timer !== null;
  }

  /** `task`: undefined = unchanged, "" or null = cleared. Returns the new state. */
  act(action: FocusAction | undefined, task?: string | null) {
    if (this.#stopped) return this.#t;
    let changed = false;
    if (task !== undefined) {
      const v = task === null ? null : task.trim().slice(0, TASK_MAX) || null;
      changed = v !== this.#task;
      this.#task = v;
    }
    const from = this.#t.phase;
    const next = action ? applyAction(this.#t, action, this.#o.durations(), this.#now()) : null;
    if (next) {
      this.#t = next;
      void this.#save();
      this.#arm();
    }
    if (next || changed) this.#o.onChange(this.#t, next && next.phase !== from ? "action" : null, from);
    return this.#t;
  }

  /** Mode left: no timeout, nothing saved any more (the work dir goes with the mode). */
  stop() {
    this.#stopped = true;
    if (this.#timer !== null) (this.#o.clearTimeout ?? clearTimeout)(this.#timer as NodeJS.Timeout);
    this.#timer = null;
    this.#task = null;
  }

  #save() {
    return this.#o.save(this.#t.phase === "idle" ? null : this.#t);
  }

  #arm() {
    if (this.#timer !== null) (this.#o.clearTimeout ?? clearTimeout)(this.#timer as NodeJS.Timeout);
    this.#timer = null;
    if (this.#stopped || this.#t.endsAt === null) return;
    // Timeouts are capped at ~24.8 days; a phase is ≤ 120 min. A late wakeup (suspend) catches up.
    const ms = Math.max(0, this.#t.endsAt - this.#now());
    const h = (this.#o.setTimeout ?? setTimeout)(() => {
      this.#timer = null;
      if (this.#stopped) return;
      const from = this.#t.phase;
      this.#t = catchUp(this.#t, this.#o.durations(), Math.max(this.#now(), this.#t.endsAt ?? 0));
      void this.#save();
      this.#arm();
      this.#o.onChange(this.#t, "timer", from);
    }, ms);
    (h as NodeJS.Timeout)?.unref?.();
    this.#timer = h;
  }
}
