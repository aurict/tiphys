// Claude HTTP + WebSocket uçları.
import { readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { listSessions, type SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { expandHome } from "../config.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import { ClaudeManager, type ClaudeEvent, type QueryFn } from "./manager.ts";
import { stopTerminalSession, terminalSessions } from "./terminal.ts";
import { findTranscript, transcriptEvents } from "./transcript.ts";

const startSchema = z.strictObject({
  cwd: z.string().min(1),
  prompt: z.string().max(200_000).default(""),
  images: z.array(z.object({ mediaType: z.enum(["image/png", "image/jpeg", "image/gif", "image/webp"]), data: z.base64() })).max(10).optional(),
  profileId: z.string().optional(),
  model: z.string().max(80).optional(),
  effort: z.enum(["low", "medium", "high", "xhigh", "max"]).optional(),
  permissionMode: z.enum(["default", "acceptEdits", "plan", "bypassPermissions"]).optional(),
  resume: z.string().uuid().optional(),
  /** Oturum ayrı bir git worktree'de (yeni dal) çalışsın; ana çalışma alanı etkilenmez. */
  worktree: z.boolean().optional(),
});

/** Terminaldeki oturumu telefona devralma: oturum ayarları (yeni oturumdakiyle aynı) + açık onay. */
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
});

/** Profilin yapılandırma klasörüyle (CLAUDE_CONFIG_DIR) geçmiş okuma. */
let profileLock: Promise<unknown> = Promise.resolve();
async function withProfile<T>(mgr: ClaudeManager, profileId: string, fn: () => Promise<T>): Promise<T> {
  // SDK'nın listSessions'ı klasörü ortam değişkeninden okur; değişken süreç genelinde olduğundan bu
  // çağrılar sırayla çalışır (iki profil aynı anda okunursa birinin listesi ötekinin hesabından gelmesin).
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

export function claudeRoutes(queryFn: QueryFn, opts: { persist?: boolean } = {}) {
  return async (app: FastifyInstance, ctx: Ctx) => {
    // Canlı oturum listesi agent.json'ın yanında: ajan yeniden başlayınca (güncelleme, çökme) oturumlar geri gelir.
    const statePath = opts.persist === false ? null : join(dirname(ctx.store.path), "claude-sessions.json");
    const mgr = new ClaudeManager(() => ctx.store.get(), ctx.notifier, queryFn, statePath);
    await mgr.restore();
    app.addHook("onClose", async () => mgr.dispose());
    const commandCache = new Map<string, { at: number; value: unknown }>();

    app.get("/v1/claude/sessions", async (req) => {
      const q = req.query as Record<string, string | undefined>;
      const profileId = q.profileId ?? ctx.store.get().claude.defaultProfile;
      const live = [...mgr.sessions.values()].map((s) => s.summary());
      const liveIds = new Set(live.map((s) => s.sdkSessionId));
      const past = await withProfile(mgr, profileId, () => listSessions({ limit: 40 })).catch(() => []);
      // Tiphys dışında (terminalde) açık oturumlar: geçmişten ayrılıp kendi listesinde gösterilir.
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

    app.post("/v1/claude/sessions", async (req) => {
      const body = startSchema.parse(req.body);
      const s = await mgr.start(body);
      return s.summary();
    });

    // Terminalde açık oturumu telefona devral: terminaldeki Claude kapatılır, aynı oturum burada sürdürülür.
    // Yalnız boştayken (Claude o an çalışmıyorken); PC'de `claude --resume <id>` ile geri alınır.
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
      const body = messageSchema.parse(req.body);
      mgr.send(s, body.text, body.images);
      return { ok: true };
    });

    app.post("/v1/claude/sessions/:id/interrupt", async (req) => {
      await mgr.interrupt(mgr.get((req.params as { id: string }).id));
      return { ok: true };
    });

    app.post("/v1/claude/sessions/:id/permissions/:requestId", async (req) => {
      const p = req.params as { id: string; requestId: string };
      const body = z.strictObject({ allow: z.boolean(), message: z.string().max(2000).optional() }).parse(req.body);
      mgr.resolvePermission(mgr.get(p.id), p.requestId, body.allow, body.message);
      return { ok: true };
    });

    app.post("/v1/claude/sessions/:id/mode", async (req) => {
      const s = mgr.get((req.params as { id: string }).id);
      const { permissionMode } = z.object({ permissionMode: startSchema.shape.permissionMode.unwrap() }).parse(req.body);
      await mgr.setMode(s, permissionMode);
      return s.summary();
    });

    app.delete("/v1/claude/sessions/:id", async (req) => {
      const s = mgr.get((req.params as { id: string }).id);
      mgr.close(s.id);
      return { ok: true };
    });

    // Canlı akış: önce `after`dan sonraki birikmiş olaylar, sonra yeniler.
    app.get("/v1/claude/sessions/:id/stream", { websocket: true }, (socket, req) => {
      let s;
      try {
        s = mgr.get((req.params as { id: string }).id);
      } catch {
        socket.close(4404, "not found");
        return;
      }
      const after = Number((req.query as { after?: string }).after ?? 0);
      // Birikmiş olaylar bir sonraki turda gönderilir: istemci dinlemeye başlamadan gelenler kaybolmasın.
      const live = s;
      const queued: ClaudeEvent[] = [];
      let ready = false;
      const listener = (e: ClaudeEvent) => (ready ? socket.send(JSON.stringify(e)) : queued.push(e));
      live.listeners.add(listener);
      setImmediate(() => {
        // İlk mesaj: bu örneğin kimliği. Telefon farklı bir epoch biliyorsa (ajan yeniden başladı) yeniden yükler.
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

    // Geçmiş bir oturumun mesajları (devam etmeden önce okumak için).
    app.get("/v1/claude/history/:sdkSessionId", async (req) => {
      const id = z.string().uuid().parse((req.params as { sdkSessionId: string }).sdkSessionId);
      const profileId = (req.query as { profileId?: string }).profileId ?? ctx.store.get().claude.defaultProfile;
      const dir = mgr.profileEnv(profileId).CLAUDE_CONFIG_DIR ?? expandHome("~/.claude");
      const file = await findTranscript(dir, id);
      if (!file) throw new AppError("agent.claude.historyNotFound", 404, { id });
      return { events: await transcriptEvents(file, 400) };
    });

    // Slash komutları: o klasör ve profil için Claude'un gerçekten tanıdığı komutlar (API çağrısı yapmadan).
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

    // Klasör seçici: izinli kökler altındaki alt klasörler.
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
