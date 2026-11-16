// 11.2 Firefox bridge: framing, native messaging helper (real temporary unix socket), agent bridge (fake extension
// client), endpoints (auth, control token, rate limit, timeout, not connected, SSE), "Open on PC" and installation.
// Real Firefox, the user's profile and the agent socket are never touched (everything lives in a temp folder).
import { spawnSync } from "node:child_process";
import { readFile, stat, mkdtemp, writeFile, mkdir } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { connect, createServer, type Socket } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { afterEach, describe, expect, it } from "vitest";
import { BrowserBridge } from "../src/browser_bridge.ts";
import { RateLimit, type Indicator } from "../src/control.ts";
import { FRAME_MAX, FrameDecoder, FrameTooLarge, encodeFrame } from "../src/firefox_frame.ts";
import { runHost } from "../src/firefox_host.ts";
import { installFirefoxHost } from "../src/firefox_install.ts";
import { AppError } from "../src/errors.ts";
import { browserOpener, browserRoutes, sseWriter } from "../src/routes/browser.ts";
import type { Ctx } from "../src/server.ts";
import { openRoutes } from "../src/routes/desktop.ts";
import { hyprRoutes, type HyprIo } from "../src/routes/hypr.ts";
import { testApp } from "./helpers.ts";

const tmp = () => mkdtemp(join(tmpdir(), "tiphys-ff-"));
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function until(fn: () => boolean, ms = 2000) {
  const t = Date.now();
  while (!fn()) {
    if (Date.now() - t > ms) throw new Error("bekleme zaman aşımı");
    await sleep(10);
  }
}
const cleanups: Array<() => unknown> = [];
afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
});

describe("çerçeveleme", () => {
  it("bölünmüş ve birleşmiş parçalar, Unicode", () => {
    const a = encodeFrame({ type: "hello", n: "çğış" });
    const b = encodeFrame({ type: "x", v: 2 });
    const all = Buffer.concat([a, b]);
    const dec = new FrameDecoder();
    const got: unknown[] = [];
    for (let i = 0; i < all.length; i += 3) for (const f of dec.push(all.subarray(i, i + 3))) got.push(JSON.parse(f.toString("utf8")));
    expect(got).toEqual([{ type: "hello", n: "çğış" }, { type: "x", v: 2 }]);
    expect(new FrameDecoder().push(all).map((f) => JSON.parse(f.toString()))).toHaveLength(2);
    expect(new FrameDecoder().push(Buffer.alloc(3))).toEqual([]); // truncated length
  });

  it("1 MB sınırı: kodlarken ve çözerken", () => {
    expect(() => encodeFrame("x".repeat(FRAME_MAX + 1))).toThrow(FrameTooLarge);
    expect(encodeFrame(Buffer.alloc(FRAME_MAX)).length).toBe(FRAME_MAX + 4);
    const head = Buffer.alloc(4);
    head.writeUInt32LE(FRAME_MAX + 1); // test machine is LE
    expect(() => new FrameDecoder().push(head)).toThrow(FrameTooLarge);
  });
});

/** Simple listener in place of the agent socket: collects incoming frames, exposes the connection. */
async function fakeAgent(path: string) {
  const got: unknown[] = [];
  let sock: Socket | null = null;
  const server = createServer((s) => {
    sock = s;
    const dec = new FrameDecoder();
    s.on("data", (c: Buffer) => dec.push(c).forEach((f) => got.push(JSON.parse(f.toString()))));
    s.on("error", () => {});
  });
  await new Promise<void>((r) => server.listen(path, r));
  return { got, sock: () => sock, close: () => new Promise<void>((r) => (sock?.destroy(), server.close(() => r()))) };
}

function firefoxSide() {
  const input = new PassThrough();
  const output = new PassThrough();
  const got: Array<Record<string, unknown>> = [];
  const dec = new FrameDecoder();
  output.on("data", (c: Buffer) => dec.push(c).forEach((f) => got.push(JSON.parse(f.toString()))));
  return { input, output, got };
}

describe("yerel ileti yardımcısı", () => {
  it("aktarır, ajan yokken bekler, 5 sn aralıkla yeniden bağlanır, stdin kapanınca çıkar", async () => {
    const dir = await tmp();
    const path = join(dir, "firefox.sock");
    const ff = firefoxSide();
    const done = runHost({ input: ff.input, output: ff.output, socketPath: path, reconnectMs: 50 });
    // Agent down: messages from the extension are dropped.
    ff.input.write(encodeFrame({ type: "hello", version: 1 }));
    await sleep(80);
    const agent = await fakeAgent(path);
    cleanups.push(agent.close);
    await until(() => ff.got.some((m) => m.type === "host" && m.agent === true));
    // Two split messages → two frames to the agent.
    const two = Buffer.concat([encodeFrame({ type: "hello", version: 1 }), encodeFrame({ type: "res", id: 1, ok: true })]);
    ff.input.write(two.subarray(0, 5));
    ff.input.write(two.subarray(5));
    await until(() => agent.got.length === 2);
    expect(agent.got).toEqual([{ type: "hello", version: 1 }, { type: "res", id: 1, ok: true }]);
    // Agent → Firefox
    agent.sock()!.write(encodeFrame({ type: "req", id: 7, op: "tabs.list", args: {} }));
    await until(() => ff.got.some((m) => m.type === "req"));
    // Agent disconnects → the extension is told, then it reconnects.
    agent.sock()!.destroy();
    await until(() => ff.got.some((m) => m.type === "host" && m.agent === false));
    await until(() => ff.got.filter((m) => m.type === "host" && m.agent === true).length === 2);
    ff.input.end();
    expect(await done).toBe(0);
  });

  it("Firefox'tan 1 MB üstü ileti atlanır (yardımcı çıkmaz); ajandan büyük ileti → bağlantı kapatılır", async () => {
    const dir = await tmp();
    const path = join(dir, "firefox.sock");
    const agent = await fakeAgent(path);
    cleanups.push(agent.close);
    const ff = firefoxSide();
    const done = runHost({ input: ff.input, output: ff.output, socketPath: path, reconnectMs: 50 });
    await until(() => ff.got.length === 1);
    const big = Buffer.alloc(4);
    big.writeUInt32LE(FRAME_MAX + 10);
    agent.sock()!.write(big);
    await until(() => ff.got.some((m) => m.type === "host" && m.agent === false));
    await until(() => ff.got.filter((m) => m.type === "host" && m.agent === true).length === 2); // reconnected
    const got = agent.got.length;
    // A large frame arrives in pieces, then a valid message: the large one is skipped, the valid one reaches the agent.
    const body = Buffer.alloc(FRAME_MAX + 10, 0x61);
    ff.input.write(Buffer.concat([big, body.subarray(0, 1000)]));
    ff.input.write(body.subarray(1000, 600_000));
    ff.input.write(Buffer.concat([body.subarray(600_000), encodeFrame({ type: "res", id: 3, ok: true })]));
    await until(() => agent.got.length === got + 1);
    expect(agent.got.at(-1)).toEqual({ type: "res", id: 3, ok: true });
    ff.input.end();
    expect(await done).toBe(0);
  });

  it("çerçeve çözücü: onOversize verilince büyük çerçeve atlanır, akış sürer", () => {
    const skipped: number[] = [];
    const dec = new FrameDecoder(16, (n) => skipped.push(n));
    const big = Buffer.alloc(4);
    big.writeUInt32LE(20);
    const ok = encodeFrame({ a: 1 });
    expect(dec.push(Buffer.concat([big, Buffer.alloc(5)]))).toEqual([]);
    expect(dec.push(Buffer.concat([Buffer.alloc(15), ok])).map((b) => b.toString())).toEqual(['{"a":1}']);
    expect(skipped).toEqual([20]);
  });
});

/** Fake extension: connects to the bridge socket, sends hello, answers requests with [handler]. */
async function fakeExtension(path: string, handler: (req: { id: number; op: string; args: Record<string, unknown> }) => unknown, hello: Record<string, unknown> = {}) {
  const s = connect(path);
  const reqs: Array<{ id: number; op: string; args: Record<string, unknown> }> = [];
  const dec = new FrameDecoder();
  s.on("data", (c: Buffer) => {
    for (const f of dec.push(c)) {
      const m = JSON.parse(f.toString());
      if (m.type !== "req") continue;
      reqs.push(m);
      const r = handler(m);
      if (r !== undefined) s.write(encodeFrame({ type: "res", id: m.id, ...(r as object) }));
    }
  });
  s.on("error", () => {});
  await new Promise<void>((r) => s.once("connect", () => r()));
  s.write(encodeFrame({ type: "hello", version: 1, ext: "0.1.0", permissions: { content: true }, ...hello }));
  const send = (m: object) => s.write(encodeFrame(m));
  return { sock: s, reqs, send, close: () => s.destroy() };
}

async function newBridge() {
  const dir = await tmp();
  const path = join(dir, "run", "tiphys", "firefox.sock");
  const bridge = await BrowserBridge.listen(path);
  cleanups.push(() => bridge.close());
  return { bridge, path, dir };
}

describe("ajan köprüsü", () => {
  it("klasör 0700, soket 0600; canlı soket ikinci kez açılmaz, ölü soket temizlenir", async () => {
    const { bridge, path } = await newBridge();
    expect((await stat(join(path, ".."))).mode & 0o777).toBe(0o700);
    expect((await stat(path)).mode & 0o777).toBe(0o600);
    await expect(BrowserBridge.listen(path)).rejects.toThrow(/kullanımda/);
    await bridge.close();
    // Dead socket file (the agent crashed): it is reopened.
    spawnSync(process.execPath, ["-e", `require("net").createServer().listen(${JSON.stringify(path)}, () => process.kill(process.pid, "SIGKILL"))`]);
    expect((await stat(path)).isSocket()).toBe(true);
    await (await BrowserBridge.listen(path)).close();
    await writeFile(path, "düz dosya");
    await expect(BrowserBridge.listen(path)).rejects.toThrow(/başka dosya/);
  });

  it("hello, istek/yanıt, hata kodları, zaman aşımı, olaylar; ikinci hello reddedilir (canlı bağlantı kalır)", async () => {
    const { bridge, path } = await newBridge();
    expect(bridge.status).toEqual({ connected: false, version: null, ext: null, permissions: { content: false } });
    await expect(bridge.request("tabs.list")).rejects.toMatchObject({ code: "agent.browser.notConnected", status: 503 });
    const events: unknown[] = [];
    bridge.onEvent((e) => events.push(e));
    const ext = await fakeExtension(path, (r) => (r.op === "tabs.list" ? { ok: true, result: [{ id: 1 }] } : r.op === "silent" ? undefined : { ok: false, error: r.op === "x" ? "tabNotFound" : "garip" }));
    await until(() => bridge.connected);
    expect(bridge.status).toEqual({ connected: true, version: 1, ext: "0.1.0", permissions: { content: true } });
    expect(await bridge.request("tabs.list")).toEqual([{ id: 1 }]);
    await expect(bridge.request("x")).rejects.toMatchObject({ code: "agent.browser.tabNotFound", status: 404 });
    await expect(bridge.request("y")).rejects.toMatchObject({ code: "agent.browser.failed", status: 502 });
    await expect(bridge.request("silent", {}, 50)).rejects.toMatchObject({ code: "agent.browser.timeout", status: 504 });
    ext.send({ type: "event", name: "tabs", tabs: [{ id: 2 }] });
    ext.send({ type: "permissions", permissions: { content: false } });
    await until(() => events.length >= 3);
    expect(events.at(-2)).toEqual({ type: "tabs", tabs: [{ id: 2 }] });
    expect(bridge.status.permissions.content).toBe(false);
    // A second extension (second Firefox) is rejected with {type:"error", code:"busy"}; the first connection and its
    // request carry on.
    const s2 = connect(path);
    const got2: unknown[] = [];
    const dec2 = new FrameDecoder();
    s2.on("data", (c: Buffer) => dec2.push(c).forEach((f) => got2.push(JSON.parse(f.toString()))));
    s2.on("error", () => {});
    let ended = false;
    s2.on("end", () => (ended = true));
    await new Promise<void>((r) => s2.once("connect", () => r()));
    s2.write(encodeFrame({ type: "hello", version: 1, ext: "0.2.0", permissions: { content: true } }));
    await until(() => ended);
    expect(got2).toEqual([{ type: "error", code: "busy" }]);
    s2.destroy();
    expect(bridge.status.ext).toBe("0.1.0");
    expect(await bridge.request("tabs.list")).toEqual([{ id: 1 }]);
    ext.close();
    await until(() => !bridge.connected);
    // Once the first one leaves, a new one is accepted.
    const ext3 = await fakeExtension(path, () => ({ ok: true, result: "yeni" }), { ext: "0.2.0" });
    cleanups.push(ext3.close);
    await until(() => bridge.status.ext === "0.2.0");
    expect(await bridge.request("tabs.list")).toBe("yeni");
  });

  it("yanlış sürüm, hello'suz ileti ve bozuk JSON reddedilir", async () => {
    const { bridge, path } = await newBridge();
    const old = await fakeExtension(path, () => ({ ok: true }), { version: 99 });
    await until(() => old.sock.destroyed || old.sock.readableEnded);
    expect(bridge.connected).toBe(false);
    const s = connect(path);
    s.on("error", () => {});
    await new Promise<void>((r) => s.once("connect", () => r()));
    s.write(encodeFrame({ type: "event", name: "tabs", tabs: [] })); // without hello: ignored
    s.write(encodeFrame("{bozuk"));
    await until(() => s.destroyed || s.readableEnded);
    expect(bridge.connected).toBe(false);
  });
});

// ---- endpoints ----

const FF_CLIENTS = [
  { address: "0xaa", mapped: true, hidden: false, at: [0, 0], size: [800, 600], workspace: { id: 1, name: "1" }, floating: false, monitor: 0, class: "firefox-esr", title: "Diğer — Mozilla Firefox", pid: 10, pinned: false, fullscreen: 0, focusHistoryID: 1 },
  { address: "0xbb", mapped: true, hidden: false, at: [0, 0], size: [800, 600], workspace: { id: 2, name: "2" }, floating: false, monitor: 0, class: "firefox-esr", title: "Haber sayfası — Mozilla Firefox", pid: 10, pinned: false, fullscreen: 0, focusHistoryID: 2 },
  { address: "0xcc", mapped: true, hidden: false, at: [0, 0], size: [800, 600], workspace: { id: 1, name: "1" }, floating: false, monitor: 0, class: "kitty", title: "~", pid: 11, pinned: false, fullscreen: 0, focusHistoryID: 0 },
];

function hyprFake() {
  const dispatched: string[] = [];
  const io: HyprIo = {
    exec: async (cmd, args) => {
      const ok = (stdout: string) => ({ stdout, stderr: "", code: 0 });
      if (cmd === "hyprctl" && args[0] === "-j" && args[1] === "clients") return ok(JSON.stringify(FF_CLIENTS));
      if (cmd === "hyprctl" && args[0] === "eval") return ok("unknown request\n");
      if (cmd === "hyprctl" && args[0] === "dispatch") {
        dispatched.push(args.slice(1).join(" "));
        return ok("ok\n");
      }
      if (cmd === "gsettings") return ok("'Adwaita'\n");
      throw new Error(`beklenmeyen komut ${cmd} ${args.join(" ")}`);
    },
    bytes: async () => ({ out: Buffer.alloc(0), code: 1, err: "" }),
    has: async () => false,
    hyprEnv: async () => ({ HYPRLAND_INSTANCE_SIGNATURE: "sig" }),
    screenEnv: async () => ({}),
  };
  return { io, dispatched };
}

const indicator: Indicator = { on: async () => {}, off: async () => {} };

async function browserApp(o: { bridge?: BrowserBridge | null; limit?: RateLimit } = {}) {
  const h = hyprFake();
  const t = await testApp(
    (c) => {
      c.features.control = true;
      return c;
    },
    [
      (a, ctx) => hyprRoutes(a, ctx, h.io, { indicator, appDirs: [] }),
      (a, ctx) => {
        if (o.bridge) ctx.browser = o.bridge;
        browserRoutes(a, ctx, { limit: o.limit, pingMs: 30, recheckMs: 50 });
      },
    ],
  );
  cleanups.push(() => t.app.close());
  const start = await t.app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: t.auth, payload: {} });
  const ctl = { ...t.auth, "x-tiphys-control": start.json().token as string };
  return { ...t, h, ctl };
}

const TABS = [{ id: 5, windowId: 1, title: "Haber sayfası", url: "https://gizli.example/yol?q=sır", pinned: false }];

function extHandler(r: { op: string; args: Record<string, unknown> }) {
  switch (r.op) {
    case "tabs.list":
      return { ok: true, result: TABS };
    case "tabs.create":
      return { ok: true, result: { id: 9 } };
    case "tabs.activate":
      return r.args.id === 5 ? { ok: true, result: { title: "Haber sayfası" } } : { ok: false, error: "tabNotFound" };
    case "page.reader":
      return { ok: true, result: { title: "Makale", text: "gövde metni gizli" } };
    case "page.text":
      return { ok: false, error: "passwordField" };
    case "slow":
      return undefined;
    default:
      return { ok: true, result: {} };
  }
}

describe("tarayıcı uçları", () => {
  it("durum ucu belirteç istemez; diğerleri kontrol oturumu ister", async () => {
    const { bridge, path } = await newBridge();
    const { app, auth, ctl } = await browserApp({ bridge });
    expect((await app.inject({ url: "/v1/desktop/browser" })).statusCode).toBe(401);
    expect((await app.inject({ url: "/v1/desktop/browser", headers: auth })).json()).toMatchObject({ connected: false });
    const ext = await fakeExtension(path, extHandler);
    cleanups.push(ext.close);
    await until(() => bridge.connected);
    expect((await app.inject({ url: "/v1/desktop/browser", headers: auth })).json()).toEqual({ connected: true, version: 1, ext: "0.1.0", permissions: { content: true } });
    const routes: Array<[string, string, object?]> = [
      ["GET", "/v1/desktop/browser/tabs"],
      ["POST", "/v1/desktop/browser/tabs", { url: "https://e.com" }],
      ["POST", "/v1/desktop/browser/tabs/5/reload"],
      ["POST", "/v1/desktop/browser/tabs/close", { ids: [5] }],
      ["POST", "/v1/desktop/browser/restore"],
      ["GET", "/v1/desktop/browser/tabs/5/reader"],
      ["POST", "/v1/desktop/browser/tabs/5/media", { action: "pause" }],
      ["POST", "/v1/desktop/browser/tabs/5/scroll", { fraction: 0.5 }],
      ["POST", "/v1/desktop/browser/tabs/5/text", { text: "merhaba" }],
      ["GET", "/v1/desktop/browser/events"],
    ];
    for (const [method, url, payload] of routes) {
      const r = await app.inject({ method: method as "GET", url, headers: { ...auth, "x-tiphys-control": "tpc_yanlis" }, payload });
      expect([url, r.statusCode, r.json().error.code]).toEqual([url, 403, "agent.control.sessionRequired"]);
    }
    expect(ext.reqs).toEqual([]);
    const tabs = await app.inject({ url: "/v1/desktop/browser/tabs", headers: ctl });
    expect(tabs.json()).toEqual({ tabs: TABS });
  });

  it("eylemler, Hyprland odağı, hata kodları ve işlem kaydında adres/metin yok", async () => {
    const { bridge, path } = await newBridge();
    const { app, ctl, h, dir } = await browserApp({ bridge });
    const ext = await fakeExtension(path, extHandler);
    cleanups.push(ext.close);
    await until(() => bridge.connected);
    const post = (url: string, payload?: object) => app.inject({ method: "POST", url, headers: ctl, payload });
    // Switch to tab → the Firefox window with the matching title is raised.
    expect((await post("/v1/desktop/browser/tabs/5/activate")).json()).toEqual({ ok: true, focused: true });
    expect(h.dispatched).toEqual(["focuswindow address:0xbb"]);
    expect((await post("/v1/desktop/browser/tabs/6/activate")).json().error.code).toBe("agent.browser.tabNotFound");
    // New tab: http/https only; focus goes to the most recent Firefox window.
    expect((await post("/v1/desktop/browser/tabs", { url: "https://gizli.example/yeni-belge" })).json()).toEqual({ ok: true, id: 9, focused: true });
    expect(h.dispatched.at(-1)).toBe("focuswindow address:0xaa");
    const bad = await post("/v1/desktop/browser/tabs", { url: "javascript:alert(1)" });
    expect([bad.statusCode, bad.json().error.code]).toEqual([400, "agent.browser.badUrl"]);
    expect((await post("/v1/desktop/browser/tabs/5/explode")).statusCode).toBe(400);
    expect((await post("/v1/desktop/browser/tabs/abc/reload")).statusCode).toBe(400);
    expect((await post("/v1/desktop/browser/tabs/close", { ids: [5, 5, 6] })).json()).toEqual({ ok: true });
    expect((await post("/v1/desktop/browser/tabs/5/pin")).json()).toEqual({ ok: true });
    expect((await post("/v1/desktop/browser/restore")).json()).toEqual({ ok: true });
    expect((await post("/v1/desktop/browser/tabs/5/media", { action: "seek" })).statusCode).toBe(400);
    expect((await post("/v1/desktop/browser/tabs/5/media", { action: "rate", rate: 9 })).statusCode).toBe(400);
    expect((await post("/v1/desktop/browser/tabs/5/media", { action: "seek", seconds: -10 })).statusCode).toBe(200);
    expect((await post("/v1/desktop/browser/tabs/5/scroll", { fraction: 0.5 })).statusCode).toBe(200);
    const pw = await post("/v1/desktop/browser/tabs/5/text", { text: "gizli yazı" });
    expect([pw.statusCode, pw.json().error.code]).toEqual([409, "agent.browser.passwordField"]);
    const reader = await app.inject({ url: "/v1/desktop/browser/tabs/5/reader", headers: ctl });
    expect(reader.json()).toEqual({ title: "Makale", text: "gövde metni gizli" });
    const sent = ext.reqs.map((r) => [r.op, r.args]);
    expect(sent).toContainEqual(["tabs.close", { ids: [5, 6] }]);
    expect(sent).toContainEqual(["tabs.create", { url: "https://gizli.example/yeni-belge" }]);
    expect(sent).toContainEqual(["page.media", { id: 5, action: "seek", seconds: -10 }]);
    // If the permission was revoked, the 11.3 endpoints are rejected before reaching the extension.
    ext.send({ type: "permissions", permissions: { content: false } });
    await until(() => !bridge.status.permissions.content);
    const n = ext.reqs.length;
    const denied = await post("/v1/desktop/browser/tabs/5/scroll", { fraction: 1 });
    expect([denied.statusCode, denied.json().error.code]).toEqual([403, "agent.browser.permissionRequired"]);
    expect(ext.reqs.length).toBe(n);
    const audit = await readFile(join(dir, "audit.jsonl"), "utf8");
    expect(audit).toContain("/v1/desktop/browser/tabs/5/activate");
    for (const secret of ["gizli.example", "gizli yazı", "Haber", "gövde"]) expect(audit).not.toContain(secret);
    const events = await readFile(join(dir, "events.jsonl"), "utf8").catch(() => "");
    for (const secret of ["gizli.example", "Haber"]) expect(events).not.toContain(secret);
  });

  it("bağlı değil, zaman aşımı ve hız sınırı", async () => {
    const none = await browserApp({ bridge: null });
    const r = await none.app.inject({ url: "/v1/desktop/browser/tabs", headers: none.ctl });
    expect([r.statusCode, r.json().error.code]).toEqual([503, "agent.browser.notConnected"]);
    expect((await none.app.inject({ url: "/v1/desktop/browser", headers: none.auth })).json().connected).toBe(false);

    const { bridge, path } = await newBridge();
    const { app, ctl } = await browserApp({ bridge, limit: new RateLimit(3, 60_000) });
    const ext = await fakeExtension(path, () => undefined); // never replies
    cleanups.push(ext.close);
    await until(() => bridge.connected);
    const t = await app.inject({ url: "/v1/desktop/browser/tabs", headers: ctl });
    expect([t.statusCode, t.json().error.code]).toEqual([504, "agent.browser.timeout"]);
    ext.close();
    await until(() => !bridge.connected);
    const ext2 = await fakeExtension(path, extHandler);
    cleanups.push(ext2.close);
    await until(() => bridge.connected);
    for (let i = 0; i < 2; i++) expect((await app.inject({ method: "POST", url: "/v1/desktop/browser/restore", headers: ctl })).statusCode).toBe(200);
    const limited = await app.inject({ url: "/v1/desktop/browser/tabs", headers: ctl });
    expect([limited.statusCode, limited.json().error.code]).toEqual([429, "agent.control.rateLimited"]);
  }, 20_000);

  it("SSE: durum + sekme olayları; kontrol oturumu kapanınca akış biter", async () => {
    const { bridge, path } = await newBridge();
    const { app, ctl, auth } = await browserApp({ bridge });
    await app.listen({ host: "127.0.0.1", port: 0 });
    const port = (app.server.address() as AddressInfo).port;
    const ext = await fakeExtension(path, extHandler);
    cleanups.push(ext.close);
    await until(() => bridge.connected);
    const res = await fetch(`http://127.0.0.1:${port}/v1/desktop/browser/events`, { headers: ctl });
    expect(res.headers.get("content-type")).toContain("text/event-stream");
    const reader = res.body!.getReader();
    let text = "";
    const read = async (want: string) => {
      while (!text.includes(want)) {
        const { value, done } = await reader.read();
        if (done) return false;
        text += new TextDecoder().decode(value);
      }
      return true;
    };
    expect(await read("event: status")).toBe(true);
    ext.send({ type: "event", name: "tabs", tabs: [{ id: 5 }] });
    expect(await read('event: tabs\ndata: {"tabs":[{"id":5}]}')).toBe(true);
    expect(await read(": ping")).toBe(true);
    await app.inject({ method: "DELETE", url: "/v1/desktop/control/session", headers: auth });
    expect(await read("hiç gelmeyecek")).toBe(false); // stream closed
  });

  it("SSE: belirteç yenilenince ya da control kapanınca akış biter", async () => {
    const { bridge } = await newBridge();
    const { app, auth, store } = await browserApp({ bridge });
    await app.listen({ host: "127.0.0.1", port: 0 });
    const port = (app.server.address() as AddressInfo).port;
    const session = async () => ({ ...auth, "x-tiphys-control": (await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} })).json().token as string });
    const stream = async (h: Record<string, string>) => {
      const res = await fetch(`http://127.0.0.1:${port}/v1/desktop/browser/events`, { headers: h });
      expect(res.status).toBe(200);
      return res.text(); // ends when closed
    };
    const a = stream(await session());
    await sleep(60);
    await session(); // the same device got a new token → the old one is invalid
    expect(await a).toContain("event: status");
    const b = stream(await session());
    await sleep(60);
    await store.update((c) => ((c.features.control = false), c));
    expect(await b).toContain("event: status");
  });

  it("SSE geri basıncı: okumayan istemcide ara sekme listeleri atılır, en sonuncusu gider; 2 MB'da kesilir", () => {
    const chunks: string[] = [];
    const drains: Array<() => void> = [];
    const raw = { writableLength: 0, destroyed: false, write: (c: string) => (chunks.push(c), true), once: (_e: string, fn: () => void) => drains.push(fn), destroy: () => ((raw.destroyed = true), raw) };
    const out = sseWriter(raw as never, 100, 1000);
    out.send("tabs", { n: 1 }, true);
    raw.writableLength = 500; // the client isn't reading
    out.send("tabs", { n: 2 }, true);
    out.send("tabs", { n: 3 }, true);
    out.send("status", { s: 1 }); // the status event isn't sent
    expect(drains).toHaveLength(1);
    raw.writableLength = 0;
    drains.shift()!();
    expect(chunks).toEqual(['event: tabs\ndata: {"n":1}\n\n', 'event: status\ndata: {"s":1}\n\n', 'event: tabs\ndata: {"n":3}\n\n']);
    raw.writableLength = 2000;
    out.write(": ping\n\n");
    expect(raw.destroyed).toBe(true);
    out.send("status", {});
    expect(chunks).toHaveLength(4); // nothing is written after disconnect
  });

  it("PC'de aç: eklenti zaman aşımında eski açıcıya düşülmez", async () => {
    const opened: string[] = [];
    let err: AppError = new AppError("agent.browser.timeout", 504);
    const ctx = { browser: { connected: true, request: async () => Promise.reject(err) } } as unknown as Ctx;
    const open = browserOpener(ctx, async (u) => void opened.push(u));
    await expect(open("https://a.example/", {})).rejects.toMatchObject({ code: "agent.browser.timeout" });
    err = new AppError("agent.browser.notConnected", 503);
    await open("https://b.example/", {});
    expect(opened).toEqual(["https://b.example/"]);
  });
});

describe("PC'de aç", () => {
  it("eklenti bağlıysa yeni sekme; bağlı değilse (ya da istekte koptuysa) eski açıcı; eklenti hatasında çift açılış yok", async () => {
    const { bridge, path } = await newBridge();
    const opened: string[] = [];
    const t = await testApp((c) => c, [
      (a, ctx) => {
        ctx.browser = bridge;
        openRoutes(a, browserOpener(ctx, async (url) => void opened.push(url)), async () => ({}));
      },
    ]);
    cleanups.push(() => t.app.close());
    const open = (url: string) => t.app.inject({ method: "POST", url: "/v1/desktop/open", headers: t.auth, payload: { url } });
    expect((await open("https://a.example/")).statusCode).toBe(200);
    expect(opened).toEqual(["https://a.example/"]);
    let answer: "ok" | "fail" | "drop" = "ok";
    let sock: Socket | null = null;
    const ext = await fakeExtension(path, () => {
      if (answer === "ok") return { ok: true, result: { id: 1 } };
      if (answer === "drop") return void sock?.destroy();
      return { ok: false, error: "failed" };
    });
    sock = ext.sock;
    cleanups.push(ext.close);
    await until(() => bridge.connected);
    expect((await open("https://b.example/")).statusCode).toBe(200);
    expect(ext.reqs.map((r) => r.args)).toEqual([{ url: "https://b.example/" }]);
    expect(opened).toEqual(["https://a.example/"]);
    // The extension replied but with an error: the tab may have opened → no fallback to the old opener, the error is
    // reported.
    answer = "fail";
    expect((await open("https://c.example/")).statusCode).toBe(502);
    expect(opened).toEqual(["https://a.example/"]);
    // Connection dropped while the request was in flight (notConnected) → old opener.
    answer = "drop";
    expect((await open("https://d.example/")).statusCode).toBe(200);
    expect(opened).toEqual(["https://a.example/", "https://d.example/"]);
    expect((await open("file:///etc/passwd")).statusCode).toBe(400);
  });
});

describe("firefox install", () => {
  it("geçici HOME'a manifest + başlatıcı yazar, XPI'yi bulur", async () => {
    const home = await tmp();
    const host = join(home, "dist", "firefox_host.js");
    await mkdir(join(home, "dist"));
    await writeFile(host, "");
    const xpiDir = join(home, "xpi");
    await mkdir(xpiDir);
    await writeFile(join(xpiDir, "tiphys-bridge-0.1.0.xpi"), "");
    const r = await installFirefoxHost({ home, node: "/usr/bin/node", hostScript: host, xpiDir });
    expect(r.manifest).toBe(join(home, ".mozilla", "native-messaging-hosts", "dev.tiphys.bridge.json"));
    expect(r.launcher).toBe(join(home, ".local", "share", "tiphys", "firefox-host"));
    expect(r.xpi).toBe(join(xpiDir, "tiphys-bridge-0.1.0.xpi"));
    expect(JSON.parse(await readFile(r.manifest, "utf8"))).toEqual({
      name: "dev.tiphys.bridge",
      description: expect.any(String),
      path: r.launcher,
      type: "stdio",
      allowed_extensions: ["bridge@tiphys.dev"],
    });
    expect(await readFile(r.launcher, "utf8")).toContain(`exec '/usr/bin/node' '${host}' "$@"`);
    expect((await stat(r.launcher)).mode & 0o777).toBe(0o755);
    await expect(installFirefoxHost({ home, hostScript: join(home, "yok.js") })).rejects.toThrow(/yardımcı bulunamadı/);
  });
});
