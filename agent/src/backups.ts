// Backup status ("backups" feature): every check in the settings is evaluated every 15 min.
//   file: newest file matching the glob; none → missing, smaller than minBytes → failed, older than maxAgeHours → stale.
//   unit: last run of the systemd unit (user unit first, otherwise system unit); failed result → failed,
//         never ran → missing, last finish older than maxAgeHours → stale.
// On status change: backup.stale / backup.failed / backup.ok notification + event. The first evaluation is silent
// (an already existing status isn't reported when the agent starts or a check is newly added; like alerts.ts).
import { readdir, stat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
import type { FastifyInstance } from "fastify";
import type { z } from "zod";
import { expandHome, type backupCheckSchema } from "./config.ts";
import { notFound } from "./errors.ts";
import { run as execRun } from "./exec.ts";
import type { Ctx } from "./server.ts";

export type BackupCheck = z.infer<typeof backupCheckSchema>;
export type BackupStatus = "ok" | "stale" | "failed" | "missing";

export interface BackupState {
  status: BackupStatus;
  /** Time of the last backup (file modification time or the unit's last finish). */
  lastAt: string | null;
  sizeBytes: number | null;
  /** Path of the newest file (file) or the unit scope "user"/"system" (unit). */
  target: string | null;
  /** Machine-readable detail: "too-small", "not-found", "never-ran", "no-match", the unit's Result value (e.g. "exit-code"). */
  detail: string | null;
  running: boolean;
  checkedAt: string;
}

export const INTERVAL_MS = 15 * 60_000;
const UNIT_PROPS = ["LoadState", "ActiveState", "Result", "ExecMainStatus", "ExecMainExitTimestamp", "InactiveEnterTimestamp", "ActiveEnterTimestamp"];

/** `systemctl show` output (key=value lines). Order is systemd's own, not the -p order. */
export function parseSystemctlShow(out: string): Record<string, string> {
  const r: Record<string, string> = {};
  for (const line of out.split("\n")) {
    const i = line.indexOf("=");
    if (i > 0) r[line.slice(0, i)] = line.slice(i + 1).trim();
  }
  return r;
}

/** "@1794670853" (--timestamp=unix) or older systemd's "Sat 2026-11-14 03:00:05 +03" format; empty/n/a → null. */
export function parseSystemdTimestamp(v: string | undefined): number | null {
  if (!v || v === "n/a" || v === "0") return null;
  if (v.startsWith("@")) {
    const n = Number(v.slice(1));
    return Number.isFinite(n) && n > 0 ? n * 1000 : null;
  }
  // Time zone abbreviations can't be parsed reliably; the agent and systemd are on the same machine, local time is assumed.
  const m = /(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2})/.exec(v);
  if (!m) return null;
  const t = new Date(`${m[1]}T${m[2]}`).getTime();
  return Number.isFinite(t) ? t : null;
}

function ageStatus(lastMs: number, now: number, maxAgeHours: number): BackupStatus {
  return now - lastMs > maxAgeHours * 3600_000 ? "stale" : "ok";
}

/** Status from systemctl show properties. `props` null = the unit exists in neither scope. */
export function unitState(props: Record<string, string> | null, scope: string | null, check: Pick<BackupCheck, "maxAgeHours">, now = Date.now()): BackupState {
  const base = { sizeBytes: null, target: scope, checkedAt: new Date(now).toISOString() };
  if (!props) return { ...base, status: "missing", lastAt: null, detail: "not-found", running: false };
  const running = props.ActiveState === "activating" || props.ActiveState === "reloading";
  // For a oneshot backup job ExecMainExitTimestamp is the last finish; for a long-lived unit the active-enter time is used.
  const last =
    parseSystemdTimestamp(props.ExecMainExitTimestamp) ?? parseSystemdTimestamp(props.InactiveEnterTimestamp) ?? parseSystemdTimestamp(props.ActiveEnterTimestamp);
  const lastAt = last === null ? null : new Date(last).toISOString();
  if (props.ActiveState === "failed" || (props.Result && props.Result !== "success")) {
    return { ...base, status: "failed", lastAt, detail: props.Result && props.Result !== "success" ? props.Result : "failed", running };
  }
  if (last === null) return { ...base, status: "missing", lastAt: null, detail: "never-ran", running };
  return { ...base, status: ageStatus(last, now, check.maxAgeHours), lastAt, detail: null, running };
}

/** Only * and ? (for the last component); every other character is literal. */
export function globToRegExp(pattern: string): RegExp {
  const re = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]");
  return new RegExp(`^${re}$`);
}

/** Newest regular file matching the glob (symlinks are followed). */
export async function newestFile(pattern: string): Promise<{ path: string; mtimeMs: number; size: number } | null> {
  const full = expandHome(pattern);
  const dir = dirname(full);
  const re = globToRegExp(basename(full));
  const names = await readdir(dir).catch(() => [] as string[]);
  let best: { path: string; mtimeMs: number; size: number } | null = null;
  for (const n of names) {
    if (!re.test(n)) continue;
    const p = join(dir, n);
    const s = await stat(p).catch(() => null);
    if (!s?.isFile()) continue;
    if (!best || s.mtimeMs > best.mtimeMs) best = { path: p, mtimeMs: s.mtimeMs, size: s.size };
  }
  return best;
}

export function fileState(f: { path: string; mtimeMs: number; size: number } | null, check: Pick<BackupCheck, "maxAgeHours" | "minBytes">, now = Date.now()): BackupState {
  const checkedAt = new Date(now).toISOString();
  if (!f) return { status: "missing", lastAt: null, sizeBytes: null, target: null, detail: "no-match", running: false, checkedAt };
  const base = { lastAt: new Date(f.mtimeMs).toISOString(), sizeBytes: f.size, target: f.path, running: false, checkedAt };
  if (f.size < check.minBytes) return { ...base, status: "failed", detail: "too-small" };
  return { ...base, status: ageStatus(f.mtimeMs, now, check.maxAgeHours), detail: null };
}

type Runner = typeof execRun;

/** Notification key: missing also counts as "failed". */
const noticeKey = (s: BackupStatus) => (s === "ok" ? "backup.ok" : s === "stale" ? "backup.stale" : "backup.failed");

export class BackupMonitor {
  readonly states = new Map<string, BackupState>();
  #ctx: Ctx;
  #run: Runner;
  #timer: NodeJS.Timeout | null = null;

  constructor(ctx: Ctx, runner: Runner = execRun) {
    this.#ctx = ctx;
    this.#run = runner;
  }

  start() {
    const tick = () => void this.checkAll().catch(() => {});
    tick();
    this.#timer = setInterval(tick, INTERVAL_MS);
    this.#timer.unref();
  }

  stop() {
    if (this.#timer) clearInterval(this.#timer);
  }

  async unitProps(unit: string): Promise<{ props: Record<string, string>; scope: string } | null> {
    for (const scope of ["user", "system"] as const) {
      const show = (extra: string[]) =>
        this.#run("systemctl", [...(scope === "user" ? ["--user"] : []), "show", ...extra, "-p", UNIT_PROPS.join(","), "--", unit], {
          allowFail: true,
          timeoutMs: 10_000,
        });
      // --timestamp=unix requires systemd 251+; older versions (e.g. Ubuntu 22.04: 249) exit with "Invalid value" and
      // print nothing. Then it's retried without the flag; parseSystemctlShow's fallback parser reads the local time format.
      let r = await show(["--timestamp=unix"]);
      if (r.code !== 0 && !r.stdout.trim()) r = await show([]);
      const props = parseSystemctlShow(r.stdout);
      if (props.LoadState && props.LoadState !== "not-found") return { props, scope };
    }
    return null;
  }

  async evaluate(c: BackupCheck, now = Date.now()): Promise<BackupState> {
    if (c.kind === "file") return fileState(await newestFile(c.path!), c, now);
    const u = await this.unitProps(c.unit!);
    return unitState(u?.props ?? null, u?.scope ?? null, c, now);
  }

  /** Runs checks, stores the status; notifies if it changed (except on the first evaluation). */
  async check(c: BackupCheck, now = Date.now()): Promise<BackupState> {
    const next = await this.evaluate(c, now);
    const prev = this.states.get(c.id);
    this.states.set(c.id, next);
    if (prev && noticeKey(prev.status) !== noticeKey(next.status)) {
      const host = this.#ctx.store.get().name;
      const key = noticeKey(next.status);
      const params: Record<string, string | number> = { host, name: c.name, id: c.id };
      if (key === "backup.stale" && next.lastAt) params.hours = Math.round((now - Date.parse(next.lastAt)) / 3600_000);
      if (key === "backup.failed") params.reason = next.detail ?? next.status;
      await this.#ctx.notifier.send({ key, params, link: "tiphys://system/backups", priority: key === "backup.ok" ? "default" : "high" });
    }
    return next;
  }

  async checkAll(now = Date.now()) {
    const checks = this.#ctx.store.get().backups.checks;
    for (const id of [...this.states.keys()]) if (!checks.some((c) => c.id === id)) this.states.delete(id);
    for (const c of checks) await this.check(c, now);
  }

  view(c: BackupCheck) {
    return { ...c, state: this.states.get(c.id) ?? null };
  }
}

export function backupRoutes(app: FastifyInstance, ctx: Ctx, monitor = new BackupMonitor(ctx), startTimer = true) {
  if (startTimer) {
    monitor.start();
    app.addHook("onClose", async () => monitor.stop());
  }

  app.get("/v1/backups", async () => {
    const checks = ctx.store.get().backups.checks;
    // Newly added (not yet evaluated) checks are evaluated immediately (first evaluation: silent).
    for (const c of checks) if (!monitor.states.has(c.id)) await monitor.check(c);
    return { intervalMinutes: INTERVAL_MS / 60_000, checks: checks.map((c) => monitor.view(c)) };
  });

  app.post("/v1/backups/:id/check", async (req) => {
    const id = (req.params as Record<string, string>).id;
    const c = ctx.store.get().backups.checks.find((x) => x.id === id);
    if (!c) throw notFound("backup", { id });
    await monitor.check(c);
    return { check: monitor.view(c) };
  });
}
