// Local alerts: disk full, crashed (failed) systemd services and Grafana/Prometheus alerts.
// Each condition is reported once; when it clears a "resolved" notification goes out and it can be reported again.
// Docker events (die/oom/restart) are also watched: unexpected crashes and out-of-memory are notified,
// restarts are only written to the event stream.
import { spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import si from "systeminformation";
import type { FastifyInstance } from "fastify";
import { run } from "./exec.ts";
import type { Ctx } from "./server.ts";

export interface AlertInputs {
  disks: Array<{ mount: string; percent: number }>;
  failed: string[];
  grafana: Array<{ name: string; state: string; severity: string | null }>;
}

type Kind = "disk" | "service" | "grafana";

export class AlertMonitor {
  /** Active conditions: "disk:/", "service:user/foo.service", "grafana:AlertName" */
  readonly active = new Set<string>();
  #first = true;
  #timer: NodeJS.Timeout | null = null;
  #ctx: Ctx;
  #fetch: typeof fetch;

  constructor(ctx: Ctx, fetchFn: typeof fetch = fetch) {
    this.#ctx = ctx;
    this.#fetch = fetchFn;
  }

  start() {
    const every = this.#ctx.store.get().alerts.intervalSeconds * 1000;
    const tick = () => void this.collect().then((i) => this.evaluate(i)).catch(() => {});
    tick();
    this.#timer = setInterval(tick, every);
    this.#timer.unref();
  }

  stop() {
    if (this.#timer) clearInterval(this.#timer);
  }

  async collect(): Promise<AlertInputs> {
    const cfg = this.#ctx.store.get().alerts;
    const [fs, failed, grafana] = await Promise.all([
      si.fsSize().catch(() => []),
      cfg.failedServices ? this.failedUnits() : Promise.resolve([]),
      cfg.grafana ? this.grafanaAlerts(cfg.grafana) : Promise.resolve([]),
    ]);
    return {
      disks: fs
        .filter((d) => d.size > 0 && !d.mount.startsWith("/snap") && !d.mount.startsWith("/boot"))
        .map((d) => ({ mount: d.mount, percent: Math.round((d.used / d.size) * 100) })),
      failed,
      grafana,
    };
  }

  async failedUnits(): Promise<string[]> {
    const out: string[] = [];
    for (const scope of ["user", "system"] as const) {
      const r = await run("systemctl", [...(scope === "user" ? ["--user"] : []), "list-units", "--state=failed", "--output=json", "--no-pager"], {
        allowFail: true,
      });
      try {
        for (const u of JSON.parse(r.stdout || "[]") as Array<{ unit: string }>) out.push(`${scope}/${u.unit}`);
      } catch {
        /* empty if there is no systemctl */
      }
    }
    return out;
  }

  async grafanaAlerts(g: { url: string; token: string; datasourceUids: string[] }) {
    const base = g.url.replace(/\/$/, "");
    const paths = ["/api/prometheus/grafana/api/v1/alerts", ...g.datasourceUids.map((u) => `/api/datasources/uid/${encodeURIComponent(u)}/resources/api/v1/alerts`)];
    const out: AlertInputs["grafana"] = [];
    for (const p of paths) {
      try {
        const res = await this.#fetch(base + p, { headers: { Authorization: `Bearer ${g.token}` }, signal: AbortSignal.timeout(15000) });
        if (!res.ok) continue;
        const j = (await res.json()) as { data?: { alerts?: Array<{ labels?: Record<string, string>; state?: string }> } };
        for (const a of j.data?.alerts ?? []) {
          const state = a.state === "alerting" ? "firing" : (a.state ?? "");
          if (state !== "firing") continue;
          out.push({ name: a.labels?.alertname ?? "?", state, severity: a.labels?.severity ?? null });
        }
      } catch {
        /* Grafana unreachable: this round is skipped */
      }
    }
    return out;
  }

  /** Sends notifications for new conditions. Conditions already present on the first round are recorded silently. */
  async evaluate(i: AlertInputs) {
    const cfg = this.#ctx.store.get().alerts;
    const now = new Map<string, { kind: Kind; params: Record<string, string | number> }>();
    for (const d of i.disks) if (d.percent >= cfg.diskFullPercent) now.set(`disk:${d.mount}`, { kind: "disk", params: { mount: d.mount, percent: d.percent } });
    for (const u of i.failed) now.set(`service:${u}`, { kind: "service", params: { unit: u.slice(u.indexOf("/") + 1), scope: u.slice(0, u.indexOf("/")) } });
    for (const a of i.grafana) now.set(`grafana:${a.name}`, { kind: "grafana", params: { name: a.name, severity: a.severity ?? "" } });

    const host = this.#ctx.store.get().name;
    const sends: Array<Promise<number>> = [];
    for (const [key, v] of now) {
      if (this.active.has(key)) continue;
      this.active.add(key);
      if (this.#first) continue;
      const k = v.kind === "disk" ? "disk.full" : v.kind === "service" ? "service.failed" : "grafana.alert";
      sends.push(this.#ctx.notifier.send({ key: k, params: { host, ...v.params }, link: v.kind === "grafana" ? "tiphys://monitor/grafana" : "tiphys://system", priority: "high" }));
    }
    for (const key of [...this.active]) {
      if (now.has(key)) continue;
      this.active.delete(key);
      const [kind, ...rest] = key.split(":");
      const name = rest.join(":");
      const k = kind === "disk" ? "disk.ok" : kind === "service" ? "service.recovered" : "grafana.resolved";
      sends.push(this.#ctx.notifier.send({ key: k, params: { host, name: kind === "service" ? name.slice(name.indexOf("/") + 1) : name } }));
    }
    this.#first = false;
    await Promise.all(sends);
    return [...this.active];
  }
}

export interface DockerEvent {
  action: string;
  name: string;
  exitCode: number | null;
  /** Event time, ms */
  at: number;
  /** For "health_status": the new status ("healthy", "unhealthy", "starting"). */
  health?: string;
  /** Compose labels of the container, if any. */
  project?: string;
  service?: string;
  workingDir?: string;
}

/** A `docker events --format '{{json .}}'` line → event; null if it isn't a container event. */
export function parseDockerEvent(line: string): DockerEvent | null {
  let j: { Type?: string; Action?: string; status?: string; Actor?: { Attributes?: Record<string, string> }; timeNano?: number; time?: number };
  try {
    j = JSON.parse(line);
  } catch {
    return null;
  }
  if (j.Type !== undefined && j.Type !== "container") return null;
  // Some actions carry a detail after a colon: "health_status: unhealthy", "exec_start: sh -c …".
  const raw = j.Action ?? j.status ?? "";
  const colon = raw.indexOf(":");
  const action = colon < 0 ? raw : raw.slice(0, colon);
  const attrs = j.Actor?.Attributes ?? {};
  const name = attrs.name;
  if (!action || !name) return null;
  const code = attrs.exitCode;
  const project = attrs["com.docker.compose.project"];
  const service = attrs["com.docker.compose.service"];
  const workingDir = attrs["com.docker.compose.project.working_dir"];
  return {
    action,
    name,
    exitCode: code === undefined || code === "" ? null : Number(code),
    at: j.timeNano ? Math.floor(j.timeNano / 1e6) : j.time ? j.time * 1000 : Date.now(),
    ...(action === "health_status" && colon >= 0 ? { health: raw.slice(colon + 1).trim() } : {}),
    ...(project ? { project } : {}),
    ...(service ? { service } : {}),
    ...(workingDir ? { workingDir } : {}),
  };
}

/** A die within this time after kill/stop counts as "expected" (docker stop, compose down/up, restart). */
const EXPECTED_WINDOW_MS = 60_000;
/** No repeat record/notification for the same container + kind within this time (crash loop noise). */
export const DOCKER_DEBOUNCE_MS = 15 * 60_000;
/** Restart loop: at least this many unexpected exits of one container within RESTART_LOOP_WINDOW_MS. */
export const RESTART_LOOP_COUNT = 3;
export const RESTART_LOOP_WINDOW_MS = 10 * 60_000;

/**
 * Interprets Docker events: die (unexpected: exit code ≠ 0 and no recent kill/stop) and oom give a notification
 * + event; restart only an event. Once per container + kind within DOCKER_DEBOUNCE_MS.
 * With the "incidents" feature on, also: health_status unhealthy → docker.unhealthy, and ≥3 unexpected exits
 * (any exit code) within 10 min → docker.restartLoop.
 */
export class DockerEventWatcher {
  #ctx: Ctx;
  #lastKill = new Map<string, number>();
  #lastSeen = new Map<string, number>();
  #exits = new Map<string, number[]>();
  #child: ChildProcess | null = null;
  #retry: NodeJS.Timeout | null = null;
  #stopped = false;

  constructor(ctx: Ctx) {
    this.#ctx = ctx;
  }

  async handle(e: DockerEvent): Promise<void> {
    if (e.action === "kill" || e.action === "stop") {
      this.#lastKill.set(e.name, e.at);
      return;
    }
    const incidents = this.#ctx.store.get().features.incidents;
    const sends: Array<Promise<unknown>> = [];
    let key: string;
    if (e.action === "oom") key = "docker.oom";
    else if (e.action === "restart") key = "docker.restarted";
    else if (e.action === "health_status") {
      if (!incidents || e.health !== "unhealthy") return;
      key = "docker.unhealthy";
    } else if (e.action === "die") {
      const killed = e.at - (this.#lastKill.get(e.name) ?? -Infinity) < EXPECTED_WINDOW_MS;
      if (killed) return; // stopped on purpose
      if (incidents) sends.push(this.#restartLoop(e));
      if (e.exitCode === 0) return void (await Promise.all(sends)); // exited cleanly
      key = "docker.died";
    } else return;
    sends.push(this.#notify(key, e, e.exitCode !== null && key === "docker.died" ? { code: e.exitCode } : {}));
    await Promise.all(sends);
  }

  /** Notifies (or for docker.restarted only records) once per container + kind within DOCKER_DEBOUNCE_MS. */
  async #notify(key: string, e: DockerEvent, extra: Record<string, string | number>): Promise<void> {
    const dk = `${key}|${e.name}`;
    if (e.at - (this.#lastSeen.get(dk) ?? -Infinity) < DOCKER_DEBOUNCE_MS) return;
    this.#lastSeen.set(dk, e.at);
    const host = this.#ctx.store.get().name;
    const params: Record<string, string | number> = { host, container: e.name, ...extra };
    if (key === "docker.restarted") {
      await this.#ctx.notifier.events?.record({ key, params, link: "tiphys://system" });
      return;
    }
    const context = { ...(e.project ? { project: e.project } : {}), ...(e.service ? { service: e.service } : {}), ...(e.workingDir ? { workingDir: e.workingDir } : {}) };
    await this.#ctx.notifier.send({ key, params, link: "tiphys://system", priority: "high", context });
  }

  async #restartLoop(e: DockerEvent): Promise<void> {
    const recent = [...(this.#exits.get(e.name) ?? []), e.at].filter((t) => e.at - t < RESTART_LOOP_WINDOW_MS);
    this.#exits.set(e.name, recent);
    if (recent.length >= RESTART_LOOP_COUNT) await this.#notify("docker.restartLoop", e, { count: recent.length });
  }

  /** Starts the `docker events` process; if it ends (Docker restarted, missing) retries after 60 s. */
  start() {
    if (this.#stopped) return;
    const child = spawn(
      "docker",
      ["events", "--format", "{{json .}}", "--filter", "type=container", ...["die", "oom", "restart", "kill", "stop", "health_status"].flatMap((a) => ["--filter", `event=${a}`])],
      { stdio: ["ignore", "pipe", "ignore"] },
    );
    this.#child = child;
    child.on("error", () => {}); // no docker: retried via exit/close
    createInterface({ input: child.stdout! }).on("line", (line) => {
      const e = parseDockerEvent(line);
      if (e) void this.handle(e).catch(() => {});
    });
    child.on("close", () => {
      this.#child = null;
      if (this.#stopped) return;
      this.#retry = setTimeout(() => this.start(), 60_000);
      this.#retry.unref();
    });
  }

  stop() {
    this.#stopped = true;
    if (this.#retry) clearTimeout(this.#retry);
    this.#child?.kill();
  }
}

export function alertRoutes(app: FastifyInstance, ctx: Ctx) {
  const m = new AlertMonitor(ctx);
  m.start();
  app.addHook("onClose", async () => m.stop());
  if (ctx.store.get().features.docker) {
    const d = new DockerEventWatcher(ctx);
    d.start();
    app.addHook("onClose", async () => d.stop());
  }
  app.get("/v1/alerts", async () => ({ active: [...m.active] }));
}
