import websocket from "@fastify/websocket";
import Fastify, { type FastifyInstance } from "fastify";
import { ZodError } from "zod";
import { authenticate } from "./auth.ts";
import type { ConfigStore, Device } from "./config.ts";
import { AppError } from "./errors.ts";
import { Notifier } from "./notify.ts";
import { configRoutes } from "./routes/config.ts";
import { dockerRoutes } from "./routes/docker.ts";
import { homepageRoutes } from "./routes/homepage.ts";
import { powerRoutes } from "./routes/power.ts";
import { serviceRoutes } from "./routes/services.ts";
import { systemRoutes } from "./routes/system.ts";
import { wakeRoutes } from "./routes/wake.ts";
import { auditRoutes } from "./audit.ts";
import { EventLog, eventRoutes, eventsPath } from "./events.ts";
import { agentStatusRoutes, type RunLog } from "./runs.ts";
import { desktopRoutes, openRoutes } from "./routes/desktop.ts";
import { browserOpener, browserRoutes } from "./routes/browser.ts";
import type { BrowserBridge } from "./browser_bridge.ts";
import { mediaRoutes } from "./routes/media.ts";
import { hyprRoutes } from "./routes/hypr.ts";
import { streamRoutes } from "./routes/stream.ts";
import { sunshineRoutes } from "./routes/sunshine.ts";
import { atspiRoutes, type UiService } from "./atspi.ts";
import type { ControlSessions } from "./control.ts";
import type { Hyprctl } from "./hyprctl.ts";
import type { DesktopApp } from "./desktop_apps.ts";
import { gitRoutes } from "./routes/git.ts";
import { portRoutes } from "./routes/ports.ts";
import { processRoutes } from "./routes/processes.ts";
import { transcribeRoutes } from "./routes/transcribe.ts";

export { VERSION } from "./version.ts";
import { VERSION } from "./version.ts";

export interface Ctx {
  store: ConfigStore;
  notifier: Notifier;
  /** Optional extra modules (Claude, Uptime Kuma) register without depending on server.ts. */
  extraRoutes?: Array<(app: FastifyInstance, ctx: Ctx) => void | Promise<void>>;
  /** Run records (unexpected restarts); without it the status endpoint only gives live info. */
  runs?: RunLog;
  /** Remote control sessions (while "desktop" is on; the live screen and Claude tools use it too). */
  control?: ControlSessions;
  /** Hyprland command adapter (shared classic/Lua mode detection; set up by hyprRoutes). */
  hyprctl?: Hyprctl;
  /** Launchable .desktop apps (set up by hyprRoutes; Claude's launch_app tool only opens these). */
  desktopApps?: () => Promise<DesktopApp[]>;
  /** Firefox bridge socket (11.2; set up by `serve`, a fake socket is supplied in tests). */
  browser?: BrowserBridge;
  /** Mobile view sessions (11.4; set up by atspiRoutes, also used by Claude's ui_* tools). */
  ui?: UiService;
}

declare module "fastify" {
  interface FastifyRequest {
    device?: Device;
  }
}

export async function buildApp(ctx: Ctx, opts: { logger?: boolean } = {}): Promise<FastifyInstance> {
  const app = Fastify({
    logger: opts.logger ? { level: "info", redact: ["req.headers.authorization"] } : false,
    bodyLimit: 32 * 1024 * 1024,
    trustProxy: "127.0.0.1",
  });

  await app.register(websocket, { options: { maxPayload: 1 << 20 } });

  app.setErrorHandler((err, req, reply) => {
    if (err instanceof AppError) {
      return reply.status(err.status).send({ error: { code: err.code, params: err.params } });
    }
    if (err instanceof ZodError) {
      return reply.status(400).send({
        error: { code: "agent.request.invalid", params: { issues: err.issues.map((i) => ({ path: i.path.join("."), message: i.message })) } },
      });
    }
    const status = (err as { statusCode?: number }).statusCode;
    if (status && status < 500) {
      return reply.status(status).send({ error: { code: "agent.request.invalid", params: { message: (err as Error).message } } });
    }
    req.log.error(err);
    return reply.status(500).send({ error: { code: "agent.internal", params: {} } });
  });

  app.setNotFoundHandler((req, reply) =>
    reply.status(404).send({ error: { code: "agent.route.notFound", params: { url: req.url.split("?")[0] } } }),
  );

  // Authentication: every request except /v1/health requires a device token.
  app.addHook("onRequest", async (req) => {
    if (req.url === "/v1/health" || req.url.startsWith("/v1/health?")) return;
    req.device = authenticate(ctx.store.get(), req);
  });

  app.get("/v1/health", async () => {
    const c = ctx.store.get();
    return { name: c.name, version: VERSION, features: c.features };
  });

  auditRoutes(app, ctx);
  // The event stream is always on (no feature flag); notifications are written here too.
  ctx.notifier.events ??= new EventLog(eventsPath(ctx.store.path));
  eventRoutes(app, ctx);
  agentStatusRoutes(ctx.runs ?? null)(app);
  configRoutes(app, ctx);
  const f = ctx.store.get().features;
  if (f.system) {
    systemRoutes(app, ctx);
    processRoutes(app, ctx);
  }
  if (f.git) gitRoutes(app, ctx);
  if (f.desktop) {
    desktopRoutes(app, ctx);
    openRoutes(app, browserOpener(ctx)); // "Open on PC": new tab if the extension is connected
    mediaRoutes(app, ctx);
    hyprRoutes(app, ctx);
    browserRoutes(app, ctx); // Firefox bridge (11.2): uses hyprRoutes' control session
    streamRoutes(app, ctx); // live screen (10.2): uses hyprRoutes' control session
    sunshineRoutes(app, ctx); // high quality (10.2 B): Sunshine status, start/stop, Moonlight pairing
    atspiRoutes(app, ctx); // mobile view (11.4): AT-SPI tree; uses hyprRoutes' control session
  }
  if (f.ports) portRoutes(app, ctx);
  if (f.transcribe) transcribeRoutes(app, ctx);
  if (f.services) serviceRoutes(app, ctx);
  if (f.docker) dockerRoutes(app, ctx);
  if (f.power) powerRoutes(app, ctx);
  if (f.homepage) homepageRoutes(app, ctx);
  if (f.wake) wakeRoutes(app, ctx);
  for (const register of ctx.extraRoutes ?? []) await register(app, ctx);

  return app;
}
