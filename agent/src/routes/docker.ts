// Docker containers: list, stats, start/stop/restart, logs (via the docker CLI).
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { run } from "../exec.ts";
import type { Ctx } from "../server.ts";

const containerId = z.string().regex(/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/);
const action = z.enum(["start", "stop", "restart"]);

/** "docker" on Linux; on macOS/Windows also Docker Desktop's own copy when it is not on the agent's PATH. */
async function docker(): Promise<string> {
  if (process.platform !== "darwin" && process.platform !== "win32") return "docker";
  return (await import("../platform/common.ts")).dockerBin();
}

export function parseJsonLines<T>(out: string): T[] {
  return out
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => JSON.parse(l) as T);
}

export function dockerRoutes(app: FastifyInstance, _ctx: Ctx) {
  app.get("/v1/docker/containers", async () => {
    const bin = await docker();
    const [ps, stats] = await Promise.all([
      run(bin, ["ps", "-a", "--no-trunc", "--format", "{{json .}}"]),
      run(bin, ["stats", "--no-stream", "--format", "{{json .}}"], { timeoutMs: 30000, allowFail: true }),
    ]);
    const statById = new Map(
      parseJsonLines<Record<string, string>>(stats.stdout).map((s) => [s.Name ?? "", s] as const),
    );
    return {
      containers: parseJsonLines<Record<string, string>>(ps.stdout).map((c) => {
        const st = statById.get(c.Names ?? "");
        return {
          id: c.ID,
          name: c.Names,
          image: c.Image,
          state: c.State,
          status: c.Status,
          project: /com\.docker\.compose\.project=([^,]+)/.exec(c.Labels ?? "")?.[1] ?? null,
          cpuPercent: st ? Number.parseFloat(st.CPUPerc ?? "") || 0 : null,
          memory: st?.MemUsage ?? null,
        };
      }),
    };
  });

  app.post("/v1/docker/containers/:id/:action", async (req) => {
    const p = req.params as Record<string, string>;
    await run(await docker(), [action.parse(p.action), containerId.parse(p.id)], { timeoutMs: 90000 });
    return { ok: true };
  });

  app.get("/v1/docker/containers/:id/logs", async (req) => {
    const id = containerId.parse((req.params as Record<string, string>).id);
    const tail = z.coerce.number().int().min(1).max(5000).default(300).parse((req.query as Record<string, unknown>).tail);
    const res = await run(await docker(), ["logs", "--tail", String(tail), "--timestamps", id], { timeoutMs: 30000 });
    // docker logs emits stdout and stderr on separate streams; the two are merged by timestamp.
    const lines = [
      ...res.stdout.split("\n").map((l) => ({ stream: "stdout", l })),
      ...res.stderr.split("\n").map((l) => ({ stream: "stderr", l })),
    ]
      .filter((x) => x.l)
      .map(({ stream, l }) => {
        const sp = l.indexOf(" ");
        return { time: l.slice(0, sp), stream, message: l.slice(sp + 1) };
      })
      .sort((a, b) => a.time.localeCompare(b.time));
    return { id, lines };
  });
}
