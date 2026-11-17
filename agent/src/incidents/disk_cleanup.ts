// disk.cleanup (PLAN.md §13.1, I-2): what each cleanup option would run and roughly how much space it frees.
// Options: the user journal (vacuum of archived files older than 7 days; only when the agent user may delete them —
// the usual persistent journal directory belongs to root, so it is reported unavailable), the system journal (always
// unavailable: needs root), build cache, dangling images and stopped containers (older than 24 h, so the crashed
// container of a fresh incident stays). `docker image prune` without -a removes only dangling (untagged) images, so the
// tagged `tiphys-rollback/*:prev` images are never removed; there is deliberately no option with `-a`.
import { constants } from "node:fs";
import { access, readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";
import { run as execRun } from "../exec.ts";

type Runner = typeof execRun;

export const CLEANUP_OPTIONS = ["userJournal", "systemJournal", "builder", "images", "containers"] as const;
export type CleanupOption = (typeof CLEANUP_OPTIONS)[number];

export const JOURNAL_VACUUM_DAYS = 7;
const DAY_MS = 24 * 3600_000;

export const CLEANUP_ARGV: Record<Exclude<CleanupOption, "systemJournal">, string[]> = {
  userJournal: ["journalctl", "--user", `--vacuum-time=${JOURNAL_VACUUM_DAYS}d`],
  builder: ["docker", "builder", "prune", "-f"],
  images: ["docker", "image", "prune", "-f"],
  containers: ["docker", "container", "prune", "-f", "--filter", "until=24h"],
};

export interface CleanupEstimate {
  option: CleanupOption;
  available: boolean;
  /** Why not available: needsRoot (system journal, or a journal directory the agent can't write), noUserJournal, noDocker. */
  reason?: "needsRoot" | "noUserJournal" | "noDocker";
  /** Estimated bytes freed (docker's own "reclaimable" figure or a sum of files); null when unknown. */
  reclaimableBytes: number | null;
  /** Current total of that kind (journal disk usage, image/container/build-cache size), when known. */
  usageBytes: number | null;
}

const UNITS: Record<string, number> = {
  b: 1,
  kb: 1e3, mb: 1e6, gb: 1e9, tb: 1e12, pb: 1e15,
  kib: 1024, mib: 1024 ** 2, gib: 1024 ** 3, tib: 1024 ** 4, pib: 1024 ** 5,
};

/** Docker's human sizes ("635.1MB", "40.96kB", "0B", "1.2GiB", "635.1MB (23%)"); null when unparsable. */
export function parseDockerSize(s: string | undefined): number | null {
  const m = /^\s*([\d.]+)\s*([kKmMgGtTpP]i?)?[bB]\b/.exec(s ?? "");
  if (!m) return null;
  const unit = ((m[2] ?? "") + "b").toLowerCase();
  const mul = UNITS[unit];
  const n = Number(m[1]);
  return mul && Number.isFinite(n) ? Math.round(n * mul) : null;
}

/** journalctl's sizes are binary: "449.2M", "8.0K", "1.5G", "512B". */
export function parseJournalSize(s: string): number | null {
  const m = /([\d.]+)\s*([BKMGTP])\b/.exec(s);
  if (!m) return null;
  const pow = "BKMGTP".indexOf(m[2]!);
  const n = Number(m[1]);
  return Number.isFinite(n) ? Math.round(n * 1024 ** pow) : null;
}

export interface DfRow {
  size: number | null;
  reclaimable: number | null;
}

/** `docker system df`: JSON lines (`--format '{{json .}}'`) or the default table. Keys: images, containers, volumes, buildCache. */
export function parseSystemDf(out: string): Partial<Record<"images" | "containers" | "volumes" | "buildCache", DfRow>> {
  const res: Partial<Record<"images" | "containers" | "volumes" | "buildCache", DfRow>> = {};
  const map = { images: "images", containers: "containers", "local volumes": "volumes", "build cache": "buildCache" } as const;
  for (const line of out.split("\n")) {
    const l = line.trim();
    if (!l) continue;
    if (l.startsWith("{")) {
      try {
        const j = JSON.parse(l) as { Type?: string; Size?: string; Reclaimable?: string };
        const k = map[(j.Type ?? "").toLowerCase() as keyof typeof map];
        if (k) res[k] = { size: parseDockerSize(j.Size), reclaimable: parseDockerSize(j.Reclaimable) };
      } catch {
        // not JSON after all
      }
      continue;
    }
    // TYPE  TOTAL  ACTIVE  SIZE  RECLAIMABLE — the type can contain one space.
    const m = /^(Images|Containers|Local Volumes|Build Cache)\s+\d+\s+\d+\s+(\S+)\s+(\S+)/i.exec(l);
    if (m) res[map[m[1]!.toLowerCase() as keyof typeof map]] = { size: parseDockerSize(m[2]), reclaimable: parseDockerSize(m[3]) };
  }
  return res;
}

export interface JournalProbe {
  /** Directories that hold this user's journal files (user-<uid>.journal, user-<uid>@….journal). */
  dirs: string[];
  writable: boolean;
  /** Archived user files older than the vacuum age. */
  vacuumBytes: number;
}

/** Looks for this user's journal files in <base>/<machine-id>/ (persistent and volatile journal). */
export async function probeUserJournal(o: { bases?: string[]; machineId?: string; uid?: number; now?: number } = {}): Promise<JournalProbe> {
  const uid = o.uid ?? process.getuid?.() ?? 0;
  const mid = o.machineId ?? (await readFile("/etc/machine-id", "utf8").catch(() => "")).trim();
  const now = o.now ?? Date.now();
  const res: JournalProbe = { dirs: [], writable: true, vacuumBytes: 0 };
  if (!/^[a-f0-9]{32}$/.test(mid)) return { ...res, writable: false };
  for (const base of o.bases ?? ["/var/log/journal", "/run/log/journal"]) {
    const dir = join(base, mid);
    const names = (await readdir(dir).catch(() => [] as string[])).filter((n) => n.startsWith(`user-${uid}.`) || n.startsWith(`user-${uid}@`));
    if (!names.length) continue;
    res.dirs.push(dir);
    if (!(await access(dir, constants.W_OK).then(() => true, () => false))) res.writable = false;
    for (const n of names) {
      if (!n.includes("@") || !/\.journal~?$/.test(n)) continue;
      const st = await stat(join(dir, n)).catch(() => null);
      if (st?.isFile() && now - st.mtimeMs > JOURNAL_VACUUM_DAYS * DAY_MS) res.vacuumBytes += st.size;
    }
  }
  return res;
}

/** Estimates for every option (each source may fail on its own; a failure makes that option unknown/unavailable). */
export async function estimateCleanup(run: Runner = execRun, journal: () => Promise<JournalProbe> = () => probeUserJournal()): Promise<CleanupEstimate[]> {
  const [df, dangling, usage, probe] = await Promise.all([
    run("docker", ["system", "df", "--format", "{{json .}}"], { allowFail: true, timeoutMs: 30_000 }).catch(() => null),
    run("docker", ["image", "ls", "--filter", "dangling=true", "--format", "{{json .}}"], { allowFail: true, timeoutMs: 15_000 }).catch(() => null),
    run("journalctl", ["--user", "--disk-usage"], { allowFail: true, timeoutMs: 15_000 }).catch(() => null),
    journal().catch(() => null),
  ]);
  const docker = !!df && df.code === 0;
  const rows = docker ? parseSystemDf(df.stdout) : {};
  // Dangling images: docker's image "reclaimable" counts every unused image, so the dangling ones are summed instead
  // (their size includes shared layers: an upper bound). Images still used by a container aren't pruned.
  let danglingBytes: number | null = null;
  if (dangling?.code === 0) {
    danglingBytes = 0;
    for (const l of dangling.stdout.split("\n")) {
      try {
        const j = JSON.parse(l) as { Size?: string; Containers?: string };
        if (j.Containers && j.Containers !== "0" && j.Containers !== "N/A") continue;
        danglingBytes += parseDockerSize(j.Size) ?? 0;
      } catch {
        // blank line
      }
    }
  }
  const journalUsage = usage?.code === 0 ? parseJournalSize(usage.stdout) : null;
  const userJournal: CleanupEstimate = !probe?.dirs.length
    ? { option: "userJournal", available: false, reason: "noUserJournal", reclaimableBytes: null, usageBytes: journalUsage }
    : !probe.writable
      ? { option: "userJournal", available: false, reason: "needsRoot", reclaimableBytes: probe.vacuumBytes, usageBytes: journalUsage }
      : { option: "userJournal", available: true, reclaimableBytes: probe.vacuumBytes, usageBytes: journalUsage };
  const dockerOpt = (option: "builder" | "images" | "containers", row: DfRow | undefined, reclaim: number | null): CleanupEstimate =>
    docker ? { option, available: true, reclaimableBytes: reclaim, usageBytes: row?.size ?? null } : { option, available: false, reason: "noDocker", reclaimableBytes: null, usageBytes: null };
  return [
    userJournal,
    { option: "systemJournal", available: false, reason: "needsRoot", reclaimableBytes: null, usageBytes: null },
    dockerOpt("builder", rows.buildCache, rows.buildCache?.reclaimable ?? null),
    dockerOpt("images", rows.images, danglingBytes),
    dockerOpt("containers", rows.containers, rows.containers?.reclaimable ?? null),
  ];
}
