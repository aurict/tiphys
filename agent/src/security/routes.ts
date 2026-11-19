// Security center routes ("security" feature, PLAN.md §15 S-1). Device tokens only, except GET /v1/security/raw which
// a "security-report" service token may call (the monitoring server pulls this host's raw audit text from there).
// Audit detail: {host} / {host, full} / {host, accepted}; host config changes {host, source}; never tokens.
import type { FastifyInstance } from "fastify";
import { z, ZodError } from "zod";
import { agentConfigSchema, securityHostSchema, securityRole, type AgentConfig } from "../config.ts";
import { RateLimit } from "../control.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import { collectLocal, type AuditMode } from "./collect.ts";
import { lokiBaseUrl, SecretScanner, type SecretOpts } from "./secrets.ts";
import { alertRelay, sendOwnerTelegram } from "./alerts.ts";
import { BlackBox, BlackBoxPusher } from "./blackbox.ts";
import { assertCodeShape, codeMatches, fanOut, hashCode, newRecoveryCode, revokeAll } from "./lockdown.ts";
import { randomBytes } from "node:crypto";
import { TrapService, type TrapOpts } from "./traps.ts";
import { ExposureScanner, type ExposureOpts } from "./exposure.ts";
import { CloudflareWatch } from "./cloudflare.ts";
import { SecurityService, type SecurityHost, type ServiceOpts } from "./service.ts";
import { VulnScanner, type InventoryHost, type VulnOpts } from "./vulns.ts";

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
const createBody = z.strictObject({ id: hostId, name: z.string().min(1).max(80), role: securityRole.default("server"), allowedPorts: ports.default([]), source: sourceInput, traps: z.boolean().default(false) });
const patchBody = z.strictObject({
  name: z.string().min(1).max(80).optional(),
  role: securityRole.optional(),
  allowedPorts: ports.optional(),
  source: sourceInput.optional(),
  traps: z.boolean().optional(),
});
const selfPatch = z.strictObject({ role: securityRole.optional(), allowedPorts: ports.optional(), sudo: z.boolean().optional() });

const agentSecurityExposure = agentConfigSchema.shape.security.unwrap().shape.exposure;

const scannersPatch = z.strictObject({
  trivy: z.boolean().optional(),
  gitleaks: z.boolean().optional(),
  javaDb: z.boolean().optional(),
  registryAuth: z
    .array(z.strictObject({ registry: z.string().regex(/^[a-z0-9.-]+(:\d+)?$/), username: z.string().min(1).max(100), token: z.string().min(1).max(500).optional() }))
    .max(10)
    .optional(),
  github: z.strictObject({ owners: z.array(z.string().regex(/^[A-Za-z0-9-]{1,39}$/)).max(20), token: z.string().min(1).max(500).nullable().optional() }).optional(),
  loki: z
    .union([z.strictObject({ container: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/), port: z.number().int().min(1).max(65535).default(3100) }), z.strictObject({ url: z.url() })])
    .nullable()
    .optional(),
  localRoots: z.array(z.string().min(1).max(1024)).max(20).optional(),
  nightHours: z.tuple([z.number().int().min(0).max(23), z.number().int().min(0).max(24)]).optional(),
});

export function publicHost(h: SecurityHost) {
  const src = h.source.kind === "agent" ? { kind: "agent" as const, url: h.source.url, hasToken: true } : h.source;
  return { id: h.id, name: h.name, role: h.role, allowedPorts: h.allowedPorts, source: src, traps: h.traps };
}

function resolveSource(input: z.infer<typeof sourceInput>, prev: SecurityHost["source"] | null): SecurityHost["source"] {
  if (input.kind === "ssh") return input;
  const token = input.token ?? (prev?.kind === "agent" && prev.url === input.url ? prev.token : undefined);
  if (!token) throw new AppError("agent.security.tokenRequired", 400);
  return { kind: "agent", url: input.url, token };
}

export interface SecurityRouteOpts extends ServiceOpts {
  service?: SecurityService;
  vulnOpts?: VulnOpts;
  trapOpts?: TrapOpts;
  exposureOpts?: ExposureOpts;
  fetch?: typeof fetch;
  lockdownLimit?: RateLimit;
  secretOpts?: SecretOpts;
  startTimer?: boolean;
  checkLimit?: RateLimit;
  scanLimit?: RateLimit;
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

    // S-2 scanners (monitoring server): images of the audited hosts' running containers; secrets in repos/logs/local repos.
    const inventoryHosts = (): InventoryHost[] =>
      svc.hosts().flatMap((h) => {
        const r = svc.states.get(h.id)?.report;
        return r ? [{ hostId: h.id, host: h.name, kind: h.source, arch: r.meta.arch, report: r }] : [];
      });
    const vulns = new VulnScanner(ctx, inventoryHosts, opts.vulnOpts);
    const secrets = new SecretScanner(ctx, opts.secretOpts);
    await vulns.load();
    await secrets.load();
    const scanLimit = opts.scanLimit ?? new RateLimit(3, 10 * 60_000);
    const exposure = new ExposureScanner(ctx, opts.exposureOpts);
    await exposure.load();
    const cloudflare = new CloudflareWatch(ctx, opts.fetch ? { fetch: opts.fetch } : {});
    await cloudflare.load();

    // S-3 traps + critical relay to the owner's Telegram.
    const traps = new TrapService(ctx, { ...opts.trapOpts, spawner: opts.trapOpts?.spawner ?? opts.spawner });
    ctx.onRejectedToken = (t, i) => traps.onRejectedToken(t, i);
    const unobserve = ctx.notifier.observe(alertRelay(ctx));
    app.addHook("onClose", async () => {
      ctx.onRejectedToken = undefined;
      unobserve();
    });
    const background = (p: Promise<unknown>) => void p.catch((e) => app.log.warn({ code: e instanceof AppError ? e.code : "error" }, "güvenlik taraması başarısız"));
    if (opts.startTimer !== false) {
      const isNight = () => {
        const [from, to] = ctx.store.get().security.scanners.nightHours;
        const h = new Date().getHours();
        return from <= to ? h >= from && h < to : h >= from || h < to;
      };
      const scanTick = () => {
        const sc = ctx.store.get().security.scanners;
        if (!isNight()) return;
        if (sc.trivy && !vulns.running) background(vulns.tick());
        const last = secrets.state.lastRun ? Date.parse(secrets.state.lastRun.at) : 0;
        if ((sc.gitleaks || sc.localRoots.length) && !secrets.running && Date.now() - last > 20 * 3600_000) background(secrets.run());
        const ex = ctx.store.get().security.exposure;
        if (ex.enabled && ex.targets.length && !exposure.running && exposure.due()) background(exposure.run());
      };
      const t = setInterval(scanTick, 10 * 60_000);
      t.unref();
      const quiet = (p: Promise<unknown>) => void p.catch(() => {});
      let primed = false;
      const trapTick = () => {
        quiet(traps.checkFiles());
        if (!primed) {
          primed = true;
          quiet(traps.checkAudit(false));
        } else quiet(traps.checkAudit());
      };
      const t2 = setInterval(trapTick, 30_000);
      t2.unref();
      const t3 = setInterval(() => quiet(traps.checkDbUsers(() => lokiBaseUrl(ctx, opts.spawner))), 2 * 60_000);
      t3.unref();
      const t6 = setInterval(() => {
        if (ctx.store.get().security.cloudflare.readToken) quiet(cloudflare.run());
      }, 15 * 60_000);
      t6.unref();
      app.addHook("onClose", async () => clearInterval(t6));
      app.addHook("onClose", async () => {
        clearInterval(t);
        clearInterval(t2);
        clearInterval(t3);
      });
    }

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

    const imageParam = (req: { params: unknown }) => `sha256:${parse(z.object({ id: z.string().regex(/^[a-f0-9]{64}$/) }), req.params).id}`;
    const scannersOn = (k: "trivy" | "gitleaks") => {
      if (!ctx.store.get().security.scanners[k]) throw new AppError("agent.security.scannerOff", 409, { scanner: k });
    };

    app.get("/v1/security/vulns", async () => {
      await vulns.refresh();
      return { enabled: ctx.store.get().security.scanners.trivy, running: vulns.running, images: vulns.list() };
    });
    app.get("/v1/security/vulns/:id", async (req) => ({ image: vulns.get(imageParam(req)) }));
    app.post("/v1/security/vulns/scan", async (req, reply) => {
      scannersOn("trivy");
      const b = parse(z.strictObject({ imageId: z.string().regex(/^sha256:[a-f0-9]{64}$/).optional() }), req.body ?? {});
      req.auditDetail = b.imageId ? { image: b.imageId.slice(7, 19) } : { all: true };
      if (!scanLimit.take(req.device?.id ?? "-")) throw new AppError("agent.security.rateLimited", 429);
      if (b.imageId) {
        await vulns.refresh();
        return { image: await vulns.scanOne(b.imageId) };
      }
      if (vulns.running) throw new AppError("agent.security.scanBusy", 409);
      background(vulns.tick(true));
      reply.code(202);
      return { started: true };
    });

    app.get("/v1/security/secrets", async () => secrets.list());
    app.post("/v1/security/secrets/scan", async (req, reply) => {
      req.auditDetail = { all: true };
      if (!scanLimit.take(req.device?.id ?? "-")) throw new AppError("agent.security.rateLimited", 429);
      if (secrets.running) throw new AppError("agent.security.scanBusy", 409);
      background(secrets.run());
      reply.code(202);
      return { started: true };
    });
    app.post("/v1/security/secrets/:id/dismiss", async (req) => {
      const id = parse(z.object({ id: z.string().regex(/^[a-f0-9]{24}$/) }), req.params).id;
      const b = parse(z.strictObject({ dismissed: z.boolean() }), req.body);
      req.auditDetail = { finding: id, dismissed: b.dismissed };
      return { finding: await secrets.dismiss(id, b.dismissed) };
    });

    const publicScanners = () => {
      const sc = ctx.store.get().security.scanners;
      return {
        trivy: sc.trivy,
        gitleaks: sc.gitleaks,
        javaDb: sc.javaDb,
        registryAuth: sc.registryAuth.map((r) => ({ registry: r.registry, username: r.username, hasToken: true })),
        github: { owners: sc.github.owners, hasToken: sc.github.token !== null },
        loki: sc.loki,
        localRoots: sc.localRoots,
        nightHours: sc.nightHours,
      };
    };
    app.get("/v1/security/scanners", async () => ({ scanners: publicScanners() }));
    app.patch("/v1/security/scanners", async (req) => {
      const b = parse(scannersPatch, req.body);
      await ctx.store.update((c) => {
        const sc = c.security.scanners;
        if (b.trivy !== undefined) sc.trivy = b.trivy;
        if (b.gitleaks !== undefined) sc.gitleaks = b.gitleaks;
        if (b.javaDb !== undefined) sc.javaDb = b.javaDb;
        if (b.loki !== undefined) sc.loki = b.loki;
        if (b.localRoots !== undefined) sc.localRoots = b.localRoots;
        if (b.nightHours !== undefined) sc.nightHours = b.nightHours;
        if (b.github !== undefined) {
          // token: omitted = keep, null = remove, string = replace.
          sc.github = { owners: b.github.owners, token: b.github.token === undefined ? sc.github.token : b.github.token };
        }
        if (b.registryAuth !== undefined) {
          sc.registryAuth = b.registryAuth.map((r) => {
            const prev = sc.registryAuth.find((x) => x.registry === r.registry && x.username === r.username);
            const token = r.token ?? prev?.token;
            if (!token) throw new AppError("agent.security.tokenRequired", 400);
            return { registry: r.registry, username: r.username, token };
          });
        }
        return c;
      });
      req.auditDetail = { fields: Object.keys(b) };
      return { scanners: publicScanners() };
    });

    app.get("/v1/security/exposure", async () => ({
      config: ctx.store.get().security.exposure,
      running: exposure.running,
      last: exposure.runs[0] ?? null,
      history: exposure.runs.slice(0, 12).map((r) => ({ at: r.at, findings: r.findings.length })),
    }));
    app.post("/v1/security/exposure/run", async (req, reply) => {
      req.auditDetail = { exposure: true };
      if (!scanLimit.take(req.device?.id ?? "-")) throw new AppError("agent.security.rateLimited", 429);
      if (exposure.running) throw new AppError("agent.security.scanBusy", 409);
      background(exposure.run());
      reply.code(202);
      return { started: true };
    });
    app.put("/v1/security/exposure", async (req) => {
      const b = parse(z.strictObject({ enabled: z.boolean(), targets: z.array(z.unknown()).max(30), extraPorts: z.array(z.number().int().min(1).max(65535)).max(100).optional(), intervalDays: z.number().int().min(1).max(30).optional() }), req.body);
      await ctx.store.update((c) => {
        const next = { ...c.security.exposure, ...b };
        c.security = { ...c.security, exposure: parse(agentSecurityExposure, next) };
        return c;
      });
      req.auditDetail = { enabled: b.enabled, targets: b.targets.length };
      return { config: ctx.store.get().security.exposure };
    });

    app.get("/v1/security/attacks", async () => ({ configured: !!ctx.store.get().security.cloudflare.readToken, ...cloudflare.list() }));
    app.post("/v1/security/attacks/run", async (req) => {
      req.auditDetail = { cloudflare: true };
      if (!scanLimit.take(req.device?.id ?? "-")) throw new AppError("agent.security.rateLimited", 429);
      return cloudflare.run();
    });
    const publicCloudflare = () => {
      const c = ctx.store.get().security.cloudflare;
      return { hasReadToken: !!c.readToken, hasBlockToken: !!c.blockToken, block: c.block, blockHours: c.blockHours, zones: c.zones, allowIps: c.allowIps };
    };
    app.get("/v1/security/cloudflare", async () => publicCloudflare());
    app.put("/v1/security/cloudflare", async (req) => {
      const tok = z.string().min(1).max(200).nullable().optional();
      const b = parse(
        z.strictObject({
          readToken: tok,
          blockToken: tok,
          block: z.boolean().optional(),
          blockHours: z.number().int().min(1).max(720).optional(),
          zones: z.array(z.string().min(1).max(253)).max(50).optional(),
          allowIps: z.array(z.string().regex(/^[0-9a-fA-F:.]{3,45}$/)).max(50).optional(),
        }),
        req.body,
      );
      await ctx.store.update((c) => {
        const cur = c.security.cloudflare;
        // Tokens: omitted = keep, null = remove, string = replace.
        const next = { ...cur, ...Object.fromEntries(Object.entries(b).filter(([, v]) => v !== undefined)) };
        if (next.block && !next.blockToken) throw new AppError("agent.security.tokenRequired", 400);
        c.security.cloudflare = next as typeof cur;
        return c;
      });
      req.auditDetail = { fields: Object.keys(b) };
      return publicCloudflare();
    });

    app.get("/v1/security/traps", async () => traps.list());
    app.post("/v1/security/traps/tokens", async (req, reply) => {
      const b = parse(z.strictObject({ name: z.string().trim().min(1).max(80) }), req.body);
      const r = await traps.createToken(b.name);
      req.auditDetail = { trap: r.id };
      reply.code(201);
      // Shown once; plant it where an intruder would look (it opens nothing).
      return r;
    });
    app.delete("/v1/security/traps/tokens/:id", async (req) => {
      const id = parse(z.object({ id: hostId }), req.params).id;
      await traps.removeToken(id);
      req.auditDetail = { trap: id };
      return { ok: true };
    });
    app.post("/v1/security/traps/files", async (req, reply) => {
      const b = parse(z.strictObject({ path: z.string().min(1).max(1024), kind: z.enum(["env", "sshkey"]) }), req.body);
      const r = await traps.createFile(b.path, b.kind);
      req.auditDetail = { trap: r.id, kind: b.kind };
      reply.code(201);
      return r;
    });
    app.delete("/v1/security/traps/files/:id", async (req) => {
      const id = parse(z.object({ id: hostId }), req.params).id;
      await traps.removeFile(id);
      req.auditDetail = { trap: id };
      return { ok: true };
    });
    app.put("/v1/security/traps/db-users", async (req) => {
      const b = parse(z.strictObject({ users: z.array(z.string().regex(/^[a-z_][a-z0-9_]{2,62}$/)).max(10) }), req.body);
      await ctx.store.update((c) => ((c.security.traps.dbUsers = b.users), c));
      req.auditDetail = { count: b.users.length };
      return traps.list();
    });
    app.post("/v1/security/traps/test", async (req) => {
      req.auditDetail = { test: true };
      await ctx.notifier.send({ key: "security.trap", params: { host: ctx.store.get().name, agent: ctx.store.get().name, trap: "test" }, link: "tiphys://security/traps", priority: "high" });
      return { ok: true };
    });
    app.get("/v1/security/alerts", async () => ctx.store.get().security.alerts);
    app.put("/v1/security/alerts", async (req) => {
      const b = parse(z.strictObject({ telegramRecipient: z.string().min(1).max(64).nullable() }), req.body);
      await ctx.store.update((c) => ((c.security.alerts.telegramRecipient = b.telegramRecipient), c));
      req.auditDetail = { telegram: b.telegramRecipient !== null };
      return ctx.store.get().security.alerts;
    });

    // ---- S-4 black box ----
    const self = () => ctx.store.get().name;
    const bbMode = ctx.store.get().security.blackbox.mode; // read at start; a change needs a restart like features
    const box = bbMode === "local" ? new BlackBox(ctx.store.path) : null;
    const pusher = bbMode === "push" ? new BlackBoxPusher(ctx, opts.fetch) : null;
    if (box) await box.load();
    if (pusher) await pusher.load();
    const record = (kind: "audit" | "event" | "lockdown", data: Record<string, unknown>) => {
      if (box) void box.append(self(), kind, data).catch((e) => app.log.warn({ err: e }, "kara kutuya yazılamadı"));
      else if (pusher) pusher.push(kind, data);
    };
    if (box || pusher) {
      ctx.onAudit = (e) => record("audit", { ...e });
      const unobserveBox = ctx.notifier.observe((n) => {
        if (!n.sensitive) record("event", { key: n.key, params: n.params ?? {} });
      });
      app.addHook("onClose", async () => {
        ctx.onAudit = undefined;
        unobserveBox();
      });
    }
    let brokenNotified = false;
    const verifyBox = async () => {
      if (!box) return null;
      const v = await box.verify();
      if (!v.ok && !brokenNotified) {
        brokenNotified = true;
        await ctx.notifier.send({ key: "blackbox.broken", params: { host: self(), agent: self(), at: v.brokenAt ?? 0, reason: v.reason ?? "" }, link: "tiphys://security/blackbox", priority: "high" });
      }
      if (v.ok) brokenNotified = false;
      return v;
    };
    const anchorBox = async () => {
      if (!box) return;
      const day = new Date().toLocaleDateString("sv");
      if ((await box.anchors()).some((a) => a.date === day)) return;
      const v = await verifyBox();
      if (!v?.ok) return;
      const sent = await sendOwnerTelegram(ctx, `🔗 Tiphys kara kutu · ${self().replace(/[<>&]/g, "")} · ${day} · ${v.count} kayıt · ${v.head.slice(0, 16)}`, opts.fetch ? { fetch: opts.fetch } : {}).catch(() => false);
      await box.addAnchor({ date: day, count: v.count, hash: v.head, telegram: sent });
    };
    if (opts.startTimer !== false && (box || pusher)) {
      const t4 = setInterval(() => {
        if (pusher) void pusher.flush().catch(() => {});
      }, 30_000);
      t4.unref();
      const t5 = setInterval(() => {
        void verifyBox().catch(() => {});
        if (new Date().getHours() === 3) void anchorBox().catch(() => {});
      }, 3600_000);
      t5.unref();
      app.addHook("onClose", async () => {
        clearInterval(t4);
        clearInterval(t5);
        if (pusher) await pusher.flush().catch(() => 0);
      });
    }

    app.get("/v1/blackbox/status", async () => ({
      mode: bbMode,
      head: box?.head ?? null,
      pending: pusher?.pending ?? null,
      lastError: pusher?.lastError ?? null,
      lastSentAt: pusher?.lastSentAt ?? null,
      url: ctx.store.get().security.blackbox.url,
    }));
    app.get("/v1/blackbox/verify", async () => {
      if (!box) throw new AppError("agent.blackbox.notLocal", 409);
      const v = await verifyBox();
      // Anchors on file (and in the owner's Telegram) must still be in the chain.
      const anchors = await box.anchors();
      const recent = new Map((await box.recent(100_000)).map((r) => [r.seq, r.hash]));
      const anchorMismatch = anchors.filter((a) => recent.has(a.count) && recent.get(a.count) !== a.hash).map((a) => a.date);
      return { ...v, anchors, anchorMismatch };
    });
    app.get("/v1/blackbox/recent", async (req) => {
      if (!box) throw new AppError("agent.blackbox.notLocal", 409);
      const q = parse(z.object({ limit: z.coerce.number().int().min(1).max(500).default(100) }), req.query);
      return { records: await box.recent(q.limit) };
    });
    app.post("/v1/blackbox/anchor", async (req) => {
      if (!box) throw new AppError("agent.blackbox.notLocal", 409);
      req.auditDetail = { anchor: true };
      await anchorBox();
      return { anchors: await box.anchors() };
    });
    const appendLimit = new RateLimit(60, 60_000);
    app.post("/v1/blackbox/append", { config: { scope: "blackbox" }, bodyLimit: 1024 * 1024 }, async (req) => {
      if (!box) throw new AppError("agent.blackbox.notLocal", 409);
      if (!req.service) throw new AppError("agent.auth.scopeDenied", 403);
      if (!appendLimit.take(req.service.id)) throw new AppError("agent.security.rateLimited", 429);
      const b = parse(
        z.strictObject({
          entries: z.array(z.strictObject({ at: z.string().max(40), kind: z.enum(["audit", "event", "lockdown"]), data: z.record(z.string(), z.unknown()) })).max(200),
          dropped: z.number().int().min(0).optional(),
        }),
        req.body,
      );
      // The source is who authenticated, never what the sender claims.
      const source = `service:${req.service.name}`;
      if (b.dropped) await box.append(source, "event", { key: "blackbox.dropped", params: { count: b.dropped } });
      for (const e of b.entries) await box.append(source, e.kind, { ...e.data, sentAt: e.at });
      return { accepted: b.entries.length, head: box.head };
    });

    // ---- S-4 lost phone: recovery code + lockdown ----
    app.post("/v1/security/recovery", async (req) => {
      parse(z.strictObject({ confirm: z.literal(true) }), req.body);
      const code = newRecoveryCode();
      const salt = randomBytes(16);
      const hash = (await hashCode(code, salt)).toString("hex");
      await ctx.store.update((c) => ((c.security.recovery = { salt: salt.toString("hex"), hash, createdAt: new Date().toISOString() }), c));
      req.auditDetail = { recovery: "created" };
      record("lockdown", { action: "recoveryCodeCreated", device: req.device?.id ?? null });
      return { code, createdAt: ctx.store.get().security.recovery!.createdAt };
    });
    app.get("/v1/security/recovery", async () => ({ configured: !!ctx.store.get().security.recovery, createdAt: ctx.store.get().security.recovery?.createdAt ?? null }));

    const lockdownLimit = opts.lockdownLimit ?? new RateLimit(5, 3600_000);
    app.post("/v1/security/lockdown", { config: { public: true }, bodyLimit: 4096 }, async (req) => {
      // Unauthenticated by design (the phone is lost): only the recovery code opens it; 5 tries an hour in total.
      if (!lockdownLimit.take("all")) throw new AppError("agent.security.rateLimited", 429);
      const body = (req.body ?? {}) as { code?: unknown };
      const code = assertCodeShape(body.code);
      const stored = ctx.store.get().security.recovery;
      if (!stored || !(await codeMatches(code, stored))) {
        record("lockdown", { action: "badRecoveryCode", ip: req.ip });
        throw new AppError("agent.security.badRecoveryCode", 401);
      }
      await ctx.notifier.send({ key: "security.lockdown", params: { host: self(), agent: self(), by: "recovery" }, link: "tiphys://security", priority: "high" });
      const targets = await fanOut(ctx, opts.fetch);
      await revokeAll(ctx);
      record("lockdown", { action: "lockdown", by: "recovery", ip: req.ip, targets: targets.map((t) => `${t.name}:${t.ok ? "ok" : (t.status ?? "unreachable")}`) });
      req.auditDetail = { lockdown: true, targets: targets.length, failed: targets.filter((t) => !t.ok).length };
      return { ok: true, targets };
    });
    app.post("/v1/security/lockdown/remote", { config: { scope: "lockdown" } }, async (req) => {
      parse(z.strictObject({ confirm: z.literal(true) }), req.body);
      const by = req.service ? `service:${req.service.name}` : `device:${req.device?.id}`;
      await ctx.notifier.send({ key: "security.lockdown", params: { host: self(), agent: self(), by: "remote" }, link: "tiphys://security", priority: "high" });
      record("lockdown", { action: "lockdown", by });
      await revokeAll(ctx);
      req.auditDetail = { lockdown: true };
      return { ok: true };
    });
    app.get("/v1/security/lockdown/targets", async () => ({ targets: ctx.store.get().security.lockdownTargets.map(({ token: _, ...t }) => ({ ...t, hasToken: true })) }));
    app.post("/v1/security/lockdown/targets", async (req, reply) => {
      const b = parse(z.strictObject({ id: hostId, name: z.string().min(1).max(80), url: z.url({ protocol: /^https$/ }), token: z.string().regex(/^tps_[A-Za-z0-9_-]{20,}$/) }), req.body);
      await ctx.store.update((c) => {
        if (c.security.lockdownTargets.some((t) => t.id === b.id)) throw new AppError("agent.security.hostExists", 409, { id: b.id });
        if (c.security.lockdownTargets.length >= 20) throw new AppError("agent.security.tooManyHosts", 409);
        c.security.lockdownTargets.push(b);
        return c;
      });
      req.auditDetail = { target: b.id };
      reply.code(201);
      return { target: { id: b.id, name: b.name, url: b.url, hasToken: true } };
    });
    app.delete("/v1/security/lockdown/targets/:id", async (req) => {
      const id = parse(z.object({ id: hostId }), req.params).id;
      await ctx.store.update((c) => ((c.security.lockdownTargets = c.security.lockdownTargets.filter((t) => t.id !== id)), c));
      req.auditDetail = { target: id };
      return { ok: true };
    });
    app.put("/v1/blackbox/settings", async (req) => {
      const b = parse(
        z.strictObject({ mode: z.enum(["off", "local", "push"]), url: z.url({ protocol: /^https$/ }).nullable().optional(), token: z.string().regex(/^tps_[A-Za-z0-9_-]{20,}$/).nullable().optional() }),
        req.body,
      );
      await ctx.store.update((c) => {
        const cur = c.security.blackbox;
        const url = b.url === undefined ? cur.url : b.url;
        // The token is kept only while the URL stays the same.
        const token = b.token !== undefined ? b.token : url === cur.url ? cur.token : null;
        if (b.mode === "push" && (!url || !token)) throw new AppError("agent.security.tokenRequired", 400);
        c.security.blackbox = { mode: b.mode, url, token };
        return c;
      });
      req.auditDetail = { mode: b.mode };
      return { mode: b.mode, url: ctx.store.get().security.blackbox.url, hasToken: !!ctx.store.get().security.blackbox.token, restartRequired: b.mode !== bbMode };
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
        if (b.traps !== undefined) h.traps = b.traps;
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
