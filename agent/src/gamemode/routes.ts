// Game mode ("gamemode" feature, PLAN.md §19). Both sides load on every machine with the flag: the source routes
// (feed, source status, ETS2 plugin) and the display routes (settings, kiosk lifecycle, live page, static page). The
// source side starts no process until a feed subscriber connects; the display side none until the mode is started.
import type { FastifyInstance } from "fastify";
import type { Ctx } from "../server.ts";
import { displayRoutes } from "./display.ts";
import { sourceRoutes } from "./source.ts";

export async function gamemodeRoutes(app: FastifyInstance, ctx: Ctx) {
  sourceRoutes(app, ctx);
  await displayRoutes(app, ctx);
}
