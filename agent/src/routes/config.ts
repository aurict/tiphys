// The agent's own settings and paired devices. The phone edits these from the Settings screen.
// Secret values (token hashes, passwords) are never sent back.
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
    sunshine: c.sunshine ? { url: c.sunshine.url, username: c.sunshine.username, hasPassword: true } : null,
    wake: c.wake,
    watch: c.watch,
    alerts: { ...c.alerts, grafana: c.alerts.grafana ? { url: c.alerts.grafana.url, datasourceUids: c.alerts.grafana.datasourceUids, hasToken: true } : null },
    transcribe: c.transcribe,
    backups: c.backups,
    desktop: c.desktop,
    telegram: c.telegram ? { configured: true, username: c.telegram.botUsername } : null,
    research: c.research ? { url: c.research.url, wakeHostId: c.research.wakeHostId ?? null, hasToken: true } : null,
    devices: c.devices.map(({ id, name, createdAt }) => ({ id, name, createdAt })),
  };
}

const shape = agentConfigSchema.shape;
/** Fields the phone can change. The device list and listen address can't be changed from here. */
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
  sunshine: z
    .strictObject({ url: z.url({ protocol: /^https$/ }).optional(), username: z.string().min(1).max(128), password: z.string().min(1).max(256).optional() })
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
  desktop: z.strictObject({ clipboardSync: z.boolean() }).optional(),
  backups: z.strictObject({ checks: shape.backups.unwrap().shape.checks }).optional(),
  research: z
    .strictObject({ url: z.url({ protocol: /^https?$/ }), token: z.string().min(1).max(200).optional(), wakeHostId: z.string().nullable().optional() })
    .nullable()
    .optional(),
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
        // When the address changes the old password mustn't be sent to the new address: it's asked for again.
        const password = p.uptimeKuma.password ?? (p.uptimeKuma.url === c.uptimeKuma?.url ? c.uptimeKuma?.password : undefined);
        if (!password) throw new AppError("agent.config.passwordRequired", 400, { field: "uptimeKuma.password" });
        c.uptimeKuma = { url: p.uptimeKuma.url, username: p.uptimeKuma.username, password };
      }
      // Sunshine: if no password is sent the old one stays (the phone never sees it back); the setting is read per request.
      if (p.sunshine === null) c.sunshine = null;
      else if (p.sunshine) {
        const url = p.sunshine.url ?? c.sunshine?.url ?? "https://127.0.0.1:47990";
        const password = p.sunshine.password ?? (url === c.sunshine?.url ? c.sunshine?.password : undefined);
        if (!password) throw new AppError("agent.config.passwordRequired", 400, { field: "sunshine.password" });
        c.sunshine = { url, username: p.sunshine.username, password };
      }
      if (p.wake) c.wake = p.wake;
      if (p.watch) c.watch = p.watch;
      if (p.transcribe) c.transcribe = p.transcribe;
      // The clipboard watcher reads the setting on every change: no restart needed.
      if (p.desktop) c.desktop = p.desktop;
      // Checks read the setting every round: no restart needed.
      if (p.backups) c.backups = p.backups;
      // Research PC (telegram feature): read on every run. The token is kept only while the URL stays the same.
      if (p.research === null) c.research = null;
      else if (p.research) {
        const token = p.research.token ?? (p.research.url === c.research?.url ? c.research?.token : undefined);
        if (!token) throw new AppError("agent.config.passwordRequired", 400, { field: "research.token" });
        const wakeHostId = p.research.wakeHostId === undefined ? c.research?.wakeHostId : (p.research.wakeHostId ?? undefined);
        c.research = { url: p.research.url, token, ...(wakeHostId ? { wakeHostId } : {}) };
      }
      if (p.alerts) {
        const g = p.alerts.grafana;
        const token = g ? (g.token ?? (g.url === c.alerts.grafana?.url ? c.alerts.grafana?.token : undefined)) : undefined;
        if (g && !token) throw new AppError("agent.config.passwordRequired", 400, { field: "alerts.grafana.token" });
        c.alerts = { ...p.alerts, grafana: g ? { url: g.url, token: token!, datasourceUids: g.datasourceUids } : null };
      }
      return c;
    });
    // Remote control turned off: an open session (live screen, Claude's PC tools) ends immediately.
    if (p.features?.control === false) await ctx.control?.end("stopped");
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

  // "Lock everything": all devices' tokens and service tokens are revoked (including this request's).
  app.post("/v1/devices/revoke-all", async (req) => {
    if (!z.object({ confirm: z.literal(true) }).safeParse(req.body).success) {
      throw new AppError("agent.devices.confirmRequired", 400);
    }
    await ctx.store.update((c) => {
      c.devices = [];
      c.serviceTokens = [];
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
