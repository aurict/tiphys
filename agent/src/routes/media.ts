// Media control (PC, "desktop" feature): MPRIS players via playerctl, system volume via wpctl (PipeWire).
// Audio outputs: `pw-dump` lists the sinks (Audio/Sink nodes) and the default; switching runs `wpctl set-default` with an
// id from that list only. Like the volume, no control session (sound only, nothing on screen changes).
// playerctl needs the session D-Bus: a systemd user service usually has DBUS_SESSION_BUS_ADDRESS; otherwise
// $XDG_RUNTIME_DIR/bus is used. No player isn't an error: 200 + players: [].
// Cover art: an http(s) URL is passed to the app as is; local (file://) art only via /v1/media/art, read from the path
// in the current metadata (the request has no path parameter), only files ≤ 5 MB starting with image bytes.
import { createHash } from "node:crypto";
import { readFile, stat } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { AppError } from "../errors.ts";
import { run, type ExecResult } from "../exec.ts";
import type { Ctx } from "../server.ts";
import { sessionBusEnv } from "./desktop.ts";

export type Exec = (cmd: string, args: string[], opts: { timeoutMs?: number; allowFail?: boolean; env?: NodeJS.ProcessEnv }) => Promise<ExecResult>;

/** Field and record separators: control characters that don't appear in titles/artist names (US / RS). */
const FS = "\u001f";
const RS = "\u001e";
const FIELDS = ["playerInstance", "status", "title", "artist", "album", "mpris:length", "position", "mpris:artUrl"] as const;
export const METADATA_FORMAT = FIELDS.map((f) => `{{${f}}}`).join(FS) + RS;

const ART_MAX_BYTES = 5 * 1024 * 1024;
const SINK = "@DEFAULT_AUDIO_SINK@";

export interface PlayerState {
  name: string;
  status: "Playing" | "Paused" | "Stopped";
  title: string | null;
  artist: string | null;
  album: string | null;
  /** Seconds (0.1 precision); null if unknown. */
  length: number | null;
  position: number | null;
  /** Raw MPRIS art URL (agent-internal only; local paths are never sent in the response). */
  art: string | null;
}

/** `playerctl -l` output: each line is a player instance (e.g. "firefox.instance_1_42", "spotify"). */
export function parsePlayerList(stdout: string): string[] {
  return [...new Set(stdout.split("\n").map((s) => s.trim()).filter(Boolean))];
}

const seconds = (us: string) => {
  const n = Number(us);
  return us.trim() === "" || !Number.isFinite(n) || n < 0 ? null : Math.round(n / 100_000) / 10;
};
const text = (s: string | undefined) => (s && s.trim() ? s : null);
const status = (s: string): PlayerState["status"] => (s === "Playing" || s === "Paused" ? s : "Stopped");

/** `playerctl -a metadata --format METADATA_FORMAT` output → state per player. */
export function parseMetadata(stdout: string): PlayerState[] {
  const out: PlayerState[] = [];
  for (const rec of stdout.split(RS)) {
    const f = rec.replace(/^\n/, "").split(FS);
    if (f.length !== FIELDS.length || !f[0]!.trim()) continue;
    out.push({
      name: f[0]!.trim(),
      status: status(f[1]!.trim()),
      title: text(f[2]),
      artist: text(f[3]),
      album: text(f[4]),
      length: seconds(f[5]!),
      position: seconds(f[6]!),
      art: text(f[7]?.trim()),
    });
  }
  return out;
}

/** The requested player if present; otherwise the playing one, then a paused one, then the first. */
export function pickPlayer(players: PlayerState[], requested?: string): PlayerState | null {
  return (
    players.find((p) => p.name === requested) ??
    players.find((p) => p.status === "Playing") ??
    players.find((p) => p.status === "Paused") ??
    players[0] ??
    null
  );
}

/** `wpctl get-volume` output: "Volume: 0.60" or "Volume: 0.45 [MUTED]". */
export function parseVolume(stdout: string): { percent: number; muted: boolean } | null {
  const m = /Volume:\s*([\d.]+)(.*)$/m.exec(stdout);
  if (!m) return null;
  return { percent: Math.round(Number(m[1]) * 100), muted: /\[MUTED\]/.test(m[2]!) };
}

/** Image type from the cover file's first bytes; null if not an image. */
export function imageType(b: Buffer): string | null {
  if (b.length >= 3 && b[0] === 0xff && b[1] === 0xd8 && b[2] === 0xff) return "image/jpeg";
  if (b.length >= 8 && b.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return "image/png";
  if (b.length >= 6 && /^GIF8[79]a$/.test(b.subarray(0, 6).toString("latin1"))) return "image/gif";
  if (b.length >= 12 && b.subarray(0, 4).toString("latin1") === "RIFF" && b.subarray(8, 12).toString("latin1") === "WEBP") return "image/webp";
  if (b.length >= 2 && b[0] === 0x42 && b[1] === 0x4d) return "image/bmp";
  return null;
}

export interface AudioOutput {
  id: number;
  name: string;
  default: boolean;
}

/** `pw-dump` JSON → audio sinks with the default one marked (metadata "default" → default.audio.sink → node.name). */
export function parseOutputs(json: string): AudioOutput[] {
  let objs: unknown;
  try {
    objs = JSON.parse(json);
  } catch {
    return [];
  }
  if (!Array.isArray(objs)) return [];
  type J = Record<string, unknown>;
  const obj = (v: unknown): J => (v && typeof v === "object" ? (v as J) : {});
  let defaultName: string | null = null;
  for (const o of objs.map(obj)) {
    if (o.type !== "PipeWire:Interface:Metadata" || obj(o.props)["metadata.name"] !== "default") continue;
    for (const m of Array.isArray(o.metadata) ? o.metadata.map(obj) : []) {
      if (m.key === "default.audio.sink") defaultName = typeof obj(m.value).name === "string" ? (obj(m.value).name as string) : null;
    }
  }
  const out: AudioOutput[] = [];
  for (const o of objs.map(obj)) {
    const props = obj(obj(o.info).props);
    if (props["media.class"] !== "Audio/Sink" || typeof o.id !== "number") continue;
    const node = typeof props["node.name"] === "string" ? props["node.name"] : "";
    const label = [props["node.description"], props["node.nick"], node].find((x) => typeof x === "string" && x.trim()) as string | undefined;
    out.push({ id: o.id, name: (label ?? `#${o.id}`).slice(0, 200), default: !!node && node === defaultName });
  }
  return out;
}

/** Short id of a cover URL (also used by Game mode for the Velour cover). */
export const artId = (art: string) => createHash("sha256").update(art).digest("hex").slice(0, 12);

export function mediaRoutes(app: FastifyInstance, _ctx: Ctx, exec: Exec = run, opts: { settleMs?: number } = {}) {
  const settleMs = opts.settleMs ?? 250;
  const env = sessionBusEnv();
  const playerctl = (args: string[]) => exec("playerctl", args, { env, timeoutMs: 5000, allowFail: true });
  const wpctl = (args: string[]) => exec("wpctl", args, { env, timeoutMs: 5000, allowFail: true });

  async function players(): Promise<PlayerState[]> {
    const list = parsePlayerList((await playerctl(["-l"])).stdout);
    if (list.length === 0) return [];
    // If a player has no metadata (e.g. no track ever opened) playerctl may return an error code; output is still read.
    const meta = parseMetadata((await playerctl(["-a", "metadata", "--format", METADATA_FORMAT])).stdout);
    return list.map((name) => meta.find((m) => m.name === name) ?? { name, status: "Stopped", title: null, artist: null, album: null, length: null, position: null, art: null });
  }

  async function state(requested?: string) {
    const all = await players();
    const p = pickPlayer(all, requested);
    return {
      players: all.map((x) => ({ name: x.name, status: x.status })),
      player: p && {
        name: p.name,
        status: p.status,
        title: p.title,
        artist: p.artist,
        album: p.album,
        length: p.length,
        position: p.position,
        // http(s) art directly; local files only through the agent (the path isn't put in the response).
        artUrl: p.art && /^https?:\/\//i.test(p.art) ? p.art : null,
        localArt: !!p.art && p.art.startsWith("file://"),
        artId: p.art ? artId(p.art) : null,
      },
    };
  }

  async function volume() {
    const r = await wpctl(["get-volume", SINK]);
    const v = r.code === 0 ? parseVolume(r.stdout) : null;
    if (!v) throw new AppError("agent.media.volumeFailed", 502, { stderr: r.stderr.slice(0, 500) });
    return v;
  }

  app.get("/v1/media", async (req) => {
    const q = z.object({ player: z.string().max(200).optional() }).parse(req.query);
    return state(q.player);
  });

  app.post("/v1/media/:action", async (req) => {
    const { action } = z.object({ action: z.enum(["play-pause", "play", "pause", "next", "previous", "seek", "position"]) }).parse(req.params);
    const b = z
      .object({ player: z.string().max(200).optional(), seconds: z.number().finite().min(-86_400).max(86_400).optional() })
      .parse(req.body ?? {});
    const p = pickPlayer(await players(), b.player);
    if (!p || (b.player && p.name !== b.player)) throw new AppError("agent.media.noPlayer", 404);
    let args: string[];
    if (action === "seek") {
      if (!b.seconds) throw new AppError("agent.request.invalid", 400, { field: "seconds" });
      // playerctl: "10+" forward, "10-" back (seconds).
      args = ["position", `${Math.abs(b.seconds)}${b.seconds > 0 ? "+" : "-"}`];
    } else if (action === "position") {
      if (b.seconds === undefined || b.seconds < 0) throw new AppError("agent.request.invalid", 400, { field: "seconds" });
      args = ["position", String(b.seconds)];
    } else {
      args = [action];
    }
    const r = await playerctl(["-p", p.name, ...args]);
    if (r.code !== 0) throw new AppError("agent.media.failed", 502, { stderr: r.stderr.slice(0, 500) });
    // Short wait for the player to update its state (otherwise the old state comes back and the button bounces back).
    if (settleMs > 0) await new Promise((res) => setTimeout(res, settleMs));
    return state(p.name);
  });

  app.get("/v1/media/volume", async () => volume());

  app.put("/v1/media/volume", async (req) => {
    const b = z
      .object({ percent: z.number().int().min(0).max(150).optional(), muted: z.boolean().optional() })
      .refine((x) => x.percent !== undefined || x.muted !== undefined)
      .parse(req.body);
    if (b.percent !== undefined) {
      // -l 1.5: at most 150% (without a wpctl limit very high values could strain the speaker).
      const r = await wpctl(["set-volume", "-l", "1.5", SINK, (b.percent / 100).toFixed(2)]);
      if (r.code !== 0) throw new AppError("agent.media.volumeFailed", 502, { stderr: r.stderr.slice(0, 500) });
    }
    if (b.muted !== undefined) {
      const r = await wpctl(["set-mute", SINK, b.muted ? "1" : "0"]);
      if (r.code !== 0) throw new AppError("agent.media.volumeFailed", 502, { stderr: r.stderr.slice(0, 500) });
    }
    return volume();
  });

  async function outputs() {
    const r = await exec("pw-dump", [], { env, timeoutMs: 5000, allowFail: true });
    if (r.code !== 0) throw new AppError("agent.media.outputFailed", 502, { stderr: r.stderr.slice(0, 500) });
    return { outputs: parseOutputs(r.stdout) };
  }

  app.get("/v1/media/outputs", async () => outputs());

  app.put("/v1/media/output", async (req) => {
    const b = z.object({ id: z.number().int().min(0).max(1_000_000) }).parse(req.body);
    if (!(await outputs()).outputs.some((o) => o.id === b.id)) throw new AppError("agent.media.outputNotFound", 404);
    const r = await wpctl(["set-default", String(b.id)]);
    if (r.code !== 0) throw new AppError("agent.media.outputFailed", 502, { stderr: r.stderr.slice(0, 500) });
    return outputs();
  });

  app.get("/v1/media/art", async (req, reply) => {
    // Strict schema: no extra parameters like a path are accepted.
    const q = z.strictObject({ player: z.string().max(200).optional() }).parse(req.query);
    const p = pickPlayer(await players(), q.player);
    if (!p?.art?.startsWith("file://")) throw new AppError("agent.media.noArt", 404);
    let file: string;
    try {
      file = fileURLToPath(p.art);
    } catch {
      throw new AppError("agent.media.noArt", 404);
    }
    const s = await stat(file).catch(() => null);
    if (!s?.isFile() || s.size === 0 || s.size > ART_MAX_BYTES) throw new AppError("agent.media.noArt", 404);
    const bytes = await readFile(file);
    const type = imageType(bytes);
    if (!type || bytes.length > ART_MAX_BYTES) throw new AppError("agent.media.noArt", 404);
    return reply.header("content-type", type).header("cache-control", "private, max-age=300").send(bytes);
  });
}
