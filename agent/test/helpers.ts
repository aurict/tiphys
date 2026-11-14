import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hashToken, newToken } from "../src/auth.ts";
import { ConfigStore, type AgentConfig } from "../src/config.ts";
import { Notifier } from "../src/notify.ts";
import { buildApp, type Ctx } from "../src/server.ts";

export async function testApp(patch: (c: AgentConfig) => AgentConfig = (c) => c, extra: Ctx["extraRoutes"] = []) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-agent-"));
  const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "test");
  const token = newToken();
  await store.update((c) => {
    c.devices.push({ id: "phone", name: "Telefon", tokenHash: hashToken(token), createdAt: new Date().toISOString() });
    return patch(c);
  });
  const sent: unknown[] = [];
  const notifier = new Notifier(() => store.get(), () => {});
  const origSend = notifier.send.bind(notifier);
  notifier.send = async (n) => {
    sent.push(n);
    return origSend(n);
  };
  const app = await buildApp({ store, notifier, extraRoutes: extra });
  const auth = { authorization: `Bearer ${token}` };
  return { app, store, token, auth, dir, sent, notifier };
}
