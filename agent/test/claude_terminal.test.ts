// Detecting Claude Code sessions open in a terminal (with a fake /proc and a fake sessions folder).
import { mkdir, mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { terminalSessions } from "../src/claude/terminal.ts";

/** /proc/<pid>/stat: field 22 is the start time. The command name may contain spaces and parentheses. */
const stat = (pid: number, start: number) =>
  `${pid} (claude (code) x) S 1 ${Array.from({ length: 17 }, (_, i) => i + 5).join(" ")} ${start} 0 0\n`;

describe("terminal oturumları", () => {
  it("yalnız yaşayan ve aynı süreç olan oturumları döner", async () => {
    const root = await mkdtemp(join(tmpdir(), "tiphys-term-"));
    const cfg = join(root, "claude");
    const proc = join(root, "proc");
    await mkdir(join(cfg, "sessions"), { recursive: true });
    const session = (pid: number, extra: Record<string, unknown>) =>
      writeFile(join(cfg, "sessions", `${pid}.json`), JSON.stringify({ pid, sessionId: `0000000${pid}-aaaa-4aaa-8aaa-aaaaaaaaaaaa`, cwd: "/home/x", status: "busy", name: "x-1", startedAt: 1_700_000_000_000, updatedAt: 1_700_000_100_000, ...extra }));
    for (const [pid, start] of [[1, 500], [2, 600]] as const) {
      await mkdir(join(proc, String(pid)), { recursive: true });
      await writeFile(join(proc, String(pid), "stat"), stat(pid, start));
    }
    await session(1, { procStart: "500" }); // alive
    await session(2, { procStart: "999" }); // the pid now belongs to another process
    await session(3, { procStart: "1" }); // no process
    await writeFile(join(cfg, "sessions", "4.json"), "{bozuk"); // half-written
    await writeFile(join(cfg, "sessions", "1.abc.key"), "x"); // unrelated file

    const list = await terminalSessions(cfg, proc);
    expect(list).toEqual([
      {
        pid: 1,
        sdkSessionId: "00000001-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
        cwd: "/home/x",
        name: "x-1",
        status: "busy",
        startedAt: new Date(1_700_000_000_000).toISOString(),
        updatedAt: new Date(1_700_000_100_000).toISOString(),
      },
    ]);
  });

  it("sessions klasörü yoksa boş liste", async () => {
    expect(await terminalSessions(join(tmpdir(), "yok-boyle-bir-klasor"))).toEqual([]);
  });
});
