// Uptime Kuma bridge: Uptime Kuma has no official REST API (its UI uses Socket.IO). The agent stays connected,
// caches events and serves plain REST to the phone. The username/password live only in the agent.
import type { FastifyInstance } from "fastify";
import { io, type Socket } from "socket.io-client";
import { z } from "zod";
import type { AgentConfig } from "../config.ts";
import { AppError, notFound } from "../errors.ts";
import type { Notifier } from "../notify.ts";
import type { Ctx } from "../server.ts";

export interface Beat {
  status: number; // 0 down, 1 up, 2 pending, 3 maintenance
  time: string;
  msg: string;
  ping: number | null;
  important?: boolean;
  duration?: number;
}

type Monitor = Record<string, unknown> & { id: number; name: string; url?: string; type: string; active: boolean | number; interval: number };

const MAX_BEATS = 300;

export class UptimeBridge {
  #getConfig: () => AgentConfig;
  #notifier: Notifier;
  #socket: Socket | null = null;
  #loggedIn = false;
  #lastError: string | null = null;
  monitors = new Map<number, Monitor>();
  beats = new Map<number, Beat[]>();
  important = new Map<number, Beat[]>();
  uptime = new Map<number, { h24: number | null; d30: number | null }>();
  avgPing = new Map<number, number | null>();
  cert = new Map<number, { valid: boolean; daysRemaining: number | null; issuer: string | null }>();
  notifications: Array<Record<string, unknown>> = [];
  maintenances = new Map<number, Record<string, unknown> & { id: number; title: string }>();
  /** Last known down (0) / up (1) state per monitor; pending and maintenance beats don't change it. */
  #lastStatus = new Map<number, number>();

  constructor(getConfig: () => AgentConfig, notifier: Notifier) {
    this.#getConfig = getConfig;
    this.#notifier = notifier;
  }

  get state() {
    return { connected: this.#socket?.connected ?? false, loggedIn: this.#loggedIn, error: this.#lastError };
  }

  start() {
    const cfg = this.#getConfig().uptimeKuma;
    if (!cfg) {
      this.#lastError = "notConfigured";
      return;
    }
    const s = io(cfg.url, { transports: ["websocket"], reconnection: true, reconnectionDelayMax: 30_000 });
    this.#socket = s;
    s.on("connect", () => {
      this.#lastError = null;
      s.emit("login", { username: cfg.username, password: cfg.password, token: "" }, (res: { ok: boolean; msg?: string }) => {
        this.#loggedIn = res.ok;
        if (!res.ok) this.#lastError = res.msg ?? "loginFailed";
        else setTimeout(() => this.#prefill(), 1500);
      });
    });
    s.on("disconnect", () => (this.#loggedIn = false));
    s.on("connect_error", (e) => (this.#lastError = e.message));
    s.on("monitorList", (list: Record<string, Monitor>) => {
      this.monitors = new Map(Object.values(list).map((m) => [m.id, m]));
    });
    s.on("updateMonitorIntoList", (list: Record<string, Monitor>) => {
      for (const m of Object.values(list)) this.monitors.set(m.id, m);
    });
    s.on("deleteMonitorFromList", (id: number) => this.monitors.delete(id));
    s.on("maintenanceList", (list: Record<string, Record<string, unknown> & { id: number; title: string }>) => {
      this.maintenances = new Map(Object.values(list).map((m) => [m.id, m]));
    });
    s.on("notificationList", (list: Array<Record<string, unknown>>) => (this.notifications = list));
    s.on("heartbeatList", (id: number, list: Beat[], overwrite: boolean) => {
      const cur = overwrite ? [] : (this.beats.get(id) ?? []);
      this.beats.set(id, [...cur, ...list].slice(-MAX_BEATS));
      this.#seed(id, [...list].reverse());
    });
    s.on("importantHeartbeatList", (id: number, list: Beat[], overwrite: boolean) => {
      const cur = overwrite ? [] : (this.important.get(id) ?? []);
      this.important.set(id, [...list, ...cur].slice(0, 200));
      this.#seed(id, list);
    });
    s.on("heartbeat", (b: Beat & { monitorID: number }) => {
      const arr = this.beats.get(b.monitorID) ?? [];
      arr.push(b);
      if (arr.length > MAX_BEATS) arr.splice(0, arr.length - MAX_BEATS);
      this.beats.set(b.monitorID, arr);
      if (b.important) {
        this.important.set(b.monitorID, [b, ...(this.important.get(b.monitorID) ?? [])].slice(0, 200));
      }
      this.onBeat(b.monitorID, b);
    });
    s.on("uptime", (id: number, period: number | string, value: number) => {
      const u = this.uptime.get(id) ?? { h24: null, d30: null };
      if (period === 24) u.h24 = value;
      if (period === 720) u.d30 = value;
      this.uptime.set(id, u);
    });
    s.on("avgPing", (id: number, v: number | null) => this.avgPing.set(id, v));
    s.on("certInfo", (id: number, json: string) => {
      try {
        const info = JSON.parse(json) as { valid?: boolean; certInfo?: { daysRemaining?: number; issuerCertificate?: { subject?: { O?: string } } } };
        this.cert.set(id, {
          valid: info.valid ?? false,
          daysRemaining: info.certInfo?.daysRemaining ?? null,
          issuer: info.certInfo?.issuerCertificate?.subject?.O ?? null,
        });
      } catch {
        /* malformed certificate info is ignored */
      }
    });
  }

  /** Cache fills (history lists, newest first here) only set the state, silently, when it isn't known yet. */
  #seed(id: number, newestFirst: Beat[]) {
    if (this.#lastStatus.has(id)) return;
    const b = newestFirst.find((x) => x.status === 0 || x.status === 1);
    if (b) this.#lastStatus.set(id, b.status);
  }

  /**
   * A live heartbeat. An important beat that flips the known state 0↔1 sends uptime.down / uptime.up (only with the
   * "incidents" feature on: Uptime Kuma usually notifies on its own). The first state of a monitor is recorded silently.
   */
  onBeat(id: number, b: Beat) {
    if (b.status !== 0 && b.status !== 1) return;
    const prev = this.#lastStatus.get(id);
    this.#lastStatus.set(id, b.status);
    if (prev === undefined || prev === b.status || !b.important) return;
    const c = this.#getConfig();
    if (!c.features.incidents) return;
    const down = b.status === 0;
    void this.#notifier
      .send({
        key: down ? "uptime.down" : "uptime.up",
        params: { host: c.name, monitor: this.monitors.get(id)?.name ?? String(id), monitorId: id },
        link: "tiphys://monitor/uptime",
        ...(down ? { priority: "high" as const } : {}),
      })
      .catch(() => {});
  }

  /** On a new connection fetches the last 2 hours of heartbeats (so the mini charts in the list fill right away). */
  #prefill() {
    for (const id of this.monitors.keys()) {
      if ((this.beats.get(id)?.length ?? 0) > 5) continue;
      this.loadBeats(id, 2)
        .then((b) => this.beats.set(id, [...(b as Beat[]), ...(this.beats.get(id) ?? [])].slice(-MAX_BEATS)))
        .catch(() => {});
    }
  }

  stop() {
    this.#socket?.close();
  }

  #emit<T = { ok: boolean; msg?: string }>(event: string, ...args: unknown[]): Promise<T> {
    const s = this.#socket;
    if (!s?.connected || !this.#loggedIn) throw new AppError("agent.uptime.notConnected", 503, { error: this.#lastError });
    return new Promise<T>((resolve, reject) => {
      const t = setTimeout(() => reject(new AppError("agent.uptime.timeout", 504)), 20_000);
      s.emit(event, ...args, (res: T) => {
        clearTimeout(t);
        resolve(res);
      });
    });
  }

  #check(res: { ok: boolean; msg?: string }) {
    if (!res.ok) throw new AppError("agent.uptime.rejected", 400, { message: res.msg ?? "" });
  }

  summary(m: Monitor) {
    const beats = this.beats.get(m.id) ?? [];
    const last = beats.at(-1);
    return {
      id: m.id,
      name: m.name,
      url: m.url ?? null,
      type: m.type,
      active: m.active === true || m.active === 1,
      interval: m.interval,
      status: !(m.active === true || m.active === 1) ? "paused" : last == null ? "pending" : (["down", "up", "pending", "maintenance"][last.status] ?? "pending"),
      ping: last?.ping ?? null,
      avgPing: this.avgPing.get(m.id) ?? null,
      uptime24h: this.uptime.get(m.id)?.h24 ?? null,
      uptime30d: this.uptime.get(m.id)?.d30 ?? null,
      cert: this.cert.get(m.id) ?? null,
      recent: beats.slice(-40).map((b) => b.status),
    };
  }

  list() {
    return [...this.monitors.values()].sort((a, b) => a.name.localeCompare(b.name, "tr")).map((m) => this.summary(m));
  }

  detail(id: number) {
    const m = this.monitors.get(id);
    if (!m) throw notFound("uptime.monitor", { id });
    return {
      ...this.summary(m),
      maxretries: m.maxretries ?? 0,
      retryInterval: m.retryInterval ?? m.interval,
      timeout: m.timeout ?? null,
      expiryNotification: m.expiryNotification ?? false,
      beats: (this.beats.get(id) ?? []).map((b) => ({ status: b.status, time: b.time, ping: b.ping, msg: b.msg })),
      incidents: (this.important.get(id) ?? []).map((b) => ({ status: b.status, time: b.time, msg: b.msg, duration: b.duration ?? null })),
    };
  }

  async add(input: MonitorInput) {
    const notificationIDList = Object.fromEntries(this.notifications.filter((n) => n.isDefault === true || n.isDefault === 1).map((n) => [String(n.id), true]));
    const res = await this.#emit<{ ok: boolean; msg?: string; monitorID: number }>("add", {
      ...monitorDefaults(input),
      notificationIDList,
    });
    this.#check(res);
    return res.monitorID;
  }

  async edit(id: number, input: Partial<MonitorInput>) {
    const cur = this.monitors.get(id);
    if (!cur) throw notFound("uptime.monitor", { id });
    // editMonitor expects the whole object: the existing record + the changed fields.
    const merged = { ...cur, ...monitorPatch(input) } as Record<string, unknown>;
    if (typeof merged.accepted_statuscodes_json === "string" && !merged.accepted_statuscodes) {
      merged.accepted_statuscodes = JSON.parse(merged.accepted_statuscodes_json as string);
    }
    this.#check(await this.#emit("editMonitor", merged));
  }

  async remove(id: number) {
    this.#check(await this.#emit("deleteMonitor", id, false));
    this.monitors.delete(id);
  }

  async pause(id: number, paused: boolean) {
    this.#check(await this.#emit(paused ? "pauseMonitor" : "resumeMonitor", id));
  }

  /** One-off maintenance window: downtime of the selected sites isn't notified during it. Times are UTC. */
  async addMaintenance(m: MaintenanceInput): Promise<number> {
    const fmt = (iso: string) => new Date(iso).toISOString().slice(0, 19).replace("T", " ");
    const res = await this.#emit<{ ok: boolean; msg?: string; maintenanceID?: number }>("addMaintenance", {
      title: m.title,
      description: "",
      strategy: "single",
      intervalDay: 1,
      timezoneOption: "UTC",
      active: true,
      dateRange: [fmt(m.start), fmt(m.end)],
      timeRange: [{ hours: 0, minutes: 0 }, { hours: 0, minutes: 0 }],
      weekdays: [],
      daysOfMonth: [],
      cron: "",
      durationMinutes: 0,
    });
    this.#check(res);
    const id = res.maintenanceID!;
    this.#check(await this.#emit("addMonitorMaintenance", id, m.monitorIds.map((x) => ({ id: x }))));
    return id;
  }

  async listMaintenances() {
    this.#check(await this.#emit("getMaintenanceList"));
    const out = [];
    for (const m of this.maintenances.values()) {
      const r = await this.#emit<{ ok: boolean; monitors?: Array<{ id: number }> }>("getMonitorMaintenance", m.id);
      const slot = (m.timeslotList as Array<{ startDate?: string; endDate?: string }> | undefined)?.[0];
      out.push({
        id: m.id,
        title: m.title,
        status: (m.status as string) ?? "unknown", // scheduled | under-maintenance | ended | inactive
        active: Boolean(m.active),
        strategy: m.strategy as string,
        start: slot?.startDate ?? null,
        end: slot?.endDate ?? null,
        monitorIds: (r.monitors ?? []).map((x) => x.id),
      });
    }
    return out;
  }

  async deleteMaintenance(id: number) {
    this.#check(await this.#emit("deleteMaintenance", id));
    this.maintenances.delete(id);
  }

  async loadBeats(id: number, hours: number) {
    const res = await this.#emit<{ ok: boolean; msg?: string; data: Beat[] }>("getMonitorBeats", id, hours);
    this.#check(res);
    return res.data.map((b) => ({ status: b.status, time: b.time, ping: b.ping, msg: b.msg ?? "" }));
  }
}

export const monitorInputSchema = z.strictObject({
  name: z.string().min(1).max(150),
  type: z.enum(["http", "keyword", "ping", "port"]).default("http"),
  url: z.string().max(2000).optional(),
  hostname: z.string().max(253).optional(),
  port: z.number().int().min(1).max(65535).optional(),
  keyword: z.string().max(500).optional(),
  interval: z.number().int().min(20).max(86400).default(60),
  alertAfterSeconds: z.number().int().min(0).max(86400).default(120),
  timeout: z.number().int().min(1).max(120).default(30),
  acceptedStatusCodes: z.array(z.string().regex(/^\d{3}(-\d{3})?$/)).default(["200-299"]),
  certExpiry: z.boolean().default(true),
});
export type MonitorInput = z.infer<typeof monitorInputSchema>;

export const maintenanceInputSchema = z
  .strictObject({
    title: z.string().min(1).max(150),
    monitorIds: z.array(z.number().int().positive()).min(1),
    start: z.iso.datetime({ offset: true }),
    end: z.iso.datetime({ offset: true }),
  })
  .refine((m) => Date.parse(m.end) > Date.parse(m.start), { message: "end must be after start", path: ["end"] });
export type MaintenanceInput = z.infer<typeof maintenanceInputSchema>;

/** "alert after x seconds down" → retry count (each retry is one interval). */
function retries(i: { interval: number; alertAfterSeconds: number }) {
  return Math.max(0, Math.round(i.alertAfterSeconds / i.interval) - 1);
}

function monitorPatch(i: Partial<MonitorInput>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  if (i.name !== undefined) out.name = i.name;
  if (i.type !== undefined) out.type = i.type;
  if (i.url !== undefined) out.url = i.url;
  if (i.hostname !== undefined) out.hostname = i.hostname;
  if (i.port !== undefined) out.port = i.port;
  if (i.keyword !== undefined) out.keyword = i.keyword;
  if (i.interval !== undefined) {
    out.interval = i.interval;
    out.retryInterval = i.interval;
  }
  if (i.interval !== undefined && i.alertAfterSeconds !== undefined) out.maxretries = retries({ interval: i.interval, alertAfterSeconds: i.alertAfterSeconds });
  if (i.timeout !== undefined) out.timeout = i.timeout;
  if (i.acceptedStatusCodes !== undefined) out.accepted_statuscodes = i.acceptedStatusCodes;
  if (i.certExpiry !== undefined) out.expiryNotification = i.certExpiry;
  return out;
}

function monitorDefaults(i: MonitorInput): Record<string, unknown> {
  return {
    type: i.type,
    name: i.name,
    url: i.url ?? "https://",
    hostname: i.hostname ?? null,
    port: i.port ?? null,
    keyword: i.keyword ?? null,
    method: "GET",
    interval: i.interval,
    retryInterval: i.interval,
    resendInterval: 0,
    maxretries: retries(i),
    timeout: i.timeout,
    accepted_statuscodes: i.acceptedStatusCodes,
    maxredirects: 10,
    expiryNotification: i.certExpiry,
    ignoreTls: false,
    upsideDown: false,
    kafkaProducerBrokers: [],
    kafkaProducerSaslOptions: { mechanism: "None" },
    rabbitmqNodes: [],
    conditions: [],
    active: true,
  };
}

export function uptimeRoutes(app: FastifyInstance, ctx: Ctx) {
  const bridge = new UptimeBridge(() => ctx.store.get(), ctx.notifier);
  ctx.uptime = bridge;
  bridge.start();
  app.addHook("onClose", async () => bridge.stop());
  const idParam = (req: { params: unknown }) => z.coerce.number().int().positive().parse((req.params as { id: string }).id);

  app.get("/v1/uptime/state", async () => bridge.state);
  app.get("/v1/uptime/monitors", async () => ({ state: bridge.state, monitors: bridge.list() }));
  app.get("/v1/uptime/monitors/:id", async (req) => bridge.detail(idParam(req)));
  app.get("/v1/uptime/monitors/:id/beats", async (req) => {
    const hours = z.coerce.number().int().min(1).max(24 * 90).default(24).parse((req.query as { hours?: string }).hours);
    return { beats: await bridge.loadBeats(idParam(req), hours) };
  });
  app.post("/v1/uptime/monitors", async (req) => ({ id: await bridge.add(monitorInputSchema.parse(req.body)) }));
  app.patch("/v1/uptime/monitors/:id", async (req) => {
    await bridge.edit(idParam(req), monitorInputSchema.partial().parse(req.body));
    return { ok: true };
  });
  app.delete("/v1/uptime/monitors/:id", async (req) => {
    await bridge.remove(idParam(req));
    return { ok: true };
  });
  app.post("/v1/uptime/monitors/:id/pause", async (req) => {
    await bridge.pause(idParam(req), true);
    return { ok: true };
  });
  app.post("/v1/uptime/monitors/:id/resume", async (req) => {
    await bridge.pause(idParam(req), false);
    return { ok: true };
  });
  app.get("/v1/uptime/maintenance", async () => ({ maintenances: await bridge.listMaintenances() }));
  app.post("/v1/uptime/maintenance", async (req) => ({ id: await bridge.addMaintenance(maintenanceInputSchema.parse(req.body)) }));
  app.delete("/v1/uptime/maintenance/:id", async (req) => {
    await bridge.deleteMaintenance(idParam(req));
    return { ok: true };
  });
}
