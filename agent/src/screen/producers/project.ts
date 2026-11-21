// Project selection for the `git` topic (and later `city`) (PLAN.md §20 A-2 "Proje seçimi"). A subscriber sends
// `project: "auto" | <path>`; a fixed path must be inside the agent's allowed roots. auto = the working directory of
// the most recently active Claude session (Tiphys sessions from the manager, terminal sessions from
// ~/.claude/sessions/), else the focused terminal's shell (focused window pid → its newest child shell →
// /proc/<pid>/cwd); either one walked up to its git root. Re-checked when ~/.claude/sessions changes (non-recursive
// fs.watch, 1 s debounce), when the focus changes (Hyprland event socket, only while no Claude session gives a
// project) and every 30 s (Tiphys sessions live in memory). Only `relativeTo` decides what leaves for the display:
// paths inside the root, relative; the root itself only as its basename.
import { watch as fsWatch, type FSWatcher } from "node:fs";
import { stat } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, relative, resolve, sep } from "node:path";
import { realFileIo, type FileIo } from "./common.ts";
import { parseStat } from "./jobs.ts";

/** "auto" or an absolute path; plus whether CI status is wanted (display setting). */
export interface ProjectSpec {
  project: "auto" | string;
  ci: boolean;
}

/** The subscribe message's `project`/`ci` → a spec (default auto, no CI); null for a malformed value. */
export function parseProject(project: unknown, ci: unknown): ProjectSpec | null {
  if (project !== undefined && project !== "auto" && !(typeof project === "string" && project.length <= 1024 && isAbsolute(project) && !project.includes("\0"))) return null;
  return { project: typeof project === "string" ? project : "auto", ci: ci === true };
}

/** Walks up from `dir` to the directory holding `.git` (directory or worktree file); null if none. */
export async function gitRootOf(dir: string, isGit: (p: string) => Promise<boolean> = defaultIsGit): Promise<string | null> {
  let d = resolve(dir);
  for (let i = 0; i < 64; i++) {
    if (await isGit(join(d, ".git"))) return d;
    const up = dirname(d);
    if (up === d) return null;
    d = up;
  }
  return null;
}

const defaultIsGit = (p: string) => stat(p).then((s) => s.isDirectory() || s.isFile(), () => false);

/** A path → relative to root, or null when it is not inside it (".." escapes, other roots, the root's siblings). */
export function relativeTo(root: string, p: string): string | null {
  const abs = resolve(root, p);
  if (abs === root) return "";
  if (!abs.startsWith(root.endsWith(sep) ? root : root + sep)) return null;
  const rel = relative(root, abs);
  return rel.startsWith("..") || isAbsolute(rel) ? null : rel;
}

/** What the display may know about a root: its last part. */
export const rootLabel = (root: string) => basename(root) || "/";

export interface Candidate {
  cwd: string;
  /** Last activity (ms). */
  at: number;
}

const SHELLS = new Set(["bash", "zsh", "fish", "sh", "dash", "nu", "ksh", "tcsh"]);

/** The focused terminal's shell directory: the newest shell among the window process's descendants (≤ 3 levels). */
export function shellCwd(io: FileIo, pid: number, procRoot = "/proc"): string | null {
  const procs: Array<{ pid: number; ppid: number; comm: string; start: number }> = [];
  for (const n of io.list(procRoot)) {
    if (!/^\d+$/.test(n)) continue;
    const st = parseStat(io.read(`${procRoot}/${n}/stat`) ?? "");
    if (st) procs.push(st);
  }
  let level = [pid];
  const shells: Array<{ pid: number; start: number }> = [];
  for (let depth = 0; depth < 3 && level.length; depth++) {
    const next = procs.filter((p) => level.includes(p.ppid));
    for (const p of next) if (SHELLS.has(p.comm)) shells.push(p);
    level = next.map((p) => p.pid);
  }
  const best = shells.sort((a, b) => b.start - a.start)[0];
  return best ? io.link(`${procRoot}/${best.pid}/cwd`) : null;
}

export interface SelectorIo {
  /** Claude sessions (Tiphys + terminal) with their cwd and last activity. */
  sessions(): Promise<Candidate[]>;
  /** Directory to watch for terminal session changes (~/.claude/sessions); null = none. */
  sessionsDir: string | null;
  /** Focused window pid changes; returns the unsubscribe function. null = no desktop. */
  focus: ((fn: (pid: number | null) => void) => () => void) | null;
  /** pid → its shell's cwd. */
  shellCwd(pid: number): string | null;
  gitRoot(dir: string): Promise<string | null>;
  watch(dir: string, fn: () => void): { close(): void };
}

/** Picks the project: the newest session that has a git root, else the focused terminal's. */
export async function pickProject(cands: Candidate[], focusedCwd: string | null, gitRoot: (d: string) => Promise<string | null>): Promise<{ root: string | null; fromSession: boolean }> {
  for (const c of [...cands].sort((a, b) => b.at - a.at)) {
    const r = await gitRoot(c.cwd);
    if (r) return { root: r, fromSession: true };
  }
  return { root: focusedCwd ? await gitRoot(focusedCwd) : null, fromSession: false };
}

/** The "auto" project: one per agent, running only while a subscriber asks for auto. */
export class ProjectSelector {
  readonly #io: SelectorIo;
  readonly #onChange: (root: string | null) => void;
  readonly #o: { debounceMs: number; recheckMs: number };
  #root: string | null = null;
  #known = false;
  #on = false;
  #watcher: { close(): void } | null = null;
  #debounce: NodeJS.Timeout | null = null;
  #recheck: NodeJS.Timeout | null = null;
  #unfocus: (() => void) | null = null;
  #focusPid: number | null = null;
  #busy: Promise<void> | null = null;
  #again = false;

  constructor(io: SelectorIo, onChange: (root: string | null) => void, o: { debounceMs?: number; recheckMs?: number } = {}) {
    this.#io = io;
    this.#onChange = onChange;
    this.#o = { debounceMs: o.debounceMs ?? 1000, recheckMs: o.recheckMs ?? 30_000 };
  }

  get root() {
    return this.#root;
  }

  /** The root is known (the first pick finished). */
  get known() {
    return this.#known;
  }

  get active() {
    return this.#on || this.#watcher !== null || this.#debounce !== null || this.#recheck !== null || this.#unfocus !== null;
  }

  start() {
    if (this.#on) return;
    this.#on = true;
    if (this.#io.sessionsDir) {
      try {
        this.#watcher = this.#io.watch(this.#io.sessionsDir, () => this.#soon());
      } catch {
        this.#watcher = null; // no sessions directory (Claude Code never ran): the 30 s check still covers Tiphys
      }
    }
    this.#recheck = setInterval(() => void this.#pick(), this.#o.recheckMs);
    this.#recheck.unref?.();
    void this.#pick();
  }

  stop() {
    this.#on = false;
    this.#watcher?.close();
    this.#watcher = null;
    if (this.#debounce) clearTimeout(this.#debounce);
    if (this.#recheck) clearInterval(this.#recheck);
    this.#debounce = this.#recheck = null;
    this.#unfocus?.();
    this.#unfocus = null;
    this.#root = null;
    this.#known = false;
  }

  #soon() {
    if (!this.#on) return;
    if (this.#debounce) clearTimeout(this.#debounce);
    this.#debounce = setTimeout(() => {
      this.#debounce = null;
      void this.#pick();
    }, this.#o.debounceMs);
    this.#debounce.unref?.();
  }

  /** One pick at a time; a request meanwhile runs once more after it. */
  async #pick(): Promise<void> {
    if (this.#busy) {
      this.#again = true;
      return this.#busy;
    }
    this.#busy = (async () => {
      do {
        this.#again = false;
        const cands = await this.#io.sessions().catch(() => []);
        const cwd = this.#focusPid ? this.#io.shellCwd(this.#focusPid) : null;
        const r = await pickProject(cands, cwd, (d) => this.#io.gitRoot(d));
        if (!this.#on) return;
        // The focus only matters while no session gives a project.
        if (r.fromSession && this.#unfocus) {
          this.#unfocus();
          this.#unfocus = null;
          this.#focusPid = null;
        } else if (!r.fromSession && !this.#unfocus && this.#io.focus) {
          this.#unfocus = this.#io.focus((pid) => {
            if (pid === this.#focusPid) return;
            this.#focusPid = pid;
            this.#soon();
          });
        }
        const root = r.root ?? (r.fromSession ? null : this.#root); // a non-terminal window keeps the last project
        if (root !== this.#root || !this.#known) {
          this.#root = root;
          this.#known = true;
          this.#onChange(root);
        }
      } while (this.#again && this.#on);
    })().finally(() => (this.#busy = null));
    return this.#busy;
  }
}

/** Real selector io: Tiphys sessions (in memory), terminal sessions (~/.claude/sessions), Hyprland focus. */
export function realSelectorIo(o: {
  tiphys: () => Candidate[];
  terminal: () => Promise<Candidate[]>;
  sessionsDir: string;
  focus: SelectorIo["focus"];
  io?: FileIo;
}): SelectorIo {
  const io = o.io ?? realFileIo;
  return {
    sessions: async () => [...o.tiphys(), ...(await o.terminal().catch(() => []))],
    sessionsDir: o.sessionsDir,
    focus: o.focus,
    shellCwd: (pid) => shellCwd(io, pid),
    gitRoot: (d) => gitRootOf(d),
    watch: (dir, fn): FSWatcher => {
      const w = fsWatch(dir, { persistent: false }, () => fn());
      w.on("error", () => w.close());
      return w;
    },
  };
}
