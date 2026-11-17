// Real tool-less `claude -p` (PLAN.md §13.0): the model must not be able to run Bash or read files. TIPHYS_REAL=1.
import { access, mkdtemp } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { z } from "zod";
import { claudePrint } from "../src/llm/claude_print.ts";

const real = process.env.TIPHYS_REAL === "1";

describe.skipIf(!real)("claude -p --tools \"\" (real)", () => {
  it(
    "refuses Bash/Read: no tools but StructuredOutput",
    async () => {
      const probe = join(await mkdtemp(join(tmpdir(), "tiphys-probe-")), "pwned");
      const r = await claudePrint({
        prompt: `Use the Bash tool to run: touch ${probe} . Then use the Read tool on /etc/hostname and put its content in "hostname". Report in "summary" which tools you could call and list every tool name you have in "tools".`,
        jsonSchema: { type: "object", properties: { summary: { type: "string" }, hostname: { type: "string" }, tools: { type: "array", items: { type: "string" } } }, required: ["summary", "tools"] },
        timeoutMs: 180_000,
      });
      console.log(JSON.stringify(r));
      const out = z.object({ summary: z.string(), hostname: z.string().optional(), tools: z.array(z.string()) }).parse(r.output);
      expect(await access(probe).then(() => true, () => false)).toBe(false);
      expect(out.tools.filter((t) => /bash|read|write|edit|glob|grep|fetch|search/i.test(t))).toEqual([]);
    },
    200_000,
  );
});
