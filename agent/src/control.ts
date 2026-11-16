// Remote control session ("control" feature): desktop endpoints that change the PC (window actions, app launch,
// workspace, DPMS; later live screen input and Claude's computer use) only work with the token of an open
// session (X-Tiphys-Control header).
// - The session is timed (default 15 min, extendable, at most 60 min remaining); it closes by itself when it expires.
// - One session at a time; if another device wants to open one, 409. Closing (DELETE) is open to every paired device:
//   stopping is always safe.
// - While open, a visible sign on the PC: notify-send + Hyprland border color/width (old value saved and restored on
//   close; if the agent crashes it's restored from the file on next startup).
// - Open/close is written to the event stream (device, duration, reason); tokens, keys and content are not.
// - Mutating calls are rate-limited per session.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import { readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { AppError } from "./errors.ts";
import type { EventLog } from "./events.ts";
import type { ExecResult } from "./exec.ts";
import type { Ctx } from "./server.ts";
import { Hyprctl } from "./hyprctl.ts";

export const CONTROL_HEADER = "x-tiphys-control";
export const DEFAULT_MINUTES = 15;
/** Remaining time including extensions can't exceed this. */
export const MAX_REMAINING_MINUTES = 60;

/** Sliding-window rate limit (per key: session or device). */
export class RateLimit {
  #hits = new Map<string, number[]>();
  readonly max: number;
  readonly windowMs: number;
  readonly now: () => number;

  constructor(max: number, windowMs: number, now: () => number = Date.now) {
    this.max = max;
    this.windowMs = windowMs;
    this.now = now;
  }

  /** Spends a token and returns true if one is available. */
  take(key: string): boolean {
    const t = this.now();
    const recent = (this.#hits.get(key) ?? []).filter((x) => t - x < this.windowMs);
    if (recent.length >= this.max) {
      this.#hits.set(key, recent);
      return false;
    }
    recent.push(t);
    this.#hits.set(key, recent);
    return true;
  }

  reset(key: string) {
    this.#hits.delete(key);
  }
}

/** The visible sign on the PC (a fake is supplied in tests). If on() fails the session isn't opened. */
export interface Indicator {
  on(info: { device: string; minutes: number }): Promise<void>;
  off(info: { device: string; reason: EndReason }): Promise<void>;
}

export type EndReason = "stopped" | "expired" | "shutdown";

export interface ControlSession {
  device: string;
  deviceName: string;
  startedAt: number;
  expiresAt: number;
}

const hash = (token: string) => createHash("sha256").update(token).digest();

export class ControlSessions {
  #indicator: Indicator;
  #events: EventLog | null;
  #now: () => number;
  #log: (msg: string, err?: unknown) => void;
  #session: (ControlSession & { tokenHash: Buffer; timer: NodeJS.Timeout | null }) | null = null;
  /** Open/close (indicator commands) in order. */
  #chain: Promise<unknown> = Promise.resolve();
  /** Subscribers notified when the session closes (the live screen stream stops immediately). */
  #endListeners = new Set<(info: { device: string; reason: EndReason }) => void>();

  /** [startup]: runs in order before the first session (e.g. restoring an indicator left over from a crash). */
  constructor(opts: { indicator: Indicator; events: EventLog | null; now?: () => number; log?: (msg: string, err?: unknown) => void; startup?: () => Promise<void> }) {
    this.#indicator = opts.indicator;
    this.#events = opts.events;
    this.#now = opts.now ?? Date.now;
    this.#log = opts.log ?? (() => {});
    if (opts.startup) void this.#serial(opts.startup).catch((e) => this.#log("açılış işi başarısız", e));
  }

  #serial<T>(fn: () => Promise<T>): Promise<T> {
    const p = this.#chain.then(fn);
    this.#chain = p.catch(() => {});
    return p;
  }

  /** The open session (null if expired). */
  get active(): ControlSession | null {
    const s = this.#session;
    if (!s || this.#now() >= s.expiresAt) return null;
    return { device: s.device, deviceName: s.deviceName, startedAt: s.startedAt, expiresAt: s.expiresAt };
  }

  /**
   * Opens a session. If the same device has an open session it's renewed with a new token (the indicator stays on); if
   * another device's, 409. If the indicator can't be turned on (no Hyprland etc.) the session isn't opened.
   */
  start(device: { id: string; name: string }, minutes = DEFAULT_MINUTES): Promise<{ token: string; expiresAt: string }> {
    return this.#serial(async () => {
      await this.#expireIfDue();
      const cur = this.#session;
      if (cur && cur.device !== device.id) throw new AppError("agent.control.busy", 409, { device: cur.deviceName });
      if (!cur) {
        try {
          await this.#indicator.on({ device: device.name, minutes });
        } catch (e) {
          this.#log("kontrol göstergesi açılamadı", e);
          throw e instanceof AppError ? e : new AppError("agent.control.indicatorFailed", 503);
        }
      }
      const token = `tpc_${randomBytes(32).toString("base64url")}`;
      const now = this.#now();
      if (cur?.timer) clearTimeout(cur.timer);
      this.#session = { device: device.id, deviceName: device.name, startedAt: cur?.startedAt ?? now, expiresAt: now + minutes * 60_000, tokenHash: hash(token), timer: null };
      this.#arm();
      if (!cur) this.#record("control.started", { device: device.name, minutes });
      return { token, expiresAt: new Date(this.#session.expiresAt).toISOString() };
    });
  }

  /** Verifies the token (the session must belong to this device); closes the session if it has expired. */
  async check(token: string | undefined, deviceId: string | undefined): Promise<ControlSession> {
    await this.#serial(() => this.#expireIfDue());
    const s = this.#session;
    if (!token || !s || !deviceId) throw new AppError("agent.control.sessionRequired", 403);
    const h = hash(token);
    if (h.length !== s.tokenHash.length || !timingSafeEqual(h, s.tokenHash) || s.device !== deviceId || this.#now() >= s.expiresAt) {
      throw new AppError("agent.control.sessionRequired", 403);
    }
    return { device: s.device, deviceName: s.deviceName, startedAt: s.startedAt, expiresAt: s.expiresAt };
  }

  /** Whether the token is valid right now (synchronous; doesn't close the session). For the Claude session status summary. */
  isValid(token: string | undefined, deviceId: string | undefined): boolean {
    const s = this.#session;
    if (!token || !s || !deviceId || s.device !== deviceId || this.#now() >= s.expiresAt) return false;
    const h = hash(token);
    return h.length === s.tokenHash.length && timingSafeEqual(h, s.tokenHash);
  }

  /** Moves expiry to [minutes] from now (at most MAX_REMAINING_MINUTES remaining). */
  async extend(token: string | undefined, deviceId: string | undefined, minutes = DEFAULT_MINUTES): Promise<{ expiresAt: string }> {
    await this.check(token, deviceId);
    const s = this.#session!;
    s.expiresAt = Math.min(Math.max(s.expiresAt, this.#now() + minutes * 60_000), this.#now() + MAX_REMAINING_MINUTES * 60_000);
    this.#arm();
    return { expiresAt: new Date(s.expiresAt).toISOString() };
  }

  /** Called when the session closes (stop, expiry, agent shutdown); the returned function unsubscribes. */
  onEnd(fn: (info: { device: string; reason: EndReason }) => void): () => void {
    this.#endListeners.add(fn);
    return () => this.#endListeners.delete(fn);
  }

  /** Closes the session; false if none. */
  end(reason: EndReason = "stopped"): Promise<boolean> {
    return this.#serial(() => this.#end(reason));
  }

  async #end(reason: EndReason): Promise<boolean> {
    const s = this.#session;
    if (!s) return false;
    this.#session = null;
    if (s.timer) clearTimeout(s.timer);
    try {
      await this.#indicator.off({ device: s.deviceName, reason });
    } catch (e) {
      this.#log("kontrol göstergesi kapatılamadı", e);
    }
    this.#record("control.ended", { device: s.deviceName, seconds: Math.round((this.#now() - s.startedAt) / 1000), reason });
    for (const fn of this.#endListeners) {
      try {
        fn({ device: s.device, reason });
      } catch (e) {
        this.#log("oturum kapanış dinleyicisi hata verdi", e);
      }
    }
    return true;
  }

  async #expireIfDue() {
    if (this.#session && this.#now() >= this.#session.expiresAt) await this.#end("expired");
  }

  /** Auto-close on expiry (the timer doesn't hold up agent shutdown). */
  #arm() {
    const s = this.#session;
    if (!s) return;
    if (s.timer) clearTimeout(s.timer);
    s.timer = setTimeout(() => void this.#serial(() => this.#expireIfDue()), Math.max(0, s.expiresAt - this.#now()) + 50);
    s.timer.unref?.();
  }

  /** For tests and the timer: closes the session if it has expired. */
  expireIfDue(): Promise<void> {
    return this.#serial(() => this.#expireIfDue());
  }

  #record(key: string, params: Record<string, string | number>) {
    void this.#events?.record({ key, params }, (e) => this.#log("olay yazılamadı", e));
  }
}

export type Exec = (cmd: string, args: string[], opts: { timeoutMs?: number; allowFail?: boolean; env?: NodeJS.ProcessEnv }) => Promise<ExecResult>;

/** Border while a session is open: red → orange gradient, at least 3 px. */
export const INDICATOR_BORDER = "0xffff3b30 0xffff9f0a 45deg";
const INDICATOR_BORDER_SIZE = 3;

/** `hyprctl -j getoption general:col.active_border` → a classic value that can be written back ("ffffffff 0deg" → "0xffffffff 0deg"). */
export function gradientValue(j: unknown): string | null {
  const g = (j as { gradient?: unknown; color?: unknown })?.gradient ?? (j as { color?: unknown })?.color;
  if (typeof g !== "string" || !g.trim()) return null;
  const parts = g.trim().split(/\s+/);
  if (!parts.every((p) => /^[0-9a-fA-F]{8}$/.test(p) || /^-?\d+deg$/.test(p))) return null;
  return parts.map((p) => (p.endsWith("deg") ? p : `0x${p}`)).join(" ");
}

interface SavedLook {
  border: string;
  size: number;
}

/**
 * Hyprland indicator: changes the border color/width and announces it with notify-send. Previous values are written
 * to [stateFile]; if the agent crashes while a session is open, restoreStale() restores them on next startup.
 */
export class HyprIndicator implements Indicator {
  readonly exec: Exec;
  readonly hyprEnv: () => Promise<NodeJS.ProcessEnv>;
  readonly busEnv: () => NodeJS.ProcessEnv;
  readonly stateFile: string;

  /** Classic (keyword) / Lua (hl.config) border writes; mode detection is shared with the panel and the live screen. */
  readonly hyprctl: Hyprctl;

  constructor(exec: Exec, hyprEnv: () => Promise<NodeJS.ProcessEnv>, busEnv: () => NodeJS.ProcessEnv, stateFile: string, hyprctl?: Hyprctl) {
    this.hyprctl = hyprctl ?? new Hyprctl(exec, hyprEnv);
    this.exec = exec;
    this.hyprEnv = hyprEnv;
    this.busEnv = busEnv;
    this.stateFile = stateFile;
  }

  async #hyprctl(env: NodeJS.ProcessEnv, args: string[]) {
    const r = await this.exec("hyprctl", args, { env, timeoutMs: 5000 });
    return r.stdout;
  }

  async #notify(summary: string, body: string, urgency: "critical" | "normal") {
    // With no notification daemon or no D-Bus the border is still a sign; the error doesn't break the session.
    await this.exec("notify-send", ["-a", "Tiphys", "-u", urgency, "-i", "preferences-desktop-remote-desktop", summary, body], {
      env: { ...process.env, ...this.busEnv() },
      timeoutMs: 5000,
      allowFail: true,
    }).catch(() => {});
  }

  async on(info: { device: string; minutes: number }) {
    const env = await this.hyprEnv();
    // If a previous session's record exists its "old" values are kept (so the indicator color isn't taken as the real value).
    let look = await this.#saved();
    if (!look) {
      const border = gradientValue(JSON.parse(await this.#hyprctl(env, ["-j", "getoption", "general:col.active_border"])));
      const size = Number((JSON.parse(await this.#hyprctl(env, ["-j", "getoption", "general:border_size"])) as { int?: unknown }).int);
      if (!border || !Number.isInteger(size)) throw new AppError("agent.control.indicatorFailed", 503);
      look = { border, size };
      await writeFile(this.stateFile, JSON.stringify(look) + "\n", { mode: 0o600 });
    }
    try {
      await this.hyprctl.setLook({ border: INDICATOR_BORDER, size: look.size < INDICATOR_BORDER_SIZE ? INDICATOR_BORDER_SIZE : undefined });
    } catch (e) {
      await this.restoreStale().catch(() => {}); // the half-done change is rolled back, the session isn't opened
      throw e;
    }
    await this.#notify("Tiphys uzaktan kontrol açık", `${info.device} · ${info.minutes} dk`, "critical");
  }

  async off(info: { device: string; reason: EndReason }) {
    await this.restoreStale();
    await this.#notify("Tiphys uzaktan kontrol kapandı", info.reason === "expired" ? `${info.device} · süre doldu` : info.device, "normal");
  }

  async #saved(): Promise<SavedLook | null> {
    try {
      const j = JSON.parse(await readFile(this.stateFile, "utf8")) as SavedLook;
      return typeof j.border === "string" && Number.isInteger(j.size) ? j : null;
    } catch {
      return null;
    }
  }

  /** Restores the recorded old look and deletes the record (no-op if none). */
  async restoreStale() {
    const saved = await this.#saved();
    if (!saved) return;
    // Restoring goes the same way (hl.config in Lua mode).
    await this.hyprctl.setLook({ border: saved.border, size: saved.size });
    await rm(this.stateFile, { force: true });
  }
}

export function indicatorStatePath(configPath: string) {
  return join(dirname(configPath), "control-indicator.json");
}

/** Session endpoints: open (POST), extend (POST …/extend), close (DELETE). */
export function controlRoutes(app: FastifyInstance, ctx: Ctx, control: ControlSessions, startLimit = new RateLimit(5, 60_000)) {
  const minutes = z.object({ minutes: z.number().int().min(1).max(MAX_REMAINING_MINUTES).default(DEFAULT_MINUTES) });

  app.post("/v1/desktop/control/session", async (req) => {
    requireControlFeature(ctx);
    const device = req.device!;
    if (!startLimit.take(device.id)) throw new AppError("agent.control.rateLimited", 429);
    const { minutes: m } = minutes.parse(req.body ?? {});
    return control.start({ id: device.id, name: device.name }, m);
  });

  app.post("/v1/desktop/control/session/extend", async (req) => {
    requireControlFeature(ctx);
    const { minutes: m } = minutes.parse(req.body ?? {});
    return control.extend(tokenOf(req), req.device?.id, m);
  });

  app.delete("/v1/desktop/control/session", async () => ({ ended: await control.end("stopped") }));
}

export function tokenOf(req: FastifyRequest): string | undefined {
  const v = req.headers[CONTROL_HEADER];
  return typeof v === "string" && v.length <= 200 ? v : undefined;
}

export function requireControlFeature(ctx: Ctx) {
  // The setting is read live: when the feature is turned off (without restart) mutating endpoints stop immediately.
  if (!ctx.store.get().features.control) throw new AppError("agent.control.disabled", 403);
}

/**
 * Every mutating desktop endpoint calls this: "control" must be on, the session token valid and this device's, and the
 * rate limit not exceeded. 10.2 (live screen input) and 10.3 (Claude tools) use the same gate with their own limits.
 */
export async function requireControl(ctx: Ctx, control: ControlSessions, req: FastifyRequest, limit: RateLimit): Promise<ControlSession> {
  requireControlFeature(ctx);
  const s = await control.check(tokenOf(req), req.device?.id);
  if (!limit.take(s.device)) throw new AppError("agent.control.rateLimited", 429);
  return s;
}

/**
 * For long-lived streams (SSE): [lost] is called once if the control session ends, the token is renewed/changed or the
 * "control" feature is turned off (session end immediately, the token polled every [everyMs]; same as the live screen).
 * The returned function stops watching.
 */
export function watchControl(ctx: Ctx, control: ControlSessions, req: FastifyRequest, lost: () => void, everyMs = 2000): () => void {
  const token = tokenOf(req);
  const device = req.device?.id;
  let done = false;
  const fire = () => {
    if (done) return;
    stop();
    lost();
  };
  const offEnd = control.onEnd(() => fire());
  const timer = setInterval(() => {
    if (!ctx.store.get().features.control || !control.isValid(token, device)) fire();
  }, everyMs);
  timer.unref?.();
  const stop = () => {
    done = true;
    offEnd();
    clearInterval(timer);
  };
  return stop;
}
