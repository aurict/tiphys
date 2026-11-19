// agy (Antigravity CLI) routes ("agy" feature, PC). Device tokens only. Like Claude sessions: the folder must be inside
// allowedRoots; agy's own permission prompts are answered from the phone; nothing runs without agy asking for it in the
// chosen mode. Audit detail: {session, cwd?} / {session, mode} / {session, option}; never prompt text.
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { RateLimit } from "../control.ts";
import { AppError } from "../errors.ts";
import { allowedPath } from "../paths.ts";
import type { Ctx } from "../server.ts";
import type { Spawn } from "./acp.ts";
import { realpath } from "node:fs/promises";
import { resolve, sep } from "node:path";
import { expandHome } from "../config.ts";
import { AgyManager } from "./manager.ts";

const sid = z.object({ id: z.string().regex(/^agy-[a-f0-9]{12}$/) });

function parse<T>(schema: z.ZodType<T>, v: unknown): T {
  const r = schema.safeParse(v);
  if (!r.success) throw new AppError("agent.request.invalid", 400, { issues: r.error.issues.map((i) => ({ path: i.path.map(String).join("."), message: i.code })) });
  return r.data;
}

export function agyRoutes(opts: { spawn?: Spawn; manager?: AgyManager } = {}) {
  return async (app: FastifyInstance, ctx: Ctx) => {
    const mgr = opts.manager ?? new AgyManager(ctx.notifier, opts.spawn, () => ctx.store.get().name);
    app.addHook("onClose", async () => mgr.shutdown());
    const startLimit = new RateLimit(6, 60_000);
    const listLimit = new RateLimit(10, 60_000);

    /** Is a conversation's folder inside allowedRoots (string check on the resolved path; the folder may be gone)? */
    const insideRoots = async (p: string) => {
      const roots = await Promise.all(ctx.store.get().allowedRoots.map((r) => realpath(expandHome(r)).catch(() => null)));
      const full = await realpath(p).catch(() => resolve(p));
      return roots.some((r) => r !== null && (full === r || full.startsWith(r.endsWith(sep) ? r : r + sep)));
    };
    const allowedConversations = async (cwd: string) => {
      const all = await mgr.conversations(cwd);
      const out = [];
      for (const c of all) if (c.cwd && (await insideRoots(c.cwd))) out.push(c);
      return out;
    };

    app.get("/v1/agy/conversations", async (req) => {
      const q = parse(z.object({ cwd: z.string().min(1).max(1024).default("~") }), req.query);
      if (!listLimit.take(req.device?.id ?? "-")) throw new AppError("agent.agy.rateLimited", 429);
      const cwd = await allowedPath(ctx.store.get(), q.cwd);
      return { conversations: await allowedConversations(cwd) };
    });

    app.get("/v1/agy/sessions", async () => ({ sessions: mgr.list() }));

    app.post("/v1/agy/sessions", async (req) => {
      const b = parse(
        z.strictObject({
          cwd: z.string().min(1).max(1024),
          prompt: z.string().max(100_000).optional(),
          resume: z.string().regex(/^[A-Za-z0-9-]{8,80}$/).optional(),
          modeId: z.string().regex(/^[a-z-]{1,40}$/).optional(),
          model: z.string().regex(/^[A-Za-z0-9._-]{1,80}$/).optional(),
        }),
        req.body,
      );
      if (!startLimit.take(req.device?.id ?? "-")) throw new AppError("agent.agy.rateLimited", 429);
      const cwd = await allowedPath(ctx.store.get(), b.cwd);
      req.auditDetail = { cwd, ...(b.resume ? { resume: b.resume } : {}) };
      // A resumed conversation must itself belong to an allowed folder (agy may keep working where it started).
      if (b.resume && !(await allowedConversations(cwd)).some((c) => c.sessionId === b.resume)) throw new AppError("agent.agy.conversationNotFound", 404);
      const s = await mgr.start({ ...b, cwd });
      req.auditDetail = { session: s.id, cwd, ...(b.resume ? { resume: b.resume } : {}) };
      return s.summary();
    });

    app.get("/v1/agy/sessions/:id", async (req) => {
      const { id } = parse(sid, req.params);
      const q = parse(z.object({ after: z.coerce.number().int().min(0).default(0), wait: z.coerce.number().int().min(0).max(25_000).default(0) }), req.query);
      const s = mgr.get(id);
      const events = await s.since(q.after, q.wait);
      return { session: s.summary(), events };
    });

    app.post("/v1/agy/sessions/:id/messages", async (req) => {
      const { id } = parse(sid, req.params);
      const b = parse(z.strictObject({ text: z.string().max(100_000).refine((t) => t.trim().length > 0) }), req.body);
      const s = mgr.get(id);
      if (s.status === "running" || s.status === "waiting" || s.status === "starting") throw new AppError("agent.agy.busy", 409);
      req.auditDetail = { session: id };
      void mgr.send(id, b.text).catch(() => {});
      return { ok: true };
    });

    app.post("/v1/agy/sessions/:id/cancel", async (req) => {
      const { id } = parse(sid, req.params);
      req.auditDetail = { session: id };
      mgr.cancel(id);
      return { ok: true };
    });

    app.post("/v1/agy/sessions/:id/permissions/:requestId", async (req) => {
      const p = parse(sid.extend({ requestId: z.string().regex(/^[a-f0-9]{12}$/) }), req.params);
      const b = parse(z.strictObject({ optionId: z.string().min(1).max(80) }), req.body);
      req.auditDetail = { session: p.id, option: b.optionId };
      mgr.answer(p.id, p.requestId, b.optionId);
      return { ok: true };
    });

    app.post("/v1/agy/sessions/:id/mode", async (req) => {
      const { id } = parse(sid, req.params);
      const b = parse(z.strictObject({ modeId: z.string().regex(/^[a-z-]{1,40}$/) }), req.body);
      req.auditDetail = { session: id, mode: b.modeId };
      await mgr.setMode(id, b.modeId);
      return mgr.get(id).summary();
    });

    app.post("/v1/agy/sessions/:id/model", async (req) => {
      const { id } = parse(sid, req.params);
      const b = parse(z.strictObject({ model: z.string().regex(/^[A-Za-z0-9._-]{1,80}$/) }), req.body);
      req.auditDetail = { session: id, model: b.model };
      await mgr.setModel(id, b.model);
      return mgr.get(id).summary();
    });

    app.delete("/v1/agy/sessions/:id", async (req) => {
      const { id } = parse(sid, req.params);
      req.auditDetail = { session: id };
      await mgr.close(id);
      return { ok: true };
    });
  };
}
