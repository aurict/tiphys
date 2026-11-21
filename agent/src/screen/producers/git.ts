// `git` topic (PLAN.md §20 A-2): the state of each subscriber's project (project.ts), one watcher per git root shared
// by every subscriber of that root. Non-recursive fs.watch on the git dir (HEAD, index, packed-refs, MERGE_HEAD …),
// refs/heads and refs/remotes/* → 500 ms debounce → ONE `git status --porcelain=v2 --branch` + `git log -3`. Working
// tree edits don't touch .git, so a slow refresh (60 s) catches them until W3's city watcher can trigger it. CI (`gh
// run list`, 5 min, 10 s timeout) only while a subscriber of that root has the CI setting on (default off). Sent:
// the root's basename, branch, ahead/behind, counts and the last 3 commits; no path at all. Unchanged state is not sent.
import { watch as fsWatch } from "node:fs";
import { readFile } from "node:fs/promises";
import { join, resolve } from "node:path";
import type { AgentConfig } from "../../config.ts";
import { whichIn } from "../../detect.ts";
import { run } from "../../exec.ts";
import { allowedPath } from "../../paths.ts";
import { parseStatus } from "../../routes/git.ts";
import type { Sock } from "../source.ts";
import type { Rec } from "./common.ts";
import { gitRootOf, rootLabel, type ProjectSpec } from "./project.ts";

const GIT_ENV = { GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0", GIT_PAGER: "cat" };
/** Files in the git dir whose change means a new state (lock files and objects don't). */
const GIT_FILES = new Set(["HEAD", "index", "packed-refs", "ORIG_HEAD", "MERGE_HEAD", "FETCH_HEAD", "CHERRY_PICK_HEAD", "REBASE_HEAD"]);

export interface GitIo {
  run(cmd: string, args: string[], o: { cwd?: string; timeoutMs: number }): Promise<{ stdout: string; code: number }>;
  watch(dir: string, fn: (file: string | null) => void): { close(): void };
  read(path: string): Promise<string | null>;
  list(dir: string): Promise<string[]>;
  has(cmd: string): boolean;
}

export const realGitIo: GitIo = {
  run: (cmd, args, o) => run(cmd, args, { ...o, env: GIT_ENV, allowFail: true }).catch(() => ({ stdout: "", code: -1 })),
  watch: (dir, fn) => {
    const w = fsWatch(dir, { persistent: false }, (_ev, f) => fn(typeof f === "string" ? f : null));
    w.on("error", () => w.close());
    return w;
  },
  read: (p) => readFile(p, "utf8").catch(() => null),
  list: async (d) => (await import("node:fs/promises")).readdir(d).catch(() => []),
  has: (cmd) => whichIn(process.env.PATH, cmd),
};

export interface Commit {
  hash7: string;
  subject: string;
  at: number;
}

/** `git log --format=%h%x1f%s%x1f%ct%x1e` → commits (subject ≤ 80, at in ms). */
export function parseCommits(out: string): Commit[] {
  return out
    .split("\x1e")
    .map((r) => r.trim())
    .filter(Boolean)
    .map((r) => {
      const [h = "", s = "", t = "0"] = r.split("\x1f");
      return { hash7: h.slice(0, 7), subject: s.length > 80 ? `${s.slice(0, 79)}…` : s, at: Number(t) * 1000 };
    });
}

/** Porcelain v2 + commits → the git message. */
export function gitMessage(root: string, porcelain: string, commits: Commit[], ci: Rec | null): Rec {
  const s = parseStatus(porcelain);
  const changed = s.files.filter((f) => !f.untracked && !f.conflicted).length;
  return {
    type: "git",
    root: rootLabel(root),
    branch: s.branch,
    head: s.head ? s.head.slice(0, 7) : null,
    upstream: s.upstream !== null,
    ahead: s.ahead,
    behind: s.behind,
    changed,
    untracked: s.files.filter((f) => f.untracked).length,
    conflicts: s.files.filter((f) => f.conflicted).length,
    commits,
    ci,
  };
}

/** `gh run list --json status,conclusion,createdAt` → CI state. */
export function parseCi(out: string): { state: "ok" | "fail" | "running" | "none"; at: string | null } {
  let runs: Array<Record<string, unknown>>;
  try {
    runs = JSON.parse(out) as typeof runs;
  } catch {
    return { state: "none", at: null };
  }
  const r = Array.isArray(runs) ? runs[0] : undefined;
  if (!r) return { state: "none", at: null };
  const at = typeof r.createdAt === "string" ? r.createdAt : null;
  if (r.status !== "completed") return { state: "running", at };
  return { state: r.conclusion === "success" ? "ok" : r.conclusion === "skipped" || r.conclusion === "neutral" ? "none" : "fail", at };
}

/** .git directory or worktree file → [git dir, common dir]. */
async function gitDirs(io: GitIo, root: string): Promise<[string, string]> {
  const dotgit = join(root, ".git");
  const file = await io.read(dotgit);
  const gitDir = file?.startsWith("gitdir:") ? resolve(root, file.slice(7).trim()) : dotgit;
  const common = (await io.read(join(gitDir, "commondir")))?.trim();
  return [gitDir, common ? resolve(gitDir, common) : gitDir];
}

export interface GitWatchOpts {
  debounceMs?: number;
  refreshMs?: number;
  ciMs?: number;
}

/** One root: watchers, the latest message and the subscribers that get it. */
export class GitWatch {
  readonly root: string;
  readonly socks = new Set<Sock>();
  readonly #io: GitIo;
  readonly #send: (data: string) => void;
  readonly #o: Required<GitWatchOpts>;
  #watchers: Array<{ close(): void }> = [];
  #debounce: NodeJS.Timeout | null = null;
  #refresh: NodeJS.Timeout | null = null;
  #ciTimer: NodeJS.Timeout | null = null;
  #ci: Rec | null = null;
  #ciOn = false;
  #busy: Promise<void> | null = null;
  #again = false;
  #stopped = false;
  last: string | null = null;
  /** git commands run (tests: no polling). */
  runs = 0;

  constructor(root: string, io: GitIo, send: (data: string) => void, o: GitWatchOpts = {}) {
    this.root = root;
    this.#io = io;
    this.#send = send;
    this.#o = { debounceMs: o.debounceMs ?? 500, refreshMs: o.refreshMs ?? 60_000, ciMs: o.ciMs ?? 5 * 60_000 };
  }

  get active() {
    return this.#watchers.length > 0 || this.#debounce !== null || this.#refresh !== null || this.#ciTimer !== null;
  }

  async start() {
    const [gitDir, common] = await gitDirs(this.#io, this.root);
    if (this.#stopped) return;
    const remotes = (await this.#io.list(join(common, "refs", "remotes"))).map((r) => join(common, "refs", "remotes", r));
    if (this.#stopped) return;
    const dirs: Array<[string, boolean]> = [[gitDir, true], ...(common !== gitDir ? [[common, true] as [string, boolean]] : []), [join(common, "refs", "heads"), false], ...remotes.map((d) => [d, false] as [string, boolean])];
    for (const [dir, filter] of dirs) {
      try {
        this.#watchers.push(this.#io.watch(dir, (f) => (!filter || f === null || GIT_FILES.has(f) ? this.#soon() : undefined)));
      } catch {}
    }
    this.#refresh = setInterval(() => void this.update(), this.#o.refreshMs);
    this.#refresh.unref?.();
    await this.update();
  }

  stop() {
    this.#stopped = true;
    for (const w of this.#watchers) w.close();
    this.#watchers = [];
    if (this.#debounce) clearTimeout(this.#debounce);
    if (this.#refresh) clearInterval(this.#refresh);
    if (this.#ciTimer) clearInterval(this.#ciTimer);
    this.#debounce = this.#refresh = this.#ciTimer = null;
  }

  setCi(on: boolean) {
    if (on === this.#ciOn || this.#stopped) return;
    this.#ciOn = on;
    if (this.#ciTimer) clearInterval(this.#ciTimer);
    this.#ciTimer = null;
    this.#ci = null;
    if (on && this.#io.has("gh")) {
      this.#ciTimer = setInterval(() => void this.#checkCi(), this.#o.ciMs);
      this.#ciTimer.unref?.();
      void this.#checkCi();
    } else void this.update();
  }

  #soon() {
    if (this.#stopped) return;
    if (this.#debounce) clearTimeout(this.#debounce);
    this.#debounce = setTimeout(() => {
      this.#debounce = null;
      void this.update();
    }, this.#o.debounceMs);
    this.#debounce.unref?.();
  }

  async #checkCi() {
    const branch = this.last ? (JSON.parse(this.last) as Rec).branch : null;
    const args = ["run", "list", "--limit", "1", "--json", "status,conclusion,createdAt", ...(typeof branch === "string" ? ["--branch", branch] : [])];
    const r = await this.#io.run("gh", args, { cwd: this.root, timeoutMs: 10_000 });
    if (this.#stopped || !this.#ciOn) return;
    this.#ci = r.code === 0 ? parseCi(r.stdout) : { state: "none", at: null };
    await this.update();
  }

  /** status + log once; a change meanwhile runs it once more. */
  update(): Promise<void> {
    if (this.#busy) {
      this.#again = true;
      return this.#busy;
    }
    this.#busy = (async () => {
      do {
        this.#again = false;
        this.runs++;
        const st = await this.#io.run("git", ["-C", this.root, "status", "--porcelain=v2", "--branch"], { timeoutMs: 10_000 });
        const lg = await this.#io.run("git", ["-C", this.root, "log", "-3", "--abbrev=7", "--format=%h%x1f%s%x1f%ct%x1e"], { timeoutMs: 10_000 });
        if (this.#stopped) return;
        const msg = st.code === 0 ? gitMessage(this.root, st.stdout, lg.code === 0 ? parseCommits(lg.stdout) : [], this.#ciOn ? this.#ci : null) : { type: "git", root: rootLabel(this.root), none: "notRepo" };
        const s = JSON.stringify(msg);
        if (s !== this.last) {
          this.last = s;
          this.#send(s);
        }
      } while (this.#again && !this.#stopped);
    })().finally(() => (this.#busy = null));
    return this.#busy;
  }
}

export interface Selector {
  readonly root: string | null;
  readonly known: boolean;
  readonly active: boolean;
  start(): void;
  stop(): void;
}

export interface GitTopicDeps {
  io: GitIo;
  /** The "auto" selector (started only while a subscriber asks for auto). */
  selector(onChange: (root: string | null) => void): Selector;
  /** A fixed path → its git root inside the allowed roots, or why not. */
  resolve(path: string): Promise<{ root: string } | { none: "notRepo" | "notAllowed" }>;
  watch?: GitWatchOpts;
}

/** Fixed path → git root, both inside the agent's allowed roots. */
export async function resolveProject(config: AgentConfig, path: string): Promise<{ root: string } | { none: "notRepo" | "notAllowed" }> {
  let real: string;
  try {
    real = await allowedPath(config, path);
  } catch {
    return { none: "notAllowed" };
  }
  const root = await gitRootOf(real);
  if (!root) return { none: "notRepo" };
  return allowedPath(config, root).then((r) => ({ root: r }), () => ({ none: "notAllowed" as const }));
}

interface Sub {
  spec: ProjectSpec;
  root: string | null;
  /** Bumped per spec change: a late resolve of an older spec is dropped. */
  gen: number;
}

const send = (sock: Sock, data: string) => {
  if (sock.readyState === 1) sock.send(data);
};

/** Subscribers → their project's watcher. */
export class GitTopic {
  readonly #d: GitTopicDeps;
  readonly #subs = new Map<Sock, Sub>();
  readonly #watches = new Map<string, GitWatch>();
  #selector: Selector | null = null;

  constructor(d: GitTopicDeps) {
    this.#d = d;
  }

  get active() {
    return this.#subs.size > 0 || this.#watches.size > 0 || this.#selector !== null;
  }

  /** Watched roots (tests). */
  get roots() {
    return [...this.#watches.keys()];
  }

  watchOf(root: string) {
    return this.#watches.get(root) ?? null;
  }

  /** The subscriber's project (null = it no longer wants git). */
  set(sock: Sock, spec: ProjectSpec | null) {
    const old = this.#subs.get(sock);
    if (!spec) {
      if (!old) return;
      this.#subs.delete(sock);
      this.#release(sock, old.root);
      this.#selectorFits();
      return;
    }
    if (old && old.spec.project === spec.project && old.spec.ci === spec.ci) return;
    const sub: Sub = { spec, root: old?.root ?? null, gen: (old?.gen ?? 0) + 1 };
    this.#subs.set(sock, sub);
    this.#selectorFits();
    if (spec.project === "auto") {
      if (this.#selector?.known) this.#assign(sock, this.#selector.root, "noProject");
    } else {
      const gen = sub.gen;
      void this.#d.resolve(spec.project).then((r) => {
        if (this.#subs.get(sock)?.gen !== gen) return;
        if ("root" in r) this.#assign(sock, r.root, "notRepo");
        else this.#assign(sock, null, r.none);
      });
    }
    if (old && old.root) this.#fitCi(old.root);
  }

  stop() {
    for (const [sock, s] of [...this.#subs]) {
      this.#subs.delete(sock);
      this.#release(sock, s.root);
    }
    this.#selectorFits();
  }

  #selectorFits() {
    const auto = [...this.#subs.values()].some((s) => s.spec.project === "auto");
    if (auto && !this.#selector) {
      const sel = this.#d.selector((root) => {
        for (const [sock, s] of this.#subs) if (s.spec.project === "auto") this.#assign(sock, root, "noProject");
      });
      this.#selector = sel;
      sel.start();
    } else if (!auto && this.#selector) {
      this.#selector.stop();
      this.#selector = null;
    }
  }

  #assign(sock: Sock, root: string | null, reason: string) {
    const sub = this.#subs.get(sock);
    if (!sub) return;
    if (sub.root !== root) {
      this.#release(sock, sub.root);
      sub.root = root;
      if (root) {
        let w = this.#watches.get(root);
        if (!w) {
          const watch = new GitWatch(root, this.#d.io, (data) => {
            for (const s of watch.socks) send(s, data);
          }, this.#d.watch);
          w = watch;
          this.#watches.set(root, w);
          w.socks.add(sock);
          this.#fitCi(root);
          void w.start();
          return;
        }
        w.socks.add(sock);
        if (w.last) send(sock, w.last);
      }
    }
    if (root) this.#fitCi(root);
    else send(sock, JSON.stringify({ type: "git", root: null, none: reason }));
  }

  #release(sock: Sock, root: string | null) {
    if (!root) return;
    const w = this.#watches.get(root);
    if (!w) return;
    w.socks.delete(sock);
    if (w.socks.size) return this.#fitCi(root);
    w.stop();
    this.#watches.delete(root);
  }

  #fitCi(root: string) {
    const w = this.#watches.get(root);
    if (!w) return;
    w.setCi([...this.#subs.values()].some((s) => s.root === root && s.spec.ci));
  }
}
