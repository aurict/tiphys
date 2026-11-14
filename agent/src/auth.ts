// Cihaz token'ları: telefon eşleşirken bir kez alır; ajan sadece SHA-256 özetini saklar.
import { createHash, randomBytes, timingSafeEqual } from "node:crypto";
import type { FastifyRequest } from "fastify";
import { AppError } from "./errors.ts";
import type { AgentConfig, Device } from "./config.ts";

export const TOKEN_PREFIX = "tph_";

export function newToken(): string {
  return TOKEN_PREFIX + randomBytes(32).toString("base64url");
}

export function hashToken(token: string): string {
  return createHash("sha256").update(token, "utf8").digest("hex");
}

export function findDevice(config: AgentConfig, token: string): Device | undefined {
  const hash = Buffer.from(hashToken(token), "hex");
  return config.devices.find((d) => timingSafeEqual(Buffer.from(d.tokenHash, "hex"), hash));
}

/** İsteği doğrular; geçerliyse cihazı döner, değilse AppError fırlatır. */
export function authenticate(config: AgentConfig, req: FastifyRequest): Device {
  if (config.requireTailscaleLogin !== null) {
    const login = req.headers["tailscale-user-login"];
    if (login !== config.requireTailscaleLogin) {
      throw new AppError("agent.auth.tailnetUserNotAllowed", 403);
    }
  }
  const header = req.headers.authorization;
  const match = typeof header === "string" ? /^Bearer (\S+)$/.exec(header) : null;
  // Tarayıcıların WebSocket'e başlık ekleyememesi nedeniyle token sorgu parametresiyle de gelebilir.
  const token = match?.[1] ?? (req.query as Record<string, unknown> | undefined)?.["token"];
  if (typeof token !== "string" || !token.startsWith(TOKEN_PREFIX)) {
    throw new AppError("agent.auth.missingToken", 401);
  }
  const device = findDevice(config, token);
  if (!device) throw new AppError("agent.auth.invalidToken", 401);
  return device;
}
