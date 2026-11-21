// Sleep mode night and morning (PLAN.md §21 A-5, A-6; S5): what happens to notifications while a sleep run is on, what
// the night collects, and the one morning summary of the group.
// - Night filter (each member, its own notifications; Notifier.setGate): only the critical kinds chosen in the
//   settings (`notify.critical`: hostDown, securityTrap, incident, diskFull) and the sleep mode's own pushes go out;
//   everything else is held. A held notification is still recorded in the event stream like any other (that is the
//   notification history, as without the sleep mode); the night keeps only its count and the first three titles in
//   memory (never written anywhere; an agent restart loses them; the stop clears them). A title is the notification
//   key and its subject (name, container, unit, …) run through redact(): no language, no message text, nothing of a
//   sensitive notification but its key. The filter lifts at the dismiss (the user is awake).
// - Collector (each member): jobs that finished during the night (the `jobs` producer's jobDone at a slow interval:
//   name, duration, exit code when known), backups (ok / failed: the backup monitor's checks that ran during the
//   night and the backup notifications seen), incidents opened during the night (the incident room's list, else the
//   distinct incident ids on the notifications seen), held notifications.
// - Morning (the leader): at the dismiss (or at a user stop when there was no dismiss) every member sends its counts to
//   the leader over the group channel (`night`); the leader waits up to MORNING_WAIT_MS for the members, merges, and
//   sends ONE push `sleep.morning` (transient: not recorded) and keeps the summary in memory for 12 h
//   (GET /v1/sleep/summary); members that didn't report are counted in `missing`. Minutes: t0 → the dismiss (or the stop).
import type { SLEEP_CRITICAL } from "../config.ts";
import type { Notice } from "../notify.ts";
import { redact } from "../redact.ts";

export type CriticalKind = (typeof SLEEP_CRITICAL)[number];

/** How long the leader waits for the members' counts after the dismiss / stop. */
export const MORNING_WAIT_MS = 5000;
/** The summary is served this long (memory only). */
export const SUMMARY_KEEP_MS = 12 * 60 * 60_000;
export const TITLES_MAX = 3;
export const JOBS_MAX = 10;
/** The jobs producer's interval during the night (it runs only for the collector). */
export const NIGHT_JOBS_MS = 30_000;

/** Security notices that count as a trap/alarm (the same set the owner's Telegram alert relays). */
const SECURITY = new Set(["security.trap", "security.secretFound", "blackbox.broken", "security.lockdown"]);
/** Incident openers (incidents/signals.ts role "open"): one with an incident id attached opened or joined an incident. */
const OPENERS = new Set(["disk.full", "service.failed", "grafana.alert", "docker.died", "docker.oom", "docker.unhealthy", "docker.restartLoop", "host.offline", "backup.failed", "backup.stale", "uptime.down", "security.change"]);

/** The critical kinds a notification belongs to (none = held at night). */
export function criticalKinds(n: Notice): CriticalKind[] {
  const out: CriticalKind[] = [];
  if (n.key === "host.offline" || n.key === "uptime.down") out.push("hostDown");
  if (SECURITY.has(n.key) || (n.key === "security.change" && n.params?.severity === "critical")) out.push("securityTrap");
  if (n.data?.incidentId && OPENERS.has(n.key)) out.push("incident");
  if (n.key === "disk.full") out.push("diskFull");
  return out;
}

/** Sent at night: the sleep mode's own pushes, a test push, and the chosen critical kinds. */
export function passesAtNight(n: Notice, critical: readonly string[]): boolean {
  if (n.key.startsWith("sleep.") || n.key === "push.test") return true;
  return criticalKinds(n).some((k) => critical.includes(k));
}

const SUBJECT = ["name", "container", "unit", "mount", "monitor", "project", "target", "host"];

/** A held notification's title: its key and subject, language-free, redacted, ≤ 120 characters. */
export function titleOf(n: Notice): string {
  if (n.sensitive) return n.key.slice(0, 120);
  const p = n.params ?? {};
  const k = SUBJECT.find((x) => (typeof p[x] === "string" && p[x] !== "") || typeof p[x] === "number");
  const subject = k ? redact(String(p[k])).replace(/\s+/g, " ").slice(0, 80) : "";
  return (subject ? `${n.key} · ${subject}` : n.key).slice(0, 120);
}

export interface JobDone {
  name: string;
  durationSec: number;
  exitCode: number | null;
  host?: string;
}

/** One member's night. */
export interface NightCounts {
  jobs: number;
  jobsFailed: number;
  backups: number;
  backupsFailed: number;
  incidents: number;
  held: number;
  titles: string[];
  jobList: JobDone[];
}

export interface NightSources {
  /** The backup monitor's checks (id, status, last run). */
  backups?: () => Array<{ id: string; status: string; lastAt: string | null }>;
  /** The incident room's incidents (opened when, test or not); none = counted from the notifications seen. */
  incidents?: () => Array<{ id: string; openedAt: string; test: boolean }>;
}

const int = (v: unknown, max = 1_000_000) => (typeof v === "number" && Number.isInteger(v) && v >= 0 ? Math.min(v, max) : 0);

/** The night of one sleep run on this host (memory only). */
export class NightLog {
  readonly t0: number;
  #held = 0;
  readonly #titles: string[] = [];
  readonly #jobs: JobDone[] = [];
  #jobCount = 0;
  #jobsFailed = 0;
  readonly #backupFailed = new Set<string>();
  readonly #backupOk = new Set<string>();
  readonly #incidents = new Set<string>();
  #end: number | null = null;

  constructor(t0: number) {
    this.t0 = t0;
  }

  /** Over (dismissed / stopped): no more counting. */
  get ended() {
    return this.#end !== null;
  }

  end(at: number) {
    this.#end ??= at;
  }

  get held() {
    return this.#held;
  }

  /** Every notification of the night (held or sent): backups and incident openers are noted. */
  seen(n: Notice) {
    if (this.ended) return;
    const id = String(n.params?.id ?? n.params?.name ?? "");
    if (id && (n.key === "backup.failed" || n.key === "backup.stale")) this.#backupFailed.add(id);
    else if (id && n.key === "backup.ok") this.#backupOk.add(id);
    if (n.data?.incidentId && OPENERS.has(n.key)) this.#incidents.add(n.data.incidentId);
  }

  hold(n: Notice) {
    if (this.ended) return;
    this.#held++;
    if (this.#titles.length < TITLES_MAX) this.#titles.push(titleOf(n));
  }

  /** The jobs producer's `jobDone` message. */
  jobDone(m: Record<string, unknown>) {
    if (this.ended || m.type !== "jobDone" || typeof m.name !== "string") return;
    const exitCode = typeof m.exitCode === "number" && Number.isInteger(m.exitCode) ? m.exitCode : null;
    this.#jobCount++;
    if (exitCode !== null && exitCode !== 0) this.#jobsFailed++;
    if (this.#jobs.length < JOBS_MAX) this.#jobs.push({ name: redact(m.name).slice(0, 80), durationSec: int(m.durationSec, 7 * 86400), exitCode });
  }

  counts(src: NightSources = {}, now = Date.now()): NightCounts {
    const end = this.#end ?? now;
    const within = (iso: string | null) => {
      const t = iso ? Date.parse(iso) : NaN;
      return Number.isFinite(t) && t >= this.t0 && t <= end;
    };
    const failed = new Set(this.#backupFailed);
    const ok = new Set(this.#backupOk);
    for (const b of src.backups?.() ?? []) {
      if (!within(b.lastAt)) continue;
      if (b.status === "ok") ok.add(b.id);
      else if (b.status === "failed" || b.status === "missing") failed.add(b.id);
    }
    for (const id of failed) ok.delete(id);
    const inc = src.incidents ? src.incidents().filter((i) => !i.test && within(i.openedAt)).length : this.#incidents.size;
    return {
      jobs: this.#jobCount, jobsFailed: this.#jobsFailed, backups: ok.size, backupsFailed: failed.size, incidents: inc, held: this.#held,
      titles: [...this.#titles], jobList: this.#jobs.map((j) => ({ ...j })),
    };
  }
}

/** A member's counts from the group channel → valid counts, or null. Strings are redacted and cut again. */
export function parseNight(v: unknown): NightCounts | null {
  if (!v || typeof v !== "object" || Array.isArray(v)) return null;
  const o = v as Record<string, unknown>;
  const str = (x: unknown, max: number) => (typeof x === "string" ? redact(x).slice(0, max) : null);
  const titles = Array.isArray(o.titles) ? o.titles.slice(0, TITLES_MAX).map((t) => str(t, 120)).filter((t): t is string => !!t) : [];
  const jobList = Array.isArray(o.jobList)
    ? o.jobList.slice(0, JOBS_MAX).flatMap((j) => {
        const r = (j && typeof j === "object" ? j : {}) as Record<string, unknown>;
        const name = str(r.name, 80);
        return name ? [{ name, durationSec: int(r.durationSec, 7 * 86400), exitCode: typeof r.exitCode === "number" && Number.isInteger(r.exitCode) ? r.exitCode : null }] : [];
      })
    : [];
  return { jobs: int(o.jobs), jobsFailed: int(o.jobsFailed), backups: int(o.backups), backupsFailed: int(o.backupsFailed), incidents: int(o.incidents), held: int(o.held), titles, jobList };
}

/** The morning summary (GET /v1/sleep/summary `summary`; the push carries its numbers and titles). */
export interface SleepSummary extends Omit<NightCounts, "jobList"> {
  /** When it was made (the leader's clock, ms). */
  at: number;
  session: string;
  t0: number;
  /** The dismiss, else the stop. */
  end: number;
  minutes: number;
  jobList: JobDone[];
  /** Group size and the members whose counts didn't arrive (down, or too late). */
  members: number;
  missing: number;
}

/** The leader's own counts and the members' (session order; a missing one counts in `missing`) → the summary. */
export function mergeNights(o: { session: string; t0: number; end: number; at: number; me: string; members: string[]; own: NightCounts; reports: ReadonlyMap<string, NightCounts> }): SleepSummary {
  const parts: Array<[string, NightCounts]> = [[o.me, o.own]];
  let missing = 0;
  for (const h of o.members) {
    if (h === o.me) continue;
    const r = o.reports.get(h);
    if (r) parts.push([h, r]);
    else missing++;
  }
  const sum = (k: "jobs" | "jobsFailed" | "backups" | "backupsFailed" | "incidents" | "held") => parts.reduce((a, [, c]) => a + c[k], 0);
  return {
    at: o.at, session: o.session, t0: o.t0, end: o.end, minutes: Math.max(0, Math.round((o.end - o.t0) / 60_000)),
    jobs: sum("jobs"), jobsFailed: sum("jobsFailed"), backups: sum("backups"), backupsFailed: sum("backupsFailed"), incidents: sum("incidents"), held: sum("held"),
    titles: parts.flatMap(([, c]) => c.titles).slice(0, TITLES_MAX),
    jobList: parts.flatMap(([h, c]) => c.jobList.map((j) => ({ ...j, host: h }))).slice(0, JOBS_MAX),
    members: Math.max(1, o.members.length), missing,
  };
}

/** The push's params: numbers, and the titles one per line (the app takes a list or a text). */
export function summaryParams(s: SleepSummary): Record<string, string | number> {
  return {
    minutes: s.minutes, jobs: s.jobs, jobsFailed: s.jobsFailed, backups: s.backups, backupsFailed: s.backupsFailed, incidents: s.incidents, held: s.held,
    titles: s.titles.join("\n"), members: s.members, missing: s.missing, at: s.at,
  };
}

/**
 * The leader's wait for its members' counts: reports may come before the leader's own end (a member's dismiss reaches
 * it first). `finish` waits until every other member reported or MORNING_WAIT_MS passed, then calls `done` once.
 */
export class MorningWait {
  readonly session: string;
  readonly #members: string[];
  readonly #me: string;
  readonly #reports = new Map<string, NightCounts>();
  #pending: { t0: number; end: number; own: NightCounts; done: (s: SleepSummary) => void; timer: unknown } | null = null;
  #finished = false;
  readonly #now: () => number;
  readonly #setT: (fn: () => void, ms: number) => unknown;
  readonly #clearT: (h: unknown) => void;
  readonly #waitMs: number;

  constructor(o: { session: string; me: string; members: string[]; waitMs?: number; now?: () => number; setTimeout?: (fn: () => void, ms: number) => unknown; clearTimeout?: (h: unknown) => void }) {
    this.session = o.session;
    this.#me = o.me;
    this.#members = o.members;
    this.#waitMs = o.waitMs ?? MORNING_WAIT_MS;
    this.#now = o.now ?? Date.now;
    this.#setT = o.setTimeout ?? ((fn, ms) => setTimeout(fn, ms));
    this.#clearT = o.clearTimeout ?? ((h) => clearTimeout(h as NodeJS.Timeout));
  }

  /** finish() was called (the summary is made or on its way). */
  get started() {
    return this.#pending !== null || this.#finished;
  }

  get finished() {
    return this.#finished;
  }

  /** A member's counts (the first one per member counts). */
  report(host: string, c: NightCounts) {
    if (this.#finished || host === this.#me || !this.#members.includes(host) || this.#reports.has(host)) return;
    this.#reports.set(host, c);
    if (this.#pending && this.#all()) this.#done();
  }

  #all() {
    return this.#members.every((h) => h === this.#me || this.#reports.has(h));
  }

  finish(t0: number, end: number, own: NightCounts, done: (s: SleepSummary) => void) {
    if (this.started) return;
    this.#pending = { t0, end, own, done, timer: null };
    if (this.#all()) return this.#done();
    const h = this.#setT(() => this.#done(), this.#waitMs);
    (h as NodeJS.Timeout)?.unref?.();
    this.#pending.timer = h;
  }

  #done() {
    const p = this.#pending;
    if (!p || this.#finished) return;
    this.#finished = true;
    if (p.timer !== null) this.#clearT(p.timer);
    p.done(mergeNights({ session: this.session, t0: p.t0, end: p.end, at: this.#now(), me: this.#me, members: this.#members, own: p.own, reports: this.#reports }));
  }

  /** Timers off without a summary (agent exit). */
  cancel() {
    if (this.#pending?.timer != null) this.#clearT(this.#pending.timer);
    this.#finished = true;
  }
}

/** The leader's summary from the group channel (a member shows it on its morning screen) → valid, or null. */
export function parseSummary(v: unknown): SleepSummary | null {
  const c = parseNight(v);
  if (!c) return null;
  const o = v as Record<string, unknown>;
  const ms = (x: unknown) => (typeof x === "number" && Number.isSafeInteger(x) && x >= 0 ? x : null);
  const at = ms(o.at), t0 = ms(o.t0), end = ms(o.end);
  if (at === null || t0 === null || end === null || typeof o.session !== "string" || !/^[A-Za-z0-9_-]{8,64}$/.test(o.session)) return null;
  const hosts = Array.isArray(o.jobList) ? o.jobList.slice(0, JOBS_MAX).map((j) => (j && typeof j === "object" && typeof (j as Record<string, unknown>).host === "string" ? String((j as Record<string, unknown>).host).slice(0, 64) : undefined)) : [];
  return {
    ...c, jobList: c.jobList.map((j, i) => (hosts[i] ? { ...j, host: hosts[i] } : j)),
    at, session: o.session, t0, end, minutes: int(o.minutes, 7 * 24 * 60), members: Math.max(1, int(o.members, 4)), missing: int(o.missing, 4),
  };
}
