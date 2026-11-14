// Gerçek makinede çalışan testler (pano, ekran görüntüsü, portlar, ses). TIPHYS_REAL=1 ile çalışır.
import { describe, expect, it } from "vitest";
import { testApp } from "./helpers.ts";

const real = process.env.TIPHYS_REAL === "1";

describe.skipIf(!real)("gerçek masaüstü", () => {
  it("pano yaz/oku, ekran görüntüsü, port listesi", async () => {
    const { app, auth } = await testApp((c) => {
      c.features.desktop = true;
      c.features.ports = true;
      return c;
    });
    const before = (await app.inject({ method: "GET", url: "/v1/desktop/clipboard", headers: auth })).json();
    const marker = `tiphys-test ${Date.now()} ğüşiöç`;
    const put = await app.inject({ method: "PUT", url: "/v1/desktop/clipboard", headers: auth, payload: { text: marker } });
    expect(put.json()).toEqual({ ok: true });
    expect((await app.inject({ method: "GET", url: "/v1/desktop/clipboard", headers: auth })).json().text).toBe(marker);
    // Kullanıcının panosu geri yüklenir.
    await app.inject({ method: "PUT", url: "/v1/desktop/clipboard", headers: auth, payload: { text: before.text ?? "" } });

    const shot = await app.inject({ method: "GET", url: "/v1/desktop/screenshot?scale=0.25", headers: auth });
    expect(shot.statusCode).toBe(200);
    expect(shot.headers["content-type"]).toBe("image/png");
    expect(shot.rawPayload.subarray(1, 4).toString()).toBe("PNG");

    const ports = (await app.inject({ method: "GET", url: "/v1/ports", headers: auth })).json();
    expect(ports.host).toMatch(/\.ts\.net$/);
    expect(ports.ports.length).toBeGreaterThan(0);
    await app.close();
  }, 60000);
});

describe.skipIf(!real)("gerçek ses yazıya çevirme", () => {
  it("m4a yüklenir, transcribe betiği çalışır, metin döner", async () => {
    const { execFileSync } = await import("node:child_process");
    const { mkdtemp, readFile } = await import("node:fs/promises");
    const { tmpdir } = await import("node:os");
    const { join } = await import("node:path");
    const dir = await mkdtemp(join(tmpdir(), "tiphys-ses-"));
    const file = join(dir, "ton.m4a");
    // Konuşma yok (TTS aracı kurulu değil): yalnızca uçtan uca yolu doğrular.
    execFileSync("ffmpeg", ["-loglevel", "error", "-f", "lavfi", "-i", "sine=frequency=440:duration=3", "-ac", "1", "-ar", "16000", "-c:a", "aac", file]);
    const { app, auth } = await testApp((c) => {
      c.features.transcribe = true;
      return c;
    });
    const res = await app.inject({ method: "POST", url: "/v1/transcribe", headers: auth, payload: { data: (await readFile(file)).toString("base64"), ext: "m4a", language: "tr" } });
    expect(res.statusCode, res.body).toBe(200);
    expect(typeof res.json().text).toBe("string");
    await app.close();
  }, 600_000);
});
