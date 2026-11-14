#!/usr/bin/env node
// tiphys-agent <komut>
//   serve                      ajanı başlatır
//   init [--name AD] [--features a,b] [--tailscale-login E-POSTA]   ayar dosyası oluşturur
//   pair --name "Phone" [--url https://host:7443]   yeni cihaz eşler, QR kodu basar
//   devices | revoke <id>      eşleşmiş cihazlar
//   schema                     profil JSON Schema'sını basar
//   run -- KOMUT [arg...]      komutu çalıştırır, bitince telefona bildirim gönderir (uzun işler için)
import { spawn } from "node:child_process";
import { hostname } from "node:os";
import { parseArgs } from "node:util";
import qrcode from "qrcode-terminal";
import { hashToken, newToken } from "./auth.ts";
import { ConfigStore, defaultConfigPath } from "./config.ts";
import { Notifier } from "./notify.ts";
import { profileJsonSchema } from "./profile/schema.ts";
import { buildApp, type Ctx } from "./server.ts";

const [cmd, ...rest] = process.argv.slice(2);
const { values, positionals } = parseArgs({
  args: rest,
  allowPositionals: true,
  options: {
    name: { type: "string" },
    url: { type: "string" },
    features: { type: "string" },
    "tailscale-login": { type: "string" },
    config: { type: "string" },
  },
});
const configPath = values.config ?? defaultConfigPath();

async function main() {
  switch (cmd) {
    case "schema":
      process.stdout.write(JSON.stringify(profileJsonSchema(), null, 2) + "\n");
      return;

    case "init": {
      const store = await ConfigStore.loadOrCreate(configPath, values.name ?? hostname());
      await store.update((c) => {
        if (values.name) c.name = values.name;
        if (values["tailscale-login"]) c.requireTailscaleLogin = values["tailscale-login"];
        if (values.features) {
          const on = new Set(values.features.split(",").map((s) => s.trim()));
          for (const k of Object.keys(c.features) as Array<keyof typeof c.features>) c.features[k] = on.has(k);
        }
        return c;
      });
      console.log(`Ayar dosyası: ${configPath}`);
      return;
    }

    case "pair": {
      const store = await ConfigStore.load(configPath);
      const name = values.name ?? "telefon";
      const token = newToken();
      const id = `${name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "cihaz"}-${Date.now().toString(36)}`;
      await store.update((c) => {
        c.devices.push({ id, name, tokenHash: hashToken(token), createdAt: new Date().toISOString() });
        return c;
      });
      const url = values.url ?? `http://${store.get().listen.host}:${store.get().listen.port}`;
      const payload = JSON.stringify({ v: 1, type: "tiphys-pair", agent: store.get().name, url, token });
      console.log(`Cihaz eklendi: ${name} (${id})`);
      console.log("Tiphys'te Ayarlar › Hostlar › Ajan › QR ile eşle ekranından okut:\n");
      qrcode.generate(payload, { small: true });
      console.log(`\nQR okutulamazsa elle gir:\n  Adres: ${url}\n  Token: ${token}\n`);
      console.log("Token bir daha gösterilmez; ajan sadece özetini saklar.");
      return;
    }

    case "devices": {
      const store = await ConfigStore.load(configPath);
      for (const d of store.get().devices) console.log(`${d.id}\t${d.name}\t${d.createdAt}`);
      return;
    }

    case "revoke": {
      const id = positionals[0];
      if (!id) throw new Error("kullanım: tiphys-agent revoke <cihaz-id>");
      const store = await ConfigStore.load(configPath);
      await store.update((c) => {
        c.devices = c.devices.filter((d) => d.id !== id);
        c.push.endpoints = c.push.endpoints.filter((e) => e.deviceId !== id);
        return c;
      });
      console.log(`İptal edildi: ${id}`);
      return;
    }

    case "run": {
      if (positionals.length === 0) {
        console.error("kullanım: tiphys-agent run -- KOMUT [arg...]");
        process.exit(2);
      }
      const store = await ConfigStore.load(configPath);
      const notifier = new Notifier(() => store.get(), (m) => console.error(`[tiphys] ${m}`));
      const started = Date.now();
      const child = spawn(positionals[0]!, positionals.slice(1), { stdio: "inherit" });
      for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(sig, () => child.kill(sig));
      const code = await new Promise<number>((res) => {
        child.on("error", () => res(127));
        child.on("exit", (c, sig) => res(c ?? (sig ? 128 : 1)));
      });
      await notifier.send({
        key: code === 0 ? "command.done" : "command.failed",
        params: { host: store.get().name, command: positionals.join(" ").slice(0, 120), seconds: Math.round((Date.now() - started) / 1000), code },
        link: "tiphys://terminal",
      });
      process.exit(code);
    }

    case "serve": {
      // Güvenlik ağı: yakalanmamış bir hata tüm ajanı (ve her canlı Claude oturumunu) düşürmesin; kaydedilir.
      process.on("unhandledRejection", (e) => console.error("yakalanmamış hata (ajan çalışmaya devam ediyor):", e));
      const store = await ConfigStore.load(configPath);
      const notifier = new Notifier(() => store.get(), (m, e) => console.error(m, e ?? ""));
      const ctx: Ctx = { store, notifier, extraRoutes: [] };
      const { extraModules } = await import("./modules.ts");
      ctx.extraRoutes!.push(...(await extraModules(ctx)));
      const app = await buildApp(ctx, { logger: true });
      const { host, port } = store.get().listen;
      await app.listen({ host, port });
      const stop = async () => {
        await app.close();
        process.exit(0);
      };
      process.on("SIGTERM", stop);
      process.on("SIGINT", stop);
      return;
    }

    default:
      console.error("komutlar: serve | init | pair | devices | revoke <id> | schema | run -- KOMUT");
      process.exit(2);
  }
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
