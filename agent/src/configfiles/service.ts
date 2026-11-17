// Config & secrets service (PLAN.md §13.3, phases C-1/C-2): list/read with masking, reveal, preview → save with a
// masked diff, backups and restore, rotation metadata; C-2: recreating the affected services after a save/restore
// (`restart: "affected"`, bound to the preview token), the rotation reminder and external-change events. Secret values
// never leave this module except in a reveal response; they are kept in memory only as redact.ts's known secrets (so
// incident context can mask them).
import type { ConfigStore } from "../config.ts";
import { AppError } from "../errors.ts";
import type { EventLog } from "../events.ts";
import type { Runner } from "../incidents/context.ts";
import type { Notifier } from "../notify.ts";
import { PreviewTokens } from "../preview.ts";
import { setKnownSecrets } from "../redact.ts";
import { discoverStacks } from "../stacks.ts";
import { affectedServices } from "./affected.ts";
import { classify, type SecretReason } from "./classify.ts";
import { applyOps, effective, entries, EnvEditError, parseEnv, type EnvDoc, type EnvOp } from "./dotenv.ts";
import { discoverConfigFiles, listBackups, readBackup, readChecked, writeAtomic, writeBackup, type ConfigFile, type WriteHooks } from "./files.ts";
import type { KeyMeta, SecretsMeta } from "./meta.ts";
import { runRestart, stepsFor as restartSteps, type PlanEntry, type RestartResult, type RunOpts } from "./restart.ts";

const REVEAL_PER_MIN = 10;
const DAY = 86_400_000;
/** Saves/restores with restart: "affected", per device. */
export const RESTART_LIMIT = 6;
export const RESTART_WINDOW_MS = 10 * 60_000;

export type Restart = "none" | "affected";

export const mask = (v: string) => `••••${[...v].length}`;
const len = (v: string) => [...v].length;

interface Pending {
  kind: "configfiles.save" | "configfiles.restore";
  /** Everything the token is bound to: the restart choice and, for "affected", the services previewed. */
  input: { fileId: string; baseHash: string; ops?: EnvOp[]; backupId?: string; restart: Restart; plan?: PlanEntry[] };
  expiresAt: number;
}

export interface Change {
  key: string;
  change: "added" | "removed" | "changed" | "renamed";
  from?: string;
  secret: boolean;
  line?: number;
  oldLine?: number;
  before?: { length: number; value?: string; inherited?: boolean };
  after?: { length: number; value?: string; inherited?: boolean };
}

export interface ServiceOpts {
  store: ConfigStore;
  meta: SecretsMeta;
  stateDir: string;
  events?: EventLog | null;
  /** secret.rotationDue / config.restartFailed notifications. */
  notifier?: Notifier;
  hooks?: WriteHooks;
  run?: Runner;
  /** Restart runner and timings (tests). */
  restart?: RunOpts;
  now?: () => number;
  log?: (msg: string, err?: unknown) => void;
}

export class ConfigFilesService {
  #o: ServiceOpts;
  #now: () => number;
  #previews: PreviewTokens;
  #pending = new Map<string, Pending>();
  #locks = new Map<string, Promise<unknown>>();
  #reveals = new Map<string, number[]>();
  #restarts = new Map<string, number[]>();
  /** fileIds whose secrets are registered with redact.ts. */
  #known = new Set<string>();

  constructor(o: ServiceOpts) {
    this.#o = o;
    this.#now = o.now ?? Date.now;
    this.#previews = new PreviewTokens({ now: this.#now });
  }

  async #resolve(fileId: string): Promise<ConfigFile> {
    const { files, skipped } = await discoverConfigFiles(this.#o.store.get());
    const f = files.find((x) => x.fileId === fileId);
    if (f) return f;
    const s = skipped.find((x) => x.fileId === fileId);
    if (s) throw new AppError("agent.configfiles.notEditable", 409, { reason: s.reason });
    throw new AppError("agent.configfiles.notFound", 404);
  }

  /** Classifies entries, feeds redact.ts and records fingerprints. */
  async #analyze(f: ConfigFile, doc: EnvDoc, by: "tiphys" | "external" = "external") {
    const marks = this.#o.meta.keys(f.fileId);
    const eff = effective(doc);
    const cls = new Map<string, { secret: boolean; reason: SecretReason | null }>();
    for (const [k, e] of eff) cls.set(k, classify(k, e.value, marks[k]?.mark));
    const list = [...eff.values()].map((e) => ({ key: e.key, value: e.value, secret: cls.get(e.key)!.secret }));
    setKnownSecrets(`configfiles:${f.fileId}`, list.filter((e) => e.secret).map(({ key, value }) => ({ key, value })));
    this.#known.add(f.fileId);
    const seen = this.#o.meta.observe(f.fileId, f.label, list, by);
    if (seen.changed) await this.#o.meta.flush().catch((err) => this.#o.log?.("sır üst verisi yazılamadı", err));
    if (seen.external.length) {
      await this.#o.events?.record(
        { key: "secret.changedExternally", params: { file: f.label, keys: seen.external.join(","), count: seen.external.length } },
        (err) => this.#o.log?.("olay yazılamadı", err),
      );
    }
    return { eff, cls, secrets: list.filter((e) => e.secret).map(({ key, value }) => ({ key, value })) };
  }

  /**
   * Reads and analyzes the file under its read lock (taken by save/restore around read → write → analyze), so an
   * analysis of content read before a write can't land after the write's own: no false external change, no stale
   * known secrets.
   */
  #readAnalyzed(f: ConfigFile) {
    return this.#locked(`read:${f.fileId}`, async () => {
      const r = await readChecked(f);
      const doc = parseEnv(r.text);
      return { r, doc, ...(await this.#analyze(f, doc)) };
    });
  }

  #keyInfo(m: KeyMeta | undefined) {
    if (!m) return {};
    const since = m.lastChangedAt ?? m.firstSeenAt;
    const ageDays = since ? Math.floor((this.#now() - Date.parse(since)) / DAY) : undefined;
    return {
      ...(m.firstSeenAt ? { firstSeenAt: m.firstSeenAt } : {}),
      ...(m.lastChangedAt ? { lastChangedAt: m.lastChangedAt, changedBy: m.changedBy } : {}),
      ...(m.maxAgeDays !== undefined ? { maxAgeDays: m.maxAgeDays } : {}),
      ...(m.mark !== undefined ? { mark: m.mark } : {}),
      ...(ageDays !== undefined ? { ageDays } : {}),
      ...(m.maxAgeDays !== undefined && ageDays !== undefined ? { due: ageDays >= m.maxAgeDays } : {}),
    };
  }

  #summary(f: ConfigFile) {
    return { fileId: f.fileId, file: f.label, source: f.source, stack: f.stack?.id ?? null };
  }

  async list() {
    const { files, skipped } = await discoverConfigFiles(this.#o.store.get());
    const out = [];
    for (const f of files) {
      try {
        const { r, cls } = await this.#readAnalyzed(f);
        out.push({
          ...this.#summary(f),
          size: r.content.length,
          modifiedAt: r.st.mtime.toISOString(),
          keys: cls.size,
          secrets: [...cls.values()].filter((c) => c.secret).length,
          worldReadable: (r.st.mode & 0o004) !== 0,
        });
      } catch (err) {
        const reason = err instanceof AppError ? ((err.params.reason as string | undefined) ?? err.code.split(".").pop()!) : "unreadable";
        if (!(err instanceof AppError)) this.#o.log?.("ayar dosyası okunamadı", (err as NodeJS.ErrnoException).code);
        skipped.push({ label: f.label, reason: reason as never, fileId: f.fileId });
      }
    }
    return { files: out, skipped: skipped.map((s) => ({ fileId: s.fileId, file: s.label, reason: s.reason })) };
  }

  async get(fileId: string) {
    const f = await this.#resolve(fileId);
    const { r, doc, eff, cls } = await this.#readAnalyzed(f);
    const meta = this.#o.meta.keys(fileId);
    return {
      ...this.#summary(f),
      hash: r.hash,
      size: r.content.length,
      modifiedAt: r.st.mtime.toISOString(),
      mode: (r.st.mode & 0o777).toString(8).padStart(4, "0"),
      warnings: r.st.mode & 0o004 ? ["worldReadable"] : [],
      entries: entries(doc).map((e) => {
        const c = cls.get(e.key)!;
        return {
          key: e.key,
          line: e.line,
          secret: c.secret,
          reason: c.reason,
          masked: mask(e.value),
          length: len(e.value),
          ...(c.secret ? {} : { value: e.value }),
          inherited: e.inherited,
          quote: e.quote,
          duplicate: eff.get(e.key) !== e,
          ...this.#keyInfo(meta[e.key]),
        };
      }),
      issues: doc.nodes.filter((n) => n.type === "invalid").map((n) => ({ line: n.line, reason: (n as { reason?: string }).reason })),
    };
  }

  async reveal(fileId: string, keys: string[], device: string) {
    const now = this.#now();
    const recent = (this.#reveals.get(device) ?? []).filter((t) => now - t < 60_000);
    if (recent.length >= REVEAL_PER_MIN) throw new AppError("agent.configfiles.rateLimited", 429, { perMinute: REVEAL_PER_MIN });
    recent.push(now);
    this.#reveals.set(device, recent);
    const f = await this.#resolve(fileId);
    const { eff } = await this.#readAnalyzed(f);
    const values: Record<string, string> = {};
    const missing: string[] = [];
    for (const k of new Set(keys)) {
      const e = eff.get(k);
      if (e) values[k] = e.value;
      else missing.push(k);
    }
    const revealed = Object.keys(values);
    if (revealed.length) {
      await this.#o.events?.record(
        { key: "secrets.revealed", params: { file: f.label, keys: revealed.join(","), count: revealed.length }, device },
        (err) => this.#o.log?.("olay yazılamadı", err),
      );
    }
    return { fileId, file: f.label, values, missing };
  }

  /** Key-level masked diff (values only for non-secrets). */
  #diff(f: ConfigFile, before: EnvDoc, after: EnvDoc, renames: Map<string, string>): { changes: Change[]; otherLinesChanged: boolean } {
    const marks = this.#o.meta.keys(f.fileId);
    const a = effective(before);
    const b = effective(after);
    const side = (k: string, e: { value: string; inherited: boolean }, secret: boolean) => ({
      length: len(e.value),
      ...(secret ? {} : { value: e.value }),
      ...(e.inherited ? { inherited: true } : {}),
    });
    const isSecret = (k: string, v: string) => classify(k, v, marks[k]?.mark).secret;
    const changes: Change[] = [];
    const renamedFrom = new Set<string>();
    for (const [k, n] of b) {
      const from = !a.has(k) ? renames.get(k) : undefined;
      const o = a.get(k) ?? (from ? a.get(from) : undefined);
      if (!o) {
        const secret = isSecret(k, n.value);
        changes.push({ key: k, change: "added", secret, line: n.line, after: side(k, n, secret) });
        continue;
      }
      const secret = isSecret(from ?? k, o.value) || isSecret(k, n.value);
      if (from) {
        renamedFrom.add(from);
        changes.push({ key: k, change: "renamed", from, secret, line: n.line, oldLine: o.line, before: side(from, o, secret), after: side(k, n, secret) });
      } else if (o.value !== n.value || o.inherited !== n.inherited) {
        changes.push({ key: k, change: "changed", secret, line: n.line, oldLine: o.line, before: side(k, o, secret), after: side(k, n, secret) });
      }
    }
    for (const [k, o] of a) {
      if (b.has(k) || renamedFrom.has(k)) continue;
      const secret = isSecret(k, o.value);
      changes.push({ key: k, change: "removed", secret, oldLine: o.line, before: side(k, o, secret) });
    }
    const other = (d: EnvDoc) => d.nodes.filter((n) => n.type !== "entry").map((n) => n.raw.trimEnd()).join("\n");
    return { changes, otherLinesChanged: other(before) !== other(after) };
  }

  #issue(kind: Pending["kind"], device: string, input: Pending["input"]) {
    const now = this.#now();
    for (const [t, p] of this.#pending) if (p.expiresAt <= now) this.#pending.delete(t);
    const t = this.#previews.issue(device, kind, input);
    this.#pending.set(t.previewToken, { kind, input, expiresAt: Date.parse(t.expiresAt) });
    return t;
  }

  /**
   * Spends the token (any outcome) and returns the previewed input bound to it. The restart choice of the execute
   * request is part of the hashed input: a token previewed without restart can't run one, and vice versa.
   */
  #consume(kind: Pending["kind"], token: string, device: string, fileId: string, restart: Restart): Pending["input"] {
    const p = this.#pending.get(token);
    this.#pending.delete(token);
    const input: Pending["input"] = p && p.kind === kind ? { ...p.input, fileId, restart } : { fileId, baseHash: "", restart };
    this.#previews.consume(token, device, kind, input);
    return input;
  }

  #locked<T>(fileId: string, fn: () => Promise<T>): Promise<T> {
    const prev = this.#locks.get(fileId) ?? Promise.resolve();
    const run = prev.then(fn, fn);
    const tail = run.catch(() => {});
    this.#locks.set(fileId, tail);
    void tail.then(() => {
      if (this.#locks.get(fileId) === tail) this.#locks.delete(fileId);
    });
    return run;
  }

  async #affected(f: ConfigFile, keys: string[]) {
    if (!f.stack) return [];
    return affectedServices(await discoverStacks(this.#o.store.get()), f.real, keys);
  }

  /** For restart "affected": the plan bound to the token (the affected services now) and the commands it would run. */
  async #restartPlan(f: ConfigFile, keys: string[], restart: Restart) {
    const stacks = f.stack ? await discoverStacks(this.#o.store.get()) : [];
    const affected = f.stack ? await affectedServices(stacks, f.real, keys) : [];
    if (restart !== "affected") return { affected };
    if (!affected.length) throw new AppError("agent.configfiles.nothingToRestart", 409);
    const steps = restartSteps(affected, stacks, affected);
    return { affected, plan: affected, restartPlan: steps.map((s) => ({ stack: s.stack, project: s.project, services: s.services, argv: s.argv })) };
  }

  #takeRestart(device: string) {
    const now = this.#now();
    const recent = (this.#restarts.get(device) ?? []).filter((t) => now - t < RESTART_WINDOW_MS);
    if (recent.length >= RESTART_LIMIT) {
      throw new AppError("agent.configfiles.restartRateLimited", 429, { limit: RESTART_LIMIT, windowSeconds: RESTART_WINDOW_MS / 1000 });
    }
    recent.push(now);
    this.#restarts.set(device, recent);
  }

  /**
   * After a successful write: recreates the services of the plan that are still affected (restart "affected"), records
   * the event with the outcome and, on failure, notifies; the file stays as written either way.
   */
  async #finish(
    f: ConfigFile,
    o: { kind: "config.saved" | "config.restored"; keys: string[]; backupId: string; restoredFrom?: string; input: Pending["input"]; device: string; replaced: Array<{ key: string; value: string }> },
  ) {
    let recreate: (RestartResult & { skipped?: PlanEntry[] }) | undefined;
    if (o.input.restart === "affected") {
      const stacks = await discoverStacks(this.#o.store.get());
      const current = await affectedServices(stacks, f.real, o.keys);
      const steps = restartSteps(o.input.plan ?? [], stacks, current);
      const skipped = (o.input.plan ?? [])
        .map((p) => ({ ...p, services: p.services.filter((s) => !steps.some((x) => x.stack === p.stack && x.services.includes(s))) }))
        .filter((p) => p.services.length);
      const r = await runRestart(steps, { run: this.#o.run, ...this.#o.restart, hide: o.replaced });
      recreate = skipped.length ? { ...r, ok: false, stage: r.stage ?? "command", skipped } : r;
    }
    const stage = recreate && !recreate.ok ? (recreate.stage ?? "command") : undefined;
    const failed = stage !== undefined;
    const services = recreate ? [...recreate.services.map((x) => x.service), ...(recreate.skipped ?? []).flatMap((p) => p.services)] : [];
    const failedServices = recreate ? [...recreate.services.filter((x) => !x.ok).map((x) => x.service), ...(recreate.skipped ?? []).flatMap((p) => p.services)] : [];
    await this.#o.events?.record(
      {
        key: o.kind,
        params: {
          file: f.label,
          keys: o.keys.join(","),
          backupId: o.restoredFrom ?? o.backupId,
          restart: !recreate ? "none" : recreate.ok ? "ok" : "failed",
          ...(recreate ? { services: [...new Set(services)].join(",") } : {}),
          ...(failed ? { stage, failed: [...new Set(failedServices)].join(",") } : {}),
        },
        device: o.device,
      },
      (err) => this.#o.log?.("olay yazılamadı", err),
    );
    if (failed) {
      void this.#o.notifier
        ?.send({
          key: "config.restartFailed",
          params: { host: this.#o.store.get().name, file: f.label, services: [...new Set(failedServices)].join(","), stage, backupId: o.backupId },
          priority: "high",
          data: { fileId: f.fileId, backupId: o.backupId },
        })
        .catch(() => {});
    }
    return {
      restart: o.input.restart,
      ...(recreate ? { recreate } : {}),
      // The file stays written; restoring the backup taken before this write undoes it.
      ...(failed ? { restore: { route: `POST /v1/config-files/${f.fileId}/restore`, backupId: o.backupId } } : {}),
    };
  }

  async preview(fileId: string, baseHash: string, ops: EnvOp[], device: string, restart: Restart = "none") {
    const f = await this.#resolve(fileId);
    const { r, doc: before } = await this.#readAnalyzed(f);
    if (r.hash !== baseHash) throw new AppError("agent.configfiles.conflict", 409, { hash: r.hash });
    const nextText = editOrThrow(before, ops);
    if (nextText === r.text) throw new AppError("agent.configfiles.noChange", 400);
    const after = parseEnv(nextText);
    const keys = keysOf(ops);
    const { affected, plan, restartPlan } = await this.#restartPlan(f, keys, restart);
    const t = this.#issue("configfiles.save", device, { fileId, baseHash, ops, restart, ...(plan ? { plan } : {}) });
    return { fileId, file: f.label, baseHash, ...this.#diff(f, before, after, renamesOf(ops)), affected, keys, restart, ...(restartPlan ? { restartPlan } : {}), ...t };
  }

  async save(fileId: string, token: string, device: string, restart: Restart = "none") {
    // Counted before the token is spent: a limited request can be retried with the same token.
    if (restart === "affected") this.#takeRestart(device);
    const input = this.#consume("configfiles.save", token, device, fileId, restart);
    const ops = input.ops!;
    return this.#locked(fileId, async () => {
      const f = await this.#resolve(fileId);
      const { w, backupId, replaced } = await this.#locked(`read:${fileId}`, async () => {
        const cur = await readChecked(f);
        if (cur.hash !== input.baseHash) throw new AppError("agent.configfiles.conflict", 409, { hash: cur.hash });
        const before = parseEnv(cur.text);
        const { secrets: replaced } = await this.#analyze(f, before, "external");
        const nextText = editOrThrow(before, ops);
        let backupId = "";
        const w = await writeAtomic(f, input.baseHash, Buffer.from(nextText, "utf8"), this.#o.hooks, async () => {
          backupId = await writeBackup(this.#o.stateDir, fileId, cur.content, this.#now());
        });
        for (const op of ops) if (op.op === "rename") this.#o.meta.rename(fileId, op.key, op.newKey);
        await this.#analyze(f, parseEnv(nextText), "tiphys");
        return { w, backupId, replaced };
      });
      const keys = keysOf(ops);
      const affected = await this.#affected(f, keys);
      const done = await this.#finish(f, { kind: "config.saved", keys, backupId, input, device, replaced });
      return { fileId, file: f.label, hash: w.hash, backupId, warnings: w.warnings, affected, keys, ...done };
    });
  }

  async backups(fileId: string) {
    const f = await this.#resolve(fileId);
    return { fileId, file: f.label, backups: await listBackups(this.#o.stateDir, fileId) };
  }

  async restorePreview(fileId: string, backupId: string, device: string, restart: Restart = "none") {
    const f = await this.#resolve(fileId);
    const { r, doc: before } = await this.#readAnalyzed(f);
    const backup = await readBackup(this.#o.stateDir, fileId, backupId);
    const after = parseEnv(backup.toString("utf8"));
    const d = this.#diff(f, before, after, new Map());
    const keys = d.changes.flatMap((c) => (c.from ? [c.from, c.key] : [c.key]));
    const { affected, plan, restartPlan } = await this.#restartPlan(f, keys, restart);
    const t = this.#issue("configfiles.restore", device, { fileId, baseHash: r.hash, backupId, restart, ...(plan ? { plan } : {}) });
    return { fileId, file: f.label, backupId, baseHash: r.hash, ...d, affected, keys, restart, ...(restartPlan ? { restartPlan } : {}), ...t };
  }

  async restore(fileId: string, token: string, device: string, backupId: string, restart: Restart = "none") {
    if (restart === "affected") this.#takeRestart(device);
    const input = this.#consume("configfiles.restore", token, device, fileId, restart);
    if (input.backupId !== backupId) throw new AppError("agent.preview.invalid", 409);
    return this.#locked(fileId, async () => {
      const f = await this.#resolve(fileId);
      const { w, newBackup, replaced, keys } = await this.#locked(`read:${fileId}`, async () => {
        const cur = await readChecked(f);
        if (cur.hash !== input.baseHash) throw new AppError("agent.configfiles.conflict", 409, { hash: cur.hash });
        const content = await readBackup(this.#o.stateDir, fileId, backupId);
        const before = parseEnv(cur.text);
        const { secrets: replaced } = await this.#analyze(f, before, "external");
        const after = parseEnv(content.toString("utf8"));
        const keys = this.#diff(f, before, after, new Map()).changes.map((c) => c.key);
        let newBackup = "";
        const w = await writeAtomic(f, input.baseHash, content, this.#o.hooks, async () => {
          newBackup = await writeBackup(this.#o.stateDir, fileId, cur.content, this.#now());
        });
        await this.#analyze(f, after, "tiphys");
        return { w, newBackup, replaced, keys };
      });
      const affected = await this.#affected(f, keys);
      const done = await this.#finish(f, { kind: "config.restored", keys, backupId: newBackup, restoredFrom: backupId, input, device, replaced });
      return { fileId, file: f.label, hash: w.hash, restoredFrom: backupId, backupId: newBackup, warnings: w.warnings, affected, keys, ...done };
    });
  }

  metaList() {
    return {
      files: this.#o.meta.files().map((f) => ({
        fileId: f.fileId,
        file: f.file,
        keys: Object.entries(f.keys).map(([key, m]) => ({ key, ...this.#keyInfo(m) })),
      })),
    };
  }

  async putMeta(updates: Array<{ fileId: string; key: string; maxAgeDays?: number | null; secret?: boolean | null }>) {
    const docs = new Map<string, { f: ConfigFile; doc: EnvDoc }>();
    for (const u of updates) {
      if (!docs.has(u.fileId)) {
        const f = await this.#resolve(u.fileId);
        docs.set(u.fileId, { f, doc: parseEnv((await readChecked(f)).text) });
      }
      const { f, doc } = docs.get(u.fileId)!;
      if (!effective(doc).has(u.key)) throw new AppError("agent.configfiles.keyNotFound", 404, { key: u.key });
      this.#o.meta.setPolicy(u.fileId, f.label, u.key, { maxAgeDays: u.maxAgeDays, mark: u.secret });
    }
    for (const { f } of docs.values()) await this.#readAnalyzed(f);
    await this.#o.meta.flush();
    return this.metaList();
  }

  /**
   * Reads every file (startup, then periodically): current secret values for redaction (sources of files that are gone
   * or no longer readable are dropped), external changes for rotation tracking.
   */
  async scanAll() {
    const r = await this.list();
    const ids = new Set(r.files.map((f) => f.fileId));
    for (const id of this.#known) {
      if (ids.has(id)) continue;
      setKnownSecrets(`configfiles:${id}`, []);
      this.#known.delete(id);
    }
    return r;
  }

  /**
   * Rotation reminder (daily and at startup): after a fresh scan, every current file with secrets older than their
   * maxAgeDays gets one `secret.rotationDue` notification per local day (key names only). Returns the files notified.
   */
  async checkRotation(): Promise<Array<{ fileId: string; file: string; keys: string[] }>> {
    const { files } = await this.scanAll();
    const ids = new Set(files.map((f) => f.fileId));
    const day = localDay(this.#now());
    const due: Array<{ fileId: string; file: string; keys: string[] }> = [];
    for (const m of this.#o.meta.files()) {
      if (!ids.has(m.fileId) || m.rotationNotifiedOn === day) continue;
      const keys = Object.entries(m.keys)
        .filter(([, k]) => this.#keyInfo(k).due === true)
        .map(([k]) => k)
        .sort();
      if (!keys.length) continue;
      due.push({ fileId: m.fileId, file: m.file, keys });
    }
    if (!due.length) return [];
    const host = this.#o.store.get().name;
    // The day is marked only after a successful send, so a failed one is retried on the next check.
    const out: Array<{ fileId: string; file: string; keys: string[] }> = [];
    for (const n of due) {
      try {
        await this.#o.notifier?.send({ key: "secret.rotationDue", params: { host, file: n.file, keys: n.keys.join(","), count: n.keys.length }, data: { fileId: n.fileId } });
      } catch (err) {
        this.#o.log?.("bildirim gönderilemedi", err);
        continue;
      }
      this.#o.meta.setRotationNotified(n.fileId, day);
      out.push(n);
    }
    if (out.length) await this.#o.meta.flush().catch((err) => this.#o.log?.("sır üst verisi yazılamadı", err));
    return out;
  }
}

function localDay(t: number): string {
  const d = new Date(t);
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

function editOrThrow(doc: EnvDoc, ops: EnvOp[]): string {
  try {
    return applyOps(doc, ops);
  } catch (e) {
    if (e instanceof EnvEditError) {
      if (e.code === "unterminatedQuote") throw new AppError("agent.configfiles.unterminatedQuote", 409, { line: Number(e.key) });
      throw new AppError(`agent.configfiles.${e.code}`, e.code === "keyExists" ? 409 : 404, { key: e.key });
    }
    throw e;
  }
}

const keysOf = (ops: EnvOp[]) => [...new Set(ops.flatMap((o) => (o.op === "rename" ? [o.key, o.newKey] : [o.key])))];

/** newKey → original key, following chains (A→B, B→C gives C→A). */
function renamesOf(ops: EnvOp[]): Map<string, string> {
  const m = new Map<string, string>();
  for (const o of ops) {
    if (o.op !== "rename") continue;
    const origin = m.get(o.key) ?? o.key;
    m.delete(o.key);
    m.set(o.newKey, origin);
  }
  return m;
}
