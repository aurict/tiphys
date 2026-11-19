// Antigravity CLI (agy) sessions driven from the phone ("agy" feature, PC). Each session is one `agy acp` process
// (Agent Client Protocol): the phone sends prompts, sees the agent's messages, thoughts and tool calls as they stream,
// answers agy's own permission prompts (Allow/Deny), switches mode (default, accept-edits, auto, plan) and model, and
// can resume any earlier agy conversation (also ones started in a terminal). agy keeps the conversation itself, so a
// session can be continued on the PC with `agy --conversation <id>`.
import { randomBytes } from "node:crypto";
import { AppError } from "../errors.ts";
import type { Notifier } from "../notify.ts";
import { AcpClient, INIT_PARAMS, type AcpRequest, type Spawn } from "./acp.ts";

export type AgyStatus = "starting" | "idle" | "running" | "waiting" | "ended" | "error";

export interface AgyEvent {
  /** Stable identity: a streamed message keeps its eid while its text grows (and its seq moves on). */
  eid: number;
  /** Version: the newest change of any event; poll with `after` = the highest seq seen. */
  seq: number;
  at: string;
  kind: "user" | "agent" | "thought" | "tool" | "toolUpdate" | "plan" | "permission" | "permissionResolved" | "mode" | "error" | "turnEnd";
  text?: string;
  toolCallId?: string;
  title?: string;
  toolKind?: string;
  status?: string;
  paths?: string[];
  command?: string;
  requestId?: string;
  options?: Array<{ optionId: string; name: string; kind: string }>;
  optionId?: string;
  entries?: Array<{ content: string; status: string; priority?: string }>;
  modeId?: string;
  stopReason?: string;
  replay?: boolean;
}

const MAX_EVENTS = 3000;
const MAX_TEXT = 100_000;
export const MAX_LIVE = 6;
export const IDLE_KILL_MS = 2 * 3600_000;

/** Single-quoted for a POSIX shell. */
export const shq = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

const clip = (s: unknown, n: number) => String(s ?? "").slice(0, n);

export class AgySession {
  readonly id = `agy-${randomBytes(6).toString("hex")}`;
  conversationId = "";
  readonly cwd: string;
  title = "agy";
  status: AgyStatus = "starting";
  modeId = "default";
  modes: Array<{ id: string; name: string; description?: string }> = [];
  model: string | null = null;
  models: Array<{ value: string; name: string }> = [];
  usage: { used: number; size: number } | null = null;
  commands: Array<{ name: string; description: string }> = [];
  readonly createdAt = new Date().toISOString();
  lastActivity = Date.now();
  events: AgyEvent[] = [];
  #seq = 0;
  #eid = 0;
  /** requestId → JSON-RPC id of agy's permission request + its options. */
  readonly pending = new Map<string, { rpcId: number | string; options: Array<{ optionId: string; name: string; kind: string }> }>();
  #waiters: Array<() => void> = [];
  replaying = false;
  client: AcpClient | null = null;

  constructor(cwd: string) {
    this.cwd = cwd;
  }

  emit(e: Omit<AgyEvent, "seq" | "at" | "eid">) {
    const ev: AgyEvent = { ...e, eid: ++this.#eid, seq: ++this.#seq, at: new Date().toISOString(), ...(this.replaying ? { replay: true } : {}) };
    this.events.push(ev);
    if (this.events.length > MAX_EVENTS) this.events.splice(0, this.events.length - MAX_EVENTS);
    this.lastActivity = Date.now();
    this.#wake();
  }

  /** Streaming chunks are merged into the previous event of the same kind (fewer events for the phone). */
  appendText(kind: "agent" | "thought" | "user", text: string) {
    const last = this.events[this.events.length - 1];
    if (last && last.kind === kind && (last.text?.length ?? 0) < MAX_TEXT && !!last.replay === this.replaying) {
      last.text = (last.text ?? "") + text;
      // A merged chunk is a new version of that event: give it a new seq so pollers see it.
      last.seq = ++this.#seq;
      last.at = new Date().toISOString();
      this.lastActivity = Date.now();
      this.#wake();
    } else this.emit({ kind, text });
  }

  setStatus(s: AgyStatus) {
    this.status = s;
    this.#wake();
  }

  #wake() {
    const w = this.#waiters;
    this.#waiters = [];
    for (const f of w) f();
  }

  /** Events after `after` (seq), waiting up to waitMs for a new one. */
  async since(after: number, waitMs: number): Promise<AgyEvent[]> {
    const pick = () => this.events.filter((e) => e.seq > after);
    let out = pick();
    if (out.length || waitMs <= 0 || this.status === "ended") return out;
    await new Promise<void>((resolve) => {
      const t = setTimeout(resolve, waitMs);
      this.#waiters.push(() => {
        clearTimeout(t);
        resolve();
      });
    });
    out = pick();
    return out;
  }

  resumeCommand() {
    return this.conversationId ? `cd ${shq(this.cwd)} && agy --conversation ${this.conversationId}` : null;
  }

  summary() {
    return {
      id: this.id,
      conversationId: this.conversationId,
      cwd: this.cwd,
      title: this.title,
      status: this.status,
      modeId: this.modeId,
      modes: this.modes,
      model: this.model,
      models: this.models,
      usage: this.usage,
      commands: this.commands,
      createdAt: this.createdAt,
      lastActivity: new Date(this.lastActivity).toISOString(),
      pendingPermissions: [...this.pending.entries()].map(([requestId, p]) => ({ requestId, options: p.options })),
      resumeCommand: this.resumeCommand(),
    };
  }
}

export interface StartAgy {
  cwd: string;
  prompt?: string;
  resume?: string;
  modeId?: string;
  model?: string;
}

export class AgyManager {
  readonly sessions = new Map<string, AgySession>();
  #notifier: Notifier;
  #spawn: Spawn | undefined;
  #reaper: NodeJS.Timeout;

  constructor(notifier: Notifier, spawnFn?: Spawn) {
    this.#notifier = notifier;
    this.#spawn = spawnFn;
    this.#reaper = setInterval(() => this.#reap(), 60_000);
    this.#reaper.unref();
  }

  #reap() {
    for (const s of this.sessions.values()) {
      if (s.status === "idle" && Date.now() - s.lastActivity > IDLE_KILL_MS) void this.close(s.id).catch(() => {});
      if (s.status === "ended" && Date.now() - s.lastActivity > IDLE_KILL_MS) this.sessions.delete(s.id);
    }
  }

  get(id: string): AgySession {
    const s = this.sessions.get(id);
    if (!s) throw new AppError("agent.agy.sessionNotFound", 404, { id });
    return s;
  }

  list() {
    return [...this.sessions.values()].map((s) => s.summary());
  }

  /** Earlier conversations (agy's own list: also terminal ones), newest first. */
  async conversations(cwd: string): Promise<Array<{ sessionId: string; cwd: string; title: string; updatedAt: string | null; liveId: string | null }>> {
    const c = new AcpClient(cwd, [], this.#spawn);
    try {
      await c.request("initialize", INIT_PARAMS, 30_000);
      const out: Array<{ sessionId: string; cwd: string; title: string; updatedAt: string | null }> = [];
      let cursor: string | undefined;
      for (let page = 0; page < 5; page++) {
        const r = await c.request<{ sessions?: Array<Record<string, unknown>>; nextCursor?: string }>("session/list", cursor ? { cursor } : {}, 30_000);
        for (const x of r.sessions ?? []) {
          const sessionId = clip(x.sessionId, 80);
          if (!/^[A-Za-z0-9-]{8,80}$/.test(sessionId)) continue;
          out.push({ sessionId, cwd: clip(x.cwd, 1024), title: clip(x.title, 200), updatedAt: typeof x.updatedAt === "string" ? x.updatedAt : null });
        }
        cursor = r.nextCursor;
        if (!cursor) break;
      }
      const live = new Map([...this.sessions.values()].filter((s) => s.status !== "ended").map((s) => [s.conversationId, s.id]));
      return out.sort((a, b) => (b.updatedAt ?? "").localeCompare(a.updatedAt ?? "")).map((x) => ({ ...x, liveId: live.get(x.sessionId) ?? null }));
    } finally {
      c.kill();
    }
  }

  async start(req: StartAgy): Promise<AgySession> {
    const live = [...this.sessions.values()].filter((s) => s.status !== "ended" && s.status !== "error");
    if (live.length >= MAX_LIVE) throw new AppError("agent.agy.tooManySessions", 409, { max: MAX_LIVE });
    if (req.resume && live.some((s) => s.conversationId === req.resume)) throw new AppError("agent.agy.alreadyOpen", 409);
    const s = new AgySession(req.cwd);
    const c = new AcpClient(req.cwd, [], this.#spawn);
    s.client = c;
    this.sessions.set(s.id, s);
    c.on("notification", (method: string, params: Record<string, unknown>) => this.#onNotification(s, method, params));
    c.on("request", (r: AcpRequest) => this.#onRequest(s, r));
    c.on("exit", () => {
      s.pending.clear();
      if (s.status !== "ended") {
        s.emit({ kind: "error", text: "agy exited" });
        s.setStatus("ended");
      }
    });
    try {
      await c.request("initialize", INIT_PARAMS, 60_000);
      let r: Record<string, unknown>;
      if (req.resume) {
        s.replaying = true;
        try {
          r = await c.request("session/load", { sessionId: req.resume, cwd: req.cwd, mcpServers: [] }, 120_000);
        } finally {
          s.replaying = false;
        }
        s.conversationId = req.resume;
      } else {
        r = await c.request("session/new", { cwd: req.cwd, mcpServers: [] }, 60_000);
        s.conversationId = clip(r.sessionId, 80);
      }
      this.#readSessionInfo(s, r);
      if (req.modeId && req.modeId !== s.modeId) await this.setMode(s.id, req.modeId);
      if (req.model && req.model !== s.model) await this.setModel(s.id, req.model);
      s.setStatus("idle");
    } catch (e) {
      s.setStatus("error");
      s.emit({ kind: "error", text: e instanceof AppError ? e.code : "agent.agy.startFailed" });
      c.kill();
      throw e instanceof AppError ? e : new AppError("agent.agy.startFailed", 502);
    }
    if (req.prompt) void this.send(s.id, req.prompt).catch(() => {});
    return s;
  }

  #readSessionInfo(s: AgySession, r: Record<string, unknown>) {
    const modes = r.modes as { currentModeId?: string; availableModes?: Array<{ id: string; name: string; description?: string }> } | undefined;
    if (modes?.availableModes) s.modes = modes.availableModes.slice(0, 20).map((m) => ({ id: clip(m.id, 40), name: clip(m.name, 80), description: clip(m.description, 200) }));
    if (modes?.currentModeId) s.modeId = clip(modes.currentModeId, 40);
    this.#readConfig(s, r.configOptions);
  }

  #readConfig(s: AgySession, opts: unknown) {
    const model = (Array.isArray(opts) ? (opts as Array<Record<string, unknown>>) : []).find((o) => o.id === "model");
    if (!model) return;
    s.model = clip(model.currentValue, 80);
    s.models = (Array.isArray(model.options) ? (model.options as Array<Record<string, unknown>>) : []).slice(0, 50).map((o) => ({ value: clip(o.value, 80), name: clip(o.name, 120) }));
  }

  #onNotification(s: AgySession, method: string, params: Record<string, unknown>) {
    if (method !== "session/update") return;
    const u = (params.update ?? {}) as Record<string, unknown>;
    const content = u.content as { type?: string; text?: string } | undefined;
    switch (u.sessionUpdate) {
      case "agent_message_chunk":
        if (content?.type === "text") s.appendText("agent", clip(content.text, MAX_TEXT));
        break;
      case "agent_thought_chunk":
        if (content?.type === "text") s.appendText("thought", clip(content.text, MAX_TEXT));
        break;
      case "user_message_chunk":
        if (content?.type === "text") s.appendText("user", clip(content.text, MAX_TEXT));
        break;
      case "tool_call": {
        const raw = (u.rawInput ?? u.args ?? {}) as Record<string, unknown>;
        s.emit({
          kind: "tool",
          toolCallId: clip(u.toolCallId, 120),
          title: clip(u.title, 300),
          toolKind: clip(u.kind, 40),
          status: clip(u.status, 40),
          paths: (Array.isArray(u.locations) ? (u.locations as Array<{ path?: string }>) : []).slice(0, 10).map((l) => clip(l.path, 500)),
          ...(raw.CommandLine ? { command: clip(raw.CommandLine, 2000) } : {}),
        });
        break;
      }
      case "tool_call_update":
        s.emit({ kind: "toolUpdate", toolCallId: clip(u.toolCallId, 120), status: clip(u.status, 40), ...(u.title ? { title: clip(u.title, 300) } : {}) });
        break;
      case "plan":
        s.emit({
          kind: "plan",
          entries: (Array.isArray(u.entries) ? (u.entries as Array<Record<string, unknown>>) : []).slice(0, 50).map((x) => ({ content: clip(x.content, 500), status: clip(x.status, 20), priority: clip(x.priority, 20) })),
        });
        break;
      case "usage_update":
        if (typeof u.used === "number" && typeof u.size === "number") s.usage = { used: u.used, size: u.size };
        break;
      case "session_info_update":
        if (typeof u.title === "string" && u.title) s.title = clip(u.title, 200);
        break;
      case "current_mode_update":
        if (typeof u.currentModeId === "string") {
          s.modeId = clip(u.currentModeId, 40);
          s.emit({ kind: "mode", modeId: s.modeId });
        }
        break;
      case "available_commands_update":
        s.commands = (Array.isArray(u.availableCommands) ? (u.availableCommands as Array<Record<string, unknown>>) : []).slice(0, 100).map((x) => ({ name: clip(x.name, 60), description: clip(x.description, 200) }));
        break;
      case "config_option_update":
        this.#readConfig(s, u.configOptions);
        break;
    }
  }

  #onRequest(s: AgySession, r: AcpRequest) {
    if (r.method !== "session/request_permission") {
      // No fs/terminal capability was offered; anything else is refused.
      s.client?.respondError(r.id, -32601, "method not supported by this client");
      return;
    }
    const tc = (r.params.toolCall ?? {}) as Record<string, unknown>;
    const raw = (tc.rawInput ?? tc.args ?? {}) as Record<string, unknown>;
    const options = (Array.isArray(r.params.options) ? (r.params.options as Array<Record<string, unknown>>) : []).slice(0, 10).map((o) => ({ optionId: clip(o.optionId, 80), name: clip(o.name, 80), kind: clip(o.kind, 40) }));
    const requestId = randomBytes(6).toString("hex");
    s.pending.set(requestId, { rpcId: r.id, options });
    s.emit({ kind: "permission", requestId, options, title: clip(tc.title, 300), toolKind: clip(tc.kind, 40), toolCallId: clip(tc.toolCallId, 120), ...(raw.CommandLine ? { command: clip(raw.CommandLine, 2000) } : {}) });
    s.setStatus("waiting");
    void this.#notifier.send({
      key: "agy.waiting",
      params: { title: s.title, tool: clip(tc.title, 120) },
      link: `tiphys://agy/${s.id}`,
      priority: "high",
      data: { sessionId: s.id, requestId },
    });
  }

  async send(id: string, text: string) {
    const s = this.get(id);
    if (!s.client || s.status === "ended" || s.status === "error") throw new AppError("agent.agy.sessionEnded", 409);
    if (s.status === "running" || s.status === "waiting" || s.status === "starting") throw new AppError("agent.agy.busy", 409);
    if (!text.trim() || text.length > MAX_TEXT) throw new AppError("agent.request.invalid", 400);
    s.emit({ kind: "user", text });
    s.setStatus("running");
    try {
      const r = await s.client.request<{ stopReason?: string }>("session/prompt", { sessionId: s.conversationId, prompt: [{ type: "text", text }] }, 0);
      s.pending.clear();
      s.emit({ kind: "turnEnd", stopReason: clip(r.stopReason, 40) });
      s.setStatus("idle");
      void this.#notifier.send({ key: "agy.done", params: { title: s.title }, link: `tiphys://agy/${s.id}`, priority: "low" });
    } catch (e) {
      if ((s.status as AgyStatus) === "ended") return; // closed meanwhile
      s.emit({ kind: "error", text: e instanceof AppError ? e.code : "agent.agy.promptFailed" });
      s.setStatus("idle");
      void this.#notifier.send({ key: "agy.error", params: { title: s.title }, link: `tiphys://agy/${s.id}` });
    }
  }

  answer(id: string, requestId: string, optionId: string) {
    const s = this.get(id);
    const p = s.pending.get(requestId);
    if (!p) throw new AppError("agent.agy.permissionNotFound", 404);
    if (!p.options.some((o) => o.optionId === optionId)) throw new AppError("agent.request.invalid", 400);
    s.pending.delete(requestId);
    s.client?.respond(p.rpcId, { outcome: { outcome: "selected", optionId } });
    s.emit({ kind: "permissionResolved", requestId, optionId });
    if (s.status === "waiting") s.setStatus(s.pending.size ? "waiting" : "running");
  }

  cancel(id: string) {
    const s = this.get(id);
    if (!s.client || s.status === "ended") return;
    for (const [requestId, p] of s.pending) {
      s.client.respond(p.rpcId, { outcome: { outcome: "cancelled" } });
      s.emit({ kind: "permissionResolved", requestId, optionId: "cancelled" });
    }
    s.pending.clear();
    s.client.notify("session/cancel", { sessionId: s.conversationId });
  }

  async setMode(id: string, modeId: string) {
    const s = this.get(id);
    if (!s.modes.some((m) => m.id === modeId)) throw new AppError("agent.agy.unknownMode", 400, { modeId });
    await s.client!.request("session/set_mode", { sessionId: s.conversationId, modeId }, 30_000);
    s.modeId = modeId;
    s.emit({ kind: "mode", modeId });
  }

  async setModel(id: string, model: string) {
    const s = this.get(id);
    if (s.models.length && !s.models.some((m) => m.value === model)) throw new AppError("agent.agy.unknownModel", 400, { model });
    const r = await s.client!.request<{ configOptions?: unknown }>("session/set_config_option", { sessionId: s.conversationId, configId: "model", value: model }, 30_000);
    this.#readConfig(s, r.configOptions);
    s.model ??= model;
  }

  async close(id: string) {
    const s = this.get(id);
    if (s.client && !s.client.closed) {
      this.cancel(id);
      await s.client.request("session/close", { sessionId: s.conversationId }, 10_000).catch(() => {});
      s.client.kill();
    }
    s.setStatus("ended");
  }

  shutdown() {
    clearInterval(this.#reaper);
    for (const s of this.sessions.values()) s.client?.kill();
  }
}
