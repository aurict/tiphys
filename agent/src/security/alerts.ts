// Critical security notices to the owner's Telegram (PLAN.md §15 component 9): a short title only (host + what),
// never paths, users or values. Push notifications are unchanged; this is an extra channel for when the phone app
// itself may be the problem. Needs the "telegram" feature's bot and security.alerts.telegramRecipient (a recipient id).
import { readFile } from "node:fs/promises";
import type { Notice, NoticeObserver } from "../notify.ts";
import type { Ctx } from "../server.ts";
import { TelegramApi } from "../telegram/api.ts";
import { telegramStatePath } from "../telegram/state.ts";

const TITLES: Record<string, string> = {
  "security.trap": "tuzak tetiklendi",
  "security.change": "beklenmeyen güvenlik değişikliği",
  "security.secretFound": "sır bulundu",
  "blackbox.broken": "kara kutu zinciri bozuk",
  "security.lockdown": "kilitleme yapıldı",
};

/** Which notices are critical enough for the extra channel. */
export function isCritical(n: Notice): boolean {
  if (n.key === "security.change") return n.params?.severity === "critical";
  return n.key in TITLES && n.key !== "security.change";
}

export function alertText(n: Notice): string {
  const host = String(n.params?.host ?? "?").replace(/[<>&]/g, "").slice(0, 60);
  const what = n.key === "security.trap" && n.params?.trap === "test" ? "deneme uyarısı" : TITLES[n.key] ?? n.key;
  return `🚨 Tiphys güvenlik · ${host} · ${what}`;
}

/** Sends plain text (HTML-escaped by the caller) to the owner's Telegram recipient; false if not configured. */
export async function sendOwnerTelegram(ctx: Ctx, text: string, opts: { fetch?: typeof fetch } = {}): Promise<boolean> {
  const c = ctx.store.get();
  const rid = c.security.alerts.telegramRecipient;
  if (!rid || !c.telegram) return false;
  const raw = await readFile(telegramStatePath(ctx.store.path), "utf8");
  const st = JSON.parse(raw) as { recipients?: Array<{ id: string; chatId: number; status: string }> };
  const r = st.recipients?.find((x) => x.id === rid && x.status !== "stopped");
  if (!r) return false;
  await new TelegramApi(c.telegram.botToken, opts.fetch ? { fetch: opts.fetch } : {}).sendMessage(r.chatId, text);
  return true;
}

export function alertRelay(ctx: Ctx, opts: { fetch?: typeof fetch } = {}): NoticeObserver {
  return (n) => {
    if (!isCritical(n)) return;
    void sendOwnerTelegram(ctx, alertText(n), opts).catch(() => {});
  };
}
