// Incident analysis job queue (PLAN.md §13.1 I-3): one job runs at a time, at most 3 wait, 3 min per job, finished
// jobs are kept 24 h. Memory only: the bundle (redacted logs) is never written to disk and is dropped once the job
// ends. Separate from the research queue, so an analysis never waits behind a research job.
// Used by the PC routes (`analysis` feature, remote mode on a server) and in-process by incidents (local mode).
import { randomBytes } from "node:crypto";
import { AppError } from "../errors.ts";
import { claudePrint } from "../llm/claude_print.ts";
import { analysisPrompt, newNonce, redactBundle } from "./prompt.ts";
import { outputJsonSchema, validateAnalysis, type AnalysisBundle, type AnalysisResult } from "./schema.ts";

export type AnalysisJobStatus = "queued" | "running" | "done" | "failed";

export interface AnalysisJob {
  id: string;
  status: AnalysisJobStatus;
  createdAt: string;
  startedAt?: string;
  finishedAt?: string;
  error?: { code: string; params: Record<string, unknown> };
  result?: AnalysisResult;
  durationSec?: number;
  /** "device:<id>", "service:<id>" or "incident:<id>" (local mode); a service token only sees its own jobs. */
  requestedBy: string;
  incidentId: string;
}

/** Runs the model on the bundle; returns its raw structured output (validated by the queue). */
export type AnalysisRunner = (b: AnalysisBundle, o: { signal: AbortSignal; timeoutMs: number }) => Promise<unknown>;

export interface AnalysisQueueOptions {
  run?: AnalysisRunner;
  timeoutMs?: number;
  retentionMs?: number;
  maxWaiting?: number;
  now?: () => number;
  log?: (level: "info" | "warn", msg: string, extra?: Record<string, unknown>) => void;
}

/** The default runner: tool-less `claude -p`, bundle as data on stdin, output limited by the JSON schema. */
export const claudeRunner: AnalysisRunner = async (b, o) => {
  const safe = redactBundle(b);
  const r = await claudePrint({
    prompt: analysisPrompt(safe, newNonce()),
    jsonSchema: outputJsonSchema(safe),
    timeoutMs: o.timeoutMs,
    signal: o.signal,
    errorPrefix: "agent.analysis",
  });
  return r.output;
};

const errorOf = (e: unknown) => (e instanceof AppError ? { code: e.code, params: e.params } : { code: "agent.analysis.failed", params: {} });

export class AnalysisQueue {
  readonly timeoutMs: number;
  #o: AnalysisQueueOptions;
  #now: () => number;
  #jobs = new Map<string, AnalysisJob>();
  #bundles = new Map<string, AnalysisBundle>();
  #waiters = new Map<string, Array<() => void>>();
  #queue: string[] = [];
  #running: { id: string; abort: AbortController; done: Promise<void> } | null = null;
  #closed = false;
  #sweepTimer: NodeJS.Timeout;

  constructor(o: AnalysisQueueOptions = {}) {
    this.#o = o;
    this.#now = o.now ?? Date.now;
    this.timeoutMs = o.timeoutMs ?? 180_000;
    this.#sweepTimer = setInterval(() => this.sweep(), 3600_000);
    this.#sweepTimer.unref();
  }

  get(id: string): AnalysisJob | undefined {
    this.sweep();
    return this.#jobs.get(id);
  }

  list(): AnalysisJob[] {
    this.sweep();
    return [...this.#jobs.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  submit(bundle: AnalysisBundle, requestedBy: string): AnalysisJob {
    if (this.#closed) throw new AppError("agent.analysis.busy", 429, { reason: "shutdown" });
    const max = this.#o.maxWaiting ?? 3;
    if (this.#queue.length >= max) throw new AppError("agent.analysis.busy", 429, { waiting: this.#queue.length });
    const job: AnalysisJob = { id: `aj-${randomBytes(8).toString("hex")}`, status: "queued", createdAt: this.#iso(), requestedBy, incidentId: bundle.incident.id };
    this.#jobs.set(job.id, job);
    this.#bundles.set(job.id, bundle);
    this.#queue.push(job.id);
    this.#o.log?.("info", "analiz işi kuyrukta", { id: job.id, by: requestedBy, evidence: bundle.evidence.length });
    this.#pump();
    return job;
  }

  /** Resolves when the job has finished (or immediately if it already has / is unknown). */
  wait(id: string): Promise<AnalysisJob | undefined> {
    const job = this.#jobs.get(id);
    if (!job || job.status === "done" || job.status === "failed") return Promise.resolve(job);
    return new Promise((resolve) => {
      const list = this.#waiters.get(id) ?? [];
      list.push(() => resolve(this.#jobs.get(id)));
      this.#waiters.set(id, list);
    });
  }

  /** Cancels a queued or running job. Returns false if it had already finished. */
  async cancel(id: string): Promise<boolean> {
    const job = this.#jobs.get(id);
    if (!job) return false;
    if (job.status === "queued") {
      this.#queue = this.#queue.filter((x) => x !== id);
      this.#finish(job, { code: "agent.analysis.cancelled", params: {} });
      return true;
    }
    if (job.status === "running" && this.#running?.id === id) {
      const r = this.#running;
      r.abort.abort(new AppError("agent.analysis.cancelled", 500));
      await r.done;
      return true;
    }
    return false;
  }

  async close(): Promise<void> {
    this.#closed = true;
    clearInterval(this.#sweepTimer);
    for (const id of this.#queue.splice(0)) {
      const job = this.#jobs.get(id);
      if (job) this.#finish(job, { code: "agent.analysis.interrupted", params: {} });
    }
    if (this.#running) {
      this.#running.abort.abort(new AppError("agent.analysis.interrupted", 500));
      await this.#running.done;
    }
  }

  sweep(now = this.#now()): void {
    const keep = this.#o.retentionMs ?? 24 * 3600_000;
    for (const j of [...this.#jobs.values()]) {
      if (j.finishedAt && now - Date.parse(j.finishedAt) > keep) this.#jobs.delete(j.id);
    }
  }

  #iso() {
    return new Date(this.#now()).toISOString();
  }

  #finish(job: AnalysisJob, error: AnalysisJob["error"] | null, result?: AnalysisResult) {
    job.status = error ? "failed" : "done";
    job.finishedAt = this.#iso();
    if (error) job.error = error;
    if (result) job.result = result;
    this.#bundles.delete(job.id);
    for (const w of this.#waiters.get(job.id) ?? []) w();
    this.#waiters.delete(job.id);
  }

  #pump() {
    if (this.#running || this.#closed) return;
    const id = this.#queue.shift();
    const job = id ? this.#jobs.get(id) : undefined;
    if (!job) return;
    const abort = new AbortController();
    const done = this.#run(job, abort).finally(() => {
      this.#running = null;
      this.#pump();
    });
    this.#running = { id: job.id, abort, done };
  }

  async #run(job: AnalysisJob, abort: AbortController): Promise<void> {
    const bundle = this.#bundles.get(job.id)!;
    job.status = "running";
    job.startedAt = this.#iso();
    const started = Date.now();
    const timer = setTimeout(() => abort.abort(new AppError("agent.analysis.timeout", 500)), this.timeoutMs);
    try {
      // Raced with the abort signal: a runner that ignores it can't hold the queue past the timeout.
      const aborted = new Promise<never>((_, reject) => abort.signal.addEventListener("abort", () => reject(abort.signal.reason), { once: true }));
      aborted.catch(() => {});
      const raw = await Promise.race([(this.#o.run ?? claudeRunner)(bundle, { signal: abort.signal, timeoutMs: this.timeoutMs }), aborted]);
      abort.signal.throwIfAborted();
      let result: AnalysisResult;
      try {
        result = validateAnalysis(raw, bundle);
      } catch {
        throw new AppError("agent.analysis.invalidOutput", 500, {});
      }
      job.durationSec = Math.round((Date.now() - started) / 1000);
      this.#finish(job, null, result);
      this.#o.log?.("info", "analiz işi bitti", { id: job.id, sec: job.durationSec, hypotheses: result.hypotheses.length, dropped: result.dropped });
    } catch (e) {
      const err = abort.signal.aborted ? errorOf(abort.signal.reason) : errorOf(e);
      this.#finish(job, err);
      this.#o.log?.("warn", "analiz işi başarısız", { id: job.id, code: err.code });
    } finally {
      clearTimeout(timer);
    }
  }
}
