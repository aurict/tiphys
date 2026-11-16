// `tiphys-agent firefox install`: registers the Firefox native messaging host (11.2).
// - Launcher: $XDG_DATA_HOME/tiphys/firefox-host (0755): absolute path of node (resolved at install) + dist/firefox_host.js.
// - Manifest: ~/.mozilla/native-messaging-hosts/dev.tiphys.bridge.json; allowed_extensions only bridge@tiphys.dev.
// Doesn't touch the Firefox profile; the extension (unsigned XPI) is installed manually by the user.
import { mkdir, readdir, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export const HOST_NAME = "dev.tiphys.bridge";
export const EXTENSION_ID = "bridge@tiphys.dev";

const here = dirname(fileURLToPath(import.meta.url));
/** From inside src/ or dist/: agent/dist/firefox_host.js. */
export const defaultHostScript = () => resolve(here, "..", "dist", "firefox_host.js");
export const defaultXpiDir = () => resolve(here, "..", "..", "firefox", "dist");

const sh = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

export interface InstallResult {
  manifest: string;
  launcher: string;
  xpi: string | null;
}

export async function installFirefoxHost(o: { home?: string; dataHome?: string; node?: string; hostScript?: string; xpiDir?: string } = {}): Promise<InstallResult> {
  const home = o.home ?? homedir();
  const dataHome = o.dataHome ?? (process.env.XDG_DATA_HOME || join(home, ".local", "share"));
  const hostScript = o.hostScript ?? defaultHostScript();
  await stat(hostScript).catch(() => {
    throw new Error(`yardımcı bulunamadı: ${hostScript} (önce: cd agent && npm run build)`);
  });
  const launcher = join(dataHome, "tiphys", "firefox-host");
  await mkdir(dirname(launcher), { recursive: true, mode: 0o700 });
  await writeFile(launcher, `#!/bin/sh\n# Tiphys Köprüsü yerel ileti yardımcısı (tiphys-agent firefox install yazdı)\nexec ${sh(o.node ?? process.execPath)} ${sh(hostScript)} "$@"\n`, { mode: 0o755 });
  const manifest = join(home, ".mozilla", "native-messaging-hosts", `${HOST_NAME}.json`);
  await mkdir(dirname(manifest), { recursive: true });
  const body = { name: HOST_NAME, description: "Tiphys Köprüsü (Firefox ⇄ Tiphys ajanı)", path: launcher, type: "stdio", allowed_extensions: [EXTENSION_ID] };
  await writeFile(manifest, JSON.stringify(body, null, 2) + "\n", { mode: 0o644 });
  const xpiDir = o.xpiDir ?? defaultXpiDir();
  const xpis = (await readdir(xpiDir).catch(() => [] as string[])).filter((f) => f.endsWith(".xpi")).sort();
  return { manifest, launcher, xpi: xpis.length ? join(xpiDir, xpis.at(-1)!) : null };
}
