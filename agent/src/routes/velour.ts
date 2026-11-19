// Velour (YouTube Music desktop player) remote ("desktop" feature): playback, queue, search, library and lyrics through
// Velour's local control socket. Velour has it off by default (Settings → Desktop → Remote control).
// - Socket $XDG_RUNTIME_DIR/velour/control.sock: one JSON line per connection, protocol 1 (velour docs/remote-control.md).
//   Connects only to a socket owned by the agent's own user.
// - One endpoint, POST /v1/velour {op, …}: the body is validated per op here and sent on with the protocol version.
//   Search queries, library contents and lyrics stay out of URLs (so out of request logs) and are never written to
//   logs or events.
// - Velour errors → agent.velour.<code>; socket missing/refused → agent.velour.unavailable (503).
import { lstat } from "node:fs/promises";
import { connect } from "node:net";
import { join } from "node:path";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

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
  z.object({ op: z.literal("create-playlist"), title: z.string().trim().min(1).max(150), videoIds: z.array(id).max(2000).default([]) }),
]);
export type VelourOp = z.infer<typeof velourOp>;

const NETWORK_OPS = new Set<VelourOp["op"]>([
  "lyrics", "search", "suggest", "page", "more", "home", "library", "liked", "history", "rate", "add-to-playlist", "create-playlist",
]);

/** Sends one request line and reads one answer line; `result` on ok, AppError otherwise. */
export async function velourRequest(path: string, op: VelourOp, timeoutMs = NETWORK_OPS.has(op.op) ? NETWORK_TIMEOUT_MS : LOCAL_TIMEOUT_MS): Promise<unknown> {
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

export function velourRoutes(app: FastifyInstance, _ctx: Ctx, opts: { socketPath?: string } = {}) {
  const path = opts.socketPath ?? velourSocketPath();
  // Same limit as Velour's own request limit (2000 tracks fit well within it).
  app.post("/v1/velour", { bodyLimit: 2 * 1024 * 1024 }, async (req) => {
    const op = velourOp.parse(req.body);
    return { result: await velourRequest(path, op) };
  });
}
