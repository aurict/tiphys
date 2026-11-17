// Heavy or optional modules (Claude, Uptime Kuma bridge, host monitoring, alerts, backups) register here.
// If a feature is off its module is never loaded (e.g. on a server with Claude off, the Claude SDK is never imported).
import type { FastifyInstance } from "fastify";
import type { Ctx } from "./server.ts";

type Register = (app: FastifyInstance, ctx: Ctx) => void | Promise<void>;

export async function extraModules(ctx: Ctx): Promise<Register[]> {
  const f = ctx.store.get().features;
  const out: Register[] = [];
  // First, so its notification observer is in place before the monitors below start.
  if (f.incidents) {
    const { incidentRoutes } = await import("./incidents/routes.ts");
    out.push(incidentRoutes());
  }
  if (f.configfiles) {
    const { configFilesRoutes } = await import("./configfiles/routes.ts");
    out.push(configFilesRoutes());
  }
  if (f.databases) {
    const { dbRoutes } = await import("./db/routes.ts");
    out.push(dbRoutes());
  }
  if (f.claude) {
    const { query } = await import("@anthropic-ai/claude-agent-sdk");
    const { claudeRoutes } = await import("./claude/routes.ts");
    out.push(claudeRoutes(query));
  }
  if (f.watch) {
    const { watchRoutes } = await import("./watch.ts");
    out.push(watchRoutes);
  }
  if (f.alerts) {
    const { alertRoutes } = await import("./alerts.ts");
    out.push(alertRoutes);
  }
  if (f.backups) {
    const { backupRoutes } = await import("./backups.ts");
    out.push((app, c) => backupRoutes(app, c));
  }
  if (f.telegram) {
    const { telegramRoutes } = await import("./telegram/routes.ts");
    out.push(telegramRoutes());
  }
  if (f.uptime) {
    const { uptimeRoutes } = await import("./uptime/bridge.ts");
    out.push(uptimeRoutes);
  }
  return out;
}
