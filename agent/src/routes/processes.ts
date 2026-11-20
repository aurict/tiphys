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
    if (process.platform === "darwin" || process.platform === "win32") {
      const { platformImpl } = await import("../platform/support.ts");
      const all = await (await platformImpl()).listProcesses();
      all.sort(q.sort === "cpu" ? (a, b) => b.cpuPercent - a.cpuPercent : (a, b) => b.rssBytes - a.rssBytes);
      return { total: all.length, processes: all.slice(0, q.limit) };
    }
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
    if (process.platform === "win32") {
      // Windows has no signals: TERM = taskkill (asks to close), KILL = forced; INT/HUP are reported unsupported.
      const { unsupported } = await import("../platform/support.ts");
      const sig = parsed.data.signal;
      if (sig !== "TERM" && sig !== "KILL") throw unsupported(`processes.signal.${sig}`); // listed in support.ts
      await (await import("../platform/win32.ts")).signalProcess(pid, sig);
      return { ok: true };
    }
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
