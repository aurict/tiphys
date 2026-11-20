// Telegram newsletters: fake Telegram API, fake PC research agent and fake news sites behind one injected fetch,
// plus a manual clock (sleep advances it), so nothing touches the network and nothing really waits.
import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { SendQueue, TelegramApi, TelegramError, type TgUpdate } from "../src/telegram/api.ts";
import { escapeHtml, MAX_MESSAGE, modelLabel, renderIssue } from "../src/telegram/render.ts";
import { telegramRoutes } from "../src/telegram/routes.ts";
import type { TelegramService } from "../src/telegram/service.ts";
import { feedInputSchema, TEMPLATES, type FeedInput } from "../src/telegram/state.ts";
import { fetchLinkRequest, jaccard, headlineTokens, normalizeUrl, pinnedLinkRequest, publicAddress, publicHost, reachable, urlKey, validateItems } from "../src/telegram/validate.ts";
import { testApp } from "./helpers.ts";
import { auditIdle } from "../src/audit.ts";

const TOKEN = `123456789:${"A".repeat(20)}secretPART${"b".repeat(5)}`;
const PC_TOKEN = "tps_pcSECRETtoken";

interface PcJob {
  polls: number;
  body: Record<string, unknown>;
}

/** Monday, 16 November 2026, local time. */
const local = (day: number, h: number, m: number) => new Date(2026, 10, day, h, m, 0).getTime();

class Net {
  t = local(16, 7, 0);
  now = () => this.t;
  /** Advances the clock to "now + ms" (sleepers that started together wake together). */
  sleep = async (ms: number) => {
    const target = this.t + ms;
    await new Promise((r) => setImmediate(r));
    this.t = Math.max(this.t, target);
  };
  tgCalls: Array<{ method: string; body: Record<string, unknown> }> = [];
  updates: TgUpdate[] = [];
  blocked = new Set<number>();
  rateLimitOnce = new Set<number>();
  sent: Array<{ chatId: number; text: string; at: number }> = [];
  left: number[] = [];
  #msgId = 100;
  pc = {
    up: true,
    pollsUntilDone: 2,
    final: { status: "done" } as Record<string, unknown>,
    jobs: new Map<string, PcJob>(),
    requests: [] as Array<Record<string, unknown>>,
    auth: [] as string[],
    cancelled: [] as string[],
    /** The first n jobs fail as "interrupted" (the PC agent restarted). */
    interruptJobs: 0,
  };
  woke: string[] = [];
  wakeWorks = true;
  links = new Map<string, number | "error" | { status: number; location: string }>();
  linkMethods: string[] = [];

  fetch = async (input: string | URL | Request, init: RequestInit = {}): Promise<Response> => {
    const url = new URL(String(input));
    const json = (status: number, body: unknown) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
    const body = init.body ? (JSON.parse(String(init.body)) as Record<string, unknown>) : {};
    if (url.hostname === "api.telegram.org") {
      const m = /^\/bot([^/]+)\/(\w+)$/.exec(url.pathname);
      if (!m || m[1] !== TOKEN) return json(401, { ok: false, error_code: 401, description: "Unauthorized" });
      const method = m[2]!;
      this.tgCalls.push({ method, body });
      if (method === "getMe") return json(200, { ok: true, result: { id: 42, is_bot: true, first_name: "Tiphys", username: "tiphysbot" } });
      if (method === "getUpdates") {
        const offset = Number(body.offset ?? 0);
        this.updates = this.updates.filter((u) => u.update_id >= offset);
        const out = this.updates;
        return json(200, { ok: true, result: out });
      }
      if (method === "leaveChat") {
        this.left.push(Number(body.chat_id));
        return json(200, { ok: true, result: true });
      }
      if (method === "sendMessage") {
        const chatId = Number(body.chat_id);
        expect(body.parse_mode).toBe("HTML");
        expect(body.link_preview_options).toEqual({ is_disabled: true });
        if (this.blocked.has(chatId)) return json(403, { ok: false, error_code: 403, description: "Forbidden: bot was blocked by the user" });
        if (this.rateLimitOnce.delete(chatId)) return json(429, { ok: false, error_code: 429, description: "Too Many Requests", parameters: { retry_after: 7 } });
        this.sent.push({ chatId, text: String(body.text), at: this.t });
        return json(200, { ok: true, result: { message_id: this.#msgId++ } });
      }
      return json(404, { ok: false, error_code: 404 });
    }
    if (url.hostname === "pc.test") {
      if (!this.pc.up) throw new TypeError("fetch failed");
      if (url.pathname === "/v1/health") return json(200, { name: "pc" });
      this.pc.auth.push(String((init.headers as Record<string, string>).authorization));
      if ((init.headers as Record<string, string>).authorization !== `Bearer ${PC_TOKEN}`) return json(401, { error: { code: "agent.auth.invalidToken" } });
      if (init.method === "POST" && url.pathname === "/v1/research/jobs") {
        const id = `rj-${String(this.pc.jobs.size).padStart(16, "0")}`;
        this.pc.jobs.set(id, { polls: 0, body });
        this.pc.requests.push(body);
        return json(202, { id });
      }
      const jm = /^\/v1\/research\/jobs\/(.+)$/.exec(url.pathname);
      const job = jm ? this.pc.jobs.get(jm[1]!) : undefined;
      if (!job) return json(404, { error: { code: "agent.research.notFound" } });
      if (init.method === "DELETE") {
        this.pc.cancelled.push(jm![1]!);
        return json(200, { cancelled: true });
      }
      job.polls++;
      if ([...this.pc.jobs.keys()].indexOf(jm![1]!) < this.pc.interruptJobs) {
        return json(200, { id: jm![1], status: "failed", createdAt: new Date(this.t).toISOString(), error: { code: "agent.research.interrupted", params: {} } });
      }
      if (job.polls < this.pc.pollsUntilDone) return json(200, { id: jm![1], status: "running", createdAt: new Date(this.t).toISOString() });
      return json(200, { id: jm![1], createdAt: new Date(this.t).toISOString(), ...this.pc.final });
    }
    // News sites
    this.linkMethods.push(`${init.method} ${url.href}`);
    const l = this.links.get(url.href) ?? 200;
    if (l === "error") throw new TypeError("getaddrinfo ENOTFOUND");
    if (typeof l === "object") return new Response(null, { status: l.status, headers: { location: l.location } });
    return new Response(null, { status: l });
  };
}

const HEADLINES = [
  "Yeni dil modeli duyuruldu",
  "Çip üreticisi rekor gelir açıkladı",
  "Açık kaynak tarayıcı sürümü çıktı",
  "Avrupa yapay zekâ yasası yürürlükte",
  "Kuantum bilgisayarda önemli adım",
  "Akıllı telefon satışları geriledi",
  "Uzay ajansı uydu fırlattı",
  "Siber saldırı bankaları vurdu",
  "Elektrikli araç pil teknolojisi gelişti",
  "Robotik fabrika otomasyonu yaygınlaşıyor",
];

const item = (n: number, urls: string[]) => ({ headline: HEADLINES[n]!, summary: `Özet ${n}: ayrıntılar burada.`, sources: urls.map((url) => ({ title: `Kaynak ${n}`, url })) });
const done = (items: ReturnType<typeof item>[], extraSeen: string[] = []) => ({
  status: "done",
  result: { items, seenUrls: [...items.flatMap((i) => i.sources.map((s) => s.url)), ...extraSeen], models: { research: "gemini-4-argon-high", editor: "claude-sonnet" }, timings: { researchSec: 200 } },
});
const fiveItems = (prefix = "a") => [0, 1, 2, 3, 4].map((n) => item(n, [`https://news${n}.example.com/${prefix}/${n}`]));

async function setup(o: { wake?: boolean; research?: boolean } = {}) {
  const net = new Net();
  let svc!: TelegramService;
  const logs: string[] = [];
  const t = await testApp(
    (c) => ({
      ...c,
      features: { ...c.features, telegram: true },
      research: o.research === false ? null : { url: "https://pc.test", token: PC_TOKEN, ...(o.wake ? { wakeHostId: "pc" } : {}) },
      wake: { targets: o.wake ? [{ hostId: "pc", mac: "aa:bb:cc:dd:ee:ff", broadcast: "255.255.255.255", port: 9 }] : [] },
    }),
    [
      telegramRoutes({
        fetch: net.fetch as typeof fetch,
        linkRequest: fetchLinkRequest(net.fetch as typeof fetch),
        now: net.now,
        sleep: net.sleep,
        wake: async (w) => {
          net.woke.push(w.hostId);
          if (net.wakeWorks) net.pc.up = true;
        },
        log: (m) => logs.push(m),
        startTimers: false,
        reachTimeoutMs: 2000,
        onService: (s) => (svc = s),
      }),
    ],
  );
  const req = async (method: "GET" | "POST" | "PUT" | "PATCH" | "DELETE", url: string, payload?: unknown) => {
    const r = await t.app.inject({ method, url, headers: t.auth, ...(payload !== undefined ? { payload: payload as object } : {}) });
    return { status: r.statusCode, body: r.json(), raw: r.body };
  };
  const keys = () => t.sent.map((n) => (n as { key: string }).key);
  let upd = 1;
  const update = (u: Omit<TgUpdate, "update_id">) => net.updates.push({ update_id: upd++, ...u } as TgUpdate);
  const priv = (chatId: number, text: string, first = "Ayşe") =>
    update({ message: { message_id: upd, date: 0, chat: { id: chatId, type: "private", first_name: first }, from: { id: chatId, first_name: first, username: "ayse" }, text } });
  /** Bot + one subscribed recipient for a new feed. */
  const ready = async (feed: Partial<FeedInput> = {}, chatId = 1001) => {
    expect((await req("PUT", "/v1/telegram/bot", { token: TOKEN })).status).toBe(200);
    const f = (await req("POST", "/v1/telegram/feeds", { ...TEMPLATES[0]!.feed, approval: { mode: "auto" }, ...feed })).body.feed;
    const inv = (await req("POST", "/v1/telegram/invites", { feedIds: [f.id] })).body.invite;
    priv(chatId, `/start ${inv.code}`);
    await svc.pollOnce(0);
    net.sent = [];
    return { feedId: f.id as string, recipientId: (await req("GET", "/v1/telegram/recipients")).body.recipients[0].id as string };
  };
  return { ...t, net, svc: () => svc, logs, req, keys, priv, update, ready };
}

describe("telegram: API client and send queue", () => {
  it("maps errors to codes and never puts the token into an error", async () => {
    const net = new Net();
    const api = new TelegramApi(TOKEN, { fetch: net.fetch as typeof fetch });
    expect((await api.getMe()).username).toBe("tiphysbot");
    const bad = new TelegramApi(`999999:${"Z".repeat(35)}`, { fetch: net.fetch as typeof fetch });
    const e = await bad.getMe().catch((x: unknown) => x);
    expect(e).toBeInstanceOf(TelegramError);
    expect((e as TelegramError).code).toBe("agent.telegram.invalidToken");
    const down = new TelegramApi(TOKEN, { fetch: (async () => { throw new TypeError(`fetch failed https://api.telegram.org/bot${TOKEN}/getMe`); }) as typeof fetch });
    const e2 = (await down.getMe().catch((x: unknown) => x)) as TelegramError;
    expect(e2.code).toBe("agent.telegram.unreachable");
    expect(JSON.stringify({ m: e2.message, p: e2.params, s: String(e2.stack) })).not.toContain("secretPART");
    expect(() => new TelegramApi("not a token")).toThrow(TelegramError);
  });

  it("≤1 msg/s per chat, ≤25/s overall, 429 waits retry_after, 403 is not retried, ≤3 attempts", async () => {
    const net = new Net();
    const sends: Array<{ chat: number; at: number }> = [];
    let fail: Record<number, string[]> = {};
    const q = new SendQueue({
      now: net.now,
      sleep: net.sleep,
      send: async (chat) => {
        const f = fail[chat]?.shift();
        if (f === "429") {
          const e = new TelegramError("agent.telegram.apiRateLimited", 429);
          e.retryAfter = 7;
          throw e;
        }
        if (f) throw new TelegramError(f, 502);
        sends.push({ chat, at: net.t });
        return { message_id: sends.length };
      },
    });
    const t0 = net.t;
    await Promise.all([1, 2, 3].map(() => q.send(1, "x")));
    expect(sends.map((s) => s.at - t0)).toEqual([0, 1000, 2000]);

    sends.length = 0;
    const t1 = net.t;
    await Promise.all(Array.from({ length: 30 }, (_, i) => q.send(100 + i, "x")));
    // The window also holds chat 1's last send (at t1): never more than 25 in any second.
    const maxInWindow = Math.max(...sends.map((a) => sends.filter((b) => b.at >= a.at && b.at - a.at < 1000).length));
    expect(maxInWindow + 1).toBe(25);
    expect(sends.filter((x) => x.at === t1)).toHaveLength(24);
    expect(sends).toHaveLength(30);

    sends.length = 0;
    fail = { 7: ["429"] };
    const t2 = net.t;
    await q.send(7, "x");
    expect(sends[0]!.at - t2).toBeGreaterThanOrEqual(7000);

    fail = { 8: ["agent.telegram.blocked"] };
    await expect(q.send(8, "x")).rejects.toMatchObject({ code: "agent.telegram.blocked" });
    fail = { 9: ["agent.telegram.unreachable", "agent.telegram.unreachable", "agent.telegram.unreachable", "agent.telegram.unreachable"] };
    await expect(q.send(9, "x")).rejects.toMatchObject({ code: "agent.telegram.unreachable" });
    expect(fail[9]).toHaveLength(1); // 3 attempts used
  });
});

describe("telegram: renderer", () => {
  const at = new Date(2026, 10, 16, 8, 5);
  it("escapes hostile text and attributes; emoji, date and footer", () => {
    const [p] = renderIssue({
      feedName: "Ben & <Sen>",
      windowHours: 24,
      at,
      models: { research: "gemini-4-argon-high", editor: "claude-sonnet-4-5" },
      items: [
        {
          headline: "</b><script>alert(1)</script> &amp;",
          summary: 'Tırnak " ve <i>etiket</i>',
          sources: [
            { url: 'https://www.example.com/a?x="><b>&y=1' },
            { url: "javascript:alert(1)" },
            { url: "https://second.org/p" },
          ],
        },
      ],
    });
    expect(p).toContain("📰 <b>Ben &amp; &lt;Sen&gt;</b> · 16 Kasım 2026");
    expect(p).toContain("1. <b>&lt;/b&gt;&lt;script&gt;alert(1)&lt;/script&gt; &amp;amp;</b>");
    expect(p).toContain("Tırnak &quot; ve &lt;i&gt;etiket&lt;/i&gt;");
    expect(p).not.toContain("<script>");
    expect(p).not.toContain("javascript:");
    expect(p).toContain('Kaynak: <a href="https://www.example.com/a?x=&quot;&gt;&lt;b&gt;&amp;y=1">example.com</a> · <a href="https://second.org/p">second.org</a>');
    expect(p!.endsWith("<i>Tiphys · Gemini 4 Argon + Claude · 08:05</i>")).toBe(true);
    // Only the tags we emit remain.
    expect(new Set(p!.match(/<\/?[a-z]+/g))).toEqual(new Set(["<b", "</b", "<a", "</a", "<i", "</i"]));
    expect(modelLabel("gemini-4-argon-high")).toBe("Gemini 4 Argon");
    expect(modelLabel("opus")).toBe("Claude");
  });

  it("splits at item boundaries under the limit; weekly emoji", () => {
    const items = Array.from({ length: 12 }, (_, i) => ({ headline: `Başlık ${i} 😀`, summary: "ö".repeat(900), sources: [{ url: `https://s${i}.com/x` }] }));
    const parts = renderIssue({ feedName: "Haftalık", windowHours: 168, at, models: { research: "gemini-4-argon-high" }, items });
    expect(parts.length).toBeGreaterThan(1);
    for (const p of parts) expect(p.length).toBeLessThanOrEqual(MAX_MESSAGE);
    expect(parts[0]!.startsWith("🗞️ <b>Haftalık</b>")).toBe(true);
    const all = parts.join("\n\n");
    for (let i = 0; i < 12; i++) expect(all).toContain(`${i + 1}. <b>Başlık ${i} 😀</b>`);
    // No part starts or ends in the middle of an item.
    for (const p of parts.slice(1)) expect(/^(\d+\. <b>|<i>)/.test(p)).toBe(true);
    expect(parts.at(-1)!.endsWith("<i>Tiphys · Gemini 4 Argon · 08:05</i>")).toBe(true);
    expect(escapeHtml(`a&"<>`)).toBe("a&amp;&quot;&lt;&gt;");
  });
});

describe("telegram: validation", () => {
  it("normalizes URLs, rejects private hosts, token Jaccard", () => {
    expect(normalizeUrl("https://x.com/a?utm_source=t&id=2&fbclid=1#frag")).toBe("https://x.com/a?id=2");
    expect(normalizeUrl("javascript:alert(1)")).toBeNull();
    expect(normalizeUrl("ftp://x.com/a")).toBeNull();
    expect(urlKey("https://WWW.X.com/a/?utm_medium=1#z")).toBe("x.com/a");
    for (const h of ["localhost", "127.0.0.1", "10.1.2.3", "192.168.1.5", "100.100.1.1", "pc.tail1234.ts.net", "nas.local", "intranet"]) expect(publicHost(h), h).toBe(false);
    expect(publicHost("www.bbc.co.uk")).toBe(true);
    expect(jaccard(headlineTokens("Yeni dil modeli duyuruldu!"), headlineTokens("yeni DİL modeli duyuruldu"))).toBeGreaterThanOrEqual(0.8);
    expect(jaccard(headlineTokens("Yeni dil modeli duyuruldu"), headlineTokens("Çip üreticisi rekor gelir açıkladı"))).toBeLessThan(0.8);
  });

  it("reachability: 2xx/3xx/401/403/429 ok; 404/410/5xx/DNS not; redirects followed ≤3 and checked; HEAD 405 → GET", async () => {
    const net = new Net();
    const f = fetchLinkRequest(net.fetch as typeof fetch);
    const cases: Array<[string, number | "error" | { status: number; location: string }, boolean]> = [
      ["https://ok.com/1", 200, true],
      ["https://ok.com/2", 403, true],
      ["https://ok.com/3", 429, true],
      ["https://ok.com/4", 404, false],
      ["https://ok.com/5", 410, false],
      ["https://ok.com/6", 503, false],
      ["https://ok.com/7", "error", false],
      ["https://ok.com/8", { status: 301, location: "http://127.0.0.1/admin" }, false],
      ["https://ok.com/9", { status: 302, location: "/1" }, true],
    ];
    for (const [u, s] of cases) net.links.set(u, s);
    for (const [u, , want] of cases) expect(await reachable(u, f, 1000), u).toBe(want);
    net.links.set("https://r.com/a", { status: 301, location: "https://r.com/b" });
    net.links.set("https://r.com/b", { status: 301, location: "https://r.com/c" });
    net.links.set("https://r.com/c", { status: 301, location: "https://r.com/d" });
    net.links.set("https://r.com/d", 404);
    expect(await reachable("https://r.com/a", f, 1000)).toBe(false); // 3 redirects followed, then 404
    net.links.set("https://h.com/x", 405);
    net.linkMethods = [];
    await reachable("https://h.com/x", f, 1000);
    expect(net.linkMethods).toEqual(["HEAD https://h.com/x", "GET https://h.com/x"]);
  });

  it("drops sources not in seenUrls, unreachable, blocked, old or duplicate; drops empty items; caps", async () => {
    const net = new Net();
    net.links.set("https://dead.com/x", 404);
    const items = [
      { headline: "Yeni dil modeli duyuruldu", summary: "a", sources: [{ url: "https://made-up.com/fake" }, { url: "https://good.com/1?utm_source=x" }] },
      { headline: "Çip üreticisi rekor gelir açıkladı", summary: "b", sources: [{ url: "https://dead.com/x" }] },
      { headline: "Açık kaynak tarayıcı sürümü çıktı", summary: "c", sources: [{ url: "https://good.com/1" }, { url: "https://blocked.com/y" }, { url: "https://old.com/z" }] },
      { headline: "Avrupa yapay zekâ yasası yürürlükte", summary: "d", sources: [1, 2, 3, 4].map((n) => ({ url: `https://m${n}.com/q` })) },
      { headline: "Yeni DİL modeli duyuruldu!", summary: "dup", sources: [{ url: "https://other.com/k" }] },
      { headline: "Kuantum bilgisayarda önemli adım", summary: "e", sources: [{ url: "http://10.0.0.1/x" }] },
      { headline: "Daha önce gönderilen başlık burada", summary: "f", sources: [{ url: "https://fresh.com/1" }] },
    ];
    const seen = ["https://good.com/1", "https://dead.com/x", "https://blocked.com/y", "https://old.com/z", "https://other.com/k", "http://10.0.0.1/x", "https://fresh.com/1", ...[1, 2, 3, 4].map((n) => `https://m${n}.com/q`)];
    const r = await validateItems(
      items,
      seen,
      { maxItems: 10, maxSourcesPerItem: 3, allowDomains: [], blockDomains: ["blocked.com"] },
      { urlKeys: new Set([urlKey("https://old.com/z")!]), headlines: ["Daha önce gönderilen başlık burada"] },
      fetchLinkRequest(net.fetch as typeof fetch),
      { timeoutMs: 1000 },
    );
    expect(r.items.map((i) => i.headline)).toEqual(["Yeni dil modeli duyuruldu", "Avrupa yapay zekâ yasası yürürlükte"]);
    expect(r.items[0]!.sources.map((s) => s.url)).toEqual(["https://good.com/1"]);
    expect(r.items[1]!.sources).toHaveLength(3);
    expect(r.stats).toMatchObject({ received: 7, kept: 2, droppedItems: 5 });
    const capped = await validateItems(items.slice(0, 1).concat(items.slice(3, 4)), seen, { maxItems: 1, maxSourcesPerItem: 1, allowDomains: ["good.com"], blockDomains: [] }, { urlKeys: new Set(), headlines: [] }, fetchLinkRequest(net.fetch as typeof fetch));
    expect(capped.items).toHaveLength(1);
  });
});

describe("telegram: bot, invites, recipients", () => {
  it("invite → /start code adds a recipient; invalid code, groups and /stop", async () => {
    const s = await setup();
    expect((await s.req("POST", "/v1/telegram/invites", {})).body.error.code).toBe("agent.telegram.notConfigured");
    expect((await s.req("PUT", "/v1/telegram/bot", { token: `1234567:${"x".repeat(35)}` })).body.error.code).toBe("agent.telegram.invalidToken");
    const bot = await s.req("PUT", "/v1/telegram/bot", { token: TOKEN });
    expect(bot.body).toEqual({ bot: { username: "tiphysbot", id: 42 } });
    const f = (await s.req("POST", "/v1/telegram/feeds", TEMPLATES[0]!.feed)).body.feed;
    const inv = (await s.req("POST", "/v1/telegram/invites", { label: "Ayşe", feedIds: [f.id] })).body.invite;
    expect(inv.link).toBe(`https://t.me/tiphysbot?start=${inv.code}`);
    expect(inv.code).toMatch(/^[A-Za-z0-9_-]{16}$/);
    expect(Date.parse(inv.expiresAt) - s.net.t).toBe(24 * 3600_000);
    expect((await s.req("GET", "/v1/telegram/status")).body).toMatchObject({ bot: { configured: true, username: "tiphysbot" }, pendingInvites: 1, research: { configured: true, reachable: true } });

    s.priv(1, "/start wrongcode");
    s.priv(2, "/start");
    s.update({ message: { message_id: 1, date: 0, chat: { id: -500, type: "group" }, text: `/start ${inv.code}` } });
    s.update({ my_chat_member: { chat: { id: -600, type: "supergroup" } } });
    s.priv(3, `/start ${inv.code}`, "Ayşe <b>");
    s.priv(4, `/start ${inv.code}`); // already used
    expect(await s.svc().pollOnce(0)).toBe(6);
    const texts = Object.fromEntries(s.net.sent.map((m) => [m.chatId, m.text]));
    expect(texts[1]).toMatch(/özel bir bot/);
    expect(texts[2]).toMatch(/özel bir bot/);
    expect(texts[4]).toMatch(/özel bir bot/);
    expect(texts[3]).toMatch(/^Merhaba Ayşe <b>! Tiphys bültenlerine eklendin/);
    expect(texts[-500]).toBeUndefined();
    expect(s.net.left.sort((a, b) => a - b)).toEqual([-600, -500]);
    const recips = (await s.req("GET", "/v1/telegram/recipients")).body.recipients;
    expect(recips).toHaveLength(1);
    expect(recips[0]).toMatchObject({ chatId: 3, firstName: "Ayşe <b>", username: "ayse", status: "active", subscriptions: [f.id] });
    expect((await s.req("GET", "/v1/telegram/invites")).body.invites[0]).toMatchObject({ status: "used", recipientId: recips[0].id });
    expect((await s.req("GET", "/v1/telegram/invites")).body.invites[0].code).toBeUndefined();
    // offset acknowledged: the same updates aren't handled again
    expect(await s.svc().pollOnce(0)).toBe(0);
    expect(s.net.tgCalls.filter((c) => c.method === "getUpdates").at(-1)!.body.offset).toBe(7);

    s.net.sent = [];
    s.priv(3, "/stop");
    s.priv(9, "/stop"); // unknown chat: ignored
    s.priv(3, "rm -rf / ; merhaba"); // nothing is executed or answered
    await s.svc().pollOnce(0);
    expect(s.net.sent.map((m) => m.chatId)).toEqual([3]);
    expect(s.net.sent[0]!.text).toMatch(/Aboneliğin kapatıldı/);
    expect((await s.req("GET", "/v1/telegram/recipients")).body.recipients[0].status).toBe("stopped");
    expect((await s.req("PATCH", `/v1/telegram/recipients/${recips[0].id}`, { status: "active" })).body.error.code).toBe("agent.telegram.recipientStopped");
    await s.app.close();
  });

  it("recipient patch, test message, 403 → unreachable, revoke invite, delete", async () => {
    const s = await setup();
    const { recipientId, feedId } = await s.ready();
    expect((await s.req("PATCH", `/v1/telegram/recipients/${recipientId}`, { status: "paused", subscriptions: [] })).body.recipient).toMatchObject({ status: "paused", subscriptions: [] });
    expect((await s.req("PATCH", `/v1/telegram/recipients/${recipientId}`, { subscriptions: ["nope"] })).status).toBe(404);
    expect((await s.req("POST", `/v1/telegram/recipients/${recipientId}/test`)).body).toMatchObject({ ok: true });
    expect(s.net.sent[0]!.text).toMatch(/test mesajı/);
    s.net.blocked.add(1001);
    expect((await s.req("POST", `/v1/telegram/recipients/${recipientId}/test`)).body.error.code).toBe("agent.telegram.blocked");
    expect((await s.req("GET", "/v1/telegram/recipients")).body.recipients[0].status).toBe("unreachable");
    // Plain test messages aren't newsletter deliveries (the log comes from the issue archive).
    expect((await s.req("GET", `/v1/telegram/recipients/${recipientId}/deliveries`)).body.deliveries).toEqual([]);
    const inv = (await s.req("POST", "/v1/telegram/invites", { feedIds: [feedId] })).body.invite;
    expect((await s.req("DELETE", `/v1/telegram/invites/${inv.id}`)).body.invite.status).toBe("revoked");
    expect((await s.req("GET", "/v1/telegram/status")).body.pendingInvites).toBe(0);
    expect((await s.req("DELETE", `/v1/telegram/recipients/${recipientId}`)).body).toEqual({ ok: true });
    expect((await s.req("GET", "/v1/telegram/recipients")).body.recipients).toEqual([]);
    await s.app.close();
  });
});

describe("telegram: run pipeline", () => {
  it("run now (auto): research job, validation, render, delivery, telegram.sent; dedupe on the next run", async () => {
    const s = await setup();
    const { feedId, recipientId } = await s.ready();
    s.net.pc.final = done(fiveItems());
    const r = await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    expect(r.status).toBe(202);
    expect(r.body.issue.status).toBe("researching");
    await s.svc().idle();
    const issue = (await s.req("GET", `/v1/telegram/issues/${r.body.issue.id}`)).body.issue;
    expect(issue).toMatchObject({ status: "sent", stats: { kept: 5 } });
    expect(issue.deliveries).toEqual([expect.objectContaining({ recipientId, status: "sent", messageIds: [expect.any(Number)] })]);
    expect(s.net.sent).toHaveLength(1);
    expect(s.net.sent[0]!.text).toContain("Günlük teknoloji ve yapay zekâ");
    expect((await s.req("GET", `/v1/telegram/recipients/${recipientId}/deliveries`)).body.deliveries).toEqual([
      expect.objectContaining({ issueId: r.body.issue.id, feedId, status: "sent" }),
    ]);
    expect(s.net.pc.requests[0]).toMatchObject({ topic: TEMPLATES[0]!.feed.topic, windowHours: 24, language: "tr", minItems: 5, maxItems: 8, maxSourcesPerItem: 3, excludeUrls: [], editor: true });
    expect(s.net.pc.auth.every((a) => a === `Bearer ${PC_TOKEN}`)).toBe(true);
    expect(s.keys()).toContain("telegram.sent");
    const sentNotice = s.sent.find((n) => (n as { key: string }).key === "telegram.sent") as { params: Record<string, unknown> };
    expect(sentNotice.params).toMatchObject({ feedId, items: 5, recipients: 1, failed: 0 });

    // Second run: previously sent URLs are excluded and deduped; one new item only → still sent (below min, ≥1)
    s.net.pc.final = done([...fiveItems(), item(5, ["https://fresh.example.com/new"])]);
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    await s.svc().idle();
    expect((s.net.pc.requests[1]!.excludeUrls as string[]).sort()).toEqual(fiveItems().map((i) => i.sources[0]!.url).sort());
    const second = (await s.req("GET", `/v1/telegram/issues?feedId=${feedId}`)).body.issues[0];
    expect(second).toMatchObject({ status: "sent", itemCount: 1 });

    // Third run: nothing new → skipped silently (skipIfNothingNew)
    s.net.pc.final = done(fiveItems());
    const before = s.sent.length;
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    await s.svc().idle();
    expect((await s.req("GET", `/v1/telegram/issues?feedId=${feedId}`)).body.issues[0].status).toBe("skipped");
    expect(s.sent.length).toBe(before);
    const events = (await s.req("GET", "/v1/events?limit=200")).body.events as Array<{ key: string; params: Record<string, unknown> }>;
    expect(events.some((e) => e.key === "telegram.skipped" && e.params.reason === "nothingNew")).toBe(true);
    // Events hold ids and counts, never newsletter content or names
    const evText = JSON.stringify(events);
    for (const h of HEADLINES.slice(0, 5)) expect(evText).not.toContain(h);
    expect(evText).not.toContain("Ayşe");
    await s.app.close();
  });

  it("no items without skipIfNothingNew → failed; PC job failed → telegram.failed; preview sends nothing", async () => {
    const s = await setup();
    const { feedId } = await s.ready({ skipIfNothingNew: false });
    s.net.pc.final = done([item(0, ["https://made-up.example.com/x"])], []);
    (s.net.pc.final.result as { seenUrls: string[] }).seenUrls = [];
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    await s.svc().idle();
    let last = (await s.req("GET", "/v1/telegram/issues")).body.issues[0];
    expect(last).toMatchObject({ status: "failed", error: "agent.telegram.noItems" });

    s.net.pc.final = { status: "failed", error: { code: "agent.research.toolFailed", params: {} } };
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    await s.svc().idle();
    last = (await s.req("GET", "/v1/telegram/issues")).body.issues[0];
    expect(last).toMatchObject({ status: "failed", error: "agent.telegram.research.failed" });
    const failed = s.sent.filter((n) => (n as { key: string }).key === "telegram.failed") as Array<{ params: Record<string, unknown> }>;
    expect(failed.map((n) => n.params.reason)).toEqual(["agent.telegram.noItems", "agent.telegram.research.failed"]);

    s.net.pc.final = done(fiveItems());
    const p = await s.req("POST", `/v1/telegram/feeds/${feedId}/preview`);
    await s.svc().idle();
    const prev = (await s.req("GET", `/v1/telegram/issues/${p.body.issue.id}`)).body.issue;
    expect(prev.status).toBe("preview");
    expect(prev.renderedParts[0]).toContain("Yeni dil modeli duyuruldu");
    expect(s.net.sent).toHaveLength(0);
    // send the preview to one recipient as a test
    const rid = (await s.req("GET", "/v1/telegram/recipients")).body.recipients[0].id;
    expect((await s.req("POST", `/v1/telegram/issues/${p.body.issue.id}/test`, { recipientId: rid })).body.delivery).toMatchObject({ status: "sent", test: true });
    expect(s.net.sent).toHaveLength(1);
    await s.app.close();
  });

  it("PC unreachable: without a wake target fails at once (telegram.pcUnreachable); with one, WoL then success", async () => {
    const s = await setup();
    const { feedId } = await s.ready();
    s.net.pc.up = false;
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    await s.svc().idle();
    expect((await s.req("GET", "/v1/telegram/issues")).body.issues[0]).toMatchObject({ status: "failed", error: "agent.telegram.research.unreachable" });
    expect(s.keys()).toContain("telegram.pcUnreachable");
    await s.app.close();

    const w = await setup({ wake: true });
    const r = await w.ready();
    w.net.pc.up = false;
    w.net.pc.final = done(fiveItems());
    await w.req("POST", `/v1/telegram/feeds/${r.feedId}/run`);
    await w.svc().idle();
    expect(w.net.woke).toEqual(["pc"]);
    expect((await w.req("GET", "/v1/telegram/issues")).body.issues[0].status).toBe("sent");
    await w.app.close();
  });

  it("deadline: a job that never finishes fails with research.timeout; PC staying down → unreachable after WoL", async () => {
    const s = await setup({ wake: true });
    const { feedId } = await s.ready({ deadlineMinutes: 5 });
    s.net.pc.pollsUntilDone = 1e9;
    const start = s.net.t;
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    await s.svc().idle();
    expect((await s.req("GET", "/v1/telegram/issues")).body.issues[0]).toMatchObject({ status: "failed", error: "agent.telegram.research.timeout" });
    expect(s.net.t - start).toBeGreaterThanOrEqual(5 * 60_000);
    expect(s.net.t - start).toBeLessThan(6 * 60_000);
    const jobPolls = [...s.net.pc.jobs.values()][0]!.polls;
    expect(jobPolls).toBeGreaterThanOrEqual(25); // every 10 s
    expect(jobPolls).toBeLessThanOrEqual(31);

    // The PC doesn't wake up: retried until the deadline, then "PC unreachable"
    s.net.pc.up = false;
    s.net.wakeWorks = false;
    const start2 = s.net.t;
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    await s.svc().idle();
    expect(s.net.woke).toEqual(["pc"]);
    expect(s.net.t - start2).toBeGreaterThanOrEqual(5 * 60_000);
    expect((await s.req("GET", "/v1/telegram/issues")).body.issues[0]).toMatchObject({ status: "failed", error: "agent.telegram.research.unreachable" });
    expect(s.keys()).toContain("telegram.pcUnreachable");
    await s.app.close();
  });
});

describe("telegram: approval", () => {
  it("firstN: approval notification with ids; approve sends, counts toward n; reject; expiry", async () => {
    const s = await setup();
    const { feedId } = await s.ready({ approval: { mode: "firstN", n: 1 } });
    s.net.pc.final = done(fiveItems());
    const id1 = (await s.req("POST", `/v1/telegram/feeds/${feedId}/run`)).body.issue.id;
    await s.svc().idle();
    expect((await s.req("GET", `/v1/telegram/issues/${id1}`)).body.issue.status).toBe("awaiting_approval");
    const notice = s.sent.find((n) => (n as { key: string }).key === "telegram.approval") as { params: Record<string, unknown>; data: Record<string, string>; link: string };
    expect(notice).toMatchObject({ data: { issueId: id1, feedId }, link: `tiphys://telegram/issues/${id1}`, params: { items: 5, recipients: 1 } });
    expect(s.net.sent).toHaveLength(0);
    expect((await s.req("POST", `/v1/telegram/issues/${id1}/approve`)).body.issue.status).toBe("sending");
    await s.svc().idle();
    expect((await s.req("GET", `/v1/telegram/issues/${id1}`)).body.issue.status).toBe("sent");
    expect(s.net.sent).toHaveLength(1);
    expect((await s.req("POST", `/v1/telegram/issues/${id1}/approve`)).body.error.code).toBe("agent.telegram.issueNotAwaiting");
    expect((await s.req("GET", `/v1/telegram/feeds/${feedId}`)).body.feed.approval.sentCount).toBe(1);
    // n reached → automatic
    s.net.pc.final = done(fiveItems("b").map((it, i) => ({ ...it, headline: HEADLINES[i + 5]! })));
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    await s.svc().idle();
    expect((await s.req("GET", "/v1/telegram/issues")).body.issues[0].status).toBe("sent");
    await s.app.close();
  });

  it("ask: reject and expiry at deadline + 2 h", async () => {
    const s = await setup();
    const { feedId } = await s.ready({ approval: { mode: "ask", n: 3 }, deadlineMinutes: 30 });
    s.net.pc.final = done(fiveItems());
    const a = (await s.req("POST", `/v1/telegram/feeds/${feedId}/run`)).body.issue.id;
    await s.svc().idle();
    expect((await s.req("POST", `/v1/telegram/issues/${a}/reject`)).body.issue.status).toBe("rejected");
    s.net.pc.final = done(fiveItems("c"));
    const created = s.net.t;
    const b = (await s.req("POST", `/v1/telegram/feeds/${feedId}/run`)).body.issue.id;
    await s.svc().idle();
    const issue = (await s.req("GET", `/v1/telegram/issues/${b}`)).body.issue;
    expect(Date.parse(issue.expiresAt) - created).toBe(30 * 60_000 + 2 * 3600_000);
    s.net.t = Date.parse(issue.expiresAt) + 1000;
    await s.svc().tick();
    expect((await s.req("GET", `/v1/telegram/issues/${b}`)).body.issue.status).toBe("expired");
    expect((await s.req("POST", `/v1/telegram/issues/${b}/approve`)).body.error.code).toBe("agent.telegram.issueNotAwaiting");
    expect(s.net.sent).toHaveLength(0);
    const fails = s.sent.filter((n) => (n as { key: string }).key === "telegram.failed") as Array<{ params: Record<string, unknown> }>;
    expect(fails.at(-1)!.params.reason).toBe("agent.telegram.approvalExpired");
    await s.app.close();
  });
});

describe("telegram: scheduler", () => {
  it("runs at the slot, doesn't repeat, skips missed slots past the deadline, catches up within it", async () => {
    const s = await setup();
    const { feedId } = await s.ready({ when: { kind: "daily", time: "08:00" }, deadlineMinutes: 30 });
    s.net.pc.final = done(fiveItems());
    const svc = s.svc();
    s.net.t = local(16, 7, 59);
    await svc.tick();
    expect(s.net.pc.requests).toHaveLength(0);
    s.net.t = local(16, 8, 0) + 5000;
    await svc.tick();
    await svc.tick();
    await svc.idle();
    expect(s.net.pc.requests).toHaveLength(1);
    const first = (await s.req("GET", "/v1/telegram/issues")).body.issues[0];
    expect(first).toMatchObject({ kind: "scheduled", status: "sent", slotAt: new Date(local(16, 8, 0)).toISOString() });
    expect(Date.parse(first.deadlineAt)).toBe(local(16, 8, 30));
    expect((await s.req("GET", `/v1/telegram/feeds/${feedId}`)).body.feed.nextRun).toBe(new Date(local(17, 8, 0)).toISOString());

    // Agent was "off" through the next slot and comes back 20 min later → still within the deadline → runs
    s.net.pc.final = done(fiveItems("d").map((it, i) => ({ ...it, headline: HEADLINES[i + 5]! })));
    s.net.t = local(17, 8, 20);
    await svc.tick();
    await svc.idle();
    expect(s.net.pc.requests).toHaveLength(2);

    // Off for a day and a half: the 18th slot is missed (past the deadline) → event, no run
    s.net.t = local(19, 7, 0);
    await svc.tick();
    await svc.idle();
    expect(s.net.pc.requests).toHaveLength(2);
    const events = (await s.req("GET", "/v1/events?limit=200")).body.events as Array<{ key: string; params: Record<string, unknown> }>;
    expect(events.find((e) => e.key === "telegram.missed")?.params).toMatchObject({ feedId, slotAt: new Date(local(18, 8, 0)).toISOString() });
    await s.app.close();
  });

  it("no subscribers → skipped event; disabled feeds don't run; weekly on Monday only", async () => {
    const s = await setup();
    await s.req("PUT", "/v1/telegram/bot", { token: TOKEN });
    const weekly = (await s.req("POST", "/v1/telegram/feeds", TEMPLATES[1]!.feed)).body.feed;
    expect(weekly.nextRun).toBe(new Date(local(16, 9, 0)).toISOString());
    const off = (await s.req("POST", "/v1/telegram/feeds", { ...TEMPLATES[0]!.feed, enabled: false })).body.feed;
    expect(off.nextRun).toBeNull();
    s.net.t = local(16, 9, 1);
    await s.svc().tick();
    const events = (await s.req("GET", "/v1/events?limit=50")).body.events as Array<{ key: string; params: Record<string, unknown> }>;
    expect(events.find((e) => e.key === "telegram.skipped")?.params).toMatchObject({ feedId: weekly.id, reason: "noRecipients" });
    expect(s.net.pc.requests).toHaveLength(0);
    expect(s.svc().dueSlot(s.svc().getFeed(weekly.id), local(17, 9, 1))).toBeNull();
    await s.app.close();
  });
});

describe("telegram: routes, auth and secrets", () => {
  it("auth required; token never in responses, config, events, audit, logs or state file", async () => {
    const s = await setup();
    expect((await s.app.inject({ method: "GET", url: "/v1/telegram/status" })).statusCode).toBe(401);
    expect((await s.app.inject({ method: "PUT", url: "/v1/telegram/bot", payload: { token: TOKEN } })).statusCode).toBe(401);
    const bodies: string[] = [];
    const call = async (m: "GET" | "POST" | "PUT" | "PATCH" | "DELETE", u: string, p?: unknown) => {
      const r = await s.req(m, u, p);
      bodies.push(r.raw);
      return r;
    };
    await call("PUT", "/v1/telegram/bot", { token: TOKEN });
    await s.ready();
    s.net.pc.final = done(fiveItems());
    const feeds = (await call("GET", "/v1/telegram/feeds")).body.feeds;
    await call("POST", `/v1/telegram/feeds/${feeds[0].id}/run`);
    await s.svc().idle();
    for (const u of ["/v1/telegram/status", "/v1/telegram/recipients", "/v1/telegram/invites", "/v1/telegram/issues", "/v1/telegram/templates", "/v1/config", "/v1/events?limit=500", "/v1/audit"]) await call("GET", u);
    const cfg = JSON.parse(bodies.at(-3)!);
    expect(cfg.telegram).toEqual({ configured: true, username: "tiphysbot" });
    expect(cfg.research).toEqual({ url: "https://pc.test", wakeHostId: null, hasToken: true });
    // and PUT bot/feeds with invalid input don't echo it either
    bodies.push((await s.req("PUT", "/v1/telegram/bot", { token: `${TOKEN}!` })).raw);
    await auditIdle(); // the audit line is written after the response
    const files = await Promise.all(["events.jsonl", "audit.jsonl", "telegram-state.json"].map((f) => readFile(join(s.dir, f), "utf8")));
    for (const text of [...bodies, ...files, s.logs.join("\n"), JSON.stringify(s.sent)]) {
      expect(text).not.toContain("secretPART");
      expect(text).not.toContain(PC_TOKEN);
    }
    // The token itself is only in agent.json (0600)
    expect(await readFile(join(s.dir, "agent.json"), "utf8")).toContain("secretPART");
    await call("DELETE", "/v1/telegram/bot");
    expect((await s.req("GET", "/v1/telegram/status")).body.bot.configured).toBe(false);
    await s.app.close();
  });

  it("PATCH research keeps the token while the URL is unchanged, requires it when the URL changes", async () => {
    const s = await setup();
    let r = await s.req("PATCH", "/v1/config", { research: { url: "https://pc.test", wakeHostId: "pc" } });
    expect(r.body.config.research).toEqual({ url: "https://pc.test", wakeHostId: "pc", hasToken: true });
    r = await s.req("PATCH", "/v1/config", { research: { url: "https://pc.test" } });
    expect(r.body.config.research.wakeHostId).toBe("pc");
    r = await s.req("PATCH", "/v1/config", { research: { url: "https://pc.test", wakeHostId: null } });
    expect(r.body.config.research).toEqual({ url: "https://pc.test", wakeHostId: null, hasToken: true });
    expect((await s.req("PATCH", "/v1/config", { research: { url: "https://pc.test", wakeHostId: "Bad Id" } })).status).toBe(400);
    expect(s.store.get().research?.token).toBe(PC_TOKEN);
    r = await s.req("PATCH", "/v1/config", { research: { url: "https://other.test" } });
    expect(r.body.error).toEqual({ code: "agent.config.passwordRequired", params: { field: "research.token" } });
    r = await s.req("PATCH", "/v1/config", { research: { url: "https://other.test", token: "tps_new" } });
    expect(s.store.get().research).toEqual({ url: "https://other.test", token: "tps_new" });
    expect(r.raw).not.toContain("tps_new");
    r = await s.req("PATCH", "/v1/config", { research: null });
    expect(s.store.get().research).toBeNull();
    await s.app.close();
  });

  it("feeds CRUD, templates, validation and rate limit", async () => {
    const s = await setup({ research: false });
    expect((await s.req("GET", "/v1/telegram/templates")).body.templates.map((t: { feed: { name: string; windowHours: number; minItems: number; maxItems: number } }) => [t.feed.name, t.feed.windowHours, t.feed.minItems, t.feed.maxItems])).toEqual([
      ["Günlük teknoloji ve yapay zekâ", 24, 5, 8],
      ["Haftalık teknoloji ve yapay zekâ özeti", 168, 10, 12],
    ]);
    expect((await s.req("GET", "/v1/telegram/feeds")).body.feeds).toEqual([]);
    expect((await s.req("POST", "/v1/telegram/feeds", { ...TEMPLATES[0]!.feed, maxSourcesPerItem: 4 })).status).toBe(400);
    expect((await s.req("POST", "/v1/telegram/feeds", { ...TEMPLATES[0]!.feed, minItems: 9 })).status).toBe(400);
    expect((await s.req("POST", "/v1/telegram/feeds", { ...TEMPLATES[0]!.feed, extra: 1 })).status).toBe(400);
    const f = (await s.req("POST", "/v1/telegram/feeds", { ...TEMPLATES[0]!.feed, instructions: "x" })).body.feed;
    expect(f.approval).toEqual({ mode: "firstN", n: 3, sentCount: 0 });
    const upd = (await s.req("PUT", `/v1/telegram/feeds/${f.id}`, { ...TEMPLATES[0]!.feed, name: "Yeni ad", when: { kind: "daily", time: "07:30" } })).body.feed;
    expect(upd).toMatchObject({ name: "Yeni ad", when: { time: "07:30" } });
    expect(upd.instructions).toBeUndefined();
    expect((await s.req("POST", `/v1/telegram/feeds/${f.id}/preview`)).body.error.code).toBe("agent.telegram.research.notConfigured");
    expect((await s.req("DELETE", `/v1/telegram/feeds/${f.id}`)).body).toEqual({ ok: true });
    expect((await s.req("GET", `/v1/telegram/feeds/${f.id}`)).status).toBe(404);
    let limited = 0;
    for (let i = 0; i < 35; i++) if ((await s.req("POST", "/v1/telegram/feeds", { ...TEMPLATES[0]!.feed, minItems: 99 })).status === 429) limited++;
    expect(limited).toBeGreaterThan(0);
    expect(feedInputSchema.safeParse({ ...TEMPLATES[0]!.feed, allowDomains: ["-bad.com"] }).success).toBe(false);
    await s.app.close();
  });
});

describe("telegram: poller lifecycle", () => {
  it("long-polls only while an invite is pending; revoke and shutdown cancel the request", async () => {
    const net = new Net();
    let open = 0;
    let svc!: TelegramService;
    // getUpdates hangs until aborted (a real long poll); everything else goes to the fake.
    const f = async (input: string | URL | Request, init: RequestInit = {}) => {
      if (String(input).endsWith("/getUpdates")) {
        open++;
        return new Promise<Response>((_, rej) => init.signal!.addEventListener("abort", () => (open--, rej(new Error("aborted")))));
      }
      return net.fetch(input, init);
    };
    const t = await testApp((c) => ({ ...c, features: { ...c.features, telegram: true } }), [
      telegramRoutes({ fetch: f as typeof fetch, stateFile: null, tickMs: 3600_000, log: () => {}, onService: (s) => (svc = s) }),
    ]);
    const req = (method: "GET" | "POST" | "PUT" | "DELETE", url: string, payload?: object) => t.app.inject({ method, url, headers: t.auth, payload });
    await req("PUT", "/v1/telegram/bot", { token: TOKEN });
    expect((await req("GET", "/v1/telegram/status")).json().polling).toBe(false);
    const inv = (await req("POST", "/v1/telegram/invites", {})).json().invite;
    await new Promise((r) => setTimeout(r, 20));
    expect(open).toBe(1);
    expect((await req("GET", "/v1/telegram/status")).json().polling).toBe(true);
    await req("DELETE", `/v1/telegram/invites/${inv.id}`);
    await new Promise((r) => setTimeout(r, 20));
    expect(open).toBe(0);
    expect((await req("GET", "/v1/telegram/status")).json().polling).toBe(false);
    await req("POST", "/v1/telegram/invites", {});
    await new Promise((r) => setTimeout(r, 20));
    expect(open).toBe(1);
    const started = Date.now();
    await t.app.close();
    expect(open).toBe(0);
    expect(Date.now() - started).toBeLessThan(1000);
    void svc;
  });
});

describe("telegram: review fixes", () => {
  it("link check resolves every hop, refuses non-public addresses and connects to the checked one", async () => {
    for (const a of ["127.0.0.1", "10.1.2.3", "100.64.0.1", "100.100.100.100", "169.254.169.254", "172.16.0.1", "192.168.1.1", "198.18.0.1", "0.0.0.0", "224.0.0.1", "255.255.255.255", "::1", "::", "fe80::1", "fc00::1", "fd7a:115c:a1e0::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "ff02::1", "not-an-ip"]) {
      expect(publicAddress(a), a).toBe(false);
    }
    for (const a of ["93.184.216.34", "1.1.1.1", "2606:4700:4700::1111"]) expect(publicAddress(a), a).toBe(true);

    const { createServer } = await import("node:http");
    const hits: string[] = [];
    const server = createServer((req, res) => {
      hits.push(`${req.method} ${req.headers.host}${req.url}`);
      if (req.url === "/redirect-internal") res.writeHead(301, { location: `http://internal.example:${port}/x` }).end();
      else if (req.url === "/redirect-ok") res.writeHead(302, { location: "/final" }).end();
      else res.writeHead(200).end("ok");
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
    const port = (server.address() as { port: number }).port;
    const lookups: string[] = [];
    const dns: Record<string, string[]> = { "news.example": ["127.0.0.1"], "internal.example": ["10.0.0.5"], "mixed.example": ["93.184.216.34", "10.0.0.5"], "loop.example": ["127.0.0.1"] };
    const resolve = async (h: string) => {
      lookups.push(h);
      return (dns[h] ?? []).map((address) => ({ address, family: 4 }));
    };
    try {
      // Test-only rule: 127.0.0.1 counts as public so the local server stands in for a news site.
      const req = pinnedLinkRequest({ resolve, isPublic: (a) => a === "127.0.0.1" || publicAddress(a) });
      expect(await reachable(`http://news.example:${port}/a`, req, 2000)).toBe(true);
      expect(hits).toEqual([`HEAD news.example:${port}/a`]); // pinned: the name never resolved to this address for real
      expect(await reachable(`http://news.example:${port}/redirect-ok`, req, 2000)).toBe(true);
      // The redirect target is resolved and checked again: 10.0.0.5 → refused without connecting.
      hits.length = 0;
      lookups.length = 0;
      expect(await reachable(`http://news.example:${port}/redirect-internal`, req, 2000)).toBe(false);
      expect(hits).toEqual([`HEAD news.example:${port}/redirect-internal`]);
      expect(lookups).toEqual(["news.example", "internal.example"]);
      // Any non-public address of a name refuses it; unknown names fail.
      expect(await reachable(`http://mixed.example:${port}/`, req, 2000)).toBe(false);
      expect(await reachable(`http://nxdomain.example:${port}/`, req, 2000)).toBe(false);
      // With the real rules loopback is refused.
      hits.length = 0;
      expect(await reachable(`http://loop.example:${port}/`, pinnedLinkRequest({ resolve }), 2000)).toBe(false);
      expect(hits).toEqual([]);
    } finally {
      server.close();
    }
  });

  it("urlKey keeps sorted non-tracking query parameters", () => {
    expect(urlKey("https://www.x.com/a/?b=2&a=1&utm_source=z#f")).toBe("x.com/a?a=1&b=2");
    expect(urlKey("https://x.com/watch?v=1")).not.toBe(urlKey("https://x.com/watch?v=2"));
    expect(urlKey("https://x.com/a?fbclid=1")).toBe("x.com/a");
  });

  it("concurrent run/run and run/tick start one research job", async () => {
    const s = await setup();
    const { feedId } = await s.ready({ when: { kind: "daily", time: "08:00" }, deadlineMinutes: 30 });
    s.net.pc.final = done(fiveItems());
    const svc = s.svc();
    const both = await Promise.allSettled([svc.run(feedId, "manual"), svc.run(feedId, "manual")]);
    expect(both.map((r) => r.status).sort()).toEqual(["fulfilled", "rejected"]);
    expect((both.find((r) => r.status === "rejected") as PromiseRejectedResult).reason).toMatchObject({ code: "agent.telegram.feedRunning" });
    await svc.idle();
    expect(s.net.pc.requests).toHaveLength(1);
    // A slot is due while a manual run starts, in both orders: one job each time, tick doesn't throw.
    s.net.pc.final = done(fiveItems("b").map((it, i) => ({ ...it, headline: HEADLINES[i + 5]! })));
    s.net.t = local(16, 8, 0) + 1000;
    await Promise.all([svc.run(feedId, "manual"), svc.tick()]);
    await svc.idle();
    expect(s.net.pc.requests).toHaveLength(2);
    s.net.t = local(17, 8, 0) + 1000;
    await Promise.all([svc.tick(), svc.run(feedId, "manual").catch((e: unknown) => e)]);
    await svc.idle();
    expect(s.net.pc.requests).toHaveLength(3);
    await s.app.close();
  });

  it("PC job interrupted → recreated; an over-long URL is dropped, not the whole result", async () => {
    const s = await setup();
    const { feedId } = await s.ready();
    s.net.pc.interruptJobs = 1;
    const long = `https://news9.example.com/${"x".repeat(2100)}`;
    const items = fiveItems();
    items[0]!.sources.push({ title: "Uzun", url: long });
    s.net.pc.final = done(items);
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    await s.svc().idle();
    expect(s.net.pc.requests).toHaveLength(2);
    const issue = (await s.req("GET", "/v1/telegram/issues")).body.issues[0];
    expect(issue).toMatchObject({ status: "sent", itemCount: 5 });
    expect(s.net.sent[0]!.text).not.toContain("x".repeat(100));
    await s.app.close();
  });

  it("atlas cancels the PC job when it gives up (deadline, shutdown)", async () => {
    const s = await setup();
    const { feedId } = await s.ready({ deadlineMinutes: 5 });
    s.net.pc.pollsUntilDone = 1e9;
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    await s.svc().idle();
    expect((await s.req("GET", "/v1/telegram/issues")).body.issues[0].error).toBe("agent.telegram.research.timeout");
    expect(s.net.pc.cancelled).toEqual([[...s.net.pc.jobs.keys()][0]]);
    await s.req("POST", `/v1/telegram/feeds/${feedId}/run`);
    for (let i = 0; i < 20 && s.net.pc.jobs.size < 2; i++) await new Promise((r) => setImmediate(r));
    await s.app.close();
    expect(s.net.pc.cancelled).toEqual([...s.net.pc.jobs.keys()]);
    expect(s.net.pc.auth.every((a) => a === `Bearer ${PC_TOKEN}`)).toBe(true);
  });

  it("send queue: close() ends waits at once and fails unsent messages with agent.telegram.shutdown", async () => {
    let sends = 0;
    let sleeps = 0;
    const q = new SendQueue({
      sleep: () => (sleeps++, new Promise<void>(() => {})), // never ends by itself
      send: async () => {
        sends++;
        const e = new TelegramError("agent.telegram.apiRateLimited", 429);
        e.retryAfter = 300;
        throw e;
      },
    });
    const a = q.send(1, "a");
    const b = q.send(1, "b");
    const c = q.send(2, "c");
    await new Promise((r) => setTimeout(r, 20));
    q.close();
    for (const p of [a, b, c]) await expect(p).rejects.toMatchObject({ code: "agent.telegram.shutdown" });
    expect(sends).toBe(2); // chat 1 and chat 2 tried once each; no spinning after close
    expect(sleeps).toBe(2);
    await expect(q.send(3, "d")).rejects.toMatchObject({ code: "agent.telegram.shutdown" });
    expect(sends).toBe(2);
  });

  it("renderer shortens a single oversized item instead of throwing", () => {
    const at = new Date(2026, 10, 16, 8, 5);
    const items = [
      { headline: "Başlık &", summary: "&".repeat(3000), sources: [{ url: "https://a.com/x" }] },
      { headline: "<".repeat(1000), summary: "&".repeat(1000), sources: [{ url: "https://b.com/x" }] },
      { headline: "Normal", summary: "Kısa 😀", sources: [{ url: "https://c.com/x" }] },
    ];
    const parts = renderIssue({ feedName: "F", windowHours: 24, at, models: { research: "gemini-4-argon-high" }, items, limit: 1000 });
    for (const p of parts) {
      expect(p.length).toBeLessThanOrEqual(1000);
      expect(p).not.toMatch(/&(?!amp;|lt;|gt;|quot;)/); // no entity cut in half
    }
    const all = parts.join("\n");
    expect(all).toContain("1. <b>Başlık &amp;</b>\n&amp;");
    expect(all).toContain("…\nKaynak: <a href=\"https://a.com/x\">a.com</a>");
    expect(all).toContain("2. <b>&lt;");
    expect(all).toContain("3. <b>Normal</b>\nKısa 😀");
  });

  it("a corrupt state file is moved aside; the agent starts with an empty state", async () => {
    const { mkdtemp, readdir, writeFile } = await import("node:fs/promises");
    const { tmpdir } = await import("node:os");
    const dir = await mkdtemp(join(tmpdir(), "tiphys-tgstate-"));
    const file = join(dir, "telegram-state.json");
    await writeFile(file, '{"recipients": [', { mode: 0o600 });
    const logs: string[] = [];
    let svc!: TelegramService;
    const t = await testApp((c) => ({ ...c, features: { ...c.features, telegram: true } }), [
      telegramRoutes({ stateFile: file, startTimers: false, log: (m) => logs.push(m), onService: (x) => (svc = x) }),
    ]);
    expect(svc.state.state.recipients).toEqual([]);
    const files = await readdir(dir);
    expect(files.filter((f) => f.startsWith("telegram-state.json.corrupt-"))).toHaveLength(1);
    expect(logs.join("\n")).toMatch(/bozuk/);
    const events = (await t.app.inject({ url: "/v1/events?limit=20", headers: t.auth })).json().events as Array<{ key: string }>;
    expect(events.map((e) => e.key)).toContain("telegram.stateCorrupt");
    expect((await t.app.inject({ url: "/v1/telegram/status", headers: t.auth })).statusCode).toBe(200);
    await t.app.close();
  });
});

describe("telegram: polling for /stop", () => {
  it("polls while a recipient is active (long pause), handles /stop, stops when nobody can write; setBot aborts the poll", async () => {
    const net = new Net();
    const polls: number[] = [];
    let hang = false;
    let open = 0;
    let svc!: TelegramService;
    const f = async (input: string | URL | Request, init: RequestInit = {}) => {
      if (String(input).endsWith("/getUpdates")) {
        polls.push(Date.now());
        if (hang) {
          open++;
          return new Promise<Response>((_, rej) => init.signal!.addEventListener("abort", () => (open--, rej(new Error("aborted")))));
        }
      }
      return net.fetch(input, init);
    };
    const t = await testApp((c) => ({ ...c, features: { ...c.features, telegram: true } }), [
      telegramRoutes({ fetch: f as typeof fetch, stateFile: null, tickMs: 3600_000, pollTimeoutSec: 0, pollGapMs: 1, idlePollGapMs: 80, log: () => {}, onService: (s) => (svc = s) }),
    ]);
    const req = (method: "GET" | "POST" | "PUT" | "DELETE", url: string, payload?: object) => t.app.inject({ method, url, headers: t.auth, payload });
    const until = async (cond: () => boolean) => {
      for (let i = 0; i < 200 && !cond(); i++) await new Promise((r) => setTimeout(r, 10));
      expect(cond()).toBe(true);
    };
    await req("PUT", "/v1/telegram/bot", { token: TOKEN });
    const inv = (await req("POST", "/v1/telegram/invites", {})).json().invite;
    net.updates.push({ update_id: 1, message: { message_id: 1, date: 0, chat: { id: 5, type: "private", first_name: "A" }, text: `/start ${inv.code}` } });
    await until(() => svc.state.state.recipients.length === 1);
    // No invite pending any more, but the recipient may /stop: polling goes on, with the long pause.
    await new Promise((r) => setTimeout(r, 300));
    expect((await req("GET", "/v1/telegram/status")).json()).toMatchObject({ pendingInvites: 0, polling: true });
    const recent = polls.slice(-3);
    expect(recent[2]! - recent[1]!).toBeGreaterThanOrEqual(70);
    net.updates.push({ update_id: 2, message: { message_id: 2, date: 0, chat: { id: 5, type: "private", first_name: "A" }, text: "/stop" } });
    await until(() => svc.state.state.recipients[0]!.status === "stopped");
    // (the /stop reply waits for the 1 msg/s per-chat slot, then the loop ends)
    let polling = true;
    for (let i = 0; i < 200 && polling; i++) {
      await new Promise((r) => setTimeout(r, 10));
      polling = (await req("GET", "/v1/telegram/status")).json().polling;
    }
    expect(polling).toBe(false);
    expect(net.sent.map((m) => m.text).at(-1)).toMatch(/Aboneliğin kapatıldı/);

    // setBot while a long poll hangs: the request is aborted and a new one starts.
    hang = true;
    await req("POST", "/v1/telegram/invites", {});
    await until(() => open === 1);
    const before = polls.length;
    await req("PUT", "/v1/telegram/bot", { token: TOKEN });
    await until(() => polls.length === before + 1 && open === 1);
    await t.app.close();
    expect(open).toBe(0);
  });
});
