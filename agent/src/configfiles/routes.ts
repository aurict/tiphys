// Config & secrets routes ("configfiles" feature, PLAN.md §13.3 C-1/C-2). Device tokens only: no route declares a scope,
// so service tokens get 403. The routes live in their own Fastify context with an error handler that never echoes
// request content (a JSON syntax error message would quote the body, a value included); validation errors carry
// only the path and the issue code. Audit detail: {file (relative label), keys (names), restart}. Background jobs: a
// rescan every 10 minutes (known secret values for redaction, external changes) and the rotation reminder at startup
// and daily.
import { homedir } from "node:os";
import { dirname, isAbsolute, join } from "node:path";
import type { FastifyInstance } from "fastify";
import { z, ZodError, type ZodType } from "zod";
import { AppError } from "../errors.ts";
import type { Runner } from "../incidents/context.ts";
import type { Ctx } from "../server.ts";
import { KEY_RE } from "./dotenv.ts";
import { BACKUP_ID_RE, FILE_ID_RE, MAX_FILE_BYTES, type WriteHooks } from "./files.ts";
import { SecretsMeta } from "./meta.ts";
import type { RunOpts } from "./restart.ts";
import { ConfigFilesService } from "./service.ts";

/** ~/.local/state/tiphys (or $XDG_STATE_HOME/tiphys). */
export function defaultStateDir(): string {
  const x = process.env.XDG_STATE_HOME;
  return join(x && isAbsolute(x) ? x : join(homedir(), ".local", "state"), "tiphys");
}

function parse<T>(schema: ZodType<T>, v: unknown): T {
  const r = schema.safeParse(v);
  if (!r.success) throw invalid(r.error);
  return r.data;
}

const invalid = (e: ZodError) =>
  new AppError("agent.request.invalid", 400, { issues: e.issues.map((i) => ({ path: i.path.map(String).join("."), message: i.code })) });

const keyName = z.string().max(128).regex(KEY_RE, { message: "invalidKey" });
const value = z.string().max(64 * 1024).refine((v) => !v.includes("\0"), { message: "nul" });
const op = z.discriminatedUnion("op", [
  z.strictObject({ op: z.literal("set"), key: keyName, value }),
  z.strictObject({ op: z.literal("unset"), key: keyName }),
  z.strictObject({ op: z.literal("rename"), key: keyName, newKey: keyName }),
]);
const fileParams = z.object({ fileId: z.string().regex(FILE_ID_RE) });
const hash = z.string().regex(/^[a-f0-9]{64}$/);
const token = z.string().max(200);
const restart = z.enum(["none", "affected"]).default("none");

const BODY_LIMIT = MAX_FILE_BYTES * 2 + 64 * 1024;
export const RESCAN_MS = 10 * 60_000;
export const ROTATION_CHECK_MS = 24 * 3600_000;

export function configFilesRoutes(
  o: { stateDir?: string; hooks?: WriteHooks; now?: () => number; run?: Runner; restart?: RunOpts; jobs?: boolean; onService?: (svc: ConfigFilesService) => void } = {},
) {
  return async (app: FastifyInstance, ctx: Ctx) => {
    const meta = await SecretsMeta.open(dirname(ctx.store.path), o.now);
    const svc = new ConfigFilesService({
      store: ctx.store,
      meta,
      stateDir: o.stateDir ?? defaultStateDir(),
      events: ctx.notifier.events,
      notifier: ctx.notifier,
      hooks: o.hooks,
      run: o.run,
      restart: o.restart,
      now: o.now,
      log: (msg, err) => app.log.warn({ errCode: (err as { code?: string } | undefined)?.code }, msg),
    });
    o.onService?.(svc);
    // Known secret values for redaction (incident context) and external-change tracking, without waiting for the app;
    // the startup scan is the rotation check's.
    const warn = (msg: string) => (err: unknown) => app.log.warn({ errCode: (err as { code?: string }).code }, msg);
    if (o.jobs !== false) {
      void svc.checkRotation().catch(warn("sır yenileme denetimi başarısız"));
      const rescan = setInterval(() => void svc.scanAll().catch(warn("ayar dosyaları taranamadı")), RESCAN_MS);
      const rotation = setInterval(() => void svc.checkRotation().catch(warn("sır yenileme denetimi başarısız")), ROTATION_CHECK_MS);
      rescan.unref();
      rotation.unref();
      app.addHook("onClose", async () => {
        clearInterval(rescan);
        clearInterval(rotation);
      });
    } else {
      void svc.scanAll().catch(warn("ayar dosyaları taranamadı"));
    }

    await app.register(async (r) => {
      r.setErrorHandler((err, req, reply) => {
        if (err instanceof AppError) return reply.status(err.status).send({ error: { code: err.code, params: err.params } });
        if (err instanceof ZodError) {
          const e = invalid(err);
          return reply.status(400).send({ error: { code: e.code, params: e.params } });
        }
        const status = (err as { statusCode?: number }).statusCode;
        const code = (err as { code?: string }).code;
        if (status && status < 500) return reply.status(status).send({ error: { code: "agent.request.invalid", params: { reason: code ?? "invalid" } } });
        // Only the name/code: a message could carry content.
        req.log.error({ errName: (err as Error).name, errCode: code }, "ayar dosyası isteği başarısız");
        return reply.status(500).send({ error: { code: "agent.internal", params: {} } });
      });

      r.get("/v1/config-files", async () => svc.list());

      r.get("/v1/config-files/:fileId", async (req) => svc.get(parse(fileParams, req.params).fileId));

      r.post("/v1/config-files/:fileId/reveal", async (req) => {
        const { fileId } = parse(fileParams, req.params);
        const { keys } = parse(z.strictObject({ keys: z.array(keyName).min(1).max(10) }), req.body);
        req.auditDetail = { fileId, keys };
        const out = await svc.reveal(fileId, keys, req.device!.id);
        req.auditDetail = { file: out.file, keys: Object.keys(out.values) };
        return out;
      });

      r.post("/v1/config-files/:fileId/preview", { bodyLimit: BODY_LIMIT }, async (req) => {
        const { fileId } = parse(fileParams, req.params);
        const b = parse(z.strictObject({ fileId: z.string().optional(), baseHash: hash, ops: z.array(op).min(1).max(100), restart }), req.body);
        if (b.fileId !== undefined && b.fileId !== fileId) throw new AppError("agent.request.invalid", 400, { issues: [{ path: "fileId", message: "mismatch" }] });
        req.auditDetail = { fileId, ops: b.ops.length, restart: b.restart };
        const p = await svc.preview(fileId, b.baseHash, b.ops, req.device!.id, b.restart);
        req.auditDetail = { file: p.file, keys: p.keys, restart: b.restart };
        return p;
      });

      r.put("/v1/config-files/:fileId", async (req) => {
        const { fileId } = parse(fileParams, req.params);
        const b = parse(z.strictObject({ previewToken: token.optional(), confirm: z.boolean().optional(), restart }), req.body ?? {});
        req.auditDetail = { fileId, restart: b.restart };
        if (b.confirm !== true) throw new AppError("agent.configfiles.confirmRequired", 400);
        if (!b.previewToken) throw new AppError("agent.preview.invalid", 409);
        const out = await svc.save(fileId, b.previewToken, req.device!.id, b.restart);
        req.auditDetail = { file: out.file, keys: out.keys, restart: restartOutcome(out), backupId: out.backupId };
        return out;
      });

      r.get("/v1/config-files/:fileId/backups", async (req) => svc.backups(parse(fileParams, req.params).fileId));

      // Without previewToken: preview (masked diff current → backup). With {previewToken, confirm: true}: restore.
      r.post("/v1/config-files/:fileId/restore", async (req) => {
        const { fileId } = parse(fileParams, req.params);
        const b = parse(
          z.strictObject({ backupId: z.string().regex(BACKUP_ID_RE), previewToken: token.optional(), confirm: z.boolean().optional(), restart }),
          req.body,
        );
        req.auditDetail = { fileId, backupId: b.backupId, restart: b.restart };
        if (!b.previewToken) {
          const p = await svc.restorePreview(fileId, b.backupId, req.device!.id, b.restart);
          req.auditDetail = { file: p.file, backupId: b.backupId, keys: p.keys, restart: b.restart, stage: "preview" };
          return p;
        }
        if (b.confirm !== true) throw new AppError("agent.configfiles.confirmRequired", 400);
        const out = await svc.restore(fileId, b.previewToken, req.device!.id, b.backupId, b.restart);
        req.auditDetail = { file: out.file, backupId: b.backupId, keys: out.keys, restart: restartOutcome(out) };
        return out;
      });

      r.get("/v1/secrets/meta", async () => svc.metaList());

      r.put("/v1/secrets/meta", async (req) => {
        const b = parse(
          z.strictObject({
            updates: z
              .array(
                z.strictObject({
                  fileId: z.string().regex(FILE_ID_RE),
                  key: keyName,
                  maxAgeDays: z.number().int().min(1).max(3650).nullable().optional(),
                  secret: z.boolean().nullable().optional(),
                }),
              )
              .min(1)
              .max(100),
          }),
          req.body,
        );
        req.auditDetail = { keys: [...new Set(b.updates.map((u) => u.key))], updates: b.updates.length };
        return svc.putMeta(b.updates);
      });
    });
  };
}

/** Audit value: none, or the outcome of restart "affected" (ok / failed:command / failed:postCheck). */
function restartOutcome(out: { restart: string; recreate?: { ok: boolean; stage?: string } }): string {
  if (!out.recreate) return out.restart;
  return out.recreate.ok ? "ok" : `failed:${out.recreate.stage}`;
}
