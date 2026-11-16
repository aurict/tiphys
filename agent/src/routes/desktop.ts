// Desktop (Wayland): clipboard read/write (wl-paste / wl-copy), screenshot (grim), clipboard sync
// (silent "clipboard.pc" notification to the phone when the PC clipboard changes) and "Open on PC" (xdg-open).
// The systemd user service may not know WAYLAND_DISPLAY; if missing, the socket under $XDG_RUNTIME_DIR is found.
// PRIVACY: clipboard text and opened addresses are never written to the event stream, the audit log or logs.
import { execFile, spawn } from "node:child_process";
import { readdir } from "node:fs/promises";
import { createInterface } from "node:readline";
import type { Readable } from "node:stream";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { AppError } from "../errors.ts";
import { payloadOf, type Notice } from "../notify.ts";
import type { Ctx } from "../server.ts";

export async function waylandEnv(): Promise<NodeJS.ProcessEnv> {
  const runtime = process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.() ?? 1000}`;
  let display = process.env.WAYLAND_DISPLAY;
  if (!display) {
    const names = await readdir(runtime).catch(() => [] as string[]);
    display = names.filter((n) => /^wayland-\d+$/.test(n)).sort()[0];
  }
  if (!display) throw new AppError("agent.desktop.noDisplay", 503);
  return { ...process.env, XDG_RUNTIME_DIR: runtime, WAYLAND_DISPLAY: display };
}

/** Session D-Bus (playerctl, browsers); if missing from the service environment, $XDG_RUNTIME_DIR/bus. */
export function sessionBusEnv(): NodeJS.ProcessEnv {
  const runtime = process.env.XDG_RUNTIME_DIR ?? `/run/user/${process.getuid?.() ?? 1000}`;
  return { XDG_RUNTIME_DIR: runtime, DBUS_SESSION_BUS_ADDRESS: process.env.DBUS_SESSION_BUS_ADDRESS ?? `unix:path=${runtime}/bus` };
}

function runBuffer(cmd: string, args: string[], env: NodeJS.ProcessEnv, timeoutMs = 15000): Promise<{ out: Buffer; code: number; err: string }> {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { env, timeout: timeoutMs, encoding: "buffer", maxBuffer: 64 * 1024 * 1024 }, (e, stdout, stderr) => {
      if (e && (e as NodeJS.ErrnoException).code === "ENOENT") return reject(new AppError("agent.exec.commandMissing", 500, { command: cmd }));
      if (e && (e as { killed?: boolean }).killed) return reject(new AppError("agent.exec.timeout", 504, { command: cmd }));
      resolve({ out: stdout, code: e ? (typeof e.code === "number" ? e.code : -1) : 0, err: stderr.toString("utf8").slice(0, 1000) });
    });
  });
}

/** wl-copy forks into the background to hold the clipboard; unless started with output streams closed, execFile never finishes. */
function copy(text: string, env: NodeJS.ProcessEnv): Promise<void> {
  return new Promise((resolve, reject) => {
    const p = spawn("wl-copy", ["--type", "text/plain;charset=utf-8"], { env, stdio: ["pipe", "ignore", "ignore"] });
    const t = setTimeout(() => p.kill(), 10000);
    p.on("error", (e) => {
      clearTimeout(t);
      reject((e as NodeJS.ErrnoException).code === "ENOENT" ? new AppError("agent.exec.commandMissing", 500, { command: "wl-copy" }) : e);
    });
    p.on("exit", (code) => {
      clearTimeout(t);
      code === 0 ? resolve() : reject(new AppError("agent.desktop.clipboardFailed", 502, { code }));
    });
    p.stdin.end(text, "utf8");
  });
}

/** Upper limit of clipboard text sent to the phone (UTF-8 bytes). */
export const CLIP_MAX_BYTES = 3000;
/**
 * Upper limit of the unencrypted notification payload. A WebPush record is at most 4096 bytes; minus the aes128gcm
 * header (86) + tag (16) + padding delimiter (1) leaves 3993. Because JSON escapes (\n, \", control characters) can
 * grow the text, the payload is measured separately.
 */
export const CLIP_MAX_PAYLOAD = 3800;
/** The "this content is secret" marker of password managers like KDE/KeePassXC. */
export const PASSWORD_HINT = "x-kde-passwordManagerHint";
const TEXT_TYPES = /^(text\/plain|UTF8_STRING$|STRING$|TEXT$)/;

/** The clipboard watcher's outside world (faked in tests). */
export interface ClipboardIo {
  /** Wayland environment; null if there is no display (session). */
  env(): Promise<NodeJS.ProcessEnv | null>;
  /** Process that writes a line on every clipboard change (`wl-paste --watch`). */
  watch(env: NodeJS.ProcessEnv): { stdout: Readable | null; kill(): unknown; on(ev: "close" | "error", fn: (...a: unknown[]) => void): unknown };
  types(env: NodeJS.ProcessEnv): Promise<string[]>;
  read(env: NodeJS.ProcessEnv): Promise<Buffer | null>;
  write(env: NodeJS.ProcessEnv, text: string): Promise<void>;
}

export const realClipboardIo: ClipboardIo = {
  env: () => waylandEnv().catch(() => null),
  // The command reads and discards the content (so the source app doesn't write into a half-closed pipe); each line
  // carries only the state: data | nil | clear | sensitive (wl-clipboard 2.2+; older versions print empty → data).
  watch: (env) => spawn("wl-paste", ["--watch", "sh", "-c", 'cat >/dev/null; echo "${CLIPBOARD_STATE:-data}"'], { env, stdio: ["ignore", "pipe", "ignore"] }),
  types: async (env) => {
    const r = await runBuffer("wl-paste", ["--list-types"], env, 5000);
    return r.code === 0 ? r.out.toString("utf8").split("\n").map((x) => x.trim()).filter(Boolean) : [];
  },
  read: async (env) => {
    const r = await runBuffer("wl-paste", ["--no-newline", "--type", "text"], env, 5000);
    return r.code === 0 ? r.out : null;
  },
  write: (env, text) => copy(text, env),
};

export type ClipboardCheck = "sent" | "disabled" | "no-display" | "password" | "not-text" | "empty" | "too-big" | "from-phone" | "same";

/**
 * Watches the PC clipboard; sends changed text to the phone with a "clipboard.pc" notification (no event record).
 * The setting (desktop.clipboardSync) is read every round: when off the process stops within 30 s, when on it starts.
 * Without a display (session closed) it idles; if the process exits it is restarted with growing delay (5 s → 5 min).
 */
export class ClipboardWatcher {
  #ctx: Ctx;
  #io: ClipboardIo;
  #debounceMs: number;
  #checkMs: number;
  #retryMs: number;
  #env: NodeJS.ProcessEnv | null = null;
  #child: ReturnType<ClipboardIo["watch"]> | null = null;
  #timer: NodeJS.Timeout | null = null;
  #debounce: NodeJS.Timeout | null = null;
  #failures = 0;
  #stopped = false;
  #running: Promise<unknown> = Promise.resolve();
  /** Last sent text (or the text on the clipboard when watching started). */
  #last: string | null = null;
  /** Last text from the phone: not sent back once written to the PC. */
  #fromPhone: string | null = null;

  constructor(ctx: Ctx, io: ClipboardIo = realClipboardIo, opts: { debounceMs?: number; checkMs?: number; retryMs?: number } = {}) {
    this.#ctx = ctx;
    this.#io = io;
    this.#debounceMs = opts.debounceMs ?? 500;
    this.#checkMs = opts.checkMs ?? 30_000;
    this.#retryMs = opts.retryMs ?? 5000;
  }

  get watching() {
    return this.#child !== null;
  }

  /** The watcher is only set up while the "desktop" feature is on; here only the sync setting is checked. */
  #enabled() {
    return this.#ctx.store.get().desktop.clipboardSync;
  }

  /** Text written from the phone to the PC (PUT /v1/desktop/clipboard). Kept only in memory. */
  fromPhone(text: string) {
    this.#fromPhone = text;
  }

  start() {
    this.#schedule(0);
  }

  stop() {
    this.#stopped = true;
    if (this.#timer) clearTimeout(this.#timer);
    if (this.#debounce) clearTimeout(this.#debounce);
    this.#child?.kill();
    this.#child = null;
  }

  #schedule(ms: number) {
    if (this.#stopped) return;
    if (this.#timer) clearTimeout(this.#timer);
    this.#timer = setTimeout(() => void this.reconcile(), ms);
    this.#timer.unref?.();
  }

  /** Starts or stops the watcher process depending on the setting and the display. */
  async reconcile(): Promise<void> {
    if (this.#stopped) return;
    if (!this.#enabled()) {
      this.#child?.kill();
      this.#child = null;
      return this.#schedule(this.#checkMs);
    }
    if (this.#child) return this.#schedule(this.#checkMs);
    const env = await this.#io.env();
    if (!env || this.#stopped) return this.#schedule(this.#checkMs);
    this.#env = env;
    // The initial clipboard content is not sent (the watcher also writes a line at startup).
    this.#last = await this.#io.read(env).then((b) => b?.toString("utf8") ?? "", () => "");
    if (this.#stopped) return;
    const started = Date.now();
    const child = this.#io.watch(env);
    this.#child = child;
    child.on("error", () => {}); // no wl-paste: retried via close
    if (child.stdout) createInterface({ input: child.stdout }).on("line", (line) => this.#onLine(line.trim()));
    child.on("close", () => {
      if (this.#child !== child) return; // stopped on purpose
      this.#child = null;
      this.#failures = Date.now() - started > 60_000 ? 1 : this.#failures + 1;
      this.#schedule(Math.min(this.#retryMs * 2 ** (this.#failures - 1), 300_000));
    });
    this.#schedule(this.#checkMs);
  }

  #onLine(state: string) {
    // Password manager content (wl-clipboard's own marker) is never read.
    if (state === "sensitive" || state === "nil" || state === "clear") return;
    if (this.#debounce) clearTimeout(this.#debounce);
    this.#debounce = setTimeout(() => {
      this.#running = this.#running.then(() => this.check()).catch(() => {});
    }, this.#debounceMs);
    this.#debounce.unref?.();
  }

  /** Reads the clipboard and notifies if needed; returns why it was skipped (for tests). */
  async check(): Promise<ClipboardCheck> {
    if (!this.#enabled()) return "disabled";
    const env = this.#env;
    if (!env) return "no-display";
    const types = await this.#io.types(env);
    if (types.some((t) => t.includes(PASSWORD_HINT))) return "password";
    if (!types.some((t) => TEXT_TYPES.test(t))) return "not-text";
    const buf = await this.#io.read(env);
    if (!buf || buf.length === 0) return "empty";
    if (buf.length > CLIP_MAX_BYTES) return "too-big";
    const text = buf.toString("utf8");
    if (!text.trim()) return "empty";
    if (text === this.#fromPhone) {
      this.#last = text;
      return "from-phone";
    }
    if (text === this.#last) return "same";
    this.#last = text;
    const notice: Notice = { key: "clipboard.pc", params: { text }, priority: "low", sensitive: true };
    if (Buffer.byteLength(payloadOf(notice), "utf8") > CLIP_MAX_PAYLOAD) return "too-big";
    await this.#ctx.notifier.send(notice);
    return "sent";
  }
}

export function desktopRoutes(app: FastifyInstance, ctx: Ctx, io: ClipboardIo = realClipboardIo, opts?: ConstructorParameters<typeof ClipboardWatcher>[2]) {
  const watcher = new ClipboardWatcher(ctx, io, opts);
  watcher.start();
  app.addHook("onClose", async () => watcher.stop());

  app.get("/v1/desktop/clipboard", async () => {
    const env = await waylandEnv();
    const r = await runBuffer("wl-paste", ["--no-newline", "--type", "text"], env);
    // wl-paste exits 1 if the clipboard is empty or not text.
    return { text: r.code === 0 ? r.out.toString("utf8").slice(0, 1_000_000) : "" };
  });

  app.put("/v1/desktop/clipboard", async (req) => {
    // The body (clipboard text) is not recorded anywhere; only method and path go to the audit log.
    const { text } = z.object({ text: z.string().max(1_000_000) }).parse(req.body);
    watcher.fromPhone(text);
    const env = await io.env();
    if (!env) throw new AppError("agent.desktop.noDisplay", 503);
    // If the same text is already on the clipboard it isn't rewritten (so rich content isn't lost when PC text copied to the phone comes back).
    if ((await io.read(env).catch(() => null))?.toString("utf8") === text) return { ok: true };
    await io.write(env, text);
    return { ok: true };
  });

  app.get("/v1/desktop/screenshot", async (req, reply) => {
    const q = z.object({ scale: z.coerce.number().min(0.1).max(1).default(0.5) }).parse(req.query);
    // PNG: distributions' grim packages are often built with JPEG support disabled.
    const r = await runBuffer("grim", ["-s", String(q.scale), "-t", "png", "-l", "3", "-"], await waylandEnv(), 20000);
    if (r.code !== 0 || r.out.length === 0) throw new AppError("agent.desktop.screenshotFailed", 502, { stderr: r.err });
    return reply.header("content-type", "image/png").header("cache-control", "no-store").send(r.out);
  });
}

/** Opens the address in the PC's default browser; the process is detached (the request doesn't wait while the browser stays open). */
export type Opener = (url: string, env: NodeJS.ProcessEnv) => Promise<void>;

export const xdgOpen: Opener = (url, env) =>
  new Promise((resolve, reject) => {
    const p = spawn("xdg-open", [url], { env, detached: true, stdio: "ignore" });
    p.once("error", (e) =>
      reject((e as NodeJS.ErrnoException).code === "ENOENT" ? new AppError("agent.exec.commandMissing", 500, { command: "xdg-open" }) : e),
    );
    p.once("spawn", () => {
      p.unref();
      resolve();
    });
  });

export const OPEN_URL_MAX = 4096;

/** Only http/https; an address with no spaces or control characters, at most 4096 characters. Returns the normalized form. */
export function checkOpenUrl(raw: string): string | null {
  if (raw.length > OPEN_URL_MAX || /[\s\u0000-\u001f\u007f]/.test(raw)) return null;
  let u: URL;
  try {
    u = new URL(raw);
  } catch {
    return null;
  }
  if ((u.protocol !== "http:" && u.protocol !== "https:") || !u.hostname) return null;
  return u.href;
}

export function openRoutes(app: FastifyInstance, opener: Opener = xdgOpen, env: () => Promise<NodeJS.ProcessEnv> = async () => ({ ...(await waylandEnv()), ...sessionBusEnv() })) {
  app.post("/v1/desktop/open", async (req) => {
    // The address may be private: not written to the event stream; only the path goes to the audit log.
    const { url } = z.object({ url: z.string().min(1).max(OPEN_URL_MAX) }).parse(req.body);
    const href = checkOpenUrl(url.trim());
    if (!href) throw new AppError("agent.desktop.badUrl", 400);
    await opener(href, await env());
    return { ok: true };
  });
}
