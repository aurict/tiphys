// Security center S-4 (PLAN.md §15): black box hash chain (local + push), recovery code and lockdown fan-out.
import { appendFile, readFile, stat, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { RateLimit } from "../src/control.ts";
import { createServiceToken } from "../src/service_tokens.ts";
import { BlackBox, BlackBoxPusher, GENESIS, recordHash } from "../src/security/blackbox.ts";
import { codeMatches, hashCode, newRecoveryCode, normalizeCode } from "../src/security/lockdown.ts";
import { securityRoutes } from "../src/security/routes.ts";
import { testApp } from "./helpers.ts";

describe("BlackBox", () => {
  it("chains records, survives a restart, verifies, and spots edits, deletions and truncation", async () => {
    const t = await testApp();
    const box = new BlackBox(t.store.path);
    await box.load();
    const a = await box.append("atlas", "audit", { method: "POST", path: "/x" });
    const b = await box.append("atlas", "event", { key: "k", params: { n: 1 } });
    expect(a.prev).toBe(GENESIS);
    expect(b.prev).toBe(a.hash);
    expect(b.hash).toBe(recordHash(a.hash, b));
    expect((await stat(box.file)).mode & 0o777).toBe(0o600);
    expect((await stat(box.dir)).mode & 0o777).toBe(0o700);
    const again = new BlackBox(t.store.path);
    await again.load();
    expect(again.head).toEqual({ count: 2, hash: b.hash });
    await again.append("atlas", "audit", { x: 1 });
    expect(await again.verify()).toMatchObject({ ok: true, count: 3 });

    const text = await readFile(box.file, "utf8");
    await writeFile(box.file, text.replace('"path":"/x"', '"path":"/y"'));
    expect(await again.verify()).toMatchObject({ ok: false, brokenAt: 1, reason: "hash" });
    const lines = text.split("\n").filter(Boolean);
    await writeFile(box.file, [lines[0], lines[2]].join("\n") + "\n");
    expect(await again.verify()).toMatchObject({ ok: false, brokenAt: 2, reason: "sequence" });
    await writeFile(box.file, lines.slice(0, 2).join("\n") + "\n");
    expect(await again.verify()).toMatchObject({ ok: false, reason: "truncated" });
  });

  it("bounds pushed data", async () => {
    const t = await testApp();
    const box = new BlackBox(t.store.path);
    const r = await box.append("x", "event", { long: "a".repeat(10_000), deep: { a: { b: { c: { d: { e: 1 } } } } } });
    expect((r.data.long as string).length).toBe(500);
    expect(JSON.stringify(r.data)).not.toContain('"e":1');
  });
});

describe("routes: local chain, push, lockdown", () => {
  async function server(extra: { fetch?: typeof fetch; lockdownLimit?: RateLimit } = {}) {
    const t = await testApp((c) => {
      c.security.blackbox.mode = "local";
      return c;
    }, [securityRoutes({ startTimer: false, fetch: extra.fetch, lockdownLimit: extra.lockdownLimit })]);
    return t;
  }

  it("audit entries and notices go into the chain; sensitive notices don't; verify + recent", async () => {
    const t = await server();
    await t.app.inject({ method: "POST", url: "/v1/security/traps/test", headers: t.auth, payload: {} });
    await t.notifier.send({ key: "desktop.clipboard", params: { text: "secret clip" }, sensitive: true });
    await new Promise((r) => setTimeout(r, 50));
    const rec = (await t.app.inject({ method: "GET", url: "/v1/blackbox/recent?limit=10", headers: t.auth })).json().records;
    expect(rec.map((r: { kind: string; data: { key?: string; path?: string } }) => r.data.key ?? r.data.path)).toEqual(expect.arrayContaining(["security.trap", "/v1/security/traps/test"]));
    expect(JSON.stringify(rec)).not.toContain("secret clip");
    const v = (await t.app.inject({ method: "GET", url: "/v1/blackbox/verify", headers: t.auth })).json();
    expect(v).toMatchObject({ ok: true, anchorMismatch: [] });
    expect(v.count).toBeGreaterThanOrEqual(2);
  });

  it("append with a blackbox token: source is the token's name; other scopes and devices refused", async () => {
    const t = await server();
    const { token } = await createServiceToken(t.store, "argo", ["blackbox"]);
    const { token: other } = await createServiceToken(t.store, "x", ["research"]);
    const body = { entries: [{ at: "2026-11-19T10:00:00Z", kind: "audit", data: { method: "POST", path: "/v1/claude/sessions", source: "forged" } }] };
    let r = await t.app.inject({ method: "POST", url: "/v1/blackbox/append", headers: { authorization: `Bearer ${token}` }, payload: body });
    expect(r.json()).toMatchObject({ accepted: 1 });
    r = await t.app.inject({ method: "POST", url: "/v1/blackbox/append", headers: { authorization: `Bearer ${other}` }, payload: body });
    expect(r.statusCode).toBe(403);
    r = await t.app.inject({ method: "POST", url: "/v1/blackbox/append", headers: t.auth, payload: body });
    expect(r.statusCode).toBe(403);
    const rec = (await t.app.inject({ method: "GET", url: "/v1/blackbox/recent?limit=50", headers: t.auth })).json().records;
    const pushed = rec.find((x: { data: { path?: string } }) => x.data.path === "/v1/claude/sessions");
    expect(pushed.source).toBe("service:argo");
  });

  it("pusher: queues while unreachable (persisted), sends in order, the chain gets them", async () => {
    const t = await server();
    const { token } = await createServiceToken(t.store, "argo", ["blackbox"]);
    const pc = await testApp((c) => {
      c.security.blackbox = { mode: "push", url: "https://atlas.example:7443", token };
      return c;
    });
    let up = false;
    const f = (async (u: string, init: RequestInit) => {
      if (!up) throw new TypeError("fetch failed");
      const res = await t.app.inject({ method: "POST", url: new URL(u).pathname, headers: init.headers as Record<string, string>, payload: String(init.body) });
      return new Response(res.body, { status: res.statusCode });
    }) as unknown as typeof fetch;
    const p = new BlackBoxPusher({ store: pc.store, notifier: pc.notifier }, f);
    p.push("audit", { method: "POST", path: "/a" });
    p.push("event", { key: "b" });
    expect(await p.flush()).toBe(0);
    expect(p.lastError).toBe("unreachable");
    await new Promise((r) => setTimeout(r, 20));
    const p2 = new BlackBoxPusher({ store: pc.store, notifier: pc.notifier }, f);
    await p2.load();
    expect(p2.pending).toBe(2);
    expect((await stat(p2.file)).mode & 0o777).toBe(0o600);
    up = true;
    expect(await p2.flush()).toBe(2);
    expect(p2.pending).toBe(0);
    const rec = (await t.app.inject({ method: "GET", url: "/v1/blackbox/recent?limit=50", headers: t.auth })).json().records;
    expect(rec.filter((x: { source: string }) => x.source === "service:argo").map((x: { data: { path?: string; key?: string } }) => x.data.path ?? x.data.key)).toEqual(["b", "/a"]);
  });

  it("recovery code: shown once, hashed; lockdown with it fans out, then revokes everything here", async () => {
    const remoteCalls: Array<{ url: string; auth: string }> = [];
    const f = (async (u: string, init: RequestInit) => {
      remoteCalls.push({ url: String(u), auth: String((init.headers as Record<string, string>).authorization) });
      return new Response("{}", { status: String(u).includes("down.example") ? 502 : 200 });
    }) as unknown as typeof fetch;
    const t = await server({ fetch: f, lockdownLimit: new RateLimit(3, 3600_000) });
    let r = await t.app.inject({ method: "POST", url: "/v1/security/recovery", headers: t.auth, payload: { confirm: true } });
    const { code } = r.json();
    expect(normalizeCode(code)).toHaveLength(25);
    expect(JSON.stringify(t.store.get())).not.toContain(code);
    const lt = "tps_" + "L".repeat(40);
    await t.app.inject({ method: "POST", url: "/v1/security/lockdown/targets", headers: t.auth, payload: { id: "argo", name: "argo", url: "https://argo.example:7443", token: lt } });
    await t.app.inject({ method: "POST", url: "/v1/security/lockdown/targets", headers: t.auth, payload: { id: "down", name: "down", url: "https://down.example:7443", token: lt } });
    expect((await t.app.inject({ method: "GET", url: "/v1/security/lockdown/targets", headers: t.auth })).body).not.toContain(lt);
    // No token needed, but a wrong code is refused.
    r = await t.app.inject({ method: "POST", url: "/v1/security/lockdown", payload: { code: "AAAAA-AAAAA-AAAAA-AAAAA-AAAAA" } });
    expect(r.statusCode).toBe(401);
    expect(t.store.get().devices).toHaveLength(1);
    r = await t.app.inject({ method: "POST", url: "/v1/security/lockdown", payload: { code: code.toLowerCase() } });
    expect(r.statusCode).toBe(200);
    expect(r.json().targets.map((x: { name: string; ok: boolean }) => `${x.name}:${x.ok}`)).toEqual(["argo:true", "down:false"]);
    expect(remoteCalls.map((c) => c.url)).toEqual(["https://argo.example:7443/v1/security/lockdown/remote", "https://down.example:7443/v1/security/lockdown/remote"]);
    expect(remoteCalls[0]!.auth).toBe(`Bearer ${lt}`);
    expect(t.store.get().devices).toEqual([]);
    expect(t.store.get().serviceTokens).toEqual([]);
    expect(t.sent.some((n) => (n as { key: string }).key === "security.lockdown")).toBe(true);
    // The old phone token is now dead; the rate limit caps guessing (3 in this test, then 429).
    expect((await t.app.inject({ method: "GET", url: "/v1/security/overview", headers: t.auth })).statusCode).toBe(401);
    r = await t.app.inject({ method: "POST", url: "/v1/security/lockdown", payload: { code } });
    expect(r.statusCode).toBe(200); // repeating a lockdown is harmless
    r = await t.app.inject({ method: "POST", url: "/v1/security/lockdown", payload: { code } });
    expect(r.statusCode).toBe(429);
    const box = (await readFile(join(t.dir, "blackbox", "chain.jsonl"), "utf8")).split("\n").filter(Boolean).map((l) => JSON.parse(l));
    expect(box.some((x) => x.kind === "lockdown" && x.data.action === "lockdown")).toBe(true);
    expect(box.some((x) => x.data.action === "badRecoveryCode")).toBe(true);
    expect(JSON.stringify(box)).not.toContain(normalizeCode(code));
  });

  it("remote lockdown needs the lockdown scope", async () => {
    const t = await server();
    const { token } = await createServiceToken(t.store, "atlas", ["lockdown"]);
    const { token: bb } = await createServiceToken(t.store, "x", ["blackbox"]);
    expect((await t.app.inject({ method: "POST", url: "/v1/security/lockdown/remote", headers: { authorization: `Bearer ${bb}` }, payload: { confirm: true } })).statusCode).toBe(403);
    expect((await t.app.inject({ method: "POST", url: "/v1/security/lockdown/remote", headers: { authorization: `Bearer ${token}` }, payload: {} })).statusCode).toBe(400);
    expect((await t.app.inject({ method: "POST", url: "/v1/security/lockdown/remote", headers: { authorization: `Bearer ${token}` }, payload: { confirm: true } })).statusCode).toBe(200);
    expect(t.store.get().devices).toEqual([]);
  });

  it("scrypt helpers", async () => {
    const c = newRecoveryCode();
    expect(c).toMatch(/^([A-Z2-9]{5}-){4}[A-Z2-9]{5}$/);
    const salt = Buffer.alloc(16, 1);
    const stored = { salt: salt.toString("hex"), hash: (await hashCode(c, salt)).toString("hex") };
    expect(await codeMatches(c.replace(/-/g, " ").toLowerCase(), stored)).toBe(true);
    expect(await codeMatches(newRecoveryCode(), stored)).toBe(false);
  });

  it("blackbox settings: push needs url + token, token kept on same url", async () => {
    const t = await testApp((c) => c, [securityRoutes({ startTimer: false })]);
    const tok = "tps_" + "B".repeat(40);
    let r = await t.app.inject({ method: "PUT", url: "/v1/blackbox/settings", headers: t.auth, payload: { mode: "push", url: "https://atlas.example:7443" } });
    expect(r.json().error.code).toBe("agent.security.tokenRequired");
    r = await t.app.inject({ method: "PUT", url: "/v1/blackbox/settings", headers: t.auth, payload: { mode: "push", url: "https://atlas.example:7443", token: tok } });
    expect(r.json()).toMatchObject({ mode: "push", hasToken: true, restartRequired: true });
    expect(r.body).not.toContain(tok);
    await t.app.inject({ method: "PUT", url: "/v1/blackbox/settings", headers: t.auth, payload: { mode: "push" } });
    expect(t.store.get().security.blackbox.token).toBe(tok);
    await appendFile(join(t.dir, "x"), "");
  });
});
