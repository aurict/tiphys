// Database console routes ("databases" feature, PLAN.md §13.2 D-1…D-3). Device tokens only: no route declares a
// scope, so service tokens get 403. Like the config file routes they have their own error handler that never echoes
// the request (SQL and credentials stay out of responses and logs). Audit detail: {conn} for connection changes and
// tests, {conn, sqlSha256, rows} for queries and exports, {conn, sqlSha256, rows, write: true} for commits; never SQL
// text or result values (the full write SQL goes to db-writes.jsonl only).
import { PassThrough } from "node:stream";
import type { FastifyInstance, FastifyReply, FastifyRequest } from "fastify";
import { z, ZodError, type ZodType } from "zod";
import { dbCredentialSchema, dbTargetSchema } from "../config.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import type { Runner } from "./docker.ts";
import { csvLine } from "./csv.ts";
import { chartSchema, paramValue } from "./queries.ts";
import { DbService, sqlSha256, type DbServiceOpts } from "./service.ts";
import { LIMITS, toCell, type RowSink } from "./sql.ts";

export { sqlSha256 };

const invalid = (e: ZodError) =>
  new AppError("agent.request.invalid", 400, { issues: e.issues.map((i) => ({ path: i.path.map(String).join("."), message: i.code })) });

function parse<T>(schema: ZodType<T>, v: unknown): T {
  const r = schema.safeParse(v);
  if (!r.success) throw invalid(r.error);
  return r.data;
}

const connId = z.string().regex(/^[a-z0-9][a-z0-9-]{0,62}$/);
const idParams = z.object({ id: connId });
const ident = z.string().min(1).max(256).refine((s) => !s.includes("\0"), { message: "nul" });
const tableParams = idParams.extend({ schema: ident, table: ident });
const timeoutMs = z.number().int().min(1000).max(LIMITS.maxTimeoutMs).default(LIMITS.defaultTimeoutMs);
const limit = z.number().int().min(1).max(LIMITS.maxRows).default(LIMITS.defaultRows);
const credentialInput = z.union([
  z.strictObject({ user: z.string().min(1).max(128), password: z.string().max(1024).nullable().optional() }),
  dbCredentialSchema.options[1],
]);

const createBody = z.strictObject({
  id: connId.optional(),
  name: z.string().min(1).max(80),
  engine: z.enum(["postgres", "mysql", "mariadb", "sqlite"]),
  target: dbTargetSchema,
  database: z.string().min(1).max(128).optional(),
  readCredential: credentialInput.optional(),
  writeCredential: credentialInput.optional(),
});
const patchBody = z.strictObject({
  name: z.string().min(1).max(80).optional(),
  target: dbTargetSchema.optional(),
  database: z.string().min(1).max(128).nullable().optional(),
  readCredential: credentialInput.optional(),
  writeCredential: credentialInput.nullable().optional(),
});
const sql = z.string().min(1).max(LIMITS.maxSqlChars);
const params = z.array(paramValue).max(LIMITS.maxParams);
const queryBody = z.strictObject({ sql, params: params.default([]), limit, timeoutMs });
const exportBody = z.strictObject({ sql, params: params.default([]), timeoutMs });
const queryIdParams = z.object({ id: z.string().regex(/^q-[a-f0-9]{8,32}$/) });
const savedCreateBody = z.strictObject({ connectionId: connId, name: z.string().min(1).max(80), sql, params: params.optional(), chart: chartSchema.optional() });
const savedPatchBody = z.strictObject({ connectionId: connId.optional(), name: z.string().min(1).max(80).optional(), sql: sql.optional(), params: params.optional(), chart: chartSchema.optional() });
const savedRunBody = z.strictObject({ params: params.optional(), limit, timeoutMs });
const savedExportBody = z.strictObject({ params: params.optional(), timeoutMs });
const writePreviewBody = z.strictObject({ sql, timeoutMs });
const writeCommitBody = z.strictObject({ previewToken: z.string().min(1).max(200), confirm: z.literal(true) });
const roleQuery = z.object({ role: z.string().regex(/^[a-z_][a-z0-9_]{0,62}$/).default("tiphys_ro") });
const sqlBodyLimit = LIMITS.maxSqlChars * 4 + 64 * 1024 * LIMITS.maxParams;
const previewQuery = z.object({
  limit: z.coerce.number().int().min(1).max(LIMITS.maxRows).default(100),
  timeoutMs: z.coerce.number().int().min(1000).max(LIMITS.maxTimeoutMs).default(LIMITS.defaultTimeoutMs),
});

/**
 * Streams a CSV export: the query starts first, and only once its columns are known is the response begun (an error
 * before that is a normal JSON error). Caps: LIMITS.exportRows rows and LIMITS.exportBytes bytes of CSV; past them the
 * export ends early. Rows and truncation come as HTTP trailers (x-tiphys-rows, x-tiphys-truncated) and in the audit.
 */
async function sendCsv(req: FastifyRequest, reply: FastifyReply, conn: string, sqlText: string, filename: string, run: (sink: RowSink) => Promise<void>) {
  const pass = new PassThrough();
  let closed = false;
  pass.on("close", () => (closed = true));
  let rows = 0;
  let bytes = 0;
  let truncated = false;
  let onStart!: () => void;
  const started = new Promise<void>((r) => (onStart = r));
  const waitDrain = () =>
    new Promise<void>((r) => {
      const done = () => {
        pass.off("drain", done);
        pass.off("close", done);
        r();
      };
      pass.on("drain", done);
      pass.on("close", done);
    });
  const sink: RowSink = {
    columns(cols) {
      const head = "\uFEFF" + csvLine(cols.map((c) => c.name));
      bytes += Buffer.byteLength(head);
      pass.write(head);
      onStart();
    },
    async row(values) {
      if (closed) return false;
      if (rows >= LIMITS.exportRows) {
        truncated = true;
        return false;
      }
      const line = csvLine(values.map((v) => toCell(v, LIMITS.exportBytes).value));
      const len = Buffer.byteLength(line);
      if (bytes + len > LIMITS.exportBytes) {
        truncated = true;
        return false;
      }
      bytes += len;
      rows++;
      if (!pass.write(line)) await waitDrain();
      return !closed;
    },
  };
  const job = run(sink);
  await Promise.race([started, job]);
  onStart();
  const finished = job.then(
    () => {
      req.auditDetail = { conn, sqlSha256: sqlSha256(sqlText), rows, truncated, bytes };
      pass.end();
    },
    (e) => {
      req.auditDetail = { conn, sqlSha256: sqlSha256(sqlText), rows, failed: e instanceof AppError ? e.code : "error" };
      pass.destroy();
    },
  );
  reply
    .header("content-type", "text/csv; charset=utf-8")
    .header("content-disposition", `attachment; filename="${filename}"`)
    .header("cache-control", "no-store")
    .header("x-tiphys-max-rows", String(LIMITS.exportRows))
    .header("x-tiphys-max-bytes", String(LIMITS.exportBytes))
    .trailer("x-tiphys-rows", async () => (await finished, String(rows)))
    .trailer("x-tiphys-truncated", async () => (await finished, String(truncated)));
  return reply.send(pass);
}

const csvName = (base: string) => `${base}-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, "-")}.csv`;

export function dbRoutes(o: { run?: Runner; now?: () => number; onService?: (svc: DbService) => void; drivers?: DbServiceOpts["drivers"]; previewTtlMs?: number } = {}) {
  return async (app: FastifyInstance, ctx: Ctx) => {
    const svc = new DbService({ store: ctx.store, run: o.run, now: o.now, drivers: o.drivers, previewTtlMs: o.previewTtlMs });
    o.onService?.(svc);

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
        // Only the name/code: a driver message could carry SQL or credentials.
        req.log.error({ errName: (err as Error).name, errCode: code }, "veritabanı isteği başarısız");
        return reply.status(500).send({ error: { code: "agent.internal", params: {} } });
      });

      r.get("/v1/db/discover", async () => {
        const conns = ctx.store.get().databases.connections;
        const found = await svc.discover();
        return {
          containers: found.map((d) => ({
            ...d,
            connections: conns.filter((c) => "container" in c.target && c.target.container === d.container).map((c) => c.id),
          })),
        };
      });

      r.get("/v1/db/connections", async () => ({ connections: svc.list(), engines: await svc.engines() }));

      r.get("/v1/db/connections/:id", async (req) => {
        const { id } = parse(idParams, req.params);
        const c = svc.list().find((x) => x.id === id);
        if (!c) throw new AppError("agent.db.connectionNotFound", 404, { id });
        return c;
      });

      r.post("/v1/db/connections", async (req, reply) => {
        const b = parse(createBody, req.body);
        const out = await svc.create(b);
        req.auditDetail = { conn: out.id, engine: out.engine };
        return reply.status(201).send(out);
      });

      r.patch("/v1/db/connections/:id", async (req) => {
        const { id } = parse(idParams, req.params);
        req.auditDetail = { conn: id };
        const b = parse(patchBody, req.body);
        req.auditDetail = { conn: id, fields: Object.keys(b) };
        return svc.patch(id, b);
      });

      r.delete("/v1/db/connections/:id", async (req) => {
        const { id } = parse(idParams, req.params);
        req.auditDetail = { conn: id };
        await svc.remove(id);
        return { ok: true };
      });

      r.post("/v1/db/connections/:id/test", async (req) => {
        const { id } = parse(idParams, req.params);
        req.auditDetail = { conn: id };
        return svc.test(id, LIMITS.defaultTimeoutMs);
      });

      r.get("/v1/db/connections/:id/schema", async (req) => {
        const { id } = parse(idParams, req.params);
        return { conn: id, ...(await svc.schema(id, LIMITS.maxTimeoutMs)) };
      });

      r.get("/v1/db/connections/:id/tables/:schema/:table/preview", async (req) => {
        const { id, schema, table } = parse(tableParams, req.params);
        const q = parse(previewQuery, req.query);
        svc.get(id);
        svc.checkRate(req.device!.id);
        const started = Date.now();
        const res = await svc.preview(id, schema, table, q.limit, q.timeoutMs);
        return { conn: id, schema, table, ...res, limit: q.limit, elapsedMs: Date.now() - started };
      });

      r.post("/v1/db/connections/:id/query", { bodyLimit: sqlBodyLimit }, async (req) => {
        const { id } = parse(idParams, req.params);
        req.auditDetail = { conn: id };
        const b = parse(queryBody, req.body);
        req.auditDetail = { conn: id, sqlSha256: sqlSha256(b.sql) };
        svc.get(id);
        svc.checkRate(req.device!.id);
        const started = Date.now();
        const res = await svc.query(id, b.sql, b.params, b.limit, b.timeoutMs);
        req.auditDetail = { conn: id, sqlSha256: sqlSha256(b.sql), rows: res.rowCount, truncated: res.truncated };
        return { conn: id, ...res, limit: b.limit, elapsedMs: Date.now() - started };
      });

      r.post("/v1/db/connections/:id/export", { bodyLimit: sqlBodyLimit }, async (req, reply) => {
        const { id } = parse(idParams, req.params);
        req.auditDetail = { conn: id };
        const b = parse(exportBody, req.body);
        req.auditDetail = { conn: id, sqlSha256: sqlSha256(b.sql) };
        svc.get(id);
        svc.checkExportRate(req.device!.id);
        return sendCsv(req, reply, id, b.sql, csvName(id), (sink) => svc.export(id, b.sql, b.params, b.timeoutMs, sink));
      });

      // --- Saved queries (D-2) ---

      r.get("/v1/db/queries", async (req) => {
        const { connectionId } = parse(z.object({ connectionId: connId.optional() }), req.query);
        return { queries: await svc.queries.list(connectionId) };
      });

      r.get("/v1/db/queries/:id", async (req) => svc.queries.get(parse(queryIdParams, req.params).id));

      r.post("/v1/db/queries", { bodyLimit: sqlBodyLimit }, async (req, reply) => {
        const b = parse(savedCreateBody, req.body);
        req.auditDetail = { conn: b.connectionId, sqlSha256: sqlSha256(b.sql) };
        svc.validateSaved(b.connectionId, b.sql);
        const q = await svc.queries.create(b);
        req.auditDetail = { conn: b.connectionId, query: q.id, sqlSha256: sqlSha256(b.sql) };
        return reply.status(201).send(q);
      });

      r.patch("/v1/db/queries/:id", { bodyLimit: sqlBodyLimit }, async (req) => {
        const { id } = parse(queryIdParams, req.params);
        req.auditDetail = { query: id };
        const b = parse(savedPatchBody, req.body);
        const old = await svc.queries.get(id);
        const conn = b.connectionId ?? old.connectionId;
        const text = b.sql ?? old.sql;
        req.auditDetail = { query: id, conn, fields: Object.keys(b), sqlSha256: sqlSha256(text) };
        svc.validateSaved(conn, text);
        return svc.queries.patch(id, b);
      });

      r.delete("/v1/db/queries/:id", async (req) => {
        const { id } = parse(queryIdParams, req.params);
        req.auditDetail = { query: id };
        await svc.queries.remove(id);
        return { ok: true };
      });

      r.post("/v1/db/queries/:id/run", { bodyLimit: sqlBodyLimit }, async (req) => {
        const { id } = parse(queryIdParams, req.params);
        req.auditDetail = { query: id };
        const b = parse(savedRunBody, req.body ?? {});
        const q = await svc.queries.get(id);
        req.auditDetail = { query: id, conn: q.connectionId, sqlSha256: sqlSha256(q.sql) };
        svc.get(q.connectionId);
        svc.checkRate(req.device!.id);
        const started = Date.now();
        const res = await svc.runSaved(id, { ...(b.params ? { params: b.params } : {}), limit: b.limit, timeoutMs: b.timeoutMs });
        req.auditDetail = { query: id, conn: q.connectionId, sqlSha256: sqlSha256(q.sql), rows: res.rowCount, truncated: res.truncated };
        return { ...res, limit: b.limit, elapsedMs: Date.now() - started };
      });

      r.post("/v1/db/queries/:id/export", { bodyLimit: sqlBodyLimit }, async (req, reply) => {
        const { id } = parse(queryIdParams, req.params);
        req.auditDetail = { query: id };
        const b = parse(savedExportBody, req.body ?? {});
        const q = await svc.queries.get(id);
        req.auditDetail = { query: id, conn: q.connectionId, sqlSha256: sqlSha256(q.sql) };
        svc.get(q.connectionId);
        svc.checkExportRate(req.device!.id);
        return sendCsv(req, reply, q.connectionId, q.sql, csvName(id), (sink) => svc.export(q.connectionId, q.sql, b.params ?? q.params, b.timeoutMs, sink));
      });

      // --- Write mode (D-3) ---

      r.post("/v1/db/connections/:id/write/preview", { bodyLimit: sqlBodyLimit }, async (req) => {
        const { id } = parse(idParams, req.params);
        req.auditDetail = { conn: id };
        const b = parse(writePreviewBody, req.body);
        req.auditDetail = { conn: id, sqlSha256: sqlSha256(b.sql), preview: true };
        svc.get(id);
        svc.checkRate(req.device!.id);
        const started = Date.now();
        const res = await svc.writePreview(req.device!.id, id, b.sql, b.timeoutMs);
        req.auditDetail = { conn: id, sqlSha256: sqlSha256(b.sql), rows: res.count ?? -1, preview: true };
        return { ...res, elapsedMs: Date.now() - started };
      });

      r.post("/v1/db/connections/:id/write/commit", async (req) => {
        const { id } = parse(idParams, req.params);
        req.auditDetail = { conn: id, write: true };
        const b = parse(writeCommitBody, req.body);
        const started = Date.now();
        const res = await svc.writeCommit(req.device!.id, id, b.previewToken, (sha, rows) => (req.auditDetail = { conn: id, sqlSha256: sha, rows: rows ?? -1, write: true }));
        return { ...res, elapsedMs: Date.now() - started };
      });

      r.get("/v1/db/connections/:id/readonly-role-sql", async (req) => {
        const { id } = parse(idParams, req.params);
        const { role } = parse(roleQuery, req.query);
        return svc.readonlyRoleSql(id, role);
      });
    });
  };
}
