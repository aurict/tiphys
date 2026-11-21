// `jobs` topic (PLAN.md §20 A-2): long-running jobs of this host, every 3 s, read from /proc and /sys without
// starting a process:
//  (a) `arkaplan` jobs: user cgroups …/user@<uid>.service/app.slice/run-*.scope (`systemd-run --user --scope`):
//      cgroup.procs, cpu.stat usage_usec delta → CPU, memory.current;
//  (b) known build/test processes (cargo, gradle, flutter, vitest, tsc, make, ffmpeg, docker build, npm run …) and
//      `tools/limited.sh` jobs, alive for more than 30 s: /proc/<pid>/stat for every process (one small read each);
//      /proc/<pid>/cmdline only once per process (cached by pid + start time + comm). Only the topmost match of a
//      process tree is a job; its CPU/memory is the whole subtree's. limited.sh is recognised by its own process
//      (no environment is ever read). Daemons (Gradle/Kotlin daemon, --watch) show only while they use CPU.
//  (c) commands started from Tiphys: the agent keeps no registry of them yet, so none (exit codes stay unknown).
// A job that disappears → `jobDone` {durationSec, exitCode: null}. Command lines: wrappers (nice, ionice, taskset…)
// dropped, paths cut to their last part, redact(), ≤ 120 characters. The working directory is sent as a basename only.
import { homedir } from "node:os";
import { redact } from "../../redact.ts";
import { realFileIo, type FileIo, type Rec, type StateProducer } from "./common.ts";

export interface JobsIo extends FileIo {
  now(): number;
}

export interface JobsOpts {
  io?: JobsIo;
  intervalMs?: number;
  /** A process counts as a job after living this long. */
  minAgeMs?: number;
  procRoot?: string;
  /** …/user@<uid>.service/app.slice. */
  appSlice?: string;
  clkTck?: number;
  pageSize?: number;
  /** /proc scan cap (a fork bomb must not make every tick slow). */
  maxProcs?: number;
  home?: string;
}

export interface Job {
  id: string;
  name: string;
  cmd: string;
  dir: string | null;
  startedAt: number;
  /** Cores in use (1 = one full core). */
  cpu: number;
  mem: number;
  kind: "scope" | "proc" | "limited";
}

export interface ProcStat {
  pid: number;
  comm: string;
  ppid: number;
  /** utime + stime + cutime + cstime (clock ticks): reaped children's time stays counted. */
  ticks: number;
  start: number;
  rss: number;
}

/** /proc/<pid>/stat → the fields used (the command name may hold spaces and parentheses). */
export function parseStat(text: string): ProcStat | null {
  const open = text.indexOf("(");
  const close = text.lastIndexOf(")");
  if (open < 0 || close < open) return null;
  const r = text.slice(close + 2).split(" ");
  const n = (i: number) => Number(r[i]);
  const p: ProcStat = { pid: Number(text.slice(0, open)), comm: text.slice(open + 1, close), ppid: n(1), ticks: n(11) + n(12) + n(13) + n(14), start: n(19), rss: n(21) };
  return Number.isFinite(p.pid) && Number.isFinite(p.ticks) && Number.isFinite(p.start) ? p : null;
}

/** cpu.stat → usage_usec. */
export function parseCpuStat(text: string): number | null {
  const m = /^usage_usec (\d+)/m.exec(text);
  return m ? Number(m[1]) : null;
}

export const appSliceOf = (uid: number) => `/sys/fs/cgroup/user.slice/user-${uid}.slice/user@${uid}.service/app.slice`;

const base = (s: string) => s.slice(s.lastIndexOf("/") + 1);
const WRAPPERS = new Set(["nice", "ionice", "taskset", "setsid", "env", "time", "chrt", "stdbuf", "timeout", "systemd-inhibit"]);
/** Option-ish tokens after a wrapper: flags, numbers/CPU lists, VAR=value, durations. */
const WRAPPER_ARG = /^(-.*|[\d,.:-]+[smhd]?|[A-Za-z_][A-Za-z0-9_]*=.*)$/;

/** A process that set its title (npm: "npm run test") has one argv entry holding the whole line. */
const splitTitle = (argv: string[]) => (argv.length === 1 && argv[0]!.includes(" ") ? argv[0]!.split(" ").filter(Boolean) : argv);

/** nice -n 10 ionice -c2 -n7 cmd … → cmd …. */
export function stripWrappers(argv: string[]): string[] {
  let a = splitTitle(argv);
  while (a.length > 1 && WRAPPERS.has(base(a[0]!))) {
    a = a.slice(1);
    while (a.length > 1 && WRAPPER_ARG.test(a[0]!)) a = a.slice(1);
  }
  return a;
}

const DIRECT = new Set(["cargo", "rustc", "make", "gmake", "ninja", "cmake", "ctest", "meson", "ffmpeg", "flutter", "gradle", "gradlew", "tsc", "vitest", "jest", "hyperframes", "mvn", "webpack", "esbuild", "rollup", "pytest"]);
const PMS = new Set(["npm", "npx", "pnpm", "yarn", "bun"]);
const PM_CMDS = new Set(["run", "test", "build", "install", "ci", "exec", "x", "dlx", "i"]);
const INTERPRETERS = new Set(["node", "nodejs", "bun", "deno", "python", "python3"]);
const tool = (s: string) => base(s).replace(/\.(m?js|cjs|ts|py|sh)$/, "");

/** A known build/test command → {name, daemon}; null otherwise. `comm` is the kernel's name (exec -a doesn't change it). */
export function matchKnown(comm: string, argv: string[]): { name: string; daemon: boolean } | null {
  const a = stripWrappers(argv);
  const a0 = tool(a[0] ?? "");
  const watch = a.some((x) => x === "--watch" || x === "-w" || x === "watch");
  const hit = (name: string, daemon = watch) => ({ name, daemon });
  if (DIRECT.has(a0)) return hit(a0);
  if (PMS.has(a0) || PMS.has(comm.split(" ")[0]!)) {
    // npx vitest / npm exec tsc → the tool; npm run build → "npm run build".
    const inner = a.slice(1).map(tool).find((x) => DIRECT.has(x));
    if (inner) return hit(inner);
    if (PM_CMDS.has(a[1] ?? "")) return hit(`${PMS.has(a0) ? a0 : comm.split(" ")[0]} ${a[1]}${a[1] === "run" && a[2] ? ` ${a[2]}` : ""}`);
    return null;
  }
  if (INTERPRETERS.has(a0)) {
    const script = a.slice(1).find((x) => !x.startsWith("-"));
    const nm = script ? /\/node_modules\/(?:\.bin\/)?(@[^/]+\/)?([^/]+)/.exec(script)?.[2] : undefined;
    for (const n of [script ? tool(script) : "", nm ?? ""]) if (DIRECT.has(n)) return hit(n);
    return null;
  }
  const all = a.join(" ");
  if (a0 === "java") {
    if (/GradleDaemon|KotlinCompileDaemon/.test(all)) return hit(/Kotlin/.test(all) ? "kotlin" : "gradle", true);
    if (/org\.gradle\./.test(all)) return hit("gradle");
    return null;
  }
  if (a0 === "dart") return /flutter_tools/.test(all) ? hit("flutter") : ["compile", "test", "run", "pub"].includes(a[1] ?? "") ? hit("dart") : null;
  if (a0 === "docker" || a0 === "podman") return a[1] === "build" || (["buildx", "compose", "image"].includes(a[1] ?? "") && a.includes("build")) ? hit(`${a0} build`) : null;
  if (a0 === "go") return ["build", "test", "generate"].includes(a[1] ?? "") ? hit("go") : null;
  if (DIRECT.has(comm)) return hit(comm);
  return null;
}

/** Display form: wrappers dropped, every path cut to its last part, secrets masked, ≤ 120 characters. */
export function displayCmd(argv: string[]): string {
  const short = (t: string): string => {
    const eq = t.indexOf("=");
    if (eq > 0 && t.startsWith("-")) return t.slice(0, eq + 1) + short(t.slice(eq + 1));
    return /^(~|\.{0,2})\/|^\/|\/.*\//.test(t) && !/^\w+:\/\//.test(t) ? base(t.replace(/\/+$/, "")) || "/" : t;
  };
  const s = redact(stripWrappers(argv).map(short).join(" ").replace(/\s+/g, " ").trim());
  return s.length > 120 ? `${s.slice(0, 119)}…` : s;
}

/** limited.sh process → the command after it (bash …/limited.sh cmd …, or the script itself as argv[0]). */
export function limitedInner(comm: string, argv: string[]): string[] | null {
  const i = argv.findIndex((x, k) => k < 2 && base(x) === "limited.sh");
  if (i < 0 && comm !== "limited.sh") return null;
  return i < 0 ? null : argv.slice(i + 1);
}

interface Classified {
  name: string;
  cmd: string;
  kind: "proc" | "limited";
  daemon: boolean;
}

/** A process → a job description, or null (not a job). */
export function classify(comm: string, argv: string[]): Classified | null {
  const inner = limitedInner(comm, argv);
  if (inner) {
    if (!inner.length) return null;
    const k = matchKnown("", inner);
    return { name: k?.name ?? tool(stripWrappers(inner)[0]!), cmd: displayCmd(inner), kind: "limited", daemon: false };
  }
  const k = matchKnown(comm, argv);
  return k ? { name: k.name, cmd: displayCmd(argv), kind: "proc", daemon: k.daemon } : null;
}

interface Prev {
  at: number;
  /** usage µs (scope) or ticks (proc). */
  used: number;
}

export class JobsProducer implements StateProducer {
  readonly #io: JobsIo;
  readonly #o: Required<Omit<JobsOpts, "io">>;
  #emit: ((m: Rec) => void) | null = null;
  #timer: NodeJS.Timeout | null = null;
  /** pid:start:comm → classification (null = not a job). */
  readonly #cache = new Map<string, Classified | null>();
  /** Per job: what it is (computed once) and the last CPU counter. */
  readonly #info = new Map<string, { name: string; cmd: string; dir: string | null }>();
  readonly #prev = new Map<string, Prev>();
  /** Daemons: last time they used CPU. */
  readonly #busyAt = new Map<string, number>();
  #running = new Map<string, Job>();
  #sent: Job[] | null = null;
  #boot: number | null = null;
  /** Last scan: processes read (cost check). */
  lastScan = 0;

  constructor(o: JobsOpts = {}) {
    this.#io = o.io ?? { ...realFileIo, now: () => Date.now() };
    this.#o = {
      intervalMs: o.intervalMs ?? 3000,
      minAgeMs: o.minAgeMs ?? 30_000,
      procRoot: o.procRoot ?? "/proc",
      appSlice: o.appSlice ?? appSliceOf(process.getuid?.() ?? 0),
      clkTck: o.clkTck ?? 100,
      pageSize: o.pageSize ?? 4096,
      maxProcs: o.maxProcs ?? 8192,
      home: o.home ?? homedir(),
    };
  }

  get active() {
    return this.#timer !== null;
  }

  start(emit: (m: Rec) => void) {
    if (this.#emit) return;
    this.#emit = emit;
    this.tick();
    this.#timer = setInterval(() => this.tick(), this.#o.intervalMs);
    this.#timer.unref?.();
  }

  async stop() {
    this.#emit = null;
    if (this.#timer) clearInterval(this.#timer);
    this.#timer = null;
    for (const m of [this.#cache, this.#info, this.#prev, this.#busyAt, this.#running]) m.clear();
    this.#sent = this.#boot = null;
  }

  #dir(pid: number): string | null {
    const cwd = this.#io.link(`${this.#o.procRoot}/${pid}/cwd`);
    if (!cwd) return null;
    return cwd === this.#o.home ? "~" : base(cwd) || "/";
  }

  #argv(pid: number): string[] {
    return (this.#io.read(`${this.#o.procRoot}/${pid}/cmdline`) ?? "").split("\0").filter(Boolean);
  }

  #cpu(id: string, used: number, now: number, perSec: number): number {
    const p = this.#prev.get(id);
    this.#prev.set(id, { at: now, used });
    if (!p || now <= p.at) return 0;
    return Math.round((Math.max(0, used - p.used) / perSec / ((now - p.at) / 1000)) * 100) / 100;
  }

  /** One scan (public for tests and the cost measurement). */
  tick() {
    const io = this.#io;
    const o = this.#o;
    const now = io.now();
    if (this.#boot === null) {
      // Once per start: /proc/uptime vs. the clock jitters, start times must not.
      const uptime = Number((io.read(`${o.procRoot}/uptime`) ?? "").split(" ")[0]);
      this.#boot = Number.isFinite(uptime) ? now - uptime * 1000 : now;
    }
    const boot = this.#boot;
    const startMs = (ticks: number) => Math.round((boot + (ticks / o.clkTck) * 1000) / 1000) * 1000;

    const procs = new Map<number, ProcStat>();
    const kids = new Map<number, number[]>();
    let n = 0;
    for (const name of io.list(o.procRoot)) {
      if (!/^\d+$/.test(name)) continue;
      if (++n > o.maxProcs) break;
      const st = parseStat(io.read(`${o.procRoot}/${name}/stat`) ?? "");
      if (!st) continue;
      procs.set(st.pid, st);
      const k = kids.get(st.ppid);
      if (k) k.push(st.pid);
      else kids.set(st.ppid, [st.pid]);
    }
    this.lastScan = n;

    const running = new Map<string, Job>();
    const seen = new Set<string>();
    // (a) arkaplan scopes
    const inScope = new Set<number>();
    for (const scope of io.list(o.appSlice)) {
      if (!/^run-[^/]+\.scope$/.test(scope)) continue;
      const dir = `${o.appSlice}/${scope}`;
      const pids = (io.read(`${dir}/cgroup.procs`) ?? "").split("\n").map(Number).filter((x) => x > 0);
      if (!pids.length) continue;
      for (const p of pids) inScope.add(p);
      const root = pids.map((p) => procs.get(p)).filter((p) => p !== undefined).sort((x, y) => x.start - y.start || x.pid - y.pid)[0];
      if (!root) continue;
      const id = `scope:${scope}`;
      seen.add(id);
      let info = this.#info.get(id);
      if (!info) {
        const argv = this.#argv(root.pid);
        const k = matchKnown(root.comm, argv);
        info = { name: k?.name ?? (tool(stripWrappers(argv)[0] ?? "") || root.comm), cmd: displayCmd(argv) || root.comm, dir: this.#dir(root.pid) };
        this.#info.set(id, info);
      }
      const usage = parseCpuStat(io.read(`${dir}/cpu.stat`) ?? "");
      const mem = Number(io.read(`${dir}/memory.current`));
      running.set(id, { id, ...info, startedAt: startMs(root.start), cpu: usage === null ? 0 : this.#cpu(id, usage, now, 1e6), mem: Number.isFinite(mem) ? mem : 0, kind: "scope" });
    }

    // (b) known processes and limited.sh, topmost of each tree, outside the scopes
    const matched = new Map<number, Classified>();
    const live = new Set<string>();
    for (const p of procs.values()) {
      if (inScope.has(p.pid) || p.ppid === 2 || p.pid === 2) continue; // kernel threads
      if (now - startMs(p.start) < o.minAgeMs) continue;
      const key = `${p.pid}:${p.start}:${p.comm}`;
      live.add(key);
      let c = this.#cache.get(key);
      if (c === undefined) {
        c = classify(p.comm, this.#argv(p.pid));
        this.#cache.set(key, c);
      }
      if (c) matched.set(p.pid, c);
    }
    for (const k of this.#cache.keys()) if (!live.has(k)) this.#cache.delete(k);
    for (const [pid, c] of matched) {
      let up = procs.get(pid)!.ppid;
      let nested = false;
      for (let i = 0; i < 64 && up > 1; i++) {
        if (matched.has(up)) {
          nested = true;
          break;
        }
        up = procs.get(up)?.ppid ?? 0;
      }
      if (nested) continue;
      let ticks = 0;
      let rss = 0;
      const stack = [pid];
      while (stack.length) {
        const q = procs.get(stack.pop()!);
        if (!q) continue;
        ticks += q.ticks;
        rss += q.rss;
        stack.push(...(kids.get(q.pid) ?? []));
      }
      const p = procs.get(pid)!;
      const id = `proc:${pid}:${p.start}`;
      seen.add(id);
      let info = this.#info.get(id);
      if (!info) {
        info = { name: c.name, cmd: c.cmd, dir: this.#dir(pid) };
        this.#info.set(id, info);
      }
      const cpu = this.#cpu(id, ticks, now, o.clkTck);
      if (c.daemon) {
        if (cpu >= 0.05) this.#busyAt.set(id, now);
        if (now - (this.#busyAt.get(id) ?? -Infinity) > 60_000) continue;
      }
      running.set(id, { id, ...info, startedAt: startMs(p.start), cpu, mem: rss * o.pageSize, kind: c.kind });
    }
    for (const m of [this.#info, this.#prev, this.#busyAt]) for (const k of m.keys()) if (!seen.has(k)) m.delete(k);

    const ended = [...this.#running.values()].filter((j) => !running.has(j.id) && !seen.has(j.id));
    this.#running = running;
    const emit = this.#emit;
    if (!emit) return;
    for (const j of ended) {
      emit({ type: "jobDone", id: j.id, name: j.name, cmd: j.cmd, dir: j.dir, kind: j.kind, durationSec: Math.max(0, Math.round((now - j.startedAt) / 1000)), exitCode: null });
    }
    const list = [...running.values()].sort((a, b) => a.startedAt - b.startedAt);
    if (!jobsChanged(this.#sent, list)) return;
    this.#sent = list;
    emit({ type: "jobs", running: list });
  }
}

/** Same jobs and CPU/memory within 0.05 core / 5 %: not worth a message. */
export function jobsChanged(a: Job[] | null, b: Job[]): boolean {
  if (!a || a.length !== b.length) return true;
  return b.some((j, i) => {
    const p = a[i]!;
    return p.id !== j.id || Math.abs(p.cpu - j.cpu) >= 0.05 || Math.abs(p.mem - j.mem) > Math.max(p.mem, j.mem) * 0.05;
  });
}
