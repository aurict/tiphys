// Desktop input and coordinates: the live screen (routes/stream.ts, 10.2) and Claude's PC tools
// (claude/pc.ts, 10.3) use the same code — a single code path.
// - Coordinates: image pixel (stream frame or Claude's screenshot) → global logical coordinate
//   (as used by hyprctl), clamped to the region.
// - Cursor via the hyprctl.ts adapter (classic `movecursor`, Lua `hl.dsp.cursor.move`); click/wheel via `ydotool`;
//   special keys via `ydotool key` (allowed key table); text via `wtype -` (stdin; Turkish characters).
// No shell: all commands take argument arrays. Keystrokes and text are never written anywhere.
import { z } from "zod";
import type { Exec } from "./control.ts";
import { AppError } from "./errors.ts";
import type { Hyprctl } from "./hyprctl.ts";
import type { Bytes, HyprMonitor, HyprWindow } from "./routes/hypr.ts";

// ---- coordinates ----

/** Region shown by the stream (global logical coordinates, as used by hyprctl). */
export interface Region {
  x: number;
  y: number;
  w: number;
  h: number;
}

export interface StreamTarget {
  /** Recorded region. */
  region: Region;
  /** Physical pixel size of the region (with monitor scale). */
  pixels: { w: number; h: number };
  /** wf-recorder / grim target arguments (-o output or -g region). */
  args: string[];
  monitor: string;
}

const even = (n: number) => Math.max(2, 2 * Math.round(n / 2));

/** Logical region of the monitor (width/height swap if rotated 90/270°). */
export function monitorRegion(m: HyprMonitor & { transform?: number }): Region {
  const rot = (m.transform ?? 0) % 2 === 1;
  const w = Math.round((rot ? m.height : m.width) / (m.scale || 1));
  const h = Math.round((rot ? m.width : m.height) / (m.scale || 1));
  return { x: m.x, y: m.y, w, h };
}

/** Monitor or single-window target. A window is clamped to the monitor bounds. */
export function targetFor(monitors: Array<HyprMonitor & { transform?: number }>, sel: { monitor?: string; window?: HyprWindow }): StreamTarget {
  if (sel.window) {
    const w = sel.window;
    const m = monitors.find((x) => x.id === w.monitor) ?? monitors.find((x) => x.focused) ?? monitors[0];
    if (!m) throw new AppError("agent.desktop.noDisplay", 503);
    const mr = monitorRegion(m);
    const x0 = Math.max(w.at[0], mr.x);
    const y0 = Math.max(w.at[1], mr.y);
    const x1 = Math.min(w.at[0] + w.size[0], mr.x + mr.w);
    const y1 = Math.min(w.at[1] + w.size[1], mr.y + mr.h);
    if (x1 - x0 < 2 || y1 - y0 < 2) throw new AppError("agent.desktop.windowNotVisible", 409);
    const region = { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    return {
      region,
      pixels: { w: Math.round(region.w * m.scale), h: Math.round(region.h * m.scale) },
      args: ["-g", `${region.x},${region.y} ${region.w}x${region.h}`],
      monitor: m.name,
    };
  }
  const m = (sel.monitor ? monitors.find((x) => x.name === sel.monitor) : null) ?? (sel.monitor ? null : (monitors.find((x) => x.focused) ?? monitors[0]));
  if (!m) throw new AppError(sel.monitor ? "agent.desktop.monitorNotFound" : "agent.desktop.noDisplay", sel.monitor ? 404 : 503);
  const region = monitorRegion(m);
  const rot = ((m as { transform?: number }).transform ?? 0) % 2 === 1;
  return { region, pixels: { w: rot ? m.height : m.width, h: rot ? m.width : m.height }, args: ["-o", m.name], monitor: m.name };
}

/** Output image size: physical size × scale, even numbers, at most 2560 wide. */
export function outputSize(pixels: { w: number; h: number }, scale: number): { w: number; h: number } {
  let s = scale;
  if (pixels.w * s > 2560) s = 2560 / pixels.w;
  return { w: even(pixels.w * s), h: even(pixels.h * s) };
}

/** Point in the image (image pixel, in [img] size) → global logical coordinate (clamped to the region). */
export function mapPoint(x: number, y: number, img: { w: number; h: number }, r: Region): [number, number] {
  const gx = r.x + (x * r.w) / img.w;
  const gy = r.y + (y * r.h) / img.h;
  return [Math.round(Math.min(Math.max(gx, r.x), r.x + r.w - 1)), Math.round(Math.min(Math.max(gy, r.y), r.y + r.h - 1))];
}

/** Global coordinate → image pixel (null if outside the region). */
export function unmapPoint(gx: number, gy: number, img: { w: number; h: number }, r: Region): [number, number] | null {
  if (gx < r.x || gy < r.y || gx >= r.x + r.w || gy >= r.y + r.h) return null;
  return [Math.round(((gx - r.x) * img.w) / r.w), Math.round(((gy - r.y) * img.h) / r.h)];
}

// ---- input ----


/** Linux input key codes (input-event-codes.h). Only these can be sent. */
export const KEYS: Record<string, number> = {
  Esc: 1, Tab: 15, Enter: 28, Backspace: 14, Delete: 111, Insert: 110, Space: 57,
  Up: 103, Down: 108, Left: 105, Right: 106, Home: 102, End: 107, PageUp: 104, PageDown: 109,
  F1: 59, F2: 60, F3: 61, F4: 62, F5: 63, F6: 64, F7: 65, F8: 66, F9: 67, F10: 68, F11: 87, F12: 88,
  Super: 125, PrintScreen: 99,
  // Numeric keypad +/−: independent of the keyboard layout (e.g. zoom in/out with Ctrl in Firefox).
  KPPlus: 78, KPMinus: 74,
  // Letters and digits only with Ctrl/Alt/Super (shortcuts); text is typed with wtype (independent of the keyboard layout).
  A: 30, B: 48, C: 46, D: 32, E: 18, F: 33, G: 34, H: 35, I: 23, J: 36, K: 37, L: 38, M: 50,
  N: 49, O: 24, P: 25, Q: 16, R: 19, S: 31, T: 20, U: 22, V: 47, W: 17, X: 45, Y: 21, Z: 44,
  "0": 11, "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10,
};
export const MODS = { ctrl: 29, alt: 56, shift: 42, super: 125 } as const;
export type Mod = keyof typeof MODS;
const CHORD_ONLY = /^[A-Z0-9]$/;

/** Key + modifiers → `ydotool key` arguments (press … release, in reverse order). AppError if not allowed. */
export function keyArgs(key: string, mods: Mod[] = []): string[] {
  const code = Object.hasOwn(KEYS, key) ? KEYS[key] : undefined;
  if (code === undefined) throw new AppError("agent.desktop.badKey", 400);
  const ms = [...new Set(mods)];
  for (const m of ms) if (!Object.hasOwn(MODS, m)) throw new AppError("agent.desktop.badKey", 400);
  if (CHORD_ONLY.test(key) && !ms.some((m) => m !== "shift")) throw new AppError("agent.desktop.badKey", 400);
  const mc = ms.map((m) => MODS[m]);
  return [...mc.map((c) => `${c}:1`), `${code}:1`, `${code}:0`, ...mc.reverse().map((c) => `${c}:0`)];
}

/** Text: at most 2000 characters; no control characters other than \n and \t. */
export const TEXT_OK = /^[^\u0000-\u0008\u000b-\u001f\u007f-\u009f]*$/;
export function checkText(text: string): boolean {
  return text.length > 0 && text.length <= 2000 && TEXT_OK.test(text);
}

/** Splits text into wtype chunks and Enter/Tab keys. */
export function textPieces(text: string): Array<{ text: string } | { key: "Enter" | "Tab" }> {
  const out: Array<{ text: string } | { key: "Enter" | "Tab" }> = [];
  for (const part of text.split(/([\n\t])/)) {
    if (part === "\n") out.push({ key: "Enter" });
    else if (part === "\t") out.push({ key: "Tab" });
    else if (part) out.push({ text: part });
  }
  return out;
}

const BUTTONS = { left: 0x00, right: 0x01, middle: 0x02 } as const;
const hex = (n: number) => `0x${n.toString(16).padStart(2, "0")}`;

const point = { x: z.number().finite(), y: z.number().finite(), w: z.number().int().min(2).max(8192).optional(), h: z.number().int().min(2).max(8192).optional() };
const button = z.enum(["left", "right", "middle"]).default("left");
export const inputEvent = z.discriminatedUnion("type", [
  z.object({ type: z.literal("move"), ...point }),
  z.object({ type: z.literal("click"), button, count: z.number().int().min(1).max(3).default(1), x: point.x.optional(), y: point.y.optional(), w: point.w, h: point.h }),
  z.object({ type: z.literal("down"), button }),
  z.object({ type: z.literal("up"), button }),
  z.object({ type: z.literal("scroll"), dx: z.number().int().min(-20).max(20).default(0), dy: z.number().int().min(-20).max(20).default(0) }),
  z.object({ type: z.literal("text"), text: z.string().max(2000) }),
  z.object({ type: z.literal("key"), key: z.string().max(20), mods: z.array(z.enum(["ctrl", "alt", "shift", "super"])).max(4).default([]) }),
  // Sequences (e.g. ctrl+shift+p → wait → text): order is kept by the agent's queue, wait at most 1 s.
  z.object({ type: z.literal("wait"), ms: z.number().int().min(0).max(1000) }),
]);
export type InputEvent = z.infer<typeof inputEvent>;

/** Outside world of the input commands (fake in tests). */
export interface InputIo {
  exec: Exec;
  bytes(cmd: string, args: string[], opts: { env: NodeJS.ProcessEnv; input?: Buffer; timeoutMs?: number }): Promise<Bytes>;
  /** ydotool/wtype environment (Wayland + YDOTOOL_SOCKET). */
  inputEnv(): Promise<NodeJS.ProcessEnv>;
}

/** Image point → global logical coordinate ([w]×[h]: image size reported by the client, else the known one). */
export type PointMapper = (x: number, y: number, w?: number, h?: number) => [number, number];

/** Runs a single input event (live screen and Claude tools). AppError for a disallowed key/text. */
export async function runInput(io: InputIo, hyprctl: Hyprctl, e: InputEvent, map: PointMapper): Promise<void> {
  const moveTo = async (x: number, y: number, w?: number, h?: number) => {
    const [gx, gy] = map(x, y, w, h);
    // Classic `movecursor` or Lua `hl.dsp.cursor.move` (the adapter detects the mode).
    await hyprctl.dispatch([{ op: "cursor", x: gx, y: gy }]);
  };
  const ydotool = async (args: string[]) => {
    const r = await io.exec("ydotool", args, { env: await io.inputEnv(), timeoutMs: 3000, allowFail: true });
    if (r.code !== 0) throw new AppError("agent.desktop.inputFailed", 502, { command: "ydotool" });
  };
  switch (e.type) {
    case "move":
      return moveTo(e.x, e.y, e.w, e.h);
    case "click": {
      if (e.x !== undefined && e.y !== undefined) await moveTo(e.x, e.y, e.w, e.h);
      const b = hex(0xc0 | BUTTONS[e.button]);
      return ydotool(e.count > 1 ? ["click", "-r", String(e.count), "-D", "60", b] : ["click", b]);
    }
    case "down":
      return ydotool(["click", hex(0x40 | BUTTONS[e.button])]);
    case "up":
      return ydotool(["click", hex(0x80 | BUTTONS[e.button])]);
    case "scroll":
      // Wheel: dy > 0 down (negative in REL_WHEEL), dx > 0 right.
      if (!e.dx && !e.dy) return;
      return ydotool(["mousemove", "-w", "-x", String(e.dx), "-y", String(-e.dy)]);
    case "key":
      return ydotool(["key", ...keyArgs(e.key, e.mods)]);
    case "wait":
      return new Promise<void>((r) => setTimeout(r, e.ms));
    case "text": {
      if (!checkText(e.text)) throw new AppError("agent.desktop.badText", 400);
      for (const p of textPieces(e.text)) {
        if ("key" in p) await ydotool(["key", ...keyArgs(p.key)]);
        else {
          const r = await io.bytes("wtype", ["-"], { env: await io.inputEnv(), input: Buffer.from(p.text, "utf8"), timeoutMs: 10000 });
          if (r.code !== 0) throw new AppError("agent.desktop.inputFailed", 502, { command: "wtype" });
        }
      }
      return;
    }
  }
}
