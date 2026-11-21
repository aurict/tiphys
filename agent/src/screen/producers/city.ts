// `city` topic (PLAN.md §20 A-2): the code city of the selected project, one watcher per git root shared by every
// subscriber of that root (the topic in git.ts places subscribers; this file is one root).
// - Snapshot: `git ls-files -z -t --cached --others --exclude-standard` (tracked + untracked-but-not-ignored; untracked
//   entries inside node_modules/build/dist/… are dropped) and the line count of each file, read in 64 KB chunks
//   (binary = a NUL in the first 8000 bytes, > 2 MB and non-regular files are skipped). More than 20 000 files: the
//   city is aggregated at folder level (the deepest level with ≤ 4000 folders, lines estimated from the size,
//   `truncated: true`). Held in memory while the root has a subscriber; a new subscriber gets the whole snapshot,
//   then everyone gets only patches (`cityPatch`).
// - Activity: ONE non-recursive fs.watch per directory that holds (or leads to) a listed file, plus the root — never
//   `{recursive:true}` (W0: that puts inotify on every directory, node_modules included). Directories named .git,
//   node_modules, build, dist, .dart_tool, target are never watched; a new directory is picked up from its parent's
//   event (unless git ignores it). At most 5000 directories (shallow ones first; ≈ 5.6 KB each in Node): a 30 000-file
//   repository needed ~4400. Events settle 150 ms (at most 1 s), then each path is looked at once: changed →
//   lines recounted → `touch` (at most once per file per second, 50 per second in all) + one `cityPatch`.
// - Commits: HEAD and logs/HEAD in the git dir; a new HEAD whose parent was the old one → `{type:"commit"}`.
// - Paths are relative to the root and never leave it (no symlink is followed). Without `screen.share.code` on this
//   host every path segment is replaced by a stable opaque token (HMAC with a per-watch random key; the kind is
//   computed before), so the city keeps its shape but no file name leaves (`masked: true`).
// Teardown (last subscriber gone, project changed): every watcher and timer closed, the cache dropped.
import { spawn } from "node:child_process";
import { constants, watch as fsWatch } from "node:fs";
import { lstat, open, readdir } from "node:fs/promises";
import { createHmac, randomBytes } from "node:crypto";
import { join } from "node:path";
import type { Sock } from "../source.ts";
import { gitDirs } from "./git.ts";
import { rootLabel } from "./project.ts";

export const IGNORED_DIRS: ReadonlySet<string> = new Set([".git", "node_modules", "build", "dist", ".dart_tool", "target"]);
/** Editor scratch files (vim swap/backup/4913, emacs locks, JetBrains and Kate temp files): never a building. */
const SCRATCH = /^\.#|^#.*#$|~$|\.sw[a-p]$|^4913$|\.kate-swp$|___jb_(?:tmp|old)___$/;
/** Folder level: sizes of these aren't counted toward the line estimate. */
const BINARY_EXT = /\.(?:png|jpe?g|gif|webp|ico|icns|bmp|tiff?|psd|woff2?|ttf|otf|eot|zip|gz|tgz|xz|bz2|7z|jar|aar|apk|so|a|o|dll|dylib|exe|bin|pdf|mp[34]|m4a|ogg|wav|flac|webm|mov|avi|pmtiles|wasm|class|pyc|db|sqlite)$/i;

export type Kind = "code" | "dart" | "docs" | "config" | "web" | "other";
const KIND_EXT: Record<Exclude<Kind, "other">, string[]> = {
  code: ["ts", "tsx", "js", "mjs", "cjs", "jsx", "py", "rs", "go", "c", "h", "cc", "cpp", "hpp", "java", "kt", "kts", "swift", "rb", "php", "cs", "lua", "sh", "zsh", "bash", "fish", "zig", "scala", "ex", "exs", "hs", "ml", "sql", "m", "mm", "vue", "svelte"],
  dart: ["dart"],
  docs: ["md", "mdx", "txt", "arb", "rst", "adoc"],
  config: ["json", "jsonc", "yaml", "yml", "toml", "lock", "gradle", "properties", "xml", "plist", "cfg", "ini", "conf", "env", "nix", "cmake"],
  web: ["html", "htm", "css", "scss", "sass", "less", "svg"],
};
const EXT_KIND = new Map<string, Kind>(Object.entries(KIND_EXT).flatMap(([k, list]) => list.map((e) => [e, k as Kind])));

/** File type → one of the six palette tones. */
export function kindOf(path: string): Kind {
  const name = path.slice(path.lastIndexOf("/") + 1);
  const dot = name.lastIndexOf(".");
  return dot > 0 ? (EXT_KIND.get(name.slice(dot + 1).toLowerCase()) ?? "other") : "other";
}

/** A git-relative path that stays inside the root (no empty, ".", ".." or absolute parts). */
export function insideRel(p: string): boolean {
  if (!p || p.startsWith("/") || p.includes("\0") || p.length > 4096) return false;
  return p.split("/").every((s) => s !== "" && s !== "." && s !== "..");
}

const hasIgnoredDir = (rel: string) => {
  const parts = rel.split("/");
  for (let i = 0; i < parts.length - 1; i++) if (IGNORED_DIRS.has(parts[i]!)) return true;
  return false;
};

/** `git ls-files -z -t …` output → paths (untracked ones inside an ignored directory dropped), unique, in order. */
export function parseLsFiles(out: string): string[] {
  const seen = new Set<string>();
  for (const e of out.split("\0")) {
    if (e.length < 3 || e[1] !== " ") continue;
    const p = e.slice(2);
    if (!insideRel(p) || (e[0] === "?" && hasIgnoredDir(p))) continue;
    seen.add(p);
  }
  return [...seen];
}

/** Directories to watch for `paths`: "" (the root) and every directory on the way to a file, minus ignored ones. */
export function watchDirs(paths: Iterable<string>): string[] {
  const dirs = new Set<string>([""]);
  for (const p of paths) {
    const parts = p.split("/");
    let d = "";
    for (let i = 0; i < parts.length - 1; i++) {
      if (IGNORED_DIRS.has(parts[i]!)) break;
      d = d ? `${d}/${parts[i]}` : parts[i]!;
      dirs.add(d);
    }
  }
  return [...dirs];
}

/** Folder level: the deepest depth whose folder count stays ≤ maxGroups; key of a file at that depth. */
export function groupDepth(paths: string[], maxGroups: number): number {
  let best = 1;
  for (let d = 1; d <= 32; d++) {
    const keys = new Set(paths.map((p) => groupKey(p, d)));
    if (keys.size > maxGroups) break;
    best = d;
    if (!paths.some((p) => p.split("/").length - 1 > d)) break; // nothing deeper
  }
  return best;
}

/** A file's folder at `depth` (a root-level file is its own entry). */
export function groupKey(p: string, depth: number): string {
  const parts = p.split("/");
  const n = Math.min(depth, parts.length - 1);
  return n === 0 ? p : parts.slice(0, n).join("/");
}

/** Stable opaque path: every segment → 8 hex characters of HMAC(key, segment). */
export function maskPath(key: Buffer, p: string): string {
  return p
    .split("/")
    .map((s) => createHmac("sha256", key).update(s).digest("hex").slice(0, 8))
    .join("/");
}

export interface CityIo {
  /** git with optional stdin; never throws ({code:-1} on failure). */
  git(root: string, args: string[], o: { timeoutMs: number; input?: string }): Promise<{ stdout: string; code: number }>;
  /** Line count of a regular file ≤ maxBytes that isn't binary; null otherwise (symlinks never followed). */
  lines(abs: string, maxBytes: number): Promise<number | null>;
  /** lstat: what the path is now (null = gone). */
  stat(abs: string): Promise<{ type: "file" | "dir" | "other"; size: number; ino: number } | null>;
  list(abs: string): Promise<string[]>;
  read(abs: string): Promise<string | null>;
  watch(abs: string, fn: (file: string | null) => void, onError: () => void): { close(): void };
}

const GIT_ENV = { ...process.env, GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0", GIT_PAGER: "cat", LC_ALL: "C" };

/** Read buffers reused across counts (a new 64 KB buffer per file left tens of MB of malloc churn behind). */
const BUFS: Buffer[] = [];

/** Line counting: 64 KB chunks into a reused buffer, O_NOFOLLOW|O_NONBLOCK (a symlink or FIFO is never read). */
export async function countLines(abs: string, maxBytes: number): Promise<number | null> {
  let fh;
  try {
    fh = await open(abs, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  } catch {
    return null;
  }
  const buf = BUFS.pop() ?? Buffer.allocUnsafe(64 * 1024);
  try {
    const st = await fh.stat();
    if (!st.isFile() || st.size > maxBytes) return null;
    let lines = 0;
    let pos = 0;
    let last = 10;
    for (;;) {
      const { bytesRead } = await fh.read(buf, 0, buf.length, pos);
      if (!bytesRead) break;
      const chunk = buf.subarray(0, bytesRead);
      if (pos < 8000 && chunk.subarray(0, 8000 - pos).includes(0)) return null;
      for (let i = chunk.indexOf(10); i !== -1; i = chunk.indexOf(10, i + 1)) lines++;
      last = chunk[bytesRead - 1]!;
      pos += bytesRead;
      if (pos > maxBytes) return null;
    }
    return pos === 0 ? 0 : lines + (last === 10 ? 0 : 1);
  } catch {
    return null;
  } finally {
    if (BUFS.length < 16) BUFS.push(buf);
    await fh.close().catch(() => {});
  }
}

export const realCityIo: CityIo = {
  git: (root, args, o) =>
    new Promise((resolve) => {
      let out = "";
      let size = 0;
      let done = false;
      const finish = (code: number) => {
        if (done) return;
        done = true;
        clearTimeout(t);
        resolve({ stdout: out, code });
      };
      const c = spawn("git", ["-C", root, ...args], { env: GIT_ENV, stdio: [o.input === undefined ? "ignore" : "pipe", "pipe", "ignore"] });
      const t = setTimeout(() => (c.kill("SIGKILL"), finish(-1)), o.timeoutMs);
      c.stdout!.setEncoding("utf8");
      c.stdout!.on("data", (d: string) => {
        size += d.length;
        if (size > 64 * 1024 * 1024) return void (c.kill("SIGKILL"), finish(-1));
        out += d;
      });
      c.on("error", () => finish(-1));
      c.on("close", (code) => finish(code ?? -1));
      if (o.input !== undefined) {
        c.stdin!.on("error", () => {});
        c.stdin!.end(o.input);
      }
    }),
  lines: (abs, max) => countLines(abs, max),
  stat: (abs) =>
    lstat(abs).then(
      (s) => ({ type: s.isFile() ? "file" : s.isDirectory() ? "dir" : "other", size: s.size, ino: s.ino }),
      () => null,
    ),
  list: (abs) => readdir(abs).catch(() => []),
  read: (abs) => import("node:fs/promises").then((f) => f.readFile(abs, "utf8")).catch(() => null),
  watch: (abs, fn, onError) => {
    const w = fsWatch(abs, { persistent: false }, (_ev, f) => fn(typeof f === "string" ? f : null));
    w.on("error", () => (w.close(), onError()));
    return w;
  },
};

export interface CityWatchOpts {
  maxFiles?: number;
  maxBytes?: number;
  /** Folder level: at most this many folders. */
  maxGroups?: number;
  /** Watched directories at most (shallow ones first). */
  maxWatches?: number;
  settleMs?: number;
  maxWaitMs?: number;
  /** Per file: at most one touch per this many ms. */
  touchGapMs?: number;
  /** All files: at most this many touches per second. */
  touchesPerSec?: number;
  refsDebounceMs?: number;
  concurrency?: number;
}

type TouchKind = "edit" | "create" | "delete";
type Entry = { lines: number; kind: Kind };

async function pool<T>(items: T[], n: number, fn: (x: T) => Promise<void>, stop: () => boolean) {
  let i = 0;
  await Promise.all(
    Array.from({ length: Math.min(n, items.length) }, async () => {
      while (i < items.length && !stop()) await fn(items[i++]!);
    }),
  );
}

/** One root: the snapshot, its watchers and the subscribers that get its messages. */
export class CityWatch {
  readonly root: string;
  readonly socks = new Set<Sock>();
  /** Called when a working tree file changed (the git topic refreshes its status). */
  onWorktree: (() => void) | null = null;
  /** Who changed a file (a Claude session's short id from the claude topic), for `touch.by`; null = unknown. */
  by: ((rel: string) => string | null) | null = null;
  readonly #io: CityIo;
  readonly #send: (data: string) => void;
  readonly #o: Required<CityWatchOpts>;
  readonly #key: Buffer | null;
  /** File level: path → entry. Folder level: folder key → entry (lines estimated). */
  #files = new Map<string, Entry>();
  #truncated = false;
  #total = 0;
  #depth = 0;
  #none: string | null = null;
  readonly #watched = new Map<string, { w: { close(): void }; ino: number }>();
  #gitWatchers: Array<{ close(): void }> = [];
  readonly #pending = new Set<string>();
  #settle: NodeJS.Timeout | null = null;
  #firstPending = 0;
  #refsTimer: NodeJS.Timeout | null = null;
  #head: string | null = null;
  readonly #lastTouch = new Map<string, number>();
  #second = 0;
  #inSecond = 0;
  #busy: Promise<void> | null = null;
  #again = false;
  #ready = false;
  #stopped = false;

  constructor(root: string, io: CityIo, send: (data: string) => void, o: CityWatchOpts & { masked?: boolean } = {}) {
    this.root = root;
    this.#io = io;
    this.#send = send;
    this.#key = o.masked ? randomBytes(32) : null;
    this.#o = {
      maxFiles: o.maxFiles ?? 20_000,
      maxBytes: o.maxBytes ?? 2 * 1024 * 1024,
      maxGroups: o.maxGroups ?? 4000,
      maxWatches: o.maxWatches ?? 5000,
      settleMs: o.settleMs ?? 150,
      maxWaitMs: o.maxWaitMs ?? 1000,
      touchGapMs: o.touchGapMs ?? 1000,
      touchesPerSec: o.touchesPerSec ?? 50,
      refsDebounceMs: o.refsDebounceMs ?? 300,
      concurrency: o.concurrency ?? 8,
    };
  }

  get ready() {
    return this.#ready;
  }

  get active() {
    return this.#watched.size > 0 || this.#gitWatchers.length > 0 || this.#settle !== null || this.#refsTimer !== null;
  }

  /** Open fs watchers (tests, measurements). */
  get watchCount() {
    return this.#watched.size + this.#gitWatchers.length;
  }

  /** Watched directories, relative ("" = root) (tests). */
  get watchedDirs() {
    return [...this.#watched.keys()];
  }

  #out(p: string) {
    return this.#key ? maskPath(this.#key, p) : p;
  }

  /** Whether names leave masked (the host didn't share code when the city started). */
  get masked() {
    return this.#key !== null;
  }

  /**
   * A root-relative file path as this city names it (the claude topic's paths hit the same building): masked with
   * this city's key, and at folder level its folder's building.
   */
  pathOf(rel: string): string {
    return this.#out(this.#truncated && this.#depth ? groupKey(rel, this.#depth) : rel);
  }

  /** The whole current city (sent to a new subscriber). */
  snapshot(): string {
    if (this.#none) return JSON.stringify({ type: "city", root: rootLabel(this.root), none: this.#none });
    const files = [...this.#files].map(([p, e]) => [this.#out(p), e.lines, e.kind]);
    return JSON.stringify({
      type: "city",
      root: rootLabel(this.root),
      files,
      truncated: this.#truncated,
      ...(this.#truncated ? { total: this.#total } : {}),
      masked: this.#key !== null,
    });
  }

  async start() {
    const ls = await this.#io.git(this.root, ["ls-files", "-z", "-t", "--cached", "--others", "--exclude-standard"], { timeoutMs: 60_000 });
    if (this.#stopped) return;
    if (ls.code !== 0) {
      this.#none = "notRepo";
      this.#ready = true;
      return this.#send(this.snapshot());
    }
    const paths = parseLsFiles(ls.stdout);
    this.#total = paths.length;
    this.#truncated = paths.length > this.#o.maxFiles;
    // Watchers first: a change while the lines are counted waits in #pending until the snapshot is out.
    let dirs = watchDirs(paths);
    if (dirs.length > this.#o.maxWatches) dirs = dirs.sort((a, b) => a.split("/").length - b.split("/").length).slice(0, this.#o.maxWatches);
    for (const d of dirs) await this.#watchDir(d);
    await this.#watchRefs();
    if (this.#stopped) return;
    if (this.#truncated) await this.#countFolders(paths);
    else await this.#countFiles(paths);
    if (this.#stopped) return;
    this.#ready = true;
    this.#send(this.snapshot());
    if (this.#pending.size) this.#schedule();
  }

  async #countFiles(paths: string[]) {
    const counted = new Map<string, Entry>();
    await pool(
      paths,
      this.#o.concurrency,
      async (p) => {
        const n = await this.#io.lines(join(this.root, p), this.#o.maxBytes);
        if (n !== null) counted.set(p, { lines: n, kind: kindOf(p) });
      },
      () => this.#stopped,
    );
    // Keep ls-files order (stable for the page's layout).
    for (const p of paths) {
      const e = counted.get(p);
      if (e) this.#files.set(p, e);
    }
  }

  async #countFolders(paths: string[]) {
    this.#depth = groupDepth(paths, this.#o.maxGroups);
    const groups = new Map<string, { lines: number; kinds: Map<Kind, number> }>();
    await pool(
      paths,
      this.#o.concurrency * 4,
      async (p) => {
        const st = BINARY_EXT.test(p) ? null : await this.#io.stat(join(this.root, p));
        const key = groupKey(p, this.#depth);
        const g = groups.get(key) ?? { lines: 0, kinds: new Map() };
        groups.set(key, g);
        if (st?.type === "file" && st.size <= this.#o.maxBytes) g.lines += Math.max(1, Math.round(st.size / 40));
        const k = kindOf(p);
        g.kinds.set(k, (g.kinds.get(k) ?? 0) + 1);
      },
      () => this.#stopped,
    );
    for (const [key, g] of groups) {
      const kind = [...g.kinds].sort((a, b) => b[1] - a[1])[0]?.[0] ?? "other";
      this.#files.set(key, { lines: Math.max(1, g.lines), kind });
    }
  }

  async #watchDir(rel: string) {
    if (this.#stopped || this.#watched.has(rel) || this.#watched.size >= this.#o.maxWatches) return;
    const abs = rel ? join(this.root, rel) : this.root;
    const st = await this.#io.stat(abs);
    if (this.#stopped || this.#watched.has(rel) || st?.type !== "dir") return;
    try {
      const w = this.#io.watch(
        abs,
        (f) => this.#event(rel, f),
        () => {
          // The directory went away (or the watch broke): drop it; its parent's event tells the rest.
          if (this.#watched.get(rel)?.w === w) this.#watched.delete(rel);
        },
      );
      this.#watched.set(rel, { w, ino: st.ino });
    } catch {}
  }

  #unwatchTree(rel: string) {
    for (const [d, x] of [...this.#watched]) {
      if (d === rel || d.startsWith(`${rel}/`)) {
        x.w.close();
        this.#watched.delete(d);
      }
    }
  }

  async #watchRefs() {
    const [gitDir] = await gitDirs(this.#io, this.root);
    const head = await this.#readHead();
    if (this.#stopped) return;
    this.#head = head?.hash ?? null;
    for (const dir of [gitDir, join(gitDir, "logs")]) {
      try {
        this.#gitWatchers.push(this.#io.watch(dir, (f) => (f === null || f === "HEAD" ? this.#refsChanged() : undefined), () => {}));
      } catch {}
    }
  }

  async #readHead() {
    const r = await this.#io.git(this.root, ["log", "-1", "--format=%H%x1f%P%x1f%s"], { timeoutMs: 10_000 });
    if (r.code !== 0) return null;
    const [hash = "", parents = "", subject = ""] = r.stdout.trim().split("\x1f");
    return hash ? { hash, parents: parents.split(" ").filter(Boolean), subject } : null;
  }

  #refsChanged() {
    if (this.#stopped) return;
    if (this.#refsTimer) clearTimeout(this.#refsTimer);
    this.#refsTimer = setTimeout(() => {
      this.#refsTimer = null;
      void this.#readHead().then((h) => {
        if (this.#stopped || !h || h.hash === this.#head) return;
        const old = this.#head;
        this.#head = h.hash;
        if (old && h.parents.includes(old)) {
          const subject = h.subject.length > 80 ? `${h.subject.slice(0, 79)}…` : h.subject;
          this.#send(JSON.stringify({ type: "commit", hash7: h.hash.slice(0, 7), subject }));
        }
      });
    }, this.#o.refsDebounceMs);
    this.#refsTimer.unref?.();
  }

  #event(dir: string, f: string | null) {
    if (this.#stopped) return;
    if (f === null) {
      // No name (queue overflow): look at the directory itself.
      if (dir) this.#pending.add(dir);
    } else {
      if (f.includes("/") || f === "." || f === ".." || IGNORED_DIRS.has(f) || SCRATCH.test(f)) return;
      this.#pending.add(dir ? `${dir}/${f}` : f);
    }
    this.#schedule();
  }

  #schedule() {
    if (this.#stopped) return;
    const now = Date.now();
    if (!this.#settle) this.#firstPending = now;
    if (this.#settle) clearTimeout(this.#settle);
    const wait = Math.max(0, Math.min(this.#o.settleMs, this.#firstPending + this.#o.maxWaitMs - now));
    this.#settle = setTimeout(() => {
      this.#settle = null;
      void this.#flush();
    }, wait);
    this.#settle.unref?.();
  }

  /** Waits for a running flush (tests). */
  async idle() {
    while (this.#busy || this.#settle) {
      await (this.#busy ?? new Promise((r) => setTimeout(r, 10)));
    }
  }

  #flush(): Promise<void> {
    if (!this.#ready) return Promise.resolve(); // start() schedules again when the snapshot is out
    if (this.#busy) {
      this.#again = true;
      return this.#busy;
    }
    this.#busy = (async () => {
      do {
        this.#again = false;
        const batch = [...this.#pending];
        this.#pending.clear();
        if (batch.length && !this.#stopped) await (this.#truncated ? this.#folderBatch(batch) : this.#fileBatch(batch));
        if (this.#pending.size && !this.#stopped) this.#again = true; // new directories' entries
      } while (this.#again && !this.#stopped);
    })().finally(() => (this.#busy = null));
    return this.#busy;
  }

  async #ignored(paths: string[]): Promise<Set<string>> {
    if (!paths.length) return new Set();
    const r = await this.#io.git(this.root, ["check-ignore", "-z", "--stdin"], { timeoutMs: 10_000, input: `${paths.join("\0")}\0` });
    return new Set(r.code === 0 ? r.stdout.split("\0").filter(Boolean) : []);
  }

  async #fileBatch(batch: string[]) {
    const edits: string[] = [];
    const candidates: string[] = [];
    const newDirs: string[] = [];
    const gone: string[] = [];
    for (const rel of batch) {
      if (!insideRel(rel) || hasIgnoredDir(rel)) continue;
      const st = await this.#io.stat(join(this.root, rel));
      if (this.#stopped) return;
      const known = this.#files.has(rel);
      if (st?.type === "file") (known ? edits : candidates).push(rel);
      else if (st?.type === "dir") {
        const w = this.#watched.get(rel);
        if (!w) newDirs.push(rel);
        else if (w.ino !== st.ino) {
          // Replaced (removed and made again): watch the new one, drop what the old one held.
          this.#unwatchTree(rel);
          gone.push(...[...this.#files.keys()].filter((p) => p.startsWith(`${rel}/`)));
          newDirs.push(rel);
        }
        if (known) gone.push(rel); // a file became a directory
      } else {
        if (known) gone.push(rel);
        if (this.#watched.has(rel)) {
          this.#unwatchTree(rel);
          gone.push(...[...this.#files.keys()].filter((p) => p.startsWith(`${rel}/`)));
        }
      }
    }
    const ignored = await this.#ignored([...candidates, ...newDirs]);
    if (this.#stopped) return;
    for (const d of newDirs) {
      if (ignored.has(d)) continue;
      await this.#watchDir(d);
      if (!this.#watched.has(d)) continue;
      for (const name of await this.#io.list(join(this.root, d))) {
        if (!IGNORED_DIRS.has(name) && !SCRATCH.test(name)) this.#pending.add(`${d}/${name}`);
      }
    }
    const touches: Array<[string, TouchKind]> = [];
    const upsert: Array<[string, number, Kind]> = [];
    const remove: string[] = [];
    for (const rel of [...edits, ...candidates.filter((c) => !ignored.has(c))]) {
      const n = await this.#io.lines(join(this.root, rel), this.#o.maxBytes);
      if (this.#stopped) return;
      const old = this.#files.get(rel);
      if (n === null) {
        if (old) gone.push(rel); // now binary, too big or not a regular file
        continue;
      }
      const kind = kindOf(rel);
      if (!old || old.lines !== n) upsert.push([rel, n, kind]);
      this.#files.set(rel, { lines: n, kind });
      touches.push([rel, old ? "edit" : "create"]);
    }
    for (const rel of new Set(gone)) {
      if (!this.#files.delete(rel)) continue;
      remove.push(rel);
      touches.push([rel, "delete"]);
    }
    this.#emit(touches, upsert, remove);
  }

  /** Folder level: a change anywhere in a folder touches its building; the estimate isn't re-done. */
  async #folderBatch(batch: string[]) {
    const touches: Array<[string, TouchKind]> = [];
    const seen = new Set<string>();
    for (const rel of batch) {
      if (!insideRel(rel) || hasIgnoredDir(rel)) continue;
      const key = groupKey(rel, this.#depth);
      if (seen.has(key) || !this.#files.has(key)) continue;
      seen.add(key);
      touches.push([key, "edit"]);
    }
    this.#emit(touches, [], []);
  }

  #emit(touches: Array<[string, TouchKind]>, upsert: Array<[string, number, Kind]>, remove: string[]) {
    if (!touches.length && !upsert.length && !remove.length) return;
    const now = Date.now();
    for (const [p, t] of this.#lastTouch) if (now - t >= this.#o.touchGapMs) this.#lastTouch.delete(p);
    const sec = Math.floor(now / 1000);
    if (sec !== this.#second) {
      this.#second = sec;
      this.#inSecond = 0;
    }
    if (upsert.length || remove.length) {
      this.#send(JSON.stringify({ type: "cityPatch", upsert: upsert.map(([p, n, k]) => [this.#out(p), n, k]), remove: remove.map((p) => this.#out(p)) }));
    }
    for (const [p, kind] of touches) {
      if (this.#lastTouch.has(p) || this.#inSecond >= this.#o.touchesPerSec) continue;
      this.#lastTouch.set(p, now);
      this.#inSecond++;
      const by = kind !== "delete" && !this.#truncated ? (this.by?.(p) ?? null) : null;
      this.#send(JSON.stringify({ type: "touch", path: this.#out(p), kind, by }));
    }
    this.onWorktree?.();
  }

  stop() {
    this.#stopped = true;
    for (const x of this.#watched.values()) x.w.close();
    this.#watched.clear();
    for (const w of this.#gitWatchers) w.close();
    this.#gitWatchers = [];
    if (this.#settle) clearTimeout(this.#settle);
    if (this.#refsTimer) clearTimeout(this.#refsTimer);
    this.#settle = this.#refsTimer = null;
    this.#pending.clear();
    this.#files.clear();
    this.#lastTouch.clear();
  }
}

export interface CityDeps {
  io: CityIo;
  /** This host shares file names (`screen.share.code`); off = masked paths. */
  share(): boolean;
  watch?: CityWatchOpts;
}
