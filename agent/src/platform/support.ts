// What the agent can do on this operating system (P3). Linux is the reference platform; macOS and Windows have their
// own implementations of the server features in platform/darwin.ts and platform/win32.ts (loaded lazily, only there).
// Entries are a feature name ("services") or a part of one ("services.logs"). GET /v1/health lists them as
// `unsupported`; routes of such a part answer 501 agent.feature.unsupported; `init --detect` and `doctor` never
// enable or recommend a whole feature listed here. Kept tiny: server.ts imports it on every start.
import type { FastifyInstance } from "fastify";
import { AppError } from "../errors.ts";

const UNSUPPORTED: Partial<Record<NodeJS.Platform, readonly string[]>> = {
  linux: [],
  darwin: [],
  win32: [
    // Windows services have no per-user scope here, and the event log is not read.
    "services.user",
    "services.logs",
    // Windows can only terminate a process: TERM (taskkill, graceful) and KILL (forced) work, INT/HUP don't exist.
    "processes.signal.INT",
    "processes.signal.HUP",
    // Unix sockets (Linux/macOS only; Windows named pipes are not implemented).
    "desktop.velour",
    "desktop.firefoxBridge",
  ],
};

export function unsupportedOn(platform: NodeJS.Platform = process.platform): string[] {
  return [...(UNSUPPORTED[platform] ?? [])];
}

export function isSupported(part: string, platform: NodeJS.Platform = process.platform): boolean {
  return !(UNSUPPORTED[platform] ?? []).includes(part);
}

export function unsupported(feature: string, platform: NodeJS.Platform = process.platform): AppError {
  return new AppError("agent.feature.unsupported", 501, { feature, platform });
}

/** Answers every method on `prefix` and below with 501 agent.feature.unsupported (instead of the real routes). */
export function unsupportedRoutes(app: FastifyInstance, prefix: string, feature: string, platform: NodeJS.Platform = process.platform) {
  const handler = async () => {
    throw unsupported(feature, platform);
  };
  app.all(prefix, handler);
  app.all(`${prefix}/*`, handler);
}

/** The macOS or Windows implementation of the server features (call only on those two). */
export const platformImpl = () => (process.platform === "win32" ? import("./win32.ts") : import("./darwin.ts"));
