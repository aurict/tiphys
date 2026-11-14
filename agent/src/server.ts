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
import { desktopRoutes } from "./routes/desktop.ts";
import { gitRoutes } from "./routes/git.ts";
import { portRoutes } from "./routes/ports.ts";
import { processRoutes } from "./routes/processes.ts";
import { transcribeRoutes } from "./routes/transcribe.ts";

export const VERSION = "0.2.0";

export interface Ctx {
  store: ConfigStore;
  notifier: Notifier;
  /** İsteğe özel ek modüller (Claude, Uptime Kuma) server.ts'e bağımlı olmadan kaydolur. */
  extraRoutes?: Array<(app: FastifyInstance, ctx: Ctx) => void | Promise<void>>;
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

  // Kimlik doğrulama: /v1/health dışında her istek cihaz token'ı ister.
  app.addHook("onRequest", async (req) => {
    if (req.url === "/v1/health" || req.url.startsWith("/v1/health?")) return;
    req.device = authenticate(ctx.store.get(), req);
  });

  app.get("/v1/health", async () => {
    const c = ctx.store.get();
    return { name: c.name, version: VERSION, features: c.features };
  });

  auditRoutes(app, ctx);
  configRoutes(app, ctx);
  const f = ctx.store.get().features;
  if (f.system) {
    systemRoutes(app, ctx);
    processRoutes(app, ctx);
  }
  if (f.git) gitRoutes(app, ctx);
  if (f.desktop) desktopRoutes(app, ctx);
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
