// Desktop panel (10.1, "desktop" feature; Hyprland): windows, workspaces, monitors, window thumbnail,
// app list and icons (read-only) + window actions, workspace, DPMS, app launch
// (mutating; also requires the "control" feature and an open control session, see control.ts).
// - The hyprctl socket is under $XDG_RUNTIME_DIR/hypr/<signature>/; if the systemd service has no
//   HYPRLAND_INSTANCE_SIGNATURE, the newest signature folder with a socket is picked.
// - NO free-text dispatch: only the allowed action list, a validated window address (^0x[0-9a-f]+$), an integer
//   workspace and an app id that's in the list.
// - Thumbnails only for windows on a visible workspace (Hyprland doesn't render other workspaces): grim -g crop,
//   ffmpeg to WebP (otherwise PNG), 2 s cache.
import { spawn } from "node:child_process";
import { access, constants, readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { delimiter, join } from "node:path";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { ControlSessions, HyprIndicator, RateLimit, controlRoutes, indicatorStatePath, requireControl, type Exec, type Indicator } from "../control.ts";
import { APP_ID, IconResolver, appForClass, defaultIconPaths, scanApps, themesFrom, xdgDataDirs, type DesktopApp, type IconPaths } from "../desktop_apps.ts";
import { AppError } from "../errors.ts";
import { ADDRESS, Hyprctl, LAUNCH_ID, type HyprCmd } from "../hyprctl.ts";
import { run } from "../exec.ts";
import type { Ctx } from "../server.ts";
import { sessionBusEnv, waylandEnv } from "./desktop.ts";

export { ADDRESS } from "../hyprctl.ts";
export const WINDOW_ACTIONS = ["focus", "close", "fullscreen", "float", "pin", "move-to-workspace"] as const;
export type WindowAction = (typeof WINDOW_ACTIONS)[number];
const workspaceNumber = z.coerce.number().int().min(1).max(100);

export interface Bytes {
  out: Buffer;
  code: number;
  err: string;
}

/** Outside world (tests pass a fake). */
export interface HyprIo {
  exec: Exec;
  /** Command with binary output; [input] is written to stdin. */
  bytes(cmd: string, args: string[], opts: { env: NodeJS.ProcessEnv; input?: Buffer; timeoutMs?: number }): Promise<Bytes>;
  has(cmd: string): Promise<boolean>;
  /** hyprctl environment; agent.desktop.noHyprland if there's no Hyprland. */
  hyprEnv(): Promise<NodeJS.ProcessEnv>;
  /** grim environment (Wayland socket + Hyprland). */
  screenEnv(): Promise<NodeJS.ProcessEnv>;
}

/** HYPRLAND_INSTANCE_SIGNATURE: from the environment (if it has a socket) or the newest signature folder with a socket. */
export async function hyprEnv(): Promise<NodeJS.ProcessEnv> {
  const runtime = process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.() ?? 1000}`;
  const base = join(runtime, "hypr");
  const hasSocket = (sig: string) => stat(join(base, sig, ".socket.sock")).then(() => true, () => false);
  let sig = process.env.HYPRLAND_INSTANCE_SIGNATURE;
  if (!sig || !(await hasSocket(sig))) {
    const dirs = await readdir(base).catch(() => [] as string[]);
    const found: Array<[string, number]> = [];
    for (const d of dirs) {
      const s = await stat(join(base, d, ".socket.sock")).catch(() => null);
      if (s) found.push([d, s.mtimeMs]);
    }
    sig = found.sort((a, b) => b[1] - a[1])[0]?.[0];
  }
  if (!sig) throw new AppError("agent.desktop.noHyprland", 503);
  return { ...process.env, XDG_RUNTIME_DIR: runtime, HYPRLAND_INSTANCE_SIGNATURE: sig };
}

function runBytes(cmd: string, args: string[], opts: { env: NodeJS.ProcessEnv; input?: Buffer; timeoutMs?: number }): Promise<Bytes> {
  return new Promise((resolve, reject) => {
    const p = spawn(cmd, args, { env: opts.env, stdio: [opts.input ? "pipe" : "ignore", "pipe", "pipe"] });
    const out: Buffer[] = [];
    let size = 0;
    let err = "";
    const t = setTimeout(() => p.kill("SIGKILL"), opts.timeoutMs ?? 15000);
    p.stdout!.on("data", (b: Buffer) => {
      size += b.length;
      if (size > 32 * 1024 * 1024) p.kill("SIGKILL");
      else out.push(b);
    });
    p.stderr!.on("data", (b: Buffer) => (err = (err + b.toString("utf8")).slice(-1000)));
    p.on("error", (e) => {
      clearTimeout(t);
      reject((e as NodeJS.ErrnoException).code === "ENOENT" ? new AppError("agent.exec.commandMissing", 500, { command: cmd }) : e);
    });
    p.on("close", (code) => {
      clearTimeout(t);
      resolve({ out: Buffer.concat(out), code: code ?? -1, err });
    });
    if (opts.input) {
      p.stdin!.on("error", () => {}); // EPIPE if the process exits early
      p.stdin!.end(opts.input);
    }
  });
}

const which = new Map<string, Promise<boolean>>();
async function has(cmd: string): Promise<boolean> {
  if (!which.has(cmd)) {
    which.set(
      cmd,
      (async () => {
        for (const dir of (process.env.PATH ?? "/usr/bin:/bin").split(delimiter)) {
          if (await access(join(dir, cmd), constants.X_OK).then(() => true, () => false)) return true;
        }
        return false;
      })(),
    );
  }
  return which.get(cmd)!;
}

export const realHyprIo: HyprIo = {
  exec: run,
  bytes: runBytes,
  has,
  hyprEnv,
  screenEnv: async () => ({ ...(await waylandEnv()), ...(await hyprEnv()) }),
};

// ---- hyprctl JSON ----

export interface HyprWindow {
  address: string;
  class: string;
  title: string;
  workspace: { id: number; name: string };
  at: [number, number];
  size: [number, number];
  floating: boolean;
  fullscreen: boolean;
  pinned: boolean;
  hidden: boolean;
  mapped: boolean;
  monitor: number;
  pid: number | null;
  /** 0 = en son odaklanan. */
  focusHistoryId: number;
}

export interface HyprMonitor {
  id: number;
  name: string;
  width: number;
  height: number;
  x: number;
  y: number;
  scale: number;
  focused: boolean;
  activeWorkspace: number;
  specialWorkspace: number;
  dpms: boolean;
}

export interface HyprWorkspace {
  id: number;
  name: string;
  monitor: string;
  windows: number;
}

type J = Record<string, unknown>;
const num = (v: unknown, d = 0) => (typeof v === "number" && Number.isFinite(v) ? v : d);
const str = (v: unknown) => (typeof v === "string" ? v : "");
const pair = (v: unknown): [number, number] => (Array.isArray(v) ? [num(v[0]), num(v[1])] : [0, 0]);
const arr = (v: unknown): J[] => (Array.isArray(v) ? v.filter((x): x is J => !!x && typeof x === "object") : []);

export function parseClients(v: unknown): HyprWindow[] {
  return arr(v)
    .filter((c) => ADDRESS.test(str(c.address)))
    .map((c) => {
      const ws = (c.workspace ?? {}) as J;
      return {
        address: str(c.address),
        class: str(c.class) || str(c.initialClass),
        title: str(c.title) || str(c.initialTitle),
        workspace: { id: num(ws.id), name: str(ws.name) || String(num(ws.id)) },
        at: pair(c.at),
        size: pair(c.size),
        floating: c.floating === true,
        // 0.42+: number (0 none, 1 maximized, 2 fullscreen, 3 both); older version: boolean
        fullscreen: typeof c.fullscreen === "number" ? c.fullscreen > 0 : c.fullscreen === true,
        pinned: c.pinned === true,
        hidden: c.hidden === true,
        mapped: c.mapped !== false,
        monitor: num(c.monitor, -1),
        pid: typeof c.pid === "number" && c.pid > 0 ? c.pid : null,
        focusHistoryId: num(c.focusHistoryID, 999),
      };
    });
}

export function parseMonitors(v: unknown): HyprMonitor[] {
  return arr(v)
    .filter((m) => m.disabled !== true)
    .map((m) => ({
      id: num(m.id),
      name: str(m.name),
      width: num(m.width),
      height: num(m.height),
      x: num(m.x),
      y: num(m.y),
      scale: num(m.scale, 1),
      focused: m.focused === true,
      activeWorkspace: num(((m.activeWorkspace ?? {}) as J).id),
      specialWorkspace: num(((m.specialWorkspace ?? {}) as J).id),
      dpms: m.dpmsStatus !== false,
    }));
}

export function parseWorkspaces(v: unknown): HyprWorkspace[] {
  return arr(v)
    .map((w) => ({ id: num(w.id), name: str(w.name) || String(num(w.id)), monitor: str(w.monitor), windows: num(w.windows) }))
    .sort((a, b) => a.id - b.id);
}

/** Is the window on screen right now (its workspace is shown on a monitor, or an open special workspace)? */
export function isVisible(w: HyprWindow, monitors: HyprMonitor[]): boolean {
  if (!w.mapped || w.hidden || w.size[0] <= 0 || w.size[1] <= 0) return false;
  return monitors.some((m) => m.activeWorkspace === w.workspace.id || (m.specialWorkspace !== 0 && m.specialWorkspace === w.workspace.id) || (w.pinned && m.id === w.monitor));
}

/**
 * Allowed action → Hyprland commands (the adapter emits classic `dispatch` or Lua `hl.dsp…`). No other command
 * is ever produced.
 */
export function dispatchFor(action: WindowAction, w: HyprWindow, workspace?: number): HyprCmd[] {
  if (!ADDRESS.test(w.address)) throw new AppError("agent.desktop.badAddress", 400);
  const address = w.address;
  switch (action) {
    case "focus":
      return [{ op: "focusWindow", address }];
    case "close":
      return [{ op: "closeWindow", address }];
    case "fullscreen":
      // Classic fullscreen only applies to the active window: focus first (so it comes to the front in Lua too).
      return [{ op: "focusWindow", address }, { op: "fullscreen", address }];
    case "float":
      return [{ op: "toggleFloat", address }];
    case "pin":
      // Hyprland only pins floating windows.
      return w.floating ? [{ op: "pin", address }] : [{ op: "setFloat", address }, { op: "pin", address }];
    case "move-to-workspace":
      return [{ op: "moveToWorkspace", address, workspace: workspaceNumber.parse(workspace) }];
  }
}

/** Panel state along with app ids by window class (for icons). */
export function desktopState(clients: HyprWindow[], active: unknown, workspaces: HyprWorkspace[], monitors: HyprMonitor[], apps: DesktopApp[]) {
  const activeAddress = str((active as J | null)?.address);
  const focusedMonitor = monitors.find((m) => m.focused) ?? monitors[0];
  return {
    hyprland: true,
    activeWorkspace: focusedMonitor?.activeWorkspace ?? null,
    monitors: monitors.map((m) => ({ id: m.id, name: m.name, width: m.width, height: m.height, x: m.x, y: m.y, scale: m.scale, focused: m.focused, activeWorkspace: m.activeWorkspace, dpms: m.dpms })),
    workspaces: workspaces
      .filter((w) => w.id > 0 || w.windows > 0)
      .map((w) => ({ ...w, visible: monitors.some((m) => m.activeWorkspace === w.id || m.specialWorkspace === w.id), focused: w.id === focusedMonitor?.activeWorkspace })),
    windows: clients
      .filter((c) => c.mapped)
      .sort((a, b) => a.workspace.id - b.workspace.id || a.focusHistoryId - b.focusHistoryId)
      .map((c) => ({
        address: c.address,
        class: c.class,
        title: c.title,
        workspace: c.workspace,
        at: c.at,
        size: c.size,
        floating: c.floating,
        fullscreen: c.fullscreen,
        pinned: c.pinned,
        focused: c.address === activeAddress,
        visible: isVisible(c, monitors),
        appId: appForClass(apps, c.class)?.id ?? null,
      })),
  };
}

export interface HyprOpts {
  appDirs?: string[];
  icons?: IconPaths;
  /** The user's icon theme (default: gtk settings.ini + gsettings). */
  themes?: () => Promise<string[]>;
  indicator?: Indicator;
  now?: () => number;
  /** Mutating panel calls (per session). */
  panelLimit?: RateLimit;
  thumbCacheMs?: number;
}

/**
 * App icon file (resolved by IconResolver) → response body: a PNG as is; an SVG converted to PNG with rsvg-convert,
 * otherwise ffmpeg's librsvg decoder; if neither exists, the SVG as is. Also used by the helper backend.
 */
export async function iconImage(io: Pick<HyprIo, "has" | "bytes">, path: string, size: number): Promise<{ type: string; body: Buffer }> {
  const file = await readFile(path);
  if (file.length > 2 * 1024 * 1024) throw new AppError("agent.desktop.iconNotFound", 404);
  if (path.toLowerCase().endsWith(".png")) {
    if (!isPng(file)) throw new AppError("agent.desktop.iconNotFound", 404);
    return { type: "image/png", body: file };
  }
  const s = String(size);
  const tries: Array<[string, string[]]> = [
    ["rsvg-convert", ["-w", s, "-h", s, "-a", "-f", "png", path]],
    ["ffmpeg", ["-v", "error", "-c:v", "librsvg", "-width", s, "-height", s, "-keep_ar", "1", "-i", path, "-frames:v", "1", "-f", "image2pipe", "-c:v", "png", "-"]],
  ];
  for (const [cmd, args] of tries) {
    if (!(await io.has(cmd))) continue;
    const r = await io.bytes(cmd, args, { env: process.env, timeoutMs: 10000 }).catch(() => null);
    if (r && r.code === 0 && isPng(r.out)) return { type: "image/png", body: r.out };
  }
  return { type: "image/svg+xml", body: file };
}

/** The user's icon theme(s): gtk settings.ini + gsettings. */
export async function defaultThemes(exec: Exec): Promise<string[]> {
  const ini = await Promise.all(["gtk-3.0", "gtk-4.0"].map((d) => readFile(join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), d, "settings.ini"), "utf8").catch(() => "")));
  const g = await exec("gsettings", ["get", "org.gnome.desktop.interface", "icon-theme"], { timeoutMs: 3000, allowFail: true }).then((r) => (r.code === 0 ? r.stdout : null), () => null);
  return themesFrom(ini, g);
}

const isPng = (b: Buffer) => b.length > 8 && b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
const isWebp = (b: Buffer) => b.length > 12 && b.subarray(0, 4).toString("latin1") === "RIFF" && b.subarray(8, 12).toString("latin1") === "WEBP";

export function hyprRoutes(app: FastifyInstance, ctx: Ctx, io: HyprIo = realHyprIo, opts: HyprOpts = {}) {
  const now = opts.now ?? Date.now;
  const log = (msg: string, err?: unknown) => app.log.warn({ err }, msg);
  // Classic/Lua mode detection shared by the panel, the PC indicator and the live screen.
  const hyprctl = new Hyprctl(io.exec, io.hyprEnv);
  ctx.hyprctl = hyprctl;
  const indicator =
    opts.indicator ?? new HyprIndicator(io.exec, io.hyprEnv, sessionBusEnv, indicatorStatePath(ctx.store.path), hyprctl);
  // If the agent crashed while a session was open, the border on the PC reverts (at session-open time: doesn't interfere).
  const control = new ControlSessions({
    indicator,
    events: ctx.notifier.events,
    now,
    log,
    startup: indicator instanceof HyprIndicator ? () => indicator.restoreStale() : undefined,
  });
  ctx.control = control;
  app.addHook("onClose", async () => void (await control.end("shutdown")));
  controlRoutes(app, ctx, control);
  // Panel: at most 10 mutating calls per 5 s (taps; live screen input has its own limit in 10.2).
  const panelLimit = opts.panelLimit ?? new RateLimit(10, 5000, now);
  const guard = (req: Parameters<typeof requireControl>[2]) => requireControl(ctx, control, req, panelLimit);

  const appDirs = opts.appDirs ?? xdgDataDirs().map((d) => join(d, "applications"));
  const icons = new IconResolver(opts.icons ?? defaultIconPaths(), opts.themes ?? (() => defaultThemes(io.exec)));
  const appCache = new Map<string, { at: number; apps: Promise<DesktopApp[]> }>();
  const apps = (lang: string) => {
    const c = appCache.get(lang);
    if (c && now() - c.at < 60_000) return c.apps;
    const p = scanApps(appDirs, lang);
    appCache.set(lang, { at: now(), apps: p });
    p.catch(() => appCache.delete(lang));
    return p;
  };
  ctx.desktopApps = () => apps("en");
  const findApp = async (id: string) => {
    if (!APP_ID.test(id)) throw new AppError("agent.desktop.appNotFound", 404);
    const a = (await apps("en")).find((x) => x.id === id);
    if (!a) throw new AppError("agent.desktop.appNotFound", 404);
    return a;
  };

  async function hyprJson(env: NodeJS.ProcessEnv, what: string): Promise<unknown> {
    const r = await io.exec("hyprctl", ["-j", what], { env, timeoutMs: 5000, allowFail: true });
    try {
      return JSON.parse(r.stdout);
    } catch {
      throw new AppError("agent.desktop.hyprctlFailed", 502, { output: (r.stdout || r.stderr).slice(0, 300) });
    }
  }

  const dispatch = (cmds: HyprCmd[]) => hyprctl.dispatch(cmds);

  ctx.focusClass = async (cls) => {
    const w = parseClients(await hyprJson(await io.hyprEnv(), "clients")).find((c) => c.class === cls);
    if (w) await dispatch([{ op: "focusWindow", address: w.address }]);
    return !!w;
  };

  const clientsOf = async (env: NodeJS.ProcessEnv) => {
    const [c, m] = await Promise.all([hyprJson(env, "clients"), hyprJson(env, "monitors")]);
    return { clients: parseClients(c), monitors: parseMonitors(m) };
  };
  const addressOf = (raw: string) => {
    if (!ADDRESS.test(raw)) throw new AppError("agent.desktop.badAddress", 400);
    return raw;
  };
  const windowOf = async (address: string) => {
    const env = await io.hyprEnv();
    const s = await clientsOf(env);
    const w = s.clients.find((c) => c.address === address);
    if (!w) throw new AppError("agent.desktop.windowNotFound", 404);
    return { ...s, w };
  };

  // ---- salt okunur ----

  app.get("/v1/desktop/windows", async () => {
    const env = await io.hyprEnv();
    const [c, a, w, m, list] = await Promise.all([hyprJson(env, "clients"), hyprJson(env, "activewindow"), hyprJson(env, "workspaces"), hyprJson(env, "monitors"), apps("en").catch(() => [])]);
    return desktopState(parseClients(c), a, parseWorkspaces(w), parseMonitors(m), list);
  });

  const thumbs = new Map<string, { at: number; type: string; body: Buffer }>();
  const thumbMs = opts.thumbCacheMs ?? 2000;
  app.get("/v1/desktop/windows/:address/thumb", async (req, reply) => {
    const address = addressOf((req.params as { address: string }).address);
    const { w: width } = z.object({ w: z.coerce.number().int().min(64).max(800).default(320) }).parse(req.query);
    const key = `${address}:${width}`;
    for (const [k, v] of thumbs) if (now() - v.at >= thumbMs) thumbs.delete(k);
    let hit = thumbs.get(key);
    if (!hit) {
      const { w, monitors } = await windowOf(address);
      if (!isVisible(w, monitors)) throw new AppError("agent.desktop.windowNotVisible", 409);
      const scale = Math.min(1, width / w.size[0]);
      const geom = `${w.at[0]},${w.at[1]} ${w.size[0]}x${w.size[1]}`;
      const shot = await io.bytes("grim", ["-g", geom, "-s", scale.toFixed(4), "-t", "png", "-l", "0", "-"], { env: await io.screenEnv(), timeoutMs: 10000 });
      if (shot.code !== 0 || !isPng(shot.out)) throw new AppError("agent.desktop.thumbFailed", 502, { stderr: shot.err.slice(0, 300) });
      let body = shot.out;
      let type = "image/png";
      if (await io.has("ffmpeg")) {
        const webp = await io
          .bytes("ffmpeg", ["-v", "error", "-f", "png_pipe", "-i", "-", "-c:v", "libwebp", "-quality", "70", "-f", "webp", "-"], { env: process.env, input: shot.out, timeoutMs: 10000 })
          .catch(() => null);
        if (webp && webp.code === 0 && isWebp(webp.out)) {
          body = webp.out;
          type = "image/webp";
        }
      }
      hit = { at: now(), type, body };
      thumbs.set(key, hit);
    }
    return reply.header("content-type", hit.type).header("cache-control", "no-store").send(hit.body);
  });

  app.get("/v1/desktop/apps", async (req) => {
    const { lang } = z.object({ lang: z.enum(["tr", "en"]).default("tr") }).parse(req.query);
    const list = await apps(lang);
    return {
      apps: list.map((a) => ({ id: a.id, name: a.name, genericName: a.genericName, comment: a.comment, categories: a.categories, keywords: a.keywords, hasIcon: a.icon !== null })),
    };
  });

  const iconCache = new Map<string, { type: string; body: Buffer }>();
  app.get("/v1/desktop/apps/:id/icon", async (req, reply) => {
    const a = await findApp((req.params as { id: string }).id);
    const { size } = z.object({ size: z.coerce.number().int().min(48).max(256).default(128) }).parse(req.query);
    const key = `${a.id}:${size}`;
    let hit = iconCache.get(key);
    if (!hit) {
      const path = a.icon ? await icons.resolve(a.icon) : null;
      if (!path) throw new AppError("agent.desktop.iconNotFound", 404);
      hit = await iconImage(io, path, size);
      if (iconCache.size > 400) iconCache.clear();
      iconCache.set(key, hit);
    }
    return reply.header("content-type", hit.type).header("cache-control", "private, max-age=86400").send(hit.body);
  });

  // ---- mutating (control + session) ----

  app.post("/v1/desktop/windows/:address/:action", async (req) => {
    const p = req.params as { address: string; action: string };
    const address = addressOf(p.address);
    const action = z.enum(WINDOW_ACTIONS).parse(p.action);
    await guard(req);
    const body = z.object({ workspace: workspaceNumber.optional() }).parse(req.body ?? {});
    if (action === "move-to-workspace" && body.workspace === undefined) throw new AppError("agent.request.invalid", 400, { field: "workspace" });
    const { w } = await windowOf(address);
    await dispatch(dispatchFor(action, w, body.workspace));
    thumbs.clear();
    return { ok: true };
  });

  app.post("/v1/desktop/workspace/:n", async (req) => {
    const n = workspaceNumber.parse((req.params as { n: string }).n);
    await guard(req);
    await dispatch([{ op: "workspace", workspace: n }]);
    thumbs.clear();
    return { ok: true };
  });

  app.post("/v1/desktop/dpms/:state", async (req) => {
    const state = z.enum(["on", "off"]).parse((req.params as { state: string }).state);
    await guard(req);
    await dispatch([{ op: "dpms", on: state === "on" }]);
    return { ok: true };
  });

  app.post("/v1/desktop/apps/:id/launch", async (req) => {
    const a = await findApp((req.params as { id: string }).id);
    await guard(req);
    if (!(await io.has("gtk-launch"))) throw new AppError("agent.exec.commandMissing", 500, { command: "gtk-launch" });
    // The app is launched as a child of Hyprland (with the right environment); the id is in the list and matches
    // LAUNCH_ID (written escaped as a Lua string; rare ids containing characters like `+` can't be launched).
    if (!LAUNCH_ID.test(a.id)) throw new AppError("agent.desktop.appNotFound", 404);
    await dispatch([{ op: "launch", appId: a.id }]);
    return { ok: true };
  });
}
