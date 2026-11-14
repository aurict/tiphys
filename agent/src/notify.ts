// Telefona bildirim: UnifiedPush (dağıtıcı = telefondaki ntfy uygulaması, sunucu = kendi ntfy sunucun).
// Telefon kayıt olurken uç nokta adresini ve WebPush açık anahtarını (pubKey + auth) ajana bildirir.
// Ajan JSON'u RFC 8291 (aes128gcm) ile şifreleyip gönderir; ntfy sunucusu içeriği okuyamaz.
// Metni telefondaki Tiphys seçili dilde oluşturur. Google/Firebase kullanılmaz.
import webpush from "web-push";
import type { AgentConfig } from "./config.ts";

export interface Notice {
  key: string; // ör. "claude.done", "claude.waiting", "host.offline"
  params?: Record<string, string | number>;
  /** Uygulamada açılacak ekran, ör. "tiphys://claude/abc" */
  link?: string;
  priority?: "low" | "default" | "high";
}

export function payloadOf(n: Notice) {
  return JSON.stringify({ v: 1, key: n.key, params: n.params ?? {}, link: n.link ?? null, at: new Date().toISOString() });
}

export class Notifier {
  #getConfig: () => AgentConfig;
  #log: (msg: string, err?: unknown) => void;

  constructor(getConfig: () => AgentConfig, log: (msg: string, err?: unknown) => void) {
    this.#getConfig = getConfig;
    this.#log = log;
  }

  /** Kayıtlı tüm uç noktalara gönderir; başarılı gönderim sayısını döner. */
  async send(n: Notice): Promise<number> {
    const { endpoints, token } = this.#getConfig().push;
    const body = payloadOf(n);
    const results = await Promise.all(
      endpoints.map(async (e) => {
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
    return results.filter(Boolean).length;
  }
}
