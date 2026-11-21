// Sleep mode alarm (PLAN.md §21 A-4, E-2, Kararlar 4–5; S4): when it rings, and what happens around it on one host.
// - nextAlarm: the next `time` (HH:MM) on an allowed day strictly after a moment, in this machine's local time zone.
//   Local dates are built with the Date constructor, so a DST change is handled by the platform: a time that falls
//   into the spring-forward gap rings at the first valid minute after it (02:30 → 03:30), a time that happens twice
//   in the autumn rings at its first occurrence. `once` takes the next day the time comes (today if still ahead).
// - The alarm runs only while the sleep mode runs (Karar 5); its plan is part of the run (sleep.ts). The phone keeps
//   its own backup alarm (S6).
// - AlarmEffects: one per run, fed the run's alarm transitions (sleep.ts SleepRun onAlarm):
//   * push `sleep.alarm` params {state: ringing|snoozed|autoStopped|dismissed, at, snoozeMin, snoozedUntil?} (transient:
//     numbers and times only, never content; ringing and autoStopped high priority). Sent by the group's leader only (one push per group); a member sends it
//     itself only while its link to the leader is down (the leader may be the one that's gone).
//   * event log `sleep.alarm` {state: rang|autoStopped|dismissed} on every host (no content);
//   * `once` alarms switch themselves off in the settings at the first ring;
//   * Velour (`sound: "velour"`, the leader only, a `velourTrack` set): the track starts at a low volume and is ramped
//     to the sleep volume over rampMin; snooze pauses it, the next ring plays it again; dismiss / auto-stop / stop
//     pause it and put Velour's volume back. Velour unreachable → the page plays the birds instead (gain 1). Other
//     members play the birds quietly (gain 0.4): the song is the leader's, but a member still wakes the room if the
//     leader's machine is down.
//   * WAV fallback: at a ring, if the page's heartbeat is older than 30 s (Firefox crashed), a short synthesized WAV
//     (birds or chime, 16-bit mono) is written into the tmpfs work dir and played with `pw-play` in a loop with
//     pauses (its volume ramped like the page's) until snooze / dismiss / auto-stop / stop or until the page's
//     heartbeat is back; the kiosk unit is relaunched (also at sunrise when stale). The file is deleted when it stops.
import type { SleepSettings } from "../config.ts";
import type { AlarmTransition, SleepPlan } from "./sleep.ts";

export const DAYS = { weekdays: [1, 2, 3, 4, 5], daily: [0, 1, 2, 3, 4, 5, 6] } as const;
/** The page's heartbeat is "missing" after this long (it beats every 10 s). */
export const STALE_MS = 30_000;
export const WAV_RATE = 24_000;
/** Pause between two plays of the fallback WAV. */
export const WAV_GAP_MS = 2500;
/** Velour's volume steps while it ramps. */
export const VELOUR_STEP_MS = 2000;
export const VELOUR_START = 4;
export const MEMBER_GAIN = 0.4;

/** The next alarm strictly after `after` (ms), in local time; null if no day is allowed. */
export function nextAlarm(a: Pick<SleepSettings["alarm"], "time" | "days">, after: number): number | null {
  const m = /^([01]\d|2[0-3]):([0-5]\d)$/.exec(a.time);
  if (!m) return null;
  const hh = Number(m[1]), mm = Number(m[2]);
  const days: readonly number[] = a.days === "once" ? DAYS.daily : typeof a.days === "string" ? DAYS[a.days] : a.days;
  const base = new Date(after);
  for (let i = 0; i <= 8; i++) {
    const d = new Date(base.getFullYear(), base.getMonth(), base.getDate() + i, hh, mm, 0, 0);
    // The weekday of the calendar day asked for (a gap time may have moved the clock to the next hour, never the day).
    const wd = new Date(base.getFullYear(), base.getMonth(), base.getDate() + i, 12).getDay();
    if (d.getTime() > after && days.includes(wd)) return d.getTime();
  }
  return null;
}

// ---- the fallback WAV (pure) ----

/** A short alarm sound as a 16-bit mono WAV: FM bird calls or a soft bell, ~3 s, peak −3 dBFS. */
export function alarmWav(sound: "birds" | "chime", rate = WAV_RATE): Buffer {
  const n = Math.round(rate * 3);
  const a = new Float64Array(n);
  if (sound === "chime") {
    for (const [f0, at] of [[523.25, 0], [659.25, 0.9]] as const) {
      for (let j = 0; j + Math.round(at * rate) < n; j++) {
        const t = j / rate;
        const v = [[1, 1, 1.6], [2.01, 0.35, 1.0], [2.76, 0.2, 0.7]].reduce((s, [m, g, d]) => s + g! * Math.sin(2 * Math.PI * f0 * m! * t) * Math.exp(-t / d!), 0);
        a[j + Math.round(at * rate)]! += v * Math.min(1, t / 0.006);
      }
    }
  } else {
    // Three calls of 2–4 notes, each an FM chirp with a sin² envelope.
    const calls = [[0.1, 3400, 900, 3], [1.0, 2900, -600, 4], [2.0, 3800, 1200, 2]] as const;
    for (const [at, f0, sweep, notes] of calls) {
      for (let k = 0; k < notes; k++) {
        const s0 = Math.round((at + k * 0.16) * rate), L = Math.round(0.09 * rate);
        let ph = 0;
        for (let j = 0; j < L && s0 + j < n; j++) {
          const u = j / L;
          ph += (2 * Math.PI * (f0 * (1 + 0.08 * Math.sin((2 * Math.PI * 40 * j) / rate)) + sweep * u)) / rate;
          a[s0 + j]! += Math.sin(ph) * Math.sin(Math.PI * u) ** 2;
        }
      }
    }
  }
  let peak = 0;
  for (const v of a) peak = Math.max(peak, Math.abs(v));
  const k = peak ? 0.707 / peak : 0;
  const out = Buffer.alloc(44 + n * 2);
  out.write("RIFF", 0, "ascii");
  out.writeUInt32LE(36 + n * 2, 4);
  out.write("WAVEfmt ", 8, "ascii");
  out.writeUInt32LE(16, 16);
  out.writeUInt16LE(1, 20);
  out.writeUInt16LE(1, 22);
  out.writeUInt32LE(rate, 24);
  out.writeUInt32LE(rate * 2, 28);
  out.writeUInt16LE(2, 32);
  out.writeUInt16LE(16, 34);
  out.write("data", 36, "ascii");
  out.writeUInt32LE(n * 2, 40);
  for (let i = 0; i < n; i++) out.writeInt16LE(Math.round(Math.max(-1, Math.min(1, a[i]! * k)) * 32767), 44 + i * 2);
  return out;
}

/** Ramp 0..1 at `t` of a ring that began at `start` (never silent: the first plays are quiet, not muted). */
export const rampAt = (start: number, rampMs: number, t: number) => 0.15 + 0.85 * Math.min(1, Math.max(0, (t - start) / Math.max(1, rampMs)));

// ---- the effects ----

export type AlarmState = "ringing" | "snoozed" | "autoStopped" | "dismissed";

export interface AlarmDeps {
  /** The run's plan now (it changes with snoozes, a dismiss, the leader's plan). */
  plan: () => SleepPlan;
  /** This host's part: the leader (or alone) pushes; a member only while its link is down. */
  role: () => "leader" | "member";
  linkUp: () => boolean;
  settings: () => SleepSettings;
  /** Push `sleep.alarm` params {state, …params} (the caller adds agent and session to `data`). */
  push: (state: AlarmState, params: Record<string, number>, high: boolean) => void;
  /** Event log `sleep.alarm` {state} (no content). */
  record: (state: "rang" | "autoStopped" | "dismissed") => void;
  /** A `once` alarm went off: switch it off in the settings. */
  disableOnce: () => void;
  heartbeatAge: () => number;
  /** Heartbeat older than this = no page (default STALE_MS; tests shorten it). */
  staleMs?: number;
  /** Relaunch the kiosk if its unit is gone (best effort). */
  restartKiosk: () => Promise<void>;
  /** The page's alarm gain changed. */
  gainChanged: () => void;
  /** Fallback player; null = none here (no pw-play, or the headless test kiosk: never a sound). */
  wav: { write: (bytes: Buffer) => Promise<void>; play: (volume: number) => Promise<boolean>; remove: () => Promise<void> } | null;
  /** Velour's control socket (the leader's); null = none here. */
  velour: ((op: Record<string, unknown>) => Promise<unknown>) | null;
  /** Velour's volume before the alarm took it (kept in the state file). */
  velourSaved: { get: () => { volume: number } | null; set: (v: { volume: number } | null) => void };
  log: (msg: string, err?: unknown) => void;
  now?: () => number;
  setTimeout?: (fn: () => void, ms: number) => unknown;
  clearTimeout?: (h: unknown) => void;
}

const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);

export class AlarmEffects {
  readonly #d: AlarmDeps;
  readonly #now: () => number;
  readonly #setT: (fn: () => void, ms: number) => unknown;
  readonly #clearT: (h: unknown) => void;
  /** The current ring's start while the alarm should sound (WAV, Velour), else null. */
  #ring: number | null = null;
  #wav: { start: number; timer: unknown; playing: boolean } | null = null;
  #wavWritten = false;
  #velourOn = false;
  #velourFailed = false;
  #velourTimer: unknown = null;
  #closed = false;

  constructor(d: AlarmDeps) {
    this.#d = d;
    this.#now = d.now ?? Date.now;
    this.#setT = d.setTimeout ?? ((fn, ms) => setTimeout(fn, ms));
    this.#clearT = d.clearTimeout ?? ((h) => clearTimeout(h as NodeJS.Timeout));
  }

  get #stale() {
    return this.#d.heartbeatAge() > (this.#d.staleMs ?? STALE_MS);
  }

  /** Does Velour play the alarm here (the leader with a track)? */
  get #velourHere() {
    const a = this.#d.settings().alarm;
    return this.#d.plan().alarmSound === "velour" && this.#d.role() === "leader" && this.#d.velour !== null && a.velourTrack !== null && !this.#velourFailed;
  }

  /** The page's alarm gain: 0 while Velour plays it here, 0.4 on members of a Velour alarm, else 1. */
  gain(): number {
    if (this.#d.plan().alarmSound !== "velour") return 1;
    if (this.#d.role() === "member") return MEMBER_GAIN;
    return this.#velourHere ? 0 : 1;
  }

  get #pusher() {
    return this.#d.role() === "leader" || !this.#d.linkUp();
  }

  #push(state: AlarmState, at: number, high: boolean, extra: Record<string, number> = {}) {
    if (!this.#pusher) return;
    this.#d.push(state, { at, snoozeMin: Math.round(this.#d.plan().snoozeMs / 60_000), ...extra }, high);
  }

  /** A transition of the run's alarm (sleep.ts reports each one once). */
  on(t: AlarmTransition) {
    if (this.#closed) return;
    const p = t.plan;
    switch (t.kind) {
      case "sunrise":
        if (this.#stale) void this.#d.restartKiosk().catch((e) => this.#d.log("kiosk yeniden açılamadı", e));
        return;
      case "ring": {
        this.#ring = t.at;
        this.#d.record("rang");
        if (t.count === 1) {
          const a = this.#d.settings().alarm;
          if (a.enabled && a.days === "once") this.#d.disableOnce();
        }
        this.#push("ringing", t.at, true, { count: t.count, ...(p.ringAt !== null ? { ringAt: p.ringAt } : {}) });
        if (this.#velourHere) void this.#velourStart(t.at);
        if (this.#stale) {
          if (!this.#velourHere) this.#wavStart(t.at);
          void this.#d.restartKiosk().catch((e) => this.#d.log("kiosk yeniden açılamadı", e));
        }
        return;
      }
      case "snoozed":
        this.#quiet(false);
        this.#push("snoozed", t.at, false, { snoozedUntil: t.at + p.snoozeMs });
        return;
      case "silenced":
        this.#quiet(true);
        this.#d.record("autoStopped");
        this.#push("autoStopped", t.at, true);
        return;
      case "dismissed":
        this.#quiet(true);
        this.#d.record("dismissed");
        this.#push("dismissed", t.at, false);
        return;
    }
  }

  /** The page beats again: it plays the alarm itself, the WAV stops. */
  heartbeat() {
    if (this.#wav) this.#wavStop();
  }

  /** The sound stops (snooze: Velour paused only; end: Velour's volume back too). */
  #quiet(end: boolean) {
    this.#ring = null;
    this.#wavStop();
    if (this.#velourOn || (end && this.#d.velourSaved.get())) void this.#velourStop(end);
  }

  // ---- WAV fallback ----

  #wavStart(start: number) {
    const w = this.#d.wav;
    if (!w || this.#wav) return;
    this.#wav = { start, timer: null, playing: false };
    const loop = async () => {
      const cur = this.#wav;
      if (!cur || this.#closed) return;
      try {
        if (!this.#wavWritten) {
          await w.write(alarmWav(this.#d.plan().alarmSound === "chime" ? "chime" : "birds"));
          this.#wavWritten = true;
        }
        if (this.#wav !== cur) return;
        const vol = (this.#d.settings().volume / 100) ** 2 * rampAt(cur.start, this.#d.plan().rampMs, this.#now());
        cur.playing = true;
        const ok = await w.play(Math.round(vol * 1000) / 1000);
        cur.playing = false;
        if (!ok) this.#d.log("yedek alarm sesi çalınamadı");
      } catch (e) {
        cur.playing = false;
        this.#d.log("yedek alarm sesi çalınamadı", e);
      }
      if (this.#wav !== cur) return;
      cur.timer = this.#setT(() => void loop(), WAV_GAP_MS);
      (cur.timer as NodeJS.Timeout)?.unref?.();
    };
    void loop();
  }

  #wavStop() {
    const cur = this.#wav;
    if (!cur) return;
    if (cur.timer !== null) this.#clearT(cur.timer);
    this.#wav = null;
  }

  /** Is the fallback looping (tests, status)? */
  get wavActive() {
    return this.#wav !== null;
  }

  // ---- Velour (leader) ----

  async #velourStart(start: number) {
    const v = this.#d.velour!;
    const track = this.#d.settings().alarm.velourTrack!;
    try {
      const st = (await v({ op: "state" })) as Record<string, unknown> | null;
      if (this.#ring !== start || this.#closed) return;
      if (!this.#d.velourSaved.get()) this.#d.velourSaved.set({ volume: num(st?.volume) ?? 50 });
      await v({ op: "volume", percent: VELOUR_START });
      // The first ring starts the track; after a snooze it plays on from where it paused.
      if (!this.#velourOn && (this.#d.plan().snoozes.length === 0 || st?.playing !== false)) await v({ op: "play-target", target: { kind: "watch", videoId: track } });
      else if (st?.playing === false) await v({ op: "toggle" });
      this.#velourOn = true;
    } catch (e) {
      this.#d.log("Velour alarmı başlatılamadı; sayfa kuş seslerini çalıyor", e);
      this.#velourFailed = true;
      this.#d.gainChanged();
      if (this.#ring === start && this.#stale) this.#wavStart(start);
      return;
    }
    const step = async () => {
      this.#velourTimer = null;
      if (this.#ring !== start || this.#closed) return;
      const k = Math.min(1, (this.#now() - start) / Math.max(1, this.#d.plan().rampMs));
      const target = this.#d.settings().volume;
      await v({ op: "volume", percent: Math.round(VELOUR_START + (Math.max(VELOUR_START, target) - VELOUR_START) * k) }).catch(() => {});
      if (k < 1 && this.#ring === start) {
        this.#velourTimer = this.#setT(() => void step(), VELOUR_STEP_MS);
        (this.#velourTimer as NodeJS.Timeout)?.unref?.();
      }
    };
    await step();
  }

  async #velourStop(end: boolean) {
    if (this.#velourTimer !== null) this.#clearT(this.#velourTimer);
    this.#velourTimer = null;
    const v = this.#d.velour;
    if (!v) return;
    try {
      if (this.#velourOn) {
        const st = (await v({ op: "state" })) as Record<string, unknown> | null;
        if (st?.playing === true) await v({ op: "toggle" });
      }
      const saved = this.#d.velourSaved.get();
      if (end && saved) {
        await v({ op: "volume", percent: saved.volume });
        this.#d.velourSaved.set(null);
      }
    } catch (e) {
      this.#d.log("Velour alarmı durdurulamadı", e);
    }
    this.#velourOn = false;
  }

  /** Timers off, nothing undone (the agent restarts; the next one adopts the run). */
  detach() {
    this.#ring = null;
    this.#wavStop();
    if (this.#velourTimer !== null) this.#clearT(this.#velourTimer);
    this.#velourTimer = null;
    this.#closed = true;
  }

  /** The run stops: sound off, the WAV file gone, Velour paused and its volume back. */
  async stop() {
    this.#ring = null;
    this.#wavStop();
    this.#closed = true;
    if (this.#velourOn || this.#d.velourSaved.get()) await this.#velourStop(true);
    if (this.#wavWritten || this.#d.wav) await this.#d.wav?.remove().catch((e) => this.#d.log("yedek alarm dosyası silinemedi", e));
    this.#wavWritten = false;
  }

  /** Any timer pending (tests). */
  get armed() {
    return this.#wav !== null || this.#velourTimer !== null;
  }
}
