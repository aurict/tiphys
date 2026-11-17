// Child process helper for AI CLIs (research: agy + claude; incident analysis: tool-less claude -p): PATH lookup at call
// time, an allowlisted environment, its own process group (so MCP servers it starts die with it) and SIGTERM → SIGKILL
// on timeout/cancel. claudePrint runs `claude -p` with no tools at all (PLAN.md §13.0).
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { access, constants, mkdir, rm } from "node:fs/promises";
import { homedir } from "node:os";
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

/** Variables passed to the AI tools; everything else in the agent's environment (secrets, tokens) is dropped. */
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
  /** Error code prefix, e.g. "agent.research" → agent.research.toolMissing / .timeout / .toolFailed. */
  errorPrefix: string;
  /** Written to stdin (then closed); without it stdin is /dev/null. */
  input?: string;
}

export async function runTool(tool: string, args: string[], o: RunOpts): Promise<RunResult> {
  const path = await which(tool);
  if (!path) throw new AppError(`${o.errorPrefix}.toolMissing`, 500, { tool });
  o.signal.throwIfAborted();
  return new Promise((resolve, reject) => {
    const child = spawn(path, args, { cwd: o.cwd, env: childEnv(), detached: true, stdio: [o.input === undefined ? "ignore" : "pipe", "pipe", "pipe"] });
    if (o.input !== undefined) {
      child.stdin!.on("error", () => {}); // the tool may exit before reading everything
      child.stdin!.end(o.input);
    }
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
    const timer = setTimeout(() => kill(new AppError(`${o.errorPrefix}.timeout`, 500, { tool })), o.timeoutMs);
    const onAbort = () => kill(o.signal.reason);
    o.signal.addEventListener("abort", onAbort, { once: true });
    child.stdout!.on("data", (b: Buffer) => {
      if (outLen < MAX_STDOUT) out.push(b);
      outLen += b.length;
    });
    child.stderr!.on("data", (b: Buffer) => {
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
      reject(failure ?? new AppError(`${o.errorPrefix}.toolFailed`, 500, { tool, reason: (e as NodeJS.ErrnoException).code ?? "spawn" }));
    });
    child.on("close", (code, signal) => {
      done();
      if (failure) reject(failure);
      else resolve({ stdout: Buffer.concat(out).toString("utf8"), stderr: err, code, signal });
    });
  });
}

// ---- tool-less claude -p ----

/**
 * Flags for a print-mode run with no tools: no user/project settings (hooks, permissions), no MCP servers, no built-in
 * tools (`--tools ""`; verified 2026-11-17 with claude 2.1.325: the model sees only StructuredOutput, Bash/Read
 * requests are not possible), structured output against the given JSON schema.
 */
export function claudePrintArgs(jsonSchema: object, model = "sonnet"): string[] {
  return [
    "-p",
    "--setting-sources", "",
    "--strict-mcp-config",
    "--tools", "",
    "--permission-mode", "default",
    "--model", model,
    "--output-format", "json",
    "--json-schema", JSON.stringify(jsonSchema),
  ];
}

export function defaultLlmRoot(): string {
  const rt = process.env.XDG_RUNTIME_DIR;
  return rt ? join(rt, "tiphys", "llm") : join(homedir(), ".cache", "tiphys", "llm");
}

export interface ClaudePrintOpts {
  prompt: string;
  jsonSchema: object;
  model?: string;
  timeoutMs: number;
  signal?: AbortSignal;
  killGraceMs?: number;
  /** Parent of the per-run empty work directory (0700, removed afterwards). */
  root?: string;
  errorPrefix?: string;
}

export interface ClaudePrintResult {
  /** `structured_output` of the result (not yet validated against the caller's zod schema). */
  output: unknown;
  durationSec: number;
}

/** Runs `claude -p` without tools; the prompt goes on stdin, the run's cwd is a fresh empty 0700 directory. */
export async function claudePrint(o: ClaudePrintOpts): Promise<ClaudePrintResult> {
  const prefix = o.errorPrefix ?? "agent.llm";
  const root = o.root ?? defaultLlmRoot();
  await mkdir(root, { recursive: true, mode: 0o700 });
  const dir = join(root, `run-${randomBytes(8).toString("hex")}`);
  await mkdir(dir, { mode: 0o700 });
  const started = Date.now();
  try {
    const r = await runTool("claude", claudePrintArgs(o.jsonSchema, o.model), {
      cwd: dir,
      signal: o.signal ?? new AbortController().signal,
      timeoutMs: o.timeoutMs,
      killGraceMs: o.killGraceMs ?? 5000,
      errorPrefix: prefix,
      input: o.prompt,
    });
    let res: { is_error?: boolean; subtype?: string; structured_output?: unknown };
    try {
      res = JSON.parse(r.stdout.trim().split("\n").at(-1) ?? "");
    } catch {
      throw new AppError(`${prefix}.invalidOutput`, 500, { tool: "claude" });
    }
    if (r.code !== 0 || res.is_error || res.subtype !== "success") {
      throw new AppError(`${prefix}.toolFailed`, 500, { tool: "claude", ...(r.code !== 0 ? { exitCode: r.code ?? -1 } : { status: res.subtype ?? "error" }) });
    }
    if (res.structured_output === undefined) throw new AppError(`${prefix}.invalidOutput`, 500, { tool: "claude" });
    return { output: res.structured_output, durationSec: Math.round((Date.now() - started) / 1000) };
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
}
