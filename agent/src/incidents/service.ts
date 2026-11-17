// Incident room core (PLAN.md §13.1, I-1): turns observed notifications into incidents (dedupe by fingerprint, group
// by stack within 5 min, reopen within 30 min of resolving), collects context, keeps the lifecycle
// (open → acknowledged → resolved, auto-resolve after 10 stable minutes) and runs confirmed actions.
import { randomBytes } from "node:crypto";
import { statfs } from "node:fs/promises";
import { AnalysisClient, unavailable, type Fetch } from "../analysis/client.ts";
import { AnalysisQueue } from "../analysis/jobs.ts";
import { validateAnalysis, type AnalysisBundle, type AnalysisResult } from "../analysis/schema.ts";
import type { AgentConfig, ConfigStore } from "../config.ts";
import { AppError, notFound } from "../errors.ts";
import { run as execRun } from "../exec.ts";
import type { Notice, Notifier } from "../notify.ts";
import { PreviewTokens } from "../preview.ts";
import { redact } from "../redact.ts";
import { discoverStacks, stackForProject, type Stack } from "../stacks.ts";
import { candidatesFor, rollbackable, stepsFor, type Candidate, type RollbackInfo, type Step, type StepExtras } from "./actions.ts";
import { ruleHints } from "./analysis.ts";
import { buildBundle, usefulSimilar } from "./bundle.ts";
import { collectContext, inspectContainer, similarIncidents, type Runner } from "./context.ts";
import { imageInfo, rollbackTag, serviceImage, type DeployTracker } from "./deploys.ts";
import { CLEANUP_OPTIONS, estimateCleanup, probeUserJournal, type CleanupEstimate, type CleanupOption, type JournalProbe } from "./disk_cleanup.ts";
import type { MetricsRing } from "./metrics_ring.ts";
import { signalOf } from "./signals.ts";
import { IncidentStore } from "./store.ts";
import type { Incident, IncidentAnalysis, IncidentStatus, IncidentSummary, Signal, TimelineEntry } from "./types.ts";

export const GROUP_WINDOW_MS = 5 * 60_000;
export const REOPEN_WINDOW_MS = 30 * 60_000;
export const STABLE_MS = 10 * 60_000;
const CONTEXT_TIMEOUT_MS = 60_000;
const STACKS_REFRESH_MS = 5 * 60_000;
const ACTION_TIMEOUT_MS = 120_000;
const RATE_LIMIT = 6;
const RATE_WINDOW_MS = 60_000;
const MAX_SIGNALS = 50;
const MAX_TIMELINE = 300;
export const PREVIEW_KIND = "incident.action";
const DISK_OK_PCT = 95;
export const ANALYZE_LIMIT = 3;
export const ANALYZE_WINDOW_MS = 10 * 60_000;
const NOTICE_SUMMARY_MAX = 140;

const sleep = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve, reject) => {
    if (signal.aborted) return reject(signal.reason);
    const t = setTimeout(() => {
      signal.removeEventListener("abort", onAbort);
      resolve();
    }, ms);
    const onAbort = () => {
      clearTimeout(t);
      reject(signal.reason);
    };
    signal.addEventListener("abort", onAbort, { once: true });
  });

/** Used share of a filesystem, the way df computes it (blocks reserved for root don't count as available). */
async function diskUsedPct(mount: string): Promise<number | null> {
  const st = await statfs(mount).catch(() => null);
  if (!st) return null;
  const used = st.blocks - st.bfree;
  const total = used + st.bavail;
  return total > 0 ? Math.round((used / total) * 1000) / 10 : null;
}

export interface ActionOptions {
  /** disk.cleanup: the chosen sub-options (preview default: every available one). */
  options?: CleanupOption[];
}

export interface IncidentServiceOptions {
  store: ConfigStore;
  notifier: Notifier;
  /** incidents/ directory (next to agent.json). */
  dir: string;
  now?: () => number;
  run?: Runner;
  metrics?: MetricsRing;
  /** Delay before collecting context (default 5 s; the plan allows up to 20 s). */
  contextDelayMs?: number;
  /** Delay before checking an action's effect (default 60 s). */
  postCheckDelayMs?: number;
  discover?: typeof discoverStacks;
  /** Deploy history (I-2): context, recentDeploy hint, GET /v1/incidents/deploys. */
  deploys?: DeployTracker;
  /** disk.cleanup preview: the user journal probe (tests). */
  journalProbe?: () => Promise<JournalProbe>;
  /** disk.cleanup post-check: used percentage of a mount (tests). */
  diskUsage?: (mount: string) => Promise<number | null>;
  /** Local analysis queue (mode local); default: one created on first use. */
  analysisQueue?: () => AnalysisQueue;
  /** Remote analysis: fetch (tests), poll interval (default 3 s), how long to wait for the PC (default 5 min). */
  analysisFetch?: Fetch;
  analysisPollMs?: number;
  analysisWaitMs?: number;
  /** Delay between the context collection on open and the automatic analysis (default 10 s). */
  analysisDelayMs?: number;
  log?: (msg: string, err?: unknown) => void;
}

const severityRank = { warning: 0, critical: 1 } as const;

export class IncidentService {
  readonly db: IncidentStore;
  readonly previews: PreviewTokens;
  /** Active incidents and those resolved within the reopen window (everything a new signal can touch). */
  readonly live = new Map<string, Incident>();
  #o: IncidentServiceOptions;
  #now: () => number;
  #run: Runner;
  #stacks: Stack[] = [];
  #stacksAt = -Infinity;
  #running = new Map<string, string>();
  #rate = new Map<string, number[]>();
  #pending = new Set<Promise<unknown>>();
  #timers = new Set<NodeJS.Timeout>();
  #closed = false;
  #closing = new AbortController();
  #analyzeRate = new Map<string, number[]>();
  /** Incidents (new or reopened) that get an automatic analysis once their context is collected. */
  #autoAnalyze = new Set<string>();
  #analysisTimers = new Map<string, NodeJS.Timeout>();
  #localQueue: AnalysisQueue | undefined;

  private constructor(o: IncidentServiceOptions) {
    this.#o = o;
    this.#now = o.now ?? Date.now;
    this.#run = o.run ?? execRun;
    this.db = new IncidentStore(o.dir, o.log);
    this.previews = new PreviewTokens({ now: this.#now });
  }

  static async open(o: IncidentServiceOptions): Promise<IncidentService> {
    const s = new IncidentService(o);
    await s.db.load();
    const now = s.#now();
    for (const sum of s.db.index.values()) {
      if (sum.status !== "resolved" || (sum.resolvedAt && now - Date.parse(sum.resolvedAt) < REOPEN_WINDOW_MS)) {
        const inc = await s.db.read(sum.id);
        if (inc) s.live.set(inc.id, inc);
      }
    }
    s.db.prune(now);
    await s.refreshStacks(true);
    return s;
  }

  // ---- signals ----

  /** Notifier observer: turns signals into incidents and adds the incident link to the notification. */
  observe = (n: Notice): Notice | void => {
    if (this.#closed) return;
    const sig = signalOf(n, this.#o.store.get());
    if (!sig) return;
    const inc = this.onSignal(sig);
    if (!inc) return;
    return { ...n, link: `tiphys://incidents/${inc.id}`, data: { ...n.data, incidentId: inc.id } };
  };

  onSignal(sig: Signal): Incident | null {
    const now = this.#now();
    const at = new Date(now).toISOString();
    if (sig.role === "close") {
      const inc = this.#activeWith(sig.fingerprint);
      if (!inc) return null;
      const part = inc.parts.find((p) => p.fingerprint === sig.fingerprint)!;
      if (!part.recoveredAt) {
        part.recoveredAt = at;
        this.#timeline(inc, { at, type: "recovered", key: sig.key, by: "agent" });
      }
      if (inc.parts.every((p) => p.recoveredAt)) inc.recoveredAt ??= at;
      this.#save(inc, now);
      return inc;
    }
    const stack = sig.stack ? this.#stackId(sig.stack, sig.workingDir) : undefined;
    let inc = this.#activeWith(sig.fingerprint);
    let fresh = false;
    if (!inc) {
      const old = this.#recentlyResolved(sig.fingerprint, now);
      if (old) {
        inc = old;
        this.#reopen(inc, "agent", at);
        fresh = true;
      }
    }
    if (!inc) {
      inc = this.#groupable(sig, stack, now);
      if (inc) this.#timeline(inc, { at, type: "merged", key: sig.key, data: { target: sig.target } });
    }
    if (!inc) {
      inc = {
        id: `inc-${randomBytes(6).toString("hex")}`,
        status: "open",
        severity: sig.severity,
        host: sig.host,
        kind: sig.key,
        target: sig.target,
        ...(stack ? { stack } : {}),
        ...(sig.service ? { service: sig.service } : {}),
        parts: [],
        openedAt: at,
        updatedAt: at,
        lastSignalAt: at,
        signalCount: 0,
        signals: [],
        timeline: [{ at, type: "opened", key: sig.key, by: "agent" }],
        hints: [],
        ...(sig.test ? { test: true } : {}),
      };
      this.live.set(inc.id, inc);
      fresh = true;
    }
    this.#addSignal(inc, sig, stack, at);
    inc.hints = ruleHints(inc, inc.context);
    this.#save(inc, now);
    if (fresh) {
      if (!inc.test) this.#autoAnalyze.add(inc.id);
      this.#scheduleContext(inc.id);
    }
    return inc;
  }

  #addSignal(inc: Incident, sig: Signal, stack: string | undefined, at: string) {
    let part = inc.parts.find((p) => p.fingerprint === sig.fingerprint);
    if (!part) {
      part = {
        fingerprint: sig.fingerprint,
        kind: sig.kind,
        target: sig.target,
        targetType: sig.targetType,
        ...(sig.unitScope ? { unitScope: sig.unitScope } : {}),
        ...(sig.workingDir ? { workingDir: sig.workingDir } : {}),
        firstAt: at,
        lastAt: at,
      };
      inc.parts.push(part);
    } else if (inc.signalCount > 0) {
      this.#timeline(inc, { at, type: "signal", key: sig.key });
    }
    part.lastAt = at;
    delete part.recoveredAt;
    delete inc.recoveredAt;
    if (!inc.stack && stack) inc.stack = stack;
    if (!inc.service && sig.service) inc.service = sig.service;
    if (severityRank[sig.severity] > severityRank[inc.severity]) inc.severity = sig.severity;
    inc.signalCount++;
    inc.lastSignalAt = at;
    inc.signals.push({ at, key: sig.key, params: sig.params });
    if (inc.signals.length > MAX_SIGNALS) inc.signals.splice(0, inc.signals.length - MAX_SIGNALS);
  }

  #activeWith(fp: string) {
    for (const i of this.live.values()) if (i.status !== "resolved" && i.parts.some((p) => p.fingerprint === fp)) return i;
    return undefined;
  }

  #recentlyResolved(fp: string, now: number) {
    let best: Incident | undefined;
    for (const i of this.live.values()) {
      if (i.status !== "resolved" || !i.resolvedAt || now - Date.parse(i.resolvedAt) >= REOPEN_WINDOW_MS) continue;
      if (!i.parts.some((p) => p.fingerprint === fp)) continue;
      if (!best || i.resolvedAt > best.resolvedAt!) best = i;
    }
    return best;
  }

  /** Same host and same stack (or, without a stack, the same target), last signal within 5 min. */
  #groupable(sig: Signal, stack: string | undefined, now: number) {
    for (const i of this.live.values()) {
      if (i.status === "resolved" || i.host !== sig.host || now - Date.parse(i.lastSignalAt) >= GROUP_WINDOW_MS) continue;
      if (stack ? i.stack === stack : i.parts.some((p) => p.target === sig.target)) return i;
    }
    return undefined;
  }

  // ---- stacks ----

  async refreshStacks(force = false): Promise<Stack[]> {
    const now = this.#now();
    if (force || now - this.#stacksAt >= STACKS_REFRESH_MS) {
      this.#stacksAt = now;
      this.#stacks = await (this.#o.discover ?? discoverStacks)(this.#o.store.get()).catch(() => this.#stacks);
    }
    return this.#stacks;
  }

  /** Stack id for a compose project name or a stack id (links use ids); unknown → the name itself. */
  #stackId(nameOrId: string, workingDir?: string): string {
    return this.#stacks.find((s) => s.id === nameOrId)?.id ?? stackForProject(this.#stacks, nameOrId, workingDir)?.id ?? nameOrId;
  }

  stackOf(i: Pick<Incident, "stack">): Stack | undefined {
    return i.stack ? this.#stacks.find((s) => s.id === i.stack) : undefined;
  }

  // ---- context ----

  #track<T>(p: Promise<T>): Promise<T> {
    this.#pending.add(p);
    void p.finally(() => this.#pending.delete(p)).catch(() => {});
    return p;
  }

  #later(ms: number, fn: () => Promise<void>) {
    if (ms <= 0) {
      void this.#track(fn().catch((e) => this.#o.log?.("olay işi başarısız", e)));
      return;
    }
    const t = setTimeout(() => {
      this.#timers.delete(t);
      if (!this.#closed) void this.#track(fn().catch((e) => this.#o.log?.("olay işi başarısız", e)));
    }, ms);
    t.unref();
    this.#timers.add(t);
  }

  #scheduleContext(id: string) {
    this.#later(this.#o.contextDelayMs ?? 5000, () => this.collect(id));
  }

  /** Collects (or re-collects) the incident's context; at most 60 s. */
  async collect(id: string): Promise<void> {
    await this.refreshStacks();
    const inc = this.live.get(id) ?? (await this.db.read(id));
    if (!inc) return;
    let timer: NodeJS.Timeout | undefined;
    const timeout = new Promise<null>((r) => (timer = setTimeout(() => r(null), CONTEXT_TIMEOUT_MS)));
    const ctx = await Promise.race([
      collectContext(inc, {
        run: this.#run,
        stackOf: (i) => this.stackOf(i),
        metrics: this.#o.metrics,
        events: this.#o.notifier.events,
        deploys: this.#o.deploys,
        index: this.db.index.values(),
        now: this.#now(),
      }),
      timeout,
    ]).finally(() => clearTimeout(timer));
    const cur = this.live.get(id) ?? inc;
    if (!ctx) {
      this.#timeline(cur, { at: new Date(this.#now()).toISOString(), type: "context", data: { ok: false } });
    } else {
      cur.context = ctx;
      cur.hints = ruleHints(cur, ctx);
      this.#timeline(cur, { at: ctx.collectedAt, type: "context", data: { ok: true, logLines: ctx.logs?.lines.length ?? 0 } });
    }
    this.#save(cur, this.#now());
    if (this.#autoAnalyze.delete(id) && ctx && this.#o.store.get().incidents.analysis.mode !== "off") this.#scheduleAnalysis(id);
  }

  // ---- AI analysis (I-3) ----

  /** Same fingerprint in the last 90 days, fresh from the index (notes and actions may have been added since). */
  similar(inc: Pick<Incident, "id" | "parts">) {
    return similarIncidents(inc, this.db.index.values(), this.#now());
  }

  /** The redacted analysis bundle (also the "Claude ile incele" text source). */
  async bundle(id: string): Promise<AnalysisBundle> {
    const { incident, candidates } = await this.candidates(id);
    return buildBundle(incident, candidates, usefulSimilar(this.similar(incident)), this.#o.store.get().incidents.analysis.language);
  }

  /** Debounced: a later collection for the same incident restarts the delay. */
  #scheduleAnalysis(id: string) {
    clearTimeout(this.#analysisTimers.get(id));
    const run = () => {
      this.#analysisTimers.delete(id);
      if (this.#closed) return;
      void this.#track(
        this.analyze(id, "auto").catch((e) => {
          // Rate limited or switched off meanwhile: the manual button still works.
          if (!(e instanceof AppError)) this.#o.log?.("otomatik analiz başarısız", e);
        }),
      );
    };
    const ms = this.#o.analysisDelayMs ?? 10_000;
    if (ms <= 0) return run();
    const t = setTimeout(run, ms);
    t.unref();
    this.#analysisTimers.set(id, t);
  }

  /**
   * Starts an analysis (3 per 10 min per incident, manual and automatic together). Returns the analysis state at once;
   * a queued/running analysis is returned as is instead of starting another.
   */
  async analyze(id: string, by: string): Promise<IncidentAnalysis> {
    const cfg = this.#o.store.get().incidents.analysis;
    if (cfg.mode === "off") throw new AppError("agent.incident.analysisOff", 409);
    const inc = await this.get(id);
    if (inc.analysis?.status === "queued" || inc.analysis?.status === "running") return { ...inc.analysis };
    const now = this.#now();
    const recent = (this.#analyzeRate.get(id) ?? []).filter((t) => now - t < ANALYZE_WINDOW_MS);
    if (recent.length >= ANALYZE_LIMIT) throw new AppError("agent.incident.analysisRateLimited", 429, { limit: ANALYZE_LIMIT, windowSeconds: ANALYZE_WINDOW_MS / 1000 });
    recent.push(now);
    this.#analyzeRate.set(id, recent);
    const bundle = await this.bundle(id);
    const cur = this.live.get(id) ?? inc;
    const at = new Date(this.#now()).toISOString();
    cur.analysis = { status: "queued", mode: cfg.mode, by, requestedAt: at };
    this.#timeline(cur, { at, type: "analysis", by, data: { status: "queued", mode: cfg.mode } });
    this.#keep(cur);
    const state = { ...cur.analysis };
    void this.#track(this.#runAnalysis(id, bundle, cfg).catch((e) => this.#o.log?.("analiz başarısız", e)));
    return state;
  }

  async #updateAnalysis(id: string, fn: (a: IncidentAnalysis, inc: Incident) => void): Promise<Incident | null> {
    const inc = this.live.get(id) ?? (await this.db.read(id));
    if (!inc?.analysis) return null; // deleted meanwhile
    fn(inc.analysis, inc);
    this.#keep(inc);
    return inc;
  }

  async #runAnalysis(id: string, bundle: AnalysisBundle, cfg: AgentConfig["incidents"]["analysis"]) {
    const setJob = (jobId: string) =>
      this.#updateAnalysis(id, (a) => {
        a.status = "running";
        a.jobId = jobId;
      });
    let result: AnalysisResult | undefined;
    let error: IncidentAnalysis["error"] | undefined;
    let reason: string | undefined;
    try {
      const job = cfg.mode === "local" ? await this.#runLocal(id, bundle, setJob) : await this.#runRemote(bundle, cfg, setJob);
      if (job.status === "done") {
        // The PC's (or the local queue's) result is validated again against this host's own bundle.
        try {
          result = validateAnalysis(job.result, bundle);
        } catch {
          error = { code: "agent.analysis.invalidOutput", params: {} };
        }
      } else {
        error = { code: job.error?.code ?? "agent.analysis.failed", params: {} };
      }
    } catch (e) {
      const code = e instanceof AppError ? e.code : "agent.internal";
      if (code.startsWith("agent.incident.analysis.") || code === "agent.analysis.busy") {
        reason = code === "agent.analysis.busy" ? "busy" : String((e as AppError).params.reason ?? code.split(".").pop());
        error = { code: `agent.incident.analysis.${reason}`, params: {} };
      } else {
        error = { code, params: e instanceof AppError ? e.params : {} };
      }
    }
    const at = new Date(this.#now()).toISOString();
    const status: IncidentAnalysis["status"] = result ? "done" : reason ? "unavailable" : "failed";
    const inc = await this.#updateAnalysis(id, (a, inc) => {
      a.status = status;
      a.finishedAt = at;
      delete a.result;
      delete a.error;
      delete a.reason;
      if (result) a.result = result;
      if (error) a.error = error;
      if (reason) a.reason = reason;
      this.#timeline(inc, {
        at,
        type: "analysisResult",
        data: {
          status,
          ...(result ? { hypotheses: result.hypotheses.length, actions: result.suggestedActions.length, droppedActions: result.dropped.actions } : {}),
          ...(error ? { code: error.code } : {}),
        },
      });
    });
    if (inc && result) this.#notifyAnalyzed(inc, result);
  }

  async #runLocal(id: string, bundle: AnalysisBundle, setJob: (jobId: string) => Promise<unknown>) {
    const q = this.#o.analysisQueue?.() ?? (this.#localQueue ??= new AnalysisQueue({ log: (_l, msg, extra) => this.#o.log?.(msg, extra) }));
    const job = q.submit(bundle, `incident:${id}`);
    await setJob(job.id);
    const signal = this.#closing.signal;
    const onAbort = () => void q.cancel(job.id);
    signal.addEventListener("abort", onAbort, { once: true });
    try {
      const fin = await q.wait(job.id);
      if (signal.aborted) throw unavailable("lost");
      if (!fin) throw unavailable("lost");
      return fin;
    } finally {
      signal.removeEventListener("abort", onAbort);
    }
  }

  async #runRemote(bundle: AnalysisBundle, cfg: AgentConfig["incidents"]["analysis"], setJob: (jobId: string) => Promise<unknown>) {
    if (!cfg.url || !cfg.token) throw unavailable("rejected");
    const client = new AnalysisClient({ url: cfg.url, token: cfg.token, ...(this.#o.analysisFetch ? { fetch: this.#o.analysisFetch } : {}) });
    const jobId = await client.create(bundle);
    await setJob(jobId);
    const deadline = Date.now() + (this.#o.analysisWaitMs ?? 5 * 60_000);
    const signal = this.#closing.signal;
    try {
      for (;;) {
        await sleep(Math.min(this.#o.analysisPollMs ?? 3000, Math.max(0, deadline - Date.now())), signal);
        if (Date.now() >= deadline) throw unavailable("timeout");
        let job;
        try {
          job = await client.get(jobId);
        } catch (e) {
          // A short outage while polling: keep trying until the deadline.
          if (e instanceof AppError && e.code === "agent.incident.analysis.unreachable") continue;
          throw e;
        }
        if (!job) throw unavailable("lost");
        if (job.status === "done" || job.status === "failed") return job;
      }
    } catch (e) {
      void client.cancel(jobId).catch(() => {});
      throw signal.aborted ? unavailable("lost") : e;
    }
  }

  /**
   * incident.analyzed: silent, and the app shows it in place of the incident's source notification (data.replaceKey +
   * data.replaceParams give the source notification's key and params, from which the app derives its notification id).
   * Sensitive: the summary is model text about logs, so it goes only to end-to-end encrypted endpoints and isn't
   * written to the event stream.
   */
  #notifyAnalyzed(inc: Incident, r: AnalysisResult) {
    const src = inc.signals.find((x) => x.key === inc.kind) ?? inc.signals[0];
    const summary = r.summary.length > NOTICE_SUMMARY_MAX ? r.summary.slice(0, NOTICE_SUMMARY_MAX - 1) + "…" : r.summary;
    void this.#o.notifier
      .send({
        key: "incident.analyzed",
        params: { host: inc.host, incidentId: inc.id, summary },
        link: `tiphys://incidents/${inc.id}`,
        priority: "low",
        sensitive: true,
        data: { incidentId: inc.id, silent: "1", ...(src ? { replaceKey: src.key, replaceParams: JSON.stringify(src.params) } : {}) },
      })
      .catch(() => {});
  }

  // ---- lifecycle ----

  list(status?: IncidentStatus | "active", limit = 100): IncidentSummary[] {
    return [...this.db.index.values()]
      .filter((s) => !status || (status === "active" ? s.status !== "resolved" : s.status === status))
      .sort((a, b) => b.openedAt.localeCompare(a.openedAt))
      .slice(0, limit);
  }

  async get(id: string): Promise<Incident> {
    const inc = this.live.get(id) ?? (await this.db.read(id));
    if (!inc) throw notFound("incident", { id });
    return inc;
  }

  async ack(id: string, by: string) {
    const inc = await this.get(id);
    if (inc.status !== "open") throw new AppError("agent.incident.badState", 409, { status: inc.status });
    const at = new Date(this.#now()).toISOString();
    inc.status = "acknowledged";
    inc.acknowledgedAt = at;
    this.#timeline(inc, { at, type: "acknowledged", by });
    return this.#keep(inc);
  }

  async resolve(id: string, by: string, note?: string) {
    const inc = await this.get(id);
    if (inc.status === "resolved") throw new AppError("agent.incident.badState", 409, { status: inc.status });
    this.#resolve(inc, by, note);
    return this.#keep(inc);
  }

  #resolve(inc: Incident, by: string, note?: string) {
    const at = new Date(this.#now()).toISOString();
    inc.status = "resolved";
    inc.resolvedAt = at;
    inc.resolvedBy = by;
    if (note) inc.resolutionNote = note;
    this.#timeline(inc, { at, type: "resolved", by, ...(note ? { text: note } : {}) });
  }

  async reopen(id: string, by: string) {
    const inc = await this.get(id);
    if (inc.status !== "resolved") throw new AppError("agent.incident.badState", 409, { status: inc.status });
    this.#reopen(inc, by, new Date(this.#now()).toISOString());
    return this.#keep(inc);
  }

  #reopen(inc: Incident, by: string, at: string) {
    inc.status = "open";
    delete inc.resolvedAt;
    delete inc.resolvedBy;
    delete inc.acknowledgedAt;
    delete inc.recoveredAt;
    for (const p of inc.parts) delete p.recoveredAt;
    this.#timeline(inc, { at, type: "reopened", by });
  }

  async note(id: string, by: string, text: string) {
    const inc = await this.get(id);
    this.#timeline(inc, { at: new Date(this.#now()).toISOString(), type: "note", by, text });
    return this.#keep(inc);
  }

  async remove(id: string) {
    await this.get(id);
    if (this.#running.has(id)) throw new AppError("agent.incident.actionRunning", 409);
    this.live.delete(id);
    await this.db.remove(id);
  }

  #keep(inc: Incident) {
    this.live.set(inc.id, inc);
    this.#save(inc, this.#now());
    return inc;
  }

  #timeline(inc: Incident, e: TimelineEntry) {
    inc.timeline.push(e);
    if (inc.timeline.length > MAX_TIMELINE) inc.timeline.splice(1, inc.timeline.length - MAX_TIMELINE);
  }

  #save(inc: Incident, now: number) {
    inc.updatedAt = new Date(now).toISOString();
    void this.db.save(inc);
  }

  /**
   * Periodic work (every 60 s): marks containers that run (healthy) again as recovered, auto-resolves incidents whose
   * parts all stayed recovered for 10 min with no new signal, drops old entries from memory and applies retention.
   */
  async tick(): Promise<void> {
    await this.refreshStacks();
    const now = this.#now();
    const at = new Date(now).toISOString();
    for (const inc of [...this.live.values()]) {
      if (inc.status === "resolved") {
        if (!inc.resolvedAt || now - Date.parse(inc.resolvedAt) >= REOPEN_WINDOW_MS) this.live.delete(inc.id);
        continue;
      }
      let changed = false;
      for (const p of inc.parts) {
        if (p.targetType !== "container") continue;
        const insp = await inspectContainer(p.target, this.#run).catch(() => null);
        const ok = !!insp && insp.running && (insp.health === null || insp.health === "healthy");
        if (ok && !p.recoveredAt) {
          p.recoveredAt = at;
          this.#timeline(inc, { at, type: "recovered", key: p.kind, by: "agent" });
          changed = true;
        } else if (!ok && p.recoveredAt) {
          delete p.recoveredAt;
          delete inc.recoveredAt;
          changed = true;
        }
      }
      if (inc.parts.every((p) => p.recoveredAt) && !inc.recoveredAt) {
        inc.recoveredAt = inc.parts.map((p) => p.recoveredAt!).sort().at(-1)!;
        changed = true;
      }
      if (inc.recoveredAt && now - Date.parse(inc.recoveredAt) >= STABLE_MS && now - Date.parse(inc.lastSignalAt) >= STABLE_MS) {
        this.#resolve(inc, "auto");
        changed = true;
        void this.#o.notifier
          .send({
            key: "incident.resolved",
            params: { host: inc.host, kind: inc.kind, target: inc.target, incidentId: inc.id },
            link: `tiphys://incidents/${inc.id}`,
            data: { incidentId: inc.id },
          })
          .catch(() => {});
      }
      if (changed) this.#save(inc, now);
    }
    for (const id of this.db.prune(now)) this.live.delete(id);
  }

  // ---- actions ----

  /** What the incident service's `:prev` tag would roll back to; null when there's no tag or nothing to change. */
  async rollbackInfo(stack: Stack, service: string): Promise<RollbackInfo | null> {
    const cur = await serviceImage(this.#run, stack.project, service).catch(() => undefined);
    if (!cur) return null;
    const tag = rollbackTag(stack.project, service);
    const [prev, curImg] = await Promise.all([imageInfo(this.#run, tag).catch(() => null), imageInfo(this.#run, cur.imageId).catch(() => null)]);
    if (!prev) return null;
    return { tag, imageRef: cur.imageRef, current: { imageId: cur.imageId, created: curImg?.created ?? null }, previous: { imageId: prev.id, created: prev.created || null } };
  }

  async candidates(id: string): Promise<{ incident: Incident; candidates: Candidate[]; rollback: RollbackInfo | null }> {
    const incident = await this.get(id);
    await this.refreshStacks();
    const stack = this.stackOf(incident);
    const rollback = stack && incident.service && stack.services.includes(incident.service) ? await this.rollbackInfo(stack, incident.service) : null;
    return { incident, candidates: candidatesFor(incident, stack, rollback), rollback };
  }

  async actions(id: string) {
    const { candidates } = await this.candidates(id);
    return { actions: candidates, running: this.#running.get(id) ?? null };
  }

  /** `extrasFor` adds kind-specific inputs (the cleanup options) once the candidate is known. */
  async #resolveAction(id: string, aid: string, extrasFor: (c: Candidate) => Promise<Omit<StepExtras, "rollback">> | Omit<StepExtras, "rollback"> = () => ({})) {
    const { incident, candidates, rollback } = await this.candidates(id);
    const candidate = candidates.find((c) => c.id === aid);
    if (!candidate) throw notFound("incident.action", { id: aid });
    const steps = stepsFor(candidate, this.stackOf(incident), { ...(await extrasFor(candidate)), rollback });
    if (!steps) throw new AppError("agent.incident.actionUnavailable", 409, { id: aid });
    return { incident, candidate, steps, rollback };
  }

  /** Canonical order, no duplicates; the system journal is never runnable. */
  static cleanupSelection(options: CleanupOption[] | undefined, estimates?: CleanupEstimate[]): CleanupOption[] {
    const available = estimates ? new Set(estimates.filter((e) => e.available).map((e) => e.option)) : null;
    const wanted = options ?? (available ? [...available] : []);
    for (const o of wanted) {
      if (o === "systemJournal" || (available && !available.has(o))) throw new AppError("agent.incident.cleanupOptionUnavailable", 409, { option: o });
    }
    return CLEANUP_OPTIONS.filter((o) => wanted.includes(o));
  }

  async preview(id: string, aid: string, device: string, o: ActionOptions = {}) {
    let details: Record<string, unknown> | undefined;
    const { incident, candidate, steps, rollback } = await this.#resolveAction(id, aid, async (c) => {
      if (c.kind !== "disk.cleanup") return {};
      const estimates = await estimateCleanup(this.#run, this.#o.journalProbe ?? (() => probeUserJournal()));
      const selected = IncidentService.cleanupSelection(o.options, estimates);
      details = { cleanup: { options: estimates, selected } };
      return { cleanup: selected };
    });
    if (candidate.kind === "compose.rollback" && rollbackable(rollback)) {
      // Rolling back the image never rolls back what the newer version did to its data.
      details = { rollback, warnings: ["dbMigrationsNotReverted"] };
    }
    const token = this.previews.issue(device, PREVIEW_KIND, { incidentId: incident.id, candidate, steps });
    return { candidate, steps, risk: candidate.risk, ...(details ? { details } : {}), ...token };
  }

  async execute(id: string, aid: string, device: string, previewToken: string, o: ActionOptions = {}) {
    const now = this.#now();
    const recent = (this.#rate.get(device) ?? []).filter((t) => now - t < RATE_WINDOW_MS);
    if (recent.length >= RATE_LIMIT) throw new AppError("agent.incident.rateLimited", 429);
    recent.push(now);
    this.#rate.set(device, recent);
    // Availability was checked by the preview; the token binds the exact commands.
    const { incident, candidate, steps, rollback } = await this.#resolveAction(id, aid, (c) =>
      c.kind === "disk.cleanup" ? { cleanup: IncidentService.cleanupSelection(o.options ?? []) } : {},
    );
    if (this.#running.has(incident.id)) throw new AppError("agent.incident.actionRunning", 409, { action: this.#running.get(incident.id) });
    this.previews.consume(previewToken, device, PREVIEW_KIND, { incidentId: incident.id, candidate, steps });
    this.#running.set(incident.id, candidate.id);
    const by = `device:${device}`;
    const data = { action: candidate.kind, candidate: candidate.id };
    try {
      this.#timeline(incident, { at: new Date(this.#now()).toISOString(), type: "action", by, data });
      this.#keep(incident);
      const result = await this.#runSteps(steps);
      const cur = this.live.get(incident.id) ?? incident;
      this.#timeline(cur, { at: new Date(this.#now()).toISOString(), type: "actionResult", data: { ...data, ok: result.ok, code: result.code }, ...(result.stderr ? { text: result.stderr } : {}) });
      this.#keep(cur);
      const expectImage = candidate.kind === "compose.rollback" ? rollback?.previous.imageId : undefined;
      if (!result.ok) this.#actionFailed(cur, candidate, "command");
      else this.#later(this.#o.postCheckDelayMs ?? 60_000, () => this.#postCheck(cur.id, candidate, expectImage));
      return { ok: result.ok, code: result.code, ...(result.stderr ? { stderr: result.stderr } : {}) };
    } finally {
      this.#running.delete(incident.id);
    }
  }

  /** Deploy history (newest first) for a stack id (or compose project name) and service. */
  async deployHistory(o: { stack?: string; service?: string; limit?: number }) {
    if (!this.#o.deploys) return [];
    await this.refreshStacks();
    const project = o.stack ? (this.#stacks.find((s) => s.id === o.stack)?.project ?? o.stack) : undefined;
    return this.#o.deploys.history({ project, service: o.service, limit: o.limit });
  }

  async #runSteps(steps: Step[]): Promise<{ ok: boolean; code: number; stderr: string }> {
    for (const s of steps) {
      try {
        const r = await this.#run(s.argv[0]!, s.argv.slice(1), { allowFail: true, timeoutMs: ACTION_TIMEOUT_MS, ...(s.cwd ? { cwd: s.cwd } : {}) });
        if (r.code !== 0) return { ok: false, code: r.code, stderr: redact(r.stderr.slice(-1000)) };
      } catch (e) {
        return { ok: false, code: -1, stderr: e instanceof AppError ? e.code : "agent.internal" };
      }
    }
    return { ok: true, code: 0, stderr: "" };
  }

  async #postCheck(id: string, c: Candidate, expectImage?: string) {
    const inc = this.live.get(id) ?? (await this.db.read(id));
    if (!inc) return;
    const t = c.target as Record<string, string>;
    let ok = false;
    let state = "unknown";
    if (c.kind === "disk.cleanup") {
      const pct = await (this.#o.diskUsage ?? diskUsedPct)(t.mount!).catch(() => null);
      state = pct === null ? "unknown" : `${pct}%`;
      ok = pct !== null && pct < DISK_OK_PCT;
    } else if (c.kind === "unit.restart") {
      const r = await this.#run("systemctl", [...(t.scope === "user" ? ["--user"] : []), "is-active", t.unit!], { allowFail: true, timeoutMs: 15_000 }).catch(() => null);
      state = r?.stdout.trim() || "unknown";
      ok = state === "active";
    } else {
      let name = t.container;
      if (c.kind === "compose.recreate" || c.kind === "compose.rollback") {
        const stack = this.stackOf(inc);
        const r = await this.#run(
          "docker",
          ["ps", "-a", "--filter", `label=com.docker.compose.project=${stack?.project ?? t.stack}`, "--filter", `label=com.docker.compose.service=${t.service}`, "--format", "{{.Names}}"],
          { allowFail: true, timeoutMs: 15_000 },
        ).catch(() => null);
        name = r?.stdout.split("\n").find(Boolean)?.trim();
      }
      const insp = name ? await inspectContainer(name, this.#run).catch(() => null) : null;
      state = insp ? (insp.health ? `${insp.status}/${insp.health}` : insp.status) : "missing";
      ok = !!insp && insp.running && insp.health !== "unhealthy";
      if (insp && expectImage && insp.imageId !== expectImage) {
        ok = false;
        state = `${state}/otherImage`;
      }
    }
    const cur = this.live.get(id) ?? inc;
    this.#timeline(cur, { at: new Date(this.#now()).toISOString(), type: "postCheck", data: { action: c.kind, candidate: c.id, ok, state } });
    if (ok) cur.workedAction = c.kind;
    this.#save(cur, this.#now());
    if (!ok) this.#actionFailed(cur, c, "postCheck");
  }

  #actionFailed(inc: Incident, c: Candidate, stage: "command" | "postCheck") {
    void this.#o.notifier
      .send({
        key: "incident.actionFailed",
        params: { host: inc.host, target: inc.target, action: c.kind, stage, incidentId: inc.id },
        link: `tiphys://incidents/${inc.id}`,
        priority: "high",
        data: { incidentId: inc.id },
      })
      .catch(() => {});
  }

  /** Waits for queued context collections, post-checks and writes (tests, shutdown). */
  async idle(): Promise<void> {
    while (this.#pending.size) await Promise.allSettled([...this.#pending]);
    await this.db.flush();
  }

  async close(): Promise<void> {
    this.#closed = true;
    for (const t of this.#timers) clearTimeout(t);
    this.#timers.clear();
    for (const t of this.#analysisTimers.values()) clearTimeout(t);
    this.#analysisTimers.clear();
    this.#closing.abort(new AppError("agent.incident.analysis.lost", 503));
    await this.idle();
    await this.#localQueue?.close();
  }
}
