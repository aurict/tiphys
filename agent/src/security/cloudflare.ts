// Attack detection from Cloudflare (PLAN.md §15 S-5), replacing the planned CrowdSec setup: the sites sit behind a
// Cloudflare Tunnel and their own logs carry no client IP, but Cloudflare's GraphQL Analytics does.
//   Every 15 min: httpRequestsAdaptiveGroups (4xx/5xx of the last window) per zone, grouped by client IP and path.
//   An IP is an offender with ≥ 3 requests to well-known scanner paths, or ≥ 30 error responses over ≥ 10 paths.
//   security.attack is sent once per IP per day (default priority; this is noise on the internet, not an incident).
//   Optional blocking (a separate token with "Zone › Firewall Services: Edit" only): a zone IP Access Rule
//   {mode: block, notes: "tiphys:<expiry>"}; rules past their expiry are removed on the next run. Allowlisted IPs
//   (the servers' own, private/Tailscale ranges) are never blocked.
// Tokens never leave agent.json. Not validated against the live API until a token is configured (see PLAN §15).
import { chmod, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

const API = "https://api.cloudflare.com/client/v4";
export const SCANNER_PATHS = [
  /^\/\.env/i,
  /^\/\.git\//i,
  /^\/\.aws\//i,
  /^\/wp-(admin|login|content|includes)/i,
  /^\/xmlrpc\.php/i,
  /^\/phpmyadmin/i,
  /^\/pma\//i,
  /^\/vendor\/phpunit/i,
  /^\/cgi-bin\//i,
  /^\/(boaform|HNAP1|GponForm)/i,
  /^\/actuator/i,
  /^\/server-status/i,
  /\.(php|asp|aspx|jsp)$/i,
  /service-account.*\.json$/i,
  /^\/(config|credentials|secrets?)\.(json|ya?ml)$/i,
  /^\/(backup|db|dump)\.(zip|sql|tar\.gz)$/i,
];

export const isScannerPath = (p: string) => SCANNER_PATHS.some((r) => r.test(p.split("?")[0]!));

export interface Offender {
  zone: string;
  ip: string;
  country: string;
  errors: number;
  scannerHits: number;
  paths: string[];
  firstSeenAt: string;
  lastSeenAt: string;
  blockedUntil: string | null;
}

export interface RequestGroup {
  count: number;
  dimensions: { clientIP: string; clientRequestPath: string; edgeResponseStatus: number; clientCountryName?: string };
}

/** Groups of one window → offenders by the rules above. */
export function offendersOf(zone: string, groups: RequestGroup[], at: string): Offender[] {
  const by = new Map<string, Offender & { pathSet: Set<string> }>();
  for (const g of groups) {
    const ip = g.dimensions.clientIP;
    if (!ip) continue;
    const o = by.get(ip) ?? { zone, ip, country: g.dimensions.clientCountryName ?? "", errors: 0, scannerHits: 0, paths: [], pathSet: new Set<string>(), firstSeenAt: at, lastSeenAt: at, blockedUntil: null };
    o.errors += g.count;
    const path = (g.dimensions.clientRequestPath ?? "").slice(0, 200);
    if (isScannerPath(path)) o.scannerHits += g.count;
    o.pathSet.add(path);
    by.set(ip, o);
  }
  return [...by.values()]
    .filter((o) => o.scannerHits >= 3 || (o.errors >= 30 && o.pathSet.size >= 10))
    .map(({ pathSet, ...o }) => ({ ...o, paths: [...pathSet].sort((a, b) => Number(isScannerPath(b)) - Number(isScannerPath(a))).slice(0, 10) }));
}

/** IPs that must never be blocked: private, loopback, CGNAT/Tailscale, link-local, IPv6 ULA/link-local, and the allowlist. */
export function neverBlock(ip: string, allow: string[]): boolean {
  if (allow.includes(ip)) return true;
  if (/^(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2\d|3[01])\.|100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.)/.test(ip)) return true;
  if (/^(::1$|f[cd]|fe[89ab])/i.test(ip)) return true;
  return !/^[0-9a-fA-F:.]{3,45}$/.test(ip);
}

export const QUERY = `query($zone: string!, $since: Time!, $until: Time!) {
  viewer { zones(filter: {zoneTag: $zone}) {
    httpRequestsAdaptiveGroups(limit: 2000, filter: {datetime_geq: $since, datetime_lt: $until, edgeResponseStatus_geq: 400}, orderBy: [count_DESC]) {
      count
      dimensions { clientIP clientRequestPath edgeResponseStatus clientCountryName }
    }
  } }
}`;

interface State {
  offenders: Record<string, Offender>;
  lastRun: { at: string; zones: number; error: string | null } | null;
  notified: Record<string, string>;
}

export class CloudflareWatch {
  readonly file: string;
  state: State = { offenders: {}, lastRun: null, notified: {} };
  #ctx: Ctx;
  #fetch: typeof fetch;
  #now: () => number;
  #busy = false;

  constructor(ctx: Ctx, o: { fetch?: typeof fetch; now?: () => number } = {}) {
    this.#ctx = ctx;
    this.#fetch = o.fetch ?? fetch;
    this.#now = o.now ?? Date.now;
    this.file = join(dirname(ctx.store.path), "security-attacks.json");
  }

  async load() {
    const raw = await readFile(this.file, "utf8").catch(() => null);
    if (!raw) return;
    try {
      const s = JSON.parse(raw) as State;
      this.state = { offenders: s.offenders ?? {}, lastRun: s.lastRun ?? null, notified: s.notified ?? {} };
    } catch {
      await rename(this.file, `${this.file}.corrupt-${Date.now()}`).catch(() => {});
    }
  }

  async #persist() {
    // Keep 7 days of offenders.
    const cutoff = this.#now() - 7 * 86_400_000;
    for (const [k, o] of Object.entries(this.state.offenders)) if (Date.parse(o.lastSeenAt) < cutoff && !o.blockedUntil) delete this.state.offenders[k];
    const tmp = `${this.file}.${process.pid}.tmp`;
    await writeFile(tmp, JSON.stringify(this.state), { mode: 0o600 });
    await chmod(tmp, 0o600);
    await rename(tmp, this.file);
  }

  async #api(path: string, token: string, init: RequestInit = {}): Promise<{ result?: unknown; success?: boolean; result_info?: { total_pages?: number } }> {
    const res = await this.#fetch(`${API}${path}`, {
      ...init,
      headers: { authorization: `Bearer ${token}`, "content-type": "application/json", ...(init.headers as Record<string, string> | undefined) },
      signal: AbortSignal.timeout(30_000),
      redirect: "error",
    });
    if (res.status === 401 || res.status === 403) throw new AppError("agent.security.cloudflareUnauthorized", 502, { status: res.status });
    const body = (await res.json().catch(() => ({}))) as { success?: boolean; result?: unknown; errors?: unknown[] };
    if (!res.ok || body.success === false) throw new AppError("agent.security.cloudflareFailed", 502, { status: res.status });
    return body;
  }

  async #zones(token: string): Promise<{ id: string; name: string }[]> {
    const cfg = this.#ctx.store.get().security.cloudflare;
    const r = await this.#api("/zones?per_page=50&status=active", token);
    const all = (Array.isArray(r.result) ? r.result : []) as Array<{ id: string; name: string }>;
    return all.filter((z) => /^[a-f0-9]{32}$/.test(z.id) && (!cfg.zones.length || cfg.zones.includes(z.name)));
  }

  async run(): Promise<{ offenders: number; blocked: number }> {
    if (this.#busy) throw new AppError("agent.security.scanBusy", 409);
    const cfg = this.#ctx.store.get().security.cloudflare;
    if (!cfg.readToken) throw new AppError("agent.security.cloudflareNotConfigured", 409);
    this.#busy = true;
    const at = new Date(this.#now()).toISOString();
    let blocked = 0;
    let fresh: Offender[] = [];
    try {
      const zones = await this.#zones(cfg.readToken);
      const until = new Date(Math.floor(this.#now() / 60_000) * 60_000);
      const since = new Date(Math.max(until.getTime() - 15 * 60_000, this.state.lastRun && !this.state.lastRun.error ? Date.parse(this.state.lastRun.at) - 60_000 : 0));
      for (const z of zones) {
        const r = await this.#fetch(`${API}/graphql`, {
          method: "POST",
          headers: { authorization: `Bearer ${cfg.readToken}`, "content-type": "application/json" },
          body: JSON.stringify({ query: QUERY, variables: { zone: z.id, since: since.toISOString(), until: until.toISOString() } }),
          signal: AbortSignal.timeout(30_000),
          redirect: "error",
        });
        if (r.status === 401 || r.status === 403) throw new AppError("agent.security.cloudflareUnauthorized", 502, { status: r.status });
        const body = (await r.json().catch(() => ({}))) as { data?: { viewer?: { zones?: Array<{ httpRequestsAdaptiveGroups?: RequestGroup[] }> } }; errors?: unknown[] | null };
        if (!r.ok || (body.errors && body.errors.length)) throw new AppError("agent.security.cloudflareFailed", 502, { status: r.status });
        const groups = body.data?.viewer?.zones?.[0]?.httpRequestsAdaptiveGroups ?? [];
        for (const o of offendersOf(z.name, groups, at)) {
          const key = `${z.name}|${o.ip}`;
          const prev = this.state.offenders[key];
          const merged: Offender = prev
            ? { ...prev, errors: prev.errors + o.errors, scannerHits: prev.scannerHits + o.scannerHits, paths: [...new Set([...prev.paths, ...o.paths])].slice(0, 10), lastSeenAt: at, country: o.country || prev.country }
            : o;
          this.state.offenders[key] = merged;
          const day = at.slice(0, 10);
          if (this.state.notified[key] !== day) {
            this.state.notified[key] = day;
            fresh.push(merged);
          }
          if (cfg.block && cfg.blockToken && !merged.blockedUntil && !neverBlock(o.ip, cfg.allowIps)) {
            const until2 = new Date(this.#now() + cfg.blockHours * 3600_000).toISOString();
            await this.#api(`/zones/${z.id}/firewall/access_rules/rules`, cfg.blockToken, {
              method: "POST",
              body: JSON.stringify({ mode: "block", configuration: { target: o.ip.includes(":") ? "ip6" : "ip", value: o.ip }, notes: `tiphys:${until2}` }),
            });
            merged.blockedUntil = until2;
            blocked++;
          }
        }
        if (cfg.blockToken) await this.#expire(z.id, cfg.blockToken);
      }
      for (const n of Object.keys(this.state.notified)) if (this.state.notified[n] !== at.slice(0, 10)) delete this.state.notified[n];
      this.state.lastRun = { at, zones: zones.length, error: null };
    } catch (e) {
      this.state.lastRun = { at, zones: 0, error: e instanceof AppError ? e.code : "agent.security.cloudflareFailed" };
      fresh = [];
      throw e;
    } finally {
      this.#busy = false;
      await this.#persist().catch(() => {});
    }
    if (fresh.length) {
      await this.#ctx.notifier.send({
        key: "security.attack",
        params: { host: this.#ctx.store.get().name, agent: this.#ctx.store.get().name, count: fresh.length, zones: [...new Set(fresh.map((o) => o.zone))].slice(0, 3).join(", "), blocked },
        link: "tiphys://security/attacks",
        priority: "default",
      });
    }
    return { offenders: fresh.length, blocked };
  }

  /** Removes this agent's block rules whose expiry passed (only rules with a "tiphys:<time>" note). */
  async #expire(zoneId: string, token: string) {
    const r = await this.#api(`/zones/${zoneId}/firewall/access_rules/rules?per_page=100&notes=tiphys%3A&match=all`, token);
    for (const rule of (Array.isArray(r.result) ? r.result : []) as Array<{ id: string; notes?: string; configuration?: { value?: string } }>) {
      const m = /^tiphys:(\S+)$/.exec(rule.notes ?? "");
      if (!m || !/^[a-f0-9]{32}$/.test(rule.id) || Date.parse(m[1]!) > this.#now()) continue;
      await this.#api(`/zones/${zoneId}/firewall/access_rules/rules/${rule.id}`, token, { method: "DELETE" });
      for (const o of Object.values(this.state.offenders)) if (o.ip === rule.configuration?.value) o.blockedUntil = null;
    }
  }

  list() {
    return {
      lastRun: this.state.lastRun,
      offenders: Object.values(this.state.offenders).sort((a, b) => b.lastSeenAt.localeCompare(a.lastSeenAt) || b.scannerHits - a.scannerHits),
    };
  }
}
