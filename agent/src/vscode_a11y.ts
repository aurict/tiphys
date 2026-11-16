// VS Code (flatpak) accessibility tree (11.4, decision 3): --force-renderer-accessibility is added only to VS Code's
// launcher. ~/.local/share/applications/com.visualstudio.code.desktop is a copy of the flatpak
// export and shadows it; no other app is affected. The setting (accessibilitySupport) is unchanged.
// A file we didn't write ourselves (unmarked) is left untouched.
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join } from "node:path";

export const VSCODE_ID = "com.visualstudio.code";
export const A11Y_FLAG = "--force-renderer-accessibility";
const MARK = "# tiphys: vscode-a11y (tiphys-agent vscode-a11y remove ile kaldırılır)";

export interface VscodePaths {
  target: string;
  sources: string[];
}

export function vscodePaths(env: NodeJS.ProcessEnv = process.env): VscodePaths {
  const data = env.XDG_DATA_HOME || join(env.HOME || homedir(), ".local", "share");
  const file = `${VSCODE_ID}.desktop`;
  return {
    target: join(data, "applications", file),
    sources: [join(data, "flatpak", "exports", "share", "applications", file), join("/var/lib/flatpak/exports/share/applications", file)],
  };
}

/** In every Exec line, the flag right after the app id (flatpak run … com.visualstudio.code FLAG @@ %F @@). */
export function addA11yFlag(desktop: string): string {
  const lines = desktop.split("\n").map((l) => {
    if (!/^Exec\s*=/.test(l) || l.includes(A11Y_FLAG)) return l;
    const re = new RegExp(`(\\s${VSCODE_ID.replace(/\./g, "\\.")})(?=\\s|$)`);
    if (!re.test(l)) throw new Error(`beklenmeyen Exec satırı: ${l}`);
    return l.replace(re, `$1 ${A11Y_FLAG}`);
  });
  return [MARK, ...lines].join("\n");
}

async function read(p: string): Promise<string | null> {
  return readFile(p, "utf8").catch(() => null);
}

export async function vscodeA11y(action: "install" | "remove", paths: VscodePaths = vscodePaths()): Promise<string> {
  const cur = await read(paths.target);
  if (cur !== null && !cur.startsWith(MARK)) throw new Error(`${paths.target} elle yazılmış; dokunulmadı`);
  if (action === "remove") {
    if (cur === null) return "kurulu değil";
    await rm(paths.target);
    return `kaldırıldı: ${paths.target}`;
  }
  let src: string | null = null;
  for (const s of paths.sources) if ((src = await read(s)) !== null) break;
  if (src === null) throw new Error(`VS Code flatpak başlatıcısı bulunamadı: ${paths.sources.join(", ")}`);
  await mkdir(dirname(paths.target), { recursive: true });
  await writeFile(paths.target, addA11yFlag(src));
  return `yazıldı: ${paths.target} (VS Code'u yeniden başlatınca erişilebilirlik ağacı açılır)`;
}
