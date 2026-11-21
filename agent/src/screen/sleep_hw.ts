// Sleep mode hardware (PLAN.md §21 A-3, A-8, A-10): the backlight (brightnessctl, laptop), the monitor brightness over
// DDC/CI (ddcutil, VCP 0x10, theloth) and the optional extras — quiet power profile (powerprofilesctl), held system
// volume (wpctl), LEDs (/sys/class/leds). Fixed commands with validated values only. Every previous value is read
// first and goes to the caller's state file (`HwSaved`) before anything is changed; `restoreSaved` puts it all back
// (stop, or the next agent after a crash). Heavy jobs are never touched.
// Output formats (ddcutil 3.0, brightnessctl 0.5, wpctl 0.5, powerprofilesctl 0.2x; parsed, never trusted):
//   brightnessctl -m -c backlight  → "intel_backlight,backlight,96000,100%,96000" (no device: a message, exit 0)
//   ddcutil detect --terse         → "Display 1\n   I2C bus:  /dev/i2c-3\n…" ("Invalid display" blocks are skipped)
//   ddcutil getvcp 10 --bus B --terse → "VCP 10 C 50 100" (failure: "DDC communication failed …", any exit code)
//   wpctl get-volume @DEFAULT_AUDIO_SINK@ → "Volume: 0.30 [MUTED]"
import { access, readdir, readFile, writeFile } from "node:fs/promises";
import { constants } from "node:fs";
import { join } from "node:path";
import type { Exec } from "../control.ts";

export type HwKind = "backlight" | "ddc";

/** What was there before the mode changed it (the sleep state file); null/empty = not changed. */
export interface HwSaved {
  backlight: { device: string; raw: number } | null;
  ddc: { bus: number; raw: number; max: number } | null;
  power: string | null;
  volume: { level: number; muted: boolean } | null;
  leds: Array<{ name: string; value: number }>;
}
export const NO_SAVED: HwSaved = { backlight: null, ddc: null, power: null, volume: null, leds: [] };

export interface HwIo {
  exec: Exec;
  which(cmd: string): boolean;
  /** /sys/class/leds (a temp dir in tests). */
  ledsDir: string;
}

const DEVICE = /^[A-Za-z0-9_.:-]{1,64}$/;
const LED = /^[A-Za-z0-9_.:-]{1,64}$/;
const PROFILE = /^[a-z][a-z-]{0,31}$/;
const SINK = "@DEFAULT_AUDIO_SINK@";
const DDC_MS = 10_000;

// ---- parsers (pure) ----

/** `brightnessctl -m -c backlight` → the first backlight device and its raw value / max. */
export function parseBacklight(out: string): { device: string; raw: number; max: number } | null {
  for (const line of out.split("\n")) {
    const f = line.trim().split(",");
    if (f.length < 5 || f[1] !== "backlight" || !DEVICE.test(f[0]!)) continue;
    const raw = Number(f[2]), max = Number(f[4]);
    if (Number.isSafeInteger(raw) && Number.isSafeInteger(max) && max > 0 && raw >= 0 && raw <= max) return { device: f[0]!, raw, max };
  }
  return null;
}

/** `ddcutil detect --terse` → the I²C bus numbers of the valid displays (in order). */
export function parseDetect(out: string): number[] {
  const buses: number[] = [];
  let valid = false;
  for (const line of out.split("\n")) {
    if (/^\S/.test(line)) valid = /^Display \d+\s*$/.test(line.trim());
    const m = /^\s+I2C bus:\s+\/dev\/i2c-(\d{1,3})\s*$/.exec(line);
    if (valid && m) buses.push(Number(m[1]));
  }
  return buses;
}

/** `ddcutil getvcp 10 --terse` → current and max of VCP 0x10. */
export function parseVcp(out: string): { raw: number; max: number } | null {
  const m = /^VCP 10 C (\d{1,5}) (\d{1,5})\s*$/m.exec(out);
  if (!m) return null;
  const raw = Number(m[1]), max = Number(m[2]);
  return max > 0 && raw <= max ? { raw, max } : null;
}

/** `wpctl get-volume` → level 0..1.5 and mute. */
export function parseVolume(out: string): { level: number; muted: boolean } | null {
  const m = /^Volume: (\d+(?:\.\d+)?)( \[MUTED\])?\s*$/m.exec(out);
  if (!m) return null;
  const level = Number(m[1]);
  return level >= 0 && level <= 1.5 ? { level, muted: m[2] !== undefined } : null;
}

/** An LED's `trigger` file → the active trigger ("none" = plain on/off). */
export function activeTrigger(text: string): string | null {
  return /\[([^\]\s]{1,64})\]/.exec(text)?.[1] ?? null;
}

// ---- commands ----

export class Hardware {
  readonly #io: HwIo;
  readonly #log: (msg: string, err?: unknown) => void;
  constructor(io: HwIo, log: (msg: string, err?: unknown) => void = () => {}) {
    this.#io = io;
    this.#log = log;
  }

  async #run(cmd: string, args: string[], timeoutMs = 5000) {
    if (!this.#io.which(cmd)) return null;
    return this.#io.exec(cmd, args, { timeoutMs, allowFail: true }).catch((e) => (this.#log(`${cmd} çalışmadı`, e), null));
  }

  /** The backlight device and its current value, or null (none, or no brightnessctl). */
  async backlight() {
    const r = await this.#run("brightnessctl", ["-m", "-c", "backlight"]);
    return r && r.code === 0 ? parseBacklight(r.stdout) : null;
  }

  /** Backlight to `pct` % (1..100). */
  async setBacklight(device: string, pct: number): Promise<boolean> {
    if (!DEVICE.test(device) || !Number.isInteger(pct) || pct < 1 || pct > 100) return false;
    return (await this.#run("brightnessctl", ["-q", "-d", device, "set", `${pct}%`]))?.code === 0;
  }

  async restoreBacklight(device: string, raw: number): Promise<boolean> {
    if (!DEVICE.test(device) || !Number.isSafeInteger(raw) || raw < 0) return false;
    return (await this.#run("brightnessctl", ["-q", "-d", device, "set", String(raw)]))?.code === 0;
  }

  get hasDdcutil() {
    return this.#io.which("ddcutil");
  }

  /** The first valid DDC display's bus (`ddcutil detect`; slow, run once and stored in the config). */
  async detectBus(): Promise<number | null> {
    const r = await this.#run("ddcutil", ["detect", "--terse"], 30_000);
    return r ? (parseDetect(r.stdout)[0] ?? null) : null;
  }

  async getVcp(bus: number) {
    if (!Number.isInteger(bus) || bus < 0 || bus > 255) return null;
    const r = await this.#run("ddcutil", ["getvcp", "10", "--bus", String(bus), "--terse"], DDC_MS);
    return r && r.code === 0 ? parseVcp(r.stdout) : null;
  }

  async setVcp(bus: number, raw: number): Promise<boolean> {
    if (!Number.isInteger(bus) || bus < 0 || bus > 255 || !Number.isInteger(raw) || raw < 0 || raw > 65535) return false;
    const r = await this.#run("ddcutil", ["setvcp", "10", String(raw), "--bus", String(bus), "--noverify"], DDC_MS);
    return r?.code === 0 && !/failed|error/i.test(r.stdout + r.stderr);
  }

  async powerProfile(): Promise<string | null> {
    const r = await this.#run("powerprofilesctl", ["get"]);
    const p = r?.code === 0 ? r.stdout.trim() : "";
    return PROFILE.test(p) ? p : null;
  }

  async setPowerProfile(p: string): Promise<boolean> {
    return PROFILE.test(p) && (await this.#run("powerprofilesctl", ["set", p]))?.code === 0;
  }

  async volume() {
    const r = await this.#run("wpctl", ["get-volume", SINK]);
    return r?.code === 0 ? parseVolume(r.stdout) : null;
  }

  async setVolume(level: number, muted: boolean): Promise<boolean> {
    if (!(level >= 0 && level <= 1.5)) return false;
    const a = await this.#run("wpctl", ["set-volume", SINK, level.toFixed(2)]);
    const b = await this.#run("wpctl", ["set-mute", SINK, muted ? "1" : "0"]);
    return a?.code === 0 && b?.code === 0;
  }

  /**
   * LEDs that are lit, writable and plain on/off (trigger "none"): an LED driven by a trigger (Wi-Fi, mic mute) would
   * lose its trigger when written and the trigger file is root's, so it couldn't be restored → skipped. Keyboard lock
   * LEDs (input*::) are state, not light → skipped.
   */
  async litLeds(): Promise<Array<{ name: string; value: number }>> {
    const out: Array<{ name: string; value: number }> = [];
    const names = await readdir(this.#io.ledsDir).catch(() => [] as string[]);
    for (const name of names.sort()) {
      if (!LED.test(name) || /^input\d+::/.test(name)) continue;
      const dir = join(this.#io.ledsDir, name);
      const value = Number((await readFile(join(dir, "brightness"), "utf8").catch(() => "")).trim());
      const trigger = activeTrigger(await readFile(join(dir, "trigger"), "utf8").catch(() => "[none]"));
      if (!Number.isInteger(value) || value <= 0 || trigger !== "none") continue;
      if (await access(join(dir, "brightness"), constants.W_OK).then(() => true, () => false)) out.push({ name, value });
    }
    return out;
  }

  async setLed(name: string, value: number): Promise<boolean> {
    if (!LED.test(name) || !Number.isInteger(value) || value < 0 || value > 100_000) return false;
    return writeFile(join(this.#io.ledsDir, name, "brightness"), String(value)).then(() => true, (e) => (this.#log("LED yazılamadı", e), false));
  }

  /** Puts back everything `saved` holds (best effort, each item on its own). */
  async restore(saved: HwSaved): Promise<void> {
    if (saved.backlight) await this.restoreBacklight(saved.backlight.device, saved.backlight.raw);
    if (saved.ddc) await this.setVcp(saved.ddc.bus, saved.ddc.raw);
    if (saved.power) await this.setPowerProfile(saved.power);
    if (saved.volume) await this.setVolume(saved.volume.level, saved.volume.muted);
    for (const l of saved.leds) await this.setLed(l.name, l.value);
  }
}

/** A saved-values object from a state file → only valid values. */
export function sanitizeSaved(v: unknown): HwSaved {
  const o = (v && typeof v === "object" ? v : {}) as Record<string, unknown>;
  const int = (x: unknown, max = 1e9) => (typeof x === "number" && Number.isSafeInteger(x) && x >= 0 && x <= max ? x : null);
  const b = o.backlight as Record<string, unknown> | null | undefined;
  const d = o.ddc as Record<string, unknown> | null | undefined;
  const vol = o.volume as Record<string, unknown> | null | undefined;
  return {
    backlight: b && typeof b.device === "string" && DEVICE.test(b.device) && int(b.raw) !== null ? { device: b.device, raw: int(b.raw)! } : null,
    ddc: d && int(d.bus, 255) !== null && int(d.raw, 65535) !== null && (int(d.max, 65535) ?? 0) > 0 ? { bus: int(d.bus)!, raw: int(d.raw)!, max: int(d.max)! } : null,
    power: typeof o.power === "string" && PROFILE.test(o.power) ? o.power : null,
    volume: vol && typeof vol.level === "number" && vol.level >= 0 && vol.level <= 1.5 ? { level: vol.level, muted: vol.muted === true } : null,
    leds: Array.isArray(o.leds)
      ? (o.leds as Array<Record<string, unknown>>).filter((l) => l && typeof l.name === "string" && LED.test(l.name) && int(l.value, 100_000) !== null).map((l) => ({ name: l.name as string, value: l.value as number })).slice(0, 32)
      : [],
  };
}

export interface ThrottleOpts {
  gapMs: number;
  apply: (v: number) => Promise<boolean>;
  onFail: () => void;
  now: () => number;
  setTimeout: (fn: () => void, ms: number) => unknown;
  clearTimeout: (h: unknown) => void;
  /** After each successful apply. */
  onApplied?: (v: number) => void;
}

/**
 * At most one apply per `gapMs`, only on a change, never two at once; the latest wanted value wins (trailing apply).
 * A failed apply calls `onFail` and stops the throttle (the caller falls back to content dimming).
 */
export class Throttle {
  current: number | null;
  #want: number | null = null;
  #last = -Infinity;
  #busy = false;
  #timer: unknown = null;
  #stopped = false;
  #inflight: Promise<unknown> = Promise.resolve();
  readonly #o: ThrottleOpts;

  constructor(o: ThrottleOpts, current: number | null = null) {
    this.#o = o;
    this.current = current;
  }

  get pending() {
    return this.#timer !== null || this.#busy;
  }

  want(v: number) {
    if (this.#stopped) return;
    this.#want = v;
    this.#kick();
  }

  #kick() {
    if (this.#stopped || this.#busy || this.#timer !== null || this.#want === null || this.#want === this.current) return;
    const wait = this.#last + this.#o.gapMs - this.#o.now();
    if (wait > 0) {
      this.#timer = this.#o.setTimeout(() => {
        this.#timer = null;
        this.#kick();
      }, wait);
      (this.#timer as NodeJS.Timeout)?.unref?.();
      return;
    }
    const v = this.#want;
    this.#busy = true;
    this.#last = this.#o.now();
    this.#inflight = this.#o.apply(v).then(
      (ok) => this.#done(v, ok),
      () => this.#done(v, false),
    );
  }

  #done(v: number, ok: boolean) {
    this.#busy = false;
    if (this.#stopped) return;
    if (!ok) {
      this.stop();
      this.#o.onFail();
      return;
    }
    this.current = v;
    this.#o.onApplied?.(v);
    this.#kick();
  }

  /** Resolves once a running apply has finished (stop waits for it before restoring). */
  settled(): Promise<void> {
    return this.#inflight.then(() => {});
  }

  /** Settled: nothing pending (tests). */
  idle() {
    return !this.#busy && this.#timer === null;
  }

  stop() {
    this.#stopped = true;
    if (this.#timer !== null) this.#o.clearTimeout(this.#timer);
    this.#timer = null;
  }
}
