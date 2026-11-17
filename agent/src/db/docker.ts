// Docker side of the database console (PLAN.md §13.2): discovery of database containers (`docker ps` + `docker
// inspect`; only env NAMES leave this module), and resolving a {container} target to its IP and, for
// fromContainerEnv, the POSTGRES_* / MYSQL_* / MARIADB_* credentials, both at connect time (never stored).
import { AppError } from "../errors.ts";
import { run as execRun } from "../exec.ts";

export type Runner = typeof execRun;

export type DiscoveredEngine = "postgres" | "mysql" | "mariadb" | "redis";

/** Image repository (last path segment) → engine. */
const IMAGE_ENGINES: Array<[RegExp, DiscoveredEngine]> = [
  [/^(postgres|postgresql|postgis|timescaledb|timescaledb-ha|pgvector|timescaledb-postgis)$/, "postgres"],
  [/^(mysql|mysql-server|percona|percona-server)$/, "mysql"],
  [/^mariadb$/, "mariadb"],
  [/^(redis|redis-stack|redis-stack-server|valkey)$/, "redis"],
];

/** "ghcr.io/x/postgis:16-3.4@sha256:…" → {repo: "postgis", tag: "16-3.4"}. */
export function parseImage(ref: string): { repo: string; tag: string | null } {
  const noDigest = ref.split("@")[0]!;
  const slash = noDigest.lastIndexOf("/");
  const colon = noDigest.lastIndexOf(":");
  const hasTag = colon > slash;
  const path = hasTag ? noDigest.slice(0, colon) : noDigest;
  return { repo: path.slice(path.lastIndexOf("/") + 1).toLowerCase(), tag: hasTag ? noDigest.slice(colon + 1) : null };
}

export function engineOfImage(ref: string): DiscoveredEngine | null {
  const { repo } = parseImage(ref);
  for (const [re, engine] of IMAGE_ENGINES) if (re.test(repo)) return engine;
  return null;
}

interface Inspect {
  Id?: string;
  Name?: string;
  Config?: { Image?: string; Env?: string[] | null; Labels?: Record<string, string> | null };
  State?: { Status?: string };
  HostConfig?: { NetworkMode?: string };
  NetworkSettings?: {
    Networks?: Record<string, { IPAddress?: string } | null> | null;
    Ports?: Record<string, Array<{ HostIp?: string; HostPort?: string }> | null> | null;
  };
}

export interface DiscoveredDb {
  container: string;
  id: string;
  engine: DiscoveredEngine;
  /** postgres, mysql and mariadb can be connected (Redis is out of scope). */
  supported: boolean;
  image: string;
  version: string | null;
  state: string;
  project: string | null;
  networks: Array<{ name: string; ip: string | null }>;
  ports: Array<{ port: string; hostIp?: string; hostPort?: string }>;
  envNames: string[];
  /** The env holds a usable credential ({fromContainerEnv: true} can work): POSTGRES_PASSWORD; MYSQL_/MARIADB_ROOT_PASSWORD, USER+PASSWORD or an allowed empty root password. */
  containerEnvCredential: boolean;
}

const envNames = (env: string[] | null | undefined) =>
  [...new Set((env ?? []).map((e) => e.slice(0, Math.max(0, e.indexOf("=")) || e.length)).filter((k) => /^[A-Za-z_][A-Za-z0-9_.-]{0,127}$/.test(k)))].sort();

export function discoveredFromInspect(list: Inspect[]): DiscoveredDb[] {
  const out: DiscoveredDb[] = [];
  for (const c of list) {
    const image = c.Config?.Image ?? "";
    const engine = engineOfImage(image);
    if (!engine) continue;
    const names = envNames(c.Config?.Env);
    out.push({
      container: (c.Name ?? "").replace(/^\//, ""),
      id: (c.Id ?? "").slice(0, 12),
      engine,
      supported: engine !== "redis",
      image,
      version: parseImage(image).tag,
      state: c.State?.Status ?? "unknown",
      project: c.Config?.Labels?.["com.docker.compose.project"] ?? null,
      networks: Object.entries(c.NetworkSettings?.Networks ?? {}).map(([name, n]) => ({ name, ip: n?.IPAddress || null })),
      ports: Object.entries(c.NetworkSettings?.Ports ?? {}).flatMap(([port, binds]) =>
        binds?.length ? binds.map((b) => ({ port, hostIp: b.HostIp, hostPort: b.HostPort })) : [{ port }],
      ),
      envNames: names,
      containerEnvCredential: engine === "postgres" ? names.includes("POSTGRES_PASSWORD") : engine === "redis" ? false : mysqlEnvUsable(names),
    });
  }
  return out.sort((a, b) => a.container.localeCompare(b.container));
}

const either = (names: string[], k: string) => names.includes(`MARIADB_${k}`) || names.includes(`MYSQL_${k}`);
/** Names only (discovery): root password, user + password, or an allowed empty root password. */
const mysqlEnvUsable = (names: string[]) =>
  either(names, "ROOT_PASSWORD") || (either(names, "USER") && either(names, "PASSWORD")) || either(names, "ALLOW_EMPTY_ROOT_PASSWORD") || names.includes("MYSQL_ALLOW_EMPTY_PASSWORD");

async function inspect(run: Runner, ids: string[]): Promise<Inspect[]> {
  if (!ids.length) return [];
  const r = await run("docker", ["inspect", "--type", "container", ...ids], { timeoutMs: 20_000 });
  return JSON.parse(r.stdout) as Inspect[];
}

export async function discover(run: Runner = execRun): Promise<DiscoveredDb[]> {
  const ps = await run("docker", ["ps", "-q", "--no-trunc"], { timeoutMs: 20_000 });
  const ids = ps.stdout.split("\n").map((l) => l.trim()).filter((l) => /^[a-f0-9]{12,64}$/.test(l));
  return discoveredFromInspect(await inspect(run, ids));
}

export interface ResolvedContainer {
  host: string;
  /** Present only when asked (fromContainerEnv): read from the container env, never stored or returned. */
  env?: { user: string; password?: string; database?: string };
}

/** The container's IP on `network` (or its first network with an IP; 127.0.0.1 for host networking). */
export async function resolveContainer(run: Runner, container: string, network: string | undefined, withEnv: boolean, family: "postgres" | "mysql" = "postgres"): Promise<ResolvedContainer> {
  let info: Inspect | undefined;
  try {
    info = (await inspect(run, [container]))[0];
  } catch (e) {
    if (e instanceof AppError && e.code === "agent.exec.failed") throw new AppError("agent.db.containerNotFound", 404, { container });
    throw e;
  }
  if (!info) throw new AppError("agent.db.containerNotFound", 404, { container });
  if (info.State?.Status !== "running") throw new AppError("agent.db.containerNotRunning", 409, { container, state: info.State?.Status ?? "unknown" });
  const nets = info.NetworkSettings?.Networks ?? {};
  let host: string | undefined;
  if (network) {
    host = nets[network]?.IPAddress || undefined;
    if (!host) throw new AppError("agent.db.networkNotFound", 404, { container, network });
  } else if (info.HostConfig?.NetworkMode === "host") {
    host = "127.0.0.1";
  } else {
    host = Object.values(nets).map((n) => n?.IPAddress).find((ip) => !!ip);
  }
  if (!host) throw new AppError("agent.db.containerNoAddress", 409, { container });
  if (!withEnv) return { host };
  const env = new Map<string, string>();
  for (const e of info.Config?.Env ?? []) {
    const i = e.indexOf("=");
    if (i > 0) env.set(e.slice(0, i), e.slice(i + 1));
  }
  if (family === "mysql") return { host, env: mysqlEnv(env) };
  const user = env.get("POSTGRES_USER") || "postgres";
  const password = env.get("POSTGRES_PASSWORD");
  if (password === undefined && env.has("POSTGRES_PASSWORD_FILE")) throw new AppError("agent.db.credentialUnavailable", 409, { reason: "passwordFile" });
  if (password === undefined && env.get("POSTGRES_HOST_AUTH_METHOD") !== "trust") throw new AppError("agent.db.credentialUnavailable", 409, { reason: "noPassword" });
  return { host, env: { user, ...(password !== undefined ? { password } : {}), database: env.get("POSTGRES_DB") || user } };
}

/**
 * The official mysql/mariadb images: MARIADB_* wins over MYSQL_*. Root with its password (or an allowed empty one)
 * first, else MYSQL_USER/MYSQL_PASSWORD. *_FILE secrets and random root passwords can't be read.
 */
function mysqlEnv(env: Map<string, string>): NonNullable<ResolvedContainer["env"]> {
  const g = (k: string) => env.get(`MARIADB_${k}`) ?? env.get(`MYSQL_${k}`);
  const yes = (v: string | undefined) => !!v && !["", "0", "no", "false"].includes(v.toLowerCase());
  const database = g("DATABASE") || undefined;
  const root = g("ROOT_PASSWORD");
  if (root) return { user: "root", password: root, ...(database ? { database } : {}) };
  if (yes(g("ALLOW_EMPTY_ROOT_PASSWORD")) || yes(env.get("MYSQL_ALLOW_EMPTY_PASSWORD"))) return { user: "root", ...(database ? { database } : {}) };
  const user = g("USER");
  const password = g("PASSWORD");
  if (user && password !== undefined) return { user, password, ...(database ? { database } : {}) };
  if (g("ROOT_PASSWORD_FILE") !== undefined || g("PASSWORD_FILE") !== undefined) throw new AppError("agent.db.credentialUnavailable", 409, { reason: "passwordFile" });
  throw new AppError("agent.db.credentialUnavailable", 409, { reason: "noPassword" });
}
