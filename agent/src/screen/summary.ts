// Session summary (PLAN.md §20 "Ek önerilerim" 5, W7): while a mode runs the display agent counts, in memory only,
// what the messages it already relays tell: focus rounds completed, commits (`commit` of the city topic), finished
// jobs (`jobDone`, failed = a non-zero exit code), Claude sessions seen and permission waits. When the mode stops
// (after at least SUMMARY_MIN_MS) the phone gets ONE `screen.summary` push with these numbers — no file name, task
// text, commit subject or session name — that is never recorded (the event log keeps only `screen.stopped`).
import type { ScreenMode } from "../config.ts";
import type { FocusPhase } from "./focus_timer.ts";

type Rec = Record<string, unknown>;

/** A mode that ran shorter than this stops without a summary. */
export const SUMMARY_MIN_MS = 2 * 60_000;

export class SessionSummary {
  readonly startedAt: number;
  readonly modes: ScreenMode[] = [];
  rounds = 0;
  commits = 0;
  jobs = 0;
  failed = 0;
  waits = 0;
  readonly #sessions = new Set<string>();
  /** Permission requests already counted ("src:requestId"). */
  readonly #requests = new Set<string>();
  /** Sessions waiting without a request id (terminal sessions), per source: a new wait is a change into waiting. */
  readonly #waiting = new Map<string, Set<string>>();

  constructor(startedAt: number, mode: ScreenMode) {
    this.startedAt = startedAt;
    this.mode(mode);
  }

  get sessions() {
    return this.#sessions.size;
  }

  mode(m: ScreenMode) {
    if (!this.modes.includes(m)) this.modes.push(m);
  }

  /** A Focus phase change: a focus round that ran out (the timer ended it) is a completed round. */
  focus(from: FocusPhase, to: FocusPhase, cause: string | null) {
    if (from === "focus" && (to === "short" || to === "long") && cause === "timer") this.rounds++;
  }

  /** A relayed topic message of source `src`. */
  message(src: string, msg: Rec) {
    switch (msg.type) {
      case "commit":
        this.commits++;
        return;
      case "jobDone":
        this.jobs++;
        if (typeof msg.exitCode === "number" && msg.exitCode !== 0) this.failed++;
        return;
      case "claude": {
        const now = new Set<string>();
        for (const s of Array.isArray(msg.sessions) ? (msg.sessions as Rec[]) : []) {
          if (!s || typeof s.id !== "string") continue;
          const key = `${src}:${s.id}`;
          this.#sessions.add(key);
          const pending = Array.isArray(s.pending) ? s.pending.filter((r): r is string => typeof r === "string") : [];
          for (const r of pending) {
            if (this.#requests.has(`${src}:${r}`)) continue;
            this.#requests.add(`${src}:${r}`);
            this.waits++;
          }
          if (s.status === "waiting" && pending.length === 0) {
            now.add(key);
            if (!this.#waiting.get(src)?.has(key)) this.waits++;
          }
        }
        this.#waiting.set(src, now);
        return;
      }
    }
  }

  /** The push params, or null when the mode ran too short. Numbers and mode names only. */
  params(now: number, minMs = SUMMARY_MIN_MS): Record<string, string | number> | null {
    const ms = now - this.startedAt;
    if (!(ms >= minMs)) return null;
    return {
      minutes: Math.floor(ms / 60_000),
      modes: this.modes.join(","),
      rounds: this.rounds,
      commits: this.commits,
      jobs: this.jobs,
      failed: this.failed,
      sessions: this.sessions,
      waits: this.waits,
    };
  }
}
