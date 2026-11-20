// Game mode display side (PLAN.md §19, runs on the laptop): settings, the kiosk lifecycle, the relay from the source
// agent's feed, the kiosk page's live WebSocket, the cover proxy and the static page.
// Lifecycle (start): tmpfs work dir $XDG_RUNTIME_DIR/tiphys-gamemode/ (0700) with an empty Firefox profile, a state
// file, temporary Hyprland window rules for the app id `tiphys-gamemode` (named workspace `yol`, fullscreen, no
// border/shadow/rounding/animation), the previous workspace and backlight remembered, then ONE transient user unit:
//   systemd-run --user --unit=tiphys-gamemode --collect -p StandardOutput=null -p StandardError=null --setenv=… --
//     systemd-inhibit --what=idle:sleep --why=… firefox --kiosk --no-remote --name tiphys-gamemode --profile <dir> <url>
// The display token (32 random bytes, memory only) is NOT on the command line (/proc/*/cmdline is readable by every
// local user): <url> is file://<work dir>/start.html (0600 in the 0700 tmpfs dir), which forwards to
// http://127.0.0.1:<port>/gamemode/#t=<token>.
// Stop: systemctl --user stop (the whole cgroup dies) → work dir removed → rules disabled → workspace and backlight
// restored → token invalid, page sockets closed, upstream closed. A crash leaves the state file: the next start of
// the agent finishes the stop. Events: only gamemode.started / gamemode.stopped. Fixed commands only, no free text.
import { randomBytes, timingSafeEqual } from "node:crypto";
import { createReadStream, existsSync } from "node:fs";
import { mkdir, readFile, realpath, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { extname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { gamemodeDisplaySchema, type GamemodeDisplay as Settings } from "../config.ts";
import type { Exec } from "../control.ts";
import { whichIn } from "../detect.ts";
import { AppError } from "../errors.ts";
import { run } from "../exec.ts";
import type { HyprMode } from "../hyprctl.ts";
import { Hyprctl } from "../hyprctl.ts";
import { imageType } from "../routes/media.ts";
import type { Ctx } from "../server.ts";
import type { Sock } from "./source.ts";

export const UNIT = "tiphys-gamemode";
export const APP_ID = "tiphys-gamemode";
export const WORKSPACE = "name:yol";
const RULE = "tiphys-gamemode";
const ART_MAX = 5 * 1024 * 1024;
const RELAYED = new Set(["music", "lyrics", "truck", "event"]);

// ---- outside world ----

/** Minimal WebSocket client surface (the global WebSocket; a fake in tests). */
export interface Upstream {
  readonly readyState: number;
  binaryType: string;
  onopen: (() => void) | null;
  onmessage: ((ev: { data: unknown }) => void) | null;
  onclose: (() => void) | null;
  onerror: (() => void) | null;
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
}

export async function realDisplayIo(): Promise<DisplayIo> {
  const [{ hyprEnv }, { waylandEnv, sessionBusEnv }] = await Promise.all([import("../routes/hypr.ts"), import("../routes/desktop.ts")]);
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
  };
}

// ---- command construction (pure; tested) ----

/** Firefox prefs of the throwaway profile: no session restore, telemetry, updates or first-run pages; WebRender on. */
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
    "browser.translations.automaticallyPopup": false,
    "browser.discovery.enabled": false,
    "datareporting.policy.dataSubmissionEnabled": false,
    "datareporting.healthreport.uploadEnabled": false,
    "datareporting.policy.firstRunURL": "",
    "toolkit.telemetry.enabled": false,
    "toolkit.telemetry.unified": false,
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
    "browser.safebrowsing.malware.enabled": false,
    "browser.safebrowsing.phishing.enabled": false,
    "browser.safebrowsing.downloads.enabled": false,
    "network.captive-portal-service.enabled": false,
    "signon.rememberSignons": false,
    "dom.disable_beforeunload": true,
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
    "--", "systemd-inhibit", "--what=idle:sleep", "--why=Tiphys Oyun Modu",
    o.firefox, "--kiosk", "--no-remote", "--name", APP_ID, "--profile", o.profile, o.url,
  ];
}

const RULE_PROPS: Array<[string, string]> = [
  ["match:class", `^(${APP_ID})$`],
  ["workspace", WORKSPACE],
  ["fullscreen", "on"],
  ["border_size", "0"],
  ["no_shadow", "on"],
  ["rounding", "0"],
  ["no_anim", "on"],
];

/** hyprctl calls that turn the named window rule on (fixed constants only). */
export function ruleOnArgs(mode: HyprMode): string[][] {
  if (mode === "lua") {
    return [["eval", `hl.window_rule({ name = "${RULE}", match = { class = "^(${APP_ID})$" }, workspace = "${WORKSPACE}", fullscreen = true, border_size = 0, no_shadow = true, rounding = 0, no_anim = true, enabled = true })`]];
  }
  return [...RULE_PROPS.map(([k, v]) => ["keyword", `windowrule[${RULE}]:${k}`, v]), ["keyword", `windowrule[${RULE}]:enable`, "true"]];
}

/** hyprctl calls that disable it again. */
export function ruleOffArgs(mode: HyprMode): string[][] {
  if (mode === "lua") return [["eval", `hl.window_rule({ name = "${RULE}", match = { class = "^(${APP_ID})$" }, enabled = false })`]];
  return [["keyword", `windowrule[${RULE}]:enable`, "false"]];
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
  if (!WS_TARGET.test(target) && target !== WORKSPACE) throw new AppError("agent.request.invalid", 400);
  return mode === "lua" ? ["eval", `hl.dispatch(hl.dsp.focus({ workspace = "${target}" }))`] : ["dispatch", "workspace", target];
}

/** `brightnessctl -m` → the current raw value ("intel_backlight,backlight,96000,100%,96000"). */
export function parseBrightness(out: string): string | null {
  const v = out.trim().split("\n")[0]?.split(",")[2];
  return v && /^\d{1,9}$/.test(v) ? v : null;
}

// ---- state ----

interface SavedState {
  startedAt: string;
  mode: HyprMode | null;
  rules: boolean;
  workspace: string | null;
  brightness: string | null;
}

export type SourceState = "off" | "connecting" | "ok" | "down";

export interface DisplayOpts {
  io?: DisplayIo;
  /** Upstream reconnect delays (s). */
  backoff?: number[];
  /** Reconnect when the feed is silent this long (it sends truck at least once a second). */
  idleMs?: number;
  /** How often the kiosk unit is checked while running. */
  watchMs?: number;
  displayDir?: string | null;
  mapDir?: string;
  maxBuffered?: number;
}

type Rec = Record<string, unknown>;

export class GamemodeDisplay {
  readonly #ctx: Ctx;
  readonly #io: DisplayIo;
  readonly #o: { backoff: number[]; idleMs: number; watchMs: number; maxBuffered: number };
  readonly #log: (msg: string, err?: unknown) => void;
  readonly workDir: string;
  readonly #mapFile: string;
  #chain: Promise<unknown> = Promise.resolve();
  #running: SavedState | null = null;
  #token: Buffer | null = null;
  readonly #pages = new Set<Sock>();
  #watch: NodeJS.Timeout | null = null;
  // relay
  #up: Upstream | null = null;
  #upTimer: NodeJS.Timeout | null = null;
  #idle: NodeJS.Timeout | null = null;
  #attempt = 0;
  #source: { state: SourceState; retryInSec?: number } = { state: "off" };
  #latest: { music: Rec | null; lyrics: string | null; truck: Rec | null; musicRaw: string | null; truckRaw: string | null } = {
    music: null, lyrics: null, truck: null, musicRaw: null, truckRaw: null,
  };
  readonly #art = new Map<string, { type: string; bytes: Buffer }>();

  constructor(ctx: Ctx, io: DisplayIo, o: DisplayOpts, log: (msg: string, err?: unknown) => void) {
    this.#ctx = ctx;
    this.#io = io;
    this.#log = log;
    this.#o = { backoff: o.backoff ?? [1, 2, 4, 8, 15, 30], idleMs: o.idleMs ?? 15_000, watchMs: o.watchMs ?? 5000, maxBuffered: o.maxBuffered ?? 256 * 1024 };
    this.workDir = join(io.runtimeDir, "tiphys-gamemode");
    this.#mapFile = join(o.mapDir ?? defaultMapDir(), "ets2.pmtiles");
  }

  #serial<T>(fn: () => Promise<T>): Promise<T> {
    const p = this.#chain.then(fn);
    this.#chain = p.catch(() => {});
    return p;
  }

  get settings(): Settings {
    return this.#ctx.store.get().gamemode.display;
  }

  status() {
    const src = this.#ctx.store.get().gamemode.source;
    const m = this.#latest.music;
    const t = this.#latest.truck;
    const job = t && typeof t.job === "object" && t.job ? (t.job as Rec) : null;
    return {
      running: this.#running !== null,
      startedAt: this.#running?.startedAt ?? null,
      settings: this.settings,
      source: { configured: src !== null, url: src?.url ?? null, state: this.#source.state },
      // The map files live on this (display) host, next to the page that draws them.
      map: { present: existsSync(this.#mapFile) },
      live: {
        music: m && !m.none ? { title: m.title ?? "", artist: m.artist ?? "", playing: m.playing === true } : null,
        truck: t ? { state: t.state, from: job?.from ?? null, to: job?.to ?? null, speedKmh: typeof t.speed === "number" ? Math.round(Math.abs(t.speed) * 3.6) : null } : null,
      },
    };
  }

  /** Display token check (constant time). */
  validToken(t: unknown): boolean {
    if (!this.#token || typeof t !== "string" || t.length !== 64) return false;
    const b = Buffer.from(t, "utf8");
    return b.length === this.#token.length && timingSafeEqual(b, this.#token);
  }

  // ---- lifecycle ----

  #stateFile = () => join(this.workDir, "state.json");

  async #save(s: SavedState) {
    await writeFile(this.#stateFile(), JSON.stringify(s) + "\n", { mode: 0o600 });
  }

  async #hypr(env: NodeJS.ProcessEnv, args: string[]) {
    const r = await this.#io.exec("hyprctl", args, { env, timeoutMs: 5000, allowFail: true });
    const ok = args[0] === "-j" || r.stdout.split("\n").map((l) => l.trim()).filter(Boolean).every((l) => l === "ok");
    if (r.code !== 0 || !ok) throw new AppError("agent.desktop.hyprctlFailed", 502, { output: r.stdout.trim().slice(0, 200) });
    return r.stdout;
  }

  start(device?: string) {
    return this.#serial(async () => {
      if (this.#running) return this.status();
      const src = this.#ctx.store.get().gamemode.source;
      if (!src) throw new AppError("agent.gamemode.noSource", 409);
      let env: NodeJS.ProcessEnv;
      try {
        env = { ...(await this.#io.waylandEnv()), ...(await this.#io.hyprEnv()), ...this.#io.busEnv() };
      } catch {
        throw new AppError("agent.gamemode.noDisplay", 503);
      }
      const firefox = ["firefox", "firefox-esr"].find((c) => this.#io.which(c));
      if (!firefox) throw new AppError("agent.exec.commandMissing", 500, { command: "firefox" });
      // A leftover unit (e.g. from a crash) would make systemd-run fail.
      await this.#io.exec("systemctl", ["--user", "stop", `${UNIT}.service`], { env, timeoutMs: 15_000, allowFail: true });
      await rm(this.workDir, { recursive: true, force: true });
      await mkdir(join(this.workDir, "profile"), { recursive: true, mode: 0o700 });
      const token = randomBytes(32).toString("hex");
      const state: SavedState = { startedAt: new Date().toISOString(), mode: null, rules: false, workspace: null, brightness: null };
      await this.#save(state);
      try {
        const hypr = new Hyprctl(this.#io.exec, async () => env);
        state.mode = await hypr.mode(env);
        state.workspace = workspaceTarget(await this.#hypr(env, ["-j", "activeworkspace"]).catch(() => ""));
        state.rules = true;
        await this.#save(state);
        for (const args of ruleOnArgs(state.mode)) await this.#hypr(env, args);
        const b = this.settings.brightness;
        if (b !== null) state.brightness = await this.#setBrightness(b, null);
        await this.#save(state);
        await writeFile(join(this.workDir, "profile", "user.js"), userJs(), { mode: 0o600 });
        const startFile = join(this.workDir, "start.html");
        await writeFile(startFile, startHtml(`${this.#pageBase()}#t=${token}`), { mode: 0o600 });
        // Show the empty named workspace first: Firefox maps straight onto it (no flash of the old workspace).
        await this.#hypr(env, focusWorkspaceArgs(state.mode, WORKSPACE)).catch(() => {});
        const r = await this.#io.exec("systemd-run", kioskArgs({ firefox, profile: join(this.workDir, "profile"), url: `file://${startFile}`, env }), {
          env, timeoutMs: 15_000, allowFail: true,
        });
        if (r.code !== 0) throw new AppError("agent.gamemode.startFailed", 502, { stderr: r.stderr.slice(0, 300) });
      } catch (e) {
        await this.#cleanup(state, env).catch(() => {});
        throw e;
      }
      this.#token = Buffer.from(token, "utf8");
      this.#running = state;
      this.#connect();
      this.#watch = setInterval(() => void this.#checkUnit(), this.#o.watchMs);
      this.#watch.unref?.();
      this.#event("gamemode.started", device);
      return this.status();
    });
  }

  stop(device?: string) {
    return this.#serial(async () => {
      const state = this.#running;
      if (!state) return this.status();
      await this.#stopNow(state);
      this.#event("gamemode.stopped", device);
      return this.status();
    });
  }

  async #stopNow(state: SavedState) {
    this.#running = null;
    this.#token = null;
    if (this.#watch) clearInterval(this.#watch);
    this.#watch = null;
    for (const p of [...this.#pages]) if (p.readyState === 0 || p.readyState === 1) p.close(4410, "stopped");
    this.#pages.clear();
    this.#disconnect();
    const env = await this.#env();
    await this.#cleanup(state, env);
  }

  async #env(): Promise<NodeJS.ProcessEnv> {
    const env: NodeJS.ProcessEnv = { ...process.env, XDG_RUNTIME_DIR: this.#io.runtimeDir, ...this.#io.busEnv() };
    return { ...env, ...(await this.#io.hyprEnv().catch(() => ({}))) };
  }

  /** Undoes everything the state says was done; every step is best effort. */
  async #cleanup(state: SavedState, env: NodeJS.ProcessEnv) {
    await this.#io.exec("systemctl", ["--user", "stop", `${UNIT}.service`], { env, timeoutMs: 20_000, allowFail: true }).catch((e) => this.#log("oyun modu birimi durdurulamadı", e));
    await rm(this.workDir, { recursive: true, force: true }).catch((e) => this.#log("oyun modu dizini silinemedi", e));
    if (env.HYPRLAND_INSTANCE_SIGNATURE) {
      const mode = state.mode ?? (await new Hyprctl(this.#io.exec, async () => env).mode(env).catch(() => "legacy" as const));
      if (state.rules) for (const args of ruleOffArgs(mode)) await this.#hypr(env, args).catch((e) => this.#log("oyun modu pencere kuralı geri alınamadı", e));
      if (state.workspace) {
        // Only if the user is still on the game mode workspace.
        const now = await this.#hypr(env, ["-j", "activeworkspace"]).catch(() => "");
        if (/"name":\s*"yol"/.test(now)) await this.#hypr(env, focusWorkspaceArgs(mode, state.workspace)).catch(() => {});
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

  #brightnessctl(args: string[]) {
    if (!this.#io.which("brightnessctl")) return Promise.reject(new Error("brightnessctl missing"));
    return this.#io.exec("brightnessctl", args, { timeoutMs: 5000, allowFail: true });
  }

  /** Finishes a mode a crashed agent left behind (state file in the tmpfs work dir). */
  recover() {
    return this.#serial(async () => {
      let state: SavedState;
      try {
        state = JSON.parse(await readFile(this.#stateFile(), "utf8")) as SavedState;
      } catch {
        // No state file: a stray work dir or unit from an older run is still removed.
        if (await stat(this.workDir).then(() => true, () => false)) await this.#cleanup({ startedAt: "", mode: null, rules: false, workspace: null, brightness: null }, await this.#env());
        return false;
      }
      await this.#cleanup(sanitizeState(state), await this.#env());
      this.#event("gamemode.stopped");
      return true;
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

  #event(key: string, device?: string) {
    void this.#ctx.notifier.events?.record({ key, ...(device ? { device } : {}) }, (e) => this.#log("olay yazılamadı", e));
  }

  #pageBase() {
    const { host, port } = this.#ctx.store.get().listen;
    const h = host === "0.0.0.0" || host === "::" || host === "localhost" ? "127.0.0.1" : host.includes(":") ? `[${host}]` : host;
    return `http://${h}:${port}/gamemode/`;
  }

  // ---- settings ----

  async update(body: { settings?: Partial<Settings>; source?: { url: string; token: string } | null }) {
    return this.#serial(async () => {
      const before = this.#ctx.store.get().gamemode;
      const next = await this.#ctx.store.update((c) => {
        if (body.settings) c.gamemode.display = gamemodeDisplaySchema.parse({ ...c.gamemode.display, ...body.settings });
        if (body.source !== undefined) c.gamemode.source = body.source;
        return c;
      });
      const g = next.gamemode;
      if (body.settings) this.#sendPages(JSON.stringify({ type: "settings", ...g.display }));
      if (this.#running && g.display.brightness !== before.display.brightness) {
        const st = this.#running;
        if (g.display.brightness !== null) st.brightness = await this.#setBrightness(g.display.brightness, st.brightness);
        else if (st.brightness) {
          await this.#brightnessctl(["-q", "set", st.brightness]).catch(() => {});
          st.brightness = null;
        }
        await this.#save(st).catch(() => {});
      }
      if (this.#running && body.source !== undefined && JSON.stringify(before.source) !== JSON.stringify(g.source)) {
        this.#disconnect();
        this.#connect();
      }
      return this.status();
    });
  }

  // ---- relay ----

  #setSource(state: SourceState, retryInSec?: number) {
    this.#source = { state, ...(retryInSec !== undefined ? { retryInSec } : {}) };
    if (state !== "off") this.#sendPages(JSON.stringify({ type: "source", ...this.#source }));
  }

  #connect() {
    const src = this.#ctx.store.get().gamemode.source;
    if (!src || !this.#running) return;
    const url = new URL("/v1/gamemode/feed", src.url);
    url.protocol = url.protocol === "https:" ? "wss:" : "ws:";
    this.#setSource("connecting");
    let ws: Upstream;
    try {
      ws = this.#io.connect(url.toString(), src.token);
    } catch {
      return this.#retry();
    }
    this.#up = ws;
    ws.binaryType = "arraybuffer";
    const mine = () => this.#up === ws;
    ws.onopen = () => {
      if (!mine()) return;
      this.#attempt = 0;
      this.#setSource("ok");
      this.#kick();
    };
    ws.onmessage = (ev) => {
      if (!mine()) return;
      this.#kick();
      this.#relay(ev.data);
    };
    ws.onclose = ws.onerror = () => {
      if (!mine()) return;
      this.#up = null;
      try {
        ws.close();
      } catch {}
      this.#retry();
    };
  }

  /** Idle watchdog: the feed sends truck at least once a second, so silence means a dead connection. */
  #kick() {
    if (this.#idle) clearTimeout(this.#idle);
    this.#idle = setTimeout(() => {
      const ws = this.#up;
      this.#up = null;
      try {
        ws?.close();
      } catch {}
      this.#retry();
    }, this.#o.idleMs);
    this.#idle.unref?.();
  }

  #retry() {
    if (!this.#running) return;
    if (this.#idle) clearTimeout(this.#idle);
    const b = this.#o.backoff;
    const sec = b[Math.min(this.#attempt++, b.length - 1)]!;
    this.#setSource("down", sec);
    this.#upTimer = setTimeout(() => {
      this.#upTimer = null;
      this.#connect();
    }, sec * 1000);
    this.#upTimer.unref?.();
  }

  #disconnect() {
    if (this.#upTimer) clearTimeout(this.#upTimer);
    if (this.#idle) clearTimeout(this.#idle);
    this.#upTimer = this.#idle = null;
    const ws = this.#up;
    this.#up = null;
    try {
      ws?.close(1000);
    } catch {}
    this.#attempt = 0;
    this.#source = { state: "off" };
    this.#latest = { music: null, lyrics: null, truck: null, musicRaw: null, truckRaw: null };
  }

  #relay(data: unknown) {
    if (typeof data !== "string") {
      const b = data instanceof ArrayBuffer ? Buffer.from(data) : Buffer.isBuffer(data) ? data : null;
      if (!b || b.length !== 25 || b[0] !== 0x01 || !this.settings.spectrum) return;
      this.#sendPages(b, true);
      return;
    }
    if (data.length > 1024 * 1024) return;
    let msg: Rec;
    try {
      msg = JSON.parse(data) as Rec;
    } catch {
      return;
    }
    if (!msg || typeof msg !== "object" || typeof msg.type !== "string" || !RELAYED.has(msg.type)) return;
    if (msg.type === "music") {
      this.#latest.music = msg;
      this.#latest.musicRaw = data;
    } else if (msg.type === "lyrics") this.#latest.lyrics = data;
    else if (msg.type === "truck") {
      this.#latest.truck = msg;
      this.#latest.truckRaw = data;
    }
    this.#sendPages(data, msg.type === "truck");
  }

  #sendPages(data: string | Buffer, droppable = false) {
    for (const p of this.#pages) {
      if (p.readyState !== 1 || (droppable && p.bufferedAmount > this.#o.maxBuffered)) continue;
      p.send(data);
    }
  }

  // ---- page ----

  addPage(sock: Sock) {
    this.#pages.add(sock);
    sock.send(JSON.stringify({ type: "settings", ...this.settings }));
    if (this.#source.state !== "off") sock.send(JSON.stringify({ type: "source", ...this.#source }));
    for (const m of [this.#latest.musicRaw, this.#latest.lyrics, this.#latest.truckRaw]) if (m) sock.send(m);
  }

  removePage(sock: Sock) {
    this.#pages.delete(sock);
  }

  /** Cover of the current music message only. */
  async art(id: string): Promise<{ type: string; bytes: Buffer }> {
    const m = this.#latest.music;
    const url = m && typeof m.artUrl === "string" ? m.artUrl : null;
    if (!url || m!.artId !== id || !/^https:\/\//i.test(url)) throw new AppError("agent.gamemode.noArt", 404);
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
      throw new AppError("agent.gamemode.noArt", 404);
    }
    const type = imageType(bytes);
    if (!type) throw new AppError("agent.gamemode.noArt", 404);
    const v = { type, bytes };
    this.#art.set(id, v);
    while (this.#art.size > 8) this.#art.delete(this.#art.keys().next().value!);
    return v;
  }
}

function sanitizeState(s: Partial<SavedState>): SavedState {
  return {
    startedAt: typeof s.startedAt === "string" ? s.startedAt : "",
    mode: s.mode === "lua" || s.mode === "legacy" ? s.mode : null,
    rules: s.rules === true,
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
  // dist/gamemode/display.js (or src/…): ../../display next to dist/ (deployed), then the repo root's display/.
  for (const rel of ["../../display", "../../../display"]) {
    const p = fileURLToPath(new URL(rel, import.meta.url));
    if (existsSync(p)) return p;
  }
  return null;
}

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
const settingsPatch = z.strictObject(
  Object.fromEntries(Object.entries(gamemodeDisplaySchema.shape).map(([k, v]) => [k, v.unwrap().optional()])) as {
    [K in keyof typeof gamemodeDisplaySchema.shape]: z.ZodOptional<ReturnType<(typeof gamemodeDisplaySchema.shape)[K]["unwrap"]>>;
  },
);
const putSchema = z.strictObject({
  settings: settingsPatch.optional(),
  source: z.strictObject({ url: z.url({ protocol: /^https?$/ }), token: z.string().min(1).max(200) }).nullable().optional(),
});

export async function displayRoutes(app: FastifyInstance, ctx: Ctx, o: DisplayOpts = {}) {
  const io = o.io ?? (await realDisplayIo());
  const display = new GamemodeDisplay(ctx, io, o, (msg, err) => app.log.warn({ err }, msg));
  const displayDir = o.displayDir === undefined ? defaultDisplayDir() : o.displayDir;
  const mapDir = o.mapDir ?? defaultMapDir();
  void display.recover().catch((e) => app.log.warn({ err: e }, "oyun modu kalıntısı temizlenemedi"));
  app.addHook("onClose", async () => display.shutdown());

  app.get("/v1/gamemode", async () => display.status());
  app.put("/v1/gamemode", async (req) => display.update(putSchema.parse(req.body)));
  app.post("/v1/gamemode/start", async (req) => display.start(req.device?.id));
  app.post("/v1/gamemode/stop", async (req) => display.stop(req.device?.id));

  const kiosk = { kiosk: true };
  app.get(
    "/v1/gamemode/live",
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

  app.get("/v1/gamemode/art", { config: kiosk }, async (req, reply) => {
    const q = z.strictObject({ t: z.string().max(100), id: z.string().regex(/^[a-f0-9]{12}$/) }).safeParse(req.query);
    if (!q.success || !display.validToken(q.data.t)) throw new AppError("agent.gamemode.noArt", 404);
    const a = await display.art(q.data.id);
    return reply.header("content-type", a.type).header("cache-control", "private, max-age=3600").send(a.bytes);
  });

  app.get("/gamemode", { config: kiosk }, async (_req, reply) => reply.redirect("/gamemode/"));
  app.get("/gamemode/*", { config: kiosk }, async (req, reply) => sendFile(req, reply, displayDir, req.url.split("?")[0]!.slice("/gamemode/".length), false));
  app.get("/gamemode/map/*", { config: kiosk }, async (req, reply) => sendFile(req, reply, mapDir, req.url.split("?")[0]!.slice("/gamemode/map/".length), true));

  return display;
}
