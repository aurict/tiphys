// `system` topic (PLAN.md §20 A-2): CPU, memory, CPU temperature, battery and GPU of this host, every 2 s, without
// starting a process per sample: /proc/stat, /proc/meminfo, one hwmon sensor (picked once at start), the first
// battery in /sys/class/power_supply. GPU: NVIDIA through ONE long-lived `nvidia-smi … -lms 2000` child (killed on
// stop, retried after 30 s if it dies); Intel through the GT idle residency in /sys/class/drm (busy = 1 − Δidle/Δt);
// neither → gpu null (the card hides the GPU ring). A sample that differs from the last sent one by less than the
// thresholds below is not sent.
import { spawn } from "node:child_process";
import type { Readable } from "node:stream";
import { whichIn } from "../../detect.ts";
import { realFileIo, type FileIo, type Rec, type StateProducer } from "./common.ts";

export interface GpuSample {
  util: number;
  temp: number | null;
  memUsed: number | null;
  memTotal: number | null;
}

export interface SystemSample {
  cpu: number;
  cores: number;
  mem: { used: number; total: number };
  temp: number | null;
  gpu: GpuSample | null;
  battery: { level: number; charging: boolean } | null;
}

export interface SmiChild {
  stdout: Readable | null;
  exitCode: number | null;
  signalCode: NodeJS.Signals | null;
  kill(signal?: NodeJS.Signals): boolean;
  on(ev: "exit", fn: () => void): unknown;
  on(ev: "error", fn: (e: Error) => void): unknown;
}

export interface SystemIo extends FileIo {
  has(cmd: string): boolean;
  spawn(cmd: string, args: string[]): SmiChild;
  now(): number;
}

export const realSystemIo: SystemIo = {
  ...realFileIo,
  has: (cmd) => whichIn(process.env.PATH, cmd),
  spawn: (cmd, args) => spawn(cmd, args, { stdio: ["ignore", "pipe", "ignore"] }),
  now: () => Date.now(),
};

export const SMI_ARGS = ["--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total", "--format=csv,noheader,nounits", "-lms", "2000"];

/** /proc/stat → total and idle jiffies of the "cpu" line, and the core count. */
export function parseProcStat(text: string): { total: number; idle: number; cores: number } | null {
  const lines = text.split("\n");
  const f = lines[0]?.split(/\s+/);
  if (!f || f[0] !== "cpu") return null;
  const v = f.slice(1, 9).map(Number);
  if (v.length < 4 || v.some((x) => !Number.isFinite(x))) return null;
  const total = v.reduce((a, b) => a + b, 0);
  const idle = v[3]! + (v[4] ?? 0); // idle + iowait
  return { total, idle, cores: lines.filter((l) => /^cpu\d+ /.test(l)).length };
}

/** /proc/meminfo → used/total bytes (used = total − available). */
export function parseMeminfo(text: string): { used: number; total: number } | null {
  const kb = (k: string) => {
    const m = new RegExp(`^${k}:\\s+(\\d+)`, "m").exec(text);
    return m ? Number(m[1]) * 1024 : null;
  };
  const total = kb("MemTotal");
  const avail = kb("MemAvailable");
  if (total === null || avail === null) return null;
  return { used: total - avail, total };
}

/** One nvidia-smi CSV line (util %, temp °C, used MiB, total MiB) → GPU sample (memory in bytes). */
export function parseSmiLine(line: string): GpuSample | null {
  const [u, t, mu, mt] = line.split(",").map((s) => Number(s.trim()));
  if (!Number.isFinite(u)) return null;
  const ok = (n: number | undefined) => (n !== undefined && Number.isFinite(n) ? n : null);
  const mib = (n: number | undefined) => (ok(n) === null ? null : n! * 1024 * 1024);
  return { util: Math.min(1, Math.max(0, u! / 100)), temp: ok(t), memUsed: mib(mu), memTotal: mib(mt) };
}

/** hwmon sensor names, CPU first. */
const CPU_SENSORS = ["k10temp", "coretemp", "zenpower", "cpu_thermal", "acpitz"];
const CPU_LABELS = /^(Tctl|Tdie|Package id 0|CPU)$/;

/** The CPU temperature file: the preferred sensor's labelled input (Tctl, Package id 0, …), else its temp1. */
export function findCpuTemp(io: FileIo, root = "/sys/class/hwmon"): string | null {
  const found: Array<{ rank: number; file: string }> = [];
  for (const h of io.list(root)) {
    const dir = `${root}/${h}`;
    const rank = CPU_SENSORS.indexOf((io.read(`${dir}/name`) ?? "").trim());
    if (rank < 0) continue;
    const inputs = io.list(dir).filter((f) => /^temp\d+_input$/.test(f)).sort();
    const labelled = inputs.find((f) => CPU_LABELS.test((io.read(`${dir}/${f.replace("_input", "_label")}`) ?? "").trim()));
    const file = labelled ?? inputs[0];
    if (file) found.push({ rank, file: `${dir}/${file}` });
  }
  return found.sort((a, b) => a.rank - b.rank)[0]?.file ?? null;
}

/**
 * Where batteries are looked up. TIPHYS_SCREEN_POWER_DIR (test only, unset by default; docs/agent/configuration.md)
 * points it at a directory of fake power_supply entries, to try the battery saver without unplugging anything.
 */
export const powerSupplyDir = () => (process.env.TIPHYS_SCREEN_POWER_DIR?.startsWith("/") ? process.env.TIPHYS_SCREEN_POWER_DIR : "/sys/class/power_supply");

/** The first system battery (type Battery, not a device's: mouse, headset). */
export function findBattery(io: FileIo, root = powerSupplyDir()): string | null {
  for (const n of io.list(root).sort()) {
    const dir = `${root}/${n}`;
    if ((io.read(`${dir}/type`) ?? "").trim() !== "Battery") continue;
    if ((io.read(`${dir}/scope`) ?? "").trim() === "Device") continue;
    if (io.read(`${dir}/capacity`) !== null) return dir;
  }
  return null;
}

/** A battery directory → level (0..100) and whether it is on mains ("Discharging" or no status = on battery). */
export function readBattery(io: FileIo, dir: string): SystemSample["battery"] {
  const raw = io.read(`${dir}/capacity`);
  const level = raw === null ? NaN : Number(raw);
  if (!Number.isFinite(level)) return null;
  const status = (io.read(`${dir}/status`) ?? "").trim();
  return { level: Math.max(0, Math.min(100, level)), charging: status !== "Discharging" && status !== "" };
}

/** Intel GT idle residency counter (ms): i915 (gt/gt0 or the older power/) or xe. */
export function findIntelIdle(io: FileIo, root = "/sys/class/drm"): string | null {
  for (const c of io.list(root).filter((n) => /^card\d+$/.test(n)).sort()) {
    for (const rel of ["gt/gt0/rc6_residency_ms", "power/rc6_residency_ms", "device/tile0/gt0/gtidle/idle_residency_ms"]) {
      const f = `${root}/${c}/${rel}`;
      if (io.read(f) !== null) return f;
    }
  }
  return null;
}

/** Thresholds below which a new sample isn't worth a message. */
export function changed(a: SystemSample | null, b: SystemSample): boolean {
  if (!a) return true;
  const far = (x: number | null | undefined, y: number | null | undefined, d: number) => (x == null) !== (y == null) || (x != null && y != null && Math.abs(x - y) >= d);
  if (far(a.cpu, b.cpu, 0.02) || far(a.mem.used, b.mem.used, b.mem.total * 0.005) || far(a.temp, b.temp, 1)) return true;
  if ((a.gpu === null) !== (b.gpu === null)) return true;
  if (a.gpu && b.gpu && (far(a.gpu.util, b.gpu.util, 0.02) || far(a.gpu.temp, b.gpu.temp, 1) || far(a.gpu.memUsed, b.gpu.memUsed, (b.gpu.memTotal ?? 0) * 0.01))) return true;
  return a.battery?.level !== b.battery?.level || a.battery?.charging !== b.battery?.charging || a.cores !== b.cores;
}

const round = (n: number, k = 1000) => Math.round(n * k) / k;

export class SystemProducer implements StateProducer {
  readonly #io: SystemIo;
  readonly #o: { intervalMs: number; smiRetryMs: number; killGraceMs: number };
  #emit: ((m: Rec) => void) | null = null;
  #timer: NodeJS.Timeout | null = null;
  #retry: NodeJS.Timeout | null = null;
  #child: SmiChild | null = null;
  #tempFile: string | null = null;
  #battery: string | null = null;
  #intel: string | null = null;
  #prevCpu: { total: number; idle: number } | null = null;
  #prevIdle: { at: number; ms: number } | null = null;
  #smi: GpuSample | null = null;
  #sent: SystemSample | null = null;

  constructor(io: SystemIo = realSystemIo, o: { intervalMs?: number; smiRetryMs?: number; killGraceMs?: number } = {}) {
    this.#io = io;
    this.#o = { intervalMs: o.intervalMs ?? 2000, smiRetryMs: o.smiRetryMs ?? 30_000, killGraceMs: o.killGraceMs ?? 1000 };
  }

  get active() {
    return this.#timer !== null || this.#retry !== null || this.#child !== null;
  }

  /** The nvidia-smi child (tests). */
  get child() {
    return this.#child;
  }

  start(emit: (m: Rec) => void) {
    if (this.#emit) return;
    this.#emit = emit;
    this.#tempFile = findCpuTemp(this.#io);
    this.#battery = findBattery(this.#io);
    if (this.#io.has("nvidia-smi")) this.#spawnSmi();
    else this.#intel = findIntelIdle(this.#io);
    this.#tick();
    this.#timer = setInterval(() => this.#tick(), this.#o.intervalMs);
    this.#timer.unref?.();
  }

  async stop() {
    this.#emit = null;
    if (this.#timer) clearInterval(this.#timer);
    if (this.#retry) clearTimeout(this.#retry);
    this.#timer = this.#retry = null;
    const c = this.#child;
    this.#child = null;
    this.#prevCpu = this.#prevIdle = this.#smi = this.#sent = null;
    if (c) await killChild(c, this.#o.killGraceMs);
  }

  #spawnSmi() {
    let c: SmiChild;
    try {
      c = this.#io.spawn("nvidia-smi", SMI_ARGS);
    } catch {
      return;
    }
    this.#child = c;
    let buf = "";
    c.stdout?.on("data", (b: Buffer) => {
      buf += b.toString();
      const lines = buf.split("\n");
      buf = lines.pop()!.slice(-1000);
      // One line per GPU per sample: the first GPU is shown.
      for (const l of lines) {
        const g = parseSmiLine(l);
        if (g) this.#smi = g;
      }
    });
    c.on("error", () => {});
    c.on("exit", () => {
      if (this.#child !== c) return; // stopped by us
      this.#child = null;
      this.#smi = null;
      if (!this.#emit) return;
      this.#retry = setTimeout(() => {
        this.#retry = null;
        if (this.#emit) this.#spawnSmi();
      }, this.#o.smiRetryMs);
      this.#retry.unref?.();
    });
  }

  /** One sample (null until the first CPU delta exists). */
  sample(): SystemSample | null {
    const io = this.#io;
    const st = parseProcStat(io.read("/proc/stat") ?? "");
    const mem = parseMeminfo(io.read("/proc/meminfo") ?? "");
    if (!st || !mem) return null;
    const prev = this.#prevCpu;
    this.#prevCpu = st;
    if (!prev || st.total <= prev.total) return null;
    const cpu = 1 - (st.idle - prev.idle) / (st.total - prev.total);
    const t = this.#tempFile ? Number(io.read(this.#tempFile)) : NaN;
    const battery = this.#battery ? readBattery(io, this.#battery) : null;
    return {
      cpu: round(Math.max(0, Math.min(1, cpu))),
      cores: st.cores,
      mem,
      temp: Number.isFinite(t) && t > 0 ? Math.round(t / 100) / 10 : null,
      gpu: this.#smi ?? this.#intelGpu(),
      battery,
    };
  }

  #intelGpu(): GpuSample | null {
    if (!this.#intel) return null;
    const ms = Number(this.#io.read(this.#intel));
    const at = this.#io.now();
    if (!Number.isFinite(ms)) return null;
    const prev = this.#prevIdle;
    this.#prevIdle = { at, ms };
    if (!prev || at <= prev.at) return null;
    return { util: round(Math.max(0, Math.min(1, 1 - (ms - prev.ms) / (at - prev.at)))), temp: null, memUsed: null, memTotal: null };
  }

  #tick() {
    const s = this.sample();
    if (!s || !this.#emit || !changed(this.#sent, s)) return;
    this.#sent = s;
    this.#emit({ type: "system", ...s });
  }
}

export async function killChild(c: SmiChild, graceMs: number) {
  if (c.exitCode !== null || c.signalCode !== null) return;
  const exited = new Promise<void>((r) => c.on("exit", () => r()));
  c.kill("SIGTERM");
  const t = setTimeout(() => c.kill("SIGKILL"), graceMs);
  await exited;
  clearTimeout(t);
}
