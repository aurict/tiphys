// /v1/telegram/* ("telegram" feature). Device-token auth like every route; mutating routes are rate-limited per
// device. The bot token is accepted only by PUT /v1/telegram/bot and never returned.
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { RateLimit } from "../control.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import { BOT_TOKEN_RE } from "./api.ts";
import { TelegramService, type ServiceDeps } from "./service.ts";
import { feedInputSchema, TEMPLATES, telegramStatePath } from "./state.ts";

export interface TelegramRouteOpts extends Partial<Omit<ServiceDeps, "store" | "notifier">> {
  /** false: no scheduler/poller timers (tests call tick()/pollOnce()). */
  startTimers?: boolean;
  onService?: (s: TelegramService) => void;
  limits?: { mutate?: RateLimit; heavy?: RateLimit };
}

const idParam = (req: FastifyRequest) => z.object({ id: z.string().min(1).max(64) }).parse(req.params).id;
const feedId = z.string().min(1).max(64);

export function telegramRoutes(opts: TelegramRouteOpts = {}) {
  return async (app: FastifyInstance, ctx: Ctx) => {
    const svc = new TelegramService({ ...opts, stateFile: opts.stateFile === undefined ? telegramStatePath(ctx.store.path) : opts.stateFile, store: ctx.store, notifier: ctx.notifier });
    await svc.load();
    opts.onService?.(svc);
    if (opts.startTimers !== false) svc.start();
    app.addHook("onClose", async () => svc.stop());

    const mutate = opts.limits?.mutate ?? new RateLimit(30, 60_000);
    // Runs (research on the PC), previews and test messages.
    const heavy = opts.limits?.heavy ?? new RateLimit(10, 10 * 60_000);
    const limited = (rl: RateLimit) => async (req: FastifyRequest) => {
      if (!rl.take(req.device?.id ?? "-")) throw new AppError("agent.telegram.rateLimited", 429);
    };
    const m = { preHandler: limited(mutate) };
    const h = { preHandler: [limited(mutate), limited(heavy)] };

    app.get("/v1/telegram/status", async () => svc.status());

    app.put("/v1/telegram/bot", m, async (req) => {
      const { token } = z.strictObject({ token: z.string().trim().regex(BOT_TOKEN_RE) }).parse(req.body);
      return { bot: await svc.setBot(token) };
    });

    app.delete("/v1/telegram/bot", m, async () => {
      await svc.removeBot();
      return { ok: true };
    });

    // Recipients
    app.get("/v1/telegram/recipients", async () => ({ recipients: svc.state.state.recipients }));

    app.patch("/v1/telegram/recipients/:id", m, async (req) => {
      const p = z.strictObject({ status: z.enum(["active", "paused"]).optional(), subscriptions: z.array(feedId).max(50).optional() }).parse(req.body);
      return { recipient: await svc.patchRecipient(idParam(req), p) };
    });

    app.delete("/v1/telegram/recipients/:id", m, async (req) => {
      await svc.removeRecipient(idParam(req));
      return { ok: true };
    });

    app.post("/v1/telegram/recipients/:id/test", h, async (req) => svc.testRecipient(idParam(req)));

    app.get("/v1/telegram/recipients/:id/deliveries", async (req) => {
      const { limit } = z.object({ limit: z.coerce.number().int().min(1).max(500).default(100) }).parse(req.query);
      return { deliveries: svc.deliveriesOf(idParam(req), limit) };
    });

    // Invites
    app.get("/v1/telegram/invites", async () => ({ invites: svc.state.state.invites.map((i) => svc.inviteView(i)) }));

    app.post("/v1/telegram/invites", m, async (req) => {
      const p = z.strictObject({ label: z.string().trim().min(1).max(80).optional(), feedIds: z.array(feedId).max(20).optional() }).parse(req.body ?? {});
      return { invite: await svc.createInvite(p) };
    });

    app.delete("/v1/telegram/invites/:id", m, async (req) => ({ invite: await svc.revokeInvite(idParam(req)) }));

    // Feeds
    app.get("/v1/telegram/templates", async () => ({ templates: TEMPLATES }));

    app.get("/v1/telegram/feeds", async () => ({ feeds: svc.state.state.feeds.map((f) => svc.feedView(f)) }));

    app.post("/v1/telegram/feeds", m, async (req) => ({ feed: svc.feedView(await svc.createFeed(feedInputSchema.parse(req.body))) }));

    app.get("/v1/telegram/feeds/:id", async (req) => ({ feed: svc.feedView(svc.getFeed(idParam(req))) }));

    app.put("/v1/telegram/feeds/:id", m, async (req) => ({ feed: svc.feedView(await svc.updateFeed(idParam(req), feedInputSchema.parse(req.body))) }));

    app.delete("/v1/telegram/feeds/:id", m, async (req) => {
      await svc.removeFeed(idParam(req));
      return { ok: true };
    });

    app.post("/v1/telegram/feeds/:id/run", h, async (req, reply) => reply.status(202).send({ issue: svc.issueSummary(await svc.run(idParam(req), "manual")) }));

    app.post("/v1/telegram/feeds/:id/preview", h, async (req, reply) => reply.status(202).send({ issue: svc.issueSummary(await svc.run(idParam(req), "preview")) }));

    // Issues (archive)
    app.get("/v1/telegram/issues", async (req) => {
      const q = z.object({ feedId: feedId.optional(), limit: z.coerce.number().int().min(1).max(500).default(50) }).parse(req.query);
      return { issues: svc.listIssues(q.feedId, q.limit).map((i) => svc.issueSummary(i)) };
    });

    app.get("/v1/telegram/issues/:id", async (req) => ({ issue: svc.getIssue(idParam(req)) }));

    app.post("/v1/telegram/issues/:id/approve", m, async (req) => ({ issue: svc.issueSummary(await svc.approve(idParam(req))) }));

    app.post("/v1/telegram/issues/:id/reject", m, async (req) => ({ issue: svc.issueSummary(await svc.reject(idParam(req))) }));

    app.post("/v1/telegram/issues/:id/test", h, async (req) => {
      const { recipientId } = z.strictObject({ recipientId: z.string().min(1).max(64) }).parse(req.body);
      return { delivery: await svc.sendTest(idParam(req), recipientId) };
    });
  };
}
