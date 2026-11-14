// Port önizleme: dinlenen TCP portları ve süreçleri. Sadece localhost'u dinleyen bir portu telefondan açmak
// için tailscale serve ile tailnet'e paylaşır (https://<pc>.ts.net:<port>); herkese açık değildir.
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { run } from "../exec.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

export interface Listen {
  port: number;
  address: string;
  process: string | null;
  pid: number | null;
  localOnly: boolean;
}

export function parseSs(out: string): Listen[] {
  const byPort = new Map<number, Listen>();
  for (const line of out.split("\n")) {
    const f = line.trim().split(/\s+/);
    if (f.length < 4) continue;
    const local = f[3]!;
    const i = local.lastIndexOf(":");
    const port = Number(local.slice(i + 1));
    if (!Number.isInteger(port)) continue;
    const address = local.slice(0, i).replace(/^\[|\]$/g, "").replace(/%.*$/, "");
    const m = /users:\(\("([^"]+)",pid=(\d+)/.exec(line);
    const loopback = address === "127.0.0.1" || address === "::1" || address.startsWith("127.");
    const prev = byPort.get(port);
    // Aynı port hem IPv4 hem IPv6'da dinlenebilir: biri herkese açıksa port herkese açık sayılır.
    if (prev) {
      prev.localOnly &&= loopback;
      prev.process ??= m?.[1] ?? null;
      continue;
    }
    byPort.set(port, { port, address, process: m?.[1] ?? null, pid: m ? Number(m[2]) : null, localOnly: loopback });
  }
  return [...byPort.values()].sort((a, b) => a.port - b.port);
}

/** tailscale serve status --json → paylaşılan https portları (port → hedef). */
export function parseServe(json: string): Map<number, string> {
  const out = new Map<number, string>();
  try {
    const j = JSON.parse(json || "{}") as { Web?: Record<string, { Handlers?: Record<string, { Proxy?: string }> }> };
    for (const [hostPort, v] of Object.entries(j.Web ?? {})) {
      const port = Number(hostPort.slice(hostPort.lastIndexOf(":") + 1));
      const proxy = v.Handlers?.["/"]?.Proxy;
      if (proxy) out.set(port, proxy);
    }
  } catch {
    /* boş */
  }
  return out;
}

async function dnsName(): Promise<string | null> {
  const r = await run("tailscale", ["status", "--self", "--peers=false", "--json"], { allowFail: true, timeoutMs: 8000 });
  try {
    return ((JSON.parse(r.stdout) as { Self?: { DNSName?: string } }).Self?.DNSName ?? "").replace(/\.$/, "") || null;
  } catch {
    return null;
  }
}

const RESERVED = new Set([7443]);

export function portRoutes(app: FastifyInstance, _ctx: Ctx) {
  app.get("/v1/ports", async () => {
    const [ss, serve, dns] = await Promise.all([
      run("ss", ["-ltnpH"], { allowFail: true }),
      run("tailscale", ["serve", "status", "--json"], { allowFail: true, timeoutMs: 8000 }),
      dnsName(),
    ]);
    const shared = parseServe(serve.stdout);
    return {
      host: dns,
      ports: parseSs(ss.stdout).map((p) => {
        const target = shared.get(p.port);
        const url = dns ? (target ? `https://${dns}:${p.port}` : p.localOnly ? null : `http://${dns}:${p.port}`) : null;
        return { ...p, shared: !!target, url, reserved: RESERVED.has(p.port) };
      }),
    };
  });

  app.post("/v1/ports/:port/share", async (req) => {
    const port = z.coerce.number().int().min(1).max(65535).parse((req.params as Record<string, string>).port);
    if (RESERVED.has(port)) throw new AppError("agent.ports.reserved", 400, { port });
    const listening = parseSs((await run("ss", ["-ltnpH"], { allowFail: true })).stdout).find((p) => p.port === port);
    if (!listening) throw new AppError("agent.ports.notListening", 404, { port });
    if (!listening.localOnly) throw new AppError("agent.ports.alreadyPublic", 409, { port });
    const r = await run("tailscale", ["serve", "--bg", `--https=${port}`, `http://127.0.0.1:${port}`], { allowFail: true, timeoutMs: 20000 });
    if (r.code !== 0) throw new AppError("agent.ports.shareFailed", 502, { stderr: (r.stderr || r.stdout).slice(0, 1000) });
    const dns = await dnsName();
    return { ok: true, url: dns ? `https://${dns}:${port}` : null };
  });

  app.delete("/v1/ports/:port/share", async (req) => {
    const port = z.coerce.number().int().min(1).max(65535).parse((req.params as Record<string, string>).port);
    if (RESERVED.has(port)) throw new AppError("agent.ports.reserved", 400, { port });
    const r = await run("tailscale", ["serve", `--https=${port}`, "off"], { allowFail: true, timeoutMs: 20000 });
    if (r.code !== 0) throw new AppError("agent.ports.shareFailed", 502, { stderr: (r.stderr || r.stdout).slice(0, 1000) });
    return { ok: true };
  });
}
