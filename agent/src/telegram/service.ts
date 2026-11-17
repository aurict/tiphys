// Telegram newsletters ("telegram" feature, PLAN §12): bot, recipients (invite only), feeds, scheduler, research on
// the PC, validation, rendering, approval, send queue and archive. Nothing received from Telegram is executed: the
// bot only understands /start <invite code> and /stop in private chats and leaves groups/channels it's added to.
// getUpdates is polled (no webhook, no open port) while an invite is pending (every 5 s) or any recipient could still
// send /stop (active or paused; a 25 s long poll, then a 60 s pause unless updates keep coming).
// The event log gets ids and counts only (no newsletter content, no recipient names).
import { randomBytes } from "node:crypto";
import type { AgentConfig, ConfigStore } from "../config.ts";
import { AppError, notFound } from "../errors.ts";
import type { Notice, Notifier } from "../notify.ts";
import { nextRun } from "../claude/schedules.ts";
import { sendMagicPacket } from "../routes/wake.ts";
import { SendQueue, TelegramApi, TelegramError, type Fetch, type TgUpdate } from "./api.ts";
import { renderIssue } from "./render.ts";
import { ResearchClient, researchError, type ResearchResult } from "./research_client.ts";
import { StateFile, type Delivery, type Feed, type FeedInput, type Invite, type Issue, type Recipient } from "./state.ts";
import { pinnedLinkRequest, urlKey, validateItems, type LinkRequest } from "./validate.ts";

export const MSG = {
  welcome: (name: string) => `Merhaba ${name}! Tiphys bültenlerine eklendin; bültenler bu sohbete gelecek. Ayrılmak için /stop yaz.`,
  already: "Zaten eklisin; bültenler bu sohbete gelecek. Ayrılmak için /stop yaz.",
  privateBot: "Bu özel bir bot; yalnız davet bağlantısıyla katılınabilir.",
  stopped: "Aboneliğin kapatıldı; artık bülten gönderilmeyecek.",
  test: "🔔 Tiphys test mesajı: bültenler bu sohbete gelecek.",
};

const HOUR = 3600_000;
const DAY = 24 * HOUR;
const INVITE_TTL = DAY;
const HISTORY_DAYS = 14;
const ISSUES_PER_FEED = 60;
const MAX_FEEDS = 20;
const MAX_PENDING_INVITES = 20;
const APPROVAL_GRACE = 2 * HOUR;
const PC_UNREACHABLE = "agent.telegram.research.unreachable";
const ACTIVE_ISSUE = new Set(["researching", "sending", "awaiting_approval"]);

export interface WakeTarget {
  hostId: string;
  mac: string;
  broadcast: string;
  port: number;
}

export interface ServiceDeps {
  store: ConfigStore;
  notifier: Notifier;
  /** null: in memory only (tests). */
  stateFile: string | null;
  /** Used for Telegram and the PC research API. */
  fetch?: Fetch;
  /** Link checks (default: DNS-pinned requests to public addresses only). */
  linkRequest?: LinkRequest;
  telegramBaseUrl?: string;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  wake?: (t: WakeTarget) => Promise<void>;
  log?: (msg: string) => void;
  pollTimeoutSec?: number;
  pollGapMs?: number;
  /** Pause between long polls when no invite is pending (only /stop is expected). */
  idlePollGapMs?: number;
  researchPollMs?: number;
  reachTimeoutMs?: number;
  tickMs?: number;
}

const id = (prefix: string) => `${prefix}${randomBytes(6).toString("hex")}`;
const codeOf = (e: unknown) => (e instanceof AppError ? e.code : "agent.internal");

export class TelegramService {
  readonly state: StateFile;
  readonly #store: ConfigStore;
  readonly #notifier: Notifier;
  readonly #fetch: Fetch;
  readonly #tgBase?: string;
  readonly #now: () => number;
  readonly #rawSleep: (ms: number) => Promise<void>;
  readonly #wake: (t: WakeTarget) => Promise<void>;
  readonly #log: (msg: string) => void;
  readonly #pollTimeoutSec: number;
  readonly #pollGapMs: number;
  readonly #idlePollGapMs: number;
  readonly #linkRequest: LinkRequest;
  readonly #researchPollMs: number;
  readonly #reachTimeoutMs?: number;
  readonly #tickMs: number;
  readonly queue: SendQueue;
  #api: TelegramApi | null = null;
  #apiToken: string | null = null;
  #timer: NodeJS.Timeout | null = null;
  #timersOn = false;
  #stopped = false;
  #pollLoop: Promise<void> | null = null;
  #pollAbort: AbortController | null = null;
  #wakers = new Set<() => void>();
  #running = new Map<string, Promise<void>>();
  #tasks = new Set<Promise<unknown>>();
  #nextAt = new Map<string, { key: string; at: number }>();

  constructor(d: ServiceDeps) {
    this.state = new StateFile(d.stateFile);
    this.#store = d.store;
    this.#notifier = d.notifier;
    this.#fetch = d.fetch ?? fetch;
    this.#tgBase = d.telegramBaseUrl;
    this.#now = d.now ?? Date.now;
    this.#rawSleep = d.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms).unref()));
    this.#wake = d.wake ?? ((t) => sendMagicPacket(t.mac, t.broadcast, t.port));
    this.#log = d.log ?? ((m) => console.error(m));
    this.#pollTimeoutSec = d.pollTimeoutSec ?? 25;
    this.#pollGapMs = d.pollGapMs ?? 5000;
    this.#idlePollGapMs = d.idlePollGapMs ?? 60_000;
    this.#linkRequest = d.linkRequest ?? pinnedLinkRequest();
    this.#researchPollMs = d.researchPollMs ?? 10_000;
    this.#reachTimeoutMs = d.reachTimeoutMs;
    this.#tickMs = d.tickMs ?? 20_000;
    // Raw sleep: the service's own sleep returns at once after stop, which would make the queue spin; stop() closes it.
    this.queue = new SendQueue({ send: (chat, text) => this.api().sendMessage(chat, text), now: this.#now, sleep: this.#rawSleep });
  }

  get #s() {
    return this.state.state;
  }

  #cfg(): AgentConfig {
    return this.#store.get();
  }

  #iso(t = this.#now()) {
    return new Date(t).toISOString();
  }

  /** Sleep that ends early when the service stops. */
  #sleep(ms: number): Promise<void> {
    if (this.#stopped) return Promise.resolve();
    return new Promise((res) => {
      const done = () => {
        this.#wakers.delete(done);
        res();
      };
      this.#wakers.add(done);
      void this.#rawSleep(ms).then(done);
    });
  }

  #save() {
    return this.state.save().catch((e) => this.#log(`telegram-state.json yazılamadı: ${(e as Error).message}`));
  }

  #event(key: string, params: Record<string, string | number>) {
    void this.#notifier.events?.record({ key, params, link: "tiphys://telegram" }, () => this.#log("olay yazılamadı"));
  }

  #notify(n: Notice) {
    return this.#notifier.send(n).catch(() => 0);
  }

  // ---------------------------------------------------------------- lifecycle

  async load() {
    const { corruptMovedTo } = await this.state.load();
    if (corruptMovedTo) {
      this.#log(`telegram-state.json bozuk; ${corruptMovedTo} olarak kenara alındı, boş durumla başlandı`);
      this.#event("telegram.stateCorrupt", {});
    }
    // Work cut short by a restart isn't resumed (approvals are: they only wait for a decision).
    let changed = false;
    for (const i of this.#s.issues) {
      if (i.status === "researching" || i.status === "sending") {
        i.status = "failed";
        i.error = "agent.telegram.interrupted";
        i.finishedAt = this.#iso();
        changed = true;
      }
    }
    if (changed) await this.#save();
  }

  start() {
    this.#timersOn = true;
    this.#timer = setInterval(() => void this.tick().catch((e) => this.#log(`telegram zamanlayıcı: ${codeOf(e)}`)), this.#tickMs);
    this.#timer.unref();
    void this.tick().catch((e) => this.#log(`telegram zamanlayıcı: ${codeOf(e)}`));
  }

  async stop() {
    this.#stopped = true;
    this.#timersOn = false;
    if (this.#timer) clearInterval(this.#timer);
    this.#pollAbort?.abort();
    this.queue.close();
    for (const w of [...this.#wakers]) w();
    await Promise.allSettled([this.#pollLoop, ...this.#running.values(), ...this.#tasks]);
  }

  /** Waits for running pipelines and deliveries (tests). */
  async idle() {
    while (this.#running.size || this.#tasks.size) await Promise.allSettled([...this.#running.values(), ...this.#tasks]);
  }

  #track<T>(p: Promise<T>): Promise<T> {
    this.#tasks.add(p);
    void p.finally(() => this.#tasks.delete(p)).catch(() => {});
    return p;
  }

  // ---------------------------------------------------------------- bot

  botConfigured(): boolean {
    return this.#cfg().telegram !== null;
  }

  api(): TelegramApi {
    const t = this.#cfg().telegram;
    if (!t) throw new AppError("agent.telegram.notConfigured", 409);
    if (!this.#api || this.#apiToken !== t.botToken) {
      this.#api = new TelegramApi(t.botToken, { fetch: this.#fetch, baseUrl: this.#tgBase });
      this.#apiToken = t.botToken;
    }
    return this.#api;
  }

  /** Validates the token with getMe and stores it in the agent config (it's never returned). */
  async setBot(token: string): Promise<{ username: string; id: number }> {
    const me = await new TelegramApi(token, { fetch: this.#fetch, baseUrl: this.#tgBase }).getMe();
    if (!me.is_bot || !me.username) throw new AppError("agent.telegram.invalidToken", 400);
    const prevId = this.#cfg().telegram?.botId;
    await this.#store.update((c) => ({ ...c, telegram: { botToken: token, botUsername: me.username!, botId: me.id } }));
    if (prevId !== me.id) {
      this.#s.updateOffset = 0;
      await this.#save();
    }
    // A long poll in flight still uses the old token: end it, the loop continues with the new bot.
    this.#pollAbort?.abort();
    this.#event("telegram.botSet", { botId: me.id });
    this.#ensurePolling();
    return { username: me.username, id: me.id };
  }

  async removeBot() {
    await this.#store.update((c) => ({ ...c, telegram: null }));
    this.#pollAbort?.abort();
    this.#api = null;
    this.#apiToken = null;
    this.#event("telegram.botRemoved", {});
  }

  async status() {
    const t = this.#cfg().telegram;
    const r = this.#cfg().research;
    const reachable = r ? await new ResearchClient({ url: r.url, token: r.token, fetch: this.#fetch }).health() : null;
    return {
      bot: t ? { configured: true, username: t.botUsername, id: t.botId } : { configured: false, username: null, id: null },
      research: { configured: r !== null, url: r?.url ?? null, wakeHostId: r?.wakeHostId ?? null, reachable },
      pendingInvites: this.pendingInvites().length,
      polling: this.#pollLoop !== null,
    };
  }

  // ---------------------------------------------------------------- invites and updates

  pendingInvites(): Invite[] {
    const now = this.#now();
    return this.#s.invites.filter((i) => !i.usedAt && !i.revokedAt && Date.parse(i.expiresAt) > now);
  }

  inviteView(i: Invite) {
    const now = this.#now();
    const status = i.usedAt ? "used" : i.revokedAt ? "revoked" : Date.parse(i.expiresAt) <= now ? "expired" : "pending";
    const username = this.#cfg().telegram?.botUsername;
    return {
      id: i.id,
      label: i.label ?? null,
      feedIds: i.feedIds,
      createdAt: i.createdAt,
      expiresAt: i.expiresAt,
      status,
      recipientId: i.recipientId ?? null,
      ...(status === "pending" ? { code: i.code, link: username ? `https://t.me/${username}?start=${i.code}` : null } : {}),
    };
  }

  async createInvite(input: { label?: string; feedIds?: string[] }) {
    const username = this.#cfg().telegram?.botUsername;
    if (!username) throw new AppError("agent.telegram.notConfigured", 409);
    for (const f of input.feedIds ?? []) this.getFeed(f);
    if (this.pendingInvites().length >= MAX_PENDING_INVITES) throw new AppError("agent.telegram.tooManyInvites", 400, { max: MAX_PENDING_INVITES });
    const now = this.#now();
    const inv: Invite = {
      id: id("i_"),
      code: randomBytes(12).toString("base64url"),
      ...(input.label ? { label: input.label } : {}),
      feedIds: [...new Set(input.feedIds ?? [])],
      createdAt: this.#iso(now),
      expiresAt: this.#iso(now + INVITE_TTL),
    };
    // Old used/expired invites are dropped after a week.
    this.#s.invites = this.#s.invites.filter((i) => Date.parse(i.expiresAt) > now - 7 * DAY);
    this.#s.invites.push(inv);
    await this.#save();
    this.#event("telegram.inviteCreated", { inviteId: inv.id });
    this.#ensurePolling();
    return this.inviteView(inv);
  }

  async revokeInvite(inviteId: string) {
    const inv = this.#s.invites.find((i) => i.id === inviteId);
    if (!inv) throw notFound("telegram.invite", { id: inviteId });
    if (!inv.usedAt && !inv.revokedAt) inv.revokedAt = this.#iso();
    await this.#save();
    if (!this.#shouldPoll()) this.#pollAbort?.abort();
    return this.inviteView(inv);
  }

  /** Someone may write to the bot: a pending invite (/start) or a recipient who can still /stop. */
  #shouldPoll() {
    return this.botConfigured() && (this.pendingInvites().length > 0 || this.#s.recipients.some((r) => r.status === "active" || r.status === "paused"));
  }

  #ensurePolling() {
    if (!this.#timersOn || this.#stopped || this.#pollLoop || !this.#shouldPoll()) return;
    this.#pollLoop = (async () => {
      while (!this.#stopped && this.#shouldPoll()) {
        let n: number;
        try {
          n = await this.pollOnce();
        } catch (e) {
          if (this.#stopped) break;
          if (codeOf(e) !== "agent.telegram.aborted") {
            this.#log(`telegram getUpdates: ${codeOf(e)}`);
            await this.#sleep(30_000);
          }
          continue;
        }
        // Adaptive: right after updates or while an invite waits, poll again soon; otherwise pause longer.
        await this.#sleep(n > 0 || this.pendingInvites().length > 0 ? this.#pollGapMs : this.#idlePollGapMs);
      }
    })().finally(() => {
      this.#pollLoop = null;
      this.#pollAbort = null;
    });
  }

  /** One getUpdates round (long poll); returns the number of updates handled. */
  async pollOnce(timeoutSec = this.#pollTimeoutSec): Promise<number> {
    const api = this.api();
    const ac = new AbortController();
    this.#pollAbort = ac;
    const updates = await api.getUpdates(this.#s.updateOffset, timeoutSec, ac.signal);
    for (const u of updates) {
      this.#s.updateOffset = Math.max(this.#s.updateOffset, u.update_id + 1);
      try {
        await this.#handleUpdate(u);
      } catch (e) {
        this.#log(`telegram güncellemesi işlenemedi: ${codeOf(e)}`);
      }
    }
    if (updates.length) await this.#save();
    return updates.length;
  }

  async #reply(chatId: number, text: string) {
    try {
      await this.queue.send(chatId, text);
    } catch (e) {
      this.#log(`telegram yanıtı gönderilemedi: ${codeOf(e)}`);
    }
  }

  async #handleUpdate(u: TgUpdate) {
    const chat = u.my_chat_member?.chat ?? u.channel_post?.chat ?? u.message?.chat;
    if (!chat) return;
    if (chat.type !== "private") {
      // Groups and channels are never served: leave (a "left" status update for this lands here too; ignore errors).
      if (u.my_chat_member || u.message || u.channel_post) {
        await this.api().leaveChat(chat.id).catch(() => {});
        this.#event("telegram.groupLeft", { chatType: chat.type });
      }
      return;
    }
    const m = u.message;
    if (!m) return;
    const cmd = /^\/(start|stop)(?:@\w+)?(?:\s+(\S+))?\s*$/.exec((m.text ?? "").trim());
    if (!cmd) return;
    const known = this.#s.recipients.find((r) => r.chatId === chat.id);
    if (cmd[1] === "stop") {
      if (!known || known.status === "stopped") return;
      known.status = "stopped";
      known.statusAt = this.#iso();
      await this.#save();
      this.#event("telegram.recipientStopped", { recipientId: known.id });
      await this.#reply(chat.id, MSG.stopped);
      return;
    }
    const now = this.#now();
    const inv = cmd[2] ? this.pendingInvites().find((i) => i.code === cmd[2]) : undefined;
    if (!inv) {
      await this.#reply(chat.id, known?.status === "active" ? MSG.already : MSG.privateBot);
      return;
    }
    const from = m.from;
    const firstName = (from?.first_name ?? chat.first_name ?? "").slice(0, 64) || "?";
    const lastName = (from?.last_name ?? chat.last_name)?.slice(0, 64);
    const username = (from?.username ?? chat.username)?.slice(0, 64);
    let r = known;
    if (r) {
      Object.assign(r, { firstName, lastName, username, status: "active", statusAt: this.#iso(now) });
      r.subscriptions = [...new Set([...r.subscriptions, ...inv.feedIds])];
    } else {
      r = {
        id: id("r_"),
        chatId: chat.id,
        firstName,
        ...(lastName ? { lastName } : {}),
        ...(username ? { username } : {}),
        addedAt: this.#iso(now),
        status: "active",
        subscriptions: inv.feedIds.filter((f) => this.#s.feeds.some((x) => x.id === f)),
      };
      this.#s.recipients.push(r);
    }
    inv.usedAt = this.#iso(now);
    inv.recipientId = r.id;
    await this.#save();
    this.#event("telegram.recipientAdded", { recipientId: r.id, inviteId: inv.id });
    await this.#reply(chat.id, MSG.welcome(firstName));
  }

  // ---------------------------------------------------------------- recipients

  getRecipient(rid: string): Recipient {
    const r = this.#s.recipients.find((x) => x.id === rid);
    if (!r) throw notFound("telegram.recipient", { id: rid });
    return r;
  }

  async patchRecipient(rid: string, p: { status?: "active" | "paused"; subscriptions?: string[] }) {
    const r = this.getRecipient(rid);
    if (p.status) {
      if (r.status === "stopped" && p.status === "active") throw new AppError("agent.telegram.recipientStopped", 409, { id: rid });
      if (r.status !== p.status && r.status !== "stopped") {
        r.status = p.status;
        r.statusAt = this.#iso();
      }
    }
    if (p.subscriptions) {
      for (const f of p.subscriptions) this.getFeed(f);
      r.subscriptions = [...new Set(p.subscriptions)];
    }
    await this.#save();
    return r;
  }

  async removeRecipient(rid: string) {
    this.getRecipient(rid);
    this.#s.recipients = this.#s.recipients.filter((r) => r.id !== rid);
    await this.#save();
    this.#event("telegram.recipientRemoved", { recipientId: rid });
  }

  async #sendParts(r: Recipient, parts: string[], test = false): Promise<Delivery> {
    const messageIds: number[] = [];
    try {
      for (const p of parts) messageIds.push(await this.queue.send(r.chatId, p));
      return { recipientId: r.id, status: "sent", messageIds, at: this.#iso(), ...(test ? { test } : {}) };
    } catch (e) {
      const code = codeOf(e);
      if (code === "agent.telegram.blocked") {
        r.status = "unreachable";
        r.statusAt = this.#iso();
        this.#event("telegram.recipientUnreachable", { recipientId: r.id });
      } else if (!(e instanceof TelegramError)) this.#log(`telegram gönderimi: ${(e as Error).message}`);
      return { recipientId: r.id, status: code === "agent.telegram.blocked" ? "unreachable" : "failed", messageIds, error: code, at: this.#iso(), ...(test ? { test } : {}) };
    }
  }

  async testRecipient(rid: string) {
    const r = this.getRecipient(rid);
    if (r.status === "stopped") throw new AppError("agent.telegram.recipientStopped", 409, { id: rid });
    this.api();
    const d = await this.#sendParts(r, [MSG.test], true);
    await this.#save();
    if (d.status !== "sent") throw new AppError(d.error ?? "agent.telegram.sendFailed", 502, { recipientId: rid });
    return { ok: true, messageIds: d.messageIds };
  }

  deliveriesOf(rid: string, limit = 100) {
    this.getRecipient(rid);
    const out = this.#s.issues.flatMap((i) => i.deliveries.filter((d) => d.recipientId === rid).map((d) => ({ ...d, issueId: i.id, feedId: i.feedId })));
    return out.sort((a, b) => b.at.localeCompare(a.at)).slice(0, limit);
  }

  // ---------------------------------------------------------------- feeds

  getFeed(fid: string): Feed {
    const f = this.#s.feeds.find((x) => x.id === fid);
    if (!f) throw notFound("telegram.feed", { id: fid });
    return f;
  }

  feedView(f: Feed) {
    return {
      ...f,
      running: this.#running.has(f.id),
      nextRun: f.enabled ? (nextRun({ when: f.when, anchorAt: f.anchorAt }, new Date(this.#now()))?.toISOString() ?? null) : null,
      recipientIds: this.#s.recipients.filter((r) => r.subscriptions.includes(f.id)).map((r) => r.id),
    };
  }

  async createFeed(input: FeedInput): Promise<Feed> {
    if (this.#s.feeds.length >= MAX_FEEDS) throw new AppError("agent.telegram.tooManyFeeds", 400, { max: MAX_FEEDS });
    const now = this.#iso();
    const f: Feed = { ...input, approval: { ...input.approval, sentCount: 0 }, id: id("f_"), createdAt: now, anchorAt: now, lastSlotAt: null };
    this.#s.feeds.push(f);
    await this.#save();
    return f;
  }

  async updateFeed(fid: string, input: FeedInput): Promise<Feed> {
    const f = this.getFeed(fid);
    const whenChanged = JSON.stringify(f.when) !== JSON.stringify(input.when);
    // Updated in place: a running pipeline holds this object.
    if (input.instructions === undefined) delete f.instructions;
    Object.assign(f, input, { approval: { ...input.approval, sentCount: f.approval.sentCount } });
    if (whenChanged) f.anchorAt = this.#iso();
    this.#nextAt.delete(f.id);
    await this.#save();
    return f;
  }

  async removeFeed(fid: string) {
    this.getFeed(fid);
    if (this.#running.has(fid)) throw new AppError("agent.telegram.feedRunning", 409, { id: fid });
    if (this.#s.issues.some((i) => i.feedId === fid && i.status === "sending")) throw new AppError("agent.telegram.feedRunning", 409, { id: fid });
    this.#s.feeds = this.#s.feeds.filter((f) => f.id !== fid);
    this.#s.issues = this.#s.issues.filter((i) => i.feedId !== fid);
    for (const r of this.#s.recipients) r.subscriptions = r.subscriptions.filter((x) => x !== fid);
    for (const i of this.#s.invites) i.feedIds = i.feedIds.filter((x) => x !== fid);
    this.#nextAt.delete(fid);
    await this.#save();
  }

  #subscribers(fid: string) {
    return this.#s.recipients.filter((r) => r.status === "active" && r.subscriptions.includes(fid));
  }

  // ---------------------------------------------------------------- runs

  /** Starts a run in the background and returns its issue (status researching). */
  async run(fid: string, kind: Issue["kind"], slotAt?: number): Promise<Issue> {
    const feed = this.getFeed(fid);
    if (this.#running.has(fid)) throw new AppError("agent.telegram.feedRunning", 409, { id: fid });
    if (kind !== "scheduled") {
      if (!this.#cfg().research) throw new AppError("agent.telegram.research.notConfigured", 409);
      if (kind === "manual") {
        this.api();
        if (this.#subscribers(fid).length === 0) throw new AppError("agent.telegram.noRecipients", 409, { id: fid });
      }
    }
    // Reserved before the first await, so two concurrent run()/tick() calls can't both start this feed.
    let settle!: () => void;
    const entry = new Promise<void>((r) => (settle = r));
    this.#running.set(fid, entry);
    const release = () => {
      if (this.#running.get(fid) === entry) this.#running.delete(fid);
      settle();
    };
    const now = this.#now();
    const issue: Issue = {
      id: id("n_"),
      feedId: fid,
      kind,
      createdAt: this.#iso(now),
      ...(slotAt !== undefined ? { slotAt: this.#iso(slotAt) } : {}),
      deadlineAt: this.#iso((slotAt ?? now) + feed.deadlineMinutes * 60_000),
      status: "researching",
      items: [],
      renderedParts: [],
      deliveries: [],
    };
    this.#s.issues.push(issue);
    this.#prune(fid);
    await this.#save(); // never rejects (errors are logged)
    this.#event("telegram.started", { feedId: fid, issueId: issue.id, kind });
    void this.#pipeline(feed, issue)
      .catch((e) => this.#log(`telegram bülteni: ${codeOf(e)}`))
      .finally(release);
    return issue;
  }

  #prune(fid: string) {
    const mine = this.#s.issues.filter((i) => i.feedId === fid && !ACTIVE_ISSUE.has(i.status));
    const drop = new Set(mine.slice(0, Math.max(0, mine.length - ISSUES_PER_FEED)).map((i) => i.id));
    if (drop.size) this.#s.issues = this.#s.issues.filter((i) => !drop.has(i.id));
  }

  /** Issues of this feed actually sent in the last 14 days. */
  #recentSent(fid: string, exceptId: string) {
    const since = this.#now() - HISTORY_DAYS * DAY;
    return this.#s.issues.filter((i) => i.feedId === fid && i.id !== exceptId && i.status === "sent" && Date.parse(i.createdAt) >= since);
  }

  async #pipeline(feed: Feed, issue: Issue) {
    try {
      const result = await this.#research(feed, issue);
      const recent = this.#recentSent(feed.id, issue.id);
      const urls = recent.flatMap((i) => i.items.flatMap((it) => it.sources.map((s) => s.url)));
      const v = await validateItems(
        result.items,
        result.seenUrls,
        feed,
        { urlKeys: new Set(urls.map(urlKey).filter((k): k is string => k !== null)), headlines: recent.flatMap((i) => i.items.map((it) => it.headline)) },
        this.#linkRequest,
        { timeoutMs: this.#reachTimeoutMs },
      );
      if (this.#stopped) throw new AppError("agent.telegram.interrupted", 503);
      issue.items = v.items;
      issue.stats = v.stats;
      issue.models = result.models;
      if (v.items.length === 0) {
        if (issue.kind !== "preview" && feed.skipIfNothingNew) {
          issue.status = "skipped";
          issue.finishedAt = this.#iso();
          await this.#save();
          this.#event("telegram.skipped", { feedId: feed.id, issueId: issue.id, reason: "nothingNew" });
          return;
        }
        throw new AppError("agent.telegram.noItems", 422);
      }
      issue.renderedParts = renderIssue({ feedName: feed.name, windowHours: feed.windowHours, items: v.items, models: result.models, at: new Date(this.#now()) });
      if (issue.kind === "preview") {
        issue.status = "preview";
        issue.finishedAt = this.#iso();
        await this.#save();
        this.#event("telegram.previewReady", { feedId: feed.id, issueId: issue.id, items: v.items.length });
        return;
      }
      const a = feed.approval;
      if (a.mode === "ask" || (a.mode === "firstN" && a.sentCount < a.n)) {
        issue.status = "awaiting_approval";
        issue.expiresAt = this.#iso(Date.parse(issue.deadlineAt) + APPROVAL_GRACE);
        await this.#save();
        await this.#notify({
          key: "telegram.approval",
          params: { feed: feed.name, feedId: feed.id, issueId: issue.id, items: v.items.length, recipients: this.#subscribers(feed.id).length },
          data: { feedId: feed.id, issueId: issue.id },
          link: `tiphys://telegram/issues/${issue.id}`,
          priority: "high",
        });
        return;
      }
      await this.#deliver(feed, issue);
    } catch (e) {
      const code = this.#stopped ? "agent.telegram.interrupted" : codeOf(e);
      if (!(e instanceof AppError)) this.#log(`telegram bülteni başarısız: ${(e as Error).message}`);
      issue.status = "failed";
      issue.error = code;
      issue.finishedAt = this.#iso();
      await this.#save();
      if (issue.kind === "preview") this.#event("telegram.previewFailed", { feedId: feed.id, issueId: issue.id, reason: code });
      else if (code === PC_UNREACHABLE) {
        await this.#notify({ key: "telegram.pcUnreachable", params: { feed: feed.name, feedId: feed.id, issueId: issue.id }, link: `tiphys://telegram/issues/${issue.id}`, priority: "high" });
      } else {
        await this.#notify({ key: "telegram.failed", params: { feed: feed.name, feedId: feed.id, issueId: issue.id, reason: code }, link: `tiphys://telegram/issues/${issue.id}`, priority: "high" });
      }
    }
  }

  /**
   * Sends a research job to the PC and polls it (10 s) until done/failed or the deadline; WoL once if unreachable.
   * A job the PC lost (404, or failed as interrupted by a PC agent restart) is created again while the deadline allows;
   * when atlas gives up (deadline, shutdown) the PC job is cancelled so it doesn't keep running for nothing.
   */
  async #research(feed: Feed, issue: Issue): Promise<ResearchResult> {
    const cfg = this.#cfg().research;
    if (!cfg) throw new AppError("agent.telegram.research.notConfigured", 409);
    const client = new ResearchClient({ url: cfg.url, token: cfg.token, fetch: this.#fetch });
    // The PC accepts ≤500 URLs and ≤100 000 characters in total: the newest are kept.
    const excludeUrls: string[] = [];
    let chars = 0;
    for (const u of [...new Set(this.#recentSent(feed.id, issue.id).flatMap((i) => i.items.flatMap((it) => it.sources.map((s) => s.url))))].reverse()) {
      if (excludeUrls.length >= 500 || chars + u.length + 1 > 90_000) break;
      excludeUrls.push(u);
      chars += u.length + 1;
    }
    const req = {
      topic: feed.topic,
      ...(feed.instructions ? { instructions: feed.instructions } : {}),
      windowHours: feed.windowHours,
      language: feed.language,
      minItems: feed.minItems,
      maxItems: feed.maxItems,
      maxSourcesPerItem: feed.maxSourcesPerItem,
      allowDomains: feed.allowDomains,
      blockDomains: feed.blockDomains,
      excludeUrls,
      editor: true,
    };
    const deadline = Date.parse(issue.deadlineAt);
    let jobId: string | null = null;
    let woke = false;
    let last: string | null = null;
    const giveUp = async (e: AppError) => {
      if (jobId) await client.cancel(jobId).catch(() => {});
      return e;
    };
    for (;;) {
      if (this.#stopped) throw await giveUp(new AppError("agent.telegram.interrupted", 503));
      if (this.#now() >= deadline) throw await giveUp(last === PC_UNREACHABLE ? researchError("unreachable", 503) : researchError("timeout", 504));
      try {
        if (!jobId) jobId = await client.create(req);
        else {
          const job = await client.get(jobId);
          if (!job || (job.status === "failed" && job.error?.code === "agent.research.interrupted")) jobId = null;
          else if (job.status === "done") {
            if (!job.result) throw researchError("badResponse", 502);
            return job.result;
          } else if (job.status === "failed") throw researchError("failed", 502, { error: job.error?.code ?? "" });
        }
        last = null;
      } catch (e) {
        const code = codeOf(e);
        if (code === PC_UNREACHABLE) {
          last = code;
          if (!woke) {
            woke = true;
            const sent = await this.#wakePc(cfg.wakeHostId);
            // Without a wake target the PC isn't waited for (an already started job is still polled).
            if (!sent && !jobId) throw e;
          }
        } else if (code === "agent.telegram.research.busy") last = code;
        else throw e;
      }
      await this.#sleep(Math.min(this.#researchPollMs, Math.max(0, deadline - this.#now())));
    }
  }

  async #wakePc(hostId: string | undefined): Promise<boolean> {
    const t = hostId ? this.#cfg().wake.targets.find((x) => x.hostId === hostId) : undefined;
    if (!t) return false;
    try {
      await this.#wake(t);
      this.#event("telegram.wakeSent", { hostId: t.hostId });
    } catch (e) {
      this.#log(`Wake-on-LAN gönderilemedi: ${(e as Error).message}`);
    }
    return true;
  }

  async #deliver(feed: Feed, issue: Issue) {
    issue.status = "sending";
    await this.#save();
    const recipients = this.#subscribers(feed.id);
    const deliveries = await Promise.all(recipients.map((r) => this.#sendParts(r, issue.renderedParts)));
    issue.deliveries.push(...deliveries);
    const ok = deliveries.filter((d) => d.status === "sent").length;
    const failed = deliveries.length - ok;
    issue.finishedAt = this.#iso();
    if (recipients.length > 0 && ok === 0) {
      issue.status = "failed";
      issue.error = this.#stopped ? "agent.telegram.interrupted" : "agent.telegram.deliveryFailed";
    } else {
      issue.status = "sent";
      feed.approval.sentCount++;
    }
    await this.#save();
    if (issue.status === "sent") {
      await this.#notify({
        key: "telegram.sent",
        params: { feed: feed.name, feedId: feed.id, issueId: issue.id, items: issue.items.length, recipients: ok, failed },
        link: `tiphys://telegram/issues/${issue.id}`,
      });
    } else {
      await this.#notify({ key: "telegram.failed", params: { feed: feed.name, feedId: feed.id, issueId: issue.id, reason: issue.error! }, link: `tiphys://telegram/issues/${issue.id}`, priority: "high" });
    }
  }

  // ---------------------------------------------------------------- issues and approval

  getIssue(iid: string): Issue {
    const i = this.#s.issues.find((x) => x.id === iid);
    if (!i) throw notFound("telegram.issue", { id: iid });
    return i;
  }

  issueSummary(i: Issue) {
    const { items, renderedParts, deliveries, ...rest } = i;
    return {
      ...rest,
      itemCount: items.length,
      partCount: renderedParts.length,
      deliveryCounts: {
        sent: deliveries.filter((d) => d.status === "sent" && !d.test).length,
        failed: deliveries.filter((d) => d.status !== "sent" && !d.test).length,
        tests: deliveries.filter((d) => d.test).length,
      },
    };
  }

  listIssues(feedId?: string, limit = 50) {
    return this.#s.issues
      .filter((i) => !feedId || i.feedId === feedId)
      .sort((a, b) => b.createdAt.localeCompare(a.createdAt))
      .slice(0, limit);
  }

  async #expire(i: Issue) {
    i.status = "expired";
    i.finishedAt = this.#iso();
    await this.#save();
    const feed = this.#s.feeds.find((f) => f.id === i.feedId);
    await this.#notify({
      key: "telegram.failed",
      params: { feed: feed?.name ?? "", feedId: i.feedId, issueId: i.id, reason: "agent.telegram.approvalExpired" },
      link: `tiphys://telegram/issues/${i.id}`,
    });
  }

  async #awaiting(iid: string): Promise<Issue> {
    const i = this.getIssue(iid);
    if (i.status !== "awaiting_approval") throw new AppError("agent.telegram.issueNotAwaiting", 409, { id: iid, status: i.status });
    if (i.expiresAt && Date.parse(i.expiresAt) <= this.#now()) {
      await this.#expire(i);
      throw new AppError("agent.telegram.issueExpired", 409, { id: iid });
    }
    return i;
  }

  /** Approves and starts sending in the background (the notification action returns at once). */
  async approve(iid: string): Promise<Issue> {
    const i = await this.#awaiting(iid);
    const feed = this.getFeed(i.feedId);
    i.status = "sending";
    this.#event("telegram.approved", { feedId: feed.id, issueId: i.id });
    void this.#track(this.#deliver(feed, i).catch((e) => this.#log(`telegram gönderimi: ${codeOf(e)}`)));
    return i;
  }

  async reject(iid: string): Promise<Issue> {
    const i = await this.#awaiting(iid);
    i.status = "rejected";
    i.finishedAt = this.#iso();
    await this.#save();
    this.#event("telegram.rejected", { feedId: i.feedId, issueId: i.id });
    return i;
  }

  /** Sends an issue's rendered parts to one recipient (test; regardless of subscription). */
  async sendTest(iid: string, rid: string): Promise<Delivery> {
    const i = this.getIssue(iid);
    if (i.renderedParts.length === 0) throw new AppError("agent.telegram.issueNotRendered", 409, { id: iid });
    const r = this.getRecipient(rid);
    if (r.status === "stopped") throw new AppError("agent.telegram.recipientStopped", 409, { id: rid });
    this.api();
    const d = await this.#sendParts(r, i.renderedParts, true);
    i.deliveries.push(d);
    await this.#save();
    this.#event("telegram.testSent", { issueId: i.id, recipientId: r.id, ok: d.status === "sent" ? 1 : 0 });
    return d;
  }

  // ---------------------------------------------------------------- scheduler

  /**
   * Latest schedule slot of the feed that is due (≤ now) and not handled yet, or null. Slots are looked for after
   * max(anchorAt, lastSlotAt, now − 8 days); for daily/weekly feeds a slot within 2 h of the previous one is the
   * repeated autumn DST hour and is ignored (like the Claude scheduler).
   */
  dueSlot(f: Feed, now = this.#now()): number | null {
    const key = `${JSON.stringify(f.when)}|${f.anchorAt}|${f.lastSlotAt}`;
    const cached = this.#nextAt.get(f.id);
    if (cached && cached.key === key && cached.at > now) return null;
    const last = f.lastSlotAt ? Date.parse(f.lastSlotAt) : -Infinity;
    let s = Math.max(Date.parse(f.anchorAt), last, now - 8 * DAY);
    let due: number | null = null;
    for (let i = 0; i < 50_000; i++) {
      const n = nextRun({ when: f.when, anchorAt: f.anchorAt }, new Date(s));
      if (!n) break;
      const t = n.getTime();
      if (t > now) {
        this.#nextAt.set(f.id, { key, at: t });
        break;
      }
      s = t;
      if (f.when.kind !== "interval" && (t - last < 2 * HOUR || (due !== null && t - due < 2 * HOUR))) continue;
      due = t;
    }
    return due;
  }

  async tick() {
    const now = this.#now();
    for (const f of [...this.#s.feeds]) {
      if (!f.enabled) continue;
      const due = this.dueSlot(f, now);
      if (due === null) continue;
      f.lastSlotAt = this.#iso(due);
      this.#nextAt.delete(f.id);
      await this.#save();
      if (now - due > f.deadlineMinutes * 60_000) this.#event("telegram.missed", { feedId: f.id, slotAt: this.#iso(due) });
      else if (this.#running.has(f.id)) this.#event("telegram.skipped", { feedId: f.id, reason: "running" });
      else if (this.#subscribers(f.id).length === 0) this.#event("telegram.skipped", { feedId: f.id, reason: "noRecipients" });
      else {
        try {
          await this.run(f.id, "scheduled", due);
        } catch (e) {
          // e.g. a manual run of the same feed started meanwhile
          this.#event("telegram.skipped", { feedId: f.id, reason: codeOf(e) === "agent.telegram.feedRunning" ? "running" : "error" });
        }
      }
    }
    for (const i of this.#s.issues) {
      if (i.status === "awaiting_approval" && i.expiresAt && Date.parse(i.expiresAt) <= now) await this.#expire(i);
    }
    this.#ensurePolling();
  }
}
