// Newsletter → Telegram HTML (parse_mode HTML). Every piece of text and every attribute is escaped; only http(s)
// links are emitted (validation already drops others, this is a second guard). Messages are split at item
// boundaries so each part stays under Telegram's 4096-character limit (JS string length = UTF-16 code units); a single
// item that wouldn't fit even alone is shortened (summary first, then headline), measured after escaping.

export const MAX_MESSAGE = 4096;

export interface RenderSource {
  title?: string;
  url: string;
}

export interface RenderItem {
  headline: string;
  summary: string;
  sources: RenderSource[];
}

export function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Hostname without "www." for an http(s) URL; null for anything else. */
export function siteName(url: string): string | null {
  try {
    const u = new URL(url);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    return u.hostname.replace(/^www\./, "");
  } catch {
    return null;
  }
}

/** Display name of a model id: gemini-4-argon-high → "Gemini 4 Argon", any Claude model → "Claude". */
export function modelLabel(id: string): string {
  const s = id.trim().toLowerCase();
  if (/claude|sonnet|opus|haiku/.test(s)) return "Claude";
  const g = /^gemini-([\d.]+)-([a-z]+)/.exec(s);
  if (g) return `Gemini ${g[1]} ${g[2]![0]!.toUpperCase()}${g[2]!.slice(1)}`;
  return id.trim();
}

const two = (n: number) => String(n).padStart(2, "0");

/** Escaped s, or its longest whole-code-point prefix + "…" whose escaped form fits max characters ("" if none). */
function fitEscaped(s: string, max: number): string {
  const full = escapeHtml(s);
  if (full.length <= max) return full;
  if (max < 1) return "";
  const cps = Array.from(s);
  let lo = 0;
  let hi = cps.length;
  while (lo < hi) {
    const mid = (lo + hi + 1) >> 1;
    if (escapeHtml(cps.slice(0, mid).join("").trimEnd()).length + 1 <= max) lo = mid;
    else hi = mid - 1;
  }
  return `${escapeHtml(cps.slice(0, lo).join("").trimEnd())}…`;
}

export function renderIssue(o: {
  feedName: string;
  windowHours: number;
  items: RenderItem[];
  models: { research: string; editor?: string | null };
  /** Render time; date and HH:MM are shown in the agent's local time zone. */
  at: Date;
  limit?: number;
}): string[] {
  const limit = o.limit ?? MAX_MESSAGE;
  const emoji = o.windowHours > 24 ? "🗞️" : "📰";
  const date = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "long", year: "numeric" }).format(o.at);
  const header = `${emoji} <b>${escapeHtml(o.feedName)}</b> · ${escapeHtml(date)}`;
  const models = [o.models.research, o.models.editor].filter((m): m is string => !!m).map(modelLabel);
  const footer = `<i>${escapeHtml(["Tiphys", models.join(" + "), `${two(o.at.getHours())}:${two(o.at.getMinutes())}`].filter(Boolean).join(" · "))}</i>`;

  const blocks = o.items.map((it, i) => {
    const links = it.sources
      .map((s) => ({ s, site: siteName(s.url) }))
      .filter((x): x is { s: RenderSource; site: string } => x.site !== null)
      .slice(0, 3)
      .map(({ s, site }) => `<a href="${escapeHtml(s.url)}">${escapeHtml(site)}</a>`);
    const make = (h: string, s: string, l: string) => `${i + 1}. <b>${h}</b>\n${s}${l}`;
    const headline = escapeHtml(it.headline);
    let linkPart = links.length ? `\nKaynak: ${links.join(" · ")}` : "";
    const whole = make(headline, escapeHtml(it.summary), linkPart);
    if (whole.length <= limit) return whole;
    if (make("", "", linkPart).length > limit) linkPart = "";
    const summaryRoom = limit - make(headline, "", linkPart).length;
    if (summaryRoom >= 0) return make(headline, fitEscaped(it.summary, summaryRoom), linkPart);
    return make(fitEscaped(it.headline, limit - make("", "", linkPart).length), "", linkPart);
  });

  const parts: string[] = [];
  let cur = header;
  for (const b of [...blocks, footer]) {
    const next = `${cur}\n\n${b}`;
    if (next.length <= limit) cur = next;
    else {
      parts.push(cur);
      cur = b;
    }
  }
  parts.push(cur);
  return parts;
}
