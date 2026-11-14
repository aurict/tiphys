// İşlem kaydı: değişiklik yapan her istek (GET dışı) cihaz, yol ve sonuçla birlikte JSONL dosyasına yazılır.
// Dosya ajan ayar dosyasının yanında durur (audit.jsonl); 1 MB'ı geçince bir önceki kopya olarak saklanır.
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
}

export function auditRoutes(app: FastifyInstance, ctx: Ctx) {
  const file = join(dirname(ctx.store.path), "audit.jsonl");
  let chain = Promise.resolve();

  app.addHook("onResponse", async (req, reply) => {
    if (req.method === "GET" || req.method === "HEAD" || req.method === "OPTIONS") return;
    const entry: AuditEntry = {
      at: new Date().toISOString(),
      device: req.device?.id ?? null,
      method: req.method,
      path: req.url.split("?")[0]!,
      status: reply.statusCode,
    };
    // Yazmalar sırayla yapılır; kayıt hatası isteği bozmaz.
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
