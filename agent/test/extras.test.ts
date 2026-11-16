import { execFileSync } from "node:child_process";
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { AlertMonitor } from "../src/alerts.ts";
import { addService, parseServices } from "../src/routes/homepage.ts";
import { parseLog, parseStatus } from "../src/routes/git.ts";
import { parseServe, parseSs } from "../src/routes/ports.ts";
import { parsePs } from "../src/routes/processes.ts";
import { maintenanceInputSchema } from "../src/uptime/bridge.ts";
import { testApp } from "./helpers.ts";

describe("ayrıştırıcılar", () => {
  it("ps çıktısı", () => {
    const p = parsePs("  123     1 user    12.5  3.1 204800   3600 node node dist/cli.js serve\n    7     2 root 0.0 0.0 0 99 kworker [kworker/0:1]\n");
    expect(p[0]).toMatchObject({ pid: 123, ppid: 1, user: "user", cpuPercent: 12.5, rssBytes: 204800 * 1024, name: "node", command: "node dist/cli.js serve" });
    expect(p).toHaveLength(2);
  });

  it("git status --porcelain=v2", () => {
    const out = [
      "# branch.oid 0123abc",
      "# branch.head main",
      "# branch.upstream origin/main",
      "# branch.ab +2 -1",
      "1 .M N... 100644 100644 100644 aaa bbb src/a file.ts",
      "1 A. N... 000000 100644 100644 000 ccc yeni.ts",
      "2 R. N... 100644 100644 100644 ddd eee R100 yeni ad.ts\teski.ts",
      "u UU N... 100644 100644 100644 100644 f g h cakisma.ts",
      "? notes.md",
    ].join("\n");
    const s = parseStatus(out);
    expect(s).toMatchObject({ branch: "main", upstream: "origin/main", ahead: 2, behind: 1, head: "0123abc" });
    expect(s.files.map((f) => [f.path, f.index, f.worktree])).toEqual([
      ["src/a file.ts", ".", "M"],
      ["yeni.ts", "A", "."],
      ["yeni ad.ts", "R", "."],
      ["cakisma.ts", "U", "U"],
      ["notes.md", ".", "?"],
    ]);
    expect(s.files[2]!.origPath).toBe("eski.ts");
    expect(s.files[3]!.conflicted).toBe(true);
  });

  it("git log", () => {
    const l = parseLog("abc\x1fAli\x1f2026-11-14T10:00:00+03:00\x1fİlk commit\x1fHEAD -> main\x1e\ndef\x1fVeli\x1f2026-11-13T10:00:00+03:00\x1fikinci\x1f\x1e\n");
    expect(l).toEqual([
      { hash: "abc", author: "Ali", date: "2026-11-14T10:00:00+03:00", subject: "İlk commit", refs: "HEAD -> main" },
      { hash: "def", author: "Veli", date: "2026-11-13T10:00:00+03:00", subject: "ikinci", refs: "" },
    ]);
  });

  it("ss -ltnpH ve tailscale serve", () => {
    const ss = [
      'LISTEN 0 511 127.0.0.1:3000 0.0.0.0:* users:(("node",pid=4242,fd=21))',
      "LISTEN 0 4096 0.0.0.0:22 0.0.0.0:*",
      "LISTEN 0 4096 [::]:22 [::]:*",
      'LISTEN 0 511 [::1]:5173 [::]:* users:(("vite",pid=99,fd=3))',
      "LISTEN 0 128 100.64.1.2%tailscale0:7443 0.0.0.0:*",
    ].join("\n");
    const p = parseSs(ss);
    expect(p.map((x) => [x.port, x.localOnly, x.process])).toEqual([
      [22, false, null],
      [3000, true, "node"],
      [5173, true, "vite"],
      [7443, false, null],
    ]);
    const shared = parseServe(JSON.stringify({ Web: { "pc.ts.net:3000": { Handlers: { "/": { Proxy: "http://127.0.0.1:3000" } } } } }));
    expect(shared.get(3000)).toBe("http://127.0.0.1:3000");
    expect(parseServe("")).toEqual(new Map());
  });

  it("Homepage'e servis ekleme yorumları korur", () => {
    const src = "# servislerim\n- Yayındaki siteler:\n    - Blog:\n        href: https://example.com\n        siteMonitor: https://example.com\n- Araçlar:\n    - Grafana:\n        href: https://g\n";
    const out = addService(src, { group: "Yayındaki siteler", name: "Yeni", href: "https://yeni.example", description: "deneme" });
    expect(out).toContain("# servislerim");
    const g = parseServices(out).find((x) => x.name === "Yayındaki siteler")!;
    expect(g.services.map((s) => s.name)).toEqual(["Blog", "Yeni"]);
    expect(g.services[1]).toMatchObject({ href: "https://yeni.example", monitorUrl: "https://yeni.example", description: "deneme" });
    const out2 = addService(out, { group: "Yeni grup", name: "X", href: "https://x.example" });
    expect(parseServices(out2).map((x) => x.name)).toEqual(["Yayındaki siteler", "Araçlar", "Yeni grup"]);
    expect(() => addService(out, { group: "Yayındaki siteler", name: "Blog", href: "https://a" })).toThrow();
  });

  it("bakım penceresi girdisi", () => {
    expect(maintenanceInputSchema.safeParse({ title: "x", monitorIds: [1], start: "2026-11-14T10:00:00Z", end: "2026-11-14T09:00:00Z" }).success).toBe(false);
    expect(maintenanceInputSchema.safeParse({ title: "x", monitorIds: [1], start: "2026-11-14T10:00:00+03:00", end: "2026-11-14T12:00:00+03:00" }).success).toBe(true);
  });
});

describe("uyarılar", () => {
  it("ilk turda sessiz, sonra yeni durumları ve düzelmeleri bildirir", async () => {
    const { app, store, sent, notifier } = await testApp();
    const m = new AlertMonitor({ store, notifier });
    const base = { disks: [{ mount: "/", percent: 95 }], failed: [], grafana: [] };
    expect(await m.evaluate(base)).toEqual(["disk:/"]);
    expect(sent).toEqual([]); // a disk that is already full when the agent starts isn't reported
    await m.evaluate({ ...base, failed: ["user/foo.service"], grafana: [{ name: "BackupStale", state: "firing", severity: "critical" }] });
    expect(sent.map((n) => (n as { key: string }).key).sort()).toEqual(["grafana.alert", "service.failed"]);
    expect(sent.find((n) => (n as { key: string }).key === "service.failed")).toMatchObject({ params: { unit: "foo.service", scope: "user", host: "test" } });
    sent.length = 0;
    await m.evaluate({ disks: [{ mount: "/", percent: 50 }], failed: ["user/foo.service"], grafana: [] });
    expect(sent.map((n) => (n as { key: string }).key).sort()).toEqual(["disk.ok", "grafana.resolved"]);
    sent.length = 0;
    await m.evaluate({ disks: [{ mount: "/", percent: 50 }], failed: ["user/foo.service"], grafana: [] });
    expect(sent).toEqual([]);
    await app.close();
  });
});

describe("git uç noktaları (geçici depo)", () => {
  it("durum, diff, stage, commit, log, dal", async () => {
    const root = await mkdtemp(join(tmpdir(), "tiphys-git-"));
    const g = (...a: string[]) => execFileSync("git", ["-C", root, ...a], { env: { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@e", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@e" } });
    g("init", "-q", "-b", "main");
    g("config", "user.name", "T");
    g("config", "user.email", "t@e");
    await writeFile(join(root, "a.txt"), "bir\n");
    g("add", "a.txt");
    g("commit", "-q", "-m", "ilk");
    await writeFile(join(root, "a.txt"), "bir\niki\n");
    await writeFile(join(root, "yeni.txt"), "x\n");
    const { app, auth } = await testApp((c) => {
      c.features.git = true;
      c.allowedRoots = [root];
      return c;
    });
    const get = async (url: string) => (await app.inject({ method: "GET", url, headers: auth })).json();
    const post = (url: string, payload: object) => app.inject({ method: "POST", url, headers: auth, payload });
    const q = encodeURIComponent(root);

    let st = await get(`/v1/git/status?path=${q}`);
    expect(st.branch).toBe("main");
    expect(st.files.map((f: { path: string; worktree: string }) => `${f.path}:${f.worktree}`).sort()).toEqual(["a.txt:M", "yeni.txt:?"]);
    expect((await get(`/v1/git/diff?path=${q}&file=a.txt`)).diff).toContain("+iki");
    expect((await get(`/v1/git/diff?path=${q}&file=yeni.txt`)).diff).toContain("+x");

    expect((await post("/v1/git/stage", { path: root, files: ["a.txt"], stage: true })).statusCode).toBe(200);
    st = await get(`/v1/git/status?path=${q}`);
    expect(st.files.find((f: { path: string }) => f.path === "a.txt").index).toBe("M");
    expect((await post("/v1/git/stage", { path: root, files: ["a.txt"], stage: false })).statusCode).toBe(200);

    const c = await post("/v1/git/commit", { path: root, message: "telefondan", all: true });
    expect(c.statusCode).toBe(200);
    expect((await get(`/v1/git/status?path=${q}`)).files).toEqual([]);
    const log = await get(`/v1/git/log?path=${q}`);
    expect(log.commits.map((x: { subject: string }) => x.subject)).toEqual(["telefondan", "ilk"]);
    expect((await get(`/v1/git/diff?path=${q}&commit=${log.commits[0].hash}`)).diff).toContain("+iki");

    const again = await post("/v1/git/commit", { path: root, message: "boş" });
    expect(again.json().error.code).toBe("agent.git.nothingToCommit");

    expect((await post("/v1/git/checkout", { path: root, branch: "ozellik", create: true })).statusCode).toBe(200);
    const br = await get(`/v1/git/branches?path=${q}`);
    expect(br.branches.find((b: { current: boolean }) => b.current).name).toBe("ozellik");
    expect((await post("/v1/git/checkout", { path: root, branch: "--evil" })).statusCode).toBe(400);

    const outside = await get(`/v1/git/status?path=${encodeURIComponent("/etc")}`);
    expect(outside.error.code).toBe("agent.path.notAllowed");
    await app.close();
  });
});

describe("süreçler ve işlem kaydı", () => {
  it("süreç listesi, onaysız sinyal reddi ve kayıt", async () => {
    const { app, auth, dir } = await testApp();
    const list = (await app.inject({ method: "GET", url: "/v1/processes?sort=mem&limit=5", headers: auth })).json();
    expect(list.processes).toHaveLength(5);
    expect(list.processes[0].rssBytes).toBeGreaterThanOrEqual(list.processes[4].rssBytes);
    const noConfirm = await app.inject({ method: "POST", url: "/v1/processes/999999/signal", headers: auth, payload: {} });
    expect(noConfirm.json().error.code).toBe("agent.processes.confirmRequired");
    const self = await app.inject({ method: "POST", url: `/v1/processes/${process.pid}/signal`, headers: auth, payload: { confirm: true } });
    expect(self.json().error.code).toBe("agent.processes.self");
    const gone = await app.inject({ method: "POST", url: "/v1/processes/4194000/signal", headers: auth, payload: { confirm: true } });
    expect(gone.json().error.code).toBe("agent.processes.notFound");
    const audit = (await app.inject({ method: "GET", url: "/v1/audit", headers: auth })).json();
    expect(audit.entries.map((e: { path: string; status: number }) => `${e.status} ${e.path}`)).toEqual([
      "404 /v1/processes/4194000/signal",
      "400 /v1/processes/" + process.pid + "/signal",
      "400 /v1/processes/999999/signal",
    ]);
    expect(audit.entries[0].device).toBe("phone");
    expect(await readFile(join(dir, "audit.jsonl"), "utf8")).not.toContain("tph_");
    await app.close();
  });
});

describe("ses → yazı", () => {
  it("telefonun seçtiği model ve dil komuta geçer, yoksa ajanın varsayılan modeli", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-tr-"));
    const cmd = join(dir, "transcribe");
    // Fake transcribe: writes out the -m/-l flags it received.
    await writeFile(cmd, '#!/bin/sh\nshift\necho "$@"\n', { mode: 0o755 });
    const { app, auth } = await testApp((c) => {
      c.features.transcribe = true;
      c.transcribe = { ...c.transcribe, command: cmd, model: "small" };
      return c;
    });
    const say = async (extra: object) =>
      (await app.inject({ method: "POST", url: "/v1/transcribe", headers: auth, payload: { data: Buffer.from("ses").toString("base64"), ext: "m4a", ...extra } })).json();
    expect(await say({ model: "large-v3", language: "tr" })).toEqual({ text: "-m large-v3 -l tr" });
    expect(await say({})).toEqual({ text: "-m small" });
  });
});

describe("ajanın kendi sağlığı", () => {
  it("düzgün kapanış sayılmaz; çökme (kapanış işareti yok) beklenmedik yeniden başlama sayılır", async () => {
    const { RunLog } = await import("../src/runs.ts");
    const file = join(await mkdtemp(join(tmpdir(), "tiphys-runs-")), "agent-runs.json");
    const a = new RunLog(file);
    await a.begin();
    expect(a.previousCrashed).toBeNull();
    await a.end(); // update/restart: clean

    const b = new RunLog(file);
    await b.begin();
    expect(b.previousCrashed).toBeNull();
    // The process died before b shut down (OOM / crash) → c sees this on startup
    const c = new RunLog(file);
    await c.begin();
    expect(c.previousCrashed?.start).toBe(b.startedAt.toISOString());
    expect(c.unexpectedSince()).toHaveLength(1);
  });

  it("durum ucu sürüm, açık kalma süresi ve bellek bilgisi verir", async () => {
    const { app, auth } = await testApp();
    const s = (await app.inject({ url: "/v1/agent/status", headers: auth })).json();
    expect(s).toMatchObject({ version: "0.3.0", unexpectedRestarts24h: 0, lastUnexpectedAt: null });
    expect(s.memory.agentBytes).toBeGreaterThan(1024 * 1024);
    expect(s.uptimeSeconds).toBeGreaterThanOrEqual(0);
  });
});
