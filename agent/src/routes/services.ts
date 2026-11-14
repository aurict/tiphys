// systemd servisleri (kullanıcı + sistem): liste, başlat/durdur/yeniden başlat, günlük.
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { run } from "../exec.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

const scope = z.enum(["user", "system"]);
const unitName = z.string().regex(/^[A-Za-z0-9@._:\\-]{1,200}$/);
const action = z.enum(["start", "stop", "restart"]);

const scopeArgs = (s: "user" | "system") => (s === "user" ? ["--user"] : []);

interface Unit {
  unit: string;
  load: string;
  active: string;
  sub: string;
  description: string;
}

export function parseUnits(json: string): Unit[] {
  const units = JSON.parse(json) as Unit[];
  return units
    .filter((u) => u.unit.endsWith(".service"))
    .map((u) => ({ unit: u.unit, load: u.load, active: u.active, sub: u.sub, description: u.description }));
}

export function serviceRoutes(app: FastifyInstance, _ctx: Ctx) {
  app.get("/v1/services/:scope", async (req) => {
    const s = scope.parse((req.params as { scope: string }).scope);
    const { stdout } = await run("systemctl", [...scopeArgs(s), "list-units", "--type=service", "--all", "--output=json", "--no-pager"]);
    return { scope: s, units: parseUnits(stdout) };
  });

  app.post("/v1/services/:scope/:unit/:action", async (req) => {
    const p = req.params as Record<string, string>;
    const s = scope.parse(p.scope);
    const u = unitName.parse(p.unit);
    const a = action.parse(p.action);
    const res = await run("systemctl", [...scopeArgs(s), "--no-ask-password", a, u], { allowFail: true, timeoutMs: 60000 });
    if (res.code !== 0) {
      const denied = /access denied|interactive authentication required|not authorized/i.test(res.stderr);
      throw new AppError(denied ? "agent.services.permissionDenied" : "agent.services.actionFailed", denied ? 403 : 502, {
        unit: u,
        action: a,
        stderr: res.stderr.slice(0, 1000),
      });
    }
    return { ok: true };
  });

  app.get("/v1/services/:scope/:unit/logs", async (req) => {
    const p = req.params as Record<string, string>;
    const s = scope.parse(p.scope);
    const u = unitName.parse(p.unit);
    const lines = z.coerce.number().int().min(1).max(2000).default(200).parse((req.query as Record<string, unknown>).lines);
    const args = [...scopeArgs(s), s === "user" ? "--user-unit" : "--unit", u, "-n", String(lines), "-o", "json", "--no-pager"];
    const { stdout } = await run("journalctl", args, { timeoutMs: 20000 });
    const entries = stdout
      .split("\n")
      .filter(Boolean)
      .map((l) => {
        const e = JSON.parse(l) as Record<string, string>;
        return {
          timeUs: Number(e.__REALTIME_TIMESTAMP ?? 0),
          priority: Number(e.PRIORITY ?? 6),
          message: typeof e.MESSAGE === "string" ? e.MESSAGE : "",
        };
      });
    return { unit: u, entries };
  });
}
