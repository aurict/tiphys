// P3: the macOS and Windows implementations against the real OS (CI: macos-latest, windows-latest). Skipped
// elsewhere; the parsers are covered on every OS by platform_parsers.test.ts. Nothing here changes the machine
// (no power action, no real service is started or stopped; only a child process of the test is signalled).
import { spawn, type ChildProcess } from "node:child_process";
import { createServer, type Server } from "node:net";
import { afterEach, describe, expect, it } from "vitest";
import { unsupportedOn } from "../src/platform/support.ts";
import { testApp } from "./helpers.ts";

const T = 60_000;
const darwin = process.platform === "darwin";
const win32 = process.platform === "win32";

let child: ChildProcess | null = null;
let server: Server | null = null;
afterEach(() => {
  child?.kill("SIGKILL");
  child = null;
  server?.close();
  server = null;
});

function sleeper(): Promise<ChildProcess> {
  child = spawn(process.execPath, ["-e", "setInterval(() => {}, 1000)"], { stdio: "ignore" });
  return new Promise((res, rej) => {
    child!.once("spawn", () => res(child!));
    child!.once("error", rej);
  });
}

const exited = (c: ChildProcess) => new Promise<void>((res) => (c.exitCode !== null || c.signalCode !== null ? res() : c.once("exit", () => res())));

async function listen(): Promise<number> {
  server = createServer();
  await new Promise<void>((res) => server!.listen(0, "127.0.0.1", res));
  return (server!.address() as { port: number }).port;
}

const app = () => testApp((c) => ({ ...c, features: { ...c.features, system: true, services: true, ports: true, power: true } }));

describe.skipIf(!darwin && !win32)("native server features (macOS / Windows)", () => {
  it("health lists the unsupported parts", async () => {
    const { app: a } = await app();
    expect((await a.inject({ url: "/v1/health" })).json().unsupported).toEqual(unsupportedOn());
  });

  it("system snapshot", async () => {
    const { app: a, auth } = await app();
    const res = await a.inject({ url: "/v1/system", headers: auth });
    expect(res.statusCode).toBe(200);
    const s = res.json();
    expect(s.os).toMatch(darwin ? /^macOS / : /Windows/);
    expect(s.cpu.cores).toBeGreaterThan(0);
    expect(s.cpu.loadPercent).toBeGreaterThanOrEqual(0);
    expect(s.memory.totalBytes).toBeGreaterThan(0);
    expect(s.memory.usedBytes).toBeGreaterThan(0);
    expect(s.memory.usedBytes).toBeLessThanOrEqual(s.memory.totalBytes);
    expect(s.uptimeSeconds).toBeGreaterThan(0);
    expect(s.disks.length).toBeGreaterThan(0);
    for (const d of s.disks) expect(d.usedBytes).toBeLessThanOrEqual(d.totalBytes);
    if (win32) expect(s.disks.map((d: { mount: string }) => d.mount)).toContain("C:\\");
    else expect(s.disks.map((d: { mount: string }) => d.mount)).toContain("/");
  }, T);

  it("process list contains this process, sorted", async () => {
    const { app: a, auth } = await app();
    const res = await a.inject({ url: "/v1/processes?sort=mem&limit=500", headers: auth });
    expect(res.statusCode).toBe(200);
    const { total, processes } = res.json() as { total: number; processes: Array<{ pid: number; name: string; rssBytes: number }> };
    expect(total).toBeGreaterThan(5);
    const self = processes.find((p) => p.pid === process.pid);
    expect(self?.name.toLowerCase()).toMatch(/^node/);
    for (let i = 1; i < processes.length; i++) expect(processes[i - 1]!.rssBytes).toBeGreaterThanOrEqual(processes[i]!.rssBytes);
  }, T);

  it("signals a child process; refuses itself", async () => {
    const { app: a, auth } = await app();
    const c = await sleeper();
    const kill = await a.inject({ method: "POST", url: `/v1/processes/${c.pid}/signal`, headers: auth, payload: { signal: "KILL", confirm: true } });
    expect(kill.statusCode).toBe(200);
    await exited(c);
    const gone = await a.inject({ method: "POST", url: `/v1/processes/${c.pid}/signal`, headers: auth, payload: { signal: "KILL", confirm: true } });
    expect(gone.statusCode).toBe(404);
    const self = await a.inject({ method: "POST", url: `/v1/processes/${process.pid}/signal`, headers: auth, payload: { signal: "TERM", confirm: true } });
    expect(self.json().error.code).toBe("agent.processes.self");
  }, T);

  it.runIf(darwin)("macOS: TERM ends a child process", async () => {
    const { app: a, auth } = await app();
    const c = await sleeper();
    const res = await a.inject({ method: "POST", url: `/v1/processes/${c.pid}/signal`, headers: auth, payload: { signal: "TERM", confirm: true } });
    expect(res.statusCode).toBe(200);
    await exited(c);
  }, T);

  it.runIf(win32)("Windows: INT/HUP are unsupported; TERM on a windowless process either closes it or reports it", async () => {
    const { app: a, auth } = await app();
    const c = await sleeper();
    const int = await a.inject({ method: "POST", url: `/v1/processes/${c.pid}/signal`, headers: auth, payload: { signal: "INT", confirm: true } });
    expect(int.statusCode).toBe(501);
    expect(int.json().error).toEqual({ code: "agent.feature.unsupported", params: { feature: "processes.signal.INT", platform: "win32" } });
    const term = await a.inject({ method: "POST", url: `/v1/processes/${c.pid}/signal`, headers: auth, payload: { signal: "TERM", confirm: true } });
    if (term.statusCode !== 200) expect(term.json().error.code).toBe("agent.processes.signalFailed");
  }, T);

  it("listening ports include a local-only port of this process", async () => {
    const port = await listen();
    const { app: a, auth } = await app();
    const res = await a.inject({ url: "/v1/ports", headers: auth });
    expect(res.statusCode).toBe(200);
    const row = (res.json().ports as Array<{ port: number; pid: number | null; localOnly: boolean; process: string | null }>).find((p) => p.port === port);
    expect(row).toMatchObject({ localOnly: true, pid: process.pid });
    expect(row!.process?.toLowerCase()).toMatch(/^node/);
  }, T);

  it("services: list, unknown unit, logs", async () => {
    const { app: a, auth } = await app();
    const sys = await a.inject({ url: "/v1/services/system", headers: auth });
    expect(sys.statusCode).toBe(200);
    expect(sys.json().units.length).toBeGreaterThan(0);
    if (win32) expect(sys.json().units.map((u: { unit: string }) => u.unit.toLowerCase())).toContain("winmgmt");
    const user = await a.inject({ url: "/v1/services/user", headers: auth });
    if (win32) {
      expect(user.statusCode).toBe(501);
      expect(user.json().error.params).toEqual({ feature: "services.user", platform: "win32" });
      const logs = await a.inject({ url: "/v1/services/system/Winmgmt/logs", headers: auth });
      expect(logs.json().error.params.feature).toBe("services.logs");
    } else {
      expect(user.statusCode).toBe(200);
      expect(Array.isArray(user.json().units)).toBe(true);
      const logs = await a.inject({ url: "/v1/services/user/com.tiphys.no-such-job/logs", headers: auth });
      expect(logs.json().error.code).toBe("agent.services.notFound");
    }
    const bad = await a.inject({ method: "POST", url: "/v1/services/system/tiphys-no-such-service/start", headers: auth });
    expect([403, 502]).toContain(bad.statusCode);
    expect(["agent.services.actionFailed", "agent.services.permissionDenied"]).toContain(bad.json().error.code);
  }, T);

  it("power still needs confirmation (nothing is run)", async () => {
    const { app: a, auth } = await app();
    const res = await a.inject({ method: "POST", url: "/v1/power/suspend", headers: auth, payload: {} });
    expect(res.json().error.code).toBe("agent.power.confirmRequired");
  });
});
