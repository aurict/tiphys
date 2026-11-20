// Windows implementations of the server features (P3): system, processes, ports, services, process termination.
// Loaded only on Windows (routes import it lazily). Data comes from one PowerShell call per request (CIM / NetTCPIP
// cmdlets) as JSON; the parsers are pure and tested with recorded outputs on every OS.
import { cpus, hostname, release, totalmem, uptime } from "node:os";
import { run } from "../exec.ts";
import { AppError } from "../errors.ts";
import type { Listen } from "../routes/ports.ts";
import type { Proc } from "../routes/processes.ts";
import type { Unit } from "../routes/services.ts";
import type { Gpu, SystemSnapshot } from "../routes/system.ts";
import { cpuLoadPercent, mergeListens } from "./common.ts";

/**
 * Runs a PowerShell script without profile or prompts. -EncodedCommand (UTF-16LE base64) avoids every command-line
 * quoting problem; scripts only interpolate values validated beforehand.
 */
export function powershellArgs(script: string): string[] {
  const full = `$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; ${script}`;
  return ["-NoProfile", "-NonInteractive", "-EncodedCommand", Buffer.from(full, "utf16le").toString("base64")];
}

export async function powershell(script: string, timeoutMs = 30000): Promise<string> {
  return (await run("powershell.exe", powershellArgs(script), { timeoutMs })).stdout;
}

/** ConvertTo-Json gives an object for one item, an array for several and nothing for none. */
export function jsonList<T>(out: string): T[] {
  const t = out.replace(/^﻿/, "").trim();
  if (!t) return [];
  const v = JSON.parse(t) as T | T[];
  return Array.isArray(v) ? v : [v];
}

const num = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) ? v : Number(v) || 0);

// ---- system --------------------------------------------------------------------------------------------------------

export const SYSTEM_SCRIPT = `$o = Get-CimInstance Win32_OperatingSystem
$d = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { [pscustomobject]@{ id = $_.DeviceID; fs = $_.FileSystem; size = $_.Size; free = $_.FreeSpace } })
[pscustomobject]@{ caption = $o.Caption; totalKb = $o.TotalVisibleMemorySize; freeKb = $o.FreePhysicalMemory; pageTotalKb = $o.SizeStoredInPagingFiles; pageFreeKb = $o.FreeSpaceInPagingFiles; disks = $d } | ConvertTo-Json -Compress -Depth 4`;

interface WinDisk {
  id?: string;
  fs?: string | null;
  size?: number | null;
  free?: number | null;
}

interface WinSystem {
  caption?: string;
  totalKb?: number;
  freeKb?: number;
  pageTotalKb?: number;
  pageFreeKb?: number;
  disks?: WinDisk[] | WinDisk;
}

export function parseWinSystem(out: string): Pick<SystemSnapshot, "os" | "memory" | "disks"> {
  const s = (jsonList<WinSystem>(out)[0] ?? {}) as WinSystem;
  const total = num(s.totalKb) * 1024;
  const pageTotal = num(s.pageTotalKb) * 1024;
  const disks = Array.isArray(s.disks) ? s.disks : s.disks ? [s.disks] : [];
  return {
    os: (s.caption ?? "Windows").trim(),
    memory: {
      totalBytes: total || totalmem(),
      usedBytes: Math.max(0, total - num(s.freeKb) * 1024),
      swapTotalBytes: pageTotal,
      swapUsedBytes: Math.max(0, pageTotal - num(s.pageFreeKb) * 1024),
    },
    disks: disks
      .filter((d) => num(d.size) > 0)
      .map((d) => ({ mount: `${d.id ?? ""}\\`, fs: d.fs ?? "", totalBytes: num(d.size), usedBytes: num(d.size) - num(d.free) })),
  };
}

export async function systemSnapshot(gpus: () => Promise<Gpu[]>): Promise<SystemSnapshot> {
  const [load, info, gpuList] = await Promise.all([cpuLoadPercent(), powershell(SYSTEM_SCRIPT), gpus()]);
  return {
    hostname: hostname(),
    ...parseWinSystem(info),
    kernel: release(),
    uptimeSeconds: Math.round(uptime()),
    // Temperatures need administrator rights and ACPI support on Windows: not reported.
    cpu: { loadPercent: load, cores: cpus().length, temperatureC: null },
    gpus: gpuList,
  };
}

// ---- processes -----------------------------------------------------------------------------------------------------

export const PROCESS_SCRIPT = `$cpu = @{}
Get-CimInstance Win32_PerfFormattedData_PerfProc_Process | ForEach-Object { $cpu[[int]$_.IDProcess] = [double]$_.PercentProcessorTime }
$now = Get-Date
@(Get-CimInstance Win32_Process | ForEach-Object {
  [pscustomobject]@{ pid = [int]$_.ProcessId; ppid = [int]$_.ParentProcessId; name = $_.Name; cmd = $_.CommandLine; ws = [int64]$_.WorkingSetSize; age = $(if ($_.CreationDate) { [int64]($now - $_.CreationDate).TotalSeconds } else { 0 }); cpu = $cpu[[int]$_.ProcessId] }
}) | ConvertTo-Json -Compress`;

interface WinProc {
  pid: number;
  ppid?: number;
  name?: string | null;
  cmd?: string | null;
  ws?: number;
  age?: number;
  cpu?: number | null;
}

/** Win32_Process + per-process CPU (perf counters, % of one core like ps). The owner is not read (slow): user "". */
export function parseWinProcesses(out: string, totalBytes = totalmem()): Proc[] {
  return jsonList<WinProc>(out)
    .filter((p) => Number.isInteger(p.pid) && p.pid > 0)
    .map((p) => ({
      pid: p.pid,
      ppid: num(p.ppid),
      user: "",
      cpuPercent: num(p.cpu),
      memPercent: totalBytes > 0 ? Math.round((num(p.ws) / totalBytes) * 1000) / 10 : 0,
      rssBytes: num(p.ws),
      elapsedSeconds: num(p.age),
      name: p.name ?? "",
      command: (p.cmd || p.name || "").slice(0, 500),
    }));
}

export async function listProcesses(): Promise<Proc[]> {
  return parseWinProcesses(await powershell(PROCESS_SCRIPT));
}

export function taskkillArgs(pid: number, signal: "TERM" | "KILL"): string[] {
  return ["/PID", String(pid), ...(signal === "KILL" ? ["/F"] : [])];
}

/** TERM: taskkill (asks the window to close); KILL: forced. Errors map to the same codes as on Linux. */
export async function signalProcess(pid: number, signal: "TERM" | "KILL"): Promise<void> {
  const exists = () => {
    try {
      process.kill(pid, 0);
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      if (code === "ESRCH") throw new AppError("agent.processes.notFound", 404, { pid });
      if (code === "EPERM") throw new AppError("agent.processes.permissionDenied", 403, { pid });
    }
  };
  exists();
  const r = await run("taskkill.exe", taskkillArgs(pid, signal), { allowFail: true, timeoutMs: 15000 });
  if (r.code === 0) return;
  exists();
  // Still there and taskkill failed: access denied (exit 1) or a console process that has no window to close.
  if (/access is denied/i.test(r.stderr)) throw new AppError("agent.processes.permissionDenied", 403, { pid });
  throw new AppError("agent.processes.signalFailed", 502, { pid, signal, stderr: (r.stderr || r.stdout).slice(0, 1000) });
}

// ---- ports ---------------------------------------------------------------------------------------------------------

export const PORTS_SCRIPT = `$names = @{}
Get-Process | ForEach-Object { $names[[int]$_.Id] = $_.ProcessName }
@(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ address = $_.LocalAddress; port = [int]$_.LocalPort; pid = [int]$_.OwningProcess; name = $names[[int]$_.OwningProcess] } }) | ConvertTo-Json -Compress`;

export function parseWinPorts(out: string): Listen[] {
  return mergeListens(
    jsonList<{ address?: string; port?: number; pid?: number; name?: string | null }>(out).map((r) => ({
      port: num(r.port),
      address: (r.address ?? "").replace(/%.*$/, ""),
      process: r.name ?? null,
      pid: r.pid ? r.pid : null,
    })),
  );
}

export async function listeningPorts(): Promise<Listen[]> {
  return parseWinPorts(await powershell(PORTS_SCRIPT));
}

// ---- services ------------------------------------------------------------------------------------------------------

export const SERVICES_SCRIPT = `@(Get-Service -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ name = $_.Name; display = $_.DisplayName; status = [string]$_.Status; start = [string]$_.StartType } }) | ConvertTo-Json -Compress`;

// ServiceControllerStatus values (PowerShell 5.1 can serialize the enum as a number).
const STATUS: Record<number, string> = { 1: "Stopped", 2: "StartPending", 3: "StopPending", 4: "Running", 5: "ContinuePending", 6: "PausePending", 7: "Paused" };
const ACTIVE: Record<string, string> = { Running: "active", StartPending: "activating", ContinuePending: "activating", StopPending: "deactivating" };

export function parseWinServices(out: string): Unit[] {
  return jsonList<{ name?: string; display?: string | null; status?: string | number; start?: string | number }>(out)
    .filter((s) => typeof s.name === "string" && s.name)
    .map((s) => {
      const status = typeof s.status === "number" ? (STATUS[s.status] ?? String(s.status)) : (s.status ?? "");
      return {
        unit: s.name!,
        load: String(s.start) === "Disabled" || s.start === 4 ? "disabled" : "loaded",
        active: ACTIVE[status] ?? "inactive",
        sub: status.toLowerCase(),
        description: s.display ?? "",
      };
    })
    .sort((a, b) => a.unit.localeCompare(b.unit));
}

export async function listServices(_scope: "user" | "system"): Promise<Unit[]> {
  return parseWinServices(await powershell(SERVICES_SCRIPT));
}

const CMDLET = { start: "Start-Service", stop: "Stop-Service", restart: "Restart-Service" } as const;

/** The unit name is validated by the route (letters, digits, @._:-), so it can't break out of the quotes. */
export function serviceActionScript(unit: string, action: "start" | "stop" | "restart"): string {
  if (!/^[A-Za-z0-9@._:-]+$/.test(unit)) throw new AppError("agent.request.invalid", 400, { unit });
  return `try { ${CMDLET[action]} -Name '${unit}' -ErrorAction Stop; '{"ok":true}' } catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; [pscustomobject]@{ ok = $false; native = $e.NativeErrorCode; message = $_.Exception.Message } | ConvertTo-Json -Compress }`;
}

/** Win32 error 5 (ERROR_ACCESS_DENIED) is locale independent, unlike the message. */
export function parseServiceAction(out: string, unit: string, action: string): void {
  const r = jsonList<{ ok?: boolean; native?: number | null; message?: string }>(out)[0];
  if (r?.ok === true) return;
  const denied = r?.native === 5;
  throw new AppError(denied ? "agent.services.permissionDenied" : "agent.services.actionFailed", denied ? 403 : 502, {
    unit,
    action,
    stderr: (r?.message ?? out).slice(0, 1000),
  });
}

export async function serviceAction(_scope: "user" | "system", unit: string, action: "start" | "stop" | "restart"): Promise<void> {
  parseServiceAction(await powershell(serviceActionScript(unit, action), 90000), unit, action);
}
