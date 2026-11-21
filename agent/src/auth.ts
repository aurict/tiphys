// Device tokens: the phone receives one once while pairing; the agent stores only its SHA-256 hash.
// Service tokens (tps_…): issued for another agent (e.g. atlas's research client), stored hashed the same way,
// and accepted only on routes that declare one of the token's scopes (route config `{ scope: "research" }`).
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { FastifyRequest } from "fastify";
import { AppError } from "./errors.ts";
import type { AgentConfig, ConfigStore, Device, ServiceToken } from "./config.ts";

export const TOKEN_PREFIX = "tph_";
export const SERVICE_TOKEN_PREFIX = "tps_";

export function newToken(): string {
  return TOKEN_PREFIX + randomBytes(32).toString("base64url");
}

export function newServiceToken(): string {
  return SERVICE_TOKEN_PREFIX + randomBytes(32).toString("base64url");
}

export function hashToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

function sameHash(stored: string, hash: Buffer): boolean {
  return timingSafeEqual(Buffer.from(stored, "hex"), hash);
}

export function findDevice(config: AgentConfig, token: string): Device | undefined {
  const hash = Buffer.from(hashToken(token), "hex");
  return config.devices.find((d) => sameHash(d.tokenHash, hash));
}

export function findServiceToken(config: AgentConfig, token: string): ServiceToken | undefined {
  const hash = Buffer.from(hashToken(token), "hex");
  return config.serviceTokens.find((t) => sameHash(t.tokenHash, hash));
}

export type Caller = { device: Device; service?: undefined } | { device?: undefined; service: ServiceToken };

/**
 * Validates the request. Device tokens open every route; a service token opens only routes whose
 * `scope` it holds (a route may list several; anything else: 403 agent.auth.scopeDenied). Throws AppError on failure.
 */
export function authenticate(config: AgentConfig, req: FastifyRequest, routeScope?: string | readonly string[]): Caller {
  if (config.requireTailscaleLogin !== null) {
    const login = req.headers["tailscale-user-login"];
    if (login !== config.requireTailscaleLogin) {
      throw new AppError("agent.auth.tailnetUserNotAllowed", 403);
    }
  }
  const header = req.headers.authorization;
  const match = typeof header === "string" ? /^Bearer (\S+)$/.exec(header) : null;
  // Because browsers can't add headers to a WebSocket, a device token may also come as a query parameter.
  const token = match?.[1] ?? (req.query as Record<string, unknown> | undefined)?.["token"];
  if (typeof token === "string" && token.startsWith(SERVICE_TOKEN_PREFIX) && match) {
    const service = findServiceToken(config, token);
    if (!service) throw new AppError("agent.auth.invalidToken", 401);
    const want: readonly string[] = routeScope === undefined ? [] : typeof routeScope === "string" ? [routeScope] : routeScope;
    if (!want.some((s) => (service.scopes as string[]).includes(s))) throw new AppError("agent.auth.scopeDenied", 403);
    return { service };
  }
  if (typeof token !== "string" || !token.startsWith(TOKEN_PREFIX)) {
    throw new AppError("agent.auth.missingToken", 401);
  }
  const device = findDevice(config, token);
  if (!device) throw new AppError("agent.auth.invalidToken", 401);
  return { device };
}

const lastReload = new WeakMap<ConfigStore, number>();

/**
 * authenticate() against the store; on an unknown token the settings file is re-read (at most once per second per
 * store) in case another process just paired that device (`tiphys-agent pair`), then checked once more.
 */
export async function authenticateFresh(store: ConfigStore, req: FastifyRequest, routeScope?: string | readonly string[]): Promise<Caller> {
  try {
    return authenticate(store.get(), req, routeScope);
  } catch (e) {
    if (!(e instanceof AppError) || e.code !== "agent.auth.invalidToken") throw e;
    const now = Date.now();
    if (now - (lastReload.get(store) ?? 0) < 1000) throw e;
    lastReload.set(store, now);
    if (!(await store.reloadIfChanged().catch(() => false))) throw e;
    return authenticate(store.get(), req, routeScope);
  }
}
