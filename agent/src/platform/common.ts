// Helpers shared by the macOS and Windows implementations (never loaded on Linux).
import { existsSync } from "node:fs";
import { cpus, homedir } from "node:os";
import { delimiter, join } from "node:path";
import type { Listen } from "../routes/ports.ts";

export interface CpuTimes {
  idle: number;
  total: number;
  at: number;
}

export function cpuTimes(list = cpus(), at = Date.now()): CpuTimes {
  let idle = 0;
  let total = 0;
  for (const { times: t } of list) {
    idle += t.idle;
    total += t.user + t.nice + t.sys + t.idle + t.irq;
  }
  return { idle, total, at };
}

/** Busy share of all cores between two samples, in percent with one decimal. */
export function loadBetween(a: CpuTimes, b: CpuTimes): number {
  const dt = b.total - a.total;
  if (dt <= 0) return 0;
  return Math.round(Math.max(0, Math.min(1, 1 - (b.idle - a.idle) / dt)) * 1000) / 10;
}

let last: CpuTimes | null = null;

/** CPU load from os.cpus(): since the previous call if it was 0.2–10 s ago, else over a fresh 250 ms window. */
export async function cpuLoadPercent(): Promise<number> {
  let prev = last;
  const age = prev ? Date.now() - prev.at : Infinity;
  if (!prev || age < 200 || age > 10_000) {
    prev = cpuTimes();
    await new Promise((r) => setTimeout(r, 250));
  }
  last = cpuTimes();
  return loadBetween(prev, last);
}

/** Same merge as parseSs (Linux): one entry per port; public if any of its addresses is not loopback. */
export function mergeListens(entries: Array<{ port: number; address: string; process: string | null; pid: number | null }>): Listen[] {
  const byPort = new Map<number, Listen>();
  for (const e of entries) {
    if (!Number.isInteger(e.port) || e.port <= 0) continue;
    const loopback = e.address === "127.0.0.1" || e.address === "::1" || e.address.startsWith("127.");
    const prev = byPort.get(e.port);
    if (prev) {
      prev.localOnly &&= loopback;
      if (prev.process === null && e.process !== null) {
        prev.process = e.process;
        prev.pid = e.pid;
      }
      continue;
    }
    byPort.set(e.port, { port: e.port, address: e.address, process: e.process, pid: e.pid, localOnly: loopback });
  }
  return [...byPort.values()].sort((a, b) => a.port - b.port);
}

/** `cmd` if it is on PATH, else the first existing fallback path, else `cmd` (the call then reports it missing). */
export function findTool(cmd: string, fallbacks: string[], pathVar = process.env.PATH ?? "", exists: (p: string) => boolean = existsSync): string {
  const exts = process.platform === "win32" ? [".exe", ".cmd", ""] : [""];
  if (pathVar.split(delimiter).some((d) => d && exts.some((e) => exists(join(d, cmd + e))))) return cmd;
  return fallbacks.find((p) => exists(p)) ?? cmd;
}

/** Docker Desktop's CLI locations, for agents started with a short PATH (launchd agents get /usr/bin:/bin:…). */
export function dockerFallbacks(platform: NodeJS.Platform = process.platform, home = homedir(), env: NodeJS.ProcessEnv = process.env): string[] {
  if (platform === "darwin") {
    return ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", join(home, ".docker", "bin", "docker"), "/Applications/Docker.app/Contents/Resources/bin/docker"];
  }
  if (platform === "win32") return [join(env.ProgramFiles ?? "C:\\Program Files", "Docker", "Docker", "resources", "bin", "docker.exe")];
  return [];
}

let docker: string | null = null;
export function dockerBin(): string {
  return (docker ??= findTool("docker", dockerFallbacks()));
}
