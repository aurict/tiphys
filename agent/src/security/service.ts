// Security center service (PLAN.md §15, S-1): collects every host's report on a timer, evaluates findings, keeps the
// baseline and the list of changes, and notifies. State: security-state.json next to agent.json (0600, atomic).
//
// Hosts: "self" (this machine) plus security.hosts (ssh: restricted audit key; agent: another agent's raw report).
// A full report (SUID scan, world-writable files) runs at most once a day per host; ordinary ones every
// intervalMinutes. A host that can't be reached keeps its last report ("stale"); after 6 hours one
// security.unreachable notification is sent, and security.reachable when it comes back.
import { chmod, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { z } from "zod";
import type { securityHostSchema } from "../config.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import { CRITICAL_CATEGORIES, diff, fillBaseline, snapshotOf, type Change, type Snapshot } from "./baseline.ts";
import { collectAgent, collectLocal, collectSsh, type AuditMode, type Fetch, type Spawner } from "./collect.ts";
import { parseReport, ReportParseError, type SecurityReport } from "./report.ts";
import { countBySeverity, evaluate, score, type Finding, type HostRole } from "./rules.ts";

export type SecurityHost = z.infer<typeof securityHostSchema>;
export const FULL_INTERVAL_MS = 24 * 3600_000;
export const UNREACHABLE_NOTIFY_MS = 6 * 3600_000;

export interface HostState {
  report: SecurityReport | null;
  /** SUID / world-writable lists of the last full report (an ordinary report has none). */
  suid: SecurityReport["suid"];
  worldWritable?: SecurityReport["worldWritable"];
  findings: Finding[];
  score: number | null;
  lastAttemptAt: string | null;
  lastOkAt: string | null;
  lastFullAt: string | null;
  lastError: { code: string; at: string } | null;
  baseline: Snapshot | null;
  baselineAt: string | null;
  /** Whether the baseline was taken with root; a report of the other kind sees different things → new baseline. */
  baselineRoot: boolean | null;
  changes: Change[];
  /** Change ids already notified (so a change is announced once). */
  notified: string[];
  unreachableNotified: boolean;
}

const emptyState = (): HostState => ({
  report: null,
  suid: null,
  findings: [],
  score: null,
  lastAttemptAt: null,
  lastOkAt: null,
  lastFullAt: null,
  lastError: null,
  baseline: null,
  baselineAt: null,
  baselineRoot: null,
  changes: [],
  notified: [],
  unreachableNotified: false,
});

export interface HostView {
  id: string;
  name: string;
  role: HostRole;
  source: "local" | "ssh" | "agent";
}

export interface ServiceOpts {
  spawner?: Spawner;
  fetch?: Fetch;
  now?: () => number;
  installedPath?: string;
}

export class SecurityService {
  readonly states = new Map<string, HostState>();
  readonly file: string;
  #ctx: Ctx;
  #o: ServiceOpts;
  #timer: NodeJS.Timeout | null = null;
  #running = new Map<string, Promise<HostState>>();
  #save: Promise<void> = Promise.resolve();

  constructor(ctx: Ctx, o: ServiceOpts = {}) {
    this.#ctx = ctx;
    this.#o = o;
    this.file = join(dirname(ctx.store.path), "security-state.json");
  }

  #now() {
    return this.#o.now?.() ?? Date.now();
  }

  hosts(): (HostView & { config: SecurityHost | null })[] {
    const c = this.#ctx.store.get();
    return [
      { id: "self", name: c.name, role: c.security.self.role, source: "local" as const, config: null },
      ...c.security.hosts.map((h) => ({ id: h.id, name: h.name, role: h.role, source: h.source.kind, config: h })),
    ];
  }

  async load() {
    const raw = await readFile(this.file, "utf8").catch(() => null);
    if (!raw) return;
    try {
      const data = JSON.parse(raw) as { hosts?: Record<string, Partial<HostState>> };
      for (const [id, s] of Object.entries(data.hosts ?? {})) this.states.set(id, { ...emptyState(), ...s });
    } catch {
      // A broken state file is set aside; the next report starts a fresh baseline (silently).
      await rename(this.file, `${this.file}.corrupt-${Date.now()}`).catch(() => {});
    }
  }

  async #persist() {
    const known = new Set(this.hosts().map((h) => h.id));
    const hosts = Object.fromEntries([...this.states].filter(([id]) => known.has(id)));
    const data = JSON.stringify({ version: 1, hosts });
    this.#save = this.#save.then(async () => {
      const tmp = `${this.file}.${process.pid}.tmp`;
      await writeFile(tmp, data, { mode: 0o600 });
      await chmod(tmp, 0o600);
      await rename(tmp, this.file);
    });
    await this.#save.catch(() => {});
  }

  start() {
    const tick = () => void this.checkDue().catch(() => {});
    // First round shortly after start, not during it.
    const first = setTimeout(tick, 30_000);
    first.unref();
    this.#timer = setInterval(tick, 60_000);
    this.#timer.unref();
  }

  stop() {
    if (this.#timer) clearInterval(this.#timer);
  }

  /** Hosts whose interval has elapsed; one at a time so the server isn't loaded by parallel scans. */
  async checkDue() {
    const interval = this.#ctx.store.get().security.intervalMinutes * 60_000;
    for (const h of this.hosts()) {
      const s = this.states.get(h.id);
      const last = s?.lastAttemptAt ? Date.parse(s.lastAttemptAt) : 0;
      if (this.#now() - last >= interval) await this.check(h.id).catch(() => {});
    }
  }

  /** Runs a check (joins one already running for the host). */
  check(id: string, opts: { full?: boolean } = {}): Promise<HostState> {
    const running = this.#running.get(id);
    if (running) return running;
    const p = this.#check(id, opts).finally(() => this.#running.delete(id));
    this.#running.set(id, p);
    return p;
  }

  async #collect(h: HostView & { config: SecurityHost | null }, mode: AuditMode): Promise<string> {
    const configPath = this.#ctx.store.path;
    if (!h.config) {
      return collectLocal({ mode, sudo: this.#ctx.store.get().security.self.sudo, configPath, spawner: this.#o.spawner, installedPath: this.#o.installedPath });
    }
    const src = h.config.source;
    if (src.kind === "ssh") return collectSsh({ mode, source: src, configPath, spawner: this.#o.spawner });
    return collectAgent({ mode, source: src, fetch: this.#o.fetch });
  }

  policy(id: string): { role: HostRole; allowedPorts: string[] } {
    const c = this.#ctx.store.get().security;
    if (id === "self") return { role: c.self.role, allowedPorts: c.self.allowedPorts };
    const h = c.hosts.find((x) => x.id === id);
    return { role: h?.role ?? "server", allowedPorts: h?.allowedPorts ?? [] };
  }

  async #check(id: string, opts: { full?: boolean }): Promise<HostState> {
    const h = this.hosts().find((x) => x.id === id);
    if (!h) throw new AppError("agent.security.hostNotFound", 404, { id });
    const s = this.states.get(id) ?? emptyState();
    this.states.set(id, s);
    const now = this.#now();
    const nowIso = new Date(now).toISOString();
    s.lastAttemptAt = nowIso;
    const full = opts.full || !s.lastFullAt || now - Date.parse(s.lastFullAt) >= FULL_INTERVAL_MS;
    let report: SecurityReport;
    try {
      const text = await this.#collect(h, full ? "report-full" : "report");
      try {
        report = parseReport(text);
      } catch (pe) {
        throw pe instanceof ReportParseError ? new AppError("agent.security.badReport", 502) : pe;
      }
    } catch (e) {
      const code = e instanceof AppError ? e.code : e instanceof ReportParseError ? "agent.security.badReport" : "agent.security.collectFailed";
      s.lastError = { code, at: nowIso };
      const since = s.lastOkAt ? Date.parse(s.lastOkAt) : null;
      if (since !== null && now - since >= UNREACHABLE_NOTIFY_MS && !s.unreachableNotified) {
        s.unreachableNotified = true;
        await this.#ctx.notifier.send({
          key: "security.unreachable",
          params: { host: h.name, hostId: id, agent: this.#ctx.store.get().name, hours: Math.floor((now - since) / 3600_000), code },
          link: `tiphys://security/${id}`,
          priority: "default",
        });
      }
      await this.#persist();
      throw e;
    }
    if (s.unreachableNotified) {
      s.unreachableNotified = false;
      await this.#ctx.notifier.send({ key: "security.reachable", params: { host: h.name, hostId: id, agent: this.#ctx.store.get().name }, link: `tiphys://security/${id}`, priority: "low" });
    }
    s.lastError = null;
    s.lastOkAt = nowIso;
    if (report.mode === "report-full") {
      s.lastFullAt = nowIso;
      if (report.suid) s.suid = report.suid;
      if (report.worldWritable) s.worldWritable = report.worldWritable;
    }
    // Full-report-only lists are carried over so their findings don't flicker between full runs.
    if (!report.worldWritable && s.worldWritable) report.worldWritable = s.worldWritable;
    s.report = report;
    s.findings = evaluate(report, this.policy(id));
    s.score = score(s.findings);
    const snap = snapshotOf(report, s.suid);
    // First report, or the privilege level changed (e.g. sudo turned on): start a new baseline silently.
    if (!s.baseline || (s.baselineRoot !== null && s.baselineRoot !== report.root)) {
      s.baseline = snap;
      s.baselineAt = nowIso;
      s.baselineRoot = report.root;
      s.changes = [];
      s.notified = [];
    } else {
      s.baseline = fillBaseline(s.baseline, snap);
      s.changes = diff(s.baseline, snap, s.changes, new Date(now));
      const fresh = s.changes.filter((c) => !s.notified.includes(c.id));
      s.notified = s.changes.map((c) => c.id);
      if (fresh.length) {
        const critical = fresh.some((c) => CRITICAL_CATEGORIES.has(c.category) && c.kind !== "removed");
        const categories = [...new Set(fresh.map((c) => c.category))].join(",");
        await this.#ctx.notifier.send({
          key: "security.change",
          params: { host: h.name, hostId: id, agent: this.#ctx.store.get().name, count: fresh.length, categories, severity: critical ? "critical" : "warning" },
          link: `tiphys://security/${id}`,
          priority: critical ? "high" : "default",
        });
      }
    }
    await this.#persist();
    return s;
  }

  /** Accepts the current state as the new baseline (the listed changes are cleared). */
  async acceptBaseline(id: string): Promise<{ accepted: number }> {
    const h = this.hosts().find((x) => x.id === id);
    if (!h) throw new AppError("agent.security.hostNotFound", 404, { id });
    const s = this.states.get(id);
    if (!s?.report) throw new AppError("agent.security.noReport", 409);
    const accepted = s.changes.length;
    s.baseline = snapshotOf(s.report, s.suid);
    s.baselineAt = new Date(this.#now()).toISOString();
    s.baselineRoot = s.report.root;
    s.changes = [];
    s.notified = [];
    await this.#persist();
    await this.#ctx.notifier.send({ key: "security.accepted", params: { host: h.name, hostId: id, agent: this.#ctx.store.get().name, count: accepted }, link: `tiphys://security/${id}`, priority: "low" });
    return { accepted };
  }

  /** Re-evaluates findings after a policy change (allowed ports, role) without collecting again. */
  async reevaluate(id: string) {
    const s = this.states.get(id);
    if (!s?.report) return;
    s.findings = evaluate(s.report, this.policy(id));
    s.score = score(s.findings);
    await this.#persist();
  }

  async forget(id: string) {
    this.states.delete(id);
    await this.#persist();
  }

  summary(h: HostView) {
    const s = this.states.get(h.id) ?? emptyState();
    const interval = this.#ctx.store.get().security.intervalMinutes * 60_000;
    const stale = !s.lastOkAt || this.#now() - Date.parse(s.lastOkAt) > 3 * interval;
    return {
      id: h.id,
      name: h.name,
      role: h.role,
      source: h.source,
      score: s.score,
      counts: countBySeverity(s.findings),
      changes: s.changes.length,
      lastOkAt: s.lastOkAt,
      lastAttemptAt: s.lastAttemptAt,
      lastFullAt: s.lastFullAt,
      lastError: s.lastError,
      stale,
      running: this.#running.has(h.id),
    };
  }

  detail(id: string) {
    const h = this.hosts().find((x) => x.id === id);
    if (!h) throw new AppError("agent.security.hostNotFound", 404, { id });
    const s = this.states.get(id) ?? emptyState();
    const r = s.report;
    return {
      host: this.summary(h),
      policy: this.policy(id),
      findings: s.findings,
      changes: s.changes,
      baselineAt: s.baselineAt,
      report: r && {
        mode: r.mode,
        root: r.root,
        meta: r.meta,
        listen: r.listen,
        firewall: r.firewall,
        sshd: r.sshd,
        users: r.users,
        passwords: r.passwords,
        groups: r.groups,
        sudoers: r.sudoers,
        authKeys: r.authKeys,
        cron: r.cron,
        timers: r.timers,
        autostart: r.autostart,
        updates: r.updates,
        services: r.services,
        sysctl: r.sysctl,
        logins: r.logins,
        docker: r.docker,
        suid: s.suid,
        worldWritable: r.worldWritable ?? s.worldWritable ?? null,
        agentFiles: r.agentFiles,
        unavailable: r.unavailable,
      },
    };
  }
}
