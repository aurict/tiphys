// Screen mode display side (PLAN.md §19, §20; e.g. the laptop): settings, the kiosk lifecycle and its placement, the
// relay from the source agents (and the in-process `self` source), the kiosk page's live WebSocket, the cover proxy
// and the static page.
// Lifecycle (start {mode}): tmpfs work dir $XDG_RUNTIME_DIR/tiphys-screen/ (0700) with an empty Firefox profile (light
// prefs), a state file, a temporary Hyprland window rule for the app id `tiphys-screen` and, for the scratch placement,
// a temporary keybind (placement.ts); the previous workspace and backlight are remembered; then ONE transient unit:
//   systemd-run --user --unit=tiphys-screen --collect -p StandardOutput=null -p StandardError=null --setenv=… --
//     systemd-inhibit --what=idle:sleep --why=… firefox --kiosk --no-remote --name tiphys-screen --profile <dir> <url>
// The display token (32 random bytes, memory only) is NOT on the command line (/proc/*/cmdline is readable by every
// local user): <url> is file://<work dir>/start.html (0600 in the 0700 tmpfs dir), which forwards to
// http://127.0.0.1:<port>/screen/#t=<token>.
// Every side effect is written to the state file before it is made. Stop: systemctl --user stop (the whole cgroup
// dies) → work dir removed → keybind and rule off → workspace and backlight restored → token invalid, page sockets
// and source subscriptions closed. A crash leaves the state file: the next start of the agent finishes the stop (also
// for a 0.5 Game mode left in $XDG_RUNTIME_DIR/tiphys-gamemode/).
// Mode switch (POST /v1/screen/mode): the page gets a `layout` message and the subscriptions follow; Firefox stays.
// Visibility (visibility.ts): not on screen → `pause` to the page (it stops drawing) and the pausable topics are
// dropped; `resume` when shown. Events: only screen.started {mode} / screen.stopped. Fixed commands only.
import { randomBytes, timingSafeEqual } from "node:crypto";
import { createReadStream, existsSync } from "node:fs";
import { mkdir, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { extname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { gameSettingsSchema, MODE_SCHEMAS, SCREEN_MODES, screenSchema, sourceName, type ModeSettings, type ScreenConfig, type ScreenMode } from "../config.ts";
import type { Exec } from "../control.ts";
import { whichIn } from "../detect.ts";
import { AppError } from "../errors.ts";
import { run } from "../exec.ts";
import type { EventSocket } from "../focus.ts";
import type { HyprMode } from "../hyprctl.ts";
import { Hyprctl } from "../hyprctl.ts";
import { imageType } from "../routes/media.ts";
import type { Ctx } from "../server.ts";
import { APP_ID, bindOffArgs, bindOnArgs, bindTaken, kioskWindow, moveToSpecialArgs, ruleOffArgs, ruleOnArgs, SPECIAL, toggleSpecialArgs, WORKSPACES, type Placement } from "./placement.ts";
import type { FeedProducer, Sock } from "./source.ts";
import type { ProjectSpec } from "./producers/project.ts";
import { checkLayout, layoutTopics, MESSAGE_TOPIC, STATE_TYPES, type Topic } from "./topics.ts";
import { VisibilityWatcher, type VisibilityOpts } from "./visibility.ts";

export const UNIT = "tiphys-screen";
export { APP_ID } from "./placement.ts";
/** What a 0.5 Game mode left behind (crash recovery only). */
const LEGACY = { unit: "tiphys-gamemode", rule: "tiphys-gamemode", appId: "tiphys-gamemode", dir: "tiphys-gamemode" };
const CURRENT = { unit: UNIT, rule: "tiphys-screen", appId: APP_ID, dir: "tiphys-screen" };
type Names = typeof CURRENT;
const ART_MAX = 5 * 1024 * 1024;

// ---- outside world ----

/** Minimal WebSocket client surface (the global WebSocket; a fake in tests). */
export interface Upstream {
  readonly readyState: number;
  binaryType: string;
  onopen: (() => void) | null;
  onmessage: ((ev: { data: unknown }) => void) | null;
  onclose: (() => void) | null;
  onerror: (() => void) | null;
  send(data: string): void;
  close(code?: number): void;
}

export interface DisplayIo {
  exec: Exec;
  runtimeDir: string;
  hyprEnv(): Promise<NodeJS.ProcessEnv>;
  waylandEnv(): Promise<NodeJS.ProcessEnv>;
  busEnv(): NodeJS.ProcessEnv;
  which(cmd: string): boolean;
  connect(url: string, token: string): Upstream;
  fetch: typeof fetch;
  /** Hyprland event socket (visibility); without it the page is never paused. */
  hyprEvents?(path: string): EventSocket;
}

export async function realDisplayIo(): Promise<DisplayIo> {
  const [{ hyprEnv }, { waylandEnv, sessionBusEnv }, { realConnect }] = await Promise.all([import("../routes/hypr.ts"), import("../routes/desktop.ts"), import("../focus.ts")]);
  return {
    exec: run,
    runtimeDir: process.env.XDG_RUNTIME_DIR?.startsWith("/") ? process.env.XDG_RUNTIME_DIR : `/run/user/${process.getuid?.() ?? 1000}`,
    hyprEnv,
    waylandEnv,
    busEnv: sessionBusEnv,
    which: (c) => whichIn(process.env.PATH, c),
    // Node's WebSocket (undici) takes request headers in its init object.
    connect: (url, token) => new (WebSocket as unknown as new (u: string, init: object) => Upstream)(url, { headers: { authorization: `Bearer ${token}` } }),
    fetch,
    hyprEvents: realConnect,
  };
}

// ---- command construction (pure; tested) ----

/**
 * Firefox prefs of the throwaway profile: no session restore, telemetry, updates or first-run pages; WebRender on;
 * the light profile of PLAN.md §20 (one content process, no Fission, no prelaunch, small memory cache, no disk cache
 * on the tmpfs, no prefetching): ~8 % less memory measured in W0.
 */
export function userJs(): string {
  const prefs: Record<string, string | number | boolean> = {
    "browser.sessionstore.resume_from_crash": false,
    "browser.sessionstore.max_resumed_crashes": 0,
    "browser.startup.page": 0,
    "browser.startup.homepage_override.mstone": "ignore",
    "startup.homepage_welcome_url": "",
    "startup.homepage_welcome_url.additional": "",
    "startup.homepage_override_url": "",
    "browser.aboutwelcome.enabled": false,
    "trailhead.firstrun.didSeeAboutWelcome": true,
    "browser.shell.checkDefaultBrowser": false,
    "browser.tabs.warnOnClose": false,
    "browser.warnOnQuit": false,
    "browser.aboutConfig.showWarning": false,
    "browser.newtabpage.enabled": false,
    "browser.newtabpage.activity-stream.feeds.telemetry": false,
    "browser.newtabpage.activity-stream.telemetry": false,
    "browser.translations.automaticallyPopup": false,
    "browser.discovery.enabled": false,
    "datareporting.policy.dataSubmissionEnabled": false,
    "datareporting.healthreport.uploadEnabled": false,
    "datareporting.policy.firstRunURL": "",
    "toolkit.telemetry.enabled": false,
    "toolkit.telemetry.unified": false,
    "toolkit.telemetry.archive.enabled": false,
    "toolkit.telemetry.reportingpolicy.firstRun": false,
    "toolkit.coverage.opt-out": true,
    "browser.ping-centre.telemetry": false,
    "browser.crashReports.unsubmittedCheck.autoSubmit2": false,
    "browser.tabs.crashReporting.sendReport": false,
    "app.update.auto": false,
    "app.update.enabled": false,
    "app.normandy.enabled": false,
    "app.shield.optoutstudies.enabled": false,
    "extensions.update.enabled": false,
    "extensions.pocket.enabled": false,
    "browser.safebrowsing.malware.enabled": false,
    "browser.safebrowsing.phishing.enabled": false,
    "browser.safebrowsing.downloads.enabled": false,
    "network.captive-portal-service.enabled": false,
    "network.connectivity-service.enabled": false,
    "network.prefetch-next": false,
    "network.dns.disablePrefetch": true,
    "network.predictor.enabled": false,
    "browser.urlbar.speculativeConnect.enabled": false,
    "signon.rememberSignons": false,
    "dom.disable_beforeunload": true,
    "dom.ipc.processCount": 1,
    "dom.ipc.processPrelaunch.enabled": false,
    "fission.autostart": false,
    "browser.cache.disk.enable": false,
    "browser.cache.memory.capacity": 32768,
    "full-screen-api.warning.timeout": 0,
    "full-screen-api.transition-duration.enter": "0 0",
    "full-screen-api.transition-duration.leave": "0 0",
    "gfx.webrender.all": true,
    "layers.acceleration.force-enabled": true,
    "media.hardware-video-decoding.enabled": true,
  };
  return Object.entries(prefs).map(([k, v]) => `user_pref(${JSON.stringify(k)}, ${JSON.stringify(v)});`).join("\n") + "\n";
}

/** The forwarding page in the work dir (the only place the token is written). */
export function startHtml(url: string): string {
  const u = JSON.stringify(url).replace(/</g, "\\u003c");
  return `<!doctype html><meta charset="utf-8"><meta name="referrer" content="no-referrer"><style>html{background:#000}</style><script>location.replace(${u})</script>\n`;
}

/** systemd-run arguments of the kiosk unit. */
export function kioskArgs(o: { firefox: string; profile: string; url: string; env: NodeJS.ProcessEnv }): string[] {
  const keep = ["WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "HYPRLAND_INSTANCE_SIGNATURE", "DBUS_SESSION_BUS_ADDRESS"];
  const setenv = keep.filter((k) => o.env[k]).map((k) => `--setenv=${k}=${o.env[k]}`);
  return [
    "--user", `--unit=${UNIT}`, "--collect", "-p", "StandardOutput=null", "-p", "StandardError=null",
    ...setenv, "--setenv=MOZ_ENABLE_WAYLAND=1",
    "--", "systemd-inhibit", "--what=idle:sleep", "--why=Tiphys Ekran Modu",
    o.firefox, "--kiosk", "--no-remote", "--name", APP_ID, "--profile", o.profile, o.url,
  ];
}

/** Workspace target remembered at start: "3" or "name:foo" (validated; anything else isn't restored). */
const WS_TARGET = /^(?:[1-9]\d{0,2}|name:[A-Za-z0-9_.-]{1,64})$/;

/** `hyprctl -j activeworkspace` → a restorable target. */
export function workspaceTarget(json: string): string | null {
  try {
    const w = JSON.parse(json) as { id?: unknown; name?: unknown };
    const t = typeof w.id === "number" && w.id > 0 ? String(w.id) : typeof w.name === "string" ? `name:${w.name}` : null;
    return t && WS_TARGET.test(t) ? t : null;
  } catch {
    return null;
  }
}

export function focusWorkspaceArgs(mode: HyprMode, target: string): string[] {
  if (!WS_TARGET.test(target)) throw new AppError("agent.request.invalid", 400);
  return mode === "lua" ? ["eval", `hl.dispatch(hl.dsp.focus({ workspace = "${target}" }))`] : ["dispatch", "workspace", target];
}

/** `brightnessctl -m` → the current raw value ("intel_backlight,backlight,96000,100%,96000"). */
export function parseBrightness(out: string): string | null {
  const v = out.trim().split("\n")[0]?.split(",")[2];
  return v && /^\d{1,9}$/.test(v) ? v : null;
}

// ---- state ----

/** The state file: everything to undo. Written before each step. */
interface SavedState {
  startedAt: string;
  mode: ScreenMode;
  hypr: HyprMode | null;
  placement: Placement;
  /** Our workspace: the named one (fullscreen) or SPECIAL (scratch). */
  ws: string;
  rules: boolean;
  /** The temporary scratch keybind ("SUPER,grave") while set. */
  bind: string | null;
  workspace: string | null;
  brightness: string | null;
}

export type SourceState = "off" | "connecting" | "ok" | "down";

interface Conn {
  name: string;
  topics: Set<Topic>;
  project: ProjectSpec;
  ws: Upstream | null;
  state: SourceState;
  retryInSec?: number;
  attempt: number;
  timer: NodeJS.Timeout | null;
  idle: NodeJS.Timeout | null;
  /** Talk the 0.5 feed (/v1/gamemode/feed, every topic, no subscribe): a source that has no /v1/screen/feed yet. */
  legacy: boolean;
  opened: boolean;
}

type Rec = Record<string, unknown>;

interface Latest {
  music: Rec | null;
  truck: Rec | null;
  /** Latest tagged state message per type (STATE_TYPES), replayed to a new page or layout. */
  raw: Map<string, string>;
  /** The latest city with the patches since folded in (path → entry); `raw` "city" is rebuilt from it when stale. */
  city: { msg: Rec; files: Map<string, unknown[]>; stale: boolean } | null;
}

export interface DisplayOpts {
  io?: DisplayIo;
  /** The shared producer of this host (the `self` source); none = `self` cards stay empty. */
  feed?: FeedProducer;
  /** Upstream reconnect delays (s). */
  backoff?: number[];
  /** Reconnect when a feed is silent this long (heartbeat every 5 s; the 0.5 feed sends truck every second). */
  idleMs?: number;
  /** How often the kiosk unit is checked while running. */
  watchMs?: number;
  displayDir?: string | null;
  mapDir?: string;
  maxBuffered?: number;
  visibility?: VisibilityOpts;
}

const emptyLatest = (): Latest => ({ music: null, truck: null, raw: new Map(), city: null });
/** A city snapshot may be large (20 000 files ≈ 1.5 MB); every other message stays under 1 MB. */
const maxMessage = (data: string) => (data.startsWith('{"type":"city"') ? 16 * 1024 * 1024 : 1024 * 1024);
const sameSet = (a: Set<Topic>, b: Set<Topic>) => a.size === b.size && [...a].every((x) => b.has(x));
const sameProject = (a: ProjectSpec, b: ProjectSpec) => a.project === b.project && a.ci === b.ci;

/** Turns a screen error into the old Game mode code for the /v1/gamemode aliases (app 1.2 knows only those). */
export function legacyError(e: unknown): unknown {
  if (e instanceof AppError && /^agent\.screen\.(noSource|noDisplay|startFailed|noArt)$/.test(e.code)) {
    return new AppError(e.code.replace("agent.screen.", "agent.gamemode."), e.status, e.params);
  }
  return e;
}

export class ScreenDisplay {
  readonly #ctx: Ctx;
  readonly #io: DisplayIo;
  readonly #feed: FeedProducer | null;
  readonly #o: { backoff: number[]; idleMs: number; watchMs: number; maxBuffered: number; visibility: VisibilityOpts };
  readonly #log: (msg: string, err?: unknown) => void;
  readonly workDir: string;
  readonly #mapFile: string;
  #chain: Promise<unknown> = Promise.resolve();
  #running: SavedState | null = null;
  #token: Buffer | null = null;
  readonly #pages = new Set<Sock>();
  #watch: NodeJS.Timeout | null = null;
  #vis: VisibilityWatcher | null = null;
  #paused = false;
  /** Scratch: the special workspace is shown once, when the page first connects after a start. */
  #shown = false;
  #self: { sock: Sock; topics: Set<Topic>; project: ProjectSpec } | null = null;
  readonly #conns = new Map<string, Conn>();
  readonly #latest = new Map<string, Latest>();
  readonly #art = new Map<string, { type: string; bytes: Buffer }>();

  constructor(ctx: Ctx, io: DisplayIo, o: DisplayOpts, log: (msg: string, err?: unknown) => void) {
    this.#ctx = ctx;
    this.#io = io;
    this.#feed = o.feed ?? null;
    this.#log = log;
    this.#o = { backoff: o.backoff ?? [1, 2, 4, 8, 15, 30], idleMs: o.idleMs ?? 15_000, watchMs: o.watchMs ?? 5000, maxBuffered: o.maxBuffered ?? 256 * 1024, visibility: o.visibility ?? {} };
    this.workDir = join(io.runtimeDir, CURRENT.dir);
    this.#mapFile = join(o.mapDir ?? defaultMapDir(), "ets2.pmtiles");
  }

  #serial<T>(fn: () => Promise<T>): Promise<T> {
    const p = this.#chain.then(fn);
    this.#chain = p.catch(() => {});
    return p;
  }

  get #cfg(): ScreenConfig {
    return this.#ctx.store.get().screen;
  }

  #settings(mode: ScreenMode): ModeSettings {
    const { layout: _layout, ...s } = this.#cfg.modes[mode];
    return s as ModeSettings;
  }

  /** The page's `layout` message: template, cards and the mode's settings. */
  #layoutMsg(mode: ScreenMode) {
    const m = this.#cfg.modes[mode];
    return JSON.stringify({ type: "layout", mode, template: m.layout.template, cards: m.layout.cards, settings: this.#settings(mode) });
  }

  /** A new layout rebuilds the page's cards: they get the latest state again right after it. */
  #sendLayout(mode: ScreenMode) {
    this.#sendPages(this.#layoutMsg(mode));
    for (const m of this.#replay()) this.#sendPages(m);
  }

  /** The latest state messages of every source (a city with its patches folded in). */
  #replay(): string[] {
    const out: string[] = [];
    for (const [src, l] of this.#latest) {
      if (l.city?.stale) {
        l.raw.set("city", JSON.stringify({ src, ...l.city.msg, files: [...l.city.files.values()] }));
        l.city.stale = false;
      }
      out.push(...l.raw.values());
    }
    return out;
  }

  /** What the git and city topics watch: the Work mode's project and CI setting. */
  #project(mode: ScreenMode): ProjectSpec {
    if (mode !== "work") return { project: "auto", ci: false };
    const w = this.#cfg.modes.work;
    return { project: w.project === "auto" ? "auto" : w.project.path, ci: w.ci };
  }

  /** Source names the mode needs that aren't configured. */
  #missing(mode: ScreenMode): string[] {
    const need = layoutTopics(mode, this.#cfg.modes[mode].layout, this.#settings(mode));
    return [...need.keys()].filter((n) => n !== "self" && !(n in this.#cfg.sources));
  }

  #live() {
    let m: Rec | null = null;
    let t: Rec | null = null;
    for (const l of this.#latest.values()) {
      m ??= l.music;
      t ??= l.truck;
    }
    const job = t && typeof t.job === "object" && t.job ? (t.job as Rec) : null;
    return {
      music: m && !m.none ? { title: m.title ?? "", artist: m.artist ?? "", playing: m.playing === true } : null,
      truck: t ? { state: t.state, from: job?.from ?? null, to: job?.to ?? null, speedKmh: typeof t.speed === "number" ? Math.round(Math.abs(t.speed) * 3.6) : null } : null,
    };
  }

  status() {
    const c = this.#cfg;
    const r = this.#running;
    const topics = (s: Set<Topic> | undefined) => [...(s ?? [])].sort();
    return {
      running: r !== null,
      mode: r?.mode ?? null,
      startedAt: r?.startedAt ?? null,
      placement: r?.placement ?? c.placement,
      visible: r ? !this.#paused : null,
      settings: { placement: c.placement, scratchBind: c.scratchBind, lastMode: c.lastMode, batterySaver: c.batterySaver, share: c.share, modes: c.modes },
      sources: [
        { name: "self", url: null, state: this.#self ? "ok" : "off", topics: topics(this.#self?.topics) },
        ...Object.entries(c.sources).map(([name, s]) => {
          const conn = this.#conns.get(name);
          return { name, url: s.url, state: conn?.state ?? "off", topics: topics(conn?.topics) };
        }),
      ],
      // Focus timer: W5.
      focus: { phase: "idle", endsAt: null, pausedLeft: null, round: 0, task: null },
      // The map files live on this (display) host, next to the page that draws them.
      map: { present: existsSync(this.#mapFile) },
      live: this.#live(),
    };
  }

  /** GET /v1/gamemode (one release): the 0.5 shape, the source being `main`. */
  legacyStatus() {
    const main = this.#cfg.sources.main;
    return {
      running: this.#running !== null,
      startedAt: this.#running?.startedAt ?? null,
      settings: this.#settings("game"),
      source: { configured: main !== undefined, url: main?.url ?? null, state: this.#conns.get("main")?.state ?? "off" },
      map: { present: existsSync(this.#mapFile) },
      live: this.#live(),
    };
  }

  /** Display token check (constant time). */
  validToken(t: unknown): boolean {
    if (!this.#token || typeof t !== "string" || t.length !== 64) return false;
    const b = Buffer.from(t, "utf8");
    return b.length === this.#token.length && timingSafeEqual(b, this.#token);
  }

  // ---- lifecycle ----

  #stateFile = (dir = this.workDir) => join(dir, "state.json");

  async #save(s: SavedState) {
    await writeFile(this.#stateFile(), JSON.stringify(s) + "\n", { mode: 0o600 });
  }

  async #hypr(env: NodeJS.ProcessEnv, args: string[]) {
    const r = await this.#io.exec("hyprctl", args, { env, timeoutMs: 5000, allowFail: true });
    const ok = args[0] === "-j" || r.stdout.split("\n").map((l) => l.trim()).filter(Boolean).every((l) => l === "ok");
    if (r.code !== 0 || !ok) throw new AppError("agent.desktop.hyprctlFailed", 502, { output: r.stdout.trim().slice(0, 200) });
    return r.stdout;
  }

  /** Starts `mode` (default: the last one). While running, a different mode is a hot switch. */
  start(mode?: ScreenMode, device?: string) {
    return this.#serial(async () => {
      const m = mode ?? this.#cfg.lastMode;
      if (this.#running) return this.#running.mode === m ? this.status() : this.#switch(m);
      const missing = this.#missing(m);
      if (missing.length) throw new AppError("agent.screen.noSource", 409, { sources: missing });
      let env: NodeJS.ProcessEnv;
      try {
        env = { ...(await this.#io.waylandEnv()), ...(await this.#io.hyprEnv()), ...this.#io.busEnv() };
      } catch {
        throw new AppError("agent.screen.noDisplay", 503);
      }
      const firefox = ["firefox", "firefox-esr"].find((c) => this.#io.which(c));
      if (!firefox) throw new AppError("agent.exec.commandMissing", 500, { command: "firefox" });
      // A leftover unit (e.g. from a crash) would make systemd-run fail.
      await this.#io.exec("systemctl", ["--user", "stop", `${UNIT}.service`], { env, timeoutMs: 15_000, allowFail: true });
      await rm(this.workDir, { recursive: true, force: true });
      await mkdir(join(this.workDir, "profile"), { recursive: true, mode: 0o700 });
      const token = randomBytes(32).toString("hex");
      const placement = this.#cfg.placement;
      const state: SavedState = {
        startedAt: new Date().toISOString(), mode: m, hypr: null, placement, ws: placement === "scratch" ? SPECIAL : WORKSPACES[m],
        rules: false, bind: null, workspace: null, brightness: null,
      };
      await this.#save(state);
      try {
        const hypr = new Hyprctl(this.#io.exec, async () => env);
        state.hypr = await hypr.mode(env);
        if (placement === "scratch") {
          const bind = this.#cfg.scratchBind;
          if (bindTaken(await this.#hypr(env, ["-j", "binds"]), bind)) throw new AppError("agent.screen.bindTaken", 409, { bind });
          state.bind = bind;
          await this.#save(state);
          await this.#hypr(env, bindOnArgs(state.hypr, bind));
        } else state.workspace = workspaceTarget(await this.#hypr(env, ["-j", "activeworkspace"]).catch(() => ""));
        state.rules = true;
        await this.#save(state);
        for (const args of ruleOnArgs(state.hypr, placement, state.ws)) await this.#hypr(env, args);
        const b = this.#settings(m).brightness;
        if (b !== null) state.brightness = await this.#setBrightness(b, null);
        await this.#save(state);
        await writeFile(join(this.workDir, "profile", "user.js"), userJs(), { mode: 0o600 });
        const startFile = join(this.workDir, "start.html");
        await writeFile(startFile, startHtml(`${this.#pageBase()}#t=${token}`), { mode: 0o600 });
        // Show the empty named workspace first: Firefox maps straight onto it (no flash of the old workspace).
        if (placement === "fullscreen") await this.#hypr(env, focusWorkspaceArgs(state.hypr, `name:${state.ws}`)).catch(() => {});
        const r = await this.#io.exec("systemd-run", kioskArgs({ firefox, profile: join(this.workDir, "profile"), url: `file://${startFile}`, env }), {
          env, timeoutMs: 15_000, allowFail: true,
        });
        if (r.code !== 0) throw new AppError("agent.screen.startFailed", 502, { stderr: r.stderr.slice(0, 300) });
      } catch (e) {
        await this.#cleanup(state, env).catch(() => {});
        throw e;
      }
      this.#token = Buffer.from(token, "utf8");
      this.#running = state;
      this.#paused = false;
      this.#shown = false;
      this.#watchVisibility(state);
      this.#resubscribe();
      this.#watch = setInterval(() => void this.#checkUnit(), this.#o.watchMs);
      this.#watch.unref?.();
      this.#event("screen.started", device, { mode: m });
      await this.#rememberMode(m);
      return this.status();
    });
  }

  /** Hot switch: new layout on the page, subscriptions and backlight follow; Firefox stays. */
  switchMode(mode: ScreenMode) {
    return this.#serial(async () => {
      if (!this.#running) {
        await this.#rememberMode(mode);
        return this.status();
      }
      return this.#switch(mode);
    });
  }

  async #switch(mode: ScreenMode) {
    const st = this.#running!;
    if (st.mode === mode) return this.status();
    const missing = this.#missing(mode);
    if (missing.length) throw new AppError("agent.screen.noSource", 409, { sources: missing });
    st.mode = mode;
    await this.#save(st).catch(() => {});
    await this.#applyBrightness(this.#settings(mode).brightness);
    this.#sendLayout(mode);
    this.#resubscribe();
    await this.#rememberMode(mode);
    return this.status();
  }

  async #rememberMode(mode: ScreenMode) {
    if (this.#cfg.lastMode === mode) return;
    await this.#ctx.store.update((c) => ((c.screen.lastMode = mode), c)).catch((e) => this.#log("ekran modu ayarı yazılamadı", e));
  }

  stop(device?: string) {
    return this.#serial(async () => {
      const state = this.#running;
      if (!state) return this.status();
      await this.#stopNow(state);
      this.#event("screen.stopped", device);
      return this.status();
    });
  }

  async #stopNow(state: SavedState) {
    this.#running = null;
    this.#token = null;
    if (this.#watch) clearInterval(this.#watch);
    this.#watch = null;
    this.#vis?.stop();
    this.#vis = null;
    this.#paused = false;
    for (const p of [...this.#pages]) if (p.readyState === 0 || p.readyState === 1) p.close(4410, "stopped");
    this.#pages.clear();
    this.#unsubscribeAll();
    const env = await this.#env();
    await this.#cleanup(state, env);
  }

  async #env(): Promise<NodeJS.ProcessEnv> {
    const env: NodeJS.ProcessEnv = { ...process.env, XDG_RUNTIME_DIR: this.#io.runtimeDir, ...this.#io.busEnv() };
    return { ...env, ...(await this.#io.hyprEnv().catch(() => ({}))) };
  }

  /** Undoes everything the state says was done; every step is best effort. */
  async #cleanup(state: SavedState, env: NodeJS.ProcessEnv, names: Names = CURRENT) {
    const dir = join(this.#io.runtimeDir, names.dir);
    await this.#io.exec("systemctl", ["--user", "stop", `${names.unit}.service`], { env, timeoutMs: 20_000, allowFail: true }).catch((e) => this.#log("ekran modu birimi durdurulamadı", e));
    await rm(dir, { recursive: true, force: true }).catch((e) => this.#log("ekran modu dizini silinemedi", e));
    if (env.HYPRLAND_INSTANCE_SIGNATURE) {
      const mode = state.hypr ?? (await new Hyprctl(this.#io.exec, async () => env).mode(env).catch(() => "legacy" as const));
      if (state.bind) await this.#hypr(env, bindOffArgs(mode, state.bind)).catch((e) => this.#log("ekran modu kısayolu geri alınamadı", e));
      if (state.rules) for (const args of ruleOffArgs(mode, names.rule, names.appId)) await this.#hypr(env, args).catch((e) => this.#log("ekran modu pencere kuralı geri alınamadı", e));
      if (state.workspace && state.placement === "fullscreen") {
        // Only if the user is still on the mode's workspace.
        const now = await this.#hypr(env, ["-j", "activeworkspace"]).catch(() => "");
        let name: unknown = null;
        try {
          name = (JSON.parse(now) as { name?: unknown }).name;
        } catch {}
        if (name === state.ws) await this.#hypr(env, focusWorkspaceArgs(mode, state.workspace)).catch(() => {});
      }
    }
    if (state.brightness) await this.#brightnessctl(["-q", "set", state.brightness]).catch(() => {});
  }

  /** Sets the backlight to `percent`; returns the value to restore later (the saved one, or the current one). */
  async #setBrightness(percent: number, saved: string | null): Promise<string | null> {
    const old = saved ?? parseBrightness((await this.#brightnessctl(["-m"]).catch(() => ({ stdout: "" }))).stdout);
    // No permission on the backlight (no udev rule / video group): the mode runs without touching it.
    const r = await this.#brightnessctl(["-q", "set", `${percent}%`]).catch(() => ({ code: -1 }));
    return r.code === 0 ? old : saved;
  }

  /** The running mode's backlight setting changed (or the mode did): set it, or restore the saved value. */
  async #applyBrightness(percent: number | null) {
    const st = this.#running;
    if (!st) return;
    if (percent !== null) st.brightness = await this.#setBrightness(percent, st.brightness);
    else if (st.brightness) {
      await this.#brightnessctl(["-q", "set", st.brightness]).catch(() => {});
      st.brightness = null;
    }
    await this.#save(st).catch(() => {});
  }

  #brightnessctl(args: string[]) {
    if (!this.#io.which("brightnessctl")) return Promise.reject(new Error("brightnessctl missing"));
    return this.#io.exec("brightnessctl", args, { timeoutMs: 5000, allowFail: true });
  }

  /** Finishes a mode a crashed agent left behind (state file in the tmpfs work dir; also a 0.5 Game mode's). */
  recover() {
    return this.#serial(async () => {
      let found = false;
      for (const names of [CURRENT, LEGACY]) {
        const dir = join(this.#io.runtimeDir, names.dir);
        let state: SavedState;
        try {
          state = sanitizeState(JSON.parse(await readFile(this.#stateFile(dir), "utf8")) as Rec);
        } catch {
          // No state file: a stray work dir or unit from an older run is still removed.
          if (await stat(dir).then(() => true, () => false)) await this.#cleanup(sanitizeState({}), await this.#env(), names);
          continue;
        }
        await this.#cleanup(state, await this.#env(), names);
        found = true;
      }
      if (found) this.#event("screen.stopped");
      return found;
    });
  }

  async #checkUnit() {
    if (!this.#running) return;
    const r = await this.#io.exec("systemctl", ["--user", "is-active", `${UNIT}.service`], { env: await this.#env(), timeoutMs: 5000, allowFail: true }).catch(() => null);
    // Firefox gone (closed or crashed): finish the stop so nothing is left behind.
    if (r && r.stdout.trim() !== "active" && r.stdout.trim() !== "activating") void this.stop();
  }

  async shutdown() {
    await this.stop();
  }

  #event(key: string, device?: string, params?: Record<string, string>) {
    void this.#ctx.notifier.events?.record({ key, ...(params ? { params } : {}), ...(device ? { device } : {}) }, (e) => this.#log("olay yazılamadı", e));
  }

  #pageBase() {
    const { host, port } = this.#ctx.store.get().listen;
    const h = host === "0.0.0.0" || host === "::" || host === "localhost" ? "127.0.0.1" : host.includes(":") ? `[${host}]` : host;
    return `http://${h}:${port}/screen/`;
  }

  // ---- visibility ----

  #watchVisibility(st: SavedState) {
    if (!this.#io.hyprEvents) return;
    const io = { exec: this.#io.exec, hyprEnv: () => this.#io.hyprEnv(), connect: this.#io.hyprEvents.bind(this.#io) };
    const where = st.placement === "scratch" ? ({ placement: "scratch" } as const) : ({ placement: "fullscreen", workspace: st.ws } as const);
    this.#vis = new VisibilityWatcher(io, where, (visible) => this.#setPaused(!visible), this.#o.visibility);
    this.#vis.start();
  }

  #setPaused(paused: boolean) {
    if (!this.#running || paused === this.#paused) return;
    this.#paused = paused;
    this.#sendPages(JSON.stringify({ type: paused ? "pause" : "resume" }));
    this.#resubscribe();
  }

  /** Scratch: on the first page after a start, make sure the window is in special:tiphys and show it once. */
  async #showScratch() {
    const st = this.#running;
    if (!st || st.placement !== "scratch" || this.#shown || !st.hypr) return;
    this.#shown = true;
    const env = await this.#env();
    const w = kioskWindow(await this.#hypr(env, ["-j", "clients"]).catch(() => ""));
    if (w && w.workspace !== `special:${SPECIAL}`) await this.#hypr(env, moveToSpecialArgs(st.hypr, w.address)).catch((e) => this.#log("ekran penceresi taşınamadı", e));
    if (this.#vis?.visible !== true) await this.#hypr(env, toggleSpecialArgs(st.hypr)).catch((e) => this.#log("ekran gösterilemedi", e));
  }

  // ---- settings ----

  /** PUT /v1/screen. */
  async update(body: z.infer<typeof putSchema>) {
    for (const mode of SCREEN_MODES) {
      const l = body.settings?.modes?.[mode]?.layout;
      if (l) checkLayout(mode, l as never);
    }
    return this.#change((c) => {
      const s = body.settings;
      if (s) {
        for (const k of ["placement", "scratchBind", "lastMode", "batterySaver"] as const) if (s[k] !== undefined) (c as Rec)[k] = s[k];
        if (s.share) c.share = s.share;
        for (const mode of SCREEN_MODES) {
          const p = s.modes?.[mode];
          if (p) (c.modes as Rec)[mode] = MODE_SCHEMAS[mode].parse({ ...c.modes[mode], ...p });
        }
      }
      for (const [name, v] of Object.entries(body.sources ?? {})) {
        if (v === null) delete c.sources[name];
        else c.sources[name] = v;
      }
    });
  }

  /** PUT /v1/gamemode (one release): game settings, and the source as `main` (the game cards then read it). */
  async updateLegacy(body: z.infer<typeof legacyPutSchema>) {
    return this.#change((c) => {
      if (body.settings) c.modes.game = MODE_SCHEMAS.game.parse({ ...c.modes.game, ...body.settings });
      if (body.source !== undefined) {
        if (body.source === null) delete c.sources.main;
        else c.sources.main = body.source;
        c.modes.game.layout.cards = c.modes.game.layout.cards.map((x) => ({ ...x, source: body.source ? "main" : "self" }));
      }
    }).then(() => this.legacyStatus());
  }

  #change(fn: (c: ScreenConfig) => void) {
    return this.#serial(async () => {
      const before = this.#cfg;
      const next = (await this.#ctx.store.update((c) => (fn(c.screen), c))).screen;
      const st = this.#running;
      if (st) {
        const m = st.mode;
        const was = before.modes[m];
        const now = next.modes[m];
        if (JSON.stringify(was.layout) !== JSON.stringify(now.layout)) this.#sendLayout(m);
        else if (JSON.stringify(was) !== JSON.stringify(now)) this.#sendPages(JSON.stringify({ type: "settings", ...this.#settings(m) }));
        if (now.brightness !== was.brightness) await this.#applyBrightness(now.brightness);
        // A changed or removed source: reconnect (or drop) it.
        for (const name of [...this.#conns.keys()]) {
          if (JSON.stringify(before.sources[name]) !== JSON.stringify(next.sources[name])) this.#closeConn(name);
        }
        this.#resubscribe();
      }
      return this.status();
    });
  }

  // ---- sources ----

  /** Makes the subscriptions match the running mode's layout (and visibility). */
  #resubscribe() {
    const st = this.#running;
    const need = st ? layoutTopics(st.mode, this.#cfg.modes[st.mode].layout, this.#settings(st.mode), this.#paused) : new Map<string, Set<Topic>>();
    const project = this.#project(st?.mode ?? "work");
    const self = need.get("self");
    if (self && this.#feed) {
      if (!this.#self) {
        const sock: Sock = { readyState: 1, bufferedAmount: 0, send: (d) => this.#relay("self", d, this.#self?.topics ?? new Set()), close: () => {} };
        this.#self = { sock, topics: self, project };
        void this.#feed.add(sock, [...self], project);
      } else if (!sameSet(this.#self.topics, self) || !sameProject(this.#self.project, project)) {
        this.#self.topics = self;
        this.#self.project = project;
        void this.#feed.setTopics(this.#self.sock, [...self], project);
      }
    } else if (this.#self) {
      void this.#feed?.remove(this.#self.sock);
      this.#self = null;
      this.#latest.delete("self");
    }
    for (const name of [...this.#conns.keys()]) if (!need.has(name) || !(name in this.#cfg.sources)) this.#closeConn(name);
    for (const [name, topics] of need) {
      if (name === "self" || !(name in this.#cfg.sources)) continue;
      const c = this.#conns.get(name);
      if (!c) {
        const conn: Conn = { name, topics, project, ws: null, state: "off", attempt: 0, timer: null, idle: null, legacy: false, opened: false };
        this.#conns.set(name, conn);
        this.#connect(conn);
      } else if (!sameSet(c.topics, topics) || !sameProject(c.project, project)) {
        c.topics = topics;
        c.project = project;
        this.#subscribe(c);
      }
    }
  }

  #unsubscribeAll() {
    if (this.#self) void this.#feed?.remove(this.#self.sock);
    this.#self = null;
    for (const name of [...this.#conns.keys()]) this.#closeConn(name);
    this.#latest.clear();
  }

  #subscribe(c: Conn) {
    if (c.legacy || !c.ws || c.ws.readyState !== 1) return;
    try {
      const git = c.topics.has("git") || c.topics.has("city") ? { project: c.project.project, ci: c.project.ci } : {};
      c.ws.send(JSON.stringify({ type: "subscribe", topics: [...c.topics], ...git }));
    } catch {}
  }

  #setState(c: Conn, state: SourceState, retryInSec?: number) {
    c.state = state;
    c.retryInSec = retryInSec;
    this.#sendPages(this.#sourceMsg(c));
  }

  #sourceMsg(c: Conn) {
    return JSON.stringify({ type: "source", name: c.name, state: c.state, ...(c.retryInSec !== undefined ? { retryInSec: c.retryInSec } : {}) });
  }

  #connect(c: Conn) {
    const src = this.#cfg.sources[c.name];
    if (!src || !this.#running || this.#conns.get(c.name) !== c) return;
    const url = new URL(c.legacy ? "/v1/gamemode/feed" : "/v1/screen/feed", src.url);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    this.#setState(c, "connecting");
    let ws: Upstream;
    try {
      ws = this.#io.connect(url.toString(), src.token);
    } catch {
      return this.#retry(c);
    }
    c.ws = ws;
    c.opened = false;
    ws.binaryType = "arraybuffer";
    const mine = () => c.ws === ws && this.#conns.get(c.name) === c;
    ws.onopen = () => {
      if (!mine()) return;
      c.attempt = 0;
      c.opened = true;
      this.#setState(c, "ok");
      this.#subscribe(c);
      this.#kick(c);
    };
    ws.onmessage = (ev) => {
      if (!mine()) return;
      this.#kick(c);
      this.#relay(c.name, ev.data, c.topics);
    };
    ws.onclose = ws.onerror = () => {
      if (!mine()) return;
      c.ws = null;
      try {
        ws.close();
      } catch {}
      // Never opened: maybe a 0.5 source without /v1/screen/feed; the next attempt tries the other feed.
      if (!c.opened) c.legacy = !c.legacy;
      this.#retry(c);
    };
  }

  /** Idle watchdog: a feed sends a heartbeat every 5 s (the 0.5 feed truck every second); silence = dead link. */
  #kick(c: Conn) {
    if (c.idle) clearTimeout(c.idle);
    c.idle = setTimeout(() => {
      const ws = c.ws;
      c.ws = null;
      try {
        ws?.close();
      } catch {}
      this.#retry(c);
    }, this.#o.idleMs);
    c.idle.unref?.();
  }

  #retry(c: Conn) {
    if (!this.#running || this.#conns.get(c.name) !== c) return;
    if (c.idle) clearTimeout(c.idle);
    c.idle = null;
    const b = this.#o.backoff;
    const sec = b[Math.min(c.attempt++, b.length - 1)]!;
    this.#setState(c, "down", sec);
    c.timer = setTimeout(() => {
      c.timer = null;
      this.#connect(c);
    }, sec * 1000);
    c.timer.unref?.();
  }

  #closeConn(name: string) {
    const c = this.#conns.get(name);
    if (!c) return;
    this.#conns.delete(name);
    this.#latest.delete(name);
    if (c.timer) clearTimeout(c.timer);
    if (c.idle) clearTimeout(c.idle);
    const ws = c.ws;
    c.ws = null;
    try {
      ws?.close(1000);
    } catch {}
    c.state = "off";
    if (this.#running) this.#sendPages(this.#sourceMsg(c));
  }

  /** Known messages of subscribed topics go to the page tagged with their source; anything else is dropped. */
  #relay(src: string, data: unknown, topics: Set<Topic>) {
    if (!this.#running) return;
    if (typeof data !== "string") {
      const b = data instanceof ArrayBuffer ? Buffer.from(data) : Buffer.isBuffer(data) ? data : null;
      if (!b || b.length !== 25 || b[0] !== 0x01 || !topics.has("spectrum")) return;
      this.#sendPages(b, true);
      return;
    }
    if (data.length > maxMessage(data)) return;
    let msg: Rec;
    try {
      msg = JSON.parse(data) as Rec;
    } catch {
      return;
    }
    if (!msg || typeof msg !== "object" || typeof msg.type !== "string") return;
    const topic = MESSAGE_TOPIC[msg.type];
    if (!topic || !topics.has(topic)) return;
    // Hidden: a page that draws nothing has no use for touch effects (the city state still follows).
    if (this.#paused && msg.type === "touch") return;
    const tagged = JSON.stringify({ src, ...msg });
    const l = this.#latest.get(src) ?? emptyLatest();
    this.#latest.set(src, l);
    if (msg.type === "music") l.music = msg;
    else if (msg.type === "truck") l.truck = msg;
    else if (msg.type === "city") {
      const { files, ...head } = msg;
      l.city = Array.isArray(files) ? { msg: head, files: new Map(files.filter(Array.isArray).map((f: unknown[]) => [String(f[0]), f])), stale: false } : null;
    } else if (msg.type === "cityPatch" && l.city) {
      for (const u of Array.isArray(msg.upsert) ? msg.upsert : []) if (Array.isArray(u)) l.city.files.set(String(u[0]), u);
      for (const r of Array.isArray(msg.remove) ? msg.remove : []) l.city.files.delete(String(r));
      l.city.stale = true;
    }
    if (STATE_TYPES.has(msg.type)) l.raw.set(msg.type, tagged);
    // Pending approval previews are replayed until resolved (or no longer pending in the source's claude state).
    if (msg.type === "diff" && typeof msg.requestId === "string") l.raw.set(`diff:${msg.requestId}`, tagged);
    else if (msg.type === "diffResolved") l.raw.delete(`diff:${String(msg.requestId)}`);
    else if (msg.type === "claude") {
      const open = new Set<string>();
      for (const x of Array.isArray(msg.sessions) ? msg.sessions : []) for (const r of Array.isArray((x as Rec)?.pending) ? ((x as Rec).pending as unknown[]) : []) open.add(String(r));
      for (const k of [...l.raw.keys()]) if (k.startsWith("diff:") && !open.has(k.slice(5))) l.raw.delete(k);
    }
    this.#sendPages(tagged, msg.type === "truck");
  }

  #sendPages(data: string | Buffer, droppable = false) {
    for (const p of this.#pages) {
      if (p.readyState !== 1 || (droppable && p.bufferedAmount > this.#o.maxBuffered)) continue;
      p.send(data);
    }
  }

  // ---- page ----

  addPage(sock: Sock) {
    const st = this.#running;
    if (!st) return;
    this.#pages.add(sock);
    sock.send(this.#layoutMsg(st.mode));
    for (const c of this.#conns.values()) sock.send(this.#sourceMsg(c));
    for (const m of this.#replay()) sock.send(m);
    if (this.#paused) sock.send(JSON.stringify({ type: "pause" }));
    void this.#showScratch().catch(() => {});
  }

  removePage(sock: Sock) {
    this.#pages.delete(sock);
  }

  /** Cover of a current music message only. */
  async art(id: string): Promise<{ type: string; bytes: Buffer }> {
    let url: string | null = null;
    for (const l of this.#latest.values()) {
      const m = l.music;
      if (m && m.artId === id && typeof m.artUrl === "string") url = m.artUrl;
    }
    if (!url || !/^https:\/\//i.test(url)) throw new AppError("agent.screen.noArt", 404);
    const hit = this.#art.get(id);
    if (hit) {
      this.#art.delete(id);
      this.#art.set(id, hit);
      return hit;
    }
    let bytes: Buffer;
    try {
      const res = await this.#io.fetch(url, { signal: AbortSignal.timeout(10_000), redirect: "follow" });
      if (!res.ok || !res.url.startsWith("https://") || Number(res.headers.get("content-length") ?? 0) > ART_MAX) throw new Error("bad");
      bytes = await readCapped(res, ART_MAX);
    } catch {
      throw new AppError("agent.screen.noArt", 404);
    }
    const type = imageType(bytes);
    if (!type) throw new AppError("agent.screen.noArt", 404);
    const v = { type, bytes };
    this.#art.set(id, v);
    while (this.#art.size > 8) this.#art.delete(this.#art.keys().next().value!);
    return v;
  }
}

/** A state file → only validated values (a 0.5 Game mode's `mode` was the Hyprland config mode). */
function sanitizeState(s: Rec): SavedState {
  const hypr = s.hypr ?? s.mode;
  const placement: Placement = s.placement === "scratch" ? "scratch" : "fullscreen";
  return {
    startedAt: typeof s.startedAt === "string" ? s.startedAt : "",
    mode: SCREEN_MODES.includes(s.mode as ScreenMode) ? (s.mode as ScreenMode) : "game",
    hypr: hypr === "lua" || hypr === "legacy" ? hypr : null,
    placement,
    ws: typeof s.ws === "string" && /^[a-z]{1,16}$/.test(s.ws) ? s.ws : placement === "scratch" ? SPECIAL : WORKSPACES.game,
    rules: s.rules === true,
    bind: typeof s.bind === "string" && screenSchema.shape.scratchBind.safeParse(s.bind).success ? s.bind : null,
    workspace: typeof s.workspace === "string" && WS_TARGET.test(s.workspace) ? s.workspace : null,
    brightness: typeof s.brightness === "string" && /^\d{1,9}$/.test(s.brightness) ? s.brightness : null,
  };
}

async function readCapped(res: Response, max: number): Promise<Buffer> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of res.body as unknown as AsyncIterable<Uint8Array>) {
    size += c.length;
    if (size > max) throw new Error("too large");
    chunks.push(Buffer.from(c));
  }
  return Buffer.concat(chunks);
}

// ---- static files ----

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".webp": "image/webp",
  ".jpg": "image/jpeg",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".wasm": "application/wasm",
  ".pbf": "application/x-protobuf",
  ".pmtiles": "application/octet-stream",
};

/**
 * Raw URL path below a prefix → safe relative segments, or null. Each segment is decoded once; empty, "." and ".."
 * segments, slashes/backslashes/NUL after decoding, hidden files and unknown extensions are refused.
 */
export function safeSegments(rest: string): string[] | null {
  const parts = rest.split("/");
  const out: string[] = [];
  for (const raw of parts) {
    let s: string;
    try {
      s = decodeURIComponent(raw);
    } catch {
      return null;
    }
    if (!s || s === "." || s === ".." || s.startsWith(".") || /[\/\\\0]/.test(s) || s.length > 200) return null;
    out.push(s);
  }
  if (out.length === 0 || out.length > 8 || !(extname(out.at(-1)!).toLowerCase() in TYPES)) return null;
  return out;
}

/** A file inside `root` after resolving symlinks (null if outside, missing or not a regular file). */
export async function resolveInside(root: string, segs: string[]): Promise<{ path: string; size: number } | null> {
  try {
    const r = await realpath(root);
    const p = await realpath(join(r, ...segs));
    if (!p.startsWith(r + sep)) return null;
    const st = await stat(p);
    return st.isFile() ? { path: p, size: st.size } : null;
  } catch {
    return null;
  }
}

/** Single `bytes=a-b` range → [start, end] inclusive; null = whole file; "bad" = 416. */
export function parseRange(h: string | undefined, size: number): [number, number] | null | "bad" {
  if (!h) return null;
  const m = /^bytes=(\d*)-(\d*)$/.exec(h.trim());
  if (!m || (m[1] === "" && m[2] === "")) return "bad";
  let start: number;
  let end: number;
  if (m[1] === "") {
    start = Math.max(0, size - Number(m[2]));
    end = size - 1;
  } else {
    start = Number(m[1]);
    end = m[2] === "" ? size - 1 : Math.min(Number(m[2]), size - 1);
  }
  if (!Number.isSafeInteger(start) || start > end || start >= size) return "bad";
  return [start, end];
}

export function defaultDisplayDir(): string | null {
  // dist/screen/display.js (or src/…): ../../display next to dist/ (deployed), then the repo root's display/.
  for (const rel of ["../../display", "../../../display"]) {
    const p = fileURLToPath(new URL(rel, import.meta.url));
    if (existsSync(p)) return p;
  }
  return null;
}

/** Where the map data is installed (the Game mode path is kept: users' installed maps stay where they are). */
export function defaultMapDir(): string {
  const data = process.env.XDG_DATA_HOME?.startsWith("/") ? process.env.XDG_DATA_HOME : join(homedir(), ".local", "share");
  return join(data, "tiphys", "gamemode", "map");
}

async function sendFile(req: FastifyRequest, reply: FastifyReply, root: string | null, rest: string, ranges: boolean) {
  const segs = rest === "" && !ranges ? ["index.html"] : safeSegments(rest);
  const f = root && segs ? await resolveInside(root, segs) : null;
  if (!f) throw new AppError("agent.route.notFound", 404);
  const type = TYPES[extname(f.path).toLowerCase()]!;
  reply.header("content-type", type).header("cache-control", "no-cache").header("x-content-type-options", "nosniff");
  if (!ranges) return reply.header("content-length", f.size).send(createReadStream(f.path));
  reply.header("accept-ranges", "bytes");
  const r = parseRange(req.headers.range, f.size);
  if (r === "bad") return reply.status(416).header("content-range", `bytes */${f.size}`).send();
  if (!r) return reply.header("content-length", f.size).send(createReadStream(f.path));
  return reply
    .status(206)
    .header("content-range", `bytes ${r[0]}-${r[1]}/${f.size}`)
    .header("content-length", r[1] - r[0] + 1)
    .send(createReadStream(f.path, { start: r[0], end: r[1] }));
}

/** Partial settings without the defaults (a plain .partial() would fill every absent field with its default). */
function patchOf<T extends z.ZodObject>(o: T) {
  return z.strictObject(Object.fromEntries(Object.entries(o.shape).map(([k, v]) => [k, (v as unknown as z.ZodDefault<z.ZodType>).unwrap().optional()])) as Record<string, z.ZodOptional<z.ZodType>>);
}
const sourceSchema = z.strictObject({ url: z.url({ protocol: /^https?$/ }), token: z.string().min(1).max(200) });
const sh = screenSchema.shape;
export const putSchema = z.strictObject({
  settings: z
    .strictObject({
      placement: sh.placement.unwrap().optional(),
      scratchBind: sh.scratchBind.unwrap().optional(),
      lastMode: sh.lastMode.unwrap().optional(),
      batterySaver: sh.batterySaver.unwrap().optional(),
      share: z.strictObject({ code: z.boolean() }).optional(),
      modes: z.strictObject({ game: patchOf(MODE_SCHEMAS.game).optional(), work: patchOf(MODE_SCHEMAS.work).optional(), focus: patchOf(MODE_SCHEMAS.focus).optional() }).optional(),
    })
    .optional(),
  sources: z
    .record(sourceName, sourceSchema.nullable())
    .refine((r) => !("self" in r), { message: "self is reserved" })
    .optional(),
});
const legacyPutSchema = z.strictObject({ settings: patchOf(gameSettingsSchema).optional(), source: sourceSchema.nullable().optional() });
const modeBody = z.strictObject({ mode: z.enum(SCREEN_MODES) });

export async function displayRoutes(app: FastifyInstance, ctx: Ctx, o: DisplayOpts = {}) {
  const io = o.io ?? (await realDisplayIo());
  const display = new ScreenDisplay(ctx, io, o, (msg, err) => app.log.warn({ err }, msg));
  const displayDir = o.displayDir === undefined ? defaultDisplayDir() : o.displayDir;
  const mapDir = o.mapDir ?? defaultMapDir();
  void display.recover().catch((e) => app.log.warn({ err: e }, "ekran modu kalıntısı temizlenemedi"));
  app.addHook("onClose", async () => display.shutdown());

  app.get("/v1/screen", async () => display.status());
  app.put("/v1/screen", async (req) => display.update(putSchema.parse(req.body)));
  app.post("/v1/screen/start", async (req) => display.start(z.strictObject({ mode: z.enum(SCREEN_MODES).optional() }).parse(req.body ?? {}).mode, req.device?.id));
  app.post("/v1/screen/mode", async (req) => display.switchMode(modeBody.parse(req.body).mode));
  app.post("/v1/screen/stop", async (req) => display.stop(req.device?.id));

  // /v1/gamemode: the 0.5 routes for app 1.2, one release; the old error codes and shapes.
  const legacy = <T>(p: () => Promise<T>) => p().catch((e) => Promise.reject(legacyError(e)));
  app.get("/v1/gamemode", async () => display.legacyStatus());
  app.put("/v1/gamemode", async (req) => legacy(() => display.updateLegacy(legacyPutSchema.parse(req.body))));
  app.post("/v1/gamemode/start", async (req) =>
    legacy(async () => {
      if (!ctx.store.get().screen.sources.main) throw new AppError("agent.gamemode.noSource", 409);
      await display.start("game", req.device?.id);
      return display.legacyStatus();
    }),
  );
  app.post("/v1/gamemode/stop", async (req) => legacy(async () => (await display.stop(req.device?.id), display.legacyStatus())));

  const kiosk = { kiosk: true };
  for (const path of ["/v1/screen/live", "/v1/gamemode/live"]) {
    app.get(
      path,
      {
        websocket: true,
        config: kiosk,
        preValidation: async (req: FastifyRequest) => {
          if (!display.validToken((req.query as Record<string, unknown>)?.t)) throw new AppError("agent.auth.invalidToken", 401);
        },
      },
      (socket) => {
        const sock = socket as unknown as Sock;
        display.addPage(sock);
        socket.on("close", () => display.removePage(sock));
        socket.on("error", () => display.removePage(sock));
        socket.on("message", (d: Buffer) => {
          if (d.length > 1024) return;
          try {
            if ((JSON.parse(d.toString()) as { type?: unknown })?.type === "stop") void display.stop().catch(() => {});
          } catch {}
        });
      },
    );
  }

  for (const path of ["/v1/screen/art", "/v1/gamemode/art"]) {
    app.get(path, { config: kiosk }, async (req, reply) => {
      const q = z.strictObject({ t: z.string().max(100), id: z.string().regex(/^[a-f0-9]{12}$/) }).safeParse(req.query);
      const noArt = new AppError(path.startsWith("/v1/gamemode") ? "agent.gamemode.noArt" : "agent.screen.noArt", 404);
      if (!q.success || !display.validToken(q.data.t)) throw noArt;
      const a = await display.art(q.data.id).catch(() => Promise.reject(noArt));
      return reply.header("content-type", a.type).header("cache-control", "private, max-age=3600").send(a.bytes);
    });
  }

  // The kiosk page: /screen/ (and /gamemode/ for one release); map data under …/map/.
  for (const base of ["screen", "gamemode"]) {
    app.get(`/${base}`, { config: kiosk }, async (_req, reply) => reply.redirect(`/${base}/`));
    app.get(`/${base}/*`, { config: kiosk }, async (req, reply) => sendFile(req, reply, displayDir, req.url.split("?")[0]!.slice(`/${base}/`.length), false));
    app.get(`/${base}/map/*`, { config: kiosk }, async (req, reply) => sendFile(req, reply, mapDir, req.url.split("?")[0]!.slice(`/${base}/map/`.length), true));
  }

  return display;
}
