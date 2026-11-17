// Incident context (PLAN.md §13.1), collected shortly after an incident opens: the target's last log lines (≤300
// lines, ≤60 KB, redacted), a docker inspect summary, git log/status of the stack's repository, metrics around the
// incident, the host's events of the last 2 hours, the stack's deploy history (I-2), recent config file changes (key
// names only) and similar past incidents. Commands run without a shell.
import type { EventLog } from "../events.ts";
import { run as execRun } from "../exec.ts";
import { redact } from "../redact.ts";
import type { Stack } from "../stacks.ts";
import type { DeployTracker } from "./deploys.ts";
import type { MetricsRing } from "./metrics_ring.ts";
import type { Incident, IncidentContext, IncidentSummary, InspectSummary } from "./types.ts";

export type Runner = typeof execRun;

export const MAX_LOG_LINES = 300;
export const MAX_LOG_BYTES = 60 * 1024;
const EVENTS_WINDOW_MS = 2 * 3600_000;
const METRICS_WINDOW_MS = 30 * 60_000;
const SIMILAR_WINDOW_MS = 90 * 24 * 3600_000;
const DEPLOYS_WINDOW_MS = 7 * 24 * 3600_000;
const CONFIG_WINDOW_MS = 48 * 3600_000;

export const CONTAINER_RE = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;
export const UNIT_RE = /^[A-Za-z0-9@._:\\-]{1,200}$/;

/** Keeps the newest lines within the line and byte limits; redacts each line. */
export function boundLines(lines: string[]): { lines: string[]; truncated: boolean } {
  const out: string[] = [];
  let bytes = 0;
  for (let i = lines.length - 1; i >= 0 && out.length < MAX_LOG_LINES; i--) {
    const l = redact(lines[i]!.length > 4000 ? lines[i]!.slice(0, 4000) + "…" : lines[i]!);
    const b = Buffer.byteLength(l) + 1;
    if (bytes + b > MAX_LOG_BYTES) break;
    bytes += b;
    out.push(l);
  }
  return { lines: out.reverse(), truncated: out.length < lines.length };
}

export async function inspectContainer(name: string, run: Runner = execRun): Promise<InspectSummary | null> {
  if (!CONTAINER_RE.test(name)) return null;
  const r = await run("docker", ["inspect", "--type", "container", name], { allowFail: true, timeoutMs: 15_000 });
  if (r.code !== 0) return null;
  try {
    const [j] = JSON.parse(r.stdout) as Array<{
      Name?: string;
      Created?: string;
      Image?: string;
      RestartCount?: number;
      State?: { Status?: string; Running?: boolean; ExitCode?: number; OOMKilled?: boolean; StartedAt?: string; FinishedAt?: string; Health?: { Status?: string } };
      Config?: { Image?: string; Labels?: Record<string, string> };
      HostConfig?: { RestartPolicy?: { Name?: string } };
    }>;
    if (!j) return null;
    const zero = (t?: string) => (!t || t.startsWith("0001-") ? null : t);
    const labels = j.Config?.Labels ?? {};
    return {
      name: (j.Name ?? name).replace(/^\//, ""),
      image: j.Config?.Image ?? "",
      imageId: j.Image ?? "",
      created: j.Created ?? "",
      startedAt: zero(j.State?.StartedAt),
      finishedAt: zero(j.State?.FinishedAt),
      status: j.State?.Status ?? "unknown",
      running: j.State?.Running === true,
      exitCode: typeof j.State?.ExitCode === "number" ? j.State.ExitCode : null,
      oomKilled: j.State?.OOMKilled === true,
      restartCount: j.RestartCount ?? 0,
      restartPolicy: j.HostConfig?.RestartPolicy?.Name || null,
      health: j.State?.Health?.Status ?? null,
      project: labels["com.docker.compose.project"] ?? null,
      service: labels["com.docker.compose.service"] ?? null,
    };
  } catch {
    return null;
  }
}

export async function containerLogs(name: string, run: Runner = execRun) {
  const r = await run("docker", ["logs", "--tail", String(MAX_LOG_LINES), "--timestamps", name], { timeoutMs: 20_000 });
  // stdout and stderr come separately; merged by their RFC 3339 timestamps.
  const ts = (l: string) => l.slice(0, Math.max(0, l.indexOf(" ")));
  const lines = [...r.stdout.split("\n"), ...r.stderr.split("\n")].filter(Boolean).sort((a, b) => ts(a).localeCompare(ts(b)));
  return { source: "docker" as const, target: name, ...boundLines(lines) };
}

export async function unitLogs(scope: "user" | "system", unit: string, run: Runner = execRun) {
  const args = [...(scope === "user" ? ["--user", "--user-unit"] : ["--unit"]), unit, "-n", String(MAX_LOG_LINES), "-o", "short-iso", "--no-pager"];
  const r = await run("journalctl", args, { timeoutMs: 20_000 });
  return { source: "journal" as const, target: `${scope}/${unit}`, ...boundLines(r.stdout.split("\n").filter(Boolean)) };
}

export async function gitInfo(repo: string, run: Runner = execRun) {
  // fsmonitor is a configurable command: never run it from here.
  const git = (args: string[]) => run("git", ["-c", "core.fsmonitor=false", "-C", repo, ...args], { timeoutMs: 15_000 });
  const [log, status] = await Promise.all([git(["log", "--since=48.hours", "-n", "10", "--format=%H%x1f%aI%x1f%s"]), git(["status", "--porcelain"])]);
  return {
    repo,
    log: log.stdout
      .split("\n")
      .filter(Boolean)
      .map((l) => {
        const [hash = "", date = "", subject = ""] = l.split("\x1f");
        return { hash, date, subject: redact(subject.slice(0, 300)) };
      }),
    status: status.stdout.split("\n").filter(Boolean).slice(0, 100),
  };
}

export interface ContextDeps {
  run: Runner;
  stackOf: (i: Incident) => Stack | undefined;
  metrics?: MetricsRing;
  events?: EventLog | null;
  deploys?: DeployTracker;
  index: Iterable<IncidentSummary>;
  now: number;
}

const codeOf = (e: unknown) => (e && typeof e === "object" && "code" in e && typeof e.code === "string" ? e.code : "agent.internal");

/**
 * Past incidents (last 90 days) sharing a fingerprint, at most 5: the ones resolved with a note or a working action
 * first (they tell what helped before), then the newest.
 */
export function similarIncidents(i: Pick<Incident, "id" | "parts">, index: Iterable<IncidentSummary>, now: number): NonNullable<IncidentContext["similar"]> {
  const fps = new Set(i.parts.map((p) => p.fingerprint));
  const useful = (s: IncidentSummary) => (s.resolvedAt && (s.resolutionNote || s.workedAction) ? 1 : 0);
  return [...index]
    .filter((s) => s.id !== i.id && now - Date.parse(s.openedAt) < SIMILAR_WINDOW_MS && s.fingerprints.some((f) => fps.has(f)))
    .sort((a, b) => useful(b) - useful(a) || b.openedAt.localeCompare(a.openedAt))
    .slice(0, 5)
    .map((s) => ({ id: s.id, kind: s.kind, status: s.status, openedAt: s.openedAt, resolvedAt: s.resolvedAt, resolutionNote: s.resolutionNote, workedAction: s.workedAction }));
}

export async function collectContext(i: Incident, d: ContextDeps): Promise<IncidentContext> {
  const ctx: IncidentContext = { collectedAt: new Date(d.now).toISOString() };
  const errors: Record<string, string> = {};
  const part = (section: string, p: Promise<void>) => p.catch((e) => void (errors[section] = codeOf(e)));
  const container = i.parts.find((p) => p.targetType === "container")?.target;
  const unit = i.parts.find((p) => p.targetType === "unit");
  const jobs: Array<Promise<void>> = [];
  if (container && CONTAINER_RE.test(container)) {
    jobs.push(part("inspect", inspectContainer(container, d.run).then((x) => void (x && (ctx.inspect = x)))));
    jobs.push(part("logs", containerLogs(container, d.run).then((x) => void (ctx.logs = x))));
  } else if (unit && UNIT_RE.test(unit.target)) {
    jobs.push(part("logs", unitLogs(unit.unitScope ?? "user", unit.target, d.run).then((x) => void (ctx.logs = x))));
  }
  const stack = d.stackOf(i);
  if (stack?.gitRepo) jobs.push(part("git", gitInfo(stack.gitRepo, d.run).then((x) => void (ctx.git = x))));
  if (d.events) {
    jobs.push(
      part(
        "events",
        d.events.list({ since: new Date(d.now - EVENTS_WINDOW_MS).toISOString(), limit: 200 }).then((evs) => {
          ctx.events = evs
            .filter((e) => e.params.host === undefined || e.params.host === i.host)
            .slice(0, 100)
            .map((e) => ({ at: e.at, key: e.key, params: Object.fromEntries(Object.entries(e.params).map(([k, v]) => [k, typeof v === "string" ? redact(v) : v])) }));
        }),
      ),
    );
  }
  const project = stack?.project ?? i.stack;
  if (d.deploys && project) {
    const tracker = d.deploys;
    // A fresh snapshot first: the crashing container may have started only seconds ago.
    jobs.push(
      part(
        "deploys",
        tracker
          .snapshot()
          .catch(() => [])
          .then(() => tracker.history({ project, since: d.now - DEPLOYS_WINDOW_MS, limit: 20 }))
          .then((x) => void (ctx.deploys = x)),
      ),
    );
  }
  if (d.events) {
    jobs.push(
      part(
        "configChanges",
        d.events.list({ since: new Date(d.now - CONFIG_WINDOW_MS).toISOString(), limit: 1000 }).then((evs) => {
          ctx.configChanges = evs
            .filter((e) => (e.key === "config.saved" || e.key === "config.restored") && typeof e.params.file === "string")
            .filter((e) => !stack || String(e.params.file).startsWith(`${stack.id}/`))
            .slice(0, 50)
            .map((e) => ({ at: e.at, key: e.key, file: String(e.params.file), keys: String(e.params.keys ?? "").split(",").filter(Boolean) }));
        }),
      ),
    );
  }
  await Promise.all(jobs);
  if (d.metrics) {
    const at = Date.parse(i.openedAt);
    ctx.metrics = d.metrics.window(at - METRICS_WINDOW_MS, at + METRICS_WINDOW_MS, container);
  }
  ctx.similar = similarIncidents(i, d.index, d.now);
  if (Object.keys(errors).length) ctx.errors = errors;
  return ctx;
}
