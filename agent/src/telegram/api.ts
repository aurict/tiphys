// Telegram Bot API client (built-in fetch) and the outgoing send queue ("telegram" feature).
// The bot token is part of every request URL (https://api.telegram.org/bot<token>/<method>): neither the token nor a
// URL containing it is ever logged or put into an error. Failures are mapped to agent.telegram.* codes; the fetch
// error itself (whose message may contain the URL) is dropped.
import { AppError } from "../errors.ts";

export type Fetch = typeof fetch;

export interface TgUser {
  id: number;
  is_bot?: boolean;
  first_name: string;
  last_name?: string;
  username?: string;
}

export interface TgChat {
  id: number;
  type: "private" | "group" | "supergroup" | "channel";
  first_name?: string;
  last_name?: string;
  username?: string;
}

export interface TgMessage {
  message_id: number;
  date: number;
  chat: TgChat;
  from?: TgUser;
  text?: string;
}

export interface TgUpdate {
  update_id: number;
  message?: TgMessage;
  channel_post?: TgMessage;
  my_chat_member?: { chat: TgChat };
}

/** Bot token shape as issued by BotFather (checked before it is ever put into a URL). */
export const BOT_TOKEN_RE = /^\d{5,15}:[A-Za-z0-9_-]{30,64}$/;

export class TelegramError extends AppError {
  /** Seconds to wait (429 only). */
  retryAfter?: number;
}

/** Errors worth retrying: the message was certainly not delivered (rate limit, connection failure, server error). */
const RETRYABLE = new Set(["agent.telegram.apiRateLimited", "agent.telegram.unreachable", "agent.telegram.apiFailed"]);

export class TelegramApi {
  readonly #token: string;
  readonly #fetch: Fetch;
  readonly #base: string;
  readonly #timeoutMs: number;

  constructor(token: string, opts: { fetch?: Fetch; baseUrl?: string; timeoutMs?: number } = {}) {
    if (!BOT_TOKEN_RE.test(token)) throw new TelegramError("agent.telegram.invalidToken", 400);
    this.#token = token;
    this.#fetch = opts.fetch ?? fetch;
    this.#base = opts.baseUrl ?? "https://api.telegram.org";
    this.#timeoutMs = opts.timeoutMs ?? 15_000;
  }

  async call<T>(method: string, body: Record<string, unknown> = {}, opts: { timeoutMs?: number; signal?: AbortSignal } = {}): Promise<T> {
    const timeout = AbortSignal.timeout(opts.timeoutMs ?? this.#timeoutMs);
    const signal = opts.signal ? AbortSignal.any([timeout, opts.signal]) : timeout;
    let res: Response;
    try {
      res = await this.#fetch(`${this.#base}/bot${this.#token}/${method}`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
        signal,
      });
    } catch {
      if (opts.signal?.aborted) throw new TelegramError("agent.telegram.aborted", 503);
      throw new TelegramError(timeout.aborted ? "agent.telegram.timeout" : "agent.telegram.unreachable", 502);
    }
    let j: { ok?: boolean; result?: T; error_code?: number; description?: string; parameters?: { retry_after?: number } };
    try {
      j = (await res.json()) as typeof j;
    } catch {
      throw new TelegramError(res.status >= 500 ? "agent.telegram.apiFailed" : "agent.telegram.badResponse", 502, { status: res.status });
    }
    if (j.ok === true) return j.result as T;
    const code = j.error_code ?? res.status;
    // Telegram's description never contains the token; it's shortened anyway.
    const description = String(j.description ?? "").slice(0, 200);
    if (code === 401 || code === 404) throw new TelegramError("agent.telegram.invalidToken", 400);
    if (code === 403) throw new TelegramError("agent.telegram.blocked", 502, { description });
    if (code === 429) {
      const retryAfter = Math.min(Math.max(Number(j.parameters?.retry_after) || 1, 1), 300);
      const e = new TelegramError("agent.telegram.apiRateLimited", 429, { retryAfter });
      e.retryAfter = retryAfter;
      throw e;
    }
    if (code >= 500) throw new TelegramError("agent.telegram.apiFailed", 502, { status: code });
    throw new TelegramError("agent.telegram.badRequest", 502, { status: code, description });
  }

  getMe(): Promise<TgUser> {
    return this.call<TgUser>("getMe");
  }

  async sendMessage(chatId: number, text: string): Promise<{ message_id: number }> {
    return this.call("sendMessage", { chat_id: chatId, text, parse_mode: "HTML", link_preview_options: { is_disabled: true } });
  }

  /** Long poll (timeout ≤ 25 s). */
  getUpdates(offset: number, timeoutSec: number, signal?: AbortSignal): Promise<TgUpdate[]> {
    const timeout = Math.min(Math.max(timeoutSec, 0), 25);
    return this.call<TgUpdate[]>(
      "getUpdates",
      { offset, timeout, allowed_updates: ["message", "my_chat_member", "channel_post"] },
      { timeoutMs: (timeout + 10) * 1000, signal },
    );
  }

  leaveChat(chatId: number): Promise<boolean> {
    return this.call<boolean>("leaveChat", { chat_id: chatId });
  }
}

export interface SendQueueOpts {
  send: (chatId: number, text: string) => Promise<{ message_id: number }>;
  now?: () => number;
  sleep?: (ms: number) => Promise<void>;
  perChatMs?: number;
  globalPerSec?: number;
  maxAttempts?: number;
}

/**
 * Outgoing messages: at most 1 message/s per chat and 25/s overall (Telegram's limits); messages to the same chat
 * keep their order. 429 → wait `retry_after`, connection/server errors → short backoff; at most 3 attempts.
 * 403 (bot blocked) and other errors are not retried. close() (agent shutdown) ends every wait at once and fails the
 * messages not sent yet with agent.telegram.shutdown (a request already in flight still completes).
 */
export class SendQueue {
  readonly #send: SendQueueOpts["send"];
  readonly #now: () => number;
  readonly #sleep: (ms: number) => Promise<void>;
  readonly #perChatMs: number;
  readonly #globalPerSec: number;
  readonly #maxAttempts: number;
  #chains = new Map<number, Promise<unknown>>();
  #lastPerChat = new Map<number, number>();
  #recent: number[] = [];
  #closed = false;
  #wakers = new Set<() => void>();

  constructor(o: SendQueueOpts) {
    this.#send = o.send;
    this.#now = o.now ?? Date.now;
    this.#sleep = o.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms)));
    this.#perChatMs = o.perChatMs ?? 1000;
    this.#globalPerSec = o.globalPerSec ?? 25;
    this.#maxAttempts = o.maxAttempts ?? 3;
  }

  close() {
    this.#closed = true;
    for (const w of [...this.#wakers]) w();
  }

  /** Sleep that ends early (with the shutdown error) when the queue is closed. */
  async #wait(ms: number) {
    if (!this.#closed) {
      let wake = () => {};
      await Promise.race([this.#sleep(ms), new Promise<void>((r) => this.#wakers.add((wake = r)))]);
      this.#wakers.delete(wake);
    }
    this.#checkOpen();
  }

  #checkOpen() {
    if (this.#closed) throw new TelegramError("agent.telegram.shutdown", 503);
  }

  /** Queues a message; resolves with the Telegram message id. */
  send(chatId: number, text: string): Promise<number> {
    const prev = this.#chains.get(chatId) ?? Promise.resolve();
    const p = prev.catch(() => {}).then(() => this.#deliver(chatId, text));
    this.#chains.set(chatId, p);
    void p.finally(() => {
      if (this.#chains.get(chatId) === p) this.#chains.delete(chatId);
    }).catch(() => {});
    return p;
  }

  async #deliver(chatId: number, text: string): Promise<number> {
    for (let attempt = 1; ; attempt++) {
      this.#checkOpen();
      await this.#slot(chatId);
      try {
        return (await this.#send(chatId, text)).message_id;
      } catch (e) {
        if (!(e instanceof TelegramError) || !RETRYABLE.has(e.code) || attempt >= this.#maxAttempts) throw e;
        await this.#wait(e.code === "agent.telegram.apiRateLimited" ? (e.retryAfter ?? 1) * 1000 : 1000 * attempt);
      }
    }
  }

  async #slot(chatId: number) {
    const last = this.#lastPerChat.get(chatId);
    if (last !== undefined) {
      const wait = last + this.#perChatMs - this.#now();
      if (wait > 0) await this.#wait(wait);
    }
    // Sliding one-second window over all chats; check and reserve happen without an await in between.
    for (;;) {
      const t = this.#now();
      this.#recent = this.#recent.filter((x) => t - x < 1000);
      if (this.#recent.length < this.#globalPerSec) {
        this.#recent.push(t);
        break;
      }
      await this.#wait(Math.max(1, this.#recent[0]! + 1000 - t));
    }
    this.#lastPerChat.set(chatId, this.#now());
  }
}
