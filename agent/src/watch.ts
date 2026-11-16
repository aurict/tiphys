// Host watch: regularly polls other hosts' agents (/v1/health). If no response comes for longer than the set time
// it sends a "host.offline" notification, and "host.online" when it comes back (e.g. server → PC).
import type { FastifyInstance } from "fastify";
import type { Ctx } from "./server.ts";

type HostState = { online: boolean | null; lastOk: number | null; since: number; notifiedOffline: boolean };

export class Watcher {
  readonly states = new Map<string, HostState>();
  #timers: NodeJS.Timeout[] = [];
  #ctx: Ctx;
  #fetch: typeof fetch;

  constructor(ctx: Ctx, fetchFn: typeof fetch = fetch) {
    this.#ctx = ctx;
    this.#fetch = fetchFn;
  }

  start(runTimers = true) {
    for (const h of this.#ctx.store.get().watch.hosts) {
      this.states.set(h.hostId, { online: null, lastOk: null, since: Date.now(), notifiedOffline: false });
      if (!runTimers) continue;
      const tick = () => void this.check(h.hostId);
      tick();
      const t = setInterval(tick, h.intervalSeconds * 1000);
      t.unref();
      this.#timers.push(t);
    }
  }

  stop() {
    this.#timers.forEach(clearInterval);
  }

  async check(hostId: string, now = Date.now()) {
    const h = this.#ctx.store.get().watch.hosts.find((x) => x.hostId === hostId);
    const s = this.states.get(hostId);
    if (!h || !s) return;
    let ok = false;
    try {
      const res = await this.#fetch(h.url, { signal: AbortSignal.timeout(10_000) });
      ok = res.ok;
      await res.body?.cancel();
    } catch {
      ok = false;
    }
    if (ok) {
      const wasDown = s.notifiedOffline;
      s.lastOk = now;
      if (s.online !== true) s.since = now;
      s.online = true;
      s.notifiedOffline = false;
      if (wasDown) await this.#ctx.notifier.send({ key: "host.online", params: { host: hostId }, link: "tiphys://system" });
      return;
    }
    if (s.online !== false) s.since = now;
    s.online = false;
    const downFor = now - (s.lastOk ?? s.since);
    if (!s.notifiedOffline && downFor >= h.offlineAfterSeconds * 1000) {
      s.notifiedOffline = true;
      await this.#ctx.notifier.send({
        key: "host.offline",
        params: { host: hostId, minutes: Math.round(downFor / 60000) },
        link: "tiphys://system",
        priority: "high",
      });
    }
  }
}

export function watchRoutes(app: FastifyInstance, ctx: Ctx) {
  const w = new Watcher(ctx);
  w.start();
  app.addHook("onClose", async () => w.stop());
  app.get("/v1/watch", async () => ({
    hosts: [...w.states.entries()].map(([hostId, s]) => ({
      hostId,
      online: s.online,
      lastOk: s.lastOk ? new Date(s.lastOk).toISOString() : null,
      since: new Date(s.since).toISOString(),
    })),
  }));
}
