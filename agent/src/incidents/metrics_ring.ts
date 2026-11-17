// In-memory metrics ring for incident context (PLAN.md §13.1): host CPU/load/memory/swap/disk every 30 s and
// per-container docker stats every 60 s, the last 2 hours only. Prometheus comes later (I-4).
import { loadavg } from "node:os";
import si from "systeminformation";
import { run } from "../exec.ts";
import type { ContainerSample, HostSample } from "./types.ts";

export const KEEP_MS = 2 * 3600_000;
const HOST_EVERY_MS = 30_000;
const DOCKER_EVERY_MS = 60_000;

const pct = (s: string | undefined) => Number.parseFloat((s ?? "").replace("%", "")) || 0;

/** "12.5MiB / 1.944GiB" → bytes of the first value. */
export function parseBytes(s: string | undefined): number {
  const m = /^\s*([\d.]+)\s*([KMGT]?i?B)/i.exec(s ?? "");
  if (!m) return 0;
  const unit = m[2]!.toUpperCase();
  const pow = { B: 0, KB: 1, KIB: 1, MB: 2, MIB: 2, GB: 3, GIB: 3, TB: 4, TIB: 4 }[unit] ?? 0;
  const base = unit.includes("I") ? 1024 : 1000;
  return Math.round(Number.parseFloat(m[1]!) * base ** pow);
}

export class MetricsRing {
  host: HostSample[] = [];
  containers = new Map<string, ContainerSample[]>();
  #timers: NodeJS.Timeout[] = [];
  #now: () => number;

  constructor(now: () => number = Date.now) {
    this.#now = now;
  }

  start(docker: boolean) {
    const host = () => void this.sampleHost().catch(() => {});
    host();
    this.#timers.push(setInterval(host, HOST_EVERY_MS));
    if (docker) {
      const d = () => void this.sampleDocker().catch(() => {});
      d();
      this.#timers.push(setInterval(d, DOCKER_EVERY_MS));
    }
    for (const t of this.#timers) t.unref();
  }

  stop() {
    for (const t of this.#timers) clearInterval(t);
    this.#timers = [];
  }

  addHost(s: HostSample) {
    this.host.push(s);
    this.#trim();
  }

  addContainer(name: string, s: ContainerSample) {
    const arr = this.containers.get(name) ?? [];
    arr.push(s);
    this.containers.set(name, arr);
    this.#trim();
  }

  async sampleHost() {
    const [load, mem, fs] = await Promise.all([si.currentLoad(), si.mem(), si.fsSize().catch(() => [])]);
    this.addHost({
      t: this.#now(),
      cpu: Math.round(load.currentLoad * 10) / 10,
      load1: Math.round((loadavg()[0] ?? 0) * 100) / 100,
      memPct: mem.total ? Math.round((mem.active / mem.total) * 1000) / 10 : 0,
      swapPct: mem.swaptotal ? Math.round((mem.swapused / mem.swaptotal) * 1000) / 10 : 0,
      disks: fs
        .filter((d) => d.size > 0 && !d.mount.startsWith("/snap") && !d.mount.startsWith("/boot"))
        .map((d) => ({ mount: d.mount, pct: Math.round((d.used / d.size) * 1000) / 10 })),
    });
  }

  async sampleDocker() {
    const r = await run("docker", ["stats", "--no-stream", "--format", "{{json .}}"], { timeoutMs: 30_000, allowFail: true });
    const t = this.#now();
    for (const line of r.stdout.split("\n")) {
      if (!line.trim()) continue;
      try {
        const s = JSON.parse(line) as Record<string, string>;
        if (!s.Name) continue;
        this.addContainer(s.Name, { t, cpu: pct(s.CPUPerc), memPct: pct(s.MemPerc), memBytes: parseBytes(s.MemUsage) });
      } catch {
        /* a malformed line is skipped */
      }
    }
  }

  /** Samples in [from, to]. */
  window(from: number, to: number, container?: string) {
    const inRange = <T extends { t: number }>(a: T[]) => a.filter((s) => s.t >= from && s.t <= to);
    return {
      host: inRange(this.host),
      ...(container && this.containers.has(container) ? { container: { name: container, samples: inRange(this.containers.get(container)!) } } : {}),
    };
  }

  #trim() {
    const cutoff = this.#now() - KEEP_MS;
    while (this.host.length && this.host[0]!.t < cutoff) this.host.shift();
    for (const [name, arr] of this.containers) {
      while (arr.length && arr[0]!.t < cutoff) arr.shift();
      if (!arr.length) this.containers.delete(name);
    }
  }
}
