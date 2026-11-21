// Hyprland commands of the kiosk placements (PLAN.md §20 "Yerleşim"), for classic (hyprctl keyword/dispatch) and Lua
// config (hyprctl eval). Pure functions over fixed constants and validated values only, nothing from a request:
// - fullscreen: a named window rule puts the app id on the mode's named workspace (yol / is / odak), fullscreen, no
//   border/shadow/rounding/animation; the workspace is focused at start.
// - scratch: the rule sends it silently to the special workspace special:tiphys instead, and a temporary keybind
//   (config screen.scratchBind, default SUPER,grave) toggles that workspace. A bind already in use is refused
//   (409 agent.screen.bindTaken) rather than overridden. Stop: unbind, rule off.
import { SCRATCH_BIND, type ScreenMode } from "../config.ts";
import { AppError } from "../errors.ts";
import { ADDRESS, luaString, type HyprMode } from "../hyprctl.ts";

export const APP_ID = "tiphys-screen";
export const RULE = "tiphys-screen";
export const SPECIAL = "tiphys";
/** Named workspace per mode (fullscreen placement). */
export const WORKSPACES: Readonly<Record<ScreenMode, string>> = { game: "yol", work: "is", focus: "odak" };

export type Placement = "fullscreen" | "scratch";

/** The rule's workspace value: "name:yol" or the special workspace (silent: it doesn't pop up on its own). */
export function ruleWorkspace(placement: Placement, ws: string): string {
  return placement === "scratch" ? `special:${SPECIAL} silent` : `name:${ws}`;
}

const NAMED = /^[a-z]{1,16}$/;

/** hyprctl calls that turn the named window rule on. `rule`/`appId` are constants (the old Game mode ones too). */
export function ruleOnArgs(mode: HyprMode, placement: Placement, ws: string, rule = RULE, appId = APP_ID): string[][] {
  if (!NAMED.test(ws)) throw new AppError("agent.request.invalid", 400);
  const target = ruleWorkspace(placement, ws);
  if (mode === "lua") {
    return [["eval", `hl.window_rule({ name = "${rule}", match = { class = "^(${appId})$" }, workspace = "${target}", fullscreen = true, border_size = 0, no_shadow = true, rounding = 0, no_anim = true, enabled = true })`]];
  }
  const props: Array<[string, string]> = [
    ["match:class", `^(${appId})$`],
    ["workspace", target],
    ["fullscreen", "on"],
    ["border_size", "0"],
    ["no_shadow", "on"],
    ["rounding", "0"],
    ["no_anim", "on"],
  ];
  return [...props.map(([k, v]) => ["keyword", `windowrule[${rule}]:${k}`, v]), ["keyword", `windowrule[${rule}]:enable`, "true"]];
}

/** hyprctl calls that disable it again. */
export function ruleOffArgs(mode: HyprMode, rule = RULE, appId = APP_ID): string[][] {
  if (mode === "lua") return [["eval", `hl.window_rule({ name = "${rule}", match = { class = "^(${appId})$" }, enabled = false })`]];
  return [["keyword", `windowrule[${rule}]:enable`, "false"]];
}

const MOD_BITS: Readonly<Record<string, number>> = { SHIFT: 1, CTRL: 4, CONTROL: 4, ALT: 8, MOD2: 16, MOD3: 32, SUPER: 64, MOD5: 128 };

/** "SUPER SHIFT,grave" → mods + key (validated against SCRATCH_BIND). */
export function parseBind(bind: string): { mods: string[]; key: string; mask: number } {
  if (!SCRATCH_BIND.test(bind)) throw new AppError("agent.request.invalid", 400);
  const [m, key] = bind.split(",") as [string, string];
  const mods = m ? m.split(/[ _]/) : [];
  return { mods, key, mask: mods.reduce((a, x) => a | MOD_BITS[x]!, 0) };
}

/** `hyprctl -j binds` → is this key combination already bound (outside submaps)? */
export function bindTaken(json: string, bind: string): boolean {
  const { key, mask } = parseBind(bind);
  let list: unknown;
  try {
    list = JSON.parse(json);
  } catch {
    return false;
  }
  if (!Array.isArray(list)) return false;
  return list.some((b: { modmask?: unknown; key?: unknown; submap?: unknown }) =>
    b?.modmask === mask && typeof b.key === "string" && b.key.toLowerCase() === key.toLowerCase() && (b.submap ?? "") === "");
}

const luaKeys = (bind: string) => {
  const { mods, key } = parseBind(bind);
  return luaString([...mods, key].join(" + "));
};

export function bindOnArgs(mode: HyprMode, bind: string): string[] {
  const { mods, key } = parseBind(bind);
  if (mode === "lua") return ["eval", `hl.bind(${luaKeys(bind)}, hl.dsp.workspace.toggle_special("${SPECIAL}"), { description = "Tiphys" })`];
  return ["keyword", "bind", `${mods.join(" ")},${key},togglespecialworkspace,${SPECIAL}`];
}

export function bindOffArgs(mode: HyprMode, bind: string): string[] {
  const { mods, key } = parseBind(bind);
  if (mode === "lua") return ["eval", `hl.unbind(${luaKeys(bind)})`];
  return ["keyword", "unbind", `${mods.join(" ")},${key}`];
}

/** Shows or hides special:tiphys (the same toggle the keybind does). */
export function toggleSpecialArgs(mode: HyprMode): string[] {
  return mode === "lua" ? ["eval", `hl.dispatch(hl.dsp.workspace.toggle_special("${SPECIAL}"))`] : ["dispatch", "togglespecialworkspace", SPECIAL];
}

/** Moves the kiosk window to special:tiphys without following it (in case the rule didn't place it). */
export function moveToSpecialArgs(mode: HyprMode, address: string): string[] {
  if (!ADDRESS.test(address)) throw new AppError("agent.desktop.badAddress", 400);
  if (mode === "lua") return ["eval", `hl.dispatch(hl.dsp.window.move({ window = "address:${address}", workspace = "special:${SPECIAL}", follow = false }))`];
  return ["dispatch", "movetoworkspacesilent", `special:${SPECIAL},address:${address}`];
}

/** `hyprctl -j clients` → the kiosk window's address and workspace name, or null. */
export function kioskWindow(json: string, appId = APP_ID): { address: string; workspace: string } | null {
  try {
    const list = JSON.parse(json) as Array<{ address?: unknown; class?: unknown; workspace?: { name?: unknown } }>;
    const w = Array.isArray(list) ? list.find((c) => c?.class === appId && typeof c.address === "string" && ADDRESS.test(c.address)) : undefined;
    return w ? { address: w.address as string, workspace: typeof w.workspace?.name === "string" ? w.workspace.name : "" } : null;
  } catch {
    return null;
  }
}
