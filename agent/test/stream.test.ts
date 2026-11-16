// 10.2 Live screen: JPEG frame splitter, coordinate transform, key table, text validation, WS stream (fake
// wf-recorder), backpressure, child process cleanup, auth/session. All with a fake runner; the real PC is not touched.
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import { describe, expect, it } from "vitest";
import { hashToken, newToken } from "../src/auth.ts";
import { RateLimit, type Indicator } from "../src/control.ts";
import { annexB } from "../src/h264.ts";
import { AppError } from "../src/errors.ts";
import { hyprRoutes, parseClients, parseMonitors } from "../src/routes/hypr.ts";
import {
  JpegSplitter,
  checkText,
  frameMessage,
  keyArgs,
  mapPoint,
  monitorRegion,
  outputSize,
  qscale,
  streamRoutes,
  targetFor,
  textPieces,
  unmapPoint,
  wfRecorderArgs,
  wfRecorderH264Args,
  type StreamIo,
  type StreamOpts,
} from "../src/routes/stream.ts";
import { testApp } from "./helpers.ts";

/** Smallest well-formed JPEG: SOI, APP0, SOS + entropy (contains FF00 and RST), EOI. */
function jpeg(tag: number, size = 0): Buffer {
  const app0 = Buffer.from([0xff, 0xe0, 0x00, 0x10, 0x4a, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0xff, 0xd9]); // FFD9 inside APP0: must be skipped via the length
  app0.writeUInt16BE(app0.length - 2, 2);
  const sos = Buffer.from([0xff, 0xda, 0x00, 0x08, 0x01, 0x01, 0x00, 0x00, 0x3f, 0x00]);
  const data = Buffer.concat([Buffer.from([tag, 0xff, 0x00, 0x12, 0xff, 0xd3, 0x34]), Buffer.alloc(size, tag)]);
  return Buffer.concat([Buffer.from([0xff, 0xd8]), app0, sos, data, Buffer.from([0xff, 0xd9])]);
}

const MONITORS = [
  { id: 0, name: "DVI-D-1", width: 1920, height: 1080, x: 0, y: 0, scale: 1, transform: 0, focused: true, activeWorkspace: { id: 1 }, specialWorkspace: { id: 0 }, dpmsStatus: true },
  { id: 1, name: "HDMI-A-1", width: 2560, height: 1440, x: 1920, y: 0, scale: 1.25, transform: 0, focused: false, activeWorkspace: { id: 5 }, specialWorkspace: { id: 0 }, dpmsStatus: true },
];
const CLIENTS = [
  { address: "0xa1", mapped: true, hidden: false, at: [100, 50], size: [800, 600], workspace: { id: 1, name: "1" }, monitor: 0, class: "foot", title: "t", pinned: false, fullscreen: 0, focusHistoryID: 0 },
  { address: "0xb2", mapped: true, hidden: false, at: [2000, 100], size: [1000, 800], workspace: { id: 5, name: "5" }, monitor: 1, class: "firefox", title: "f", pinned: false, fullscreen: 0, focusHistoryID: 1 },
  { address: "0xc3", mapped: true, hidden: false, at: [0, 0], size: [500, 500], workspace: { id: 3, name: "3" }, monitor: 0, class: "x", title: "gizli", pinned: false, fullscreen: 0, focusHistoryID: 2 },
];

class FakeChild extends EventEmitter {
  stdout = new PassThrough();
  stderr = new PassThrough();
  exitCode: number | null = null;
  signalCode: NodeJS.Signals | null = null;
  signals: string[] = [];
  ignoreTerm = false;
  readonly args: string[];
  constructor(args: string[]) {
    super();
    this.args = args;
  }
  get alive() {
    return this.exitCode === null && this.signalCode === null;
  }
  kill(sig: NodeJS.Signals = "SIGTERM") {
    this.signals.push(sig);
    if (!this.alive || (this.ignoreTerm && sig === "SIGTERM")) return true;
    setImmediate(() => this.exit(null, sig));
    return true;
  }
  exit(code: number | null, sig: NodeJS.Signals | null = null) {
    if (!this.alive) return;
    this.exitCode = code;
    this.signalCode = sig;
    this.emit("exit", code, sig);
  }
}

interface FakeOpts {
  /** Hyprland with Lua config: the old dispatch syntax is rejected. */
  lua?: boolean;
  noRecorder?: boolean;
  ignoreTerm?: boolean;
  cursor?: { x: number; y: number };
  /** screenEnv delay (for restart races). */
  envDelayMs?: number;
  /** hyprctl -j activewindow response (focus notification). */
  active?: () => unknown;
}

/** Fake Hyprland event socket (../src/focus.ts). */
export class FakeEventSocket extends EventEmitter {
  destroyed = false;
  readonly path: string;
  constructor(path: string) {
    super();
    this.path = path;
  }
  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    setImmediate(() => this.emit("close"));
  }
  /** Event lines arrive. */
  lines(...l: string[]) {
    this.emit("data", Buffer.from(l.map((x) => `${x}\n`).join(""), "utf8"));
  }
}

function fakeIo(o: FakeOpts = {}) {
  const children: FakeChild[] = [];
  const execs: string[] = [];
  const inputs: Array<{ cmd: string; args: string[]; input?: string }> = [];
  const sockets: FakeEventSocket[] = [];
  const io: StreamIo = {
    connect: (path) => {
      const s = new FakeEventSocket(path);
      sockets.push(s);
      setImmediate(() => !s.destroyed && s.emit("connect"));
      return s;
    },
    exec: async (cmd, args) => {
      const ok = (stdout: string) => ({ stdout, stderr: "", code: 0 });
      execs.push(`${cmd} ${args.join(" ")}`);
      if (cmd === "hyprctl" && args[0] === "-j") {
        if (args[1] === "monitors") return ok(JSON.stringify(MONITORS));
        if (args[1] === "clients") return ok(JSON.stringify(CLIENTS));
        if (args[1] === "cursorpos") return ok(JSON.stringify(o.cursor ?? { x: 960, y: 540 }));
        if (args[1] === "getoption") return ok(args[2] === "general:border_size" ? '{"int":2}' : '{"gradient":"ffffffff 0deg"}');
        if (args[1] === "activewindow") return ok(JSON.stringify(o.active?.() ?? {}));
        if (args[1] === "workspaces") return ok("[]");
      }
      if (cmd === "hyprctl" && args[0] === "eval") {
        // Mode probe: Lua config "ok", classic Hyprland unknown request.
        if (!o.lua) return { stdout: "unknown request\n", stderr: "", code: 0 };
        if (args[1] !== "return 1") inputs.push({ cmd, args });
        return ok("ok\n");
      }
      if (cmd === "hyprctl" && (args[0] === "keyword" || args[0] === "dispatch")) {
        if (o.lua) return { stdout: "keyword can't work with non-legacy parsers. Use eval.\n", stderr: "", code: 1 };
        if (args[0] === "dispatch") inputs.push({ cmd, args });
        return ok("ok\n");
      }
      if (cmd === "ydotool") {
        inputs.push({ cmd, args });
        return ok("");
      }
      if (cmd === "notify-send" || cmd === "gsettings") return ok("");
      throw new Error(`beklenmeyen komut ${cmd} ${args.join(" ")}`);
    },
    bytes: async (cmd, args, opts) => {
      if (cmd === "wtype") {
        inputs.push({ cmd, args, input: opts.input?.toString("utf8") });
        return { out: Buffer.alloc(0), code: 0, err: "" };
      }
      if (cmd === "grim") return { out: Buffer.from("P6\n2 2\n255\n" + "x".repeat(12)), code: 0, err: "" };
      if (cmd === "ffmpeg") return { out: jpeg(7), code: 0, err: "" };
      throw new Error(`beklenmeyen komut ${cmd}`);
    },
    has: async (c) => !(c === "wf-recorder" && o.noRecorder),
    // Returns on the next tick like a real command (injectWS misses the first message landing in the same chunk as the
    // 101 response).
    hyprEnv: async () => {
      await new Promise((r) => setTimeout(r, 5));
      return { HYPRLAND_INSTANCE_SIGNATURE: "sig" };
    },
    screenEnv: async () => {
      if (o.envDelayMs) await new Promise((r) => setTimeout(r, o.envDelayMs));
      return { WAYLAND_DISPLAY: "wayland-1" };
    },
    inputEnv: async () => ({ WAYLAND_DISPLAY: "wayland-1", YDOTOOL_SOCKET: "/tmp/ys" }),
    spawn: (cmd, args) => {
      if (cmd !== "wf-recorder") throw new Error(`beklenmeyen süreç ${cmd}`);
      const c = new FakeChild(args);
      c.ignoreTerm = !!o.ignoreTerm;
      children.push(c);
      return c;
    },
  };
  return { io, children, execs, inputs, sockets };
}

const indicator: Indicator = { on: async () => {}, off: async () => {} };

async function streamApp(f: ReturnType<typeof fakeIo>, opts: StreamOpts = {}, control = true) {
  const t = await testApp(
    (c) => {
      c.features.control = control;
      return c;
    },
    [
      (a, ctx) => {
        hyprRoutes(a, ctx, f.io, { indicator, now: opts.now, appDirs: [] }); // hermetic: no .desktop files from the host
        streamRoutes(a, ctx, f.io, { killGraceMs: 50, statsMs: 60_000, ...opts });
      },
    ],
  );
  await t.app.ready();
  const session = async (auth = t.auth) => (await t.app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} })).json().token as string;
  return { ...t, session };
}

/** WS client: text messages are collected as JSON, binaries as parsed frames. */
async function connect(app: Awaited<ReturnType<typeof streamApp>>["app"], url: string, headers: Record<string, string>) {
  const ws = await app.injectWS(url, { headers });
  const texts: Array<Record<string, unknown>> = [];
  const frames: Array<{ seq: number; flags: number; w: number; h: number; jpeg: Buffer }> = [];
  let closeCode: number | null = null;
  ws.on("message", (d: Buffer, binary: boolean) => {
    if (binary) frames.push({ seq: d.readUInt32BE(0) & 0xffffff, flags: d[0]!, w: d.readUInt16BE(12), h: d.readUInt16BE(14), jpeg: d.subarray(16) });
    else texts.push(JSON.parse(d.toString()));
  });
  ws.on("close", (code: number) => (closeCode = code));
  return { ws, texts, frames, closed: () => closeCode, send: (m: object) => ws.send(JSON.stringify(m)) };
}

async function until<T>(fn: () => T | undefined | false, ms = 2000): Promise<T> {
  const end = Date.now() + ms;
  for (;;) {
    const v = fn();
    if (v) return v;
    if (Date.now() > end) throw new Error("zaman aşımı");
    await new Promise((r) => setTimeout(r, 5));
  }
}

describe("JPEG kare ayırıcı", () => {
  it("parça sınırları, çöp, uzunluklu bölüt içindeki FFD9, bozuk kare", () => {
    const a = jpeg(1, 100);
    const b = jpeg(2, 3000);
    const stream = Buffer.concat([Buffer.from("çöp\xff\xff"), a, Buffer.from([0x00, 0xff]), b]);
    // Same result for every split point.
    for (let cut = 1; cut < stream.length; cut += 7) {
      const s = new JpegSplitter();
      const out = [...s.push(stream.subarray(0, cut)), ...s.push(stream.subarray(cut))];
      expect(out.map((x) => x.length), `kesim ${cut}`).toEqual([a.length, b.length]);
      expect(out[0]!.equals(a) && out[1]!.equals(b)).toBe(true);
    }
    // Bayt bayt.
    const s = new JpegSplitter();
    const got: Buffer[] = [];
    for (const byte of stream) got.push(...s.push(Buffer.from([byte])));
    expect(got).toHaveLength(2);
    // If what follows SOI is not a marker (corrupt), it is skipped and the next frame is found.
    const bad = new JpegSplitter();
    expect(bad.push(Buffer.concat([Buffer.from([0xff, 0xd8, 0xff, 0xd8, 0x12, 0x34]), a])).map((x) => x.length)).toEqual([a.length]);
    expect(bad.discarded).toBeGreaterThan(0);
    // A partial frame exceeding the limit is dropped.
    const small = new JpegSplitter(200);
    expect(small.push(jpeg(3, 1000).subarray(0, 900))).toEqual([]);
    expect(small.push(a)).toHaveLength(1);
  });
});

describe("koordinatlar ve hedef", () => {
  const ms = parseMonitors(MONITORS).map((m, i) => ({ ...m, transform: MONITORS[i]!.transform }));
  it("monitör: ölçek ve monitör konumu", () => {
    const t = targetFor(ms, {});
    expect(t).toEqual({ region: { x: 0, y: 0, w: 1920, h: 1080 }, pixels: { w: 1920, h: 1080 }, args: ["-o", "DVI-D-1"], monitor: "DVI-D-1" });
    const out = outputSize(t.pixels, 0.6);
    expect(out).toEqual({ w: 1152, h: 648 });
    expect(mapPoint(576, 324, out, t.region)).toEqual([960, 540]);
    expect(mapPoint(-5, 9999, out, t.region)).toEqual([0, 1079]); // clamped
    // Second monitor: 2560x1440 physical, scale 1.25 → 2048x1152 logical, starts at x=1920.
    const h = targetFor(ms, { monitor: "HDMI-A-1" });
    expect(h.region).toEqual({ x: 1920, y: 0, w: 2048, h: 1152 });
    const ho = outputSize(h.pixels, 0.5);
    expect(ho).toEqual({ w: 1280, h: 720 });
    expect(mapPoint(640, 360, ho, h.region)).toEqual([1920 + 1024, 576]);
    expect(unmapPoint(1920 + 1024, 576, ho, h.region)).toEqual([640, 360]);
    expect(unmapPoint(10, 10, ho, h.region)).toBeNull();
    expect(() => targetFor(ms, { monitor: "YOK" })).toThrow(AppError);
    // Rotated monitor.
    expect(monitorRegion({ ...ms[0]!, transform: 1 })).toEqual({ x: 0, y: 0, w: 1080, h: 1920 });
  });

  it("tek pencere: pencere geometrisi, ölçekli monitörde fiziksel boyut, monitöre kırpma", () => {
    const ws = parseClients(CLIENTS);
    const t = targetFor(ms, { window: ws[0] });
    expect(t.args).toEqual(["-g", "100,50 800x600"]);
    const out = outputSize(t.pixels, 0.5);
    expect(out).toEqual({ w: 400, h: 300 });
    expect(mapPoint(200, 150, out, t.region)).toEqual([500, 350]);
    const f = targetFor(ms, { window: ws[1] });
    expect(f.region).toEqual({ x: 2000, y: 100, w: 1000, h: 800 });
    expect(f.pixels).toEqual({ w: 1250, h: 1000 });
    expect(mapPoint(0, 0, outputSize(f.pixels, 1), f.region)).toEqual([2000, 100]);
    // A window overflowing the monitor is clipped.
    const over = targetFor(ms, { window: { ...ws[0]!, at: [1500, 900], size: [800, 600] } });
    expect(over.region).toEqual({ x: 1500, y: 900, w: 420, h: 180 });
    expect(outputSize({ w: 3840, h: 2160 }, 1)).toEqual({ w: 2560, h: 1440 }); // upper bound
  });

  it("wf-recorder argümanları: önce fps sonra tam sayı ölçek, sabit niceleyici", () => {
    const t = targetFor(ms, {});
    expect(wfRecorderArgs(t, { w: 1152, h: 648 }, { fps: 12, scale: 0.6, q: 70, codec: "mjpeg", kbps: 2000 })).toEqual([
      "-y", "-D", "-o", "DVI-D-1", "-c", "mjpeg", "-m", "mjpeg", "-x", "yuvj420p", "-F", "fps=12,scale=1152:648", "-p", "qmin=11", "-p", "qmax=11", "-f", "pipe:1",
    ]);
    expect([qscale(95), qscale(70), qscale(10)]).toEqual([3, 11, 28]);
    expect(wfRecorderH264Args(t, { w: 1152, h: 648 }, { fps: 30, scale: 0.6, q: 70, codec: "h264", kbps: 2000 })).toEqual([
      "-y", "-D", "-o", "DVI-D-1", "-c", "h264_nvenc", "-m", "h264", "-x", "yuv420p", "-F", "fps=30,scale=1152:648", "-b", "0",
      "-p", "preset=p1", "-p", "tune=ull", "-p", "zerolatency=1", "-p", "rc=vbr", "-p", "b=2000k", "-p", "maxrate=3000k", "-p", "g=60", "-p", "bf=0", "-f", "pipe:1",
    ]);
  });
});

describe("tuşlar ve metin", () => {
  it("izinli tuşlar ve kısayollar → ydotool key kodları", () => {
    expect(keyArgs("Enter")).toEqual(["28:1", "28:0"]);
    expect(keyArgs("F12")).toEqual(["88:1", "88:0"]);
    expect(keyArgs("C", ["ctrl"])).toEqual(["29:1", "46:1", "46:0", "29:0"]);
    expect(keyArgs("Tab", ["alt"])).toEqual(["56:1", "15:1", "15:0", "56:0"]);
    expect(keyArgs("T", ["ctrl", "shift"])).toEqual(["29:1", "42:1", "20:1", "20:0", "42:0", "29:0"]);
    expect(keyArgs("Super")).toEqual(["125:1", "125:0"]);
    expect(keyArgs("KPPlus", ["ctrl"])).toEqual(["29:1", "78:1", "78:0", "29:0"]);
    expect(keyArgs("Left", ["super", "super"])).toEqual(["125:1", "105:1", "105:0", "125:0"]);
    for (const [k, m] of [["rm -rf", []], ["constructor", []], ["__proto__", []], ["C", []], ["C", ["shift"]], ["Enter", ["hyper"]]] as const) {
      expect(() => keyArgs(k, m as never), `${k} ${m}`).toThrow(AppError);
    }
  });

  it("metin: Türkçe serbest, denetim karakteri yok; \\n ve \\t tuşa çevrilir", () => {
    expect(checkText("Merhaba ğüşıöçĞÜŞİÖÇ €")).toBe(true);
    expect(checkText("satır\nsekme\t")).toBe(true);
    for (const bad of ["", "a\u0000b", "\u001b[31m", "a\rb", "\u007f", "x".repeat(2001)]) expect(checkText(bad), JSON.stringify(bad)).toBe(false);
    expect(textPieces("ab\ncd\t\n")).toEqual([{ text: "ab" }, { key: "Enter" }, { text: "cd" }, { key: "Tab" }, { key: "Enter" }]);
  });

  it("kare başlığı", () => {
    const m = frameMessage(7, 1234.5, 1152, 648, Buffer.from([0xff, 0xd8]));
    expect([m.readUInt32BE(0), m.readDoubleBE(4), m.readUInt16BE(12), m.readUInt16BE(14), m.length]).toEqual([7, 1234.5, 1152, 648, 18]);
  });
});

describe("WS /v1/desktop/stream", () => {
  it("yetki: desktop/control kapalı, oturumsuz, yanlış belirteç, başka cihaz → yükseltme yok", async () => {
    const f = fakeIo();
    const off = await streamApp(f, {}, false);
    await expect(off.app.injectWS(`/v1/desktop/stream?token=${off.token}`, { headers: { "x-tiphys-control": "tpc_x" } })).rejects.toThrow(/403/);
    await off.app.close();

    const { app, token, auth, store, session } = await streamApp(f);
    await expect(app.injectWS(`/v1/desktop/stream`, {})).rejects.toThrow(/401/);
    await expect(app.injectWS(`/v1/desktop/stream?token=${token}`, {})).rejects.toThrow(/403/);
    const ctl = await session();
    await expect(app.injectWS(`/v1/desktop/stream?token=${token}`, { headers: { "x-tiphys-control": "tpc_yanlis" } })).rejects.toThrow(/403/);
    await expect(app.injectWS(`/v1/desktop/stream?token=${token}&fps=60`, { headers: { "x-tiphys-control": ctl } })).rejects.toThrow(/400/);
    await expect(app.injectWS(`/v1/desktop/stream?token=${token}&window=0x1;rm`, { headers: { "x-tiphys-control": ctl } })).rejects.toThrow(/400/);
    const other = newToken();
    await store.update((c) => {
      c.devices.push({ id: "tablet", name: "Tablet", tokenHash: hashToken(other), createdAt: new Date().toISOString() });
      return c;
    });
    await expect(app.injectWS(`/v1/desktop/stream?token=${other}`, { headers: { "x-tiphys-control": ctl } })).rejects.toThrow(/403/);
    expect(f.children).toHaveLength(0);
    void auth;
    await app.close();
  });

  it("odak: hello'dan sonra focus, pencere değişince yenisi; akışlar tek dinleyiciyi paylaşır, kapanınca soket kapanır", async () => {
    let active: unknown = { address: "0xb2", class: "firefox", initialClass: "firefox", title: "Ana sayfa", pid: 77, workspace: { id: 5, name: "5" } };
    const f = fakeIo({ active: () => active });
    const { app, token, session } = await streamApp(f);
    const ctl = await session();
    const c = await connect(app, `/v1/desktop/stream?token=${token}`, { "x-tiphys-control": ctl });
    const first = await until(() => c.texts.find((m) => m.type === "focus"));
    expect(c.texts.findIndex((m) => m.type === "hello")).toBeLessThan(c.texts.indexOf(first));
    expect(first).toEqual({ type: "focus", address: "0xb2", class: "firefox", initialClass: "firefox", title: "Ana sayfa", pid: 77, workspace: 5, appId: null });
    const sock = await until(() => f.sockets[0]);
    expect(sock.path).toBe("hypr/sig/.socket2.sock");
    active = { address: "0xa1", class: "kitty", initialClass: "kitty", title: "~", pid: 78, workspace: { id: 1, name: "1" } };
    sock.lines("activewindow>>kitty,~", "activewindowv2>>a1");
    expect(await until(() => c.texts.filter((m) => m.type === "focus")[1])).toMatchObject({ address: "0xa1", class: "kitty", title: "~" });
    c.ws.terminate();
    await until(() => sock.destroyed);
    expect(f.sockets).toHaveLength(1);
    // A new connection opens a new listener; it closes too when the agent shuts down.
    const d = await connect(app, `/v1/desktop/stream?token=${token}`, { "x-tiphys-control": ctl });
    expect(await until(() => d.texts.find((m) => m.type === "focus"))).toMatchObject({ class: "kitty" });
    const sock2 = await until(() => f.sockets[1]);
    await app.close();
    expect(sock2.destroyed).toBe(true);
  });

  it("kareler: hello, başlıklı JPEG, aynı kare atlanır, kalite değişince süreç yeniden başlar, kapanınca süreç ölür", async () => {
    const f = fakeIo({ cursor: { x: 960, y: 540 } });
    const { app, token, session } = await streamApp(f);
    const ctl = await session();
    const c = await connect(app, `/v1/desktop/stream?token=${token}&fps=10&scale=0.5&q=80`, { "x-tiphys-control": ctl });
    const hello = await until(() => c.texts.find((m) => m.type === "hello"));
    expect(hello).toMatchObject({ width: 960, height: 540, region: { x: 0, y: 0, w: 1920, h: 1080 }, fps: 10, source: "wf-recorder", cursor: { x: 480, y: 270 } });
    const child = await until(() => f.children[0]);
    expect(child.args).toEqual(["-y", "-D", "-o", "DVI-D-1", "-c", "mjpeg", "-m", "mjpeg", "-x", "yuvj420p", "-F", "fps=10,scale=960:540", "-p", "qmin=8", "-p", "qmax=8", "-f", "pipe:1"]);
    const a = jpeg(1, 500);
    const b = jpeg(2, 500);
    // Two frames in one chunk and one frame split in two; the same frame repeated in between.
    child.stdout.write(Buffer.concat([a, a]));
    child.stdout.write(b.subarray(0, 100));
    child.stdout.write(b.subarray(100));
    await until(() => c.frames.length >= 2);
    await new Promise((r) => setTimeout(r, 30));
    expect(c.frames.map((x) => [x.seq, x.w, x.h, x.jpeg.length])).toEqual([
      [1, 960, 540, a.length],
      [2, 960, 540, b.length],
    ]);
    expect(c.frames[1]!.jpeg.equals(b)).toBe(true);

    c.send({ type: "ping", t: 42 });
    expect(await until(() => c.texts.find((m) => m.type === "pong"))).toMatchObject({ t: 42 });

    c.send({ type: "quality", fps: 5, scale: 0.25, q: 40 });
    const second = await until(() => f.children[1]);
    expect(child.alive).toBe(false);
    expect(second.args).toContain("fps=5,scale=480:270");
    expect(second.args).toContain("qmin=19");
    expect(await until(() => c.texts.filter((m) => m.type === "hello")[1])).toMatchObject({ width: 480, height: 270 });
    // After a restart the same frame is sent again (so the client gets the new size).
    second.stdout.write(b);
    await until(() => c.frames.length === 3);
    expect(c.frames[2]).toMatchObject({ seq: 3, w: 480, h: 270 });
    c.send({ type: "quality", fps: 99 });
    expect(await until(() => c.texts.find((m) => m.type === "error"))).toMatchObject({ code: "agent.request.invalid" });

    c.ws.terminate();
    await until(() => !second.alive);
    expect(f.children.every((x) => !x.alive)).toBe(true);
    await app.close();
  });

  it("art arda kalite değişikliği yetim süreç bırakmaz; kopunca basılı fare düğmesi bırakılır", async () => {
    const f = fakeIo({ envDelayMs: 20 });
    const { app, token, session } = await streamApp(f);
    const ctl = await session();
    const c = await connect(app, `/v1/desktop/stream?token=${token}&fps=10&scale=0.5&q=80`, { "x-tiphys-control": ctl });
    await until(() => f.children[0]);
    c.send({ type: "quality", fps: 5 });
    c.send({ type: "quality", fps: 6 });
    c.send({ type: "quality", fps: 7 });
    await until(() => c.texts.filter((m) => m.type === "hello").length === 4);
    await new Promise((r) => setTimeout(r, 60));
    expect(f.children.filter((x) => x.alive)).toHaveLength(1);
    expect(f.children.find((x) => x.alive)!.args).toContain("fps=7,scale=960:540");
    c.send({ type: "down", button: "left" });
    await until(() => f.inputs.some((i) => i.cmd === "ydotool" && i.args.join(" ") === "click 0x40"));
    c.ws.terminate();
    await until(() => f.inputs.some((i) => i.cmd === "ydotool" && i.args.join(" ") === "click 0x80"));
    await until(() => f.children.every((x) => !x.alive));
    await app.close();
  });

  it("geri basınç: soket tamponu doluyken kare kuyruğa alınmaz, atlanır", async () => {
    const f = fakeIo();
    const { app, token, session } = await streamApp(f, { maxBuffered: -1, statsMs: 20 });
    const c = await connect(app, `/v1/desktop/stream?token=${token}`, { "x-tiphys-control": await session() });
    const child = await until(() => f.children[0]);
    for (let i = 0; i < 5; i++) child.stdout.write(jpeg(i + 1, 50));
    const stats = await until(() => c.texts.find((m) => m.type === "stats" && (m.dropped as number) > 0));
    expect(stats).toMatchObject({ sent: 0, dropped: 5 });
    expect(c.frames).toHaveLength(0);
    c.ws.terminate();
    await until(() => !child.alive);
    await app.close();
  });

  it("temizlik: oturum durdurulunca / süresi dolunca / ajan kapanınca süreç ölür; SIGTERM'e uymayan SIGKILL alır", async () => {
    let t = 1_000_000;
    const f = fakeIo({ ignoreTerm: true });
    const { app, token, auth, session } = await streamApp(f, { now: () => t });
    // 1) stop via DELETE
    const c1 = await connect(app, `/v1/desktop/stream?token=${token}`, { "x-tiphys-control": await session() });
    const p1 = await until(() => f.children[0]);
    await app.inject({ method: "DELETE", url: "/v1/desktop/control/session", headers: auth });
    await until(() => !p1.alive);
    expect(p1.signals).toEqual(["SIGTERM", "SIGKILL"]);
    await until(() => c1.closed() === 4401);

    // 2) expiry (expireIfDue: without waiting for the timer)
    const ctl = await session();
    const c2 = await connect(app, `/v1/desktop/stream?token=${token}`, { "x-tiphys-control": ctl });
    const p2 = await until(() => f.children[1]);
    t += 16 * 60_000;
    // An input event surfaces the expired session.
    c2.send({ type: "move", x: 1, y: 1 });
    await until(() => !p2.alive);
    await until(() => c2.closed() === 4401);

    // 3) when the same device reconnects, the old stream closes (one stream per session)
    const ctl3 = await session();
    const c3 = await connect(app, `/v1/desktop/stream?token=${token}`, { "x-tiphys-control": ctl3 });
    const p3 = await until(() => f.children[2]);
    const c4 = await connect(app, `/v1/desktop/stream?token=${token}`, { "x-tiphys-control": ctl3 });
    await until(() => !p3.alive);
    await until(() => c3.closed() === 4409);
    const p4 = await until(() => f.children[3]);
    expect(p4.alive).toBe(true);

    // 4) agent shutdown
    await app.close();
    expect(p4.alive).toBe(false);
    void c4;
  });

  it("wf-recorder yoksa ya da kare veremeden biterse grim yedeği (en çok 4 fps) ve uyarı", async () => {
    const f = fakeIo({ noRecorder: true });
    const { app, token, session } = await streamApp(f, { grimMaxFps: 4 });
    const c = await connect(app, `/v1/desktop/stream?token=${token}&fps=12`, { "x-tiphys-control": await session() });
    expect(await until(() => c.texts.find((m) => m.type === "notice"))).toMatchObject({ code: "agent.desktop.streamFallback", fps: 4 });
    await until(() => c.frames.length >= 1);
    expect(c.texts.filter((m) => m.type === "hello").at(-1)).toMatchObject({ source: "grim", fps: 4 });
    expect(f.children).toHaveLength(0);
    c.ws.terminate();
    await app.close();

    const g = fakeIo();
    const s2 = await streamApp(g);
    const d = await connect(s2.app, `/v1/desktop/stream?token=${s2.token}`, { "x-tiphys-control": await s2.session() });
    const child = await until(() => g.children[0]);
    child.stderr.write("failed to bind screencopy\n");
    child.exit(1);
    expect(await until(() => d.texts.find((m) => m.type === "notice"))).toMatchObject({ code: "agent.desktop.streamFallback" });
    await until(() => d.frames.length >= 1);
    d.ws.terminate();
    await s2.app.close();
  });

  it("tek pencere: görünmeyen pencere 409, görünen pencerenin bölgesi", async () => {
    const f = fakeIo({ cursor: { x: 500, y: 350 } });
    const { app, token, session } = await streamApp(f);
    const ctl = await session();
    const hidden = await connect(app, `/v1/desktop/stream?token=${token}&window=0xc3`, { "x-tiphys-control": ctl });
    expect(await until(() => hidden.texts.find((m) => m.type === "error"))).toMatchObject({ code: "agent.desktop.windowNotVisible" });
    await until(() => hidden.closed() === 4400);
    const c = await connect(app, `/v1/desktop/stream?token=${token}&window=0xa1&scale=1`, { "x-tiphys-control": ctl });
    expect(await until(() => c.texts.find((m) => m.type === "hello"))).toMatchObject({ width: 800, height: 600, region: { x: 100, y: 50, w: 800, h: 600 }, cursor: { x: 400, y: 300 } });
    expect((await until(() => f.children[0])).args).toContain("100,50 800x600");
    c.send({ type: "move", x: 400, y: 300 });
    await until(() => f.inputs.length);
    expect(f.inputs[0]).toEqual({ cmd: "hyprctl", args: ["dispatch", "movecursor", "500", "350"] });
    c.ws.terminate();
    await app.close();

    // Lua config: the mode is probed once, the cursor is moved with hl.dsp.cursor.move (the PC indicator via hl.config
    // too).
    const g = fakeIo({ lua: true });
    const s2 = await streamApp(g);
    const d = await connect(s2.app, `/v1/desktop/stream?token=${s2.token}&scale=1`, { "x-tiphys-control": await s2.session() });
    await until(() => d.texts.find((m) => m.type === "hello"));
    d.send({ type: "move", x: 10, y: 20 });
    d.send({ type: "click", x: 30, y: 40 });
    await until(() => g.inputs.length >= 3);
    expect(g.inputs.map((x) => x.args.join(" "))).toEqual(["eval hl.dispatch(hl.dsp.cursor.move({ x = 10, y = 20 }))", "eval hl.dispatch(hl.dsp.cursor.move({ x = 30, y = 40 }))", "click 0xc0"]);
    expect(g.execs.filter((e) => e === "hyprctl eval return 1")).toHaveLength(1);
    expect(d.texts.filter((m) => m.type === "error")).toEqual([]);
    d.ws.terminate();
    await s2.app.close();
  });

  it("giriş: hareket (birleştirme), tık, sürükle, teker, tuş, metin; geçersizler reddedilir; hız sınırı", async () => {
    let t = 5_000_000;
    const f = fakeIo();
    const { app, token, session } = await streamApp(f, { now: () => t, inputLimit: new RateLimit(60, 1000, () => t) });
    const c = await connect(app, `/v1/desktop/stream?token=${token}&scale=0.5`, { "x-tiphys-control": await session() });
    await until(() => c.texts.find((m) => m.type === "hello"));
    const sent = [
      { type: "click", x: 100, y: 50 },
      { type: "click", button: "right" },
      { type: "click", count: 2 },
      { type: "down" },
      { type: "move", x: 200, y: 100 },
      { type: "up" },
      { type: "scroll", dy: 3 },
      { type: "scroll", dx: -2 },
      { type: "key", key: "C", mods: ["ctrl"] },
      { type: "key", key: "Esc" },
      { type: "text", text: "Çağrı ğüş\nyeni" },
      { type: "move", x: 960, y: 540, w: 1920, h: 1080 }, // with the previous frame size
    ];
    for (const m of sent) c.send(m);
    await until(() => f.inputs.some((x) => x.args.join(" ") === "dispatch movecursor 960 540"));
    expect(f.inputs.map((x) => (x.input !== undefined ? `${x.cmd} ${x.args.join(" ")} <${x.input}>` : `${x.cmd} ${x.args.join(" ")}`))).toEqual([
      "hyprctl dispatch movecursor 200 100",
      "ydotool click 0xc0",
      "ydotool click 0xc1",
      "ydotool click -r 2 -D 60 0xc0",
      "ydotool click 0x40",
      "hyprctl dispatch movecursor 400 200",
      "ydotool click 0x80",
      "ydotool mousemove -w -x 0 -y -3",
      "ydotool mousemove -w -x -2 -y 0",
      "ydotool key 29:1 46:1 46:0 29:0",
      "ydotool key 1:1 1:0",
      "wtype - <Çağrı ğüş>",
      "ydotool key 28:1 28:0",
      "wtype - <yeni>",
      "hyprctl dispatch movecursor 960 540",
    ]);

    // Invalid ones: no command runs, an error message arrives.
    const before = f.inputs.length;
    for (const bad of [{ type: "key", key: "rm" }, { type: "key", key: "A" }, { type: "text", text: "a\u001bb" }, { type: "click", button: "side" }, { type: "exec", cmd: "ls" }]) c.send(bad);
    await until(() => c.texts.filter((m) => m.type === "error").length >= 5);
    expect(c.texts.filter((m) => m.type === "error").map((m) => m.code)).toEqual(["agent.desktop.badKey", "agent.desktop.badKey", "agent.desktop.badText", "agent.request.invalid", "agent.request.invalid"]);
    expect(f.inputs.length).toBe(before);

    // Rate limit: 60 events per second (the ones above used 12 events in the same second).
    for (let i = 0; i < 60; i++) c.send({ type: "key", key: "Esc" });
    await until(() => c.texts.some((m) => m.code === "agent.control.rateLimited"));
    await new Promise((r) => setTimeout(r, 50));
    expect(f.inputs.filter((x) => x.args.join(" ") === "key 1:1 1:0").length).toBe(1 + 48);
    t += 1000;
    c.send({ type: "key", key: "Tab" });
    await until(() => f.inputs.some((x) => x.args.join(" ") === "key 15:1 15:0"));
    c.ws.terminate();
    await app.close();
  });
  it("giriş: wait olayı sırayı ajanda korur (ctrl+shift+p → bekle → metin); 1000 ms üstü reddedilir", async () => {
    const f = fakeIo();
    const { app, token, session } = await streamApp(f);
    const c = await connect(app, `/v1/desktop/stream?token=${token}&scale=0.5`, { "x-tiphys-control": await session() });
    await until(() => c.texts.find((m) => m.type === "hello"));
    c.send({ type: "key", key: "P", mods: ["ctrl", "shift"] });
    c.send({ type: "wait", ms: 150 });
    c.send({ type: "text", text: "Terminal" });
    await until(() => f.inputs.some((x) => x.cmd === "ydotool"));
    const t1 = Date.now();
    expect(f.inputs.some((x) => x.cmd === "wtype")).toBe(false); // no text typed while the wait was ongoing
    await until(() => f.inputs.some((x) => x.cmd === "wtype"));
    expect(Date.now() - t1).toBeGreaterThanOrEqual(100);
    expect(f.inputs.map((x) => (x.input !== undefined ? `${x.cmd} <${x.input}>` : `${x.cmd} ${x.args.join(" ")}`))).toEqual(["ydotool key 29:1 42:1 25:1 25:0 42:0 29:0", "wtype <Terminal>"]);
    for (const bad of [{ type: "wait", ms: 1001 }, { type: "wait", ms: -1 }, { type: "wait", ms: 1.5 }, { type: "wait" }]) c.send(bad);
    await until(() => c.texts.filter((m) => m.type === "error").length >= 4);
    expect(c.texts.filter((m) => m.type === "error").map((m) => m.code)).toEqual(Array(4).fill("agent.request.invalid"));
    c.ws.terminate();
    await app.close();
  });
  describe("H.264", () => {
    const SPS = Buffer.from([0x67, 0x64, 0x00, 0x1f, 0xac, 0xd9, 0x40, 0x48]);
    const PPS = Buffer.from([0x68, 0xee, 0x3c, 0x80]);
    const IDR = Buffer.from([0x65, 0x88, 0x84, 0x5a, 0x5a, 0x80]);
    const P = (tag: number) => Buffer.from([0x41, 0x9a, tag, tag, 0x40]);

    it("codec=h264: nvenc argümanları, IDR'den önce SPS+PPS, IDR'siz başlangıç beklenir, anahtar kare isteği süreci yeniler", async () => {
      let t = 1_000_000;
      const f = fakeIo();
      const { app, token, session } = await streamApp(f, { statsMs: 30, now: () => t });
      const c = await connect(app, `/v1/desktop/stream?token=${token}&codec=h264&fps=30&scale=0.6&kbps=1500`, { "x-tiphys-control": await session() });
      expect(await until(() => c.texts.find((m) => m.type === "hello"))).toMatchObject({ codec: "h264", kbps: 1500, fps: 30, width: 1152, height: 648 });
      const child = await until(() => f.children[0]);
      expect(child.args).toContain("h264_nvenc");
      expect(child.args).toContain("b=1500k");
      // No P-frame is sent before an IDR arrives.
      child.stdout.write(annexB([P(1)]));
      await new Promise((r) => setTimeout(r, 20));
      // AUD + SPS + PPS + IDR in one chunk; a P-frame split in two (ends with silence).
      child.stdout.write(annexB([Buffer.from([0x09, 0xf0]), SPS, PPS, IDR]));
      await until(() => c.frames.length >= 2);
      const p2 = annexB([P(2)]);
      child.stdout.write(p2.subarray(0, 3));
      child.stdout.write(p2.subarray(3));
      await until(() => c.frames.length >= 3);
      expect(c.frames.map((x) => [x.flags, x.w, x.h])).toEqual([[0x12, 1152, 648], [0x11, 1152, 648], [0x10, 1152, 648]]);
      expect(c.frames[0]!.jpeg).toEqual(annexB([SPS, PPS]));
      expect(c.frames[1]!.jpeg).toEqual(annexB([IDR]));
      expect(c.frames[2]!.jpeg).toEqual(p2);
      expect(c.frames.map((x) => x.seq)).toEqual([1, 2, 3]);
      const stats = await until(() => c.texts.find((m) => m.type === "stats" && (m.waited as number) > 0));
      expect(stats).toMatchObject({ codec: "h264", waited: 1 });

      // If an IDR just went out (newly connected client), the request is ignored: the process keeps running, P-frames
      // keep flowing.
      c.send({ type: "keyframe" });
      await new Promise((r) => setTimeout(r, 20));
      child.stdout.write(annexB([P(9)]));
      await until(() => c.frames.length === 4);
      expect(f.children).toHaveLength(1);
      c.frames.pop();
      // Keyframe request: the next IDR is ~1 s away → the process restarts; no P-frame goes out until the new IDR.
      t += 1000;
      c.send({ type: "keyframe" });
      const second = await until(() => f.children[1]);
      expect(child.alive).toBe(false);
      second.stdout.write(annexB([P(3)]));
      await new Promise((r) => setTimeout(r, 20));
      expect(c.frames).toHaveLength(3);
      second.stdout.write(annexB([SPS, PPS, IDR]));
      await until(() => c.frames.length === 5);
      expect(c.frames.slice(3).map((x) => x.flags)).toEqual([0x12, 0x11]);
      // Second request: no restart before 3 s have passed.
      t += 600;
      c.send({ type: "keyframe" });
      await new Promise((r) => setTimeout(r, 30));
      expect(f.children).toHaveLength(2);
      // When the bitrate changes the process restarts; the MJPEG-specific fps limit is not applied.
      c.send({ type: "quality", kbps: 800, fps: 24 });
      const third = await until(() => f.children[2]);
      expect(third.args).toContain("b=800k");
      expect(third.args).toContain("fps=24,scale=1152:648");
      // The client switches to JPEG (decoder error): MJPEG on the same connection, fps upper limit 20.
      c.send({ type: "quality", codec: "mjpeg", fps: 30 });
      const fourth = await until(() => f.children[3]);
      expect(fourth.args).toContain("mjpeg");
      expect(fourth.args).toContain("fps=20,scale=1152:648");
      expect(await until(() => c.texts.filter((m) => m.type === "hello")[3])).toMatchObject({ codec: "mjpeg" });
      c.ws.terminate();
      await until(() => !fourth.alive);
      await app.close();
    });

    it("geri basınç: tıkanınca IDR dahil atlanır", async () => {
      const f = fakeIo();
      const { app, token, session } = await streamApp(f, { maxBuffered: -1, statsMs: 20 });
      const c = await connect(app, `/v1/desktop/stream?token=${token}&codec=h264`, { "x-tiphys-control": await session() });
      const child = await until(() => f.children[0]);
      child.stdout.write(annexB([SPS, PPS, IDR]));
      await new Promise((r) => setTimeout(r, 10));
      child.stdout.write(annexB([P(1)]));
      expect(await until(() => c.texts.find((m) => m.type === "stats" && (m.dropped as number) >= 2))).toMatchObject({ sent: 0 });
      expect(c.frames).toHaveLength(0);
      c.ws.terminate();
      await app.close();
    });

    it("yedek: anahtar kare süresinde gelmezse ya da süreç kare vermeden biterse MJPEG'e geçilir", async () => {
      const f = fakeIo();
      const { app, token, session } = await streamApp(f, { h264StartMs: 40 });
      const c = await connect(app, `/v1/desktop/stream?token=${token}&codec=h264&fps=30`, { "x-tiphys-control": await session() });
      const child = await until(() => f.children[0]);
      child.stdout.write(annexB([P(1)])); // no IDR
      expect(await until(() => c.texts.find((m) => m.type === "notice"))).toMatchObject({ code: "agent.desktop.codecFallback", codec: "mjpeg" });
      const mj = await until(() => f.children[1]);
      expect(child.alive).toBe(false);
      expect(mj.args).toContain("mjpeg");
      expect(mj.args).toContain("fps=20,scale=1152:648"); // MJPEG upper limit
      expect(await until(() => c.texts.filter((m) => m.type === "hello")[1])).toMatchObject({ codec: "mjpeg", source: "wf-recorder" });
      mj.stdout.write(jpeg(1, 10));
      await until(() => c.frames.length === 1);
      expect(c.frames[0]!.flags).toBe(0);
      c.ws.terminate();
      await app.close();

      const g = fakeIo();
      const s2 = await streamApp(g);
      const d = await connect(s2.app, `/v1/desktop/stream?token=${s2.token}&codec=h264`, { "x-tiphys-control": await s2.session() });
      const h = await until(() => g.children[0]);
      h.stderr.write("[h264_nvenc] OpenEncodeSessionEx failed: unsupported device\n");
      h.exit(1);
      expect(await until(() => d.texts.find((m) => m.type === "notice"))).toMatchObject({ code: "agent.desktop.codecFallback" });
      expect((await until(() => g.children[1])).args).toContain("mjpeg");
      d.ws.terminate();
      await s2.app.close();

      // If wf-recorder is missing entirely, grim (MJPEG) + two warnings.
      const n = fakeIo({ noRecorder: true });
      const s3 = await streamApp(n);
      const e = await connect(s3.app, `/v1/desktop/stream?token=${s3.token}&codec=h264`, { "x-tiphys-control": await s3.session() });
      await until(() => e.texts.filter((m) => m.type === "notice").length >= 2);
      expect(e.texts.filter((m) => m.type === "notice").map((m) => m.code)).toEqual(["agent.desktop.codecFallback", "agent.desktop.streamFallback"]);
      expect(e.texts.filter((m) => m.type === "hello").at(-1)).toMatchObject({ codec: "mjpeg", source: "grim" });
      e.ws.terminate();
      await s3.app.close();
    });
  });
});
