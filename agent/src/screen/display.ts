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
// dropped; `resume` when shown. Events: screen.started {mode} / screen.stopped, and screen.focus.phase {phase, round,
// cause} (also pushed; never the task). Fixed commands only.
// Focus timer (W5, focus_timer.ts): exists only while the Focus mode runs; its times sit in focus.json in the work dir
// (the task line is memory only). Privacy veil (W5): `veil` to the page, which tears its view down to a dim clock;
// meanwhile the agent forwards no topic message at all (state is still kept and replayed when the veil lifts).
// Agent restart (a systemd restart job of the agent's own unit): the mode is left running (Firefox, work dir, rules)
// and the next agent adopts it from the state file (token included, 0600 on tmpfs) while the unit is still active;
// the page reconnects with the same token. Any other stop of the agent stops the mode as before.
// Session summary (W7, summary.ts): counters fed by the relayed messages, memory only; a stop after ≥ 2 min sends ONE
// `screen.summary` push (numbers only, not recorded). Battery saver (W7): while the display host runs on battery below
// 30 % (back at 35 % or on mains) the page gets `power {saver:true}` (motion low, flat city); the level comes from the
// `self` source's system messages and a read of /sys/class/power_supply every 30 s (no process).
// Sleep mode (PLAN.md §21 S2, sleep.ts): a fourth run mode with its own routes (/v1/sleep/*): always fullscreen on the
// workspace `uyku`, a fixed view (no layout, no topic subscription), the phase machine and the brightness curve of
// sleep.ts with its state in sleep.json next to state.json. Its events are sleep.started / sleep.stopped only. While it
// runs, a layout mode can't be switched to (409 agent.sleep.running); POST /v1/sleep/start stops a running layout mode
// first. The page sends `heartbeat` every 10 s on its live socket.
// Sleep group (S3, sleep_group.ts): a non-leader member keeps a topic-less source connection to the leader for the
// group messages; the leader takes them from its own feed (`feed.group`). A user stop ends the group, a local end
// (kiosk died, agent exit) doesn't. Test only: TIPHYS_SCREEN_HEADLESS runs the kiosk headless (see headlessBrowser).
import { randomBytes, timingSafeEqual } from "node:crypto";
import { createReadStream, existsSync } from "node:fs";
import { mkdir, readFile, realpath, rename, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { extname, join, sep } from "node:path";
import { fileURLToPath } from "node:url";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z } from "zod";
import { gameSettingsSchema, MODE_SCHEMAS, SCREEN_MODES, screenSchema, sourceName, type ModeSettings, type RunMode, type ScreenConfig, type ScreenMode } from "../config.ts";
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
import { FOCUS_ACTIONS, FocusClock, IDLE, parseTimes, TASK_MAX, type FocusAction, type FocusPhase, type FocusTimes } from "./focus_timer.ts";
import { realFileIo, type FileIo } from "./producers/common.ts";
import { findBattery, powerSupplyDir, readBattery } from "./producers/system.ts";
import { SessionSummary, SUMMARY_MIN_MS } from "./summary.ts";
import { Hardware, sanitizeSaved, type HwSaved } from "./sleep_hw.ts";
import { HardwarePreview, hostIdOf, mergeSettings, parseSleepFile, SleepRun, sleepPreviewSchema, sleepPutSchema, sleepStartSchema, type SleepFile, type SleepSession } from "./sleep.ts";
import { leaderSource, LeaderGroup, MemberGroup, parseGroupMessage, type SleepGroup } from "./sleep_group.ts";

export const UNIT = "tiphys-screen";
export { APP_ID } from "./placement.ts";
/** What a 0.5 Game mode left behind (crash recovery only). */
const LEGACY = { unit: "tiphys-gamemode", rule: "tiphys-gamemode", appId: "tiphys-gamemode", dir: "tiphys-gamemode" };
const CURRENT = { unit: UNIT, rule: "tiphys-screen", appId: APP_ID, dir: "tiphys-screen" };
/** Test-only headless kiosk (TIPHYS_SCREEN_HEADLESS): its own unit and work dir, so it never meets a real mode. */
const HEADLESS = { unit: "tiphys-screen-headless", rule: "tiphys-screen-headless", appId: "tiphys-screen-headless", dir: "tiphys-screen-headless" };
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
  /** Is the agent's own service being restarted (not stopped)? Then a running mode is left for the next agent. */
  restarting?(): Promise<boolean>;
}

/** `systemctl list-jobs --plain --no-legend` → is a restart job of `unit` running? */
export function restartJob(out: string, unit: string): boolean {
  return out.split("\n").some((l) => {
    const f = l.trim().split(/\s+/);
    return f[1] === unit && /restart$/.test(f[2] ?? "");
  });
}

/** /proc/self/cgroup → the systemd service this process runs in, and whether it's a user unit. */
export function ownUnit(cgroup: string): { unit: string; user: boolean } | null {
  const path = cgroup.split("\n").find((l) => l.startsWith("0::"))?.slice(3) ?? "";
  const unit = path.split("/").pop() ?? "";
  return /^[A-Za-z0-9@_.-]{1,200}\.service$/.test(unit) ? { unit, user: path.includes("/user@") } : null;
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
    restarting: async () => {
      const own = ownUnit(await readFile("/proc/self/cgroup", "utf8").catch(() => ""));
      if (!own) return false;
      const r = await run("systemctl", [...(own.user ? ["--user"] : []), "list-jobs", "--plain", "--no-legend"], { timeoutMs: 3000, allowFail: true });
      return r.code === 0 && restartJob(r.stdout, own.unit);
    },
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
    // Focus mode ambient sound and chime (WebAudio, synthesized in the page): no click ever reaches the kiosk.
    "media.autoplay.default": 0,
    "media.autoplay.blocking_policy": 0,
    "media.autoplay.block-webaudio": false,
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

/**
 * TIPHYS_SCREEN_HEADLESS (test only, unset by default; docs/agent/configuration.md): the absolute path of a
 * Chromium-family browser. The kiosk then runs headless and muted in its own unit/work dir, with no Hyprland step, no
 * visibility watch and no hardware (backlight, DDC, extras): a second agent on a desktop can run a mode without
 * opening a window or making a sound (PLAN.md §21 S3's temporary group leader).
 */
export function headlessBrowser(v = process.env.TIPHYS_SCREEN_HEADLESS): string | null {
  return v && /^\/[A-Za-z0-9_.\/-]{1,300}$/.test(v) ? v : null;
}

/** systemd-run arguments of the headless test kiosk (no window, no sound, autoplay allowed). */
export function headlessArgs(o: { browser: string; profile: string; url: string }): string[] {
  return [
    "--user", `--unit=${HEADLESS.unit}`, "--collect", "-p", "StandardOutput=null", "-p", "StandardError=null",
    "--", o.browser, "--headless", "--mute-audio", "--autoplay-policy=no-user-gesture-required", "--no-first-run", "--no-default-browser-check",
    `--user-data-dir=${o.profile}`, o.url,
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
  mode: RunMode;
  hypr: HyprMode | null;
  placement: Placement;
  /** Our workspace: the named one (fullscreen) or SPECIAL (scratch). */
  ws: string;
  rules: boolean;
  /** The temporary scratch keybind ("SUPER,grave") while set. */
  bind: string | null;
  workspace: string | null;
  brightness: string | null;
  /** The page's display token (also in start.html): lets the next agent adopt the mode after a restart. */
  token: string | null;
  /** Privacy veil on (W5): kept across an agent restart, gone with the mode. */
  veil: boolean;
}

export type SourceState = "off" | "connecting" | "ok" | "down";
type StopWhy = "user" | "group" | "local";

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
  /** The sleep group's link to its leader (sleep_group.ts): no topics, group messages both ways. */
  group: boolean;
}

type Rec = Record<string, unknown>;

interface Latest {
  music: Rec | null;
  truck: Rec | null;
  /** Counts for the phone's one-line summary (GET live): Claude sessions / waiting ones, running jobs. */
  claude: { sessions: number; waiting: number } | null;
  jobs: number | null;
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
  /** A mode that ran shorter than this stops without a summary push. */
  summaryMinMs?: number;
  /** Battery saver: where batteries are (default /sys/class/power_supply or TIPHYS_SCREEN_POWER_DIR) and how often read. */
  power?: { dir?: string; everyMs?: number; io?: FileIo };
  /**
   * Sleep mode: the test-only time scale (default TIPHYS_SLEEP_SCALE, else 1; every phase length is divided by it),
   * where the LEDs are (default /sys/class/leds) and the clock (tests).
   */
  sleep?: { scale?: number; ledsDir?: string; syncLog?: boolean; now?: () => number; setTimeout?: (fn: () => void, ms: number) => unknown; clearTimeout?: (h: unknown) => void };
  /** Test-only headless kiosk: a browser path (default TIPHYS_SCREEN_HEADLESS); null = the real kiosk. */
  headless?: string | null;
}

/** TIPHYS_SLEEP_SCALE (test only, unset by default; docs/agent/configuration.md): 1..1000, anything else 1. */
export function sleepScale(v = process.env.TIPHYS_SLEEP_SCALE): number {
  const n = Number(v);
  return v && Number.isFinite(n) && n >= 1 && n <= 1000 ? n : 1;
}

/** TIPHYS_SLEEP_SYNCLOG=1 (test only, unset by default): the page reports crackle timings into the work dir (S3 measurement). */
export const sleepSyncLog = (v = process.env.TIPHYS_SLEEP_SYNCLOG) => v === "1";
const SYNC_FILE = "sync.jsonl";
/** How long a user-stopped session is remembered (a member's late hello gets `stop`); memory only. */
const ENDED_MS = 12 * 60 * 60_000;

/** The fixed sleep view: no cards, no topics; the page builds it from the `sleep` message. */
const SLEEP_LAYOUT = { template: "sleep", cards: [] as unknown[] };
const PREVIEW_FILE = "tiphys-sleep-preview.json";

/** Battery saver thresholds (%): on below SAVER_ON, off again at SAVER_OFF or on mains. */
export const SAVER_ON = 30;
export const SAVER_OFF = 35;

/** The saver's next state for a battery reading (hysteresis between the thresholds). */
export function saverNext(prev: boolean, b: { level: number; charging: boolean } | null, enabled: boolean): boolean {
  if (!enabled || !b || b.charging) return false;
  if (b.level < SAVER_ON) return true;
  if (b.level >= SAVER_OFF) return false;
  return prev;
}

const emptyLatest = (): Latest => ({ music: null, truck: null, claude: null, jobs: null, raw: new Map(), city: null });
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
  readonly #o: {
    backoff: number[]; idleMs: number; watchMs: number; maxBuffered: number; visibility: VisibilityOpts; summaryMinMs: number; power: { dir: string; everyMs: number; io: FileIo };
    sleep: { scale: number; ledsDir: string; syncLog: boolean; now?: () => number; setTimeout?: (fn: () => void, ms: number) => unknown; clearTimeout?: (h: unknown) => void };
    headless: string | null;
  };
  readonly #names: Names;
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
  /** Focus timer: only while the Focus mode runs. */
  #focus: FocusClock | null = null;
  #focusSave: Promise<unknown> = Promise.resolve();
  readonly #conns = new Map<string, Conn>();
  readonly #latest = new Map<string, Latest>();
  readonly #art = new Map<string, { type: string; bytes: Buffer }>();
  /** The running mode's summary counters (memory only). */
  #summary: SessionSummary | null = null;
  /** The last stop (memory only): did it send a summary? The phone then leaves its held count to that push. */
  #lastStop: { at: number; summary: boolean } | null = null;
  /** Battery saver: on, the battery directory found at start, the /sys read timer. */
  #saver = false;
  #battery: string | null = null;
  #powerTimer: NodeJS.Timeout | null = null;
  /** Sleep mode: the run while it runs; the hardware-only preview while it doesn't. */
  #sleep: SleepRun | null = null;
  #preview: HardwarePreview | null = null;
  /** Sleep group (S3): the leader's peers or a member's link; null alone. */
  #group: SleepGroup | null = null;
  /** Sessions stopped by a user (here or relayed): session id → when (memory only). */
  readonly #ended = new Map<string, number>();

  constructor(ctx: Ctx, io: DisplayIo, o: DisplayOpts, log: (msg: string, err?: unknown) => void) {
    this.#ctx = ctx;
    this.#io = io;
    this.#feed = o.feed ?? null;
    this.#log = log;
    this.#o = {
      backoff: o.backoff ?? [1, 2, 4, 8, 15, 30], idleMs: o.idleMs ?? 15_000, watchMs: o.watchMs ?? 5000, maxBuffered: o.maxBuffered ?? 256 * 1024, visibility: o.visibility ?? {},
      summaryMinMs: o.summaryMinMs ?? SUMMARY_MIN_MS, power: { dir: o.power?.dir ?? powerSupplyDir(), everyMs: o.power?.everyMs ?? 30_000, io: o.power?.io ?? realFileIo },
      sleep: { ...o.sleep, scale: o.sleep?.scale ?? sleepScale(), ledsDir: o.sleep?.ledsDir ?? "/sys/class/leds", syncLog: o.sleep?.syncLog ?? sleepSyncLog() },
      headless: o.headless === undefined ? headlessBrowser() : o.headless,
    };
    this.#names = this.#o.headless ? HEADLESS : CURRENT;
    this.workDir = join(io.runtimeDir, this.#names.dir);
    if (this.#feed) this.#feed.group = { message: (sock, m) => this.#groupIn(sock, m), gone: (sock) => (this.#group instanceof LeaderGroup ? this.#group.gone(sock) : undefined) };
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

  /** The page's `layout` message: template, cards and the mode's settings (sleep: the fixed view). */
  #layoutMsg(mode: RunMode) {
    if (mode === "sleep") return JSON.stringify({ type: "layout", mode, ...SLEEP_LAYOUT, settings: {} });
    const m = this.#cfg.modes[mode];
    return JSON.stringify({ type: "layout", mode, template: m.layout.template, cards: m.layout.cards, settings: this.#settings(mode) });
  }

  /** A new layout rebuilds the page's cards: they get the latest state again right after it. */
  #sendLayout(mode: RunMode) {
    if (this.#running?.veil) return; // sent when the veil lifts
    this.#sendPages(this.#layoutMsg(mode));
    if (this.#sleep) this.#sendPages(this.#sleep.sleepMessage());
    for (const m of this.#replay()) this.#sendPages(m);
    if (mode === "focus") this.#sendPages(this.#focusMsg(null));
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
  #project(mode: RunMode): ProjectSpec {
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
    const latest = [...this.#latest.values()];
    for (const l of latest) {
      m ??= l.music;
      t ??= l.truck;
    }
    const withClaude = latest.filter((l) => l.claude);
    const withJobs = latest.filter((l) => l.jobs !== null);
    const claude = withClaude.length ? { sessions: withClaude.reduce((a, l) => a + l.claude!.sessions, 0), waiting: withClaude.reduce((a, l) => a + l.claude!.waiting, 0) } : null;
    const jobs = withJobs.length ? withJobs.reduce((a, l) => a + l.jobs!, 0) : null;
    const job = t && typeof t.job === "object" && t.job ? (t.job as Rec) : null;
    return {
      music: m && !m.none ? { title: m.title ?? "", artist: m.artist ?? "", playing: m.playing === true } : null,
      truck: t ? { state: t.state, from: job?.from ?? null, to: job?.to ?? null, speedKmh: typeof t.speed === "number" ? Math.round(Math.abs(t.speed) * 3.6) : null } : null,
      claude,
      jobs,
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
      veil: r?.veil ?? false,
      power: { saver: this.#saver },
      lastStop: this.#lastStop,
      focus: this.#focusState(),
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
      await this.#launch(m, null);
      this.#event("screen.started", device, { mode: m });
      await this.#rememberMode(m);
      return this.status();
    });
  }

  /** Starts the kiosk for `m`; sleep also begins its run once the kiosk unit is up. Every step undone on failure. */
  async #launch(m: RunMode, sleep: { session: SleepSession; me: string } | null) {
      const headless = this.#o.headless;
      let env: NodeJS.ProcessEnv;
      try {
        env = headless ? await this.#env() : { ...(await this.#io.waylandEnv()), ...(await this.#io.hyprEnv()), ...this.#io.busEnv() };
      } catch {
        throw new AppError("agent.screen.noDisplay", 503);
      }
      const firefox = headless ?? ["firefox", "firefox-esr"].find((c) => this.#io.which(c));
      if (!firefox) throw new AppError("agent.exec.commandMissing", 500, { command: "firefox" });
      // A leftover unit (e.g. from a crash) would make systemd-run fail.
      await this.#io.exec("systemctl", ["--user", "stop", `${this.#names.unit}.service`], { env, timeoutMs: 15_000, allowFail: true });
      await rm(this.workDir, { recursive: true, force: true });
      await mkdir(join(this.workDir, "profile"), { recursive: true, mode: 0o700 });
      const token = randomBytes(32).toString("hex");
      const placement: Placement = m === "sleep" ? "fullscreen" : this.#cfg.placement;
      const state: SavedState = {
        startedAt: new Date().toISOString(), mode: m, hypr: null, placement, ws: placement === "scratch" ? SPECIAL : WORKSPACES[m],
        rules: false, bind: null, workspace: null, brightness: null, token, veil: false,
      };
      await this.#save(state);
      try {
        // The headless test kiosk has no window: no Hyprland step, no backlight.
        if (!headless) {
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
          // Sleep dims along its own curve (sleep.ts); the layout modes have one fixed backlight setting.
          const b = m === "sleep" ? null : this.#settings(m).brightness;
          if (b !== null) state.brightness = await this.#setBrightness(b, null);
          await this.#save(state);
        }
        await writeFile(join(this.workDir, "profile", "user.js"), userJs(), { mode: 0o600 });
        const startFile = join(this.workDir, "start.html");
        await writeFile(startFile, startHtml(`${this.#pageBase()}#t=${token}`), { mode: 0o600 });
        // Show the empty named workspace first: Firefox maps straight onto it (no flash of the old workspace).
        if (placement === "fullscreen" && !headless) await this.#hypr(env, focusWorkspaceArgs(state.hypr!, `name:${state.ws}`)).catch(() => {});
        const profile = join(this.workDir, "profile");
        const args = headless ? headlessArgs({ browser: headless, profile, url: `file://${startFile}` }) : kioskArgs({ firefox, profile, url: `file://${startFile}`, env });
        const r = await this.#io.exec("systemd-run", args, { env, timeoutMs: 15_000, allowFail: true });
        if (r.code !== 0) throw new AppError("agent.screen.startFailed", 502, { stderr: r.stderr.slice(0, 300) });
        if (sleep) {
          this.#sleep = await SleepRun.begin(this.#sleepDeps(env), sleep.session, sleep.me, this.#o.sleep.scale);
          this.#group = this.#makeGroup(this.#sleep.file);
        }
      } catch (e) {
        this.#sleep?.detach();
        this.#sleep = null;
        this.#group?.close();
        this.#group = null;
        await this.#cleanup(state, env).catch(() => {});
        throw e;
      }
      this.#token = Buffer.from(token, "utf8");
      this.#shown = false;
      this.#began(state, null);
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

  /** A started (or adopted) mode: visibility, subscriptions, the unit watch and, in Focus, the timer. */
  #began(state: SavedState, focus: FocusTimes | null) {
    this.#running = state;
    this.#paused = false;
    this.#watchVisibility(state);
    this.#resubscribe();
    this.#watch = setInterval(() => void this.#checkUnit(), this.#o.watchMs);
    this.#watch.unref?.();
    // Sleep: no session summary (its morning summary is S5's) and no battery saver (the view is already the dimmest).
    if (state.mode === "sleep") return;
    this.#summary = new SessionSummary(Date.parse(state.startedAt) || Date.now(), state.mode);
    this.#focusFor(state.mode, focus);
    this.#battery = findBattery(this.#o.power.io, this.#o.power.dir);
    this.#power();
    if (this.#battery) {
      this.#powerTimer = setInterval(() => this.#power(), this.#o.power.everyMs);
      this.#powerTimer.unref?.();
    }
  }

  async #switch(mode: ScreenMode) {
    const st = this.#running!;
    if (st.mode === mode) return this.status();
    // Sleep holds the hardware along its curve: it is stopped (POST /v1/sleep/stop or /v1/screen/stop), not switched.
    if (st.mode === "sleep") throw new AppError("agent.sleep.running", 409);
    const missing = this.#missing(mode);
    if (missing.length) throw new AppError("agent.screen.noSource", 409, { sources: missing });
    st.mode = mode;
    this.#summary?.mode(mode);
    await this.#save(st).catch(() => {});
    this.#focusFor(mode, null);
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

  /** `why`: "user" (API, the page's Esc hold: a sleep group stops with it), "local" (the kiosk died, the agent exits). */
  stop(device?: string, why: StopWhy = "user") {
    return this.#serial(async () => {
      await this.#stopInner(device, why);
      return this.status();
    });
  }

  /** Stops the running mode (any), with its events and the summary push; inside the serial chain. */
  async #stopInner(device?: string, why: StopWhy = "user") {
    const state = this.#running;
    if (!state) return;
    if (state.mode === "sleep" && this.#sleep && why !== "local") {
      // A user stop ends the whole group: told before this host's link closes; a late hello gets `stop` (leader).
      if (why === "user") this.#group?.user("stop");
      const now = Date.now();
      for (const [id, at] of this.#ended) if (now - at > ENDED_MS) this.#ended.delete(id);
      this.#ended.set(this.#sleep.file.session.id, now);
    }
    const summary = this.#summary?.params(Date.now(), this.#o.summaryMinMs) ?? null;
    this.#focusEnded(summary !== null);
    await this.#stopNow(state);
    this.#event(state.mode === "sleep" ? "sleep.stopped" : "screen.stopped", device);
    this.#lastStop = { at: Date.now(), summary: summary !== null };
    // ONE notification at the stop: the phone adds the count of the notifications it held during Focus to it.
    if (summary) void this.#ctx.notifier.send({ key: "screen.summary", params: summary, data: { agent: this.#ctx.store.get().name }, transient: true }).catch((e) => this.#log("ekran modu özeti gönderilemedi", e));
  }

  async #stopNow(state: SavedState) {
    const sleep = this.#sleep;
    this.#let(4410, "stopped");
    await this.#focusSave;
    // Sleep: every saved hardware value back first; its file then goes (the cleanup would restore it once more).
    if (sleep) {
      await sleep.stop().catch((e) => this.#log("uyku modu donanımı geri alınamadı", e));
      await rm(this.#sleepFile(), { force: true }).catch(() => {});
    }
    const env = await this.#env();
    await this.#cleanup(state, env);
  }

  /** Drops everything this agent holds for the mode (timers, watchers, pages, subscriptions); nothing outside. */
  #let(code: number, reason: string) {
    this.#running = null;
    this.#token = null;
    if (this.#watch) clearInterval(this.#watch);
    this.#watch = null;
    this.#vis?.stop();
    this.#vis = null;
    this.#paused = false;
    this.#focus?.stop();
    this.#focus = null;
    this.#sleep?.detach();
    this.#sleep = null;
    this.#group?.close();
    this.#group = null;
    this.#summary = null;
    if (this.#powerTimer) clearInterval(this.#powerTimer);
    this.#powerTimer = null;
    this.#saver = false;
    this.#battery = null;
    for (const p of [...this.#pages]) if (p.readyState === 0 || p.readyState === 1) p.close(code, reason);
    this.#pages.clear();
    this.#unsubscribeAll();
  }

  async #env(): Promise<NodeJS.ProcessEnv> {
    const env: NodeJS.ProcessEnv = { ...process.env, XDG_RUNTIME_DIR: this.#io.runtimeDir, ...this.#io.busEnv() };
    return { ...env, ...(await this.#io.hyprEnv().catch(() => ({}))) };
  }

  /** Undoes everything the state says was done; every step is best effort. */
  async #cleanup(state: SavedState, env: NodeJS.ProcessEnv, names: Names = this.#names) {
    const dir = join(this.#io.runtimeDir, names.dir);
    // A sleep run's hardware (crash, or a failed start): what its state file says was there before.
    if (names === this.#names) {
      const raw = await readFile(this.#sleepFile(dir), "utf8").catch(() => null);
      if (raw !== null) {
        let saved: HwSaved | null = null;
        try {
          saved = sanitizeSaved((JSON.parse(raw) as Rec).saved);
        } catch {}
        if (saved) await this.#hardware(env).restore(saved).catch((e) => this.#log("uyku modu donanımı geri alınamadı", e));
      }
    }
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
      let slept = false;
      await this.#recoverPreview();
      // The headless test kiosk never touches the real ones (nor a 0.5 Game mode's).
      for (const names of this.#o.headless ? [this.#names] : [CURRENT, LEGACY]) {
        const dir = join(this.#io.runtimeDir, names.dir);
        let state: SavedState;
        try {
          state = sanitizeState(JSON.parse(await readFile(this.#stateFile(dir), "utf8")) as Rec);
          if (names === this.#names && (await this.#adopt(state))) continue;
          slept ||= state.mode === "sleep";
        } catch {
          // No state file: a stray work dir or unit from an older run is still removed.
          if (await stat(dir).then(() => true, () => false)) await this.#cleanup(sanitizeState({}), await this.#env(), names);
          continue;
        }
        await this.#cleanup(state, await this.#env(), names);
        found = true;
      }
      if (found) this.#event(slept ? "sleep.stopped" : "screen.stopped");
      return found;
    });
  }

  /** The previous agent left a running mode (restart or crash) and its Firefox still runs: carry on with it. */
  async #adopt(state: SavedState): Promise<boolean> {
    if (!state.token || this.#running) return false;
    const r = await this.#io.exec("systemctl", ["--user", "is-active", `${this.#names.unit}.service`], { env: await this.#env(), timeoutMs: 5000, allowFail: true }).catch(() => null);
    if (r?.stdout.trim() !== "active") return false;
    if (state.mode === "sleep") {
      // The run goes on from its file (its saved hardware values stay as they were at the start); unreadable → stop.
      const file = parseSleepFile(await readFile(this.#sleepFile(), "utf8").then((t) => JSON.parse(t) as unknown, () => null));
      if (!file) return false;
      this.#sleep = SleepRun.adopt(this.#sleepDeps(await this.#env()), file);
      this.#group = this.#makeGroup(file);
    }
    let focus: FocusTimes | null = null;
    if (state.mode === "focus") {
      try {
        focus = parseTimes(JSON.parse(await readFile(this.#focusFile(), "utf8")));
      } catch {} // no timer running, or an unreadable file: idle
    }
    this.#token = Buffer.from(state.token, "utf8");
    this.#shown = true; // the scratch workspace was shown by the previous agent
    this.#began(state, focus);
    return true;
  }

  async #checkUnit() {
    if (!this.#running) return;
    const r = await this.#io.exec("systemctl", ["--user", "is-active", `${this.#names.unit}.service`], { env: await this.#env(), timeoutMs: 5000, allowFail: true }).catch(() => null);
    // Firefox gone (closed or crashed): finish the stop so nothing is left behind (a sleep group goes on without us).
    if (r && r.stdout.trim() !== "active" && r.stdout.trim() !== "activating") void this.stop(undefined, "local");
  }

  /** Agent exit: a restart leaves the mode for the next agent (adopted in recover()); any other exit stops it. */
  async shutdown() {
    await this.#preview?.end();
    const restarting = this.#running !== null && (await this.#io.restarting?.().catch(() => false)) === true;
    if (!restarting) return void (await this.stop(undefined, "local"));
    await this.#serial(async () => {
      if (!this.#running) return;
      this.#let(1012, "restart");
      await this.#focusSave;
    });
  }

  #event(key: string, device?: string, params?: Record<string, string>) {
    void this.#ctx.notifier.events?.record({ key, ...(params ? { params } : {}), ...(device ? { device } : {}) }, (e) => this.#log("olay yazılamadı", e));
  }

  #pageBase() {
    const { host, port } = this.#ctx.store.get().listen;
    const h = host === "0.0.0.0" || host === "::" || host === "localhost" ? "127.0.0.1" : host.includes(":") ? `[${host}]` : host;
    return `http://${h}:${port}/screen/`;
  }

  // ---- focus timer (W5) ----

  #focusFile = () => join(this.workDir, "focus.json");

  /** The timer follows the mode: created when Focus starts (or is adopted with saved times), gone when it ends. */
  #focusFor(mode: RunMode, restored: FocusTimes | null) {
    if (mode !== "focus") {
      if (!this.#focus) return;
      this.#focusEnded();
      this.#focus.stop();
      this.#focus = null;
      this.#saveFocus(null);
      return;
    }
    if (this.#focus) return;
    this.#focus = new FocusClock(
      {
        durations: () => this.#cfg.modes.focus,
        save: async (t) => this.#saveFocus(t),
        onChange: (t, cause, from) => this.#focusChanged(t, cause, from),
      },
      restored,
    );
  }

  /** Writes (or removes) focus.json in order; never the task. */
  #saveFocus(t: FocusTimes | null) {
    const st = this.#running;
    this.#focusSave = this.#focusSave
      .then(async () => {
        if (t && st && this.#running === st) {
          // Whole or nothing: the next agent may read it at any moment.
          await writeFile(`${this.#focusFile()}.new`, JSON.stringify(t) + "\n", { mode: 0o600 });
          await rename(`${this.#focusFile()}.new`, this.#focusFile());
        }
        else if (!t) await rm(this.#focusFile(), { force: true });
      })
      .catch((e) => this.#log("odak sayacı durumu yazılamadı", e));
  }

  #focusState() {
    const t = this.#focus?.times ?? IDLE;
    return { phase: t.phase, endsAt: t.endsAt, pausedLeft: t.pausedLeft, total: t.total, round: t.round, longEvery: this.#cfg.modes.focus.longEvery, task: this.#focus?.task ?? null, now: Date.now() };
  }

  /** The page's `focus` message; `cause` set when the phase just changed ("timer": it ended by itself → chime). */
  #focusMsg(cause: "timer" | "action" | null) {
    return JSON.stringify({ type: "focus", ...this.#focusState(), cause });
  }

  #focusChanged(t: FocusTimes, cause: "timer" | "action" | null, from: FocusPhase) {
    if (!this.#running?.veil) this.#sendPages(this.#focusMsg(cause));
    if (!cause) return;
    this.#summary?.focus(from, t.phase, cause);
    // No task text: the phone shows the phase (W6); the record says which phase began and why.
    const params = { phase: t.phase, from, round: t.round, cause };
    this.#focusPush(params, t.endsAt);
  }

  /**
   * The phase push. `data` (sent, never recorded) tells the phone whether to quiet its notifications (`quiet`), when the
   * phase ends (`endsAt`, ms) and which agent runs the timer (`agent`), for its ongoing notification and its Pause button.
   */
  #focusPush(params: { phase: FocusPhase; from: FocusPhase; round: number; cause: string }, endsAt: number | null, summary = false) {
    const data = { agent: this.#ctx.store.get().name, quiet: this.#cfg.modes.focus.quietPhone ? "1" : "0", ...(endsAt !== null ? { endsAt: String(endsAt) } : {}), ...(summary ? { summary: "1" } : {}) };
    void this.#ctx.notifier.send({ key: "screen.focus.phase", params, data }).catch((e) => this.#log("odak bildirimi gönderilemedi", e));
  }

  /**
   * Focus ends with a running timer (mode stopped or switched): one `cause: "stop"` push so the phone ends its quiet.
   * `summary`: a `screen.summary` push follows (data.summary "1"); the phone keeps its held count for that one.
   */
  #focusEnded(summary = false) {
    const t = this.#focus?.times;
    if (t && t.phase !== "idle") this.#focusPush({ phase: "idle", from: t.phase, round: t.round, cause: "stop" }, null, summary);
  }

  /** POST /v1/screen/focus. Only while the Focus mode runs (409 agent.screen.notFocus otherwise). */
  focusAction(action: FocusAction | undefined, task?: string | null) {
    return this.#serial(async () => {
      if (!this.#focus) throw new AppError("agent.screen.notFocus", 409);
      this.#focus.act(action, task);
      return this.#focusState();
    });
  }

  // ---- sleep mode (PLAN.md §21 S2) ----

  #sleepFile = (dir = this.workDir) => join(dir, "sleep.json");

  #hardware(env: NodeJS.ProcessEnv) {
    // The headless test kiosk touches no hardware: no tool is "there".
    const which = this.#o.headless ? () => false : (c: string) => this.#io.which(c);
    return new Hardware({ exec: (cmd, args, opts) => this.#io.exec(cmd, args, { ...opts, env }), which, ledsDir: this.#o.sleep.ledsDir }, this.#log);
  }

  #clock() {
    const o = this.#o.sleep;
    return { ...(o.now ? { now: o.now } : {}), ...(o.setTimeout ? { setTimeout: o.setTimeout } : {}), ...(o.clearTimeout ? { clearTimeout: o.clearTimeout } : {}) };
  }

  /** A DDC bus found once is a setting (screen.modes.sleep.ddc.bus), not a trace. */
  #storeBus = async (bus: number) => {
    await this.#ctx.store.update((c) => ((c.screen.modes.sleep.ddc.bus = bus), c));
  };

  /** The group of a run with more than one member: the leader's peers, or a member's link (null alone). */
  #makeGroup(file: SleepFile): SleepGroup | null {
    const s = file.session;
    if (s.members.length < 2) return null;
    const deps = {
      session: s,
      me: file.me,
      // Another member's user stop: this host stops too (no relay back).
      onStop: () => void this.#serial(async () => {
        if (this.#running?.mode === "sleep" && this.#sleep?.file.session.id === s.id) await this.#stopInner(undefined, "group");
      }),
      // snooze / dismiss / phase: the alarm's (S4); S3 carries them only.
      onEvent: () => {},
      log: this.#log,
      ...this.#clock(),
    };
    if (s.leader === file.me) return new LeaderGroup(deps);
    return new MemberGroup({ ...deps, send: (m) => this.#sendLeader(m), onOffset: (ms) => this.#sleep?.setOffset(ms) });
  }

  /** The source name of the link to the leader (a member of a running group), or null. */
  #leaderConn(): string | null {
    const g = this.#group;
    return g instanceof MemberGroup && this.#sleep ? leaderSource(this.#cfg.sources, this.#sleep.file.session.leader) : null;
  }

  #sendLeader(m: object): boolean {
    const name = this.#leaderConn();
    const ws = name ? this.#conns.get(name)?.ws : null;
    if (!ws || ws.readyState !== 1) return false;
    try {
      ws.send(JSON.stringify(m));
      return true;
    } catch {
      return false;
    }
  }

  /** A `sleepGroup` message on this host's feed (the leader's side). Not this host's running session: stop or unknown. */
  #groupIn(sock: Sock, raw: unknown) {
    const m = parseGroupMessage(raw);
    if (!m) return;
    const g = this.#group;
    if (g instanceof LeaderGroup && this.#sleep?.file.session.id === m.sessionId) return g.message(sock, m);
    if ((m.action !== "hello" && m.action !== "state") || sock.readyState !== 1) return;
    const ended = this.#ended.get(m.sessionId);
    const me = hostIdOf(this.#ctx.store.get().name);
    sock.send(JSON.stringify(ended !== undefined ? { type: "sleepGroup", sessionId: m.sessionId, action: "stop", host: me, at: ended } : { type: "sleepGroup", sessionId: m.sessionId, action: "unknown" }));
  }

  /** Test only (TIPHYS_SLEEP_SYNCLOG): the page's crackle timings, appended to the work dir (gone with the mode). */
  syncLog(lines: unknown) {
    if (!this.#o.sleep.syncLog || !this.#sleep || !Array.isArray(lines)) return;
    const ok = lines.slice(0, 64).filter((l) => Array.isArray(l) && l.length <= 8 && l.every((x) => typeof x === "string" || (typeof x === "number" && Number.isFinite(x))));
    if (!ok.length) return;
    const me = this.#sleep.file.me;
    void writeFile(join(this.workDir, SYNC_FILE), ok.map((l) => JSON.stringify([me, ...(l as unknown[])])).join("\n") + "\n", { flag: "a", mode: 0o600 }).catch(() => {});
  }

  #sleepDeps(env: NodeJS.ProcessEnv) {
    return {
      hw: this.#hardware(env),
      syncLog: this.#o.sleep.syncLog,
      settings: () => this.#cfg.modes.sleep,
      // Whole or nothing (rename), 0600 in the 0700 tmpfs work dir (written only while the run begins).
      save: async (f: unknown) => {
        await writeFile(`${this.#sleepFile()}.new`, JSON.stringify(f) + "\n", { mode: 0o600 });
        await rename(`${this.#sleepFile()}.new`, this.#sleepFile());
      },
      send: (m: string) => {
        if (!this.#running?.veil) this.#sendPages(m);
      },
      storeBus: this.#storeBus,
      log: this.#log,
      ...this.#clock(),
    };
  }

  #previewFile = () => join(this.#io.runtimeDir, PREVIEW_FILE);

  async #previewer() {
    this.#preview ??= new HardwarePreview({
      hw: this.#hardware(await this.#env()),
      settings: () => this.#cfg.modes.sleep,
      save: async (saved) => {
        if (saved) await writeFile(this.#previewFile(), JSON.stringify({ saved }) + "\n", { mode: 0o600 });
        else await rm(this.#previewFile(), { force: true });
      },
      storeBus: this.#storeBus,
      log: this.#log,
      ...this.#clock(),
    });
    return this.#preview;
  }

  /** A preview the previous agent left (crash within its 5 s): its saved value back. */
  async #recoverPreview() {
    const raw = await readFile(this.#previewFile(), "utf8").catch(() => null);
    if (raw === null) return;
    try {
      await this.#hardware(await this.#env()).restore(sanitizeSaved((JSON.parse(raw) as Rec).saved));
    } catch (e) {
      this.#log("parlaklık önizlemesi geri alınamadı", e);
    }
    await rm(this.#previewFile(), { force: true }).catch(() => {});
  }

  /** GET /v1/sleep. */
  sleepStatus() {
    const r = this.#sleep?.status() ?? null;
    const name = this.#ctx.store.get().name;
    const g = this.#group?.status() ?? null;
    const me = this.#sleep?.file.me;
    const alone = r ? r.session.members.map((m) => ({ host: m.host, side: m.side, distance: m.distance, leader: true, state: m.host === me ? "running" : "unknown" })) : null;
    return {
      running: r !== null,
      session: r?.session ?? null,
      phase: r?.phase ?? null,
      phaseStartedAt: r?.phaseStartedAt ?? null,
      phaseEndsAt: r?.phaseEndsAt ?? null,
      // S4: the alarm; S3: the other members.
      alarm: { next: null, ringing: false, snoozedUntil: null },
      members: g?.members ?? alone ?? [{ host: hostIdOf(name), state: "off" }],
      // S3: the group link, clock offset and `agent.sleep.memberDown` (null alone or off).
      group: g ? { role: g.role, link: g.link, offsetMs: g.offsetMs, appliedOffsetMs: g.appliedOffsetMs, rttMs: g.rttMs, syncedAt: g.syncedAt, error: g.error } : null,
      brightness: r?.brightness ?? null,
      warning: r?.warning ?? null,
      page: r?.page ?? null,
      scale: this.#o.sleep.scale,
      settings: this.#cfg.modes.sleep,
      now: Date.now(),
    };
  }

  /**
   * POST /v1/sleep/start. Without a session: one made here (this host alone, its own side/distance). A group session
   * (S3): this host must be a member (else 409 agent.sleep.noGroup {reason: "notMember"}), and a non-leader needs a
   * source to the leader (sleep_group.ts leaderSource; else 409 agent.sleep.noGroup {reason: "noLeaderSource",
   * leader}). Already sleeping: the status (the phone may retry). A running layout mode is stopped first.
   */
  startSleep(session: SleepSession | undefined, device?: string) {
    return this.#serial(async () => {
      if (this.#running?.mode === "sleep") return this.sleepStatus();
      const me = hostIdOf(this.#ctx.store.get().name);
      const set = this.#cfg.modes.sleep;
      const s: SleepSession = session ?? {
        id: randomBytes(12).toString("base64url"), seed: randomBytes(4).readUInt32BE(0), t0: Date.now(), members: [{ host: me, side: set.side, distance: set.distance }], leader: me,
      };
      if (!s.members.some((m) => m.host === me)) throw new AppError("agent.sleep.noGroup", 409, { reason: "notMember", host: me });
      if (s.members.length > 1 && s.leader !== me && !leaderSource(this.#cfg.sources, s.leader)) throw new AppError("agent.sleep.noGroup", 409, { reason: "noLeaderSource", leader: s.leader });
      await this.#preview?.end();
      if (this.#running) await this.#stopInner(device);
      await this.#launch("sleep", { session: s, me });
      this.#event("sleep.started", device);
      return this.sleepStatus();
    });
  }

  /** POST /v1/sleep/stop: stops the sleep mode only (a layout mode running instead is left alone). */
  stopSleep(device?: string) {
    return this.#serial(async () => {
      if (this.#running?.mode === "sleep") await this.#stopInner(device);
      return this.sleepStatus();
    });
  }

  /** PUT /v1/sleep (partial settings). A running sleep gets the new settings at once (times at the next start). */
  updateSleep(patch: Record<string, unknown>) {
    return this.#change((c) => {
      c.modes.sleep = mergeSettings(c.modes.sleep, patch);
    }).then(() => this.sleepStatus());
  }

  /** POST /v1/sleep/preview: 5 s at `pct` — on the running sleep (hardware and page), otherwise the hardware alone. */
  previewSleep(pct: number) {
    return this.#serial(async () => {
      if (this.#sleep) {
        this.#sleep.preview(pct);
        return this.sleepStatus();
      }
      const p = await (await this.#previewer()).show(pct);
      return { ...this.sleepStatus(), preview: p };
    });
  }

  /** The kiosk page's heartbeat (every 10 s while the sleep view runs). */
  heartbeat() {
    this.#sleep?.heartbeat();
  }

  // ---- privacy veil (W5) ----

  /** POST /v1/screen/veil: on → the page drops its view for a dim clock and gets no topic message until off. */
  setVeil(on: boolean) {
    return this.#serial(async () => {
      const st = this.#running;
      if (!st) throw new AppError("agent.screen.notRunning", 409);
      if (st.veil === on) return this.status();
      st.veil = on;
      await this.#save(st).catch((e) => this.#log("ekran modu durumu yazılamadı", e));
      this.#sendPages(JSON.stringify({ type: "veil", on }));
      if (!on) this.#sendLayout(st.mode);
      return this.status();
    });
  }

  // ---- battery saver (W7) ----

  #powerMsg = () => JSON.stringify({ type: "power", saver: this.#saver });

  /** A battery reading (the `self` system message's, or read from /sys now) → saver on/off, told to the page. */
  #power(b?: { level: number; charging: boolean } | null) {
    if (!this.#running) return;
    const battery = b !== undefined ? b : this.#battery ? readBattery(this.#o.power.io, this.#battery) : null;
    const next = saverNext(this.#saver, battery, this.#cfg.batterySaver);
    if (next === this.#saver) return;
    this.#saver = next;
    this.#sendPages(this.#powerMsg());
  }

  // ---- visibility ----

  #watchVisibility(st: SavedState) {
    if (!this.#io.hyprEvents || this.#o.headless) return;
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
      if (st?.mode === "sleep") {
        if (JSON.stringify(before.modes.sleep) !== JSON.stringify(next.modes.sleep)) this.#sleep?.settingsChanged();
      } else if (st) {
        const m = st.mode;
        const was = before.modes[m];
        const now = next.modes[m];
        if (JSON.stringify(was.layout) !== JSON.stringify(now.layout)) this.#sendLayout(m);
        else if (JSON.stringify(was) !== JSON.stringify(now)) this.#sendPages(JSON.stringify({ type: "settings", ...this.#settings(m) }));
        if (now.brightness !== was.brightness) await this.#applyBrightness(now.brightness);
        if (next.batterySaver !== before.batterySaver) this.#power();
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
    // Sleep subscribes nothing (no producer runs while sleeping; Velour comes in S5).
    const need = st && st.mode !== "sleep" ? layoutTopics(st.mode, this.#cfg.modes[st.mode].layout, this.#settings(st.mode), this.#paused) : new Map<string, Set<Topic>>();
    // A sleep group member: the link to the leader (no topics; group messages only).
    const lead = this.#leaderConn();
    if (st?.mode === "sleep" && lead) need.set(lead, new Set());
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
        const conn: Conn = { name, topics, project, ws: null, state: "off", attempt: 0, timer: null, idle: null, legacy: false, opened: false, group: name === lead };
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
      if (c.group && this.#group instanceof MemberGroup) this.#group.linkUp();
    };
    ws.onmessage = (ev) => {
      if (!mine()) return;
      this.#kick(c);
      if (c.group && typeof ev.data === "string" && /^\{"type":"(?:sleepGroup|clockPong)"/.test(ev.data)) {
        if (ev.data.length > 4096 || !(this.#group instanceof MemberGroup)) return;
        try {
          this.#group.message(JSON.parse(ev.data));
        } catch {}
        return;
      }
      this.#relay(c.name, ev.data, c.topics);
    };
    ws.onclose = ws.onerror = () => {
      if (!mine()) return;
      c.ws = null;
      try {
        ws.close();
      } catch {}
      // Never opened: maybe a 0.5 source without /v1/screen/feed; the next attempt tries the other feed (not for a
      // sleep group's leader: that one has the feed).
      if (!c.opened && !c.group) c.legacy = !c.legacy;
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
    if (c.group && this.#group instanceof MemberGroup) this.#group.linkDown();
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
    this.#summary?.message(src, msg);
    if (src === "self" && msg.type === "system" && msg.battery !== undefined) this.#power(msg.battery as { level: number; charging: boolean } | null);
    // Hidden: a page that draws nothing has no use for touch effects (the city state still follows).
    if (this.#paused && msg.type === "touch") return;
    const tagged = JSON.stringify({ src, ...msg });
    const l = this.#latest.get(src) ?? emptyLatest();
    this.#latest.set(src, l);
    if (msg.type === "music") l.music = msg;
    else if (msg.type === "truck") l.truck = msg;
    else if (msg.type === "jobs") l.jobs = Array.isArray(msg.running) ? msg.running.length : 0;
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
      const list = Array.isArray(msg.sessions) ? msg.sessions : [];
      l.claude = { sessions: list.length, waiting: list.filter((x) => (x as Rec)?.status === "waiting").length };
      const open = new Set<string>();
      for (const x of Array.isArray(msg.sessions) ? msg.sessions : []) for (const r of Array.isArray((x as Rec)?.pending) ? ((x as Rec).pending as unknown[]) : []) open.add(String(r));
      for (const k of [...l.raw.keys()]) if (k.startsWith("diff:") && !open.has(k.slice(5))) l.raw.delete(k);
    }
    // Veiled: nothing of a topic reaches the page (code, diffs, names, titles); the state above is replayed later.
    if (this.#running.veil) return;
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
    if (st.veil) sock.send(JSON.stringify({ type: "veil", on: true }));
    else {
      sock.send(this.#layoutMsg(st.mode));
      if (this.#sleep) sock.send(this.#sleep.sleepMessage());
      for (const c of this.#conns.values()) sock.send(this.#sourceMsg(c));
      for (const m of this.#replay()) sock.send(m);
      if (st.mode === "focus") sock.send(this.#focusMsg(null));
    }
    if (this.#paused) sock.send(JSON.stringify({ type: "pause" }));
    if (this.#saver) sock.send(this.#powerMsg());
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
    mode: s.mode === "sleep" || SCREEN_MODES.includes(s.mode as ScreenMode) ? (s.mode as RunMode) : "game",
    hypr: hypr === "lua" || hypr === "legacy" ? hypr : null,
    placement,
    ws: typeof s.ws === "string" && /^[a-z]{1,16}$/.test(s.ws) ? s.ws : placement === "scratch" ? SPECIAL : WORKSPACES.game,
    rules: s.rules === true,
    bind: typeof s.bind === "string" && screenSchema.shape.scratchBind.safeParse(s.bind).success ? s.bind : null,
    workspace: typeof s.workspace === "string" && WS_TARGET.test(s.workspace) ? s.workspace : null,
    brightness: typeof s.brightness === "string" && /^\d{1,9}$/.test(s.brightness) ? s.brightness : null,
    token: typeof s.token === "string" && /^[a-f0-9]{64}$/.test(s.token) ? s.token : null,
    veil: s.veil === true,
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
/** The task: one line, no control characters; "" or null clears it. Without `action` only the task changes. */
const focusBody = z
  .strictObject({ action: z.enum(FOCUS_ACTIONS).optional(), task: z.string().max(TASK_MAX).regex(/^[^\p{Cc}\u2028\u2029]*$/u).nullable().optional() })
  .refine((b) => b.action !== undefined || b.task !== undefined, { message: "action or task" });

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
  app.post("/v1/screen/focus", async (req) => {
    const b = focusBody.parse(req.body);
    return { focus: await display.focusAction(b.action, b.task) };
  });
  app.post("/v1/screen/veil", async (req) => display.setVeil(z.strictObject({ on: z.boolean() }).parse(req.body).on));

  // Sleep mode (PLAN.md §21 Sözleşme; S2: this host alone).
  app.get("/v1/sleep", async () => display.sleepStatus());
  app.put("/v1/sleep", async (req) => display.updateSleep(sleepPutSchema.parse(req.body).settings));
  app.post("/v1/sleep/start", async (req) => display.startSleep(sleepStartSchema.parse(req.body ?? {}).session, req.device?.id));
  app.post("/v1/sleep/stop", async (req) => display.stopSleep(req.device?.id));
  app.post("/v1/sleep/preview", async (req) => display.previewSleep(sleepPreviewSchema.parse(req.body).brightness));

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
          if (d.length > 2048) return;
          try {
            const m = JSON.parse(d.toString()) as { type?: unknown; lines?: unknown };
            if (m?.type === "stop") void display.stop().catch(() => {});
            else if (m?.type === "heartbeat") display.heartbeat();
            else if (m?.type === "syncLog") display.syncLog(m.lines);
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
