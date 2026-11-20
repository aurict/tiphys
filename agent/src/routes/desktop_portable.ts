// Desktop routes over the native helper (desktop.backend "helper"; desktops other than Hyprland: Sway, X11, GNOME/KDE
// through the portal, Windows, macOS). The same HTTP API as the Hyprland routes (hypr.ts, desktop.ts, stream.ts), so
// the phone needs no second code path:
// - Panel: GET /v1/desktop/windows (same shape as desktopState; `hyprland: false`, `backend: "helper"`), window
//   thumbnail, apps (+ icon: the helper's .desktop icon name, resolved in the icon theme as on Hyprland), and the
//   mutating window actions, workspace, DPMS, app launch.
// - Screenshot, clipboard (only when the Wayland tools aren't usable; server.ts decides), live screen WS (the helper's
//   `stream` mode through stream.ts' LiveStream: same splitter, dedupe, backpressure, quality; MJPEG only).
// - GET /v1/desktop/capabilities: what the helper can do on this platform; a missing capability answers
//   agent.desktop.unsupported (501). AT-SPI mobile view and Sunshine stay Hyprland-only (501 here).
// Security as on Hyprland: every mutating call needs the "control" feature + a valid control session + the rate limit
// (requireControl); ids are validated (window ids ^0x[0-9a-f]{1,16}$, workspaces 1–100, apps only from the helper's
// list); nothing typed, no clipboard text and no titles are logged. The control session has no visible sign on the PC
// here (Hyprland's border indicator doesn't exist): the phone's "Control on" bar is the sign.
// Helper workspaces are strings; the API keeps Hyprland's numbers: numeric names keep their number, the others get the
// next free one in the helper's order (stable as long as the workspace list is).
import { spawn } from "node:child_process";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { ControlSessions, RateLimit, controlRoutes, requireControl, type Indicator } from "../control.ts";
import { capabilitiesRoute } from "../desktop_backend.ts";
import { keyArgs, mapPoint, textPieces, type InputEvent, type Mod, type StreamTarget } from "../desktop_input.ts";
import type { HelperClient } from "../desktop_helper.ts";
import { AppError } from "../errors.ts";
import { ADDRESS } from "../hyprctl.ts";
import type { Ctx } from "../server.ts";
import { IconResolver, defaultIconPaths } from "../desktop_apps.ts";
import { run } from "../exec.ts";
import { WINDOW_ACTIONS, defaultThemes, iconImage, realHyprIo } from "./hypr.ts";
import { LiveStream, MJPEG_MAX_FPS, realStreamIo, screenRoute, type StreamIo, type StreamOpts } from "./stream.ts";

/** Capabilities the API knows (the helper's other ones, e.g. audio, aren't used by these routes). */
export const PORTABLE_CAPABILITIES = ["windows", "windowActions", "workspaces", "monitors", "screenshot", "stream", "input", "text", "apps", "launch", "dpms", "clipboard"] as const;

export const PORTABLE_ACTIONS = [...WINDOW_ACTIONS, "minimize", "maximize"] as const;
const workspaceNumber = z.coerce.number().int().min(1).max(100);
/** Helper app ids (Linux .desktop ids, Windows AppUserModelIDs, macOS bundle paths): printable, at most 300. */
const appIdSchema = z.string().min(1).max(300).regex(/^[^\u0000-\u001f\u007f]+$/);

/** No visible sign on the PC (only Hyprland has the border indicator); the phone shows the "Control on" bar. */
export const noIndicator: Indicator = { on: async () => {}, off: async () => {} };

// ---- helper JSON ----

export interface HelperWindow {
  id: string;
  title: string;
  appId: string;
  pid: number | null;
  workspace: string | null;
  monitor: string;
  x: number;
  y: number;
  w: number;
  h: number;
  focused: boolean;
  minimized: boolean;
  fullscreen: boolean;
  floating: boolean;
}

export interface HelperWorkspace {
  id: string;
  name: string;
  focused: boolean;
  monitor: string;
}

export interface HelperMonitor {
  id: string;
  name: string;
  x: number;
  y: number;
  w: number;
  h: number;
  scale: number;
  primary: boolean;
}

export interface HelperApp {
  id: string;
  name: string;
  /** Icon name or absolute path (Linux .desktop `Icon=`); null if none. */
  icon: string | null;
}

type J = Record<string, unknown>;
const num = (v: unknown, d = 0) => (typeof v === "number" && Number.isFinite(v) ? v : d);
const str = (v: unknown) => (typeof v === "string" ? v : typeof v === "number" ? String(v) : "");
const arr = (v: unknown): J[] => (Array.isArray(v) ? v.filter((x): x is J => !!x && typeof x === "object") : []);

export function parseHelperWindows(v: unknown): HelperWindow[] {
  return arr(v)
    .filter((w) => ADDRESS.test(str(w.id)))
    .map((w) => ({
      id: str(w.id),
      title: str(w.title),
      appId: str(w.appId),
      pid: typeof w.pid === "number" && w.pid > 0 ? w.pid : null,
      workspace: w.workspace === null || w.workspace === undefined ? null : str(w.workspace),
      monitor: str(w.monitor),
      x: num(w.x),
      y: num(w.y),
      w: num(w.w),
      h: num(w.h),
      focused: w.focused === true,
      minimized: w.minimized === true,
      fullscreen: w.fullscreen === true,
      floating: w.floating === true,
    }));
}

export function parseHelperWorkspaces(v: unknown): HelperWorkspace[] {
  return arr(v)
    .filter((w) => str(w.id))
    .map((w) => ({ id: str(w.id), name: str(w.name) || str(w.id), focused: w.focused === true, monitor: str(w.monitor) }));
}

export function parseHelperMonitors(v: unknown): HelperMonitor[] {
  return arr(v).map((m) => ({ id: str(m.id), name: str(m.name) || str(m.id), x: num(m.x), y: num(m.y), w: num(m.w), h: num(m.h), scale: num(m.scale, 1) || 1, primary: m.primary === true }));
}

export function parseHelperApps(v: unknown): HelperApp[] {
  return arr(v)
    .filter((a) => appIdSchema.safeParse(a.id).success)
    .map((a) => ({ id: str(a.id), name: str(a.name) || str(a.id), icon: typeof a.icon === "string" && a.icon ? a.icon : null }));
}

/** Helper workspace id → API number (1–100): numeric names keep their number, the rest get the next free one. */
export function workspaceNumbers(list: HelperWorkspace[]): Map<string, number> {
  const out = new Map<string, number>();
  const used = new Set<number>();
  for (const w of list) {
    const n = /^\d{1,3}$/.test(w.name) ? Number(w.name) : /^\d{1,3}$/.test(w.id) ? Number(w.id) : NaN;
    if (n >= 1 && n <= 100 && !used.has(n)) {
      out.set(w.id, n);
      used.add(n);
    }
  }
  let next = 1;
  for (const w of list) {
    if (out.has(w.id)) continue;
    while (used.has(next)) next++;
    if (next > 100) break;
    out.set(w.id, next);
    used.add(next);
  }
  return out;
}

const appFor = (apps: HelperApp[], appId: string) => {
  const a = appId.toLowerCase().replace(/\.desktop$/, "");
  return a ? (apps.find((x) => x.id.toLowerCase().replace(/\.desktop$/, "") === a) ?? null) : null;
};

/** Panel state in the Hyprland shape (desktopState in hypr.ts). */
export function portableState(windows: HelperWindow[], workspaces: HelperWorkspace[], monitors: HelperMonitor[], apps: HelperApp[]) {
  const nums = workspaceNumbers(workspaces);
  const wsNum = (id: string | null) => (id === null ? 0 : (nums.get(id) ?? 0));
  const shown = new Set(workspaces.filter((w) => w.focused).map((w) => w.id));
  const focusedWs = workspaces.find((w) => w.focused) ?? null;
  const focusedWindow = windows.find((w) => w.focused);
  const focusedMonitor = monitors.find((m) => m.name === focusedWs?.monitor || m.id === focusedWs?.monitor) ?? monitors.find((m) => m.name === focusedWindow?.monitor || m.id === focusedWindow?.monitor) ?? monitors.find((m) => m.primary) ?? monitors[0];
  const visible = (w: HelperWindow) => !w.minimized && w.w > 0 && w.h > 0 && (w.workspace === null || shown.has(w.workspace));
  return {
    hyprland: false,
    backend: "helper",
    activeWorkspace: focusedWs ? (nums.get(focusedWs.id) ?? null) : null,
    monitors: monitors.map((m, i) => {
      const ws = workspaces.find((w) => w.focused && (w.monitor === m.name || w.monitor === m.id));
      return { id: i, name: m.name, width: Math.round(m.w * m.scale), height: Math.round(m.h * m.scale), x: m.x, y: m.y, scale: m.scale, focused: m === focusedMonitor, activeWorkspace: ws ? (nums.get(ws.id) ?? 0) : 0, dpms: true };
    }),
    workspaces: workspaces
      .filter((w) => nums.has(w.id))
      .map((w) => ({ id: nums.get(w.id)!, name: w.name, monitor: w.monitor, windows: windows.filter((x) => x.workspace === w.id).length, visible: shown.has(w.id), focused: w.focused }))
      .sort((a, b) => a.id - b.id),
    windows: windows
      .map((w, i) => ({ w, i }))
      .sort((a, b) => wsNum(a.w.workspace) - wsNum(b.w.workspace) || a.i - b.i) // helper order: most recently focused first
      .map(({ w }) => ({
        address: w.id,
        class: w.appId,
        title: w.title,
        workspace: { id: wsNum(w.workspace), name: w.workspace === null ? "" : (workspaces.find((x) => x.id === w.workspace)?.name ?? w.workspace) },
        at: [w.x, w.y],
        size: [w.w, w.h],
        floating: w.floating,
        fullscreen: w.fullscreen,
        pinned: false,
        focused: w.focused,
        visible: visible(w),
        appId: appFor(apps, w.appId)?.id ?? null,
      })),
  };
}

// ---- input ----

const KEY_NAMES: Record<string, string> = {
  Esc: "escape", Tab: "tab", Enter: "enter", Backspace: "backspace", Delete: "delete", Insert: "insert", Space: "space",
  Up: "up", Down: "down", Left: "left", Right: "right", Home: "home", End: "end", PageUp: "pageup", PageDown: "pagedown",
  Super: "super", PrintScreen: "printscreen",
};

/** API key + modifiers (validated by keyArgs, same rules as on Hyprland) → helper `keys` (modifiers first). */
export function helperKeys(key: string, mods: Mod[] = []): string[] {
  keyArgs(key, mods);
  const name = KEY_NAMES[key] ?? (/^(F([1-9]|1[0-2])|[A-Z0-9])$/.test(key) ? key.toLowerCase() : null);
  if (!name) throw new AppError("agent.desktop.badKey", 400); // KPPlus/KPMinus: not in the helper's key table
  return [...new Set<string>(mods), name];
}

/** One input event through the helper (live screen); [map]: image point → global logical coordinate. */
export async function runHelperInput(client: HelperClient, e: InputEvent, map: (x: number, y: number, w?: number, h?: number) => [number, number]): Promise<void> {
  if (e.type === "wait") return new Promise<void>((r) => setTimeout(r, e.ms));
  await client.require(e.type === "text" ? "text" : "input");
  switch (e.type) {
    case "move": {
      const [x, y] = map(e.x, e.y, e.w, e.h);
      await client.request("pointer", { x, y });
      return;
    }
    case "click": {
      const at = e.x !== undefined && e.y !== undefined ? map(e.x, e.y, e.w, e.h) : null;
      const pos = at ? { x: at[0], y: at[1] } : {};
      await client.request("click", { button: e.button, ...pos, double: e.count >= 2 });
      if (e.count === 3) await client.request("click", { button: e.button });
      return;
    }
    case "down":
    case "up":
      await client.request("button", { button: e.button, down: e.type === "down" });
      return;
    case "scroll":
      if (!e.dx && !e.dy) return;
      await client.request("scroll", { dx: e.dx, dy: e.dy });
      return;
    case "key":
      await client.request("key", { keys: helperKeys(e.key, e.mods) });
      return;
    case "text":
      for (const p of textPieces(e.text)) {
        if ("key" in p) await client.request("key", { keys: helperKeys(p.key) });
        else await client.request("text", { text: p.text });
      }
      return;
  }
}

/** Monitor or window target for `tiphys-desktop stream` (args: --monitor ID [--region x,y,w,h], global logical). */
export function helperTarget(monitors: HelperMonitor[], sel: { monitor?: string; window?: HelperWindow }): StreamTarget {
  if (sel.window) {
    const w = sel.window;
    const m = monitors.find((x) => x.name === w.monitor || x.id === w.monitor) ?? monitors.find((x) => x.primary) ?? monitors[0];
    if (!m) throw new AppError("agent.desktop.noDisplay", 503);
    const x0 = Math.max(w.x, m.x);
    const y0 = Math.max(w.y, m.y);
    const x1 = Math.min(w.x + w.w, m.x + m.w);
    const y1 = Math.min(w.y + w.h, m.y + m.h);
    if (x1 - x0 < 2 || y1 - y0 < 2) throw new AppError("agent.desktop.windowNotVisible", 409);
    const region = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    return { region, pixels: { w: Math.round(region.w * m.scale), h: Math.round(region.h * m.scale) }, args: ["--monitor", m.id, "--region", `${x0},${y0},${region.w},${region.h}`], monitor: m.name };
  }
  const m = sel.monitor ? monitors.find((x) => x.name === sel.monitor) : (monitors.find((x) => x.primary) ?? monitors[0]);
  if (!m) throw new AppError(sel.monitor ? "agent.desktop.monitorNotFound" : "agent.desktop.noDisplay", sel.monitor ? 404 : 503);
  const region = { x: m.x, y: m.y, w: m.w, h: m.h };
  return { region, pixels: { w: Math.round(m.w * m.scale), h: Math.round(m.h * m.scale) }, args: ["--monitor", m.id], monitor: m.name };
}

/** The helper's stream mode reads stdin (it exits when stdin closes, e.g. the agent died): piped, unlike wf-recorder. */
const helperStreamIo: StreamIo = { ...realStreamIo, spawn: (cmd, args, env) => spawn(cmd, args, { env, stdio: ["pipe", "pipe", "pipe"] }) };

const isPng = (b: Buffer) => b.length > 8 && b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
const isJpeg = (b: Buffer) => b.length > 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff;

/** Decodes a helper `screenshot` answer; content type from the bytes, not the claim. */
function image(r: unknown, failCode: string): { type: string; body: Buffer } {
  const body = Buffer.from(str((r as J | null)?.data), "base64");
  if (isPng(body)) return { type: "image/png", body };
  if (isJpeg(body)) return { type: "image/jpeg", body };
  throw new AppError(failCode, 502);
}

export interface PortableOpts {
  client: HelperClient;
  /** "wayland": clipboard routes are wl-paste/wl-copy (registered by server.ts); "helper": through the helper. */
  clipboard: "wayland" | "helper";
  now?: () => number;
  /** Mutating panel calls (per session). */
  panelLimit?: RateLimit;
  thumbCacheMs?: number;
  stream?: StreamOpts;
  /** Live screen process spawner (default: the real one, stdin piped). */
  streamIo?: StreamIo;
  icons?: IconResolver;
}

export function portableRoutes(app: FastifyInstance, ctx: Ctx, opts: PortableOpts) {
  const { client } = opts;
  const now = opts.now ?? Date.now;
  const log = (msg: string, err?: unknown) => app.log.warn({ err }, msg);
  const control = new ControlSessions({ indicator: noIndicator, events: ctx.notifier.events, now, log });
  ctx.control = control;
  app.addHook("onClose", async () => {
    await control.end("shutdown");
  });
  controlRoutes(app, ctx, control);
  // Same limits as the Hyprland panel: at most 10 mutating calls per 5 s.
  const panelLimit = opts.panelLimit ?? new RateLimit(10, 5000, now);
  const guard = (req: FastifyRequest) => requireControl(ctx, control, req, panelLimit);

  const appCache = new Map<string, { at: number; apps: Promise<HelperApp[]> }>();
  const apps = (lang: string) => {
    const c = appCache.get(lang);
    if (c && now() - c.at < 60_000) return c.apps;
    const p = client.require("apps").then(() => client.request("apps", { lang }, { timeoutMs: 20_000 })).then(parseHelperApps);
    appCache.set(lang, { at: now(), apps: p });
    p.catch(() => appCache.delete(lang));
    return p;
  };
  const findApp = async (raw: string) => {
    if (!appIdSchema.safeParse(raw).success) throw new AppError("agent.desktop.appNotFound", 404);
    const a = (await apps("en")).find((x) => x.id === raw);
    if (!a) throw new AppError("agent.desktop.appNotFound", 404);
    return a;
  };
  const caps = async () => (await client.hello()).capabilities;
  const windows = async () => {
    await client.require("windows");
    return parseHelperWindows(await client.request("windows"));
  };
  const workspaces = async (has: string[]) => (has.includes("workspaces") ? parseHelperWorkspaces(await client.request("workspaces")) : []);
  const monitors = async (has: string[]) => (has.includes("monitors") ? parseHelperMonitors(await client.request("monitors")) : []);
  const addressOf = (raw: string) => {
    if (!ADDRESS.test(raw)) throw new AppError("agent.desktop.badAddress", 400);
    return raw;
  };
  const windowOf = async (address: string) => {
    const w = (await windows()).find((x) => x.id === address);
    if (!w) throw new AppError("agent.desktop.windowNotFound", 404);
    return w;
  };

  ctx.focusClass = async (cls) => {
    const w = (await windows()).find((x) => x.appId === cls);
    if (w) await client.request("window", { window: w.id, action: "focus" });
    return !!w;
  };

  capabilitiesRoute(app, async () => {
    const extra: string[] = opts.clipboard === "wayland" ? ["clipboard", "clipboardSync"] : [];
    try {
      const h = await client.hello();
      const list: string[] = PORTABLE_CAPABILITIES.filter((c) => h.capabilities.includes(c) && !(c === "clipboard" && opts.clipboard === "wayland"));
      if (list.includes("windows") && list.includes("screenshot")) list.push("thumbnails");
      return { backend: "helper", platform: h.backend, version: h.version, capabilities: [...list, ...extra] };
    } catch (e) {
      if (!(e instanceof AppError)) throw e;
      return { backend: "helper", platform: null, version: null, capabilities: extra, error: e.code };
    }
  });

  // ---- read-only ----

  app.get("/v1/desktop/windows", async () => {
    const has = await caps();
    const [w, ws, ms, list] = await Promise.all([windows(), workspaces(has), monitors(has), has.includes("apps") ? apps("en").catch(() => []) : Promise.resolve([])]);
    return portableState(w, ws, ms, list);
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
      await client.require("screenshot");
      const w = await windowOf(address);
      if (w.minimized || w.w <= 0 || w.h <= 0) throw new AppError("agent.desktop.windowNotVisible", 409);
      const r = await client.request("screenshot", { window: address, maxWidth: width, format: "jpeg", quality: 70 }, { timeoutMs: 15_000 });
      hit = { at: now(), ...image(r, "agent.desktop.thumbFailed") };
      thumbs.set(key, hit);
    }
    return reply.header("content-type", hit.type).header("cache-control", "no-store").send(hit.body);
  });

  app.get("/v1/desktop/apps", async (req) => {
    const { lang } = z.object({ lang: z.enum(["tr", "en"]).default("tr") }).parse(req.query);
    const list = await apps(lang);
    return { apps: list.map((a) => ({ id: a.id, name: a.name, genericName: null, comment: null, categories: [], keywords: [], hasIcon: a.icon !== null })) };
  });

  // Linux: the .desktop icon name, resolved in the icon theme like on Hyprland. Windows/macOS give none (yet).
  const icons = opts.icons ?? new IconResolver(defaultIconPaths(), () => defaultThemes(run));
  const iconCache = new Map<string, { type: string; body: Buffer }>();
  app.get("/v1/desktop/apps/:id/icon", async (req, reply) => {
    const a = await findApp((req.params as { id: string }).id);
    const { size } = z.object({ size: z.coerce.number().int().min(48).max(256).default(128) }).parse(req.query);
    const key = `${a.id}:${size}`;
    let hit = iconCache.get(key);
    if (!hit) {
      const path = a.icon ? await icons.resolve(a.icon) : null;
      if (!path) throw new AppError("agent.desktop.iconNotFound", 404);
      hit = await iconImage(realHyprIo, path, size);
      if (iconCache.size > 400) iconCache.clear();
      iconCache.set(key, hit);
    }
    return reply.header("content-type", hit.type).header("cache-control", "private, max-age=86400").send(hit.body);
  });

  app.get("/v1/desktop/screenshot", async (req, reply) => {
    const q = z.object({ scale: z.coerce.number().min(0.1).max(1).default(0.5) }).parse(req.query);
    const has = (await client.require("screenshot")).capabilities;
    // The helper takes a width: the desktop's physical width × scale (1920 if the monitors are unknown).
    const ms = await monitors(has);
    const left = Math.min(...ms.map((m) => m.x));
    const right = Math.max(...ms.map((m) => m.x + m.w));
    const physical = ms.length ? (right - left) * Math.max(...ms.map((m) => m.scale)) : 1920;
    const maxWidth = Math.min(3840, Math.max(64, Math.round(physical * q.scale)));
    const r = await client.request("screenshot", { maxWidth, format: "png" }, { timeoutMs: 20_000 });
    const shot = image(r, "agent.desktop.screenshotFailed");
    return reply.header("content-type", shot.type).header("cache-control", "no-store").send(shot.body);
  });

  if (opts.clipboard === "helper") {
    // PRIVACY: the text is never logged; only method and path reach the audit log. No sync (the helper has no
    // clipboard events): GET/PUT only.
    app.get("/v1/desktop/clipboard", async () => {
      await client.require("clipboard");
      const r = (await client.request("clipboard-get")) as J | null;
      return { text: typeof r?.text === "string" ? r.text.slice(0, 1_000_000) : "" };
    });
    app.put("/v1/desktop/clipboard", async (req) => {
      const { text } = z.object({ text: z.string().max(1_000_000) }).parse(req.body);
      await client.require("clipboard");
      await client.request("clipboard-set", { text });
      return { ok: true };
    });
  }

  // ---- mutating (control + session) ----

  app.post("/v1/desktop/windows/:address/:action", async (req) => {
    const p = req.params as { address: string; action: string };
    const address = addressOf(p.address);
    const action = z.enum(PORTABLE_ACTIONS).parse(p.action);
    await guard(req);
    const body = z.object({ workspace: workspaceNumber.optional() }).parse(req.body ?? {});
    if (action === "move-to-workspace" && body.workspace === undefined) throw new AppError("agent.request.invalid", 400, { field: "workspace" });
    if (action === "pin") throw new AppError("agent.desktop.unsupported", 501, { action });
    const has = (await client.require(action === "move-to-workspace" ? "workspaces" : "windowActions")).capabilities;
    await windowOf(address);
    if (action === "move-to-workspace") {
      const id = [...workspaceNumbers(await workspaces(has))].find(([, n]) => n === body.workspace)?.[0] ?? String(body.workspace);
      await client.request("move-to-workspace", { window: address, workspace: id });
    } else {
      await client.request("window", { window: address, action });
    }
    thumbs.clear();
    return { ok: true };
  });

  app.post("/v1/desktop/workspace/:n", async (req) => {
    const n = workspaceNumber.parse((req.params as { n: string }).n);
    await guard(req);
    const has = (await client.require("workspaces")).capabilities;
    // A number without a workspace goes as its name (Sway/X11 create or reject it).
    const id = [...workspaceNumbers(await workspaces(has))].find(([, x]) => x === n)?.[0] ?? String(n);
    await client.request("workspace", { workspace: id });
    thumbs.clear();
    return { ok: true };
  });

  app.post("/v1/desktop/dpms/:state", async (req) => {
    const state = z.enum(["on", "off"]).parse((req.params as { state: string }).state);
    await guard(req);
    await client.require("dpms");
    await client.request("dpms", { on: state === "on" });
    return { ok: true };
  });

  app.post("/v1/desktop/apps/:id/launch", async (req) => {
    const a = await findApp((req.params as { id: string }).id);
    await guard(req);
    await client.require("launch");
    await client.request("launch", { app: a.id }, { notFound: "agent.desktop.appNotFound", timeoutMs: 20_000 });
    return { ok: true };
  });

  // ---- live screen ----

  screenRoute(app, ctx, control, opts.stream ?? {}, {
    async open(q, socket, streamOpts, slog) {
      if (!client.command) throw new AppError("agent.desktop.helperMissing", 500);
      const has = (await client.require("stream")).capabilities;
      const ms = await monitors(has);
      let window: HelperWindow | undefined;
      if (q.window) {
        window = await windowOf(q.window);
        if (window.minimized) throw new AppError("agent.desktop.windowNotVisible", 409);
      }
      const target = helperTarget(ms, { monitor: q.monitor, window });
      const params = { fps: Math.min(q.fps, MJPEG_MAX_FPS), scale: q.scale, q: q.q, codec: "mjpeg" as const, kbps: q.kbps };
      return new LiveStream(socket, opts.streamIo ?? helperStreamIo, target, params, streamOpts, slog, client.command);
    },
    cursorIn: async () => null, // the helper doesn't report the cursor
    runInput: (stream, e) => runHelperInput(client, e, (x, y, w, h) => mapPoint(x, y, w && h ? { w, h } : stream.out, stream.target.region)),
    subscribeFocus(fn) {
      // The live screen keeps the helper running (input goes through it); focus events if it lists windows.
      const release = client.hold();
      const off = client.lastHello?.capabilities.includes("windows")
        ? client.subscribe("focus", (ev) => {
            const w = parseHelperWindows([(ev as J).window])[0];
            const cached = appCache.get("en");
            void (cached ? cached.apps.catch(() => []) : Promise.resolve([] as HelperApp[])).then((list) =>
              fn({
                address: w?.id ?? null,
                class: w?.appId ?? "",
                initialClass: w?.appId ?? "",
                title: (w?.title ?? "").slice(0, 200),
                pid: w?.pid ?? null,
                workspace: w?.workspace && /^\d{1,3}$/.test(w.workspace) ? Number(w.workspace) : null,
                appId: w ? (appFor(list, w.appId)?.id ?? null) : null,
              }),
            );
          })
        : () => {};
      return () => {
        off();
        release();
      };
    },
    stop: () => client.stop(), // after the streams closed (their held buttons are released through it)
  });

  // ---- Hyprland-only features: 501 here (the app hides them via /v1/desktop/capabilities) ----

  const unsupported = async () => {
    throw new AppError("agent.desktop.unsupported", 501);
  };
  for (const url of ["/v1/desktop/sunshine", "/v1/desktop/sunshine/*", "/v1/desktop/ui", "/v1/desktop/ui/*"]) app.all(url, unsupported);
}
