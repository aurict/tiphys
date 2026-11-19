// Minimal Agent Client Protocol (JSON-RPC 2.0 over stdio, one JSON object per line) client for `agy acp`.
// The client advertises no file system or terminal capabilities: agy does its own file and shell work (with its own
// permission prompts, which come here as session/request_permission and are answered from the phone).
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { EventEmitter } from "node:events";
import { AppError } from "../errors.ts";

export type Spawn = (cmd: string, args: string[], opts: { cwd: string }) => ChildProcessWithoutNullStreams;

const MAX_LINE = 4 * 1024 * 1024;

export interface AcpRequest {
  id: number | string;
  method: string;
  params: Record<string, unknown>;
}

/**
 * Events: "notification" (method, params), "request" (AcpRequest — answer with respond()), "exit" (code).
 */
export class AcpClient extends EventEmitter {
  readonly child: ChildProcessWithoutNullStreams;
  #id = 0;
  #pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();
  #buf = "";
  #closed = false;

  /** A line longer than MAX_LINE is being skipped up to its newline; "oversize" is emitted once per such line. */
  #discarding = false;

  constructor(
    cwd: string,
    args: string[] = [],
    // Own process group (detached): close/shutdown kill agy together with the shells it started.
    spawnFn: Spawn = (c, a, o) => spawn(c, a, { cwd: o.cwd, stdio: ["pipe", "pipe", "pipe"], env: process.env, detached: true }),
  ) {
    super();
    this.child = spawnFn("agy", ["acp", ...args], { cwd });
    this.child.stdout.setEncoding("utf8");
    this.child.stdout.on("data", (d: string) => this.#onData(d));
    this.child.stderr.on("data", () => {});
    this.child.stdin.on("error", () => {});
    this.child.on("error", (e: NodeJS.ErrnoException) => this.#fail(e.code === "ENOENT" ? new AppError("agent.agy.missing", 501) : e));
    // "close" also fires when the binary couldn't be started (then there is no "exit").
    this.child.on("close", (code) => {
      this.#fail(new AppError("agent.agy.exited", 502, { code: code ?? -1 }));
      this.emit("exit", code);
    });
  }

  get closed() {
    return this.#closed;
  }

  #fail(e: Error) {
    this.#closed = true;
    for (const [, p] of this.#pending) {
      clearTimeout(p.timer);
      p.reject(e);
    }
    this.#pending.clear();
  }

  #onData(d: string) {
    if (this.#closed) return;
    if (this.#discarding) {
      const k = d.indexOf("\n");
      if (k < 0) return;
      this.#discarding = false;
      d = d.slice(k + 1);
    }
    this.#buf += d;
    if (this.#buf.length > MAX_LINE && !this.#buf.includes("\n")) {
      // A runaway line: dropped up to its newline. The session hears about it (a lost request would hang the turn).
      this.#buf = "";
      this.#discarding = true;
      this.emit("oversize");
      return;
    }
    let k: number;
    while ((k = this.#buf.indexOf("\n")) >= 0) {
      const line = this.#buf.slice(0, k).trim();
      this.#buf = this.#buf.slice(k + 1);
      if (!line) continue;
      let m: { id?: number | string; method?: string; params?: Record<string, unknown>; result?: unknown; error?: { code?: number; message?: string } };
      try {
        m = JSON.parse(line);
      } catch {
        continue;
      }
      if (m.method && m.id !== undefined) this.emit("request", { id: m.id, method: m.method, params: m.params ?? {} } satisfies AcpRequest);
      else if (m.method) this.emit("notification", m.method, m.params ?? {});
      else if (typeof m.id === "number" && this.#pending.has(m.id)) {
        const p = this.#pending.get(m.id)!;
        this.#pending.delete(m.id);
        clearTimeout(p.timer);
        if (m.error) p.reject(new AppError("agent.agy.rpcError", 502, { code: m.error.code ?? 0, message: String(m.error.message ?? "").slice(0, 300) }));
        else p.resolve(m.result);
      }
    }
  }

  #write(obj: unknown) {
    if (this.#closed) throw new AppError("agent.agy.exited", 502);
    this.child.stdin.write(JSON.stringify(obj) + "\n");
  }

  /** Writes unless closed: answers and notifications to a process that is gone are simply dropped (never throw from a
   * stream listener — that would take the whole agent down). */
  #post(obj: unknown) {
    if (this.#closed) return;
    try {
      this.child.stdin.write(JSON.stringify(obj) + "\n");
    } catch {
      // stdin already closed
    }
  }

  request<T = Record<string, unknown>>(method: string, params: Record<string, unknown>, timeoutMs = 60_000): Promise<T> {
    return new Promise((resolve, reject) => {
      if (this.#closed) return reject(new AppError("agent.agy.exited", 502));
      const id = ++this.#id;
      // A prompt turn can run for a long time; timeoutMs 0 = no limit.
      const timer = setTimeout(() => {
        if (!this.#pending.delete(id)) return;
        reject(new AppError("agent.agy.timeout", 504, { method }));
      }, timeoutMs || 2 ** 31 - 1);
      this.#pending.set(id, { resolve: resolve as (v: unknown) => void, reject, timer });
      this.#write({ jsonrpc: "2.0", id, method, params });
    });
  }

  notify(method: string, params: Record<string, unknown>) {
    this.#post({ jsonrpc: "2.0", method, params });
  }

  respond(id: number | string, result: unknown) {
    this.#post({ jsonrpc: "2.0", id, result });
  }

  respondError(id: number | string, code: number, message: string) {
    this.#post({ jsonrpc: "2.0", id, error: { code, message } });
  }

  #signal(sig: NodeJS.Signals) {
    const pid = this.child.pid;
    try {
      // The whole process group (agy and the commands it started); falls back to the process itself.
      if (pid) process.kill(-pid, sig);
      else this.child.kill(sig);
    } catch {
      try {
        this.child.kill(sig);
      } catch {
        // already gone
      }
    }
  }

  kill(hard = false) {
    this.#fail(new AppError("agent.agy.exited", 502));
    this.#signal(hard ? "SIGKILL" : "SIGTERM");
    if (hard) return;
    const t = setTimeout(() => this.#signal("SIGKILL"), 5000);
    t.unref();
  }
}

export const INIT_PARAMS = { protocolVersion: 1, clientCapabilities: { fs: { readTextFile: false, writeTextFile: false }, terminal: false } };
