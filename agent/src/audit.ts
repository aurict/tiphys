// Audit log: every mutating request (non-GET) is written to a JSONL file with device, path and result.
// The file sits next to the agent settings file (audit.jsonl); past 1 MB it's kept as the previous copy.
// A route may add `req.auditDetail` (ids, key names, counts, hashes; never values): it is written as `detail`.
import { appendFile, readFile, rename, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Ctx } from "./server.ts";

const MAX_BYTES = 1024 * 1024;

export interface AuditEntry {
  at: string;
  device: string | null;
  method: string;
  path: string;
  status: number;
  detail?: AuditDetail;
}

export type AuditDetail = Record<string, string | number | boolean | string[]>;

const MAX_DETAIL_KEYS = 16;
const MAX_DETAIL_CHARS = 200;

/** Bounds the detail a route attached (key count, string length, list length). */
export function auditDetailOf(d: AuditDetail | undefined): AuditDetail | undefined {
  if (!d) return undefined;
  const cut = (v: string) => v.slice(0, MAX_DETAIL_CHARS);
  const out: AuditDetail = {};
  for (const [k, v] of Object.entries(d).slice(0, MAX_DETAIL_KEYS)) {
    out[k] = typeof v === "string" ? cut(v) : Array.isArray(v) ? v.slice(0, 50).map(cut) : v;
  }
  return out;
}

export function auditRoutes(app: FastifyInstance, ctx: Ctx) {
  const file = join(dirname(ctx.store.path), "audit.jsonl");
  let chain = Promise.resolve();

  app.addHook("onResponse", async (req, reply) => {
    if (req.method === "GET" || req.method === "HEAD" || req.method === "OPTIONS") return;
    const entry: AuditEntry = {
      at: new Date().toISOString(),
      device: req.device?.id ?? (req.service ? `service:${req.service.id}` : null),
      method: req.method,
      path: req.url.split("?")[0]!,
      status: reply.statusCode,
    };
    const detail = auditDetailOf(req.auditDetail);
    if (detail) entry.detail = detail;
    try {
      ctx.onAudit?.(entry);
    } catch (e) {
      req.log.warn({ err: e }, "kara kutu kaydı alınamadı");
    }
    // Writes are serialized; a logging error doesn't break the request.
    chain = chain
      .then(async () => {
        const size = await stat(file).then((s) => s.size, () => 0);
        if (size > MAX_BYTES) await rename(file, `${file}.1`);
        await appendFile(file, JSON.stringify(entry) + "\n", { mode: 0o600 });
      })
      .catch((e) => req.log.warn({ err: e }, "işlem kaydı yazılamadı"));
  });

  app.get("/v1/audit", async (req) => {
    const { limit } = z.object({ limit: z.coerce.number().int().min(1).max(1000).default(200) }).parse(req.query);
    await chain;
    const text = await readFile(file, "utf8").catch(() => "");
    const entries = text
      .split("\n")
      .filter(Boolean)
      .slice(-limit)
      .map((l) => JSON.parse(l) as AuditEntry)
      .reverse();
    return { entries };
  });
}
