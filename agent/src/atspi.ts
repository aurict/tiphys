// Mobile view (11.4, "control" feature): the AT-SPI accessibility tree of the focused visible window goes to the
// phone, and the phone runs the widget's own action (not a pixel click).
// - Helper: helpers/atspi_helper.py (python3 -I, JSON lines). Lives only while the mobile view is open and the control
//   session is valid; killed when the view closes (no subscription + 60 s idle, DELETE), when control ends and when the
//   agent shuts down. Restarted once if it crashes; 5 s per request (on timeout the helper is killed = crash),
//   at most 4 MB per line.
// - Clients (UiService/UiClient): the phone view and each Claude PC session (11.5, claude/pc.ts ui_* tools) use a
//   separate helper + generation; Claude's opens on the first ui_* call, closes after 60 s idle / when control ends.
// - Firefox's tree only comes while org.a11y.Status.IsEnabled=true (Phase 0): set to true when the view opens, the old
//   value is written to a11y-state.json (crash recovery), restored when the last view closes / on agent startup.
// - Every endpoint requires the control session token (requireControl + rate limit); the window must be visible on the
//   active workspace.
// PRIVACY: snapshots are never written to disk or logs; the event log only gets "ui.opened {class}"; password field text
// isn't read even in the helper, and typing into a password field requires `confirm: true`.
import { spawn } from "node:child_process";
import { readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { Readable, Writable } from "node:stream";
import { fileURLToPath } from "node:url";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { RateLimit, requireControl, watchControl, type Exec } from "./control.ts";
import { TEXT_OK, runInput, type InputIo } from "./desktop_input.ts";
import { AppError } from "./errors.ts";
import { run } from "./exec.ts";
import { ADDRESS } from "./hyprctl.ts";
import { sessionBusEnv } from "./routes/desktop.ts";
import { hyprEnv, isVisible, parseClients, parseMonitors, realHyprIo, type HyprWindow } from "./routes/hypr.ts";
import type { Ctx } from "./server.ts";

export const PROTOCOL_VERSION = 1;
/** Firefox private window title (140 ESR: "… — Mozilla Firefox Private Browsing", TR "… Gizli Gezinti"): tree isn't read. */
export const PRIVATE_TITLE = /(?:Private Browsing|Gizli Gezinti)\s*$/u;
export const HELPER_PATH = fileURLToPath(new URL("../helpers/atspi_helper.py", import.meta.url));

// ---- org.a11y.Status.IsEnabled ----

const BUSCTL = ["org.a11y.Bus", "/org/a11y/bus", "org.a11y.Status", "IsEnabled"];

export function a11yStatePath(configPath: string) {
  return join(dirname(configPath), "a11y-state.json");
}

/** Sets IsEnabled to true for the view's lifetime; previous value in [stateFile] (restored on startup if the agent crashes). */
export class A11yStatus {
  readonly exec: Exec;
  readonly stateFile: string;
  #chain: Promise<unknown> = Promise.resolve();

  constructor(exec: Exec, stateFile: string) {
    this.exec = exec;
    this.stateFile = stateFile;
  }

  #serial<T>(fn: () => Promise<T>): Promise<T> {
    const p = this.#chain.then(fn);
    this.#chain = p.catch(() => {});
    return p;
  }

  #busctl(args: string[]) {
    return this.exec("busctl", ["--user", ...args], { env: { ...process.env, ...sessionBusEnv() }, timeoutMs: 3000 });
  }

  async #get(): Promise<boolean> {
    const m = /^b (true|false)\b/.exec((await this.#busctl(["get-property", ...BUSCTL])).stdout.trim());
    if (!m) throw new AppError("agent.ui.a11yBus", 503);
    return m[1] === "true";
  }

  #set(v: boolean) {
    return this.#busctl(["set-property", ...BUSCTL, "b", String(v)]);
  }

  async #saved(): Promise<boolean | null> {
    try {
      const j = JSON.parse(await readFile(this.stateFile, "utf8")) as { previous?: unknown };
      return typeof j.previous === "boolean" ? j.previous : null;
    } catch {
      return null;
    }
  }

  /** Enables (if a record already exists the old value is kept, so e.g. the indicator value isn't mistaken for the "real value"). */
  enable(): Promise<void> {
    return this.#serial(async () => {
      let previous = await this.#saved();
      if (previous === null) {
        previous = await this.#get();
        await writeFile(this.stateFile, JSON.stringify({ previous }) + "\n", { mode: 0o600 });
      }
      if (!previous) await this.#set(true);
    });
  }

  /** Restores the recorded old value and deletes the record (no-op if none). This is also crash recovery on startup. */
  restore(): Promise<void> {
    return this.#serial(async () => {
      const previous = await this.#saved();
      if (previous === null) return;
      if (!previous) await this.#set(false);
      await rm(this.stateFile, { force: true });
    });
  }
}

// ---- helper process ----

export interface HelperChild {
  stdin: Writable | null;
  stdout: Readable | null;
  kill(signal?: NodeJS.Signals): boolean;
  on(ev: "exit", fn: (code: number | null, signal: NodeJS.Signals | null) => void): unknown;
  on(ev: "error", fn: (e: Error) => void): unknown;
}

type Reply = Record<string, unknown>;

/** Helper error code → agent error. */
const HELPER_ERRORS: Record<string, [string, number]> = {
  stale: ["agent.ui.stale", 409],
  unsupported: ["agent.ui.unsupported", 422],
  confirmRequired: ["agent.ui.confirmRequired", 409],
  noAction: ["agent.ui.noAction", 400],
  badRequest: ["agent.request.invalid", 400],
};

/**
 * Helper process manager: starts on demand, request/response with ids (5 s), forwards "changed" events.
 * On unexpected exit pending requests fail; the next request restarts it once, and after a second crash it's
 * agent.ui.helperFailed until stop() is called.
 */
export class AtspiHelper {
  readonly spawnChild: () => HelperChild;
  readonly timeoutMs: number;
  readonly maxLine: number;
  onEvent: (ev: string) => void = () => {};
  #child: HelperChild | null = null;
  #ready: Promise<void> | null = null;
  #pending = new Map<number, { resolve: (r: Reply) => void; reject: (e: unknown) => void; timer: NodeJS.Timeout }>();
  #seq = 0;
  #crashes = 0;
  #missing = false;

  constructor(spawnChild: () => HelperChild, opts: { timeoutMs?: number; maxLine?: number } = {}) {
    this.spawnChild = spawnChild;
    this.timeoutMs = opts.timeoutMs ?? 5000;
    this.maxLine = opts.maxLine ?? 4 * 1024 * 1024;
  }

  get running() {
    return this.#child !== null;
  }

  #start(): Promise<void> {
    if (this.#missing) return Promise.reject(new AppError("agent.ui.helperMissing", 503));
    if (this.#crashes > 1) return Promise.reject(new AppError("agent.ui.helperFailed", 502));
    if (this.#ready) return this.#ready;
    const child = this.spawnChild();
    this.#child = child;
    let hello: (e?: unknown) => void = () => {};
    this.#ready = new Promise<void>((resolve, reject) => {
      const t = setTimeout(() => hello(new AppError("agent.ui.timeout", 504)), this.timeoutMs);
      hello = (e) => {
        clearTimeout(t);
        hello = () => {};
        e ? reject(e) : resolve();
      };
    });
    this.#ready.catch(() => {});
    const bufs: Buffer[] = [];
    let size = 0;
    const line = (raw: string) => {
      let m: Reply;
      try {
        m = JSON.parse(raw) as Reply;
      } catch {
        return;
      }
      if (typeof m.event === "string") {
        if (m.event === "hello") hello(m.version === PROTOCOL_VERSION ? undefined : new AppError("agent.ui.helperMissing", 503, { version: m.version as number }));
        else if (m.event === "fatal") {
          this.#missing = true;
          hello(new AppError("agent.ui.helperMissing", 503));
        } else this.onEvent(m.event);
        return;
      }
      const p = typeof m.id === "number" ? this.#pending.get(m.id) : undefined;
      if (!p) return;
      this.#pending.delete(m.id as number);
      clearTimeout(p.timer);
      const err = (m.error as { code?: unknown } | undefined)?.code;
      if (typeof err === "string") {
        const [code, status] = HELPER_ERRORS[err] ?? ["agent.ui.failed", 502];
        p.reject(new AppError(code, status));
      } else p.resolve(m);
    };
    child.stdout?.on("data", (b: Buffer) => {
      let start = 0;
      for (let i = b.indexOf(10); i >= 0; i = b.indexOf(10, start)) {
        bufs.push(b.subarray(start, i));
        line(Buffer.concat(bufs).toString("utf8"));
        bufs.length = 0;
        size = 0;
        start = i + 1;
      }
      if (start < b.length) {
        bufs.push(b.subarray(start));
        size += b.length - start;
        if (size > this.maxLine) {
          bufs.length = 0;
          size = 0;
          child.kill("SIGKILL"); // protocol violation: counts as a crash
        }
      }
    });
    child.stdin?.on("error", () => {}); // EPIPE when the process dies
    child.on("error", (e) => {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") this.#missing = true;
      this.#gone(child);
      hello(new AppError(this.#missing ? "agent.ui.helperMissing" : "agent.ui.helperFailed", this.#missing ? 503 : 502));
    });
    child.on("exit", () => {
      const crashed = this.#child === child;
      this.#gone(child);
      hello(new AppError(this.#missing ? "agent.ui.helperMissing" : "agent.ui.helperFailed", this.#missing ? 503 : 502));
      if (crashed && !this.#missing) {
        this.#crashes++;
        this.onEvent("changed"); // the phone asks again → helper restarts once
      }
    });
    return this.#ready;
  }

  #gone(child: HelperChild) {
    if (this.#child !== child) return;
    this.#child = null;
    this.#ready = null;
    for (const [id, p] of this.#pending) {
      clearTimeout(p.timer);
      p.reject(new AppError("agent.ui.helperFailed", 502));
      this.#pending.delete(id);
    }
  }

  async request(cmd: string, args: Reply = {}): Promise<Reply> {
    await this.#start();
    const child = this.#child;
    if (!child?.stdin) throw new AppError("agent.ui.helperFailed", 502);
    const id = ++this.#seq;
    return new Promise<Reply>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new AppError("agent.ui.timeout", 504));
        // A hung helper would stall later requests too: it's killed and counts as a crash (restarts once).
        if (this.#child === child) child.kill("SIGKILL");
      }, this.timeoutMs);
      this.#pending.set(id, { resolve, reject, timer });
      child.stdin!.write(JSON.stringify({ ...args, id, cmd }) + "\n");
    });
  }

  /** Kills the process and resets the crash counter. */
  stop() {
    const child = this.#child;
    this.#crashes = 0;
    if (!child) return;
    this.#gone(child);
    child.stdin?.end();
    child.kill("SIGTERM");
  }
}

// ---- endpoints ----

export interface UiIo {
  exec: Exec;
  hyprEnv(): Promise<NodeJS.ProcessEnv>;
  /** For typing into fields without an editable-text interface (same path as the live screen). */
  input: InputIo;
  spawnHelper(): HelperChild;
}

export const realUiIo: UiIo = {
  exec: run,
  hyprEnv,
  input: {
    exec: run,
    bytes: realHyprIo.bytes,
    inputEnv: async () => {
      const env = await realHyprIo.screenEnv();
      const runtime = env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.() ?? 1000}`;
      return { ...env, YDOTOOL_SOCKET: process.env.YDOTOOL_SOCKET ?? `${runtime}/.ydotool_socket` };
    },
  },
  // stderr isn't read (so content doesn't leak); env: session D-Bus (the a11y bus address is queried from it).
  spawnHelper: () => spawn("python3", ["-I", HELPER_PATH], { env: { ...process.env, ...sessionBusEnv() }, stdio: ["pipe", "pipe", "ignore"] }),
};

export interface UiOpts {
  limit?: RateLimit;
  /** SSE: how often the control token is rechecked (default 2 s). */
  recheckMs?: number;
  /** Idle time after which the view closes when there's no subscription. */
  idleMs?: number;
  timeoutMs?: number;
  stateFile?: string;
}

/** A node in the helper's snapshot (atspi_helper.py walk). */
export interface UiNode {
  id: string;
  parent: string | null;
  depth: number;
  role: string;
  name: string;
  desc: string;
  states: string[];
  value: { now: number; min: number; max: number; step: number } | null;
  text: string | null;
  password?: boolean;
  actions: string[];
}

export interface UiSnapshot {
  address: string;
  class: string;
  gen: number;
  title: string;
  partial: boolean;
  nodes: UiNode[];
}

/**
 * Mobile view sessions: each client (the phone view, each Claude PC session) gets its own helper and generation
 * (so one's snapshot doesn't invalidate the other's ids). IsEnabled becomes true when the first view opens and returns
 * to its old value when the last view closes. All close when control ends and when the agent shuts down.
 */
export class UiService {
  readonly ctx: Ctx;
  readonly io: UiIo;
  readonly a11y: A11yStatus;
  readonly idleMs: number;
  readonly timeoutMs: number | undefined;
  readonly log: (msg: string, err?: unknown) => void;
  #clients = new Map<string, UiClient>();
  #open = new Set<UiClient>();
  /** In-flight IsEnabled enable: later clients wait for it too (so the tree isn't requested before IsEnabled). */
  #enabling: Promise<void> = Promise.resolve();
  #genSeq = 0;

  constructor(ctx: Ctx, io: UiIo, opts: { idleMs?: number; timeoutMs?: number; stateFile?: string; log?: (msg: string, err?: unknown) => void } = {}) {
    this.ctx = ctx;
    this.io = io;
    this.idleMs = opts.idleMs ?? 60_000;
    this.timeoutMs = opts.timeoutMs;
    this.log = opts.log ?? (() => {});
    this.a11y = new A11yStatus(io.exec, opts.stateFile ?? a11yStatePath(ctx.store.path));
    // If the previous run crashed with a view open, IsEnabled is restored.
    void this.a11y.restore().catch((e) => this.log("a11y durumu geri yüklenemedi", e));
    ctx.control?.onEnd(() => void this.closeAll());
  }

  /** Client [key] (created if missing). While [busy] is true no idle close is armed (the phone's SSE subscription). */
  client(key: string, busy: () => boolean = () => false): UiClient {
    let c = this.#clients.get(key);
    if (!c) this.#clients.set(key, (c = new UiClient(this, busy)));
    return c;
  }

  /** Closes and forgets the client (Claude session deleted). */
  async drop(key: string) {
    const c = this.#clients.get(key);
    this.#clients.delete(key);
    await c?.close();
  }

  async closeAll() {
    await Promise.all([...this.#clients.values()].map((c) => c.close()));
  }

  nextGen() {
    return ++this.#genSeq;
  }

  async opened(c: UiClient) {
    const first = this.#open.size === 0;
    this.#open.add(c);
    // If IsEnabled can't be enabled (no a11y bus) GTK still provides a tree; the view opens.
    if (first) this.#enabling = this.a11y.enable().catch((e) => this.log("a11y IsEnabled açılamadı", e));
    await this.#enabling;
  }

  async closed(c: UiClient) {
    if (!this.#open.delete(c) || this.#open.size > 0) return;
    await this.a11y.restore().catch((e) => this.log("a11y IsEnabled geri yüklenemedi", e));
  }

  /** The window must be visible on the active workspace. */
  async visibleWindow(addr: string): Promise<HyprWindow> {
    const env = await this.io.hyprEnv();
    const json = async (what: string) => {
      const r = await this.io.exec("hyprctl", ["-j", what], { env, timeoutMs: 5000, allowFail: true });
      try {
        return JSON.parse(r.stdout) as unknown;
      } catch {
        throw new AppError("agent.desktop.hyprctlFailed", 502);
      }
    };
    const [c, m] = await Promise.all([json("clients"), json("monitors")]);
    const w = parseClients(c).find((x) => x.address === addr);
    if (!w) throw new AppError("agent.desktop.windowNotFound", 404);
    if (!isVisible(w, parseMonitors(m))) throw new AppError("agent.desktop.windowNotVisible", 409);
    return w;
  }

  /** A visible window that isn't a private browsing window (same rule for the phone and Claude). */
  async uiWindow(addr: string): Promise<HyprWindow> {
    const w = await this.visibleWindow(addr);
    if (PRIVATE_TITLE.test(w.title)) throw new AppError("agent.ui.unsupported", 422, { reason: "private" });
    return w;
  }
}

/**
 * A client's view: the last snapshot's window and generation. The agent's generation is what goes out (it keeps
 * increasing even if the helper restarts; a new helper's generation starting at 1 doesn't collide with old ids).
 * Authorization (control session) is the caller's job.
 */
export class UiClient {
  readonly svc: UiService;
  readonly helper: AtspiHelper;
  readonly busy: () => boolean;
  view: { address: string | null; class: string; gen: number; helperGen: number; opened: Set<string> } | null = null;
  /** The helper reported "changed" (no content). */
  onChanged: () => void = () => {};
  /** The view closed. */
  onClosed: () => void = () => {};
  #idle: NodeJS.Timeout | null = null;
  /** Incremented on every close(): an in-flight snapshot must not reopen the view after it was closed. */
  #closes = 0;

  constructor(svc: UiService, busy: () => boolean) {
    this.svc = svc;
    this.busy = busy;
    this.helper = new AtspiHelper(svc.io.spawnHelper, { timeoutMs: svc.timeoutMs });
    this.helper.onEvent = (ev) => {
      if (ev === "changed") this.onChanged();
    };
  }

  /** Re-arms the idle close timer (not while busy). */
  arm() {
    if (this.#idle) clearTimeout(this.#idle);
    this.#idle = null;
    if (this.view && !this.busy()) {
      this.#idle = setTimeout(() => void this.close(), this.svc.idleMs);
      this.#idle.unref?.();
    }
  }

  async #open(w: HyprWindow) {
    if (!this.view) {
      this.view = { address: null, class: "", gen: 0, helperGen: 0, opened: new Set() };
      await this.svc.opened(this);
    }
    if (!this.view.opened.has(w.address)) {
      this.view.opened.add(w.address);
      void this.svc.ctx.notifier.events?.record({ key: "ui.opened", params: { class: w.class.slice(0, 80) } }, (e) => this.svc.log("olay yazılamadı", e));
    }
    this.arm();
  }

  async close() {
    this.#closes++;
    if (this.#idle) clearTimeout(this.#idle);
    this.#idle = null;
    const was = this.view;
    this.view = null;
    this.helper.stop();
    if (was) {
      this.onClosed();
      await this.svc.closed(this);
    }
  }

  /** Snapshot of the visible window; agent.ui.unsupported if there's no tree. */
  async snapshot(addr: string): Promise<UiSnapshot> {
    const closes = this.#closes;
    const alive = () => {
      if (this.#closes !== closes) throw new AppError("agent.ui.stale", 409); // closed meanwhile (control ended, DELETE)
    };
    const w = await this.svc.uiWindow(addr);
    if (!w.pid) throw new AppError("agent.ui.unsupported", 422);
    alive();
    await this.#open(w);
    alive();
    const r = await this.helper.request("snapshot", { pid: w.pid, title: w.title });
    alive();
    const nodes = (Array.isArray(r.nodes) ? r.nodes : []) as UiNode[];
    const gen = this.svc.nextGen();
    if (this.view) Object.assign(this.view, { address: w.address, class: w.class, gen, helperGen: r.gen as number });
    if (nodes.length === 0) throw new AppError("agent.ui.unsupported", 422);
    return { address: w.address, class: w.class, gen, title: typeof r.title === "string" ? r.title : "", partial: r.partial === true, nodes };
  }

  /** Actions: the window must still be visible and the id must come from the last snapshot. */
  async #actOn(address: string, gen: number) {
    await this.svc.uiWindow(address);
    const v = this.view;
    if (!v || v.address !== address || v.gen !== gen) throw new AppError("agent.ui.stale", 409);
    this.arm();
    return v.helperGen;
  }

  async act(address: string, gen: number, id: string, op: "action" | "focus" | "select", action?: string) {
    const g = await this.#actOn(address, gen);
    if (op === "action") {
      if (!action) throw new AppError("agent.request.invalid", 400);
      await this.helper.request("act", { gen: g, node: id, action });
    } else await this.helper.request(op, { gen: g, node: id });
  }

  /**
   * Types the text. Without an editable interface, falls back to the keyboard ([typing], phone) if the helper gives focus
   * and confirms the node really has it; after the window is raised focus is checked again (so text doesn't go elsewhere).
   * [typing] false (Claude): the fallback is never tried → agent.ui.noAction.
   */
  async setText(address: string, gen: number, id: string, text: string, confirm = false, typing = true): Promise<{ typed: boolean }> {
    const g = await this.#actOn(address, gen);
    const r = await this.helper.request("set_text", { gen: g, node: id, text, confirm, typing });
    if (r.needsTyping !== true || !text) return { typed: false };
    if (!typing) throw new AppError("agent.ui.noAction", 400);
    const h = this.svc.ctx.hyprctl;
    if (!h) throw new AppError("agent.desktop.noHyprland", 503);
    await h.dispatch([{ op: "focusWindow", address }]);
    const f = await this.helper.request("is_focused", { gen: g, node: id });
    if (f.focused !== true) throw new AppError("agent.ui.noAction", 400);
    await runInput(this.svc.io.input, h, { type: "text", text }, (x, y) => [x, y]);
    return { typed: true };
  }

  async setValue(address: string, gen: number, id: string, value: number) {
    const g = await this.#actOn(address, gen);
    await this.helper.request("set_value", { gen: g, node: id, value });
  }
}

interface Subscriber {
  address: string;
  send(ev: string): void;
  close(): void;
}

const address = z.string().regex(ADDRESS);
export const UI_NODE_ID = /^\d{1,5}(\.\d{1,5}){0,40}$/;
const target = { address, gen: z.number().int().min(1), id: z.string().regex(UI_NODE_ID) };

export function atspiRoutes(app: FastifyInstance, ctx: Ctx, io: UiIo = realUiIo, opts: UiOpts = {}) {
  const limit = opts.limit ?? new RateLimit(30, 5000);
  const ui = new UiService(ctx, io, { idleMs: opts.idleMs, timeoutMs: opts.timeoutMs, stateFile: opts.stateFile, log: (msg, err) => app.log.warn({ err }, msg) });
  ctx.ui = ui; // Claude PC tools (ui_*) use it with their own clients
  const subs = new Set<Subscriber>();
  const phone = ui.client("phone", () => subs.size > 0);
  phone.onChanged = () => {
    for (const s of subs) if (s.address === phone.view?.address) s.send("changed");
  };
  phone.onClosed = () => {
    for (const s of subs) s.close();
    subs.clear();
  };
  app.addHook("onClose", async () => ui.closeAll());

  const guard = (req: FastifyRequest) => {
    if (!ctx.control) throw new AppError("agent.control.disabled", 403);
    return requireControl(ctx, ctx.control, req, limit);
  };

  app.get("/v1/desktop/ui", async (req) => {
    await guard(req);
    const q = z.object({ address }).parse(req.query);
    return phone.snapshot(q.address);
  });

  app.delete("/v1/desktop/ui", async () => {
    // Closing is always safe (like control DELETE, no token required).
    const was = phone.view !== null;
    await phone.close();
    return { closed: was };
  });

  app.post("/v1/desktop/ui/act", async (req) => {
    const b = z
      .object({ ...target, op: z.enum(["action", "focus", "select"]).default("action"), action: z.string().regex(/^[A-Za-z][A-Za-z0-9 _.-]{0,39}$/).optional() })
      .parse(req.body);
    await guard(req);
    await phone.act(b.address, b.gen, b.id, b.op, b.action);
    return { ok: true };
  });

  app.post("/v1/desktop/ui/text", async (req) => {
    const b = z.object({ ...target, text: z.string().max(2000).regex(TEXT_OK), confirm: z.boolean().default(false) }).parse(req.body);
    await guard(req);
    return { ok: true, ...(await phone.setText(b.address, b.gen, b.id, b.text, b.confirm)) };
  });

  app.post("/v1/desktop/ui/value", async (req) => {
    const b = z.object({ ...target, value: z.number().finite() }).parse(req.body);
    await guard(req);
    await phone.setValue(b.address, b.gen, b.id, b.value);
    return { ok: true };
  });

  // SSE: only "changed" (no content) → the phone re-requests the snapshot; "closed" when the view closes, when control
  // ends (even if the view was never opened), when the token changes or when "control" is turned off.
  app.get("/v1/desktop/ui/events", async (req, reply) => {
    await guard(req);
    const q = z.object({ address }).parse(req.query);
    await ui.uiWindow(q.address);
    reply.hijack();
    const res = reply.raw;
    res.writeHead(200, { "content-type": "text/event-stream", "cache-control": "no-cache", "x-accel-buffering": "no" });
    res.write(": tiphys\n\n");
    const ping = setInterval(() => res.write(": ping\n\n"), 25_000);
    ping.unref?.();
    let unwatch = () => {};
    const sub: Subscriber = {
      address: q.address,
      send: (ev) => res.write(`event: ${ev}\ndata: {}\n\n`),
      close: () => {
        clearInterval(ping);
        unwatch();
        subs.delete(sub);
        res.end("event: closed\ndata: {}\n\n");
      },
    };
    subs.add(sub);
    unwatch = watchControl(ctx, ctx.control!, req, () => {
      sub.close();
      phone.arm();
    }, opts.recheckMs);
    phone.arm();
    req.raw.on("close", () => {
      clearInterval(ping);
      unwatch();
      subs.delete(sub);
      phone.arm();
    });
  });
}
