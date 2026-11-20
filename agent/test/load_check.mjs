// CI check (H4, PLAN.md §18): with only "system" on, the agent must not load feature modules it doesn't use
// (desktop, live screen, AT-SPI, Claude, web-push…). Run after `npm run build`: node test/load_check.mjs
import { registerHooks } from "node:module";
import { mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

const loaded = new Set();
registerHooks({
  load(url, context, next) {
    loaded.add(url);
    return next(url, context);
  },
});

const dir = await mkdtemp(join(tmpdir(), "tiphys-load-"));
const { ConfigStore } = await import("../dist/config.js");
const { Notifier } = await import("../dist/notify.js");
const { buildApp } = await import("../dist/server.js");
const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "load-check");
await store.update((c) => {
  for (const k of Object.keys(c.features)) c.features[k] = k === "system";
  return c;
});
const app = await buildApp({ store, notifier: new Notifier(() => store.get(), () => {}) });
await app.ready();
const forbidden = ["/dist/routes/hypr.js", "/dist/routes/stream.js", "/dist/atspi.js", "/dist/routes/desktop.js", "/dist/routes/sunshine.js", "/dist/routes/docker.js", "/dist/claude/", "/node_modules/web-push/", "/node_modules/@anthropic-ai/"];
// claude/schedules.js only holds the schedule schema that config.ts validates with (no SDK).
const allowed = ["/dist/claude/schedules.js"];
const bad = [...loaded].filter((u) => forbidden.some((f) => u.includes(f)) && !allowed.some((a) => u.includes(a)));
await app.close();
if (bad.length) {
  console.error("loaded although their feature is off:\n" + bad.join("\n"));
  process.exit(1);
}
console.log(`ok: ${[...loaded].filter((u) => u.includes("/dist/")).length} agent modules loaded with only "system"`);
