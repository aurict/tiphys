// Power: restart, shut down, sleep. Every request needs explicit confirmation ({ "confirm": true }).
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { run } from "../exec.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

const action = z.enum(["reboot", "poweroff", "suspend"]);
const body = z.object({ confirm: z.literal(true) });
type Action = z.infer<typeof action>;

/**
 * The command for an action on this OS. Linux: systemctl (polkit). macOS: pmset for sleep; restart/shut down through
 * System Events (a normal user may; `shutdown` would need root), apps can still cancel it (unsaved documents).
 * Windows: shutdown.exe; sleep via SetSuspendState (hibernates instead when hibernation is on).
 */
export function powerCommand(a: Action, platform: NodeJS.Platform = process.platform): [string, string[]] {
  if (platform === "darwin") {
    if (a === "suspend") return ["pmset", ["sleepnow"]];
    return ["osascript", ["-e", `tell application "System Events" to ${a === "reboot" ? "restart" : "shut down"}`]];
  }
  if (platform === "win32") {
    if (a === "suspend") return ["rundll32.exe", ["powrprof.dll,SetSuspendState", "0,1,0"]];
    return ["shutdown.exe", [a === "reboot" ? "/r" : "/s", "/t", "0"]];
  }
  return ["systemctl", ["--no-ask-password", a]];
}

export function powerRoutes(app: FastifyInstance, _ctx: Ctx) {
  app.post("/v1/power/:action", async (req, reply) => {
    const a = action.parse((req.params as Record<string, string>).action);
    if (!body.safeParse(req.body).success) throw new AppError("agent.power.confirmRequired", 400);
    // Run after the response is sent; otherwise the connection drops before the response arrives.
    reply.raw.on("finish", () => {
      const [cmd, args] = powerCommand(a);
      setTimeout(() => void run(cmd, args, { allowFail: true }), 1500);
    });
    return { ok: true, action: a };
  });
}
