// Client for the PC agent's analysis API (remote mode of incidents.analysis, PLAN.md §13.1 I-3):
//   POST /v1/analysis/jobs {bundle} → 202 {id};  GET /v1/analysis/jobs/:id → {id, status, error?, result?}
// Authorization: Bearer <service token with the "analysis" scope> (config `incidents.analysis.token`, never logged).
// Failures are AppErrors `agent.incident.analysis.<reason>`; reason unreachable also covers 502/503/504 (tailscale
// serve answers that way while the PC agent is down). The PC is never woken for an analysis.
import { z } from "zod";
import { AppError } from "../errors.ts";
import type { AnalysisBundle } from "./schema.ts";

export type Fetch = typeof fetch;
export type UnavailableReason = "unreachable" | "unauthorized" | "busy" | "rejected" | "badResponse" | "timeout" | "lost";

export const unavailable = (reason: UnavailableReason, params: Record<string, unknown> = {}) =>
  new AppError(`agent.incident.analysis.${reason}`, 503, { reason, ...params });

const jobSchema = z.object({
  id: z.string().min(1).max(100),
  status: z.enum(["queued", "running", "done", "failed"]),
  error: z.object({ code: z.string().max(200) }).nullish(),
  // Shape checked loosely here; the incident service validates it against its own bundle.
  result: z.unknown().optional(),
});
export type RemoteJob = z.infer<typeof jobSchema>;

export class AnalysisClient {
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
        redirect: "error",
      });
    } catch {
      throw unavailable("unreachable");
    }
    if (res.status === 502 || res.status === 503 || res.status === 504) {
      await res.body?.cancel().catch(() => {});
      throw unavailable("unreachable");
    }
    const json = await res.json().catch(() => null);
    if (res.status === 401 || res.status === 403) throw unavailable("unauthorized");
    if (res.status === 429) throw unavailable("busy");
    return { status: res.status, json };
  }

  async create(bundle: AnalysisBundle): Promise<string> {
    const r = await this.#req("POST", "/v1/analysis/jobs", { bundle });
    const id = (r.json as { id?: unknown } | null)?.id;
    if (r.status >= 300 || typeof id !== "string" || !/^aj-[a-f0-9]{16}$/.test(id)) throw unavailable("rejected", { status: r.status, code: errorCode(r.json) });
    return id;
  }

  /** null: the PC doesn't know the job (it restarted, or the result expired). */
  async get(id: string): Promise<RemoteJob | null> {
    const r = await this.#req("GET", `/v1/analysis/jobs/${encodeURIComponent(id)}`);
    if (r.status === 404) return null;
    if (r.status >= 300) throw unavailable("rejected", { status: r.status, code: errorCode(r.json) });
    const p = jobSchema.safeParse(r.json);
    if (!p.success) throw unavailable("badResponse");
    return p.data;
  }

  /** Best effort, short timeout (used when the server gives up waiting). */
  async cancel(id: string, timeoutMs = 3000): Promise<void> {
    await this.#req("DELETE", `/v1/analysis/jobs/${encodeURIComponent(id)}`, undefined, timeoutMs);
  }
}

function errorCode(j: unknown): string {
  const c = (j as { error?: { code?: unknown } } | null)?.error?.code;
  return typeof c === "string" ? c.slice(0, 100) : "";
}
