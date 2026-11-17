// Research jobs ("research" feature, PLAN.md §12). Starting, reading and cancelling a job are open to service tokens
// with the "research" scope (atlas; only their own jobs) and to devices; listing all jobs is for the app only.
import { dirname, join } from "node:path";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { notFound } from "../errors.ts";
import { defaultOptions, ResearchService, type Job } from "../research/jobs.ts";
import { jobInputSchema } from "../research/schema.ts";
import type { Ctx } from "../server.ts";

const scoped = { config: { scope: "research" } };
const params = z.object({ id: z.string().regex(/^rj-[a-f0-9]{16}$/) });

const caller = (req: FastifyRequest) => (req.service ? `service:${req.service.id}` : `device:${req.device?.id ?? "?"}`);

/** Contract shape: no input, no requester. */
function publicJob(j: Job) {
  return {
    id: j.id,
    status: j.status,
    createdAt: j.createdAt,
    ...(j.startedAt ? { startedAt: j.startedAt } : {}),
    ...(j.finishedAt ? { finishedAt: j.finishedAt } : {}),
    ...(j.error ? { error: j.error } : {}),
    ...(j.result ? { result: j.result } : {}),
  };
}

function summary(j: Job) {
  return {
    id: j.id,
    status: j.status,
    createdAt: j.createdAt,
    startedAt: j.startedAt ?? null,
    finishedAt: j.finishedAt ?? null,
    error: j.error ?? null,
    topic: j.input.topic,
    editor: j.input.editor,
    requestedBy: j.requestedBy,
    itemCount: j.result?.items.length ?? null,
    sourceCount: j.result ? j.result.items.reduce((n, i) => n + i.sources.length, 0) : null,
    timings: j.result?.timings ?? null,
  };
}

export async function researchRoutes(app: FastifyInstance, ctx: Ctx) {
  const svc =
    ctx.research ??
    (await ResearchService.open(
      defaultOptions(join(dirname(ctx.store.path), "research-jobs.json"), (level, msg, extra) => app.log[level](extra ?? {}, msg)),
    ));
  app.addHook("onClose", async () => svc.close());

  /** A service token sees only the jobs it started. */
  const find = (req: FastifyRequest) => {
    const { id } = params.parse(req.params);
    const job = svc.get(id);
    if (!job || (req.service && job.requestedBy !== caller(req))) throw notFound("research", { id });
    return job;
  };

  app.post("/v1/research/jobs", scoped, async (req, reply) => {
    const input = jobInputSchema.parse(req.body);
    const job = svc.submit(input, caller(req));
    return reply.status(202).send({ id: job.id });
  });

  app.get("/v1/research/jobs/:id", scoped, async (req) => publicJob(find(req)));

  app.get("/v1/research/jobs", async () => ({ jobs: svc.list().map(summary) }));

  app.delete("/v1/research/jobs/:id", scoped, async (req) => {
    const job = find(req);
    const cancelled = await svc.cancel(job.id);
    return { cancelled, job: publicJob(job) };
  });
}
