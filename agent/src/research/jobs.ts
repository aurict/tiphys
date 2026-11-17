// Research job queue and pipeline (PLAN.md §12): one job runs at a time, at most 5 wait.
// Per job: Gemini (agy) drafts → Claude edits (optional) → one bounded follow-up round → cleaned result.
// Each job works in its own 0700 directory; results and directories are kept for 24 h after the job ends.
import { randomBytes } from "node:crypto";
import { chmod, mkdir, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { AppError } from "../errors.ts";
import { editorPrompt, researchPrompt } from "./prompts.ts";
import { runTool } from "./run.ts";
import { draftJsonSchema, draftOutputSchema, editorJsonSchema, editorOutputSchema, type Item, type JobInput } from "./schema.ts";
import { MAX_URL_LENGTH, MCP_PACKAGES, MCP_TOOLS, normalizeUrl, parseAgyStream, parseClaudeStream, UrlSet } from "./streams.ts";

export const RESEARCH_MODEL = "gemini-4-argon-high";
export const EDITOR_MODEL = "claude-sonnet";

export type JobStatus = "queued" | "running" | "done" | "failed";

export interface JobError {
  code: string;
  params: Record<string, unknown>;
}

export interface JobResult {
  items: Item[];
  seenUrls: string[];
  models: { research: string; editor?: string };
  timings: { researchSec: number; editorSec?: number };
}

export interface Job {
  id: string;
  status: JobStatus;
  createdAt: string;
  startedAt?: string;
  finishedAt?: string;
  error?: JobError;
  result?: JobResult;
  input: JobInput;
  /** "device:<id>" or "service:<id>"; a service token only sees its own jobs. */
  requestedBy: string;
}

export interface ResearchOptions {
  /** Parent of the per-job work directories. */
  root: string;
  /** JSON file with recent jobs (null: memory only). */
  statePath: string | null;
  /** Claude Code user config; the env of its searxng/firecrawl MCP entries is used (packages are pinned here). */
  claudeJsonPath: string;
  jobTimeoutMs: number;
  killGraceMs: number;
  retentionMs: number;
  maxWaiting: number;
  log: (level: "info" | "warn" | "debug", msg: string, extra?: Record<string, unknown>) => void;
}

export function defaultWorkRoot(): string {
  const rt = process.env.XDG_RUNTIME_DIR;
  return rt ? join(rt, "tiphys", "research") : join(homedir(), ".cache", "tiphys", "research");
}

export function defaultOptions(statePath: string | null, log: ResearchOptions["log"]): ResearchOptions {
  return {
    root: defaultWorkRoot(),
    statePath,
    claudeJsonPath: join(homedir(), ".claude.json"),
    jobTimeoutMs: 20 * 60_000,
    killGraceMs: 5000,
    retentionMs: 24 * 3600_000,
    maxWaiting: 5,
    log,
  };
}

const errorOf = (e: unknown): JobError =>
  e instanceof AppError ? { code: e.code, params: e.params } : { code: "agent.research.failed", params: {} };

// ---- URL helpers ----

const sameish = (u: string) => u.replace(/\/+$/, "").replace(/^https?:\/\/(www\.)?/, "");
const inDomains = (host: string, domains: string[]) => domains.some((d) => host === d || host.endsWith(`.${d}`));

/** Enforces the job's rules on model output, whatever the models did. */
export { normalizeUrl };

/** agy permission rules: only the listed MCP tools (headless agy soft-denies everything else). */
export const agyMcpAllow = () => Object.entries(MCP_TOOLS).flatMap(([server, tools]) => Object.keys(tools).map((t) => `mcp(${server}/${t})`));
/** claude --allowedTools entries for the same tools (other MCP tools are denied in -p mode). */
export const claudeMcpAllow = () => Object.entries(MCP_TOOLS).flatMap(([server, tools]) => Object.keys(tools).map((t) => `mcp__${server}__${t}`));

export function cleanItems(items: Item[], job: JobInput): Item[] {
  const excluded = new Set(job.excludeUrls.map((u) => sameish(normalizeUrl(u) ?? u)));
  const used = new Set<string>();
  const out: Item[] = [];
  for (const it of items) {
    const headline = it.headline.trim().slice(0, 300);
    const summary = it.summary.trim().slice(0, 1500);
    if (!headline || !summary) continue;
    const urls = it.sources.map((s) => ({ title: s.title.trim().slice(0, 300), url: s.url.length > MAX_URL_LENGTH ? null : normalizeUrl(s.url) }));
    // Already sent story (any of its sources was sent before) → dropped entirely.
    if (urls.some((s) => s.url && excluded.has(sameish(s.url)))) continue;
    const sources: Item["sources"] = [];
    for (const s of urls) {
      if (!s.url) continue;
      const host = new URL(s.url).hostname.toLowerCase();
      if (inDomains(host, job.blockDomains)) continue;
      if (job.allowDomains.length && !inDomains(host, job.allowDomains)) continue;
      if (sources.some((x) => sameish(x.url) === sameish(s.url!))) continue;
      sources.push({ title: s.title || host, url: s.url });
    }
    if (sources.length === 0) continue;
    // Duplicate story: shares a source with an item already kept.
    if (sources.some((s) => used.has(sameish(s.url)))) continue;
    sources.splice(job.maxSourcesPerItem);
    for (const s of sources) used.add(sameish(s.url));
    out.push({ headline, summary, ...(it.published?.trim() ? { published: it.published.trim().slice(0, 64) } : {}), sources });
    if (out.length >= job.maxItems) break;
  }
  return out;
}

export class ResearchService {
  readonly o: ResearchOptions;
  #jobs = new Map<string, Job>();
  #queue: string[] = [];
  #running: { id: string; abort: AbortController; done: Promise<void> } | null = null;
  #closed = false;
  #saveChain = Promise.resolve();
  #sweepTimer: NodeJS.Timeout | undefined;

  private constructor(o: ResearchOptions) {
    this.o = o;
  }

  /** Loads recent jobs (a job that was queued/running when the agent stopped is marked failed). */
  static async open(o: ResearchOptions): Promise<ResearchService> {
    const s = new ResearchService(o);
    if (o.statePath) {
      const raw = await readFile(o.statePath, "utf8").catch(() => null);
      const jobs = raw ? ((JSON.parse(raw) as { jobs?: Job[] }).jobs ?? []) : [];
      for (const j of jobs) {
        if (j.status === "queued" || j.status === "running") {
          j.status = "failed";
          j.error = { code: "agent.research.interrupted", params: {} };
          j.finishedAt ??= new Date().toISOString();
        }
        s.#jobs.set(j.id, j);
      }
    }
    await s.sweep();
    s.#sweepTimer = setInterval(() => void s.sweep().catch((e) => o.log("warn", "araştırma temizliği başarısız", { err: String(e) })), 3600_000);
    s.#sweepTimer.unref();
    return s;
  }

  get(id: string): Job | undefined {
    return this.#jobs.get(id);
  }

  list(): Job[] {
    return [...this.#jobs.values()].sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  submit(input: JobInput, requestedBy: string): Job {
    if (this.#closed) throw new AppError("agent.research.busy", 429, { reason: "shutdown" });
    if (this.#queue.length >= this.o.maxWaiting) throw new AppError("agent.research.busy", 429, { waiting: this.#queue.length });
    const job: Job = { id: `rj-${randomBytes(8).toString("hex")}`, status: "queued", createdAt: new Date().toISOString(), input, requestedBy };
    this.#jobs.set(job.id, job);
    this.#queue.push(job.id);
    this.o.log("info", "araştırma işi kuyrukta", { id: job.id, by: requestedBy, editor: input.editor, maxItems: input.maxItems });
    this.#save();
    this.#pump();
    return job;
  }

  /** Cancels a queued or running job (kills its processes). Returns false if it had already finished. */
  async cancel(id: string): Promise<boolean> {
    const job = this.#jobs.get(id);
    if (!job) return false;
    if (job.status === "queued") {
      this.#queue = this.#queue.filter((x) => x !== id);
      this.#finish(job, { code: "agent.research.cancelled", params: {} });
      return true;
    }
    if (job.status === "running" && this.#running?.id === id) {
      const r = this.#running;
      r.abort.abort(new AppError("agent.research.cancelled", 500));
      await r.done;
      return true;
    }
    return false;
  }

  /** Agent shutdown: kills the running job, fails queued ones, writes the state file. */
  async close(): Promise<void> {
    this.#closed = true;
    clearInterval(this.#sweepTimer);
    for (const id of this.#queue.splice(0)) {
      const job = this.#jobs.get(id);
      if (job) this.#finish(job, { code: "agent.research.interrupted", params: {} });
    }
    if (this.#running) {
      this.#running.abort.abort(new AppError("agent.research.interrupted", 500));
      await this.#running.done;
    }
    await this.#saveChain;
  }

  /** Drops jobs (and work dirs) finished longer than the retention ago, and orphan dirs older than that. */
  async sweep(now = Date.now()): Promise<void> {
    let changed = false;
    for (const j of [...this.#jobs.values()]) {
      if (j.finishedAt && now - Date.parse(j.finishedAt) > this.o.retentionMs) {
        this.#jobs.delete(j.id);
        await rm(join(this.o.root, j.id), { recursive: true, force: true });
        changed = true;
      }
    }
    for (const name of await readdir(this.o.root).catch(() => [] as string[])) {
      if (this.#jobs.has(name) || !/^rj-[a-f0-9]{16}$/.test(name)) continue;
      const st = await stat(join(this.o.root, name)).catch(() => null);
      if (st && now - st.mtimeMs > this.o.retentionMs) await rm(join(this.o.root, name), { recursive: true, force: true });
    }
    if (changed) this.#save();
  }

  #save() {
    const path = this.o.statePath;
    if (!path) return;
    const snapshot = JSON.stringify({ jobs: [...this.#jobs.values()] });
    this.#saveChain = this.#saveChain
      .then(async () => {
        const tmp = `${path}.${process.pid}.tmp`;
        await writeFile(tmp, snapshot, { mode: 0o600 });
        await rename(tmp, path);
      })
      .catch((e) => this.o.log("warn", "araştırma durumu yazılamadı", { err: String(e) }));
  }

  #finish(job: Job, error: JobError | null, result?: JobResult) {
    job.status = error ? "failed" : "done";
    job.finishedAt = new Date().toISOString();
    if (error) job.error = error;
    if (result) job.result = result;
    this.#save();
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

  async #run(job: Job, abort: AbortController): Promise<void> {
    job.status = "running";
    job.startedAt = new Date().toISOString();
    this.#save();
    const started = Date.now();
    const deadline = started + this.o.jobTimeoutMs;
    const timer = setTimeout(() => abort.abort(new AppError("agent.research.timeout", 500)), this.o.jobTimeoutMs);
    const dir = join(this.o.root, job.id);
    try {
      await mkdir(this.o.root, { recursive: true, mode: 0o700 });
      await mkdir(dir, { mode: 0o700 });
      await chmod(dir, 0o700);
      const result = await this.#pipeline(job.input, dir, abort.signal, deadline);
      this.#finish(job, null, result);
      this.o.log("info", "araştırma işi bitti", { id: job.id, items: result.items.length, sec: Math.round((Date.now() - started) / 1000) });
    } catch (e) {
      const err = abort.signal.aborted ? errorOf(abort.signal.reason) : errorOf(e);
      this.#finish(job, err);
      this.o.log("warn", "araştırma işi başarısız", { id: job.id, code: err.code, ...(e instanceof AppError ? {} : { err: String(e) }) });
    } finally {
      clearTimeout(timer);
    }
  }

  async #pipeline(job: JobInput, dir: string, signal: AbortSignal, deadline: number): Promise<JobResult> {
    const now = new Date();
    // Only URLs from successful searxng/firecrawl tool outputs (see streams.ts), never model-written text.
    const seen = new UrlSet();
    const run = (tool: string, args: string[]) =>
      runTool(tool, args, { cwd: dir, signal, timeoutMs: Math.max(1, deadline - Date.now()), killGraceMs: this.o.killGraceMs });
    await writeFile(join(dir, "draft.schema.json"), JSON.stringify(draftJsonSchema), { mode: 0o600 });

    let researchMs = 0;
    let editorMs = 0;
    const gemini = async (extra: { followups?: string[]; existing?: Item[] } = {}): Promise<Item[]> => {
      const t = Date.now();
      const settings = JSON.stringify({
        permissions: { allow: [...agyMcpAllow(), `write_file(${dir})`], deny: ["command(*)"] },
      });
      const prompt = researchPrompt(job, { dir, now, ...extra });
      this.o.log("debug", "agy başlıyor", { promptChars: prompt.length });
      const r = await run("agy", [
        "-p", prompt,
        "--model", RESEARCH_MODEL,
        "--add-dir", dir,
        "--project", "tiphys-research",
        "--settings", settings,
        "--output-format", "stream-json",
        "--json-schema", join(dir, "draft.schema.json"),
        "--print-timeout", "15m",
      ]);
      researchMs += Date.now() - t;
      const parsed = draftOutputSchema.safeParse(parseAgyStream(r.stdout, r.code, seen));
      if (!parsed.success) throw new AppError("agent.research.invalidOutput", 500, { tool: "agy" });
      return parsed.data.items;
    };

    const editor = async (items: Item[], final: boolean) => {
      const t = Date.now();
      // Inline (never a file in the job dir, which the editor can Read): the MCP config holds API keys.
      const mcpConfig = JSON.stringify({ mcpServers: await this.#mcpServers() });
      await writeFile(join(dir, "draft.json"), JSON.stringify({ items }, null, 2), { mode: 0o600 });
      try {
        const r = await run("claude", [
          "-p", editorPrompt(job, { dir, now, final }),
          "--model", "sonnet",
          "--setting-sources", "",
          "--strict-mcp-config",
          "--mcp-config", mcpConfig,
          "--tools", "Read", "Write",
          "--allowedTools", ...claudeMcpAllow(), `Read(/${dir}/**)`, `Edit(/${dir}/**)`,
          "--permission-mode", "default",
          "--output-format", "stream-json",
          "--verbose",
          "--json-schema", JSON.stringify(editorJsonSchema),
        ]);
        const parsed = editorOutputSchema.safeParse(parseClaudeStream(r.stdout, r.code, seen));
        if (!parsed.success) throw new AppError("agent.research.invalidOutput", 500, { tool: "claude" });
        return parsed.data;
      } finally {
        editorMs += Date.now() - t;
      }
    };

    let items = await gemini();
    if (job.editor) {
      const first = await editor(items, false);
      items = first.items;
      // One bounded extra round when the editor asks for more and the digest is short.
      if (first.followups.length > 0 && cleanItems(items, job).length < job.minItems) {
        const more = await gemini({ followups: first.followups.slice(0, 3), existing: items });
        items = (await editor([...items, ...more], true)).items;
      }
    }
    return {
      items: cleanItems(items, job),
      seenUrls: [...seen.urls],
      models: { research: RESEARCH_MODEL, ...(job.editor ? { editor: EDITOR_MODEL } : {}) },
      timings: { researchSec: Math.round(researchMs / 1000), ...(job.editor ? { editorSec: Math.round(editorMs / 1000) } : {}) },
    };
  }

  /**
   * searxng and firecrawl as pinned npx packages; only their env (service URLs, API key) comes from the user's
   * Claude config. Values are never logged.
   */
  async #mcpServers(): Promise<Record<string, unknown>> {
    const raw = await readFile(this.o.claudeJsonPath, "utf8").catch(() => null);
    const all = raw ? ((JSON.parse(raw) as { mcpServers?: Record<string, { env?: unknown }> }).mcpServers ?? {}) : {};
    const out: Record<string, unknown> = {};
    for (const [name, pkg] of Object.entries(MCP_PACKAGES)) {
      const entry = Object.hasOwn(all, name) ? all[name] : undefined;
      if (!entry) throw new AppError("agent.research.mcpMissing", 500, { server: name });
      const env = entry.env && typeof entry.env === "object" ? entry.env : {};
      out[name] = { type: "stdio", command: "npx", args: ["-y", pkg], env };
    }
    return out;
  }
}
