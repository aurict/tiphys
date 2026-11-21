// Is the kiosk on screen? (PLAN.md §20 "Görünmüyorsa durur"). Firefox keeps drawing at ~20 % of a core in a hidden
// special workspace (W0), so the display agent tells the page to pause. Source: the Hyprland event socket
// ($XDG_RUNTIME_DIR/hypr/<signature>/.socket2.sock, as in focus.ts): on a workspace, special workspace or monitor
// event `hyprctl -j monitors` is read (coalesced over 60 ms; same in classic and Lua mode) and the answer compared:
// scratch → some monitor shows special:tiphys; fullscreen → some monitor's active workspace is ours with no special
// workspace over it. A monitor with DPMS off counts as not showing anything. One listener per running mode; it closes
// at stop. Without a socket (Hyprland restarting) the monitors are polled every 2 s and the socket is reconnected
// with backoff (1 → 30 s).
import { join } from "node:path";
import type { Exec } from "../control.ts";
import type { EventSocket } from "../focus.ts";

export interface VisibilityIo {
  exec: Exec;
  hyprEnv(): Promise<NodeJS.ProcessEnv>;
  connect(path: string): EventSocket;
}

export type Where = { placement: "scratch" } | { placement: "fullscreen"; workspace: string };

/** Event names after which the visible workspaces may have changed. */
const EVENTS = new Set([
  "workspace", "workspacev2", "focusedmon", "focusedmonv2", "activespecial", "activespecialv2",
  "monitoradded", "monitoraddedv2", "monitorremoved", "monitorremovedv2", "moveworkspace", "moveworkspacev2",
]);

export function relevantEvent(line: string): boolean {
  const i = line.indexOf(">>");
  return i > 0 && EVENTS.has(line.slice(0, i));
}

/** `hyprctl -j monitors` → is the kiosk shown? null if the output can't be read. */
export function visibleIn(json: string, where: Where, special = "special:tiphys"): boolean | null {
  let ms: unknown;
  try {
    ms = JSON.parse(json);
  } catch {
    return null;
  }
  if (!Array.isArray(ms)) return null;
  return ms.some((m: { activeWorkspace?: { name?: unknown }; specialWorkspace?: { name?: unknown }; dpmsStatus?: unknown }) => {
    if (m?.dpmsStatus === false) return false;
    const sp = typeof m?.specialWorkspace?.name === "string" ? m.specialWorkspace.name : "";
    if (where.placement === "scratch") return sp === special;
    return sp === "" && m?.activeWorkspace?.name === where.workspace;
  });
}

export interface VisibilityOpts {
  debounceMs?: number;
  pollMs?: number;
  retryMs?: number;
  retryMaxMs?: number;
}

export class VisibilityWatcher {
  readonly #io: VisibilityIo;
  readonly #where: Where;
  readonly #onChange: (visible: boolean) => void;
  readonly #o: Required<VisibilityOpts>;
  #visible: boolean | null = null;
  #run = 0;
  #sock: EventSocket | null = null;
  #connected = false;
  #buf = "";
  #retry = 0;
  #timers = new Set<NodeJS.Timeout>();
  #readTimer: NodeJS.Timeout | null = null;

  constructor(io: VisibilityIo, where: Where, onChange: (visible: boolean) => void, o: VisibilityOpts = {}) {
    this.#io = io;
    this.#where = where;
    this.#onChange = onChange;
    this.#o = { debounceMs: 60, pollMs: 2000, retryMs: 1000, retryMaxMs: 30_000, ...o };
  }

  /** Last known answer (null until the first read). */
  get visible(): boolean | null {
    return this.#visible;
  }

  /** Any socket or timer open (tests: leak check). */
  get active(): boolean {
    return this.#sock !== null || this.#timers.size > 0 || this.#readTimer !== null;
  }

  start() {
    this.#run++;
    this.refresh();
    void this.#connect();
  }

  stop() {
    this.#run++;
    const s = this.#sock;
    this.#sock = null;
    this.#connected = false;
    this.#buf = "";
    s?.destroy();
    for (const t of this.#timers) clearTimeout(t);
    this.#timers.clear();
    if (this.#readTimer) clearTimeout(this.#readTimer);
    this.#readTimer = null;
  }

  #later(ms: number, fn: () => void) {
    const t = setTimeout(() => {
      this.#timers.delete(t);
      fn();
    }, ms);
    this.#timers.add(t);
  }

  /** Re-reads the monitors soon (coalesced). */
  refresh() {
    if (this.#readTimer) return;
    const run = this.#run;
    this.#readTimer = setTimeout(() => {
      this.#readTimer = null;
      if (run === this.#run) void this.#read(run);
    }, this.#o.debounceMs);
  }

  async #read(run: number) {
    try {
      const env = await this.#io.hyprEnv();
      const r = await this.#io.exec("hyprctl", ["-j", "monitors"], { env, timeoutMs: 3000, allowFail: true });
      if (run !== this.#run || r.code !== 0) return;
      const v = visibleIn(r.stdout, this.#where);
      if (v === null || v === this.#visible) return;
      this.#visible = v;
      this.#onChange(v);
    } catch {
      // No Hyprland / hyprctl error: the next event or poll retries.
    }
  }

  async #connect() {
    const run = this.#run;
    let path: string;
    try {
      const env = await this.#io.hyprEnv();
      path = join(env.XDG_RUNTIME_DIR ?? "", "hypr", env.HYPRLAND_INSTANCE_SIGNATURE ?? "", ".socket2.sock");
    } catch {
      if (run === this.#run) this.#lost(run);
      return;
    }
    if (run !== this.#run) return;
    let sock: EventSocket;
    try {
      sock = this.#io.connect(path);
    } catch {
      return this.#lost(run);
    }
    this.#sock = sock;
    const mine = () => run === this.#run && this.#sock === sock;
    sock.on("connect", () => {
      if (!mine()) return;
      this.#connected = true;
      this.#retry = 0;
      this.refresh(); // changes missed while there was no socket
    });
    sock.on("data", (b: Buffer) => {
      if (!mine()) return;
      this.#buf += b.toString("utf8");
      const lines = this.#buf.split("\n");
      this.#buf = lines.pop() ?? "";
      if (this.#buf.length > 64 * 1024) this.#buf = "";
      if (lines.some(relevantEvent)) this.refresh();
    });
    sock.on("error", () => {}); // close follows
    sock.on("close", () => {
      if (mine()) this.#lost(run);
    });
  }

  /** Socket missing/dropped: poll the monitors, reconnect with increasing backoff. */
  #lost(run: number) {
    const s = this.#sock;
    this.#sock = null;
    this.#connected = false;
    this.#buf = "";
    s?.destroy();
    const poll = () => {
      if (run !== this.#run || this.#connected) return;
      this.refresh();
      this.#later(this.#o.pollMs, poll);
    };
    if (this.#retry === 0) poll();
    const wait = Math.min(this.#o.retryMaxMs, this.#o.retryMs * 2 ** this.#retry++);
    this.#later(wait, () => {
      if (run === this.#run && !this.#connected) void this.#connect();
    });
  }
}
