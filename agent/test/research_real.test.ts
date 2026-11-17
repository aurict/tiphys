// One tiny research job with the real agy + claude (uses the user's subscriptions). Run with TIPHYS_REAL=1.
import { mkdtemp } from "node:fs/promises";
import { homedir, tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { ResearchService, type Job } from "../src/research/jobs.ts";
import { normalizeUrl } from "../src/research/streams.ts";
import { jobInputSchema } from "../src/research/schema.ts";

const real = process.env.TIPHYS_REAL === "1";

describe.skipIf(!real)("research (real agy + claude)", () => {
  it(
    "son 24 saatin 1 yapay zekâ haberi, editor on",
    async () => {
      const dir = await mkdtemp(join(tmpdir(), "tiphys-research-real-"));
      const svc = await ResearchService.open({
        root: join(dir, "work"),
        statePath: null,
        claudeJsonPath: join(homedir(), ".claude.json"),
        jobTimeoutMs: 20 * 60_000,
        killGraceMs: 5000,
        retentionMs: 24 * 3600_000,
        maxWaiting: 5,
        log: (level, msg, extra) => console.log(level, msg, JSON.stringify(extra ?? {})),
      });
      const started = Date.now();
      const job = svc.submit(jobInputSchema.parse({ topic: "son 24 saatin 1 yapay zekâ haberi", windowHours: 24, minItems: 1, maxItems: 1, editor: true }), "test");
      let j: Job | undefined;
      while ((j = svc.get(job.id)) && j.status !== "done" && j.status !== "failed") await new Promise((r) => setTimeout(r, 2000));
      console.log(`research job: ${Math.round((Date.now() - started) / 1000)} s`, JSON.stringify(j, null, 2));
      await svc.close();
      expect(j?.error).toBeUndefined();
      expect(j?.status).toBe("done");
      expect(j!.result!.items.length).toBeGreaterThanOrEqual(1);
      const seen = new Set(j!.result!.seenUrls);
      for (const s of j!.result!.items.flatMap((i) => i.sources)) expect(seen.has(normalizeUrl(s.url)!), s.url).toBe(true);
    },
    21 * 60_000,
  );
});
