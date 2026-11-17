// Recreating the services affected by a config file change (PLAN.md §13.3, C-2). `docker compose restart` doesn't
// reload .env / env_file, so each stack runs `docker compose -f <files…> up -d --no-deps <services…>` in its directory
// (no shell; service names come from the compose parse and are validated again here). Then a post-check like the
// incident room's: every container of each service must be running and not unhealthy, without restarting meanwhile.
import { AppError } from "../errors.ts";
import { run as execRun } from "../exec.ts";
import { inspectContainer, type Runner } from "../incidents/context.ts";
import { redact } from "../redact.ts";
import { SERVICE_NAME, type Stack } from "../stacks.ts";

export const RESTART_TIMEOUT_MS = 3 * 60_000;
export const POST_CHECK_MS = 30_000;
const POLL_MS = 2_000;
const STDERR_TAIL = 2000;

export interface PlanEntry {
  stack: string;
  project: string;
  services: string[];
}

export interface Step extends PlanEntry {
  argv: string[];
  cwd: string;
}

export interface StackResult extends PlanEntry {
  ok: boolean;
  code: number;
  stderr?: string;
}

export interface ServiceResult {
  stack: string;
  service: string;
  ok: boolean;
  /** running, running/healthy, running/starting, exited, restarting, missing, notRun (its stack's command failed)… */
  state: string;
}

export interface RestartResult {
  ok: boolean;
  stage?: "command" | "postCheck";
  stacks: StackResult[];
  services: ServiceResult[];
}

/**
 * The commands for a plan: only stacks still discovered, only services that are in the plan, still affected now and
 * defined in the stack. A plan entry with nothing left is dropped.
 */
export function stepsFor(plan: PlanEntry[], stacks: Stack[], current: PlanEntry[]): Step[] {
  const out: Step[] = [];
  for (const p of plan) {
    const stack = stacks.find((s) => s.id === p.stack);
    const now = current.find((c) => c.stack === p.stack);
    if (!stack || !now) continue;
    const services = p.services.filter((s) => SERVICE_NAME.test(s) && !s.startsWith("-") && stack.services.includes(s) && now.services.includes(s));
    if (!services.length) continue;
    const files = stack.composeFiles.flatMap((f) => ["-f", f]);
    out.push({ stack: stack.id, project: stack.project, services, argv: ["docker", "compose", ...files, "up", "-d", "--no-deps", ...services], cwd: stack.dir });
  }
  return out;
}

/** Last part of the output, ANSI-free, with `hide` values and then everything redact.ts knows replaced. */
function tail(s: string, hide: Array<{ key: string; value: string }>): string {
  let t = s.replace(/\x1b\[[0-9;?]*[A-Za-z]/g, "");
  for (const { key, value } of [...hide].sort((a, b) => b.value.length - a.value.length)) {
    if (value.length >= 6 && t.includes(value)) t = t.split(value).join(`[GİZLİ:${key}]`);
  }
  return redact(t.slice(-STDERR_TAIL)).trim();
}

export interface RunOpts {
  run?: Runner;
  timeoutMs?: number;
  postCheckMs?: number;
  pollMs?: number;
  /** Values to mask in the output besides redact.ts's known secrets (the secrets the save replaced). */
  hide?: Array<{ key: string; value: string }>;
}

export async function runRestart(steps: Step[], o: RunOpts = {}): Promise<RestartResult> {
  const run = o.run ?? execRun;
  const stacks: StackResult[] = [];
  for (const s of steps) {
    const base = { stack: s.stack, project: s.project, services: s.services };
    try {
      const r = await run(s.argv[0]!, s.argv.slice(1), { allowFail: true, timeoutMs: o.timeoutMs ?? RESTART_TIMEOUT_MS, cwd: s.cwd });
      const err = tail(r.stderr, o.hide ?? []);
      stacks.push({ ...base, ok: r.code === 0, code: r.code, ...(err ? { stderr: err } : {}) });
    } catch (e) {
      stacks.push({ ...base, ok: false, code: -1, stderr: e instanceof AppError ? e.code : "agent.internal" });
    }
  }
  const checked = stacks.filter((s) => s.ok);
  const services: ServiceResult[] = stacks.filter((s) => !s.ok).flatMap((s) => s.services.map((service) => ({ stack: s.stack, service, ok: false, state: "notRun" })));
  services.push(...(await postCheck(checked, run, o.postCheckMs ?? POST_CHECK_MS, o.pollMs ?? POLL_MS)));
  const commandOk = stacks.every((s) => s.ok);
  const ok = commandOk && services.every((s) => s.ok);
  return { ok, ...(ok ? {} : { stage: commandOk ? ("postCheck" as const) : ("command" as const) }), stacks, services };
}

interface Seen {
  state: string;
  /** true/false once decided, null while it may still change. */
  final: boolean | null;
  ok: boolean;
}

async function containersOf(run: Runner, project: string, service: string): Promise<string[]> {
  const r = await run(
    "docker",
    ["ps", "-a", "--filter", `label=com.docker.compose.project=${project}`, "--filter", `label=com.docker.compose.service=${service}`, "--filter", "label=com.docker.compose.oneoff=False", "--format", "{{.Names}}"],
    { allowFail: true, timeoutMs: 15_000 },
  ).catch(() => null);
  return (r?.stdout ?? "").split("\n").map((l) => l.trim()).filter(Boolean);
}

/**
 * Polls every pollMs for up to windowMs. A service fails early when a container exits, is unhealthy, is missing or its
 * restart count grows; it passes early when every container reports healthy; otherwise it is judged at the end
 * (running and not unhealthy).
 */
async function postCheck(stacks: StackResult[], run: Runner, windowMs: number, pollMs: number): Promise<ServiceResult[]> {
  const items = stacks.flatMap((s) => s.services.map((service) => ({ stack: s.stack, project: s.project, service })));
  if (!items.length) return [];
  const restarts = new Map<string, number>();
  const seen = new Map<string, Seen>();
  const end = Date.now() + windowMs;
  for (;;) {
    const left = end - Date.now();
    if (left > 0) await new Promise((r) => setTimeout(r, Math.min(pollMs, left)));
    const last = Date.now() >= end;
    for (const it of items) {
      const k = `${it.stack}/${it.service}`;
      const had = seen.get(k);
      if (had && had.final !== null) continue;
      const names = await containersOf(run, it.project, it.service);
      if (!names.length) {
        seen.set(k, { state: "missing", final: last ? false : null, ok: false });
        continue;
      }
      const cs: Seen[] = [];
      for (const n of names) {
        const i = await inspectContainer(n, run).catch(() => null);
        const prev = restarts.get(n);
        if (i && prev === undefined) restarts.set(n, i.restartCount);
        const state = !i ? "missing" : i.health ? `${i.status}/${i.health}` : i.status;
        if (!i) cs.push({ state, final: last ? false : null, ok: false });
        else if (prev !== undefined && i.restartCount > prev) cs.push({ state: "restarting", final: false, ok: false });
        else if (i.health === "unhealthy" || i.status === "exited" || i.status === "dead") cs.push({ state, final: false, ok: false });
        else if (i.running && i.health === "healthy") cs.push({ state, final: true, ok: true });
        else cs.push({ state, final: last ? i.running : null, ok: i.running });
      }
      // The worst container decides: failed, then undecided, then passed.
      const s = cs.find((c) => c.final === false) ?? cs.find((c) => c.final === null) ?? cs[0]!;
      seen.set(k, s);
    }
    const open = [...seen.values()].some((s) => s.final === null);
    if (!open || last) break;
  }
  return items.map((it) => {
    const s = seen.get(`${it.stack}/${it.service}`)!;
    return { stack: it.stack, service: it.service, ok: s.final === true && s.ok, state: s.state };
  });
}
