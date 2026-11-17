// Telegram newsletter state: recipients, invites, feeds, issue archive and the getUpdates offset.
// One JSON file next to the agent config (telegram-state.json, mode 600, atomic temp-file + rename, writes in order).
import { readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { z } from "zod";
import { whenSchema } from "../claude/schedules.ts";
import type { ResearchResult } from "./research_client.ts";
import type { RenderItem } from "./render.ts";
import type { ValidationStats } from "./validate.ts";

const domain = z
  .string()
  .trim()
  .toLowerCase()
  .regex(/^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}$/);

/** Fields the phone sends for a feed (create/update). */
export const feedInputSchema = z
  .strictObject({
    name: z.string().trim().min(1).max(80),
    enabled: z.boolean().default(true),
    when: whenSchema,
    topic: z.string().trim().min(1).max(500),
    instructions: z.string().trim().max(4000).optional(),
    windowHours: z.int().min(1).max(720).default(24),
    language: z.literal("tr").default("tr"),
    minItems: z.int().min(1).max(20).default(5),
    maxItems: z.int().min(1).max(20).default(8),
    maxSourcesPerItem: z.int().min(1).max(3).default(3),
    allowDomains: z.array(domain).max(50).default([]),
    blockDomains: z.array(domain).max(50).default([]),
    skipIfNothingNew: z.boolean().default(true),
    approval: z
      .strictObject({ mode: z.enum(["auto", "ask", "firstN"]).default("firstN"), n: z.int().min(1).max(100).default(3) })
      .default({ mode: "firstN", n: 3 }),
    deadlineMinutes: z.int().min(5).max(360).default(30),
  })
  .refine((f) => f.minItems <= f.maxItems, { message: "minItems ≤ maxItems olmalı", path: ["minItems"] });
export type FeedInput = z.infer<typeof feedInputSchema>;

export type Feed = Omit<FeedInput, "approval"> & {
  id: string;
  createdAt: string;
  /** Start of interval slots and of the scheduler scan (created / timing changed). */
  anchorAt: string;
  /** Last schedule slot handled (run or missed). */
  lastSlotAt: string | null;
  approval: FeedInput["approval"] & { sentCount: number };
};

export const RECIPIENT_STATUSES = ["active", "paused", "stopped", "unreachable"] as const;
export interface Recipient {
  id: string;
  chatId: number;
  firstName: string;
  lastName?: string;
  username?: string;
  addedAt: string;
  status: (typeof RECIPIENT_STATUSES)[number];
  statusAt?: string;
  subscriptions: string[];
}

export interface Invite {
  id: string;
  code: string;
  label?: string;
  /** Feeds the new recipient is subscribed to. */
  feedIds: string[];
  createdAt: string;
  expiresAt: string;
  usedAt?: string;
  recipientId?: string;
  revokedAt?: string;
}

export type IssueStatus = "researching" | "awaiting_approval" | "sending" | "sent" | "skipped" | "failed" | "expired" | "rejected" | "preview";

export interface Delivery {
  recipientId: string;
  status: "sent" | "failed" | "unreachable";
  messageIds: number[];
  error?: string;
  at: string;
  test?: boolean;
}

export interface Issue {
  id: string;
  feedId: string;
  kind: "scheduled" | "manual" | "preview";
  createdAt: string;
  /** Schedule slot (scheduled runs). */
  slotAt?: string;
  deadlineAt: string;
  /** awaiting_approval: not sent after this. */
  expiresAt?: string;
  status: IssueStatus;
  items: RenderItem[];
  renderedParts: string[];
  models?: ResearchResult["models"];
  stats?: ValidationStats;
  deliveries: Delivery[];
  error?: string;
  finishedAt?: string;
}

export interface TelegramState {
  version: 1;
  updateOffset: number;
  recipients: Recipient[];
  invites: Invite[];
  feeds: Feed[];
  issues: Issue[];
}

export const emptyState = (): TelegramState => ({ version: 1, updateOffset: 0, recipients: [], invites: [], feeds: [], issues: [] });

export const telegramStatePath = (configPath: string) => join(dirname(configPath), "telegram-state.json");

export class StateFile {
  readonly file: string | null;
  state: TelegramState = emptyState();
  #chain: Promise<void> = Promise.resolve();

  constructor(file: string | null) {
    this.file = file;
  }

  /**
   * Loads the file. A file that isn't valid state JSON is moved aside to `<file>.corrupt-<time>` and the state starts
   * empty (the agent keeps running); returns the new path in that case. Read errors other than ENOENT are thrown.
   */
  async load(): Promise<{ corruptMovedTo?: string }> {
    if (!this.file) return {};
    let raw: string;
    try {
      raw = await readFile(this.file, "utf8");
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code === "ENOENT") return {};
      throw e;
    }
    let parsed: unknown = null;
    try {
      parsed = JSON.parse(raw);
    } catch {
      // handled below
    }
    const o = parsed as Record<string, unknown> | null;
    const valid =
      !!o && typeof o === "object" && !Array.isArray(o) && (["recipients", "invites", "feeds", "issues"] as const).every((k) => o[k] === undefined || Array.isArray(o[k]));
    if (!valid) {
      const moved = `${this.file}.corrupt-${new Date().toISOString().replace(/[:.]/g, "-")}`;
      await rename(this.file, moved);
      this.state = emptyState();
      return { corruptMovedTo: moved };
    }
    this.state = { ...emptyState(), ...(o as unknown as TelegramState) };
    return {};
  }

  /** Atomic write of the current state, in order; a failed write doesn't block later ones. */
  save(): Promise<void> {
    if (!this.file) return Promise.resolve();
    const file = this.file;
    const body = JSON.stringify(this.state, null, 1);
    const next = this.#chain.then(async () => {
      const tmp = `${file}.${process.pid}.tmp`;
      await writeFile(tmp, body, { mode: 0o600 });
      await rename(tmp, file);
    });
    this.#chain = next.catch(() => {});
    return next;
  }
}

/** Built-in templates (not created automatically; the app creates a feed from one, the user picks the time). */
export const TEMPLATES: Array<{ id: string; feed: FeedInput }> = [
  {
    id: "daily-tech-ai",
    feed: feedInputSchema.parse({
      name: "Günlük teknoloji ve yapay zekâ",
      when: { kind: "daily", time: "08:00" },
      topic: "Son 24 saatin en önemli teknoloji ve yapay zekâ haberleri: yeni modeller ve ürünler, büyük şirket duyuruları, açık kaynak, güvenlik, düzenlemeler ve önemli araştırmalar.",
      windowHours: 24,
      minItems: 5,
      maxItems: 8,
    }),
  },
  {
    id: "weekly-tech-ai",
    feed: feedInputSchema.parse({
      name: "Haftalık teknoloji ve yapay zekâ özeti",
      when: { kind: "weekly", time: "09:00", days: [1] },
      topic: "Son 7 günün en önemli teknoloji ve yapay zekâ gelişmeleri: haftanın öne çıkan model ve ürün duyuruları, sektör hareketleri, açık kaynak, güvenlik, düzenlemeler ve araştırmalar.",
      windowHours: 168,
      minItems: 10,
      maxItems: 12,
    }),
  },
];
