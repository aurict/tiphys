// Desktop apps: XDG .desktop files and icon theme resolution (a plain version of the freedesktop specs).
// - App directories: $XDG_DATA_HOME/applications first, then $XDG_DATA_DIRS/applications; for the same ID the first
//   found wins (the user's Hidden=true copy also hides the system one). ID: subfolder "/" → "-".
// - Not shown: Type≠Application, NoDisplay/Hidden=true, OnlyShowIn/NotShowIn with respect to Hyprland.
// - Name: Name[tr_TR] > Name[tr] > Name (by requested language). Exec is never used (launching is gtk-launch <id>).
// - Icon: first the user's theme (gtk settings.ini, then gsettings), the Inherits chain, hicolor last;
//   48–256 px or scalable folders in the Applications context; otherwise /usr/share/pixmaps.
import { readdir, readFile, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

export interface DesktopApp {
  id: string;
  name: string;
  genericName: string | null;
  comment: string | null;
  categories: string[];
  keywords: string[];
  /** Icon= value (name or absolute path); the response only says present/absent. */
  icon: string | null;
  wmClass: string | null;
  /** Path of the .desktop file (only inside the agent). */
  path: string;
}

/** ID passed to the shell via gtk-launch / hyprctl exec: safe characters only. */
export const APP_ID = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$/;

function unescape(v: string) {
  return v.replace(/\\([sntr\\;])/g, (_, c: string) => ({ s: " ", n: "\n", t: "\t", r: "\r", "\\": "\\", ";": ";" })[c]!);
}

function list(v: string | undefined): string[] {
  if (!v) return [];
  return v
    .split(/(?<!\\);/)
    .map((s) => unescape(s).trim())
    .filter(Boolean);
}

/** Keys in the [Desktop Entry] group (other groups, e.g. [Desktop Action new-window], are skipped). */
export function parseDesktopFile(text: string): Map<string, string> {
  const out = new Map<string, string>();
  let inMain = false;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    if (line.startsWith("[")) {
      inMain = line === "[Desktop Entry]";
      continue;
    }
    if (!inMain) continue;
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    const key = line.slice(0, eq).trim();
    if (!out.has(key)) out.set(key, line.slice(eq + 1).trim());
  }
  return out;
}

/** Localized value: for "tr", Key[tr_TR] > Key[tr] > Key. */
export function localized(f: Map<string, string>, key: string, lang: string): string | undefined {
  const region = lang === "tr" ? "TR" : lang === "en" ? "US" : lang.toUpperCase();
  return f.get(`${key}[${lang}_${region}]`) ?? f.get(`${key}[${lang}]`) ?? f.get(key);
}

const truthy = (v: string | undefined) => v === "true" || v === "1";

/** App to show; null if it shouldn't be shown. [desktop]: XDG_CURRENT_DESKTOP (OnlyShowIn/NotShowIn). */
export function toApp(f: Map<string, string>, id: string, path: string, lang: string, desktop = "Hyprland"): DesktopApp | null {
  if ((f.get("Type") ?? "Application") !== "Application") return null;
  if (truthy(f.get("NoDisplay")) || truthy(f.get("Hidden"))) return null;
  const only = list(f.get("OnlyShowIn"));
  if (only.length && !only.includes(desktop)) return null;
  if (list(f.get("NotShowIn")).includes(desktop)) return null;
  const name = localized(f, "Name", lang);
  if (!name || !f.get("Exec")) return null;
  const opt = (k: string) => {
    const v = localized(f, k, lang);
    return v ? unescape(v) : null;
  };
  return {
    id,
    name: unescape(name),
    genericName: opt("GenericName"),
    comment: opt("Comment"),
    categories: list(f.get("Categories")),
    keywords: list(localized(f, "Keywords", lang)),
    icon: f.get("Icon") ? unescape(f.get("Icon")!) : null,
    wmClass: f.get("StartupWMClass") ?? null,
    path,
  };
}

export function xdgDataDirs(): string[] {
  const home = process.env.XDG_DATA_HOME || join(homedir(), ".local", "share");
  const rest = (process.env.XDG_DATA_DIRS || "/usr/local/share:/usr/share").split(":").filter(Boolean);
  return [...new Set([home, ...rest])];
}

async function walk(dir: string, prefix: string, depth: number, out: Array<{ id: string; path: string }>) {
  const entries = await readdir(dir, { withFileTypes: true }).catch(() => []);
  for (const e of entries.sort((a, b) => a.name.localeCompare(b.name))) {
    const p = join(dir, e.name);
    if (e.isDirectory() && depth < 3) await walk(p, `${prefix}${e.name}-`, depth + 1, out);
    else if ((e.isFile() || e.isSymbolicLink()) && e.name.endsWith(".desktop")) out.push({ id: `${prefix}${e.name.slice(0, -8)}`, path: p });
  }
}

/** All apps in the app directories (first found ID wins), sorted by name. */
export async function scanApps(appDirs: string[], lang: string, desktop = "Hyprland"): Promise<DesktopApp[]> {
  const seen = new Set<string>();
  const apps: DesktopApp[] = [];
  for (const dir of appDirs) {
    const files: Array<{ id: string; path: string }> = [];
    await walk(dir, "", 0, files);
    for (const { id, path } of files) {
      if (seen.has(id)) continue;
      seen.add(id);
      if (!APP_ID.test(id)) continue; // ID that can't be safely passed to the shell: not listed
      const text = await readFile(path, "utf8").catch(() => null);
      if (text === null || text.length > 512 * 1024) continue;
      const app = toApp(parseDesktopFile(text), id, path, lang, desktop);
      if (app) apps.push(app);
    }
  }
  const coll = new Intl.Collator(lang, { sensitivity: "base" });
  return apps.sort((a, b) => coll.compare(a.name, b.name));
}

/** App from a window class: StartupWMClass, the ID or the last part of the ID (case-insensitive). */
export function appForClass(apps: DesktopApp[], cls: string): DesktopApp | null {
  const c = cls.toLowerCase();
  if (!c) return null;
  return (
    apps.find((a) => a.wmClass?.toLowerCase() === c) ??
    apps.find((a) => a.id.toLowerCase() === c) ??
    apps.find((a) => a.id.toLowerCase().split(".").pop() === c) ??
    apps.find((a) => a.icon?.toLowerCase() === c) ??
    null
  );
}

// ---- icon theme ----

interface ThemeDir {
  sub: string;
  size: number;
  scale: number;
  type: "Fixed" | "Scalable" | "Threshold";
  context: string;
}

interface Theme {
  dirs: ThemeDir[];
  inherits: string[];
}

/** index.theme → folders (Directories + ScaledDirectories) and Inherits. */
export function parseIndexTheme(text: string): Theme {
  const groups = new Map<string, Map<string, string>>();
  let cur: Map<string, string> | null = null;
  for (const raw of text.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const g = /^\[(.+)\]$/.exec(line);
    if (g) {
      cur = new Map();
      groups.set(g[1]!, cur);
      continue;
    }
    const eq = line.indexOf("=");
    if (cur && eq > 0) cur.set(line.slice(0, eq).trim(), line.slice(eq + 1).trim());
  }
  const head = groups.get("Icon Theme") ?? new Map<string, string>();
  const subs = [...(head.get("Directories") ?? "").split(","), ...(head.get("ScaledDirectories") ?? "").split(",")].map((s) => s.trim()).filter(Boolean);
  const dirs: ThemeDir[] = [];
  for (const sub of new Set(subs)) {
    const d = groups.get(sub);
    if (!d) continue;
    const t = d.get("Type");
    dirs.push({
      sub,
      size: Number(d.get("Size")) || 0,
      scale: Number(d.get("Scale")) || 1,
      type: t === "Scalable" || t === "Fixed" ? t : "Threshold",
      context: d.get("Context") ?? "",
    });
  }
  return { dirs, inherits: (head.get("Inherits") ?? "").split(",").map((s) => s.trim()).filter(Boolean) };
}

/**
 * Icon folders in order of preference: PNG sizes close to 128 px (48–256), then scalable. Applications context
 * first; with [anyContext] the rest (e.g. generic names like "printer", "preferences-system").
 */
export function candidateDirs(theme: Theme, symbolic: boolean, anyContext = false): ThemeDir[] {
  const isApps = (d: ThemeDir) => d.context === "Applications" || d.context === "Apps" || /(^|\/)apps(@\d+x)?(\/|$)/.test(d.sub);
  const apps = theme.dirs.filter((d) => (anyContext ? !isApps(d) : isApps(d)) && d.sub.includes("symbolic") === symbolic);
  const fixed = apps
    .filter((d) => d.type !== "Scalable" && d.size * d.scale >= 48 && d.size * d.scale <= 256)
    .sort((a, b) => Math.abs(Math.log2((a.size * a.scale) / 128)) - Math.abs(Math.log2((b.size * b.scale) / 128)) || b.size * b.scale - a.size * a.scale);
  return [...fixed, ...apps.filter((d) => d.type === "Scalable")];
}

const exists = (p: string) => stat(p).then((s) => s.isFile(), () => false);

export interface IconPaths {
  /** Theme roots, e.g. ~/.local/share/icons, ~/.icons, /usr/share/icons */
  iconBases: string[];
  pixmapDirs: string[];
}

export function defaultIconPaths(): IconPaths {
  const data = xdgDataDirs();
  return { iconBases: [join(homedir(), ".icons"), ...data.map((d) => join(d, "icons"))], pixmapDirs: ["/usr/share/pixmaps"] };
}

/** The user's icon theme: gtk-3.0/gtk-4.0 settings.ini, then gsettings output. */
export function themesFrom(settingsIni: string[], gsettings: string | null): string[] {
  const out: string[] = [];
  for (const text of settingsIni) {
    const m = /^\s*gtk-icon-theme-name\s*=\s*"?([^"\n]+?)"?\s*$/m.exec(text);
    if (m) out.push(m[1]!);
  }
  const g = gsettings?.trim().replace(/^'(.*)'$/, "$1");
  if (g) out.push(g);
  return [...new Set(out)];
}

/** Resolves an icon name to a file (png or svg); null if not found. Themes and results are cached. */
export class IconResolver {
  #themes = new Map<string, Theme | null>();
  #cache = new Map<string, string | null>();

  readonly paths: IconPaths;
  readonly userThemes: () => Promise<string[]>;

  constructor(paths: IconPaths, userThemes: () => Promise<string[]>) {
    this.paths = paths;
    this.userThemes = userThemes;
  }

  async #theme(name: string): Promise<Theme | null> {
    if (this.#themes.has(name)) return this.#themes.get(name)!;
    let theme: Theme | null = null;
    for (const base of this.paths.iconBases) {
      const text = await readFile(join(base, name, "index.theme"), "utf8").catch(() => null);
      if (text) {
        theme = parseIndexTheme(text);
        break;
      }
    }
    this.#themes.set(name, theme);
    return theme;
  }

  /** Theme chain: the user's themes and Inherits (breadth-first), hicolor last. */
  async chain(): Promise<Array<[string, Theme]>> {
    const queue = await this.userThemes().catch(() => [] as string[]);
    const seen = new Set(["hicolor"]);
    const out: Array<[string, Theme]> = [];
    while (queue.length) {
      const n = queue.shift()!;
      if (seen.has(n)) continue;
      seen.add(n);
      const t = await this.#theme(n);
      if (!t) continue;
      out.push([n, t]);
      queue.push(...t.inherits);
    }
    const hicolor = await this.#theme("hicolor");
    if (hicolor) out.push(["hicolor", hicolor]);
    return out;
  }

  async resolve(icon: string): Promise<string | null> {
    if (this.#cache.has(icon)) return this.#cache.get(icon)!;
    const found = await this.#resolve(icon);
    this.#cache.set(icon, found);
    return found;
  }

  async #resolve(icon: string): Promise<string | null> {
    if (icon.startsWith("/")) return /\.(png|svg)$/i.test(icon) && (await exists(icon)) ? icon : null;
    if (!/^[A-Za-z0-9][A-Za-z0-9._+-]{0,199}$/.test(icon)) return null;
    const name = icon.replace(/\.(png|svg|xpm)$/i, "");
    const symbolic = name.endsWith("-symbolic");
    const chain = await this.chain();
    for (const anyContext of [false, true]) {
      for (const [themeName, theme] of chain) {
        for (const d of candidateDirs(theme, symbolic, anyContext)) {
          for (const base of this.paths.iconBases) {
            for (const ext of ["png", "svg"]) {
              const p = join(base, themeName, d.sub, `${name}.${ext}`);
              if (await exists(p)) return p;
            }
          }
        }
      }
    }
    for (const dir of this.paths.pixmapDirs) {
      for (const ext of ["png", "svg"]) {
        const p = join(dir, `${name}.${ext}`);
        if (await exists(p)) return p;
      }
    }
    return null;
  }
}
