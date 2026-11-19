// Security center S-5 (PLAN.md §15): outside view (ports, TLS, headers, leak paths) and Cloudflare attack detection.
import { describe, expect, it } from "vitest";
import { CloudflareWatch, isScannerPath, neverBlock, offendersOf, type RequestGroup } from "../src/security/cloudflare.ts";
import { ExposureScanner, LEAK_PATHS } from "../src/security/exposure.ts";
import { securityRoutes } from "../src/security/routes.ts";
import { testApp } from "./helpers.ts";

describe("exposure", () => {
  async function setup(pages: Record<string, { status: number; body?: string; type?: string; headers?: Record<string, string> }>, open: number[], certDays = 60) {
    const t = await testApp((c) => {
      c.security.exposure = {
        enabled: true,
        targets: [
          { id: "srv", kind: "ip", value: "203.0.113.10", expectedPorts: [443] },
          { id: "site", kind: "domain", value: "example.org", expectedPorts: [] },
        ],
        extraPorts: [],
        intervalDays: 7,
      };
      return c;
    });
    const now = Date.parse("2026-11-19T03:00:00Z");
    const requested: string[] = [];
    const s = new ExposureScanner(
      { store: t.store, notifier: t.notifier },
      {
        now: () => now,
        spacingMs: 0,
        probe: async (_h, p) => open.includes(p),
        cert: async () => ({ validTo: new Date(now + certDays * 86_400_000).toISOString() }),
        fetch: (async (u: string) => {
          requested.push(String(u));
          const p = pages[String(u)] ?? pages["*"] ?? { status: 404 };
          return new Response(p.body ?? "", { status: p.status, headers: { "content-type": p.type ?? "text/html", ...p.headers } });
        }) as unknown as typeof fetch,
      },
    );
    return { t, s, requested };
  }

  it("open ports beyond the expected ones; SPA index answers aren't leaks; a real .env is", async () => {
    const spa = { status: 200, body: "<!doctype html><div id=root></div>", type: "text/html" };
    const { t, s, requested } = await setup(
      {
        "http://example.org/": { status: 301 },
        "https://example.org/": { status: 200, body: "<html>", headers: { "strict-transport-security": "max-age=1", "x-content-type-options": "nosniff", "referrer-policy": "no-referrer", "content-security-policy": "frame-ancestors 'none'" } },
        "https://example.org/.env": { status: 200, body: "DB_PASSWORD=hunter2\n", type: "text/plain" },
        "*": spa,
      },
      [22, 443, 6379],
    );
    const run = await s.run();
    expect(run.targets.find((x) => x.id === "srv")!.openPorts).toEqual([22, 443, 6379]);
    expect(run.findings.map((f) => f.id).sort()).toEqual(["exposure.leakPath:example.org:/.env", "exposure.openPort:203.0.113.10:22", "exposure.openPort:203.0.113.10:6379"]);
    expect(JSON.stringify(run)).not.toContain("hunter2");
    // First run: only critical findings are announced (the leak).
    expect(t.sent).toEqual([expect.objectContaining({ key: "security.exposure", priority: "high", params: expect.objectContaining({ count: 1, targets: "example.org" }) })]);
    expect(requested.length).toBe(2 + LEAK_PATHS.length);
  });

  it("second run announces only what is new; TLS/HTTPS/header findings", async () => {
    const { t, s } = await setup({ "http://example.org/": { status: 200 }, "https://example.org/": { status: 200 }, "*": { status: 404 } }, [443], 5);
    const r1 = await s.run();
    expect(r1.findings.map((f) => f.rule).sort()).toEqual(["exposure.headers", "exposure.noHsts", "exposure.noHttps", "exposure.tlsExpiry"]);
    expect(r1.findings.find((f) => f.rule === "exposure.tlsExpiry")!.severity).toBe("high");
    expect(t.sent).toEqual([]);
    await s.run();
    expect(t.sent).toEqual([]);
    expect(s.due()).toBe(false);
  });
});

describe("cloudflare", () => {
  const g = (ip: string, path: string, count = 1, status = 404): RequestGroup => ({ count, dimensions: { clientIP: ip, clientRequestPath: path, edgeResponseStatus: status, clientCountryName: "XX" } });

  it("scanner paths and offender rules", () => {
    expect(isScannerPath("/.env.production")).toBe(true);
    expect(isScannerPath("/wp-login.php?x=1")).toBe(true);
    expect(isScannerPath("/service-account-key.json")).toBe(true);
    expect(isScannerPath("/api/users/1")).toBe(false);
    const groups = [g("198.51.100.1", "/.env", 2), g("198.51.100.1", "/.git/config"), g("198.51.100.2", "/api/x", 50), ...Array.from({ length: 12 }, (_, i) => g("198.51.100.3", `/p${i}`, 3))];
    expect(offendersOf("example.org", groups, "t").map((o) => `${o.ip}:${o.scannerHits}:${o.errors}`)).toEqual(["198.51.100.1:3:3", "198.51.100.3:0:36"]);
  });

  it("never blocks private, Tailscale, link-local or allowlisted addresses", () => {
    for (const ip of ["10.0.0.1", "192.168.1.5", "172.20.0.1", "100.82.1.1", "127.0.0.1", "fd7a:115c::1", "fe80::1", "203.0.113.10", "not an ip"]) expect(neverBlock(ip, ["203.0.113.10"]), ip).toBe(true);
    expect(neverBlock("198.51.100.1", [])).toBe(false);
  });

  it("detects, notifies once a day, blocks with a separate token, removes expired rules", async () => {
    let now = Date.parse("2026-11-19T10:00:00Z");
    const t = await testApp((c) => {
      c.security.cloudflare = { readToken: "read-tok", blockToken: "block-tok", block: true, blockHours: 24, zones: [], allowIps: ["198.51.100.9"] };
      return c;
    });
    const calls: Array<{ method: string; url: string; auth: string; body?: string }> = [];
    let rules: Array<{ id: string; notes: string; configuration: { value: string } }> = [{ id: "a".repeat(32), notes: "tiphys:2026-11-18T00:00:00.000Z", configuration: { value: "198.51.100.7" } }, { id: "b".repeat(32), notes: "manual", configuration: { value: "x" } }];
    const fetchFake = (async (u: string, init: RequestInit) => {
      const url = String(u);
      calls.push({ method: init.method ?? "GET", url, auth: String((init.headers as Record<string, string>).authorization), body: init.body as string | undefined });
      const json = (x: unknown) => new Response(JSON.stringify(x));
      if (url.endsWith("/graphql")) return json({ data: { viewer: { zones: [{ httpRequestsAdaptiveGroups: [g("198.51.100.1", "/.env", 3), g("198.51.100.9", "/.env", 5), g("10.0.0.1", "/.git/HEAD", 9)] }] } }, errors: null });
      if (url.includes("/zones?")) return json({ success: true, result: [{ id: "c".repeat(32), name: "example.org" }] });
      if (url.includes("/access_rules/rules?")) return json({ success: true, result: rules });
      if (init.method === "DELETE") {
        rules = rules.filter((r) => !url.endsWith(r.id));
        return json({ success: true, result: {} });
      }
      return json({ success: true, result: { id: "d".repeat(32) } });
    }) as unknown as typeof fetch;
    const w = new CloudflareWatch({ store: t.store, notifier: t.notifier }, { fetch: fetchFake, now: () => now });
    expect(await w.run()).toEqual({ offenders: 3, blocked: 1 });
    const posts = calls.filter((c) => c.method === "POST" && c.url.includes("access_rules"));
    expect(posts).toHaveLength(1);
    expect(JSON.parse(posts[0]!.body!)).toEqual({ mode: "block", configuration: { target: "ip", value: "198.51.100.1" }, notes: "tiphys:2026-11-20T10:00:00.000Z" });
    expect(posts[0]!.auth).toBe("Bearer block-tok");
    expect(calls.find((c) => c.url.endsWith("/graphql"))!.auth).toBe("Bearer read-tok");
    expect(calls.filter((c) => c.method === "DELETE").map((c) => c.url.slice(-32))).toEqual(["a".repeat(32)]);
    expect(t.sent).toEqual([expect.objectContaining({ key: "security.attack", params: expect.objectContaining({ count: 3, blocked: 1 }) })]);
    now += 15 * 60_000;
    expect(await w.run()).toEqual({ offenders: 0, blocked: 0 });
    expect(t.sent).toHaveLength(1);
    expect(w.list().offenders.find((o) => o.ip === "198.51.100.1")!.blockedUntil).toBe("2026-11-20T10:00:00.000Z");
    expect(JSON.stringify(w.state)).not.toMatch(/read-tok|block-tok/);
  });

  it("settings hide tokens; blocking needs the block token", async () => {
    const t = await testApp((c) => c, [securityRoutes({ startTimer: false })]);
    let r = await t.app.inject({ method: "PUT", url: "/v1/security/cloudflare", headers: t.auth, payload: { readToken: "r1", block: true } });
    expect(r.json().error.code).toBe("agent.security.tokenRequired");
    r = await t.app.inject({ method: "PUT", url: "/v1/security/cloudflare", headers: t.auth, payload: { readToken: "r1", blockToken: "b1", block: true } });
    expect(r.json()).toMatchObject({ hasReadToken: true, hasBlockToken: true, block: true });
    expect(r.body).not.toMatch(/r1|b1/);
    r = await t.app.inject({ method: "PUT", url: "/v1/security/cloudflare", headers: t.auth, payload: { zones: ["example.org"] } });
    expect(t.store.get().security.cloudflare.readToken).toBe("r1");
    r = await t.app.inject({ method: "PUT", url: "/v1/security/cloudflare", headers: t.auth, payload: { blockToken: null } });
    expect(r.json().error.code).toBe("agent.security.tokenRequired");
    r = await t.app.inject({ method: "GET", url: "/v1/security/attacks", headers: t.auth });
    expect(r.json()).toMatchObject({ configured: true, offenders: [] });
    r = await t.app.inject({ method: "PUT", url: "/v1/security/exposure", headers: t.auth, payload: { enabled: true, targets: [{ id: "x", kind: "domain", value: "bad value" }] } });
    expect(r.statusCode).toBe(400);
  });
});
