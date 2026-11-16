// App context (11, "Common"): the focused window. Sent to the live stream WS as `{type:"focus", …}`; the phone
// picks the toolbar profile based on it.
// Source is the Hyprland event socket ($XDG_RUNTIME_DIR/hypr/<signature>/.socket2.sock): `activewindowv2>>ADDRESS`,
// `activewindow>>CLASS,TITLE`, `windowtitlev2>>ADDRESS,TITLE`, `closewindow>>ADDRESS` (addresses without 0x). On an
// event the details are read from `hyprctl -j activewindow` (same in classic and Lua mode). A focus change refreshes
// immediately; title changes of the focused window are coalesced over 250 ms.
// One listener per agent: the first subscriber opens the socket; when the last leaves, everything closes (socket, timers).
// If the socket can't be opened or closes (Hyprland restarted, signature changed) it is polled every 1 s and reconnected
// with increasing backoff (1 → 30 s). The title is capped at 200 characters and never written anywhere (logs included).
import { createConnection } from "node:net";
import { join } from "node:path";
import type { Exec } from "./control.ts";
import { appForClass, type DesktopApp } from "./desktop_apps.ts";
import { ADDRESS } from "./hyprctl.ts";

export interface Focus {
  /** Window address (0x…); null if no window is focused. */
  address: string | null;
  class: string;
  initialClass: string;
  title: string;
  pid: number | null;
  workspace: number | null;
  /** .desktop app matching the class (for the icon); null if none. */
  appId: string | null;
}

export const TITLE_MAX = 200;
const CLASS_MAX = 200;
const NONE: Focus = { address: null, class: "", initialClass: "", title: "", pid: null, workspace: null, appId: null };

/** The surface of the event socket that is used (net.Socket; fake in tests). */
export interface EventSocket {
  on(ev: "connect", fn: () => void): unknown;
  on(ev: "data", fn: (b: Buffer) => void): unknown;
  on(ev: "error", fn: (e: Error) => void): unknown;
  on(ev: "close", fn: () => void): unknown;
  destroy(): void;
}

export interface FocusIo {
  exec: Exec;
  hyprEnv(): Promise<NodeJS.ProcessEnv>;
  connect(path: string): EventSocket;
}

export const realConnect = (path: string): EventSocket => createConnection(path);

export interface FocusOpts {
  /** Coalescing period for title changes. */
  titleMs?: number;
  /** Polling interval while there is no socket. */
  pollMs?: number;
  /** Reconnect delay: minimum / maximum. */
  retryMs?: number;
  retryMaxMs?: number;
  /** .desktop list for class → app id. */
  apps?: () => Promise<DesktopApp[]>;
  log?: (msg: string) => void;
}

/** Event line → what to do: "focus" refresh now, "title" refresh coalesced; null if irrelevant. */
export function parseEvent(line: string, current: string | null): "focus" | "title" | null {
  const i = line.indexOf(">>");
  if (i < 0) return null;
  const ev = line.slice(0, i);
  const data = line.slice(i + 2);
  const cur = current?.replace(/^0x/, "") ?? null;
  const addrOf = (s: string) => s.split(",")[0]!.replace(/^0x/, "");
  switch (ev) {
    case "activewindowv2":
      // Same window reported again (e.g. Hyprland resends it on a title change): not a new focus, coalesced.
      return cur !== null && data.replace(/^0x/, "") === cur ? "title" : "focus";
    case "windowtitlev2":
      return cur !== null && addrOf(data) === cur ? "title" : null;
    case "closewindow":
      return cur !== null && addrOf(data) === cur ? "focus" : null;
    default:
      // activewindow>>CLASS,TITLE and others: activewindowv2 arrives anyway.
      return null;
  }
}

const cap = (v: unknown, n: number) => (typeof v === "string" ? v.slice(0, n) : "");

/** `hyprctl -j activewindow` → focus (no window gives `{}` → NONE). */
export function parseActive(v: unknown, apps: DesktopApp[] = []): Focus {
  if (!v || typeof v !== "object") return NONE;
  const j = v as Record<string, unknown>;
  const address = typeof j.address === "string" && ADDRESS.test(j.address) ? j.address : null;
  if (!address) return NONE;
  const cls = cap(j.class, CLASS_MAX) || cap(j.initialClass, CLASS_MAX);
  const ws = j.workspace as { id?: unknown } | undefined;
  return {
    address,
    class: cls,
    initialClass: cap(j.initialClass, CLASS_MAX),
    title: cap(j.title, TITLE_MAX),
    pid: typeof j.pid === "number" && j.pid > 0 ? j.pid : null,
    workspace: typeof ws?.id === "number" ? ws.id : null,
    appId: cls ? (appForClass(apps, cls)?.id ?? null) : null,
  };
}

const same = (a: Focus, b: Focus) =>
  a.address === b.address && a.class === b.class && a.initialClass === b.initialClass && a.title === b.title && a.pid === b.pid && a.workspace === b.workspace && a.appId === b.appId;

/** Shared focus listener (subscribers are live streams). */
export class FocusWatcher {
  readonly io: FocusIo;
  readonly opts: Required<Omit<FocusOpts, "apps" | "log">> & Pick<FocusOpts, "apps" | "log">;
  #subs = new Set<(f: Focus) => void>();
  #last: Focus | null = null;
  /** Run generation: bumped on stop, so stale callbacks have no effect. */
  #run = 0;
  #sock: EventSocket | null = null;
  #connected = false;
  #buf = "";
  #retry = 0;
  #retryTimer: NodeJS.Timeout | null = null;
  #pollTimer: NodeJS.Timeout | null = null;
  #refreshTimer: NodeJS.Timeout | null = null;
  #refreshAt = 0;
  #refreshing = false;
  #again = false;

  constructor(io: FocusIo, opts: FocusOpts = {}) {
    this.io = io;
    this.opts = { titleMs: 250, pollMs: 1000, retryMs: 1000, retryMaxMs: 30_000, ...opts };
  }

  /** Subscriber count (test). */
  get subscribers(): number {
    return this.#subs.size;
  }

  /** Is any socket/timer open (test: leak check). */
  get active(): boolean {
    return !!(this.#sock || this.#retryTimer || this.#pollTimer || this.#refreshTimer);
  }

  get socketConnected(): boolean {
    return this.#connected;
  }

  /** Subscribes; the known focus is reported at once. The returned function unsubscribes (the last closes everything). */
  subscribe(fn: (f: Focus) => void): () => void {
    this.#subs.add(fn);
    if (this.#subs.size === 1) this.#start();
    else if (this.#last) {
      const last = this.#last;
      queueMicrotask(() => this.#subs.has(fn) && fn(last));
    }
    return () => {
      if (!this.#subs.delete(fn)) return;
      if (this.#subs.size === 0) this.stop();
    };
  }

  /** Closes everything (when the last subscriber leaves and on agent shutdown). */
  stop() {
    this.#subs.clear();
    this.#run++;
    this.#last = null;
    this.#closeSocket();
    for (const t of [this.#retryTimer, this.#pollTimer, this.#refreshTimer]) if (t) clearTimeout(t);
    this.#retryTimer = this.#pollTimer = this.#refreshTimer = null;
    this.#retry = 0;
    this.#again = false;
  }

  #start() {
    this.#run++;
    this.#refresh(0);
    void this.#connect();
  }

  #closeSocket() {
    const s = this.#sock;
    this.#sock = null;
    this.#connected = false;
    this.#buf = "";
    s?.destroy();
  }

  async #connect() {
    const run = this.#run;
    let path: string;
    try {
      const env = await this.io.hyprEnv();
      path = join(env.XDG_RUNTIME_DIR ?? "", "hypr", env.HYPRLAND_INSTANCE_SIGNATURE ?? "", ".socket2.sock");
    } catch {
      if (run === this.#run) this.#lost();
      return;
    }
    if (run !== this.#run) return;
    let sock: EventSocket;
    try {
      sock = this.io.connect(path);
    } catch {
      return this.#lost();
    }
    this.#sock = sock;
    const mine = () => run === this.#run && this.#sock === sock;
    sock.on("connect", () => {
      if (!mine()) return;
      this.#connected = true;
      this.#retry = 0;
      if (this.#pollTimer) clearTimeout(this.#pollTimer);
      this.#pollTimer = null;
      this.#refresh(0); // changes missed while there was no socket
    });
    sock.on("data", (b: Buffer) => {
      if (!mine()) return;
      this.#buf += b.toString("utf8");
      const lines = this.#buf.split("\n");
      this.#buf = lines.pop() ?? "";
      if (this.#buf.length > 64 * 1024) this.#buf = ""; // overflow with no line ending
      for (const l of lines) {
        const what = parseEvent(l, this.#last?.address ?? null);
        if (what) this.#refresh(what === "title" ? this.opts.titleMs : 0);
      }
    });
    sock.on("error", () => {}); // close follows
    sock.on("close", () => {
      if (!mine()) return;
      this.#lost();
    });
  }

  /** Socket missing/dropped: switch to polling, reconnect with increasing backoff. */
  #lost() {
    if (this.#sock) {
      const s = this.#sock;
      this.#sock = null;
      this.#connected = false;
      this.#buf = "";
      s.destroy();
    }
    if (this.#retry === 0) this.opts.log?.("Hyprland olay soketi açılamadı, odak yoklanıyor");
    this.#schedulePoll();
    if (this.#retryTimer) return;
    const wait = Math.min(this.opts.retryMaxMs, this.opts.retryMs * 2 ** this.#retry);
    this.#retry++;
    const run = this.#run;
    this.#retryTimer = setTimeout(() => {
      this.#retryTimer = null;
      if (run === this.#run) void this.#connect();
    }, wait);
  }

  #schedulePoll() {
    if (this.#pollTimer || this.#connected) return;
    const run = this.#run;
    this.#pollTimer = setTimeout(() => {
      this.#pollTimer = null;
      if (run !== this.#run || this.#connected) return;
      this.#refresh(0);
      this.#schedulePoll();
    }, this.opts.pollMs);
  }

  /** Re-reads after [delay]; if an earlier read is already pending, joins it. */
  #refresh(delay: number) {
    const at = Date.now() + delay;
    if (this.#refreshTimer) {
      if (this.#refreshAt <= at) return;
      clearTimeout(this.#refreshTimer);
    }
    this.#refreshAt = at;
    const run = this.#run;
    this.#refreshTimer = setTimeout(() => {
      this.#refreshTimer = null;
      if (run === this.#run) void this.#read(run);
    }, delay);
  }

  async #read(run: number) {
    if (this.#refreshing) {
      this.#again = true;
      return;
    }
    this.#refreshing = true;
    try {
      const env = await this.io.hyprEnv();
      const r = await this.io.exec("hyprctl", ["-j", "activewindow"], { env, timeoutMs: 3000, allowFail: true });
      if (run !== this.#run) return;
      if (r.code !== 0) return;
      let j: unknown;
      try {
        j = JSON.parse(r.stdout);
      } catch {
        return;
      }
      const apps = this.opts.apps ? await this.opts.apps().catch(() => []) : [];
      if (run !== this.#run) return;
      const f = parseActive(j, apps);
      if (this.#last && same(this.#last, f)) return;
      this.#last = f;
      for (const fn of [...this.#subs]) fn(f);
    } catch {
      // No Hyprland / hyprctl error: the next event or poll retries.
    } finally {
      this.#refreshing = false;
      // A refresh requested while reading (including one from a restarted listener) runs now.
      if (this.#again) {
        this.#again = false;
        if (this.#subs.size) this.#refresh(0);
      }
    }
  }
}
