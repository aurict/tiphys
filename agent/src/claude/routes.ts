// Claude HTTP + WebSocket endpoints.
import { readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { listSessions, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { expandHome } from "../config.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import { requireControlFeature, tokenOf } from "../control.ts";
import { realStreamIo } from "../routes/stream.ts";
import { ClaudeManager, type ClaudeEvent, type ControlBinding, type QueryFn } from "./manager.ts";
import { createPcSupport, type PcSupportOpts } from "./pc.ts";
import { ClaudeScheduler, scheduleRoutes } from "./schedules.ts";
import { stopTerminalSession, terminalSessions } from "./terminal.ts";
import { findTranscript, transcriptPage } from "./transcript.ts";

const startSchema = z.strictObject({
  cwd: z.string().min(1),
  prompt: z.string().max(200_000).default(""),
  images: z.array(z.object({ mediaType: z.enum(["image/png", "image/jpeg", "image/gif", "image/webp"]), data: z.base64() })).max(10).optional(),
  profileId: z.string().optional(),
  model: z.string().max(80).optional(),
  effort: z.enum(["low", "medium", "high", "xhigh", "max"]).optional(),
  permissionMode: z.enum(["default", "acceptEdits", "plan", "bypassPermissions"]).optional(),
  resume: z.string().uuid().optional(),
  /** Run the session in a separate git worktree (new branch); the main working tree is unaffected. */
  worktree: z.boolean().optional(),
  /** "pc": Claude uses the PC (desktop + control + X-Tiphys-Control control session token). */
  kind: z.enum(["code", "pc"]).optional(),
});

/** Taking over a terminal session on the phone: session settings (same as for a new session) + explicit confirmation. */
const takeoverSchema = z.strictObject({
  confirm: z.literal(true),
  profileId: startSchema.shape.profileId,
  model: startSchema.shape.model,
  effort: startSchema.shape.effort,
  permissionMode: startSchema.shape.permissionMode,
});

const messageSchema = z.strictObject({
  text: z.string().min(1).max(200_000),
  images: startSchema.shape.images,
  /** Id the phone gives the message: the same message (resent after a timeout) isn't processed twice. */
  clientId: z.string().min(8).max(64).optional(),
});

/** History reading with the profile's config folder (CLAUDE_CONFIG_DIR). */
let profileLock: Promise<unknown> = Promise.resolve();
async function withProfile<T>(mgr: ClaudeManager, profileId: string, fn: () => Promise<T>): Promise<T> {
  // The SDK's listSessions reads the folder from an environment variable; since the variable is process-wide these
  // calls run sequentially (if two profiles were read at once, one's list could come from the other's account).
  const run = profileLock.then(async () => {
    const env = mgr.profileEnv(profileId);
    const prev = process.env.CLAUDE_CONFIG_DIR;
    if (env.CLAUDE_CONFIG_DIR) process.env.CLAUDE_CONFIG_DIR = env.CLAUDE_CONFIG_DIR;
    else delete process.env.CLAUDE_CONFIG_DIR;
    try {
      return await fn();
    } finally {
      if (prev === undefined) delete process.env.CLAUDE_CONFIG_DIR;
      else process.env.CLAUDE_CONFIG_DIR = prev;
    }
  });
  profileLock = run.catch(() => {});
  return run;
}

export function claudeRoutes(
  queryFn: QueryFn,
  opts: {
    persist?: boolean;
    /** Scheduler clock (tests); if given, the scheduler doesn't tick on its own, tests call tick(). */
    now?: () => Date;
    onScheduler?: (s: ClaudeScheduler) => void;
    /** PC tools (fake input/screen and shortcut list in tests). */
    pc?: Partial<PcSupportOpts>;
    onPc?: (pc: ReturnType<typeof createPcSupport>) => void;
    /** Tests: manager (pcTick is called manually with a fake clock; if given, no timer is set up). */
    onManager?: (m: ClaudeManager) => void;
  } = {},
) {
  return async (app: FastifyInstance, ctx: Ctx) => {
    // Live session list sits next to agent.json: sessions come back when the agent restarts (update, crash).
    const statePath = opts.persist === false ? null : join(dirname(ctx.store.path), "claude-sessions.json");
    // PC sessions (10.3): if the desktop panel (hyprRoutes) set up the control session and the Hyprland adapter.
    const pc = ctx.control
      ? createPcSupport(ctx, { io: realStreamIo, shotsDir: join(dirname(ctx.store.path), "claude-shots"), ...opts.pc })
      : null;
    if (pc) opts.onPc?.(pc);
    const mgr = new ClaudeManager(() => ctx.store.get(), ctx.notifier, queryFn, statePath, pc);
    // When the control session ends (stop, expiry, agent shutdown), attached PC sessions stop immediately.
    const offControl = ctx.control?.onEnd((info) => mgr.controlEnded(info.device, info.reason));
    // "Extend" notification 2 min before control time runs out (PC sessions).
    const pcTimer = pc && !opts.onManager ? setInterval(() => mgr.pcTick(), 10_000) : null;
    pcTimer?.unref();
    opts.onManager?.(mgr);
    await mgr.restore();
    // Scheduled tasks: claude-schedules.json (in memory only if persistence is off).
    const scheduler = new ClaudeScheduler(mgr, ctx, statePath && join(dirname(ctx.store.path), "claude-schedules.json"), opts.now);
    await scheduler.load();
    if (!opts.now) scheduler.start();
    opts.onScheduler?.(scheduler);
    scheduleRoutes(app, scheduler);
    app.addHook("onClose", async () => {
      offControl?.();
      if (pcTimer) clearInterval(pcTimer);
      scheduler.stop();
      await mgr.dispose();
    });
    const commandCache = new Map<string, { at: number; value: unknown }>();

    app.get("/v1/claude/sessions", async (req) => {
      const q = req.query as Record<string, string | undefined>;
      const profileId = q.profileId ?? ctx.store.get().claude.defaultProfile;
      const live = [...mgr.sessions.values()].map((s) => s.summary());
      const liveIds = new Set(live.map((s) => s.sdkSessionId));
      const past = await withProfile(mgr, profileId, () => listSessions({ limit: 40 })).catch(() => []);
      // Sessions open outside Tiphys (in a terminal): separated from history and shown in their own list.
      const configDir = mgr.profileEnv(profileId).CLAUDE_CONFIG_DIR ?? expandHome("~/.claude");
      const titles = new Map(past.map((p) => [p.sessionId, p.customTitle ?? p.summary ?? p.firstPrompt ?? ""]));
      const terminal = (await terminalSessions(configDir))
        .filter((t) => !liveIds.has(t.sdkSessionId))
        .map((t) => ({ ...t, title: titles.get(t.sdkSessionId) || t.name || "" }));
      const terminalIds = new Set(terminal.map((t) => t.sdkSessionId));
      return {
        live,
        terminal,
        history: past
          .filter((p) => !liveIds.has(p.sessionId) && !terminalIds.has(p.sessionId) && !p.archived)
          .map((p) => ({
            sdkSessionId: p.sessionId,
            title: p.customTitle ?? p.summary ?? p.firstPrompt ?? "",
            cwd: p.cwd ?? null,
            lastActivity: new Date(p.lastModified).toISOString(),
            gitBranch: p.gitBranch ?? null,
            live: false,
          })),
      };
    });

    /** Control binding for a PC session: features must be enabled and the phone's control session token valid. */
    const controlBinding = async (req: FastifyRequest): Promise<ControlBinding> => {
      if (!pc?.available() || !ctx.control) throw new AppError("agent.claude.pcUnavailable", 403);
      requireControlFeature(ctx);
      const token = tokenOf(req);
      const device = req.device!.id;
      await ctx.control.check(token, device);
      return { token: token!, device };
    };

    /** A PC session is managed only by the device holding control (messages, permission decisions, mode). */
    const pcOwner = (req: FastifyRequest, s: { kind: string; control: ControlBinding | null }) => {
      if (s.kind === "pc" && s.control && s.control.device !== req.device!.id) throw new AppError("agent.control.sessionRequired", 403);
    };

    app.post("/v1/claude/sessions", async (req) => {
      const body = startSchema.parse(req.body);
      const control = body.kind === "pc" ? await controlBinding(req) : undefined;
      const s = await mgr.start({ ...body, control });
      return s.summary();
    });

    // Bind the PC session to the new (or renewed) control session: the phone re-asked the lock and opened a session.
    app.post("/v1/claude/sessions/:id/control", async (req) => {
      const s = mgr.get((req.params as { id: string }).id);
      if (s.kind !== "pc") throw new AppError("agent.claude.notPcSession", 400);
      mgr.bindControl(s, await controlBinding(req));
      return s.summary();
    });

    // Screenshots of the PC session (thumbnails in the chat; last 60 on disk).
    app.get("/v1/claude/shots/:shotId", async (req, reply) => {
      const body = await pc?.shots.read((req.params as { shotId: string }).shotId);
      if (!body) throw new AppError("agent.claude.shotNotFound", 404);
      return reply.header("content-type", "image/jpeg").header("cache-control", "private, max-age=86400").send(body);
    });

    // Take over a terminal session on the phone: the Claude in the terminal is closed, the same session continues here.
    // Only while idle (Claude not running at the moment); taken back on the PC with `claude --resume <id>`.
    app.post("/v1/claude/terminal/:sessionId/takeover", async (req) => {
      const sessionId = (req.params as { sessionId: string }).sessionId;
      const parsed = takeoverSchema.safeParse(req.body ?? {});
      if (!parsed.success) throw new AppError("agent.claude.confirmRequired", 400);
      const b = parsed.data;
      const profileId = b.profileId ?? ctx.store.get().claude.defaultProfile;
      const configDir = mgr.profileEnv(profileId).CLAUDE_CONFIG_DIR ?? expandHome("~/.claude");
      const t = (await terminalSessions(configDir)).find((x) => x.sdkSessionId === sessionId);
      if (!t) throw new AppError("agent.claude.terminalNotFound", 404, { sessionId });
      if (t.status !== "idle") throw new AppError("agent.claude.terminalBusy", 409, { sessionId });
      if (!(await stopTerminalSession(t.pid))) throw new AppError("agent.claude.terminalStuck", 504, { pid: t.pid });
      const s = await mgr.start({ ...b, cwd: t.cwd ?? "~", prompt: "", resume: sessionId, profileId });
      return s.summary();
    });

    app.get("/v1/claude/sessions/:id", async (req) => {
      const s = mgr.get((req.params as { id: string }).id);
      const after = Number((req.query as { after?: string }).after ?? 0);
      return { session: s.summary(), events: s.events.filter((e) => e.seq > after) };
    });

    app.post("/v1/claude/sessions/:id/messages", async (req) => {
      const s = mgr.get((req.params as { id: string }).id);
      pcOwner(req, s);
      const body = messageSchema.parse(req.body);
      const accepted = mgr.send(s, body.text, body.images, body.clientId);
      return { ok: true, duplicate: !accepted };
    });

    app.post("/v1/claude/sessions/:id/interrupt", async (req) => {
      await mgr.interrupt(mgr.get((req.params as { id: string }).id));
      return { ok: true };
    });

    app.post("/v1/claude/sessions/:id/permissions/:requestId", async (req) => {
      const p = req.params as { id: string; requestId: string };
      const body = z.strictObject({ allow: z.boolean(), message: z.string().max(2000).optional() }).parse(req.body);
      const s = mgr.get(p.id);
      pcOwner(req, s);
      mgr.resolvePermission(s, p.requestId, body.allow, body.message);
      return { ok: true };
    });

    app.post("/v1/claude/sessions/:id/mode", async (req) => {
      const s = mgr.get((req.params as { id: string }).id);
      pcOwner(req, s);
      const { permissionMode } = z.object({ permissionMode: startSchema.shape.permissionMode.unwrap() }).parse(req.body);
      await mgr.setMode(s, permissionMode);
      return s.summary();
    });

    app.delete("/v1/claude/sessions/:id", async (req) => {
      const s = mgr.get((req.params as { id: string }).id);
      mgr.close(s.id);
      return { ok: true };
    });

    // Live stream: first the events accumulated after `after`, then new ones.
    app.get("/v1/claude/sessions/:id/stream", { websocket: true }, (socket, req) => {
      let s;
      try {
        s = mgr.get((req.params as { id: string }).id);
      } catch {
        socket.close(4404, "not found");
        return;
      }
      const after = Number((req.query as { after?: string }).after ?? 0);
      // Accumulated events are sent on the next tick: so ones arriving before the client starts listening aren't lost.
      const live = s;
      const queued: ClaudeEvent[] = [];
      let ready = false;
      const listener = (e: ClaudeEvent) => (ready ? socket.send(JSON.stringify(e)) : queued.push(e));
      live.listeners.add(listener);
      setImmediate(() => {
        // First message: this instance's id. If the phone knows a different epoch (agent restarted), it reloads.
        socket.send(JSON.stringify({ kind: "hello", seq: 0, epoch: live.epoch, lastSeq: live.events.at(-1)?.seq ?? 0 }));
        for (const e of live.events) if (e.seq > after && !queued.includes(e)) socket.send(JSON.stringify(e));
        for (const e of queued) if (e.seq > after) socket.send(JSON.stringify(e));
        ready = true;
      });
      const ping = setInterval(() => socket.ping(), 25_000);
      socket.on("close", () => {
        clearInterval(ping);
        live.listeners.delete(listener);
      });
    });

    // Messages of a past session (to read before resuming).
    app.get("/v1/claude/history/:sdkSessionId", async (req) => {
      const id = z.string().uuid().parse((req.params as { sdkSessionId: string }).sdkSessionId);
      const profileId = (req.query as { profileId?: string }).profileId ?? ctx.store.get().claude.defaultProfile;
      const dir = mgr.profileEnv(profileId).CLAUDE_CONFIG_DIR ?? expandHome("~/.claude");
      const file = await findTranscript(dir, id);
      if (!file) throw new AppError("agent.claude.historyNotFound", 404, { id });
      const q = req.query as { skip?: string; limit?: string };
      const skip = Math.max(0, Number(q.skip ?? 0) || 0);
      const limit = Math.min(1000, Math.max(1, Number(q.limit ?? 400) || 400));
      return await transcriptPage(file, limit, skip);
    });

    // Slash commands: the commands Claude actually recognizes for that folder and profile (without an API call).
    app.get("/v1/claude/commands", async (req) => {
      const q = req.query as { cwd?: string; profileId?: string };
      const cwd = await mgr.checkCwd(q.cwd ?? "~");
      const profileId = q.profileId ?? ctx.store.get().claude.defaultProfile;
      const key = `${profileId}:${cwd}`;
      const hit = commandCache.get(key);
      if (hit && Date.now() - hit.at < 10 * 60_000) return hit.value;
      const never: AsyncIterable<SDKUserMessage> = { [Symbol.asyncIterator]: () => ({ next: () => new Promise(() => {}) }) };
      const query = queryFn({ prompt: never, options: { cwd, env: mgr.profileEnv(profileId), settingSources: ["user", "project", "local"], stderr: () => {} } });
      try {
        const cmds = await Promise.race([
          query.supportedCommands(),
          new Promise<never>((_, rej) => setTimeout(() => rej(new AppError("agent.exec.timeout", 504, { command: "claude" })), 45_000)),
        ]);
        const value = { commands: cmds.map((c) => ({ name: c.name, description: c.description, argumentHint: c.argumentHint })) };
        commandCache.set(key, { at: Date.now(), value });
        return value;
      } finally {
        query.close();
      }
    });

    // Folder picker: subfolders under the allowed roots.
    app.get("/v1/fs/dirs", async (req) => {
      const path = (req.query as { path?: string }).path ?? "~";
      const real = await mgr.checkCwd(path);
      const entries = await readdir(real, { withFileTypes: true });
      return {
        path: real,
        home: expandHome("~"),
        dirs: entries
          .filter((e) => e.isDirectory() && !e.name.startsWith("."))
          .map((e) => ({ name: e.name, path: join(real, e.name) }))
          .sort((a, b) => a.name.localeCompare(b.name, "tr")),
      };
    });
  };
}
