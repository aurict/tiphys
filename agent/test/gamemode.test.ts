// Game mode (PLAN.md §19): config, feed scope, secrets, display token lifecycle, static path sanitising, art proxy,
// kiosk start/stop command construction (fake exec), crash cleanup, FFT/bands, ETS2 telemetry parser and events.
// No real Velour, PipeWire, Hyprland, Firefox or game is touched.
import { EventEmitter } from "node:events";
import { mkdir, mkdtemp, readdir, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { afterEach, describe, expect, it } from "vitest";
import { agentConfigSchema, defaultConfig } from "../src/config.ts";
import type { ExecResult } from "../src/exec.ts";
import { displayRoutes, kioskArgs, parseRange, safeSegments, workspaceTarget, type DisplayIo, type Upstream } from "../src/gamemode/display.ts";
import { LAYOUT_REVISION, OFF, parseLibraryFolders, parseTelemetry, READ_BYTES, TruckEvents, unzipSingle } from "../src/gamemode/ets2.ts";
import { lyricsMessage, musicMessage, nextTracks, sourceRoutes, type Child, type SourceIo } from "../src/gamemode/source.ts";
import { BANDS, bandBins, fft, FFT_N, parseSinkName, RATE, SpectrumAnalyzer } from "../src/gamemode/spectrum.ts";
import { createServiceToken } from "../src/service_tokens.ts";
import { testApp } from "./helpers.ts";

const cleanups: Array<() => unknown> = [];
afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
});

const until = async (f: () => boolean, ms = 3000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
};

// ---------------------------------------------------------------- config

describe("gamemode config", () => {
  it("defaults and validation", () => {
    const c = defaultConfig("x");
    expect(c.features.gamemode).toBe(false);
    expect(c.gamemode).toEqual({
      source: null,
      display: { scene: "auto", lyrics: true, spectrum: true, motion: "normal", brightness: null, clock24: true, dimIdleMinutes: 10 },
    });
    const base = { version: 1, name: "x", listen: {}, features: {} };
    expect(agentConfigSchema.safeParse({ ...base, gamemode: { display: { brightness: 4 } } }).success).toBe(false);
    expect(agentConfigSchema.safeParse({ ...base, gamemode: { display: { brightness: 101 } } }).success).toBe(false);
    expect(agentConfigSchema.safeParse({ ...base, gamemode: { display: { dimIdleMinutes: 121 } } }).success).toBe(false);
    expect(agentConfigSchema.safeParse({ ...base, gamemode: { display: { scene: "map" } } }).success).toBe(false);
    expect(agentConfigSchema.safeParse({ ...base, gamemode: { source: { url: "ftp://a", token: "tps_x" } } }).success).toBe(false);
    const ok = agentConfigSchema.parse({ ...base, gamemode: { source: { url: "https://argo.example.com:7443", token: "tps_x" }, display: { brightness: 40 } } });
    expect(ok.gamemode.display).toMatchObject({ brightness: 40, scene: "auto" });
  });
});

// ---------------------------------------------------------------- fakes

interface Call {
  cmd: string;
  args: string[];
  env?: NodeJS.ProcessEnv;
}

function fakeExec(o: { lua?: boolean; unitActive?: () => boolean; fail?: (c: Call) => ExecResult | null } = {}) {
  const calls: Call[] = [];
  const exec = async (cmd: string, args: string[], opts: { env?: NodeJS.ProcessEnv } = {}): Promise<ExecResult> => {
    const c = { cmd, args, env: opts.env };
    calls.push(c);
    const f = o.fail?.(c);
    if (f) return f;
    const ok = (stdout = "") => ({ stdout, stderr: "", code: 0 });
    if (cmd === "hyprctl") {
      if (args[0] === "eval" && args[1] === "return 1") return o.lua ? ok("ok") : ok("eval is only supported with the lua config manager");
      if (args[0] === "-j" && args[1] === "activeworkspace") {
        const onYol = calls.some((x) => x.args.includes("name:yol") || /name:yol/.test(x.args[1] ?? ""));
        return ok(onYol ? '{"id":-1337,"name":"yol"}' : '{"id":3,"name":"3"}');
      }
      return ok("ok");
    }
    if (cmd === "brightnessctl" && args[0] === "-m") return ok("intel_backlight,backlight,96000,100%,96000\n");
    if (cmd === "systemctl" && args[1] === "is-active") return { stdout: o.unitActive?.() === false ? "inactive\n" : "active\n", stderr: "", code: 0 };
    if (cmd === "wpctl") return ok('id 57\n  * media.class = "Audio/Sink"\n  * node.name = "alsa_output.test"\n');
    return ok("");
  };
  return { exec, calls };
}

class FakeUpstream implements Upstream {
  readyState = 0;
  binaryType = "blob";
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: unknown }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  closed = false;
  readonly url: string;
  readonly token: string;
  constructor(url: string, token: string) {
    this.url = url;
    this.token = token;
  }
  close() {
    this.closed = true;
    this.readyState = 3;
  }
}

async function displayApp(o: { lua?: boolean; fetch?: typeof fetch; fail?: (c: Call) => ExecResult | null; hypr?: boolean } = {}) {
  const runtime = await mkdtemp(join(tmpdir(), "tiphys-gm-run-"));
  const displayDir = await mkdtemp(join(tmpdir(), "tiphys-gm-display-"));
  const mapDir = await mkdtemp(join(tmpdir(), "tiphys-gm-map-"));
  let active = true;
  const x = fakeExec({ lua: o.lua, unitActive: () => active, fail: o.fail });
  const ups: FakeUpstream[] = [];
  const io: DisplayIo = {
    exec: x.exec,
    runtimeDir: runtime,
    hyprEnv: async () => {
      if (o.hypr === false) throw new Error("no hyprland");
      return { XDG_RUNTIME_DIR: runtime, HYPRLAND_INSTANCE_SIGNATURE: "sig" };
    },
    waylandEnv: async () => ({ WAYLAND_DISPLAY: "wayland-1", XDG_RUNTIME_DIR: runtime }),
    busEnv: () => ({ DBUS_SESSION_BUS_ADDRESS: `unix:path=${runtime}/bus` }),
    which: () => true,
    connect: (url, token) => {
      const u = new FakeUpstream(url, token);
      ups.push(u);
      return u;
    },
    fetch: o.fetch ?? (async () => new Response("x")),
  };
  const t = await testApp((c) => c, [async (a, ctx) => void (await displayRoutes(a, ctx, { io, displayDir, mapDir, backoff: [0.05], watchMs: 60_000 }))]);
  cleanups.push(() => t.app.close());
  const req = (method: "GET" | "PUT" | "POST", url: string, payload?: object) => t.app.inject({ method, url, headers: t.auth, ...(payload ? { payload } : {}) });
  const setSource = () => req("PUT", "/v1/gamemode", { source: { url: "https://argo.example.com:7443", token: "tps_secretsecret" } });
  return { ...t, runtime, displayDir, mapDir, calls: x.calls, ups, req, setSource, setActive: (v: boolean) => (active = v) };
}

/** The display token from the work dir's start page (the only place it is written). */
async function tokenOf(runtime: string): Promise<string> {
  const { readFile } = await import("node:fs/promises");
  const html = await readFile(join(runtime, "tiphys-gamemode", "start.html"), "utf8");
  return /#t=([a-f0-9]{64})/.exec(html)![1]!;
}

// ---------------------------------------------------------------- display side

describe("gamemode display", () => {
  it("source token is never returned; settings validate", async () => {
    const t = await displayApp();
    expect((await t.req("GET", "/v1/gamemode")).json()).toMatchObject({ running: false, startedAt: null, source: { configured: false, url: null, state: "off" }, map: { present: false }, live: { music: null, truck: null } });
    await writeFile(join(t.mapDir, "ets2.pmtiles"), "PMTiles");
    expect((await t.req("GET", "/v1/gamemode")).json()).toMatchObject({ map: { present: true } });
    const put = await t.setSource();
    expect(put.statusCode).toBe(200);
    expect(put.body).not.toContain("tps_secretsecret");
    expect(put.json().source).toEqual({ configured: true, url: "https://argo.example.com:7443", state: "off" });
    for (const url of ["/v1/gamemode", "/v1/config"]) expect((await t.req("GET", url)).body).not.toContain("tps_secretsecret");
    expect((await t.req("PUT", "/v1/gamemode", { settings: { brightness: 3 } })).statusCode).toBe(400);
    expect((await t.req("PUT", "/v1/gamemode", { settings: { nope: 1 } })).statusCode).toBe(400);
    expect((await t.req("PUT", "/v1/gamemode", { settings: { motion: "low" } })).json().settings.motion).toBe("low");
    // A gamemode service token can't use the phone's routes.
    const { token } = await createServiceToken(t.store, "laptop", ["gamemode"]);
    expect((await t.app.inject({ url: "/v1/gamemode", headers: { authorization: `Bearer ${token}` } })).statusCode).toBe(403);
  });

  it("start: 409 without a source, 503 without Hyprland", async () => {
    const t = await displayApp({ hypr: false });
    expect((await t.req("POST", "/v1/gamemode/start")).json().error.code).toBe("agent.gamemode.noSource");
    await t.setSource();
    const r = await t.req("POST", "/v1/gamemode/start");
    expect([r.statusCode, r.json().error.code]).toEqual([503, "agent.gamemode.noDisplay"]);
    expect(t.calls.some((c) => c.cmd === "systemd-run")).toBe(false);
  });

  it("start/stop: commands, display token lifecycle, relay, cleanup", async () => {
    const t = await displayApp();
    await t.setSource();
    await t.req("PUT", "/v1/gamemode", { settings: { brightness: 40 } });
    const s = await t.req("POST", "/v1/gamemode/start");
    expect(s.statusCode).toBe(200);
    expect(s.json()).toMatchObject({ running: true, source: { state: "connecting" } });
    const work = join(t.runtime, "tiphys-gamemode");
    expect((await stat(work)).mode & 0o777).toBe(0o700);
    expect((await readdir(work)).sort()).toEqual(["profile", "start.html", "state.json"]);
    const { readFile } = await import("node:fs/promises");
    expect(await readFile(join(work, "profile", "user.js"), "utf8")).toContain('user_pref("browser.sessionstore.resume_from_crash", false);');

    // Commands: rules (legacy keywords), workspace remembered + switched, backlight, one systemd-run unit.
    const hypr = t.calls.filter((c) => c.cmd === "hyprctl").map((c) => c.args.join(" "));
    expect(hypr).toContain("keyword windowrule[tiphys-gamemode]:match:class ^(tiphys-gamemode)$");
    expect(hypr).toContain("keyword windowrule[tiphys-gamemode]:workspace name:yol");
    expect(hypr).toContain("keyword windowrule[tiphys-gamemode]:fullscreen on");
    expect(hypr).toContain("keyword windowrule[tiphys-gamemode]:enable true");
    expect(hypr).toContain("dispatch workspace name:yol");
    expect(t.calls.filter((c) => c.cmd === "brightnessctl").map((c) => c.args.join(" "))).toEqual(["-m", "-q set 40%"]);
    const runs = t.calls.filter((c) => c.cmd === "systemd-run");
    expect(runs).toHaveLength(1);
    const args = runs[0]!.args;
    expect(args.slice(0, 7)).toEqual(["--user", "--unit=tiphys-gamemode", "--collect", "-p", "StandardOutput=null", "-p", "StandardError=null"]);
    expect(args).toContain("--setenv=MOZ_ENABLE_WAYLAND=1");
    expect(args).toContain("--setenv=WAYLAND_DISPLAY=wayland-1");
    expect(args).toContain("--setenv=HYPRLAND_INSTANCE_SIGNATURE=sig");
    const tail = args.slice(args.indexOf("--"));
    expect(tail).toEqual(["--", "systemd-inhibit", "--what=idle:sleep", "--why=Tiphys Oyun Modu", "firefox", "--kiosk", "--no-remote", "--name", "tiphys-gamemode", "--profile", join(work, "profile"), `file://${join(work, "start.html")}`]);
    // The display token is not on any command line.
    const token = await tokenOf(t.runtime);
    expect(JSON.stringify(t.calls)).not.toContain(token);

    // Upstream: feed URL + service token; relayed verbatim to the page.
    const up = t.ups[0]!;
    expect([up.url, up.token]).toEqual(["wss://argo.example.com:7443/v1/gamemode/feed", "tps_secretsecret"]);
    await expect(t.app.injectWS("/v1/gamemode/live?t=" + "0".repeat(64))).rejects.toThrow();
    const got: string[] = [];
    const ws = await t.app.injectWS(`/v1/gamemode/live?t=${token}`, {}, { onInit: (w) => w.on("message", (d: Buffer, binary: boolean) => got.push(binary ? `bin:${d.length}` : d.toString())) });
    await until(() => got.length >= 2);
    expect(JSON.parse(got[0]!)).toMatchObject({ type: "settings", brightness: 40 });
    expect(JSON.parse(got[1]!)).toEqual({ type: "source", state: "connecting" });
    up.onopen!();
    const music = JSON.stringify({ type: "music", playing: true, title: "Song", artist: "Band", album: null, artId: null, duration: 200, position: 3, at: 1, next: [] });
    up.onmessage!({ data: music });
    up.onmessage!({ data: JSON.stringify({ type: "evil" }) });
    up.onmessage!({ data: new Uint8Array([1, ...new Array(24).fill(9)]).buffer });
    await until(() => got.includes("bin:25"));
    expect(got).toContain(music);
    expect(got.some((m) => m.includes("evil"))).toBe(false);
    expect((await t.req("GET", "/v1/gamemode")).json()).toMatchObject({ source: { state: "ok" }, live: { music: { title: "Song", artist: "Band", playing: true } } });
    // Settings reach the page at once.
    const put = await t.req("PUT", "/v1/gamemode", { settings: { lyrics: false } });
    expect(put.json().settings).toMatchObject({ lyrics: false, brightness: 40 }); // a partial update keeps the rest
    await until(() => got.some((m) => m.includes('"lyrics":false')));

    // Page → stop (Esc held): everything is undone.
    const closed = new Promise((r) => ws.on("close", r));
    ws.send(JSON.stringify({ type: "stop" }));
    await closed;
    await until(() => t.calls.some((c) => c.cmd === "brightnessctl" && c.args.join(" ") === "-q set 96000"));
    expect((await t.req("GET", "/v1/gamemode")).json()).toMatchObject({ running: false, source: { state: "off" }, live: { music: null } });
    expect(await stat(work).catch(() => null)).toBeNull();
    const after = t.calls.map((c) => `${c.cmd} ${c.args.join(" ")}`);
    expect(after).toContain("systemctl --user stop tiphys-gamemode.service");
    expect(after).toContain("hyprctl keyword windowrule[tiphys-gamemode]:enable false");
    expect(after).toContain("hyprctl dispatch workspace 3");
    expect(up.closed).toBe(true);
    // The token is dead.
    await expect(t.app.injectWS(`/v1/gamemode/live?t=${token}`)).rejects.toThrow();
    // Idempotent.
    expect((await t.req("POST", "/v1/gamemode/stop")).json().running).toBe(false);
    const events = await (await import("node:fs/promises")).readFile(join(t.dir, "events.jsonl"), "utf8");
    expect(events.match(/gamemode\.(started|stopped)/g)).toEqual(["gamemode.started", "gamemode.stopped"]);
    expect(events).not.toContain("Song");
  });

  it("Lua mode rules; a failed launch rolls back", async () => {
    const t = await displayApp({ lua: true, fail: (c) => (c.cmd === "systemd-run" ? { stdout: "", stderr: "boom", code: 1 } : null) });
    await t.setSource();
    const r = await t.req("POST", "/v1/gamemode/start");
    expect([r.statusCode, r.json().error.code]).toEqual([502, "agent.gamemode.startFailed"]);
    const hypr = t.calls.filter((c) => c.cmd === "hyprctl").map((c) => c.args.join(" "));
    expect(hypr.some((h) => h.startsWith('eval hl.window_rule({ name = "tiphys-gamemode"') && h.includes("enabled = true"))).toBe(true);
    expect(hypr.some((h) => h.startsWith('eval hl.window_rule({ name = "tiphys-gamemode"') && h.includes("enabled = false"))).toBe(true);
    expect(await stat(join(t.runtime, "tiphys-gamemode")).catch(() => null)).toBeNull();
    expect((await t.req("GET", "/v1/gamemode")).json().running).toBe(false);
  });

  it("crash recovery: a state file left in the work dir is cleaned up on start", async () => {
    const runtime = await mkdtemp(join(tmpdir(), "tiphys-gm-run-"));
    const work = join(runtime, "tiphys-gamemode");
    await mkdir(join(work, "profile"), { recursive: true });
    await writeFile(join(work, "state.json"), JSON.stringify({ startedAt: "x", mode: "legacy", rules: true, workspace: "2", brightness: "50000; rm -rf ~" }));
    const x = fakeExec();
    const io: DisplayIo = {
      exec: x.exec, runtimeDir: runtime, hyprEnv: async () => ({ HYPRLAND_INSTANCE_SIGNATURE: "sig" }), waylandEnv: async () => ({}),
      busEnv: () => ({}), which: () => true, connect: () => new FakeUpstream("", ""), fetch,
    };
    const t = await testApp((c) => c, [async (a, ctx) => void (await displayRoutes(a, ctx, { io, displayDir: null, mapDir: runtime }))]);
    cleanups.push(() => t.app.close());
    await until(() => x.calls.some((c) => c.cmd === "hyprctl" && c.args.join(" ") === "keyword windowrule[tiphys-gamemode]:enable false"));
    await until(() => !!x.calls.find((c) => c.cmd === "hyprctl" && c.args[1] === "activeworkspace"));
    expect(x.calls.map((c) => `${c.cmd} ${c.args.join(" ")}`)).toContain("systemctl --user stop tiphys-gamemode.service");
    expect(await stat(work).catch(() => null)).toBeNull();
    // An invalid saved backlight value is never passed on.
    expect(x.calls.some((c) => c.cmd === "brightnessctl")).toBe(false);
  });

  it("static files: sanitised paths, no listing, symlinks can't escape; map with ranges", async () => {
    const t = await displayApp();
    await writeFile(join(t.displayDir, "index.html"), "<h1>hi</h1>");
    await writeFile(join(t.displayDir, "app.js"), "export {}");
    await writeFile(join(t.displayDir, ".env"), "SECRET=1");
    const outside = await mkdtemp(join(tmpdir(), "tiphys-gm-out-"));
    await writeFile(join(outside, "secret.js"), "secret");
    await symlink(join(outside, "secret.js"), join(t.displayDir, "link.js"));
    await mkdir(join(t.displayDir, "sub"));
    const get = (url: string, headers: Record<string, string> = {}) => t.app.inject({ url, headers });
    expect((await get("/gamemode/")).body).toBe("<h1>hi</h1>");
    expect((await get("/gamemode/")).headers["content-type"]).toContain("text/html");
    expect((await get("/gamemode")).statusCode).toBe(302);
    expect((await get("/gamemode/app.js")).headers["content-type"]).toContain("text/javascript");
    for (const bad of ["/gamemode/../agent.json", "/gamemode/%2e%2e/agent.json", "/gamemode/sub%2f..%2fapp.js", "/gamemode/.env", "/gamemode/link.js", "/gamemode/sub/", "/gamemode/sub", "/gamemode/app.js%00.js", "/gamemode/%E0%A4%A"]) {
      const r = await get(bad);
      // "/gamemode/../x" is normalised to "/x" before routing (401 there), a broken escape is 400; nothing is served.
      expect([bad, r.statusCode >= 400]).toEqual([bad, true]);
      expect(r.body).not.toContain("secret");
    }
    expect(safeSegments("a/../b.js")).toBeNull();
    expect(safeSegments("a/b.js")).toEqual(["a", "b.js"]);
    expect(safeSegments("x.sh")).toBeNull();

    await writeFile(join(t.mapDir, "europe.pmtiles"), Buffer.from("0123456789"));
    const whole = await get("/gamemode/map/europe.pmtiles");
    expect([whole.statusCode, whole.body, whole.headers["accept-ranges"]]).toEqual([200, "0123456789", "bytes"]);
    const part = await get("/gamemode/map/europe.pmtiles", { range: "bytes=2-5" });
    expect([part.statusCode, part.body, part.headers["content-range"]]).toEqual([206, "2345", "bytes 2-5/10"]);
    expect((await get("/gamemode/map/europe.pmtiles", { range: "bytes=-3" })).body).toBe("789");
    expect((await get("/gamemode/map/europe.pmtiles", { range: "bytes=20-" })).statusCode).toBe(416);
    expect((await get("/gamemode/map/../agent.json")).statusCode).toBe(404);
    expect(parseRange("bytes=5-2", 10)).toBe("bad");
    expect(parseRange(undefined, 10)).toBeNull();
  });

  it("art proxy: current cover only, https, image bytes, size cap", async () => {
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(100)]);
    let body: Buffer = png;
    let fetches = 0;
    const t = await displayApp({
      fetch: (async (url: string) => {
        fetches++;
        const r = new Response(new Uint8Array(body));
        Object.defineProperty(r, "url", { value: url });
        return r;
      }) as unknown as typeof fetch,
    });
    await t.setSource();
    await t.req("POST", "/v1/gamemode/start");
    const token = await tokenOf(t.runtime);
    const up = t.ups[0]!;
    up.onopen!();
    const { artId } = await import("../src/routes/media.ts");
    const url = "https://img.example.com/cover.png";
    const id = artId(url);
    const art = (i = id, tk = token) => t.app.inject({ url: `/v1/gamemode/art?t=${tk}&id=${i}` });
    expect((await art()).statusCode).toBe(404); // no music yet
    up.onmessage!({ data: JSON.stringify({ type: "music", playing: true, title: "a", artist: "b", artId: id, artUrl: url, next: [] }) });
    expect((await art(id, "0".repeat(64))).statusCode).toBe(404);
    expect((await art("aaaaaaaaaaaa")).statusCode).toBe(404);
    const ok = await art();
    expect([ok.statusCode, ok.headers["content-type"]]).toEqual([200, "image/png"]);
    await art();
    expect(fetches).toBe(1); // cached
    const http = "http://img.example.com/x.png";
    up.onmessage!({ data: JSON.stringify({ type: "music", artId: artId(http), artUrl: http }) });
    expect((await art(artId(http))).statusCode).toBe(404);
    for (const [name, b] of [["text", Buffer.from("<html>")], ["big", Buffer.concat([png, Buffer.alloc(5 * 1024 * 1024)])]] as const) {
      const u = `https://img.example.com/${name}.png`;
      body = b;
      up.onmessage!({ data: JSON.stringify({ type: "music", artId: artId(u), artUrl: u }) });
      expect([name, (await art(artId(u))).statusCode]).toEqual([name, 404]);
    }
    await t.req("POST", "/v1/gamemode/stop");
    expect((await art()).statusCode).toBe(404);
  });

  it("helpers", () => {
    expect(workspaceTarget('{"id":4,"name":"4"}')).toBe("4");
    expect(workspaceTarget('{"id":-5,"name":"music"}')).toBe("name:music");
    expect(workspaceTarget('{"id":-98,"name":"special:magic"}')).toBeNull();
    expect(workspaceTarget('{"id":-5,"name":"a b"}')).toBeNull();
    const a = kioskArgs({ firefox: "firefox-esr", profile: "/p", url: "file:///s.html", env: { WAYLAND_DISPLAY: "wayland-0", OTHER: "x" } });
    expect(a).toContain("--setenv=WAYLAND_DISPLAY=wayland-0");
    expect(a.join(" ")).not.toContain("OTHER");
  });
});

// ---------------------------------------------------------------- source side

class FakeChild extends EventEmitter implements Child {
  stdout = new PassThrough();
  exitCode: number | null = null;
  signalCode: NodeJS.Signals | null = null;
  killed: string[] = [];
  kill(sig: NodeJS.Signals = "SIGTERM") {
    this.killed.push(sig);
    this.signalCode = sig;
    setImmediate(() => this.emit("exit"));
    return true;
  }
}

function velourFake() {
  let playing = true;
  let rev = 1;
  const ops: string[] = [];
  const state = () => ({
    rev, queueRev: 1, playing, position: 12.5, duration: 200,
    track: { videoId: "v1", title: "Song", artists: [{ name: "Band" }], album: { name: "Album" }, thumbnail: "https://img.example.com/c.jpg" },
  });
  const waiters: Array<() => void> = [];
  const velour = async (op: { op: string }, signal?: AbortSignal) => {
    ops.push(op.op);
    if (op.op === "state") return state();
    if (op.op === "queue") return { index: 0, tracks: [{ title: "Song" }, { title: "Next", artists: [{ name: "B2" }] }, { title: "After" }, { title: "Later" }] };
    if (op.op === "lyrics") return { kind: "synced", videoId: "v1", lines: [{ time: 1.5, text: "la" }], text: "la", source: "x" };
    // wait: until changed or aborted
    await new Promise<void>((r) => {
      waiters.push(r);
      signal?.addEventListener("abort", () => r(), { once: true });
    });
    return state();
  };
  return {
    velour, ops,
    pause: () => {
      playing = false;
      rev++;
      for (const w of waiters.splice(0)) w();
    },
  };
}

describe("gamemode source", () => {
  it("messages from Velour shapes", () => {
    const m = musicMessage({ playing: true, position: 1, duration: 2, track: { videoId: "v", title: "T", artists: [{ name: "A" }, { name: "B" }], album: { name: "Al" }, thumbnail: "http://x" } }, [], 5);
    expect(m).toEqual({ type: "music", playing: true, title: "T", artist: "A, B", album: "Al", artId: null, artUrl: null, duration: 2, position: 1, at: 5, next: [] });
    expect(musicMessage({ track: null }, [])).toEqual({ type: "music", none: true });
    expect(lyricsMessage({ kind: "synced", lines: [{ time: 2, text: "x" }] }, { artId: "a", title: "T" })).toEqual({ type: "lyrics", artId: "a", title: "T", kind: "synced", lines: [{ t: 2, text: "x" }] });
    expect(lyricsMessage({ kind: "plain", text: "a\nb" }, {}).lines).toEqual([{ t: 0, text: "a" }, { t: 0, text: "b" }]);
    expect(lyricsMessage({ kind: "none" }, {}).kind).toBe("none");
    expect(nextTracks({ index: 1, tracks: [{ title: "a" }, { title: "b" }, { title: "c", artists: [{ name: "x" }] }] })).toEqual([{ title: "c", artist: "x" }]);
    expect(parseSinkName('  * media.class = "Audio/Sink"\n  * node.name = "alsa_output.x"')).toBe("alsa_output.x");
    expect(parseSinkName('  * media.class = "Audio/Source"\n  * node.name = "mic"')).toBeNull();
  });

  it("feed: scope enforced, one shared producer, spectrum only while playing, children killed when the last leaves", async () => {
    const v = velourFake();
    const children: FakeChild[] = [];
    const io: SourceIo = {
      velour: v.velour as SourceIo["velour"],
      exec: fakeExec().exec,
      spawn: (cmd, args) => {
        expect(cmd).toBe("pw-record");
        expect(args).toContain("alsa_output.test");
        expect(args.join(" ")).toContain("stream.capture.sink=true");
        const c = new FakeChild();
        children.push(c);
        return c;
      },
      telemetry: async () => ({ running: false, buf: null }),
    };
    let feed!: ReturnType<typeof sourceRoutes>;
    const t = await testApp((c) => c, [(a, ctx) => void (feed = sourceRoutes(a, ctx, { io, frameMs: 10, idleMs: 30 }))]);
    cleanups.push(() => t.app.close());
    const { token: research } = await createServiceToken(t.store, "x", ["research"]);
    const { token: gm } = await createServiceToken(t.store, "laptop", ["gamemode"]);
    await t.app.ready(); // injectWS doesn't wait for it
    await expect(t.app.injectWS("/v1/gamemode/feed", { headers: { authorization: `Bearer ${research}` } })).rejects.toThrow(/403/);
    await expect(t.app.injectWS("/v1/gamemode/feed")).rejects.toThrow(/401/);
    // The gamemode token opens only the feed.
    expect((await t.app.inject({ url: "/v1/gamemode/source", headers: { authorization: `Bearer ${gm}` } })).statusCode).toBe(403);
    expect((await t.app.inject({ method: "POST", url: "/v1/gamemode/plugin", headers: { authorization: `Bearer ${gm}` }, payload: { action: "install" } })).statusCode).toBe(403);

    const got: Array<string | number> = [];
    const a = await t.app.injectWS("/v1/gamemode/feed", { headers: { authorization: `Bearer ${gm}` } }, { onInit: (w) => w.on("message", (d: Buffer, bin: boolean) => got.push(bin ? d.length : d.toString())) });
    await until(() => got.some((m) => typeof m === "string" && m.includes('"type":"lyrics"')) && got.includes(25));
    const music = JSON.parse(got.find((m) => typeof m === "string" && m.includes('"type":"music"')) as string);
    expect(music).toMatchObject({ playing: true, title: "Song", artist: "Band", album: "Album", next: [{ title: "Next", artist: "B2" }, { title: "After", artist: "" }] });
    expect(got.some((m) => typeof m === "string" && m.includes('"state":"none"'))).toBe(true);
    // A second subscriber shares the producer (no second capture) and gets the latest state at once.
    const gotB: string[] = [];
    const b = await t.app.injectWS("/v1/gamemode/feed", { headers: { authorization: `Bearer ${t.token}` } }, { onInit: (w) => w.on("message", (d: Buffer, bin: boolean) => void (!bin && gotB.push(d.toString()))) });
    await until(() => gotB.some((m) => m.includes('"type":"lyrics"')));
    expect(children).toHaveLength(1);
    expect(feed.subscribers).toBe(2);
    // Pause → capture stops.
    v.pause();
    await until(() => children[0]!.killed.length > 0);
    expect(v.ops.filter((o) => o === "lyrics")).toHaveLength(1);
    a.terminate();
    b.terminate();
    await until(() => !feed.running);
    expect(feed.subscribers).toBe(0);
  });

  it("feed: the capture child dies when the last subscriber leaves while playing", async () => {
    const v = velourFake();
    const children: FakeChild[] = [];
    const io: SourceIo = {
      velour: v.velour as SourceIo["velour"], exec: fakeExec().exec,
      spawn: () => (children.push(new FakeChild()), children.at(-1)!),
      telemetry: async () => ({ running: false, buf: null }),
    };
    let feed!: ReturnType<typeof sourceRoutes>;
    const t = await testApp((c) => c, [(a, ctx) => void (feed = sourceRoutes(a, ctx, { io }))]);
    cleanups.push(() => t.app.close());
    await t.app.ready();
    const a = await t.app.injectWS("/v1/gamemode/feed", { headers: t.auth });
    await until(() => children.length === 1);
    a.terminate();
    await until(() => !feed.running);
    expect(children[0]!.killed).toEqual(["SIGTERM"]);
  });
});

// ---------------------------------------------------------------- spectrum

describe("spectrum", () => {
  it("fft of an impulse is flat; of a cosine peaks at its bin", () => {
    const re = new Float64Array(8);
    const im = new Float64Array(8);
    re[0] = 1;
    fft(re, im);
    expect([...re]).toEqual(new Array(8).fill(1));
    const n = 64;
    const r2 = Float64Array.from({ length: n }, (_, i) => Math.cos((2 * Math.PI * 5 * i) / n));
    const i2 = new Float64Array(n);
    fft(r2, i2);
    const mag = [...r2].map((x, i) => Math.hypot(x, i2[i]!));
    expect(mag[5]).toBeCloseTo(32, 6);
    expect(mag[59]).toBeCloseTo(32, 6);
    expect(Math.max(...mag.filter((_, i) => i !== 5 && i !== 59))).toBeLessThan(1e-9);
  });

  it("24 increasing bands, a 1 kHz tone lights its band, silence is zero", () => {
    const bins = bandBins();
    expect(bins).toHaveLength(BANDS);
    for (let i = 0; i < BANDS; i++) {
      expect(bins[i]![1]).toBeGreaterThan(bins[i]![0]);
      if (i) expect(bins[i]![0]).toBe(bins[i - 1]![1]);
    }
    expect(bins.at(-1)![1]).toBeLessThanOrEqual(FFT_N / 2);
    const a = new SpectrumAnalyzer();
    const tone = Int16Array.from({ length: 4096 }, (_, i) => Math.round(16000 * Math.sin((2 * Math.PI * 1000 * i) / RATE)));
    const bytes = Buffer.from(tone.buffer);
    // Split mid-sample on purpose.
    a.pushBytes(bytes.subarray(0, 1001));
    a.pushBytes(bytes.subarray(1001));
    let f = a.frame();
    for (let k = 0; k < 10; k++) f = a.frame();
    expect(f.length).toBe(25);
    expect(f[0]).toBe(1);
    const bandsOut = [...f.subarray(1)];
    const peak = bandsOut.indexOf(Math.max(...bandsOut));
    const binOf1k = Math.round(1000 / (RATE / FFT_N));
    expect(bins[peak]![0]).toBeLessThanOrEqual(binOf1k);
    expect(bins[peak]![1]).toBeGreaterThan(binOf1k);
    expect(bandsOut[peak]).toBeGreaterThan(200);
    expect(bandsOut[0]).toBeLessThan(60);
    const s = new SpectrumAnalyzer();
    s.push(new Int16Array(2048));
    expect([...s.frame().subarray(1)]).toEqual(new Array(24).fill(0));
  });
});

// ---------------------------------------------------------------- ETS2

/** A revision-12 shared-memory image written at the parser's offsets. */
function telemetryBuf(p: Partial<Record<string, number | boolean | string>> = {}) {
  const b = Buffer.alloc(READ_BYTES);
  const d = new DataView(b.buffer, b.byteOffset, b.byteLength);
  const v = { sdkActive: true, paused: false, revision: LAYOUT_REVISION, game: 1, timeAbs: 4000, speed: 22.2, fuel: 400, fuelCapacity: 800, restStop: 300, onJob: true, ...p };
  const f32 = (o: number, x: number) => d.setFloat32(o, x, true);
  d.setUint8(OFF.sdkActive, v.sdkActive ? 1 : 0);
  d.setUint8(OFF.paused, v.paused ? 1 : 0);
  d.setUint32(OFF.revision, v.revision as number, true);
  d.setUint32(OFF.game, v.game as number, true);
  d.setUint32(OFF.timeAbs, v.timeAbs as number, true);
  d.setUint32(OFF.gears, 12, true);
  d.setUint32(OFF.timeAbsDelivery, 5000, true);
  d.setInt32(OFF.restStop, v.restStop as number, true);
  d.setInt32(OFF.gearDashboard, -1, true);
  if (p.scale !== undefined) f32(OFF.scale, p.scale as number);
  f32(OFF.fuelCapacity, v.fuelCapacity as number);
  f32(OFF.engineRpmMax, 2500);
  f32(OFF.speed, v.speed as number);
  f32(OFF.engineRpm, 1200.4);
  f32(OFF.cruiseSpeed, 0);
  f32(OFF.fuel, v.fuel as number);
  f32(OFF.fuelRange, 950);
  f32(OFF.wearCabin, 0.05);
  f32(OFF.wearChassis, 0.12);
  f32(OFF.routeDistance, 123456);
  f32(OFF.routeTime, 5400);
  f32(OFF.speedLimit, 25);
  f32(OFF.jobCargoDamage, 0.02);
  d.setUint8(OFF.parkBrake, 1);
  d.setUint8(OFF.lowBeam, 1);
  d.setUint8(OFF.blinkerRight, 1);
  d.setFloat64(OFF.x, -12345.678, true);
  d.setFloat64(OFF.z, 4567.891, true);
  d.setFloat64(OFF.heading, 0.25, true);
  b.write("Bursa", OFF.citySrc);
  b.write("München", OFF.cityDst);
  b.write("Elektronik", OFF.cargo);
  b.write("speeding", OFF.fineOffence);
  b.write("Calais", OFF.ferryTarget);
  d.setBigUint64(OFF.jobIncome, 12500n, true);
  d.setBigInt64(OFF.fineAmount, BigInt(p.fineAmount ?? 0), true);
  d.setBigInt64(OFF.ferryAmount, 300n, true);
  d.setBigInt64(OFF.deliveredRevenue, 9876n, true);
  d.setUint8(OFF.onJob, v.onJob ? 1 : 0);
  for (const k of ["fined", "ferry", "jobDelivered", "tollgate", "train", "jobCancelled"] as const) d.setUint8(OFF[k], p[k] ? 1 : 0);
  return b;
}

describe("ETS2 telemetry", () => {
  it("parses the contract's truck message", () => {
    const s = parseTelemetry(telemetryBuf(), true, 7);
    expect(s.telemetry).toBe("ok");
    expect(s.msg).toEqual({
      type: "truck", state: "driving", at: 7,
      speed: 22.2, speedLimit: 25, rpm: 1200, rpmMax: 2500, gear: -1, gears: 12,
      fuel: 400, fuelCap: 800, fuelRange: 950, cruise: 0, parkingBrake: true, lowBeam: true, highBeam: false, beacon: false,
      blinkerL: false, blinkerR: true, wear: 0.12, cargoDamage: 0.02,
      x: -12345.68, z: 4567.89, heading: 0.25, gameTime: 4000, restMinutes: 300,
      job: { from: "Bursa", to: "München", cargo: "Elektronik", income: 12500, currency: "EUR", deadlineGameTime: 5000 },
      nav: { distance: 123456, time: 5400 },
    });
  });

  it("states and revision check", () => {
    expect(parseTelemetry(null, false, 1)).toEqual({ telemetry: "none", msg: { type: "truck", state: "none", reason: "noGame", at: 1 } });
    expect(parseTelemetry(null, true, 1).msg).toEqual({ type: "truck", state: "none", reason: "noPlugin", at: 1 });
    expect(parseTelemetry(telemetryBuf({ sdkActive: false }), true).msg.state).toBe("menu");
    expect(parseTelemetry(telemetryBuf({ paused: true }), true).msg.state).toBe("paused");
    expect(parseTelemetry(telemetryBuf({ paused: true, timeAbs: 0 }), true).msg.state).toBe("menu");
    const old = parseTelemetry(telemetryBuf({ revision: 11 }), true, 1);
    expect(old).toEqual({ telemetry: "unsupported", msg: { type: "truck", state: "none", reason: "unsupported", at: 1 } });
    expect(parseTelemetry(telemetryBuf({ game: 2 }), true).msg.job).toMatchObject({ currency: "USD" });
    expect(parseTelemetry(telemetryBuf({ onJob: false }), true).msg).toMatchObject({ job: null, cargoDamage: null });
    expect(parseTelemetry(Buffer.alloc(100), true).telemetry).toBe("none");
  });

  it("sends the game's time scale only when the layout has one", () => {
    expect(parseTelemetry(telemetryBuf({ scale: 19 }), true).msg.timeScale).toBe(19);
    expect(parseTelemetry(telemetryBuf({ scale: 3 }), true).msg.timeScale).toBe(3);
    expect(parseTelemetry(telemetryBuf(), true).msg).not.toHaveProperty("timeScale");
  });

  it("derives events once per flag flip and threshold crossing", () => {
    const e = new TruckEvents();
    const at = (p: Parameters<typeof telemetryBuf>[0]) => e.update(parseTelemetry(telemetryBuf(p), true));
    expect(at({})).toEqual([]); // baseline
    expect(at({})).toEqual([]);
    expect(at({ fined: true, fineAmount: 250 })).toEqual([{ type: "event", kind: "fine", amount: 250, currency: "EUR", detail: "speeding" }]);
    expect(at({ fined: true, fineAmount: 250 })).toEqual([]); // same flag value: no repeat
    expect(at({ fined: true, ferry: true })).toEqual([{ type: "event", kind: "ferry", amount: 300, currency: "EUR", detail: "Calais" }]);
    expect(at({ fined: true, ferry: true, jobDelivered: true })).toEqual([{ type: "event", kind: "delivered", amount: 9876, currency: "EUR" }]);
    // The plugin XORs the flags: flipping back is the next event.
    expect(at({ ferry: true, jobDelivered: true }).map((x) => x.kind)).toEqual(["fine"]);
    const base = { ferry: true, jobDelivered: true };
    expect(at({ ...base, fuel: 100 })).toEqual([{ type: "event", kind: "fuelLow" }]);
    expect(at({ ...base, fuel: 90 })).toEqual([]);
    expect(at({ ...base, fuel: 125 })).toEqual([]); // 0.156: not re-armed yet (hysteresis)
    expect(at({ ...base, fuel: 110 })).toEqual([]);
    expect(at({ ...base, fuel: 800 })).toEqual([]);
    expect(at({ ...base, fuel: 100 })).toEqual([{ type: "event", kind: "fuelLow" }]);
    expect(at({ ...base, restStop: 59 })).toEqual([{ type: "event", kind: "rest" }]);
    expect(at({ ...base, restStop: 30 })).toEqual([]);
    // Game gone → baseline again (no burst of events on reconnect).
    expect(e.update(parseTelemetry(null, false))).toEqual([]);
    expect(at({ fined: true, train: true })).toEqual([]);
  });

  it("libraryfolders.vdf paths and the zip reader", async () => {
    const vdf = '"libraryfolders"\n{\n\t"0"\n\t{\n\t\t"path"\t\t"/home/u/.local/share/Steam"\n\t}\n\t"1"\n\t{\n\t\t"path"\t\t"/mnt/games\\\\x"\n\t}\n}';
    expect(parseLibraryFolders(vdf)).toEqual(["/home/u/.local/share/Steam", "/mnt/games\\x"]);
    const { deflateRawSync } = await import("node:zlib");
    const data = Buffer.from("hello plugin");
    const comp = deflateRawSync(data);
    const name = Buffer.from("libscs-telemetry.so");
    const h = Buffer.alloc(30);
    h.writeUInt32LE(0x04034b50, 0);
    h.writeUInt16LE(8, 8);
    h.writeUInt32LE(comp.length, 18);
    h.writeUInt32LE(data.length, 22);
    h.writeUInt16LE(name.length, 26);
    expect(unzipSingle(Buffer.concat([h, name, comp]), "libscs-telemetry.so").toString()).toBe("hello plugin");
    expect(() => unzipSingle(Buffer.concat([h, name, comp]), "other.so")).toThrow();
  });
});

describe("request log", () => {
  it("keeps the display token (?t=) out of the log", async () => {
    const { ConfigStore } = await import("../src/config.ts");
    const { Notifier } = await import("../src/notify.ts");
    const { buildApp } = await import("../src/server.ts");
    const dir = await mkdtemp(join(tmpdir(), "tiphys-agent-"));
    const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "test");
    const logs: string[] = [];
    const app = await buildApp({ store, notifier: new Notifier(() => store.get(), () => {}) }, { logger: true, logStream: { write: (l: string) => void logs.push(l) } });
    await app.inject({ method: "GET", url: "/v1/gamemode/art?t=SECRET123&id=x" });
    await app.close();
    expect(logs.join("")).toContain("/v1/gamemode/art?t=[redacted]&id=x");
    expect(logs.join("")).not.toContain("SECRET123");
  });
});

describe("display map projection (display/projection.js)", () => {
  // Plain browser module; a computed specifier keeps tsc from asking for types.
  const load = () => import(String(new URL("../../display/projection.js", import.meta.url)));

  it("inverts the LCC and places cities where the map tiles have them", async () => {
    const p = await load();
    for (const [lon, lat] of [[15, 50], [-3, 56], [28, 60]] as const) {
      const [X, Y] = p.lccForward(lon, lat);
      const [lo, la] = p.lccInverse(X, Y);
      expect(lo).toBeCloseTo(lon, 9);
      expect(la).toBeCloseTo(lat, 9);
    }
    // City label points of ets2.pmtiles (generated with the same constants), from game coordinates of the city areas.
    const near = (a: number[], b: number[]) => expect(Math.hypot(a[0]! - b[0]!, a[1]! - b[1]!)).toBeLessThan(0.003);
    near(p.gameToLngLat(-3419.96, -3747.54), [9.2743, 51.2561]);   // Kassel
    near(p.gameToLngLat(1849.11, 6498.55), [10.9343, 49.5113]);    // Nuremberg
    near(p.gameToLngLat(-24054.89, 5660.02), [3.864, 49.1785]);    // Reims
    // Great Britain is drawn at 0.75 scale around Calais: Aberdeen lands in Scotland, not in the North Sea.
    const [lon, lat] = p.gameToLngLat(-39596.79 + 750, -56040.47 + 750);
    expect(lon).toBeGreaterThan(-3.5);
    expect(lon).toBeLessThan(-2);
    expect(lat).toBeGreaterThan(56.5);
  });

  it("turns the SCS heading (0 = north, counter-clockwise) into a map bearing", async () => {
    const p = await load();
    const b = (h: number) => p.headingBearing(-3419.96, -3747.54, h);
    // Kassel is west of the LCC central meridian (15°E), so grid north points a few degrees west of true north.
    expect(Math.min(b(0), 360 - b(0))).toBeLessThan(15);
    expect(Math.abs(b(0.25) - 270)).toBeLessThan(15); // west
    expect(Math.abs(b(0.5) - 180)).toBeLessThan(15);  // south
    expect(Math.abs(b(0.75) - 90)).toBeLessThan(15);  // east
  });
});
