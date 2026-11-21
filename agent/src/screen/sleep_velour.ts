// Sleep mode and Velour on the leader (PLAN.md §21 A-7, S5; the S4 alarm in sleep_alarm.ts): one owner of Velour's
// volume for the whole run, and the sleep playlist.
// - VelourVolume: every part of the run that changes Velour's volume (the playlist, the Velour alarm) takes it through
//   here. The first user saves Velour's volume as it was; later users share that saved value (a user never saves a
//   volume another one set: the alarm after a faded playlist still restores the evening's volume); the value goes
//   back once, when the last user releases it. Who uses it and who started playback live in the run's state file
//   (`velour` in sleep.json: {volume, users, started, playlistEnds}), so an adopting agent carries on and a crash is
//   undone by restoreVelour (pause what the mode started, cancel the playlist's sleep timer, the volume back).
//   Playback is paused only if a user of the mode started it ("the user was already listening" is never touched).
// - SleepPlaylist (the leader with `velour.playlistId`, the "desktop" feature and Velour reachable): at the run's start
//   the playlist plays at `velour.volume`; the volume fades linearly to 0 over `velour.fadeMin` (scaled like the
//   phases in a test) with Velour's own sleep timer set to the same length (it pauses Velour at the end even if the
//   agent is gone); then the playlist releases the volume. If Velour is already playing, the playlist is skipped (the
//   user's music). While it plays the page ducks its ember sounds (−12 dB, `music` in the sleep message, relayed to
//   the members); sunrise/ring ends it early (the alarm's turn). Unreachable / feature off → skipped, GET says so.
import type { SleepSettings } from "../config.ts";

export type VelourCall = (op: Record<string, unknown>) => Promise<unknown>;
export const VELOUR_USERS = ["playlist", "alarm"] as const;
export type VelourUser = (typeof VELOUR_USERS)[number];

/** The `velour` part of the state file. */
export interface VelourHeld {
  /** Velour's volume before the mode took it. */
  volume: number;
  users: VelourUser[];
  /** Users that started playback (they pause it when they let go). */
  started: VelourUser[];
  /** The playlist's fade end (ms), null when the playlist isn't a user. */
  playlistEnds: number | null;
}

export const VELOUR_UNAVAILABLE = "agent.sleep.velourUnavailable";
/** How often the fade steps (at most; shorter fades step 20 times). */
export const FADE_STEP_MS = 10_000;

const num = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : null);
const users = (v: unknown) => (Array.isArray(v) ? VELOUR_USERS.filter((u) => v.includes(u)) : []);

/** The state file's `velour` → valid, or null. An S4 file's `{volume}` was the alarm's. */
export function parseVelourHeld(v: unknown): VelourHeld | null {
  if (!v || typeof v !== "object") return null;
  const o = v as Record<string, unknown>;
  const volume = num(o.volume);
  if (volume === null) return null;
  const u = o.users === undefined ? (["alarm"] as VelourUser[]) : users(o.users);
  const ends = num(o.playlistEnds);
  return { volume: Math.max(0, Math.min(100, volume)), users: u, started: users(o.started).filter((x) => u.includes(x)), playlistEnds: u.includes("playlist") && ends !== null && ends >= 0 ? ends : null };
}

export interface VolumeDeps {
  call: VelourCall | null;
  /** The held state (the run's file); set() writes it. */
  get: () => VelourHeld | null;
  set: (v: VelourHeld | null) => void;
  log: (msg: string, err?: unknown) => void;
}

/** The single owner of Velour's volume during a run. */
export class VelourVolume {
  readonly #d: VolumeDeps;

  constructor(d: VolumeDeps) {
    this.#d = d;
  }

  get saved(): VelourHeld | null {
    return this.#d.get();
  }

  holds(user: VelourUser) {
    return this.#d.get()?.users.includes(user) ?? false;
  }

  /** `user` takes the volume; `current` is Velour's volume now (saved only if nobody holds it yet). */
  take(user: VelourUser, current: number, extra: Partial<Pick<VelourHeld, "playlistEnds">> = {}) {
    const h = this.#d.get();
    const next: VelourHeld = h
      ? { ...h, users: h.users.includes(user) ? h.users : [...h.users, user] }
      : { volume: Math.max(0, Math.min(100, Math.round(current))), users: [user], started: [], playlistEnds: null };
    if (extra.playlistEnds !== undefined) next.playlistEnds = extra.playlistEnds;
    this.#d.set(next);
  }

  /** `user` started playback (it pauses it when it lets go). */
  started(user: VelourUser) {
    const h = this.#d.get();
    if (h && h.users.includes(user) && !h.started.includes(user)) this.#d.set({ ...h, started: [...h.started, user] });
  }

  /** Pause if `user` started playback and Velour plays (snooze: the volume stays held). */
  async pause(user: VelourUser) {
    const v = this.#d.call;
    if (!v || !this.#d.get()?.started.includes(user)) return;
    const st = (await v({ op: "state" })) as Record<string, unknown> | null;
    if (st?.playing === true) await v({ op: "toggle" });
  }

  /** `user` lets go: paused (if it started playback and `pause`), and the last one puts the volume back. */
  async release(user: VelourUser, pause = true) {
    const h = this.#d.get();
    if (!h || !h.users.includes(user)) return;
    try {
      if (pause) await this.pause(user);
    } catch (e) {
      this.#d.log("Velour duraklatılamadı", e);
    }
    const rest = h.users.filter((u) => u !== user);
    if (rest.length) {
      this.#d.set({ ...h, users: rest, started: h.started.filter((u) => u !== user), playlistEnds: user === "playlist" ? null : h.playlistEnds });
      return;
    }
    this.#d.set(null);
    await this.#d.call?.({ op: "volume", percent: h.volume }).catch((e) => this.#d.log("Velour ses düzeyi geri konamadı", e));
  }

  /** The run's end: whatever is still held is let go (paused if the mode started it, the volume back). */
  async releaseAll() {
    const h = this.#d.get();
    if (!h) return;
    this.#d.set(null);
    await restoreVelour(this.#d.call, h, this.#d.log);
  }
}

/** Undoes a held state (the run's end, or crash recovery from the state file). */
export async function restoreVelour(call: VelourCall | null, h: VelourHeld, log: (msg: string, err?: unknown) => void) {
  if (!call) return;
  try {
    if (h.users.includes("playlist")) await call({ op: "sleep" }).catch(() => {}); // the playlist's timer off
    if (h.started.length) {
      const st = (await call({ op: "state" })) as Record<string, unknown> | null;
      if (st?.playing === true) await call({ op: "toggle" });
    }
    await call({ op: "volume", percent: h.volume });
  } catch (e) {
    log("Velour geri alınamadı", e);
  }
}

export type PlaylistState = "off" | "starting" | "playing" | "done" | "busy" | "unavailable";

export interface PlaylistDeps {
  /** Velour's control socket; null = no Velour here (headless, or the "desktop" feature off). */
  call: VelourCall | null;
  volume: VelourVolume;
  settings: () => SleepSettings["velour"];
  /** The fade's length (velour.fadeMin, scaled like the phases). */
  fadeMs: number;
  /** The page ducks its sounds while this is true (and the members' pages). */
  duck: (on: boolean) => void;
  log: (msg: string, err?: unknown) => void;
  now?: () => number;
  setTimeout?: (fn: () => void, ms: number) => unknown;
  clearTimeout?: (h: unknown) => void;
}

/** The leader's sleep playlist (one per run). */
export class SleepPlaylist {
  readonly #d: PlaylistDeps;
  readonly #now: () => number;
  readonly #setT: (fn: () => void, ms: number) => unknown;
  readonly #clearT: (h: unknown) => void;
  #state: PlaylistState = "off";
  #timer: unknown = null;
  #level = -1;
  #closed = false;

  constructor(d: PlaylistDeps) {
    this.#d = d;
    this.#now = d.now ?? Date.now;
    this.#setT = d.setTimeout ?? ((fn, ms) => setTimeout(fn, ms));
    this.#clearT = d.clearTimeout ?? ((h) => clearTimeout(h as NodeJS.Timeout));
  }

  get state() {
    return this.#state;
  }

  /** Is the music on (the pages duck)? */
  get music() {
    return this.#state === "playing";
  }

  status() {
    return { state: this.#state, endsAt: this.#d.volume.saved?.playlistEnds ?? null, warning: this.#state === "unavailable" ? VELOUR_UNAVAILABLE : null };
  }

  /** A new run: start the playlist if one is set. */
  async begin() {
    const id = this.#d.settings().playlistId;
    if (!id) return;
    const v = this.#d.call;
    if (!v) return void (this.#state = "unavailable");
    this.#state = "starting";
    let st: Record<string, unknown> | null;
    try {
      st = (await v({ op: "state" })) as Record<string, unknown> | null;
    } catch (e) {
      this.#d.log("Velour'a ulaşılamadı; uyku listesi atlandı", e);
      return void (this.#state = "unavailable");
    }
    if (this.#closed) return;
    if (st?.playing === true) return void (this.#state = "busy"); // the user's own music: not touched
    const ends = this.#now() + this.#d.fadeMs;
    this.#d.volume.take("playlist", num(st?.volume) ?? 50, { playlistEnds: ends });
    try {
      await v({ op: "volume", percent: this.#d.settings().volume });
      await v({ op: "play-target", target: { kind: "watch", playlistId: id } });
      this.#d.volume.started("playlist");
      await v({ op: "sleep", minutes: Math.max(1, Math.min(720, Math.ceil(this.#d.fadeMs / 60_000))) });
    } catch (e) {
      this.#d.log("uyku listesi başlatılamadı", e);
      this.#state = "unavailable";
      await this.#d.volume.release("playlist").catch(() => {});
      return;
    }
    if (this.#closed) return;
    this.#state = "playing";
    this.#d.duck(true);
    this.#step();
  }

  /** An adopting agent: a playlist still held goes on fading. */
  adopt() {
    if (!this.#d.volume.holds("playlist")) return;
    this.#state = "playing";
    this.#d.duck(true);
    this.#step();
  }

  #step() {
    this.#timer = null;
    if (this.#closed || this.#state !== "playing") return;
    const ends = this.#d.volume.saved?.playlistEnds ?? this.#now();
    const now = this.#now();
    if (now >= ends) return void this.end();
    const k = Math.max(0, Math.min(1, 1 - (ends - now) / Math.max(1, this.#d.fadeMs)));
    const level = Math.round(this.#d.settings().volume * (1 - k));
    if (level !== this.#level) {
      this.#level = level;
      void this.#d.call?.({ op: "volume", percent: level }).catch((e) => this.#d.log("Velour ses düzeyi ayarlanamadı", e));
    }
    const gap = Math.max(250, Math.min(FADE_STEP_MS, this.#d.fadeMs / 20));
    this.#timer = this.#setT(() => this.#step(), Math.min(gap, ends - now));
    (this.#timer as NodeJS.Timeout)?.unref?.();
  }

  /** The fade is over (Velour's timer pauses it; paused here too in case), or the alarm's turn (sunrise/ring). */
  async end() {
    if (this.#timer !== null) this.#clearT(this.#timer);
    this.#timer = null;
    if (this.#state !== "playing") return;
    this.#state = "done";
    this.#d.duck(false);
    // Velour's own timer off (it was rounded up to whole minutes: it must not pause later music).
    await this.#d.call?.({ op: "sleep" }).catch(() => {});
    await this.#d.volume.release("playlist").catch((e) => this.#d.log("uyku listesi bırakılamadı", e));
  }

  /** The run stops: the music off if the mode started it, the volume back (with the alarm's, VelourVolume). */
  async stop() {
    this.#closed = true;
    await this.end();
  }

  /** Timers off, nothing undone (agent restart; the next agent adopts). */
  detach() {
    this.#closed = true;
    if (this.#timer !== null) this.#clearT(this.#timer);
    this.#timer = null;
  }

  get armed() {
    return this.#timer !== null;
  }
}
