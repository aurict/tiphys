// Event stream: every notification (even without an endpoint) and events that need no notification (Docker
// restarts, work the phone did over SSH) are written to a JSONL file. The file sits next to the agent settings file
// (events.jsonl); past 2 MB the previous copy is kept as (.1). The app shows it in Sistem › Olaylar.
import { randomBytes } from "node:crypto";
import { appendFile, readFile, rename, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import type { Ctx } from "./server.ts";

const MAX_BYTES = 2 * 1024 * 1024;
/** Upper limit of a single text parameter in the event record (e.g. a Claude summary). */
const MAX_PARAM_CHARS = 500;

export interface AgentEvent {
  id: string;
  at: string;
  key: string;
  params: Record<string, string | number>;
  link: string | null;
  /** "agent": the agent itself; "app": reported from the phone (e.g. a compose update over SSH). */
  source: "agent" | "app";
  device?: string;
}

export function eventsPath(configPath: string) {
  return join(dirname(configPath), "events.jsonl");
}

export class EventLog {
  readonly file: string;
  #chain = Promise.resolve();
  #seq = 0;

  constructor(file: string) {
    this.file = file;
  }

  /** Queues and writes the event; a write error doesn't break the caller (it's recorded, not swallowed: goes to onError). */
  record(
    e: { key: string; params?: Record<string, string | number>; link?: string | null; source?: AgentEvent["source"]; device?: string },
    onError: (err: unknown) => void = () => {},
  ): Promise<AgentEvent> {
    const ev: AgentEvent = {
      id: `${Date.now().toString(36)}-${(this.#seq++).toString(36)}-${randomBytes(3).toString("hex")}`,
      at: new Date().toISOString(),
      key: e.key,
      params: Object.fromEntries(Object.entries(e.params ?? {}).map(([k, v]) => [k, typeof v === "string" ? v.slice(0, MAX_PARAM_CHARS) : v])),
      link: e.link ?? null,
      source: e.source ?? "agent",
      ...(e.device ? { device: e.device } : {}),
    };
    this.#chain = this.#chain
      .then(async () => {
        const size = await stat(this.file).then((s) => s.size, () => 0);
        if (size > MAX_BYTES) await rename(this.file, `${this.file}.1`);
        await appendFile(this.file, JSON.stringify(ev) + "\n", { mode: 0o600 });
      })
      .catch(onError);
    return this.#chain.then(() => ev);
  }

  /** Newest to oldest; if `since` (ISO time) is given, only those after it. */
  async list(opts: { since?: string; limit?: number } = {}): Promise<AgentEvent[]> {
    await this.#chain;
    const limit = opts.limit ?? 100;
    const since = opts.since ? Date.parse(opts.since) : null;
    const out: AgentEvent[] = [];
    // The current file first, then the rotated old copy if needed.
    for (const f of [this.file, `${this.file}.1`]) {
      const text = await readFile(f, "utf8").catch(() => "");
      const lines = text.split("\n").filter(Boolean).reverse();
      for (const l of lines) {
        let e: AgentEvent;
        try {
          e = JSON.parse(l) as AgentEvent;
        } catch {
          continue; // half-written line
        }
        if (since !== null && Date.parse(e.at) <= since) return out;
        out.push(e);
        if (out.length >= limit) return out;
      }
    }
    return out;
  }
}

const paramValue = z.union([z.string().max(MAX_PARAM_CHARS), z.number().finite()]);
/** Event reported by the phone: small and bounded (e.g. "compose.updated"). */
export const appEventSchema = z.strictObject({
  key: z.string().regex(/^[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9]+){1,3}$/).max(64),
  params: z
    .record(z.string().regex(/^[a-zA-Z][a-zA-Z0-9]{0,31}$/), paramValue)
    .refine((r) => Object.keys(r).length <= 16, { message: "en çok 16 parametre" })
    .default({}),
  link: z.string().regex(/^tiphys:\/\/\S{0,200}$/).nullable().default(null),
});

export function eventRoutes(app: FastifyInstance, ctx: Ctx) {
  const log = ctx.notifier.events!;
  app.get("/v1/events", async (req) => {
    const q = z.object({ since: z.iso.datetime({ offset: true }).optional(), limit: z.coerce.number().int().min(1).max(500).default(100) }).parse(req.query);
    return { events: await log.list(q) };
  });

  app.post("/v1/events", async (req) => {
    const e = appEventSchema.parse(req.body);
    const ev = await log.record({ ...e, source: "app", device: req.device?.id }, (err) => req.log.warn({ err }, "olay yazılamadı"));
    return { event: ev };
  });
}
