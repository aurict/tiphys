// macOS implementations of the server features (P3): system, processes, ports, services (launchd). Loaded only on
// macOS (routes import it lazily). Parsers are pure and tested with recorded command outputs on every OS.
import { open, stat } from "node:fs/promises";
import { cpus, hostname, release, totalmem, uptime } from "node:os";
import { basename } from "node:path";
import { run } from "../exec.ts";
import { AppError } from "../errors.ts";
import type { Listen } from "../routes/ports.ts";
import type { Proc } from "../routes/processes.ts";
import type { LogEntry, Unit } from "../routes/services.ts";
import type { Gpu, SystemSnapshot } from "../routes/system.ts";
import { cpuLoadPercent, mergeListens } from "./common.ts";

// ---- system --------------------------------------------------------------------------------------------------------

/** `sw_vers` → "macOS 15.1". */
export function parseSwVers(out: string): string {
  const get = (k: string) => new RegExp(`^${k}:\\s*(.+)$`, "m").exec(out)?.[1]?.trim() ?? "";
  return `${get("ProductName") || "macOS"} ${get("ProductVersion")}`.trim();
}

/** `vm_stat` → used memory in bytes (what Activity Monitor calls Memory Used: app + wired + compressed). */
export function parseVmStat(out: string): number | null {
  const pageSize = Number(/page size of (\d+) bytes/.exec(out)?.[1] ?? NaN);
  if (!Number.isFinite(pageSize)) return null;
  const pages = (label: string) => {
    const m = new RegExp(`^"?${label}"?:\\s+(\\d+)`, "m").exec(out);
    return m ? Number(m[1]) : null;
  };
  const wired = pages("Pages wired down") ?? 0;
  const compressed = pages("Pages occupied by compressor") ?? 0;
  const anonymous = pages("Anonymous pages");
  const app = anonymous !== null ? anonymous - (pages("Pages purgeable") ?? 0) : (pages("Pages active") ?? 0);
  return (Math.max(0, app) + wired + compressed) * pageSize;
}

const UNIT: Record<string, number> = { K: 1024, M: 1024 ** 2, G: 1024 ** 3, T: 1024 ** 4 };

/** `sysctl -n vm.swapusage` → "total = 2048.00M  used = 1059.25M  free = 988.75M  (encrypted)". */
export function parseSwapUsage(out: string): { totalBytes: number; usedBytes: number } {
  const val = (k: string) => {
    const m = new RegExp(`${k} = ([\\d.]+)([KMGT])`).exec(out);
    return m ? Math.round(Number(m[1]) * UNIT[m[2]!]!) : 0;
  };
  return { totalBytes: val("total"), usedBytes: val("used") };
}

/** `df -k` (macOS adds inode columns; POSIX output without them and 512-byte blocks are parsed too). Mount points may contain spaces. */
export function parseDf(out: string): Array<{ filesystem: string; mount: string; totalBytes: number; usedBytes: number }> {
  const lines = out.split("\n");
  const unit = /(\d+)-blocks/.exec(lines[0] ?? "")?.[1];
  const block = unit ? Number(unit) : 1024;
  const rows = [];
  for (const line of lines.slice(1)) {
    const m = /^(.+?)\s+(\d+)\s+(\d+)\s+(\d+)\s+\d+%\s+(?:\d+\s+\d+\s+(?:\d+%|-)\s+)?(\/.*)$/.exec(line.trimEnd());
    if (!m) continue;
    rows.push({ filesystem: m[1]!, mount: m[5]!, totalBytes: Number(m[2]) * block, usedBytes: Number(m[3]) * block });
  }
  return rows;
}

/** `mount` → mount point → file system type ("/dev/disk3s5 on /System/Volumes/Data (apfs, local, …)"). */
export function parseMount(out: string): Map<string, string> {
  const types = new Map<string, string>();
  for (const line of out.split("\n")) {
    const m = /^.+? on (.+) \(([^,)]+)[,)]/.exec(line);
    if (m) types.set(m[1]!, m[2]!.trim());
  }
  return types;
}

/** Real disks: /, the Data volume and anything under /Volumes; the other APFS system volumes are hidden. */
export function darwinDisks(df: string, mount: string): SystemSnapshot["disks"] {
  const types = parseMount(mount);
  return parseDf(df)
    .filter((d) => d.totalBytes > 0 && d.filesystem.startsWith("/dev/"))
    .filter((d) => d.mount === "/System/Volumes/Data" || !d.mount.startsWith("/System/Volumes/"))
    .map((d) => ({ mount: d.mount, fs: types.get(d.mount) ?? "", totalBytes: d.totalBytes, usedBytes: d.usedBytes }));
}

let osName: string | null = null;

export async function systemSnapshot(gpus: () => Promise<Gpu[]>): Promise<SystemSnapshot> {
  const text = (cmd: string, args: string[]) => run(cmd, args, { allowFail: true, timeoutMs: 5000 }).then((r) => r.stdout, () => "");
  const [load, vm, swap, df, mount, os, gpuList] = await Promise.all([
    cpuLoadPercent(),
    text("vm_stat", []),
    text("sysctl", ["-n", "vm.swapusage"]),
    text("df", ["-k"]),
    text("mount", []),
    osName ? Promise.resolve(osName) : text("sw_vers", []).then((o) => (osName = parseSwVers(o))),
    gpus(),
  ]);
  const s = parseSwapUsage(swap);
  return {
    hostname: hostname(),
    os,
    kernel: release(),
    uptimeSeconds: Math.round(uptime()),
    // CPU temperature needs root (powermetrics) on macOS: not reported.
    cpu: { loadPercent: load, cores: cpus().length, temperatureC: null },
    memory: { totalBytes: totalmem(), usedBytes: parseVmStat(vm) ?? 0, swapTotalBytes: s.totalBytes, swapUsedBytes: s.usedBytes },
    disks: darwinDisks(df, mount),
    gpus: gpuList,
  };
}

// ---- processes -----------------------------------------------------------------------------------------------------

/** ps etime "[[dd-]hh:]mm:ss" → seconds. */
export function parseEtime(s: string): number {
  const m = /^(?:(\d+)-)?(?:(\d+):)?(\d+):(\d+)$/.exec(s.trim());
  if (!m) return 0;
  return Number(m[1] ?? 0) * 86400 + Number(m[2] ?? 0) * 3600 + Number(m[3]) * 60 + Number(m[4]);
}

/**
 * `ps -axo pid=,ppid=,user=,%cpu=,%mem=,rss=,etime=,args=` plus `ps -axo pid=,comm=` (macOS `comm` is the full
 * executable path and may contain spaces, so it comes from a second call where it is the only free-text column).
 */
export function parsePsDarwin(out: string, commOut: string): Proc[] {
  const comm = new Map<number, string>();
  for (const line of commOut.split("\n")) {
    const m = /^\s*(\d+)\s+(.+)$/.exec(line);
    if (m) comm.set(Number(m[1]), m[2]!.trim());
  }
  return out
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => {
      const f = l.split(/\s+/);
      const [pid, ppid, user, cpu, mem, rss, etime] = f;
      const command = f.slice(7).join(" ");
      const exe = comm.get(Number(pid)) ?? f[7] ?? "";
      return {
        pid: Number(pid),
        ppid: Number(ppid),
        user: user ?? "",
        cpuPercent: Number(cpu),
        memPercent: Number(mem),
        rssBytes: Number(rss) * 1024,
        elapsedSeconds: parseEtime(etime ?? ""),
        name: basename(exe),
        command: command.slice(0, 500),
      };
    })
    .filter((p) => Number.isFinite(p.pid));
}

export async function listProcesses(): Promise<Proc[]> {
  const [main, comm] = await Promise.all([
    run("ps", ["-axo", "pid=,ppid=,user=,%cpu=,%mem=,rss=,etime=,args="]),
    run("ps", ["-axo", "pid=,comm="]),
  ]);
  return parsePsDarwin(main.stdout, comm.stdout);
}

// ---- ports ---------------------------------------------------------------------------------------------------------

/** `netstat -an -p tcp` LISTEN rows ("tcp4 0 0 127.0.0.1.7443 *.* LISTEN"; address and port joined by a dot). */
export function parseNetstat(out: string): Array<{ port: number; address: string; process: null; pid: null }> {
  const rows = [];
  for (const line of out.split("\n")) {
    const f = line.trim().split(/\s+/);
    if (!f[0]?.startsWith("tcp") || f.at(-1) !== "LISTEN" || f.length < 6) continue;
    const local = f[3]!;
    const i = local.lastIndexOf(".");
    const port = Number(local.slice(i + 1));
    const raw = local.slice(0, i).replace(/%.*$/, "");
    rows.push({ port, address: raw === "*" ? (f[0] === "tcp4" ? "0.0.0.0" : "::") : raw, process: null, pid: null });
  }
  return rows;
}

/** `lsof -nP -iTCP -sTCP:LISTEN -Fpcn`: p<pid>, c<command>, n<address:port> records. */
export function parseLsof(out: string): Array<{ port: number; address: string; process: string | null; pid: number | null }> {
  const rows = [];
  let pid: number | null = null;
  let cmd: string | null = null;
  for (const line of out.split("\n")) {
    const tag = line[0];
    const v = line.slice(1);
    if (tag === "p") {
      pid = Number(v);
      cmd = null;
    } else if (tag === "c") cmd = v;
    else if (tag === "n") {
      const i = v.lastIndexOf(":");
      const raw = v.slice(0, i).replace(/^\[|\]$/g, "").replace(/%.*$/, "");
      rows.push({ port: Number(v.slice(i + 1)), address: raw === "*" ? "0.0.0.0" : raw, process: cmd, pid });
    }
  }
  return rows;
}

/** netstat sees every listening socket; lsof adds the process (for the agent's own user's processes only). */
export function mergeDarwinPorts(netstat: string, lsof: string): Listen[] {
  const procs = parseLsof(lsof);
  const byPort = new Map(procs.map((p) => [p.port, p] as const));
  const rows = parseNetstat(netstat).map((r) => ({ ...r, process: byPort.get(r.port)?.process ?? null, pid: byPort.get(r.port)?.pid ?? null }));
  return mergeListens([...rows, ...procs]);
}

export async function listeningPorts(): Promise<Listen[]> {
  const [ns, ls] = await Promise.all([
    run("netstat", ["-an", "-p", "tcp"], { allowFail: true }),
    run("lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpcn"], { allowFail: true, timeoutMs: 10000 }).catch(() => ({ stdout: "" })),
  ]);
  return mergeDarwinPorts(ns.stdout, ls.stdout);
}

// ---- services (launchd) --------------------------------------------------------------------------------------------

function unitOf(label: string, pid: number, status: number | null): Unit {
  const running = pid > 0;
  const failed = !running && status !== null && status > 0;
  return {
    unit: label,
    load: "loaded",
    active: running ? "active" : failed ? "failed" : "inactive",
    sub: running ? "running" : failed ? "failed" : "dead",
    description: "",
  };
}

/** `launchctl list`: "PID\tStatus\tLabel" rows; PID "-" when not running. */
export function parseLaunchctlList(out: string): Unit[] {
  const units: Unit[] = [];
  for (const line of out.split("\n").slice(1)) {
    const [pid, status, label] = line.split("\t");
    if (!label?.trim()) continue;
    units.push(unitOf(label.trim(), pid === "-" ? 0 : Number(pid), status === "-" ? null : Number(status)));
  }
  return units.sort((a, b) => a.unit.localeCompare(b.unit));
}

/** `launchctl print system`: the "services = { PID LAST-EXIT LABEL }" block (PID 0 = not running). */
export function parseLaunchctlPrint(out: string): Unit[] {
  const units: Unit[] = [];
  let inside = false;
  for (const line of out.split("\n")) {
    if (/^\s*services = \{/.test(line)) inside = true;
    else if (inside && /^\s*\}/.test(line)) break;
    else if (inside) {
      const m = /^\s*(\d+)\s+(-|-?\d+)\s+(\S.*)$/.exec(line);
      if (m) units.push(unitOf(m[3]!.trim(), Number(m[1]), m[2] === "-" ? null : Number(m[2])));
    }
  }
  return units.sort((a, b) => a.unit.localeCompare(b.unit));
}

/** `launchctl print <domain>/<label>` → its stdout/stderr log files (StandardOutPath/StandardErrorPath). */
export function parseLogPaths(out: string): string[] {
  const paths = new Set<string>();
  for (const m of out.matchAll(/^\s*(?:stdout|stderr) path = (\/.+)$/gm)) paths.add(m[1]!.trim());
  return [...paths];
}

const domain = (scope: "user" | "system") => (scope === "user" ? `gui/${process.getuid?.() ?? 0}` : "system");

export function launchctlArgs(scope: "user" | "system", unit: string, action: "start" | "stop" | "restart"): string[] {
  const target = `${domain(scope)}/${unit}`;
  if (action === "start") return ["kickstart", target];
  if (action === "restart") return ["kickstart", "-k", target];
  return ["kill", "SIGTERM", target];
}

export async function listServices(scope: "user" | "system"): Promise<Unit[]> {
  if (scope === "user") return parseLaunchctlList((await run("launchctl", ["list"])).stdout);
  return parseLaunchctlPrint((await run("launchctl", ["print", "system"], { timeoutMs: 20000 })).stdout);
}

export async function serviceAction(scope: "user" | "system", unit: string, action: "start" | "stop" | "restart"): Promise<void> {
  const res = await run("launchctl", launchctlArgs(scope, unit, action), { allowFail: true, timeoutMs: 60000 });
  if (res.code === 0) return;
  const msg = (res.stderr || res.stdout).slice(0, 1000);
  const denied = /operation not permitted|not privileged|permission denied/i.test(msg);
  throw new AppError(denied ? "agent.services.permissionDenied" : "agent.services.actionFailed", denied ? 403 : 502, { unit, action, stderr: msg });
}

/** Last `lines` lines of a file (reads at most the last 1 MB). */
async function tail(path: string, lines: number): Promise<string[]> {
  const st = await stat(path);
  if (!st.isFile()) return [];
  const len = Math.min(st.size, 1024 * 1024);
  const fh = await open(path, "r");
  try {
    const buf = Buffer.alloc(len);
    await fh.read(buf, 0, len, st.size - len);
    return buf.toString("utf8").split("\n").filter(Boolean).slice(-lines);
  } finally {
    await fh.close();
  }
}

/** launchd keeps no journal: the lines come from the job's own log files; there are no timestamps (timeUs 0). */
export async function serviceLogs(scope: "user" | "system", unit: string, lines: number): Promise<LogEntry[]> {
  const res = await run("launchctl", ["print", `${domain(scope)}/${unit}`], { allowFail: true, timeoutMs: 20000 });
  if (res.code !== 0) throw new AppError("agent.services.notFound", 404, { unit });
  const paths = parseLogPaths(res.stdout);
  if (!paths.length) throw new AppError("agent.services.logsUnavailable", 404, { unit });
  const out: LogEntry[] = [];
  for (const p of paths) {
    for (const message of await tail(p, lines).catch(() => [])) out.push({ timeUs: 0, priority: 6, message });
  }
  return out.slice(-lines);
}
