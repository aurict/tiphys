// Config file discovery and safe file I/O (PLAN.md §13.3). Only the .env / env_file files of discovered stacks
// (stacks.ts) and `configFiles.extraPaths` are reachable, and only by fileId (a hash of the real path): routes never
// take a path. A file qualifies when its real path is inside its root (stack root; for an extra path, its own
// directory), it is a regular file owned by the agent user, ≤256 KB, and named .env, *.env or .env.*.
// Writes are atomic (temp file in the same directory → fsync → rename) and re-check the file right before the rename.
import { createHash, randomBytes } from "node:crypto";
import { constants, type Stats } from "node:fs";
import { lstat, mkdir, open, readdir, readFile, realpath, rename, rm, stat, chmod } from "node:fs/promises";
import { homedir } from "node:os";
import { basename, dirname, join, relative } from "node:path";
import { expandHome, type AgentConfig } from "../config.ts";
import { AppError } from "../errors.ts";
import { discoverStacks, inside, type Stack } from "../stacks.ts";

export const MAX_FILE_BYTES = 256 * 1024;
export const FILE_ID_RE = /^cf-[a-f0-9]{24}$/;
export const NAME_RE = /^(?:\.env|.+\.env|\.env\..+)$/;
export const BACKUP_ID_RE = /^\d{4}-\d{2}-\d{2}T\d{2}-\d{2}-\d{2}-\d{3}Z(?:-\d{1,3})?$/;
export const KEEP_BACKUPS = 10;

export type SkipReason = "notRegular" | "notOwner" | "tooLarge" | "badName" | "outsideRoot" | "missing";
// list() may also report the read-time reasons: moved | replaced | notText | unreadable.

export interface ConfigFile {
  fileId: string;
  /** Real path. */
  real: string;
  /** Directory the real path must stay inside. */
  root: string;
  /** Path shown to the user and written to the audit log: "<stack>/<path in stack>" or "~/…". */
  label: string;
  source: "stack" | "extra";
  stack?: Stack;
}

export interface Skipped {
  label: string;
  reason: SkipReason;
}

export const fileIdOf = (real: string) => "cf-" + createHash("sha256").update(real).digest("hex").slice(0, 24);
export const sha256 = (b: Buffer | string) => createHash("sha256").update(b).digest("hex");

function tilde(p: string): string {
  const home = homedir();
  return inside(home, p) && p !== home ? "~/" + relative(home, p) : p;
}

/** Why a real path doesn't qualify, or null. Uses lstat: the real path itself must not be a symlink. */
export async function checkFile(real: string, root: string, st?: Stats): Promise<SkipReason | null> {
  if (!inside(root, real)) return "outsideRoot";
  const s = st ?? (await lstat(real).catch(() => null));
  if (!s) return "missing";
  if (!s.isFile()) return "notRegular";
  if (s.uid !== process.getuid?.()) return "notOwner";
  if (s.size > MAX_FILE_BYTES) return "tooLarge";
  if (!NAME_RE.test(basename(real))) return "badName";
  return null;
}

/** Every reachable config file (stack files first; a file found twice is listed once) and the ones skipped. */
export async function discoverConfigFiles(config: Pick<AgentConfig, "stacks" | "configFiles">): Promise<{ files: ConfigFile[]; skipped: Array<Skipped & { fileId: string }> }> {
  const files: ConfigFile[] = [];
  const skipped: Array<Skipped & { fileId: string }> = [];
  const seen = new Set<string>();
  const add = async (c: Omit<ConfigFile, "fileId">) => {
    const fileId = fileIdOf(c.real);
    if (seen.has(fileId)) return;
    seen.add(fileId);
    const reason = await checkFile(c.real, c.root);
    if (reason) skipped.push({ label: c.label, reason, fileId });
    else files.push({ ...c, fileId });
  };
  for (const stack of await discoverStacks(config)) {
    for (const real of stack.envFiles) {
      const label = inside(stack.dir, real) ? `${stack.id}/${relative(stack.dir, real)}` : relative(stack.root, real);
      await add({ real, root: stack.root, label, source: "stack", stack });
    }
  }
  for (const p of config.configFiles.extraPaths) {
    const abs = expandHome(p);
    const label = tilde(abs);
    const root = await realpath(dirname(abs)).catch(() => null);
    const real = await realpath(abs).catch(() => null);
    if (!root || !real) {
      skipped.push({ label, reason: "missing", fileId: fileIdOf(abs) });
      continue;
    }
    // A symlink pointing out of its own directory is an escape.
    if (dirname(real) !== root) {
      skipped.push({ label, reason: "outsideRoot", fileId: fileIdOf(real) });
      continue;
    }
    await add({ real, root, label, source: "extra" });
  }
  return { files, skipped };
}

export interface FileRead {
  content: Buffer;
  text: string;
  hash: string;
  st: Stats;
}

const fileChanged = (reason: string) => new AppError("agent.configfiles.fileChanged", 409, { reason });

/** Reads the file without following a symlink and re-checks every rule on the open descriptor. */
export async function readChecked(f: ConfigFile): Promise<FileRead> {
  const real = await realpath(f.real).catch(() => null);
  if (real !== f.real) throw fileChanged("moved");
  const before = await lstat(f.real).catch(() => null);
  const reason = before ? await checkFile(f.real, f.root, before) : "missing";
  if (reason) throw fileChanged(reason);
  const fh = await open(f.real, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const st = await fh.stat();
    if (st.ino !== before!.ino || st.dev !== before!.dev) throw fileChanged("replaced");
    if (st.size > MAX_FILE_BYTES) throw fileChanged("tooLarge");
    const content = await fh.readFile();
    if (content.length > MAX_FILE_BYTES) throw fileChanged("tooLarge");
    let text: string;
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(content);
    } catch {
      throw new AppError("agent.configfiles.notText", 409);
    }
    return { content, text, hash: sha256(content), st };
  } finally {
    await fh.close();
  }
}

export interface WriteHooks {
  /** Test seam: runs after the temp file is complete, before the final checks and the rename. */
  beforeRename?: (tmp: string) => Promise<void>;
}

/**
 * Atomically replaces the file when its current content still hashes to baseHash (409 agent.configfiles.conflict
 * otherwise). Keeps mode and group; re-checks realpath, lstat (same inode, rules) and the content right before the
 * rename (TOCTOU). The original stays untouched on any failure. Returns the new hash and warnings.
 */
export async function writeAtomic(f: ConfigFile, baseHash: string, next: Buffer, hooks: WriteHooks = {}): Promise<{ hash: string; warnings: string[] }> {
  if (next.length > MAX_FILE_BYTES) throw new AppError("agent.configfiles.tooLarge", 400, { max: MAX_FILE_BYTES });
  const cur = await readChecked(f);
  if (cur.hash !== baseHash) throw new AppError("agent.configfiles.conflict", 409, { hash: cur.hash });
  const warnings: string[] = [];
  const mode = cur.st.mode & 0o777;
  if (mode & 0o004) warnings.push("worldReadable");
  const tmp = join(dirname(f.real), `.${basename(f.real)}.tiphys-${randomBytes(6).toString("hex")}.tmp`);
  let created = false;
  try {
    const fh = await open(tmp, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    created = true;
    try {
      await fh.writeFile(next);
      if (cur.st.gid !== (await fh.stat()).gid) {
        await fh.chown(cur.st.uid, cur.st.gid).catch(() => warnings.push("groupNotKept"));
      }
      await fh.chmod(mode);
      await fh.sync();
    } finally {
      await fh.close();
    }
    await hooks.beforeRename?.(tmp);
    // TOCTOU: the target must still be the same regular file with the same content.
    const again = await readChecked(f);
    if (again.st.ino !== cur.st.ino || again.st.dev !== cur.st.dev) throw fileChanged("replaced");
    if (again.hash !== baseHash) throw new AppError("agent.configfiles.conflict", 409, { hash: again.hash });
    await rename(tmp, f.real);
    created = false;
    const dir = await open(dirname(f.real), constants.O_RDONLY);
    await dir.sync().catch(() => {});
    await dir.close();
    return { hash: sha256(next), warnings };
  } finally {
    if (created) await rm(tmp, { force: true });
  }
}

// --- Backups: <stateDir>/config-backups/<fileId>/<time> (0700 directories, 0600 files, last 10 kept) ----------------

export const backupDir = (stateDir: string, fileId: string) => join(stateDir, "config-backups", fileId);

export async function writeBackup(stateDir: string, fileId: string, content: Buffer, now = Date.now()): Promise<string> {
  const dir = backupDir(stateDir, fileId);
  await mkdir(dir, { recursive: true, mode: 0o700 });
  await chmod(join(stateDir, "config-backups"), 0o700);
  await chmod(dir, 0o700);
  const base = new Date(now).toISOString().replace(/[:.]/g, "-");
  for (let n = 0; n < 1000; n++) {
    const id = n ? `${base}-${n}` : base;
    try {
      const fh = await open(join(dir, id), constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
      try {
        await fh.writeFile(content);
        await fh.sync();
      } finally {
        await fh.close();
      }
      const all = (await readdir(dir)).filter((x) => BACKUP_ID_RE.test(x)).sort(byBackupId);
      for (const old of all.slice(0, Math.max(0, all.length - KEEP_BACKUPS))) await rm(join(dir, old), { force: true });
      return id;
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "EEXIST") throw e;
    }
  }
  throw new AppError("agent.internal", 500);
}

function byBackupId(a: string, b: string): number {
  const [ta, na] = [a.slice(0, 24), Number(a.slice(25) || 0)];
  const [tb, nb] = [b.slice(0, 24), Number(b.slice(25) || 0)];
  return ta < tb ? -1 : ta > tb ? 1 : na - nb;
}

/** Backups, newest first. */
export async function listBackups(stateDir: string, fileId: string): Promise<Array<{ id: string; at: string; size: number }>> {
  const dir = backupDir(stateDir, fileId);
  const names = (await readdir(dir).catch(() => [] as string[])).filter((x) => BACKUP_ID_RE.test(x)).sort(byBackupId).reverse();
  const out: Array<{ id: string; at: string; size: number }> = [];
  for (const id of names) {
    const st = await stat(join(dir, id)).catch(() => null);
    if (!st?.isFile()) continue;
    const t = id.slice(0, 24);
    const at = `${t.slice(0, 13)}:${t.slice(14, 16)}:${t.slice(17, 19)}.${t.slice(20, 23)}Z`;
    out.push({ id, at, size: st.size });
  }
  return out;
}

export async function readBackup(stateDir: string, fileId: string, id: string): Promise<Buffer> {
  if (!BACKUP_ID_RE.test(id)) throw new AppError("agent.configfiles.backupNotFound", 404);
  const p = join(backupDir(stateDir, fileId), id);
  const st = await lstat(p).catch(() => null);
  if (!st?.isFile() || st.size > MAX_FILE_BYTES) throw new AppError("agent.configfiles.backupNotFound", 404);
  return readFile(p);
}
