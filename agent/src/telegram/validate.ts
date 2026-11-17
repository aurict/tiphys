// Validation of a research result before anything is sent (atlas side; the PC's output is not trusted):
// - sources: http/https only, public host names only (no localhost/private/tailnet addresses: the agent fetches them),
//   allow/block domain rules, the URL must appear in result.seenUrls (tool output on the PC; a made-up link drops),
//   and must be reachable (HEAD/GET, 8 s, ≤3 redirects; every hop's host is resolved, all its addresses must be
//   public, and the connection goes to the checked address, so DNS can't point the agent into the tailnet/LAN);
// - dedupe against this feed's issues of the last 14 days (normalized URL, headline token Jaccard ≥ 0.8) and within the
//   issue; items with no source left are dropped; length caps keep every item well inside one Telegram message.
import { lookup } from "node:dns/promises";
import { request as httpRequest, type IncomingMessage } from "node:http";
import { request as httpsRequest } from "node:https";
import { BlockList, isIP } from "node:net";
import type { Fetch } from "./api.ts";
import { escapeHtml, type RenderItem } from "./render.ts";

const TRACKING = /^(utm_.*|fbclid|gclid|dclid|msclkid|mc_cid|mc_eid|igshid|_ga|ref_src|cmpid)$/i;
const MAX_URL = 512;
const HEADLINE_CHARS = 200;
const SUMMARY_CHARS = 800;
/** Escaped-length caps (pathological input with many & or quotes): an item then always fits one message. */
const HEADLINE_ESCAPED = 600;
const SUMMARY_ESCAPED = 1500;
const URL_ESCAPED = 400;
export const SIMILAR_HEADLINE = 0.8;
export const REACH_TIMEOUT_MS = 8000;
const UA = "Mozilla/5.0 (compatible; TiphysBot/1.0; link check)";

/** http(s) URL without fragment and tracking parameters; null if unusable. */
export function normalizeUrl(raw: string): string | null {
  let u: URL;
  try {
    u = new URL(raw.trim());
  } catch {
    return null;
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return null;
  if (u.username || u.password) return null;
  u.hash = "";
  for (const k of [...u.searchParams.keys()]) if (TRACKING.test(k)) u.searchParams.delete(k);
  return u.href;
}

/** Comparison key: host (lowercase, without www.) + path (without trailing slash) + sorted non-tracking query. */
export function urlKey(raw: string): string | null {
  const n = normalizeUrl(raw);
  if (!n) return null;
  const u = new URL(n);
  const path = u.pathname.replace(/\/+$/, "");
  u.searchParams.sort();
  return `${u.hostname.replace(/^www\./, "")}${path}${u.search}`;
}

/** Only public-looking names: the agent requests these URLs from inside the tailnet. */
export function publicHost(hostname: string): boolean {
  const h = hostname.toLowerCase().replace(/\.$/, "");
  if (!h.includes(".")) return false;
  if (h.startsWith("[")) return false; // IPv6 literal
  if (/(^|\.)(localhost|local|internal|lan|home\.arpa|ts\.net|onion)$/.test(h)) return false;
  const v4 = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(h);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    if (a === 0 || a === 10 || a === 127 || a >= 224) return false;
    if (a === 169 && b === 254) return false;
    if (a === 172 && b >= 16 && b <= 31) return false;
    if (a === 192 && b === 168) return false;
    if (a === 100 && b >= 64 && b <= 127) return false; // CGNAT / Tailscale
  }
  return true;
}

export function domainMatches(host: string, domain: string): boolean {
  const h = host.toLowerCase().replace(/^www\./, "");
  const d = domain.toLowerCase().replace(/^www\./, "");
  return h === d || h.endsWith(`.${d}`);
}

export function headlineTokens(s: string): Set<string> {
  return new Set(
    s
      .toLocaleLowerCase("tr-TR")
      .normalize("NFKD")
      .replace(/\p{M}/gu, "")
      .split(/[^\p{L}\p{N}]+/u)
      .filter((t) => t.length >= 2),
  );
}

export function jaccard(a: Set<string>, b: Set<string>): number {
  if (a.size === 0 && b.size === 0) return 1;
  let inter = 0;
  for (const t of a) if (b.has(t)) inter++;
  return inter / (a.size + b.size - inter);
}

const okStatus = (s: number) => (s >= 200 && s < 400) || s === 401 || s === 403 || s === 429;

// Addresses the link check never connects to (IANA special-purpose ranges, private, loopback, link-local, CGNAT/
// Tailscale 100.64/10 and fd7a:115c:a1e0::/48 (inside fc00::/7), multicast, IPv4-mapped/translated IPv6).
// Separate lists: one BlockList would also match IPv4 addresses against the IPv4-mapped IPv6 rule.
const BLOCKED_V4 = new BlockList();
const BLOCKED_V6 = new BlockList();
for (const [net, bits] of [
  ["0.0.0.0", 8], ["10.0.0.0", 8], ["100.64.0.0", 10], ["127.0.0.0", 8], ["169.254.0.0", 16], ["172.16.0.0", 12],
  ["192.0.0.0", 24], ["192.0.2.0", 24], ["192.88.99.0", 24], ["192.168.0.0", 16], ["198.18.0.0", 15],
  ["198.51.100.0", 24], ["203.0.113.0", 24], ["224.0.0.0", 4], ["240.0.0.0", 4],
] as const) BLOCKED_V4.addSubnet(net, bits, "ipv4");
for (const [net, bits] of [
  ["::", 128], ["::1", 128], ["::ffff:0:0", 96], ["64:ff9b::", 96], ["64:ff9b:1::", 48], ["100::", 64], ["2001::", 32],
  ["2001:db8::", 32], ["2002::", 16], ["fc00::", 7], ["fe80::", 10], ["fec0::", 10], ["ff00::", 8],
] as const) BLOCKED_V6.addSubnet(net, bits, "ipv6");

/** Is this IP address a public unicast address? */
export function publicAddress(address: string): boolean {
  const v = isIP(address);
  if (v === 0) return false;
  return v === 4 ? !BLOCKED_V4.check(address, "ipv4") : !BLOCKED_V6.check(address, "ipv6");
}

export type Resolve = (host: string) => Promise<Array<{ address: string; family: number }>>;
const systemResolve: Resolve = (host) => lookup(host, { all: true, verbatim: true });

/** One HEAD/GET of a link check: status and Location header (the body is never read). */
export type LinkRequest = (url: string, method: "HEAD" | "GET", signal: AbortSignal) => Promise<{ status: number; location: string | null }>;

/**
 * The real link check request: resolves the host, refuses it unless every address is public, then connects to the
 * address it checked (no second lookup that DNS rebinding could answer differently). TLS still verifies the host name.
 */
export function pinnedLinkRequest(o: { resolve?: Resolve; isPublic?: (address: string) => boolean } = {}): LinkRequest {
  const resolve = o.resolve ?? systemResolve;
  const isPublic = o.isPublic ?? publicAddress;
  return async (url, method, signal) => {
    const u = new URL(url);
    const host = u.hostname.replace(/^\[|\]$/g, "");
    const addrs = isIP(host) ? [{ address: host, family: isIP(host) }] : await resolve(host);
    if (addrs.length === 0 || !addrs.every((a) => isPublic(a.address))) throw new Error("link check: non-public address");
    const { address, family } = addrs[0]!;
    const req = u.protocol === "https:" ? httpsRequest : httpRequest;
    return new Promise((resolveRes, reject) => {
      const r = req(
        u,
        {
          method,
          signal,
          agent: false,
          headers: { "user-agent": UA, accept: "text/html,*/*" },
          lookup: ((_h: string, opts: { all?: boolean }, cb: (...a: unknown[]) => void) =>
            opts?.all ? cb(null, [{ address, family }]) : cb(null, address, family)) as never,
        },
        (res: IncomingMessage) => {
          const location = typeof res.headers.location === "string" ? res.headers.location : null;
          res.destroy();
          resolveRes({ status: res.statusCode ?? 0, location });
        },
      );
      r.on("error", reject);
      r.end();
    });
  };
}

/** LinkRequest over a fetch function (tests with fake sites). */
export function fetchLinkRequest(f: Fetch): LinkRequest {
  return async (url, method, signal) => {
    const res = await f(url, { method, redirect: "manual", signal, headers: { "user-agent": UA, accept: "text/html,*/*" } });
    await res.body?.cancel().catch(() => {});
    return { status: res.status, location: res.headers.get("location") };
  };
}

/**
 * Is the URL reachable? HEAD (GET if HEAD isn't allowed), redirects followed by hand (≤3, each target must be a public
 * http(s) URL and is checked again like the first). 2xx/3xx count; 401/403/429 too (news sites answer bots that way,
 * and the URL was already seen in the research tool output); 404/410/5xx, network/DNS errors and non-public addresses don't.
 */
export async function reachable(url: string, req: LinkRequest, timeoutMs = REACH_TIMEOUT_MS): Promise<boolean> {
  const signal = AbortSignal.timeout(timeoutMs);
  let cur = url;
  try {
    for (let hop = 0; ; hop++) {
      if (!publicHost(new URL(cur).hostname)) return false;
      let res = await req(cur, "HEAD", signal);
      if (res.status === 405 || res.status === 501 || res.status === 400) res = await req(cur, "GET", signal);
      const loc = res.location;
      if (res.status >= 300 && res.status < 400 && loc && hop < 3) {
        const next = normalizeUrl(new URL(loc, cur).href);
        if (!next || !publicHost(new URL(next).hostname)) return false;
        cur = next;
        continue;
      }
      return okStatus(res.status);
    }
  } catch {
    return false;
  }
}

async function mapLimit<T, R>(xs: T[], n: number, fn: (x: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(xs.length);
  let i = 0;
  await Promise.all(
    Array.from({ length: Math.min(n, xs.length) }, async () => {
      while (i < xs.length) {
        const k = i++;
        out[k] = await fn(xs[k]!);
      }
    }),
  );
  return out;
}

const clean = (s: string) => s.replace(/[\u0000-\u001f\u007f​-‏‪-‮⁦-⁩]+/g, " ").replace(/\s+/g, " ").trim();
const cap = (s: string, n: number) => (s.length > n ? `${s.slice(0, n - 1).trimEnd()}…` : s);

export interface ResearchItem {
  headline: string;
  summary: string;
  published?: string | null;
  sources: Array<{ title?: string; url: string }>;
}

export interface ValidationRules {
  maxItems: number;
  maxSourcesPerItem: number;
  allowDomains: string[];
  blockDomains: string[];
}

export interface ValidationStats {
  received: number;
  kept: number;
  droppedItems: number;
  droppedSources: number;
}

export async function validateItems(
  items: ResearchItem[],
  seenUrls: string[],
  rules: ValidationRules,
  history: { urlKeys: Set<string>; headlines: string[] },
  req: LinkRequest,
  opts: { timeoutMs?: number; concurrency?: number } = {},
): Promise<{ items: RenderItem[]; stats: ValidationStats }> {
  const seen = new Set(seenUrls.map(urlKey).filter((k): k is string => k !== null));
  let droppedSources = 0;

  // 1. Cheap checks per source.
  const pre = items.map((it) => {
    const headline = cap(clean(it.headline ?? ""), HEADLINE_CHARS);
    const summary = cap(clean(it.summary ?? ""), SUMMARY_CHARS);
    const candidates: Array<{ title: string; url: string; key: string }> = [];
    for (const s of it.sources ?? []) {
      const url = typeof s.url === "string" ? normalizeUrl(s.url) : null;
      const key = url ? urlKey(url) : null;
      const host = url ? new URL(url).hostname : "";
      const ok =
        url !== null &&
        key !== null &&
        url.length <= MAX_URL &&
        escapeHtml(url).length <= URL_ESCAPED &&
        publicHost(host) &&
        !rules.blockDomains.some((d) => domainMatches(host, d)) &&
        (rules.allowDomains.length === 0 || rules.allowDomains.some((d) => domainMatches(host, d))) &&
        seen.has(key) &&
        !history.urlKeys.has(key) &&
        !candidates.some((c) => c.key === key);
      if (ok) candidates.push({ title: clean(s.title ?? "").slice(0, 200), url, key });
      else droppedSources++;
    }
    // A few spares in case some aren't reachable.
    const extra = candidates.splice(rules.maxSourcesPerItem + 2);
    droppedSources += extra.length;
    const valid = headline !== "" && summary !== "" && escapeHtml(headline).length <= HEADLINE_ESCAPED && escapeHtml(summary).length <= SUMMARY_ESCAPED;
    return { headline, summary, candidates: valid ? candidates : [] };
  });

  // 2. Reachability, each distinct URL once.
  const urls = [...new Set(pre.flatMap((p) => p.candidates.map((c) => c.url)))];
  const results = await mapLimit(urls, opts.concurrency ?? 6, (u) => reachable(u, req, opts.timeoutMs));
  const ok = new Map(urls.map((u, i) => [u, results[i]!]));

  // 3. Assemble in order: headline dedupe, URL dedupe within the issue, caps.
  const usedKeys = new Set<string>();
  const kept: RenderItem[] = [];
  const keptHeadlines = history.headlines.map(headlineTokens);
  for (const p of pre) {
    if (kept.length >= rules.maxItems) break;
    if (!p.headline) continue;
    const tokens = headlineTokens(p.headline);
    if (keptHeadlines.some((h) => jaccard(h, tokens) >= SIMILAR_HEADLINE)) continue;
    const sources = p.candidates.filter((c) => ok.get(c.url) && !usedKeys.has(c.key)).slice(0, rules.maxSourcesPerItem);
    droppedSources += p.candidates.length - sources.length;
    if (sources.length === 0) continue;
    for (const s of sources) usedKeys.add(s.key);
    keptHeadlines.push(tokens);
    kept.push({ headline: p.headline, summary: p.summary, sources: sources.map(({ title, url }) => ({ title, url })) });
  }
  return { items: kept, stats: { received: items.length, kept: kept.length, droppedItems: items.length - kept.length, droppedSources } };
}
