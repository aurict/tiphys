// Compose stack discovery (PLAN.md §13.0). Every directory directly under a `stacks.roots` entry that holds a compose
// file is a stack. All paths are resolved with realpath and must stay inside their root (a symlink pointing out of the
// root is skipped); this list is separate from allowedRoots. Used by the incident room and later by config files (13.3).
import { lstat, readdir, readFile, realpath, stat } from "node:fs/promises";
import { basename, dirname, isAbsolute, join, resolve, sep } from "node:path";
import { parse } from "yaml";
import { expandHome, type AgentConfig } from "./config.ts";

export interface Stack {
  /** Directory name (unique per agent; the first root wins on a clash). */
  id: string;
  /** Compose project name: top-level `name:` or the directory name normalized the way compose does. */
  project: string;
  /** Real path of the stack directory. */
  dir: string;
  /** Real path of the root it was found in. */
  root: string;
  /** The compose file compose picks by default, then its override file if present. */
  composeFiles: string[];
  /** `.env` in the stack directory and every `env_file` of the services; existing files inside the root only. */
  envFiles: string[];
  services: string[];
  /** Top level of the git repository holding the stack, if that repository is inside the root. */
  gitRepo?: string;
}

/** Default file names in compose's own order of preference. */
const COMPOSE_NAMES = ["compose.yaml", "compose.yml", "docker-compose.yaml", "docker-compose.yml"];
const OVERRIDE_NAMES: Record<string, string[]> = {
  "compose.yaml": ["compose.override.yaml", "compose.override.yml"],
  "compose.yml": ["compose.override.yaml", "compose.override.yml"],
  "docker-compose.yaml": ["docker-compose.override.yaml", "docker-compose.override.yml"],
  "docker-compose.yml": ["docker-compose.override.yaml", "docker-compose.override.yml"],
};
export const STACK_ID = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/;
export const SERVICE_NAME = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/;
const MAX_COMPOSE_BYTES = 1024 * 1024;

export const inside = (root: string, p: string) => p === root || p.startsWith(root.endsWith(sep) ? root : root + sep);

/** realpath of p if it exists and stays inside root; otherwise null. */
async function confined(root: string, p: string): Promise<string | null> {
  const real = await realpath(p).catch(() => null);
  return real && inside(root, real) ? real : null;
}

async function isFile(p: string) {
  return stat(p).then((s) => s.isFile(), () => false);
}

/** Compose's default project name: lowercase, only [a-z0-9_-], must start with a letter or digit. */
export function composeProjectName(dirName: string): string {
  return dirName.toLowerCase().replace(/[^a-z0-9_-]/g, "").replace(/^[^a-z0-9]+/, "");
}

/** `env_file` in its three forms: "a.env", ["a.env", …], [{path, required}]. */
function envFileEntries(v: unknown): string[] {
  const list = Array.isArray(v) ? v : v === undefined || v === null ? [] : [v];
  return list.flatMap((e) => (typeof e === "string" ? [e] : e && typeof e === "object" && typeof (e as { path?: unknown }).path === "string" ? [(e as { path: string }).path] : []));
}

async function gitTop(root: string, dir: string): Promise<string | undefined> {
  for (let d = dir; inside(root, d); d = dirname(d)) {
    if (await lstat(join(d, ".git")).then(() => true, () => false)) return d;
    if (d === root) break;
  }
  return undefined;
}

/** Reads one stack directory; null when it has no compose file inside the root or it can't be parsed. */
export async function readStack(root: string, dir: string): Promise<Stack | null> {
  let main: string | null = null;
  let mainName = "";
  for (const n of COMPOSE_NAMES) {
    const p = await confined(root, join(dir, n));
    if (p && (await isFile(p))) {
      main = p;
      mainName = n;
      break;
    }
  }
  if (!main) return null;
  const composeFiles = [main];
  for (const n of OVERRIDE_NAMES[mainName] ?? []) {
    const p = await confined(root, join(dir, n));
    if (p && (await isFile(p))) {
      composeFiles.push(p);
      break;
    }
  }
  const services = new Set<string>();
  const envCandidates = [join(dir, ".env")];
  let projectName: string | null = null;
  for (const f of composeFiles) {
    const st = await stat(f);
    if (st.size > MAX_COMPOSE_BYTES) return null;
    let doc: unknown;
    try {
      doc = parse(await readFile(f, "utf8"));
    } catch {
      return null;
    }
    if (!doc || typeof doc !== "object") continue;
    const d = doc as { name?: unknown; services?: unknown };
    if (typeof d.name === "string" && /^[a-z0-9][a-z0-9_-]*$/.test(d.name)) projectName = d.name;
    if (d.services && typeof d.services === "object") {
      for (const [svc, def] of Object.entries(d.services as Record<string, unknown>)) {
        if (!SERVICE_NAME.test(svc)) continue;
        services.add(svc);
        const envFile = def && typeof def === "object" ? (def as { env_file?: unknown }).env_file : undefined;
        for (const e of envFileEntries(envFile)) envCandidates.push(isAbsolute(e) ? e : resolve(dir, e));
      }
    }
  }
  const envFiles: string[] = [];
  for (const c of envCandidates) {
    const p = await confined(root, c);
    if (p && (await isFile(p)) && !envFiles.includes(p)) envFiles.push(p);
  }
  const gitRepo = await gitTop(root, dir);
  const id = basename(dir);
  return {
    id,
    project: projectName ?? composeProjectName(id),
    dir,
    root,
    composeFiles,
    envFiles,
    services: [...services].sort(),
    ...(gitRepo ? { gitRepo } : {}),
  };
}

/** Discovers stacks under every configured root (missing roots are skipped). */
export async function discoverStacks(config: Pick<AgentConfig, "stacks">): Promise<Stack[]> {
  const out: Stack[] = [];
  const seen = new Set<string>();
  for (const r of config.stacks.roots) {
    const root = await realpath(expandHome(r)).catch(() => null);
    if (!root) continue;
    const entries = await readdir(root, { withFileTypes: true }).catch(() => []);
    for (const e of entries.sort((a, b) => a.name.localeCompare(b.name))) {
      if (!STACK_ID.test(e.name) || seen.has(e.name)) continue;
      if (!e.isDirectory() && !e.isSymbolicLink()) continue;
      const dir = await confined(root, join(root, e.name));
      if (!dir || dir === root || !(await stat(dir).then((s) => s.isDirectory(), () => false))) continue;
      const stack = await readStack(root, dir).catch(() => null);
      if (!stack) continue;
      seen.add(e.name);
      out.push(stack);
    }
  }
  return out;
}

/**
 * Finds the stack of a compose project (from container labels). The label's working directory is only a hint:
 * the result is always a discovered (confined) stack.
 */
export function stackForProject(stacks: Stack[], project: string | undefined, workingDir?: string): Stack | undefined {
  if (!project) return undefined;
  const byProject = stacks.filter((s) => s.project === project);
  if (byProject.length <= 1) return byProject[0];
  return byProject.find((s) => s.dir === workingDir) ?? byProject[0];
}
