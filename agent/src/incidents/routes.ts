// Incident room routes ("incidents" feature, PLAN.md §13.1 I-1, I-2, I-3). Device tokens only (no service scope).
import { dirname, join } from "node:path";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { AnalysisQueue } from "../analysis/jobs.ts";
import { inspectText } from "../analysis/prompt.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import { SERVICE_NAME, STACK_ID } from "../stacks.ts";
import { DeployTracker } from "./deploys.ts";
import { CLEANUP_OPTIONS } from "./disk_cleanup.ts";
import { MetricsRing } from "./metrics_ring.ts";
import { IncidentService } from "./service.ts";
import { ID_RE } from "./store.ts";

const TICK_MS = 60_000;
const BUNDLE_LIMIT = 10;
const BUNDLE_WINDOW_MS = 10 * 60_000;

const idParams = z.object({ id: z.string().regex(ID_RE) });
const actionParams = idParams.extend({ aid: z.string().regex(/^c-[a-f0-9]{12}$/) });
const actionBody = { options: z.array(z.enum(CLEANUP_OPTIONS)).max(CLEANUP_OPTIONS.length).optional() };
const TEST_KINDS = ["docker.died", "docker.unhealthy", "service.failed", "disk.full", "uptime.down"] as const;

const by = (req: FastifyRequest) => `device:${req.device?.id ?? "?"}`;

export function incidentRoutes(svcIn?: IncidentService) {
  return async (app: FastifyInstance, ctx: Ctx) => {
    let metrics: MetricsRing | undefined;
    let deploys: DeployTracker | undefined;
    let svc = svcIn;
    if (!svc) {
      const dir = join(dirname(ctx.store.path), "incidents");
      const log = (msg: string, err?: unknown) => app.log.warn({ err }, msg);
      metrics = new MetricsRing();
      metrics.start(ctx.store.get().features.docker);
      if (ctx.store.get().features.docker) {
        deploys = new DeployTracker({ file: join(dir, "deploys.jsonl"), log });
        await deploys.load();
        deploys.start();
      }
      svc = await IncidentService.open({
        store: ctx.store,
        notifier: ctx.notifier,
        dir,
        metrics,
        deploys,
        // Local mode shares the agent's analysis queue (the "analysis" feature's, if on).
        analysisQueue: () => (ctx.analysis ??= new AnalysisQueue({ log: (level, msg, extra) => app.log[level](extra ?? {}, msg) })),
        log: (msg, err) => app.log.warn({ err }, msg),
      });
    }
    const s = svc;
    const unobserve = ctx.notifier.observe(s.observe);
    const timer = setInterval(() => void s.tick().catch((err) => app.log.warn({ err }, "olay denetimi başarısız")), TICK_MS);
    timer.unref();
    app.addHook("onClose", async () => {
      clearInterval(timer);
      unobserve();
      metrics?.stop();
      await deploys?.stop();
      await s.close();
      await ctx.analysis?.close();
    });
    const bundleRate = new Map<string, number[]>();

    app.get("/v1/incidents", async (req) => {
      const q = z
        .object({ status: z.enum(["open", "acknowledged", "resolved", "active"]).optional(), limit: z.coerce.number().int().min(1).max(500).default(100) })
        .parse(req.query);
      return { incidents: s.list(q.status, q.limit) };
    });

    app.get("/v1/incidents/deploys", async (req) => {
      const q = z
        .object({ stack: z.string().regex(STACK_ID).optional(), service: z.string().regex(SERVICE_NAME).optional(), limit: z.coerce.number().int().min(1).max(500).default(100) })
        .parse(req.query);
      return { deploys: await s.deployHistory(q) };
    });

    app.get("/v1/incidents/:id", async (req) => {
      const incident = await s.get(idParams.parse(req.params).id);
      return { incident, similar: s.similar(incident) };
    });

    app.post("/v1/incidents/:id/ack", async (req) => {
      const { id } = idParams.parse(req.params);
      req.auditDetail = { incident: id };
      return { incident: await s.ack(id, by(req)) };
    });

    app.post("/v1/incidents/:id/resolve", async (req) => {
      const { id } = idParams.parse(req.params);
      const { note } = z.object({ note: z.string().trim().min(1).max(2000).optional() }).parse(req.body ?? {});
      req.auditDetail = { incident: id, noteChars: note?.length ?? 0 };
      return { incident: await s.resolve(id, by(req), note) };
    });

    app.post("/v1/incidents/:id/reopen", async (req) => {
      const { id } = idParams.parse(req.params);
      req.auditDetail = { incident: id };
      return { incident: await s.reopen(id, by(req)) };
    });

    app.post("/v1/incidents/:id/notes", async (req) => {
      const { id } = idParams.parse(req.params);
      const { text } = z.strictObject({ text: z.string().trim().min(1).max(2000) }).parse(req.body);
      req.auditDetail = { incident: id, chars: text.length };
      return { incident: await s.note(id, by(req), text) };
    });

    app.post("/v1/incidents/:id/analyze", async (req, reply) => {
      const { id } = idParams.parse(req.params);
      req.auditDetail = { incident: id };
      const analysis = await s.analyze(id, by(req));
      return reply.status(202).send({ analysis });
    });

    // "Claude ile incele": the redacted bundle as text, for a normal Claude session the app starts on the PC.
    app.get("/v1/incidents/:id/bundle", async (req) => {
      const { id } = idParams.parse(req.params);
      const { redacted } = z.object({ redacted: z.string().optional() }).parse(req.query);
      if (redacted !== "1") throw new AppError("agent.incident.redactedOnly", 400);
      const dev = req.device!.id;
      const now = Date.now();
      const recent = (bundleRate.get(dev) ?? []).filter((t) => now - t < BUNDLE_WINDOW_MS);
      if (recent.length >= BUNDLE_LIMIT) throw new AppError("agent.incident.bundleRateLimited", 429, { limit: BUNDLE_LIMIT, windowSeconds: BUNDLE_WINDOW_MS / 1000 });
      recent.push(now);
      bundleRate.set(dev, recent);
      const b = await s.bundle(id);
      const text = inspectText(b);
      req.auditDetail = { incident: id, evidence: b.evidence.length, bytes: Buffer.byteLength(text) };
      return { text, bytes: Buffer.byteLength(text), evidenceCount: b.evidence.length, truncated: b.truncated };
    });

    app.get("/v1/incidents/:id/actions", async (req) => s.actions(idParams.parse(req.params).id));

    app.post("/v1/incidents/:id/actions/:aid/preview", async (req) => {
      const { id, aid } = actionParams.parse(req.params);
      const body = z.strictObject(actionBody).parse(req.body ?? {});
      const p = await s.preview(id, aid, req.device!.id, body);
      req.auditDetail = { incident: id, action: p.candidate.kind, candidate: aid, ...(body.options ? { options: body.options.join(",") } : {}) };
      return p;
    });

    app.post("/v1/incidents/:id/actions/:aid/execute", async (req) => {
      const { id, aid } = actionParams.parse(req.params);
      const body = z.object({ previewToken: z.string().max(200).optional(), confirm: z.boolean().optional(), ...actionBody }).parse(req.body ?? {});
      req.auditDetail = { incident: id, candidate: aid, ...(body.options ? { options: body.options.join(",") } : {}) };
      if (body.confirm !== true) throw new AppError("agent.incident.confirmRequired", 400);
      if (!body.previewToken) throw new AppError("agent.preview.invalid", 409);
      const result = await s.execute(id, aid, req.device!.id, body.previewToken, { options: body.options });
      req.auditDetail = { incident: id, candidate: aid, ok: result.ok };
      return result;
    });

    app.post("/v1/incidents/test", async (req) => {
      const { kind } = z.strictObject({ kind: z.enum(TEST_KINDS) }).parse(req.body);
      req.auditDetail = { kind };
      const host = ctx.store.get().name;
      const T = "tiphys-test";
      const params: Record<string, string | number> =
        kind === "service.failed"
          ? { host, unit: `${T}.service`, scope: "user" }
          : kind === "disk.full"
            ? { host, mount: `/${T}`, percent: 99 }
            : kind === "uptime.down"
              ? { host, monitor: T, monitorId: 0 }
              : kind === "docker.died"
                ? { host, container: T, code: 1 }
                : { host, container: T };
      // Goes through the normal notification path, so the observer opens (or updates) a test incident and links it.
      await ctx.notifier.send({ key: kind, params, link: "tiphys://system", context: { test: "1" } });
      const target = String(params.container ?? params.unit ?? params.mount ?? params.monitor);
      const inc = s.list("active", 500).find((i) => i.test && i.target === target && i.kind === kind) ?? s.list("active", 500).find((i) => i.test);
      return { incident: inc ?? null };
    });

    app.delete("/v1/incidents/:id", async (req) => {
      const { id } = idParams.parse(req.params);
      req.auditDetail = { incident: id };
      await s.remove(id);
      return { ok: true };
    });
  };
}
