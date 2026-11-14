// Claude oturumları: Claude Agent SDK ile, ajanda yaşar. Telefon bağlantısı kopsa da çalışmaya devam eder.
// Her oturum tek bir query() çağrısıdır; mesajlar bir kuyruk üzerinden akar (çalışırken yeni mesaj sıraya girer).
import { randomUUID } from "node:crypto";
import { readFile, realpath, rename, writeFile } from "node:fs/promises";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import type {
  CanUseTool,
  EffortLevel,
  Options,
  PermissionMode,
  PermissionResult,
  Query,
  SDKMessage,
  SDKUserMessage,
} from "@anthropic-ai/claude-agent-sdk";
import { expandHome, type AgentConfig } from "../config.ts";
import { AppError, notFound } from "../errors.ts";
import { run } from "../exec.ts";
import type { Notifier } from "../notify.ts";
import { findTranscript, transcriptEvents } from "./transcript.ts";

export type QueryFn = (p: { prompt: AsyncIterable<SDKUserMessage>; options: Options }) => Query;

export type SessionStatus = "starting" | "running" | "waiting" | "idle" | "error" | "stopped";

/** Telefona giden sadeleştirilmiş olaylar. */
export type ClaudeEvent = { seq: number; at: string } & (
  | { kind: "user"; text: string; images: number }
  | { kind: "text"; text: string }
  | { kind: "delta"; text: string }
  | { kind: "thinking"; text: string }
  | { kind: "tool_use"; id: string; name: string; input: unknown }
  | { kind: "tool_result"; toolUseId: string; text: string; isError: boolean }
  | { kind: "init"; model: string; cwd: string; permissionMode: string; slashCommands: string[] }
  | {
      kind: "result";
      ok: boolean;
      subtype: string;
      text: string;
      costUsd: number;
      turns: number;
      durationMs: number;
      contextTokens: number | null;
      contextWindow: number | null;
    }
  | { kind: "permission"; requestId: string; toolName: string; input: unknown; reason: string | null }
  | { kind: "permissionResolved"; requestId: string; allow: boolean }
  | { kind: "status"; status: SessionStatus }
  | { kind: "error"; message: string }
  /** Ajan yeniden başladı; oturum diskteki kayıttan geri yüklendi, kaldığı yerden sürer. */
  | { kind: "restored" }
  /** Geçmişte sıkıştırma (compact) noktası. */
  | { kind: "compacted" }
);

type EventBody = ClaudeEvent extends infer E ? (E extends unknown ? Omit<E, "seq" | "at"> : never) : never;

export interface StartRequest {
  cwd: string;
  prompt: string;
  images?: Array<{ mediaType: string; data: string }>;
  profileId?: string;
  model?: string;
  effort?: EffortLevel;
  permissionMode?: PermissionMode;
  resume?: string;
  worktree?: boolean;
}

const MAX_EVENTS = 3000;

/** Diskte tutulan canlı oturum bilgisi (sohbet içeriği değil; o Claude'un kendi kaydında). */
interface PersistedSession {
  id: string;
  sdkSessionId: string | null;
  cwd: string;
  profileId: string;
  model: string;
  effort: EffortLevel | undefined;
  permissionMode: PermissionMode;
  title: string;
  createdAt: string;
  costUsd: number;
}
const MAX_TEXT = 20000;

/** Basit itilebilir async kuyruk (query'ye giden kullanıcı mesajları). */
class Inbox implements AsyncIterable<SDKUserMessage> {
  #items: SDKUserMessage[] = [];
  #wake: (() => void) | null = null;
  #closed = false;
  push(m: SDKUserMessage) {
    this.#items.push(m);
    this.#wake?.();
  }
  close() {
    this.#closed = true;
    this.#wake?.();
  }
  async *[Symbol.asyncIterator]() {
    while (true) {
      const next = this.#items.shift();
      if (next) {
        yield next;
        continue;
      }
      if (this.#closed) return;
      await new Promise<void>((r) => (this.#wake = r));
      this.#wake = null;
    }
  }
}

export class LiveSession {
  readonly id: string; // telefonun bildiği kimlik (ajan yeniden başlasa da aynı kalır)
  /**
   * Bu bellek içi örneğin kimliği. Ajan yeniden başlayınca oturum aynı `id` ile geri gelir ama olay sıra
   * numaraları baştan başlar; telefon `epoch` değişince olaylarını sıfırlayıp yeniden yükler.
   */
  readonly epoch = randomUUID();
  sdkSessionId: string | null = null;
  readonly cwd: string;
  readonly profileId: string;
  model: string;
  permissionMode: PermissionMode;
  effort: EffortLevel | undefined;
  status: SessionStatus = "starting";
  title: string;
  createdAt = new Date().toISOString();
  lastActivity = Date.now();
  costUsd = 0;
  /** Son model çağrısının girdi boyutu (bağlam doluluğu) ve modelin bağlam penceresi. */
  contextTokens: number | null = null;
  contextWindow: number | null = null;
  events: ClaudeEvent[] = [];
  #seq = 0;
  readonly inbox = new Inbox();
  query: Query | null = null;
  /** Claude süreci ilk mesajda başlatılır (boş/geri yüklenen oturum bellek harcamasın). */
  options: Options | null = null;
  readonly pending = new Map<string, (r: PermissionResult) => void>();
  readonly listeners = new Set<(e: ClaudeEvent) => void>();
  /** Son alınan mesaj kimlikleri (tekrar gönderimi ayıklamak için; en fazla 200). */
  readonly seenClientIds = new Set<string>();

  constructor(cwd: string, profileId: string, model: string, permissionMode: PermissionMode, title: string, id?: string) {
    this.id = id ?? randomUUID();
    this.cwd = cwd;
    this.profileId = profileId;
    this.model = model;
    this.permissionMode = permissionMode;
    this.title = title.slice(0, 120);
  }

  emit(body: EventBody) {
    const e = { ...body, seq: ++this.#seq, at: new Date().toISOString() } as ClaudeEvent;
    // Akan metin parçaları geçmişte tutulmaz (tam metin "text" olayıyla gelir).
    if (e.kind !== "delta") {
      this.events.push(e);
      if (this.events.length > MAX_EVENTS) this.events.splice(0, this.events.length - MAX_EVENTS);
    }
    this.lastActivity = Date.now();
    for (const l of this.listeners) l(e);
  }

  /** Diskteki kayıttan gelen geçmiş olayları (geri yüklemede). */
  loadHistory(events: Array<Record<string, unknown>>) {
    for (const e of events) {
      const { seq: _seq, ...body } = e;
      this.events.push({ ...body, seq: ++this.#seq, at: this.createdAt } as ClaudeEvent);
    }
  }

  setStatus(s: SessionStatus) {
    if (this.status === s) return;
    this.status = s;
    this.emit({ kind: "status", status: s });
  }

  summary() {
    return {
      id: this.id,
      epoch: this.epoch,
      sdkSessionId: this.sdkSessionId,
      cwd: this.cwd,
      title: this.title,
      status: this.status,
      model: this.model,
      permissionMode: this.permissionMode,
      profileId: this.profileId,
      costUsd: this.costUsd,
      contextTokens: this.contextTokens,
      contextWindow: this.contextWindow,
      createdAt: this.createdAt,
      lastActivity: new Date(this.lastActivity).toISOString(),
      pendingPermissions: this.pending.size,
      live: true,
    };
  }
}

function clip(s: string) {
  return s.length > MAX_TEXT ? `${s.slice(0, MAX_TEXT)}\n… (${s.length - MAX_TEXT} karakter kısaltıldı)` : s;
}

function blockText(content: unknown): string {
  if (typeof content === "string") return content;
  if (Array.isArray(content)) {
    return content
      .map((b) => (b && typeof b === "object" && "text" in b && typeof (b as { text: unknown }).text === "string" ? (b as { text: string }).text : ""))
      .join("");
  }
  return "";
}

/** SDK mesajını telefon olaylarına çevirir. Testlerde de kullanılır. */
export function translate(s: LiveSession, m: SDKMessage) {
  switch (m.type) {
    case "system":
      if ("subtype" in m && m.subtype === "init") {
        s.sdkSessionId = m.session_id;
        s.model = m.model;
        s.emit({ kind: "init", model: m.model, cwd: m.cwd, permissionMode: m.permissionMode, slashCommands: m.slash_commands });
      }
      return;
    case "assistant": {
      if (m.parent_tool_use_id) return; // alt ajan içerikleri ana akışa karışmasın
      const u = m.message.usage;
      if (u) s.contextTokens = (u.input_tokens ?? 0) + (u.cache_read_input_tokens ?? 0) + (u.cache_creation_input_tokens ?? 0);
      for (const b of m.message.content) {
        if (b.type === "text") s.emit({ kind: "text", text: clip(b.text) });
        else if (b.type === "thinking" && b.thinking) s.emit({ kind: "thinking", text: clip(b.thinking) });
        else if (b.type === "tool_use") s.emit({ kind: "tool_use", id: b.id, name: b.name, input: b.input });
      }
      return;
    }
    case "user": {
      if (m.parent_tool_use_id) return;
      const content = m.message.content;
      if (Array.isArray(content)) {
        for (const b of content) {
          if (b.type === "tool_result") {
            s.emit({ kind: "tool_result", toolUseId: b.tool_use_id, text: clip(blockText(b.content)), isError: b.is_error === true });
          }
        }
      }
      return;
    }
    case "stream_event": {
      const ev = m.event;
      if (!m.parent_tool_use_id && ev.type === "content_block_delta" && ev.delta.type === "text_delta") {
        s.emit({ kind: "delta", text: ev.delta.text });
      }
      return;
    }
    case "result": {
      s.costUsd = m.total_cost_usd;
      s.sdkSessionId = m.session_id;
      const windows = Object.values(m.modelUsage ?? {})
        .map((x) => x.contextWindow)
        .filter((x): x is number => typeof x === "number" && x > 0);
      if (windows.length) s.contextWindow = Math.max(...windows);
      s.emit({
        kind: "result",
        ok: m.subtype === "success" && !m.is_error,
        subtype: m.subtype,
        text: m.subtype === "success" ? clip(m.result) : "",
        costUsd: m.total_cost_usd,
        turns: m.num_turns,
        durationMs: m.duration_ms,
        contextTokens: s.contextTokens,
        contextWindow: s.contextWindow,
      });
      return;
    }
    default:
      return;
  }
}

export class ClaudeManager {
  readonly sessions = new Map<string, LiveSession>();
  #getConfig: () => AgentConfig;
  #notifier: Notifier;
  #query: QueryFn;
  #sweep: NodeJS.Timeout;
  /** Canlı oturumların listesi (ajan yeniden başlayınca geri yüklenir). null: kalıcılık yok (testler). */
  #statePath: string | null;
  #saveTimer: NodeJS.Timeout | null = null;

  constructor(getConfig: () => AgentConfig, notifier: Notifier, queryFn: QueryFn, statePath: string | null = null) {
    this.#getConfig = getConfig;
    this.#notifier = notifier;
    this.#query = queryFn;
    this.#statePath = statePath;
    // 6 saattir hareketsiz ve boşta olan oturumlar kapatılır (geçmiş diskte kalır, devam edilebilir).
    this.#sweep = setInterval(() => {
      const cutoff = Date.now() - 6 * 3600_000;
      for (const s of this.sessions.values()) {
        if (s.lastActivity < cutoff && (s.status === "idle" || s.status === "error" || s.status === "stopped")) this.close(s.id);
      }
    }, 600_000);
    this.#sweep.unref();
  }

  get(id: string): LiveSession {
    const s = this.sessions.get(id) ?? [...this.sessions.values()].find((x) => x.sdkSessionId === id);
    if (!s) throw notFound("claude.session", { id });
    return s;
  }

  /** Klasör izinli köklerden birinin içinde mi? (sembolik bağlar çözülerek) */
  async checkCwd(cwd: string): Promise<string> {
    let real: string;
    try {
      real = await realpath(expandHome(cwd));
    } catch {
      throw new AppError("agent.claude.folderNotFound", 404, { cwd });
    }
    const roots = await Promise.all(this.#getConfig().allowedRoots.map((r) => realpath(expandHome(r)).catch(() => null)));
    const ok = roots.some((r) => r !== null && (real === r || real.startsWith(r.endsWith(sep) ? r : r + sep)));
    if (!ok) throw new AppError("agent.claude.folderNotAllowed", 403, { cwd });
    return real;
  }

  profileEnv(profileId: string): Record<string, string | undefined> {
    const c = this.#getConfig().claude;
    const dir = c.profiles[profileId];
    if (!dir) throw new AppError("agent.claude.unknownProfile", 400, { profileId });
    const env: Record<string, string | undefined> = { ...process.env };
    // Varsayılan ~/.claude için değişken olmamalı (Claude kendi varsayılanını kullanır). Açıkça silinir:
    // ortamda başka bir profilden kalmış değer olsa bile oturum yanlış hesapla açılmasın.
    if (resolve(expandHome(dir)) !== resolve(expandHome("~/.claude"))) env.CLAUDE_CONFIG_DIR = expandHome(dir);
    else delete env.CLAUDE_CONFIG_DIR;
    return env;
  }

  /** Klasörün git deposunda kardeş bir worktree açar (dal: tiphys/<kısa-id>); aynı alt klasöre karşılık gelen yolu döner. */
  async createWorktree(cwd: string, shortId: string): Promise<string> {
    const top = await run("git", ["-C", cwd, "rev-parse", "--show-toplevel"], { allowFail: true });
    if (top.code !== 0) throw new AppError("agent.claude.notGitRepo", 400, { cwd });
    const root = top.stdout.trim();
    const target = join(dirname(root), `${basename(root)}-tiphys-${shortId}`);
    const res = await run("git", ["-C", root, "worktree", "add", "-b", `tiphys/${shortId}`, target, "HEAD"], {
      allowFail: true,
      timeoutMs: 60000,
      env: { GIT_TERMINAL_PROMPT: "0" },
    });
    if (res.code !== 0) throw new AppError("agent.claude.worktreeFailed", 502, { stderr: res.stderr.slice(0, 1000) });
    const sub = relative(root, cwd);
    return this.checkCwd(sub ? join(target, sub) : target);
  }

  async start(req: StartRequest): Promise<LiveSession> {
    const cfg = this.#getConfig().claude;
    let cwd = await this.checkCwd(req.cwd);
    if (req.worktree) cwd = await this.createWorktree(cwd, randomUUID().slice(0, 8));
    const profileId = req.profileId ?? cfg.defaultProfile;
    // İlk mesajsız (boş) oturum: başlık ilk gönderilen mesajdan alınır.
    const s = this.#create({ ...req, cwd, profileId }, req.prompt || (req.resume ? "(devam)" : ""));
    this.sessions.set(s.id, s);
    if (req.prompt) this.send(s, req.prompt, req.images);
    // Mesajsız açılan (ya da mesajsız devam ettirilen) oturum ilk mesajı bekler; süreç o zaman başlar.
    else s.setStatus("idle");
    this.#save();
    return s;
  }

  /** Oturum nesnesi + SDK seçenekleri (Claude süreci henüz başlamaz, bkz. #launch). */
  #create(req: StartRequest & { profileId: string }, title: string, id?: string): LiveSession {
    const mode = req.permissionMode ?? "default";
    const s = new LiveSession(req.cwd, req.profileId, req.model ?? "", mode, title, id);
    s.effort = req.effort;
    const canUseTool: CanUseTool = (toolName, input, opts) =>
      new Promise<PermissionResult>((resolvePermission) => {
        const requestId = randomUUID();
        const done = (r: PermissionResult) => {
          if (!s.pending.delete(requestId)) return;
          s.emit({ kind: "permissionResolved", requestId, allow: r.behavior === "allow" });
          s.setStatus(s.pending.size > 0 ? "waiting" : "running");
          resolvePermission(r);
        };
        s.pending.set(requestId, done);
        opts.signal.addEventListener("abort", () => done({ behavior: "deny", message: "aborted" }), { once: true });
        s.emit({ kind: "permission", requestId, toolName, input, reason: opts.decisionReason ?? null });
        s.setStatus("waiting");
        void this.#notifier.send({
          key: "claude.waiting",
          params: { title: s.title, tool: toolName },
          link: `tiphys://claude/${s.id}`,
          priority: "high",
          // Telefon bildirimdeki "İzin ver / Reddet" düğmeleriyle uygulamayı açmadan karar verebilsin.
          data: { sessionId: s.id, requestId },
        });
      });
    s.options = {
      cwd: req.cwd,
      env: this.profileEnv(req.profileId),
      settingSources: ["user", "project", "local"],
      includePartialMessages: true,
      permissionMode: mode,
      ...(mode === "bypassPermissions" ? { allowDangerouslySkipPermissions: true } : { canUseTool }),
      ...(req.model ? { model: req.model } : {}),
      ...(req.effort ? { effort: req.effort } : {}),
      ...(req.resume ? { resume: req.resume } : {}),
      stderr: () => {},
    };
    return s;
  }

  /** Claude sürecini başlatır (ilk mesajla). */
  #launch(s: LiveSession) {
    if (s.query || !s.options) return;
    s.query = this.#query({ prompt: s.inbox, options: s.options });
    void this.#pump(s);
  }

  /** Ajan yeniden başladıysa önceki canlı oturumları aynı kimlikle, boşta olarak geri getirir. */
  async restore(): Promise<number> {
    if (!this.#statePath) return 0;
    let list: PersistedSession[];
    try {
      list = JSON.parse(await readFile(this.#statePath, "utf8")) as PersistedSession[];
    } catch {
      return 0;
    }
    let n = 0;
    for (const p of list) {
      try {
        const cwd = await this.checkCwd(p.cwd);
        const s = this.#create({ cwd, profileId: p.profileId, prompt: "", model: p.model || undefined, effort: p.effort, permissionMode: p.permissionMode, resume: p.sdkSessionId ?? undefined }, p.title, p.id);
        s.sdkSessionId = p.sdkSessionId;
        s.createdAt = p.createdAt;
        s.costUsd = p.costUsd;
        if (p.sdkSessionId) {
          const dir = s.options!.env?.CLAUDE_CONFIG_DIR ?? expandHome("~/.claude");
          const file = await findTranscript(dir, p.sdkSessionId);
          if (file) s.loadHistory(await transcriptEvents(file, 400));
        }
        s.emit({ kind: "restored" });
        s.setStatus("idle");
        this.sessions.set(s.id, s);
        n++;
      } catch {
        // klasör silinmiş/izin dışı: bu oturum geri gelmez (geçmişi diskte durur)
      }
    }
    this.#save();
    return n;
  }

  /** Oturum listesini diske yazar (kısa gecikmeyle, art arda değişiklikler tek yazım). */
  #save() {
    if (!this.#statePath || this.#saveTimer) return;
    this.#saveTimer = setTimeout(() => {
      this.#saveTimer = null;
      this.saveNow().catch((e) => console.error("claude-sessions.json yazılamadı:", e));
    }, 300);
    this.#saveTimer.unref();
  }

  async saveNow() {
    if (!this.#statePath) return;
    const list: PersistedSession[] = [...this.sessions.values()].map((s) => ({
      id: s.id,
      sdkSessionId: s.sdkSessionId,
      cwd: s.cwd,
      profileId: s.profileId,
      model: s.model,
      effort: s.effort,
      permissionMode: s.permissionMode,
      title: s.title,
      createdAt: s.createdAt,
      costUsd: s.costUsd,
    }));
    const tmp = `${this.#statePath}.tmp`;
    await writeFile(tmp, JSON.stringify(list, null, 1), { mode: 0o600 });
    await rename(tmp, this.#statePath);
  }

  async #pump(s: LiveSession) {
    try {
      for await (const m of s.query!) {
        const before = s.sdkSessionId;
        translate(s, m);
        if (s.sdkSessionId !== before || m.type === "result") this.#save();
        if (m.type === "result") {
          const ok = m.subtype === "success" && !m.is_error;
          s.setStatus(ok ? "idle" : "error");
          void this.#notifier.send({
            key: ok ? "claude.done" : "claude.error",
            params: { title: s.title, cost: Math.round(m.total_cost_usd * 100) / 100 },
            link: `tiphys://claude/${s.id}`,
          });
        }
      }
      if (s.status !== "error") s.setStatus("stopped");
    } catch (e) {
      if (!this.sessions.has(s.id)) return; // kullanıcı kapattı: hata bildirimi gönderme
      // Ölü süreci bırak: sonraki mesaj yeni bir Claude süreci başlatır ve konuşmayı kaldığı yerden sürdürür.
      s.query = null;
      if (s.options && s.sdkSessionId) s.options.resume = s.sdkSessionId;
      s.emit({ kind: "error", message: e instanceof Error ? e.message : String(e) });
      s.setStatus("error");
      void this.#notifier.send({ key: "claude.error", params: { title: s.title }, link: `tiphys://claude/${s.id}` });
    }
  }

  /** Mesajı kuyruğa koyar. Aynı `clientId` daha önce geldiyse hiçbir şey yapmaz ve false döner. */
  send(s: LiveSession, text: string, images: Array<{ mediaType: string; data: string }> = [], clientId?: string): boolean {
    if (s.status === "stopped") throw new AppError("agent.claude.sessionStopped", 409, { id: s.id });
    if (clientId) {
      if (s.seenClientIds.has(clientId)) return false;
      s.seenClientIds.add(clientId);
      if (s.seenClientIds.size > 200) s.seenClientIds.delete(s.seenClientIds.values().next().value!);
    }
    const content = [
      ...images.map((i) => ({ type: "image" as const, source: { type: "base64" as const, media_type: i.mediaType as "image/png", data: i.data } })),
      { type: "text" as const, text },
    ];
    if (!s.title || s.title === "(devam)") {
      s.title = text.slice(0, 120);
      this.#save();
    }
    s.inbox.push({ type: "user", message: { role: "user", content }, parent_tool_use_id: null, origin: { kind: "human" } });
    s.emit({ kind: "user", text, images: images.length });
    if (s.status === "idle" || s.status === "error") s.setStatus("running");
    this.#launch(s);
    return true;
  }

  async interrupt(s: LiveSession) {
    for (const done of [...s.pending.values()]) done({ behavior: "deny", message: "interrupted", interrupt: true });
    await s.query?.interrupt();
  }

  resolvePermission(s: LiveSession, requestId: string, allow: boolean, message?: string) {
    const done = s.pending.get(requestId);
    if (!done) throw notFound("claude.permission", { requestId });
    done(allow ? { behavior: "allow" } : { behavior: "deny", message: message || "Kullanıcı reddetti" });
  }

  async setMode(s: LiveSession, mode: PermissionMode) {
    if (mode === "bypassPermissions" && s.permissionMode !== "bypassPermissions") {
      // Baştan izinsiz başlatılmamış oturum sonradan izinsize geçemez (SDK güvenlik kuralı).
      throw new AppError("agent.claude.bypassNeedsNewSession", 400);
    }
    if (s.query) await s.query.setPermissionMode(mode);
    else if (s.options) s.options.permissionMode = mode; // süreç henüz başlamadı
    s.permissionMode = mode;
    this.#save();
  }

  close(id: string) {
    const s = this.sessions.get(id);
    if (!s) return;
    for (const done of [...s.pending.values()]) done({ behavior: "deny", message: "closed" });
    s.inbox.close();
    s.query?.close();
    s.setStatus("stopped");
    s.listeners.clear();
    this.sessions.delete(id);
    this.#save();
  }

  /** Ajan kapanırken: oturum listesi diskte kalır (yeniden başlayınca geri gelir), süreçler kapatılır. */
  async dispose() {
    clearInterval(this.#sweep);
    if (this.#saveTimer) clearTimeout(this.#saveTimer);
    await this.saveNow().catch(() => {});
    for (const s of this.sessions.values()) {
      for (const done of [...s.pending.values()]) done({ behavior: "deny", message: "closed" });
      s.inbox.close();
      s.query?.close();
    }
    this.sessions.clear();
  }
}
