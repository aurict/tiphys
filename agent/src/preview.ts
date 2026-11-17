// Preview tokens (PLAN.md §13.0): a risky operation is first previewed, and the preview returns a tpv_ token bound to
// the device, the operation kind and a SHA-256 of its input. The execute route must present the same token with
// confirm: true; a token is valid for 120 s and only once. Kept in memory only (an agent restart voids them).
import { createHash, randomBytes } from "node:crypto";
import { AppError } from "./errors.ts";

export const PREVIEW_PREFIX = "tpv_";
const TTL_MS = 120_000;
const MAX_LIVE = 1000;

/** JSON with sorted object keys, so the same input always hashes the same. */
export function stableJson(v: unknown): string {
  if (Array.isArray(v)) return `[${v.map(stableJson).join(",")}]`;
  if (v && typeof v === "object") {
    return `{${Object.keys(v)
      .sort()
      .filter((k) => (v as Record<string, unknown>)[k] !== undefined)
      .map((k) => `${JSON.stringify(k)}:${stableJson((v as Record<string, unknown>)[k])}`)
      .join(",")}}`;
  }
  return JSON.stringify(v) ?? "null";
}

export const inputHash = (input: unknown) => createHash("sha256").update(stableJson(input)).digest("hex");

interface Entry {
  device: string;
  kind: string;
  hash: string;
  expiresAt: number;
}

export class PreviewTokens {
  #live = new Map<string, Entry>();
  #now: () => number;
  #ttlMs: number;

  constructor(o: { now?: () => number; ttlMs?: number } = {}) {
    this.#now = o.now ?? Date.now;
    this.#ttlMs = o.ttlMs ?? TTL_MS;
  }

  issue(device: string, kind: string, input: unknown): { previewToken: string; expiresAt: string } {
    const now = this.#now();
    for (const [t, e] of this.#live) if (e.expiresAt <= now) this.#live.delete(t);
    // Oldest first: Map keeps insertion order.
    while (this.#live.size >= MAX_LIVE) this.#live.delete(this.#live.keys().next().value!);
    const token = PREVIEW_PREFIX + randomBytes(32).toString("base64url");
    const expiresAt = now + this.#ttlMs;
    this.#live.set(token, { device, kind, hash: inputHash(input), expiresAt });
    return { previewToken: token, expiresAt: new Date(expiresAt).toISOString() };
  }

  /** Uses up the token; throws 409 agent.preview.invalid unless device, kind and input all match and it is fresh. */
  consume(token: string, device: string, kind: string, input: unknown): void {
    const e = this.#live.get(token);
    // Any presented token is spent, matching or not: a mismatch can't be retried with other inputs.
    this.#live.delete(token);
    if (!e || e.expiresAt <= this.#now() || e.device !== device || e.kind !== kind || e.hash !== inputHash(input)) {
      throw new AppError("agent.preview.invalid", 409);
    }
  }

  get size() {
    return this.#live.size;
  }
}
