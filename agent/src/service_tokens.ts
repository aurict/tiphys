// Scoped service tokens (tps_…) for other agents (e.g. atlas starting research jobs on the PC).
// The token is shown once at creation; only its hash is stored. Managed by the CLI and by device-only routes.
import { randomBytes } from "node:crypto";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { hashToken, newServiceToken } from "./auth.ts";
import { SERVICE_SCOPES, type ConfigStore, type ServiceScope, type ServiceToken } from "./config.ts";
import { notFound } from "./errors.ts";
import type { Ctx } from "./server.ts";

/** lastUsedAt is written at most this often, so a polling client doesn't rewrite agent.json on every request. */
const TOUCH_INTERVAL_MS = 60 * 60 * 1000;

export function publicServiceToken({ tokenHash: _, ...rest }: ServiceToken) {
  return rest;
}

export async function createServiceToken(store: ConfigStore, name: string, scopes: ServiceScope[]) {
  const token = newServiceToken();
  const slug = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 40) || "service";
  const id = `${slug}-${randomBytes(3).toString("hex")}`;
  const entry: ServiceToken = { id, name, scopes, tokenHash: hashToken(token), createdAt: new Date().toISOString() };
  await store.update((c) => {
    c.serviceTokens.push(entry);
    return c;
  });
  return { token, serviceToken: publicServiceToken(entry) };
}

export async function revokeServiceToken(store: ConfigStore, id: string): Promise<boolean> {
  if (!store.get().serviceTokens.some((t) => t.id === id)) return false;
  await store.update((c) => {
    c.serviceTokens = c.serviceTokens.filter((t) => t.id !== id);
    return c;
  });
  return true;
}

/** Records the last use (throttled); a write error is only logged by the caller. */
export async function touchServiceToken(store: ConfigStore, id: string, now = Date.now()): Promise<void> {
  const t = store.get().serviceTokens.find((x) => x.id === id);
  if (!t || (t.lastUsedAt && now - Date.parse(t.lastUsedAt) < TOUCH_INTERVAL_MS)) return;
  await store.update((c) => {
    const x = c.serviceTokens.find((y) => y.id === id);
    if (x) x.lastUsedAt = new Date(now).toISOString();
    return c;
  });
}

const USAGE = `kullanım: tiphys-agent service-token create --name AD --scope ${SERVICE_SCOPES.join("|")} | list | revoke <id>`;

/** `tiphys-agent service-token …`; returns the lines to print (the token is printed once, at creation). */
export async function serviceTokenCli(store: ConfigStore, positionals: string[], o: { name?: string; scopes: string[] }): Promise<string[]> {
  const [action, arg] = positionals;
  if (action === "create") {
    const scopes = [...new Set(o.scopes)];
    const valid = (s: string): s is ServiceScope => (SERVICE_SCOPES as readonly string[]).includes(s);
    const name = o.name?.trim();
    if (!name || name.length > 80 || scopes.length === 0 || !scopes.every(valid)) throw new Error(USAGE);
    const { token, serviceToken: t } = await createServiceToken(store, name, scopes);
    return [`Hizmet belirteci eklendi: ${t.name} (${t.id}), kapsam: ${t.scopes.join(",")}`, `Belirteç: ${token}`, "Belirteç bir daha gösterilmez; ajan sadece özetini saklar."];
  }
  if (action === "list") {
    return store.get().serviceTokens.map((t) => `${t.id}\t${t.name}\t${t.scopes.join(",")}\t${t.createdAt}\t${t.lastUsedAt ?? "-"}`);
  }
  if (action === "revoke" && arg) {
    if (!(await revokeServiceToken(store, arg))) throw new Error(`bulunamadı: ${arg}`);
    return [`İptal edildi: ${arg}`];
  }
  throw new Error(USAGE);
}

const createSchema = z.strictObject({
  name: z.string().trim().min(1).max(80),
  scopes: z.array(z.enum(SERVICE_SCOPES)).min(1).max(SERVICE_SCOPES.length),
});

/** Routes for the app; service tokens can't call them (no route scope). */
export function serviceTokenRoutes(app: FastifyInstance, ctx: Ctx) {
  app.get("/v1/service-tokens", async () => ({ tokens: ctx.store.get().serviceTokens.map(publicServiceToken) }));

  app.post("/v1/service-tokens", async (req, reply) => {
    const body = createSchema.parse(req.body);
    const created = await createServiceToken(ctx.store, body.name, [...new Set(body.scopes)]);
    void ctx.notifier.events?.record(
      { key: "serviceToken.created", params: { id: created.serviceToken.id, name: body.name, scopes: body.scopes.join(",") }, device: req.device?.id },
      (err) => req.log.warn({ err }, "olay yazılamadı"),
    );
    return reply.status(201).send(created);
  });

  app.delete("/v1/service-tokens/:id", async (req) => {
    const id = (req.params as Record<string, string>).id ?? "";
    if (!(await revokeServiceToken(ctx.store, id))) throw notFound("serviceToken", { id });
    void ctx.notifier.events?.record({ key: "serviceToken.revoked", params: { id }, device: req.device?.id }, (err) =>
      req.log.warn({ err }, "olay yazılamadı"),
    );
    return { ok: true };
  });
}
