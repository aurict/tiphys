// Services affected by a change to a stack's env file (PLAN.md §13.3): services that load it with `env_file`, and for
// the stack's root .env (compose's interpolation source) services whose definition references a changed key as
// ${KEY} / $KEY. restart.ts recreates them (C-2).
import { readFile, realpath } from "node:fs/promises";
import { isAbsolute, join, resolve } from "node:path";
import { parse } from "yaml";
import type { Stack } from "../stacks.ts";

function envFileEntries(v: unknown): string[] {
  const list = Array.isArray(v) ? v : v === undefined || v === null ? [] : [v];
  return list.flatMap((e) => (typeof e === "string" ? [e] : e && typeof e === "object" && typeof (e as { path?: unknown }).path === "string" ? [(e as { path: string }).path] : []));
}

/** Variable names referenced in compose interpolation syntax anywhere in a value (keys included); `$$` is a literal. */
export function referencedVars(v: unknown, out = new Set<string>()): Set<string> {
  if (typeof v === "string") {
    const s = v.replace(/\$\$/g, "");
    for (const m of s.matchAll(/\$(?:\{([A-Za-z_][A-Za-z0-9_]*)[^}]*\}|([A-Za-z_][A-Za-z0-9_]*))/g)) out.add((m[1] ?? m[2])!);
  } else if (Array.isArray(v)) {
    for (const x of v) referencedVars(x, out);
  } else if (v && typeof v === "object") {
    for (const [k, x] of Object.entries(v)) {
      referencedVars(k, out);
      referencedVars(x, out);
    }
  }
  return out;
}

export async function affectedServices(stacks: Stack[], real: string, keys: string[]): Promise<Array<{ stack: string; project: string; services: string[] }>> {
  const out: Array<{ stack: string; project: string; services: string[] }> = [];
  for (const stack of stacks) {
    if (!stack.envFiles.includes(real)) continue;
    const rootEnv = (await realpath(join(stack.dir, ".env")).catch(() => null)) === real;
    const services = new Set<string>();
    for (const f of stack.composeFiles) {
      let doc: unknown;
      try {
        doc = parse(await readFile(f, "utf8"), { merge: true });
      } catch {
        continue;
      }
      const svcs = doc && typeof doc === "object" ? (doc as { services?: unknown }).services : undefined;
      if (!svcs || typeof svcs !== "object") continue;
      for (const [name, def] of Object.entries(svcs as Record<string, unknown>)) {
        if (!stack.services.includes(name)) continue;
        const envFile = def && typeof def === "object" ? (def as { env_file?: unknown }).env_file : undefined;
        for (const e of envFileEntries(envFile)) {
          const p = await realpath(isAbsolute(e) ? e : resolve(stack.dir, e)).catch(() => null);
          if (p === real) services.add(name);
        }
        if (rootEnv) {
          const refs = referencedVars(def);
          if (keys.some((k) => refs.has(k))) services.add(name);
        }
      }
    }
    if (services.size) out.push({ stack: stack.id, project: stack.project, services: [...services].sort() });
  }
  return out;
}
