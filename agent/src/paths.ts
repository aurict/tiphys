// Allowed roots (allowedRoots) check: after resolving symlinks, the path must be inside one of the roots.
import { realpath } from "node:fs/promises";
import { sep } from "node:path";
import { expandHome, type AgentConfig } from "./config.ts";
import { AppError } from "./errors.ts";

export async function allowedPath(config: AgentConfig, p: string): Promise<string> {
  let real: string;
  try {
    real = await realpath(expandHome(p));
  } catch {
    throw new AppError("agent.path.notFound", 404, { path: p });
  }
  const roots = await Promise.all(config.allowedRoots.map((r) => realpath(expandHome(r)).catch(() => null)));
  const ok = roots.some((r) => r !== null && (real === r || real.startsWith(r.endsWith(sep) ? r : r + sep)));
  if (!ok) throw new AppError("agent.path.notAllowed", 403, { path: p });
  return real;
}
