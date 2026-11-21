// Sleep mode on one display host (PLAN.md §21 A-2, A-3, A-4, A-10; S2, S4): the phase machine, the alarm's phases
// and the brightness curve.
// Phases follow from the plan (the session's start `t0`, the times and the alarm), not from ticks: settle → fade →
// night → sunrise (alarm − sunriseMin) → ring → (snoozed → ring)* → morning (after a dismiss, if morningScreen) → end.
// The plan is the group's: the leader computes it from its settings at start and it travels with the session
// (`session.plan`, and the leader's `hello`), so every member computes the same sunrise/ring/snooze times. User events
// (snooze, dismiss) are timestamps in the plan (`snoozes`, `dismissedAt`); applying the same event twice changes
// nothing, and the past never changes. The alarm's sound stops `autoStopMs` after each ring start (the screens stay
// bright, the phase stays `ring`). sleep_alarm.ts holds the next-alarm computation and the alarm's side effects.
// Brightness: a target level L(t) in percent of full brightness — `start` in settle, eased out to `night` over the
// fade, eased in from `night` to `morning` during sunrise, `morning` from the ring on. Two layers: the hardware
// (backlight via brightnessctl, at most one call per 2 s; DDC/CI via ddcutil, at most one step per 15 s, only on a
// change) never below its floor, and the page's content multiplier L / hardware (0..1), which fills between hardware
// steps and does the darkest part of the night. Without hardware dimming (no backlight, DDC unavailable) the page dims
// alone and the status carries the warning `agent.sleep.ddcUnavailable`. The page gets `sleep` (everything; again on
// a plan change), `phase` and `brightness` messages; it sends `heartbeat` every 10 s (the WAV fallback listens).
// Trace-free: the state file (sleep.json in the screen mode's tmpfs work dir, 0600, written whole before every side
// effect) holds the session, the plan and every previous hardware value; stop restores them and removes it, and after
// a crash the next agent either adopts the run (kiosk still up) or restores from it.
// Test-only time scale (`scale`, from TIPHYS_SLEEP_SCALE; unset = 1): every phase length is divided by it (the alarm's
// clock time itself is not). The hardware rate limits are not scaled.
import { z } from "zod";
import { hostId, sleepSettingsSchema, type SleepSettings } from "../config.ts";
import { AppError } from "../errors.ts";
import { Hardware, NO_SAVED, sanitizeSaved, Throttle, type HwKind, type HwSaved } from "./sleep_hw.ts";
import { nextAlarm } from "./sleep_alarm.ts";
import { parseVelourHeld, type VelourHeld } from "./sleep_velour.ts";

export const SLEEP_PHASES = ["settle", "fade", "night", "sunrise", "ring", "snoozed", "morning"] as const;
export type SleepPhase = (typeof SLEEP_PHASES)[number];

export const SIDES = ["left", "right", "foot", "head"] as const;
export const DISTANCES = ["near", "mid", "far"] as const;

/** A group member and its place in the room (the phone sends the same list to every member: one shared layout). */
export interface SleepMember {
  host: string;
  side: (typeof SIDES)[number];
  distance: (typeof DISTANCES)[number];
}

export interface SleepSession {
  id: string;
  seed: number;
  t0: number;
  members: SleepMember[];
  leader: string;
  /** The group's plan (S4): sent by the phone (copied from the leader's start response); none = computed here. */
  plan?: SleepPlan;
}

/** The timeline of a run (ms since the epoch / ms); the page's timeline.js takes the same shape. */
export interface SleepPlan {
  t0: number;
  settleMs: number;
  fadeMs: number;
  soundFadeMs: number;
  nightSound: "hum" | "off";
  /** Alarm (S4): when sunrise starts and the alarm rings; null = no alarm. */
  sunriseAt: number | null;
  ringAt: number | null;
  rampMs: number;
  alarmSound: "birds" | "chime" | "velour";
  /** A snooze's length, how long a ring sounds before it goes quiet by itself, the morning screen's length (0 = none). */
  snoozeMs: number;
  autoStopMs: number;
  morningMs: number;
  /** User events (shared clock, ms): each snooze's time (sorted), the dismiss. */
  snoozes: number[];
  dismissedAt: number | null;
}

const MIN = 60_000;
/** Hardware rate limits (PLAN.md §21 A-3). */
export const BACKLIGHT_GAP_MS = 2000;
export const DDC_GAP_MS = 15_000;
/** The backlight's floor (percent): 0 switches some panels off; the content does the rest. */
export const BACKLIGHT_MIN = 1;
/** How often the curve is followed while it moves (fade, sunrise); nothing runs in flat phases. */
export const TICK_MS = 2000;
export const PREVIEW_MS = 5000;
export const DDC_UNAVAILABLE = "agent.sleep.ddcUnavailable";

export const MORNING_MIN = 10;

/**
 * The plan of a run started at `t0` with the settings' times and alarm, lengths divided by `scale`. The alarm rings at
 * the next `alarm.time` on an allowed day after `t0` in this machine's local time (sleep_alarm.ts nextAlarm).
 */
export function planOf(t0: number, s: SleepSettings, scale = 1): SleepPlan {
  const ms = (min: number) => Math.round((min * MIN) / scale);
  const ringAt = s.alarm.enabled ? nextAlarm(s.alarm, t0) : null;
  return {
    t0,
    settleMs: ms(s.times.settleMin),
    fadeMs: ms(s.times.fadeMin),
    soundFadeMs: ms(s.times.soundFadeMin),
    nightSound: s.times.nightSound,
    sunriseAt: ringAt === null ? null : ringAt - ms(s.alarm.sunriseMin),
    ringAt,
    rampMs: ms(s.alarm.rampMin),
    alarmSound: s.alarm.sound,
    snoozeMs: ms(s.alarm.snoozeMin),
    autoStopMs: ms(s.alarm.autoStopMin),
    morningMs: s.alarm.morningScreen ? ms(MORNING_MIN) : 0,
    snoozes: [],
    dismissedAt: null,
  };
}

export interface PhaseSpan {
  phase: SleepPhase;
  startedAt: number;
  endsAt: number | null;
}

/**
 * The phase spans of a plan in order (zero-length ones dropped). Without an alarm: settle, fade, night (open-ended).
 * With one, everything before the ring is cut at `ringAt` (a short night shortens sunrise first, then the fade), each
 * snooze turns a ring into `snoozed` for `snoozeMs`, and a dismiss ends the list (+ `morning` for `morningMs`).
 * display/sleep/timeline.js phasesOf is the same function for the page.
 */
export function phasesOf(p: SleepPlan): PhaseSpan[] {
  const settleEnd = p.t0 + p.settleMs, fadeEnd = settleEnd + p.fadeMs;
  let out: PhaseSpan[];
  if (p.ringAt === null) out = [{ phase: "settle", startedAt: p.t0, endsAt: settleEnd }, { phase: "fade", startedAt: settleEnd, endsAt: fadeEnd }, { phase: "night", startedAt: fadeEnd, endsAt: null }];
  else {
    const R = Math.max(p.ringAt, p.t0);
    const cut = (x: number) => Math.min(x, R);
    const sun = Math.min(R, Math.max(fadeEnd, p.sunriseAt ?? R));
    out = [
      { phase: "settle", startedAt: p.t0, endsAt: cut(settleEnd) },
      { phase: "fade", startedAt: cut(settleEnd), endsAt: cut(fadeEnd) },
      { phase: "night", startedAt: cut(fadeEnd), endsAt: sun },
      { phase: "sunrise", startedAt: sun, endsAt: R },
    ];
    let cur = R;
    for (const s of p.snoozes) {
      if (s < cur) continue; // not inside a ring (refused when applied; a hand-made plan may have it)
      out.push({ phase: "ring", startedAt: cur, endsAt: s }, { phase: "snoozed", startedAt: s, endsAt: s + p.snoozeMs });
      cur = s + p.snoozeMs;
    }
    out.push({ phase: "ring", startedAt: cur, endsAt: null });
  }
  const D = p.dismissedAt;
  if (D !== null && p.ringAt !== null) {
    out = out.filter((x) => x.startedAt < D).map((x) => (x.endsAt === null || x.endsAt > D ? { ...x, endsAt: D } : x));
    if (p.morningMs > 0) out.push({ phase: "morning", startedAt: D, endsAt: D + p.morningMs });
  }
  return out.filter((x) => x.endsAt === null || x.endsAt > x.startedAt);
}

/** When the run ends by itself (the morning is over, or the dismiss without a morning screen); null = never. */
export function endOf(p: SleepPlan): number | null {
  return p.dismissedAt === null || p.ringAt === null ? null : p.dismissedAt + p.morningMs;
}

/** Does the alarm sound at `t` (a ring span, before its auto-stop)? */
export function soundingAt(p: SleepPlan, t: number): boolean {
  const s = phaseAt(p, t);
  return s.phase === "ring" && t < s.startedAt + p.autoStopMs && (endOf(p) === null || t < endOf(p)!);
}

/** The run's alarm at `t` for GET /v1/sleep: the next (or current) ring start, ringing, until when snoozed. */
export function alarmAt(p: SleepPlan, t: number) {
  const s = phaseAt(p, t);
  const done = endOf(p) !== null && t >= p.dismissedAt!;
  const next = p.ringAt === null || done ? null : s.phase === "ring" ? s.startedAt : s.phase === "snoozed" ? s.endsAt : t < p.ringAt ? p.ringAt : null;
  return {
    next,
    sunriseAt: p.ringAt === null || done ? null : phasesOf(p).find((x) => x.phase === "sunrise")?.startedAt ?? p.ringAt,
    ringing: !done && soundingAt(p, t),
    silenced: !done && s.phase === "ring" && t >= s.startedAt + p.autoStopMs,
    snoozedUntil: !done && s.phase === "snoozed" ? s.endsAt : null,
    snoozes: p.snoozes.length,
    dismissedAt: p.dismissedAt,
  };
}

export type AlarmAction = "snooze" | "dismiss";

/**
 * A user's snooze or dismiss at `at` → the new plan, or null when it doesn't apply: snooze only while it rings (also
 * after the auto-stop), dismiss during sunrise, ring or snooze; the same event twice (within a second) is null too.
 */
export function applyAlarm(p: SleepPlan, action: AlarmAction, at: number): SleepPlan | null {
  if (p.ringAt === null || p.dismissedAt !== null) return null;
  const s = phaseAt(p, at);
  if (action === "snooze") {
    if (s.phase !== "ring" || p.snoozes.some((x) => Math.abs(x - at) < 1000)) return null;
    return { ...p, snoozes: [...p.snoozes, at].sort((a, b) => a - b) };
  }
  if (s.phase !== "sunrise" && s.phase !== "ring" && s.phase !== "snoozed") return null;
  return { ...p, dismissedAt: at };
}

/**
 * Two members' plans after a missed message (the leader's hello): the leader's base with both sides' events replayed
 * in time order (each one checked as it was when made).
 */
export function mergePlans(mine: SleepPlan, leader: SleepPlan): SleepPlan {
  let p: SleepPlan = { ...leader, snoozes: [], dismissedAt: null };
  const evs: Array<[number, AlarmAction]> = [...new Set([...mine.snoozes, ...leader.snoozes])].map((t) => [t, "snooze"]);
  for (const d of [mine.dismissedAt, leader.dismissedAt]) if (d !== null) evs.push([d, "dismiss"]);
  for (const [t, a] of evs.sort((x, y) => x[0] - y[0])) p = applyAlarm(p, a, t) ?? p;
  return p;
}

/** The phase at `t` (before t0: settle, starting at t0). */
export function phaseAt(p: SleepPlan, t: number): PhaseSpan {
  const list = phasesOf(p);
  return list.find((x) => x.endsAt === null || t < x.endsAt) ?? list[list.length - 1]!;
}

const clamp01 = (x: number) => Math.min(1, Math.max(0, x));
export const easeOut = (k: number) => 1 - (1 - k) * (1 - k);
export const easeIn = (k: number) => k * k;

/** Target brightness (percent of full, may be fractional) at `t`. */
export function levelAt(p: SleepPlan, b: SleepSettings["brightness"], t: number): number {
  const s = phaseAt(p, t);
  switch (s.phase) {
    case "settle":
      return b.start;
    case "fade": // over the planned fade (an early alarm cuts the span, not the curve)
      return b.start + (Math.min(b.night, b.start) - b.start) * easeOut(clamp01((t - p.t0 - p.settleMs) / Math.max(1, p.fadeMs)));
    case "night":
      return Math.min(b.night, b.start);
    case "sunrise": // toward the alarm (a dismiss during sunrise cuts the span, not the curve)
      return Math.min(b.night, b.start) + (b.morning - Math.min(b.night, b.start)) * easeIn(clamp01((t - s.startedAt) / Math.max(1, Math.max(p.ringAt ?? t, p.t0) - s.startedAt)));
    default: // ring, snoozed, morning
      return b.morning;
  }
}

/** The hardware step for level `l`: never below the floor, rounded up so the content multiplier stays ≤ 1. */
export function hardwareFor(l: number, floor: number): number {
  return Math.min(100, Math.max(floor, Math.ceil(l - 1e-9)));
}

/** The page's multiplier with the hardware at `hw` percent (null: no hardware dimming, the screen as it is). */
export function contentFor(l: number, hw: number | null): number {
  const base = hw ?? 100;
  if (base <= 0) return l > 0 ? 1 : 0;
  return Math.round(clamp01(l / base) * 1000) / 1000;
}

// ---- state file ----

export interface SleepFile {
  v: 1;
  session: SleepSession;
  /** This host's id in the session. */
  me: string;
  plan: SleepPlan;
  scale: number;
  /** Which hardware dims (null: content only); `ddc` with `saved.ddc` set. */
  hw: HwKind | null;
  saved: HwSaved;
  /** The last alarm transition handled ("ring:<span start>", …): an adopting agent doesn't push it again. */
  reported: string | null;
  /** Velour's volume before the mode took it, who holds it, who started playback (the leader; sleep_velour.ts). */
  velour: VelourHeld | null;
}

const SESSION_ID = /^[A-Za-z0-9_-]{8,64}$/;
const HOST = /^[A-Za-z0-9_.-]{1,64}$/;

const DAY = 24 * 60 * MIN;
const ms = (x: unknown): x is number => typeof x === "number" && Number.isSafeInteger(x) && x >= 0;
const len = (x: unknown, def: number) => (x === undefined ? def : ms(x) && x <= DAY ? x : NaN);

/**
 * A plan from outside (the session, the leader's hello, the state file) → a valid plan, or null. Fields S4 added may
 * be missing (an S3 file or phone): no snooze/auto-stop/morning lengths given → the defaults (9, 20, 0 min).
 */
export function parsePlan(v: unknown): SleepPlan | null {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const p = v as Record<string, unknown>;
  const lens = [len(p.settleMs, NaN), len(p.fadeMs, NaN), len(p.soundFadeMs, NaN), len(p.rampMs, NaN), len(p.snoozeMs, 9 * MIN), len(p.autoStopMs, 20 * MIN), len(p.morningMs, 0)];
  if (!ms(p.t0) || lens.some((x) => Number.isNaN(x))) return null;
  const at = (x: unknown) => (x === null || x === undefined ? null : ms(x) ? x : NaN);
  const sunriseAt = at(p.sunriseAt), ringAt = at(p.ringAt), dismissedAt = at(p.dismissedAt);
  if ([sunriseAt, ringAt, dismissedAt].some((x) => Number.isNaN(x))) return null;
  if (ringAt !== null && (ringAt < p.t0 || ringAt - p.t0 > 2 * DAY || (sunriseAt !== null && (sunriseAt > ringAt || ringAt - sunriseAt > DAY)))) return null;
  const snoozes = p.snoozes === undefined ? [] : Array.isArray(p.snoozes) && p.snoozes.length <= 50 && p.snoozes.every(ms) ? [...(p.snoozes as number[])].sort((a, b) => a - b) : null;
  if (!snoozes) return null;
  const [settleMs, fadeMs, soundFadeMs, rampMs, snoozeMs, autoStopMs, morningMs] = lens as number[];
  return {
    t0: p.t0, settleMs: settleMs!, fadeMs: fadeMs!, soundFadeMs: soundFadeMs!, nightSound: p.nightSound === "off" ? "off" : "hum",
    sunriseAt: ringAt === null ? null : sunriseAt, ringAt, rampMs: rampMs!, alarmSound: p.alarmSound === "chime" || p.alarmSound === "velour" ? p.alarmSound : "birds",
    snoozeMs: snoozeMs!, autoStopMs: autoStopMs!, morningMs: morningMs!, snoozes: ringAt === null ? [] : snoozes, dismissedAt: ringAt === null ? null : dismissedAt,
  };
}

/** A state file's content → a valid file, or null (the run can't be adopted; its hardware is still restored). */
export function parseSleepFile(v: unknown): SleepFile | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const s = o.session as Record<string, unknown> | undefined;
  if (!s || typeof s.id !== "string" || !SESSION_ID.test(s.id) || !ms(s.seed) || !ms(s.t0)) return null;
  const members = Array.isArray(s.members) ? membersOf(s.members.filter((m) => (typeof m === "string" ? HOST.test(m) : !!m && typeof m === "object" && HOST.test(String((m as Record<string, unknown>).host)))).slice(0, 4)) : [];
  if (!members.length || typeof s.leader !== "string" || !members.some((m) => m.host === s.leader) || typeof o.me !== "string" || !HOST.test(o.me)) return null;
  const plan = parsePlan(o.plan);
  if (!plan) return null;
  const scale = typeof o.scale === "number" && o.scale >= 1 && o.scale <= 1000 ? o.scale : 1;
  return {
    v: 1,
    session: { id: s.id, seed: s.seed as number, t0: s.t0 as number, members, leader: s.leader },
    me: o.me,
    plan,
    scale,
    hw: o.hw === "backlight" || o.hw === "ddc" ? o.hw : null,
    saved: sanitizeSaved(o.saved),
    reported: typeof o.reported === "string" && /^[a-z]{1,10}:\d{1,16}$/.test(o.reported) ? o.reported : null,
    velour: parseVelourHeld(o.velour),
  };
}

/**
 * Finds the dimming hardware and reads its current value: the backlight, else DDC/CI (bus from the settings, or
 * detected once and handed to `storeBus`). `keep` gets the previous value BEFORE anything is changed. null = no
 * hardware dimming here (no backlight and no working DDC).
 */
export async function probeHardware(
  hw: Hardware,
  s: SleepSettings,
  keep: (saved: Partial<HwSaved>, kind: HwKind) => Promise<void>,
  storeBus: ((bus: number) => Promise<void>) | undefined,
  log: (msg: string, err?: unknown) => void,
): Promise<{ kind: HwKind; pct: number; max: number } | null> {
  const bl = await hw.backlight();
  if (bl) {
    await keep({ backlight: { device: bl.device, raw: bl.raw } }, "backlight");
    return { kind: "backlight", pct: Math.round((bl.raw * 100) / bl.max), max: bl.max };
  }
  if (!hw.hasDdcutil) return null;
  let bus = s.ddc.bus;
  if (bus === null) {
    bus = await hw.detectBus();
    if (bus !== null) await storeBus?.(bus).catch((e) => log("DDC veri yolu ayara yazılamadı", e));
  }
  const v = bus === null ? null : await hw.getVcp(bus);
  if (bus === null || !v) return null;
  await keep({ ddc: { bus, raw: v.raw, max: v.max } }, "ddc");
  return { kind: "ddc", pct: Math.round((v.raw * 100) / v.max), max: v.max };
}

export interface PreviewDeps {
  hw: Hardware;
  settings: () => SleepSettings;
  /** The preview's previous values (a tmpfs file; null: remove it). */
  save: (saved: HwSaved | null) => Promise<void>;
  storeBus?: (bus: number) => Promise<void>;
  log: (msg: string, err?: unknown) => void;
  now?: () => number;
  setTimeout?: (fn: () => void, ms: number) => unknown;
  clearTimeout?: (h: unknown) => void;
}

/**
 * POST /v1/sleep/preview while the sleep mode isn't running: the hardware alone at `pct` for 5 s (each call extends
 * it), then the previous value back. Rate limits as in the mode. No hardware → 409 agent.sleep.ddcUnavailable.
 */
export class HardwarePreview {
  readonly #d: PreviewDeps;
  #saved: HwSaved | null = null;
  #throttle: Throttle | null = null;
  #timer: unknown = null;
  #chain: Promise<unknown> = Promise.resolve();

  constructor(d: PreviewDeps) {
    this.#d = d;
  }

  get active() {
    return this.#saved !== null;
  }

  show(pct: number): Promise<{ dimming: HwKind; until: number }> {
    const p = this.#chain.then(() => this.#show(pct));
    this.#chain = p.catch(() => {});
    return p;
  }

  async #show(pct: number) {
    const now = this.#d.now ?? Date.now;
    const setT = this.#d.setTimeout ?? ((fn, ms) => setTimeout(fn, ms));
    const clearT = this.#d.clearTimeout ?? ((h) => clearTimeout(h as NodeJS.Timeout));
    if (!this.#saved) {
      const saved: HwSaved = { ...NO_SAVED, leds: [] };
      const found = await probeHardware(this.#d.hw, this.#d.settings(), async (part) => {
        Object.assign(saved, part);
        this.#saved = saved;
        await this.#d.save(saved);
      }, this.#d.storeBus, this.#d.log);
      if (!found) throw new AppError(DDC_UNAVAILABLE, 409, { reason: this.#d.hw.hasDdcutil ? "failed" : "missing" });
      const ddc = saved.ddc;
      const device = saved.backlight?.device ?? "";
      this.#throttle = new Throttle(
        {
          gapMs: ddc ? DDC_GAP_MS : BACKLIGHT_GAP_MS,
          apply: (v) => (ddc ? this.#d.hw.setVcp(ddc.bus, Math.round((v * ddc.max) / 100)) : this.#d.hw.setBacklight(device, v)),
          onFail: () => this.#d.log("önizleme parlaklığı ayarlanamadı"),
          now, setTimeout: setT, clearTimeout: clearT,
        },
        found.pct,
      );
    }
    const kind: HwKind = this.#saved!.ddc ? "ddc" : "backlight";
    this.#throttle!.want(hardwareFor(pct, kind === "ddc" ? this.#d.settings().ddc.min : BACKLIGHT_MIN));
    if (this.#timer !== null) clearT(this.#timer);
    this.#timer = setT(() => {
      this.#timer = null;
      void this.end();
    }, PREVIEW_MS);
    (this.#timer as NodeJS.Timeout)?.unref?.();
    return { dimming: kind, until: now() + PREVIEW_MS };
  }

  /** Back to the previous value (time's up, the sleep mode starts, or the agent stops). */
  end(): Promise<void> {
    const p = this.#chain.then(async () => {
      if (this.#timer !== null) (this.#d.clearTimeout ?? ((h) => clearTimeout(h as NodeJS.Timeout)))(this.#timer);
      this.#timer = null;
      const saved = this.#saved;
      if (!saved) return;
      this.#throttle?.stop();
      await this.#throttle?.settled();
      this.#throttle = null;
      await this.#d.hw.restore(saved);
      this.#saved = null;
      await this.#d.save(null);
    });
    this.#chain = p.catch((e) => this.#d.log("önizleme geri alınamadı", e));
    return this.#chain as Promise<void>;
  }
}

// ---- the run ----

export interface SleepDeps {
  hw: Hardware;
  settings: () => SleepSettings;
  /** Writes the state file whole (before each side effect). */
  save: (f: SleepFile) => Promise<void>;
  /** A message to the kiosk page(s). */
  send: (msg: string) => void;
  /** A DDC bus found by `ddcutil detect` (stored in the config: a setting, not a trace). */
  storeBus?: (bus: number) => Promise<void>;
  log: (msg: string, err?: unknown) => void;
  /** Test only (TIPHYS_SLEEP_SYNCLOG): the page reports its crackle timings. */
  syncLog?: boolean;
  /** An alarm transition (sleep_alarm.ts AlarmEffects): once per transition, also across an adopting agent. */
  onAlarm?: (t: AlarmTransition) => void;
  /** The plan's end (the morning is over / dismissed without a morning screen): the mode stops. */
  onEnd?: () => void;
  /** The page's alarm gain (0..1; 0 = another player plays it, e.g. Velour on the leader). */
  alarmGain?: () => number;
  /** More fields of the page's `sleep` message (S5: `music` = the pages duck, `morning` = the summary). */
  extra?: () => Record<string, unknown>;
  now?: () => number;
  setTimeout?: (fn: () => void, ms: number) => unknown;
  clearTimeout?: (h: unknown) => void;
}

export interface AlarmTransition {
  kind: "sunrise" | "ring" | "silenced" | "snoozed" | "dismissed";
  /** When it began (span start, or the dismiss). */
  at: number;
  /** Rings so far in this run including this one (ring), snoozes so far (snoozed). */
  count: number;
  plan: SleepPlan;
}

export class SleepRun {
  readonly #d: SleepDeps;
  readonly #now: () => number;
  readonly #setT: (fn: () => void, ms: number) => unknown;
  readonly #clearT: (h: unknown) => void;
  readonly file: SleepFile;
  #phase: PhaseSpan | null = null;
  #phaseTimer: unknown = null;
  #tickTimer: unknown = null;
  #previewTimer: unknown = null;
  #preview: number | null = null;
  #throttle: Throttle | null = null;
  #content = -1;
  #warning: string | null = null;
  #heartbeatAt: number | null = null;
  #offset = 0;
  #stopped = false;
  #ended = false;
  readonly #createdAt: number;
  #saving: Promise<unknown> = Promise.resolve();

  private constructor(d: SleepDeps, file: SleepFile) {
    this.#d = d;
    this.#now = d.now ?? Date.now;
    this.#setT = d.setTimeout ?? ((fn, ms) => setTimeout(fn, ms));
    this.#clearT = d.clearTimeout ?? ((h) => clearTimeout(h as NodeJS.Timeout));
    this.file = file;
    this.#createdAt = this.#now();
  }

  /** A new run: reads and saves every previous hardware value, applies the extras, then follows the curve. */
  static async begin(d: SleepDeps, session: SleepSession, me: string, scale: number): Promise<SleepRun> {
    const s = d.settings();
    const { plan, ...bare } = session;
    const run = new SleepRun(d, { v: 1, session: bare, me, plan: plan ?? planOf(session.t0, s, scale), scale, hw: null, saved: { ...NO_SAVED, leds: [] }, reported: null, velour: null });
    await run.#save();
    await run.#takeHardware(s);
    await run.#extras(s);
    run.#start(null);
    return run;
  }

  /** The previous agent's run (restart or crash with the kiosk still up): its saved values stay as they are. */
  static adopt(d: SleepDeps, file: SleepFile): SleepRun {
    const run = new SleepRun(d, file);
    run.#start(null);
    return run;
  }

  /** Writes the state file now (a field changed outside, e.g. Velour's saved volume). */
  persist() {
    return this.#save();
  }

  async #save() {
    const f = this.file;
    this.#saving = this.#saving.then(() => this.#d.save(f)).catch((e) => this.#d.log("uyku durumu yazılamadı", e));
    await this.#saving;
  }

  async #takeHardware(s: SleepSettings) {
    const found = await probeHardware(this.#d.hw, s, async (saved, kind) => {
      Object.assign(this.file.saved, saved);
      this.file.hw = kind;
      await this.#save();
    }, this.#d.storeBus, this.#d.log);
    if (!found) this.#warning = DDC_UNAVAILABLE;
    else this.#makeThrottle(found.pct);
  }

  async #extras(s: SleepSettings) {
    const hw = this.#d.hw;
    const saved = this.file.saved;
    if (s.quietPower) {
      const p = await hw.powerProfile();
      if (p && p !== "power-saver") {
        saved.power = p;
        await this.#save();
        if (!(await hw.setPowerProfile("power-saver"))) this.#d.log("sessiz güç profili ayarlanamadı");
      }
    }
    if (s.holdVolume !== null) {
      const v = await hw.volume();
      if (v) {
        saved.volume = v;
        await this.#save();
        if (!(await hw.setVolume(s.holdVolume / 100, false))) this.#d.log("ses düzeyi ayarlanamadı");
      }
    }
    if (s.leds) {
      const lit = await hw.litLeds();
      if (lit.length) {
        saved.leds = lit;
        await this.#save();
        for (const l of lit) await hw.setLed(l.name, 0);
      }
    }
  }

  #makeThrottle(current: number | null) {
    const f = this.file;
    const ddc = f.hw === "ddc" ? f.saved.ddc : null;
    const device = f.saved.backlight?.device ?? "";
    this.#throttle = new Throttle(
      {
        gapMs: ddc ? DDC_GAP_MS : BACKLIGHT_GAP_MS,
        apply: (pct) => (ddc ? this.#d.hw.setVcp(ddc.bus, Math.round((pct * ddc.max) / 100)) : this.#d.hw.setBacklight(device, pct)),
        onFail: () => {
          // The monitor stopped answering (or the backlight went away): the page dims alone from now on.
          this.#d.log(ddc ? "DDC parlaklık ayarlanamadı; yalnız içerik kısılıyor" : "arka ışık ayarlanamadı; yalnız içerik kısılıyor");
          if (ddc) this.#warning = DDC_UNAVAILABLE;
          this.#follow();
        },
        onApplied: () => this.#follow(),
        now: this.#now,
        setTimeout: this.#setT,
        clearTimeout: this.#clearT,
      },
      current,
    );
  }

  #start(current: number | null) {
    if (this.file.hw && !this.#throttle) this.#makeThrottle(current);
    this.#enter();
  }

  /** The phase now: tell the page on a change, follow the curve, wait for the next boundary. */
  #enter() {
    if (this.#stopped) return;
    const now = this.#now();
    const span = phaseAt(this.file.plan, now);
    const changed = !this.#phase || this.#phase.phase !== span.phase || this.#phase.startedAt !== span.startedAt;
    this.#phase = span;
    if (this.#phaseTimer !== null) this.#clearT(this.#phaseTimer);
    this.#phaseTimer = null;
    // The next moment anything changes: the span's end, the ring's auto-stop, the run's end.
    const plan = this.file.plan;
    const end = endOf(plan);
    const next = [span.endsAt, span.phase === "ring" ? span.startedAt + plan.autoStopMs : null, end].filter((x): x is number => x !== null && x > now);
    if (next.length) {
      this.#phaseTimer = this.#setT(() => {
        this.#phaseTimer = null;
        this.#enter();
      }, Math.max(0, Math.min(...next) - now));
      (this.#phaseTimer as NodeJS.Timeout)?.unref?.();
    }
    if (changed) this.#d.send(JSON.stringify({ type: "phase", ...this.#phaseFields() }));
    this.#follow();
    this.#alarmTick(span, now);
    if (end !== null && now >= end && !this.#ended) {
      this.#ended = true;
      this.#d.onEnd?.();
    }
  }

  /** Reports an alarm transition once (the key is kept in the state file: an adopting agent doesn't repeat it). */
  #alarmTick(span: PhaseSpan, now: number) {
    const p = this.file.plan;
    if (p.ringAt === null) return;
    let t: Omit<AlarmTransition, "plan"> | null = null;
    if (p.dismissedAt !== null && now >= p.dismissedAt) t = { kind: "dismissed", at: p.dismissedAt, count: p.snoozes.length };
    else if (span.phase === "sunrise") t = { kind: "sunrise", at: span.startedAt, count: 0 };
    else if (span.phase === "snoozed") t = { kind: "snoozed", at: span.startedAt, count: p.snoozes.filter((x) => x <= span.startedAt).length };
    else if (span.phase === "ring") {
      const count = p.snoozes.filter((x) => x < span.startedAt).length + 1;
      t = now < span.startedAt + p.autoStopMs ? { kind: "ring", at: span.startedAt, count } : { kind: "silenced", at: span.startedAt + p.autoStopMs, count };
    }
    if (!t) return;
    const key = `${t.kind}:${t.at}`;
    if (key === this.file.reported) return;
    this.file.reported = key;
    void this.#save();
    this.#d.onAlarm?.({ ...t, plan: p });
  }

  /**
   * A snooze or dismiss (API, the page's keys, another member) at `at` (shared clock): the plan changes, the page gets
   * it, the phase follows. false = it didn't apply (not ringing, already done).
   */
  alarm(action: AlarmAction, at: number): boolean {
    if (this.#stopped) return false;
    const next = applyAlarm(this.file.plan, action, at);
    if (!next) return false;
    this.#replan(next);
    return true;
  }

  /** The leader's plan (its hello): merged with this member's events; a change goes to the page. */
  setPlan(leader: SleepPlan) {
    if (this.#stopped || leader.t0 !== this.file.plan.t0) return;
    const next = mergePlans(this.file.plan, leader);
    if (JSON.stringify(next) !== JSON.stringify(this.file.plan)) this.#replan(next);
  }

  #replan(next: SleepPlan) {
    this.file.plan = next;
    void this.#save();
    this.#d.send(this.sleepMessage());
    this.#enter();
  }

  /** ms since the page's last heartbeat (since this run object began if none came yet). */
  heartbeatAge(): number {
    return this.#now() - (this.#heartbeatAt ?? this.#createdAt);
  }

  /** The alarm's gain on the page changed (e.g. Velour failed on the leader): a fresh `sleep` message. */
  alarmGainChanged() {
    this.resend();
  }

  /** Something in the page's `sleep` message changed (music, the morning summary): sent again. */
  resend() {
    if (!this.#stopped) this.#d.send(this.sleepMessage());
  }

  get #ramping() {
    const p = this.#phase?.phase;
    return p === "fade" || p === "sunrise" || this.#preview !== null;
  }

  /** The level now → the hardware step (rate-limited) and the content multiplier; ticks only while the curve moves. */
  #follow() {
    if (this.#stopped) return;
    const now = this.#now();
    const b = this.#d.settings().brightness;
    const l = this.#preview ?? levelAt(this.file.plan, b, now);
    const t = this.#throttle;
    if (t && !this.#broken) t.want(hardwareFor(l, this.#floor));
    // Against what the hardware is at now (a step may still be waiting for its rate limit, or DDC broke mid-run).
    const content = contentFor(l, this.file.hw ? (t?.current ?? null) : null);
    // While the curve moves, small changes wait for the next tick; in a flat phase the exact value goes out.
    if (content !== this.#content && (Math.abs(content - this.#content) >= 0.005 || content === 0 || content === 1 || !this.#ramping)) {
      this.#content = content;
      this.#d.send(JSON.stringify({ type: "brightness", content }));
    }
    if (this.#tickTimer !== null) this.#clearT(this.#tickTimer);
    this.#tickTimer = null;
    if (this.#ramping) {
      this.#tickTimer = this.#setT(() => {
        this.#tickTimer = null;
        this.#follow();
      }, TICK_MS);
      (this.#tickTimer as NodeJS.Timeout)?.unref?.();
    }
  }

  get #broken() {
    return this.file.hw === "ddc" && this.#warning === DDC_UNAVAILABLE;
  }

  get #floor() {
    return this.file.hw === "ddc" ? Math.max(0, this.#d.settings().ddc.min) : BACKLIGHT_MIN;
  }

  #phaseFields() {
    const p = this.#phase ?? phaseAt(this.file.plan, this.#now());
    return { phase: p.phase, phaseStartedAt: p.startedAt, phaseEndsAt: p.endsAt };
  }

  /** The page's full message (on connect and when settings change). */
  sleepMessage(): string {
    const s = this.#d.settings();
    const f = this.file;
    return JSON.stringify({
      type: "sleep",
      session: {
        id: f.session.id, seed: f.session.seed, t0: f.session.t0, leader: f.session.leader, members: f.session.members.map((m) => m.host),
        layout: f.session.members.map((m) => ({ id: m.host, side: m.side, distance: m.distance })),
      },
      me: f.me,
      // shared time = this host's clock + offsetMs (the leader's clock; sleep_group.ts: 0 unless it is off by more than 20 ms).
      offsetMs: this.#offset,
      plan: f.plan,
      alarm: { gain: this.#d.alarmGain?.() ?? 1 },
      ...this.#d.extra?.(),
      ...this.#phaseFields(),
      brightness: Math.max(0, this.#content),
      settings: { volume: s.volume, layers: s.layers, nightSound: s.times.nightSound },
      scale: f.scale,
      ...(this.#d.syncLog ? { syncLog: true } : {}),
    });
  }

  /** The page's clock correction to the leader (ms); a change goes to the page at once. */
  setOffset(ms: number) {
    if (ms === this.#offset) return;
    this.#offset = ms;
    if (!this.#stopped) this.#d.send(this.sleepMessage());
  }


  /** Settings changed (PUT /v1/sleep): the page gets them; a new brightness curve applies at once. Times apply at the next start. */
  settingsChanged() {
    this.#d.send(this.sleepMessage());
    this.#follow();
  }

  /** POST /v1/sleep/preview while running: `pct` for 5 s (hardware and content), then the curve again. */
  preview(pct: number) {
    this.#preview = pct;
    if (this.#previewTimer !== null) this.#clearT(this.#previewTimer);
    this.#previewTimer = this.#setT(() => {
      this.#previewTimer = null;
      this.#preview = null;
      this.#follow();
    }, PREVIEW_MS);
    (this.#previewTimer as NodeJS.Timeout)?.unref?.();
    this.#follow();
  }

  heartbeat() {
    this.#heartbeatAt = this.#now();
  }

  status() {
    const t = this.#throttle;
    const f = this.file;
    return {
      // The plan travels with the session: the phone sends the leader's to the other members (one plan for the group).
      session: { ...f.session, plan: f.plan },
      ...this.#phaseFields(),
      alarm: alarmAt(f.plan, this.#now()),
      brightness: {
        dimming: f.hw && !this.#broken ? f.hw : "content",
        hardware: t && !this.#broken ? t.current : null,
        content: Math.max(0, this.#content),
        preview: this.#preview,
      },
      warning: this.#warning,
      page: { heartbeatAt: this.#heartbeatAt },
      scale: f.scale,
    };
  }

  /** Timers off, nothing restored: the next agent adopts the run (restart). */
  detach() {
    this.#stopped = true;
    for (const h of [this.#phaseTimer, this.#tickTimer, this.#previewTimer]) if (h !== null) this.#clearT(h);
    this.#phaseTimer = this.#tickTimer = this.#previewTimer = null;
    this.#throttle?.stop();
  }

  /** Any timer pending (tests: nothing left after stop). */
  get armed() {
    return this.#phaseTimer !== null || this.#tickTimer !== null || this.#previewTimer !== null || (this.#throttle !== null && !this.#throttle.idle());
  }

  /** Stop: timers off, an in-flight hardware call finished, every saved value put back. */
  async stop() {
    this.detach();
    await this.#throttle?.settled();
    await this.#saving;
    await this.#d.hw.restore(this.file.saved);
  }
}

// ---- request bodies ----

/** A partial of an object schema without its defaults, nested objects partial too (unknown keys refused). */
function deepPatch(o: z.ZodObject): z.ZodObject {
  const fields: Record<string, z.ZodType> = {};
  for (const [k, v] of Object.entries(o.shape)) {
    let inner = v as z.ZodType;
    while (inner._zod.def.type === "default" || inner._zod.def.type === "prefault") inner = (inner._zod.def as unknown as { innerType: z.ZodType }).innerType;
    fields[k] = (inner instanceof z.ZodObject ? deepPatch(inner) : inner).optional();
  }
  return z.strictObject(fields);
}

/** PUT /v1/sleep: `{settings: <partial>}`; nested blocks merge, arrays and `group` are replaced whole. */
export const sleepPutSchema = z.strictObject({ settings: deepPatch(sleepSettingsSchema) });

/** Merges a validated patch into the settings (plain objects deep, anything else replaced). */
export function mergeSettings(cur: SleepSettings, patch: Record<string, unknown>): SleepSettings {
  const merge = (a: unknown, b: unknown): unknown => {
    if (b === undefined) return a;
    if (!b || typeof b !== "object" || Array.isArray(b) || !a || typeof a !== "object" || Array.isArray(a)) return b;
    const out: Record<string, unknown> = { ...(a as Record<string, unknown>) };
    for (const [k, v] of Object.entries(b)) out[k] = merge(out[k], v);
    return out;
  };
  return sleepSettingsSchema.parse(merge(cur, patch));
}

/** This agent's name as a session member id (the config name allows more characters). */
export function hostIdOf(name: string): string {
  return name.replace(/[^A-Za-z0-9_.-]/g, "-").slice(0, 64) || "host";
}

/** How far `t0` may lie from the agent's clock: a group member may start late (S3), never long before or after. */
export const T0_PAST_MS = 12 * 60 * MIN;
export const T0_FUTURE_MS = 10 * MIN;

/**
 * Members as sent → the layout every member computes alike. A bare host id (the S2 draft's form) gets its side from
 * its place in the list (first left, last right, others at the foot) and distance "mid".
 */
export function membersOf(list: ReadonlyArray<unknown>): SleepMember[] {
  return list.map((m, i) => {
    if (typeof m === "string") return { host: m, side: i === 0 ? "left" : i === list.length - 1 ? "right" : "foot", distance: "mid" };
    const o = m as Record<string, unknown>;
    return {
      host: String(o.host),
      side: SIDES.includes(o.side as SleepMember["side"]) ? (o.side as SleepMember["side"]) : "left",
      distance: DISTANCES.includes(o.distance as SleepMember["distance"]) ? (o.distance as SleepMember["distance"]) : "mid",
    };
  });
}

const memberSchema = z.union([hostId, z.strictObject({ host: hostId, side: z.enum(SIDES), distance: z.enum(DISTANCES).default("mid") })]);

/** The session object the phone sends to every member (PLAN.md §21 Mimari): members [{host, side, distance}]. */
export const sessionSchema = z
  .strictObject({
    id: z.string().regex(SESSION_ID),
    seed: z.number().int().min(0).max(0xffffffff),
    t0: z.number().int().positive(),
    members: z.array(memberSchema).min(1).max(4),
    leader: hostId,
    plan: z.unknown().optional(),
  })
  .transform((s, ctx): SleepSession => {
    const { plan: raw, ...rest } = s;
    const plan = raw === undefined ? undefined : parsePlan(raw);
    if (plan === null || (plan && plan.t0 !== s.t0)) {
      ctx.addIssue({ code: "custom", message: "bad plan", path: ["plan"] });
      return z.NEVER;
    }
    return { ...rest, members: membersOf(s.members), ...(plan ? { plan } : {}) };
  })
  .refine((s) => s.members.some((m) => m.host === s.leader), { message: "leader must be a member", path: ["leader"] })
  .refine((s) => new Set(s.members.map((m) => m.host)).size === s.members.length, { message: "members repeat", path: ["members"] })
  .refine((s) => s.t0 > Date.now() - T0_PAST_MS && s.t0 < Date.now() + T0_FUTURE_MS, { message: "t0 too far from now", path: ["t0"] });

export const sleepStartSchema = z.strictObject({ session: sessionSchema.optional() });
export const sleepPreviewSchema = z.strictObject({ brightness: z.number().int().min(0).max(100) });
export const sleepAlarmSchema = z.strictObject({ action: z.enum(["snooze", "dismiss"]) });
