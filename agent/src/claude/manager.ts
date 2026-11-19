// Claude sessions: run in the agent via the Claude Agent SDK. They keep running even if the phone disconnects.
// Each session is a single query() call; messages flow through a queue (a new message is queued while one runs).
import { randomUUID } from "node:crypto";
import { homedir } from "node:os";
import { readFile, realpath, rename, writeFile } from "node:fs/promises";
import { basename, dirname, join, relative, resolve, sep } from "node:path";
import type {
  CanUseTool,
  EffortLevel,
  McpServerConfig,
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
import { PC_DISALLOWED_TOOLS, PC_SERVER, PC_SYSTEM_PROMPT, PC_TOOLS, SHOT_MARK, pcToolName } from "./pc.ts";
import { findTranscript, transcriptEvents } from "./transcript.ts";

export type QueryFn = (p: { prompt: AsyncIterable<SDKUserMessage>; options: Options }) => Query;

export type SessionStatus = "starting" | "running" | "waiting" | "idle" | "error" | "stopped";

/** "code": regular session working in a folder; "pc": Claude uses the PC (10.3, PC tools only). */
export type SessionKind = "code" | "pc";

/** The control session a PC session is bound to (token kept in memory only; never written to disk). */
export interface ControlBinding {
  token: string;
  device: string;
}

/** What the PC tools ask of the manager. */
export interface PcHooks {
  /** Approval from the phone (permission card + claude.waiting notification); true = allowed. */
  approve: (reason: string, input: Record<string, unknown>, signal?: AbortSignal) => Promise<boolean>;
  /** A tool noticed the control session has ended. */
  lost: () => void;
}

/** PC support (claude/pc.ts; agent with the "desktop" feature). */
export interface PcSupport {
  available(): boolean;
  server(s: LiveSession, hooks: PcHooks): McpServerConfig;
  /** End time of the bound control session, if it is valid. */
  controlUntil(s: LiveSession): string | null;
  /** Clock (same as the control sessions'; fake in tests). */
  now(): number;
  forget(id: string): void;
}

/** Simplified events sent to the phone. */
export type ClaudeEvent = { seq: number; at: string } & (
  | { kind: "user"; text: string; images: number }
  | { kind: "text"; text: string }
  | { kind: "delta"; text: string }
  | { kind: "thinking"; text: string }
  | { kind: "tool_use"; id: string; name: string; input: unknown }
  | { kind: "tool_result"; toolUseId: string; text: string; isError: boolean; shot?: string }
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
  /** The PC session's control binding opened/closed (reason: stopped | expired | shutdown | lost). */
  | { kind: "control"; active: boolean; expiresAt: string | null; reason: string | null }
  | { kind: "status"; status: SessionStatus }
  | { kind: "error"; message: string }
  /** The agent restarted; the session was restored from the on-disk record and continues where it left off. */
  | { kind: "restored" }
  /** A compaction (compact) point in the history. */
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
  /** Session title (scheduled task: "⏰ name"); defaults to the first message. */
  title?: string;
  kind?: SessionKind;
  /** "pc": the control session opened by the phone (lock re-prompted). */
  control?: ControlBinding;
}

const MAX_EVENTS = 3000;

/** Live session info kept on disk (not the chat content; that lives in Claude's own transcript). */
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
  kind?: SessionKind;
}
const MAX_TEXT = 20000;

/** Simple pushable async queue (user messages going to query()). */
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
  readonly id: string; // the id the phone knows (stays the same even if the agent restarts)
  /**
   * Id of this in-memory instance. When the agent restarts the session comes back with the same `id`, but event
   * sequence numbers start over; when `epoch` changes the phone resets and reloads its events.
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
  /** Last cumulative cost reported by the current Claude process (the SDK accumulates per process; 0 in a new one). */
  processCostUsd = 0;
  /** Input size of the last model call (context fill) and the model's context window. */
  contextTokens: number | null = null;
  contextWindow: number | null = null;
  events: ClaudeEvent[] = [];
  #seq = 0;
  readonly inbox = new Inbox();
  query: Query | null = null;
  /** The Claude process is started on the first message (so empty/restored sessions don't use memory). */
  options: Options | null = null;
  readonly pending = new Map<string, (r: PermissionResult) => void>();
  readonly listeners = new Set<(e: ClaudeEvent) => void>();
  /** Recently received message ids (to filter out resends; at most 200). */
  readonly seenClientIds = new Set<string>();
  kind: SessionKind = "code";
  /** "pc": bound control session; null once it ends (tools don't work). */
  control: ControlBinding | null = null;
  /** Stopped because control ended: the result doesn't count as an "error" and no notification is sent. */
  controlStopped = false;
  /** The "control ends in 2 min" notification was sent for this end time (re-sent after an extension). */
  pcWarnedFor: string | null = null;
  /** End of the bound control session (set by the manager). */
  controlUntil: () => string | null = () => null;

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
    // Streamed text chunks are not kept in the history (the full text arrives with the "text" event).
    if (e.kind !== "delta") {
      this.events.push(e);
      if (this.events.length > MAX_EVENTS) this.events.splice(0, this.events.length - MAX_EVENTS);
    }
    this.lastActivity = Date.now();
    for (const l of this.listeners) l(e);
  }

  /** History events from the on-disk transcript (on restore). */
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
      // "Continue on the PC": run in a terminal there (after stopping it here).
      resumeCommand:
        this.sdkSessionId && /^[A-Za-z0-9-]{8,80}$/.test(this.sdkSessionId) ? `cd '${this.cwd.replace(/'/g, `'\\''`)}' && claude --resume ${this.sdkSessionId}` : null,
      kind: this.kind,
      ...(this.kind === "pc" ? { control: { active: this.control !== null && this.controlUntil() !== null, expiresAt: this.controlUntil() } } : {}),
    };
  }
}

const EDIT_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit"]);

/**
 * Summary of what happened since the last user message (for the done notification): number of changed files and
 * the first meaningful line of the reply (Markdown markup stripped, at most 160 characters).
 */
export function turnSummary(s: LiveSession, resultText: string): { files: number; summary: string } {
  const files = new Set<string>();
  for (let i = s.events.length - 1; i >= 0; i--) {
    const e = s.events[i]!;
    if (e.kind === "user") break;
    if (e.kind === "tool_use" && EDIT_TOOLS.has(e.name) && e.input && typeof e.input === "object") {
      const inp = e.input as { file_path?: unknown; notebook_path?: unknown };
      const p = typeof inp.file_path === "string" ? inp.file_path : typeof inp.notebook_path === "string" ? inp.notebook_path : null;
      if (p) files.add(p);
    }
  }
  const line =
    resultText
      .split("\n")
      .map((l) => l.replace(/^[\s#>*\-+`|]+/, "").replace(/[*`_]/g, "").trim())
      .find((l) => l.length > 0) ?? "";
  return { files: files.size, summary: line.length > 160 ? `${line.slice(0, 159)}…` : line };
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

/** Converts an SDK message into phone events. Also used in tests. */
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
      if (m.parent_tool_use_id) return; // keep subagent content out of the main stream
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
            const text = clip(blockText(b.content));
            // PC screenshot: the image doesn't go into the event stream; the id of its on-disk copy does.
            const hasImage = Array.isArray(b.content) && b.content.some((x) => x && typeof x === "object" && (x as { type?: unknown }).type === "image");
            const shot = hasImage ? SHOT_MARK.exec(text)?.[1] : undefined;
            s.emit({ kind: "tool_result", toolUseId: b.tool_use_id, text, isError: b.is_error === true, ...(shot ? { shot } : {}) });
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
  /** List of live sessions (restored when the agent restarts). null: no persistence (tests). */
  #statePath: string | null;
  #saveTimer: NodeJS.Timeout | null = null;
  /** PC sessions (without it the "pc" kind can't be opened). */
  readonly pc: PcSupport | null;

  constructor(getConfig: () => AgentConfig, notifier: Notifier, queryFn: QueryFn, statePath: string | null = null, pc: PcSupport | null = null) {
    this.#getConfig = getConfig;
    this.#notifier = notifier;
    this.#query = queryFn;
    this.#statePath = statePath;
    this.pc = pc;
    // Sessions inactive and idle for 6 hours are closed (history stays on disk and can be resumed).
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

  /** Is the folder inside one of the allowed roots? (symlinks resolved) */
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
    // For the default ~/.claude the variable must not be set (Claude uses its own default). It is removed explicitly:
    // even if a value from another profile lingers in the environment, the session must not open on the wrong account.
    if (resolve(expandHome(dir)) !== resolve(expandHome("~/.claude"))) env.CLAUDE_CONFIG_DIR = expandHome(dir);
    else delete env.CLAUDE_CONFIG_DIR;
    return env;
  }

  /** Opens a sibling worktree in the folder's git repo (branch: tiphys/<short-id>); returns the same subfolder's path. */
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
    const pc = req.kind === "pc";
    if (pc && (!this.pc?.available() || !req.control)) throw new AppError("agent.claude.pcUnavailable", 403);
    // No file tools in a PC session: the folder is only the process's working directory (home folder).
    let cwd = pc ? homedir() : await this.checkCwd(req.cwd);
    if (req.worktree && !pc) cwd = await this.createWorktree(cwd, randomUUID().slice(0, 8));
    const profileId = req.profileId ?? cfg.defaultProfile;
    // Session opened without a message (empty): the title is taken from the first message sent.
    const s = this.#create({ ...req, cwd, profileId }, req.title || req.prompt || (req.resume ? "(devam)" : ""));
    this.sessions.set(s.id, s);
    if (pc) this.bindControl(s, req.control!);
    if (req.prompt) this.send(s, req.prompt, req.images);
    // A session opened (or resumed) without a message waits for the first message; the process starts then.
    else s.setStatus("idle");
    this.#save();
    return s;
  }

  /** Session object + SDK options (the Claude process doesn't start yet, see #launch). */
  /**
   * Asks the phone for permission: event ("permission") + claude.waiting notification (with Allow / Deny buttons).
   * Claude's tool permissions and the PC session's confirm tool go the same way.
   */
  #ask(s: LiveSession, toolName: string, input: unknown, reason: string | null, signal?: AbortSignal, notifyTool = toolName): Promise<PermissionResult> {
    return new Promise<PermissionResult>((resolvePermission) => {
      const requestId = randomUUID();
      const done = (r: PermissionResult) => {
        if (!s.pending.delete(requestId)) return;
        s.emit({ kind: "permissionResolved", requestId, allow: r.behavior === "allow" });
        if (s.status === "waiting" || s.status === "running") s.setStatus(s.pending.size > 0 ? "waiting" : "running");
        resolvePermission(r);
      };
      s.pending.set(requestId, done);
      if (signal?.aborted) return done({ behavior: "deny", message: "aborted" });
      signal?.addEventListener("abort", () => done({ behavior: "deny", message: "aborted" }), { once: true });
      s.emit({ kind: "permission", requestId, toolName, input, reason });
      s.setStatus("waiting");
      void this.#notifier.send({
        key: "claude.waiting",
        params: { title: s.title, tool: notifyTool, ...(s.kind === "pc" ? { pc: 1 } : {}) }, // pc: the phone hides the buttons on the lock screen
        link: `tiphys://claude/${s.id}`,
        priority: "high",
        // So the phone can decide with the notification's "Allow / Deny" buttons without opening the app.
        data: { sessionId: s.id, requestId },
      });
    });
  }

  #create(req: StartRequest & { profileId: string }, title: string, id?: string): LiveSession {
    const pc = req.kind === "pc";
    // PC session is "default" only: bypass/plan modes must not change the tool rules.
    const mode = pc ? "default" : (req.permissionMode ?? "default");
    const s = new LiveSession(req.cwd, req.profileId, req.model ?? "", mode, title, id);
    s.effort = req.effort;
    if (pc) return this.#createPc(s, req);
    const canUseTool: CanUseTool = (toolName, input, opts) => this.#ask(s, toolName, input, opts.decisionReason ?? null, opts.signal);
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

  /**
   * "pc" session: built-in tools off (tools: []), user/project settings and MCP servers are not loaded; only the
   * in-process tiphys_pc tools (auto-allowed). Any other tool requested is denied. Risky steps reach the phone via
   * the confirm tool.
   */
  #createPc(s: LiveSession, req: StartRequest & { profileId: string }): LiveSession {
    const pc = this.pc;
    if (!pc) throw new AppError("agent.claude.pcUnavailable", 403);
    s.kind = "pc";
    s.controlUntil = () => pc.controlUntil(s);
    const server = pc.server(s, {
      approve: async (reason, input, signal) =>
        (await this.#ask(s, pcToolName("confirm"), input, reason, signal, `PC · ${reason.length > 80 ? `${reason.slice(0, 79)}…` : reason}`)).behavior === "allow",
      lost: () => this.#unbind(s, "lost"),
    });
    const deny: CanUseTool = async (toolName) => ({ behavior: "deny", message: `PC oturumunda yalnız tiphys_pc araçları kullanılabilir (${toolName} kapalı).` });
    s.options = {
      cwd: req.cwd,
      env: this.profileEnv(req.profileId),
      settingSources: [],
      strictMcpConfig: true,
      tools: [],
      mcpServers: { [PC_SERVER]: server },
      allowedTools: PC_TOOLS.map(pcToolName),
      disallowedTools: PC_DISALLOWED_TOOLS,
      systemPrompt: PC_SYSTEM_PROMPT,
      includePartialMessages: true,
      permissionMode: "default",
      canUseTool: deny,
      ...(req.model ? { model: req.model } : {}),
      ...(req.effort ? { effort: req.effort } : {}),
      ...(req.resume ? { resume: req.resume } : {}),
      stderr: () => {},
    };
    return s;
  }

  /** (Re)binds a PC session to a control session (the phone re-prompted the lock and opened a session). */
  bindControl(s: LiveSession, b: ControlBinding) {
    if (s.kind !== "pc") throw new AppError("agent.claude.notPcSession", 400);
    s.control = b;
    s.emit({ kind: "control", active: true, expiresAt: s.controlUntil(), reason: null });
  }

  /** A control session ended (stop, expiry, agent shutdown): PC sessions bound to that device stop. */
  controlEnded(device: string, reason: string) {
    for (const s of this.sessions.values()) if (s.control?.device === device) this.#unbind(s, reason);
  }

  /** Breaks the binding; if Claude is running it is stopped immediately and the session goes idle. */
  #unbind(s: LiveSession, reason: string) {
    if (!s.control) return;
    s.control = null;
    s.pcWarnedFor = null;
    s.emit({ kind: "control", active: false, expiresAt: null, reason });
    const working = s.status === "running" || s.status === "waiting" || s.status === "starting";
    if (working) {
      s.controlStopped = true;
      void this.interrupt(s).catch(() => {});
      s.setStatus("idle");
    }
    // The phone app may be closed: this clears the persistent "Claude is using the PC" notification; if Claude was
    // running when stopped, a visible notification (the app doesn't show the "stopped" reason: the user stopped it).
    void this.#notifier.send({
      key: "claude.pcEnded",
      params: { title: s.title, reason, working: working ? 1 : 0 },
      link: `tiphys://claude/${s.id}`,
      priority: working ? "high" : "default",
      data: { sessionId: s.id },
    });
  }

  /**
   * Control time of PC sessions: one notification with an "Extend" button 2 min before the end (again for the new end
   * time after an extension). Called every 10 s from outside the manager (routes.ts); tests call it with a fake clock.
   */
  pcTick() {
    const pc = this.pc;
    if (!pc) return;
    const now = pc.now();
    for (const s of this.sessions.values()) {
      if (s.kind !== "pc" || !s.control) continue;
      const until = s.controlUntil();
      if (!until || s.pcWarnedFor === until) continue;
      const left = Date.parse(until) - now;
      if (left <= 0 || left > 120_000) continue;
      s.pcWarnedFor = until;
      void this.#notifier.send({
        key: "claude.pcExpiring",
        params: { title: s.title, minutes: Math.max(1, Math.round(left / 60_000)) },
        link: `tiphys://claude/${s.id}`,
        priority: "high",
        data: { sessionId: s.id },
      });
    }
  }

  /** Starts the Claude process (with the first message). */
  #launch(s: LiveSession) {
    if (s.query || !s.options) return;
    s.processCostUsd = 0;
    s.query = this.#query({ prompt: s.inbox, options: s.options });
    void this.#pump(s);
  }

  /** If the agent restarted, brings back the previous live sessions with the same id, as idle. */
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
        const pc = p.kind === "pc";
        if (pc && !this.pc) continue; // desktop off: the PC session doesn't come back
        // A PC session comes back without a control binding (the token isn't written to disk); the phone rebinds it.
        const s = this.#create({ cwd: pc ? homedir() : await this.checkCwd(p.cwd), profileId: p.profileId, prompt: "", model: p.model || undefined, effort: p.effort, permissionMode: p.permissionMode, resume: p.sdkSessionId ?? undefined, kind: p.kind }, p.title, p.id);
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
        // folder deleted/not allowed: this session doesn't come back (its history stays on disk)
      }
    }
    this.#save();
    return n;
  }

  /** Writes the session list to disk (with a short delay; rapid successive changes become one write). */
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
      ...(s.kind === "pc" ? { kind: s.kind } : {}),
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
          if (s.controlStopped) {
            // Stopped because control ended: not an error, no notification either (the control.ended event is enough).
            s.controlStopped = false;
            s.processCostUsd = m.total_cost_usd;
            s.setStatus("idle");
            continue;
          }
          const ok = m.subtype === "success" && !m.is_error;
          s.setStatus(ok ? "idle" : "error");
          // Cost of this turn: the SDK accumulates the total over the Claude process's lifetime; when the process restarts
          // (agent restarted, process crashed) it counts from zero. So it is compared with the process's previous total,
          // not with the session's recorded total.
          const turnCost = Math.max(0, m.total_cost_usd - s.processCostUsd);
          s.processCostUsd = m.total_cost_usd;
          const { files, summary } = turnSummary(s, m.subtype === "success" ? m.result : "");
          void this.#notifier.send({
            key: ok ? "claude.done" : "claude.error",
            params: { title: s.title, cost: Math.round(turnCost * 100) / 100, seconds: Math.round(m.duration_ms / 1000), files, summary },
            link: `tiphys://claude/${s.id}`,
          });
        }
      }
      if (s.status !== "error") s.setStatus("stopped");
    } catch (e) {
      if (!this.sessions.has(s.id)) return; // user closed it: don't send an error notification
      // Drop the dead process: the next message starts a new Claude process and resumes the conversation.
      s.query = null;
      if (s.options && s.sdkSessionId) s.options.resume = s.sdkSessionId;
      s.emit({ kind: "error", message: e instanceof Error ? e.message : String(e) });
      s.setStatus("error");
      void this.#notifier.send({ key: "claude.error", params: { title: s.title }, link: `tiphys://claude/${s.id}` });
    }
  }

  /** Queues the message. If the same `clientId` arrived before, does nothing and returns false. */
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
    if (s.kind === "pc" && mode !== "default") throw new AppError("agent.claude.pcModeFixed", 400);
    if (mode === "bypassPermissions" && s.permissionMode !== "bypassPermissions") {
      // A session not started with bypassed permissions can't switch to bypass later (SDK security rule).
      throw new AppError("agent.claude.bypassNeedsNewSession", 400);
    }
    if (s.query) await s.query.setPermissionMode(mode);
    else if (s.options) s.options.permissionMode = mode; // process not started yet
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
    this.pc?.forget(id);
    this.#save();
  }

  /** On agent shutdown: the session list stays on disk (comes back on restart), processes are closed. */
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
