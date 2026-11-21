// Screen mode `claude` and `diff` topics (PLAN.md §20 W4): terminal session files (waiting/waitingFor, dead or reused
// pids), the transcript tail (only appended bytes, partial lines, truncation and replacement), path containment and
// masking with the city's tokens, unified diff generation and its limits, code-sharing gating (no diff and no file
// names without screen.share.code), diffResolved on resolve and on session end, terminal sessions never giving a
// diff, and touch attribution. Temp dirs, a fake /proc and a fake manager; nothing real under ~/.claude is read.
import { execFileSync } from "node:child_process";
import { appendFile, mkdir, mkdtemp, rename, rm, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import type { ClaudeEvent } from "../src/claude/manager.ts";
import { readTerminalSession } from "../src/claude/terminal.ts";
import { CityWatch, realCityIo } from "../src/screen/producers/city.ts";
import { ClaudeTopic, pagePath, realClaudeIo, rowTools, TranscriptTail, type ClaudeIo, type ManagerLike, type TiphysLike } from "../src/screen/producers/claude.ts";
import { bashPreview, editScript, fileToolDiff, langOf, splitLines, toolSummary, unifiedDiff } from "../src/screen/producers/diff.ts";
import type { Sock } from "../src/screen/source.ts";

const cleanups: Array<() => unknown> = [];
afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
});
const until = async (f: () => boolean, ms = 4000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
async function tmp(prefix = "tiphys-w4-") {
  const d = await mkdtemp(join(tmpdir(), prefix));
  cleanups.push(() => rm(d, { recursive: true, force: true }));
  return d;
}
/** /proc/<pid>/stat with start time `start` (field 22). */
const statLine = (pid: number, start: number) => `${pid} (claude) S 1 ${Array.from({ length: 17 }, (_, i) => i + 5).join(" ")} ${start} 0 0\n`;
async function fakeProc(proc: string, pid: number, start: number) {
  await mkdir(join(proc, String(pid)), { recursive: true });
  await writeFile(join(proc, String(pid), "stat"), statLine(pid, start));
}

type Msg = Record<string, unknown>;
function sock() {
  const got: Msg[] = [];
  const s: Sock = { readyState: 1, bufferedAmount: 0, send: (d) => void got.push(JSON.parse(String(d)) as Msg), close: () => {} };
  return { s, got, of: (t: string) => got.filter((m) => m.type === t), last: (t: string) => got.filter((m) => m.type === t).at(-1) };
}

/** A fake manager: sessions + observers; emit() plays an event the way LiveSession.emit does. */
function fakeManager() {
  const sessions = new Map<string, TiphysLike & { events: ClaudeEvent[]; pending: Map<string, unknown>; status: string }>();
  const m: ManagerLike = { sessions, observers: new Set() };
  let seq = 0;
  const add = (id: string, cwd: string, title = "ekran modları") => {
    const s = { id, cwd, title, status: "running", kind: "code", sdkSessionId: `sdk-${id}`, events: [] as ClaudeEvent[], pending: new Map<string, unknown>() };
    sessions.set(id, s);
    return s;
  };
  const emit = (id: string, body: Record<string, unknown>) => {
    const s = sessions.get(id)!;
    const e = { ...body, seq: ++seq, at: new Date().toISOString() } as ClaudeEvent;
    if (e.kind === "permission") s.pending.set(e.requestId, true);
    if (e.kind === "permissionResolved") s.pending.delete(e.requestId);
    if (e.kind === "status") s.status = e.status;
    s.events.push(e);
    for (const o of m.observers) o(s, e);
    if (e.kind === "status" && e.status === "stopped") sessions.delete(id);
  };
  return { m, add, emit };
}

describe("terminal session files", () => {
  it("waiting + waitingFor are read; a dead or reused pid is no session", async () => {
    const d = await tmp();
    const proc = join(d, "proc");
    await fakeProc(proc, 10, 500);
    await fakeProc(proc, 11, 600);
    const f = (pid: number, extra: object) => writeFile(join(d, `${pid}.json`), JSON.stringify({ pid, sessionId: `sess-${pid}-aaaa`, cwd: "/w", status: "waiting", waitingFor: "permission for Edit", procStart: "500", ...extra }));
    await f(10, {});
    await f(11, {}); // procStart 500 ≠ 600: the pid belongs to another process now
    await f(12, {}); // no process
    expect(await readTerminalSession(join(d, "10.json"), proc)).toMatchObject({ pid: 10, sdkSessionId: "sess-10-aaaa", status: "waiting", waitingFor: "permission for Edit" });
    expect(await readTerminalSession(join(d, "11.json"), proc)).toBeNull();
    expect(await readTerminalSession(join(d, "12.json"), proc)).toBeNull();
    await writeFile(join(d, "13.json"), "{half");
    expect(await readTerminalSession(join(d, "13.json"), proc)).toBeNull();
  });
});

describe("transcript tail", () => {
  const row = (i: number, extra = "") => JSON.stringify({ type: "assistant", i, pad: extra }) + "\n";

  it("reads only appended bytes; a partial line waits; truncation and replacement start over at the tail", async () => {
    const d = await tmp();
    const file = join(d, "s.jsonl");
    await writeFile(file, row(1) + row(2));
    const ranges: Array<[number, number]> = [];
    const base = realClaudeIo();
    const io: ClaudeIo = { ...base, range: (f, s, l) => (ranges.push([s, l]), base.range(f, s, l)) };
    const t = new TranscriptTail(file, io, { initialBytes: 1 << 20 });
    expect((await t.read()).map((r) => r.i)).toEqual([1, 2]);
    const size1 = t.offset;
    expect(await t.read()).toEqual([]); // nothing new: no read at all
    expect(ranges).toHaveLength(1);
    const third = row(3);
    await appendFile(file, third.slice(0, 10));
    expect(await t.read()).toEqual([]); // half a line
    await appendFile(file, third.slice(10) + row(4));
    expect((await t.read()).map((r) => r.i)).toEqual([3, 4]);
    // Every read started where the previous one ended.
    expect(ranges.slice(1).map((r) => r[0])).toEqual([size1, size1 + 10]);
    // Truncated (shorter than the offset): from the tail of the new content.
    await writeFile(file, row(9));
    expect((await t.read()).map((r) => r.i)).toEqual([9]);
    // Replaced by another file (new inode, even if longer): starts over.
    await writeFile(join(d, "new"), row(20) + row(21) + row(22) + row(23) + row(24));
    await rename(join(d, "new"), file);
    expect((await t.read()).map((r) => r.i)).toEqual([20, 21, 22, 23, 24]);
  });

  it("the first read takes only the tail; a line cut by the window is skipped, one that starts on it is kept", async () => {
    const d = await tmp();
    const file = join(d, "s.jsonl");
    const lines = Array.from({ length: 50 }, (_, i) => row(i, "x".repeat(50)));
    await writeFile(file, lines.join(""));
    const len = lines.slice(-3).join("").length; // the last three lines exactly
    const exact = new TranscriptTail(file, realClaudeIo(), { initialBytes: len, maxRead: len * 5 });
    expect((await exact.read()).map((r) => r.i)).toEqual([47, 48, 49]);
    const cut = new TranscriptTail(file, realClaudeIo(), { initialBytes: len - 5 });
    expect((await cut.read()).map((r) => r.i)).toEqual([48, 49]);
    // More than maxRead appended at once: only the last part.
    await appendFile(file, Array.from({ length: 40 }, (_, i) => row(100 + i, "y".repeat(50))).join(""));
    const rows = await exact.read();
    expect(rows.length).toBeLessThan(40);
    expect(rows.at(-1)!.i).toBe(139);
  });

  it("tool uses and results from rows; paths resolved against the cwd", () => {
    const rows = [
      { type: "assistant", timestamp: "2026-11-21T10:00:00Z", message: { content: [{ type: "tool_use", id: "t1", name: "Edit", input: { file_path: "src/a.ts", old_string: "SECRET" } }, { type: "text", text: "hi" }] } },
      { type: "assistant", message: { content: [{ type: "tool_use", id: "t2", name: "Bash", input: { command: "ls" } }] } },
      { type: "user", message: { content: [{ type: "tool_result", tool_use_id: "t1", content: "ok" }] } },
    ];
    const { uses, done } = rowTools(rows, "/w/p", 5);
    expect(uses).toEqual([
      { id: "t1", tool: "Edit", abs: "/w/p/src/a.ts", at: Date.parse("2026-11-21T10:00:00Z") },
      { id: "t2", tool: "Bash", abs: null, at: 5 },
    ]);
    expect(done).toEqual(["t1"]);
    expect(JSON.stringify(uses)).not.toContain("SECRET");
  });
});

describe("paths", () => {
  it("only inside the root, relative; masked through the given mapping; dropped without one", () => {
    const id = (r: string) => r;
    expect(pagePath("/w/p/src/a.ts", "/w/p", id)).toBe("src/a.ts");
    for (const out of ["/w/other/a.ts", "/w/p", "/etc/passwd", "/w/p/../q/a.ts"]) expect(pagePath(out, "/w/p", id)).toBeNull();
    expect(pagePath("/w/p/src/a.ts", null, id)).toBeNull();
    expect(pagePath("/w/p/src/a.ts", "/w/p", null)).toBeNull();
    expect(pagePath("/w/p/src/a.ts", "/w/p", (r) => `m:${r}`)).toBe("m:src/a.ts");
  });
});

describe("diff generation", () => {
  it("edit script and unified hunks with context 3 and line numbers", () => {
    const a = Array.from({ length: 20 }, (_, i) => `line ${i + 1}`);
    const b = [...a];
    b[9] = "changed 10";
    b.splice(15, 0, "inserted");
    const d = unifiedDiff(a.join("\n") + "\n", b.join("\n") + "\n");
    expect(d).toMatchObject({ added: 2, removed: 1, truncated: false, more: 0, binary: false });
    expect(d.hunks).toHaveLength(1); // the two changes are within 2×3 lines: one hunk
    expect(d.hunks[0]).toMatchObject({ oldStart: 7, newStart: 7 });
    expect(d.hunks[0]!.lines).toEqual([" line 7", " line 8", " line 9", "-line 10", "+changed 10", " line 11", " line 12", " line 13", " line 14", " line 15", "+inserted", " line 16", " line 17", " line 18"]);
    const far = [...a];
    far[0] = "x";
    far[19] = "y";
    const d2 = unifiedDiff(a.join("\n"), far.join("\n"));
    expect(d2.hunks.map((h) => [h.oldStart, h.newStart, h.lines.length])).toEqual([[1, 1, 5], [17, 17, 5]]);
    expect(editScript(splitLines("a\nb\nc"), splitLines("a\nc\nd")).map((o) => o.join(""))).toEqual([" a", "-b", " c", "+d"]);
  });

  it("Edit / MultiEdit against the current file; Write new (all added) and overwrite; NotebookEdit as text", () => {
    const cur = "import x\n\nfunction a() {\n  return 1;\n}\n\nfunction b() {\n  return 2;\n}\n";
    const e = fileToolDiff("Edit", { file_path: "/p/a.ts", old_string: "return 1;", new_string: "return 10;" }, cur);
    expect(e.hunks[0]!.lines).toContain("-  return 1;");
    expect(e.hunks[0]!.lines).toContain("+  return 10;");
    expect(e.hunks[0]!.oldStart).toBe(1);
    const m = fileToolDiff("MultiEdit", { edits: [{ old_string: "return 1;", new_string: "return 11;" }, { old_string: "return 2;", new_string: "return 22;" }] }, cur);
    expect([m.added, m.removed]).toEqual([2, 2]);
    // old_string not in the file: the strings themselves.
    const miss = fileToolDiff("Edit", { old_string: "nope", new_string: "yes" }, cur);
    expect(miss.hunks[0]!.lines).toEqual(["-nope", "+yes"]);
    const fresh = fileToolDiff("Write", { content: "a\nb\n" }, null);
    expect(fresh).toMatchObject({ added: 2, removed: 0 });
    expect(fresh.hunks[0]!.lines).toEqual(["+a", "+b"]);
    const over = fileToolDiff("Write", { content: "a\nB\n" }, "a\nb\n");
    expect(over.hunks[0]!.lines).toEqual([" a", "-b", "+B"]);
    expect(fileToolDiff("NotebookEdit", { new_source: "print(1)" }, null).hunks[0]!.lines).toEqual(["+print(1)"]);
  });

  it("limits: ≤ 400 lines and ≤ 64 KB of hunk text, the rest counted; long lines cut; binary; secrets redacted", () => {
    const big = Array.from({ length: 1000 }, (_, i) => `n${i}`).join("\n");
    const d = unifiedDiff("", big);
    expect(d.hunks.flatMap((h) => h.lines)).toHaveLength(400);
    expect(d).toMatchObject({ truncated: true, more: 600, added: 1000 });
    const wide = Array.from({ length: 300 }, () => "w".repeat(380)).join("\n");
    const w = unifiedDiff("", wide);
    const bytes = w.hunks.flatMap((h) => h.lines).reduce((a, l) => a + l.length + 1, 0);
    expect(bytes).toBeLessThanOrEqual(64 * 1024);
    expect(w.truncated).toBe(true);
    expect(unifiedDiff("", "x".repeat(2000)).hunks[0]!.lines[0]!.length).toBeLessThanOrEqual(401);
    expect(unifiedDiff("a\0b", "c")).toMatchObject({ binary: true, hunks: [] });
    const s = unifiedDiff("", "const k = 'ghp_abcdefghijklmnopqrstuvwxyz0123456789';\n");
    expect(JSON.stringify(s)).not.toContain("ghp_abcdefghijklmnopqrstuvwxyz0123456789");
    // A very different middle isn't aligned (bounded work): all removed, then all added.
    const x = unifiedDiff(Array.from({ length: 4000 }, (_, i) => `a${i}`).join("\n"), Array.from({ length: 4000 }, (_, i) => `b${i}`).join("\n"));
    expect([x.added, x.removed]).toEqual([4000, 4000]);
  });

  it("language, Bash preview, other tools' summary without secret fields", () => {
    expect(["a.ts", "b.mjs", "c.dart", "d.yml", "e.rs", "Makefile", "f.unknown"].map(langOf)).toEqual(["ts", "ts", "dart", "json", "rust", "text", "text"]);
    expect(bashPreview({ command: "npm test", description: "Testleri çalıştır" }, "r")).toEqual({ command: "npm test", reason: "Testleri çalıştır" });
    expect(bashPreview({ command: "ls" }, null)).toEqual({ command: "ls", reason: null });
    const sum = toolSummary({ url: "https://example.com", apiKey: "k-123", token: "t", headers: { a: 1 }, n: 3 });
    expect(sum).toBe('{"url":"https://example.com","n":3}');
  });
});

describe("claude topic", () => {
  async function setup(o: { share?: boolean; root?: string; city?: CityWatch } = {}) {
    const root = o.root ?? (await tmp());
    await mkdir(join(root, "src"), { recursive: true });
    await writeFile(join(root, "src/a.ts"), "one\ntwo\nthree\n");
    let share = o.share ?? true;
    const mgr = fakeManager();
    const cfg = await tmp("tiphys-w4-cfg-");
    const proc = await tmp("tiphys-w4-proc-");
    const topic = new ClaudeTopic(
      { manager: () => mgr.m, configDirs: () => [cfg], io: realClaudeIo(proc), share: () => share, opts: { debounceMs: 10, livenessMs: 60 } },
      { rootOf: () => root, cityOf: () => (o.city ? { out: (rel) => o.city!.pathOf(rel) } : null) },
    );
    cleanups.push(() => topic.stop());
    return { root, mgr, topic, cfg, proc, setShare: (v: boolean) => (share = v) };
  }

  it("Tiphys session: status, recent tool uses (paths inside the root only), Edit permission → diff → diffResolved", async () => {
    const { root, mgr, topic } = await setup();
    const a = sock();
    mgr.add("aaaaaaaa-1111", root);
    topic.set(a.s, ["claude", "diff"]);
    await until(() => a.of("claude").length > 0);
    mgr.emit("aaaaaaaa-1111", { kind: "tool_use", id: "u1", name: "Read", input: { file_path: join(root, "src/a.ts") } });
    mgr.emit("aaaaaaaa-1111", { kind: "tool_use", id: "u2", name: "Read", input: { file_path: "/etc/hosts" } });
    await until(() => ((a.last("claude")?.sessions as Msg[])?.[0]?.recent as Msg[])?.length === 2);
    const s0 = (a.last("claude")!.sessions as Msg[])[0]!;
    expect(s0).toMatchObject({ id: "aaaaaaaa", origin: "tiphys", status: "running", project: root.split("/").pop(), name: "ekran modları" });
    expect((s0.recent as Msg[]).map((r) => [r.tool, r.path, r.kind])).toEqual([["Read", "src/a.ts", "read"], ["Read", null, "read"]]);
    mgr.emit("aaaaaaaa-1111", { kind: "permission", requestId: "r1", toolName: "Edit", input: { file_path: join(root, "src/a.ts"), old_string: "two", new_string: "TWO" }, reason: null });
    await until(() => a.of("diff").length === 1);
    expect(a.of("diff")[0]).toMatchObject({ type: "diff", sessionId: "aaaaaaaa", session: "ekran modları", requestId: "r1", tool: "Edit", path: "src/a.ts", lang: "ts", added: 1, removed: 1, truncated: false, created: false });
    expect((a.of("diff")[0]!.hunks as Msg[])[0]).toEqual({ oldStart: 1, newStart: 1, lines: [" one", "-two", "+TWO", " three"] });
    await until(() => (a.last("claude")!.sessions as Msg[])[0]!.status === "waiting");
    expect((a.last("claude")!.sessions as Msg[])[0]).toMatchObject({ waiting: { tool: "Edit", path: "src/a.ts" }, pending: ["r1"] });
    // A late subscriber gets the pending diff at once.
    const b = sock();
    topic.set(b.s, ["claude", "diff"]);
    await until(() => b.of("diff").length === 1);
    mgr.emit("aaaaaaaa-1111", { kind: "permissionResolved", requestId: "r1", allow: false });
    await until(() => a.of("diffResolved").length === 1 && b.of("diffResolved").length === 1);
    expect(a.of("diffResolved")[0]).toEqual({ type: "diffResolved", requestId: "r1", allow: false });
    // Bash and other tools; then the session ends with both open → both resolved.
    mgr.emit("aaaaaaaa-1111", { kind: "permission", requestId: "r2", toolName: "Bash", input: { command: "rm -rf build", description: "Temizlik" }, reason: null });
    mgr.emit("aaaaaaaa-1111", { kind: "permission", requestId: "r3", toolName: "WebFetch", input: { url: "https://example.com", prompt: "p" }, reason: null });
    await until(() => a.of("diff").length === 3);
    expect(a.of("diff")[1]).toMatchObject({ tool: "Bash", command: "rm -rf build", reason: "Temizlik" });
    expect(a.of("diff")[2]).toMatchObject({ tool: "WebFetch", summary: '{"url":"https://example.com","prompt":"p"}' });
    mgr.emit("aaaaaaaa-1111", { kind: "status", status: "stopped" });
    await until(() => a.of("diffResolved").length === 3);
    expect(a.of("diffResolved").slice(1).map((m) => m.requestId).sort()).toEqual(["r2", "r3"]);
    await until(() => (a.last("claude")!.sessions as Msg[]).length === 0);
    // Unsubscribed: everything off.
    topic.set(a.s, []);
    topic.set(b.s, []);
    expect(topic.active).toBe(false);
    expect(mgr.m.observers.size).toBe(0);
  });

  it("Write of a new file is all-added; a file outside the root gives no diff (the banner still knows)", async () => {
    const { root, mgr, topic } = await setup();
    const a = sock();
    mgr.add("bbbbbbbb", root);
    topic.set(a.s, ["claude", "diff"]);
    mgr.emit("bbbbbbbb", { kind: "permission", requestId: "w1", toolName: "Write", input: { file_path: join(root, "src/new.dart"), content: "void main() {}\n" }, reason: null });
    await until(() => a.of("diff").length === 1);
    expect(a.of("diff")[0]).toMatchObject({ path: "src/new.dart", lang: "dart", created: true, added: 1, removed: 0 });
    mgr.emit("bbbbbbbb", { kind: "permission", requestId: "w2", toolName: "Edit", input: { file_path: "/etc/hosts", old_string: "a", new_string: "b" }, reason: null });
    await until(() => ((a.last("claude")?.sessions as Msg[])?.[0]?.pending as string[])?.length === 2);
    await sleep(60);
    expect(a.of("diff")).toHaveLength(1);
  });

  it("share.code off: no diff message at all and no file names; the claude topic still says what waits", async () => {
    const { root, mgr, topic } = await setup({ share: false });
    const a = sock();
    mgr.add("cccccccc", root);
    topic.set(a.s, ["claude", "diff"]);
    mgr.emit("cccccccc", { kind: "tool_use", id: "u", name: "Edit", input: { file_path: join(root, "src/a.ts") } });
    mgr.emit("cccccccc", { kind: "permission", requestId: "q1", toolName: "Edit", input: { file_path: join(root, "src/a.ts"), old_string: "two", new_string: "TWO" }, reason: null });
    await until(() => (a.last("claude")?.sessions as Msg[])?.[0]?.status === "waiting");
    mgr.emit("cccccccc", { kind: "permissionResolved", requestId: "q1", allow: false });
    await sleep(60);
    expect(a.got.some((m) => m.type === "diff" || m.type === "diffResolved")).toBe(false);
    const text = JSON.stringify(a.got);
    expect(text).not.toContain("a.ts");
    expect(text).not.toContain("TWO");
    expect(a.got.find((m) => m.type === "claude" && (m.sessions as Msg[])[0]?.status === "waiting")!.sessions).toMatchObject([{ waiting: { tool: "Edit", path: null } }]);
  });

  it("share.code off with a city: paths are the city's masked tokens (the beam hits the same building)", async () => {
    const root = await tmp();
    await mkdir(join(root, "src"), { recursive: true });
    await writeFile(join(root, "src/a.ts"), "one\n");
    execFileSync("git", ["init", "-q"], { cwd: root });
    const got: Msg[] = [];
    const city = new CityWatch(root, realCityIo, (d) => got.push(JSON.parse(d) as Msg), { masked: true });
    cleanups.push(() => city.stop());
    await city.start();
    const token = ((got[0]!.files as unknown[][]).find(() => true)![0]) as string;
    expect(token).toMatch(/^[0-9a-f]{8}\/[0-9a-f]{8}$/);
    const { mgr, topic } = await setup({ share: false, root, city });
    const a = sock();
    mgr.add("dddddddd", root);
    topic.set(a.s, ["claude"]);
    mgr.emit("dddddddd", { kind: "tool_use", id: "u", name: "Read", input: { file_path: join(root, "src/a.ts") } });
    await until(() => ((a.last("claude")?.sessions as Msg[])?.[0]?.recent as Msg[])?.length === 1);
    expect(((a.last("claude")!.sessions as Msg[])[0]!.recent as Msg[])[0]!.path).toBe(token);
  });

  it("terminal session: status from the file, tool uses from the transcript tail, waiting → tool + file, never a diff; dead pid drops it", async () => {
    const { root, topic, cfg, proc } = await setup({ share: true });
    await mkdir(join(cfg, "sessions"), { recursive: true });
    await mkdir(join(cfg, "projects", "-x"), { recursive: true });
    const sid = "eeeeeeee-2222-4aaa-8aaa-aaaaaaaaaaaa";
    const tr = join(cfg, "projects", "-x", `${sid}.jsonl`);
    await writeFile(tr, "");
    await fakeProc(proc, 4242, 77);
    const file = (status: string, waitingFor?: string) =>
      writeFile(join(cfg, "sessions", "4242.json"), JSON.stringify({ pid: 4242, sessionId: sid, cwd: root, name: "terminal işi", status, procStart: "77", ...(waitingFor ? { waitingFor } : {}) }));
    await file("busy");
    const a = sock();
    topic.set(a.s, ["claude", "diff"]);
    await until(() => (a.last("claude")?.sessions as Msg[])?.length === 1);
    expect((a.last("claude")!.sessions as Msg[])[0]).toMatchObject({ id: "eeeeeeee", origin: "terminal", status: "running", name: "terminal işi", pending: [] });
    await appendFile(tr, JSON.stringify({ type: "assistant", message: { content: [{ type: "tool_use", id: "t1", name: "Edit", input: { file_path: "src/a.ts", old_string: "two", new_string: "2" } }] } }) + "\n");
    await until(() => ((a.last("claude")!.sessions as Msg[])[0]!.recent as Msg[]).length === 1);
    await file("waiting", "permission");
    await until(() => (a.last("claude")!.sessions as Msg[])[0]!.status === "waiting");
    expect((a.last("claude")!.sessions as Msg[])[0]!.waiting).toMatchObject({ tool: "Edit", path: "src/a.ts" });
    expect(a.of("diff")).toHaveLength(0); // Decision 4
    // The edit names the session in a touch of that file.
    expect(topic.attribute(join(root, "src/a.ts"))).toBe("eeeeeeee");
    expect(topic.attribute(join(root, "src/other.ts"))).toBeNull();
    // The process dies (the file may stay): gone within the liveness check.
    await unlink(join(proc, "4242", "stat"));
    await until(() => (a.last("claude")!.sessions as Msg[]).length === 0);
    topic.set(a.s, []);
    expect(topic.watchCount).toBe(0);
  });
});

describe("touch attribution", () => {
  it("a city touch after a session's Edit carries that session's id; others stay null", async () => {
    const root = await tmp();
    await mkdir(join(root, "src"), { recursive: true });
    await writeFile(join(root, "src/a.ts"), "one\n");
    await writeFile(join(root, "src/b.ts"), "one\n");
    execFileSync("git", ["init", "-q"], { cwd: root });
    const got: Msg[] = [];
    const city = new CityWatch(root, realCityIo, (d) => got.push(JSON.parse(d) as Msg), { settleMs: 30, maxWaitMs: 300 });
    cleanups.push(() => city.stop());
    const mgr = fakeManager();
    const topic = new ClaudeTopic({ manager: () => mgr.m, configDirs: () => [], io: realClaudeIo(), share: () => true, opts: { debounceMs: 10 } }, { rootOf: () => root, cityOf: () => null });
    cleanups.push(() => topic.stop());
    city.by = (rel) => topic.attribute(join(root, rel));
    await city.start();
    mgr.add("ffffffff-9", root);
    const a = sock();
    topic.set(a.s, ["claude"]);
    await until(() => a.of("claude").length > 0);
    mgr.emit("ffffffff-9", { kind: "tool_use", id: "u", name: "Edit", input: { file_path: join(root, "src/a.ts") } });
    await writeFile(join(root, "src/a.ts"), "one\ntwo\n");
    await writeFile(join(root, "src/b.ts"), "one\ntwo\n");
    await until(() => got.filter((m) => m.type === "touch").length === 2);
    const by = Object.fromEntries(got.filter((m) => m.type === "touch").map((m) => [m.path, m.by]));
    expect(by).toEqual({ "src/a.ts": "ffffffff", "src/b.ts": null });
  });
});
