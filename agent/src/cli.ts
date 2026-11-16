#!/usr/bin/env node
// tiphys-agent <command>
//   serve                      starts the agent
//   init [--name AD] [--features a,b] [--tailscale-login E-POSTA]   creates the settings file
//   pair --name "Phone" [--url https://host:7443]   pairs a new device, prints a QR code
//   devices | revoke <id>      paired devices
//   schema                     prints the profile JSON Schema
//   run -- KOMUT [arg...]      runs the command, sends a notification to the phone when done (for long jobs)
//   firefox install            registers the Firefox bridge native messaging host (11.2)
//   vscode-a11y install|remove adds/removes --force-renderer-accessibility in the VS Code launcher (11.4)
import { spawn } from "node:child_process";
import { hostname } from "node:os";
import { parseArgs } from "node:util";
import qrcode from "qrcode-terminal";
import { hashToken, newToken } from "./auth.ts";
import { ConfigStore, defaultConfigPath } from "./config.ts";
import { EventLog, eventsPath } from "./events.ts";
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
      const notifier = new Notifier(() => store.get(), (m) => console.error(`[tiphys] ${m}`), new EventLog(eventsPath(store.path)));
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

    case "firefox": {
      if (positionals[0] !== "install") throw new Error("kullanım: tiphys-agent firefox install");
      const { installFirefoxHost } = await import("./firefox_install.ts");
      const r = await installFirefoxHost();
      console.log(`Yerel ileti manifesti: ${r.manifest}\nBaşlatıcı: ${r.launcher}`);
      console.log(r.xpi ? `Eklenti (imzasız XPI): ${r.xpi}` : "Eklenti XPI'si yok: önce cd firefox && npm run build");
      console.log(
        "\nElle yapılacak iki adım (Firefox 140 ESR):\n" +
          "  1. about:config → xpinstall.signatures.required = false\n" +
          "  2. about:addons → dişli → \"Dosyadan eklenti yükle…\" → yukarıdaki XPI\n" +
          "Sayfa içeriği (okuma, medya, kaydırma, yazı) için eklenti simgesi › \"Sayfa içeriği iznini ver\".",
      );
      return;
    }

    case "vscode-a11y": {
      const action = positionals[0];
      if (action !== "install" && action !== "remove") throw new Error("kullanım: tiphys-agent vscode-a11y install|remove");
      const { vscodeA11y } = await import("./vscode_a11y.ts");
      console.log(await vscodeA11y(action));
      return;
    }

    case "serve": {
      // Safety net: an uncaught error must not take down the whole agent (and every live Claude session); it's logged.
      process.on("unhandledRejection", (e) => console.error("yakalanmamış hata (ajan çalışmaya devam ediyor):", e));
      const store = await ConfigStore.load(configPath);
      const notifier = new Notifier(() => store.get(), (m, e) => console.error(m, e ?? ""), new EventLog(eventsPath(store.path)));
      const { RunLog, runLogPath } = await import("./runs.ts");
      const runs = new RunLog(runLogPath({ store } as Ctx));
      await runs.begin();
      const ctx: Ctx = { store, notifier, extraRoutes: [], runs };
      if (store.get().features.desktop) {
        // Firefox bridge socket (11.2); if it can't be opened (e.g. another agent listens) the bridge is skipped, agent runs.
        const { BrowserBridge } = await import("./browser_bridge.ts");
        const { defaultSocketPath } = await import("./firefox_host.ts");
        ctx.browser = await BrowserBridge.listen(defaultSocketPath(), { log: (m) => console.error(m) }).catch((e) => {
          console.error("Firefox köprüsü açılamadı:", e instanceof Error ? e.message : e);
          return undefined;
        });
      }
      const { extraModules } = await import("./modules.ts");
      ctx.extraRoutes!.push(...(await extraModules(ctx)));
      const app = await buildApp(ctx, { logger: true });
      const { host, port } = store.get().listen;
      await app.listen({ host, port });
      // If the previous run didn't shut down cleanly (crash, out of memory): notify the phone.
      if (runs.previousCrashed) {
        void notifier.send({ key: "agent.restarted", params: { host: store.get().name }, link: "tiphys://system", priority: "high" });
      }
      const stop = async () => {
        await app.close();
        await ctx.browser?.close().catch(() => {});
        await runs.end().catch(() => {});
        process.exit(0);
      };
      process.on("SIGTERM", stop);
      process.on("SIGINT", stop);
      return;
    }

    default:
      console.error("komutlar: serve | init | pair | devices | revoke <id> | schema | run -- KOMUT | firefox install | vscode-a11y install|remove");
      process.exit(2);
  }
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
