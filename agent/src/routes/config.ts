// Ajanın kendi ayarları ve eşleşmiş cihazlar. Telefon bunları Ayarlar ekranından düzenler.
// Gizli değerler (token özetleri, şifreler) asla geri gönderilmez.
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { agentConfigSchema, type AgentConfig } from "../config.ts";
import { AppError, notFound } from "../errors.ts";
import type { Ctx } from "../server.ts";

export function redact(c: AgentConfig) {
  return {
    name: c.name,
    features: c.features,
    requireTailscaleLogin: c.requireTailscaleLogin,
    allowedRoots: c.allowedRoots,
    claude: c.claude,
    homepage: c.homepage,
    push: { endpoints: c.push.endpoints.map((e) => ({ deviceId: e.deviceId })), hasToken: c.push.token !== null },
    uptimeKuma: c.uptimeKuma ? { url: c.uptimeKuma.url, username: c.uptimeKuma.username, hasPassword: true } : null,
    wake: c.wake,
    watch: c.watch,
    alerts: { ...c.alerts, grafana: c.alerts.grafana ? { url: c.alerts.grafana.url, datasourceUids: c.alerts.grafana.datasourceUids, hasToken: true } : null },
    transcribe: c.transcribe,
    devices: c.devices.map(({ id, name, createdAt }) => ({ id, name, createdAt })),
  };
}

const shape = agentConfigSchema.shape;
/** Telefonun değiştirebildiği alanlar. Cihaz listesi ve dinleme adresi buradan değişmez. */
const patchSchema = z.strictObject({
  name: shape.name.optional(),
  features: shape.features.partial().optional(),
  allowedRoots: shape.allowedRoots.optional(),
  claude: shape.claude.optional(),
  homepage: shape.homepage.optional(),
  pushToken: z.string().min(1).nullable().optional(),
  uptimeKuma: z
    .strictObject({ url: z.url(), username: z.string().min(1), password: z.string().min(1).optional() })
    .nullable()
    .optional(),
  wake: shape.wake.optional(),
  watch: shape.watch.optional(),
  alerts: z
    .strictObject({
      intervalSeconds: z.number().int().min(30),
      diskFullPercent: z.number().int().min(50).max(100),
      failedServices: z.boolean(),
      grafana: z
        .strictObject({ url: z.url(), token: z.string().min(1).optional(), datasourceUids: z.array(z.string()) })
        .nullable(),
    })
    .optional(),
  transcribe: shape.transcribe.optional(),
});

export function configRoutes(app: FastifyInstance, ctx: Ctx) {
  app.get("/v1/config", async () => redact(ctx.store.get()));

  app.patch("/v1/config", async (req) => {
    const p = patchSchema.parse(req.body);
    const next = await ctx.store.update((c) => {
      if (p.name !== undefined) c.name = p.name;
      if (p.features) c.features = { ...c.features, ...p.features };
      if (p.allowedRoots) c.allowedRoots = p.allowedRoots;
      if (p.claude) c.claude = p.claude;
      if (p.homepage) c.homepage = p.homepage;
      if (p.pushToken !== undefined) c.push.token = p.pushToken;
      if (p.uptimeKuma === null) c.uptimeKuma = null;
      else if (p.uptimeKuma) {
        const password = p.uptimeKuma.password ?? c.uptimeKuma?.password;
        if (!password) throw new AppError("agent.config.passwordRequired", 400, { field: "uptimeKuma.password" });
        c.uptimeKuma = { url: p.uptimeKuma.url, username: p.uptimeKuma.username, password };
      }
      if (p.wake) c.wake = p.wake;
      if (p.watch) c.watch = p.watch;
      if (p.transcribe) c.transcribe = p.transcribe;
      if (p.alerts) {
        const g = p.alerts.grafana;
        const token = g ? (g.token ?? c.alerts.grafana?.token) : undefined;
        if (g && !token) throw new AppError("agent.config.passwordRequired", 400, { field: "alerts.grafana.token" });
        c.alerts = { ...p.alerts, grafana: g ? { url: g.url, token: token!, datasourceUids: g.datasourceUids } : null };
      }
      return c;
    });
    return { config: redact(next), restartRequired: p.features !== undefined || p.alerts !== undefined };
  });

  app.get("/v1/devices", async () => ({ devices: redact(ctx.store.get()).devices }));

  app.delete("/v1/devices/:id", async (req) => {
    const id = (req.params as Record<string, string>).id;
    if (!ctx.store.get().devices.some((d) => d.id === id)) throw notFound("device", { id });
    await ctx.store.update((c) => {
      c.devices = c.devices.filter((d) => d.id !== id);
      c.push.endpoints = c.push.endpoints.filter((e) => e.deviceId !== id);
      return c;
    });
    return { ok: true };
  });

  // "Her şeyi kilitle": tüm cihazların token'ları iptal edilir (bu istek dahil).
  app.post("/v1/devices/revoke-all", async (req) => {
    if (!z.object({ confirm: z.literal(true) }).safeParse(req.body).success) {
      throw new AppError("agent.devices.confirmRequired", 400);
    }
    await ctx.store.update((c) => {
      c.devices = [];
      c.push.endpoints = [];
      return c;
    });
    return { ok: true };
  });

  app.put("/v1/push/endpoint", async (req) => {
    const { url, pubKey, auth } = z
      .object({ url: z.url(), pubKey: z.string().regex(/^[A-Za-z0-9_-]{40,200}$/).optional(), auth: z.string().regex(/^[A-Za-z0-9_-]{10,60}$/).optional() })
      .parse(req.body);
    const deviceId = req.device!.id;
    await ctx.store.update((c) => {
      c.push.endpoints = [...c.push.endpoints.filter((e) => e.deviceId !== deviceId), { deviceId, url, ...(pubKey && auth ? { pubKey, auth } : {}) }];
      return c;
    });
    return { ok: true };
  });

  app.post("/v1/push/test", async (req) => {
    const sent = await ctx.notifier.send({ key: "push.test", params: { device: req.device!.name } });
    return { sent };
  });
}
