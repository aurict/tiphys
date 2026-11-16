// Reads Homepage's services.yaml, splits it into groups and checks the siteMonitor addresses.
// It can also add a new service to a group (comments and layout are preserved).
import { readFile, rename, writeFile } from "node:fs/promises";
import type { FastifyInstance } from "fastify";
import { isMap, isSeq, parse, parseDocument, type YAMLMap, type YAMLSeq } from "yaml";
import { z } from "zod";
import { expandHome } from "../config.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

export interface HpService {
  name: string;
  href: string | null;
  description: string | null;
  icon: string | null;
  monitorUrl: string | null;
}
export interface HpGroup {
  name: string;
  services: HpService[];
  groups: HpGroup[];
}

type Raw = Record<string, unknown>;

function toGroup(name: string, items: unknown): HpGroup {
  const g: HpGroup = { name, services: [], groups: [] };
  if (!Array.isArray(items)) return g;
  for (const item of items) {
    if (!item || typeof item !== "object") continue;
    for (const [key, value] of Object.entries(item as Raw)) {
      if (Array.isArray(value)) {
        g.groups.push(toGroup(key, value));
      } else if (value && typeof value === "object") {
        const v = value as Raw;
        const str = (k: string) => (typeof v[k] === "string" ? (v[k] as string) : null);
        // Cards without a link (e.g. just a Glances widget) aren't shown in the list.
        if (!str("href")) continue;
        g.services.push({
          name: key,
          href: str("href"),
          description: str("description"),
          icon: str("icon"),
          monitorUrl: str("siteMonitor"),
        });
      }
    }
  }
  return g;
}

export function parseServices(yamlText: string): HpGroup[] {
  const doc = parse(yamlText) as unknown;
  if (!Array.isArray(doc)) throw new AppError("agent.homepage.invalidFile", 500);
  return doc.flatMap((entry) =>
    entry && typeof entry === "object" ? Object.entries(entry as Raw).map(([k, v]) => toGroup(k, v)) : [],
  );
}

export type Status = "up" | "down" | "unknown";

export async function check(url: string, timeoutMs: number): Promise<{ status: Status; httpStatus: number | null; ms: number | null }> {
  const started = Date.now();
  try {
    const res = await fetch(url, { method: "GET", redirect: "manual", signal: AbortSignal.timeout(timeoutMs) });
    await res.body?.cancel();
    // Like Homepage's siteMonitor: any response other than 5xx counts as "up".
    return { status: res.status < 500 ? "up" : "down", httpStatus: res.status, ms: Date.now() - started };
  } catch {
    return { status: "down", httpStatus: null, ms: null };
  }
}

let cache: { at: number; value: unknown } | null = null;

export const newService = z.object({
  group: z.string().min(1).max(100),
  name: z.string().trim().min(1).max(100),
  href: z.url(),
  description: z.string().max(300).optional(),
  icon: z.string().max(200).optional(),
  siteMonitor: z.url().optional(),
});

/** Adds a service to a top-level group (creating the group at the end if missing). Errors if a same-named service exists. */
export function addService(yamlText: string, s: z.infer<typeof newService>): string {
  const doc = parseDocument(yamlText);
  if (!isSeq(doc.contents)) throw new AppError("agent.homepage.invalidFile", 500);
  const root = doc.contents as unknown as YAMLSeq<unknown>;
  let groupSeq: YAMLSeq<unknown> | null = null;
  for (const item of root.items) {
    if (isMap(item) && item.has(s.group)) {
      const v = item.get(s.group, true);
      if (isSeq(v)) groupSeq = v as YAMLSeq<unknown>;
    }
  }
  if (!groupSeq) {
    const groupMap = doc.createNode({ [s.group]: [] }) as YAMLMap<unknown, unknown>;
    root.add(groupMap);
    groupSeq = groupMap.get(s.group, true) as unknown as YAMLSeq<unknown>;
  }
  for (const item of groupSeq.items) {
    if (isMap(item) && item.has(s.name)) throw new AppError("agent.homepage.serviceExists", 409, { name: s.name });
  }
  const body: Record<string, string> = { href: s.href };
  if (s.description) body.description = s.description;
  if (s.icon) body.icon = s.icon;
  body.siteMonitor = s.siteMonitor ?? s.href;
  groupSeq.add(doc.createNode({ [s.name]: body }));
  return doc.toString();
}

export function homepageRoutes(app: FastifyInstance, ctx: Ctx) {
  app.get("/v1/homepage", async () => {
    if (cache && Date.now() - cache.at < 30000) return cache.value;
    const cfg = ctx.store.get().homepage;
    let text: string;
    try {
      text = await readFile(expandHome(cfg.servicesPath), "utf8");
    } catch {
      throw new AppError("agent.homepage.fileNotFound", 404, { path: cfg.servicesPath });
    }
    const groups = parseServices(text);
    const all: HpService[] = [];
    const walk = (g: HpGroup) => {
      all.push(...g.services);
      g.groups.forEach(walk);
    };
    groups.forEach(walk);
    const results = new Map<string, Awaited<ReturnType<typeof check>>>();
    await Promise.all(
      [...new Set(all.map((s) => s.monitorUrl).filter((u): u is string => !!u))].map(async (u) =>
        results.set(u, await check(u, cfg.checkTimeoutMs)),
      ),
    );
    const decorate = (g: HpGroup): unknown => ({
      name: g.name,
      services: g.services.map((s) => ({
        ...s,
        status: s.monitorUrl ? (results.get(s.monitorUrl)?.status ?? "unknown") : "unknown",
        responseMs: s.monitorUrl ? (results.get(s.monitorUrl)?.ms ?? null) : null,
      })),
      groups: g.groups.map(decorate),
    });
    const value = { checkedAt: new Date().toISOString(), groups: groups.map(decorate) };
    cache = { at: Date.now(), value };
    return value;
  });

  app.post("/v1/homepage/services", async (req) => {
    const body = newService.parse(req.body);
    const file = expandHome(ctx.store.get().homepage.servicesPath);
    let text: string;
    try {
      text = await readFile(file, "utf8");
    } catch {
      throw new AppError("agent.homepage.fileNotFound", 404, { path: ctx.store.get().homepage.servicesPath });
    }
    const next = addService(text, body);
    // Homepage watches the file; temp file + rename so it never sees a half-written file.
    const tmp = `${file}.tiphys.tmp`;
    await writeFile(tmp, next);
    await rename(tmp, file);
    cache = null;
    return { ok: true };
  });
}
