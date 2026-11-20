// Game mode source side (PLAN.md §19, runs on the PC): WS /v1/gamemode/feed (scope "gamemode") with ONE shared
// producer for all subscribers. It starts with the first subscriber and stops (children killed, sockets dropped) when
// the last one leaves:
// - music: Velour state long-poll (`wait`), lyrics + next 2 tracks on track change. Titles/lyrics are never logged.
// - spectrum: pw-record on the default output's monitor → FFT → binary frames, only while Velour plays.
// - truck: ETS2 shared memory, 20 Hz while driving and 1 Hz otherwise, plus derived events.
// GET /v1/gamemode/source and POST /v1/gamemode/plugin are for the phone (device token).
import { spawn } from "node:child_process";
import type { Readable } from "node:stream";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { whichIn } from "../detect.ts";
import { AppError } from "../errors.ts";
import { run } from "../exec.ts";
import type { Exec } from "../control.ts";
import { artId } from "../routes/media.ts";
import { sessionBusEnv } from "../routes/desktop.ts";
import { velourRequest, velourSocketPath, type VelourOp } from "../routes/velour.ts";
import type { Ctx } from "../server.ts";
import { findGameDir, installPlugin, parseTelemetry, pluginStatus, removePlugin, TelemetryReader, TruckEvents, type Sample } from "./ets2.ts";
import { parseSinkName, pwRecordArgs, SpectrumAnalyzer } from "./spectrum.ts";

/** The WebSocket surface used (ws). */
export interface Sock {
  readonly readyState: number;
  readonly bufferedAmount: number;
  send(data: string | Buffer): void;
  close(code?: number, reason?: string): void;
}

export interface Child {
  stdout: Readable | null;
  exitCode: number | null;
  signalCode: NodeJS.Signals | null;
  kill(signal?: NodeJS.Signals): boolean;
  on(ev: "exit", fn: () => void): unknown;
  on(ev: "error", fn: (e: Error) => void): unknown;
}

export interface SourceIo {
  velour(op: VelourOp, signal?: AbortSignal): Promise<unknown>;
  exec: Exec;
  spawn(cmd: string, args: string[], env: NodeJS.ProcessEnv): Child;
  telemetry(): Promise<{ running: boolean; buf: Buffer | null }>;
}

export function realSourceIo(): SourceIo {
  const reader = new TelemetryReader();
  const path = velourSocketPath();
  return {
    velour: (op, signal) => velourRequest(path, op, undefined, signal),
    exec: run,
    spawn: (cmd, args, env) => spawn(cmd, args, { env, stdio: ["ignore", "pipe", "ignore"] }),
    telemetry: () => reader.read(),
  };
}

export interface SourceOpts {
  io?: SourceIo;
  /** Skip a frame / truck sample when a socket has this much queued. */
  maxBuffered?: number;
  waitSeconds?: number;
  retryMs?: number;
  frameMs?: number;
  driveMs?: number;
  idleMs?: number;
  killGraceMs?: number;
}

type Rec = Record<string, unknown>;
const obj = (v: unknown): Rec => (v && typeof v === "object" ? (v as Rec) : {});
const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const text = (v: unknown, max = 500) => (typeof v === "string" ? v.slice(0, max) : "");
const artists = (t: Rec) => (Array.isArray(t.artists) ? t.artists.map((a) => text(obj(a).name, 200)).filter(Boolean).join(", ") : "");

/** Velour state → the contract's music message (+ artUrl: the https cover the display agent proxies). */
export function musicMessage(state: unknown, next: Array<{ title: string; artist: string }>, at = Date.now()): Rec {
  const s = obj(state);
  const t = obj(s.track);
  if (!s.track || typeof t.videoId !== "string") return { type: "music", none: true };
  const thumb = typeof t.thumbnail === "string" && /^https:\/\//i.test(t.thumbnail) ? t.thumbnail.slice(0, 2000) : null;
  return {
    type: "music",
    playing: s.playing === true,
    title: text(t.title),
    artist: artists(t),
    album: obj(t.album).name ? text(obj(t.album).name) : null,
    artId: thumb ? artId(thumb) : null,
    artUrl: thumb,
    duration: num(s.duration) ?? num(t.duration) ?? 0,
    position: num(s.position) ?? 0,
    at,
    next,
  };
}

/** Velour lyrics → the contract's lyrics message (time → t, seconds). */
export function lyricsMessage(lyrics: unknown, music: Rec): Rec {
  const l = obj(lyrics);
  const kind = l.kind === "synced" || l.kind === "plain" ? l.kind : "none";
  let lines: Array<{ t: number; text: string }> = [];
  if (kind === "synced" && Array.isArray(l.lines)) {
    lines = l.lines.slice(0, 2000).map((x) => ({ t: num(obj(x).time) ?? 0, text: text(obj(x).text) }));
  } else if (kind === "plain") {
    const raw = Array.isArray(l.lines) && l.lines.length ? l.lines.map((x) => text(obj(x).text)) : text(l.text, 50_000).split("\n");
    lines = raw.slice(0, 2000).map((s) => ({ t: 0, text: s }));
  }
  return { type: "lyrics", artId: music.artId ?? null, title: music.title ?? "", kind: lines.length ? kind : "none", lines };
}

/** Queue → the next ≤2 tracks after the current index. */
export function nextTracks(queue: unknown): Array<{ title: string; artist: string }> {
  const q = obj(queue);
  const index = num(q.index) ?? -1;
  const tracks = Array.isArray(q.tracks) ? q.tracks : [];
  return tracks.slice(index + 1, index + 3).map((x) => ({ title: text(obj(x).title), artist: artists(obj(x)) }));
}

const delay = (ms: number, signal: AbortSignal) =>
  new Promise<void>((resolve) => {
    if (signal.aborted) return resolve();
    const t = setTimeout(resolve, ms);
    signal.addEventListener("abort", () => (clearTimeout(t), resolve()), { once: true });
  });

interface Capture {
  child: Child | null;
  timer: NodeJS.Timeout;
  stop: boolean;
}

/** Shared producer: runs only while it has subscribers. */
export class FeedProducer {
  readonly #io: SourceIo;
  readonly #o: Required<Omit<SourceOpts, "io">>;
  readonly #log: (msg: string, err?: unknown) => void;
  readonly #subs = new Set<Sock>();
  #abort: AbortController | null = null;
  /** Latest messages, sent to a new subscriber at once. */
  #music: string | null = null;
  #lyrics: string | null = null;
  #truck: string | null = null;
  #playing = false;
  #spectrum: Capture | null = null;
  #loops: Promise<unknown>[] = [];

  constructor(io: SourceIo, o: SourceOpts, log: (msg: string, err?: unknown) => void) {
    this.#io = io;
    this.#log = log;
    this.#o = {
      maxBuffered: o.maxBuffered ?? 256 * 1024,
      waitSeconds: o.waitSeconds ?? 20,
      retryMs: o.retryMs ?? 3000,
      frameMs: o.frameMs ?? 33,
      driveMs: o.driveMs ?? 50,
      idleMs: o.idleMs ?? 1000,
      killGraceMs: o.killGraceMs ?? 1000,
    };
  }

  get subscribers() {
    return this.#subs.size;
  }

  get running() {
    return this.#abort !== null;
  }

  /** The spectrum capture child (tests). */
  get spectrumChild() {
    return this.#spectrum?.child ?? null;
  }

  add(sock: Sock) {
    this.#subs.add(sock);
    for (const m of [this.#music, this.#lyrics, this.#truck]) if (m) sock.send(m);
    if (!this.#abort) this.#start();
  }

  async remove(sock: Sock) {
    if (!this.#subs.delete(sock) || this.#subs.size > 0) return;
    await this.stop();
  }

  async stop() {
    const a = this.#abort;
    this.#abort = null;
    a?.abort();
    await this.#stopSpectrum();
    await Promise.all(this.#loops.splice(0));
    this.#music = this.#lyrics = this.#truck = null;
    this.#playing = false;
  }

  async closeAll() {
    for (const s of [...this.#subs]) if (s.readyState === 0 || s.readyState === 1) s.close(1001, "agent shutdown");
    this.#subs.clear();
    await this.stop();
  }

  #broadcast(msg: Rec, droppable = false) {
    const s = JSON.stringify(msg);
    for (const sock of this.#subs) {
      if (sock.readyState !== 1 || (droppable && sock.bufferedAmount > this.#o.maxBuffered)) continue;
      sock.send(s);
    }
    return s;
  }

  #start() {
    const a = new AbortController();
    this.#abort = a;
    this.#loops = [this.#musicLoop(a.signal), this.#truckLoop(a.signal)].map((p) => p.catch((e) => this.#log("oyun modu akışı hata verdi", e)));
  }

  async #musicLoop(signal: AbortSignal) {
    let rev: number | null = null;
    let track: string | null = null;
    let queueRev: number | null = null;
    let next: Array<{ title: string; artist: string }> = [];
    let down = false;
    while (!signal.aborted) {
      try {
        const op: VelourOp = rev === null ? { op: "state" } : { op: "wait", since: rev, timeout: this.#o.waitSeconds };
        const started = Date.now();
        const s = obj(await this.#io.velour(op, signal));
        if (signal.aborted) break;
        down = false;
        const r = num(s.rev);
        if (rev !== null && r === rev) {
          if (Date.now() - started < 1000) await delay(2000, signal); // answered at once (busy): don't spin
          continue;
        }
        rev = r;
        const id = typeof obj(s.track).videoId === "string" ? (obj(s.track).videoId as string) : null;
        const qr = num(s.queueRev);
        if (id && (id !== track || qr !== queueRev)) {
          next = nextTracks(await this.#io.velour({ op: "queue" }, signal).catch(() => null));
          queueRev = qr;
        }
        const music = musicMessage(s, id ? next : []);
        this.#music = this.#broadcast(music);
        if (id !== track) {
          track = id;
          const lyrics = id ? await this.#io.velour({ op: "lyrics" }, signal).catch(() => null) : null;
          if (signal.aborted) break;
          this.#lyrics = this.#broadcast(id ? lyricsMessage(lyrics, music) : { type: "lyrics", artId: null, title: "", kind: "none", lines: [] });
        }
        this.#setPlaying(music.playing === true);
        if (r === null) await delay(2000, signal); // a Velour without `rev`: poll
      } catch {
        if (signal.aborted) break;
        if (!down) {
          this.#music = this.#broadcast({ type: "music", none: true });
          this.#setPlaying(false);
          track = null;
        }
        down = true;
        rev = null;
        await delay(this.#o.retryMs, signal);
      }
    }
  }

  async #truckLoop(signal: AbortSignal) {
    const events = new TruckEvents();
    while (!signal.aborted) {
      let sample: Sample;
      try {
        const t = await this.#io.telemetry();
        sample = parseTelemetry(t.buf, t.running);
      } catch {
        sample = parseTelemetry(null, false);
      }
      if (signal.aborted) break;
      this.#truck = this.#broadcast(sample.msg, true);
      for (const e of events.update(sample)) this.#broadcast(e as unknown as Rec);
      await delay(sample.msg.state === "driving" ? this.#o.driveMs : this.#o.idleMs, signal);
    }
  }

  #setPlaying(on: boolean) {
    if (on === this.#playing) return;
    this.#playing = on;
    if (on) void this.#startSpectrum();
    else void this.#stopSpectrum();
  }

  async #startSpectrum() {
    if (this.#spectrum || !this.#abort) return;
    const analyzer = new SpectrumAnalyzer();
    const sp: Capture = {
      child: null,
      stop: false,
      timer: setInterval(() => {
        const frame = analyzer.frame();
        for (const sock of this.#subs) if (sock.readyState === 1 && sock.bufferedAmount <= this.#o.maxBuffered) sock.send(frame);
      }, this.#o.frameMs),
    };
    sp.timer.unref?.();
    this.#spectrum = sp;
    const env = { ...process.env, ...sessionBusEnv() };
    const sink = parseSinkName((await this.#io.exec("wpctl", ["inspect", "@DEFAULT_AUDIO_SINK@"], { env, timeoutMs: 5000, allowFail: true }).catch(() => ({ stdout: "" }))).stdout);
    if (sp.stop || this.#spectrum !== sp) return;
    if (!sink) {
      this.#log("oyun modu: varsayılan ses çıkışı bulunamadı");
      return;
    }
    const child = this.#io.spawn("pw-record", pwRecordArgs(sink), env);
    sp.child = child;
    child.stdout?.on("data", (b: Buffer) => analyzer.pushBytes(b));
    child.on("error", () => {});
  }

  async #stopSpectrum() {
    const sp = this.#spectrum;
    if (!sp) return;
    this.#spectrum = null;
    sp.stop = true;
    clearInterval(sp.timer);
    const c = sp.child;
    if (!c || c.exitCode !== null || c.signalCode !== null) return;
    const exited = new Promise<void>((r) => c.on("exit", () => r()));
    c.kill("SIGTERM");
    const t = setTimeout(() => c.kill("SIGKILL"), this.#o.killGraceMs);
    await exited;
    clearTimeout(t);
  }
}

/** GET /v1/gamemode/source body. */
export async function sourceStatus(io: SourceIo) {
  const velour = await io.velour({ op: "state" }).then(() => true, () => false);
  const audio =
    whichIn(process.env.PATH, "pw-record") &&
    parseSinkName((await io.exec("wpctl", ["inspect", "@DEFAULT_AUDIO_SINK@"], { env: { ...process.env, ...sessionBusEnv() }, timeoutMs: 5000, allowFail: true }).catch(() => ({ stdout: "" }))).stdout) !== null;
  const gameDir = await findGameDir();
  const plugin = await pluginStatus(gameDir);
  const t = await io.telemetry().catch(() => ({ running: false, buf: null }));
  return {
    velour,
    audio,
    ets2: { gameDir, plugin: plugin.plugin, version: plugin.version, running: t.running, telemetry: parseTelemetry(t.buf, t.running).telemetry },
    map: { present: false },
  };
}

export function sourceRoutes(app: FastifyInstance, _ctx: Ctx, o: SourceOpts = {}) {
  const io = o.io ?? realSourceIo();
  const feed = new FeedProducer(io, o, (msg, err) => app.log.warn({ err }, msg));
  app.addHook("onClose", async () => feed.closeAll());

  app.get("/v1/gamemode/feed", { websocket: true, config: { scope: "gamemode" } }, (socket) => {
    const sock = socket as unknown as Sock;
    feed.add(sock);
    const gone = () => void feed.remove(sock);
    socket.on("close", gone);
    socket.on("error", gone);
    socket.on("message", () => {}); // nothing is accepted from subscribers
  });

  app.get("/v1/gamemode/source", async () => sourceStatus(io));

  app.post("/v1/gamemode/plugin", async (req) => {
    const { action } = z.strictObject({ action: z.enum(["install", "remove"]) }).parse(req.body);
    const dir = await findGameDir();
    if (!dir) throw new AppError("agent.gamemode.noGame", 404);
    if (action === "install") await installPlugin(dir);
    else await removePlugin(dir);
    return sourceStatus(io);
  });

  return feed;
}
