// Sesli mesaj: telefon kaydı (base64) → Scriberr/Whisper (yapılandırılan transcribe komutu) → metin.
import { mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { expandHome } from "../config.ts";
import { run } from "../exec.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

const body = z.object({
  data: z.base64().max(30 * 1024 * 1024),
  ext: z.enum(["m4a", "aac", "mp3", "wav", "ogg", "opus", "webm"]),
  language: z.enum(["tr", "en"]).optional(),
  /** Telefondaki Scriberr ayarı; verilmezse ajanın varsayılanı. */
  model: z.enum(["small", "large-v3"]).optional(),
});

export function transcribeRoutes(app: FastifyInstance, ctx: Ctx) {
  app.post("/v1/transcribe", async (req) => {
    const b = body.parse(req.body);
    const cfg = ctx.store.get().transcribe;
    const dir = await mkdtemp(join(tmpdir(), "tiphys-voice-"));
    try {
      const file = join(dir, `ses.${b.ext}`);
      await writeFile(file, Buffer.from(b.data, "base64"), { mode: 0o600 });
      const args = [file, "-m", b.model ?? cfg.model, ...(b.language ? ["-l", b.language] : [])];
      const r = await run(expandHome(cfg.command), args, { timeoutMs: 10 * 60_000, allowFail: true });
      if (r.code !== 0) throw new AppError("agent.transcribe.failed", 502, { stderr: r.stderr.slice(0, 1000) });
      return { text: r.stdout.trim() };
    } finally {
      await rm(dir, { recursive: true, force: true });
    }
  });
}
