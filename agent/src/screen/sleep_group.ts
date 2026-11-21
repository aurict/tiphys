// Sleep group (PLAN.md §21 Kavramlar, Mimari, A-9; S3): two to four display hosts as one scene. The scene itself needs
// no network (every member computes the same timeline from the session's seed and t0, display/sleep/timeline.js);
// the group channel carries only user events, member states and the clock offset.
// Channel: each non-leader member's EXISTING source connection to the leader (WS /v1/screen/feed, scope screen),
// both directions; the leader never connects to a member. Messages (JSON, small):
//   member → leader  {type:"sleepGroup", sessionId, action:"hello"|"state", host}          (state: every 5 s, keepalive)
//   leader → member  {type:"sleepGroup", sessionId, action:"hello"|"members", host, members:[{host, state}], plan}
//                    (plan, S4: the group's plan with its snoozes/dismiss; a member merges it with its own)
//                    {type:"sleepGroup", sessionId, action:"unknown"}  (the leader doesn't run this session)
//   both ways        {type:"sleepGroup", sessionId, action:"stop"|"snooze"|"dismiss"|"phase", host, at[, phase]}
//                    (snooze/dismiss, S4: `at` is the moment on the sender's clock; every member applies the same `at`)
//   member → leader  {type:"clockPing", t}  →  leader → member {type:"clockPong", t, peer}   (source.ts answers at once)
// A user stop (API or the page's Esc hold) on any member stops the group: the leader relays it to every other member,
// and answers a late hello of a session it stopped that way with `stop` (memory only). A member that loses the link
// keeps running on its own timeline and reports `agent.sleep.memberDown`; the link reconnects with the source's
// backoff and the messages resume. The leader marks a member down after 15 s without its keepalive.
// Clock: a burst of 8 pings 150 ms apart on every (re)connect and every 10 min; Wi-Fi RTT swings 2–81 ms (S0), so the
// estimate uses only the lowest-RTT samples (a median gave a wrong 44 ms): offset = t_leader − (t_send + t_recv) / 2,
// averaged over the best quarter (1–3 samples), discarded if even the best RTT is over 150 ms. The page gets it only
// when |offset| > 20 ms (NTP alone is ~10 ms), else 0.
import type { SleepSession } from "./sleep.ts";

export const CLOCK_PINGS = 8;
export const CLOCK_GAP_MS = 150;
export const CLOCK_WAIT_MS = 2000;
export const CLOCK_EVERY_MS = 10 * 60_000;
export const CLOCK_RETRY_MS = 30_000;
export const CLOCK_MAX_RTT_MS = 150;
export const OFFSET_APPLY_MS = 20;
export const ALIVE_MS = 5000;
export const PEER_TIMEOUT_MS = 15_000;
/** A member that never connected is "connecting" this long after the start, then "down". */
export const JOIN_GRACE_MS = 60_000;
export const MEMBER_DOWN = "agent.sleep.memberDown";

export type MemberState = "running" | "connecting" | "down" | "stopped" | "unknown";
export const USER_ACTIONS = ["stop", "snooze", "dismiss", "phase"] as const;
export type UserAction = (typeof USER_ACTIONS)[number];

export interface ClockSample {
  send: number;
  recv: number;
  peer: number;
}

/** Lowest-RTT samples → {offsetMs (leader − here), rttMs (best)}; null when even the best RTT is too long. */
export function estimateOffset(samples: readonly ClockSample[], maxRttMs = CLOCK_MAX_RTT_MS): { offsetMs: number; rttMs: number; used: number } | null {
  const ok = samples.filter((s) => s.recv >= s.send).sort((a, b) => a.recv - a.send - (b.recv - b.send));
  if (!ok.length || ok[0]!.recv - ok[0]!.send > maxRttMs) return null;
  const best = ok.slice(0, Math.max(1, Math.min(3, Math.floor(ok.length / 4))));
  const offset = best.reduce((a, s) => a + (s.peer - (s.send + s.recv) / 2), 0) / best.length;
  return { offsetMs: Math.round(offset * 10) / 10, rttMs: Math.round((ok[0]!.recv - ok[0]!.send) * 10) / 10, used: best.length };
}

/** What the page gets: the offset only when it matters (|offset| > 20 ms), whole ms. */
export const appliedOffset = (est: number | null) => (est !== null && Math.abs(est) > OFFSET_APPLY_MS ? Math.round(est) : 0);

type Rec = Record<string, unknown>;
const HOST = /^[A-Za-z0-9_.-]{1,64}$/;
const SID = /^[A-Za-z0-9_-]{8,64}$/;

export interface GroupMsg {
  sessionId: string;
  action: "hello" | "state" | "members" | "unknown" | UserAction;
  host: string | null;
  at: number | null;
  phase: string | null;
  members: Array<{ host: string; state: MemberState }>;
  /** The leader's plan (unvalidated here: sleep.ts parsePlan), or undefined. */
  plan: unknown;
}

/** A received `sleepGroup` message → validated fields, or null. */
export function parseGroupMessage(v: unknown): GroupMsg | null {
  if (!v || typeof v !== "object") return null;
  const m = v as Rec;
  const actions = ["hello", "state", "members", "unknown", ...USER_ACTIONS];
  if (m.type !== "sleepGroup" || typeof m.sessionId !== "string" || !SID.test(m.sessionId) || !actions.includes(m.action as string)) return null;
  const host = typeof m.host === "string" && HOST.test(m.host) ? m.host : null;
  if (m.action !== "unknown" && !host) return null;
  const states: MemberState[] = ["running", "connecting", "down", "stopped", "unknown"];
  const members = Array.isArray(m.members)
    ? m.members.slice(0, 4).flatMap((x) => {
        const o = (x && typeof x === "object" ? x : {}) as Rec;
        return typeof o.host === "string" && HOST.test(o.host) && states.includes(o.state as MemberState) ? [{ host: o.host, state: o.state as MemberState }] : [];
      })
    : [];
  return {
    sessionId: m.sessionId,
    action: m.action as GroupMsg["action"],
    host,
    at: typeof m.at === "number" && Number.isFinite(m.at) ? m.at : null,
    phase: typeof m.phase === "string" && /^[a-z]{1,16}$/.test(m.phase) ? m.phase : null,
    members,
    plan: m.plan,
  };
}

/** A pong for our ping: {t (our send time), peer (the leader's clock)} or null. */
export function parsePong(v: unknown): { t: number; peer: number } | null {
  const m = (v && typeof v === "object" ? v : {}) as Rec;
  return m.type === "clockPong" && typeof m.t === "number" && Number.isFinite(m.t) && typeof m.peer === "number" && Number.isFinite(m.peer) ? { t: m.t, peer: m.peer } : null;
}

export interface GroupClock {
  now?: () => number;
  setTimeout?: (fn: () => void, ms: number) => unknown;
  clearTimeout?: (h: unknown) => void;
}

export interface GroupDeps extends GroupClock {
  session: SleepSession;
  me: string;
  /** A user event from another member: stop this host (no relay back), or snooze/dismiss/phase (S4). */
  onStop: (from: string) => void;
  onEvent?: (action: Exclude<UserAction, "stop">, at: number | null, from: string) => void;
  /** Leader: the plan to send with hello/members. Member: the leader's plan arrived (raw). */
  plan?: () => unknown;
  onPlan?: (raw: unknown) => void;
  /** The page's offset changed (member only). */
  onOffset?: (appliedMs: number) => void;
  log?: (msg: string, err?: unknown) => void;
}

export interface GroupStatus {
  role: "leader" | "member";
  /** Member: the link to the leader. Leader: null. */
  link: "connecting" | "ok" | "down" | null;
  members: Array<{ host: string; side: string; distance: string; leader: boolean; state: MemberState }>;
  offsetMs: number | null;
  appliedOffsetMs: number;
  rttMs: number | null;
  syncedAt: number | null;
  error: string | null;
}

abstract class GroupBase {
  protected readonly d: GroupDeps;
  protected readonly now: () => number;
  protected readonly setT: (fn: () => void, ms: number) => unknown;
  protected readonly clearT: (h: unknown) => void;
  protected closed = false;

  constructor(d: GroupDeps) {
    this.d = d;
    this.now = d.now ?? Date.now;
    this.setT = d.setTimeout ?? ((fn, ms) => setTimeout(fn, ms));
    this.clearT = d.clearTimeout ?? ((h) => clearTimeout(h as NodeJS.Timeout));
  }

  protected timer(fn: () => void, ms: number) {
    const h = this.setT(fn, ms);
    (h as NodeJS.Timeout)?.unref?.();
    return h;
  }

  protected msg(action: GroupMsg["action"], extra: Rec = {}) {
    return { type: "sleepGroup", sessionId: this.d.session.id, action, host: this.d.me, ...extra };
  }

  protected layout(states: (host: string) => MemberState) {
    return this.d.session.members.map((m) => ({ host: m.host, side: m.side, distance: m.distance, leader: m.host === this.d.session.leader, state: m.host === this.d.me ? ("running" as const) : states(m.host) }));
  }

  /** A user event from another member. */
  protected handleUser(m: GroupMsg) {
    if (m.action === "stop") this.d.onStop(m.host ?? "?");
    else this.d.onEvent?.(m.action as Exclude<UserAction, "stop">, m.at, m.host ?? "?");
  }

  abstract status(): GroupStatus;
  /** A user event on this host (stop, snooze, dismiss): to the rest of the group. */
  abstract user(action: UserAction, extra?: Rec): void;
  abstract close(): void;
}

/** The leader's side: peers are feed sockets that said hello for this session. */
export class LeaderGroup extends GroupBase {
  readonly #peers = new Map<{ send(d: string): void }, { host: string; seen: number }>();
  readonly #seen = new Map<string, number>();
  readonly #started: number;

  constructor(d: GroupDeps) {
    super(d);
    this.#started = this.now();
  }

  #state(host: string): MemberState {
    const live = [...this.#peers.values()].find((p) => p.host === host);
    const t = this.now();
    if (live && t - live.seen <= PEER_TIMEOUT_MS) return "running";
    if (this.#seen.has(host)) return "down";
    return t - this.#started < JOIN_GRACE_MS ? "connecting" : "down";
  }

  #members() {
    return this.d.session.members.map((m) => ({ host: m.host, state: m.host === this.d.me ? ("running" as const) : this.#state(m.host) }));
  }

  /** A `sleepGroup` message on a feed socket (already parsed; this session's). */
  message(sock: { send(d: string): void }, m: GroupMsg) {
    if (this.closed || !m.host || m.host === this.d.me || !this.d.session.members.some((x) => x.host === m.host)) return;
    const t = this.now();
    this.#peers.set(sock, { host: m.host, seen: t });
    this.#seen.set(m.host, t);
    const plan = this.d.plan?.();
    if (m.action === "hello") return void sock.send(JSON.stringify(this.msg("hello", { members: this.#members(), ...(plan ? { plan } : {}) })));
    if (m.action === "state") return void sock.send(JSON.stringify(this.msg("members", { members: this.#members(), ...(plan ? { plan } : {}) })));
    if ((USER_ACTIONS as readonly string[]).includes(m.action)) {
      // Relay to the other members first, then act on it here.
      this.#broadcast(JSON.stringify({ type: "sleepGroup", sessionId: m.sessionId, action: m.action, host: m.host, at: m.at, ...(m.phase ? { phase: m.phase } : {}) }), sock);
      this.handleUser(m);
    }
  }

  gone(sock: { send(d: string): void }) {
    this.#peers.delete(sock);
  }

  #broadcast(data: string, except?: { send(d: string): void }) {
    for (const s of this.#peers.keys()) {
      if (s === except) continue;
      try {
        s.send(data);
      } catch {}
    }
  }

  user(action: UserAction, extra: Rec = {}) {
    if (this.closed) return;
    this.#broadcast(JSON.stringify(this.msg(action, { at: this.now(), ...extra })));
  }

  status(): GroupStatus {
    const members = this.layout((h) => this.#state(h));
    return { role: "leader", link: null, members, offsetMs: 0, appliedOffsetMs: 0, rttMs: null, syncedAt: null, error: members.some((m) => m.state === "down") ? MEMBER_DOWN : null };
  }

  close() {
    this.closed = true;
    this.#peers.clear();
  }
}

export interface MemberDeps extends GroupDeps {
  /** Sends on the link to the leader; false when there is none. */
  send: (msg: object) => boolean;
}

/** A non-leader member: its source connection to the leader carries the group. */
export class MemberGroup extends GroupBase {
  readonly #send: (msg: object) => boolean;
  #link: "connecting" | "ok" | "down" = "connecting";
  /** The leader answered hello for this session. */
  #acked = false;
  #leader: MemberState = "connecting";
  #others = new Map<string, MemberState>();
  #alive: unknown = null;
  #burstTimers: unknown[] = [];
  #nextBurst: unknown = null;
  #pending = new Map<number, number>();
  #samples: ClockSample[] = [];
  #offset: number | null = null;
  #rtt: number | null = null;
  #syncedAt: number | null = null;
  #applied = 0;

  constructor(d: MemberDeps) {
    super(d);
    this.#send = d.send;
  }

  get offset() {
    return this.#offset;
  }

  get applied() {
    return this.#applied;
  }

  /** The source connection opened: say hello; keepalive (and hello until answered) every 5 s. */
  linkUp() {
    if (this.closed) return;
    this.#link = "ok";
    this.#acked = false;
    this.#hello();
    if (this.#alive !== null) this.clearT(this.#alive);
    const tick = () => {
      this.#alive = this.timer(tick, ALIVE_MS);
      if (this.#acked) this.#send(this.msg("state"));
      else this.#hello();
    };
    this.#alive = this.timer(tick, ALIVE_MS);
  }

  #hello() {
    this.#send(this.msg("hello"));
  }

  /** The link is gone (closed, silent, or not there yet): this host carries on alone; the source reconnects. */
  linkDown() {
    this.#link = "down";
    this.#acked = false;
    this.#leader = "down";
    this.#others.clear();
    this.#stopTimers();
  }

  #stopTimers() {
    for (const h of [this.#alive, this.#nextBurst, ...this.#burstTimers]) if (h !== null) this.clearT(h);
    this.#alive = this.#nextBurst = null;
    this.#burstTimers = [];
    this.#pending.clear();
  }

  /** A message from the leader on the link (`sleepGroup` or `clockPong`). */
  message(raw: unknown) {
    if (this.closed) return;
    const pong = parsePong(raw);
    if (pong) return this.#pong(pong);
    const m = parseGroupMessage(raw);
    if (!m || m.sessionId !== this.d.session.id) return;
    if (m.action === "unknown") {
      // The leader doesn't run this session (not started there, or stopped by its own failure): carry on alone.
      this.#acked = false;
      this.#leader = "stopped";
      return;
    }
    if (m.action === "hello" || m.action === "members") {
      if (m.host !== this.d.session.leader) return;
      const first = !this.#acked;
      this.#acked = true;
      this.#leader = "running";
      this.#others = new Map(m.members.filter((x) => x.host !== this.d.me && x.host !== this.d.session.leader).map((x) => [x.host, x.state]));
      if (m.plan !== undefined) this.d.onPlan?.(m.plan);
      if (first) this.#burst();
      return;
    }
    if (m.host === this.d.me || !(USER_ACTIONS as readonly string[]).includes(m.action)) return;
    this.handleUser(m);
  }

  /** Ping burst: CLOCK_PINGS pings CLOCK_GAP_MS apart, estimated when all are back or after CLOCK_WAIT_MS. */
  #burst() {
    if (this.closed || this.#link !== "ok") return;
    if (this.#nextBurst !== null) this.clearT(this.#nextBurst);
    this.#nextBurst = null;
    for (const h of this.#burstTimers) this.clearT(h);
    this.#burstTimers = [];
    this.#pending.clear();
    this.#samples = [];
    for (let i = 0; i < CLOCK_PINGS; i++) {
      this.#burstTimers.push(
        this.timer(() => {
          const t = this.now();
          this.#pending.set(t, t);
          this.#send({ type: "clockPing", t });
        }, i * CLOCK_GAP_MS),
      );
    }
    this.#burstTimers.push(this.timer(() => this.#estimate(), (CLOCK_PINGS - 1) * CLOCK_GAP_MS + CLOCK_WAIT_MS));
  }

  #pong(p: { t: number; peer: number }) {
    const send = this.#pending.get(p.t);
    if (send === undefined) return;
    this.#pending.delete(p.t);
    this.#samples.push({ send, recv: this.now(), peer: p.peer });
    if (this.#samples.length === CLOCK_PINGS) this.#estimate();
  }

  #estimate() {
    if (this.closed || this.#link !== "ok") return;
    for (const h of this.#burstTimers) this.clearT(h);
    this.#burstTimers = [];
    this.#pending.clear();
    const e = estimateOffset(this.#samples);
    this.#samples = [];
    if (e) {
      this.#offset = e.offsetMs;
      this.#rtt = e.rttMs;
      this.#syncedAt = this.now();
      const applied = appliedOffset(e.offsetMs);
      if (applied !== this.#applied) {
        this.#applied = applied;
        this.d.onOffset?.(applied);
      }
    } else this.d.log?.("uyku grubu: saat ölçümü güvenilmez (gidiş-dönüş çok uzun), önceki değer kalıyor");
    this.#nextBurst = this.timer(() => this.#burst(), e ? CLOCK_EVERY_MS : CLOCK_RETRY_MS);
  }

  user(action: UserAction, extra: Rec = {}) {
    if (this.closed) return;
    if (this.#link === "ok") this.#send(this.msg(action, { at: this.now(), ...extra }));
  }

  status(): GroupStatus {
    const leader = this.d.session.leader;
    const members = this.layout((h) => (h === leader ? this.#leader : this.#link === "ok" ? (this.#others.get(h) ?? "unknown") : "unknown"));
    return {
      role: "member",
      link: this.#link,
      members,
      offsetMs: this.#offset,
      appliedOffsetMs: this.#applied,
      rttMs: this.#rtt,
      syncedAt: this.#syncedAt,
      error: members.some((m) => m.state === "down") ? MEMBER_DOWN : null,
    };
  }

  /** Any timer pending (tests). */
  get armed() {
    return this.#alive !== null || this.#nextBurst !== null || this.#burstTimers.length > 0;
  }

  close() {
    this.closed = true;
    this.#stopTimers();
  }
}

export type SleepGroup = LeaderGroup | MemberGroup;

/** Which configured source reaches the leader: one named like it, else one whose URL host starts with its name. */
export function leaderSource(sources: Record<string, { url: string }>, leader: string): string | null {
  const l = leader.toLowerCase();
  const names = Object.keys(sources);
  const byName = names.find((n) => n.toLowerCase() === l);
  if (byName) return byName;
  return (
    names.find((n) => {
      try {
        return new URL(sources[n]!.url).hostname.toLowerCase().split(".")[0] === l;
      } catch {
        return false;
      }
    }) ?? null
  );
}
