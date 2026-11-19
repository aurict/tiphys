// Report collectors (PLAN.md §15, S-1). Each returns the raw text of helpers/audit.sh; parsing happens in report.ts.
//   local: the agent's own copy of the script without root, or (security.self.sudo) the root-owned installed copy via
//          `sudo -n` (never the agent's copy: a file the agent user can change must not run as root).
//   ssh:   a host without an agent, through the restricted audit key. The key's forced command runs the installed
//          script; we only send the mode word. Host keys are pinned in security-known-hosts (no TOFU).
//   agent: another agent's GET /v1/security/raw with a "security-report" service token.
import { spawn } from "node:child_process";
import { stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expandHome } from "../config.ts";
import { AppError } from "../errors.ts";

export type AuditMode = "report" | "report-full";

export const HELPER_PATH = fileURLToPath(new URL("../../helpers/audit.sh", import.meta.url));
export const INSTALLED_PATH = "/usr/local/lib/tiphys/audit.sh";
export const MAX_REPORT_BYTES = 2 * 1024 * 1024;
const TIMEOUT_MS: Record<AuditMode, number> = { report: 90_000, "report-full": 300_000 };

export interface SpawnResult {
  stdout: string;
  stderr: string;
  code: number;
}
export type Spawner = (cmd: string, args: string[], o: { timeoutMs: number; maxBytes: number; env?: Record<string, string> }) => Promise<SpawnResult>;

/** Spawns without a shell; kills the child on timeout or when stdout exceeds maxBytes. */
export const spawnCapped: Spawner = (cmd, args, o) =>
  new Promise((resolve, reject) => {
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"], env: { ...process.env, LC_ALL: "C.UTF-8", ...o.env } });
    const out: Buffer[] = [];
    let size = 0;
    let err = "";
    let failure: AppError | null = null;
    const kill = (e: AppError) => {
      failure ??= e;
      child.kill("SIGKILL");
    };
    const timer = setTimeout(() => kill(new AppError("agent.security.timeout", 504)), o.timeoutMs);
    child.stdout.on("data", (d: Buffer) => {
      size += d.length;
      if (size > o.maxBytes) kill(new AppError("agent.security.reportTooLarge", 502));
      else out.push(d);
    });
    child.stderr.on("data", (d: Buffer) => {
      if (err.length < 4000) err += d.toString("utf8");
    });
    child.on("error", (e: NodeJS.ErrnoException) => {
      clearTimeout(timer);
      reject(e.code === "ENOENT" ? new AppError("agent.exec.commandMissing", 500, { command: cmd }) : e);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (failure) reject(failure);
      else resolve({ stdout: Buffer.concat(out).toString("utf8"), stderr: err.slice(0, 4000), code: code ?? -1 });
    });
  });

/** Appends the agent's own file modes (config dir + its files) as an extra section; local source only. */
export async function agentFilesSection(configPath: string): Promise<string> {
  const dir = dirname(configPath);
  const lines: string[] = [];
  const files = [
    dir,
    configPath,
    "events.jsonl",
    "audit.jsonl",
    "security-state.json",
    "security-vulns.json",
    "security-secrets.json",
    "security-exposure.json",
    "security-attacks.json",
    "security-known-hosts",
    "security-audit-key",
    "blackbox",
    "blackbox/chain.jsonl",
    "blackbox/anchors.jsonl",
    "blackbox/head.json",
    "blackbox-queue.jsonl",
  ].map((f) => (f.startsWith("/") ? f : join(dir, f)));
  for (const p of files) {
    const s = await stat(p).catch(() => null);
    if (s) lines.push(`${(s.mode & 0o777).toString(8).padStart(3, "0")} ${p}`);
  }
  return `\n@@section agentfiles\n${lines.join("\n")}\n`;
}

export function withSection(text: string, section: string): string {
  const i = text.lastIndexOf("\n@@end");
  return i < 0 ? text : text.slice(0, i) + section + text.slice(i);
}

/** Installed copy must be root-owned and not writable by group/others, or sudo would run something we can change. */
async function checkInstalled(path: string) {
  const s = await stat(path).catch(() => null);
  if (!s || !s.isFile()) throw new AppError("agent.security.scriptMissing", 409, { path });
  if (s.uid !== 0 || s.mode & 0o022) throw new AppError("agent.security.scriptUnsafe", 409, { path });
}

function failed(code: string, r: SpawnResult): never {
  // stderr may name a host or a path but never carries secrets (the script prints none); still capped.
  throw new AppError(code, 502, { code: r.code, stderr: r.stderr.replace(/[^\x20-\x7e\n]/g, "").slice(0, 500) });
}

export async function collectLocal(o: { mode: AuditMode; sudo: boolean; configPath: string; spawner?: Spawner; installedPath?: string }): Promise<string> {
  const sp = o.spawner ?? spawnCapped;
  let r: SpawnResult;
  if (o.sudo) {
    const path = o.installedPath ?? INSTALLED_PATH;
    await checkInstalled(path);
    r = await sp("sudo", ["-n", path, o.mode], { timeoutMs: TIMEOUT_MS[o.mode], maxBytes: MAX_REPORT_BYTES });
  } else {
    r = await sp("sh", [HELPER_PATH, o.mode], { timeoutMs: TIMEOUT_MS[o.mode], maxBytes: MAX_REPORT_BYTES });
  }
  if (r.code !== 0) failed("agent.security.collectFailed", r);
  return withSection(r.stdout, await agentFilesSection(o.configPath));
}

export function knownHostsPath(configPath: string) {
  return join(dirname(configPath), "security-known-hosts");
}

export function sshArgs(s: { host: string; user: string; port: number; keyPath: string }, knownHosts: string, mode: AuditMode): string[] {
  return [
    "-T",
    "-F",
    "/dev/null",
    "-i",
    expandHome(s.keyPath),
    "-p",
    String(s.port),
    "-o",
    "BatchMode=yes",
    "-o",
    "IdentitiesOnly=yes",
    "-o",
    "IdentityAgent=none",
    "-o",
    "StrictHostKeyChecking=yes",
    "-o",
    `UserKnownHostsFile=${knownHosts}`,
    "-o",
    "GlobalKnownHostsFile=/dev/null",
    "-o",
    "ConnectTimeout=15",
    "-o",
    "ServerAliveInterval=15",
    "-o",
    "ServerAliveCountMax=3",
    "-o",
    "ClearAllForwardings=yes",
    "-l",
    s.user,
    "--",
    s.host,
    mode,
  ];
}

export async function collectSsh(o: {
  mode: AuditMode;
  source: { host: string; user: string; port: number; keyPath: string };
  configPath: string;
  spawner?: Spawner;
}): Promise<string> {
  const known = knownHostsPath(o.configPath);
  if (!(await stat(known).catch(() => null))) throw new AppError("agent.security.knownHostsMissing", 409);
  const r = await (o.spawner ?? spawnCapped)("ssh", sshArgs(o.source, known, o.mode), { timeoutMs: TIMEOUT_MS[o.mode] + 20_000, maxBytes: MAX_REPORT_BYTES });
  if (r.code === 255) failed("agent.security.sshFailed", r);
  if (r.code !== 0) failed("agent.security.collectFailed", r);
  return r.stdout;
}

export type Fetch = typeof fetch;

/** Reads a response body up to `max` bytes; more → `tooLarge` error (no unbounded res.text() on remote input). */
export async function readCapped(res: Response, max: number, tooLarge = "agent.security.reportTooLarge"): Promise<string> {
  const len = Number(res.headers.get("content-length") ?? "0");
  if (len > max) {
    await res.body?.cancel().catch(() => {});
    throw new AppError(tooLarge, 502);
  }
  if (!res.body) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) {
      await reader.cancel().catch(() => {});
      throw new AppError(tooLarge, 502);
    }
    chunks.push(value);
  }
  return Buffer.concat(chunks).toString("utf8");
}

export async function collectAgent(o: { mode: AuditMode; source: { url: string; token: string }; fetch?: Fetch }): Promise<string> {
  const f = o.fetch ?? fetch;
  const url = new URL(`/v1/security/raw?mode=${o.mode}`, o.source.url).toString();
  let res: Response;
  try {
    res = await f(url, { headers: { authorization: `Bearer ${o.source.token}` }, signal: AbortSignal.timeout(TIMEOUT_MS[o.mode] + 20_000), redirect: "error" });
  } catch (e) {
    const timeout = e instanceof Error && (e.name === "TimeoutError" || e.name === "AbortError");
    throw new AppError(timeout ? "agent.security.timeout" : "agent.security.unreachable", 502);
  }
  if (res.status === 401 || res.status === 403) throw new AppError("agent.security.unauthorized", 502, { status: res.status });
  if (res.status === 429) throw new AppError("agent.security.busy", 502);
  if (!res.ok) throw new AppError("agent.security.agentFailed", 502, { status: res.status });
  // JSON-escaped report text is larger than the text itself: allow some room.
  const body = await readCapped(res, MAX_REPORT_BYTES * 2);
  let text: unknown;
  try {
    text = (JSON.parse(body) as { text?: unknown }).text;
  } catch {
    throw new AppError("agent.security.agentFailed", 502, { status: res.status });
  }
  if (typeof text !== "string") throw new AppError("agent.security.agentFailed", 502, { status: res.status });
  return text;
}
