// Scheduled Claude tasks ("claude" feature): claude-schedules.json (next to the agent's config file).
// The scheduler checks once a minute; times are in the agent's local time zone (TZ env variable / system).
//   daily    : every day at HH:MM
//   weekly   : on selected days (1 = Monday … 7 = Sunday) at HH:MM
//   interval : every N minutes (at least 15); slots are counted from when the task was created/its timing changed.
// Missed runs aren't made up: if the agent was off at that minute (or the event loop stalled for over 2 minutes)
// the task isn't run late; the next time is awaited. If the task's previous run is still going, the new one is skipped
// (event: claude.scheduleSkipped). A run is a normal Claude session (title "⏰ name"); when it finishes the usual
// claude.done / claude.error notification goes out. If it can't start (folder deleted etc.) claude.scheduleFailed is sent.
import { randomUUID } from "node:crypto";
import { readFile, rename, writeFile } from "node:fs/promises";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { AppError, notFound } from "../errors.ts";
import type { Ctx } from "../server.ts";
import type { ClaudeEvent, ClaudeManager } from "./manager.ts";

const hhmm = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/);

export const whenSchema = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("daily"), time: hhmm }),
  z.strictObject({ kind: z.literal("weekly"), time: hhmm, days: z.array(z.int().min(1).max(7)).min(1).max(7) }),
  z.strictObject({ kind: z.literal("interval"), everyMinutes: z.int().min(15).max(7 * 24 * 60) }),
]);
export type When = z.infer<typeof whenSchema>;

/** Fields sent by the phone (editable). */
export const scheduleInputSchema = z.strictObject({
  name: z.string().trim().min(1).max(80),
  cwd: z.string().min(1).max(1024),
  prompt: z.string().trim().min(1).max(50_000),
  when: whenSchema,
  permissionMode: z.enum(["default", "acceptEdits", "plan", "bypassPermissions"]).default("default"),
  model: z.string().max(80).optional(),
  effort: z.enum(["low", "medium", "high", "xhigh", "max"]).optional(),
  profileId: z.string().max(64).optional(),
  enabled: z.boolean().default(true),
});

export interface LastRun {
  at: string;
  /** Live session id in the agent (null if it couldn't start). */
  sessionId: string | null;
  sdkSessionId: string | null;
  /** null: still running or no result yet. */
  ok: boolean | null;
  /** Error code if it couldn't start (e.g. agent.claude.folderNotFound). */
  error?: string;
  manual?: boolean;
}

export type Schedule = z.infer<typeof scheduleInputSchema> & {
  id: string;
  createdAt: string;
  /** Start of the interval slots (when it was created or its timing changed). */
  anchorAt: string;
  lastRun: LastRun | null;
};

const minuteOf = (d: Date) => Math.floor(d.getTime() / 60_000);
/** JS getDay (0 = Sunday) → ISO day (1 = Monday … 7 = Sunday). */
const isoDay = (d: Date) => ((d.getDay() + 6) % 7) + 1;

/** Should the task run at this minute (local time)? */
export function dueAt(s: Pick<Schedule, "when" | "anchorAt">, minute: Date): boolean {
  const w = s.when;
  if (w.kind === "interval") {
    const diff = minuteOf(minute) - minuteOf(new Date(s.anchorAt));
    return diff > 0 && diff % w.everyMinutes === 0;
  }
  const [h, m] = w.time.split(":").map(Number);
  const target = h! * 60 + m!;
  const wall = (d: Date) => d.getHours() * 60 + d.getMinutes();
  const cur = wall(minute);
  const prev = wall(new Date(minute.getTime() - 60_000));
  // On the DST switch (spring, e.g. 02:00 → 03:00) a task in the skipped hour runs at the first minute after the switch.
  // The second run in the repeated autumn hour is prevented in tick() by looking at the last run.
  const hit = cur === target || (cur - prev > 1 && prev < target && target < cur);
  if (!hit) return false;
  return w.kind === "daily" || w.days.includes(isoDay(minute));
}

/** First run time after `after` (looks at most 8 days ahead; interval is computed directly). */
export function nextRun(s: Pick<Schedule, "when" | "anchorAt">, after: Date): Date | null {
  const start = minuteOf(after) + 1;
  if (s.when.kind === "interval") {
    const a = minuteOf(new Date(s.anchorAt));
    const n = s.when.everyMinutes;
    const k = Math.max(1, Math.ceil((start - a) / n));
    return new Date((a + k * n) * 60_000);
  }
  for (let i = 0; i < 8 * 24 * 60; i++) {
    const d = new Date((start + i) * 60_000);
    if (dueAt(s, d)) return d;
  }
  return null;
}

const ACTIVE = new Set(["starting", "running", "waiting"]);

export class ClaudeScheduler {
  schedules: Schedule[] = [];
  readonly #mgr: ClaudeManager;
  readonly #ctx: Ctx;
  readonly #file: string | null;
  readonly #now: () => Date;
  #timer: NodeJS.Timeout | null = null;
  #lastMinute: number;
  #chain: Promise<void> = Promise.resolve();

  constructor(mgr: ClaudeManager, ctx: Ctx, file: string | null, now: () => Date = () => new Date()) {
    this.#mgr = mgr;
    this.#ctx = ctx;
    this.#file = file;
    this.#now = now;
    this.#lastMinute = minuteOf(now()) - 1;
  }

  async load() {
    if (!this.#file) return;
    try {
      this.schedules = JSON.parse(await readFile(this.#file, "utf8")) as Schedule[];
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "ENOENT") console.error("claude-schedules.json okunamadı:", e);
    }
  }

  /** Atomic write (temp file + rename), in order. */
  save(): Promise<void> {
    if (!this.#file) return Promise.resolve();
    const file = this.#file;
    const body = JSON.stringify(this.schedules, null, 1);
    const next = this.#chain.then(async () => {
      const tmp = `${file}.tmp`;
      await writeFile(tmp, body, { mode: 0o600 });
      await rename(tmp, file);
    });
    // A write error (disk full, permissions) mustn't leave the chain permanently rejected: later saves are still tried.
    this.#chain = next.catch(() => {});
    return next;
  }

  start(intervalMs = 20_000) {
    this.#timer = setInterval(() => void this.tick().catch((e) => console.error("zamanlayıcı:", e)), intervalMs);
    this.#timer.unref();
  }

  stop() {
    if (this.#timer) clearInterval(this.#timer);
  }

  /**
   * Runs tasks that are due for the minutes since the last check (at most the last 2 minutes: short stalls are made
   * up, long outages aren't). The same minute is never evaluated twice.
   */
  async tick() {
    const now = minuteOf(this.#now());
    const from = Math.max(this.#lastMinute + 1, now - 2);
    this.#lastMinute = Math.max(this.#lastMinute, now);
    for (let m = from; m <= now; m++) {
      const d = new Date(m * 60_000);
      for (const s of [...this.schedules]) {
        if (!s.enabled || !dueAt(s, d)) continue;
        // When clocks go back in autumn (e.g. 03:00 → 02:00) the same wall time comes twice: if a daily/weekly task
        // already ran on time within the last 2 hours, the second is skipped.
        const last = s.lastRun && !s.lastRun.manual ? Date.parse(s.lastRun.at) : NaN;
        if (s.when.kind !== "interval" && d.getTime() - last < 2 * 3600_000) continue;
        await this.run(s, false);
      }
    }
  }

  get(id: string): Schedule {
    const s = this.schedules.find((x) => x.id === id);
    if (!s) throw notFound("claude.schedule", { id });
    return s;
  }

  running(s: Schedule): boolean {
    const id = s.lastRun?.sessionId;
    const live = id ? this.#mgr.sessions.get(id) : undefined;
    return !!live && ACTIVE.has(live.status);
  }

  /** Runs the task now. If its previous run is still going, skips it (scheduler) or 409 (manual). */
  async run(s: Schedule, manual: boolean): Promise<string | null> {
    const events = this.#ctx.notifier.events;
    if (this.running(s)) {
      if (manual) throw new AppError("agent.claude.scheduleRunning", 409, { id: s.id });
      void events?.record({ key: "claude.scheduleSkipped", params: { name: s.name, id: s.id }, link: `tiphys://claude/${s.lastRun!.sessionId}` });
      return null;
    }
    const at = this.#now().toISOString();
    try {
      const session = await this.#mgr.start({
        cwd: s.cwd,
        prompt: s.prompt,
        title: `⏰ ${s.name}`,
        permissionMode: s.permissionMode,
        model: s.model,
        effort: s.effort,
        profileId: s.profileId,
      });
      s.lastRun = { at, sessionId: session.id, sdkSessionId: null, ok: null, ...(manual ? { manual: true } : {}) };
      // When the result arrives (the claude.done/claude.error notification is sent separately by manager) the last run is updated.
      const run = s.lastRun;
      const listener = (e: ClaudeEvent) => {
        if (e.kind !== "result" && e.kind !== "error") return;
        session.listeners.delete(listener);
        run.ok = e.kind === "result" ? e.ok : false;
        run.sdkSessionId = session.sdkSessionId;
        void this.save().catch((err) => console.error("claude-schedules.json yazılamadı:", err));
      };
      session.listeners.add(listener);
      // The session started: even if the record can't be written this isn't a "failed to start" (it mustn't fall into
      // the catch below and clear sessionId; otherwise running() returns false and the next tick starts the task again).
      await this.save().catch((err) => console.error("claude-schedules.json yazılamadı:", err));
      void events?.record({ key: "claude.scheduled", params: { name: s.name, id: s.id, ...(manual ? { manual: 1 } : {}) }, link: `tiphys://claude/${session.id}` });
      return session.id;
    } catch (e) {
      const code = e instanceof AppError ? e.code : "agent.internal";
      s.lastRun = { at, sessionId: null, sdkSessionId: null, ok: false, error: code, ...(manual ? { manual: true } : {}) };
      await this.save();
      if (manual) throw e;
      await this.#ctx.notifier.send({ key: "claude.scheduleFailed", params: { name: s.name, id: s.id, reason: code }, link: "tiphys://claude/schedules", priority: "high" });
      return null;
    }
  }

  view(s: Schedule) {
    const live = s.lastRun?.sessionId ? this.#mgr.sessions.get(s.lastRun.sessionId) : undefined;
    return {
      ...s,
      lastRun: s.lastRun ? { ...s.lastRun, live: !!live, sdkSessionId: live?.sdkSessionId ?? s.lastRun.sdkSessionId } : null,
      running: this.running(s),
      nextRun: s.enabled ? (nextRun(s, this.#now())?.toISOString() ?? null) : null,
    };
  }

  async create(input: z.infer<typeof scheduleInputSchema>): Promise<Schedule> {
    await this.#mgr.checkCwd(input.cwd);
    if (this.schedules.length >= 50) throw new AppError("agent.claude.tooManySchedules", 400, { max: 50 });
    const now = this.#now().toISOString();
    const s: Schedule = { ...input, id: randomUUID(), createdAt: now, anchorAt: now, lastRun: null };
    this.schedules.push(s);
    await this.save();
    return s;
  }

  async update(id: string, input: z.infer<typeof scheduleInputSchema>): Promise<Schedule> {
    const s = this.get(id);
    await this.#mgr.checkCwd(input.cwd);
    const whenChanged = JSON.stringify(s.when) !== JSON.stringify(input.when);
    const next: Schedule = { ...input, id: s.id, createdAt: s.createdAt, anchorAt: whenChanged ? this.#now().toISOString() : s.anchorAt, lastRun: s.lastRun };
    this.schedules = this.schedules.map((x) => (x.id === id ? next : x));
    await this.save();
    return next;
  }

  async remove(id: string) {
    this.get(id);
    this.schedules = this.schedules.filter((x) => x.id !== id);
    await this.save();
  }
}

export function scheduleRoutes(app: FastifyInstance, sched: ClaudeScheduler) {
  const idOf = (req: { params: unknown }) => (req.params as { id: string }).id;

  app.get("/v1/claude/schedules", async () => ({ schedules: sched.schedules.map((s) => sched.view(s)) }));

  app.post("/v1/claude/schedules", async (req) => {
    const s = await sched.create(scheduleInputSchema.parse(req.body));
    return { schedule: sched.view(s) };
  });

  app.put("/v1/claude/schedules/:id", async (req) => {
    const s = await sched.update(idOf(req), scheduleInputSchema.parse(req.body));
    return { schedule: sched.view(s) };
  });

  app.delete("/v1/claude/schedules/:id", async (req) => {
    await sched.remove(idOf(req));
    return { ok: true };
  });

  app.post("/v1/claude/schedules/:id/run", async (req) => {
    const s = sched.get(idOf(req));
    const sessionId = await sched.run(s, true);
    return { schedule: sched.view(s), sessionId };
  });
}
