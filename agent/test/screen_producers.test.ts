// Screen mode Work producers (PLAN.md §20 W2): system (delta suppression, one nvidia-smi child), jobs (cgroup and /proc
// fixture trees, known-process matching, command line clean-up), git (porcelain v2, commits, CI, one watcher per root),
// project auto-selection (fake Claude session files + fake /proc) and path containment, and the feed's
// first-subscriber-starts / last-subscriber-stops rule with nothing left behind. Fixture files in temp dirs, fake
// children and watchers; no real nvidia-smi, git, gh or Hyprland.
import { EventEmitter } from "node:events";
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { afterEach, describe, expect, it, vi } from "vitest";
import { terminalSessions } from "../src/claude/terminal.ts";
import { realFileIo, type FileIo } from "../src/screen/producers/common.ts";
import { gitMessage, GitTopic, GitWatch, parseCi, parseCommits, realGitIo, type GitIo } from "../src/screen/producers/git.ts";
import { classify, displayCmd, JobsProducer, jobsChanged, matchKnown, parseCpuStat, parseStat, stripWrappers } from "../src/screen/producers/jobs.ts";
import { gitRootOf, parseProject, pickProject, ProjectSelector, relativeTo, rootLabel, shellCwd, type SelectorIo } from "../src/screen/producers/project.ts";
import { serversMessage, ServersProducer } from "../src/screen/producers/servers.ts";
import { changed, findBattery, findCpuTemp, findIntelIdle, parseMeminfo, parseProcStat, parseSmiLine, SMI_ARGS, SystemProducer, type SmiChild, type SystemIo, type SystemSample } from "../src/screen/producers/system.ts";
import { FeedProducer, type Sock, type SourceIo } from "../src/screen/source.ts";

const cleanups: Array<() => unknown> = [];
afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
});

const until = async (f: () => boolean, ms = 3000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 5));
  }
};

/** Writes {relative path: content} under a new temp dir. */
async function tree(files: Record<string, string>) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-w2-"));
  cleanups.push(() => rm(dir, { recursive: true, force: true }));
  for (const [p, c] of Object.entries(files)) {
    await mkdir(join(dir, p, ".."), { recursive: true });
    await writeFile(join(dir, p), c);
  }
  return dir;
}

/** A /proc/<pid>/stat line: utime/stime/cutime/cstime, start time (ticks), rss (pages). */
const stat = (pid: number, comm: string, ppid: number, o: { ticks?: number; start?: number; rss?: number } = {}) =>
  `${pid} (${comm}) S ${ppid} ${pid} ${pid} 0 -1 4194560 100 0 0 0 ${o.ticks ?? 0} 0 0 0 20 0 1 0 ${o.start ?? 100} 1000000 ${o.rss ?? 10} 18446744073709551615\n`;

// ---------------------------------------------------------------- system

describe("system producer", () => {
  it("parses /proc/stat, /proc/meminfo, nvidia-smi lines; picks the CPU sensor, the battery and the Intel idle counter", async () => {
    expect(parseProcStat("cpu  100 0 50 800 50 0 0 0 0 0\ncpu0 1 0 0 0 0\ncpu1 1 0 0 0 0\nintr 1")).toEqual({ total: 1000, idle: 850, cores: 2 });
    expect(parseProcStat("garbage")).toBeNull();
    expect(parseMeminfo("MemTotal:       16000 kB\nMemFree: 1 kB\nMemAvailable:    4000 kB\n")).toEqual({ used: 12000 * 1024, total: 16000 * 1024 });
    expect(parseSmiLine("37, 61, 1200, 4096")).toEqual({ util: 0.37, temp: 61, memUsed: 1200 * 1048576, memTotal: 4096 * 1048576 });
    expect(parseSmiLine("[N/A], [N/A], 1, 2")).toBeNull();
    expect(parseSmiLine("5, [N/A], [N/A], [N/A]")).toEqual({ util: 0.05, temp: null, memUsed: null, memTotal: null });
    const root = await tree({
      "hwmon/hwmon0/name": "nvme\n", "hwmon/hwmon0/temp1_input": "40000\n",
      "hwmon/hwmon1/name": "coretemp\n", "hwmon/hwmon1/temp1_input": "51000\n", "hwmon/hwmon1/temp1_label": "Package id 0\n",
      "hwmon/hwmon1/temp2_input": "48000\n", "hwmon/hwmon1/temp2_label": "Core 0\n",
      "ps/hidpp_battery_0/type": "Battery\n", "ps/hidpp_battery_0/scope": "Device\n", "ps/hidpp_battery_0/capacity": "90\n",
      "ps/AC/type": "Mains\n", "ps/BAT0/type": "Battery\n", "ps/BAT0/capacity": "54\n", "ps/BAT0/status": "Discharging\n",
      "drm/card0-eDP-1/x": "", "drm/card1/gt/gt0/rc6_residency_ms": "1000\n",
    });
    expect(findCpuTemp(realFileIo, `${root}/hwmon`)).toBe(`${root}/hwmon/hwmon1/temp1_input`);
    expect(findBattery(realFileIo, `${root}/ps`)).toBe(`${root}/ps/BAT0`);
    expect(findIntelIdle(realFileIo, `${root}/drm`)).toBe(`${root}/drm/card1/gt/gt0/rc6_residency_ms`);
    expect(findCpuTemp(realFileIo, `${root}/nope`)).toBeNull();
  });

  it("delta thresholds", () => {
    const a: SystemSample = { cpu: 0.2, cores: 8, mem: { used: 4e9, total: 16e9 }, temp: 50, gpu: { util: 0.1, temp: 40, memUsed: 1e9, memTotal: 4e9 }, battery: { level: 80, charging: false } };
    expect(changed(null, a)).toBe(true);
    expect(changed(a, { ...a, cpu: 0.21, temp: 50.6, mem: { used: 4.05e9, total: 16e9 } })).toBe(false);
    expect(changed(a, { ...a, cpu: 0.23 })).toBe(true);
    expect(changed(a, { ...a, temp: 51.2 })).toBe(true);
    expect(changed(a, { ...a, mem: { used: 4.1e9, total: 16e9 } })).toBe(true);
    expect(changed(a, { ...a, gpu: null })).toBe(true);
    expect(changed(a, { ...a, gpu: { ...a.gpu!, util: 0.11 } })).toBe(false);
    expect(changed(a, { ...a, battery: { level: 79, charging: false } })).toBe(true);
    expect(changed(a, { ...a, battery: { level: 80, charging: true } })).toBe(true);
    expect(changed(a, { ...a, temp: null })).toBe(true);
  });

  it("samples every tick, sends only changes; one nvidia-smi child, killed on stop; nothing left", async () => {
    const files: Record<string, string> = {
      "/proc/meminfo": "MemTotal: 1000 kB\nMemAvailable: 600 kB\n",
      "/proc/stat": "cpu 0 0 0 0 0 0 0 0\ncpu0 0\n",
    };
    let cpuTotal = 0;
    let busy = 0;
    const setCpu = (busyAdd: number, totalAdd: number) => {
      busy += busyAdd;
      cpuTotal += totalAdd;
      files["/proc/stat"] = `cpu ${busy} 0 0 ${cpuTotal - busy} 0 0 0 0\ncpu0 0\ncpu1 0\n`;
    };
    const children: Array<EventEmitter & SmiChild & { args: string[]; killed: string[] }> = [];
    const io: SystemIo = {
      read: (p) => files[p] ?? null,
      list: () => [],
      link: () => null,
      now: () => Date.now(),
      has: (c) => c === "nvidia-smi",
      spawn: (cmd, args) => {
        const c = Object.assign(new EventEmitter(), { stdout: new PassThrough(), exitCode: null as number | null, signalCode: null, args, killed: [] as string[] }) as never as EventEmitter & SmiChild & { args: string[]; killed: string[] };
        c.kill = (sig?: NodeJS.Signals) => {
          c.killed.push(sig ?? "SIGTERM");
          c.exitCode = 0;
          queueMicrotask(() => c.emit("exit"));
          return true;
        };
        expect(cmd).toBe("nvidia-smi");
        children.push(c);
        return c;
      },
    };
    const p = new SystemProducer(io, { intervalMs: 20 });
    const got: Array<Record<string, unknown>> = [];
    setCpu(0, 100);
    p.start((m) => got.push(m));
    expect(children.length).toBe(1);
    expect(children[0]!.args).toEqual(SMI_ARGS);
    expect(got).toEqual([]); // the first CPU sample has no delta yet
    setCpu(50, 100);
    (children[0]!.stdout as PassThrough).write("37, 61, 1200, 4096\n");
    await until(() => got.length === 1);
    expect(got[0]).toEqual({ type: "system", cpu: 0.5, cores: 2, mem: { used: 400 * 1024, total: 1000 * 1024 }, temp: null, gpu: { util: 0.37, temp: 61, memUsed: 1200 * 1048576, memTotal: 4096 * 1048576 }, battery: null });
    // Steady load: ticks keep sampling, no message.
    for (let i = 0; i < 5; i++) {
      setCpu(50, 100);
      await new Promise((r) => setTimeout(r, 25));
    }
    expect(got.length).toBe(1);
    setCpu(90, 100);
    await until(() => got.length === 2);
    expect(got[1]!.cpu).toBe(0.9);
    await p.stop();
    expect(children[0]!.killed).toEqual(["SIGTERM"]);
    expect(p.active).toBe(false);
    const n = got.length;
    setCpu(10, 100);
    await new Promise((r) => setTimeout(r, 60));
    expect(got.length).toBe(n);
    expect(children.length).toBe(1);
  });
});

// ---------------------------------------------------------------- jobs

describe("jobs producer", () => {
  it("known-process matching", () => {
    const m = (comm: string, ...argv: string[]) => matchKnown(comm, argv)?.name ?? null;
    expect(m("cargo", "cargo", "build", "--release")).toBe("cargo");
    expect(m("sleep", "vitest", "40")).toBe("vitest"); // exec -a vitest sleep 40
    expect(m("node", "/usr/bin/node", "/home/u/p/node_modules/vitest/vitest.mjs", "run")).toBe("vitest");
    expect(m("node", "node", "/home/u/p/node_modules/typescript/bin/tsc", "--noEmit")).toBe("tsc");
    expect(m("node", "node", "/home/u/p/node_modules/.bin/jest")).toBe("jest");
    expect(m("npm exec vitest", "npm", "exec", "vitest", "run")).toBe("vitest");
    expect(m("npm run build", "npm run build")).toBe("npm run build");
    expect(m("pnpm", "pnpm", "run", "test")).toBe("pnpm run test");
    expect(m("npm", "npm", "ci")).toBe("npm ci");
    expect(m("java", "/usr/lib/jvm/bin/java", "-Xmx2g", "-cp", "gradle.jar", "org.gradle.launcher.daemon.bootstrap.GradleDaemon", "8.7")).toBe("gradle");
    expect(matchKnown("java", ["java", "org.gradle.launcher.daemon.bootstrap.GradleDaemon"])!.daemon).toBe(true);
    expect(m("java", "java", "-cp", "x", "org.gradle.wrapper.GradleWrapperMain", "assembleRelease")).toBe("gradle");
    expect(m("dart", "dart", "/opt/flutter/bin/cache/flutter_tools.snapshot", "build", "apk")).toBe("flutter");
    expect(m("docker", "docker", "build", "-t", "x", ".")).toBe("docker build");
    expect(m("docker", "docker", "compose", "build")).toBe("docker build");
    expect(m("docker", "docker", "ps")).toBeNull();
    expect(m("ffmpeg", "ffmpeg", "-i", "a.mp4", "b.mp4")).toBe("ffmpeg");
    expect(m("nice", "nice", "-n", "10", "ionice", "-c2", "-n7", "hyperframes", "render", "--gpu")).toBe("hyperframes");
    expect(m("make", "make", "-j8")).toBe("make");
    // Not jobs: shells, servers, the agent itself, an interactive node, java without gradle.
    for (const [c, ...a] of [["zsh", "-zsh"], ["node", "node", "dist/cli.js", "serve"], ["node", "node"], ["java", "java", "-jar", "server.jar"], ["firefox", "firefox"], ["npm", "npm", "start"]]) {
      expect(matchKnown(c!, a)).toBeNull();
    }
    expect(matchKnown("node", ["node", "node_modules/.bin/tsc", "--watch"])).toEqual({ name: "tsc", daemon: true });
  });

  it("command lines: wrappers dropped, paths cut, secrets masked, ≤ 120 characters; limited.sh by its own process", () => {
    expect(stripWrappers(["taskset", "-c", "0,1", "nice", "-n", "15", "ionice", "-c2", "-n7", "npx", "vitest"])).toEqual(["npx", "vitest"]);
    expect(stripWrappers(["env", "A=1", "B=2", "make"])).toEqual(["make"]);
    expect(displayCmd(["/usr/bin/node", "/home/someone/secret-project/node_modules/vitest/vitest.mjs", "run", "--dir=/home/someone/x/y"])).toBe("node vitest.mjs run --dir=y");
    expect(displayCmd(["ffmpeg", "-i", "~/Videos/a b.mp4", "https://example.com/a/b/c"])).toBe("ffmpeg -i a b.mp4 https://example.com/a/b/c");
    expect(displayCmd(["curl", "-H", "Authorization: Bearer abcdefghijklmnopqrstuvwxyz0123456789"])).not.toContain("abcdefghijklmnop");
    const long = displayCmd(["cargo", "build", ...Array.from({ length: 60 }, (_, i) => `--feature-${i}`)]);
    expect(long.length).toBe(120);
    expect(long.endsWith("…")).toBe(true);
    expect(displayCmd(["cargo", "build"])).not.toContain("/home");
    expect(classify("limited.sh", ["bash", "../tools/limited.sh", "npx", "vitest", "run"])).toEqual({ name: "vitest", cmd: "npx vitest run", kind: "limited", daemon: false });
    expect(classify("limited.sh", ["/bin/bash", "/home/u/tiphys/tools/limited.sh", "flutter", "build", "apk"])).toMatchObject({ name: "flutter", kind: "limited" });
    expect(classify("bash", ["bash", "-c", "echo"])).toBeNull();
  });

  it("parses stat (comm with spaces and parens) and cpu.stat", () => {
    expect(parseStat(stat(42, "node (vitest 1)", 7, { ticks: 5, start: 900, rss: 3 }))).toEqual({ pid: 42, comm: "node (vitest 1)", ppid: 7, ticks: 5, start: 900, rss: 3 });
    expect(parseStat("nonsense")).toBeNull();
    expect(parseCpuStat("usage_usec 123456\nuser_usec 1\n")).toBe(123456);
    expect(parseCpuStat("")).toBeNull();
  });

  it("fixture /proc + cgroups: arkaplan scopes, topmost known process with its subtree, limited.sh, young ones skipped; jobDone", async () => {
    // Boot at t=0; now = 1000 s → ticks start = seconds * 100.
    const files: Record<string, string> = {
      "proc/uptime": "1000.00 5000.00\n",
      // arkaplan: run-r1.scope holds 500 (ffmpeg, started at 100 s) and its child 501.
      "slice/run-r1.scope/cgroup.procs": "501\n500\n",
      "slice/run-r1.scope/cpu.stat": "usage_usec 1000000\nuser_usec 1\n",
      "slice/run-r1.scope/memory.current": "52428800\n",
      "slice/run-empty.scope/cgroup.procs": "",
      "slice/app-firefox.scope/cgroup.procs": "900\n",
      "slice/tiphys-agent.service/cgroup.procs": "910\n",
      "proc/500/stat": stat(500, "ffmpeg", 1, { start: 10_000 }),
      "proc/500/cmdline": "ffmpeg\0-i\0/home/u/Videos/in.mp4\0out.webm\0",
      "proc/501/stat": stat(501, "ffmpeg", 500, { start: 10_000 }),
      // npm run test → node vitest (both match; the topmost wins and counts the subtree) → worker.
      "proc/600/stat": stat(600, "npm run test", 1, { start: 20_000, ticks: 100, rss: 100 }),
      "proc/600/cmdline": "npm run test\0",
      "proc/601/stat": stat(601, "node", 600, { start: 20_000, ticks: 300, rss: 200 }),
      "proc/601/cmdline": "node\0/x/node_modules/vitest/vitest.mjs\0run\0",
      "proc/602/stat": stat(602, "node (vitest 1)", 601, { start: 20_000, ticks: 600, rss: 300 }),
      "proc/602/cmdline": "node (vitest 1)\0",
      // limited.sh with its job.
      "proc/700/stat": stat(700, "limited.sh", 1, { start: 30_000 }),
      "proc/700/cmdline": "bash\0../tools/limited.sh\0cargo\0build\0",
      "proc/701/stat": stat(701, "cargo", 700, { start: 30_000, ticks: 50 }),
      "proc/701/cmdline": "cargo\0build\0",
      // Too young (started 10 s ago), a shell, firefox (another scope, not run-*) and the agent.
      "proc/800/stat": stat(800, "rustc", 1, { start: 99_000 }),
      "proc/800/cmdline": "rustc\0",
      "proc/810/stat": stat(810, "zsh", 1, { start: 100 }),
      "proc/810/cmdline": "-zsh\0",
      "proc/900/stat": stat(900, "firefox", 1, { start: 100 }),
      "proc/900/cmdline": "firefox\0",
      "proc/910/stat": stat(910, "node", 1, { start: 100 }),
      "proc/910/cmdline": "node\0dist/cli.js\0serve\0",
      "proc/2/stat": stat(2, "kthreadd", 0),
      "proc/3/stat": stat(3, "make", 2),
      "proc/self": "",
    };
    const root = await tree(files);
    let now = 1_000_000;
    const reads: string[] = [];
    const io = {
      read: (p: string) => (reads.push(p), realFileIo.read(p)),
      list: realFileIo.list,
      link: (p: string) => (p.endsWith("/600/cwd") ? "/home/u/work/agent" : p.endsWith("/500/cwd") ? "/home/u" : null),
      now: () => now,
    };
    const jobs = new JobsProducer({ io, procRoot: `${root}/proc`, appSlice: `${root}/slice`, home: "/home/u", intervalMs: 60_000 });
    const got: Array<Record<string, unknown>> = [];
    jobs.start((m) => got.push(m));
    expect(got.length).toBe(1);
    const run1 = got[0]!.running as Array<Record<string, unknown>>;
    expect(run1.map((j) => [j.id, j.name, j.cmd, j.kind, j.dir])).toEqual([
      ["scope:run-r1.scope", "ffmpeg", "ffmpeg -i in.mp4 out.webm", "scope", "~"],
      ["proc:600:20000", "npm run test", "npm run test", "proc", "agent"],
      ["proc:700:30000", "cargo", "cargo build", "limited", null],
    ]);
    expect(run1[0]).toMatchObject({ startedAt: 100_000, mem: 52428800, cpu: 0 });
    expect(run1[1]).toMatchObject({ startedAt: 200_000, mem: 600 * 4096 });
    // cmdline is read once per process: the next tick reads stat files only (and the cgroup files).
    reads.length = 0;
    await writeFile(`${root}/slice/run-r1.scope/cpu.stat`, "usage_usec 4000000\n");
    await writeFile(`${root}/proc/602/stat`, stat(602, "node (vitest 1)", 601, { start: 20_000, ticks: 900, rss: 300 }));
    now += 3000;
    jobs.tick();
    expect(reads.filter((r) => r.endsWith("/cmdline"))).toEqual([]);
    const run2 = got.at(-1)!.running as Array<Record<string, unknown>>;
    expect(run2[0]!.cpu).toBe(1); // 3 s of CPU in 3 s
    expect(run2[1]!.cpu).toBe(1); // 300 ticks / 100 Hz / 3 s
    // The vitest tree ends: jobDone with its duration, no exit code.
    for (const pid of ["600", "601", "602"]) await writeFile(`${root}/proc/${pid}/stat`, "");
    now += 3000;
    jobs.tick();
    expect(got.at(-2)).toEqual({ type: "jobDone", id: "proc:600:20000", name: "npm run test", cmd: "npm run test", dir: "agent", kind: "proc", durationSec: 806, exitCode: null });
    expect((got.at(-1)!.running as unknown[]).length).toBe(2);
    // Nothing changed: no message.
    const n = got.length;
    now += 3000;
    jobs.tick();
    expect(got.length).toBe(n);
    await jobs.stop();
    expect(jobs.active).toBe(false);
  });

  it("jobsChanged ignores small CPU/memory moves", () => {
    const j = { id: "a", name: "x", cmd: "x", dir: null, startedAt: 0, cpu: 1, mem: 1000, kind: "proc" as const };
    expect(jobsChanged(null, [])).toBe(true);
    expect(jobsChanged([j], [{ ...j, cpu: 1.04, mem: 1040 }])).toBe(false);
    expect(jobsChanged([j], [{ ...j, cpu: 1.1 }])).toBe(true);
    expect(jobsChanged([j], [])).toBe(true);
  });
});

// ---------------------------------------------------------------- git

const PORCELAIN = [
  "# branch.oid 4758fb0aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  "# branch.head screen-modes",
  "# branch.upstream origin/screen-modes",
  "# branch.ab +2 -1",
  "1 .M N... 100644 100644 100644 abc abc agent/src/a.ts",
  "1 M. N... 100644 100644 100644 abc abc display/b b.js",
  "2 R. N... 100644 100644 100644 abc abc R100 new.ts\told.ts",
  "u UU N... 100644 100644 100644 100644 a b c conflict.ts",
  "? untracked/file.txt",
  "? other.md",
].join("\n");

describe("git", () => {
  it("porcelain v2 + log → the message: counts, commits, no path but the root's basename", () => {
    const commits = parseCommits(`4758fb0\x1fdocs: screen routes\x1f1763700000\x1e\n4b03498\x1f${"x".repeat(100)}\x1f1763690000\x1e\n`);
    expect(commits[0]).toEqual({ hash7: "4758fb0", subject: "docs: screen routes", at: 1763700000000 });
    expect(commits[1]!.subject.length).toBe(80);
    const m = gitMessage("/home/someone/Desktop/tiphys", PORCELAIN, commits, null);
    expect(m).toMatchObject({ type: "git", root: "tiphys", branch: "screen-modes", head: "4758fb0", upstream: true, ahead: 2, behind: 1, changed: 3, untracked: 2, conflicts: 1, ci: null });
    expect(JSON.stringify(m)).not.toContain("/home");
    expect(JSON.stringify(m)).not.toContain("agent/src"); // counts only, no file names
    expect(gitMessage("/r", "# branch.oid (initial)\n# branch.head main\n", [], null)).toMatchObject({ branch: "main", head: null, upstream: false, ahead: 0, changed: 0 });
    expect(gitMessage("/r", "# branch.oid abc\n# branch.head (detached)\n", [], null).branch).toBeNull();
    expect(parseCi('[{"status":"completed","conclusion":"success","createdAt":"2026-11-21T10:00:00Z"}]')).toEqual({ state: "ok", at: "2026-11-21T10:00:00Z" });
    expect(parseCi('[{"status":"in_progress","conclusion":"","createdAt":"x"}]').state).toBe("running");
    expect(parseCi('[{"status":"completed","conclusion":"failure"}]').state).toBe("fail");
    expect(parseCi("[]").state).toBe("none");
    expect(parseCi("not json").state).toBe("none");
  });

  /** Fake git io: watchers, git/gh calls; `fire(dir, file)` simulates a change. */
  function fakeGit(o: { gh?: boolean } = {}) {
    const watchers = new Map<string, { fn: (f: string | null) => void; closed: boolean }>();
    const calls: string[][] = [];
    let head = "aaaaaaa";
    const io: GitIo = {
      run: async (cmd, args) => {
        calls.push([cmd, ...args]);
        if (cmd === "gh") return { stdout: '[{"status":"completed","conclusion":"success","createdAt":"t"}]', code: 0 };
        if (args.includes("status")) return { stdout: `# branch.oid ${head}\n# branch.head main\n`, code: 0 };
        return { stdout: `${head}\x1fsubject ${head}\x1f1000\x1e`, code: 0 };
      },
      watch: (dir, fn) => {
        const w = { fn, closed: false };
        watchers.set(dir, w);
        return { close: () => void (w.closed = true) };
      },
      read: async () => null,
      list: async (d) => (d.endsWith("/refs/remotes") ? ["origin"] : []),
      has: (c) => c === "gh" && o.gh === true,
    };
    return { io, watchers, calls, setHead: (h: string) => (head = h), fire: (dir: string, f: string | null) => watchers.get(dir)!.fn(f) };
  }

  const sock = (): Sock & { got: Array<Record<string, unknown>> } => {
    const got: Array<Record<string, unknown>> = [];
    return { readyState: 1, bufferedAmount: 0, got, send: (d) => got.push(JSON.parse(String(d)) as Record<string, unknown>), close() {} };
  };

  it("one watcher per root shared by its subscribers; fs events debounced into one status; CI only when asked; all closed", async () => {
    const g = fakeGit({ gh: true });
    const roots: Record<string, string> = { "/w/a/sub": "/w/a", "/w/a": "/w/a", "/w/b": "/w/b" };
    const topic = new GitTopic({
      io: g.io,
      selector: () => ({ root: null, known: false, active: false, start() {}, stop() {} }),
      resolve: async (p) => (p === "/etc" ? { none: "notAllowed" } : roots[p] ? { root: roots[p]! } : { none: "notRepo" }),
      watch: { debounceMs: 20, refreshMs: 60_000, ciMs: 60_000 },
    });
    const s1 = sock();
    const s2 = sock();
    const s3 = sock();
    topic.set(s1, { project: "/w/a", ci: false });
    topic.set(s2, { project: "/w/a/sub", ci: false });
    topic.set(s3, { project: "/etc", ci: false });
    await until(() => s1.got.length === 1 && s2.got.length === 1 && s3.got.length === 1);
    expect(topic.roots).toEqual(["/w/a"]);
    expect(s1.got[0]).toMatchObject({ type: "git", root: "a", branch: "main", commits: [{ hash7: "aaaaaaa", subject: "subject aaaaaaa", at: 1_000_000 }], ci: null });
    expect(s3.got[0]).toEqual({ type: "git", root: null, none: "notAllowed" });
    // git dir (filtered by name), refs/heads and each remote's refs are watched.
    expect([...g.watchers.keys()].sort()).toEqual(["/w/a/.git", "/w/a/.git/refs/heads", "/w/a/.git/refs/remotes/origin"]);
    const runs = g.calls.filter((c) => c[0] === "git").length;
    g.fire("/w/a/.git", "index.lock"); // ignored
    g.fire("/w/a/.git", "objects");
    await new Promise((r) => setTimeout(r, 50));
    expect(g.calls.filter((c) => c[0] === "git").length).toBe(runs);
    g.setHead("bbbbbbb");
    for (let i = 0; i < 5; i++) g.fire("/w/a/.git", "index");
    g.fire("/w/a/.git/refs/heads", "main");
    await until(() => s1.got.length === 2 && s2.got.length === 2);
    expect(g.calls.filter((c) => c[0] === "git").length).toBe(runs + 2); // one status + one log
    expect(s1.got[1]).toMatchObject({ head: "bbbbbbb" });
    // Same state again: no message.
    g.fire("/w/a/.git", "HEAD");
    await new Promise((r) => setTimeout(r, 60));
    expect(s1.got.length).toBe(2);
    expect(g.calls.some((c) => c[0] === "gh")).toBe(false);
    topic.set(s2, { project: "/w/a/sub", ci: true });
    await until(() => s1.got.some((m) => (m.ci as { state?: string } | null)?.state === "ok"));
    expect(g.calls.find((c) => c[0] === "gh")).toEqual(["gh", "run", "list", "--limit", "1", "--json", "status,conclusion,createdAt", "--branch", "main"]);
    // Moving s1 to another root keeps /w/a for s2; the last subscriber gone closes everything.
    topic.set(s1, { project: "/w/b", ci: false });
    await until(() => topic.roots.length === 2);
    const wa = topic.watchOf("/w/a")!;
    topic.set(s2, null);
    expect(wa.active).toBe(false);
    expect(g.watchers.get("/w/a/.git")!.closed).toBe(true);
    topic.set(s1, null);
    topic.set(s3, null);
    expect(topic.active).toBe(false);
    expect([...g.watchers.values()].every((w) => w.closed)).toBe(true);
  });

  it("auto subscribers follow the selector; the selector runs only while someone asks for auto", async () => {
    const g = fakeGit();
    let change: ((r: string | null) => void) | null = null;
    const sel = { root: null as string | null, known: false, active: false, start() { sel.active = true; }, stop() { sel.active = false; } };
    const topic = new GitTopic({ io: g.io, selector: (fn) => ((change = fn), sel), resolve: async () => ({ none: "notRepo" }), watch: { debounceMs: 5 } });
    const s = sock();
    topic.set(s, { project: "auto", ci: false });
    expect(sel.active).toBe(true);
    change!(null);
    expect(s.got).toEqual([{ type: "git", root: null, none: "noProject" }]);
    change!("/w/a");
    await until(() => s.got.length === 2);
    expect(s.got[1]).toMatchObject({ root: "a", branch: "main" });
    change!("/w/b");
    await until(() => topic.roots.join() === "/w/b");
    topic.set(s, { project: "/w/b", ci: false });
    expect(sel.active).toBe(false);
    topic.stop();
    expect(topic.active).toBe(false);
  });
});

// ---------------------------------------------------------------- project

describe("git CI (W7)", () => {
  /** Fake git io that answers gh with `ci` (null: gh fails) and counts the calls. */
  function ciIo(o: { gh: boolean; ci: () => string | null }) {
    const calls: Array<{ cmd: string; args: string[]; timeoutMs: number }> = [];
    const io: GitIo = {
      run: async (cmd, args, opt) => {
        calls.push({ cmd, args, timeoutMs: opt.timeoutMs });
        if (cmd === "gh") {
          const out = o.ci();
          return out === null ? { stdout: "", code: 4 } : { stdout: out, code: 0 };
        }
        if (args.includes("status")) return { stdout: "# branch.oid aaaaaaa\n# branch.head main\n", code: 0 };
        return { stdout: "", code: 0 };
      },
      watch: () => ({ close() {} }),
      read: async () => null,
      list: async () => [],
      has: (c) => c === "gh" && o.gh,
    };
    return { io, gh: () => calls.filter((c) => c.cmd === "gh") };
  }

  it("every 5 minutes with a 10 s timeout while on; never while off; no gh or a failing gh → ci null", async () => {
    vi.useFakeTimers();
    cleanups.push(() => vi.useRealTimers());
    let out: string | null = '[{"status":"completed","conclusion":"success","createdAt":"t"}]';
    const f = ciIo({ gh: true, ci: () => out });
    const got: Array<Record<string, unknown>> = [];
    const w = new GitWatch("/w/a", f.io, (d) => got.push(JSON.parse(d) as Record<string, unknown>));
    await w.start();
    await vi.advanceTimersByTimeAsync(30 * 60_000);
    expect(f.gh()).toEqual([]); // off: zero calls in half an hour
    w.setCi(true);
    await vi.advanceTimersByTimeAsync(10);
    expect(f.gh().length).toBe(1);
    expect(f.gh()[0]!.timeoutMs).toBe(10_000);
    expect(got.at(-1)!.ci).toEqual({ state: "ok", at: "t" });
    await vi.advanceTimersByTimeAsync(5 * 60_000 - 100);
    expect(f.gh().length).toBe(1);
    await vi.advanceTimersByTimeAsync(200);
    expect(f.gh().length).toBe(2);
    out = null; // logged out / no GitHub remote / timeout
    await vi.advanceTimersByTimeAsync(5 * 60_000);
    expect(f.gh().length).toBe(3);
    expect(got.at(-1)!.ci).toBeNull();
    w.setCi(false);
    await vi.advanceTimersByTimeAsync(30 * 60_000);
    expect(f.gh().length).toBe(3);
    w.stop();
    expect(w.active).toBe(false);
    // gh not installed: on, but nothing is called and ci stays null.
    const n = ciIo({ gh: false, ci: () => "[]" });
    const got2: Array<Record<string, unknown>> = [];
    const w2 = new GitWatch("/w/a", n.io, (d) => got2.push(JSON.parse(d) as Record<string, unknown>));
    await w2.start();
    w2.setCi(true);
    await vi.advanceTimersByTimeAsync(20 * 60_000);
    expect(n.gh()).toEqual([]);
    expect(got2.every((m) => m.ci === null)).toBe(true);
    w2.stop();
  });

  it("end to end with a fake gh on PATH and a real repository: pass/fail/running/none/logged out/timeout; off spawns nothing", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-w7-ci-"));
    cleanups.push(() => rm(dir, { recursive: true, force: true }));
    const bin = join(dir, "bin");
    const repo = join(dir, "repo");
    await mkdir(bin);
    await mkdir(repo);
    const git = (...a: string[]) => execFileSync("git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@example.com", ...a], { stdio: "ignore" });
    git("init", "-q", "-b", "main");
    await writeFile(join(repo, "a.txt"), "a\n");
    git("add", "a.txt");
    git("commit", "-q", "-m", "first");
    const run = (conclusion: string, status = "completed") => `[{"status":"${status}","conclusion":"${conclusion}","createdAt":"2026-11-21T10:00:00Z"}]`;
    const script = `#!/bin/sh
echo "$*" >> "${dir}/calls"
case "$(cat "${dir}/mode")" in
  pass) echo '${run("success")}' ;;
  fail) echo '${run("failure")}' ;;
  running) echo '${run("", "in_progress")}' ;;
  none) echo '[]' ;;
  loggedout) echo "To get started with GitHub CLI, please run:  gh auth login" >&2; exit 4 ;;
  slow) exec sleep 30 ;;
esac
`;
    await writeFile(join(bin, "gh"), script, { mode: 0o755 });
    const path = process.env.PATH;
    process.env.PATH = `${bin}:${path}`;
    cleanups.push(() => void (process.env.PATH = path));
    const calls = async () => (await readFile(join(dir, "calls"), "utf8").catch(() => "")).split("\n").filter(Boolean);

    // Off: a git subscriber without CI → status messages, zero gh processes.
    const topic = new GitTopic({
      io: realGitIo,
      selector: () => ({ root: null, known: false, active: false, start() {}, stop() {} }),
      resolve: async () => ({ root: repo }),
      watch: { debounceMs: 20, ciTimeoutMs: 500 },
    });
    const got: Array<Record<string, unknown>> = [];
    const sk: Sock = { readyState: 1, bufferedAmount: 0, send: (d) => void got.push(JSON.parse(String(d)) as Record<string, unknown>), close() {} };
    await writeFile(join(dir, "mode"), "pass");
    topic.set(sk, { project: repo, ci: false });
    await until(() => got.some((m) => m.type === "git" && m.branch === "main"), 10_000);
    await new Promise((r) => setTimeout(r, 300));
    expect(await calls()).toEqual([]);
    expect(got.at(-1)!.ci).toBeNull();
    topic.set(sk, null);
    expect(topic.active).toBe(false);

    const matrix: Array<[string, unknown]> = [
      ["pass", { state: "ok", at: "2026-11-21T10:00:00Z" }],
      ["fail", { state: "fail", at: "2026-11-21T10:00:00Z" }],
      ["running", { state: "running", at: "2026-11-21T10:00:00Z" }],
      ["none", { state: "none", at: null }],
      ["loggedout", null],
      ["slow", null],
    ];
    for (const [mode, want] of matrix) {
      await writeFile(join(dir, "mode"), mode);
      const n = (await calls()).length;
      const msgs: Array<Record<string, unknown>> = [];
      const w = new GitWatch(repo, realGitIo, (d) => msgs.push(JSON.parse(d) as Record<string, unknown>), { ciTimeoutMs: 500 });
      await w.start();
      const t0 = Date.now();
      w.setCi(true);
      await until(() => msgs.some((m) => JSON.stringify(m.ci) === JSON.stringify(want)), 10_000);
      // The failing ones: wait until gh was called and its answer (or the timeout) came back.
      if (want === null) {
        for (let i = 0; i < 200 && (await calls()).length === n; i++) await new Promise((r) => setTimeout(r, 10));
        await new Promise((r) => setTimeout(r, mode === "slow" ? 700 : 150));
      }
      expect(msgs.at(-1)!.ci).toEqual(want);
      expect((await calls()).slice(n)).toEqual(["run list --limit 1 --json status,conclusion,createdAt --branch main"]);
      if (mode === "slow") expect(Date.now() - t0).toBeLessThan(5_000);
      w.stop();
    }
  }, 30_000);
});

describe("project selection", () => {
  it("path containment: only paths inside the root, relative; the root as its basename", () => {
    expect(relativeTo("/w/proj", "/w/proj/src/a.ts")).toBe("src/a.ts");
    expect(relativeTo("/w/proj", "src/../src/a.ts")).toBe("src/a.ts");
    expect(relativeTo("/w/proj", "/w/proj")).toBe("");
    for (const bad of ["/w/proj2/a.ts", "/w/other", "../secret", "/etc/passwd", "src/../../x", "/w/proj/../proj2/a"]) expect(relativeTo("/w/proj", bad)).toBeNull();
    expect(rootLabel("/home/someone/Desktop/tiphys")).toBe("tiphys");
    expect(parseProject(undefined, undefined)).toEqual({ project: "auto", ci: false });
    expect(parseProject("/w/p", true)).toEqual({ project: "/w/p", ci: true });
    for (const bad of ["relative/p", 3, "/x\0y", "/" + "a".repeat(1100)]) expect(parseProject(bad, false)).toBeNull();
  });

  it("git root walk-up; newest session with a repo wins; else the focused terminal's shell", async () => {
    const root = await tree({ "repo/.git/HEAD": "ref: x\n", "repo/src/deep/f": "", "wt/.git": "gitdir: ../repo/.git/worktrees/wt\n", "plain/x": "" });
    expect(await gitRootOf(join(root, "repo/src/deep"))).toBe(join(root, "repo"));
    expect(await gitRootOf(join(root, "wt"))).toBe(join(root, "wt"));
    expect(await gitRootOf(join(root, "plain"))).toBeNull();
    const gr = (d: string) => gitRootOf(d);
    const r = await pickProject([{ cwd: join(root, "plain"), at: 300 }, { cwd: join(root, "repo/src"), at: 200 }, { cwd: join(root, "wt"), at: 100 }], null, gr);
    expect(r).toEqual({ root: join(root, "repo"), fromSession: true });
    expect(await pickProject([], join(root, "wt"), gr)).toEqual({ root: join(root, "wt"), fromSession: false });
    expect(await pickProject([{ cwd: join(root, "plain"), at: 1 }], null, gr)).toEqual({ root: null, fromSession: false });
  });

  it("fake Claude session files + fake /proc: terminal sessions, the focused terminal's newest shell", async () => {
    const root = await tree({
      "repo/.git/HEAD": "", "other/.git/HEAD": "",
      "proc/100/stat": stat(100, "claude", 1, { start: 555 }),
      "proc/200/stat": stat(200, "kitty", 1),
      "proc/201/stat": stat(201, "zsh", 200, { start: 10 }),
      "proc/202/stat": stat(202, "zsh", 200, { start: 20 }),
      "proc/203/stat": stat(203, "nvim", 202, { start: 30 }),
    });
    const cfg = join(root, "claude");
    await mkdir(join(cfg, "sessions"), { recursive: true });
    await writeFile(join(cfg, "sessions", "100.json"), JSON.stringify({ pid: 100, sessionId: "s-1", cwd: join(root, "repo"), procStart: "555", updatedAt: 2000, status: "busy" }));
    await writeFile(join(cfg, "sessions", "999.json"), JSON.stringify({ pid: 999, sessionId: "dead", cwd: join(root, "other"), updatedAt: 9000 })); // no process
    const proc = join(root, "proc");
    const fio: FileIo = { ...realFileIo, link: (p) => (p === `${proc}/202/cwd` ? join(root, "repo") : p === `${proc}/201/cwd` ? "/somewhere" : null) };
    expect(shellCwd(fio, 200, proc)).toBe(join(root, "repo"));
    expect(shellCwd(fio, 203, proc)).toBeNull();

    let focusFn: ((pid: number | null) => void) | null = null;
    let tiphys: Array<{ cwd: string; at: number }> = [];
    const watchers: Array<{ fn: () => void; closed: boolean }> = [];
    const io: SelectorIo = {
      sessions: async () => [...tiphys, ...(await terminalSessions(cfg, proc)).map((t) => ({ cwd: t.cwd!, at: Date.parse(t.updatedAt!) }))],
      sessionsDir: join(cfg, "sessions"),
      focus: (fn) => ((focusFn = fn), () => (focusFn = null)),
      shellCwd: (pid) => shellCwd(fio, pid, proc),
      gitRoot: (d) => gitRootOf(d),
      watch: (_d, fn) => {
        const w = { fn, closed: false };
        watchers.push(w);
        return { close: () => void (w.closed = true) };
      },
    };
    const picks: Array<string | null> = [];
    const sel = new ProjectSelector(io, (r) => picks.push(r), { debounceMs: 5, recheckMs: 60_000 });
    cleanups.push(() => sel.stop());
    sel.start();
    await until(() => picks.length === 1);
    expect(picks).toEqual([join(root, "repo")]); // the live terminal session; the dead one is ignored
    expect(focusFn).toBeNull(); // a session gives the project: no focus listener
    // A newer Tiphys session elsewhere wins on the next check (session dir event).
    tiphys = [{ cwd: join(root, "other"), at: Date.now() }];
    watchers[0]!.fn();
    await until(() => picks.length === 2);
    expect(picks[1]).toBe(join(root, "other"));
    // No sessions at all: the focused terminal's shell decides.
    tiphys = [];
    await writeFile(join(cfg, "sessions", "100.json"), "");
    watchers[0]!.fn();
    await until(() => focusFn !== null);
    focusFn!(200);
    await until(() => picks.length === 3);
    expect(picks[2]).toBe(join(root, "repo"));
    sel.stop();
    expect(sel.active).toBe(false);
    expect(focusFn).toBeNull();
    expect(watchers.every((w) => w.closed)).toBe(true);
  });
});

// ---------------------------------------------------------------- servers

describe("servers", () => {
  it("message from the uptime/incident state; sent on change only", async () => {
    expect(serversMessage({ monitors: null, connected: false, incidents: null })).toEqual({ type: "servers", available: false, hosts: [], incidents: 0 });
    const state = { monitors: [{ name: "charon", status: "up", since: null as string | null }, { name: "old", status: "paused", since: null }], connected: true, incidents: 0 as number | null };
    expect(serversMessage(state)).toEqual({ type: "servers", available: true, hosts: [{ name: "charon", up: true, since: null }], incidents: 0 });
    const p = new ServersProducer(() => state, { intervalMs: 10 });
    const got: Array<Record<string, unknown>> = [];
    p.start((m) => got.push(m));
    await new Promise((r) => setTimeout(r, 40));
    expect(got.length).toBe(1);
    state.monitors[0] = { name: "charon", status: "down", since: "2026-11-21T10:00:00Z" };
    state.incidents = 1;
    await until(() => got.length === 2);
    expect(got[1]).toMatchObject({ hosts: [{ name: "charon", up: false, since: "2026-11-21T10:00:00Z" }], incidents: 1 });
    await p.stop();
    expect(p.active).toBe(false);
  });
});

// ---------------------------------------------------------------- feed lifecycle

describe("feed: first subscriber starts, last stops", () => {
  it("shared producers per topic, latest state to a late subscriber, nothing left after the last one", async () => {
    const made: Record<string, Array<{ active: boolean; emit: ((m: Record<string, unknown>) => void) | null }>> = { system: [], jobs: [], servers: [] };
    const make = (t: "system" | "jobs" | "servers") => () => {
      const p = {
        active: false,
        emit: null as ((m: Record<string, unknown>) => void) | null,
        start(emit: (m: Record<string, unknown>) => void) {
          p.active = true;
          p.emit = emit;
          emit({ type: t, n: 1 });
        },
        async stop() {
          p.active = false;
          p.emit = null;
        },
      };
      made[t]!.push(p);
      return p;
    };
    const g = { closed: 0, opened: 0 };
    const io: SourceIo = { velour: async () => ({}), exec: async () => ({ stdout: "", stderr: "", code: 0 }), spawn: () => { throw new Error("no"); }, telemetry: async () => ({ running: false, buf: null }) };
    const feed = new FeedProducer(io, {
      producers: {
        make: { system: make("system"), jobs: make("jobs"), servers: make("servers") },
        git: {
          io: { run: async () => ({ stdout: "# branch.head main\n", code: 0 }), watch: () => (g.opened++, { close: () => void g.closed++ }), read: async () => null, list: async () => [], has: () => false },
          selector: (fn) => ({ root: "/w/p" as string | null, known: true, active: true, start: () => fn("/w/p"), stop() {} }),
          resolve: async () => ({ none: "notRepo" }),
          watch: { debounceMs: 5 },
        },
      },
    }, () => {});
    const a = sock();
    const b = sock();
    await feed.add(a, ["system", "jobs", "git"]);
    expect(feed.producing).toEqual(["system", "jobs", "git"]);
    await until(() => a.got.some((m) => m.type === "git"));
    await feed.add(b, ["system", "servers"]);
    expect(made.system!.length).toBe(1); // shared
    expect(b.got.map((m) => m.type)).toEqual(["system", "servers"]); // system's latest state replayed
    made.jobs![0]!.emit!({ type: "jobDone", id: "x" }); // an event: not replayed later
    await feed.setTopics(b, ["jobs"]);
    expect(b.got.filter((m) => m.type === "jobs").length).toBe(1);
    expect(b.got.some((m) => m.type === "jobDone")).toBe(false);
    expect(made.servers![0]!.active).toBe(false);
    await feed.remove(a);
    expect(made.system![0]!.active).toBe(false);
    expect(feed.producing).toEqual(["jobs"]);
    expect(g.closed).toBe(g.opened); // git watchers of a's project closed
    await feed.remove(b);
    expect(feed.producing).toEqual([]);
    expect(feed.running).toBe(false);
    expect(Object.values(made).flat().every((p) => !p.active)).toBe(true);
  });

  function sock(): Sock & { got: Array<Record<string, unknown>> } {
    const got: Array<Record<string, unknown>> = [];
    return { readyState: 1, bufferedAmount: 0, got, send: (d) => got.push(JSON.parse(String(d)) as Record<string, unknown>), close() {} };
  }
});
