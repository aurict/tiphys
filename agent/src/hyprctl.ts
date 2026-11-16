// Hyprland command adapter: the same operations for Hyprland with classic (hyprlang) and Lua config (0.55+,
// hyprland.lua). In Lua mode `hyprctl keyword` doesn't work ("non-legacy parsers. Use eval"), and `hyprctl dispatch X`
// is evaluated as Lua `hl.dispatch(X)`. The mode is queried once (`hyprctl eval 'return 1'` → "ok" means Lua) and
// cached per Hyprland instance (signature).
// SECURITY: no client-supplied text goes into Lua source. Window address ^0x[0-9a-f]+$, workspace and coordinates are
// integers, app id ^[A-Za-z0-9][A-Za-z0-9._-]*$ (and must also be in the list) and written escaped as a Lua string;
// colors/width are internal constants or values validated from getoption.
import type { Exec } from "./control.ts";
import { AppError } from "./errors.ts";

export type HyprMode = "legacy" | "lua";

export const ADDRESS = /^0x[0-9a-f]{1,16}$/;
/** Launchable app id (characters safe for the shell and Lua). */
export const LAUNCH_ID = /^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$/;

export type HyprCmd =
  | { op: "focusWindow"; address: string }
  | { op: "closeWindow"; address: string }
  | { op: "fullscreen"; address: string }
  | { op: "toggleFloat"; address: string }
  | { op: "setFloat"; address: string }
  | { op: "pin"; address: string }
  | { op: "moveToWorkspace"; address: string; workspace: number }
  | { op: "workspace"; workspace: number }
  | { op: "dpms"; on: boolean }
  | { op: "launch"; appId: string }
  | { op: "cursor"; x: number; y: number };

/**
 * Lua string literal: double-quoted; backslash, quote and every non-printable/non-ASCII byte is escaped as \ddd
 * (UTF-8 byte). The output is printable ASCII only.
 */
export function luaString(s: string): string {
  let out = '"';
  for (const b of Buffer.from(s, "utf8")) {
    if (b === 0x5c) out += "\\\\";
    else if (b === 0x22) out += '\\"';
    else if (b >= 0x20 && b < 0x7f) out += String.fromCharCode(b);
    else out += `\\${String(b).padStart(3, "0")}`;
  }
  return out + '"';
}

const bad = () => new AppError("agent.request.invalid", 400);
const addr = (a: string) => {
  if (!ADDRESS.test(a)) throw new AppError("agent.desktop.badAddress", 400);
  return a;
};
const int = (n: number, min: number, max: number) => {
  if (!Number.isInteger(n) || n < min || n > max) throw bad();
  return n;
};
const appId = (id: string) => {
  if (!LAUNCH_ID.test(id)) throw new AppError("agent.desktop.appNotFound", 404);
  return id;
};

/** Classic `hyprctl dispatch` arguments. */
export function legacyDispatch(c: HyprCmd): string[] {
  switch (c.op) {
    case "focusWindow":
      return ["focuswindow", `address:${addr(c.address)}`];
    case "closeWindow":
      return ["closewindow", `address:${addr(c.address)}`];
    case "fullscreen":
      addr(c.address);
      return ["fullscreen", "0"]; // applies to the active window: focusWindow is sent first
    case "toggleFloat":
      return ["togglefloating", `address:${addr(c.address)}`];
    case "setFloat":
      return ["setfloating", `address:${addr(c.address)}`];
    case "pin":
      return ["pin", `address:${addr(c.address)}`];
    case "moveToWorkspace":
      return ["movetoworkspacesilent", `${int(c.workspace, 1, 100)},address:${addr(c.address)}`];
    case "workspace":
      return ["workspace", String(int(c.workspace, 1, 100))];
    case "dpms":
      return ["dpms", c.on ? "on" : "off"];
    case "launch":
      return ["exec", "gtk-launch", appId(c.appId)];
    case "cursor":
      return ["movecursor", String(int(c.x, -100_000, 100_000)), String(int(c.y, -100_000, 100_000))];
  }
}

/** Lua dispatcher (`hl.dsp…` expression). */
export function luaDispatch(c: HyprCmd): string {
  const win = (a: string) => `window = ${luaString(`address:${addr(a)}`)}`;
  switch (c.op) {
    case "focusWindow":
      return `hl.dsp.focus({ ${win(c.address)} })`;
    case "closeWindow":
      return `hl.dsp.window.close({ ${win(c.address)} })`;
    case "fullscreen":
      return `hl.dsp.window.fullscreen({ ${win(c.address)}, mode = "fullscreen", action = "toggle" })`;
    case "toggleFloat":
      return `hl.dsp.window.float({ ${win(c.address)}, action = "toggle" })`;
    case "setFloat":
      return `hl.dsp.window.float({ ${win(c.address)}, action = "enable" })`;
    case "pin":
      return `hl.dsp.window.pin({ ${win(c.address)}, action = "toggle" })`;
    case "moveToWorkspace":
      return `hl.dsp.window.move({ ${win(c.address)}, workspace = ${luaString(String(int(c.workspace, 1, 100)))}, follow = false })`;
    case "workspace":
      return `hl.dsp.focus({ workspace = ${luaString(String(int(c.workspace, 1, 100)))} })`;
    case "dpms":
      return `hl.dsp.dpms({ action = ${c.on ? '"enable"' : '"disable"'} })`;
    case "launch":
      return `hl.dsp.exec_cmd(${luaString(`gtk-launch ${appId(c.appId)}`)})`;
    case "cursor":
      return `hl.dsp.cursor.move({ x = ${int(c.x, -100_000, 100_000)}, y = ${int(c.y, -100_000, 100_000)} })`;
  }
}

/** Command list → hyprctl arguments (single call). */
export function dispatchArgs(mode: HyprMode, cmds: HyprCmd[]): string[] {
  if (cmds.length === 0) throw bad();
  if (mode === "lua") return ["eval", cmds.map((c) => `hl.dispatch(${luaDispatch(c)})`).join("; ")];
  const parts = cmds.map(legacyDispatch);
  return parts.length === 1 ? ["dispatch", ...parts[0]!] : ["--batch", parts.map((p) => `dispatch ${p.join(" ")}`).join(" ; ")];
}

/** Classic gradient value ("0xffff3b30 0xffff9f0a 45deg"); only colors and an optional angle. */
const GRADIENT_PART = /^(0x[0-9a-fA-F]{8}|-?\d{1,3}deg)$/;

/** Classic gradient → Lua table `{ colors = { "0x…", … }, angle = 45 }`. */
export function gradientLua(value: string): string {
  const parts = value.trim().split(/\s+/);
  if (!parts.length || !parts.every((p) => GRADIENT_PART.test(p))) throw bad();
  const colors = parts.filter((p) => p.startsWith("0x"));
  const angles = parts.filter((p) => p.endsWith("deg"));
  if (colors.length === 0 || colors.length > 10 || angles.length > 1) throw bad();
  const angle = angles.length ? `, angle = ${parseInt(angles[0]!, 10)}` : "";
  return `{ colors = { ${colors.map((c) => luaString(c.toLowerCase())).join(", ")} }${angle} }`;
}

/** Active border color and width (control indicator) → hyprctl calls (each a separate argument array). */
export function lookArgs(mode: HyprMode, look: { border: string; size?: number }): string[][] {
  if (look.size !== undefined) int(look.size, 0, 100);
  if (mode === "lua") {
    const size = look.size !== undefined ? `, border_size = ${look.size}` : "";
    return [["eval", `hl.config({ general = { col = { active_border = ${gradientLua(look.border)} }${size} } })`]];
  }
  gradientLua(look.border); // validation
  return [["keyword", "general:col.active_border", look.border], ...(look.size !== undefined ? [["keyword", "general:border_size", String(look.size)]] : [])];
}

/** Mode detection + command execution. The mode is cached per Hyprland signature (re-queried if Hyprland restarts). */
export class Hyprctl {
  readonly exec: Exec;
  readonly env: () => Promise<NodeJS.ProcessEnv>;
  #modes = new Map<string, HyprMode>();

  constructor(exec: Exec, env: () => Promise<NodeJS.ProcessEnv>) {
    this.exec = exec;
    this.env = env;
  }

  async mode(env?: NodeJS.ProcessEnv): Promise<HyprMode> {
    const e = env ?? (await this.env());
    const key = e.HYPRLAND_INSTANCE_SIGNATURE ?? "";
    const known = this.#modes.get(key);
    if (known) return known;
    const r = await this.exec("hyprctl", ["eval", "return 1"], { env: e, timeoutMs: 5000, allowFail: true });
    const mode: HyprMode = r.code === 0 && r.stdout.trim() === "ok" ? "lua" : "legacy";
    // Only a clear answer is cached: on a transient error like socket busy / Hyprland starting, the next call asks again.
    if (r.code === 0) this.#modes.set(key, mode);
    return mode;
  }

  async #run(env: NodeJS.ProcessEnv, args: string[], code: string) {
    const r = await this.exec("hyprctl", args, { env, timeoutMs: 5000, allowFail: true });
    const lines = r.stdout.split("\n").map((s) => s.trim()).filter(Boolean);
    if (r.code !== 0 || lines.length === 0 || !lines.every((l) => l === "ok")) {
      throw new AppError(code, code === "agent.control.indicatorFailed" ? 503 : 502, { output: (r.stdout || r.stderr).trim().slice(0, 300) });
    }
  }

  /** Runs dispatchers in a single call; agent.desktop.hyprctlFailed unless every line is "ok". */
  async dispatch(cmds: HyprCmd[]): Promise<void> {
    const env = await this.env();
    await this.#run(env, dispatchArgs(await this.mode(env), cmds), "agent.desktop.hyprctlFailed");
  }

  /** Border color/width (turning the indicator on and restoring use the same path). */
  async setLook(look: { border: string; size?: number }): Promise<void> {
    const env = await this.env();
    for (const args of lookArgs(await this.mode(env), look)) await this.#run(env, args, "agent.control.indicatorFailed");
  }
}
