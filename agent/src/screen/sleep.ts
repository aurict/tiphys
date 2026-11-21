// Sleep mode on one display host (PLAN.md §21 A-2, A-3, A-10; S2): the phase machine and the brightness curve.
// Phases follow from the session's start `t0` and the settings' times (Kararlar 4: settle 3 min, fade 30 min), not from
// ticks: settle → fade → night (open-ended in S2). sunrise / ring / snoozed / morning exist as types and in the pure
// functions (a plan with `ringAt`) for S4's alarm; S2 never sets it.
// Brightness: a target level L(t) in percent of full brightness — `start` in settle, eased out to `night` over the
// fade, eased in from `night` to `morning` during sunrise. Two layers: the hardware (backlight via brightnessctl, at
// most one call per 2 s; DDC/CI via ddcutil, at most one step per 15 s, only on a change) never below its floor, and
// the page's content multiplier L / hardware (0..1), which fills between hardware steps and does the darkest part of
// the night. Without hardware dimming (no backlight, DDC unavailable) the page dims alone and the status carries the
// warning `agent.sleep.ddcUnavailable`. The page gets `sleep` (everything), `phase` and `brightness` messages; it
// sends `heartbeat` every 10 s (kept for S4's WAV fallback).
// Trace-free: the state file (sleep.json in the screen mode's tmpfs work dir, 0600, written whole before every side
// effect) holds the session, the plan and every previous hardware value; stop restores them and removes it, and after
// a crash the next agent either adopts the run (kiosk still up) or restores from it.
// Test-only time scale (`scale`, from TIPHYS_SLEEP_SCALE; unset = 1): every phase length is divided by it. The
// hardware rate limits are not scaled.
import { z } from "zod";
import { hostId, sleepSettingsSchema, type SleepSettings } from "../config.ts";
import { AppError } from "../errors.ts";
import { Hardware, NO_SAVED, sanitizeSaved, Throttle, type HwKind, type HwSaved } from "./sleep_hw.ts";

export const SLEEP_PHASES = ["settle", "fade", "night", "sunrise", "ring", "snoozed", "morning"] as const;
export type SleepPhase = (typeof SLEEP_PHASES)[number];

export interface SleepSession {
  id: string;
  seed: number;
  t0: number;
  members: string[];
  leader: string;
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

/** The plan of a run started at `t0` with the settings' times (and alarm, S4) divided by `scale`. */
export function planOf(t0: number, s: SleepSettings, scale = 1): SleepPlan {
  return {
    t0,
    settleMs: Math.round((s.times.settleMin * MIN) / scale),
    fadeMs: Math.round((s.times.fadeMin * MIN) / scale),
    soundFadeMs: Math.round((s.times.soundFadeMin * MIN) / scale),
    nightSound: s.times.nightSound,
    sunriseAt: null,
    ringAt: null,
    rampMs: Math.round((s.alarm.rampMin * MIN) / scale),
    alarmSound: s.alarm.sound,
  };
}

export interface PhaseSpan {
  phase: SleepPhase;
  startedAt: number;
  endsAt: number | null;
}

/** The phase spans of a plan in order (zero-length ones dropped; the last is open-ended). */
export function phasesOf(p: SleepPlan): PhaseSpan[] {
  const settleEnd = p.t0 + p.settleMs, fadeEnd = settleEnd + p.fadeMs;
  const out: PhaseSpan[] = [{ phase: "settle", startedAt: p.t0, endsAt: settleEnd }, { phase: "fade", startedAt: settleEnd, endsAt: fadeEnd }];
  if (p.ringAt === null) out.push({ phase: "night", startedAt: fadeEnd, endsAt: null });
  else {
    const sun = Math.min(p.ringAt, Math.max(fadeEnd, p.sunriseAt ?? p.ringAt));
    out.push({ phase: "night", startedAt: fadeEnd, endsAt: sun }, { phase: "sunrise", startedAt: sun, endsAt: p.ringAt }, { phase: "ring", startedAt: p.ringAt, endsAt: null });
  }
  return out.filter((x) => x.endsAt === null || x.endsAt > x.startedAt);
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
  const k = s.endsAt === null ? 1 : clamp01((t - s.startedAt) / (s.endsAt - s.startedAt));
  switch (s.phase) {
    case "settle":
      return b.start;
    case "fade":
      return b.start + (Math.min(b.night, b.start) - b.start) * easeOut(k);
    case "night":
      return Math.min(b.night, b.start);
    case "sunrise":
      return Math.min(b.night, b.start) + (b.morning - Math.min(b.night, b.start)) * easeIn(k);
    default:
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
}

const SESSION_ID = /^[A-Za-z0-9_-]{8,64}$/;
const HOST = /^[A-Za-z0-9_.-]{1,64}$/;

/** A state file's content → a valid file, or null (the run can't be adopted; its hardware is still restored). */
export function parseSleepFile(v: unknown): SleepFile | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const s = o.session as Record<string, unknown> | undefined;
  const p = o.plan as Record<string, unknown> | undefined;
  const ms = (x: unknown) => typeof x === "number" && Number.isSafeInteger(x) && x >= 0;
  if (!s || !p || typeof s.id !== "string" || !SESSION_ID.test(s.id) || !ms(s.seed) || !ms(s.t0)) return null;
  const members = Array.isArray(s.members) ? s.members.filter((m): m is string => typeof m === "string" && HOST.test(m)).slice(0, 4) : [];
  if (!members.length || typeof s.leader !== "string" || !members.includes(s.leader) || typeof o.me !== "string" || !HOST.test(o.me)) return null;
  if (![p.t0, p.settleMs, p.fadeMs, p.soundFadeMs, p.rampMs].every(ms) || !(p.sunriseAt === null || ms(p.sunriseAt)) || !(p.ringAt === null || ms(p.ringAt))) return null;
  const scale = typeof o.scale === "number" && o.scale >= 1 && o.scale <= 1000 ? o.scale : 1;
  return {
    v: 1,
    session: { id: s.id, seed: s.seed as number, t0: s.t0 as number, members, leader: s.leader },
    me: o.me,
    plan: {
      t0: p.t0 as number, settleMs: p.settleMs as number, fadeMs: p.fadeMs as number, soundFadeMs: p.soundFadeMs as number,
      nightSound: p.nightSound === "off" ? "off" : "hum", sunriseAt: (p.sunriseAt as number | null) ?? null, ringAt: (p.ringAt as number | null) ?? null,
      rampMs: p.rampMs as number, alarmSound: p.alarmSound === "chime" || p.alarmSound === "velour" ? p.alarmSound : "birds",
    },
    scale,
    hw: o.hw === "backlight" || o.hw === "ddc" ? o.hw : null,
    saved: sanitizeSaved(o.saved),
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
  now?: () => number;
  setTimeout?: (fn: () => void, ms: number) => unknown;
  clearTimeout?: (h: unknown) => void;
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
  #stopped = false;
  #saving: Promise<unknown> = Promise.resolve();

  private constructor(d: SleepDeps, file: SleepFile) {
    this.#d = d;
    this.#now = d.now ?? Date.now;
    this.#setT = d.setTimeout ?? ((fn, ms) => setTimeout(fn, ms));
    this.#clearT = d.clearTimeout ?? ((h) => clearTimeout(h as NodeJS.Timeout));
    this.file = file;
  }

  /** A new run: reads and saves every previous hardware value, applies the extras, then follows the curve. */
  static async begin(d: SleepDeps, session: SleepSession, me: string, scale: number): Promise<SleepRun> {
    const s = d.settings();
    const run = new SleepRun(d, { v: 1, session, me, plan: planOf(session.t0, s, scale), scale, hw: null, saved: { ...NO_SAVED, leds: [] } });
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
    if (span.endsAt !== null) {
      this.#phaseTimer = this.#setT(() => {
        this.#phaseTimer = null;
        this.#enter();
      }, Math.max(0, span.endsAt - now));
      (this.#phaseTimer as NodeJS.Timeout)?.unref?.();
    }
    if (changed) this.#d.send(JSON.stringify({ type: "phase", ...this.#phaseFields() }));
    this.#follow();
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
      session: { id: f.session.id, seed: f.session.seed, t0: f.session.t0, leader: f.session.leader, members: f.session.members, layout: [{ id: f.me, side: s.side, distance: s.distance }] },
      me: f.me,
      // S3 measures the offset to the leader; alone it is 0.
      offsetMs: 0,
      plan: f.plan,
      ...this.#phaseFields(),
      brightness: Math.max(0, this.#content),
      settings: { volume: s.volume, layers: s.layers, nightSound: s.times.nightSound },
      scale: f.scale,
    });
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
      session: f.session,
      ...this.#phaseFields(),
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

/** The session object the phone sends to every member (PLAN.md §21 Mimari). */
export const sessionSchema = z
  .strictObject({
    id: z.string().regex(SESSION_ID),
    seed: z.number().int().min(0).max(0xffffffff),
    t0: z.number().int().positive(),
    members: z.array(hostId).min(1).max(4),
    leader: hostId,
  })
  .refine((s) => s.members.includes(s.leader), { message: "leader must be a member", path: ["leader"] })
  .refine((s) => new Set(s.members).size === s.members.length, { message: "members repeat", path: ["members"] })
  .refine((s) => s.t0 > Date.now() - T0_PAST_MS && s.t0 < Date.now() + T0_FUTURE_MS, { message: "t0 too far from now", path: ["t0"] });

export const sleepStartSchema = z.strictObject({ session: sessionSchema.optional() });
export const sleepPreviewSchema = z.strictObject({ brightness: z.number().int().min(0).max(100) });
