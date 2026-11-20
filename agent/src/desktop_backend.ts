// Desktop backend selection ("desktop" feature, once at startup; see server.ts): Hyprland (the agent drives it itself,
// routes/hypr.ts, stream.ts, …) or the native helper `tiphys-desktop` (other desktops, desktop_helper.ts,
// routes/desktop_portable.ts). config `desktop.backend` (absent = "auto"):
// - "auto": Hyprland if an instance is found (same cheap check as hyprctl uses: a socket under
//   $XDG_RUNTIME_DIR/hypr), else the helper if its binary is found, else Hyprland (its routes answer
//   agent.desktop.noHyprland, as before the helper existed).
// - Helper binary: `desktop.helperPath`, else next to the agent (../desktop-helper/target/release/tiphys-desktop),
//   else `tiphys-desktop` on PATH. Only an executable regular file counts.
// GET /v1/desktop/capabilities tells the app which backend runs and what it can do.
import { constants } from "node:fs";
import { access, stat } from "node:fs/promises";
import { delimiter, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { FastifyInstance } from "fastify";

export type DesktopBackend = "hyprland" | "helper";

/** Everything the Hyprland backend offers (the helper backend lists what its platform can do). */
export const HYPRLAND_CAPABILITIES = [
  "windows", "windowActions", "workspaces", "monitors", "thumbnails", "screenshot", "stream", "input", "text", "apps", "launch",
  "dpms", "clipboard", "clipboardSync", "h264", "mobileView", "sunshine", "pcTools", "browserFocus",
] as const;

const exe = process.platform === "win32" ? "tiphys-desktop.exe" : "tiphys-desktop";
/** The helper built in this repository (agent/../desktop-helper). */
export const BUNDLED_HELPER = fileURLToPath(new URL(`../../desktop-helper/target/release/${exe}`, import.meta.url));

async function executable(path: string): Promise<boolean> {
  const s = await stat(path).catch(() => null);
  if (!s?.isFile()) return false;
  return access(path, constants.X_OK).then(() => true, () => false);
}

/** The helper binary: configured path, bundled build, PATH; null if none is executable. */
export async function findHelper(configured: string | undefined, bundled = BUNDLED_HELPER, path = process.env.PATH ?? ""): Promise<string | null> {
  if (configured) return (await executable(configured)) ? configured : null;
  if (await executable(bundled)) return bundled;
  for (const dir of path.split(delimiter)) {
    if (dir && (await executable(join(dir, exe)))) return join(dir, exe);
  }
  return null;
}

export interface BackendDeps {
  /** Resolves if a Hyprland instance is reachable (hypr.ts hyprEnv). */
  hyprland(): Promise<unknown>;
  findHelper(configured: string | undefined): Promise<string | null>;
}

export interface BackendChoice {
  backend: DesktopBackend;
  /** Helper binary (helper backend); null = not found (requests answer agent.desktop.helperMissing). */
  helperPath: string | null;
}

export async function selectBackend(cfg: { backend?: "auto" | DesktopBackend; helperPath?: string }, deps: BackendDeps): Promise<BackendChoice> {
  const want = cfg.backend ?? "auto";
  if (want === "hyprland") return { backend: "hyprland", helperPath: null };
  if (want === "helper") return { backend: "helper", helperPath: await deps.findHelper(cfg.helperPath) };
  if (await deps.hyprland().then(() => true, () => false)) return { backend: "hyprland", helperPath: null };
  const helperPath = await deps.findHelper(cfg.helperPath);
  return helperPath ? { backend: "helper", helperPath } : { backend: "hyprland", helperPath: null };
}

/** GET /v1/desktop/capabilities → {backend, capabilities, …}. */
export function capabilitiesRoute(app: FastifyInstance, get: () => Promise<Record<string, unknown>>) {
  app.get("/v1/desktop/capabilities", async () => get());
}
