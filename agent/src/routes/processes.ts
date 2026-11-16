// Processes: top CPU/memory users, sending signals (with confirmation). Comes with the "system" feature.
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { run } from "../exec.ts";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

export interface Proc {
  pid: number;
  ppid: number;
  user: string;
  cpuPercent: number;
  memPercent: number;
  rssBytes: number;
  elapsedSeconds: number;
  name: string;
  command: string;
}

export function parsePs(out: string): Proc[] {
  return out
    .split("\n")
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => {
      const f = l.split(/\s+/);
      const [pid, ppid, user, cpu, mem, rss, etimes, name] = f;
      return {
        pid: Number(pid),
        ppid: Number(ppid),
        user: user ?? "",
        cpuPercent: Number(cpu),
        memPercent: Number(mem),
        rssBytes: Number(rss) * 1024,
        elapsedSeconds: Number(etimes),
        name: name ?? "",
        command: f.slice(8).join(" ").slice(0, 500),
      };
    })
    .filter((p) => Number.isFinite(p.pid));
}

const query = z.object({
  sort: z.enum(["cpu", "mem"]).default("cpu"),
  limit: z.coerce.number().int().min(1).max(500).default(80),
});
const signalBody = z.object({ signal: z.enum(["TERM", "KILL", "INT", "HUP"]).default("TERM"), confirm: z.literal(true) });

export function processRoutes(app: FastifyInstance, _ctx: Ctx) {
  app.get("/v1/processes", async (req) => {
    const q = query.parse(req.query);
    const { stdout } = await run("ps", [
      "-eo",
      "pid=,ppid=,user=,pcpu=,pmem=,rss=,etimes=,comm=,args=",
      `--sort=${q.sort === "cpu" ? "-pcpu" : "-rss"}`,
    ]);
    const all = parsePs(stdout);
    return { total: all.length, processes: all.slice(0, q.limit) };
  });

  app.post("/v1/processes/:pid/signal", async (req) => {
    const pid = z.coerce.number().int().min(2).parse((req.params as Record<string, string>).pid);
    const parsed = signalBody.safeParse(req.body);
    if (!parsed.success) throw new AppError("agent.processes.confirmRequired", 400);
    if (pid === process.pid) throw new AppError("agent.processes.self", 400, { pid });
    try {
      process.kill(pid, `SIG${parsed.data.signal}` as NodeJS.Signals);
    } catch (e) {
      const code = (e as NodeJS.ErrnoException).code;
      if (code === "ESRCH") throw new AppError("agent.processes.notFound", 404, { pid });
      if (code === "EPERM") throw new AppError("agent.processes.permissionDenied", 403, { pid });
      throw e;
    }
    return { ok: true };
  });
}
