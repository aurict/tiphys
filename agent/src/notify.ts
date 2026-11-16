// Notifications to the phone: UnifiedPush (distributor = the ntfy app on the phone, server = your own ntfy server).
// On registration the phone tells the agent its endpoint URL and WebPush public key (pubKey + auth).
// The agent encrypts the JSON with RFC 8291 (aes128gcm) and sends it; the ntfy server can't read the content.
// Tiphys on the phone builds the text in the selected language. Google/Firebase are not used.
import webpush from "web-push";
import type { AgentConfig } from "./config.ts";
import type { EventLog } from "./events.ts";

export interface Notice {
  key: string; // e.g. "claude.done", "claude.waiting", "host.offline"
  params?: Record<string, string | number>;
  /** Screen to open in the app, e.g. "tiphys://claude/abc" */
  link?: string;
  priority?: "low" | "default" | "high";
  /** Extra info for notification buttons (e.g. claude.waiting: session and permission request id). */
  data?: Record<string, string>;
  /**
   * Sensitive content (e.g. clipboard text): not written to the event stream (events.jsonl) and sent only to endpoints
   * with a WebPush key (end-to-end encrypted); plain text never goes to ntfy.
   */
  sensitive?: boolean;
}

export function payloadOf(n: Notice) {
  return JSON.stringify({ v: 1, key: n.key, params: n.params ?? {}, link: n.link ?? null, ...(n.data ? { data: n.data } : {}), at: new Date().toISOString() });
}

/**
 * Parameters written to the event stream (persisted on disk, read via GET /v1/events). Command lines may contain
 * passwords (`mysql -pGIZLI …`): the notification shows the full command, the persistent record keeps only the program name.
 */
export function eventParams(n: Notice): Record<string, string | number> | undefined {
  if (!n.params || !n.key.startsWith("command.") || typeof n.params.command !== "string") return n.params;
  const program = n.params.command.trim().split(/\s+/)[0] ?? "";
  return { ...n.params, command: program.split("/").pop() ?? program };
}

export class Notifier {
  #getConfig: () => AgentConfig;
  #log: (msg: string, err?: unknown) => void;
  /** Every notification is also written to the event stream (created next to the settings file if there's no buildApp). */
  events: EventLog | null;

  constructor(getConfig: () => AgentConfig, log: (msg: string, err?: unknown) => void, events: EventLog | null = null) {
    this.#getConfig = getConfig;
    this.#log = log;
    this.events = events;
  }

  /** Records an event (if not sensitive) and sends to all registered endpoints; returns the number of successful sends. */
  async send(n: Notice): Promise<number> {
    const { endpoints, token } = this.#getConfig().push;
    const body = payloadOf(n);
    const recorded = n.sensitive ? undefined : this.events?.record({ key: n.key, params: eventParams(n), link: n.link }, (e) => this.#log("olay yazılamadı", e));
    const results = await Promise.all(
      endpoints.map(async (e) => {
        if (n.sensitive && !(e.pubKey && e.auth)) return false;
        try {
          let headers: Record<string, string> = { "Content-Type": "application/json" };
          let data: string | Buffer = body;
          if (e.pubKey && e.auth) {
            const req = webpush.generateRequestDetails({ endpoint: e.url, keys: { p256dh: e.pubKey, auth: e.auth } }, body, {
              TTL: 86400,
              urgency: n.priority === "high" ? "high" : "normal",
              contentEncoding: "aes128gcm",
            });
            headers = Object.fromEntries(Object.entries(req.headers).map(([k, v]) => [k, String(v)]));
            data = req.body;
          }
          if (token) headers.Authorization = `Bearer ${token}`;
          const res = await fetch(e.url, { method: "POST", headers, body: typeof data === "string" ? data : new Uint8Array(data), signal: AbortSignal.timeout(10000) });
          if (!res.ok) this.#log(`bildirim uç noktası ${e.deviceId} yanıtı ${res.status}`);
          return res.ok;
        } catch (err) {
          this.#log(`bildirim uç noktasına ulaşılamadı: ${e.deviceId}`, err);
          return false;
        }
      }),
    );
    await recorded;
    return results.filter(Boolean).length;
  }
}
