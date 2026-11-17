// Child process helper for the research tools (agy, claude): PATH lookup at call time, an allowlisted environment,
// its own process group (so MCP servers it starts die with it) and SIGTERM → SIGKILL on timeout/cancel.
import { spawn } from "node:child_process";
import { access, constants } from "node:fs/promises";
import { delimiter, join } from "node:path";
import { AppError } from "../errors.ts";

const MAX_STDOUT = 20 * 1024 * 1024;
const MAX_STDERR = 64 * 1024;

/** Resolves an executable from the current PATH; null if missing. */
export async function which(name: string): Promise<string | null> {
  for (const dir of (process.env.PATH ?? "").split(delimiter)) {
    if (!dir) continue;
    const p = join(dir, name);
    if (await access(p, constants.X_OK).then(() => true, () => false)) return p;
  }
  return null;
}

/** Variables passed to the research tools; everything else in the agent's environment (secrets, tokens) is dropped. */
const ENV_ALLOW = new Set([
  "HOME", "PATH", "LANG", "LANGUAGE", "USER", "LOGNAME", "TERM", "TZ",
  "XDG_RUNTIME_DIR", "XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME", "XDG_STATE_HOME",
  "NODE_EXTRA_CA_CERTS",
]);

export function childEnv(): NodeJS.ProcessEnv {
  return Object.fromEntries(Object.entries(process.env).filter(([k]) => ENV_ALLOW.has(k) || k.startsWith("LC_")));
}

function killGroup(pid: number | undefined, sig: NodeJS.Signals) {
  if (!pid) return;
  try {
    process.kill(-pid, sig);
  } catch {
    // ESRCH: the group is already gone
  }
}

export interface RunResult {
  stdout: string;
  stderr: string;
  code: number | null;
  signal: NodeJS.Signals | null;
}

export interface RunOpts {
  cwd: string;
  /** Aborting kills the process group; the step then rejects with signal.reason. */
  signal: AbortSignal;
  timeoutMs: number;
  killGraceMs: number;
}

export async function runTool(tool: string, args: string[], o: RunOpts): Promise<RunResult> {
  const path = await which(tool);
  if (!path) throw new AppError("agent.research.toolMissing", 500, { tool });
  o.signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const child = spawn(path, args, { cwd: o.cwd, env: childEnv(), detached: true, stdio: ["ignore", "pipe", "pipe"] });
    const out: Buffer[] = [];
    let outLen = 0;
    let err = "";
    let failure: unknown = null;
    const kill = (why: unknown) => {
      if (failure) return;
      failure = why;
      killGroup(child.pid, "SIGTERM");
      // Not cleared on close: group members that ignore SIGTERM are still killed after the grace period.
      setTimeout(() => killGroup(child.pid, "SIGKILL"), o.killGraceMs).unref();
    };
    const timer = setTimeout(() => kill(new AppError("agent.research.timeout", 500, { tool })), o.timeoutMs);
    const onAbort = () => kill(o.signal.reason);
    o.signal.addEventListener("abort", onAbort, { once: true });
    child.stdout.on("data", (b: Buffer) => {
      if (outLen < MAX_STDOUT) out.push(b);
      outLen += b.length;
    });
    child.stderr.on("data", (b: Buffer) => {
      err = (err + b.toString("utf8")).slice(-MAX_STDERR);
    });
    // Leftovers in the group (e.g. MCP servers) are stopped once the tool itself has exited.
    child.on("exit", () => killGroup(child.pid, "SIGTERM"));
    const done = () => {
      clearTimeout(timer);
      o.signal.removeEventListener("abort", onAbort);
    };
    child.on("error", (e) => {
      done();
      reject(failure ?? new AppError("agent.research.toolFailed", 500, { tool, reason: (e as NodeJS.ErrnoException).code ?? "spawn" }));
    });
    child.on("close", (code, signal) => {
      done();
      if (failure) reject(failure);
      else resolve({ stdout: Buffer.concat(out).toString("utf8"), stderr: err, code, signal });
    });
  });
}
