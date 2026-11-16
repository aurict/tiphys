// Firefox bridge, agent side (11.2): the unix socket the helper (firefox_host.ts) connects to.
// - Socket $XDG_RUNTIME_DIR/tiphys/firefox.sock; directory 0700 and ours (not a symlink), socket 0600 → only the same
//   user can connect (Node has no SO_PEERCRED; checked via path permissions). Won't open if another agent is listening.
// - Versioned protocol: the extension first sends `hello {version, ext, permissions}` (within 5 s, otherwise closed).
//   Agent → extension `req {id, op, args}`; extension → agent `res {id, ok, result | error}` (5 s timeout), `event
//   {name:"tabs", tabs}` (coalesced over 300 ms), `permissions {permissions}`.
// - Single active extension connection: a second hello while a live connection exists (second Firefox, old extension)
//   is rejected with `{type:"error", code:"busy"}`; the extension retries with growing delay (≤ 10 min). Two instances
//   don't keep kicking each other off.
// PRIVACY: tab URLs/titles and page text pass through memory only in request responses; never written to logs or events.
import { chmod, lstat, mkdir, rm } from "node:fs/promises";
import { connect, createServer, type Server, type Socket } from "node:net";
import { dirname } from "node:path";
import { z } from "zod";
import { AppError } from "./errors.ts";
import { FrameDecoder, encodeFrame } from "./firefox_frame.ts";

export const BRIDGE_PROTOCOL = 1;
export const REQUEST_TIMEOUT_MS = 5000;
const HELLO_TIMEOUT_MS = 5000;

/** Extension error codes → HTTP status (agent.browser.<code>); anything not listed → failed. */
export const BROWSER_ERRORS: Record<string, number> = {
  tabNotFound: 404,
  badUrl: 400,
  permissionRequired: 403,
  passwordField: 409,
  noMedia: 404,
  noInput: 404,
  noArticle: 404,
  unsupported: 422,
  badRequest: 400,
  failed: 502,
};

export interface BrowserStatus {
  connected: boolean;
  version: number | null;
  ext: string | null;
  permissions: { content: boolean };
}

export type BrowserEvent = { type: "tabs"; tabs: unknown[] } | { type: "status"; status: BrowserStatus };

const permissionsSchema = z.object({ content: z.boolean().default(false) }).default({ content: false });
const messageSchema = z.discriminatedUnion("type", [
  z.object({ type: z.literal("hello"), version: z.number().int(), ext: z.string().max(40).nullable().default(null), permissions: permissionsSchema }),
  z.object({ type: z.literal("res"), id: z.number().int(), ok: z.boolean(), result: z.unknown().optional(), error: z.string().max(40).optional() }),
  z.object({ type: z.literal("event"), name: z.literal("tabs"), tabs: z.array(z.unknown()).max(5000) }),
  z.object({ type: z.literal("permissions"), permissions: permissionsSchema }),
]);

interface Conn {
  sock: Socket;
  version: number;
  ext: string | null;
  permissions: { content: boolean };
}

/** Prepares the socket directory; deletes a stale (dead) socket file, errors if it's live. */
async function prepare(path: string) {
  const dir = dirname(path);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  const st = await lstat(dir);
  if (!st.isDirectory() || (process.getuid && st.uid !== process.getuid())) throw new Error(`güvensiz soket klasörü: ${dir}`);
  await chmod(dir, 0o700);
  const old = await lstat(path).catch(() => null);
  if (!old) return;
  if (!old.isSocket()) throw new Error(`soket yolunda başka dosya var: ${path}`);
  const alive = await new Promise<boolean>((res) => {
    const s = connect(path);
    s.once("connect", () => (s.destroy(), res(true)));
    s.once("error", () => res(false));
  });
  if (alive) throw new Error(`Firefox köprü soketi kullanımda: ${path}`);
  await rm(path, { force: true });
}

export class BrowserBridge {
  readonly path: string;
  #server: Server;
  #conn: Conn | null = null;
  #nextId = 1;
  #pending = new Map<number, { sock: Socket; resolve: (v: unknown) => void; reject: (e: unknown) => void; timer: NodeJS.Timeout }>();
  #listeners = new Set<(e: BrowserEvent) => void>();
  #socks = new Set<Socket>();
  #log: (msg: string) => void;

  private constructor(path: string, server: Server, log: (msg: string) => void) {
    this.path = path;
    this.#server = server;
    this.#log = log;
  }

  static async listen(path: string, opts: { log?: (msg: string) => void } = {}): Promise<BrowserBridge> {
    await prepare(path);
    const server = createServer();
    const bridge = new BrowserBridge(path, server, opts.log ?? (() => {}));
    server.on("connection", (s) => bridge.#accept(s));
    await new Promise<void>((res, rej) => {
      server.once("error", rej);
      server.listen(path, () => res());
    });
    await chmod(path, 0o600);
    return bridge;
  }

  get connected() {
    return this.#conn !== null;
  }

  get status(): BrowserStatus {
    const c = this.#conn;
    return { connected: !!c, version: c?.version ?? null, ext: c?.ext ?? null, permissions: { content: c?.permissions.content ?? false } };
  }

  /** Subscribes to events (tab list, status); the returned function unsubscribes. */
  onEvent(fn: (e: BrowserEvent) => void): () => void {
    this.#listeners.add(fn);
    return () => this.#listeners.delete(fn);
  }

  #emit(e: BrowserEvent) {
    for (const fn of this.#listeners) {
      try {
        fn(e);
      } catch {
        // a listener error doesn't break the bridge
      }
    }
  }

  /** Request to the extension; notConnected if not connected, timeout if no reply in 5 s, extension error agent.browser.<code>. */
  request(op: string, args: Record<string, unknown> = {}, timeoutMs = REQUEST_TIMEOUT_MS): Promise<unknown> {
    const c = this.#conn;
    if (!c) return Promise.reject(new AppError("agent.browser.notConnected", 503));
    const id = this.#nextId++;
    let frame: Buffer;
    try {
      frame = encodeFrame({ type: "req", id, op, args });
    } catch {
      return Promise.reject(new AppError("agent.request.invalid", 400));
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new AppError("agent.browser.timeout", 504));
      }, timeoutMs);
      this.#pending.set(id, { sock: c.sock, resolve, reject, timer });
      c.sock.write(frame);
    });
  }

  #accept(sock: Socket) {
    this.#socks.add(sock);
    const dec = new FrameDecoder();
    const helloTimer = setTimeout(() => sock.destroy(), HELLO_TIMEOUT_MS);
    helloTimer.unref?.();
    sock.on("data", (chunk: Buffer) => {
      try {
        for (const f of dec.push(chunk)) this.#onMessage(sock, messageSchema.parse(JSON.parse(f.toString("utf8"))), helloTimer);
      } catch (e) {
        this.#log(`Firefox köprüsü: bozuk ileti, bağlantı kapatıldı (${e instanceof Error ? e.name : "hata"})`);
        sock.destroy();
      }
    });
    sock.on("error", () => {});
    sock.on("close", () => {
      this.#socks.delete(sock);
      clearTimeout(helloTimer);
      this.#drop(sock);
    });
  }

  #onMessage(sock: Socket, m: z.infer<typeof messageSchema>, helloTimer: NodeJS.Timeout) {
    if (m.type === "hello") {
      if (m.version !== BRIDGE_PROTOCOL) {
        sock.end(encodeFrame({ type: "error", code: "version", supported: BRIDGE_PROTOCOL }));
        return;
      }
      clearTimeout(helloTimer);
      const old = this.#conn;
      if (old && old.sock !== sock) {
        this.#log("Firefox köprüsü: başka bir eklenti bağlantısı zaten var, yenisi reddedildi");
        sock.end(encodeFrame({ type: "error", code: "busy" })); // the existing live connection stays
        return;
      }
      this.#conn = { sock, version: m.version, ext: m.ext, permissions: m.permissions };
      this.#emit({ type: "status", status: this.status });
      return;
    }
    if (this.#conn?.sock !== sock) return; // connection without hello, or one replaced by a newer one
    if (m.type === "res") {
      const p = this.#pending.get(m.id);
      if (!p || p.sock !== sock) return;
      this.#pending.delete(m.id);
      clearTimeout(p.timer);
      if (m.ok) p.resolve(m.result ?? null);
      else {
        const code = m.error && Object.hasOwn(BROWSER_ERRORS, m.error) ? m.error : "failed";
        p.reject(new AppError(`agent.browser.${code}`, BROWSER_ERRORS[code]!));
      }
    } else if (m.type === "event") {
      this.#emit({ type: "tabs", tabs: m.tabs });
    } else {
      this.#conn.permissions = m.permissions;
      this.#emit({ type: "status", status: this.status });
    }
  }

  #failPending(sock: Socket) {
    for (const [id, p] of this.#pending) {
      if (p.sock !== sock) continue;
      this.#pending.delete(id);
      clearTimeout(p.timer);
      p.reject(new AppError("agent.browser.notConnected", 503));
    }
  }

  #drop(sock: Socket) {
    this.#failPending(sock);
    if (this.#conn?.sock === sock) {
      this.#conn = null;
      this.#emit({ type: "status", status: this.status });
    }
  }

  async close() {
    for (const s of this.#socks) s.destroy();
    await new Promise<void>((res) => this.#server.close(() => res()));
    await rm(this.path, { force: true });
  }
}
