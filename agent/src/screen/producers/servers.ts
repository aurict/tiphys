// `servers` topic (PLAN.md §20 A-2): the uptime bridge's monitors (up/down and since when) and the number of open
// incidents, sent when they change. Both modules already hold this state in memory (Uptime Kuma pushes beats to the
// bridge), so the producer only compares it every 5 s: no I/O, no process.
import type { Rec, StateProducer } from "./common.ts";

export interface ServersState {
  /** null = the uptime bridge isn't loaded (feature off). */
  monitors: Array<{ name: string; status: string; since: string | null }> | null;
  connected: boolean;
  /** null = the incidents feature is off. */
  incidents: number | null;
}

/** State → the servers message: paused monitors left out; `available` = there is something to report about. */
export function serversMessage(s: ServersState): Rec {
  const hosts = (s.monitors ?? []).filter((m) => m.status !== "paused").map((m) => ({ name: m.name.slice(0, 80), up: m.status !== "down", since: m.since }));
  return { type: "servers", available: (s.monitors !== null && s.connected) || s.incidents !== null, hosts, incidents: s.incidents ?? 0 };
}

export class ServersProducer implements StateProducer {
  readonly #read: () => ServersState;
  readonly #intervalMs: number;
  #emit: ((m: Rec) => void) | null = null;
  #timer: NodeJS.Timeout | null = null;
  #last: string | null = null;

  constructor(read: () => ServersState, o: { intervalMs?: number } = {}) {
    this.#read = read;
    this.#intervalMs = o.intervalMs ?? 5000;
  }

  get active() {
    return this.#timer !== null;
  }

  start(emit: (m: Rec) => void) {
    if (this.#emit) return;
    this.#emit = emit;
    this.#tick();
    this.#timer = setInterval(() => this.#tick(), this.#intervalMs);
    this.#timer.unref?.();
  }

  async stop() {
    this.#emit = null;
    if (this.#timer) clearInterval(this.#timer);
    this.#timer = null;
    this.#last = null;
  }

  #tick() {
    let msg: Rec;
    try {
      msg = serversMessage(this.#read());
    } catch {
      return;
    }
    const s = JSON.stringify(msg);
    if (s === this.#last || !this.#emit) return;
    this.#last = s;
    this.#emit(msg);
  }
}
