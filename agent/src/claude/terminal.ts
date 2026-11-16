// Claude Code sessions running in a terminal (outside Tiphys).
// Claude Code writes <config folder>/sessions/<pid>.json for each live session. The file may not be deleted on
// exit; so whether the process is still alive and is the same process (the pid may have been reused) is verified
// with the start time in /proc/<pid>/stat (procStart).
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

export interface TerminalSession {
  pid: number;
  sdkSessionId: string;
  cwd: string | null;
  name: string | null;
  /** Status reported by Claude Code: busy | idle | … */
  status: string | null;
  startedAt: string | null;
  updatedAt: string | null;
}

/** /proc/<pid>/stat → start time (field 22). null if there is no process. */
export async function procStart(procRoot: string, pid: number): Promise<string | null> {
  try {
    const stat = await readFile(join(procRoot, String(pid), "stat"), "utf8");
    // Field 2 (command name) may contain spaces/parentheses: count from after the last ')'.
    const rest = stat.slice(stat.lastIndexOf(")") + 2).split(" ");
    return rest[19] ?? null; // rest[0] = 3. alan → 22. alan = rest[19]
  } catch {
    return null;
  }
}

const iso = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? new Date(v).toISOString() : null);
const str = (v: unknown) => (typeof v === "string" && v.length > 0 ? v : null);

export async function terminalSessions(configDir: string, procRoot = "/proc"): Promise<TerminalSession[]> {
  const dir = join(configDir, "sessions");
  let names: string[];
  try {
    names = await readdir(dir);
  } catch {
    return [];
  }
  const out: TerminalSession[] = [];
  for (const n of names.filter((n) => /^\d+\.json$/.test(n))) {
    let j: Record<string, unknown>;
    try {
      j = JSON.parse(await readFile(join(dir, n), "utf8")) as Record<string, unknown>;
    } catch {
      continue; // read while being written, or corrupt: skip this round
    }
    const pid = Number(j.pid);
    const sessionId = str(j.sessionId);
    if (!Number.isInteger(pid) || pid <= 0 || !sessionId) continue;
    const started = await procStart(procRoot, pid);
    if (started === null) continue; // no process
    if (j.procStart !== undefined && String(j.procStart) !== started) continue; // pid moved to another process
    out.push({
      pid,
      sdkSessionId: sessionId,
      cwd: str(j.cwd),
      name: str(j.name),
      status: str(j.status),
      startedAt: iso(j.startedAt),
      updatedAt: iso(j.updatedAt),
    });
  }
  return out.sort((a, b) => (b.updatedAt ?? "").localeCompare(a.updatedAt ?? ""));
}

/**
 * Closes the terminal session (SIGTERM: Claude Code already writes the transcript to disk on every message) and waits
 * for the process to really exit. Returns false if the timeout expires; SIGKILL is not used.
 */
export async function stopTerminalSession(pid: number, procRoot = "/proc", timeoutMs = 8000): Promise<boolean> {
  const start = await procStart(procRoot, pid);
  if (start === null) return true;
  try {
    process.kill(pid, "SIGTERM");
  } catch {
    return (await procStart(procRoot, pid)) !== start;
  }
  const end = Date.now() + timeoutMs;
  while (Date.now() < end) {
    await new Promise((r) => setTimeout(r, 100));
    if ((await procStart(procRoot, pid)) !== start) return true;
  }
  return false;
}
