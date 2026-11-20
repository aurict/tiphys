// Firefox bridge endpoints (11.2, 11.3; "desktop" feature, every modifying/reading endpoint "control" + session token).
// - Status (`GET /v1/desktop/browser`: connected, version, permissions) needs pairing only; everything else, the tab
//   list included, needs a control session + rate limit (addresses are browsing history).
// - Switching to a tab also raises the Firefox window in Hyprland (hyprctl adapter; classic/Lua). If that fails
//   the tab is still active (focused:false).
// - Only method + path go to the audit log (action type, tab id); address, title and page text are not written.
// - "Open on PC" (9.9): tabs.create if the extension is connected, the old opener otherwise. If the extension doesn't
//   respond (timeout) there's no fallback to the old opener (the tab may have opened anyway → double open);
//   an error is reported.
// - SSE backpressure: if the client isn't reading (write buffer > 256 KB) intermediate tab lists are dropped, and once
//   drained only the latest is sent; if the buffer exceeds 2 MB the connection is cut.
import type { ServerResponse } from "node:http";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { RateLimit, requireControl, watchControl } from "../control.ts";
import { AppError } from "../errors.ts";
import { unsupportedRoutes } from "../platform/support.ts";
import type { Ctx } from "../server.ts";
import { OPEN_URL_MAX, checkOpenUrl, xdgOpen, type Opener } from "./desktop.ts";
import { parseClients } from "./hypr.ts";

export const TAB_ACTIONS = ["activate", "close", "reload", "back", "forward", "pin", "mute"] as const;
const tabId = z.coerce.number().int().min(0).max(2 ** 31 - 1);

/** Raises the Firefox window: the one whose title starts with the tab title, else the last focused Firefox window. */
export async function focusFirefox(ctx: Ctx, title: string | null): Promise<boolean> {
  const h = ctx.hyprctl;
  if (!h) return false;
  try {
    const env = await h.env();
    const r = await h.exec("hyprctl", ["-j", "clients"], { env, timeoutMs: 5000, allowFail: true });
    const wins = parseClients(JSON.parse(r.stdout)).filter((w) => /firefox/i.test(w.class));
    if (!wins.length) return false;
    const w = (title ? wins.find((x) => x.title.startsWith(title)) : undefined) ?? wins.sort((a, b) => a.focusHistoryId - b.focusHistoryId)[0]!;
    await h.dispatch([{ op: "focusWindow", address: w.address }]);
    return true;
  } catch {
    return false;
  }
}

/** "Open on PC" opener: a new tab if the extension is connected, else [fallback]. */
export function browserOpener(ctx: Ctx, fallback: Opener = xdgOpen): Opener {
  return async (url, env) => {
    if (ctx.browser?.connected) {
      try {
        await ctx.browser.request("tabs.create", { url });
        await focusFirefox(ctx, null);
        return;
      } catch (e) {
        // Only "not connected" (dropped meanwhile) falls back to the old path; timeout/extension errors are reported.
        if (!(e instanceof AppError && e.code === "agent.browser.notConnected")) throw e;
      }
    }
    return fallback(url, env);
  };
}

export interface BrowserOpts {
  /** Per session (default 20 per 5 s). */
  limit?: RateLimit;
  /** SSE keep-alive interval. */
  pingMs?: number;
  /** SSE: re-check interval for the control token (default 2 s). */
  recheckMs?: number;
}

export const SSE_SOFT_BYTES = 256 * 1024;
export const SSE_HARD_BYTES = 2 * 1024 * 1024;

/**
 * SSE writer (with backpressure): for [coalesce] events (tab list), once the buffer exceeds [soft] only the latest
 * snapshot is held and sent on "drain"; a client whose buffer exceeds [hard] is cut (destroy).
 */
export function sseWriter(raw: Pick<ServerResponse, "write" | "writableLength" | "once" | "destroy" | "destroyed">, soft = SSE_SOFT_BYTES, hard = SSE_HARD_BYTES) {
  let latest: { event: string; data: unknown } | null = null;
  const write = (chunk: string) => {
    if (raw.destroyed) return;
    raw.write(chunk);
    if (raw.writableLength > hard) raw.destroy();
  };
  const frame = (event: string, data: unknown) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
  const flush = () => {
    const l = latest;
    latest = null;
    if (l) send(l.event, l.data, true);
  };
  const send = (event: string, data: unknown, coalesce = false) => {
    if (coalesce && raw.writableLength > soft) {
      if (!latest) raw.once("drain", flush);
      latest = { event, data };
      return;
    }
    write(frame(event, data));
  };
  return { send, write };
}

export function browserRoutes(app: FastifyInstance, ctx: Ctx, opts: BrowserOpts = {}) {
  // The bridge is a Unix socket (Linux/macOS); `serve` doesn't open it on Windows.
  if (process.platform === "win32") return unsupportedRoutes(app, "/v1/desktop/browser", "desktop.firefoxBridge");
  const limit = opts.limit ?? new RateLimit(20, 5000);
  const guard = (req: FastifyRequest) => {
    if (!ctx.control) throw new AppError("agent.control.disabled", 403);
    return requireControl(ctx, ctx.control, req, limit);
  };
  const status = () => ctx.browser?.status ?? { connected: false, version: null, ext: null, permissions: { content: false } };
  const call = (op: string, args: Record<string, unknown> = {}) => {
    if (!ctx.browser?.connected) throw new AppError("agent.browser.notConnected", 503);
    return ctx.browser.request(op, args);
  };
  /** 11.3 endpoints: if the optional permission isn't granted in the extension, rejected without sending the request. */
  const page = (op: string, args: Record<string, unknown>) => {
    if (ctx.browser?.connected && !ctx.browser.status.permissions.content) throw new AppError("agent.browser.permissionRequired", 403);
    return call(op, args);
  };
  const idOf = (req: FastifyRequest) => tabId.parse((req.params as { id: string }).id);

  app.get("/v1/desktop/browser", async () => status());

  app.get("/v1/desktop/browser/tabs", async (req) => {
    await guard(req);
    return { tabs: await call("tabs.list") };
  });

  app.post("/v1/desktop/browser/tabs", async (req) => {
    await guard(req);
    const { url } = z.object({ url: z.string().min(1).max(OPEN_URL_MAX) }).parse(req.body);
    const href = checkOpenUrl(url.trim());
    if (!href) throw new AppError("agent.browser.badUrl", 400);
    const r = (await call("tabs.create", { url: href })) as { id?: unknown };
    return { ok: true, id: typeof r?.id === "number" ? r.id : null, focused: await focusFirefox(ctx, null) };
  });

  app.post("/v1/desktop/browser/tabs/close", async (req) => {
    await guard(req);
    const { ids } = z.object({ ids: z.array(tabId).min(1).max(200) }).parse(req.body);
    await call("tabs.close", { ids: [...new Set(ids)] });
    return { ok: true };
  });

  app.post("/v1/desktop/browser/tabs/:id/:action", async (req) => {
    await guard(req);
    const id = idOf(req);
    const action = z.enum(TAB_ACTIONS).parse((req.params as { action: string }).action);
    const r = (await call(`tabs.${action}`, { id })) as { title?: unknown } | null;
    if (action !== "activate") return { ok: true };
    return { ok: true, focused: await focusFirefox(ctx, typeof r?.title === "string" && r.title ? r.title : null) };
  });

  app.post("/v1/desktop/browser/restore", async (req) => {
    await guard(req);
    await call("sessions.restore");
    return { ok: true };
  });

  app.get("/v1/desktop/browser/tabs/:id/reader", async (req) => {
    await guard(req);
    return page("page.reader", { id: idOf(req) });
  });

  app.post("/v1/desktop/browser/tabs/:id/media", async (req) => {
    await guard(req);
    const id = idOf(req);
    const b = z
      .object({ action: z.enum(["play", "pause", "toggle", "seek", "rate"]), seconds: z.number().min(-86_400).max(86_400).optional(), rate: z.number().min(0.25).max(4).optional() })
      .parse(req.body);
    if (b.action === "seek" && b.seconds === undefined) throw new AppError("agent.request.invalid", 400, { field: "seconds" });
    if (b.action === "rate" && b.rate === undefined) throw new AppError("agent.request.invalid", 400, { field: "rate" });
    return page("page.media", { id, ...b });
  });

  app.post("/v1/desktop/browser/tabs/:id/scroll", async (req) => {
    await guard(req);
    const id = idOf(req);
    const { fraction } = z.object({ fraction: z.number().min(-10).max(10) }).parse(req.body);
    return page("page.scroll", { id, fraction });
  });

  app.post("/v1/desktop/browser/tabs/:id/text", async (req) => {
    await guard(req);
    const id = idOf(req);
    const { text } = z.object({ text: z.string().min(1).max(10_000) }).parse(req.body);
    return page("page.text", { id, text });
  });

  // SSE: `status` (connection/permission change) and `tabs` (merged tab list). Closes when the control session ends.
  const streams = new Set<() => void>();
  app.addHook("onClose", async () => {
    for (const end of [...streams]) end();
  });
  app.get("/v1/desktop/browser/events", async (req, reply) => {
    await guard(req);
    reply.hijack();
    const raw: ServerResponse = reply.raw;
    raw.writeHead(200, { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-store", "x-accel-buffering": "no" });
    const out = sseWriter(raw);
    out.send("status", status());
    const offEvents = ctx.browser?.onEvent((e) => (e.type === "tabs" ? out.send("tabs", { tabs: e.tabs }, true) : out.send("status", e.status)));
    // The stream closes if control ends, the token changes or "control" is turned off.
    const unwatch = watchControl(ctx, ctx.control!, req, () => end(), opts.recheckMs);
    const ping = setInterval(() => out.write(": ping\n\n"), opts.pingMs ?? 25_000);
    ping.unref?.();
    const end = () => {
      if (!streams.delete(end)) return;
      offEvents?.();
      unwatch();
      clearInterval(ping);
      raw.end();
    };
    streams.add(end);
    raw.on("close", end);
  });
}
