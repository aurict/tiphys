// Self-update (K8) for installs made by install.sh:
//   <root>/versions/<version>/{dist,node_modules,helpers,node,bin}   <root>/current -> versions/<version>
// Only signed releases: SHA256SUMS must carry a valid ed25519 signature (public key in update_key.ts) and the bundle
// must match its SHA-256 line. The download location is fixed (GitHub releases, or TIPHYS_RELEASE_URL from the
// agent's own environment), never taken from the request. After the switch the agent exits and the service manager
// starts the new version; the guard in <root>/guard.sh (written by install.sh) rolls back if it keeps failing.
import { createHash, createPublicKey, verify } from "node:crypto";
import { createWriteStream, existsSync, readFileSync, realpathSync, lstatSync } from "node:fs";
import { mkdir, mkdtemp, readFile, readdir, rename, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
import { fileURLToPath } from "node:url";
import { AppError } from "./errors.ts";
import { run } from "./exec.ts";
import { isPlaceholderKey, UPDATE_PUBLIC_KEY } from "./update_key.ts";
import { VERSION } from "./version.ts";

export const DEFAULT_RELEASES = "https://github.com/aurict/tiphys/releases";
export const MARKER = "update-pending";
const VERSION_RE = /^\d+\.\d+\.\d+$/;
const MAX_BUNDLE = 1024 * 1024 * 1024;

export interface UpdateOptions {
  /** Base of the releases: files at <base>/download/v<version>/<file>, latest version at <base>/latest/download/VERSION. */
  releases?: string;
  publicKey?: string;
  current?: string;
  /** Install root (directory holding versions/ and current); null = not managed. Default: derived from this file. */
  root?: string | null;
  platform?: NodeJS.Platform;
  arch?: string;
  fetchImpl?: typeof fetch;
}

export function releasesBase(o: UpdateOptions = {}): string {
  return (o.releases ?? process.env.TIPHYS_RELEASE_URL ?? DEFAULT_RELEASES).replace(/\/+$/, "");
}

/** "linux-x64", "darwin-arm64", "win-x64"… (bundle naming of tools/release.sh); null when there is no bundle. */
export function platformId(platform: NodeJS.Platform = process.platform, arch: string = process.arch): string | null {
  const os = platform === "win32" ? "win" : platform === "linux" || platform === "darwin" ? platform : null;
  if (!os || (arch !== "x64" && arch !== "arm64") || (os === "win" && arch !== "x64")) return null;
  return `${os}-${arch}`;
}

export function bundleName(version: string, pid: string): string {
  return `tiphys-agent-${version}-${pid}.${pid.startsWith("win") ? "zip" : "tar.gz"}`;
}

/**
 * The install root when this agent runs from an install.sh layout: the bundle directory (parent of dist/) is
 * <root>/versions/<v> and <root>/current points at it. A git checkout or a package install is not managed.
 */
export function managedRoot(bundleDir = fileURLToPath(new URL("..", import.meta.url))): string | null {
  try {
    const real = realpathSync(bundleDir);
    const versions = dirname(real);
    if (basename(versions) !== "versions") return null;
    const root = dirname(versions);
    const current = join(root, "current");
    if (!lstatSync(current).isSymbolicLink() && process.platform !== "win32") return null;
    return realpathSync(current) === real ? root : null;
  } catch {
    return null;
  }
}

export function compareVersions(a: string, b: string): number {
  const pa = a.split(".").map(Number);
  const pb = b.split(".").map(Number);
  for (let i = 0; i < 3; i++) if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) - (pb[i] ?? 0);
  return 0;
}

export function parseSums(text: string): Map<string, string> {
  const m = new Map<string, string>();
  for (const line of text.split("\n")) {
    const r = /^([a-f0-9]{64}) [ *]?(\S+)$/.exec(line.trim());
    if (r) m.set(r[2]!, r[1]!);
  }
  return m;
}

/** ed25519 signature over the exact bytes of SHA256SUMS. Refuses to run with the placeholder key. */
export function verifySums(sums: Buffer, sig: Buffer, publicKey: string): boolean {
  if (isPlaceholderKey(publicKey)) throw new AppError("agent.update.noKey", 503);
  try {
    return verify(null, sums, createPublicKey(publicKey), sig);
  } catch {
    return false;
  }
}

export interface UpdateInfo {
  current: string;
  latest: string | null;
  available: boolean;
  managed: boolean;
  notesUrl: string | null;
  /** Set when the release server could not be reached. */
  error?: string;
}

let cache: { at: number; ttl: number; key: string; info: Omit<UpdateInfo, "managed" | "current"> } | null = null;

export function clearUpdateCache() {
  cache = null;
}

/** Latest release (VERSION asset of the "latest" release), cached for an hour (5 minutes after a failure). */
export async function checkUpdate(o: UpdateOptions = {}): Promise<UpdateInfo> {
  const base = releasesBase(o);
  const current = o.current ?? VERSION;
  const managed = (o.root === undefined ? managedRoot() : o.root) !== null;
  if (!cache || cache.key !== base || Date.now() - cache.at > cache.ttl) {
    try {
      const res = await (o.fetchImpl ?? fetch)(`${base}/latest/download/VERSION`, { signal: AbortSignal.timeout(5000), redirect: "follow" });
      if (!res.ok) throw new Error(String(res.status));
      const latest = (await res.text()).trim();
      if (!VERSION_RE.test(latest)) throw new Error("bad version");
      cache = { at: Date.now(), ttl: 3600_000, key: base, info: { latest, available: false, notesUrl: `${base}/tag/v${latest}` } };
    } catch {
      cache = { at: Date.now(), ttl: 300_000, key: base, info: { latest: null, available: false, notesUrl: null, error: "agent.update.unreachable" } };
    }
  }
  const info = cache.info;
  return { current, managed, ...info, available: info.latest !== null && compareVersions(info.latest, current) > 0 };
}

async function download(f: typeof fetch, url: string, timeoutMs: number): Promise<Response> {
  let res: Response;
  try {
    res = await f(url, { signal: AbortSignal.timeout(timeoutMs), redirect: "follow" });
  } catch {
    throw new AppError("agent.update.unreachable", 502);
  }
  if (res.status === 404) throw new AppError("agent.update.missingAsset", 502, { file: basename(new URL(url).pathname) });
  if (!res.ok || !res.body) throw new AppError("agent.update.unreachable", 502, { status: res.status });
  return res;
}

let applying = false;

/**
 * Downloads, verifies and unpacks <version>, then points `current` at it and leaves a marker for the guard.
 * Returns the new version directory; the caller restarts the agent.
 */
export async function applyUpdate(version: string, o: UpdateOptions = {}): Promise<{ version: string; dir: string }> {
  const root = o.root === undefined ? managedRoot() : o.root;
  if (root === null) throw new AppError("agent.update.notManaged", 409);
  if (!VERSION_RE.test(version)) throw new AppError("agent.update.badVersion", 400, { version });
  const current = o.current ?? VERSION;
  if (compareVersions(version, current) <= 0) throw new AppError("agent.update.notNewer", 409, { current, version });
  const pid = platformId(o.platform, o.arch);
  if (!pid) throw new AppError("agent.update.unsupportedPlatform", 409, { platform: o.platform ?? process.platform, arch: o.arch ?? process.arch });
  const key = o.publicKey ?? UPDATE_PUBLIC_KEY;
  if (isPlaceholderKey(key)) throw new AppError("agent.update.noKey", 503);
  if (applying) throw new AppError("agent.update.busy", 409);
  applying = true;
  const f = o.fetchImpl ?? fetch;
  const dl = `${releasesBase(o)}/download/v${version}`;
  const work = await mkdtemp(join(root, ".update-"));
  try {
    const sums = Buffer.from(await (await download(f, `${dl}/SHA256SUMS`, 30_000)).arrayBuffer());
    const sig = Buffer.from(await (await download(f, `${dl}/SHA256SUMS.sig`, 30_000)).arrayBuffer());
    if (!verifySums(sums, sig, key)) throw new AppError("agent.update.badSignature", 502);
    const name = bundleName(version, pid);
    const want = parseSums(sums.toString("utf8")).get(name);
    if (!want) throw new AppError("agent.update.missingAsset", 502, { file: name });

    const file = join(work, name);
    const res = await download(f, `${dl}/${name}`, 15 * 60_000);
    const hash = createHash("sha256");
    let size = 0;
    const body = Readable.fromWeb(res.body as import("node:stream/web").ReadableStream);
    body.on("data", (c: Buffer) => {
      size += c.length;
      if (size > MAX_BUNDLE) body.destroy(new AppError("agent.update.badBundle", 502, { reason: "tooLarge" }));
      hash.update(c);
    });
    await pipeline(body, createWriteStream(file, { mode: 0o600 }));
    if (hash.digest("hex") !== want) throw new AppError("agent.update.badChecksum", 502, { file: name });

    // Unpack (system tar; Windows 10+ tar.exe also reads zip) and check the bundle is what was asked for.
    const out = join(work, "x");
    await mkdir(out);
    await run("tar", ["-xf", file, "-C", out], { timeoutMs: 5 * 60_000 });
    const entries = await readdir(out);
    const top = entries.length === 1 ? join(out, entries[0]!) : out;
    const pkg = JSON.parse(await readFile(join(top, "package.json"), "utf8").catch(() => "{}")) as { version?: string };
    if (pkg.version !== version || !existsSync(join(top, "dist", "cli.js"))) throw new AppError("agent.update.badBundle", 502, { reason: "content" });

    const versions = join(root, "versions");
    const dir = join(versions, version);
    await rm(dir, { recursive: true, force: true });
    await rename(top, dir);
    await switchCurrent(root, dir);
    await writeFile(join(root, MARKER), `from=${current}\nto=${version}\nattempts=0\n`, { mode: 0o600 });
    return { version, dir };
  } finally {
    applying = false;
    await rm(work, { recursive: true, force: true }).catch(() => {});
  }
}

/** Points <root>/current at dir: a new symlink renamed over the old one (atomic on POSIX; a junction on Windows). */
export async function switchCurrent(root: string, dir: string) {
  const current = join(root, "current");
  if (process.platform === "win32") {
    await unlink(current).catch(() => {});
    await symlink(dir, current, "junction");
    return;
  }
  const tmp = join(root, `.current-${process.pid}`);
  await unlink(tmp).catch(() => {});
  await symlink(join("versions", basename(dir)), tmp);
  await rename(tmp, current);
}

/**
 * Called once the agent has been listening for a while: if it is the version an update switched to, the update is
 * confirmed (marker removed, so the guard won't roll back) and older versions beyond the previous one are pruned.
 */
export async function settleUpdate(root: string, version = VERSION): Promise<"confirmed" | "none"> {
  const marker = join(root, MARKER);
  let text: string;
  try {
    text = readFileSync(marker, "utf8");
  } catch {
    return "none";
  }
  const kv = Object.fromEntries(text.split("\n").filter(Boolean).map((l) => l.split("=", 2) as [string, string]));
  if (kv.to !== version) return "none";
  await unlink(marker).catch(() => {});
  // Keep the running version and the one it replaced (for a manual rollback); remove the rest.
  const keep = new Set([version, kv.from]);
  for (const v of await readdir(join(root, "versions")).catch(() => [] as string[])) {
    if (!keep.has(v) && VERSION_RE.test(v)) await rm(join(root, "versions", v), { recursive: true, force: true }).catch(() => {});
  }
  return "confirmed";
}
