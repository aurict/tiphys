// Security center routes ("security" feature, PLAN.md §15 S-1). Device tokens only, except GET /v1/security/raw which
// a "security-report" service token may call (the monitoring server pulls this host's raw audit text from there).
// Audit detail: {host} / {host, full} / {host, accepted}; host config changes {host, source}; never tokens.
import type { FastifyInstance } from "fastify";
import { z, ZodError } from "zod";
import { securityHostSchema, securityRole, type AgentConfig } from "../config.ts";
import { RateLimit } from "../control.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import { collectLocal, type AuditMode } from "./collect.ts";
import { SecurityService, type SecurityHost, type ServiceOpts } from "./service.ts";

const invalid = (e: ZodError) =>
  new AppError("agent.request.invalid", 400, { issues: e.issues.map((i) => ({ path: i.path.map(String).join("."), message: i.code })) });

function parse<T>(schema: z.ZodType<T>, v: unknown): T {
  const r = schema.safeParse(v);
  if (!r.success) throw invalid(r.error);
  return r.data;
}

const hostId = z.string().regex(/^[a-z0-9][a-z0-9-]{0,62}$/);
const ports = z.array(z.string().regex(/^(tcp|udp)\/([1-9]\d{0,3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$/)).max(100);
const sourceInput = z.discriminatedUnion("kind", [
  securityHostSchema.shape.source.options[0],
  // token may be omitted on PATCH when the URL stays the same (kept).
  z.strictObject({ kind: z.literal("agent"), url: z.url({ protocol: /^https$/ }), token: z.string().regex(/^tps_[A-Za-z0-9_-]{20,}$/).optional() }),
]);
const createBody = z.strictObject({ id: hostId, name: z.string().min(1).max(80), role: securityRole.default("server"), allowedPorts: ports.default([]), source: sourceInput });
const patchBody = z.strictObject({ name: z.string().min(1).max(80).optional(), role: securityRole.optional(), allowedPorts: ports.optional(), source: sourceInput.optional() });
const selfPatch = z.strictObject({ role: securityRole.optional(), allowedPorts: ports.optional(), sudo: z.boolean().optional() });

export function publicHost(h: SecurityHost) {
  const src = h.source.kind === "agent" ? { kind: "agent" as const, url: h.source.url, hasToken: true } : h.source;
  return { id: h.id, name: h.name, role: h.role, allowedPorts: h.allowedPorts, source: src };
}

function resolveSource(input: z.infer<typeof sourceInput>, prev: SecurityHost["source"] | null): SecurityHost["source"] {
  if (input.kind === "ssh") return input;
  const token = input.token ?? (prev?.kind === "agent" && prev.url === input.url ? prev.token : undefined);
  if (!token) throw new AppError("agent.security.tokenRequired", 400);
  return { kind: "agent", url: input.url, token };
}

export interface SecurityRouteOpts extends ServiceOpts {
  service?: SecurityService;
  startTimer?: boolean;
  checkLimit?: RateLimit;
  rawLimit?: RateLimit;
}

export function securityRoutes(opts: SecurityRouteOpts = {}) {
  return async (app: FastifyInstance, ctx: Ctx) => {
    const svc = opts.service ?? new SecurityService(ctx, opts);
    await svc.load();
    if (opts.startTimer !== false) {
      svc.start();
      app.addHook("onClose", async () => svc.stop());
    }
    const checkLimit = opts.checkLimit ?? new RateLimit(6, 10 * 60_000);
    const rawLimit = opts.rawLimit ?? new RateLimit(10, 10 * 60_000);
    const idOf = (req: { params: unknown }) => parse(z.object({ id: hostId }), req.params).id;

    app.get("/v1/security/overview", async () => ({
      intervalMinutes: ctx.store.get().security.intervalMinutes,
      hosts: svc.hosts().map((h) => svc.summary(h)),
    }));

    app.get("/v1/security/hosts/:id", async (req) => svc.detail(idOf(req)));

    app.post("/v1/security/hosts/:id/check", async (req) => {
      const id = idOf(req);
      const b = parse(z.strictObject({ full: z.boolean().default(false) }), req.body ?? {});
      req.auditDetail = { host: id, full: b.full };
      if (!checkLimit.take(req.device?.id ?? "-")) throw new AppError("agent.security.rateLimited", 429);
      await svc.check(id, { full: b.full });
      return svc.detail(id);
    });

    app.post("/v1/security/hosts/:id/baseline", async (req) => {
      const id = idOf(req);
      parse(z.strictObject({ confirm: z.literal(true) }), req.body);
      const r = await svc.acceptBaseline(id);
      req.auditDetail = { host: id, accepted: r.accepted };
      return { ...r, ...svc.detail(id) };
    });

    // Host settings (separate from PATCH /v1/config so tokens never travel back).
    app.get("/v1/security/hosts", async () => ({ self: ctx.store.get().security.self, hosts: ctx.store.get().security.hosts.map(publicHost) }));

    app.post("/v1/security/hosts", async (req, reply) => {
      const b = parse(createBody, req.body);
      if (b.id === "self") throw new AppError("agent.security.hostExists", 409, { id: b.id });
      const host: SecurityHost = { ...b, source: resolveSource(b.source, null) };
      await ctx.store.update((c: AgentConfig) => {
        if (c.security.hosts.some((h) => h.id === b.id)) throw new AppError("agent.security.hostExists", 409, { id: b.id });
        if (c.security.hosts.length >= 20) throw new AppError("agent.security.tooManyHosts", 409);
        c.security.hosts.push(host);
        return c;
      });
      req.auditDetail = { host: b.id, source: b.source.kind };
      reply.code(201);
      return { host: publicHost(host) };
    });

    app.patch("/v1/security/hosts/:id", async (req) => {
      const id = idOf(req);
      if (id === "self") {
        const s = parse(selfPatch, req.body);
        await ctx.store.update((c) => {
          c.security.self = { ...c.security.self, ...s };
          return c;
        });
        req.auditDetail = { host: id };
        await svc.reevaluate(id);
        return { self: ctx.store.get().security.self };
      }
      const b = parse(patchBody, req.body);
      let out: SecurityHost | null = null;
      await ctx.store.update((c) => {
        const h = c.security.hosts.find((x) => x.id === id);
        if (!h) throw new AppError("agent.security.hostNotFound", 404, { id });
        if (b.name !== undefined) h.name = b.name;
        if (b.role !== undefined) h.role = b.role;
        if (b.allowedPorts !== undefined) h.allowedPorts = b.allowedPorts;
        if (b.source !== undefined) h.source = resolveSource(b.source, h.source);
        out = { ...h };
        return c;
      });
      req.auditDetail = { host: id, ...(b.source ? { source: b.source.kind } : {}) };
      await svc.reevaluate(id);
      return { host: publicHost(out!) };
    });

    app.delete("/v1/security/hosts/:id", async (req) => {
      const id = idOf(req);
      if (id === "self") throw new AppError("agent.security.selfPermanent", 409);
      await ctx.store.update((c) => {
        if (!c.security.hosts.some((h) => h.id === id)) throw new AppError("agent.security.hostNotFound", 404, { id });
        c.security.hosts = c.security.hosts.filter((h) => h.id !== id);
        return c;
      });
      await svc.forget(id);
      req.auditDetail = { host: id };
      return { ok: true };
    });

    // Raw audit text of this host for the monitoring server ("security-report" scope) or a device.
    app.get("/v1/security/raw", { config: { scope: "security-report" } }, async (req) => {
      const q = parse(z.object({ mode: z.enum(["report", "report-full"]).default("report") }), req.query);
      const who = req.device?.id ?? `service:${req.service?.id ?? "-"}`;
      if (!rawLimit.take(who)) throw new AppError("agent.security.rateLimited", 429);
      const text = await collectLocal({ mode: q.mode as AuditMode, sudo: ctx.store.get().security.self.sudo, configPath: ctx.store.path, spawner: opts.spawner });
      return { text };
    });
  };
}
