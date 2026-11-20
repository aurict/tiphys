#!/usr/bin/env node
// tiphys-agent <command>
//   serve                      starts the agent
//   init [--name AD] [--detect] [--features a,b] [--set-features a,b] [--disable a,b] [--tailscale-login E-POSTA]
//                              creates/updates the settings file. --features ADDS, --set-features is an exact list,
//                              --detect turns on the safe features this machine supports (detect.ts)
//   pair --name "Phone" [--url https://host:7443]   pairs a new device, prints a QR code (URL found via Tailscale)
//   doctor [--json]            checks the install (doctor.ts); exit 1 when a check fails
//   devices | revoke <id>      paired devices
//   schema                     prints the profile JSON Schema
//   run -- KOMUT [arg...]      runs the command, sends a notification to the phone when done (for long jobs)
//   firefox install            registers the Firefox bridge native messaging host (11.2)
//   vscode-a11y install|remove adds/removes --force-renderer-accessibility in the VS Code launcher (11.4)
//   service-token create --name N --scope research | list | revoke <id>   scoped tokens for other agents
//   lockdown --url https://atlas:7443   lost phone: asks for the recovery code (stdin), locks that agent and the agents
//                              it fans out to (security center, PLAN.md §15 S-4)
import { spawn } from "node:child_process";
import { existsSync, realpathSync } from "node:fs";
import { hostname } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";
import { hashToken, newToken } from "./auth.ts";
import { ConfigStore, defaultConfigPath } from "./config.ts";
import { EventLog, eventsPath } from "./events.ts";
import { Notifier } from "./notify.ts";
import { buildApp, type Ctx } from "./server.ts";

const [cmd, ...rest] = process.argv.slice(2);
const { values, positionals } = parseArgs({
  args: rest,
  allowPositionals: true,
  options: {
    name: { type: "string" },
    url: { type: "string" },
    features: { type: "string" },
    "set-features": { type: "string" },
    disable: { type: "string" },
    detect: { type: "boolean" },
    json: { type: "boolean" },
    "tailscale-login": { type: "string" },
    config: { type: "string" },
    scope: { type: "string", multiple: true },
  },
});
const configPath = values.config ?? defaultConfigPath();

async function main() {
  switch (cmd) {
    case "schema":
      const { profileJsonSchema } = await import("./profile/schema.ts");
      process.stdout.write(JSON.stringify(profileJsonSchema(), null, 2) + "\n");
      return;

    case "init": {
      const { initCommand, FeatureError } = await import("./detect.ts");
      try {
        await initCommand(configPath, {
          name: values.name,
          tailscaleLogin: values["tailscale-login"],
          features: values.features,
          setFeatures: values["set-features"],
          disable: values.disable,
          detect: values.detect === true,
        });
      } catch (e) {
        if (!(e instanceof FeatureError)) throw e;
        console.error(e.message);
        process.exit(2);
      }
      return;
    }

    case "pair": {
      const store = await ConfigStore.load(configPath);
      const name = values.name ?? "telefon";
      // Without --url: this machine's MagicDNS name and the `tailscale serve` port of the agent (K4).
      let url = values.url;
      if (!url) {
        const ts = await import("./tailscale.ts");
        const port = store.get().listen.port;
        const own = await ts.ownAgentUrl(port);
        if (!own.url) {
          const why = !own.state.installed ? "Tailscale is not installed (https://tailscale.com/download)" : !own.state.running ? "Tailscale is not running or not logged in (tailscale up)" : "Tailscale reports no MagicDNS name (enable MagicDNS)";
          console.error(`Could not find this agent's address: ${why}.\nPass it yourself: tiphys-agent pair --url https://<machine>.<tailnet>.ts.net:7443`);
          process.exit(1);
        }
        if (!own.served) console.error(`Note: tailscale serve does not publish the agent yet. Run:\n  ${ts.serveCommand(port)}\n`);
        url = own.url;
      }
      const token = newToken();
      const id = `${name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "") || "cihaz"}-${Date.now().toString(36)}`;
      await store.update((c) => {
        c.devices.push({ id, name, tokenHash: hashToken(token), createdAt: new Date().toISOString() });
        return c;
      });
      const payload = JSON.stringify({ v: 1, type: "tiphys-pair", agent: store.get().name, url, token });
      console.log(`Cihaz eklendi: ${name} (${id})`);
      console.log("Tiphys'te Ayarlar › Hostlar › Ajan › QR ile eşle ekranından okut:\n");
      const { default: qrcode } = await import("qrcode-terminal");
      qrcode.generate(payload, { small: true });
      console.log(`\nQR okutulamazsa elle gir:\n  Adres: ${url}\n  Token: ${token}\n`);
      console.log("Token bir daha gösterilmez; ajan sadece özetini saklar.");
      // The running agent re-reads agent.json (watch + on unknown tokens); check that it already accepts the device.
      console.log((await agentKnowsToken(store.get(), token)) ? "The running agent accepts the new device; no restart needed." : "The agent did not confirm the new device (not running, or an older version). If pairing fails: systemctl --user restart tiphys-agent");
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

    case "service-token": {
      const { serviceTokenCli } = await import("./service_tokens.ts");
      const store = await ConfigStore.load(configPath);
      for (const line of await serviceTokenCli(store, positionals, { name: values.name, scopes: values.scope ?? [] })) console.log(line);
      return;
    }

    case "lockdown": {
      const url = values.url;
      if (!url || !/^https:\/\//.test(url)) throw new Error("kullanım: tiphys-agent lockdown --url https://SUNUCU:7443  (kurtarma kodu standart girdiden okunur)");
      // The code is read from stdin, not argv (it would land in the shell history and the process list).
      if (process.stdin.isTTY) process.stderr.write("Kurtarma kodu: ");
      const chunks: Buffer[] = [];
      for await (const c of process.stdin) {
        chunks.push(c as Buffer);
        if (Buffer.concat(chunks).includes(10)) break;
      }
      const code = Buffer.concat(chunks).toString("utf8").split("\n")[0]!.trim();
      const res = await fetch(new URL("/v1/security/lockdown", url), {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ code }),
        signal: AbortSignal.timeout(60_000),
      });
      const body = (await res.json().catch(() => ({}))) as { targets?: Array<{ name: string; ok: boolean; status: number | null }>; error?: { code: string } };
      if (!res.ok) throw new Error(`kilitleme başarısız: ${body.error?.code ?? res.status}`);
      console.log("Kilitlendi: tüm cihazlar, hizmet belirteçleri ve bildirim uçları silindi.");
      for (const t of body.targets ?? []) console.log(`  ${t.name}: ${t.ok ? "kilitlendi" : `BAŞARISIZ (${t.status ?? "ulaşılamadı"}) — bu ajanda 'Her şeyi kilitle'yi elle yapın`}`);
      console.log("Yeniden eşleştirmek için her makinede: tiphys-agent pair");
      return;
    }

    case "doctor": {
      const store = await ConfigStore.load(configPath).catch((e: NodeJS.ErrnoException) => {
        if (e.code !== "ENOENT") console.error(`Settings file ${configPath} could not be read: ${e.message}`);
        return null;
      });
      const { runDoctor, defaultDoctorDeps, formatCheck } = await import("./doctor.ts");
      const report = await runDoctor(defaultDoctorDeps(store?.get() ?? null, configPath));
      if (values.json) console.log(JSON.stringify(report, null, 2));
      else {
        console.log(`Tiphys agent ${report.version}`);
        for (const c of report.checks) console.log(formatCheck(c));
      }
      process.exit(report.checks.some((c) => c.status === "fail") ? 1 : 0);
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
      // Unix socket: Linux/macOS only (on Windows the bridge routes answer agent.feature.unsupported).
      if (store.get().features.desktop && process.platform !== "win32") {
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
      // Devices paired with the CLI (another process) work without a restart (K4).
      const unwatch = store.watch(() => console.error("agent.json başka bir süreç tarafından değişti; yeniden okundu"));
      settleUpdateLater();
      // If the previous run didn't shut down cleanly (crash, out of memory): notify the phone.
      if (runs.previousCrashed) {
        void notifier.send({ key: "agent.restarted", params: { host: store.get().name }, link: "tiphys://system", priority: "high" });
      }
      const stop = async () => {
        unwatch();
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
      console.error("komutlar: serve | init | pair | doctor | devices | revoke <id> | schema | run -- KOMUT | firefox install | vscode-a11y install|remove | service-token create|list|revoke");
      process.exit(2);
  }
}

/** GET /v1/devices on the local listen address with the new token (a few tries: the watcher is debounced). */
async function agentKnowsToken(c: import("./config.ts").AgentConfig, token: string): Promise<boolean> {
  const host = c.listen.host === "0.0.0.0" || c.listen.host === "::" ? "127.0.0.1" : c.listen.host.includes(":") ? `[${c.listen.host}]` : c.listen.host;
  const headers: Record<string, string> = { authorization: `Bearer ${token}` };
  if (c.requireTailscaleLogin) headers["tailscale-user-login"] = c.requireTailscaleLogin;
  for (let i = 0; i < 3; i++) {
    try {
      const r = await fetch(`http://${host}:${c.listen.port}/v1/devices`, { headers, signal: AbortSignal.timeout(2000) });
      if (r.ok) return true;
      if (r.status !== 401) return false;
    } catch {
      return false;
    }
    await new Promise((res) => setTimeout(res, 700));
  }
  return false;
}

/**
 * After a self-update the new version confirms itself once it has been up for 15 s (removes the marker the guard
 * counts, see update.ts). Only installs from install.sh have the marker; update.ts loads only then.
 */
function settleUpdateLater() {
  let root: string;
  try {
    root = join(realpathSync(fileURLToPath(new URL("..", import.meta.url))), "..", "..");
  } catch {
    return;
  }
  if (!existsSync(join(root, "update-pending"))) return;
  setTimeout(async () => {
    const { managedRoot, settleUpdate } = await import("./update.ts");
    const r = managedRoot();
    if (r && (await settleUpdate(r)) === "confirmed") console.error("güncelleme onaylandı");
  }, 15_000).unref();
}

main().catch((e) => {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
});
