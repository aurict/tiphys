// Incident analysis jobs on the PC ("analysis" feature, PLAN.md §13.1 I-3). Starting, reading and cancelling a job
// are open to service tokens with the "analysis" scope (a server's incident room; only their own jobs) and to devices;
// listing all jobs is for devices only.
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { AppError, notFound } from "../errors.ts";
import type { Ctx } from "../server.ts";
import { AnalysisQueue, type AnalysisJob } from "./jobs.ts";
import { bundleSchema, MAX_BUNDLE_BYTES } from "./schema.ts";

const scoped = { config: { scope: "analysis" } };
const params = z.object({ id: z.string().regex(/^aj-[a-f0-9]{16}$/) });

const caller = (req: FastifyRequest) => (req.service ? `service:${req.service.id}` : `device:${req.device?.id ?? "?"}`);

export function publicJob(j: AnalysisJob) {
  return {
    id: j.id,
    status: j.status,
    createdAt: j.createdAt,
    ...(j.startedAt ? { startedAt: j.startedAt } : {}),
    ...(j.finishedAt ? { finishedAt: j.finishedAt } : {}),
    ...(j.durationSec !== undefined ? { durationSec: j.durationSec } : {}),
    ...(j.error ? { error: j.error } : {}),
    ...(j.result ? { result: j.result } : {}),
  };
}

export async function analysisRoutes(app: FastifyInstance, ctx: Ctx) {
  const q = (ctx.analysis ??= new AnalysisQueue({ log: (level, msg, extra) => app.log[level](extra ?? {}, msg) }));
  app.addHook("onClose", async () => q.close());

  const find = (req: FastifyRequest) => {
    const { id } = params.parse(req.params);
    const job = q.get(id);
    if (!job || (req.service && job.requestedBy !== caller(req))) throw notFound("analysis", { id });
    return job;
  };

  app.post("/v1/analysis/jobs", scoped, async (req, reply) => {
    // Size first, so a huge body isn't walked by the schema.
    if (Buffer.byteLength(JSON.stringify(req.body ?? null)) > MAX_BUNDLE_BYTES + 1024) throw new AppError("agent.analysis.bundleTooLarge", 413, { maxBytes: MAX_BUNDLE_BYTES });
    const { bundle } = z.strictObject({ bundle: bundleSchema }).parse(req.body);
    const job = q.submit(bundle, caller(req));
    req.auditDetail = { job: job.id, incident: bundle.incident.id, evidence: bundle.evidence.length };
    return reply.status(202).send({ id: job.id, status: job.status });
  });

  app.get("/v1/analysis/jobs/:id", scoped, async (req) => publicJob(find(req)));

  app.get("/v1/analysis/jobs", async () => ({
    jobs: q.list().map((j) => ({
      id: j.id,
      status: j.status,
      createdAt: j.createdAt,
      startedAt: j.startedAt ?? null,
      finishedAt: j.finishedAt ?? null,
      durationSec: j.durationSec ?? null,
      error: j.error ?? null,
      requestedBy: j.requestedBy,
      incidentId: j.incidentId,
      hypothesisCount: j.result?.hypotheses.length ?? null,
    })),
  }));

  app.delete("/v1/analysis/jobs/:id", scoped, async (req) => {
    const job = find(req);
    const cancelled = await q.cancel(job.id);
    return { cancelled, job: publicJob(job) };
  });
}
