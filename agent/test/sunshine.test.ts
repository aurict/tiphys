// 10.2 Phase B: Sunshine status (installed/running/config), start/stop, Moonlight PIN pairing (request format,
// Basic auth, error mapping), auth/session, password masking and loopback TLS pinning.
// All with a fake runner/HTTP; the only real network test is a local (127.0.0.1) self-signed HTTPS server.
import { execFile } from "node:child_process";
import { X509Certificate } from "node:crypto";
import { mkdtemp, readFile } from "node:fs/promises";
import { createServer } from "node:https";
import { createServer as netServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { RateLimit, type Indicator } from "../src/control.ts";
import { hyprRoutes, type HyprIo } from "../src/routes/hypr.ts";
import { isLoopbackHost, listeningPorts, parseSunshineConf, sunshineRoutes, tlsHttp, type HttpResult, type SunshineIo } from "../src/routes/sunshine.ts";
import { testApp } from "./helpers.ts";

const UNIT = "app-dev.lizardbyte.app.Sunshine.service";
const PAIRING = "0123456789abcdef0123456789abcdef";
const SS = [
  "LISTEN 0      4096       0.0.0.0:47984      0.0.0.0:*",
  "LISTEN 0      4096       0.0.0.0:47989      0.0.0.0:*",
  "LISTEN 0      4096       127.0.0.1:47990    0.0.0.0:*",
  "LISTEN 0      4096       0.0.0.0:48010      0.0.0.0:*",
  "LISTEN 0      511        127.0.0.1:7443     0.0.0.0:*",
].join("\n");

interface FakeOpts {
  installed?: boolean;
  running?: boolean;
  conf?: string | null;
  http?: (url: URL, method: string, body: unknown) => HttpResult;
}

function fakeIo(o: FakeOpts = {}) {
  const installed = o.installed ?? true;
  let running = o.running ?? true;
  const execs: string[] = [];
  const http: Array<{ url: string; method: string; auth: string; body: unknown }> = [];
  const ok = (stdout: string, code = 0) => ({ stdout, stderr: "", code });
  const io: SunshineIo = {
    configDir: "/fake/.config/sunshine",
    hostName: "argo",
    exec: async (cmd, args) => {
      execs.push([cmd, ...args].join(" "));
      if (cmd === "systemctl") {
        const verb = args[2];
        const unit = args.at(-1);
        if (verb === "show") {
          if (!installed || unit !== UNIT) return ok("LoadState=not-found\nActiveState=inactive\nUnitFileState=\n");
          return ok(`LoadState=loaded\nActiveState=${running ? "active" : "inactive"}\nUnitFileState=enabled\n`);
        }
        if (verb === "start" || verb === "stop") {
          running = verb === "start";
          return ok("");
        }
      }
      if (cmd === "ss") return ok(running ? SS : "");
      if (cmd === "dpkg-query") return installed ? ok("2026.914.233613-1+debiantrixie") : ok("", 1);
      return ok("", 1);
    },
    has: async (cmd) => cmd === "sunshine" && installed,
    readText: async (p) => {
      if (p.endsWith("sunshine.conf")) return o.conf === undefined ? "# yorum\ncapture = wlr\nencoder=nvenc\n" : o.conf;
      if (p === "/fake/.config/sunshine/sunshine_state.json") return JSON.stringify({ root: { uniqueid: "7A3D5D8C-1F2B-4C3D-9E8F-0123456789AB", named_devices: [] }, username: "sunny", password: "özet", salt: "tuz" });
      return null;
    },
    http: async (url, opts) => {
      http.push({ url: url.toString(), method: opts.method, auth: Buffer.from(`${opts.auth.username}:${opts.auth.password}`).toString("base64"), body: opts.body });
      const h = o.http ?? defaultHttp;
      return h(url, opts.method, opts.body);
    },
  };
  return { io, execs, http, isRunning: () => running };
}

const res = (status: number, body: unknown = {}, location?: string): HttpResult => ({ status, body: typeof body === "string" ? body : JSON.stringify(body), location });

function defaultHttp(url: URL, method: string): HttpResult {
  if (url.pathname === "/api/clients/list") return res(200, { named_certs: [{ name: "Pixel", uuid: "u", enabled: true }], status: true });
  if (url.pathname === "/api/pin" && method === "GET") return res(200, { pairings: [{ id: PAIRING, name: "Pixel 8", address: "100.64.0.5" }] });
  if (url.pathname === "/api/pin" && method === "POST") return res(200, { status: true });
  return res(404);
}

const fakeHyprIo: HyprIo = {
  exec: async () => ({ stdout: "{}", stderr: "", code: 0 }),
  bytes: async () => ({ out: Buffer.alloc(0), code: 1, err: "" }),
  has: async () => false,
  hyprEnv: async () => ({}),
  screenEnv: async () => ({}),
};
const indicator: Indicator = { on: async () => {}, off: async () => {} };

async function sunApp(f: ReturnType<typeof fakeIo>, o: { control?: boolean; creds?: boolean; limit?: RateLimit } = {}) {
  const t = await testApp(
    (c) => {
      c.features.control = o.control ?? true;
      if (o.creds ?? true) c.sunshine = { url: "https://127.0.0.1:47990", username: "sunny", password: "gizli-sifre" };
      return c;
    },
    [
      (a, ctx) => hyprRoutes(a, ctx, fakeHyprIo, { indicator }),
      (a, ctx) => sunshineRoutes(a, ctx, f.io, { limit: o.limit }),
    ],
  );
  const session = async () => {
    const r = await t.app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: t.auth, payload: {} });
    return { ...t.auth, "x-tiphys-control": r.json().token as string };
  };
  return { ...t, session };
}

describe("Sunshine ayrıştırma", () => {
  it("sunshine.conf, ss portları, loopback", () => {
    expect(parseSunshineConf("# capture = kms\ncapture = wlr\n encoder=nvenc \nbozuk\n")).toEqual({ capture: "wlr", encoder: "nvenc" });
    expect(listeningPorts(SS)).toEqual([47984, 47989, 47990, 48010]);
    expect(listeningPorts("LISTEN 0 4096 [::]:47990 [::]:*\nLISTEN 0 1 0.0.0.0:22 0.0.0.0:*")).toEqual([47990]);
    expect(listeningPorts("")).toEqual([]);
    for (const h of ["127.0.0.1", "127.1.2.3", "localhost", "[::1]", "::1"]) expect(isLoopbackHost(h)).toBe(true);
    for (const h of ["100.64.0.2", "argo.example.ts.net", "1127.0.0.1", "[::2]"]) expect(isLoopbackHost(h)).toBe(false);
  });
});

describe("GET /v1/desktop/sunshine", () => {
  it("kurulu + çalışıyor: sürüm, birim, portlar, yakalama, eşleşmiş istemci", async () => {
    const f = fakeIo();
    const { app, auth } = await sunApp(f);
    const r = await app.inject({ method: "GET", url: "/v1/desktop/sunshine", headers: auth });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({
      installed: true,
      version: "2026.914.233613-1+debiantrixie",
      unit: UNIT,
      running: true,
      enabled: true,
      ports: [47984, 47989, 47990, 48010],
      capture: "wlr",
      encoder: "nvenc",
      credentials: true,
      api: "ok",
      pairedClients: 1,
      pendingPairings: 1,
      uniqueId: "7A3D5D8C-1F2B-4C3D-9E8F-0123456789AB",
      hostName: "argo",
    });
    expect(r.body).not.toMatch(/özet|tuz|gizli-sifre/); // only the ID from the state file
    // Reading the status needs no session; it goes to the API with Basic auth.
    expect(f.http[0]).toMatchObject({ url: "https://127.0.0.1:47990/api/clients/list", method: "GET", auth: Buffer.from("sunny:gizli-sifre").toString("base64") });
    expect(f.execs).toContain(`systemctl --user --no-ask-password show -p LoadState,ActiveState,UnitFileState -- ${UNIT}`);
    await app.close();
  });

  it("kurulu değil; kurulu ama durmuş (API'ye gidilmez); kimlik bilgisi yok; yanlış kimlik; ilk kurulum", async () => {
    const none = fakeIo({ installed: false, running: false, conf: null });
    let t = await sunApp(none);
    expect((await t.app.inject({ method: "GET", url: "/v1/desktop/sunshine", headers: t.auth })).json()).toMatchObject({
      installed: false, version: null, unit: null, running: false, ports: [], capture: null, api: "stopped", uniqueId: null,
    });
    await t.app.close();

    const stopped = fakeIo({ running: false });
    t = await sunApp(stopped);
    expect((await t.app.inject({ method: "GET", url: "/v1/desktop/sunshine", headers: t.auth })).json()).toMatchObject({ installed: true, running: false, api: "stopped", capture: "wlr" });
    expect(stopped.http).toEqual([]);
    await t.app.close();

    t = await sunApp(fakeIo(), { creds: false });
    expect((await t.app.inject({ method: "GET", url: "/v1/desktop/sunshine", headers: t.auth })).json()).toMatchObject({ running: true, credentials: false, api: "noCredentials", pairedClients: null });
    await t.app.close();

    t = await sunApp(fakeIo({ http: () => res(401, { status: false, error: "Unauthorized" }) }));
    expect((await t.app.inject({ method: "GET", url: "/v1/desktop/sunshine", headers: t.auth })).json()).toMatchObject({ api: "unauthorized", pairedClients: null });
    await t.app.close();

    t = await sunApp(fakeIo({ http: () => res(307, "", "/welcome") }));
    expect((await t.app.inject({ method: "GET", url: "/v1/desktop/sunshine", headers: t.auth })).json()).toMatchObject({ api: "setupRequired" });
    await t.app.close();

    t = await sunApp(fakeIo({ http: () => { throw new Error("ECONNREFUSED"); } }));
    expect((await t.app.inject({ method: "GET", url: "/v1/desktop/sunshine", headers: t.auth })).json()).toMatchObject({ api: "unreachable" });
    await t.app.close();
  });

  it("desktop kapalıyken uç yok", async () => {
    const plain = await testApp();
    expect((await plain.app.inject({ method: "GET", url: "/v1/desktop/sunshine", headers: plain.auth })).statusCode).toBe(404);
    await plain.app.close();
  });
});

describe("başlat / durdur / eşleştir", () => {
  it("control + oturum ister; başlat/durdur systemctl --user", async () => {
    const f = fakeIo({ running: false });
    const { app, auth, session } = await sunApp(f);
    for (const a of ["start", "stop", "pair"]) {
      const r = await app.inject({ method: "POST", url: `/v1/desktop/sunshine/${a}`, headers: auth, payload: { pin: "1234" } });
      expect(r.statusCode).toBe(403);
      expect(r.json().error.code).toBe("agent.control.sessionRequired");
    }
    expect(f.http.filter((h) => h.method === "POST")).toEqual([]);
    const h = await session();
    const start = await app.inject({ method: "POST", url: "/v1/desktop/sunshine/start", headers: h });
    expect(start.statusCode).toBe(200);
    expect(start.json().running).toBe(true);
    expect(f.execs).toContain(`systemctl --user --no-ask-password start -- ${UNIT}`);
    expect((await app.inject({ method: "POST", url: "/v1/desktop/sunshine/stop", headers: h })).json().running).toBe(false);
    expect((await app.inject({ method: "POST", url: "/v1/desktop/sunshine/restart", headers: h })).statusCode).toBe(400);
    await app.close();

    const off = await sunApp(fakeIo(), { control: false });
    const r = await off.app.inject({ method: "POST", url: "/v1/desktop/sunshine/start", headers: off.auth });
    expect(r.json().error.code).toBe("agent.control.disabled");
    await off.app.close();

    const missing = await sunApp(fakeIo({ installed: false }));
    const r2 = await missing.app.inject({ method: "POST", url: "/v1/desktop/sunshine/start", headers: await missing.session() });
    expect(r2.statusCode).toBe(404);
    expect(r2.json().error.code).toBe("agent.sunshine.notInstalled");
    await missing.app.close();
  });

  it("eşleştirme: bekleyen pairing_id + PIN + ad, Basic auth; PIN yanıtta/hatada geçmez", async () => {
    const f = fakeIo();
    const { app, session } = await sunApp(f);
    const h = await session();
    const r = await app.inject({ method: "POST", url: "/v1/desktop/sunshine/pair", headers: h, payload: { pin: "4821", name: "Tiphys telefon" } });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ paired: true, client: "Pixel 8" });
    const post = f.http.find((x) => x.method === "POST")!;
    expect(post).toEqual({ url: "https://127.0.0.1:47990/api/pin", method: "POST", auth: Buffer.from("sunny:gizli-sifre").toString("base64"), body: { pairing_id: PAIRING, pin: "4821", name: "Tiphys telefon" } });
    // Device name if no name is given.
    await app.inject({ method: "POST", url: "/v1/desktop/sunshine/pair", headers: h, payload: { pin: "1111" } });
    expect(f.http.filter((x) => x.method === "POST").at(-1)!.body).toMatchObject({ name: "Telefon" });
    // Invalid PIN: no request is sent, the error does not contain the PIN.
    for (const pin of ["12345", "12a4", ""]) {
      const bad = await app.inject({ method: "POST", url: "/v1/desktop/sunshine/pair", headers: h, payload: { pin } });
      expect(bad.statusCode).toBe(400);
      expect(bad.json().error.code).toBe("agent.sunshine.badPin");
      if (pin) expect(bad.body).not.toContain(pin);
    }
    expect(f.http.filter((x) => x.method === "POST")).toHaveLength(2);
    await app.close();
  });

  it("eşleştirme hata eşlemesi: yanlış kimlik 409, yanlış PIN, bekleyen yok, ilk kurulum, eski Sunshine, kimlik yok", async () => {
    const cases: Array<[FakeOpts["http"], number, string]> = [
      [() => res(401, { status: false, error: "Unauthorized" }), 409, "agent.sunshine.unauthorized"],
      [(u, m) => (m === "GET" ? res(200, { pairings: [{ id: PAIRING, name: "P", address: "x" }] }) : res(200, { status: false })), 400, "agent.sunshine.pairFailed"],
      [() => res(200, { pairings: [] }), 409, "agent.sunshine.noPendingPairing"],
      [() => res(307, "", "/welcome"), 409, "agent.sunshine.setupRequired"],
      [(u, m) => (m === "GET" ? res(200, { pairings: [{ id: PAIRING }] }) : res(400, { status: false, error: "PIN must contain exactly 4 numeric digits" })), 400, "agent.sunshine.badRequest"],
      [() => res(500), 502, "agent.sunshine.apiFailed"],
    ];
    for (const [http, status, code] of cases) {
      const f = fakeIo({ http });
      const { app, session } = await sunApp(f);
      const r = await app.inject({ method: "POST", url: "/v1/desktop/sunshine/pair", headers: await session(), payload: { pin: "4821" } });
      expect([r.statusCode, r.json().error.code]).toEqual([status, code]);
      expect(r.body).not.toContain("4821");
      expect(r.body).not.toContain("gizli-sifre");
      await app.close();
    }

    // Old Sunshine: no GET /api/pin (404) → {pin, name}.
    const old = fakeIo({ http: (u, m) => (m === "GET" ? res(404) : res(200, { status: true })) });
    let t = await sunApp(old);
    expect((await t.app.inject({ method: "POST", url: "/v1/desktop/sunshine/pair", headers: await t.session(), payload: { pin: "4821" } })).json()).toEqual({ paired: true, client: null });
    expect(old.http.at(-1)!.body).toEqual({ pin: "4821", name: "Telefon" });
    await t.app.close();

    const nocreds = fakeIo();
    t = await sunApp(nocreds, { creds: false });
    const r = await t.app.inject({ method: "POST", url: "/v1/desktop/sunshine/pair", headers: await t.session(), payload: { pin: "4821" } });
    expect([r.statusCode, r.json().error.code]).toEqual([409, "agent.sunshine.noCredentials"]);
    expect(nocreds.http).toEqual([]);
    await t.app.close();
  });

  it("hız sınırı (PIN denemeleri)", async () => {
    const { app, session } = await sunApp(fakeIo(), { limit: new RateLimit(2, 60_000) });
    const h = await session();
    const codes = [];
    for (let i = 0; i < 3; i++) codes.push((await app.inject({ method: "POST", url: "/v1/desktop/sunshine/pair", headers: h, payload: { pin: "0000" } })).statusCode);
    expect(codes).toEqual([200, 200, 429]);
    await app.close();
  });
});

describe("ayar: sunshine kimlik bilgisi", () => {
  it("PATCH ile yazılır, GET şifreyi asla döndürmez, şifresiz PATCH eskisini korur", async () => {
    const { app, auth, store } = await testApp();
    expect((await app.inject({ method: "GET", url: "/v1/config", headers: auth })).json().sunshine).toBeNull();
    // Password is required on first save.
    const first = await app.inject({ method: "PATCH", url: "/v1/config", headers: auth, payload: { sunshine: { username: "sunny" } } });
    expect(first.json().error.code).toBe("agent.config.passwordRequired");
    const p = await app.inject({ method: "PATCH", url: "/v1/config", headers: auth, payload: { sunshine: { username: "sunny", password: "gizli-sifre" } } });
    expect(p.statusCode).toBe(200);
    expect(p.body).not.toContain("gizli-sifre");
    expect(p.json().config.sunshine).toEqual({ url: "https://127.0.0.1:47990", username: "sunny", hasPassword: true });
    const g = await app.inject({ method: "GET", url: "/v1/config", headers: auth });
    expect(g.body).not.toContain("gizli-sifre");
    await app.inject({ method: "PATCH", url: "/v1/config", headers: auth, payload: { sunshine: { username: "yeni" } } });
    expect(store.get().sunshine).toEqual({ url: "https://127.0.0.1:47990", username: "yeni", password: "gizli-sifre" });
    // If the address changes, the stored password is not carried over to the new address: it is asked again.
    const moved = await app.inject({ method: "PATCH", url: "/v1/config", headers: auth, payload: { sunshine: { url: "https://kotu.example:47990", username: "yeni" } } });
    expect(moved.json().error.code).toBe("agent.config.passwordRequired");
    expect(store.get().sunshine?.url).toBe("https://127.0.0.1:47990");
    // An http address is rejected (so Basic auth doesn't go out in plain text).
    expect((await app.inject({ method: "PATCH", url: "/v1/config", headers: auth, payload: { sunshine: { url: "http://127.0.0.1:47990", username: "x", password: "y" } } })).statusCode).toBe(400);
    await app.inject({ method: "PATCH", url: "/v1/config", headers: auth, payload: { sunshine: null } });
    expect(store.get().sunshine).toBeNull();
    await app.close();
  });
});

// Real TLS: self-signed server on 127.0.0.1. Skipped if openssl is missing.
const openssl = await new Promise<boolean>((r) => execFile("openssl", ["version"], (e) => r(!e)));
describe.skipIf(!openssl)("loopback TLS sabitlemesi", () => {
  async function selfSigned(dir: string, name: string) {
    const key = join(dir, `${name}.key`);
    const cert = join(dir, `${name}.pem`);
    await new Promise<void>((ok, fail) =>
      execFile("openssl", ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert, "-days", "1", "-subj", "/CN=Sunshine Gamestream Host"], (e) => (e ? fail(e) : ok())),
    );
    return { key: await readFile(key), cert: await readFile(cert) };
  }

  it("parmak izi eşleşirse istek gider; eşleşmezse Authorization hiç gönderilmeden kesilir", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-sun-"));
    const real = await selfSigned(dir, "a");
    const other = await selfSigned(dir, "b");
    const seen: string[] = [];
    const server = createServer({ key: real.key, cert: real.cert }, (req, r) => {
      seen.push(String(req.headers.authorization));
      r.writeHead(200, { "content-type": "application/json" }).end(JSON.stringify({ status: true }));
    });
    await new Promise<void>((ok) => server.listen(0, "127.0.0.1", ok));
    const port = (server.address() as { port: number }).port;
    const url = new URL(`https://127.0.0.1:${port}/api/clients/list`);
    const auth = { username: "u", password: "p" };
    try {
      const good = tlsHttp(dir, async () => new X509Certificate(real.cert).fingerprint256);
      expect(await good(url, { method: "GET", auth, timeoutMs: 5000 })).toMatchObject({ status: 200 });
      expect(seen).toEqual([`Basic ${Buffer.from("u:p").toString("base64")}`]);

      const bad = tlsHttp(dir, async () => new X509Certificate(other.cert).fingerprint256);
      await expect(bad(url, { method: "GET", auth, timeoutMs: 5000 })).rejects.toMatchObject({ code: "agent.sunshine.certMismatch" });
      expect(seen).toHaveLength(1);

      // Accepted on loopback if there is no certificate file (loopback only).
      const unpinned = tlsHttp(dir, async () => null);
      expect(await unpinned(url, { method: "POST", auth, body: { a: 1 }, timeoutMs: 5000 })).toMatchObject({ status: 200 });
    } finally {
      server.close();
    }
  });

  it("TLS el sıkışması hiç bitmezse istek süre sınırında düşer", async () => {
    const sockets: import("node:net").Socket[] = [];
    const silent = netServer((s) => void sockets.push(s)); // accepts the connection, never responds
    await new Promise<void>((ok) => silent.listen(0, "127.0.0.1", ok));
    const port = (silent.address() as { port: number }).port;
    try {
      const http = tlsHttp(await mkdtemp(join(tmpdir(), "tiphys-sun-")), async () => null);
      const t0 = Date.now();
      await expect(http(new URL(`https://127.0.0.1:${port}/api/pin`), { method: "GET", auth: { username: "u", password: "p" }, timeoutMs: 200 })).rejects.toMatchObject({ code: "agent.sunshine.timeout" });
      expect(Date.now() - t0).toBeLessThan(3000);
    } finally {
      for (const s of sockets) s.destroy();
      silent.close();
    }
  });
});
