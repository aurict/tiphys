// Backup restore tests (PLAN.md §13.2, D-4): restores the newest dump matching `dumpGlob` into a throwaway database
// container and checks sanity queries. Everything runs through argv (no shell):
//   docker run -d --rm --network none --memory 1g --tmpfs <datadir> -e <PASSWORD_ENV> --name tiphys-restore-<id>-<rand> <image>
//   → wait ready (pg_isready / mysqladmin ping over loopback, i.e. the final server) → the dump is streamed into
//   `docker exec -i … psql|pg_restore|mysql` (gz: gunzip in Node) → one `docker exec` client call per sanity query
//   (read-only session) → `docker rm -f` in finally (also on timeout and agent shutdown).
// One test at a time, 30 min limit, last 20 results per test in db-restore-results.json (0600). The random password is
// passed to docker through the environment (`-e NAME`), never in argv.
import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import { createReadStream } from "node:fs";
import { chmod, mkdir, readFile, realpath, rename, stat, statfs, writeFile } from "node:fs/promises";
import { dirname, isAbsolute, join, resolve, sep } from "node:path";
import { pipeline } from "node:stream/promises";
import { createGunzip } from "node:zlib";
import { newestFile } from "../backups.ts";
import { dueAt, nextRun } from "../claude/schedules.ts";
import { expandHome, restoreTestSchema, type AgentConfig, type ConfigStore } from "../config.ts";
import { AppError } from "../errors.ts";
import { run as execRun } from "../exec.ts";
import type { Notifier } from "../notify.ts";
import { parseImage } from "./docker.ts";
import { checkReadStatement, firstKeyword } from "./sql.ts";

export type RestoreTest = ReturnType<typeof restoreTestSchema.parse>;
export type RestoreTestInput = Omit<RestoreTest, "anchorAt">;

export const RESULTS_PER_TEST = 20;
export const RUN_TIMEOUT_MS = 30 * 60_000;
export const READY_TIMEOUT_MS = 120_000;
const SANITY_TIMEOUT_MS = 60_000;
const LABEL = "tiphys.restore=1";
const SANITY_KEYWORDS = new Set(["select", "with", "values", "table", "show"]);

export type FailureReason =
  | "noDump"
  | "dumpOutsideRoots"
  | "insufficientDisk"
  | "imageVersionMismatch"
  | "dockerFailed"
  | "notReady"
  | "restoreFailed"
  | "dumpCorrupt"
  | "sanityFailed"
  | "timeout"
  | "shutdown";

export interface SanityFailure {
  index: number;
  reason: "queryFailed" | "notNumeric" | "expectation";
  actual?: number;
  expected: string;
}

export interface RestoreResult {
  id: string;
  testId: string;
  trigger: "manual" | "schedule";
  startedAt: string;
  finishedAt: string;
  ok: boolean;
  reason: FailureReason | null;
  /** Short tool output for restoreFailed / queryFailed (last stderr line, ≤200 chars; never the password). */
  detail: string | null;
  image: string;
  dumpFile: string | null;
  dumpBytes: number | null;
  dumpModifiedAt: string | null;
  /** Number of sanity queries that returned a value. */
  rowsChecked: number;
  failures: SanityFailure[];
  durations: { startMs: number | null; readyMs: number | null; restoreMs: number | null; sanityMs: number | null; totalMs: number };
}

type Runner = typeof execRun;

export interface RestoreOpts {
  store: ConfigStore;
  notifier: Notifier;
  run?: Runner;
  /** The docker binary (tests point it at a fake script). */
  dockerBin?: string;
  now?: () => number;
  timeoutMs?: number;
  readyTimeoutMs?: number;
  readyIntervalMs?: number;
  /** Where free space is measured (default /var/lib/docker, or the dump's directory when that can't be read). */
  diskPath?: string;
  /** Test hook: free bytes for a path (default: statfs). */
  freeBytes?: (path: string) => Promise<number | null>;
}

const dataDirOf = (engine: RestoreTest["engine"], image: string) => {
  if (engine !== "postgres") return "/var/lib/mysql";
  // The postgres 18+ images keep PGDATA below /var/lib/postgresql/<major>/docker.
  const major = Number(/^(\d+)/.exec(parseImage(image).tag ?? "")?.[1]);
  return major >= 18 ? "/var/lib/postgresql" : "/var/lib/postgresql/data";
};
const passwordEnv = { postgres: "POSTGRES_PASSWORD", mysql: "MYSQL_ROOT_PASSWORD", mariadb: "MARIADB_ROOT_PASSWORD" } as const;
const clientBin = (e: RestoreTest["engine"]) => (e === "mariadb" ? "mariadb" : "mysql");
const adminBin = (e: RestoreTest["engine"]) => (e === "mariadb" ? "mariadb-admin" : "mysqladmin");
const majorOf = (tag: string | null) => /^(\d+)/.exec(tag ?? "")?.[1] ?? null;
const sleep = (ms: number) => new Promise<void>((r) => setTimeout(r, ms));
/** The first line mentioning an error (psql prints the offending SQL and a caret after it), else the last line. */
const lastLine = (s: string) => {
  const lines = s.trim().split("\n").filter(Boolean);
  return (lines.find((l) => /error|fatal/i.test(l)) ?? lines.pop())?.slice(0, 200) ?? null;
};

const OPS = {
  ">": (a: number, b: number) => a > b,
  "=": (a: number, b: number) => a === b,
  ">=": (a: number, b: number) => a >= b,
  "<": (a: number, b: number) => a < b,
  "<=": (a: number, b: number) => a <= b,
} as const;

/** Directories dumps may be read from: allowedRoots plus the directories of file backup checks. */
export function dumpRoots(c: AgentConfig): string[] {
  const roots = c.allowedRoots.map(expandHome);
  for (const b of c.backups.checks) if (b.kind === "file" && b.path) roots.push(dirname(expandHome(b.path)));
  return roots;
}

const within = (p: string, root: string) => p === root || p.startsWith(root.endsWith(sep) ? root : root + sep);

async function realOrResolved(p: string): Promise<string> {
  try {
    return await realpath(p);
  } catch {
    return resolve(p);
  }
}

/** Is `path` (a file or directory; symlinks resolved when it exists) inside one of the dump roots? */
export async function insideDumpRoots(c: AgentConfig, path: string): Promise<boolean> {
  const real = await realOrResolved(path);
  const roots = await Promise.all(dumpRoots(c).map(realOrResolved));
  return roots.some((r) => within(real, r));
}

/** Validates a sanity query for the restore test: one read statement starting with SELECT/WITH/VALUES/TABLE/SHOW. */
export function checkSanitySql(sql: string, engine: RestoreTest["engine"]): { ok: true } | { ok: false; keyword: string } {
  const r = checkReadStatement(sql, engine);
  if (!r.ok) return { ok: false, keyword: r.keyword ?? r.code };
  const kw = firstKeyword(sql, engine);
  if (!SANITY_KEYWORDS.has(kw)) return { ok: false, keyword: kw || "?" };
  return { ok: true };
}

interface Active {
  testId: string;
  runId: string;
  abort: AbortController;
  done: Promise<RestoreResult>;
}

export class RestoreService {
  readonly #store: ConfigStore;
  readonly #notifier: Notifier;
  readonly #run: Runner;
  readonly #bin: string;
  readonly #now: () => number;
  readonly #timeoutMs: number;
  readonly #readyTimeoutMs: number;
  readonly #readyIntervalMs: number;
  readonly #diskPath: string;
  readonly #freeFn: ((path: string) => Promise<number | null>) | undefined;
  readonly #file: string;
  readonly #fallbackAnchor: string;
  #results: Record<string, RestoreResult[]> | null = null;
  #chain: Promise<void> = Promise.resolve();
  #active: Active | null = null;
  #containers = new Set<string>();
  #timer: NodeJS.Timeout | null = null;
  #lastMinute: number;

  constructor(o: RestoreOpts) {
    this.#store = o.store;
    this.#notifier = o.notifier;
    this.#run = o.run ?? execRun;
    this.#bin = o.dockerBin ?? "docker";
    this.#now = o.now ?? Date.now;
    this.#timeoutMs = o.timeoutMs ?? RUN_TIMEOUT_MS;
    this.#readyTimeoutMs = o.readyTimeoutMs ?? READY_TIMEOUT_MS;
    this.#readyIntervalMs = o.readyIntervalMs ?? 1000;
    this.#diskPath = o.diskPath ?? "/var/lib/docker";
    this.#freeFn = o.freeBytes;
    this.#file = join(dirname(o.store.path), "db-restore-results.json");
    this.#fallbackAnchor = new Date(this.#now()).toISOString();
    this.#lastMinute = Math.floor(this.#now() / 60_000) - 1;
  }

  // --- tests (CRUD) ---

  list() {
    return this.#store.get().databases.restoreTests;
  }

  get(id: string): RestoreTest {
    const t = this.list().find((x) => x.id === id);
    if (!t) throw new AppError("agent.db.restoreTestNotFound", 404, { id });
    return t;
  }

  async #validate(input: unknown, existingId?: string): Promise<RestoreTest> {
    const p = restoreTestSchema.safeParse(input);
    if (!p.success) throw new AppError("agent.request.invalid", 400, { issues: p.error.issues.map((i) => ({ path: i.path.map(String).join("."), message: i.code })) });
    const t = p.data;
    const cfg = this.#store.get();
    if (!existingId && cfg.databases.restoreTests.some((x) => x.id === t.id)) throw new AppError("agent.db.restoreTestExists", 409, { id: t.id });
    if (t.connectionId) {
      const c = cfg.databases.connections.find((x) => x.id === t.connectionId);
      if (!c) throw new AppError("agent.db.connectionNotFound", 404, { id: t.connectionId });
      const family = (e: string) => (e === "mariadb" ? "mysql" : e);
      if (c.engine === "sqlite" || family(c.engine) !== family(t.engine)) throw new AppError("agent.db.restoreEngineMismatch", 400, { connection: c.engine, engine: t.engine });
    }
    t.sanity.forEach((s, index) => {
      const r = checkSanitySql(s.sql, t.engine);
      if (!r.ok) throw new AppError("agent.db.sanityNotAllowed", 400, { index, keyword: r.keyword });
    });
    const glob = expandHome(t.dumpGlob);
    if (!isAbsolute(glob) || !(await insideDumpRoots(cfg, dirname(glob)))) throw new AppError("agent.db.dumpOutsideRoots", 400, { path: t.dumpGlob });
    return t;
  }

  async create(input: unknown): Promise<RestoreTest> {
    const t = await this.#validate({ ...(input as object), anchorAt: new Date(this.#now()).toISOString() });
    await this.#store.update((c) => {
      c.databases.restoreTests.push(t);
      return c;
    });
    return t;
  }

  async patch(id: string, input: Record<string, unknown>): Promise<RestoreTest> {
    const old = this.get(id);
    const merged: Record<string, unknown> = { ...old, ...input, id, ...(old.anchorAt ? { anchorAt: old.anchorAt } : {}) };
    if (input.connectionId === null) delete merged.connectionId;
    // A changed schedule restarts the interval slots.
    if ("schedule" in input && JSON.stringify(input.schedule) !== JSON.stringify(old.schedule)) merged.anchorAt = new Date(this.#now()).toISOString();
    const t = await this.#validate(merged, id);
    await this.#store.update((c) => {
      c.databases.restoreTests = c.databases.restoreTests.map((x) => (x.id === id ? t : x));
      return c;
    });
    return t;
  }

  async remove(id: string) {
    this.get(id);
    if (this.#active?.testId === id) throw new AppError("agent.db.restoreBusy", 409, { id });
    await this.#store.update((c) => {
      c.databases.restoreTests = c.databases.restoreTests.filter((x) => x.id !== id);
      return c;
    });
    const all = await this.#load();
    delete all[id];
    await this.#save();
  }

  /** The tests with their latest result, next scheduled run and whether one is running now. */
  async view() {
    const all = await this.#load();
    const now = new Date(this.#now());
    return {
      running: this.#active ? { testId: this.#active.testId, runId: this.#active.runId } : null,
      tests: this.list().map((t) => ({
        ...t,
        running: this.#active?.testId === t.id,
        last: all[t.id]?.[0] ?? null,
        nextRunAt: t.enabled && t.schedule ? (nextRun({ when: t.schedule, anchorAt: t.anchorAt ?? this.#fallbackAnchor }, now)?.toISOString() ?? null) : null,
      })),
    };
  }

  async results(id: string): Promise<RestoreResult[]> {
    this.get(id);
    return [...((await this.#load())[id] ?? [])];
  }

  // --- results store ---

  async #load() {
    if (this.#results) return this.#results;
    try {
      this.#results = JSON.parse(await readFile(this.#file, "utf8")) as Record<string, RestoreResult[]>;
    } catch {
      this.#results = {};
    }
    return this.#results;
  }

  #save(): Promise<void> {
    const body = JSON.stringify(this.#results ?? {}, null, 1);
    const next = this.#chain.then(async () => {
      await mkdir(dirname(this.#file), { recursive: true, mode: 0o700 });
      const tmp = `${this.#file}.tmp`;
      await writeFile(tmp, body, { mode: 0o600 });
      await chmod(tmp, 0o600);
      await rename(tmp, this.#file);
    });
    this.#chain = next.catch(() => {});
    return next;
  }

  async #record(r: RestoreResult) {
    const all = await this.#load();
    all[r.testId] = [r, ...(all[r.testId] ?? [])].slice(0, RESULTS_PER_TEST);
    await this.#save().catch((e) => console.error("geri yükleme sonucu yazılamadı:", (e as Error).name));
  }

  // --- running ---

  /** Starts a test in the background (one at a time). Resolves with the run id; await `idle()` for the result. */
  start(testId: string, trigger: "manual" | "schedule"): { runId: string } {
    const test = this.get(testId);
    if (this.#active) throw new AppError("agent.db.restoreBusy", 409, { id: this.#active.testId });
    const runId = `r-${randomBytes(6).toString("hex")}`;
    const abort = new AbortController();
    const done = this.#execute(test, runId, trigger, abort).then(async (result) => {
      await this.#record(result);
      await this.#notify(test, result);
      return result;
    });
    const active: Active = { testId, runId, abort, done };
    this.#active = active;
    void done.catch((e) => console.error("geri yükleme testi:", (e as Error).name)).finally(() => {
      if (this.#active === active) this.#active = null;
    });
    return { runId };
  }

  /** Resolves when the current run (if any) is finished and recorded. */
  async idle() {
    await this.#active?.done.catch(() => {});
    await this.#chain;
  }

  async #notify(test: RestoreTest, r: RestoreResult) {
    const host = this.#store.get().name;
    const reason = r.detail ? `${r.reason}: ${r.detail}` : (r.reason ?? "");
    await this.#notifier
      .send(
        r.ok
          ? { key: "db.restoreTest.ok", params: { host, name: test.name }, link: "tiphys://system/backups" }
          : { key: "db.restoreTest.failed", params: { host, name: test.name, reason }, link: "tiphys://system/backups", priority: "high" },
      )
      .catch(() => {});
  }

  docker(args: string[], timeoutMs: number, env?: NodeJS.ProcessEnv) {
    return this.#run(this.#bin, args, { allowFail: true, timeoutMs: Math.max(1000, timeoutMs), ...(env ? { env } : {}) });
  }

  async #execute(test: RestoreTest, runId: string, trigger: "manual" | "schedule", abort: AbortController): Promise<RestoreResult> {
    const t0 = this.#now();
    const startedAt = new Date(t0).toISOString();
    const res: RestoreResult = {
      id: runId,
      testId: test.id,
      trigger,
      startedAt,
      finishedAt: startedAt,
      ok: false,
      reason: null,
      detail: null,
      image: test.image,
      dumpFile: null,
      dumpBytes: null,
      dumpModifiedAt: null,
      rowsChecked: 0,
      failures: [],
      durations: { startMs: null, readyMs: null, restoreMs: null, sanityMs: null, totalMs: 0 },
    };
    const deadline = t0 + this.#timeoutMs;
    const timer = setTimeout(() => abort.abort("timeout"), this.#timeoutMs);
    const name = `tiphys-restore-${test.id}-${randomBytes(4).toString("hex")}`;
    const fail = (reason: FailureReason, detail: string | null = null) => {
      res.reason = abort.signal.aborted ? (abort.signal.reason === "shutdown" ? "shutdown" : "timeout") : reason;
      res.detail = abort.signal.aborted ? null : detail;
      return res;
    };
    const remaining = () => deadline - this.#now();
    try {
      // 1. The dump.
      const cfg = this.#store.get();
      const dump = await newestFile(test.dumpGlob);
      if (!dump) return fail("noDump");
      const real = await realpath(dump.path).catch(() => dump.path);
      res.dumpFile = dump.path.split("/").pop() ?? null;
      res.dumpBytes = dump.size;
      res.dumpModifiedAt = new Date(dump.mtimeMs).toISOString();
      if (!(await insideDumpRoots(cfg, real))) return fail("dumpOutsideRoots");

      // 2. Free space (twice the dump size).
      const free = await this.#freeBytes(dirname(real));
      if (free !== null && free < 2 * dump.size) return fail("insufficientDisk", `${free}<${2 * dump.size}`);

      // 3. The image must be the source's major version.
      const conn = test.connectionId ? cfg.databases.connections.find((c) => c.id === test.connectionId) : undefined;
      if (conn && "container" in conn.target) {
        const r = await this.docker(["inspect", "--type", "container", "--format", "{{.Config.Image}}", conn.target.container], 20_000);
        const src = majorOf(parseImage(r.stdout.trim()).tag);
        const dst = majorOf(parseImage(test.image).tag);
        if (r.code === 0 && src && dst && src !== dst) return fail("imageVersionMismatch", `${src}!=${dst}`);
      }

      // 4. Start the throwaway container.
      const password = randomBytes(18).toString("base64url");
      const pwName = passwordEnv[test.engine];
      const tStart = this.#now();
      this.#containers.add(name);
      const up = await this.docker(
        ["run", "-d", "--rm", "--network", "none", "--memory", "1g", "--tmpfs", dataDirOf(test.engine, test.image), "--label", LABEL, "-e", pwName, "--name", name, test.image],
        Math.min(remaining(), 10 * 60_000),
        { [pwName]: password },
      ).catch((e) => ({ code: -1, stdout: "", stderr: e instanceof AppError ? e.code : "error" }));
      if (up.code !== 0) return fail("dockerFailed", lastLine(up.stderr));
      res.durations.startMs = this.#now() - tStart;
      if (abort.signal.aborted) return fail("timeout");

      // 5. Wait until the final server (TCP on loopback; the init-time server has no TCP) answers.
      const tReady = this.#now();
      const clientEnv = test.engine === "postgres" ? undefined : { MYSQL_PWD: password };
      const envArgs = test.engine === "postgres" ? [] : ["-e", "MYSQL_PWD"];
      const readyArgv =
        test.engine === "postgres"
          ? ["exec", name, "pg_isready", "-h", "127.0.0.1", "-U", "postgres"]
          : ["exec", ...envArgs, name, adminBin(test.engine), "-h", "127.0.0.1", "-uroot", "--silent", "ping"];
      let ready = false;
      const readyBy = Math.min(deadline, this.#now() + this.#readyTimeoutMs);
      while (!abort.signal.aborted && this.#now() < readyBy) {
        const r = await this.docker(readyArgv, 15_000, clientEnv).catch(() => ({ code: -1 }));
        if (r.code === 0) {
          ready = true;
          break;
        }
        await sleep(this.#readyIntervalMs);
      }
      if (abort.signal.aborted) return fail("timeout");
      if (!ready) return fail("notReady");
      res.durations.readyMs = this.#now() - tReady;

      // 6. Stream the dump into the client.
      const tRestore = this.#now();
      const restoreArgv =
        test.engine === "postgres"
          ? test.format === "custom"
            ? ["exec", "-i", name, "pg_restore", "-U", "postgres", "-d", "postgres", "--no-owner", "--exit-on-error"]
            : ["exec", "-i", name, "psql", "-X", "-q", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres"]
          : ["exec", "-i", ...envArgs, name, clientBin(test.engine), "-h", "127.0.0.1", "-uroot"];
      const streamed = await this.#stream(restoreArgv, real, test.format === "gz", abort.signal, clientEnv);
      res.durations.restoreMs = this.#now() - tRestore;
      if (abort.signal.aborted) return fail("timeout");
      if (streamed.corrupt) return fail("dumpCorrupt", streamed.corrupt);
      if (streamed.code !== 0) return fail("restoreFailed", lastLine(streamed.stderr));

      // 7. Sanity queries (read-only session).
      const tSanity = this.#now();
      for (const [index, s] of test.sanity.entries()) {
        if (abort.signal.aborted) return fail("timeout");
        const argv =
          test.engine === "postgres"
            ? ["exec", "-e", "PGOPTIONS=-c default_transaction_read_only=on", name, "psql", "-X", "-A", "-t", "-v", "ON_ERROR_STOP=1", "-U", "postgres", "-d", "postgres", "-c", s.sql]
            : ["exec", ...envArgs, name, clientBin(test.engine), "-h", "127.0.0.1", "-uroot", "-N", "-B", "-e", `SET SESSION TRANSACTION READ ONLY; ${s.sql}`];
        const expected = `${s.expect.op} ${s.expect.value}`;
        const r = await this.docker(argv, Math.min(SANITY_TIMEOUT_MS, remaining()), clientEnv).catch(() => ({ code: -1, stdout: "", stderr: "" }));
        if (abort.signal.aborted) return fail("timeout");
        if (r.code !== 0) {
          res.failures.push({ index, reason: "queryFailed", expected });
          res.detail ??= lastLine(r.stderr);
          continue;
        }
        const first = r.stdout.trim().split("\n")[0]?.trim() ?? "";
        const actual = first === "" ? NaN : Number(first);
        if (!Number.isFinite(actual)) {
          res.failures.push({ index, reason: "notNumeric", expected });
          continue;
        }
        res.rowsChecked++;
        if (!OPS[s.expect.op](actual, s.expect.value)) res.failures.push({ index, reason: "expectation", actual, expected });
      }
      res.durations.sanityMs = this.#now() - tSanity;
      if (res.failures.length) {
        res.reason = "sanityFailed";
        return res;
      }
      res.ok = true;
      return res;
    } catch (e) {
      return fail("dockerFailed", e instanceof AppError ? e.code : "error");
    } finally {
      clearTimeout(timer);
      if (this.#containers.has(name)) {
        await this.docker(["rm", "-f", name], 60_000).catch(() => {});
        this.#containers.delete(name);
      }
      res.finishedAt = new Date(this.#now()).toISOString();
      res.durations.totalMs = this.#now() - t0;
    }
  }

  async #freeBytes(fallbackDir: string): Promise<number | null> {
    for (const p of [this.#diskPath, fallbackDir]) {
      try {
        if (this.#freeFn) return await this.#freeFn(p);
        const s = await statfs(p);
        return Number(s.bavail) * Number(s.bsize);
      } catch {
        // try the next one
      }
    }
    return null;
  }

  /** `docker exec -i …` with the dump on stdin (gunzipped in Node for gz). Output is discarded, stderr kept (tail). */
  async #stream(argv: string[], file: string, gz: boolean, signal: AbortSignal, env?: NodeJS.ProcessEnv) {
    await stat(file);
    const child = spawn(this.#bin, argv, { stdio: ["pipe", "ignore", "pipe"], env: { ...process.env, ...env }, signal });
    let stderr = "";
    child.stderr!.on("data", (d: Buffer) => (stderr = (stderr + d.toString("utf8")).slice(-4096)));
    const exited = new Promise<number>((r) => {
      child.on("error", () => r(-1));
      child.on("close", (code) => r(code ?? -1));
    });
    const src = createReadStream(file);
    const piped = (gz ? pipeline(src, createGunzip(), child.stdin!) : pipeline(src, child.stdin!)).then(
      () => null,
      (e: NodeJS.ErrnoException) => e,
    );
    const [code, perr] = await Promise.all([exited, piped]);
    // EPIPE: the client quit early (its own error is in stderr / the exit code).
    const corrupt = perr && typeof perr.code === "string" && perr.code.startsWith("Z_") ? perr.code : null;
    return { code, stderr, corrupt };
  }

  // --- scheduling and shutdown ---

  /** Runs tests that are due for the minutes since the last tick (at most the last 2 minutes). */
  tick() {
    const now = Math.floor(this.#now() / 60_000);
    const from = Math.max(this.#lastMinute + 1, now - 2);
    this.#lastMinute = Math.max(this.#lastMinute, now);
    for (let m = from; m <= now; m++) {
      for (const t of this.list()) {
        if (!t.enabled || !t.schedule || this.#active) continue;
        if (dueAt({ when: t.schedule, anchorAt: t.anchorAt ?? this.#fallbackAnchor }, new Date(m * 60_000))) this.start(t.id, "schedule");
      }
    }
  }

  /** Removes containers left by an agent that was killed mid-test. */
  async sweep() {
    const r = await this.docker(["ps", "-aq", "--filter", `label=${LABEL}`], 20_000).catch(() => null);
    const ids = (r?.stdout ?? "").split("\n").map((l) => l.trim()).filter((l) => /^[a-f0-9]{12,64}$/.test(l));
    if (ids.length) await this.docker(["rm", "-f", ...ids], 60_000).catch(() => {});
  }

  begin(intervalMs = 20_000) {
    void this.sweep();
    this.#timer = setInterval(() => {
      try {
        this.tick();
      } catch (e) {
        console.error("geri yükleme zamanlayıcısı:", (e as Error).name);
      }
    }, intervalMs);
    this.#timer.unref();
  }

  /** Agent shutdown: stops the timer, aborts the running test and removes its container. */
  async stop() {
    if (this.#timer) clearInterval(this.#timer);
    this.#timer = null;
    this.#active?.abort.abort("shutdown");
    await this.#active?.done.catch(() => {});
    for (const n of [...this.#containers]) {
      await this.docker(["rm", "-f", n], 30_000).catch(() => {});
      this.#containers.delete(n);
    }
  }
}
