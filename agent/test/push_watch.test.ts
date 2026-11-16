import { createECDH, randomBytes } from "node:crypto";
import { createServer } from "node:http";
import type { AddressInfo } from "node:net";
// We decrypt with http_ece, a dependency of web-push, the same way the phone would.
// @ts-expect-error no type definitions
import ece from "http_ece";
import { describe, expect, it } from "vitest";
import type { Notifier } from "../src/notify.ts";
import { Watcher } from "../src/watch.ts";
import { testApp } from "./helpers.ts";

function receiver() {
  const got: Array<{ headers: Record<string, unknown>; body: Buffer }> = [];
  const srv = createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on("data", (c) => chunks.push(c));
    req.on("end", () => {
      got.push({ headers: req.headers, body: Buffer.concat(chunks) });
      res.writeHead(201).end();
    });
  });
  return new Promise<{ url: string; got: typeof got; close: () => void }>((r) =>
    srv.listen(0, "127.0.0.1", () => r({ url: `http://127.0.0.1:${(srv.address() as AddressInfo).port}/upABC`, got, close: () => srv.close() })),
  );
}

describe("bildirimler", () => {
  it("WebPush (aes128gcm) ile şifreler; telefon anahtarıyla çözülür; ntfy token'ı eklenir", async () => {
    const rx = await receiver();
    const phone = createECDH("prime256v1");
    phone.generateKeys();
    const auth = randomBytes(16);
    const { app, auth: h, store } = await testApp((c) => ({ ...c, push: { endpoints: [], token: "tk_ntfy" } }));
    await app.inject({
      method: "PUT",
      url: "/v1/push/endpoint",
      headers: h,
      payload: { url: rx.url, pubKey: phone.getPublicKey().toString("base64url"), auth: auth.toString("base64url") },
    });
    expect(store.get().push.endpoints[0]).toMatchObject({ deviceId: "phone", url: rx.url });
    const res = await app.inject({ method: "POST", url: "/v1/push/test", headers: h });
    expect(res.json()).toEqual({ sent: 1 });
    const msg = rx.got[0]!;
    expect(msg.headers["content-encoding"]).toBe("aes128gcm");
    expect(msg.headers.authorization).toBe("Bearer tk_ntfy");
    expect(msg.body.toString("utf8")).not.toContain("push.test");
    const clear = ece.decrypt(msg.body, { version: "aes128gcm", privateKey: phone, authSecret: auth.toString("base64url") }) as Buffer;
    const json = JSON.parse(clear.toString("utf8"));
    expect(json).toMatchObject({ v: 1, key: "push.test", params: { device: "Telefon" } });
    rx.close();
  });

  it("anahtarsız uç noktaya düz JSON gönderir", async () => {
    const rx = await receiver();
    const { app, auth: h } = await testApp();
    await app.inject({ method: "PUT", url: "/v1/push/endpoint", headers: h, payload: { url: rx.url } });
    await app.inject({ method: "POST", url: "/v1/push/test", headers: h });
    expect(JSON.parse(rx.got[0]!.body.toString()).key).toBe("push.test");
    rx.close();
  });

  it("geçersiz anahtar biçimini reddeder", async () => {
    const { app, auth: h } = await testApp();
    const r = await app.inject({ method: "PUT", url: "/v1/push/endpoint", headers: h, payload: { url: "https://x/up", pubKey: "kısa!", auth: "x" } });
    expect(r.statusCode).toBe(400);
  });
});

describe("host izleme", () => {
  it("süre dolunca bir kez 'offline', geri gelince 'online' bildirir", async () => {
    const t = await testApp((c) => ({
      ...c,
      watch: { hosts: [{ hostId: "argo", url: "https://argo/v1/health", intervalSeconds: 60, offlineAfterSeconds: 180 }] },
    }));
    let up = true;
    const fakeFetch = (async () => (up ? new Response("{}", { status: 200 }) : Promise.reject(new Error("down")))) as unknown as typeof fetch;
    const notifier = { send: async (n: unknown) => (t.sent.push(n), 1) } as unknown as Notifier;
    const w = new Watcher({ store: t.store, notifier }, fakeFetch);
    w.start(false);
    const t0 = 1_000_000;
    await w.check("argo", t0);
    up = false;
    await w.check("argo", t0 + 60_000);
    await w.check("argo", t0 + 120_000);
    expect(t.sent).toEqual([]);
    await w.check("argo", t0 + 181_000);
    await w.check("argo", t0 + 240_000);
    expect(t.sent).toEqual([expect.objectContaining({ key: "host.offline", params: { host: "argo", minutes: 3 } })]);
    up = true;
    await w.check("argo", t0 + 300_000);
    expect(t.sent.at(-1)).toMatchObject({ key: "host.online" });
    expect(t.sent).toHaveLength(2);
  });
});
