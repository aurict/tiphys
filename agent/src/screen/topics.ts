// Screen feed topics (PLAN.md §20 "Konular ve üreticiler"): what a source agent produces, what each kiosk card needs
// and which layouts are valid. The display agent sums the topics of the active layout's cards per source and sends
// each source only those (`{type:"subscribe", topics}`); a producer runs only while a subscriber wants its topic.
// W2 adds the Work mode state topics (system, jobs, git, servers); W3+ add city, claude and diff.
import type { CardKind, GameSettings, Layout, ModeSettings, ScreenMode } from "../config.ts";
import { AppError } from "../errors.ts";

export const TOPICS = ["music", "spectrum", "truck", "system", "jobs", "git", "servers"] as const;
export type Topic = (typeof TOPICS)[number];

/** A token with only the older "gamemode" scope gets these (PLAN.md §20 A-1). */
export const GAMEMODE_TOPICS: readonly Topic[] = ["music", "spectrum", "truck"];

/** Dropped from the subscriptions while the kiosk is hidden: pure animation or a live gauge, no state is lost. */
export const PAUSABLE: ReadonlySet<Topic> = new Set(["spectrum", "system"]);

/** JSON message type → topic (binary frames are always spectrum). Other types are never relayed. */
export const MESSAGE_TOPIC: Readonly<Record<string, Topic>> = {
  music: "music", lyrics: "music", truck: "truck", event: "truck",
  system: "system", jobs: "jobs", jobDone: "jobs", git: "git", servers: "servers",
};

/** Message types that are a topic's whole current state (replayed to a new page or layout); the rest are events. */
export const STATE_TYPES: ReadonlySet<string> = new Set(["music", "lyrics", "truck", "system", "jobs", "git", "servers"]);

/** Templates per mode and the card kinds each one can hold (anything else: 400 agent.screen.badLayout). */
export const TEMPLATES: Readonly<Record<ScreenMode, Readonly<Record<string, readonly CardKind[]>>>> = {
  game: { game: ["map", "cockpit", "music", "lyrics"] },
  work: { work: ["city", "day", "system", "jobs", "git", "music", "servers"] },
  focus: { focus: ["focus", "task", "day", "music", "servers"] },
};

/**
 * Card kinds the kiosk page of this version draws. Only these subscribe topics, so a card the page can't show yet
 * starts no producer (W3 adds the city, W5 the Focus timer and task).
 */
export const DRAWN: Readonly<Record<ScreenMode, readonly CardKind[]>> = {
  game: ["map", "cockpit", "music", "lyrics"],
  work: ["day", "system", "jobs", "git", "music", "servers"],
  focus: ["day", "music", "servers"],
};

/** Topics one card needs. */
export function cardTopics(mode: ScreenMode, kind: CardKind, settings: ModeSettings): Topic[] {
  switch (kind) {
    case "map":
    case "cockpit":
      return ["truck"];
    case "lyrics":
      return ["music"];
    case "music":
      return mode === "game" && (settings as GameSettings).spectrum ? ["music", "spectrum"] : ["music"];
    case "system":
    case "jobs":
    case "git":
    case "servers":
      return [kind];
    default:
      return [];
  }
}

/** Source name → topics for a layout (enabled, drawn cards only; `paused` drops the pausable ones). Empty sets are left out. */
export function layoutTopics(mode: ScreenMode, layout: Layout, settings: ModeSettings, paused = false): Map<string, Set<Topic>> {
  const out = new Map<string, Set<Topic>>();
  for (const c of layout.cards) {
    if (!c.enabled || !DRAWN[mode].includes(c.kind)) continue;
    for (const t of cardTopics(mode, c.kind, settings)) {
      if (paused && PAUSABLE.has(t)) continue;
      const set = out.get(c.source) ?? new Set<Topic>();
      set.add(t);
      out.set(c.source, set);
    }
  }
  return out;
}

/** 400 agent.screen.badLayout unless the template belongs to the mode and every card kind fits it, once. */
export function checkLayout(mode: ScreenMode, layout: Layout): void {
  const kinds = TEMPLATES[mode][layout.template];
  const seen = new Set<string>();
  for (const c of layout.cards) {
    if (!kinds || !kinds.includes(c.kind) || seen.has(c.kind)) throw new AppError("agent.screen.badLayout", 400, { mode, template: layout.template, kind: c.kind });
    seen.add(c.kind);
  }
  if (!kinds) throw new AppError("agent.screen.badLayout", 400, { mode, template: layout.template });
}

/** Subscribe message topics → the known ones the caller may have (unknown/forbidden ones are dropped). */
export function parseTopics(v: unknown, allowed: readonly Topic[]): Topic[] | null {
  if (!Array.isArray(v) || v.length > 32) return null;
  return [...new Set(v.filter((t): t is Topic => typeof t === "string" && (allowed as readonly string[]).includes(t)))];
}
