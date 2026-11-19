// Secret scanning (PLAN.md §15 S-2). Findings never contain the secret: only where (repo/file/line/commit or log host/
// stream/time) and which rule.
//   github: gitleaks (pinned container, no network, read-only) over bare clones of the configured owners' repositories
//           (public ones without a token; private ones with a contents:read token, passed to git only through its
//           environment). A repository is rescanned only when its default branch head moved.
//   loki:   the last 24 hours of every host's logs from Loki through `gitleaks stdin`.
//   local:  (any agent, e.g. the PC) git-tracked files under security.scanners.localRoots, matched with the agent's own
//           redaction patterns for well-known key formats; nothing leaves the machine but the location.
import { createHash } from "node:crypto";
import { chmod, lstat, mkdtemp, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join, relative } from "node:path";
import { allowedPath } from "../paths.ts";
import { AppError } from "../errors.ts";
import { expandHome } from "../config.ts";
import { redact } from "../redact.ts";
import type { Ctx } from "../server.ts";
import { readCapped, spawnCapped, type Spawner } from "./collect.ts";
import type { Fetch } from "./collect.ts";

export const GITLEAKS_IMAGE = "zricethezav/gitleaks@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"; // v8.30.1
const MAX_REPOS = 200;
const LOKI_LINES_PER_HOST = 50_000;
const LOKI_BYTES_PER_HOST = 32 * 1024 * 1024;

export type SecretSource = "github" | "loki" | "local";

export interface SecretFinding {
  id: string;
  source: SecretSource;
  rule: string;
  /** github: owner/repo; loki: host; local: repo dir (relative to its root). */
  where: string;
  file: string | null;
  line: number | null;
  commit: string | null;
  /** loki: the stream's labels (container/unit) and the log time. */
  stream: string | null;
  at: string | null;
  firstSeenAt: string;
  dismissed: boolean;
}

const sha = (s: string) => createHash("sha256").update(s).digest("hex").slice(0, 24);
const clip = (s: unknown, n: number) => String(s ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, n);

export interface GitleaksHit {
  RuleID?: string;
  File?: string;
  StartLine?: number;
  Commit?: string;
  Date?: string;
}

/** gitleaks JSON report → hits; Secret/Match fields are dropped here, whatever they contain. */
export function parseGitleaks(json: string): GitleaksHit[] {
  const data = JSON.parse(json || "[]") as Array<Record<string, unknown>>;
  if (!Array.isArray(data)) throw new Error("not a report");
  return data.map((h) => ({
    RuleID: clip(h.RuleID, 80),
    File: clip(h.File, 300),
    StartLine: typeof h.StartLine === "number" ? h.StartLine : undefined,
    Commit: clip(h.Commit, 40),
    Date: clip(h.Date, 40),
  }));
}

export function gitleaksArgs(mode: "git" | "stdin", mount: string | null): string[] {
  const args = ["run", "--rm", "-i", "--network", "none", "--read-only", "--memory", "1g", "--cpus", "1", "--security-opt", "no-new-privileges"];
  if (mount) args.push("-v", `${mount}:/repo:ro`, "-e", "GIT_CONFIG_COUNT=1", "-e", "GIT_CONFIG_KEY_0=safe.directory", "-e", "GIT_CONFIG_VALUE_0=*");
  args.push(GITLEAKS_IMAGE, mode);
  if (mode === "git") args.push("/repo");
  args.push("--redact", "--no-banner", "--no-color", "--log-level", "error", "--report-format", "json", "--report-path", "-", "--exit-code", "0");
  return args;
}

/** Tagged redaction rules only (PEM, JWT, AWS, GitHub, Stripe, Slack, Google, API keys, Tiphys tokens): the generic
 * key=value rule would flag every `password = form.password`. Returns the tags found in the line. */
export function localRules(line: string): string[] {
  const out = redact(line);
  if (out === line) return [];
  return [...new Set([...out.matchAll(/\[GİZLİ:([A-Z]+)\]/g)].map((m) => m[1]!.toLowerCase()))];
}

interface State {
  findings: Record<string, SecretFinding>;
  repos: Record<string, { head: string; scannedAt: string; error?: string }>;
  lastRun: { at: string; github: string | null; loki: string | null; local: string | null } | null;
}

export interface SecretOpts {
  spawner?: Spawner;
  /** Runs `gitleaks stdin` on the data and returns its JSON report (tests replace it). */
  gitleaksStdin?: (data: string) => Promise<string>;
  fetch?: Fetch;
  now?: () => number;
}

export class SecretScanner {
  readonly file: string;
  state: State = { findings: {}, repos: {}, lastRun: null };
  #ctx: Ctx;
  #o: SecretOpts;
  #busy: Promise<unknown> | null = null;
  #save: Promise<void> = Promise.resolve();

  constructor(ctx: Ctx, o: SecretOpts = {}) {
    this.#ctx = ctx;
    this.#o = o;
    this.file = join(dirname(ctx.store.path), "security-secrets.json");
  }

  #now() {
    return this.#o.now?.() ?? Date.now();
  }

  get running() {
    return this.#busy !== null;
  }

  async load() {
    const raw = await readFile(this.file, "utf8").catch(() => null);
    if (!raw) return;
    try {
      const s = JSON.parse(raw) as State;
      this.state = { findings: s.findings ?? {}, repos: s.repos ?? {}, lastRun: s.lastRun ?? null };
    } catch {
      await rename(this.file, `${this.file}.corrupt-${Date.now()}`).catch(() => {});
    }
  }

  async #persist() {
    const data = JSON.stringify(this.state);
    this.#save = this.#save.catch(() => {}).then(async () => {
      const tmp = `${this.file}.${process.pid}.tmp`;
      await writeFile(tmp, data, { mode: 0o600 });
      await chmod(tmp, 0o600);
      await rename(tmp, this.file);
    });
    await this.#save.catch(() => {});
  }

  /** Records hits; returns the ones not seen before. */
  #record(hits: Omit<SecretFinding, "id" | "firstSeenAt" | "dismissed">[]): SecretFinding[] {
    const fresh: SecretFinding[] = [];
    const nowIso = new Date(this.#now()).toISOString();
    for (const h of hits) {
      // Loki lines move every day; their identity is host + stream + rule + time.
      const id = sha([h.source, h.where, h.file ?? "", h.source === "local" ? "" : (h.line ?? ""), h.commit ?? "", h.stream ?? "", h.at ?? "", h.rule].join("|"));
      const known = this.state.findings[id];
      if (known) {
        if (h.source === "local") known.line = h.line; // lines added above a finding move it
        continue;
      }
      const f = { ...h, id, firstSeenAt: nowIso, dismissed: false };
      this.state.findings[id] = f;
      fresh.push(f);
    }
    return fresh;
  }

  async run(): Promise<{ fresh: number }> {
    if (this.#busy) throw new AppError("agent.security.scanBusy", 409);
    const job = this.#run();
    this.#busy = job;
    try {
      return await job;
    } finally {
      this.#busy = null;
    }
  }

  async #run(): Promise<{ fresh: number }> {
    const sc = this.#ctx.store.get().security.scanners;
    const lastRun = { at: new Date(this.#now()).toISOString(), github: null as string | null, loki: null as string | null, local: null as string | null };
    const fresh: SecretFinding[] = [];
    if (sc.gitleaks && sc.github.owners.length) fresh.push(...(await this.#github().catch((e) => ((lastRun.github = errCode(e)), []))));
    if (sc.gitleaks && sc.loki) fresh.push(...(await this.#loki().catch((e) => ((lastRun.loki = errCode(e)), []))));
    if (sc.localRoots.length) fresh.push(...(await this.#local().catch((e) => ((lastRun.local = errCode(e)), []))));
    this.state.lastRun = lastRun;
    await this.#persist();
    if (fresh.length) {
      const sources = [...new Set(fresh.map((f) => f.source))].join(",");
      const where = [...new Set(fresh.map((f) => f.where))].slice(0, 3).join(", ");
      await this.#ctx.notifier.send({
        key: "security.secretFound",
        params: { host: this.#ctx.store.get().name, agent: this.#ctx.store.get().name, count: fresh.length, sources, where: clip(where, 140) },
        link: "tiphys://security/secrets",
        priority: "high",
      });
    }
    return { fresh: fresh.length };
  }

  async #api(path: string, token: string | null): Promise<unknown> {
    const f = this.#o.fetch ?? fetch;
    const res = await f(`https://api.github.com${path}`, {
      headers: { accept: "application/vnd.github+json", "user-agent": "tiphys-agent", ...(token ? { authorization: `Bearer ${token}` } : {}) },
      signal: AbortSignal.timeout(30_000),
      redirect: "error",
    });
    if (res.status === 401 || res.status === 403) throw new AppError("agent.security.githubUnauthorized", 502, { status: res.status });
    if (!res.ok) throw new AppError("agent.security.githubFailed", 502, { status: res.status });
    return JSON.parse(await readCapped(res, 8 * 1024 * 1024, "agent.security.githubFailed"));
  }

  async #repos(): Promise<{ full: string; branch: string; private: boolean }[]> {
    const { owners, token } = this.#ctx.store.get().security.scanners.github;
    const out = new Map<string, { full: string; branch: string; private: boolean }>();
    const want = new Set(owners.map((o) => o.toLowerCase()));
    const add = (list: unknown) => {
      for (const r of Array.isArray(list) ? (list as Array<Record<string, unknown>>) : []) {
        const full = String(r.full_name ?? "");
        const owner = full.split("/")[0]!.toLowerCase();
        if (!/^[A-Za-z0-9-]{1,39}\/[A-Za-z0-9._-]{1,100}$/.test(full) || !want.has(owner) || r.fork) continue;
        out.set(full, { full, branch: String(r.default_branch ?? "main"), private: !!r.private });
      }
    };
    if (token) for (let p = 1; p <= 5; p++) {
      const page = await this.#api(`/user/repos?per_page=100&page=${p}&affiliation=owner,organization_member`, token);
      add(page);
      if (!Array.isArray(page) || page.length < 100) break;
    }
    for (const o of owners) add(await this.#api(`/users/${o}/repos?per_page=100&type=owner`, token));
    return [...out.values()].slice(0, MAX_REPOS);
  }

  #gitEnv(token: string | null): Record<string, string> {
    const env: Record<string, string> = { GIT_TERMINAL_PROMPT: "0", GIT_ASKPASS: "/bin/false" };
    if (token) {
      env.GIT_CONFIG_COUNT = "1";
      env.GIT_CONFIG_KEY_0 = "http.https://github.com/.extraheader";
      env.GIT_CONFIG_VALUE_0 = `AUTHORIZATION: basic ${Buffer.from(`x-access-token:${token}`).toString("base64")}`;
    }
    return env;
  }

  async #github(): Promise<Omit<SecretFinding, never>[]> {
    const { token } = this.#ctx.store.get().security.scanners.github;
    const sp = this.#o.spawner ?? spawnCapped;
    const env = this.#gitEnv(token);
    const fresh: SecretFinding[] = [];
    for (const repo of await this.#repos()) {
      const url = `https://github.com/${repo.full}.git`;
      const head = await sp("git", ["ls-remote", "--", url, `refs/heads/${repo.branch}`], { timeoutMs: 60_000, maxBytes: 1 << 20, env });
      const sha1 = head.code === 0 ? head.stdout.split(/\s/)[0] ?? "" : "";
      const prev = this.state.repos[repo.full];
      if (sha1 && prev?.head === sha1 && !prev.error) continue;
      const dir = await mkdtemp(join(tmpdir(), "tiphys-gitleaks-"));
      try {
        const clone = await sp("git", ["clone", "--bare", "--quiet", "--", url, join(dir, "r.git")], { timeoutMs: 10 * 60_000, maxBytes: 1 << 20, env });
        if (clone.code !== 0) {
          this.state.repos[repo.full] = { head: sha1, scannedAt: new Date(this.#now()).toISOString(), error: "cloneFailed" };
          continue;
        }
        const r = await sp("docker", gitleaksArgs("git", join(dir, "r.git")), { timeoutMs: 20 * 60_000, maxBytes: 32 << 20 });
        let hits: GitleaksHit[];
        try {
          if (r.code !== 0) throw new Error("gitleaks");
          hits = parseGitleaks(r.stdout);
        } catch {
          this.state.repos[repo.full] = { head: sha1, scannedAt: new Date(this.#now()).toISOString(), error: "scanFailed" };
          continue;
        }
        fresh.push(
          ...this.#record(
            hits.map((h) => ({ source: "github" as const, rule: h.RuleID || "unknown", where: repo.full, file: h.File || null, line: h.StartLine ?? null, commit: h.Commit ? h.Commit.slice(0, 12) : null, stream: null, at: h.Date || null })),
          ),
        );
        this.state.repos[repo.full] = { head: sha1, scannedAt: new Date(this.#now()).toISOString() };
      } finally {
        await rm(dir, { recursive: true, force: true }).catch(() => {});
      }
    }
    return fresh;
  }

  #lokiUrl(): Promise<string> {
    return lokiBaseUrl(this.#ctx, this.#o.spawner);
  }

  async #lokiGet(base: string, path: string, q: Record<string, string>): Promise<Record<string, unknown>> {
    const f = this.#o.fetch ?? fetch;
    const res = await f(`${base}${path}?${new URLSearchParams(q)}`, { signal: AbortSignal.timeout(60_000) });
    if (!res.ok) throw new AppError("agent.security.lokiFailed", 502, { status: res.status });
    return JSON.parse(await readCapped(res, 64 * 1024 * 1024, "agent.security.lokiFailed")) as Record<string, unknown>;
  }

  async #loki(): Promise<SecretFinding[]> {
    const base = await this.#lokiUrl();
    const end = this.#now() * 1_000_000;
    const start = end - 24 * 3600 * 1e9;
    const hostsResp = await this.#lokiGet(base, "/loki/api/v1/label/host/values", { start: String(start), end: String(end) });
    const hosts = (Array.isArray(hostsResp.data) ? (hostsResp.data as unknown[]) : []).map(String).filter((h) => /^[A-Za-z0-9._-]{1,100}$/.test(h));
    const fresh: SecretFinding[] = [];
    for (const host of hosts) {
      const lines: string[] = [];
      const meta: { stream: string; at: string }[] = [];
      let from = start;
      let bytes = 0;
      while (lines.length < LOKI_LINES_PER_HOST && bytes < LOKI_BYTES_PER_HOST) {
        const resp = await this.#lokiGet(base, "/loki/api/v1/query_range", { query: `{host="${host}"}`, start: String(from), end: String(end), limit: "5000", direction: "forward" });
        const result = ((resp.data as { result?: unknown[] } | undefined)?.result ?? []) as Array<{ stream?: Record<string, string>; values?: [string, string][] }>;
        const batch: { ts: number; stream: string; line: string }[] = [];
        for (const s of result) {
          const label = clip(s.stream?.container ?? s.stream?.unit ?? s.stream?.service_name ?? "", 80);
          for (const [ts, line] of s.values ?? []) batch.push({ ts: Number(ts), stream: label, line });
        }
        if (!batch.length) break;
        batch.sort((a, b) => a.ts - b.ts);
        for (const b of batch) {
          const l = b.line.replace(/\r?\n/g, " ");
          lines.push(l);
          meta.push({ stream: b.stream, at: new Date(Math.floor(b.ts / 1e6)).toISOString() });
          bytes += l.length + 1;
        }
        const last = batch[batch.length - 1]!.ts;
        if (batch.length < 5000 || last + 1 >= end) break;
        from = last + 1;
      }
      if (!lines.length) continue;
      const r = await this.#gitleaksStdin(lines.join("\n") + "\n");
      fresh.push(
        ...this.#record(
          r.flatMap((h) => {
            const m = h.StartLine ? meta[h.StartLine - 1] : undefined;
            return m ? [{ source: "loki" as const, rule: h.RuleID || "unknown", where: host, file: null, line: null, commit: null, stream: m.stream, at: m.at }] : [];
          }),
        ),
      );
    }
    return fresh;
  }

  /** gitleaks stdin needs the data on stdin; spawnCapped ignores stdin, so this one pipes it. */
  async #gitleaksStdin(data: string): Promise<GitleaksHit[]> {
    if (this.#o.gitleaksStdin) return parseGitleaks(await this.#o.gitleaksStdin(data));
    const { spawn } = await import("node:child_process");
    const out = await new Promise<{ code: number; stdout: string }>((resolve, reject) => {
      const child = spawn("docker", gitleaksArgs("stdin", null), { stdio: ["pipe", "pipe", "ignore"] });
      const chunks: Buffer[] = [];
      const timer = setTimeout(() => child.kill("SIGKILL"), 15 * 60_000);
      child.stdout.on("data", (d: Buffer) => chunks.push(d));
      child.on("error", (e) => (clearTimeout(timer), reject(e)));
      child.on("close", (code) => (clearTimeout(timer), resolve({ code: code ?? -1, stdout: Buffer.concat(chunks).toString("utf8") })));
      child.stdin.on("error", () => {});
      child.stdin.end(data);
    });
    if (out.code !== 0) throw new AppError("agent.security.scanFailed", 502);
    return parseGitleaks(out.stdout);
  }

  async #local(): Promise<SecretFinding[]> {
    const fresh: SecretFinding[] = [];
    const sp = this.#o.spawner ?? spawnCapped;
    for (const r of this.#ctx.store.get().security.scanners.localRoots) {
      let root: string;
      try {
        root = await allowedPath(this.#ctx.store.get(), r);
      } catch {
        continue;
      }
      // The root itself or its direct subdirectories that are git repositories.
      const ls = await sp("git", ["-C", root, "rev-parse", "--show-toplevel"], { timeoutMs: 10_000, maxBytes: 4096 });
      const repos: string[] = [];
      if (ls.code === 0) repos.push(root);
      else {
        const { readdir } = await import("node:fs/promises");
        for (const d of await readdir(root, { withFileTypes: true }).catch(() => [])) {
          if (d.isDirectory() && !d.name.startsWith(".") && (await stat(join(root, d.name, ".git")).catch(() => null))) repos.push(join(root, d.name));
        }
      }
      for (const repo of repos.slice(0, 100)) {
        const files = await sp("git", ["-C", repo, "ls-files", "-z"], { timeoutMs: 30_000, maxBytes: 16 << 20 });
        if (files.code !== 0) continue;
        const where = relative(expandHome("~"), repo) || repo;
        for (const f of files.stdout.split("\0").filter(Boolean).slice(0, 20_000)) {
          const p = join(repo, f);
          // lstat: a tracked symlink may point outside the repository; it is not followed.
          const st = await lstat(p).catch(() => null);
          if (!st?.isFile() || st.size > 512 * 1024) continue;
          const buf = await readFile(p).catch(() => null);
          if (!buf || buf.includes(0)) continue;
          const hits: Omit<SecretFinding, "id" | "firstSeenAt" | "dismissed">[] = [];
          if (/(^|\/)\.env(\.[^/]*)?$/.test(f) && !/\.(example|sample|template|dist)$/.test(f)) {
            hits.push({ source: "local", rule: "env-file-tracked", where, file: f, line: null, commit: null, stream: null, at: null });
          }
          const nth = new Map<string, number>();
          buf.toString("utf8")
            .split("\n")
            .forEach((line, i) => {
              for (const rule of localRules(line)) {
                const n = (nth.get(rule) ?? 0) + 1;
                nth.set(rule, n);
                // `commit` carries the occurrence number for local findings: the identity survives lines added above.
                hits.push({ source: "local", rule, where, file: f, line: i + 1, commit: `#${n}`, stream: null, at: null });
              }
            });
          fresh.push(...this.#record(hits));
        }
      }
    }
    return fresh;
  }

  /** Dismisses every finding of one source/place/rule (optionally under a path prefix or one log stream). */
  async dismissGroup(g: { source: SecretSource; where: string; rule: string; pathPrefix?: string; stream?: string }, dismissed: boolean): Promise<number> {
    let n = 0;
    for (const f of Object.values(this.state.findings)) {
      if (f.source !== g.source || f.where !== g.where || f.rule !== g.rule) continue;
      // pathPrefix = one folder ("a/"): files directly in it, not in its subfolders.
      if (g.pathPrefix !== undefined) {
        const file = f.file ?? "";
        if (!file.startsWith(g.pathPrefix) || file.slice(g.pathPrefix.length).includes("/")) continue;
      }
      if (g.stream !== undefined && f.stream !== g.stream) continue;
      if (f.dismissed !== dismissed) n++;
      f.dismissed = dismissed;
    }
    await this.#persist();
    return n;
  }

  async dismiss(id: string, dismissed: boolean) {
    const f = this.state.findings[id];
    if (!f) throw new AppError("agent.security.findingNotFound", 404);
    f.dismissed = dismissed;
    await this.#persist();
    return f;
  }

  list() {
    return {
      lastRun: this.state.lastRun,
      running: this.running,
      repos: Object.entries(this.state.repos).map(([repo, r]) => ({ repo, ...r })),
      findings: Object.values(this.state.findings).sort((a, b) => Number(a.dismissed) - Number(b.dismissed) || b.firstSeenAt.localeCompare(a.firstSeenAt)),
    };
  }
}

/** Loki base URL from security.scanners.loki: a container on this machine (IP looked up each time) or a URL. */
export async function lokiBaseUrl(ctx: Ctx, spawner?: Spawner): Promise<string> {
  const l = ctx.store.get().security.scanners.loki;
  if (!l) throw new AppError("agent.security.lokiUnavailable", 409);
  if ("url" in l) return l.url.replace(/\/$/, "");
  const r = await (spawner ?? spawnCapped)("docker", ["inspect", "--format", "{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}", "--", l.container], { timeoutMs: 15_000, maxBytes: 4096 });
  const ip = r.stdout.trim().split(/\s+/).find((x) => /^\d+\.\d+\.\d+\.\d+$/.test(x));
  if (r.code !== 0 || !ip) throw new AppError("agent.security.lokiUnavailable", 502);
  return `http://${ip}:${l.port}`;
}

const errCode = (e: unknown) => (e instanceof AppError ? e.code : "agent.security.scanFailed");
