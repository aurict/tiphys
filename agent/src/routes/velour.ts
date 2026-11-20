// Velour (YouTube Music desktop player) remote ("desktop" feature): playback, queue, search, library and lyrics through
// Velour's local control socket. Velour has it off by default (Settings → Desktop → Remote control).
// - Socket $XDG_RUNTIME_DIR/velour/control.sock: one JSON line per connection, protocol 1 (velour docs/remote-control.md).
//   Connects only to a socket owned by the agent's own user.
// - One endpoint, POST /v1/velour {op, …}: the body is validated per op here and sent on with the protocol version.
//   Search queries, library contents and lyrics stay out of URLs (so out of request logs) and are never written to
//   logs or events.
// - Velour errors → agent.velour.<code>; socket missing/refused → agent.velour.unavailable (503).
// - GET /v1/velour/events (SSE): live state. Long-polls Velour's `wait` op and sends a `state` event each time its `rev`
//   changes (an older Velour without `rev`: the state every 2 s); `unavailable`-type errors as `error {code}`, retried.
// - POST /v1/velour/sleep: Velour's sleep timer plus an optional PC action when it fires (screen off: control session
//   when set; suspend: "power" feature + confirm). The action lives in memory: an agent restart forgets it (the timer
//   itself runs in Velour). POST /v1/velour/show: Velour's window to the front and focused (control session).
import { lstat } from "node:fs/promises";
import type { ServerResponse } from "node:http";
import { connect } from "node:net";
import { join } from "node:path";
import type { FastifyInstance, FastifyRequest } from "fastify";
import { z } from "zod";
import { RateLimit, requireControl } from "../control.ts";
import { AppError } from "../errors.ts";
import { run } from "../exec.ts";
import { unsupportedRoutes } from "../platform/support.ts";
import type { Ctx } from "../server.ts";
import { sseWriter } from "./browser.ts";

export const VELOUR_PROTOCOL = 1;
const RESPONSE_MAX = 16 * 1024 * 1024;
const LOCAL_TIMEOUT_MS = 5_000;
/** Ops that call YouTube Music (Velour itself gives up after 30 s). */
const NETWORK_TIMEOUT_MS = 35_000;

export function velourSocketPath(env: NodeJS.ProcessEnv = process.env): string {
  const runtime = env.XDG_RUNTIME_DIR?.startsWith("/") ? env.XDG_RUNTIME_DIR : `/run/user/${process.getuid?.() ?? 0}`;
  return join(runtime, "velour", "control.sock");
}

/** Velour error code → HTTP status (agent.velour.<code>); anything else → failed (502). */
export const VELOUR_ERRORS: Record<string, number> = {
  badRequest: 400,
  unsupportedVersion: 502,
  tooLarge: 413,
  notFound: 404,
  notSignedIn: 409,
  timeout: 504,
  busy: 429,
  failed: 502,
};

const id = z.string().min(1).max(300);
const link = z.object({ name: z.string().max(500), browseId: z.string().max(300).nullish() });
const track = z.object({
  videoId: id,
  title: z.string().max(1000),
  artists: z.array(link).max(50).optional(),
  album: link.nullish(),
  duration: z.number().int().min(0).nullish(),
  thumbnail: z.string().max(2000).nullish(),
  setVideoId: z.string().max(300).nullish(),
  playable: z.boolean().optional(),
  like: z.enum(["like", "dislike", "indifferent"]).nullish(),
  detail: z.string().max(1000).nullish(),
});
const watchTarget = z.object({
  kind: z.literal("watch"),
  videoId: id.nullish(),
  playlistId: id.nullish(),
  params: z.string().max(300).nullish(),
});
const index = z.number().int().min(0).max(100_000);
const query = z.string().trim().min(1).max(300);
const playlistTitle = z.string().trim().min(1).max(150);
const sleepFields = { minutes: z.number().int().min(1).max(720).optional(), endOfTrack: z.boolean().optional() };
const oneSleepMode = (x: { minutes?: number; endOfTrack?: boolean }) => !(x.minutes !== undefined && x.endOfTrack);

export const velourOp = z.discriminatedUnion("op", [
  z.object({ op: z.literal("state") }),
  z.object({ op: z.literal("queue") }),
  z.object({ op: z.literal("lyrics") }),
  z.object({ op: z.literal("toggle") }),
  z.object({ op: z.literal("next") }),
  z.object({ op: z.literal("prev") }),
  z.object({ op: z.literal("clear") }),
  z.object({ op: z.literal("seek"), seconds: z.number().finite().min(0).max(86_400) }),
  z.object({ op: z.literal("volume"), percent: z.number().finite().min(0).max(100) }),
  z.object({ op: z.literal("mute"), on: z.boolean() }),
  z.object({ op: z.literal("shuffle"), on: z.boolean() }),
  z.object({ op: z.literal("repeat"), mode: z.enum(["off", "all", "one"]) }),
  z.object({ op: z.literal("jump"), index }),
  z.object({ op: z.literal("remove"), index }),
  z.object({ op: z.literal("move"), from: index, to: index }),
  z.object({ op: z.literal("play-next"), track }),
  z.object({ op: z.literal("add-to-queue"), track }),
  z.object({ op: z.literal("play"), tracks: z.array(track).min(1).max(2000), start: index.default(0), shuffle: z.boolean().default(false) }),
  z.object({ op: z.literal("play-target"), target: watchTarget }),
  z.object({ op: z.literal("radio"), videoId: id }),
  z.object({ op: z.literal("search"), query }),
  z.object({ op: z.literal("suggest"), query }),
  z.object({ op: z.literal("page"), id, params: z.string().max(300).nullish() }),
  z.object({ op: z.literal("more"), token: z.string().min(1).max(4096) }),
  z.object({ op: z.literal("home") }),
  z.object({ op: z.literal("library"), tab: z.enum(["playlists", "albums", "artists"]) }),
  z.object({ op: z.literal("liked") }),
  z.object({ op: z.literal("history") }),
  z.object({ op: z.literal("rate"), videoId: id, like: z.enum(["like", "dislike", "indifferent"]) }),
  z.object({ op: z.literal("playlists") }),
  z.object({ op: z.literal("add-to-playlist"), playlistId: id, videoIds: z.array(id).min(1).max(2000) }),
  z.object({ op: z.literal("create-playlist"), title: playlistTitle, videoIds: z.array(id).max(2000).default([]) }),
  z.object({ op: z.literal("wait"), since: z.number().int().min(0), timeout: z.number().int().min(1).max(25).optional() }),
  z.object({ op: z.literal("explore") }),
  z.object({ op: z.literal("eq") }),
  z.object({ op: z.literal("set-eq"), preset: z.string().trim().min(1).max(100) }),
  z.object({ op: z.literal("sleep"), ...sleepFields }),
  z.object({ op: z.literal("show") }),
  z.object({ op: z.literal("save-queue"), title: playlistTitle }),
  z.object({ op: z.literal("save-to-library"), playlistId: id, save: z.boolean() }),
  z.object({ op: z.literal("remove-from-playlist"), playlistId: id, videoId: id, setVideoId: id }),
]);
export type VelourOp = z.infer<typeof velourOp>;

const NETWORK_OPS = new Set<VelourOp["op"]>([
  "lyrics", "search", "suggest", "page", "more", "home", "library", "liked", "history", "rate", "add-to-playlist", "create-playlist",
  "explore", "save-queue", "save-to-library", "remove-from-playlist",
]);

/** How long to wait for Velour's answer: `wait` holds the line up to its own timeout (default 20 s). */
export function velourTimeout(op: VelourOp): number {
  if (op.op === "wait") return ((op.timeout ?? 20) + 5) * 1000;
  return NETWORK_OPS.has(op.op) ? NETWORK_TIMEOUT_MS : LOCAL_TIMEOUT_MS;
}

/** Sends one request line and reads one answer line; `result` on ok, AppError otherwise. `signal` drops the connection. */
export async function velourRequest(path: string, op: VelourOp, timeoutMs = velourTimeout(op), signal?: AbortSignal): Promise<unknown> {
  // Only a socket that belongs to us (Velour makes it 0600 in a 0700 directory of ours).
  const st = await lstat(path).catch(() => null);
  if (!st?.isSocket()) throw new AppError("agent.velour.unavailable", 503);
  if (process.getuid && st.uid !== process.getuid()) throw new AppError("agent.velour.unavailable", 503, { reason: "owner" });

  const line = await new Promise<string>((resolve, reject) => {
    const sock = connect(path);
    const chunks: Buffer[] = [];
    let size = 0;
    let done = false;
    const finish = (err: AppError | null, value = "") => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      sock.destroy();
      if (err) reject(err);
      else resolve(value);
    };
    const timer = setTimeout(() => finish(new AppError("agent.velour.timeout", 504)), timeoutMs);
    signal?.addEventListener("abort", () => finish(new AppError("agent.velour.failed", 502, { reason: "aborted" })), { once: true });
    sock.on("connect", () => sock.write(JSON.stringify({ v: VELOUR_PROTOCOL, ...op }) + "\n"));
    sock.on("data", (b: Buffer) => {
      const nl = b.indexOf(0x0a);
      chunks.push(nl === -1 ? b : b.subarray(0, nl));
      size += b.length;
      if (nl !== -1) finish(null, Buffer.concat(chunks).toString("utf8"));
      else if (size > RESPONSE_MAX) finish(new AppError("agent.velour.failed", 502, { reason: "tooLarge" }));
    });
    sock.on("end", () => finish(size ? null : new AppError("agent.velour.failed", 502), Buffer.concat(chunks).toString("utf8")));
    sock.on("error", (e: NodeJS.ErrnoException) =>
      finish(e.code === "ENOENT" || e.code === "ECONNREFUSED" ? new AppError("agent.velour.unavailable", 503) : new AppError("agent.velour.failed", 502)),
    );
  });

  const res = z
    .object({ ok: z.boolean(), result: z.unknown().optional(), error: z.object({ code: z.string(), message: z.string().optional() }).optional() })
    .safeParse((() => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })());
  if (!res.success) throw new AppError("agent.velour.failed", 502, { reason: "badResponse" });
  if (res.data.ok) return res.data.result ?? null;
  const code = res.data.error?.code ?? "failed";
  const known = code in VELOUR_ERRORS;
  // Velour's message is English text about the request (e.g. "start is out of range"), never library content.
  throw new AppError(`agent.velour.${known ? code : "failed"}`, VELOUR_ERRORS[known ? code : "failed"], { message: res.data.error?.message?.slice(0, 300) ?? "" });
}

export type SleepThen = "none" | "screenOff" | "suspend";

/** Velour's state with the agent's pending sleep action added (`sleep.then`); other results unchanged. */
export function withSleepThen(result: unknown, then: SleepThen): unknown {
  if (!result || typeof result !== "object" || !("sleep" in result)) return result;
  const r = result as { sleep: unknown };
  if (!r.sleep || typeof r.sleep !== "object") return result;
  return { ...r, sleep: { ...(r.sleep as object), then } };
}

const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);

export interface VelourOpts {
  socketPath?: string;
  /** Retry delay after Velour was unreachable, and the poll interval for a Velour without `wait`. */
  retryMs?: number;
  pollMs?: number;
  pingMs?: number;
  /** Long-poll length asked of Velour (seconds). */
  waitSeconds?: number;
  /** Runs the sleep timer's PC action (tests replace it). */
  sleepAction?: (then: Exclude<SleepThen, "none">) => Promise<void>;
  limit?: RateLimit;
}

export function velourRoutes(app: FastifyInstance, ctx: Ctx, opts: VelourOpts = {}) {
  // Unix socket only (Windows named pipes are not implemented).
  if (process.platform === "win32") return unsupportedRoutes(app, "/v1/velour", "desktop.velour");
  const path = opts.socketPath ?? velourSocketPath();
  const limit = opts.limit ?? new RateLimit(10, 5000);
  const guard = (req: FastifyRequest) => {
    if (!ctx.control) throw new AppError("agent.control.disabled", 403);
    return requireControl(ctx, ctx.control, req, limit);
  };

  // ---- sleep timer's PC action ----
  let sleep: { then: Exclude<SleepThen, "none">; slept: number; abort: AbortController } | null = null;
  const runAction =
    opts.sleepAction ??
    (async (then: Exclude<SleepThen, "none">) => {
      if (then === "screenOff") {
        if (!ctx.hyprctl) throw new AppError("agent.desktop.noHyprland", 409);
        await ctx.hyprctl.dispatch([{ op: "dpms", on: false }]);
      } else {
        await run("systemctl", ["--no-ask-password", "suspend"], { allowFail: true });
      }
    });
  const pendingThen = (): SleepThen => sleep?.then ?? "none";
  const clearSleep = () => {
    sleep?.abort.abort();
    sleep = null;
  };
  /** Waits for Velour's `slept` counter to pass `slept` (fired → action) or its timer to go away (cancelled). */
  async function watchSleep(w: NonNullable<typeof sleep>, rev: number) {
    let since = rev;
    while (sleep === w) {
      let s: Record<string, unknown>;
      try {
        s = (await velourRequest(path, { op: "wait", since, timeout: opts.waitSeconds ?? 20 }, undefined, w.abort.signal)) as Record<string, unknown>;
      } catch {
        if (sleep !== w) return;
        await delay(opts.retryMs ?? 3000, w.abort.signal);
        continue;
      }
      if (sleep !== w) return;
      if (num(s?.rev) === since) await delay(1000, w.abort.signal); // answered at once (busy): don't spin
      since = num(s?.rev) ?? since;
      if ((num(s?.slept) ?? 0) > w.slept) {
        sleep = null;
        try {
          await runAction(w.then);
        } catch (err) {
          app.log.warn({ err }, "velour sleep action failed");
        }
        return;
      }
      if (!s?.sleep) {
        sleep = null; // cancelled (in Velour or from the phone)
        return;
      }
    }
  }

  // Same limit as Velour's own request limit (2000 tracks fit well within it).
  app.post("/v1/velour", { bodyLimit: 2 * 1024 * 1024 }, async (req) => {
    const op = velourOp.parse(req.body);
    // Cancelling the timer through the plain op drops the PC action too.
    if (op.op === "sleep" && op.minutes === undefined && !op.endOfTrack) clearSleep();
    return { result: withSleepThen(await velourRequest(path, op), pendingThen()) };
  });

  app.post("/v1/velour/sleep", async (req) => {
    const b = z
      .object({ ...sleepFields, then: z.enum(["none", "screenOff", "suspend"]).default("none"), confirm: z.literal(true).optional() })
      .refine(oneSleepMode)
      .parse(req.body ?? {});
    const cancel = b.minutes === undefined && !b.endOfTrack;
    if (!cancel && b.then === "screenOff") await guard(req);
    if (!cancel && b.then === "suspend") {
      if (!ctx.store.get().features.power) throw new AppError("agent.velour.powerDisabled", 403);
      if (!b.confirm) throw new AppError("agent.power.confirmRequired", 400);
    }
    clearSleep();
    const state = (await velourRequest(path, { op: "sleep", minutes: b.minutes, endOfTrack: b.endOfTrack })) as Record<string, unknown>;
    if (!cancel && b.then !== "none" && state && typeof state === "object") {
      const w = { then: b.then, slept: num(state.slept) ?? 0, abort: new AbortController() };
      sleep = w;
      void watchSleep(w, num(state.rev) ?? 0);
    }
    return { result: withSleepThen(state, pendingThen()) };
  });

  app.post("/v1/velour/show", async (req) => {
    await guard(req);
    await velourRequest(path, { op: "show" });
    // Hyprland doesn't let a background app take focus; focus its window from here (best effort).
    await ctx.focusClass?.(VELOUR_CLASS).catch(() => false);
    return { ok: true };
  });

  // ---- live state ----
  const streams = new Set<() => void>();
  app.addHook("onClose", async () => {
    for (const end of [...streams]) end();
    clearSleep();
  });
  app.get("/v1/velour/events", async (req, reply) => {
    reply.hijack();
    const raw: ServerResponse = reply.raw;
    raw.writeHead(200, { "content-type": "text/event-stream; charset=utf-8", "cache-control": "no-store", "x-accel-buffering": "no" });
    const out = sseWriter(raw);
    const abort = new AbortController();
    const ping = setInterval(() => out.write(": ping\n\n"), opts.pingMs ?? 15_000);
    ping.unref?.();
    const end = () => {
      if (!streams.delete(end)) return;
      abort.abort();
      clearInterval(ping);
      raw.end();
    };
    streams.add(end);
    raw.on("close", end);

    let rev: number | null = null;
    let lastError: string | null = null;
    while (!abort.signal.aborted) {
      try {
        const op: VelourOp = rev === null ? { op: "state" } : { op: "wait", since: rev, timeout: opts.waitSeconds ?? 20 };
        const started = Date.now();
        const s = (await velourRequest(path, op, undefined, abort.signal)) as Record<string, unknown> | null;
        if (abort.signal.aborted) break;
        lastError = null;
        const r = num(s?.rev);
        if (rev === null || r !== rev) out.send("state", withSleepThen(s, pendingThen()), true);
        if (r === null) {
          // A Velour without `wait`: plain polling.
          rev = null;
          await delay(opts.pollMs ?? 2000, abort.signal);
        } else {
          // Velour answers a wait at once when too many are parked: don't spin on an unchanged rev.
          if (r === rev && Date.now() - started < 1000) await delay(opts.pollMs ?? 2000, abort.signal);
          rev = r;
        }
      } catch (e) {
        if (abort.signal.aborted) break;
        const code = e instanceof AppError ? e.code : "agent.velour.failed";
        if (code !== lastError) out.send("error", { code });
        lastError = code;
        rev = null;
        await delay(opts.retryMs ?? 3000, abort.signal);
      }
    }
  });
}

/** Velour's Wayland app id (window class). */
const VELOUR_CLASS = "io.github.mikailustuner.Velour";

const delay = (ms: number, signal?: AbortSignal) =>
  new Promise<void>((resolve) => {
    if (signal?.aborted) return resolve();
    const t = setTimeout(resolve, ms);
    signal?.addEventListener("abort", () => (clearTimeout(t), resolve()), { once: true });
  });
