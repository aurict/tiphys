// Sleep mode, S2 (PLAN.md §21): the phase machine and brightness curve with a fake clock, the hardware parsers, the
// rate limits, DDC through a fake ddcutil (detect, getvcp/setvcp, restore, failure → content only), the optional
// extras' save/restore, the hardware-only preview, and the routes on a fake display (start/stop, nothing left, restart
// adoption, crash recovery, validation). No real backlight, monitor, Hyprland or Firefox.
import { mkdir, mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { sleepSettingsSchema, type SleepSettings } from "../src/config.ts";
import type { ExecResult } from "../src/exec.ts";
import { displayRoutes, sleepScale, type DisplayIo } from "../src/screen/display.ts";
import {
  BACKLIGHT_GAP_MS, contentFor, DDC_GAP_MS, easeIn, easeOut, HardwarePreview, hardwareFor, levelAt, mergeSettings, parseSleepFile, phaseAt, phasesOf, planOf,
  PREVIEW_MS, SleepRun, sleepPutSchema, sessionSchema, type SleepFile, type SleepPlan, type SleepSession,
} from "../src/screen/sleep.ts";
import { activeTrigger, Hardware, parseBacklight, parseDetect, parseVcp, parseVolume, Throttle } from "../src/screen/sleep_hw.ts";
import { testApp } from "./helpers.ts";

const MIN = 60_000;
const cleanups: Array<() => unknown> = [];
afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
});
const flush = async (n = 6) => {
  for (let i = 0; i < n; i++) await new Promise((r) => setImmediate(r));
};
const until = async (f: () => boolean, ms = 4000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
};
const defaults = (): SleepSettings => sleepSettingsSchema.parse({});

/** Many timeouts at once (phase, tick, throttle, preview). */
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

interface HwCall {
  cmd: string;
  args: string[];
  at: number;
}

/** A fake machine: backlight (laptop) or a DDC monitor (theloth), power profile, volume, LEDs. */
function fakeMachine(o: { backlight?: boolean; ddc?: "ok" | "noDisplay" | "getFail" | "setFail"; tools?: string[]; now?: () => number; ledsDir?: string } = {}) {
  const calls: HwCall[] = [];
  const st = { raw: 48_000, vcp: 80, profile: "balanced", volume: "0.30", muted: true, setFails: false };
  const tools = o.tools ?? ["brightnessctl", "ddcutil", "powerprofilesctl", "wpctl"];
  const exec = async (cmd: string, args: string[]): Promise<ExecResult> => {
    calls.push({ cmd, args, at: o.now?.() ?? Date.now() });
    const out = (stdout: string, code = 0) => ({ stdout, stderr: "", code });
    const a = args.join(" ");
    if (cmd === "brightnessctl") {
      if (a === "-m -c backlight") return o.backlight ? out(`intel_backlight,backlight,${st.raw},${Math.round((st.raw * 100) / 96000)}%,96000\n`) : out("Failed to read any devices of class 'backlight'.\n");
      const m = /^-q -d intel_backlight set (\d+)(%?)$/.exec(a);
      if (m && o.backlight) {
        st.raw = m[2] ? Math.round((Number(m[1]) * 96000) / 100) : Number(m[1]);
        return out("");
      }
      return out("", 1);
    }
    if (cmd === "ddcutil") {
      if (a === "detect --terse") {
        return out(o.ddc === "noDisplay"
          ? "Invalid display\n   I2C bus:  /dev/i2c-3\n   DRM_connector:           card1-DVI-D-1\n   DDC communication failed\n"
          : "Display 1\n   I2C bus:  /dev/i2c-4\n   DRM_connector:           card1-DVI-D-1\n   Monitor:   ACI:VG248:X\n\nInvalid display\n   I2C bus:  /dev/i2c-7\n");
      }
      if (a === "getvcp 10 --bus 4 --terse") return o.ddc === "ok" || o.ddc === "setFail" ? out(`VCP 10 C ${st.vcp} 100\n`) : out("DDC communication failed for monitor on bus /dev/i2c-4\n", 1);
      const m = /^setvcp 10 (\d+) --bus 4 --noverify$/.exec(a);
      if (m && o.ddc === "ok" && !st.setFails) {
        st.vcp = Number(m[1]);
        return out("");
      }
      return out("DDC communication failed\n", 1);
    }
    if (cmd === "powerprofilesctl") {
      if (a === "get") return out(`${st.profile}\n`);
      if (args[0] === "set") return ((st.profile = args[1]!), out(""));
    }
    if (cmd === "wpctl") {
      if (args[0] === "get-volume") return out(`Volume: ${st.volume}${st.muted ? " [MUTED]" : ""}\n`);
      if (args[0] === "set-volume") return ((st.volume = args[2]!), out(""));
      if (args[0] === "set-mute") return ((st.muted = args[2] === "1"), out(""));
    }
    return out("", 1);
  };
  const io = { exec, which: (c: string) => tools.includes(c), ledsDir: o.ledsDir ?? "/nonexistent-leds" };
  const sets = (cmd: string) => calls.filter((c) => c.cmd === cmd && (c.args.includes("set") || c.args[0] === "setvcp"));
  return { calls, st, io, hw: new Hardware(io), sets };
}

// ---------------------------------------------------------------- pure

describe("sleep phases and curve", () => {
  const s = defaults();
  const t0 = 1_000_000;

  it("settle 3 → fade 30 → night (open); the alarm's sunrise and ring when a plan has one; the scale divides lengths", () => {
    const p = planOf(t0, s);
    expect(p).toMatchObject({ t0, settleMs: 3 * MIN, fadeMs: 30 * MIN, soundFadeMs: 45 * MIN, sunriseAt: null, ringAt: null, rampMs: 3 * MIN, nightSound: "hum", alarmSound: "birds" });
    expect(phasesOf(p)).toEqual([
      { phase: "settle", startedAt: t0, endsAt: t0 + 3 * MIN },
      { phase: "fade", startedAt: t0 + 3 * MIN, endsAt: t0 + 33 * MIN },
      { phase: "night", startedAt: t0 + 33 * MIN, endsAt: null },
    ]);
    expect(phaseAt(p, t0 - 5).phase).toBe("settle"); // a start time just ahead (group, S3)
    expect(phaseAt(p, t0 + 3 * MIN - 1).phase).toBe("settle");
    expect(phaseAt(p, t0 + 3 * MIN).phase).toBe("fade");
    expect(phaseAt(p, t0 + 33 * MIN - 1).phase).toBe("fade");
    expect(phaseAt(p, t0 + 33 * MIN).phase).toBe("night");
    expect(phaseAt(p, t0 + 20 * 60 * MIN)).toEqual({ phase: "night", startedAt: t0 + 33 * MIN, endsAt: null });
    expect(planOf(t0, s, 60)).toMatchObject({ settleMs: 3000, fadeMs: 30_000 });

    const ring = t0 + 8 * 60 * MIN;
    const alarm: SleepPlan = { ...p, sunriseAt: ring - 25 * MIN, ringAt: ring };
    expect(phasesOf(alarm).map((x) => [x.phase, x.startedAt - t0, x.endsAt === null ? null : x.endsAt - t0])).toEqual([
      ["settle", 0, 3 * MIN], ["fade", 3 * MIN, 33 * MIN], ["night", 33 * MIN, 455 * MIN], ["sunrise", 455 * MIN, 480 * MIN], ["ring", 480 * MIN, null],
    ]);
    // An alarm so close that sunrise would begin inside the fade: the fade finishes, then sunrise; no night.
    const soon: SleepPlan = { ...p, sunriseAt: t0 + 10 * MIN, ringAt: t0 + 40 * MIN };
    expect(phasesOf(soon).map((x) => x.phase)).toEqual(["settle", "fade", "sunrise", "ring"]);
    expect(phaseAt(soon, t0 + 34 * MIN)).toEqual({ phase: "sunrise", startedAt: t0 + 33 * MIN, endsAt: t0 + 40 * MIN });
  });

  it("brightness: start in settle, eased out to night over the fade, flat at night, eased in during sunrise", () => {
    const p = planOf(t0, s);
    const b = s.brightness; // 25 → 3, morning 70
    expect(levelAt(p, b, t0 + MIN)).toBe(25);
    expect(levelAt(p, b, t0 + 3 * MIN)).toBe(25);
    const mid = levelAt(p, b, t0 + 18 * MIN); // halfway through the fade
    expect(mid).toBeCloseTo(25 - 22 * 0.75, 6); // ease-out: 3/4 of the way at half time
    expect(mid).toBeLessThan((25 + 3) / 2);
    let prev = Infinity;
    for (let m = 3; m <= 33; m++) {
      const l = levelAt(p, b, t0 + m * MIN);
      expect(l).toBeLessThanOrEqual(prev);
      prev = l;
    }
    expect(levelAt(p, b, t0 + 33 * MIN)).toBe(3);
    expect(levelAt(p, b, t0 + 5 * 60 * MIN)).toBe(3);
    const ring = t0 + 8 * 60 * MIN;
    const alarm: SleepPlan = { ...p, sunriseAt: ring - 25 * MIN, ringAt: ring };
    expect(levelAt(alarm, b, ring - 12.5 * MIN)).toBeCloseTo(3 + 67 * 0.25, 6); // ease-in: a quarter at half time
    expect(levelAt(alarm, b, ring)).toBe(70);
    // night above start (settings in a strange order): never brighter at night than at the start
    expect(levelAt(p, { start: 10, night: 30, morning: 70 }, t0 + 40 * MIN)).toBe(10);
    expect(easeOut(0.5)).toBe(0.75);
    expect(easeIn(0.5)).toBe(0.25);
  });

  it("hardware step never below its floor, rounded up; content = level / hardware, 0..1", () => {
    expect(hardwareFor(3, 1)).toBe(3);
    expect(hardwareFor(2.2, 1)).toBe(3);
    expect(hardwareFor(0, 1)).toBe(1);
    expect(hardwareFor(0.4, 0)).toBe(1);
    expect(hardwareFor(0, 0)).toBe(0);
    expect(hardwareFor(140, 1)).toBe(100);
    expect(contentFor(2.2, 3)).toBe(0.733);
    expect(contentFor(0, 1)).toBe(0);
    expect(contentFor(25, 20)).toBe(1); // hardware behind a rising level: full content
    expect(contentFor(25, null)).toBe(0.25); // no hardware dimming: the page does it all
    expect(contentFor(0, 0)).toBe(0);
    expect(contentFor(5, 0)).toBe(1);
  });
});

describe("sleep hardware parsers", () => {
  it("brightnessctl, ddcutil detect / getvcp, wpctl, LED triggers", () => {
    expect(parseBacklight("intel_backlight,backlight,96000,100%,96000\n")).toEqual({ device: "intel_backlight", raw: 96000, max: 96000 });
    expect(parseBacklight("Failed to read any devices of class 'backlight'.\n")).toBeNull();
    expect(parseBacklight("input24::compose,leds,0,0%,1")).toBeNull(); // brightnessctl -m without a class picks an LED
    expect(parseBacklight("bad dev,backlight,1,1%,10")).toBeNull();
    expect(parseBacklight("x,backlight,20,1%,10")).toBeNull();
    // This PC's monitor today (NVIDIA hardware I²C): an invalid display only.
    expect(parseDetect("Invalid display\n   I2C bus:  /dev/i2c-3\n   DRM_connector:           card1-DVI-D-1\n   EDID synopsis:\n      Model:                VG248\n   DDC communication failed\n")).toEqual([]);
    expect(parseDetect("Display 1\n   I2C bus:  /dev/i2c-3\n   DRM connector:    card1-DVI-D-1\n\nDisplay 2\n   I2C bus:  /dev/i2c-5\n")).toEqual([3, 5]);
    expect(parseVcp("VCP 10 C 50 100\n")).toEqual({ raw: 50, max: 100 });
    expect(parseVcp("VCP 10 C 150 100")).toBeNull();
    expect(parseVcp("DDC communication failed for monitor on bus /dev/i2c-3")).toBeNull();
    expect(parseVolume("Volume: 0.30 [MUTED]\n")).toEqual({ level: 0.3, muted: true });
    expect(parseVolume("Volume: 0.70\n")).toEqual({ level: 0.7, muted: false });
    expect(parseVolume("Volume: 9.00")).toBeNull();
    expect(activeTrigger("none rfkill-any [phy0radio] phy0tpt")).toBe("phy0radio");
    expect(activeTrigger("[none] audio-micmute")).toBe("none");
  });

  it("throttle: at most one apply per gap, only on a change, the latest value wins; a failure stops it", async () => {
    const c = fakeClock();
    const applied: Array<[number, number]> = [];
    let fail = false;
    let failed = 0;
    const t = new Throttle({ gapMs: 2000, apply: async (v) => (applied.push([c.now(), v]), !fail), onFail: () => failed++, now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout }, 50);
    t.want(50);
    await flush();
    expect(applied).toEqual([]); // no change
    const start = c.now();
    for (let v = 40; v > 30; v--) t.want(v);
    await flush();
    for (let i = 0; i < 10; i++) {
      t.want(30 - i);
      await c.advance(300);
    }
    await c.advance(5000);
    expect(applied[0]).toEqual([start, 40]);
    for (let i = 1; i < applied.length; i++) expect(applied[i]![0] - applied[i - 1]![0]).toBeGreaterThanOrEqual(2000);
    expect(applied.at(-1)![1]).toBe(21);
    expect(t.current).toBe(21);
    fail = true;
    t.want(10);
    await c.advance(3000);
    expect(failed).toBe(1);
    t.want(5);
    await c.advance(10_000);
    expect(applied.at(-1)![1]).toBe(10); // stopped after the failure
    expect(c.pending).toBe(0);
  });
});

// ---------------------------------------------------------------- the run

function runDeps(m: ReturnType<typeof fakeMachine>, c: ReturnType<typeof fakeClock>, settings: SleepSettings = defaults()) {
  const files: SleepFile[] = [];
  const sent: Array<Record<string, unknown>> = [];
  const buses: number[] = [];
  return {
    files, sent, buses,
    deps: {
      hw: m.hw,
      settings: () => settings,
      save: async (f: SleepFile) => void files.push(JSON.parse(JSON.stringify(f)) as SleepFile),
      send: (s: string) => void sent.push(JSON.parse(s) as Record<string, unknown>),
      storeBus: async (b: number) => void buses.push(b),
      log: () => {},
      now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout,
    },
  };
}
const session = (t0: number): SleepSession => ({ id: "sess-0001", seed: 42, t0, members: [{ host: "laptop", side: "left", distance: "mid" }], leader: "laptop" });

describe("SleepRun", () => {
  it("laptop: saves the backlight first, follows the curve (≤ 1 call / 2 s, only on change), phases on time, restores exactly", async () => {
    const c = fakeClock();
    const m = fakeMachine({ backlight: true, now: c.now });
    const d = runDeps(m, c);
    const t0 = c.now();
    const run = await SleepRun.begin(d.deps, session(t0), "laptop", 1);
    // The previous value was in the file before the first set.
    const firstSet = m.calls.findIndex((x) => x.args.includes("set"));
    expect(d.files.some((f) => f.saved.backlight?.raw === 48000)).toBe(true);
    expect(firstSet).toBeGreaterThan(m.calls.findIndex((x) => x.args.join(" ") === "-m -c backlight"));
    await flush();
    expect(m.st.raw).toBe(24000); // 25 %
    // Content against the hardware as it is: 25 / 50 until the first step lands, then 1.
    expect(d.sent).toEqual([{ type: "phase", phase: "settle", phaseStartedAt: t0, phaseEndsAt: t0 + 3 * MIN }, { type: "brightness", content: 0.5 }, { type: "brightness", content: 1 }]);
    // Settle: nothing moves.
    const before = m.calls.length;
    await c.advance(3 * MIN - 1);
    expect(m.calls.length).toBe(before);
    await c.advance(1);
    expect(d.sent.find((x) => x.type === "phase" && x.phase === "fade")).toMatchObject({ phaseStartedAt: t0 + 3 * MIN, phaseEndsAt: t0 + 33 * MIN });
    await c.advance(30 * MIN);
    expect(d.sent.filter((x) => x.type === "phase").map((x) => x.phase)).toEqual(["settle", "fade", "night"]);
    const sets = m.sets("brightnessctl");
    for (let i = 1; i < sets.length; i++) expect(sets[i]!.at - sets[i - 1]!.at).toBeGreaterThanOrEqual(BACKLIGHT_GAP_MS);
    const pcts = sets.map((x) => Number(x.args.at(-1)!.replace("%", "")));
    expect(pcts[0]).toBe(25);
    expect(pcts.at(-1)).toBe(3);
    expect(new Set(pcts).size).toBe(pcts.length); // only on a change
    expect(pcts.every((p, i) => i === 0 || p < pcts[i - 1]!)).toBe(true);
    // Content between the steps: always ≤ 1, ends at 1 at night (3 % on the hardware = the level).
    const contents = d.sent.filter((x) => x.type === "brightness").map((x) => x.content as number);
    expect(Math.max(...contents)).toBeLessThanOrEqual(1);
    expect(contents.at(-1)).toBe(1);
    // Night: no tick, no call.
    const atNight = m.calls.length;
    await c.advance(60 * MIN);
    expect(m.calls.length).toBe(atNight);
    expect(run.armed).toBe(false);
    expect(run.status()).toMatchObject({ phase: "night", phaseEndsAt: null, brightness: { dimming: "backlight", hardware: 3, content: 1 }, warning: null });
    await run.stop();
    expect(m.calls.at(-1)!.args).toEqual(["-q", "-d", "intel_backlight", "set", "48000"]);
    expect(m.st.raw).toBe(48000);
    expect(c.pending).toBe(0);
  });

  it("night at 0 %: the backlight stays at its floor, the page goes black; the setting changes live", async () => {
    const c = fakeClock();
    const m = fakeMachine({ backlight: true, now: c.now });
    const s = defaults();
    s.brightness.night = 0;
    const d = runDeps(m, c, s);
    const run = await SleepRun.begin(d.deps, session(c.now()), "laptop", 1);
    await c.advance(40 * MIN);
    expect(run.status().brightness).toMatchObject({ hardware: 1, content: 0 });
    s.brightness.night = 10;
    s.brightness.start = 30;
    run.settingsChanged();
    await c.advance(3000);
    expect(run.status().brightness).toMatchObject({ hardware: 10, content: 1 });
    expect(d.sent.some((x) => x.type === "sleep")).toBe(true);
    await run.stop();
    expect(m.st.raw).toBe(48000);
  });

  it("DDC: bus detected once and stored, getvcp saved, setvcp at most every 15 s, restored; the floor from ddc.min", async () => {
    const c = fakeClock();
    const m = fakeMachine({ ddc: "ok", now: c.now });
    const s = defaults();
    s.ddc.min = 5;
    const d = runDeps(m, c, s);
    const run = await SleepRun.begin(d.deps, session(c.now()), "theloth", 1);
    expect(d.buses).toEqual([4]); // the first valid display, not the invalid one
    expect(m.calls.slice(0, 3).map((x) => `${x.cmd} ${x.args.join(" ")}`)).toEqual(["brightnessctl -m -c backlight", "ddcutil detect --terse", "ddcutil getvcp 10 --bus 4 --terse"]);
    expect(d.files.at(-1)).toMatchObject({ hw: "ddc", saved: { ddc: { bus: 4, raw: 80, max: 100 } } });
    await c.advance(40 * MIN);
    const sets = m.sets("ddcutil");
    expect(sets[0]!.args).toEqual(["setvcp", "10", "25", "--bus", "4", "--noverify"]);
    for (let i = 1; i < sets.length; i++) expect(sets[i]!.at - sets[i - 1]!.at).toBeGreaterThanOrEqual(DDC_GAP_MS);
    expect(m.st.vcp).toBe(5); // night 3 % is below the monitor floor: hardware 5, content 0.6
    expect(run.status().brightness).toMatchObject({ dimming: "ddc", hardware: 5, content: 0.6 });
    const n = m.calls.length;
    await c.advance(120 * MIN);
    expect(m.calls.length).toBe(n); // nothing at night
    await run.stop();
    expect(m.calls.at(-1)!.args).toEqual(["setvcp", "10", "80", "--bus", "4", "--noverify"]);
    expect(m.st.vcp).toBe(80);
    // A configured bus: no detect.
    const m2 = fakeMachine({ ddc: "ok", now: c.now });
    const s2 = defaults();
    s2.ddc.bus = 4;
    const r2 = await SleepRun.begin(runDeps(m2, c, s2).deps, session(c.now()), "theloth", 1);
    expect(m2.calls.some((x) => x.args[0] === "detect")).toBe(false);
    await r2.stop();
  });

  it("DDC unavailable (no display, getvcp fails, no ddcutil): content only + agent.sleep.ddcUnavailable; setvcp failing mid-run too", async () => {
    for (const [ddc, tools] of [["noDisplay", undefined], ["getFail", undefined], ["ok", ["brightnessctl"]]] as const) {
      const c = fakeClock();
      const m = fakeMachine({ ddc, tools: tools ? [...tools] : undefined, now: c.now });
      const d = runDeps(m, c);
      const run = await SleepRun.begin(d.deps, session(c.now()), "theloth", 1);
      await c.advance(18 * MIN);
      expect(m.sets("ddcutil")).toEqual([]);
      expect(run.status()).toMatchObject({ warning: "agent.sleep.ddcUnavailable", brightness: { dimming: "content", hardware: null } });
      expect(run.status().brightness.content).toBeCloseTo((25 - 22 * 0.75) / 100, 2);
      expect(d.files.at(-1)).toMatchObject({ hw: null, saved: { ddc: null } });
      await run.stop();
      expect(m.sets("ddcutil")).toEqual([]);
    }
    const c = fakeClock();
    const m = fakeMachine({ ddc: "ok", now: c.now });
    const run = await SleepRun.begin(runDeps(m, c).deps, session(c.now()), "theloth", 1);
    await c.advance(5 * MIN);
    m.st.setFails = true;
    await c.advance(10 * MIN);
    const tries = m.sets("ddcutil").length;
    expect(run.status()).toMatchObject({ warning: "agent.sleep.ddcUnavailable", brightness: { dimming: "content", hardware: null } });
    // The monitor kept the last value it took: content is measured against it.
    expect(run.status().brightness.content).toBeLessThan(1);
    await c.advance(20 * MIN);
    expect(m.sets("ddcutil").length).toBe(tries);
    m.st.setFails = false;
    await run.stop();
    expect(m.st.vcp).toBe(80); // the restore is still tried
  });

  it("extras: power profile, held volume, plain lit LEDs — saved before, restored after; triggered and lock LEDs untouched", async () => {
    const leds = await mkdtemp(join(tmpdir(), "tiphys-leds-"));
    cleanups.push(() => rm(leds, { recursive: true, force: true }));
    const led = async (name: string, value: number, trigger: string) => {
      await mkdir(join(leds, name));
      await writeFile(join(leds, name, "brightness"), `${value}\n`);
      await writeFile(join(leds, name, "trigger"), trigger);
    };
    await led("platform::lamp", 1, "[none] audio-mute");
    await led("phy0-led", 1, "none [phy0radio]");
    await led("input3::capslock", 1, "[none] kbd-capslock");
    await led("platform::dark", 0, "[none]");
    const c = fakeClock();
    const m = fakeMachine({ backlight: true, now: c.now, ledsDir: leds });
    const s = defaults();
    s.quietPower = true;
    s.holdVolume = 40;
    s.leds = true;
    const d = runDeps(m, c, s);
    const run = await SleepRun.begin(d.deps, session(c.now()), "laptop", 1);
    expect(d.files.at(-1)!.saved).toMatchObject({ power: "balanced", volume: { level: 0.3, muted: true }, leds: [{ name: "platform::lamp", value: 1 }] });
    expect(m.st).toMatchObject({ profile: "power-saver", volume: "0.40", muted: false });
    expect((await readFile(join(leds, "platform::lamp", "brightness"), "utf8")).trim()).toBe("0");
    for (const n of ["phy0-led", "input3::capslock"]) expect((await readFile(join(leds, n, "brightness"), "utf8")).trim()).toBe("1");
    await run.stop();
    expect(m.st).toMatchObject({ profile: "balanced", volume: "0.30", muted: true, raw: 48000 });
    expect((await readFile(join(leds, "platform::lamp", "brightness"), "utf8")).trim()).toBe("1");
    // Defaults: none of it is touched.
    const m2 = fakeMachine({ backlight: true, now: c.now, ledsDir: leds });
    const r2 = await SleepRun.begin(runDeps(m2, c).deps, session(c.now()), "laptop", 1);
    await r2.stop();
    expect(m2.calls.filter((x) => x.cmd !== "brightnessctl")).toEqual([]);
  });

  it("adoption after a restart: no new reads, the saved values stay; the phase is where the clock says; stop restores them", async () => {
    const c = fakeClock();
    const m = fakeMachine({ backlight: true, now: c.now });
    const d = runDeps(m, c);
    const t0 = c.now();
    const first = await SleepRun.begin(d.deps, session(t0), "laptop", 1);
    await c.advance(10 * MIN);
    first.detach();
    expect(c.pending).toBe(0);
    const file = parseSleepFile(JSON.parse(JSON.stringify(d.files.at(-1))))!;
    expect(file).toMatchObject({ session: { id: "sess-0001", t0 }, me: "laptop", hw: "backlight", saved: { backlight: { device: "intel_backlight", raw: 48000 } } });
    await c.advance(30 * MIN); // the agent was down for a while
    const reads = m.calls.filter((x) => x.args.join(" ") === "-m -c backlight").length;
    const d2 = runDeps(m, c);
    const run = SleepRun.adopt(d2.deps, file);
    await flush();
    expect(d2.sent[0]).toMatchObject({ type: "phase", phase: "night", phaseStartedAt: t0 + 33 * MIN });
    expect(m.calls.filter((x) => x.args.join(" ") === "-m -c backlight").length).toBe(reads);
    expect(m.st.raw).toBe(2880); // 3 %
    await run.stop();
    expect(m.st.raw).toBe(48000);
    expect(parseSleepFile({ ...file, session: { ...file.session, leader: "elsewhere" } })).toBeNull();
    expect(parseSleepFile(null)).toBeNull();
  });

  it("preview while running: 5 s at the asked level, then the curve", async () => {
    const c = fakeClock();
    const m = fakeMachine({ backlight: true, now: c.now });
    const run = await SleepRun.begin(runDeps(m, c).deps, session(c.now()), "laptop", 1);
    await c.advance(40 * MIN);
    run.preview(60);
    await c.advance(2500);
    expect(run.status().brightness).toMatchObject({ hardware: 60, preview: 60, content: 1 });
    await c.advance(PREVIEW_MS);
    await c.advance(2500);
    expect(run.status().brightness).toMatchObject({ hardware: 3, preview: null });
    await run.stop();
    expect(m.st.raw).toBe(48000);
  });
});

describe("hardware preview (mode off)", () => {
  it("saves, sets, extends on a new value, restores after 5 s; nothing to dim → 409 agent.sleep.ddcUnavailable", async () => {
    const c = fakeClock();
    const m = fakeMachine({ backlight: true, now: c.now });
    const files: unknown[] = [];
    const p = new HardwarePreview({ hw: m.hw, settings: defaults, save: async (s) => void files.push(s), log: () => {}, now: c.now, setTimeout: c.setTimeout, clearTimeout: c.clearTimeout });
    expect(await p.show(10)).toMatchObject({ dimming: "backlight" });
    expect(files[0]).toMatchObject({ backlight: { raw: 48000 } });
    await flush();
    expect(m.st.raw).toBe(9600);
    await c.advance(3000);
    await p.show(20);
    await c.advance(3000);
    expect(p.active).toBe(true);
    expect(m.st.raw).toBe(19200);
    await c.advance(2100);
    await flush();
    expect(p.active).toBe(false);
    expect(m.st.raw).toBe(48000);
    expect(files.at(-1)).toBeNull();
    const none = new HardwarePreview({ hw: fakeMachine({ ddc: "noDisplay" }).hw, settings: defaults, save: async () => {}, log: () => {} });
    await expect(none.show(10)).rejects.toMatchObject({ code: "agent.sleep.ddcUnavailable", status: 409, params: { reason: "failed" } });
    const bare = new HardwarePreview({ hw: fakeMachine({ tools: [] }).hw, settings: defaults, save: async () => {}, log: () => {} });
    await expect(bare.show(10)).rejects.toMatchObject({ params: { reason: "missing" } });
  });
});

describe("sleep request bodies", () => {
  it("session shape, PUT patch (nested, strict, ranges), merge", () => {
    const ok = { id: "abcdefgh", seed: 1, t0: Date.now(), members: [{ host: "theloth", side: "left", distance: "near" }, { host: "laptop", side: "right" }], leader: "theloth" };
    expect(sessionSchema.parse(ok).members).toEqual([{ host: "theloth", side: "left", distance: "near" }, { host: "laptop", side: "right", distance: "mid" }]);
    // The S2 draft's bare ids: sides by place (first left, last right, others at the foot).
    expect(sessionSchema.parse({ ...ok, members: ["a", "b", "c"], leader: "a" }).members.map((m) => m.side)).toEqual(["left", "foot", "right"]);
    for (const bad of [{ ...ok, members: [{ host: "theloth", side: "up" }] }, { ...ok, members: [{ host: "theloth", side: "left", x: 1 }] }, { ...ok, members: [{ host: "theloth", side: "left" }, { host: "theloth", side: "right" }] }]) {
      expect(sessionSchema.safeParse(bad).success).toBe(false);
    }
    for (const bad of [{ ...ok, id: "short" }, { ...ok, leader: "x" }, { ...ok, members: [] }, { ...ok, members: ["a", "a"], leader: "a" }, { ...ok, t0: Date.now() - 13 * 60 * MIN },
      { ...ok, t0: Date.now() + 11 * MIN }, { ...ok, seed: -1 }, { ...ok, extra: 1 }, { ...ok, members: ["bad host"], leader: "bad host" }]) {
      expect(sessionSchema.safeParse(bad).success).toBe(false);
    }
    expect(sleepPutSchema.safeParse({ settings: { brightness: { night: 5 } } }).success).toBe(true);
    expect(sleepPutSchema.safeParse({ settings: { brightness: { night: 31 } } }).success).toBe(false);
    expect(sleepPutSchema.safeParse({ settings: { brightness: { nope: 1 } } }).success).toBe(false);
    expect(sleepPutSchema.safeParse({ settings: { times: { fadeMin: 9 } } }).success).toBe(false);
    expect(sleepPutSchema.safeParse({ settings: { alarm: { time: "24:00" } } }).success).toBe(false);
    expect(sleepPutSchema.safeParse({ settings: { group: { members: ["a"], leader: "b" } } }).success).toBe(false);
    const cur = defaults();
    const next = mergeSettings(cur, sleepPutSchema.parse({ settings: { brightness: { night: 5 }, alarm: { days: [1, 3] }, group: { members: ["a", "b"], leader: "a" } } }).settings);
    expect(next.brightness).toEqual({ start: 25, night: 5, morning: 70 });
    expect(next.alarm).toMatchObject({ days: [1, 3], time: "07:00" });
    expect(next.group).toEqual({ members: ["a", "b"], leader: "a" });
    expect(mergeSettings(next, { group: null }).group).toBeNull();
    expect(sleepScale(undefined)).toBe(1);
    expect(sleepScale("60")).toBe(60);
    expect(sleepScale("0.5")).toBe(1);
    expect(sleepScale("abc")).toBe(1);
  });
});

// ---------------------------------------------------------------- routes on a fake display

async function sleepApp(o: { runtime?: string; restarting?: () => boolean; active?: () => boolean; backlight?: boolean; tools?: string[]; placement?: "fullscreen" | "scratch" } = {}) {
  const runtime = o.runtime ?? (await mkdtemp(join(tmpdir(), "tiphys-sleep-run-")));
  const m = fakeMachine({ backlight: o.backlight ?? true, tools: o.tools ?? ["brightnessctl", "firefox", "systemd-run"] });
  const calls: HwCall[] = m.calls;
  const exec = async (cmd: string, args: string[]): Promise<ExecResult> => {
    if (cmd === "brightnessctl" || cmd === "ddcutil") return m.io.exec(cmd, args);
    calls.push({ cmd, args, at: Date.now() });
    const ok = (stdout = "") => ({ stdout, stderr: "", code: 0 });
    if (cmd === "hyprctl") {
      const a = args.join(" ");
      if (a === "eval return 1") return ok("eval is only supported with the lua config manager");
      if (a === "-j activeworkspace") return ok(JSON.stringify({ id: 3, name: "3" }));
      if (a === "-j monitors") return ok(JSON.stringify([{ activeWorkspace: { name: "uyku" }, specialWorkspace: { name: "" }, dpmsStatus: true }]));
      return ok("ok");
    }
    if (cmd === "systemctl" && args[1] === "is-active") return ok((o.active?.() ?? true) ? "active\n" : "inactive\n");
    return ok("");
  };
  const io: DisplayIo = {
    exec,
    runtimeDir: runtime,
    hyprEnv: async () => ({ XDG_RUNTIME_DIR: runtime, HYPRLAND_INSTANCE_SIGNATURE: "sig" }),
    waylandEnv: async () => ({ WAYLAND_DISPLAY: "wayland-1", XDG_RUNTIME_DIR: runtime }),
    busEnv: () => ({}),
    which: (c) => (o.tools ?? ["brightnessctl", "firefox", "systemd-run"]).includes(c),
    connect: () => {
      throw new Error("no sources in sleep");
    },
    fetch,
    ...(o.restarting ? { restarting: async () => o.restarting!() } : {}),
  };
  const t = await testApp(
    (c) => ((c.screen.placement = o.placement ?? "fullscreen"), c),
    [async (a, ctx) => void (await displayRoutes(a, ctx, { io, displayDir: null, mapDir: runtime, watchMs: 60_000, power: { dir: join(runtime, "none") }, sleep: { scale: 1000, ledsDir: join(runtime, "no-leds") } }))],
  );
  const closed = { done: false };
  cleanups.push(() => (closed.done ? undefined : t.app.close()));
  await t.app.ready();
  const req = (method: "GET" | "PUT" | "POST", url: string, payload?: object) => t.app.inject({ method, url, headers: t.auth, ...(payload ? { payload } : {}) });
  const page = async () => {
    const html = await readFile(join(runtime, "tiphys-screen", "start.html"), "utf8");
    const token = /#t=([a-f0-9]{64})/.exec(html)![1]!;
    const got: Array<Record<string, unknown>> = [];
    const ws = await t.app.injectWS(`/v1/screen/live?t=${token}`, {}, { onInit: (w) => w.on("message", (d: Buffer) => got.push(JSON.parse(d.toString()) as Record<string, unknown>)) });
    return { ws, got };
  };
  const read = async () => (await readFile(join(t.dir, "events.jsonl"), "utf8").catch(() => "")).trim().split("\n").filter(Boolean).map((l) => (JSON.parse(l) as { key: string }).key);
  /** The event keys once `n` are written (records are written in the background). */
  const events = async (n: number) => {
    const end = Date.now() + 3000;
    let k = await read();
    while (k.length < n && Date.now() < end) {
      await new Promise((r) => setTimeout(r, 10));
      k = await read();
    }
    await new Promise((r) => setTimeout(r, 30));
    return read();
  };
  const hypr = () => calls.filter((c) => c.cmd === "hyprctl").map((c) => c.args.join(" "));
  return { ...t, runtime, m, req, page, events, hypr, close: async () => ((closed.done = true), await t.app.close()) };
}

describe("sleep routes", () => {
  it("start (one host, session made here) → phases advance → stop: backlight exact, files gone, only sleep.* events", async () => {
    const t = await sleepApp({ placement: "scratch" }); // sleep is fullscreen anyway
    const g = (await t.req("GET", "/v1/sleep")).json();
    expect(g).toMatchObject({ running: false, session: null, phase: null, members: [{ host: "test", state: "off" }], settings: { side: "left", brightness: { start: 25, night: 3, morning: 70 }, group: null }, scale: 1000 });
    const s = await t.req("POST", "/v1/sleep/start", {});
    expect(s.statusCode).toBe(200);
    expect(s.json()).toMatchObject({ running: true, phase: "settle", session: { members: [{ host: "test", side: "left", distance: "mid" }], leader: "test" }, brightness: { dimming: "backlight" }, warning: null });
    expect((await t.req("GET", "/v1/screen")).json()).toMatchObject({ running: true, mode: "sleep", placement: "fullscreen", sources: [{ name: "self", state: "off", topics: [] }] });
    expect(t.hypr()).toContain("keyword windowrule[tiphys-screen]:workspace name:uyku");
    expect(t.hypr().some((a) => a.includes("bind"))).toBe(false);
    const file = JSON.parse(await readFile(join(t.runtime, "tiphys-screen", "sleep.json"), "utf8")) as SleepFile;
    expect(file.saved.backlight).toEqual({ device: "intel_backlight", raw: 48000 });
    expect((await stat(join(t.runtime, "tiphys-screen", "sleep.json"))).mode & 0o777).toBe(0o600);
    const p = await t.page();
    await until(() => p.got.some((x) => x.type === "sleep"));
    expect(p.got[0]).toMatchObject({ type: "layout", mode: "sleep", template: "sleep", cards: [] });
    expect(p.got.find((x) => x.type === "sleep")).toMatchObject({ session: { seed: expect.any(Number), layout: [{ id: "test", side: "left", distance: "mid" }] }, me: "test", offsetMs: 0, plan: { settleMs: 180, fadeMs: 1800 } });
    p.ws.send(JSON.stringify({ type: "heartbeat" }));
    await until(() => p.got.some((x) => x.type === "phase" && x.phase === "night"));
    expect((await t.req("GET", "/v1/sleep")).json()).toMatchObject({ phase: "night", page: { heartbeatAt: expect.any(Number) } });
    await until(() => t.m.st.raw === 2880);
    // A layout mode can't be switched to while sleeping.
    expect((await t.req("POST", "/v1/screen/mode", { mode: "work" })).json()).toMatchObject({ error: { code: "agent.sleep.running" } });
    expect((await t.req("POST", "/v1/screen/start", { mode: "focus" })).statusCode).toBe(409);
    expect((await t.req("POST", "/v1/sleep/start", {})).json()).toMatchObject({ running: true, session: { id: file.session.id } }); // idempotent
    const stop = await t.req("POST", "/v1/sleep/stop");
    expect(stop.json()).toMatchObject({ running: false });
    expect(t.m.st.raw).toBe(48000);
    expect(t.m.calls.filter((c) => c.cmd === "brightnessctl").at(-1)!.args).toEqual(["-q", "-d", "intel_backlight", "set", "48000"]);
    expect(existsSync(join(t.runtime, "tiphys-screen"))).toBe(false);
    expect(t.hypr()).toContain("keyword windowrule[tiphys-screen]:enable false");
    expect(await t.events(2)).toEqual(["sleep.started", "sleep.stopped"]);
    expect((await t.req("POST", "/v1/sleep/stop")).json()).toMatchObject({ running: false }); // nothing running: fine
  });

  it("validation: bad sessions 400, not a member / no source to the leader 409 agent.sleep.noGroup; PUT merges and refuses unknown keys", async () => {
    const t = await sleepApp();
    const base = { id: "abcdefgh12", seed: 7, t0: Date.now(), members: ["test"], leader: "test" };
    for (const bad of [{ ...base, id: "x" }, { ...base, leader: "other" }, { ...base, t0: 5 }, { ...base, extra: true }]) {
      expect((await t.req("POST", "/v1/sleep/start", { session: bad })).statusCode).toBe(400);
    }
    expect((await t.req("POST", "/v1/sleep/start", { session: { ...base, members: ["theloth", "laptop"], leader: "theloth" } })).json()).toMatchObject({ error: { code: "agent.sleep.noGroup", params: { reason: "notMember", host: "test" } } });
    expect((await t.req("POST", "/v1/sleep/start", { session: { ...base, members: ["theloth", "test"], leader: "theloth" } })).json()).toMatchObject({ error: { code: "agent.sleep.noGroup", params: { reason: "noLeaderSource", leader: "theloth" } } });
    expect((await t.req("GET", "/v1/screen")).json().running).toBe(false);
    const put = await t.req("PUT", "/v1/sleep", { settings: { brightness: { night: 6 }, side: "right", times: { fadeMin: 45 } } });
    expect(put.statusCode).toBe(200);
    expect(put.json().settings).toMatchObject({ side: "right", brightness: { start: 25, night: 6, morning: 70 }, times: { settleMin: 3, fadeMin: 45 } });
    expect(t.store.get().screen.modes.sleep.brightness.night).toBe(6);
    expect((await t.req("PUT", "/v1/sleep", { settings: { brightness: { dim: 1 } } })).statusCode).toBe(400);
    expect((await t.req("PUT", "/v1/sleep", { settings: { volume: 101 } })).statusCode).toBe(400);
    expect((await t.req("PUT", "/v1/sleep", {})).statusCode).toBe(400);
    // The phone's session with this host alone.
    const s = await t.req("POST", "/v1/sleep/start", { session: base });
    expect(s.json()).toMatchObject({ running: true, session: { ...base, members: [{ host: "test", side: "left", distance: "mid" }] }, group: null });
    // A live setting change reaches the page.
    const p = await t.page();
    await until(() => p.got.some((x) => x.type === "sleep"));
    await t.req("PUT", "/v1/sleep", { settings: { volume: 20 } });
    await until(() => p.got.some((x) => x.type === "sleep" && (x.settings as { volume: number }).volume === 20));
    await t.req("POST", "/v1/screen/stop"); // the generic stop ends sleep too
    expect(t.m.st.raw).toBe(48000);
    expect(await t.events(2)).toEqual(["sleep.started", "sleep.stopped"]);
  });

  it("sleep replaces a running layout mode (stopped with its own event first)", async () => {
    const t = await sleepApp();
    await t.req("POST", "/v1/screen/start", { mode: "focus" });
    await t.req("POST", "/v1/sleep/start", {});
    expect((await t.req("GET", "/v1/screen")).json()).toMatchObject({ mode: "sleep" });
    await t.req("POST", "/v1/sleep/stop");
    expect(await t.events(4)).toEqual(["screen.started", "screen.stopped", "sleep.started", "sleep.stopped"]);
    expect(t.store.get().screen.lastMode).toBe("focus");
  });

  it("preview: on the running sleep; with the mode off on the hardware alone; no hardware → 409 agent.sleep.ddcUnavailable", async () => {
    const t = await sleepApp();
    const off = await t.req("POST", "/v1/sleep/preview", { brightness: 40 });
    expect(off.json()).toMatchObject({ running: false, preview: { dimming: "backlight" } });
    await until(() => t.m.st.raw === 38400);
    expect(existsSync(join(t.runtime, "tiphys-sleep-preview.json"))).toBe(true);
    expect((await t.req("POST", "/v1/sleep/preview", { brightness: 101 })).statusCode).toBe(400);
    // Starting the mode ends the preview first (its saved value back, then the mode saves the same one).
    await t.req("POST", "/v1/sleep/start", {});
    expect(existsSync(join(t.runtime, "tiphys-sleep-preview.json"))).toBe(false);
    const f = JSON.parse(await readFile(join(t.runtime, "tiphys-screen", "sleep.json"), "utf8")) as SleepFile;
    expect(f.saved.backlight!.raw).toBe(48000);
    expect((await t.req("POST", "/v1/sleep/preview", { brightness: 80 })).json()).toMatchObject({ running: true, brightness: { preview: 80 } });
    await t.req("POST", "/v1/sleep/stop");
    expect(t.m.st.raw).toBe(48000);
    const bare = await sleepApp({ backlight: false, tools: ["firefox", "systemd-run"] });
    expect((await bare.req("POST", "/v1/sleep/preview", { brightness: 40 })).json()).toMatchObject({ error: { code: "agent.sleep.ddcUnavailable", params: { reason: "missing" } } });
    // Without hardware the mode still runs: the page dims alone.
    expect((await bare.req("POST", "/v1/sleep/start", {})).json()).toMatchObject({ running: true, warning: "agent.sleep.ddcUnavailable", brightness: { dimming: "content" } });
    await bare.req("POST", "/v1/sleep/stop");
  });

  it("agent restart: adopted (same session, no new read), stop restores the original value", async () => {
    const t = await sleepApp({ restarting: () => true });
    const s = (await t.req("POST", "/v1/sleep/start", {})).json();
    await until(() => t.m.st.raw < 24000); // into the fade
    await t.close();
    expect(t.m.st.raw).not.toBe(48000); // left as it was for the next agent
    expect(existsSync(join(t.runtime, "tiphys-screen", "sleep.json"))).toBe(true);
    const t2 = await sleepApp({ runtime: t.runtime });
    t2.m.st.raw = t.m.st.raw; // same hardware
    await until(() => true);
    let g: Record<string, unknown> = {};
    for (let i = 0; i < 100 && !g.running; i++) {
      g = (await t2.req("GET", "/v1/sleep")).json();
      await new Promise((r) => setTimeout(r, 10));
    }
    expect(g).toMatchObject({ running: true, session: { id: s.session.id } });
    expect(t2.m.calls.some((c) => c.args.join(" ") === "-m -c backlight")).toBe(false);
    await t2.req("POST", "/v1/sleep/stop");
    expect(t2.m.st.raw).toBe(48000);
    expect(await t2.events(1)).toEqual(["sleep.stopped"]);
  });

  it("crash with the kiosk gone: the next agent restores the hardware from sleep.json and leaves nothing", async () => {
    const t = await sleepApp({ restarting: () => true });
    await t.req("POST", "/v1/sleep/start", {});
    await until(() => t.m.st.raw < 24000);
    await t.close();
    const t2 = await sleepApp({ runtime: t.runtime, active: () => false });
    t2.m.st.raw = 1234;
    await until(() => !existsSync(join(t.runtime, "tiphys-screen")));
    await until(() => t2.m.st.raw === 48000);
    expect(await t2.events(1)).toEqual(["sleep.stopped"]);
    expect((await t2.req("GET", "/v1/sleep")).json().running).toBe(false);
  });
});
