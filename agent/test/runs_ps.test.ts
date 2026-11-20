// GET /v1/agent/status memory: works without `ps` (minimal container images such as debian:12).
import { describe, expect, it } from "vitest";
import { AppError } from "../src/errors.ts";
import { treeRss } from "../src/runs.ts";

describe("treeRss", () => {
  it("sums the children from ps", async () => {
    const exec = (async () => ({ stdout: "10 1 1000\n11 10 200\n12 11 300\n13 1 999\n", stderr: "", code: 0 })) as never;
    expect(await treeRss(10, exec)).toEqual({ selfBytes: 1000 * 1024, childrenBytes: 500 * 1024 });
  });

  it("without ps: this process only", async () => {
    const exec = (async () => {
      throw new AppError("agent.exec.commandMissing", 500, { command: "ps" });
    }) as never;
    const r = await treeRss(process.pid, exec);
    expect(r.childrenBytes).toBe(0);
    expect(r.selfBytes).toBeGreaterThan(0);
  });
});
