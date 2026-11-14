// Ağır ya da isteğe bağlı modüller (Claude, Uptime Kuma köprüsü, host izleme, uyarılar) burada kaydolur.
// Özellik kapalıysa modül hiç yüklenmez (ör. Claude kapalı bir sunucuda Claude SDK hiç içe aktarılmaz).
import type { FastifyInstance } from "fastify";
import type { Ctx } from "./server.ts";

type Register = (app: FastifyInstance, ctx: Ctx) => void | Promise<void>;

export async function extraModules(ctx: Ctx): Promise<Register[]> {
  const f = ctx.store.get().features;
  const out: Register[] = [];
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
  if (f.uptime) {
    const { uptimeRoutes } = await import("./uptime/bridge.ts");
    out.push(uptimeRoutes);
  }
  return out;
}
