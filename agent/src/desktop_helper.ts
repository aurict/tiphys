// Client of the native desktop helper `tiphys-desktop` (desktop-helper/PROTOCOL.md, protocol 1): the desktop backend on
// desktops other than Hyprland (Sway, X11, GNOME/KDE via the portal, Windows, macOS).
// - `tiphys-desktop serve` is started lazily on the first request: JSON lines over stdin/stdout, first line the hello
//   (protocol, platform backend, capabilities). Requests carry an id; answers may come out of order; each request has
//   its own timeout. Events (`{"event":…}`) go to subscribers; subscriptions are renewed after a restart.
// - The process stops after [idleMs] without requests, holds (open live screens) or subscribers (memory), and is
//   killed on agent shutdown. A crash rejects the pending requests; the next start waits for a growing backoff
//   (0.5 s → 30 s, reset once a process lived 60 s); with subscribers it restarts by itself after that backoff.
// - Helper error codes → AppError (see toAppError). No shell: the binary is spawned with an argument array.
// PRIVACY: request fields (typed text, clipboard) and answers (window titles, clipboard) are never logged; stderr is
// only logged as the helper's last line on a crash (the protocol keeps it free of such content).
import { spawn, type ChildProcess } from "node:child_process";
import { AppError } from "./errors.ts";

export const HELPER_PROTOCOL = 1;

export interface HelperHello {
  protocol: number;
  version: string;
  /** Platform backend: sway, x11, portal, windows, macos, none. */
  backend: string;
  capabilities: string[];
}

export interface HelperOpts {
  /** Helper binary; null = not found (every request answers agent.desktop.helperMissing). */
  command: string | null;
  /** Child environment (default: the agent's). */
  env?: NodeJS.ProcessEnv;
  timeoutMs?: number;
  helloTimeoutMs?: number;
  idleMs?: number;
  /** Restart delays after consecutive crashes (the last one repeats). */
  backoffMs?: number[];
  /** A process that lived this long resets the backoff. */
  stableMs?: number;
  killGraceMs?: number;
  /** Longest accepted line (screenshots are base64 in one line). */
  maxLine?: number;
  log?: (msg: string, err?: unknown) => void;
  now?: () => number;
}

interface Pending {
  op: string;
  resolve: (v: unknown) => void;
  reject: (e: unknown) => void;
  timer: NodeJS.Timeout;
  notFound?: string;
}

interface Proc {
  child: ChildProcess;
  hello: Promise<HelperHello>;
  startedAt: number;
  exited: Promise<void>;
}

/** Helper error → AppError. [notFound]: the route's code for `notFound` (default agent.desktop.windowNotFound). */
export function toAppError(op: string, error: unknown, notFound = "agent.desktop.windowNotFound"): AppError {
  const e = (error ?? {}) as { code?: unknown; message?: unknown };
  switch (e.code) {
    case "badRequest":
      return new AppError("agent.request.invalid", 400, { op });
    case "unsupported":
      return new AppError("agent.desktop.unsupported", 501, { op });
    case "notFound":
      return new AppError(notFound, 404);
    case "permission":
      // Which OS permission is missing (e.g. macOS Accessibility / Screen Recording); never content.
      return new AppError("agent.desktop.permission", 403, { permission: typeof e.message === "string" ? e.message.slice(0, 200) : "" });
    case "busy":
      return new AppError("agent.control.rateLimited", 429);
    default:
      return new AppError("agent.desktop.helperFailed", 502, { op });
  }
}

export class HelperClient {
  readonly command: string | null;
  #opts: Required<Omit<HelperOpts, "command" | "env">> & { env: NodeJS.ProcessEnv };
  #proc: Proc | null = null;
  #pending = new Map<number, Pending>();
  #nextId = 1;
  #holds = 0;
  #subs = new Map<string, Set<(e: Record<string, unknown>) => void>>();
  #idleTimer: NodeJS.Timeout | null = null;
  #restartTimer: NodeJS.Timeout | null = null;
  #failures = 0;
  #notBefore = 0;
  #stopped = false;
  /** The last hello (null before the first start). */
  lastHello: HelperHello | null = null;

  constructor(opts: HelperOpts) {
    this.command = opts.command;
    this.#opts = {
      env: opts.env ?? process.env,
      timeoutMs: opts.timeoutMs ?? 10_000,
      helloTimeoutMs: opts.helloTimeoutMs ?? 5000,
      idleMs: opts.idleMs ?? 60_000,
      backoffMs: opts.backoffMs ?? [500, 1000, 2000, 5000, 10_000, 30_000],
      stableMs: opts.stableMs ?? 60_000,
      killGraceMs: opts.killGraceMs ?? 1000,
      maxLine: opts.maxLine ?? 64 * 1024 * 1024,
      log: opts.log ?? (() => {}),
      now: opts.now ?? Date.now,
    };
  }

  /** Is a helper process running now (tests, memory checks)? */
  get running(): boolean {
    return this.#proc !== null;
  }

  /** Starts the helper if needed; its hello (capabilities). */
  async hello(): Promise<HelperHello> {
    const h = await this.#ensure().hello;
    this.#armIdle();
    return h;
  }

  /** AppError agent.desktop.unsupported (501) unless the helper offers [cap]. */
  async require(cap: string): Promise<HelperHello> {
    const h = await this.hello();
    if (!h.capabilities.includes(cap)) throw new AppError("agent.desktop.unsupported", 501, { capability: cap });
    return h;
  }

  /** One request; the answer's result or an AppError. */
  async request<T = unknown>(op: string, fields: Record<string, unknown> = {}, opts: { timeoutMs?: number; notFound?: string } = {}): Promise<T> {
    const proc = this.#ensure();
    await proc.hello;
    if (this.#proc !== proc) throw new AppError("agent.desktop.helperFailed", 502, { op });
    this.#clearIdle();
    const id = this.#nextId++;
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new AppError("agent.desktop.helperFailed", 502, { op, reason: "timeout" }));
        this.#armIdle();
      }, opts.timeoutMs ?? this.#opts.timeoutMs);
      this.#pending.set(id, { op, resolve: resolve as (v: unknown) => void, reject, timer, notFound: opts.notFound });
      proc.child.stdin?.write(JSON.stringify({ ...fields, id, op }) + "\n");
    });
  }

  /** Keeps the helper running (e.g. while a live screen is open); the returned function releases it. */
  hold(): () => void {
    this.#holds++;
    this.#clearIdle();
    let done = false;
    return () => {
      if (done) return;
      done = true;
      this.#holds--;
      this.#armIdle();
    };
  }

  /** Subscribes to a helper event (e.g. "focus"); the helper keeps running meanwhile. Returns the unsubscribe function. */
  subscribe(event: string, fn: (e: Record<string, unknown>) => void): () => void {
    let set = this.#subs.get(event);
    const first = !set;
    if (!set) this.#subs.set(event, (set = new Set()));
    set.add(fn);
    this.#clearIdle();
    if (first) void this.#subscribeAll();
    return () => {
      const s = this.#subs.get(event);
      if (!s?.delete(fn)) return;
      if (!s.size) this.#subs.delete(event); // the helper keeps sending until it restarts; such events are ignored
      this.#armIdle();
    };
  }

  async #subscribeAll() {
    if (!this.#subs.size) return;
    await this.request("subscribe", { events: [...this.#subs.keys()] }).catch((e) => this.#opts.log("yardımcı olay aboneliği başarısız", e));
  }

  /** Stops the helper for good (agent shutdown). */
  async stop(): Promise<void> {
    this.#stopped = true;
    this.#clearIdle();
    if (this.#restartTimer) clearTimeout(this.#restartTimer);
    await this.#kill();
  }

  #ensure(): Proc {
    if (this.#proc) return this.#proc;
    const proc: Proc = { child: null as unknown as ChildProcess, hello: Promise.resolve(null as unknown as HelperHello), startedAt: this.#opts.now(), exited: Promise.resolve() };
    this.#proc = proc;
    const hello = (async () => {
      if (this.#stopped) throw new AppError("agent.desktop.helperFailed", 502, { op: "hello" });
      const wait = this.#notBefore - this.#opts.now();
      if (wait > 0) await new Promise((r) => setTimeout(r, wait));
      return this.#start(proc);
    })();
    proc.hello = hello;
    hello.catch(() => {
      if (this.#proc === proc) this.#proc = null;
    });
    return proc;
  }

  #start(proc: Proc): Promise<HelperHello> {
    if (!this.command) throw new AppError("agent.desktop.helperMissing", 500);
    if (this.#stopped || this.#proc !== proc) throw new AppError("agent.desktop.helperFailed", 502, { op: "hello" });
    const child = spawn(this.command, ["serve"], { env: this.#opts.env, stdio: ["pipe", "pipe", "pipe"] });
    proc.child = child;
    proc.startedAt = this.#opts.now();
    child.stdin!.on("error", () => {}); // EPIPE if it exits early
    let stderr = "";
    child.stderr!.on("data", (b: Buffer) => (stderr = (stderr + b.toString("utf8")).slice(-1000)));
    let buf = "";
    let gotHello: ((h: HelperHello) => void) | null = null;
    let failHello: ((e: unknown) => void) | null = null;
    const hello = new Promise<HelperHello>((resolve, reject) => {
      gotHello = resolve;
      failHello = reject;
    });
    const helloTimer = setTimeout(() => {
      failHello?.(new AppError("agent.desktop.helperFailed", 502, { op: "hello", reason: "timeout" }));
      child.kill("SIGKILL");
    }, this.#opts.helloTimeoutMs);
    const onLine = (line: string) => {
      if (!line.trim()) return;
      let msg: Record<string, unknown>;
      try {
        msg = JSON.parse(line) as Record<string, unknown>;
      } catch {
        return this.#opts.log("yardımcıdan geçersiz satır");
      }
      if (gotHello) {
        const h = msg.hello as Partial<HelperHello> | undefined;
        if (!h || h.protocol !== HELPER_PROTOCOL || !Array.isArray(h.capabilities)) {
          failHello!(new AppError("agent.desktop.helperFailed", 502, { op: "hello", reason: "protocol" }));
          child.kill("SIGKILL");
          return;
        }
        const ok: HelperHello = { protocol: h.protocol, version: String(h.version ?? ""), backend: String(h.backend ?? "none"), capabilities: h.capabilities.filter((c): c is string => typeof c === "string") };
        clearTimeout(helloTimer);
        this.lastHello = ok;
        const g = gotHello;
        gotHello = failHello = null;
        g(ok);
        return;
      }
      if (typeof msg.event === "string") {
        for (const fn of this.#subs.get(msg.event) ?? []) {
          try {
            fn(msg);
          } catch (e) {
            this.#opts.log("yardımcı olay dinleyicisi hata verdi", e);
          }
        }
        return;
      }
      const p = typeof msg.id === "number" ? this.#pending.get(msg.id) : undefined;
      if (!p) return;
      this.#pending.delete(msg.id as number);
      clearTimeout(p.timer);
      if (msg.ok === true) p.resolve(msg.result);
      else p.reject(toAppError(p.op, msg.error, p.notFound));
      this.#armIdle();
    };
    child.stdout!.on("data", (b: Buffer) => {
      buf += b.toString("utf8");
      let i: number;
      while ((i = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, i);
        buf = buf.slice(i + 1);
        onLine(line);
      }
      if (buf.length > this.#opts.maxLine) {
        this.#opts.log("yardımcı satırı çok uzun, süreç durduruluyor");
        child.kill("SIGKILL");
      }
    });
    proc.exited = new Promise<void>((resolve) => {
      child.on("error", (e) => {
        const code = (e as NodeJS.ErrnoException).code;
        clearTimeout(helloTimer);
        failHello?.(code === "ENOENT" || code === "EACCES" ? new AppError("agent.desktop.helperMissing", 500) : new AppError("agent.desktop.helperFailed", 502, { op: "hello" }));
        this.#exited(proc, "");
        resolve();
      });
      child.on("exit", (code, signal) => {
        clearTimeout(helloTimer);
        failHello?.(new AppError("agent.desktop.helperFailed", 502, { op: "hello" }));
        this.#exited(proc, `kod ${code ?? signal}: ${stderr.trim().split("\n").at(-1) ?? ""}`);
        resolve();
      });
    });
    return hello;
  }

  /** The process ended (crash, idle stop, kill): pending requests fail, backoff for the next start. */
  #exited(proc: Proc, why: string) {
    if (this.#proc !== proc) return;
    this.#proc = null;
    for (const [id, p] of this.#pending) {
      clearTimeout(p.timer);
      p.reject(new AppError("agent.desktop.helperFailed", 502, { op: p.op }));
      this.#pending.delete(id);
    }
    if (this.#stopped || (proc as { idle?: boolean }).idle) return;
    const t = this.#opts.now();
    this.#failures = t - proc.startedAt >= this.#opts.stableMs ? 1 : this.#failures + 1;
    const b = this.#opts.backoffMs;
    const delay = b[Math.min(this.#failures - 1, b.length - 1)] ?? 0;
    this.#notBefore = t + delay;
    if (why) this.#opts.log(`masaüstü yardımcısı beklenmedik şekilde kapandı (${why}); ${delay} ms sonra yeniden`);
    // With subscribers it comes back by itself (events keep flowing); otherwise on the next request.
    if (this.#subs.size) {
      if (this.#restartTimer) clearTimeout(this.#restartTimer);
      this.#restartTimer = setTimeout(() => {
        this.#restartTimer = null;
        if (!this.#stopped && this.#subs.size && !this.#proc) void this.#subscribeAll();
      }, delay);
      this.#restartTimer.unref?.();
    }
  }

  #clearIdle() {
    if (this.#idleTimer) clearTimeout(this.#idleTimer);
    this.#idleTimer = null;
  }

  #armIdle() {
    this.#clearIdle();
    if (!this.#proc || this.#pending.size || this.#holds > 0 || this.#subs.size) return;
    this.#idleTimer = setTimeout(() => {
      this.#idleTimer = null;
      if (this.#pending.size || this.#holds > 0 || this.#subs.size) return;
      void this.#kill(true);
    }, this.#opts.idleMs);
    this.#idleTimer.unref?.();
  }

  /** Closes stdin (the helper exits), SIGTERM/SIGKILL if it doesn't. [idle]: a planned stop, no backoff. */
  async #kill(idle = false) {
    const proc = this.#proc;
    if (!proc) return;
    if (idle) (proc as { idle?: boolean }).idle = true;
    await proc.hello.catch(() => {});
    const c = proc.child;
    if (!c || c.exitCode !== null || c.signalCode !== null) {
      if (this.#proc === proc) this.#exited(proc, "");
      return;
    }
    c.stdin?.end();
    const term = setTimeout(() => c.kill("SIGTERM"), this.#opts.killGraceMs);
    const kill = setTimeout(() => c.kill("SIGKILL"), this.#opts.killGraceMs * 2);
    await proc.exited;
    clearTimeout(term);
    clearTimeout(kill);
  }
}
