// Live screen (10.2 Phase A, "desktop" + "control" + an open control session): WS /v1/desktop/stream.
// Video: wf-recorder (wlr-screencopy) produces MJPEG directly → JPEG frames are split out → each frame is a binary
// message with a small header. Lowest-latency setup measured on argo, one process: `wf-recorder -D -F "fps=N,scale=W:H" -c mjpeg
// -m mjpeg -f pipe:1` (first frame ~110 ms, steady stream at the requested fps, output not buffered). Piping to
// ffmpeg is unnecessary: wf-recorder's own filter scales. Notes:
// - -D (continuous capture without waiting for damage) is required: in damage mode the first frame never arrives on
//   a static screen, and the fps filter also holds the last change until the next one. Since capture runs at the
//   refresh rate, the filter applies fps first, then scale (otherwise every captured frame is scaled, CPU 120% → 30%).
// - A scale expression (iw*0.6) produces no frames in wf-recorder; the size is computed and passed as integers.
// - Quality: for mjpeg, -p qmin=Q -p qmax=Q (2 best … 31 worst).
// Identical consecutive frames (static screen) are not sent (SHA-1). If the socket buffer is full the frame is not
// queued but skipped; the client changes fps/scale/quality with {type:"quality"} (the process restarts). If wf-recorder
// is missing or exits without producing any frame, fallback: a grim loop (at most 4 fps) + a warning to the client.
// Input (same WS, JSON): cursor via the hyprctl.ts adapter (classic `movecursor`, Lua `hl.dsp.cursor.move`;
// image coordinate → global logical coordinate),
// click/wheel `ydotool`, special keys `ydotool key` (allowed key table), text `wtype` (stdin; Turkish characters).
// Every event re-validates the session token, limited to 60 events per second per session. No shell: all commands
// use argument arrays. Keystrokes and text are never written anywhere.
// H.264 (10.2 Phase C, `codec=h264`): `wf-recorder -c h264_nvenc -m h264` raw Annex-B → access units (../h264.ts)
// → each frame is one binary message (header flag: h264/key/config). Before every IDR, SPS+PPS go as a separate
// "config" message. GOP 2 s, no B-frames; if the client requests a keyframe and the next IDR is far off, the process
// restarts (NVENC can't be forced to emit an IDR externally; a restart takes ~200 ms). When a frame is skipped under
// backpressure, no frame goes out until the next IDR. If the process can't produce a keyframe within [h264StartMs]
// (no nvenc, driver, etc.): `notice agent.desktop.codecFallback` + switch to MJPEG.
// App context (11): after hello and whenever the focused window changes, `{type:"focus", address, class,
// initialClass, title, pid, workspace, appId}` is sent (one Hyprland event listener per agent, ../focus.ts).
// Child processes are killed when the WS closes, when the session ends (expiry/stop/token refresh) and when the agent
// shuts down (SIGTERM, SIGKILL 1 s later). If the agent crashes, wf-recorder exits by itself on the broken pipe (SIGPIPE).
import { spawn } from "node:child_process";
import { createHash } from "node:crypto";
import type { Readable } from "node:stream";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { RateLimit, requireControlFeature, tokenOf, type ControlSessions } from "../control.ts";
import { AppError } from "../errors.ts";
import { FocusWatcher, realConnect, type EventSocket } from "../focus.ts";
import { AccessUnitParser, FRAME, KeyGate, annexB, frameHeader, type AccessUnit } from "../h264.ts";
import { Hyprctl } from "../hyprctl.ts";
import type { Ctx } from "../server.ts";
import { ADDRESS, isVisible, parseClients, parseMonitors, realHyprIo, type HyprIo, type HyprWindow } from "./hypr.ts";
import {
  checkText,
  inputEvent,
  keyArgs,
  mapPoint,
  outputSize,
  runInput as runInputShared,
  targetFor,
  unmapPoint,
  type InputEvent,
  type InputIo,
  type StreamTarget,
} from "../desktop_input.ts";

// ---- JPEG frame splitter ----

/**
 * Extracts complete JPEG frames from the stream: after SOI (FFD8) segments are skipped by their lengths, after SOS
 * FF00 / RSTn are passed over in the entropy data, EOI (FFD9) ends the frame. Chunk boundaries may fall anywhere;
 * garbage before SOI and corrupt frames are dropped, a partial frame exceeding [maxFrame] is abandoned.
 */
export class JpegSplitter {
  #buf: Buffer = Buffer.alloc(0);
  readonly maxFrame: number;
  /** Number of dropped corrupt/oversized frames (for tests and stats). */
  discarded = 0;

  constructor(maxFrame = 8 * 1024 * 1024) {
    this.maxFrame = maxFrame;
  }

  push(chunk: Buffer): Buffer[] {
    this.#buf = this.#buf.length ? Buffer.concat([this.#buf, chunk]) : chunk;
    const out: Buffer[] = [];
    for (;;) {
      const b = this.#buf;
      const soi = findSoi(b);
      if (soi < 0) {
        // A trailing FF or FF D8 may be the start of an SOI in the next chunk.
        const n = b.length;
        const keep = n >= 2 && b[n - 2] === 0xff && b[n - 1] === 0xd8 ? 2 : n >= 1 && b[n - 1] === 0xff ? 1 : 0;
        this.#buf = b.subarray(n - keep);
        break;
      }
      const end = jpegEnd(b, soi);
      if (end === -1) {
        if (b.length - soi > this.maxFrame) {
          this.discarded++;
          this.#buf = b.subarray(soi + 2);
          continue;
        }
        this.#buf = b.subarray(soi);
        break;
      }
      if (end === -2) {
        this.discarded++;
        this.#buf = b.subarray(soi + 2);
        continue;
      }
      out.push(Buffer.from(b.subarray(soi, end)));
      this.#buf = b.subarray(end);
    }
    return out;
  }
}

function findSoi(b: Buffer): number {
  let i = b.indexOf(0xff);
  while (i >= 0 && i + 2 < b.length) {
    if (b[i + 1] === 0xd8 && b[i + 2] === 0xff) return i;
    i = b.indexOf(0xff, i + 1);
  }
  return -1;
}

/** Position where the frame ends (including EOI); -1 incomplete, -2 corrupt. */
function jpegEnd(b: Buffer, soi: number): number {
  let i = soi + 2;
  for (;;) {
    if (i + 1 >= b.length) return -1;
    if (b[i] !== 0xff) return -2;
    const m = b[i + 1]!;
    if (m === 0xff) {
      i++; // dolgu
      continue;
    }
    if (m === 0xd9) return i + 2;
    if (m === 0xd8 || m === 0x00) return -2;
    if ((m >= 0xd0 && m <= 0xd7) || m === 0x01) {
      i += 2;
      continue;
    }
    if (i + 3 >= b.length) return -1;
    const len = b.readUInt16BE(i + 2);
    if (len < 2) return -2;
    i += 2 + len;
    if (m !== 0xda) continue;
    // Entropy data: up to the next real marker.
    for (;;) {
      const j = b.indexOf(0xff, i);
      if (j < 0 || j + 1 >= b.length) return -1;
      const n = b[j + 1]!;
      if (n === 0x00 || (n >= 0xd0 && n <= 0xd7)) {
        i = j + 2;
        continue;
      }
      if (n === 0xff) {
        i = j + 1;
        continue;
      }
      i = j; // EOI or (in a progressive/multi-scan JPEG) the next segment
      break;
    }
  }
}

// Coordinate conversion, key table, text validation and input commands are shared with Claude's PC tools
// (../desktop_input.ts): a single code path.
export {
  KEYS,
  MODS,
  TEXT_OK,
  checkText,
  inputEvent,
  keyArgs,
  mapPoint,
  monitorRegion,
  outputSize,
  targetFor,
  textPieces,
  unmapPoint,
  type InputEvent,
  type Mod,
  type Region,
  type StreamTarget,
} from "../desktop_input.ts";

/** Client quality (10–95, JPEG-like) → mjpeg quantizer (2 best … 31). */
export function qscale(q: number): number {
  return Math.min(31, Math.max(2, Math.round(2 + (100 - q) * 0.29)));
}

export type Codec = "mjpeg" | "h264";

export interface StreamParams {
  fps: number;
  scale: number;
  q: number;
  codec: Codec;
  /** H.264 target bitrate (kbit/s). */
  kbps: number;
}

/** fps cap for MJPEG (CPU); H.264 up to 30. */
export const MJPEG_MAX_FPS = 20;

export function wfRecorderArgs(t: StreamTarget, out: { w: number; h: number }, p: StreamParams): string[] {
  const qs = String(qscale(p.q));
  return ["-y", "-D", ...t.args, "-c", "mjpeg", "-m", "mjpeg", "-x", "yuvj420p", "-F", `fps=${p.fps},scale=${out.w}:${out.h}`, "-p", `qmin=${qs}`, "-p", `qmax=${qs}`, "-f", "pipe:1"];
}

/**
 * Lowest-latency NVENC setup (argo, GTX 1050 Ti, driver 580): p1 + ull + zerolatency, no B-frames, GOP 2 s.
 * VBR: on a static screen P-frames are ~200 bytes (CBR fills the gap with padding bits and uses 3-4x the bandwidth).
 * Scaling on the CPU (wf-recorder's filter output wants a software format; hwupload_cuda/scale_cuda are rejected).
 */
export function wfRecorderH264Args(t: StreamTarget, out: { w: number; h: number }, p: StreamParams): string[] {
  const kbps = Math.round(p.kbps);
  return [
    "-y", "-D", ...t.args, "-c", "h264_nvenc", "-m", "h264", "-x", "yuv420p", "-F", `fps=${p.fps},scale=${out.w}:${out.h}`, "-b", "0",
    "-p", "preset=p1", "-p", "tune=ull", "-p", "zerolatency=1", "-p", "rc=vbr", "-p", `b=${kbps}k`, "-p", `maxrate=${Math.round(kbps * 1.5)}k`,
    "-p", `g=${p.fps * 2}`, "-p", "bf=0", "-f", "pipe:1",
  ];
}

const qualityMsg = z.object({
  type: z.literal("quality"),
  fps: z.number().int().min(1).max(30).optional(),
  scale: z.number().min(0.25).max(1).optional(),
  q: z.number().int().min(10).max(95).optional(),
  kbps: z.number().int().min(100).max(20_000).optional(),
  codec: z.enum(["mjpeg", "h264"]).optional(),
});

// ---- outside world ----

export interface StreamChild {
  stdout: Readable | null;
  stderr: Readable | null;
  pid?: number;
  exitCode: number | null;
  signalCode: NodeJS.Signals | null;
  kill(signal?: NodeJS.Signals): boolean;
  on(ev: "exit", fn: (code: number | null, signal: NodeJS.Signals | null) => void): unknown;
  on(ev: "error", fn: (e: Error) => void): unknown;
}

export interface StreamIo extends HyprIo, InputIo {
  spawn(cmd: string, args: string[], env: NodeJS.ProcessEnv): StreamChild;
  /** Hyprland event socket (focus notifications). */
  connect(path: string): EventSocket;
}

export const realStreamIo: StreamIo = {
  ...realHyprIo,
  spawn: (cmd, args, env) => spawn(cmd, args, { env, stdio: ["ignore", "pipe", "pipe"] }),
  connect: realConnect,
  inputEnv: async () => {
    const env = await realHyprIo.screenEnv();
    const runtime = env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.() ?? 1000}`;
    return { ...env, YDOTOOL_SOCKET: process.env.YDOTOOL_SOCKET ?? `${runtime}/.ydotool_socket` };
  },
};

// ---- stream ----

/** The WebSocket surface used (ws). */
export interface WebSocket {
  readonly readyState: number;
  readonly bufferedAmount: number;
  send(data: string | Buffer): void;
  close(code?: number, reason?: string): void;
}

/**
 * Binary frame: 16-byte header (u8 flag, u24 seq, f64 time ms, u16 width, u16 height; big endian) + data. Flag 0 =
 * JPEG (same as the old u32-seq header); for H.264, FRAME.h264 | key | config (../h264.ts).
 */
export function frameMessage(seq: number, ts: number, w: number, h: number, data: Buffer, flags = 0): Buffer {
  return Buffer.concat([frameHeader(flags, seq, ts, w, h), data]);
}

export interface StreamOpts {
  now?: () => number;
  /** If the socket buffer exceeds this, the frame is skipped. */
  maxBuffered?: number;
  /** Input events (per session). */
  inputLimit?: RateLimit;
  /** Token re-validation interval. */
  recheckMs?: number;
  killGraceMs?: number;
  grimMaxFps?: number;
  statsMs?: number;
  /** If the H.264 process can't produce a keyframe within this time, switch to MJPEG. */
  h264StartMs?: number;
  /** When the stream goes quiet this long, the pending frame is considered complete (see ../h264.ts). */
  h264FlushMs?: number;
  /** Focus listener (default: a new one via io). */
  focus?: FocusWatcher;
}

interface Proc {
  child: StreamChild;
  exited: Promise<void>;
}

/**
 * `tiphys-desktop stream` arguments (desktop-helper/PROTOCOL.md): [t.args] holds `--monitor ID [--region x,y,w,h]`; the
 * helper scales to the output width and uses the same MJPEG quantizer scale.
 */
export function helperStreamArgs(t: StreamTarget, out: { w: number; h: number }, p: StreamParams): string[] {
  return ["stream", ...t.args, "--fps", String(p.fps), "--max-width", String(out.w), "--quality", String(qscale(p.q))];
}

/** `tiphys-desktop stream` exit codes → error codes for the client. */
const HELPER_STREAM_EXIT: Record<number, string> = { 3: "agent.desktop.permission", 4: "agent.desktop.monitorNotFound", 5: "agent.desktop.unsupported" };

/**
 * A single live stream: source process(es), frame sending, stats. Sources: wf-recorder (Hyprland; grim fallback) or,
 * with [helper] set, `tiphys-desktop stream` (other desktops; MJPEG only, no fallback).
 */
export class LiveStream {
  readonly socket: WebSocket;
  readonly io: StreamIo;
  readonly opts: Required<Pick<StreamOpts, "maxBuffered" | "killGraceMs" | "grimMaxFps" | "statsMs" | "h264StartMs" | "h264FlushMs">> & { now: () => number };
  readonly log: (msg: string, err?: unknown) => void;
  target: StreamTarget;
  params: StreamParams;
  out: { w: number; h: number };
  source: "wf-recorder" | "grim" | "helper" = "wf-recorder";
  /** Helper binary (helper source). */
  readonly helper: string | null;
  #proc: Proc | null = null;
  #grim: { stop: boolean; done: Promise<void> } | null = null;
  #seq = 0;
  #lastHash = "";
  #stopped = false;
  #restarts: number[] = [];
  #framesThisRun = 0;
  #stats = { sent: 0, skipped: 0, dropped: 0, bytes: 0, waited: 0 };
  #statsTimer: NodeJS.Timeout | null = null;
  #restartTimer: NodeJS.Timeout | null = null;
  // H.264
  #gate = new KeyGate();
  #sps: Buffer | null = null;
  #pps: Buffer | null = null;
  #lastKeyAt = 0;
  #forcedKeyAt = 0;
  #flushTimer: NodeJS.Timeout | null = null;
  #startTimer: NodeJS.Timeout | null = null;

  constructor(socket: WebSocket, io: StreamIo, target: StreamTarget, params: StreamParams, opts: LiveStream["opts"], log: LiveStream["log"], helper: string | null = null) {
    this.helper = helper;
    if (helper) this.source = "helper";
    this.socket = socket;
    this.io = io;
    this.target = target;
    this.params = params;
    this.out = outputSize(target.pixels, params.scale);
    this.opts = opts;
    this.log = log;
  }

  send(msg: object) {
    if (this.socket.readyState === 1) this.socket.send(JSON.stringify(msg));
  }

  hello(cursor: [number, number] | null) {
    const p = this.params;
    this.send({ type: "hello", width: this.out.w, height: this.out.h, region: this.target.region, monitor: this.target.monitor, fps: p.fps, scale: p.scale, q: p.q, codec: p.codec, kbps: p.kbps, source: this.source, cursor: cursor && { x: cursor[0], y: cursor[1] } });
  }

  async start() {
    if (this.#stopped) return;
    this.#statsTimer ??= setInterval(() => {
      this.send({ type: "stats", codec: this.params.codec, ...this.#stats });
      this.#stats = { sent: 0, skipped: 0, dropped: 0, bytes: 0, waited: 0 };
    }, this.opts.statsMs);
    if (this.source === "helper") return this.#startHelper();
    if (this.source === "wf-recorder" && (await this.io.has("wf-recorder"))) return this.#startRecorder();
    this.#fallback();
  }

  #restartChain: Promise<void> = Promise.resolve();

  /** Resolution/fps/quality changed: the source restarts (consecutive requests run in order). */
  restart(params: StreamParams, cursor: [number, number] | null): Promise<void> {
    const p = this.#restartChain.then(() => this.#restart(params, cursor));
    this.#restartChain = p.catch(() => {});
    return p;
  }

  async #restart(params: StreamParams, cursor: [number, number] | null) {
    await this.#stopSources();
    if (this.#stopped) return;
    this.params = params;
    this.out = outputSize(this.target.pixels, params.scale);
    this.#lastHash = "";
    this.hello(cursor);
    if (this.source === "grim") this.#startGrim();
    else if (this.source === "helper") this.#startHelper();
    else await this.#startRecorder(); // the next restart must not run before the process is set up (orphan process)
  }

  /** Applies the source's limits to a requested quality change (codec, fps). */
  limit(next: StreamParams) {
    // No H.264 in the grim fallback or from the helper.
    if (this.source === "grim") Object.assign(next, { codec: "mjpeg", fps: Math.min(next.fps, this.opts.grimMaxFps) });
    else if (this.source === "helper") Object.assign(next, { codec: "mjpeg", fps: Math.min(next.fps, MJPEG_MAX_FPS) });
    else if (next.codec === "mjpeg") next.fps = Math.min(next.fps, MJPEG_MAX_FPS);
  }

  #emit(jpeg: Buffer) {
    if (this.#stopped || this.socket.readyState !== 1) return;
    this.#framesThisRun++;
    const h = createHash("sha1").update(jpeg).digest("hex");
    if (h === this.#lastHash) {
      this.#stats.skipped++;
      return;
    }
    if (this.socket.bufferedAmount > this.opts.maxBuffered) {
      this.#stats.dropped++; // not queued; the next frame (even if identical) is sent
      return;
    }
    this.#lastHash = h;
    this.#seq++;
    this.#stats.sent++;
    this.#stats.bytes += jpeg.length;
    this.socket.send(frameMessage(this.#seq, this.opts.now(), this.out.w, this.out.h, jpeg));
  }

  /** H.264 frame: sent if it passes the keyframe gate (with SPS+PPS before an IDR). */
  #emitAu(au: AccessUnit) {
    if (this.#stopped || this.socket.readyState !== 1) return;
    this.#framesThisRun++;
    if (au.sps) this.#sps = au.sps;
    if (au.pps) this.#pps = au.pps;
    // An IDR with unknown config can't be decoded: not counted as a keyframe.
    const key = au.key && !!this.#sps && !!this.#pps;
    if (key && this.#startTimer) {
      clearTimeout(this.#startTimer);
      this.#startTimer = null;
    }
    const r = this.#gate.offer(key, this.socket.bufferedAmount > this.opts.maxBuffered);
    if (r === "drop") return void this.#stats.dropped++;
    if (r === "wait") return void this.#stats.waited++;
    const ts = this.opts.now();
    if (key) {
      this.#lastKeyAt = ts;
      const config = annexB([this.#sps!, this.#pps!]);
      this.socket.send(frameMessage(++this.#seq, ts, this.out.w, this.out.h, config, FRAME.h264 | FRAME.config));
      this.#stats.bytes += config.length;
    }
    this.#seq++;
    this.#stats.sent++;
    this.#stats.bytes += au.data.length;
    this.socket.send(frameMessage(this.#seq, ts, this.out.w, this.out.h, au.data, FRAME.h264 | (key ? FRAME.key : 0)));
  }

  /**
   * The client requested a keyframe (decoder rebuilt / corrupt image): the gate waits for the next IDR; if that IDR
   * is more than 600 ms away the process restarts (at most once every 3 s), and the new process starts with an IDR. A
   * newly connected client's request is ignored if the first IDR hasn't gone out yet or went out within 500 ms.
   */
  requestKey() {
    if (this.params.codec !== "h264" || this.source !== "wf-recorder" || this.#stopped) return;
    const t = this.opts.now();
    // Process just started (first IDR on the way) or an IDR just went out (reaches the client on this connection): ignore.
    if (this.#lastKeyAt === 0 || t - this.#lastKeyAt < 500) return;
    this.#gate.waiting = true;
    const gopMs = 2000;
    if (this.#proc && gopMs - (t - this.#lastKeyAt) > 600 && t - this.#forcedKeyAt > 3000) {
      this.#forcedKeyAt = t;
      void this.restart(this.params, null);
    }
  }

  /** H.264 didn't start / crashed: switch to MJPEG and notify the client. */
  #codecFallback(reason: string) {
    if (this.#stopped || this.params.codec !== "h264") return;
    this.log(`H.264 akışı başlamadı, MJPEG'e geçiliyor: ${reason}`);
    this.send({ type: "notice", code: "agent.desktop.codecFallback", codec: "mjpeg" });
    void this.restart({ ...this.params, codec: "mjpeg", fps: Math.min(this.params.fps, MJPEG_MAX_FPS) }, null);
  }

  /** Source generation: stop increments it; a start that went stale while waiting for the environment opens no process. */
  #run = 0;

  async #startRecorder() {
    if (this.#stopped) return;
    const run = this.#run;
    let env: NodeJS.ProcessEnv;
    try {
      env = await this.io.screenEnv();
    } catch (e) {
      this.send({ type: "error", code: e instanceof AppError ? e.code : "agent.desktop.streamFailed" });
      this.socket.close(4503, "no display");
      return;
    }
    if (this.#stopped || run !== this.#run || this.#proc) return;
    const h264 = this.params.codec === "h264";
    const child = this.io.spawn("wf-recorder", (h264 ? wfRecorderH264Args : wfRecorderArgs)(this.target, this.out, this.params), env);
    const splitter = new JpegSplitter();
    const parser = new AccessUnitParser();
    this.#framesThisRun = 0;
    this.#gate = new KeyGate();
    this.#lastKeyAt = 0;
    this.#sps = this.#pps = null; // the new process sends its own config
    let err = "";
    let spawnFailed = false;
    const exited = new Promise<void>((resolve) => {
      child.on("exit", () => resolve());
      child.on("error", (e) => {
        spawnFailed = (e as NodeJS.ErrnoException).code === "ENOENT";
        resolve();
      });
    });
    const proc: Proc = { child, exited };
    this.#proc = proc;
    if (h264) {
      // If no keyframe arrives (no nvenc/busy, driver error), switch to MJPEG.
      this.#startTimer = setTimeout(() => {
        this.#startTimer = null;
        if (this.#proc === proc) this.#codecFallback(`${this.opts.h264StartMs} ms içinde anahtar kare yok: ${err.trim().split("\n").at(-1) ?? ""}`);
      }, this.opts.h264StartMs);
      child.stdout?.on("data", (b: Buffer) => {
        if (this.#proc !== proc) return;
        const corrupt = parser.corrupt;
        const aus = parser.push(b);
        // Partially sent frame (silence fell mid-frame): following P-frames aren't sent, a new IDR is requested.
        if (parser.corrupt !== corrupt) {
          this.#gate.waiting = true;
          this.requestKey();
        }
        for (const au of aus) this.#emitAu(au);
        if (this.#flushTimer) clearTimeout(this.#flushTimer);
        this.#flushTimer = setTimeout(() => {
          this.#flushTimer = null;
          if (this.#proc === proc) for (const au of parser.flush()) this.#emitAu(au);
        }, this.opts.h264FlushMs);
      });
    } else {
      child.stdout?.on("data", (b: Buffer) => {
        if (this.#proc !== proc) return;
        for (const f of splitter.push(b)) this.#emit(f);
      });
    }
    child.stderr?.on("data", (b: Buffer) => (err = (err + b.toString("utf8")).slice(-600)));
    void exited.then(() => {
      if (this.#proc !== proc || this.#stopped) return; // stopped on purpose
      this.#proc = null;
      if (h264 && !spawnFailed && this.#framesThisRun === 0) return this.#codecFallback(err.trim().split("\n").at(-1) ?? "");
      if (spawnFailed || this.#framesThisRun === 0) {
        this.log(`wf-recorder kare veremedi, grim'e geçiliyor: ${err.trim().split("\n").at(-1) ?? ""}`);
        return this.#fallback();
      }
      this.#restartLater(() => this.#startRecorder());
    });
  }

  /** Unexpected exit (e.g. monitor turned off): restarts at most 3 times per minute. */
  #restartLater(start: () => Promise<void> | void) {
    const t = this.opts.now();
    this.#restarts = [...this.#restarts.filter((x) => t - x < 60_000), t];
    if (this.#restarts.length > 3) {
      this.send({ type: "error", code: "agent.desktop.streamFailed" });
      this.socket.close(4502, "capture failed");
      return;
    }
    this.#restartTimer = setTimeout(() => void start(), 1000);
  }

  /** `tiphys-desktop stream`: MJPEG on stdout like wf-recorder; no fallback (exit code → error for the client). */
  #startHelper() {
    if (this.#stopped || this.#proc) return;
    const child = this.io.spawn(this.helper!, helperStreamArgs(this.target, this.out, this.params), process.env);
    const splitter = new JpegSplitter();
    this.#framesThisRun = 0;
    let err = "";
    let code: number | null = null;
    let spawnFailed = false;
    const exited = new Promise<void>((resolve) => {
      child.on("exit", (c) => {
        code = c;
        resolve();
      });
      child.on("error", () => {
        spawnFailed = true;
        resolve();
      });
    });
    const proc: Proc = { child, exited };
    this.#proc = proc;
    child.stdout?.on("data", (b: Buffer) => {
      if (this.#proc !== proc) return;
      for (const f of splitter.push(b)) this.#emit(f);
    });
    child.stderr?.on("data", (b: Buffer) => (err = (err + b.toString("utf8")).slice(-600)));
    void exited.then(() => {
      if (this.#proc !== proc || this.#stopped) return; // stopped on purpose
      this.#proc = null;
      if (spawnFailed || this.#framesThisRun === 0) {
        this.log(`masaüstü yardımcısı kare veremedi (kod ${code}): ${err.trim().split("\n").at(-1) ?? ""}`);
        this.send({ type: "error", code: spawnFailed ? "agent.desktop.helperMissing" : (HELPER_STREAM_EXIT[code ?? -1] ?? "agent.desktop.streamFailed") });
        this.socket.close(4502, "capture failed");
        return;
      }
      this.#restartLater(() => this.#startHelper());
    });
  }

  #fallback() {
    if (this.#stopped) return;
    this.source = "grim";
    if (this.params.codec === "h264") this.send({ type: "notice", code: "agent.desktop.codecFallback", codec: "mjpeg" });
    this.params = { ...this.params, codec: "mjpeg", fps: Math.min(this.params.fps, this.opts.grimMaxFps) };
    this.send({ type: "notice", code: "agent.desktop.streamFallback", fps: this.params.fps });
    this.hello(null);
    this.#startGrim();
  }

  #startGrim() {
    const state = { stop: false, done: Promise.resolve() };
    this.#grim = state;
    const interval = 1000 / Math.min(this.params.fps, this.opts.grimMaxFps);
    state.done = (async () => {
      let failures = 0;
      while (!state.stop && !this.#stopped) {
        const t0 = this.opts.now();
        try {
          const env = await this.io.screenEnv();
          const scale = (this.out.w / this.target.pixels.w).toFixed(4);
          const shot = await this.io.bytes("grim", [...this.target.args, "-s", scale, "-t", "ppm", "-"], { env, timeoutMs: 5000 });
          if (state.stop) break;
          if (shot.code !== 0) throw new Error(shot.err);
          const jpeg = await this.io.bytes(
            "ffmpeg",
            ["-v", "error", "-f", "ppm_pipe", "-i", "-", "-vf", `scale=${this.out.w}:${this.out.h}`, "-q:v", String(qscale(this.params.q)), "-f", "mjpeg", "-"],
            { env: process.env, input: shot.out, timeoutMs: 5000 },
          );
          if (jpeg.code !== 0) throw new Error(jpeg.err);
          for (const f of new JpegSplitter().push(jpeg.out)) this.#emit(f);
          failures = 0;
        } catch (e) {
          if (++failures >= 3) {
            this.log("grim yedeği de çalışmıyor", e);
            this.send({ type: "error", code: "agent.desktop.streamFailed" });
            this.socket.close(4502, "capture failed");
            return;
          }
        }
        const wait = Math.max(0, interval - (this.opts.now() - t0));
        await new Promise((r) => setTimeout(r, wait));
      }
    })();
  }

  async #stopSources() {
    this.#run++;
    for (const t of [this.#restartTimer, this.#flushTimer, this.#startTimer]) if (t) clearTimeout(t);
    this.#restartTimer = this.#flushTimer = this.#startTimer = null;
    const g = this.#grim;
    this.#grim = null;
    if (g) {
      g.stop = true;
      await g.done;
    }
    const p = this.#proc;
    this.#proc = null;
    if (p) await killChild(p, this.opts.killGraceMs);
  }

  /** Kills all child processes; returns when they're done. */
  async stop() {
    this.#stopped = true;
    if (this.#statsTimer) clearInterval(this.#statsTimer);
    await this.#stopSources();
  }
}

async function killChild(p: Proc, graceMs: number) {
  const c = p.child;
  if (c.exitCode !== null || c.signalCode !== null) return;
  c.kill("SIGTERM");
  const t = setTimeout(() => c.kill("SIGKILL"), graceMs);
  await p.exited;
  clearTimeout(t);
}

/** Runs input events in order; of consecutive cursor moves only the last one is kept (coalescing). */
class InputQueue {
  #queue: InputEvent[] = [];
  #running = false;
  readonly run: (e: InputEvent) => Promise<void>;
  readonly onError: (e: unknown) => void;

  constructor(run: (e: InputEvent) => Promise<void>, onError: (e: unknown) => void) {
    this.run = run;
    this.onError = onError;
  }

  push(e: InputEvent) {
    const last = this.#queue.at(-1);
    if (e.type === "move" && last?.type === "move") this.#queue[this.#queue.length - 1] = e;
    else this.#queue.push(e);
    if (!this.#running) void this.#drain();
  }

  clear() {
    this.#queue = [];
  }

  async #drain() {
    this.#running = true;
    while (this.#queue.length) {
      const e = this.#queue.shift()!;
      try {
        await this.run(e);
      } catch (err) {
        this.onError(err);
      }
    }
    this.#running = false;
  }
}

export const streamQuery = z.object({
  fps: z.coerce.number().int().min(1).max(30).default(12),
  scale: z.coerce.number().min(0.25).max(1).default(0.6),
  q: z.coerce.number().int().min(10).max(95).default(70),
  monitor: z.string().regex(/^[A-Za-z0-9._-]{1,64}$/).optional(),
  window: z.string().regex(ADDRESS).optional(),
  codec: z.enum(["mjpeg", "h264"]).default("mjpeg"),
  kbps: z.coerce.number().int().min(100).max(20_000).default(2000),
});
export type StreamQuery = z.infer<typeof streamQuery>;

/** The live screen's desktop backend: Hyprland (streamRoutes below) or the native helper (desktop_portable.ts). */
export interface ScreenSource {
  /** Resolves the query's target and creates the stream (nothing runs yet); AppError if that's impossible. */
  open(q: StreamQuery, socket: WebSocket, opts: LiveStream["opts"], log: LiveStream["log"]): Promise<LiveStream>;
  /** Cursor position in the stream's image (for hello); null if unknown. */
  cursorIn(stream: LiveStream): Promise<[number, number] | null>;
  runInput(stream: LiveStream, e: InputEvent): Promise<void>;
  /** Focused window changes (sent as {type:"focus", …}); returns the unsubscribe function. */
  subscribeFocus(fn: (f: object) => void): () => void;
  /** Agent shutdown, after the streams closed. */
  stop(): void | Promise<void>;
}

/**
 * WS /v1/desktop/stream: no upgrade without the "desktop" + "control" features and a valid control session
 * (X-Tiphys-Control header) (403). One stream per session: if the same device reconnects, the old one closes.
 */
export function streamRoutes(app: FastifyInstance, ctx: Ctx, io: StreamIo = realStreamIo, opts: StreamOpts = {}) {
  const control = ctx.control;
  if (!control) throw new Error("streamRoutes: önce hyprRoutes (kontrol oturumu) kaydedilmeli");
  // Focused window: shared among open streams (no socket/timer while there are no subscribers).
  const focus = opts.focus ?? new FocusWatcher({ exec: io.exec, hyprEnv: io.hyprEnv, connect: io.connect }, { apps: () => ctx.desktopApps?.() ?? Promise.resolve([]), log: (m) => app.log.warn(m) });

  async function hyprJson(env: NodeJS.ProcessEnv, what: string): Promise<unknown> {
    const r = await io.exec("hyprctl", ["-j", what], { env, timeoutMs: 5000, allowFail: true });
    try {
      return JSON.parse(r.stdout);
    } catch {
      throw new AppError("agent.desktop.hyprctlFailed", 502);
    }
  }

  const hyprctl = ctx.hyprctl ?? new Hyprctl(io.exec, io.hyprEnv);

  screenRoute(app, ctx, control, opts, {
    async open(q, socket, streamOpts, log) {
      const env = await io.hyprEnv();
      const [c, m] = await Promise.all([q.window ? hyprJson(env, "clients") : Promise.resolve([]), hyprJson(env, "monitors")]);
      const monitors = parseMonitors(m).map((x, i) => ({ ...x, transform: Number(((m as Array<{ transform?: unknown }>)[i] ?? {}).transform) || 0 }));
      let window: HyprWindow | undefined;
      if (q.window) {
        window = parseClients(c).find((w) => w.address === q.window);
        if (!window) throw new AppError("agent.desktop.windowNotFound", 404);
        if (!isVisible(window, monitors)) throw new AppError("agent.desktop.windowNotVisible", 409);
      }
      const target = targetFor(monitors, { monitor: q.monitor, window });
      const fps = q.codec === "mjpeg" ? Math.min(q.fps, MJPEG_MAX_FPS) : q.fps;
      return new LiveStream(socket, io, target, { fps, scale: q.scale, q: q.q, codec: q.codec, kbps: q.kbps }, streamOpts, log);
    },
    async cursorIn(stream) {
      try {
        const j = (await hyprJson(await io.hyprEnv(), "cursorpos")) as { x?: unknown; y?: unknown };
        if (typeof j.x !== "number" || typeof j.y !== "number") return null;
        return unmapPoint(j.x, j.y, stream.out, stream.target.region);
      } catch {
        return null;
      }
    },
    // Input: code shared with Claude's PC tools (desktop_input.ts). Image pixel → global coordinate; if the client
    // also sends the frame size (while quality is changing), conversion uses that size.
    runInput: (stream, e) => runInputShared(io, hyprctl, e, (x, y, w, h) => mapPoint(x, y, w && h ? { w, h } : stream.out, stream.target.region)),
    subscribeFocus: (fn) => focus.subscribe(fn),
    stop: () => focus.stop(),
  });
}

/**
 * The live screen WebSocket over a [source] (shared by the Hyprland and helper backends): session checks, one stream
 * per device, input queue and limits, quality changes, cleanup.
 */
export function screenRoute(app: FastifyInstance, ctx: Ctx, control: ControlSessions, opts: StreamOpts, source: ScreenSource) {
  const now = opts.now ?? Date.now;
  const log = (msg: string, err?: unknown) => app.log.warn({ err }, msg);
  // 60 input events per second (security rule); enough in practice since cursor moves are coalesced.
  const inputLimit = opts.inputLimit ?? new RateLimit(60, 1000, now);
  const streamOpts = {
    maxBuffered: opts.maxBuffered ?? 512 * 1024,
    killGraceMs: opts.killGraceMs ?? 1000,
    grimMaxFps: opts.grimMaxFps ?? 4,
    statsMs: opts.statsMs ?? 1000,
    h264StartMs: opts.h264StartMs ?? 4000,
    h264FlushMs: opts.h264FlushMs ?? 3,
    now,
  };
  const live = new Map<string, { stream: LiveStream; close: (code: number, reason: string) => Promise<void> }>();

  app.addHook("onClose", async () => {
    await Promise.all([...live.values()].map((s) => s.close(1001, "agent shutdown")));
    await source.stop();
  });

  const cursorIn = (stream: LiveStream) => source.cursorIn(stream);
  const runInput = (stream: LiveStream, e: InputEvent) => source.runInput(stream, e);

  app.get(
    "/v1/desktop/stream",
    {
      websocket: true,
      // Before upgrading: feature, session and parameters (otherwise a plain HTTP error response).
      preValidation: async (req: FastifyRequest) => {
        requireControlFeature(ctx);
        await control.check(tokenOf(req), req.device?.id);
        streamQuery.parse(req.query);
      },
    },
    (socket, req) => {
      const token = tokenOf(req);
      const device = req.device!.id;
      const q = streamQuery.parse(req.query);
      let stream: LiveStream | null = null;
      let closed = false;
      const pending: Array<Buffer | string> = [];
      /** Mouse buttons held down: released if the connection drops (so no button stays pressed on the PC). */
      const pressed = new Set<"left" | "right" | "middle">();
      /** Each quality change restarts the recorder: at most 6 per 10 s. */
      let qualityAt: number[] = [];
      let offFocus: (() => void) | null = null;

      const close = async (code: number, reason: string) => {
        if (!closed) {
          closed = true;
          if (socket.readyState === 0 || socket.readyState === 1) socket.close(code, reason);
        }
        offEnd();
        offFocus?.();
        offFocus = null;
        clearInterval(recheck);
        inputs.clear();
        for (const button of pressed) await (stream ? runInput(stream, { type: "up", button }) : Promise.resolve()).catch(() => {});
        pressed.clear();
        if (live.get(device)?.stream === stream) live.delete(device);
        await stream?.stop();
      };
      const offEnd = control.onEnd((info) => {
        if (info.device === device) void close(4401, "control ended");
      });
      // The stream stops if the token was refreshed or the session ended some other way.
      const recheck = setInterval(() => {
        if (!ctx.store.get().features.control) return void close(4401, "control ended");
        control.check(token, device).catch(() => void close(4401, "control ended"));
      }, opts.recheckMs ?? 2000);
      recheck.unref?.();

      const inputs = new InputQueue(
        (e) => runInput(stream!, e),
        (err) => {
          if (err instanceof AppError && err.code === "agent.control.sessionRequired") return void close(4401, "control ended");
          stream?.send({ type: "error", code: err instanceof AppError ? err.code : "agent.desktop.inputFailed" });
          if (!(err instanceof AppError)) log("giriş olayı başarısız", err);
        },
      );

      let rateNoticeAt = 0;
      const onMessage = async (raw: Buffer | string) => {
        if (closed || !stream) return;
        let msg: { type?: unknown };
        try {
          msg = JSON.parse(raw.toString());
        } catch {
          return stream.send({ type: "error", code: "agent.request.invalid" });
        }
        if (msg?.type === "ping") return stream.send({ type: "pong", t: (msg as { t?: unknown }).t ?? null, at: now() });
        if (msg?.type === "keyframe") return stream.requestKey();
        if (msg?.type === "quality") {
          const p = qualityMsg.safeParse(msg);
          if (!p.success) return stream.send({ type: "error", code: "agent.request.invalid" });
          const cur = stream.params;
          const next = { fps: p.data.fps ?? cur.fps, scale: p.data.scale ?? cur.scale, q: p.data.q ?? cur.q, kbps: p.data.kbps ?? cur.kbps, codec: p.data.codec ?? cur.codec };
          stream.limit(next);
          if (next.fps === cur.fps && next.scale === cur.scale && next.q === cur.q && next.kbps === cur.kbps && next.codec === cur.codec) return;
          const t = now();
          qualityAt = qualityAt.filter((x) => t - x < 10_000);
          if (qualityAt.length >= 6) return stream.send({ type: "error", code: "agent.control.rateLimited" });
          qualityAt.push(t);
          return stream.restart(next, await cursorIn(stream));
        }
        const p = inputEvent.safeParse(msg);
        if (!p.success) return stream.send({ type: "error", code: "agent.request.invalid" });
        if (p.data.type === "key") {
          try {
            keyArgs(p.data.key, p.data.mods);
          } catch {
            return stream.send({ type: "error", code: "agent.desktop.badKey" });
          }
        }
        if (p.data.type === "text" && !checkText(p.data.text)) return stream.send({ type: "error", code: "agent.desktop.badText" });
        let s;
        try {
          s = await control.check(token, device);
        } catch {
          return void close(4401, "control ended");
        }
        if (!inputLimit.take(s.device)) {
          if (now() - rateNoticeAt > 1000) {
            rateNoticeAt = now();
            stream.send({ type: "error", code: "agent.control.rateLimited" });
          }
          return;
        }
        if (p.data.type === "down") pressed.add(p.data.button);
        else if (p.data.type === "up") pressed.delete(p.data.button);
        inputs.push(p.data);
      };
      // Messages arriving before the stream is set up are held.
      socket.on("message", (d: Buffer) => {
        if (stream) return void onMessage(d);
        if (pending.length < 64) pending.push(d); // overflow isn't held while setup is in progress
      });
      socket.on("close", () => void close(1000, "closed"));
      socket.on("error", () => void close(1011, "error"));

      void (async () => {
        try {
          const s = await source.open(q, socket, streamOpts, log);
          if (closed) return;
          // One stream per session: the old one (e.g. left open after a network drop) closes.
          const old = live.get(device);
          live.set(device, { stream: s, close });
          stream = s;
          if (old) await old.close(4409, "replaced");
          if (closed) return void (await s.stop());
          s.hello(await cursorIn(s));
          if (!closed) offFocus = source.subscribeFocus((f) => s.send({ type: "focus", ...f }));
          await s.start();
          for (const d of pending.splice(0)) void onMessage(d);
        } catch (e) {
          if (!(e instanceof AppError)) log("canlı ekran başlatılamadı", e);
          if (socket.readyState === 1) socket.send(JSON.stringify({ type: "error", code: e instanceof AppError ? e.code : "agent.desktop.streamFailed" }));
          await close(4400, "start failed");
        }
      })();
    },
  );
}
