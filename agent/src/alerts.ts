// Yerel uyarılar: disk dolu, çöken (failed) systemd servisleri ve Grafana/Prometheus alarmları.
// Her durum bir kez bildirilir; düzelince "düzeldi" bildirimi gider ve tekrar bildirilebilir hale gelir.
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
  /** Etkin durumlar: "disk:/", "service:user/foo.service", "grafana:AlertName" */
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
        /* systemctl yoksa boş */
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
        /* Grafana'ya ulaşılamadı: bu tur atlanır */
      }
    }
    return out;
  }

  /** Yeni durumlar için bildirim gönderir. İlk turda zaten var olan durumlar sessizce kaydedilir. */
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

export function alertRoutes(app: FastifyInstance, ctx: Ctx) {
  const m = new AlertMonitor(ctx);
  m.start();
  app.addHook("onClose", async () => m.stop());
  app.get("/v1/alerts", async () => ({ active: [...m.active] }));
}
