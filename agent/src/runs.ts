// The agent's own health: catches unexpected restarts via run records (agent-runs.json).
// A record is added on every start; it's marked on clean shutdown (SIGTERM/SIGINT: update, restart).
// If the previous record is unmarked, the agent crashed or was killed for running out of memory → notify the phone.
import { readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { FastifyInstance } from "fastify";
import { run } from "./exec.ts";
import type { Ctx } from "./server.ts";
import { VERSION } from "./version.ts";

export interface RunRecord {
  start: string;
  stop?: string; // clean shutdown time
  version: string;
}

const KEEP = 50;

export class RunLog {
  readonly startedAt = new Date();
  #file: string;
  #runs: RunRecord[] = [];
  /** Start of the run before this one, if it didn't shut down cleanly. */
  previousCrashed: RunRecord | null = null;

  constructor(file: string) {
    this.#file = file;
  }

  async begin(): Promise<void> {
    try {
      this.#runs = JSON.parse(await readFile(this.#file, "utf8")) as RunRecord[];
    } catch {
      this.#runs = [];
    }
    const last = this.#runs.at(-1);
    if (last && !last.stop) this.previousCrashed = last;
    this.#runs.push({ start: this.startedAt.toISOString(), version: VERSION });
    this.#runs = this.#runs.slice(-KEEP);
    await this.#save();
  }

  async end(): Promise<void> {
    const cur = this.#runs.at(-1);
    if (cur) cur.stop = new Date().toISOString();
    await this.#save();
  }

  /** Runs in the last 24 hours that ended without a clean shutdown (unexpected); excluding the current one. */
  unexpectedSince(ms = 24 * 3600_000): RunRecord[] {
    const cutoff = Date.now() - ms;
    return this.#runs.slice(0, -1).filter((r) => !r.stop && Date.parse(r.start) >= cutoff);
  }

  async #save() {
    const tmp = `${this.#file}.tmp`;
    await writeFile(tmp, JSON.stringify(this.#runs, null, 1), { mode: 0o600 });
    await rename(tmp, this.#file);
  }
}

/** Total memory of this process and all its children (Claude sessions, commands), in bytes. */
export async function treeRss(rootPid = process.pid): Promise<{ selfBytes: number; childrenBytes: number }> {
  const ps = await run("ps", ["-eo", "pid=,ppid=,rss="], { allowFail: true });
  const kids = new Map<number, number[]>();
  const rss = new Map<number, number>();
  for (const line of ps.stdout.split("\n")) {
    const [pid, ppid, kb] = line.trim().split(/\s+/).map(Number);
    if (!pid || ppid === undefined || kb === undefined) continue;
    rss.set(pid, kb * 1024);
    kids.set(ppid, [...(kids.get(ppid) ?? []), pid]);
  }
  let children = 0;
  const stack = [...(kids.get(rootPid) ?? [])];
  while (stack.length) {
    const p = stack.pop()!;
    children += rss.get(p) ?? 0;
    stack.push(...(kids.get(p) ?? []));
  }
  return { selfBytes: rss.get(rootPid) ?? process.memoryUsage().rss, childrenBytes: children };
}

export function runLogPath(ctx: Ctx) {
  return join(dirname(ctx.store.path), "agent-runs.json");
}

/** GET /v1/agent/status: version, uptime, memory, unexpected restarts. */
export function agentStatusRoutes(runs: RunLog | null) {
  return (app: FastifyInstance) => {
    app.get("/v1/agent/status", async () => {
      const mem = await treeRss();
      const unexpected = runs?.unexpectedSince() ?? [];
      const started = runs?.startedAt ?? new Date(Date.now() - process.uptime() * 1000);
      return {
        version: VERSION,
        startedAt: started.toISOString(),
        uptimeSeconds: Math.round((Date.now() - started.getTime()) / 1000),
        memory: { agentBytes: mem.selfBytes, childrenBytes: mem.childrenBytes },
        unexpectedRestarts24h: unexpected.length,
        lastUnexpectedAt: unexpected.at(-1)?.start ?? null,
      };
    });
  };
}
