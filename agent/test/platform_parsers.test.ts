// P3: macOS and Windows implementations, tested with recorded command outputs (test/fixtures/platform). Runs on every
// OS: nothing here starts a platform command.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import Fastify from "fastify";
import { describe, expect, it } from "vitest";
import { defaultConfig, defaultConfigPath } from "../src/config.ts";
import { detect, safeFeatures, suggestions, type DetectEnv } from "../src/detect.ts";
import { runDoctor, type DoctorDeps } from "../src/doctor.ts";
import { AppError } from "../src/errors.ts";
import * as common from "../src/platform/common.ts";
import * as darwin from "../src/platform/darwin.ts";
import { isSupported, unsupported, unsupportedOn, unsupportedRoutes } from "../src/platform/support.ts";
import * as win32 from "../src/platform/win32.ts";
import { powerCommand } from "../src/routes/power.ts";
import type { Exec } from "../src/tailscale.ts";
import { testApp } from "./helpers.ts";

// Git may check the fixtures out with CRLF on Windows; the commands print LF.
const fixture = (name: string) => readFileSync(new URL(`./fixtures/platform/${name}`, import.meta.url), "utf8").replace(/\r\n/g, "\n");

describe("macOS parsers", () => {
  it("sw_vers, vm_stat, swap usage", () => {
    expect(darwin.parseSwVers("ProductName:\t\tmacOS\nProductVersion:\t\t15.1\nBuildVersion:\t\t24B83\n")).toBe("macOS 15.1");
    // app (anonymous 398194 - purgeable 11036) + wired 151227 + compressor 344122 pages of 16 KiB
    expect(darwin.parseVmStat(fixture("darwin/vm_stat.txt"))).toBe((398194 - 11036 + 151227 + 344122) * 16384);
    expect(darwin.parseVmStat("garbage")).toBeNull();
    expect(darwin.parseSwapUsage("total = 2048.00M  used = 1059.25M  free = 988.75M  (encrypted)\n")).toEqual({
      totalBytes: 2048 * 1024 ** 2,
      usedBytes: Math.round(1059.25 * 1024 ** 2),
    });
    expect(darwin.parseSwapUsage("total = 0.00M  used = 0.00M  free = 0.00M  (encrypted)")).toEqual({ totalBytes: 0, usedBytes: 0 });
  });

  it("df + mount: real volumes only, mount points with spaces, file system types", () => {
    const disks = darwin.darwinDisks(fixture("darwin/df.txt"), fixture("darwin/mount.txt"));
    expect(disks.map((d) => d.mount)).toEqual(["/", "/System/Volumes/Data", "/Volumes/USB Stick"]);
    expect(disks[1]).toEqual({ mount: "/System/Volumes/Data", fs: "apfs", totalBytes: 482797652 * 1024, usedBytes: 213345588 * 1024 });
    expect(disks[2]!.fs).toBe("msdos");
    expect(darwin.parseDf(fixture("darwin/df.txt")).find((d) => d.filesystem === "map auto_home")).toBeDefined();
    // POSIX output (no inode columns) with 512-byte blocks is parsed too
    const posix = "Filesystem 512-blocks Used Available Capacity Mounted on\n/dev/disk3s5 965595304 426691176 496087096 47% /System/Volumes/Data\n";
    expect(darwin.parseDf(posix)).toEqual([{ filesystem: "/dev/disk3s5", mount: "/System/Volumes/Data", totalBytes: 965595304 * 512, usedBytes: 426691176 * 512 }]);
  });

  it("ps: elapsed time, names from paths with spaces, full command line", () => {
    expect(darwin.parseEtime("12-03:14:09")).toBe(12 * 86400 + 3 * 3600 + 14 * 60 + 9);
    expect(darwin.parseEtime("02:41:07")).toBe(2 * 3600 + 41 * 60 + 7);
    expect(darwin.parseEtime("05:12")).toBe(312);
    expect(darwin.parseEtime("?")).toBe(0);
    const ps = darwin.parsePsDarwin(fixture("darwin/ps.txt"), fixture("darwin/ps_comm.txt"));
    expect(ps).toHaveLength(5);
    expect(ps[2]).toEqual({
      pid: 733,
      ppid: 1,
      user: "alice",
      cpuPercent: 38.7,
      memPercent: 4.6,
      rssBytes: 772560 * 1024,
      elapsedSeconds: 2 * 3600 + 41 * 60 + 7,
      name: "Google Chrome",
      command: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
    });
    expect(ps[3]!.name).toBe("Google Chrome Helper (Renderer)");
    expect(ps[3]!.command).toContain("--type=renderer");
    expect(ps[4]).toMatchObject({ pid: 5120, name: "node", user: "alice", elapsedSeconds: 312 });
    expect(ps[1]!.user).toBe("_windowserver");
  });

  it("netstat + lsof: one row per port, public if any address is, processes from lsof", () => {
    const ports = darwin.mergeDarwinPorts(fixture("darwin/netstat.txt"), fixture("darwin/lsof.txt"));
    expect(ports.map((p) => p.port)).toEqual([631, 3000, 5000, 7443, 49152]);
    const by = Object.fromEntries(ports.map((p) => [p.port, p]));
    expect(by[7443]).toEqual({ port: 7443, address: "127.0.0.1", process: "node", pid: 5120, localOnly: true });
    expect(by[5000]).toMatchObject({ localOnly: false, process: "ControlCenter", pid: 412 });
    expect(by[631]).toMatchObject({ localOnly: true, process: null });
    expect(by[49152]).toMatchObject({ address: "fe80::1", localOnly: false });
    // without netstat output the lsof rows alone still list the user's ports
    expect(darwin.mergeDarwinPorts("", fixture("darwin/lsof.txt")).map((p) => p.port)).toEqual([3000, 5000, 7443]);
    expect(darwin.parseLsof("p1\ncx\nn[::1]:8080\n")).toEqual([{ port: 8080, address: "::1", process: "x", pid: 1 }]);
  });

  it("launchctl list / print system / job log paths", () => {
    const user = darwin.parseLaunchctlList(fixture("darwin/launchctl_list.txt"));
    const by = Object.fromEntries(user.map((u) => [u.unit, u]));
    expect(by["com.apple.Finder"]).toEqual({ unit: "com.apple.Finder", load: "loaded", active: "active", sub: "running", description: "" });
    expect(by["com.example.backup"]).toMatchObject({ active: "failed", sub: "failed" });
    expect(by["com.apple.SafariHistoryServiceAgent"]).toMatchObject({ active: "inactive", sub: "dead" });
    // killed by a signal (negative status) is not reported as failed
    expect(by["com.apple.mdworker.shared.0B000000-0000-0000-0000-000000000000"]!.active).toBe("inactive");
    const system = darwin.parseLaunchctlPrint(fixture("darwin/launchctl_print_system.txt"));
    expect(system.map((u) => u.unit)).toEqual(["com.apple.backupd-auto", "com.apple.metadata.mds", "com.apple.storekitagent", "org.example.failing"]);
    expect(system.find((u) => u.unit === "com.apple.metadata.mds")!.active).toBe("active");
    expect(system.find((u) => u.unit === "org.example.failing")!.active).toBe("failed");
    expect(darwin.parseLogPaths(fixture("darwin/launchctl_print_job.txt"))).toEqual(["/Users/alice/Library/Logs/tiphys-agent.log"]);
  });

  it("launchctl action arguments", () => {
    const uid = process.getuid?.() ?? 0;
    expect(darwin.launchctlArgs("user", "com.example.x", "start")).toEqual(["kickstart", `gui/${uid}/com.example.x`]);
    expect(darwin.launchctlArgs("user", "com.example.x", "restart")).toEqual(["kickstart", "-k", `gui/${uid}/com.example.x`]);
    expect(darwin.launchctlArgs("system", "com.example.x", "stop")).toEqual(["kill", "SIGTERM", "system/com.example.x"]);
  });
});

describe("Windows parsers", () => {
  it("PowerShell runs an encoded script without profile or prompts", () => {
    const args = win32.powershellArgs("Get-Service -Name 'x' | ConvertTo-Json");
    expect(args.slice(0, 3)).toEqual(["-NoProfile", "-NonInteractive", "-EncodedCommand"]);
    const script = Buffer.from(args[3]!, "base64").toString("utf16le");
    expect(script).toContain("Get-Service -Name 'x' | ConvertTo-Json");
    expect(script).toContain("[Console]::OutputEncoding=[Text.Encoding]::UTF8");
  });

  it("ConvertTo-Json: object, array, empty, BOM", () => {
    expect(win32.jsonList('{"a":1}')).toEqual([{ a: 1 }]);
    expect(win32.jsonList('[{"a":1},{"a":2}]')).toHaveLength(2);
    expect(win32.jsonList("  \r\n")).toEqual([]);
    expect(win32.jsonList('\uFEFF{"a":1}\r\n')).toEqual([{ a: 1 }]);
  });

  it("system: memory, page file, fixed disks", () => {
    const s = win32.parseWinSystem(fixture("win32/system.json"));
    expect(s.os).toBe("Microsoft Windows 11 Pro");
    expect(s.memory).toEqual({
      totalBytes: 33476572 * 1024,
      usedBytes: (33476572 - 18120440) * 1024,
      swapTotalBytes: 5242880 * 1024,
      swapUsedBytes: (5242880 - 4980736) * 1024,
    });
    expect(s.disks).toEqual([
      { mount: "C:\\", fs: "NTFS", totalBytes: 1022870155264, usedBytes: 1022870155264 - 512613908480 },
      { mount: "D:\\", fs: "NTFS", totalBytes: 2000381014016, usedBytes: 2000381014016 - 1500285760512 },
    ]);
  });

  it("processes: same shape as ps, idle process dropped, missing command line falls back to the name", () => {
    const ps = win32.parseWinProcesses(fixture("win32/processes.json"), 32 * 1024 ** 3);
    expect(ps.map((p) => p.pid)).toEqual([4, 7420, 10212, 11804]);
    expect(ps[1]).toEqual({
      pid: 7420,
      ppid: 6640,
      user: "",
      cpuPercent: 37,
      memPercent: Math.round((312475648 / (32 * 1024 ** 3)) * 1000) / 10,
      rssBytes: 312475648,
      elapsedSeconds: 9671,
      name: "chrome.exe",
      command: '"C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe" --type=renderer --lang=en-US',
    });
    expect(ps[3]).toMatchObject({ command: "Code.exe", cpuPercent: 0 });
  });

  it("ports: v4/v6 merged, loopback only when every address is", () => {
    const ports = win32.parseWinPorts(fixture("win32/ports.json"));
    expect(ports.map((p) => p.port)).toEqual([135, 139, 5357, 5432, 7443]);
    const by = Object.fromEntries(ports.map((p) => [p.port, p]));
    expect(by[7443]).toEqual({ port: 7443, address: "127.0.0.1", process: "node", pid: 10212, localOnly: true });
    expect(by[135]!.localOnly).toBe(false);
    expect(by[5357]!.address).toBe("fe80::1c2b:3d4e:5f60:7182");
    expect(win32.parseWinPorts("")).toEqual([]);
  });

  it("services: states as systemd-like fields; PowerShell 5.1 numeric enums", () => {
    const units = win32.parseWinServices(fixture("win32/services.json"));
    expect(units.map((u) => u.unit)).toEqual(["BITS", "RemoteRegistry", "Spooler", "Tailscale", "wuauserv"]);
    const by = Object.fromEntries(units.map((u) => [u.unit, u]));
    expect(by.Spooler).toEqual({ unit: "Spooler", load: "loaded", active: "active", sub: "running", description: "Print Spooler" });
    expect(by.RemoteRegistry).toMatchObject({ load: "disabled", active: "inactive", sub: "stopped" });
    expect(by.BITS).toMatchObject({ active: "activating", sub: "startpending" });
    expect(win32.parseWinServices(fixture("win32/services_ps51.json"))).toEqual([by.Spooler]);
  });

  it("service actions: quoted name, access denied by Win32 error code (not by the localized message)", () => {
    expect(win32.serviceActionScript("Spooler", "restart")).toContain("Restart-Service -Name 'Spooler' -ErrorAction Stop");
    expect(() => win32.serviceActionScript("x'; Remove-Item C:\\ -Recurse; '", "stop")).toThrow(AppError);
    expect(() => win32.parseServiceAction('{"ok":true}', "Spooler", "stop")).not.toThrow();
    const denied = (() => {
      try {
        win32.parseServiceAction('{"ok":false,"native":5,"message":"Der Dienst kann nicht geöffnet werden"}', "Spooler", "stop");
      } catch (e) {
        return e as AppError;
      }
    })();
    expect(denied).toMatchObject({ code: "agent.services.permissionDenied", status: 403 });
    expect(() => win32.parseServiceAction('{"ok":false,"native":1060,"message":"no such service"}', "Nope", "start")).toThrow(
      expect.objectContaining({ code: "agent.services.actionFailed", status: 502 }),
    );
  });

  it("taskkill arguments: TERM asks the window to close, KILL forces", () => {
    expect(win32.taskkillArgs(1234, "TERM")).toEqual(["/PID", "1234"]);
    expect(win32.taskkillArgs(1234, "KILL")).toEqual(["/PID", "1234", "/F"]);
  });
});

describe("shared helpers", () => {
  it("CPU load between two os.cpus() samples", () => {
    const t = (user: number, idle: number) => ({ model: "", speed: 0, times: { user, nice: 0, sys: 0, idle, irq: 0 } });
    const a = common.cpuTimes([t(100, 900), t(100, 900)], 0);
    const b = common.cpuTimes([t(150, 950), t(200, 900)], 1000);
    expect(common.loadBetween(a, b)).toBe(75);
    expect(common.loadBetween(b, b)).toBe(0);
  });

  it("finds a tool on PATH, else at a fallback path", () => {
    const sep = process.platform === "win32" ? ";" : ":";
    const ext = process.platform === "win32" ? ".exe" : "";
    const has = (want: string) => (p: string) => p === want;
    expect(common.findTool("docker", ["/opt/x/docker"], ["/a", "/b"].join(sep), has(join("/b", `docker${ext}`)))).toBe("docker");
    expect(common.findTool("docker", ["/opt/x/docker", "/opt/y/docker"], "/a", has("/opt/y/docker"))).toBe("/opt/y/docker");
    expect(common.findTool("docker", [], "/a", () => false)).toBe("docker");
    expect(common.dockerFallbacks("darwin", "/Users/a")).toContain("/Applications/Docker.app/Contents/Resources/bin/docker");
    expect(common.dockerFallbacks("win32", "C:\\Users\\a", { ProgramFiles: "C:\\Program Files" })[0]).toMatch(/Docker.+docker\.exe$/);
    expect(common.dockerFallbacks("linux")).toEqual([]);
  });

  it("power commands per OS (Linux unchanged)", () => {
    expect(powerCommand("reboot", "linux")).toEqual(["systemctl", ["--no-ask-password", "reboot"]]);
    expect(powerCommand("suspend", "linux")).toEqual(["systemctl", ["--no-ask-password", "suspend"]]);
    expect(powerCommand("suspend", "darwin")).toEqual(["pmset", ["sleepnow"]]);
    expect(powerCommand("reboot", "darwin")).toEqual(["osascript", ["-e", 'tell application "System Events" to restart']]);
    expect(powerCommand("poweroff", "darwin")).toEqual(["osascript", ["-e", 'tell application "System Events" to shut down']]);
    expect(powerCommand("reboot", "win32")).toEqual(["shutdown.exe", ["/r", "/t", "0"]]);
    expect(powerCommand("poweroff", "win32")).toEqual(["shutdown.exe", ["/s", "/t", "0"]]);
    expect(powerCommand("suspend", "win32")).toEqual(["rundll32.exe", ["powrprof.dll,SetSuspendState", "0,1,0"]]);
  });

  it("config path: ~/.config/tiphys on Linux/macOS, %APPDATA%\\Tiphys on Windows unless an old install exists", () => {
    const env = { APPDATA: "C:\\Users\\a\\AppData\\Roaming" };
    expect(defaultConfigPath("linux", env)).toMatch(/\.config[\\/]tiphys[\\/]agent\.json$/);
    expect(defaultConfigPath("darwin", env)).toMatch(/\.config[\\/]tiphys[\\/]agent\.json$/);
    expect(defaultConfigPath("win32", env, () => false)).toBe(join(env.APPDATA, "Tiphys", "agent.json"));
    expect(defaultConfigPath("win32", env, () => true)).toMatch(/\.config[\\/]tiphys[\\/]agent\.json$/);
    expect(defaultConfigPath("win32", { ...env, TIPHYS_AGENT_CONFIG: "/x/agent.json" })).toBe("/x/agent.json");
  });
});

describe("unsupported features and parts", () => {
  it("support table: nothing missing on Linux/macOS; Windows lacks Unix sockets, signals and per-user services", () => {
    expect(unsupportedOn("linux")).toEqual([]);
    expect(unsupportedOn("darwin")).toEqual([]);
    expect(unsupportedOn("win32")).toEqual(expect.arrayContaining(["services.user", "services.logs", "desktop.velour", "desktop.firefoxBridge"]));
    expect(isSupported("services", "win32")).toBe(true);
    expect(isSupported("services.user", "win32")).toBe(false);
    expect(unsupported("services.logs", "win32")).toMatchObject({ code: "agent.feature.unsupported", status: 501, params: { feature: "services.logs", platform: "win32" } });
  });

  it("unsupported routes answer 501 with feature and platform", async () => {
    const app = Fastify();
    app.setErrorHandler((err, _req, reply) => {
      const e = err as AppError;
      return reply.status(e.status).send({ error: { code: e.code, params: e.params } });
    });
    unsupportedRoutes(app, "/v1/velour", "desktop.velour", "win32");
    for (const [method, url] of [["POST", "/v1/velour"], ["GET", "/v1/velour/events"], ["POST", "/v1/velour/sleep"]] as const) {
      const res = await app.inject({ method, url });
      expect(res.statusCode).toBe(501);
      expect(res.json()).toEqual({ error: { code: "agent.feature.unsupported", params: { feature: "desktop.velour", platform: "win32" } } });
    }
  });

  it("GET /v1/health lists this OS's unsupported parts", async () => {
    const { app } = await testApp();
    const res = await app.inject({ url: "/v1/health" });
    expect(res.json().unsupported).toEqual(unsupportedOn());
  });
});

const fakeExec = (map: Record<string, { stdout?: string; code?: number }>): Exec => async (cmd, args) => {
  const key = [cmd.split(/[\\/]/).pop(), ...args].join(" ");
  const hit = Object.entries(map).find(([k]) => key.startsWith(k));
  return { stdout: hit?.[1].stdout ?? "", stderr: "", code: hit ? (hit[1].code ?? 0) : 127 };
};

describe("init --detect and doctor on macOS / Windows", () => {
  const env = (platform: NodeJS.Platform, over: Partial<DetectEnv> = {}): DetectEnv => ({
    env: {},
    exec: fakeExec({ "docker version": { stdout: "27.3.1\n" } }),
    which: (c) => ["docker", "git", "launchctl", "claude"].includes(c),
    exists: () => false,
    canUse: async () => false,
    managed: () => false,
    platform,
    ...over,
  });

  it("macOS: launchd services, Docker Desktop answering, no desktop turned on", async () => {
    const x = await detect(defaultConfig("x"), env("darwin"));
    expect(x).toMatchObject({ platform: "darwin", serviceManager: "launchd", docker: true, session: null, systemdUser: false });
    expect(safeFeatures(x)).toEqual(["system", "services", "docker", "git"]);
    expect(suggestions(x).map((s) => s.feature)).toEqual(expect.arrayContaining(["claude", "power", "databases"]));
  });

  it("Windows: service manager always there; Docker Desktop not running = docker off", async () => {
    const x = await detect(defaultConfig("x"), env("win32", { exec: fakeExec({ "docker version": { code: 1 } }), which: (c) => c === "docker" }));
    expect(x.serviceManager).toBe("windows");
    expect(safeFeatures(x)).toEqual(["system", "services"]);
  });

  const deps = (over: Partial<DoctorDeps> = {}): DoctorDeps => {
    const config = defaultConfig("x");
    return {
      config,
      configPath: "/Users/u/.config/tiphys/agent.json",
      exec: fakeExec({ "docker version": { code: 1 } }),
      which: (c) => c === "docker",
      exists: async () => true,
      canUse: async () => true,
      stat: async () => ({ mode: 0o100600, uid: 501 }),
      freeBytes: async () => ({ free: 50e9, total: 100e9 }),
      healthy: async () => true,
      update: async () => ({ current: "0.3.0", latest: "0.3.0", available: false, managed: false, notesUrl: null }),
      nodeVersion: "24.1.0",
      platform: "darwin",
      uid: 501,
      helpersDir: "/x",
      ...over,
    };
  };

  it("doctor: Docker Desktop down is reported, no socket path is checked", async () => {
    const r = await runDoctor(deps());
    const docker = r.checks.find((c) => c.id === "feature.docker");
    expect(docker).toMatchObject({ status: "fail", code: "doctor.feature.dockerUnreachable" });
    const up = await runDoctor(deps({ exec: fakeExec({ "docker version": { stdout: "27.3.1" } }) }));
    expect(up.checks.find((c) => c.id === "feature.docker")).toBeUndefined();
    const none = await runDoctor(deps({ which: () => false, exists: async (p) => !p.toLowerCase().includes("docker") }));
    expect(none.checks.find((c) => c.id === "feature.docker")).toMatchObject({ code: "doctor.feature.toolsMissing" });
  });
});
