// Lost phone (PLAN.md §15 S-4). A recovery code (shown once, stored as a scrypt hash) lets any device in the tailnet
// lock everything without a paired token: POST /v1/security/lockdown {code} on the monitoring server revokes all
// devices, service tokens and push endpoints there and fans out to every agent in security.lockdownTargets (each has
// given this server a "lockdown" service token). `tiphys-agent lockdown --url …` does the same from a terminal.
// Afterwards pair again (tiphys-agent pair) on each machine.
// Note: scrypt (N=2^15, r=8, p=1) instead of the planned Argon2: Node ships scrypt, Argon2 would need a native module.
import { randomBytes, scrypt as scryptCb, timingSafeEqual } from "node:crypto";
import { promisify } from "node:util";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import type { Fetch } from "./collect.ts";

const scrypt = promisify(scryptCb) as (pw: string, salt: Buffer, len: number, o: { N: number; r: number; p: number; maxmem: number }) => Promise<Buffer>;
const PARAMS = { N: 1 << 15, r: 8, p: 1, maxmem: 64 * 1024 * 1024 };

/** 5 groups of 5 from an unambiguous alphabet (~125 bits). */
export function newRecoveryCode(): string {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const b = randomBytes(25);
  const chars = [...b].map((x) => alphabet[x % 32]);
  return [0, 5, 10, 15, 20].map((i) => chars.slice(i, i + 5).join("")).join("-");
}

export const normalizeCode = (c: string) => c.toUpperCase().replace(/[^A-Z0-9]/g, "");

export async function hashCode(code: string, salt: Buffer): Promise<Buffer> {
  return scrypt(normalizeCode(code), salt, 32, PARAMS);
}

export async function codeMatches(code: string, stored: { salt: string; hash: string }): Promise<boolean> {
  const h = await hashCode(code, Buffer.from(stored.salt, "hex"));
  return timingSafeEqual(h, Buffer.from(stored.hash, "hex"));
}

/** Revokes every device, service token and push endpoint of this agent (like "Lock everything"). */
export async function revokeAll(ctx: Ctx) {
  await ctx.store.update((c) => {
    c.devices = [];
    c.serviceTokens = [];
    c.push.endpoints = [];
    return c;
  });
}

export async function fanOut(ctx: Ctx, f: Fetch = fetch): Promise<Array<{ id: string; name: string; ok: boolean; status: number | null }>> {
  const targets = ctx.store.get().security.lockdownTargets;
  return Promise.all(
    targets.map(async (t) => {
      const res = await f(new URL("/v1/security/lockdown/remote", t.url).toString(), {
        method: "POST",
        headers: { authorization: `Bearer ${t.token}`, "content-type": "application/json" },
        body: JSON.stringify({ confirm: true }),
        signal: AbortSignal.timeout(15_000),
        redirect: "error",
      }).catch(() => null);
      return { id: t.id, name: t.name, ok: !!res?.ok, status: res?.status ?? null };
    }),
  );
}

export function assertCodeShape(code: unknown): string {
  if (typeof code !== "string" || normalizeCode(code).length !== 25) throw new AppError("agent.security.badRecoveryCode", 401);
  return code;
}
