// Client for the PC agent's research API (PLAN §12 "Ajanlar arası sözleşme"):
//   POST /v1/research/jobs → 202 {id};  GET /v1/research/jobs/:id → {id, status, error?, result?}
// Authorization: Bearer <scoped service token> (config `research.token`, never logged or returned).
// Errors map to agent.telegram.research.* codes; "unreachable" also covers 502/503/504 (tailscale serve answers
// that way while the PC agent is down).
import { z } from "zod";
import { AppError } from "../errors.ts";
import type { Fetch } from "./api.ts";

export interface ResearchRequest {
  topic: string;
  instructions?: string;
  windowHours: number;
  language: string;
  minItems: number;
  maxItems: number;
  maxSourcesPerItem: number;
  allowDomains: string[];
  blockDomains: string[];
  excludeUrls: string[];
  editor: boolean;
}

/** Longer URLs are dropped one by one (the PC caps them at 2048 too), never the whole result. */
const MAX_URL = 2048;
const shortUrl = (u: string) => u.length <= MAX_URL;

export const researchResultSchema = z.object({
  items: z
    .array(
      z.object({
        headline: z.string().max(2000),
        summary: z.string().max(10_000),
        published: z.string().max(100).nullish(),
        sources: z
          .array(z.object({ title: z.string().max(1000).optional(), url: z.string() }))
          .max(20)
          .transform((ss) => ss.filter((s) => shortUrl(s.url))),
      }),
    )
    .max(100),
  seenUrls: z
    .array(z.string())
    .max(10_000)
    .transform((us) => us.filter(shortUrl)),
  models: z.object({ research: z.string().max(100), editor: z.string().max(100).nullish() }),
  timings: z.object({ researchSec: z.number().optional(), editorSec: z.number().optional() }).optional(),
});
export type ResearchResult = z.infer<typeof researchResultSchema>;

const jobSchema = z.object({
  id: z.string().min(1).max(100),
  status: z.enum(["queued", "running", "done", "failed"]),
  error: z.object({ code: z.string().max(200) }).nullish(),
  result: researchResultSchema.nullish(),
});
export type ResearchJob = z.infer<typeof jobSchema>;

export const researchError = (what: string, status = 502, params: Record<string, unknown> = {}) =>
  new AppError(`agent.telegram.research.${what}`, status, params);

export class ResearchClient {
  readonly #url: string;
  readonly #token: string;
  readonly #fetch: Fetch;
  readonly #timeoutMs: number;

  constructor(o: { url: string; token: string; fetch?: Fetch; timeoutMs?: number }) {
    this.#url = o.url.replace(/\/+$/, "");
    this.#token = o.token;
    this.#fetch = o.fetch ?? fetch;
    this.#timeoutMs = o.timeoutMs ?? 15_000;
  }

  async #req(method: "GET" | "POST" | "DELETE", path: string, body?: unknown, timeoutMs = this.#timeoutMs): Promise<{ status: number; json: unknown }> {
    let res: Response;
    try {
      res = await this.#fetch(`${this.#url}${path}`, {
        method,
        headers: { authorization: `Bearer ${this.#token}`, ...(body ? { "content-type": "application/json" } : {}) },
        body: body ? JSON.stringify(body) : undefined,
        signal: AbortSignal.timeout(timeoutMs),
      });
    } catch {
      throw researchError("unreachable", 503);
    }
    if (res.status === 502 || res.status === 503 || res.status === 504) {
      await res.body?.cancel().catch(() => {});
      throw researchError("unreachable", 503);
    }
    const json = await res.json().catch(() => null);
    if (res.status === 401 || res.status === 403) throw researchError("unauthorized", 502);
    if (res.status === 429) throw researchError("busy", 503);
    return { status: res.status, json };
  }

  async create(req: ResearchRequest): Promise<string> {
    const r = await this.#req("POST", "/v1/research/jobs", req);
    const id = (r.json as { id?: unknown } | null)?.id;
    if (r.status >= 300 || typeof id !== "string") throw researchError("rejected", 502, { status: r.status, code: errorCode(r.json) });
    return id;
  }

  /** null: the PC doesn't know the job (e.g. it restarted) → create a new one. */
  async get(id: string): Promise<ResearchJob | null> {
    const r = await this.#req("GET", `/v1/research/jobs/${encodeURIComponent(id)}`);
    if (r.status === 404) return null;
    if (r.status >= 300) throw researchError("rejected", 502, { status: r.status, code: errorCode(r.json) });
    const p = jobSchema.safeParse(r.json);
    if (!p.success) throw researchError("badResponse", 502);
    return p.data;
  }

  /** Cancels a job this token started (best effort, short timeout: used when atlas gives up on it). */
  async cancel(id: string, timeoutMs = 3000): Promise<void> {
    await this.#req("DELETE", `/v1/research/jobs/${encodeURIComponent(id)}`, undefined, timeoutMs);
  }

  /** The PC agent answers /v1/health without authentication. */
  async health(timeoutMs = 3000): Promise<boolean> {
    try {
      const res = await this.#fetch(`${this.#url}/v1/health`, { signal: AbortSignal.timeout(timeoutMs) });
      await res.body?.cancel().catch(() => {});
      return res.ok;
    } catch {
      return false;
    }
  }
}

function errorCode(j: unknown): string {
  const c = (j as { error?: { code?: unknown } } | null)?.error?.code;
  return typeof c === "string" ? c.slice(0, 100) : "";
}
