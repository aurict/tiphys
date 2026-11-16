// Power: restart, shut down, sleep. Every request needs explicit confirmation ({ "confirm": true }).
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { run } from "../exec.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

const action = z.enum(["reboot", "poweroff", "suspend"]);
const body = z.object({ confirm: z.literal(true) });

export function powerRoutes(app: FastifyInstance, _ctx: Ctx) {
  app.post("/v1/power/:action", async (req, reply) => {
    const a = action.parse((req.params as Record<string, string>).action);
    if (!body.safeParse(req.body).success) throw new AppError("agent.power.confirmRequired", 400);
    // Run after the response is sent; otherwise the connection drops before the response arrives.
    reply.raw.on("finish", () => {
      setTimeout(() => void run("systemctl", ["--no-ask-password", a], { allowFail: true }), 1500);
    });
    return { ok: true, action: a };
  });
}
