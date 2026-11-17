import { chmod, mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { hashToken, newToken } from "../src/auth.ts";
import { ConfigStore } from "../src/config.ts";
import { EventLog, eventsPath } from "../src/events.ts";
import { Notifier } from "../src/notify.ts";
import { cleanItems, ResearchService, type Job } from "../src/research/jobs.ts";
import { childEnv } from "../src/llm/claude_print.ts";
import { normalizeUrl, toolUrls } from "../src/research/streams.ts";
import { jobInputSchema } from "../src/research/schema.ts";
import { buildApp } from "../src/server.ts";
import { createServiceToken, serviceTokenCli } from "../src/service_tokens.ts";

const FAKE = new URL("./fake_research_tool.mjs", import.meta.url).pathname;
const origPath = process.env.PATH;
let binDir = "";

beforeAll(async () => {
  binDir = await mkdtemp(join(tmpdir(), "tiphys-fakebin-"));
  for (const tool of ["agy", "claude"]) {
    // The agent passes only allowlisted variables, so the wrapper tells the fake where the current test dir is.
    await writeFile(join(binDir, tool), `#!/bin/sh\nFAKE_RESEARCH_DIR="$(cat "${binDir}/current")" exec "${process.execPath}" "${FAKE}" ${tool} "$@"\n`);
    await chmod(join(binDir, tool), 0o755);
  }
  process.env.PATH = `${binDir}:${origPath}`;
  process.env.TIPHYS_TEST_SECRET = "must-not-leak";
  process.env.SOME_API_KEY = "must-not-leak-either";
});

afterAll(() => {
  process.env.PATH = origPath;
  delete process.env.TIPHYS_TEST_SECRET;
  delete process.env.SOME_API_KEY;
});

type Tool = { server: string; tool: string; args?: Record<string, unknown>; output: string; failed?: boolean };
type Step = { mode: "ok" | "error" | "invalid" | "hang" | "stubborn" | "denied"; output?: unknown; notes?: string; exitCode?: number; tools?: Tool[] };

const ENV_ALLOWED = /^(HOME|PATH|LANG|LANGUAGE|USER|LOGNAME|TERM|TZ|XDG_(RUNTIME_DIR|CONFIG_HOME|CACHE_HOME|DATA_HOME|STATE_HOME)|NODE_EXTRA_CA_CERTS|LC_\w+)$/;
/** searxng_web_search text format (each value on one line). */
const searx = (...rs: Array<{ title: string; url: string; desc?: string }>) =>
  rs.map((r) => `Title: ${r.title}\nDescription: ${r.desc ?? "Açıklama"}\nURL: ${r.url}\nRelevance Score: 1.000`).join("\n\n");
const scrape = (markdown: string, metadata: Record<string, unknown> = { statusCode: 200 }) => JSON.stringify({ markdown, metadata });

const src = (url: string, title = "Kaynak") => ({ title, url });
const item = (headline: string, ...urls: string[]) => ({ headline, summary: `${headline} özeti.`, published: "2026-11-17T07:00:00+03:00", sources: urls.map((u) => src(u)) });

async function setup(scenario: { agy?: Step[]; claude?: Step[] }, o: { jobTimeoutMs?: number } = {}) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-research-"));
  await writeFile(join(binDir, "current"), dir);
  await writeFile(join(dir, "scenario.json"), JSON.stringify(scenario));
  const claudeJsonPath = join(dir, "claude.json");
  await writeFile(
    claudeJsonPath,
    JSON.stringify({
      mcpServers: {
        searxng: { type: "stdio", command: "npx", args: ["mcp-searxng"], env: { SEARXNG_URL: "https://searx.example" } },
        firecrawl: { type: "stdio", command: "npx", args: ["firecrawl-mcp"], env: { FIRECRAWL_API_KEY: "fc-very-secret" } },
        docs: { type: "http", url: "https://docs.example/mcp" },
      },
    }),
  );
  const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "test");
  const deviceToken = newToken();
  await store.update((c) => {
    c.features.research = true;
    c.devices.push({ id: "phone", name: "Telefon", tokenHash: hashToken(deviceToken), createdAt: new Date().toISOString() });
    return c;
  });
  const { token: serviceToken, serviceToken: st } = await createServiceToken(store, "atlas", ["research"]);
  const research = await ResearchService.open({
    root: join(dir, "work"),
    statePath: join(dir, "research-jobs.json"),
    claudeJsonPath,
    jobTimeoutMs: o.jobTimeoutMs ?? 15_000,
    killGraceMs: 300,
    retentionMs: 24 * 3600_000,
    maxWaiting: 5,
    log: () => {},
  });
  const notifier = new Notifier(() => store.get(), () => {}, new EventLog(eventsPath(store.path)));
  const app = await buildApp({ store, notifier, research });
  const device = { authorization: `Bearer ${deviceToken}` };
  const service = { authorization: `Bearer ${serviceToken}` };
  const calls = async () =>
    (await readFile(join(dir, "calls.jsonl"), "utf8").catch(() => ""))
      .split("\n")
      .filter(Boolean)
      .map(
        (l) =>
          JSON.parse(l) as {
            tool: string;
            n: number;
            args: string[];
            cwd: string;
            envKeys: string[];
            cwdFiles: string[];
            mcp?: { mcpServers: Record<string, { type: string; command: string; args: string[]; env: Record<string, string> }> };
            draft?: { items: unknown[] };
          },
      );
  const submit = async (body: Record<string, unknown> = {}, headers = service) =>
    app.inject({ method: "POST", url: "/v1/research/jobs", headers, payload: { topic: "yapay zekâ haberleri", windowHours: 24, maxItems: 5, ...body } });
  const waitDone = async (id: string, headers = service): Promise<Job> => {
    for (let i = 0; i < 300; i++) {
      const j = (await app.inject({ url: `/v1/research/jobs/${id}`, headers })).json() as Job;
      if (j.status === "done" || j.status === "failed") return j;
      await new Promise((r) => setTimeout(r, 50));
    }
    throw new Error("job did not finish");
  };
  const waitRunning = async (tool = "agy", n = 0) => {
    for (let i = 0; i < 200; i++) {
      const p = await readFile(join(dir, `pids-${tool}-${n}.json`), "utf8").catch(() => null);
      if (p) return JSON.parse(p) as number[];
      await new Promise((r) => setTimeout(r, 25));
    }
    throw new Error("tool did not start");
  };
  return { dir, store, app, research, device, service, serviceToken, st, calls, submit, waitDone, waitRunning };
}

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};
async function expectDead(pids: number[]) {
  for (let i = 0; i < 40 && pids.some(alive); i++) await new Promise((r) => setTimeout(r, 50));
  expect(pids.filter(alive)).toEqual([]);
}

describe("research pipeline", () => {
  it("happy path: agy draft, claude edit, merged seenUrls, safe arguments", async () => {
    const draft = {
      items: [item("Bir", "https://a.example/1"), item("İki", "https://b.example/2"), item("Gönderilmiş", "https://old.example/x"), item("Yasak", "https://bad.example/y")],
      seenUrls: ["https://a.example/1", "https://b.example/2", "https://search.example/q"],
    };
    const edited = { items: [item("Bir (düzeltildi)", "https://a.example/1", "javascript:alert(1)"), item("Yasak", "https://bad.example/y")], seenUrls: ["https://c.example/verify"], followups: [] };
    const agyTools: Tool[] = [
      {
        server: "searxng",
        tool: "searxng_web_search",
        args: { query: "ai" },
        output: searx({ title: "Bir", url: "https://a.example/1/?utm_source=x#top", desc: "see URL: https://in-desc.example/x" }, { title: "İki", url: "https://b.example/2" }, { title: "Ara", url: "https://search.example/q" }),
      },
      { server: "firecrawl", tool: "firecrawl_scrape", args: { url: "https://scraped.example/page" }, output: scrape("[link](https://inpage.example/a)\nURL: https://inpage.example/b") },
      { server: "firecrawl", tool: "firecrawl_scrape", args: { url: "https://failed.example/p" }, output: "fetch failed https://failed-out.example/x", failed: true },
      { server: "firecrawl", tool: "firecrawl_map", args: { url: "https://mapped.example/" }, output: '{"links":[{"url":"https://mapped.example/a"}]}' },
      { server: "other", tool: "x", output: "https://other-server.example/x" },
    ];
    const claudeTools: Tool[] = [
      { server: "firecrawl", tool: "firecrawl_scrape", args: { url: "https://c.example/verify" }, output: scrape("ok, body text https://c-body.example/x", { statusCode: 200, url: "https://c.example/verify-final" }) },
      { server: "searxng", tool: "web_url_read", args: { url: "https://claude-failed.example/" }, output: "https://claude-failed-out.example", failed: true },
    ];
    const t = await setup({
      agy: [{ mode: "ok", output: draft, notes: "not: https://notes.example/page bakıldı", tools: agyTools }],
      claude: [{ mode: "ok", output: edited, tools: claudeTools }],
    });
    const res = await t.submit({ excludeUrls: ["https://old.example/x"], blockDomains: ["bad.example"], instructions: "Türkçe yaz" });
    expect(res.statusCode).toBe(202);
    const job = await t.waitDone(res.json().id);
    expect(job.status).toBe("done");
    expect(job.result!.items).toEqual([{ ...item("Bir (düzeltildi)", "https://a.example/1") }]);
    // seenUrls: only structured fields of successful allowed tool calls (search result URLs, requested/final page
    // URLs), normalized; nothing from page text, descriptions, failed or disallowed calls.
    expect(job.result!.seenUrls.sort()).toEqual(
      ["https://a.example/1", "https://b.example/2", "https://search.example/q", "https://scraped.example/page", "https://c.example/verify", "https://c.example/verify-final"].sort(),
    );
    expect(job.result!.models).toEqual({ research: "gemini-4-argon-high", editor: "claude-sonnet" });
    expect(job.result!.timings).toMatchObject({ researchSec: expect.any(Number), editorSec: expect.any(Number) });
    expect(job).not.toHaveProperty("input");

    const workDir = join(t.dir, "work", job.id);
    expect((await stat(workDir)).mode & 0o777).toBe(0o700);
    const [agy, claude] = await t.calls();
    // agy: verified flags, no permission bypass, commands denied.
    expect(agy!.cwd).toBe(workDir);
    expect(agy!.args).not.toContain("--dangerously-skip-permissions");
    const a = (flag: string) => agy!.args[agy!.args.indexOf(flag) + 1];
    expect(a("--model")).toBe("gemini-4-argon-high");
    expect(a("--add-dir")).toBe(workDir);
    expect(a("--project")).toBe("tiphys-research");
    expect(a("--output-format")).toBe("stream-json");
    expect(a("--json-schema")).toBe(join(workDir, "draft.schema.json"));
    expect(a("--print-timeout")).toBe("15m");
    // Only the four web tools; no server-wide wildcard.
    expect(JSON.parse(a("--settings")!)).toEqual({
      permissions: {
        allow: ["mcp(searxng/searxng_web_search)", "mcp(searxng/web_url_read)", "mcp(firecrawl/firecrawl_search)", "mcp(firecrawl/firecrawl_scrape)", `write_file(${workDir})`],
        deny: ["command(*)"],
      },
    });
    expect(a("-p")).toContain("yapay zekâ haberleri");
    expect(a("-p")).toContain("https://old.example/x");
    expect(a("-p")).toContain("bad.example");
    // Allowlisted environment only.
    for (const call of [agy!, claude!]) {
      expect(call.envKeys.filter((k) => !ENV_ALLOWED.test(k))).toEqual([]);
      expect(call.envKeys).toContain("PATH");
    }
    // claude: no user settings, strict MCP with only the two pinned servers passed inline (no file in the job dir).
    const c = (flag: string) => claude!.args[claude!.args.indexOf(flag) + 1];
    expect(claude!.args).not.toContain("--dangerously-skip-permissions");
    expect(c("--setting-sources")).toBe("");
    expect(claude!.args).toContain("--strict-mcp-config");
    expect(claude!.mcp).toEqual({
      mcpServers: {
        searxng: { type: "stdio", command: "npx", args: ["-y", "mcp-searxng@2.10.1"], env: { SEARXNG_URL: "https://searx.example" } },
        firecrawl: { type: "stdio", command: "npx", args: ["-y", "firecrawl-mcp@3.40.0"], env: { FIRECRAWL_API_KEY: "fc-very-secret" } },
      },
    });
    for (const call of [agy!, claude!]) expect(call.cwdFiles.filter((f) => f.includes("mcp"))).toEqual([]);
    const i = claude!.args.indexOf("--tools");
    expect(claude!.args.slice(i + 1, i + 3)).toEqual(["Read", "Write"]);
    const j = claude!.args.indexOf("--allowedTools");
    expect(claude!.args.slice(j + 1, j + 9)).toEqual([
      "mcp__searxng__searxng_web_search",
      "mcp__searxng__web_url_read",
      "mcp__firecrawl__firecrawl_search",
      "mcp__firecrawl__firecrawl_scrape",
      `Read(/${workDir}/**)`,
      `Edit(/${workDir}/**)`,
      "--permission-mode",
      "default",
    ]);
    // The prompts name exactly the allowed tools.
    expect(a("-p")).toContain("searxng_web_search (searxng MCP server), web_url_read (searxng MCP server), firecrawl_search (firecrawl MCP server), firecrawl_scrape (firecrawl MCP server)");
    expect(c("--permission-mode")).toBe("default");
    expect(c("--model")).toBe("sonnet");
    expect(c("--output-format")).toBe("stream-json");
    expect(claude!.args).toContain("--verbose");
    expect(JSON.parse(c("--json-schema")!).properties).toHaveProperty("followups");
    expect(claude!.draft!.items).toHaveLength(4);
    // No MCP secrets anywhere in the job dir or the state file.
    await t.research.close();
    for (const f of ["draft.json", "draft.schema.json"]) expect(await readFile(join(workDir, f), "utf8")).not.toContain("fc-very-secret");
    const state = await readFile(join(t.dir, "research-jobs.json"), "utf8");
    expect(state).not.toContain("fc-very-secret");
    expect(state).not.toContain(t.serviceToken);
  });

  it("seenUrls never contain URLs that only the model wrote", async () => {
    const t = await setup({
      agy: [
        {
          mode: "ok",
          // The model claims both URLs (and its own seenUrls/notes), but only a.example appeared in a tool output.
          output: { items: [item("Gerçek", "https://a.example/1"), item("Uydurma", "https://invented.example/story")], seenUrls: ["https://invented.example/story"] },
          notes: "https://invented.example/story",
          tools: [
            { server: "searxng", tool: "searxng_web_search", output: searx({ title: "A", url: "https://a.example/1" }) },
            { server: "firecrawl", tool: "firecrawl_scrape", args: { url: "https://invented.example/story" }, output: "Error: 404", failed: true },
          ],
        },
      ],
    });
    const job = await t.waitDone((await t.submit({ editor: false })).json().id);
    expect(job.status).toBe("done");
    expect(job.result!.items).toHaveLength(2); // atlas drops the unverified one
    expect(job.result!.seenUrls).toEqual(["https://a.example/1"]);
  });

  it("editor off: only agy runs, its items are cleaned", async () => {
    const t = await setup({ agy: [{ mode: "ok", output: { items: [item("A", "https://a.example/1"), item("A kopya", "https://a.example/1/"), item("B", "ftp://b.example")], seenUrls: [] } }] });
    const job = await t.waitDone((await t.submit({ editor: false })).json().id);
    expect(job.status).toBe("done");
    expect(job.result!.items.map((x) => x.headline)).toEqual(["A"]);
    expect(job.result!.models).toEqual({ research: "gemini-4-argon-high" });
    expect((await t.calls()).map((x) => x.tool)).toEqual(["agy"]);
  });

  it("agy ERROR status fails the job", async () => {
    const t = await setup({ agy: [{ mode: "error" }] });
    const job = await t.waitDone((await t.submit()).json().id);
    expect(job).toMatchObject({ status: "failed", error: { code: "agent.research.toolFailed", params: { tool: "agy", status: "ERROR" } } });
  });

  it("invalid JSON: invalidOutput on exit 0, toolFailed on non-zero exit", async () => {
    const t = await setup({ agy: [{ mode: "invalid" }, { mode: "invalid", exitCode: 3 }, { mode: "ok", output: { nope: 1 } }] });
    const a = await t.waitDone((await t.submit()).json().id);
    expect(a.error).toEqual({ code: "agent.research.invalidOutput", params: { tool: "agy" } });
    const b = await t.waitDone((await t.submit()).json().id);
    expect(b.error).toEqual({ code: "agent.research.toolFailed", params: { tool: "agy", exitCode: 3 } });
    const c = await t.waitDone((await t.submit()).json().id);
    expect(c.error).toEqual({ code: "agent.research.invalidOutput", params: { tool: "agy" } });
  });

  it("claude error envelope fails the job", async () => {
    const t = await setup({ agy: [{ mode: "ok", output: { items: [item("A", "https://a.example/1")], seenUrls: [] } }], claude: [{ mode: "error" }] });
    const job = await t.waitDone((await t.submit()).json().id);
    expect(job.error).toEqual({ code: "agent.research.toolFailed", params: { tool: "claude", status: "error_max_turns" } });
  });

  it("agy ending the turn after a denied tool call fails with toolFailed/denied", async () => {
    const t = await setup({ agy: [{ mode: "denied" }] });
    const job = await t.waitDone((await t.submit()).json().id);
    expect(job.error).toEqual({ code: "agent.research.toolFailed", params: { tool: "agy", status: "denied" } });
  });

  it("child environment is an allowlist", () => {
    const keys = Object.keys(childEnv());
    expect(keys).toContain("PATH");
    expect(keys).not.toContain("TIPHYS_TEST_SECRET");
    expect(keys).not.toContain("SOME_API_KEY");
    expect(keys.filter((k) => !ENV_ALLOWED.test(k))).toEqual([]);
  });

  it("timeout kills the whole process group (SIGTERM, then SIGKILL)", async () => {
    const t = await setup({ agy: [{ mode: "stubborn" }] }, { jobTimeoutMs: 800 });
    const { id } = (await t.submit()).json();
    const pids = await t.waitRunning();
    const job = await t.waitDone(id);
    expect(job.error).toEqual({ code: "agent.research.timeout", params: {} });
    await expectDead(pids);
  });

  it("follow-up round: one extra agy run and a final editor pass", async () => {
    const t = await setup({
      agy: [
        { mode: "ok", output: { items: [item("A", "https://a.example/1"), item("Zayıf", "https://w.example/1")], seenUrls: [] } },
        { mode: "ok", output: { items: [item("B", "https://b.example/1"), item("C", "https://c.example/1")], seenUrls: ["https://b.example/1"] } },
      ],
      claude: [
        { mode: "ok", output: { items: [item("A", "https://a.example/1")], seenUrls: [], followups: ["Bugünkü model duyuruları?"] } },
        { mode: "ok", output: { items: [item("A", "https://a.example/1"), item("B", "https://b.example/1"), item("C", "https://c.example/1")], seenUrls: [], followups: ["yine"] } },
      ],
    });
    const job = await t.waitDone((await t.submit({ minItems: 3, maxItems: 5 })).json().id);
    expect(job.status).toBe("done");
    expect(job.result!.items.map((x) => x.headline)).toEqual(["A", "B", "C"]);
    const calls = await t.calls();
    expect(calls.map((x) => x.tool)).toEqual(["agy", "claude", "agy", "claude"]);
    const p2 = calls[2]!.args[calls[2]!.args.indexOf("-p") + 1]!;
    expect(p2).toContain("Bugünkü model duyuruları?");
    expect(p2).toContain("https://a.example/1");
    expect(calls[3]!.draft!.items).toHaveLength(3);
  });

  it("no follow-up round when the editor kept enough items", async () => {
    const t = await setup({
      agy: [{ mode: "ok", output: { items: [item("A", "https://a.example/1")], seenUrls: [] } }],
      claude: [{ mode: "ok", output: { items: [item("A", "https://a.example/1")], seenUrls: [], followups: ["daha?"] } }],
    });
    const job = await t.waitDone((await t.submit({ minItems: 1 })).json().id);
    expect(job.status).toBe("done");
    expect((await t.calls()).map((x) => x.tool)).toEqual(["agy", "claude"]);
  });

  it("cancel kills the running job's processes", async () => {
    const t = await setup({ agy: [{ mode: "hang" }] });
    const { id } = (await t.submit()).json();
    const pids = await t.waitRunning();
    // atlas (service token) cancels its own running job.
    const res = await t.app.inject({ method: "DELETE", url: `/v1/research/jobs/${id}`, headers: t.service });
    expect(res.json()).toMatchObject({ cancelled: true, job: { status: "failed", error: { code: "agent.research.cancelled" } } });
    await expectDead(pids);
    const again = await t.app.inject({ method: "DELETE", url: `/v1/research/jobs/${id}`, headers: t.device });
    expect(again.json().cancelled).toBe(false);
  });

  it("queue: 1 running + 5 waiting, then 429; shutdown interrupts all", async () => {
    const t = await setup({ agy: [{ mode: "hang" }] });
    const ids: string[] = [];
    for (let i = 0; i < 6; i++) {
      const r = await t.submit();
      expect(r.statusCode).toBe(202);
      ids.push(r.json().id);
    }
    const pids = await t.waitRunning();
    const busy = await t.submit();
    expect(busy.statusCode).toBe(429);
    expect(busy.json().error.code).toBe("agent.research.busy");
    const list = (await t.app.inject({ url: "/v1/research/jobs", headers: t.device })).json().jobs as Array<{ status: string; topic: string }>;
    expect(list.map((j) => j.status).sort()).toEqual(["queued", "queued", "queued", "queued", "queued", "running"]);
    expect(list[0]!.topic).toBe("yapay zekâ haberleri");
    // Cancelling a waiting job frees a slot.
    expect((await t.app.inject({ method: "DELETE", url: `/v1/research/jobs/${ids[5]}`, headers: t.device })).json().cancelled).toBe(true);
    expect((await t.submit()).statusCode).toBe(202);
    await t.app.close();
    await expectDead(pids);
    const state = JSON.parse(await readFile(join(t.dir, "research-jobs.json"), "utf8")) as { jobs: Job[] };
    expect(state.jobs.filter((j) => j.error?.code === "agent.research.interrupted")).toHaveLength(6);
    // Reloaded after a restart: results are still readable.
    const again = await ResearchService.open({ ...t.research.o });
    expect(again.get(ids[0]!)?.status).toBe("failed");
    await again.close();
  });

  it("missing executable fails with toolMissing", async () => {
    const t = await setup({});
    process.env.PATH = "/nonexistent";
    try {
      const { id } = (await t.submit()).json();
      const job = await t.waitDone(id);
      expect(job.error).toEqual({ code: "agent.research.toolMissing", params: { tool: "agy" } });
    } finally {
      process.env.PATH = `${binDir}:${origPath}`;
    }
  });

  it("validates input", async () => {
    const t = await setup({});
    for (const bad of [{ topic: "x".repeat(501) }, { windowHours: 0 }, { windowHours: 721 }, { maxItems: 21 }, { maxSourcesPerItem: 6 }, { minItems: 6, maxItems: 5 }, { allowDomains: ["not a domain"] }, { excludeUrls: ["ftp://x.example"] }, { instructions: "x".repeat(4001) }, { extra: 1 }]) {
      const r = await t.submit(bad);
      expect(r.statusCode, JSON.stringify(bad)).toBe(400);
    }
    expect(jobInputSchema.safeParse({ topic: "t", windowHours: 24, maxItems: 1, blockDomains: Array(51).fill("a.example") }).success).toBe(false);
  });

  it("sweep drops results and work dirs after 24 h", async () => {
    const t = await setup({ agy: [{ mode: "ok", output: { items: [item("A", "https://a.example/1")], seenUrls: [] } }] });
    const job = await t.waitDone((await t.submit({ editor: false })).json().id);
    await t.research.sweep(Date.now() + 23 * 3600_000);
    expect(t.research.get(job.id)).toBeDefined();
    await t.research.sweep(Date.now() + 25 * 3600_000);
    expect(t.research.get(job.id)).toBeUndefined();
    await expect(stat(join(t.dir, "work", job.id))).rejects.toThrow();
  });
});

describe("URL extraction", () => {
  it("only structured result fields of allowed tools count", () => {
    // searxng text format: only URL lines of Title/Description/URL blocks.
    expect(toolUrls("searxng", "searxng_web_search", {}, searx({ title: "x URL: https://t.example", url: "https://r.example/1", desc: "URL: https://d.example" }) + "\nURL: https://loose.example")).toEqual(["https://r.example/1"]);
    // searxng JSON format and firecrawl search: result URLs only, not scraped content in them.
    expect(toolUrls("searxng", "searxng_web_search", {}, JSON.stringify({ results: [{ url: "https://j.example/1", content: "https://c.example" }] }))).toEqual(["https://j.example/1"]);
    const fc = { success: true, data: { web: [{ url: "https://w.example/1", markdown: "https://md.example" }], news: [{ url: "https://n.example/1" }], images: [{ url: "https://i.example/1" }] } };
    expect(toolUrls("firecrawl", "firecrawl_search", { query: "q" }, JSON.stringify(fc))).toEqual(["https://w.example/1", "https://n.example/1"]);
    expect(toolUrls("firecrawl", "firecrawl_search", {}, "Results: https://free.example/text")).toEqual([]);
    // Page reads: the requested URL (+ final URL); never URLs in the page text; not on HTTP errors.
    expect(toolUrls("firecrawl", "firecrawl_scrape", { url: "https://p.example/a" }, scrape("see https://in.example/x", { statusCode: 200, url: "https://p.example/b" }))).toEqual(["https://p.example/a", "https://p.example/b"]);
    expect(toolUrls("firecrawl", "firecrawl_scrape", { url: "https://p.example/a" }, scrape("Not found", { statusCode: 404 }))).toEqual([]);
    expect(toolUrls("firecrawl", "firecrawl_scrape", { url: "https://p.example/a" }, "plain text https://in.example")).toEqual([]);
    expect(toolUrls("searxng", "web_url_read", { url: "https://r.example/a" }, "# Page\nhttps://in.example/y")).toEqual(["https://r.example/a"]);
    expect(toolUrls("searxng", "web_url_read", { url: "https://r.example/a" }, "Error: blocked")).toEqual([]);
    // Other tools of the same servers prove nothing.
    expect(toolUrls("firecrawl", "firecrawl_map", { url: "https://m.example" }, JSON.stringify({ links: [{ url: "https://m.example/a" }] }))).toEqual([]);
    expect(toolUrls("searxng", "constructor", { url: "https://m.example" }, "x")).toEqual([]);
  });

  it("normalizes; URLs over 2048 characters are ignored", () => {
    const long = `https://a.example/${"x".repeat(2040)}`;
    expect(normalizeUrl(long)).toBeNull();
    expect(cleanItems([item("Uzun", long)], jobInputSchema.parse({ topic: "t", windowHours: 24, maxItems: 2 }))).toEqual([]);
    expect(normalizeUrl("https://a.example/p/?utm_source=x&id=2&UTM_medium=y#frag")).toBe("https://a.example/p?id=2");
    expect(normalizeUrl("https://a.example")).toBe("https://a.example/");
    expect(normalizeUrl("javascript:alert(1)")).toBeNull();
  });
});

describe("cleanItems", () => {
  const base = jobInputSchema.parse({ topic: "t", windowHours: 24, maxItems: 2, maxSourcesPerItem: 1, allowDomains: ["ok.example"] });
  it("enforces allow list, source and item limits", () => {
    const out = cleanItems([item("A", "https://x.example/1", "https://news.ok.example/a", "https://ok.example/b"), item("B", "https://ok.example/c"), item("C", "https://ok.example/d")], base);
    expect(out.map((i) => [i.headline, i.sources.map((s) => s.url)])).toEqual([
      ["A", ["https://news.ok.example/a"]],
      ["B", ["https://ok.example/c"]],
    ]);
  });
});

describe("service tokens", () => {
  it("scope enforcement: a research token opens only research job routes", async () => {
    const t = await setup({ agy: [{ mode: "ok", output: { items: [], seenUrls: [] } }] });
    for (const [method, url] of [
      ["GET", "/v1/system"],
      ["GET", "/v1/config"],
      ["GET", "/v1/audit"],
      ["GET", "/v1/events"],
      ["GET", "/v1/service-tokens"],
      ["POST", "/v1/service-tokens"],
      ["GET", "/v1/research/jobs"],
      ["GET", "/v1/no-such-route"],
    ] as const) {
      const r = await t.app.inject({ method, url, headers: t.service, payload: method === "POST" ? {} : undefined });
      expect([url, r.statusCode, r.json().error?.code]).toEqual([url, 403, "agent.auth.scopeDenied"]);
    }
    // Health stays open; a service token in the query string is not accepted.
    expect((await t.app.inject({ url: "/v1/health" })).statusCode).toBe(200);
    expect((await t.app.inject({ url: `/v1/research/jobs/rj-0000000000000000?token=${t.serviceToken}` })).json().error.code).toBe("agent.auth.missingToken");
    // Service token may start and read its own jobs; the device may do everything.
    const mine = (await t.submit()).json().id as string;
    expect((await t.app.inject({ url: `/v1/research/jobs/${mine}`, headers: t.service })).statusCode).toBe(200);
    expect((await t.app.inject({ url: `/v1/research/jobs/${mine}`, headers: t.device })).statusCode).toBe(200);
    expect((await t.app.inject({ url: "/v1/system", headers: t.device })).statusCode).toBe(200);
    await t.waitDone(mine);
    const byDevice = await t.submit({}, t.device);
    expect(byDevice.statusCode).toBe(202);
    expect((await t.app.inject({ url: `/v1/research/jobs/${byDevice.json().id}`, headers: t.service })).statusCode).toBe(404);
    // Cancelling: only its own jobs (others look like they don't exist).
    await t.waitDone(byDevice.json().id, t.device);
    expect((await t.app.inject({ method: "DELETE", url: `/v1/research/jobs/${byDevice.json().id}`, headers: t.service })).statusCode).toBe(404);
    expect((await t.app.inject({ method: "DELETE", url: "/v1/research/jobs/rj-0000000000000000", headers: t.service })).statusCode).toBe(404);
    const own = await t.app.inject({ method: "DELETE", url: `/v1/research/jobs/${mine}`, headers: t.service });
    expect(own.statusCode).toBe(200);
    expect(own.json().cancelled).toBe(false); // already finished
    // Tailscale identity applies to service tokens too.
    await t.store.update((c) => ({ ...c, requireTailscaleLogin: "owner@example.com" }));
    expect((await t.app.inject({ url: `/v1/research/jobs/${mine}`, headers: t.service })).json().error.code).toBe("agent.auth.tailnetUserNotAllowed");
  });

  it("app routes create (token shown once), list and revoke; nothing logs the token", async () => {
    const t = await setup({});
    const created = await t.app.inject({ method: "POST", url: "/v1/service-tokens", headers: t.device, payload: { name: "atlas", scopes: ["research"] } });
    expect(created.statusCode).toBe(201);
    const { token, serviceToken } = created.json() as { token: string; serviceToken: { id: string } };
    expect(token).toMatch(/^tps_[A-Za-z0-9_-]{43}$/);
    expect(created.body).not.toContain("tokenHash");
    expect((await t.app.inject({ method: "POST", url: "/v1/service-tokens", headers: t.device, payload: { name: "x", scopes: ["desktop"] } })).statusCode).toBe(400);
    const list = await t.app.inject({ url: "/v1/service-tokens", headers: t.device });
    expect(list.json().tokens.map((x: { id: string }) => x.id)).toEqual([t.st.id, serviceToken.id]);
    expect(list.body).not.toContain("tokenHash");
    expect(list.body).not.toContain("tps_");
    // Usage is recorded (throttled) as lastUsedAt.
    const auth = { authorization: `Bearer ${token}` };
    expect((await t.submit({}, auth)).statusCode).toBe(202);
    await new Promise((r) => setTimeout(r, 100));
    expect(t.store.get().serviceTokens.find((x) => x.id === serviceToken.id)?.lastUsedAt).toBeDefined();
    const del = await t.app.inject({ method: "DELETE", url: `/v1/service-tokens/${serviceToken.id}`, headers: t.device });
    expect(del.json()).toEqual({ ok: true });
    expect((await t.app.inject({ method: "DELETE", url: `/v1/service-tokens/${serviceToken.id}`, headers: t.device })).statusCode).toBe(404);
    expect((await t.submit({}, auth)).json().error.code).toBe("agent.auth.invalidToken");
    await new Promise((r) => setTimeout(r, 100));
    const files = await Promise.all(["agent.json", "audit.jsonl", "events.jsonl"].map((f) => readFile(join(t.dir, f), "utf8")));
    for (const f of files) {
      expect(f).not.toContain(token);
      expect(f).not.toContain(t.serviceToken);
    }
    expect(files[1]).toContain(`"device":"service:${serviceToken.id}"`);
    expect(files[2]).toContain("serviceToken.created");
    expect(files[2]).toContain("serviceToken.revoked");
    await t.research.close();
  });

  it("lock everything revokes service tokens too", async () => {
    const t = await setup({});
    await t.app.inject({ method: "POST", url: "/v1/devices/revoke-all", headers: t.device, payload: { confirm: true } });
    expect(t.store.get().serviceTokens).toEqual([]);
  });

  it("CLI: service-token create / list / revoke", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-cli-"));
    const config = join(dir, "agent.json");
    await ConfigStore.loadOrCreate(config, "test");
    const cli = async (args: string[], o: { name?: string; scopes: string[] } = { scopes: [] }) =>
      (await serviceTokenCli(await ConfigStore.load(config), args, o)).join("\n");
    const created = await cli(["create"], { name: "atlas", scopes: ["research"] });
    const token = /Belirteç: (tps_\S+)/.exec(created)?.[1];
    expect(token).toBeDefined();
    const id = /\(([a-z0-9-]+)\)/.exec(created)?.[1]!;
    const saved = await readFile(config, "utf8");
    expect(saved).not.toContain(token!);
    expect(saved).toContain(hashToken(token!));
    expect(await cli(["list"])).toMatch(new RegExp(`^${id}\\tatlas\\tresearch\\t`));
    expect(await cli(["list"])).not.toContain("tps_");
    await expect(cli(["create"], { name: "x", scopes: ["desktop"] })).rejects.toThrow(/kullanım/);
    await expect(cli(["create"], { scopes: ["research"] })).rejects.toThrow(/kullanım/);
    expect(await cli(["revoke", id])).toContain(id);
    await expect(cli(["revoke", id])).rejects.toThrow(/bulunamadı/);
    expect(await cli(["list"])).toBe("");
    expect((await stat(config)).mode & 0o777).toBe(0o600);
  });
});
