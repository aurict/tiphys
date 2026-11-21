// Shared surface of the screen feed's state producers (PLAN.md §20 A-2): a producer starts with its topic's first
// subscriber and stops with its last (FeedProducer in ../source.ts); it emits whole state messages (deltas only: no
// message when nothing changed) and events. Reads of /proc and /sys are synchronous: tiny pseudo files, no process.
import { readdirSync, readFileSync, readlinkSync } from "node:fs";

export type Rec = Record<string, unknown>;

export interface StateProducer {
  start(emit: (msg: Rec) => void): void;
  /** Everything off: timers, children, watchers. */
  stop(): Promise<void>;
  /** Anything still open (tests: leak check). */
  readonly active: boolean;
}

/** Small synchronous file access (fake in tests). Every call returns null/[] instead of throwing. */
export interface FileIo {
  read(path: string): string | null;
  list(path: string): string[];
  link(path: string): string | null;
}

export const realFileIo: FileIo = {
  read: (p) => {
    try {
      return readFileSync(p, "utf8");
    } catch {
      return null;
    }
  },
  list: (p) => {
    try {
      return readdirSync(p);
    } catch {
      return [];
    }
  },
  link: (p) => {
    try {
      return readlinkSync(p);
    } catch {
      return null;
    }
  },
};
