// `git` topic (PLAN.md §20 A-2): the state of each subscriber's project (project.ts), one watcher per git root shared
// by every subscriber of that root. Non-recursive fs.watch on the git dir (HEAD, index, packed-refs, MERGE_HEAD …),
// refs/heads and refs/remotes/* → 500 ms debounce → ONE `git status --porcelain=v2 --branch` + `git log -3`. Working
// tree edits don't touch .git: while the root also has a `city` watcher (city.ts, one fs.watch per tracked
// directory) its changes refresh the status (at most once a second); without one, a slow refresh (60 s) catches them.
// CI (`gh run list`, 5 min, 10 s timeout) only while a subscriber of that root has the CI setting on (default off).
// Sent: the root's basename, branch, ahead/behind, counts and the last 3 commits; no path at all. Unchanged state is
// not sent. The topic below also places `city` subscribers (same project selection, one CityWatch per root).
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
import { CityWatch, type CityDeps } from "./city.ts";
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
export async function gitDirs(io: { read(path: string): Promise<string | null> }, root: string): Promise<[string, string]> {
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
  /** Working tree change → status after at most this long. */
  pokeMs?: number;
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
  /** A city watcher reports working tree changes: no slow refresh needed. */
  #worktree = false;
  #poke: NodeJS.Timeout | null = null;
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
    this.#o = { debounceMs: o.debounceMs ?? 500, refreshMs: o.refreshMs ?? 60_000, ciMs: o.ciMs ?? 5 * 60_000, pokeMs: o.pokeMs ?? 1000 };
  }

  get active() {
    return this.#watchers.length > 0 || this.#debounce !== null || this.#refresh !== null || this.#ciTimer !== null || this.#poke !== null;
  }

  /** The slow refresh runs only while nothing reports working tree changes. */
  get polling() {
    return this.#refresh !== null;
  }

  /** On: working tree changes come from poke() (the city watcher); off: the 60 s refresh. */
  setWorktreeEvents(on: boolean) {
    if (this.#stopped || on === this.#worktree) return;
    this.#worktree = on;
    this.#arm();
  }

  #arm() {
    if (this.#refresh) clearInterval(this.#refresh);
    this.#refresh = null;
    if (this.#worktree || this.#stopped) return;
    this.#refresh = setInterval(() => void this.update(), this.#o.refreshMs);
    this.#refresh.unref?.();
  }

  /** A working tree file changed: status again within a second (throttled, not pushed back by more changes). */
  poke() {
    if (this.#stopped || this.#poke) return;
    this.#poke = setTimeout(() => {
      this.#poke = null;
      void this.update();
    }, this.#o.pokeMs);
    this.#poke.unref?.();
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
    this.#arm();
    await this.update();
  }

  stop() {
    this.#stopped = true;
    for (const w of this.#watchers) w.close();
    this.#watchers = [];
    if (this.#debounce) clearTimeout(this.#debounce);
    if (this.#refresh) clearInterval(this.#refresh);
    if (this.#ciTimer) clearInterval(this.#ciTimer);
    if (this.#poke) clearTimeout(this.#poke);
    this.#debounce = this.#refresh = this.#ciTimer = this.#poke = null;
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
  /** The city topic (none: city subscriptions are ignored). */
  city?: CityDeps;
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

/** Topics that follow the subscriber's project. */
export type ProjectTopicName = "git" | "city";
const PROJECT_TOPICS: readonly ProjectTopicName[] = ["git", "city"];
/** "root": only the project root is wanted (the claude/diff topics place their paths with it); no watcher. */
export type ProjectWant = ProjectTopicName | "root";

interface Sub {
  spec: ProjectSpec;
  want: Set<ProjectWant>;
  /** The resolved project (null: none, see `none`). */
  root: string | null;
  none: string | null;
  resolved: boolean;
  /** Bumped per spec change: a late resolve of an older spec is dropped. */
  gen: number;
  /** The root whose watcher currently has this subscriber, per topic. */
  at: Record<ProjectTopicName, string | null>;
}

interface RootWatch {
  git: GitWatch | null;
  city: CityWatch | null;
}

const send = (sock: Sock, data: string) => {
  if (sock.readyState === 1) sock.send(data);
};

/** Subscribers → their project's watchers (git and/or city; one of each per root, shared). */
export class GitTopic {
  readonly #d: GitTopicDeps;
  readonly #subs = new Map<Sock, Sub>();
  readonly #watches = new Map<string, RootWatch>();
  #selector: Selector | null = null;
  /** A subscriber's root was (re)assigned (the claude topic re-renders its paths). */
  onRoot: ((sock: Sock) => void) | null = null;
  /** Absolute path → the Claude session that just changed it (the city's `touch.by`). */
  attribute: ((abs: string) => string | null) | null = null;

  constructor(d: GitTopicDeps) {
    this.#d = d;
  }

  get active() {
    return this.#subs.size > 0 || this.#watches.size > 0 || this.#selector !== null;
  }

  /** A subscriber wants the topic or a watcher of it still runs. */
  has(t: ProjectTopicName) {
    return [...this.#subs.values()].some((s) => s.want.has(t)) || [...this.#watches.values()].some((e) => e[t] !== null);
  }

  /** Watched roots (tests). */
  get roots() {
    return [...this.#watches.keys()];
  }

  watchOf(root: string) {
    return this.#watches.get(root)?.git ?? null;
  }

  cityOf(root: string) {
    return this.#watches.get(root)?.city ?? null;
  }

  /** The subscriber's resolved root (undefined: not resolved yet or not subscribed; null: no project). */
  rootOf(sock: Sock): string | null | undefined {
    const s = this.#subs.get(sock);
    return s?.resolved ? s.root : undefined;
  }

  /** The subscriber's project and the project topics it wants (null or none = it wants neither any more). */
  set(sock: Sock, spec: ProjectSpec | null, want: readonly ProjectWant[] = ["git"]) {
    const old = this.#subs.get(sock);
    const w = new Set(want.filter((t) => t === "git" || t === "root" || (t === "city" && this.#d.city)));
    if (!spec || !w.size) {
      if (!old) return;
      this.#subs.delete(sock);
      old.want.clear();
      this.#place(sock, old);
      this.#selectorFits();
      return;
    }
    if (old && old.spec.project === spec.project && old.spec.ci === spec.ci) {
      const added = new Set([...w].filter((t) => !old.want.has(t)));
      old.want = w;
      if (old.resolved) this.#place(sock, old, added);
      return;
    }
    const sub: Sub = { spec, want: w, root: old?.root ?? null, none: old?.none ?? null, resolved: old?.resolved ?? false, gen: (old?.gen ?? 0) + 1, at: old?.at ?? { git: null, city: null } };
    this.#subs.set(sock, sub);
    if (old) this.#place(sock, sub, new Set([...w].filter((t) => !old.want.has(t))));
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
  }

  stop() {
    for (const [sock, s] of [...this.#subs]) {
      this.#subs.delete(sock);
      s.want.clear();
      this.#place(sock, s);
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
    sub.root = root;
    sub.none = root ? null : reason;
    sub.resolved = true;
    this.#place(sock, sub);
    if (root) this.#fitCi(root);
    this.onRoot?.(sock);
  }

  /** Moves the subscriber's memberships to its root; `fresh` topics without a project get the "none" message. */
  #place(sock: Sock, sub: Sub, fresh: ReadonlySet<ProjectWant> = sub.want) {
    for (const t of PROJECT_TOPICS) {
      const target = sub.want.has(t) ? sub.root : null;
      if (sub.at[t] !== target) {
        this.#leave(sock, t, sub.at[t]);
        sub.at[t] = target;
        if (target) this.#join(sock, t, target);
      }
      if (!target && sub.want.has(t) && sub.resolved && fresh.has(t)) send(sock, JSON.stringify({ type: t, root: null, none: sub.none ?? "noProject" }));
    }
  }

  #join(sock: Sock, t: ProjectTopicName, root: string) {
    let e = this.#watches.get(root);
    if (!e) {
      e = { git: null, city: null };
      this.#watches.set(root, e);
    }
    if (t === "git") {
      if (e.git) {
        e.git.socks.add(sock);
        if (e.git.last) send(sock, e.git.last);
        return this.#fitCi(root);
      }
      const watch = new GitWatch(root, this.#d.io, (data) => {
        for (const s of watch.socks) send(s, data);
      }, this.#d.watch);
      e.git = watch;
      watch.socks.add(sock);
      watch.setWorktreeEvents(e.city !== null);
      this.#fitCi(root);
      void watch.start();
      return;
    }
    const d = this.#d.city!;
    if (e.city) {
      e.city.socks.add(sock);
      if (e.city.ready) send(sock, e.city.snapshot());
      return;
    }
    const city = new CityWatch(root, d.io, (data) => {
      for (const s of city.socks) send(s, data);
    }, { ...d.watch, masked: !d.share() });
    city.onWorktree = () => this.#watches.get(root)?.git?.poke();
    city.by = (rel) => this.attribute?.(join(root, rel)) ?? null;
    e.city = city;
    city.socks.add(sock);
    e.git?.setWorktreeEvents(true);
    void city.start();
  }

  #leave(sock: Sock, t: ProjectTopicName, root: string | null) {
    if (!root) return;
    const e = this.#watches.get(root);
    const w = e?.[t];
    if (!e || !w) return;
    w.socks.delete(sock);
    if (w.socks.size) {
      if (t === "git") this.#fitCi(root);
    } else {
      w.stop();
      e[t] = null;
      if (t === "city") e.git?.setWorktreeEvents(false);
    }
    if (!e.git && !e.city) this.#watches.delete(root);
  }

  #fitCi(root: string) {
    const w = this.#watches.get(root)?.git;
    if (!w) return;
    w.setCi([...this.#subs.values()].some((s) => s.at.git === root && s.spec.ci));
  }
}
