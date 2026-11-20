import websocket from "@fastify/websocket";
import Fastify, { type FastifyInstance } from "fastify";
import { ZodError } from "zod";
import { authenticateFresh } from "./auth.ts";
import type { ConfigStore, Device, ServiceToken } from "./config.ts";
import { AppError } from "./errors.ts";
import { Notifier } from "./notify.ts";
import { configRoutes } from "./routes/config.ts";
import { auditRoutes, type AuditDetail } from "./audit.ts";
import { EventLog, eventRoutes, eventsPath } from "./events.ts";
import { agentStatusRoutes, type RunLog } from "./runs.ts";
import type { BrowserBridge } from "./browser_bridge.ts";
import type { UiService } from "./atspi.ts";
import type { ControlSessions } from "./control.ts";
import type { Hyprctl } from "./hyprctl.ts";
import type { DesktopApp } from "./desktop_apps.ts";
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
  /** Focuses the first Hyprland window of an app class (set by hyprRoutes); false if none is open. */
  focusClass?: (cls: string) => Promise<boolean>;
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
    let caller: Awaited<ReturnType<typeof authenticateFresh>>;
    try {
      caller = await authenticateFresh(ctx.store, req, req.routeOptions.config?.scope);
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
  // Doctor and self-update (K6/K8): tiny route file; the checks and the updater load on first use.
  (await import("./routes/maintenance.ts")).maintenanceRoutes(app, ctx);
  const f = ctx.store.get().features;
  // Feature modules load only when the feature is on: a server without the desktop never loads the desktop code
  // (H1, PLAN.md §18). Order matters inside "desktop": hyprRoutes sets up the control session the later ones use.
  if (f.system) {
    (await import("./routes/system.ts")).systemRoutes(app, ctx);
    (await import("./routes/processes.ts")).processRoutes(app, ctx);
  }
  if (f.git) (await import("./routes/git.ts")).gitRoutes(app, ctx);
  // Desktop backend (once at startup): Hyprland as before, or the native helper on other desktops (desktop_backend.ts).
  const backend = f.desktop ? await (await import("./desktop_backend.ts")).selectBackend(ctx.store.get().desktop, await defaultBackendDeps()) : null;
  if (backend?.backend === "helper") await helperDesktop(app, ctx, backend.helperPath);
  else if (f.desktop) {
    const [desktop, browser, media, velour, hypr, stream, sunshine, atspi] = await Promise.all([
      import("./routes/desktop.ts"),
      import("./routes/browser.ts"),
      import("./routes/media.ts"),
      import("./routes/velour.ts"),
      import("./routes/hypr.ts"),
      import("./routes/stream.ts"),
      import("./routes/sunshine.ts"),
      import("./atspi.ts"),
    ]);
    desktop.desktopRoutes(app, ctx);
    desktop.openRoutes(app, browser.browserOpener(ctx)); // "Open on PC": new tab if the extension is connected
    media.mediaRoutes(app, ctx);
    velour.velourRoutes(app, ctx); // Velour (YouTube Music player) remote over its local control socket
    hypr.hyprRoutes(app, ctx);
    browser.browserRoutes(app, ctx); // Firefox bridge (11.2): uses hyprRoutes' control session
    stream.streamRoutes(app, ctx); // live screen (10.2): uses hyprRoutes' control session
    sunshine.sunshineRoutes(app, ctx); // high quality (10.2 B): Sunshine status, start/stop, Moonlight pairing
    atspi.atspiRoutes(app, ctx); // mobile view (11.4): AT-SPI tree; uses hyprRoutes' control session
    const { capabilitiesRoute, HYPRLAND_CAPABILITIES } = await import("./desktop_backend.ts");
    capabilitiesRoute(app, async () => ({ backend: "hyprland", capabilities: HYPRLAND_CAPABILITIES }));
  }
  if (f.ports) (await import("./routes/ports.ts")).portRoutes(app, ctx);
  if (f.transcribe) (await import("./routes/transcribe.ts")).transcribeRoutes(app, ctx);
  if (f.services) (await import("./routes/services.ts")).serviceRoutes(app, ctx);
  if (f.docker) (await import("./routes/docker.ts")).dockerRoutes(app, ctx);
  if (f.power) (await import("./routes/power.ts")).powerRoutes(app, ctx);
  if (f.homepage) (await import("./routes/homepage.ts")).homepageRoutes(app, ctx);
  if (f.wake) (await import("./routes/wake.ts")).wakeRoutes(app, ctx);
  if (f.research) await (await import("./routes/research.ts")).researchRoutes(app, ctx);
  if (f.analysis) await (await import("./analysis/routes.ts")).analysisRoutes(app, ctx);
  for (const register of ctx.extraRoutes ?? []) await register(app, ctx);

  return app;
}

/** Hyprland detection and helper lookup used by the "auto" backend (both cheap: a directory listing, a few stats). */
async function defaultBackendDeps(): Promise<import("./desktop_backend.ts").BackendDeps> {
  const [{ hyprEnv }, { findHelper }] = await Promise.all([import("./routes/hypr.ts"), import("./desktop_backend.ts")]);
  const { realHyprIo } = await import("./routes/hypr.ts");
  return { hyprland: hyprEnv, hyprlandInstalled: () => realHyprIo.has("hyprctl"), findHelper: (p) => findHelper(p) };
}

/**
 * "desktop" on the helper backend: the panel, screenshot, live screen and (off Wayland) clipboard go through
 * `tiphys-desktop`; media, Velour, "Open on PC" and the Firefox bridge are the same as on Hyprland. AT-SPI mobile view,
 * Sunshine, Claude's PC tools and the Firefox window raising stay Hyprland-only.
 */
async function helperDesktop(app: FastifyInstance, ctx: Ctx, helperPath: string | null) {
  const [desktop, browser, media, velour, portable, helper, hypr] = await Promise.all([
    import("./routes/desktop.ts"),
    import("./routes/browser.ts"),
    import("./routes/media.ts"),
    import("./routes/velour.ts"),
    import("./routes/desktop_portable.ts"),
    import("./desktop_helper.ts"),
    import("./routes/hypr.ts"),
  ]);
  // Clipboard: wl-paste/wl-copy (with PC → phone sync) on a Wayland session that has them, else the helper.
  const wayland =
    process.platform === "linux" &&
    (await desktop.waylandEnv().then(() => true, () => false)) &&
    (await hypr.realHyprIo.has("wl-paste")) &&
    (await hypr.realHyprIo.has("wl-copy"));
  if (wayland) desktop.clipboardRoutes(app, ctx);
  const env = async () => ({ ...process.env, ...(await desktop.waylandEnv().catch(() => ({}))), ...desktop.sessionBusEnv() });
  desktop.openRoutes(app, browser.browserOpener(ctx), env);
  media.mediaRoutes(app, ctx);
  velour.velourRoutes(app, ctx);
  const client = new helper.HelperClient({ command: helperPath, log: (msg, err) => app.log.warn({ err }, msg) });
  portable.portableRoutes(app, ctx, { client, clipboard: wayland ? "wayland" : "helper" });
  browser.browserRoutes(app, ctx); // Firefox bridge: uses portableRoutes' control session
}
