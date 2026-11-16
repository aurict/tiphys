// Claude Code transcript reader: backwards from the end, skipping past compaction, paged.
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { findTranscript, transcriptEvents, transcriptPage } from "../src/claude/transcript.ts";

async function fixture() {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-tr-"));
  await mkdir(join(dir, "projects", "-home-user-proj"), { recursive: true });
  const rows: object[] = [];
  let prev: string | null = null;
  const push = (r: Record<string, unknown>) => {
    const uuid = `u${rows.length}`;
    rows.push({ uuid, parentUuid: prev, ...r });
    prev = uuid;
    return uuid;
  };
  // Part before compaction: m1..m4
  for (let i = 1; i <= 4; i++) push({ type: "user", message: { role: "user", content: `m${i}` } });
  const beforeCompact = prev;
  // Compaction boundary (parentUuid null, logicalParentUuid links to the previous part) + summary (not shown)
  prev = null;
  push({ type: "system", subtype: "compact_boundary", logicalParentUuid: beforeCompact });
  push({ type: "user", isCompactSummary: true, message: { role: "user", content: "ÖZET" } });
  // Later part: command wrapper, meta line, subagent line, tool call and its result
  push({ type: "user", message: { role: "user", content: "<command-name>/review</command-name><command-args>src</command-args>" } });
  push({ type: "user", isMeta: true, message: { role: "user", content: "gizli meta" } });
  push({ type: "assistant", message: { role: "assistant", content: [{ type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } }] } });
  push({ type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "a.txt" }] } });
  rows.push({ uuid: "side", parentUuid: prev, isSidechain: true, type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "alt ajan" }] } });
  push({ type: "assistant", message: { role: "assistant", content: [{ type: "text", text: "son cevap" }] } });
  const id = "99999999-9999-4999-8999-999999999999";
  await writeFile(join(dir, "projects", "-home-user-proj", `${id}.jsonl`), rows.map((r) => JSON.stringify(r)).join("\n") + "\n");
  return { dir, id };
}

describe("oturum kaydı okuyucu", () => {
  it("sondan başlar, sıkıştırmayı geçer, özet/meta/alt ajan satırlarını göstermez", async () => {
    const { dir, id } = await fixture();
    const file = (await findTranscript(dir, id))!;
    const ev = await transcriptEvents(file, 100);
    expect(ev.map((e) => (e.kind === "user" || e.kind === "text" ? `${e.kind}:${e.text}` : e.kind))).toEqual([
      "user:m1", "user:m2", "user:m3", "user:m4", "compacted", "user:/review src", "tool_use", "tool_result", "text:son cevap",
    ]);
    expect(await findTranscript(dir, "00000000-0000-4000-8000-000000000000")).toBeNull();
  });

  it("sayfalı: en yeniler önce, skip ile daha eskiler; daha eskisi kalmayınca more=false", async () => {
    const { dir, id } = await fixture();
    const file = (await findTranscript(dir, id))!;
    const p1 = await transcriptPage(file, 3, 0);
    expect(p1.events.map((e) => e.kind)).toEqual(["tool_use", "tool_result", "text"]);
    expect(p1.more).toBe(true);
    const p2 = await transcriptPage(file, 3, 3);
    expect(p2.events.map((e) => (e.kind === "user" ? e.text : e.kind))).toEqual(["m4", "compacted", "/review src"]);
    const p3 = await transcriptPage(file, 10, 6);
    expect(p3.events.map((e) => e.text)).toEqual(["m1", "m2", "m3"]);
    expect(p3.more).toBe(false);
  });
});
