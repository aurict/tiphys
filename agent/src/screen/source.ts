// Screen mode source side (PLAN.md §19, §20; e.g. the PC): WS /v1/screen/feed with ONE shared producer for all
// subscribers, local ones included (the display agent's `self` source subscribes in-process). Each subscriber holds a
// topic set (`{type:"subscribe", topics}` replaces it); a topic's loop starts with its first subscriber and stops
// (children killed) with its last:
// - music: Velour state long-poll (`wait`), lyrics + next 2 tracks on track change. Titles/lyrics are never logged.
//   It also runs for spectrum alone (the capture follows Velour's playing state).
// - spectrum: pw-record on the default output's monitor → FFT → binary frames, only while Velour plays.
// - truck: ETS2 shared memory, 20 Hz while driving and 1 Hz otherwise, plus derived events.
// - system, jobs, servers: state producers (producers/*.ts), the latest message replayed to a new subscriber.
// - git, city: per subscriber project (`project`, `ci` in the subscribe message), one watcher of each per git root
//   (producers/git.ts, producers/city.ts); the city's working tree watchers also refresh the git status.
// - claude, diff: one shared topic (producers/claude.ts) rendered per subscriber with its project root (from the git
//   topic's selection) and that root's city path tokens; it names the session behind a city touch (`by`).
// Sleep group (PLAN.md §21 S3, sleep_group.ts): on a `screen` feed a member's `clockPing` is answered at once with
// `clockPong` (this clock) and `sleepGroup` messages go to the display side (`feed.group`).
// WS /v1/gamemode/feed is the 0.5 feed for one release: every Game mode topic at once, nothing accepted.
// GET /v1/screen/game/source and POST /v1/screen/game/plugin (+ the /v1/gamemode/… aliases) are for the phone.
import { spawn } from "node:child_process";
import { join } from "node:path";
import type { Readable } from "node:stream";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { terminalSessions } from "../claude/terminal.ts";
import { expandHome } from "../config.ts";
import { whichIn } from "../detect.ts";
import { AppError } from "../errors.ts";
import { run } from "../exec.ts";
import type { Exec } from "../control.ts";
import { FocusWatcher, realConnect } from "../focus.ts";
import { sessionBusEnv } from "../routes/desktop.ts";
import { hyprEnv } from "../routes/hypr.ts";
import { artId } from "../routes/media.ts";
import { velourRequest, velourSocketPath, type VelourOp } from "../routes/velour.ts";
import type { Ctx } from "../server.ts";
import { findGameDir, installPlugin, parseTelemetry, pluginStatus, removePlugin, TelemetryReader, TruckEvents, type Sample } from "./ets2.ts";
import type { StateProducer } from "./producers/common.ts";
import { realCityIo } from "./producers/city.ts";
import { ClaudeTopic, realClaudeIo, type ClaudeDeps, type ManagerLike } from "./producers/claude.ts";
import { GitTopic, realGitIo, resolveProject, type GitTopicDeps, type ProjectTopicName, type ProjectWant } from "./producers/git.ts";
import { JobsProducer } from "./producers/jobs.ts";
import { parseProject, ProjectSelector, realSelectorIo, type ProjectSpec } from "./producers/project.ts";
import { ServersProducer, type ServersState } from "./producers/servers.ts";
import { SystemProducer } from "./producers/system.ts";
import { parseSinkName, pwRecordArgs, SpectrumAnalyzer } from "./spectrum.ts";
import { GAMEMODE_TOPICS, parseTopics, TOPICS, type Topic } from "./topics.ts";

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
  /** Heartbeat to /v1/screen/feed subscribers: their idle watchdog must not fire on quiet topics. */
  heartbeatMs?: number;
  /** Work mode producers (defaults: the real ones, see sourceRoutes). */
  producers?: Producers;
}

/** Topics served by a state producer (one instance while subscribed). */
export const STATE_TOPICS = ["system", "jobs", "servers"] as const;
export type StateTopic = (typeof STATE_TOPICS)[number];

export interface Producers {
  make: Record<StateTopic, () => StateProducer>;
  git: GitTopicDeps;
  claude?: ClaudeDeps;
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

interface Loop {
  abort: AbortController;
  done: Promise<unknown>;
}

/** Shared producer: each loop runs only while a subscriber wants its topic. */
export class FeedProducer {
  readonly #io: SourceIo;
  readonly #o: Required<Omit<SourceOpts, "io" | "heartbeatMs" | "producers">>;
  readonly #make: Producers["make"] | null;
  /** Running state producers and their latest state message. */
  readonly #state = new Map<StateTopic, { p: StateProducer; last: string | null }>();
  readonly #git: GitTopic | null;
  readonly #claude: ClaudeTopic | null;
  readonly #projects = new Map<Sock, ProjectSpec>();
  readonly #log: (msg: string, err?: unknown) => void;
  readonly #subs = new Map<Sock, Set<Topic>>();
  #music: Loop | null = null;
  #truck: Loop | null = null;
  /** Latest messages, sent at once to a subscriber that adds the topic. */
  #musicMsg: string | null = null;
  #lyrics: string | null = null;
  #truckMsg: string | null = null;
  #playing = false;
  #spectrum: Capture | null = null;
  /** The sleep group's leader side (display.ts sets it): `sleepGroup` messages of feed subscribers go here. */
  group: { message(sock: Sock, msg: unknown): void; gone(sock: Sock): void } | null = null;

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
    this.#make = o.producers?.make ?? null;
    this.#git = o.producers ? new GitTopic(o.producers.git) : null;
    const git = this.#git;
    this.#claude =
      git && o.producers?.claude
        ? new ClaudeTopic(o.producers.claude, {
            rootOf: (sock) => git.rootOf(sock),
            cityOf: (root) => {
              const c = git.cityOf(root);
              return c ? { out: (rel) => c.pathOf(rel) } : null;
            },
          })
        : null;
    if (git && this.#claude) {
      const claude = this.#claude;
      git.onRoot = (sock) => claude.refresh(sock);
      git.attribute = (abs) => claude.attribute(abs);
    }
  }

  get subscribers() {
    return this.#subs.size;
  }

  get running() {
    return this.#music !== null || this.#truck !== null || this.#state.size > 0 || this.#git?.active === true || this.#claude?.active === true;
  }

  /** Topics with a running producer (tests). */
  get producing(): Topic[] {
    return [
      ...(this.#music ? ["music" as const] : []),
      ...(this.#spectrum ? ["spectrum" as const] : []),
      ...(this.#truck ? ["truck" as const] : []),
      ...STATE_TOPICS.filter((t) => this.#state.has(t)),
      ...(this.#git?.has("git") ? ["git" as const] : []),
      ...(this.#git?.has("city") ? ["city" as const] : []),
      ...(this.#claude?.has("claude") ? ["claude" as const] : []),
      ...(this.#claude?.has("diff") ? ["diff" as const] : []),
    ];
  }

  /** The claude and diff topics (tests). */
  get claude() {
    return this.#claude;
  }

  /** A running state producer (tests). */
  producer(t: StateTopic) {
    return this.#state.get(t)?.p ?? null;
  }

  /** The git and city topics (tests). */
  get git() {
    return this.#git;
  }

  /** The spectrum capture child (tests). */
  get spectrumChild() {
    return this.#spectrum?.child ?? null;
  }

  add(sock: Sock, topics: readonly Topic[] = GAMEMODE_TOPICS, project?: ProjectSpec) {
    this.#subs.set(sock, new Set());
    return this.setTopics(sock, topics, project);
  }

  /** Replaces a subscriber's topics (and project); the latest state of each added topic is sent at once. */
  setTopics(sock: Sock, topics: readonly Topic[], project: ProjectSpec = { project: "auto", ci: false }) {
    const old = this.#subs.get(sock);
    if (!old) return Promise.resolve();
    const next = new Set(topics);
    this.#subs.set(sock, next);
    this.#projects.set(sock, project);
    if (next.has("music") && !old.has("music")) for (const m of [this.#musicMsg, this.#lyrics]) if (m) sock.send(m);
    if (next.has("truck") && !old.has("truck") && this.#truckMsg) sock.send(this.#truckMsg);
    for (const t of STATE_TOPICS) {
      const last = this.#state.get(t)?.last;
      if (next.has(t) && !old.has(t) && last) sock.send(last);
    }
    const brain = [...next].filter((t): t is "claude" | "diff" => (t === "claude" || t === "diff") && this.#claude !== null);
    const proj: ProjectWant[] = [...next].filter((t): t is ProjectTopicName => t === "git" || t === "city");
    if (brain.length) proj.push("root");
    this.#git?.set(sock, proj.length ? project : null, proj);
    this.#claude?.set(sock, brain);
    return this.#apply();
  }

  async remove(sock: Sock) {
    if (!this.#subs.delete(sock)) return;
    this.#projects.delete(sock);
    this.#git?.set(sock, null);
    this.#claude?.set(sock, []);
    await this.#apply();
  }

  async stop() {
    this.#subs.clear();
    this.#projects.clear();
    this.#git?.stop();
    this.#claude?.stop();
    await this.#apply();
  }

  async closeAll() {
    for (const s of [...this.#subs.keys()]) if (s.readyState === 0 || s.readyState === 1) s.close(1001, "agent shutdown");
    await this.stop();
  }

  #wanted(): Set<Topic> {
    const w = new Set<Topic>();
    for (const t of this.#subs.values()) for (const x of t) w.add(x);
    return w;
  }

  /** Starts/stops loops to match what the subscribers want. */
  async #apply() {
    const w = this.#wanted();
    const stops: Promise<unknown>[] = [];
    if ((w.has("music") || w.has("spectrum")) && !this.#music) this.#music = this.#loop((s) => this.#musicLoop(s));
    else if (!w.has("music") && !w.has("spectrum") && this.#music) {
      stops.push(this.#end(this.#music));
      this.#music = null;
      this.#musicMsg = this.#lyrics = null;
      this.#playing = false;
    }
    if (w.has("truck") && !this.#truck) this.#truck = this.#loop((s) => this.#truckLoop(s));
    else if (!w.has("truck") && this.#truck) {
      stops.push(this.#end(this.#truck));
      this.#truck = null;
      this.#truckMsg = null;
    }
    if (!w.has("spectrum") || !this.#playing) stops.push(this.#stopSpectrum());
    else void this.#startSpectrum();
    for (const t of STATE_TOPICS) {
      const cur = this.#state.get(t);
      if (w.has(t) && !cur && this.#make) {
        const entry = { p: this.#make[t](), last: null as string | null };
        this.#state.set(t, entry);
        // Only the topic's own type is its state; jobDone is an event.
        entry.p.start((m) => {
          if (this.#state.get(t) !== entry) return;
          const s = this.#broadcast(m, t);
          if (m.type === t) entry.last = s;
        });
      } else if (!w.has(t) && cur) {
        this.#state.delete(t);
        stops.push(cur.p.stop());
      }
    }
    await Promise.all(stops);
  }

  #loop(fn: (signal: AbortSignal) => Promise<void>): Loop {
    const abort = new AbortController();
    return { abort, done: fn(abort.signal).catch((e) => this.#log("ekran modu akışı hata verdi", e)) };
  }

  async #end(l: Loop) {
    l.abort.abort();
    await l.done;
  }

  #broadcast(msg: Rec, topic: Topic, droppable = false) {
    const s = JSON.stringify(msg);
    for (const [sock, topics] of this.#subs) {
      if (!topics.has(topic) || sock.readyState !== 1 || (droppable && sock.bufferedAmount > this.#o.maxBuffered)) continue;
      sock.send(s);
    }
    return s;
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
        this.#musicMsg = this.#broadcast(music, "music");
        if (id !== track) {
          track = id;
          const lyrics = id ? await this.#io.velour({ op: "lyrics" }, signal).catch(() => null) : null;
          if (signal.aborted) break;
          this.#lyrics = this.#broadcast(id ? lyricsMessage(lyrics, music) : { type: "lyrics", artId: null, title: "", kind: "none", lines: [] }, "music");
        }
        this.#setPlaying(music.playing === true);
        if (r === null) await delay(2000, signal); // a Velour without `rev`: poll
      } catch {
        if (signal.aborted) break;
        if (!down) {
          this.#musicMsg = this.#broadcast({ type: "music", none: true }, "music");
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
      this.#truckMsg = this.#broadcast(sample.msg, "truck", true);
      for (const e of events.update(sample)) this.#broadcast(e as unknown as Rec, "truck");
      await delay(sample.msg.state === "driving" ? this.#o.driveMs : this.#o.idleMs, signal);
    }
  }

  #setPlaying(on: boolean) {
    if (on === this.#playing) return;
    this.#playing = on;
    if (on && this.#wanted().has("spectrum")) void this.#startSpectrum();
    else if (!on) void this.#stopSpectrum();
  }

  async #startSpectrum() {
    if (this.#spectrum || !this.#music) return;
    const analyzer = new SpectrumAnalyzer();
    const sp: Capture = {
      child: null,
      stop: false,
      timer: setInterval(() => {
        const frame = analyzer.frame();
        for (const [sock, topics] of this.#subs) if (topics.has("spectrum") && sock.readyState === 1 && sock.bufferedAmount <= this.#o.maxBuffered) sock.send(frame);
      }, this.#o.frameMs),
    };
    sp.timer.unref?.();
    this.#spectrum = sp;
    const env = { ...process.env, ...sessionBusEnv() };
    const sink = parseSinkName((await this.#io.exec("wpctl", ["inspect", "@DEFAULT_AUDIO_SINK@"], { env, timeoutMs: 5000, allowFail: true }).catch(() => ({ stdout: "" }))).stdout);
    if (sp.stop || this.#spectrum !== sp) return;
    if (!sink) {
      this.#log("ekran modu: varsayılan ses çıkışı bulunamadı");
      return;
    }
    const child = this.#io.spawn("pw-record", pwRecordArgs(sink), env);
    sp.child = child;
    child.stdout?.on("data", (b: Buffer) => analyzer.pushBytes(b));
    child.on("error", () => {});
    // Stopped while pw-record was being spawned: it must not outlive the capture.
    if (sp.stop) await killChild(child, this.#o.killGraceMs);
  }

  async #stopSpectrum() {
    const sp = this.#spectrum;
    if (!sp) return;
    this.#spectrum = null;
    sp.stop = true;
    clearInterval(sp.timer);
    if (sp.child) await killChild(sp.child, this.#o.killGraceMs);
  }
}

async function killChild(c: Child, graceMs: number) {
  if (c.exitCode !== null || c.signalCode !== null) return;
  const exited = new Promise<void>((r) => c.on("exit", () => r()));
  c.kill("SIGTERM");
  const t = setTimeout(() => c.kill("SIGKILL"), graceMs);
  await exited;
  clearTimeout(t);
}

/** GET /v1/screen/game/source body. */
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
  };
}

const HEARTBEAT = JSON.stringify({ type: "hb" });

/** Source routes on a shared producer (the display side's `self` source uses the same one). */
export function sourceRoutes(app: FastifyInstance, ctx: Ctx, o: SourceOpts & { feed?: FeedProducer } = {}) {
  const io = o.io ?? realSourceIo();
  const feed = o.feed ?? new FeedProducer(io, { ...o, producers: o.producers ?? realProducers(ctx) }, (msg, err) => app.log.warn({ err }, msg));
  app.addHook("onClose", async () => feed.closeAll());

  // Topics come with `{type:"subscribe", topics, project?}` (replaces the set). A token with only the older
  // "gamemode" scope gets the Game mode topics; devices and "screen" tokens get every topic.
  app.get("/v1/screen/feed", { websocket: true, config: { scope: ["screen", "gamemode"] } }, (socket, req) => {
    const sock = socket as unknown as Sock;
    const allowed = !req.service || (req.service.scopes as string[]).includes("screen") ? TOPICS : GAMEMODE_TOPICS;
    void feed.add(sock, []);
    const hb = setInterval(() => sock.readyState === 1 && sock.send(HEARTBEAT), o.heartbeatMs ?? 5000);
    hb.unref?.();
    const gone = () => {
      clearInterval(hb);
      feed.group?.gone(sock);
      void feed.remove(sock);
    };
    socket.on("close", gone);
    socket.on("error", gone);
    socket.on("message", (d: Buffer) => {
      if (d.length > 4096) return;
      let m: { type?: unknown; topics?: unknown; project?: unknown; ci?: unknown; t?: unknown };
      try {
        m = JSON.parse(d.toString()) as typeof m;
      } catch {
        return;
      }
      // Sleep group (PLAN.md §21 S3, sleep_group.ts): a member's clock ping is answered at once with this clock.
      if (allowed === TOPICS && m?.type === "clockPing") {
        if (typeof m.t === "number" && Number.isFinite(m.t) && sock.readyState === 1) sock.send(JSON.stringify({ type: "clockPong", t: m.t, peer: Date.now() }));
        return;
      }
      if (allowed === TOPICS && m?.type === "sleepGroup") return void feed.group?.message(sock, m);
      const topics = m?.type === "subscribe" ? parseTopics(m.topics, allowed) : null;
      const project = topics ? parseProject(m.project, m.ci) : null;
      if (topics && project) void feed.setTopics(sock, topics, project);
    });
  });

  // The 0.5 feed (one release): every Game mode topic from the start, nothing accepted from subscribers.
  app.get("/v1/gamemode/feed", { websocket: true, config: { scope: ["gamemode", "screen"] } }, (socket) => {
    const sock = socket as unknown as Sock;
    void feed.add(sock, GAMEMODE_TOPICS);
    const gone = () => void feed.remove(sock);
    socket.on("close", gone);
    socket.on("error", gone);
    socket.on("message", () => {});
  });

  for (const base of ["/v1/screen/game", "/v1/gamemode"]) {
    app.get(`${base}/source`, async () => sourceStatus(io));
    app.post(`${base}/plugin`, async (req) => {
      const { action } = z.strictObject({ action: z.enum(["install", "remove"]) }).parse(req.body);
      const dir = await findGameDir();
      if (!dir) throw new AppError("agent.gamemode.noGame", 404);
      if (action === "install") await installPlugin(dir);
      else await removePlugin(dir);
      return sourceStatus(io);
    });
  }

  return feed;
}

/** The uptime bridge's and the incident room's current state (both in memory). */
export function serversState(ctx: Ctx): ServersState {
  const b = ctx.uptime;
  const inc = ctx.incidents;
  return {
    monitors: b ? b.list().map((m) => ({ name: m.name, status: m.status, since: b.important.get(m.id)?.[0]?.time ?? null })) : null,
    connected: b ? b.state.connected && b.state.loggedIn : false,
    incidents: inc ? inc.list("active", 1000).length : null,
  };
}

/** Real Work mode producers of this host. Modules registered later (Claude, uptime, incidents) are read from ctx lazily. */
export function realProducers(ctx: Ctx): Producers {
  const claudeDir = expandHome("~/.claude");
  return {
    make: {
      system: () => new SystemProducer(),
      jobs: () => new JobsProducer(),
      servers: () => new ServersProducer(() => serversState(ctx)),
    },
    git: {
      io: realGitIo,
      resolve: (path) => resolveProject(ctx.store.get(), path),
      selector: (onChange) =>
        new ProjectSelector(
          realSelectorIo({
            tiphys: () => [...(ctx.claude?.sessions.values() ?? [])].map((s) => ({ cwd: s.cwd, at: s.lastActivity })),
            terminal: async () =>
              (await terminalSessions(claudeDir)).filter((t) => t.cwd).map((t) => ({ cwd: t.cwd!, at: Date.parse(t.updatedAt ?? t.startedAt ?? "") || 0 })),
            sessionsDir: join(claudeDir, "sessions"),
            focus: process.platform === "linux" ? focusPids(ctx) : null,
          }),
          onChange,
        ),
      city: { io: realCityIo, share: () => ctx.store.get().screen.share.code },
    },
    claude: {
      // The manager is registered with the claude feature (maybe later than the screen routes): read when it starts.
      manager: () => (ctx.claude ?? null) as ManagerLike | null,
      configDirs: () => [...new Set([claudeDir, ...Object.values(ctx.store.get().claude.profiles).map((d) => expandHome(d))])],
      io: realClaudeIo(),
      share: () => ctx.store.get().screen.share.code,
    },
  };
}

/** Focused window pid from the Hyprland event socket (one shared listener while subscribed). */
function focusPids(ctx: Ctx) {
  let watcher: FocusWatcher | null = null;
  return (fn: (pid: number | null) => void) => {
    watcher ??= new FocusWatcher({ exec: run, hyprEnv, connect: realConnect }, { apps: () => ctx.desktopApps?.() ?? Promise.resolve([]) });
    return watcher.subscribe((f) => fn(f.pid));
  };
}
