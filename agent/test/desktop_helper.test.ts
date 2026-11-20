// Native desktop helper (other desktops, P1): HelperClient against a fake `tiphys-desktop` (fake_desktop_helper.mjs:
// hello, multiplexing, timeouts, crash restart, idle stop, error mapping), backend selection, and every portable route
// (control session, rate limits, id validation, capabilities, live screen WS). The real PC is never touched.
import { spawn } from "node:child_process";
import { chmod, mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { RateLimit } from "../src/control.ts";
import { HYPRLAND_CAPABILITIES, findHelper, selectBackend } from "../src/desktop_backend.ts";
import { HelperClient, type HelperOpts } from "../src/desktop_helper.ts";
import { AppError } from "../src/errors.ts";
import { helperKeys, portableRoutes, portableState, parseHelperWindows, parseHelperWorkspaces, parseHelperMonitors, workspaceNumbers, type PortableOpts } from "../src/routes/desktop_portable.ts";
import { realStreamIo, type StreamIo } from "../src/routes/stream.ts";
import { testApp } from "./helpers.ts";

const FAKE = fileURLToPath(new URL("./fake_desktop_helper.mjs", import.meta.url));

async function tmpLog() {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-helper-"));
  return join(dir, "helper.log");
}
const lines = async (file: string) => (await readFile(file, "utf8").catch(() => "")).split("\n").filter(Boolean);

function client(log: string, env: Record<string, string> = {}, opts: Partial<HelperOpts> = {}) {
  return new HelperClient({ command: FAKE, env: { ...process.env, FAKE_HELPER_LOG: log, ...env }, killGraceMs: 100, ...opts });
}

async function until<T>(fn: () => T | undefined | false | Promise<T | undefined | false>, ms = 3000): Promise<T> {
  const end = Date.now() + ms;
  for (;;) {
    const v = await fn();
    if (v) return v;
    if (Date.now() > end) throw new Error("zaman aşımı");
    await new Promise((r) => setTimeout(r, 10));
  }
}

const codeOf = (p: Promise<unknown>) => p.then(() => "ok", (e: unknown) => (e instanceof AppError ? `${e.code} ${e.status}` : String(e)));

describe("HelperClient", () => {
  it("lazy start, hello, out-of-order answers, timeout, idle stop", async () => {
    const log = await tmpLog();
    const c = client(log, {}, { idleMs: 150 });
    expect(c.running).toBe(false);
    expect(await lines(log)).toEqual([]); // nothing runs before the first use
    const h = await c.hello();
    expect(h).toMatchObject({ protocol: 1, backend: "x11", version: "0.0.1-fake" });
    expect(h.capabilities).toContain("windows");
    // The slow answer comes after the quick one: matched by id.
    const order: string[] = [];
    await Promise.all([c.request("slow").then(() => order.push("slow")), c.request("ping").then(() => order.push("ping"))]);
    expect(order).toEqual(["ping", "slow"]);
    expect(await codeOf(c.request("hang", {}, { timeoutMs: 50 }))).toBe("agent.desktop.helperFailed 502");
    // Idle: stops after idleMs without requests; a hold keeps it running.
    const release = c.hold();
    await new Promise((r) => setTimeout(r, 250));
    expect(c.running).toBe(true);
    release();
    await until(() => !c.running);
    // Next use starts it again (no backoff after a planned stop).
    await c.request("ping");
    expect((await lines(log)).filter((l) => l.startsWith("start serve"))).toHaveLength(2);
    await c.stop();
    expect(c.running).toBe(false);
  });

  it("helper error codes → AppError", async () => {
    const c = client(await tmpLog());
    expect(await codeOf(c.request("err:unsupported"))).toBe("agent.desktop.unsupported 501");
    expect(await codeOf(c.request("err:notFound"))).toBe("agent.desktop.windowNotFound 404");
    expect(await codeOf(c.request("err:notFound", {}, { notFound: "agent.desktop.appNotFound" }))).toBe("agent.desktop.appNotFound 404");
    expect(await codeOf(c.request("err:busy"))).toBe("agent.control.rateLimited 429");
    expect(await codeOf(c.request("err:failed"))).toBe("agent.desktop.helperFailed 502");
    expect(await codeOf(c.request("err:badRequest"))).toBe("agent.request.invalid 400");
    const perm = await c.request("err:permission").catch((e) => e as AppError);
    expect(perm).toMatchObject({ code: "agent.desktop.permission", status: 403, params: { permission: "Accessibility" } });
    await expect(c.require("nope")).rejects.toMatchObject({ code: "agent.desktop.unsupported", status: 501 });
    await c.stop();
  });

  it("crash: pending requests fail, restart after backoff; subscribers come back by themselves", async () => {
    const log = await tmpLog();
    const c = client(log, {}, { backoffMs: [100] });
    const events: unknown[] = [];
    c.subscribe("focus", (e) => events.push(e));
    await until(() => events.length === 1);
    const t0 = Date.now();
    expect(await codeOf(c.request("die"))).toBe("agent.desktop.helperFailed 502");
    // The subscription restarts the helper after the backoff and subscribes again.
    await until(() => events.length === 2);
    expect(Date.now() - t0).toBeGreaterThanOrEqual(90);
    expect((await lines(log)).filter((l) => l.startsWith("subscribe"))).toHaveLength(2);
    expect(await c.request("ping")).toEqual({});
    await c.stop();
  });

  it("missing binary, wrong protocol, no hello", async () => {
    expect(await codeOf(new HelperClient({ command: null }).hello())).toBe("agent.desktop.helperMissing 500");
    expect(await codeOf(new HelperClient({ command: "/nonexistent/tiphys-desktop" }).request("ping"))).toBe("agent.desktop.helperMissing 500");
    const bad = client(await tmpLog(), { FAKE_HELPER_MODE: "badProtocol" });
    expect(await codeOf(bad.hello())).toBe("agent.desktop.helperFailed 502");
    await bad.stop();
    const silent = client(await tmpLog(), { FAKE_HELPER_MODE: "silent" }, { helloTimeoutMs: 100 });
    expect(await codeOf(silent.hello())).toBe("agent.desktop.helperFailed 502");
    await silent.stop();
  });
});

describe("backend seçimi", () => {
  const deps = (hypr: boolean, helper: string | null) => ({ hyprland: async () => (hypr ? {} : Promise.reject(new AppError("agent.desktop.noHyprland", 503))), findHelper: async () => helper });

  it("auto: Hyprland if found, else the helper, else Hyprland; explicit choices", async () => {
    expect(await selectBackend({}, deps(true, "/h"))).toEqual({ backend: "hyprland", helperPath: null });
    expect(await selectBackend({ backend: "auto" }, deps(false, "/h"))).toEqual({ backend: "helper", helperPath: "/h" });
    expect(await selectBackend({}, deps(false, null))).toEqual({ backend: "hyprland", helperPath: null });
    expect(await selectBackend({ backend: "hyprland" }, deps(false, "/h"))).toEqual({ backend: "hyprland", helperPath: null });
    expect(await selectBackend({ backend: "helper" }, deps(true, null))).toEqual({ backend: "helper", helperPath: null });
  });

  it("helper lookup: configured path, bundled build, PATH; only executable files", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-find-"));
    const bundled = join(dir, "bundled");
    const onPath = join(dir, "bin", "tiphys-desktop");
    await mkdir(join(dir, "bin"));
    await writeFile(onPath, "");
    expect(await findHelper(undefined, bundled, join(dir, "bin"))).toBeNull(); // not executable
    await chmod(onPath, 0o755);
    expect(await findHelper(undefined, bundled, join(dir, "bin"))).toBe(onPath);
    await writeFile(bundled, "", { mode: 0o755 });
    expect(await findHelper(undefined, bundled, join(dir, "bin"))).toBe(bundled);
    expect(await findHelper(join(dir, "yok"), bundled, join(dir, "bin"))).toBeNull(); // a configured path is not second-guessed
    expect(await findHelper(dir, bundled, "")).toBeNull(); // a directory doesn't count
  });

  it("buildApp: helper backend from the config; Hyprland reports everything", async () => {
    const h = await testApp((c) => {
      c.features.desktop = true;
      c.desktop = { clipboardSync: false, backend: "helper", helperPath: FAKE };
      return c;
    });
    const caps = (await h.app.inject({ method: "GET", url: "/v1/desktop/capabilities", headers: h.auth })).json();
    expect(caps).toMatchObject({ backend: "helper", platform: "x11" });
    expect(caps.capabilities).toEqual(expect.arrayContaining(["windows", "stream", "thumbnails"]));
    expect(caps.capabilities).not.toContain("audio");
    expect((await h.app.inject({ method: "GET", url: "/v1/desktop/windows", headers: h.auth })).json()).toMatchObject({ hyprland: false, backend: "helper" });
    expect((await h.app.inject({ method: "GET", url: "/v1/desktop/sunshine", headers: h.auth })).json().error.code).toBe("agent.desktop.unsupported");
    // The config API keeps the file-only fields when the phone changes clipboardSync.
    await h.app.inject({ method: "PATCH", url: "/v1/config", headers: h.auth, payload: { desktop: { clipboardSync: true } } });
    expect(h.store.get().desktop).toEqual({ clipboardSync: true, backend: "helper", helperPath: FAKE });
    await h.app.close();

    const y = await testApp((c) => {
      c.features.desktop = true;
      c.desktop = { clipboardSync: false, backend: "hyprland" };
      return c;
    });
    expect((await y.app.inject({ method: "GET", url: "/v1/desktop/capabilities", headers: y.auth })).json()).toEqual({ backend: "hyprland", capabilities: [...HYPRLAND_CAPABILITIES] });
    await y.app.close();
  });
});

describe("taşınabilir durum eşlemesi", () => {
  it("workspaces get Hyprland numbers; windows keep the Hyprland shape", () => {
    const ws = parseHelperWorkspaces([{ id: "w-a", name: "mail" }, { id: "3", name: "3" }, { id: "w-b", name: "web", focused: true }]);
    expect([...workspaceNumbers(ws)]).toEqual([["3", 3], ["w-a", 1], ["w-b", 2]]);
    const s = portableState(
      parseHelperWindows([{ id: "0x1", title: "T", appId: "Foot", workspace: "w-b", x: 1, y: 2, w: 30, h: 40, focused: true }, { id: "bad" }]),
      ws,
      parseHelperMonitors([{ id: "0", name: "HDMI-1", x: 0, y: 0, w: 1280, h: 720, scale: 1.5 }]),
      [{ id: "foot", name: "Foot", icon: null }],
    );
    expect(s.activeWorkspace).toBe(2);
    expect(s.monitors).toEqual([{ id: 0, name: "HDMI-1", width: 1920, height: 1080, x: 0, y: 0, scale: 1.5, focused: true, activeWorkspace: 0, dpms: true }]);
    expect(s.windows).toEqual([
      { address: "0x1", class: "Foot", title: "T", workspace: { id: 2, name: "web" }, at: [1, 2], size: [30, 40], floating: false, fullscreen: false, pinned: false, focused: true, visible: true, appId: "foot" },
    ]);
  });

  it("keys: same allow-list as Hyprland, helper names", () => {
    expect(helperKeys("C", ["ctrl"])).toEqual(["ctrl", "c"]);
    expect(helperKeys("Esc")).toEqual(["escape"]);
    expect(helperKeys("F11")).toEqual(["f11"]);
    expect(() => helperKeys("C")).toThrow(AppError); // letters only as shortcuts
    expect(() => helperKeys("KPPlus", ["ctrl"])).toThrow(AppError); // not in the helper's table
  });
});

/** Live screen spawner: real processes with the fake's environment. */
const streamIo = (env: Record<string, string>): StreamIo => ({ ...realStreamIo, spawn: (cmd, args, e) => spawn(cmd, args, { env: { ...e, ...env }, stdio: ["pipe", "pipe", "pipe"] }) });

async function portableApp(o: { env?: Record<string, string>; control?: boolean; opts?: Partial<PortableOpts> } = {}) {
  const log = await tmpLog();
  const icon = join(dirname(log), "editor.png");
  await writeFile(icon, Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]));
  const env = { FAKE_HELPER_LOG: log, FAKE_HELPER_ICON: icon, ...o.env };
  const c = client(log, env);
  const t = await testApp(
    (cfg) => {
      cfg.features.control = o.control ?? true;
      return cfg;
    },
    [(a, ctx) => portableRoutes(a, ctx, { client: c, clipboard: "helper", streamIo: streamIo(env), stream: { killGraceMs: 100, statsMs: 60_000 }, ...o.opts })],
  );
  await t.app.ready();
  const session = async () => (await t.app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: t.auth, payload: {} })).json().token as string;
  return { ...t, client: c, log, session };
}

describe("taşınabilir uçlar", () => {
  it("read-only: capabilities, windows, thumbnail, apps, icon, screenshot, clipboard", async () => {
    const { app, auth, log } = await portableApp();
    const get = (url: string) => app.inject({ method: "GET", url, headers: auth });
    expect((await get("/v1/desktop/capabilities")).json()).toMatchObject({ backend: "helper", platform: "x11", capabilities: expect.arrayContaining(["clipboard", "thumbnails"]) });
    const s = (await get("/v1/desktop/windows")).json();
    expect(s.workspaces.map((w: { id: number; name: string; windows: number }) => [w.id, w.name, w.windows])).toEqual([[1, "1", 2], [2, "2", 1], [3, "mail", 0]]);
    expect(s.windows.map((w: { address: string; visible: boolean; appId: string | null }) => [w.address, w.visible, w.appId])).toEqual([
      ["0x3a00007", true, "org.gnome.TextEditor.desktop"],
      ["0x3a00020", false, "foot.desktop"],
      ["0x3a00010", false, "foot.desktop"],
    ]);
    const thumb = await get("/v1/desktop/windows/0x3a00007/thumb?w=200");
    expect(thumb.headers["content-type"]).toBe("image/jpeg");
    expect((await get("/v1/desktop/windows/0x3a00020/thumb")).json().error.code).toBe("agent.desktop.windowNotVisible");
    expect((await get("/v1/desktop/windows/0x99/thumb")).statusCode).toBe(404);
    expect((await get("/v1/desktop/windows/garip/thumb")).statusCode).toBe(400);
    expect((await get("/v1/desktop/apps?lang=en")).json().apps.map((a: { id: string; hasIcon: boolean }) => [a.id, a.hasIcon])).toEqual([["org.gnome.TextEditor.desktop", true], ["foot.desktop", false]]);
    expect((await get("/v1/desktop/apps/org.gnome.TextEditor.desktop/icon")).headers["content-type"]).toBe("image/png");
    expect((await get("/v1/desktop/apps/foot.desktop/icon")).statusCode).toBe(404);
    const shot = await get("/v1/desktop/screenshot?scale=0.5");
    expect(shot.headers["content-type"]).toBe("image/png");
    expect((await lines(log)).find((l) => l.startsWith("screenshot") && l.includes('"format":"png"'))).toContain('"maxWidth":960');
    expect((await get("/v1/desktop/clipboard")).json()).toEqual({ text: "" });
    expect((await app.inject({ method: "PUT", url: "/v1/desktop/clipboard", headers: auth, payload: { text: "gizli ğ" } })).json()).toEqual({ ok: true });
    expect((await get("/v1/desktop/clipboard")).json()).toEqual({ text: "gizli ğ" });
    for (const url of ["/v1/desktop/ui", "/v1/desktop/sunshine"]) expect((await get(url)).statusCode).toBe(501);
    await app.close();
  });

  it("mutating: control feature, session, validation, rate limit, workspace mapping", async () => {
    const off = await portableApp({ control: false });
    expect((await off.app.inject({ method: "POST", url: "/v1/desktop/dpms/off", headers: off.auth })).json().error.code).toBe("agent.control.disabled");
    await off.app.close();

    const { app, auth, log, session } = await portableApp({ opts: { panelLimit: new RateLimit(6, 60_000) } });
    const post = (url: string, headers: Record<string, string>, payload: object = {}) => app.inject({ method: "POST", url, headers, payload });
    expect((await post("/v1/desktop/windows/0x3a00007/focus", auth)).json().error.code).toBe("agent.control.sessionRequired");
    const h = { ...auth, "x-tiphys-control": await session() };
    expect((await post("/v1/desktop/windows/garip/focus", h)).statusCode).toBe(400);
    expect((await post("/v1/desktop/windows/0x3a00007/rm", h)).statusCode).toBe(400);
    expect((await post("/v1/desktop/workspace/0", h)).statusCode).toBe(400);
    expect((await post("/v1/desktop/apps/yok/launch", h)).statusCode).toBe(404);
    expect((await post("/v1/desktop/windows/0x3a00007/focus", h)).json()).toEqual({ ok: true });
    expect((await post("/v1/desktop/windows/0x3a00010/move-to-workspace", h, { workspace: 3 })).json()).toEqual({ ok: true });
    expect((await post("/v1/desktop/workspace/2", h)).json()).toEqual({ ok: true });
    expect((await post("/v1/desktop/apps/foot.desktop/launch", h)).json()).toEqual({ ok: true });
    expect((await post("/v1/desktop/dpms/off", h)).json()).toEqual({ ok: true });
    expect((await post("/v1/desktop/windows/0x3a00007/pin", h)).statusCode).toBe(501);
    expect((await post("/v1/desktop/windows/0x3a00007/focus", h)).json().error.code).toBe("agent.control.rateLimited");
    const reqs = (await lines(log)).filter((l) => !l.startsWith("start") && !/^(windows|workspaces|monitors|apps) /.test(l));
    expect(reqs).toEqual([
      'window {"window":"0x3a00007","action":"focus"}',
      'move-to-workspace {"window":"0x3a00010","workspace":"w-mail"}',
      'workspace {"workspace":"2"}',
      'launch {"app":"foot.desktop"}',
      'dpms {"on":false}',
    ]);
    await app.close();
  });

  it("a capability the helper lacks answers unsupported", async () => {
    const { app, auth, session } = await portableApp({ env: { FAKE_HELPER_CAPS: "windows,apps" } });
    const h = { ...auth, "x-tiphys-control": await session() };
    expect((await app.inject({ method: "POST", url: "/v1/desktop/dpms/off", headers: h })).json().error).toEqual({ code: "agent.desktop.unsupported", params: { capability: "dpms" } });
    expect((await app.inject({ method: "GET", url: "/v1/desktop/screenshot", headers: auth })).statusCode).toBe(501);
    expect((await app.inject({ method: "GET", url: "/v1/desktop/capabilities", headers: auth })).json().capabilities).toEqual(["windows", "apps"]);
    await app.close();
  });

  it("live screen: session required, helper stream frames, input through the helper, cleanup", async () => {
    const { app, auth, log, session, client: c } = await portableApp();
    const denied = await app.inject({ method: "GET", url: "/v1/desktop/stream", headers: { ...auth, connection: "upgrade", upgrade: "websocket", "sec-websocket-version": "13", "sec-websocket-key": "dGhlIHNhbXBsZSBub25jZQ==" } });
    expect(denied.statusCode).toBe(403);
    const ws = await app.injectWS("/v1/desktop/stream?scale=0.5&fps=30", { headers: { ...auth, "x-tiphys-control": await session() } });
    const texts: Array<Record<string, unknown>> = [];
    const frames: Buffer[] = [];
    ws.on("message", (d: Buffer, binary: boolean) => (binary ? frames.push(d) : texts.push(JSON.parse(d.toString()))));
    await until(() => frames.length === 3);
    expect(texts[0]).toMatchObject({ type: "hello", width: 960, height: 540, codec: "mjpeg", fps: 20, source: "helper", cursor: null });
    expect(texts.find((t) => t.type === "focus")).toMatchObject({ address: "0x3a00010", class: "foot", title: "Terminal", workspace: 2 });
    expect((await lines(log)).find((l) => l.startsWith("start stream"))).toBe("start stream --monitor DP-1 --fps 20 --max-width 960 --quality 11");
    for (const m of [{ type: "move", x: 480, y: 270 }, { type: "click", button: "right" }, { type: "key", key: "C", mods: ["ctrl"] }, { type: "text", text: "a\nb" }, { type: "down", button: "left" }]) ws.send(JSON.stringify(m));
    await until(async () => (await lines(log)).some((l) => l.startsWith("button")));
    ws.terminate(); // dropped connection: the held button is released
    await until(async () => (await lines(log)).filter((l) => l.startsWith("button")).length === 2);
    const input = (await lines(log)).filter((l) => /^(pointer|click|key|text|button) /.test(l));
    expect(input).toEqual([
      'pointer {"x":960,"y":540}',
      'click {"button":"right","double":false}',
      'key {"keys":["ctrl","c"]}',
      'text {"text":"a"}',
      'key {"keys":["enter"]}',
      'text {"text":"b"}',
      'button {"button":"left","down":true}',
      'button {"button":"left","down":false}',
    ]);
    await app.close();
    expect(c.running).toBe(false); // agent shutdown kills the helper
  });

  it("live screen: helper stream exit code → error for the client", async () => {
    const { app, auth, session } = await portableApp({ env: { FAKE_STREAM_EXIT: "3" } });
    const ws = await app.injectWS("/v1/desktop/stream", { headers: { ...auth, "x-tiphys-control": await session() } });
    const texts: Array<Record<string, unknown>> = [];
    let closed: number | null = null;
    ws.on("message", (d: Buffer, binary: boolean) => !binary && texts.push(JSON.parse(d.toString())));
    ws.on("close", (code: number) => (closed = code));
    await until(() => closed);
    expect(texts.find((t) => t.type === "error")).toEqual({ type: "error", code: "agent.desktop.permission" });
    expect(closed).toBe(4502);
    await app.close();
  });
});
