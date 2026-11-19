import websocket from "@fastify/websocket";
import Fastify, { type FastifyInstance } from "fastify";
import { ZodError } from "zod";
import { authenticate } from "./auth.ts";
import type { ConfigStore, Device, ServiceToken } from "./config.ts";
import { AppError } from "./errors.ts";
import { Notifier } from "./notify.ts";
import { configRoutes } from "./routes/config.ts";
import { dockerRoutes } from "./routes/docker.ts";
import { homepageRoutes } from "./routes/homepage.ts";
import { powerRoutes } from "./routes/power.ts";
import { serviceRoutes } from "./routes/services.ts";
import { systemRoutes } from "./routes/system.ts";
import { wakeRoutes } from "./routes/wake.ts";
import { auditRoutes, type AuditDetail } from "./audit.ts";
import { EventLog, eventRoutes, eventsPath } from "./events.ts";
import { agentStatusRoutes, type RunLog } from "./runs.ts";
import { desktopRoutes, openRoutes } from "./routes/desktop.ts";
import { browserOpener, browserRoutes } from "./routes/browser.ts";
import type { BrowserBridge } from "./browser_bridge.ts";
import { mediaRoutes } from "./routes/media.ts";
import { velourRoutes } from "./routes/velour.ts";
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
import { serviceTokenRoutes, touchServiceToken } from "./service_tokens.ts";
import type { ResearchService } from "./research/jobs.ts";
import type { AnalysisQueue } from "./analysis/jobs.ts";

export { VERSION } from "./version.ts";
import { VERSION } from "./version.ts";

export interface Ctx {
  store: ConfigStore;
  notifier: Notifier;
  /** Called (synchronously, must not throw) with a token the agent rejected as unknown; set by the security center. */
  onRejectedToken?: (token: string, info: { ip: string; path: string }) => void;
  /** Called with every audit entry after it is built (the security center's black box). */
  onAudit?: (entry: import("./audit.ts").AuditEntry) => void;
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
  /** Research job queue ("research" feature); created by researchRoutes unless supplied (tests). */
  research?: ResearchService;
  /**
   * Incident analysis queue: created by analysisRoutes ("analysis" feature) or lazily by the incident room in local
   * mode; one queue per agent (tests supply their own).
   */
  analysis?: AnalysisQueue;
}

declare module "fastify" {
  interface FastifyRequest {
    device?: Device;
    /** Set instead of device when a scoped service token authenticated the request. */
    service?: ServiceToken;
    /** Extra audit fields set by the route (ids, key names, counts, hashes; never values). See audit.ts. */
    auditDetail?: AuditDetail;
  }
  interface FastifyContextConfig {
    /** Service tokens holding this scope may call the route (devices may call every route). */
    scope?: string;
    /** No token needed: the route checks its own credential (only the recovery-code lockdown). */
    public?: boolean;
  }
}

export async function buildApp(ctx: Ctx, opts: { logger?: boolean; logStream?: { write(line: string): void } } = {}): Promise<FastifyInstance> {
  const app = Fastify({
    // logStream: tests capture the log (leak checks); in production pino writes to stdout.
    logger: opts.logger ? { level: "info", redact: ["req.headers.authorization"], ...(opts.logStream ? { stream: opts.logStream } : {}) } : false,
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

  // Authentication: every request except /v1/health requires a device token, or a service token on a route of its scope.
  app.addHook("onRequest", async (req) => {
    if (req.url === "/v1/health" || req.url.startsWith("/v1/health?")) return;
    // Routes that authenticate themselves (the recovery-code lockdown: the phone is gone, so is its token). The
    // Tailscale identity check still applies.
    if (req.routeOptions.config?.public === true) {
      const want = ctx.store.get().requireTailscaleLogin;
      if (want !== null && req.headers["tailscale-user-login"] !== want) throw new AppError("agent.auth.tailnetUserNotAllowed", 403);
      return;
    }
    let caller: ReturnType<typeof authenticate>;
    try {
      caller = authenticate(ctx.store.get(), req, req.routeOptions.config?.scope);
    } catch (e) {
      // A rejected token may be a planted decoy (security center traps): the hook raises the alarm; the caller sees
      // the same 401 as for any unknown token.
      if (e instanceof AppError && (e.code === "agent.auth.invalidToken" || e.code === "agent.auth.missingToken") && ctx.onRejectedToken) {
        const m = /^Bearer (\S+)$/.exec(String(req.headers.authorization ?? ""));
        const q = (req.query as Record<string, unknown> | undefined)?.["token"];
        const token = m?.[1] ?? (typeof q === "string" ? q : undefined);
        if (token) ctx.onRejectedToken(token, { ip: req.ip, path: req.url.split("?")[0]!.slice(0, 200) });
      }
      throw e;
    }
    req.device = caller.device;
    req.service = caller.service;
    if (caller.service) {
      void touchServiceToken(ctx.store, caller.service.id).catch((err) => req.log.warn({ err }, "hizmet belirteci kullanımı yazılamadı"));
    }
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
  serviceTokenRoutes(app, ctx);
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
    velourRoutes(app, ctx); // Velour (YouTube Music player) remote over its local control socket
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
  if (f.research) await (await import("./routes/research.ts")).researchRoutes(app, ctx);
  if (f.analysis) await (await import("./analysis/routes.ts")).analysisRoutes(app, ctx);
  for (const register of ctx.extraRoutes ?? []) await register(app, ctx);

  return app;
}
