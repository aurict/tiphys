// Screen modes ("screen" feature, PLAN.md §19, §20). Both sides load on every machine with the flag: the source routes
// (feed, Game source status, ETS2 plugin) and the display routes (settings, kiosk lifecycle, live page, static page).
// They share one producer: the display's `self` source subscribes to it in-process. The source side starts no
// process until something subscribes a topic; the display side none until a mode is started.
import type { FastifyInstance } from "fastify";
import type { Ctx } from "../server.ts";
import { displayRoutes } from "./display.ts";
import { sourceRoutes } from "./source.ts";

export async function screenRoutes(app: FastifyInstance, ctx: Ctx) {
  const feed = sourceRoutes(app, ctx);
  await displayRoutes(app, ctx, { feed });
}
