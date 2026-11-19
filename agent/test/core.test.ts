import { readFile, stat } from "node:fs/promises";
import { describe, expect, it } from "vitest";
import { profileSchema } from "../src/profile/schema.ts";
import { parseServices } from "../src/routes/homepage.ts";
import { parseUnits } from "../src/routes/services.ts";
import { magicPacket } from "../src/routes/wake.ts";
import { testApp } from "./helpers.ts";

describe("kimlik doğrulama", () => {
  it("health token istemez", async () => {
    const { app } = await testApp();
    const res = await app.inject({ url: "/v1/health" });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ name: "test", version: "0.3.0" });
  });

  it("token'sız isteği kodla reddeder", async () => {
    const { app } = await testApp();
    const res = await app.inject({ url: "/v1/config" });
    expect(res.statusCode).toBe(401);
    expect(res.json()).toEqual({ error: { code: "agent.auth.missingToken", params: {} } });
  });

  it("yanlış token'ı reddeder", async () => {
    const { app } = await testApp();
    const res = await app.inject({ url: "/v1/config", headers: { authorization: "Bearer tph_yanlis" } });
    expect(res.statusCode).toBe(401);
    expect(res.json().error.code).toBe("agent.auth.invalidToken");
  });

  it("Tailscale kullanıcısı zorunluysa başlığı kontrol eder", async () => {
    const { app, auth } = await testApp((c) => ({ ...c, requireTailscaleLogin: "sahip@ornek.com" }));
    const no = await app.inject({ url: "/v1/config", headers: auth });
    expect(no.json().error.code).toBe("agent.auth.tailnetUserNotAllowed");
    const yes = await app.inject({ url: "/v1/config", headers: { ...auth, "tailscale-user-login": "sahip@ornek.com" } });
    expect(yes.statusCode).toBe(200);
  });

  it("bilinmeyen yol kod döner", async () => {
    const { app, auth } = await testApp();
    const res = await app.inject({ url: "/v1/yok", headers: auth });
    expect(res.statusCode).toBe(404);
    expect(res.json().error.code).toBe("agent.route.notFound");
  });
});

describe("ayarlar", () => {
  it("gizli bilgileri geri göndermez", async () => {
    const { app, auth } = await testApp((c) => ({
      ...c,
      push: { endpoints: [], token: "tk_gizli" },
      uptimeKuma: { url: "https://uk.example", username: "owner", password: "cokgizli" },
    }));
    const body = (await app.inject({ url: "/v1/config", headers: auth })).body;
    expect(body).not.toContain("tk_gizli");
    expect(body).not.toContain("cokgizli");
    expect(body).not.toContain("tokenHash");
    expect(JSON.parse(body).uptimeKuma).toEqual({ url: "https://uk.example", username: "owner", hasPassword: true });
  });

  it("PATCH şifreyi boş bırakınca eskisini korur ve dosyayı 600 izinle yazar", async () => {
    const { app, auth, store } = await testApp((c) => ({
      ...c,
      uptimeKuma: { url: "https://uk.example", username: "owner", password: "eski" },
    }));
    const res = await app.inject({
      method: "PATCH",
      url: "/v1/config",
      headers: auth,
      payload: { uptimeKuma: { url: "https://uk.example", username: "sahip" }, allowedRoots: ["~/Desktop"] },
    });
    expect(res.statusCode).toBe(200);
    expect(store.get().uptimeKuma).toEqual({ url: "https://uk.example", username: "sahip", password: "eski" });
    // When the address changes, the stored password isn't sent to the new address: it is asked for again.
    const moved = await app.inject({ method: "PATCH", url: "/v1/config", headers: auth, payload: { uptimeKuma: { url: "https://uk2.example", username: "owner" } } });
    expect(moved.json().error.code).toBe("agent.config.passwordRequired");
    expect(store.get().allowedRoots).toEqual(["~/Desktop"]);
    expect((await stat(store.path)).mode & 0o777).toBe(0o600);
  });

  it("geçersiz PATCH alanını reddeder", async () => {
    const { app, auth } = await testApp();
    const res = await app.inject({ method: "PATCH", url: "/v1/config", headers: auth, payload: { devices: [] } });
    expect(res.statusCode).toBe(400);
    expect(res.json().error.code).toBe("agent.request.invalid");
  });

  it("revoke-all onay ister ve tüm cihazları siler", async () => {
    const { app, auth, store } = await testApp();
    expect((await app.inject({ method: "POST", url: "/v1/devices/revoke-all", headers: auth, payload: {} })).statusCode).toBe(400);
    const ok = await app.inject({ method: "POST", url: "/v1/devices/revoke-all", headers: auth, payload: { confirm: true } });
    expect(ok.statusCode).toBe(200);
    expect(store.get().devices).toEqual([]);
    expect((await app.inject({ url: "/v1/config", headers: auth })).statusCode).toBe(401);
  });

  it("push uç noktasını cihaza bağlar", async () => {
    const { app, auth, store } = await testApp();
    await app.inject({ method: "PUT", url: "/v1/push/endpoint", headers: auth, payload: { url: "https://ntfy.example/upABC" } });
    expect(store.get().push.endpoints).toEqual([{ deviceId: "phone", url: "https://ntfy.example/upABC" }]);
  });
});

describe("güç", () => {
  it("onaysız isteği çalıştırmaz", async () => {
    const { app, auth } = await testApp();
    const res = await app.inject({ method: "POST", url: "/v1/power/reboot", headers: auth, payload: {} });
    expect(res.statusCode).toBe(400);
    expect(res.json().error.code).toBe("agent.power.confirmRequired");
  });
  it("bilinmeyen eylemi reddeder", async () => {
    const { app, auth } = await testApp();
    const res = await app.inject({ method: "POST", url: "/v1/power/explode", headers: auth, payload: { confirm: true } });
    expect(res.statusCode).toBe(400);
  });
});

describe("ayrıştırıcılar", () => {
  it("Homepage services.yaml gruplarını ve alt gruplarını okur", () => {
    const groups = parseServices(`
- Sunucu:
  - İşlemci:
      widget: { type: glances }
  - Araçlar:
    - Console:
        href: https://x:8000
        description: 4× Android
        siteMonitor: https://x:8000/healthz
- PC:
  - Gitea:
      href: http://pc:3000
      icon: gitea.png
`);
    expect(groups.map((g) => g.name)).toEqual(["Sunucu", "PC"]);
    expect(groups[0]!.services).toEqual([]);
    expect(groups[0]!.groups[0]).toMatchObject({ name: "Araçlar", services: [{ name: "Console", monitorUrl: "https://x:8000/healthz" }] });
    expect(groups[1]!.services[0]).toMatchObject({ name: "Gitea", icon: "gitea.png", monitorUrl: null });
  });

  it("gerçek Homepage dosyasını hatasız okur", async () => {
    const text = await readFile(`${process.env.HOME}/homepage/homepage/services.yaml`, "utf8").catch(() => null);
    if (text === null) return; // skip if the file is missing (on another machine)
    const groups = parseServices(text);
    expect(groups.length).toBeGreaterThan(1);
  });

  it("systemctl JSON çıktısından sadece servisleri alır", () => {
    const units = parseUnits(
      JSON.stringify([
        { unit: "a.service", load: "loaded", active: "active", sub: "running", description: "A" },
        { unit: "b.socket", load: "loaded", active: "active", sub: "listening", description: "B" },
      ]),
    );
    expect(units.map((u) => u.unit)).toEqual(["a.service"]);
  });

  it("WoL sihirli paketi 6×FF + 16×MAC", () => {
    const p = magicPacket("02:00:00:00:00:01");
    expect(p.length).toBe(102);
    expect(p.subarray(0, 6).equals(Buffer.alloc(6, 0xff))).toBe(true);
    expect(p.subarray(6, 12).toString("hex")).toBe("020000000001");
    expect(p.subarray(96, 102).toString("hex")).toBe("020000000001");
  });
});

describe("profil şeması", () => {
  it("örnek profil geçerli", async () => {
    const json = JSON.parse(await readFile(new URL("../../tiphys.example.json", import.meta.url), "utf8"));
    const res = profileSchema.safeParse(json);
    if (!res.success) console.error(res.error.issues);
    expect(res.success).toBe(true);
  });

  it("kısmi profil geçerli, bilinmeyen alan geçersiz", () => {
    expect(profileSchema.safeParse({ format: "tiphys-profile", schemaVersion: 1, integrations: { grafana: [] } }).success).toBe(true);
    expect(profileSchema.safeParse({ format: "tiphys-profile", schemaVersion: 1, fazla: 1 }).success).toBe(false);
  });

  it("güvenlik kartı: securityStyle isteğe bağlı (varsayılan shield), geçersiz değer reddedilir", () => {
    const base = { format: "tiphys-profile", schemaVersion: 1 };
    const old = profileSchema.parse({ ...base, app: { home: { cards: ["infra"], layout: "cards" } } });
    expect(old.app?.home.securityStyle).toBe("shield");
    expect(profileSchema.parse({ ...base, app: {} }).app?.home.securityStyle).toBe("shield");
    const ok = profileSchema.parse({ ...base, app: { home: { cards: ["infra", "security"], securityStyle: "bars" } } });
    expect(ok.app?.home.cards).toContain("security");
    expect(ok.app?.home.securityStyle).toBe("bars");
    expect(profileSchema.safeParse({ ...base, app: { home: { securityStyle: "pie" } } }).success).toBe(false);
  });

  it("gizli bilgi düz metin olarak giremez (ref biçimi zorunlu)", () => {
    const res = profileSchema.safeParse({
      format: "tiphys-profile",
      schemaVersion: 1,
      integrations: { grafana: [{ id: "g", name: "G", url: "https://g", auth: { type: "token", tokenRef: "glsa_duzmetin" } }] },
    });
    expect(res.success).toBe(false);
  });
});
