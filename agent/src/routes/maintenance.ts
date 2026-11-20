// GET /v1/doctor (K6), GET /v1/update and POST /v1/update/apply (K8). Always registered (device token required, like
// every route); doctor.ts and update.ts are loaded on first use only.
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import type { UpdateOptions } from "../update.ts";

export function maintenanceRoutes(app: FastifyInstance, ctx: Ctx, updateOpts: UpdateOptions = {}, restart = defaultRestart) {
  app.get("/v1/doctor", async () => {
    const { runDoctor, defaultDoctorDeps } = await import("../doctor.ts");
    return runDoctor(defaultDoctorDeps(ctx.store.get(), ctx.store.path));
  });

  app.get("/v1/update", async () => {
    const { checkUpdate } = await import("../update.ts");
    return checkUpdate(updateOpts);
  });

  app.post("/v1/update/apply", async (req, reply) => {
    if (!req.device) throw new AppError("agent.auth.scopeDenied", 403);
    if (!ctx.store.get().features.update) throw new AppError("agent.update.disabled", 403);
    const body = z.object({ version: z.string().regex(/^\d+\.\d+\.\d+$/), confirm: z.literal(true) }).safeParse(req.body);
    if (!body.success) throw new AppError("agent.update.confirmRequired", 400);
    const { applyUpdate } = await import("../update.ts");
    req.auditDetail = { version: body.data.version };
    const r = await applyUpdate(body.data.version, updateOpts);
    await ctx.notifier.events?.record({ key: "agent.updated", params: { host: ctx.store.get().name, version: r.version }, device: req.device.id }, (err) => req.log.warn({ err }, "olay yazılamadı"));
    // Answer first, then exit: the service manager (Restart=always / KeepAlive / the Windows loop) starts the new one.
    reply.raw.once("finish", () => setTimeout(restart, 500).unref());
    return { ok: true, version: r.version, restarting: true };
  });
}

function defaultRestart() {
  process.kill(process.pid, "SIGTERM");
}
