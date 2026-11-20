import { mkdir, readFile, stat, utimes, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { AlertMonitor, DockerEventWatcher, DOCKER_DEBOUNCE_MS, parseDockerEvent } from "../src/alerts.ts";
import { backupRoutes, BackupMonitor, fileState, globToRegExp, newestFile, parseSystemctlShow, parseSystemdTimestamp, unitState } from "../src/backups.ts";
import type { AgentConfig } from "../src/config.ts";
import { EventLog } from "../src/events.ts";
import type { ExecResult } from "../src/exec.ts";
import { testApp } from "./helpers.ts";

const keys = (sent: unknown[]) => sent.map((n) => (n as { key: string }).key);

describe("olay akışı", () => {
  it("her bildirim (uç nokta olmasa da) olay olarak yazılır; yeniden eskiye, since ve limit", async () => {
    const { app, auth, store } = await testApp();
    expect(store.get().push.endpoints).toEqual([]);
    expect((await app.inject({ method: "POST", url: "/v1/push/test", headers: auth })).json()).toEqual({ sent: 0 });
    const r1 = await app.inject({ method: "GET", url: "/v1/events", headers: auth });
    const [e1] = r1.json().events;
    expect(e1).toMatchObject({ key: "push.test", params: { device: "Telefon" }, source: "agent", link: null });
    await new Promise((r) => setTimeout(r, 5));
    const post = await app.inject({
      method: "POST",
      url: "/v1/events",
      headers: auth,
      payload: { key: "compose.updated", params: { host: "orion", stack: "web", services: 3 }, link: "tiphys://system" },
    });
    expect(post.statusCode).toBe(200);
    expect(post.json().event).toMatchObject({ key: "compose.updated", source: "app", device: "phone" });
    const all = (await app.inject({ method: "GET", url: "/v1/events", headers: auth })).json().events;
    expect(all.map((e: { key: string }) => e.key)).toEqual(["compose.updated", "push.test"]);
    const newer = (await app.inject({ method: "GET", url: `/v1/events?since=${encodeURIComponent(e1.at)}`, headers: auth })).json().events;
    expect(newer.map((e: { key: string }) => e.key)).toEqual(["compose.updated"]);
    expect((await app.inject({ method: "GET", url: "/v1/events?limit=1", headers: auth })).json().events).toHaveLength(1);
    // Adding an event is also recorded in the audit log.
    const audit = (await app.inject({ method: "GET", url: "/v1/audit", headers: auth })).json().entries;
    expect(audit.some((a: { path: string }) => a.path === "/v1/events")).toBe(true);
    await app.close();
  });

  it("telefondan gelen olay doğrulanır", async () => {
    const { app, auth } = await testApp();
    const bad = [
      { key: "Bad Key" },
      { key: "x.y", link: "https://evil" },
      { key: "x.y", params: { a: "x".repeat(501) } },
      { key: "x.y", params: Object.fromEntries(Array.from({ length: 17 }, (_, i) => [`p${i}`, i])) },
      { key: "x.y", extra: 1 },
    ];
    for (const payload of bad) {
      expect((await app.inject({ method: "POST", url: "/v1/events", headers: auth, payload })).statusCode, JSON.stringify(payload).slice(0, 60)).toBe(400);
    }
    expect((await app.inject({ method: "GET", url: "/v1/events" })).statusCode).toBe(401);
    await app.close();
  });

  it("2 MB'ı geçince döner; liste eski kopyadan da okur", async () => {
    const { dir } = await testApp();
    const log = new EventLog(join(dir, "ev.jsonl"));
    await writeFile(log.file, `${JSON.stringify({ id: "old", at: "2026-01-01T00:00:00.000Z", key: "old.one", params: { pad: "x".repeat(100) }, link: null, source: "agent" })}\n`.repeat(22000));
    expect((await stat(log.file)).size).toBeGreaterThan(2 * 1024 * 1024);
    await log.record({ key: "new.one", params: { long: "y".repeat(2000) } });
    expect((await stat(log.file)).size).toBeLessThan(10_000);
    expect((await stat(`${log.file}.1`)).size).toBeGreaterThan(2 * 1024 * 1024);
    const list = await log.list({ limit: 3 });
    expect(list.map((e) => e.key)).toEqual(["new.one", "old.one", "old.one"]);
    expect((list[0]!.params.long as string).length).toBe(500);
    expect(await log.list({ since: "2026-06-01T00:00:00Z" })).toHaveLength(1);
  });

  it("uyarı bildirimleri de olay akışına düşer", async () => {
    const { app, auth, store, notifier } = await testApp();
    const m = new AlertMonitor({ store, notifier });
    await m.evaluate({ disks: [], failed: [], grafana: [] });
    await m.evaluate({ disks: [{ mount: "/", percent: 97 }], failed: [], grafana: [] });
    const ev = (await app.inject({ method: "GET", url: "/v1/events", headers: auth })).json().events;
    expect(ev[0]).toMatchObject({ key: "disk.full", params: { mount: "/", percent: 97, host: "test" }, link: "tiphys://system" });
    await app.close();
  });
});

describe("olay kaydında gizlilik", () => {
  it("komut satırı olaya yalnız program adıyla yazılır; bildirimde tam komut gider", async () => {
    const { app, auth, notifier, sent } = await testApp();
    await notifier.send({ key: "command.done", params: { host: "test", command: "/usr/bin/mysql -uroot -pGIZLI123 -e 'select 1'", seconds: 70, code: 0 } });
    expect((sent.at(-1) as { params: { command: string } }).params.command).toContain("-pGIZLI123");
    const ev = (await app.inject({ method: "GET", url: "/v1/events", headers: auth })).json().events;
    expect(ev[0]).toMatchObject({ key: "command.done", params: { command: "mysql", seconds: 70 } });
    expect(JSON.stringify(ev)).not.toContain("GIZLI");
    await app.close();
  });
});

describe("docker olayları", () => {
  const line = (Action: string, name: string, extra: Record<string, string> = {}, sec = 1_800_000_000) =>
    JSON.stringify({ Type: "container", Action, Actor: { ID: "abc", Attributes: { name, image: "img", ...extra } }, time: sec, timeNano: sec * 1e9 });

  it("satır ayrıştırma", () => {
    expect(parseDockerEvent(line("die", "web", { exitCode: "137" }))).toEqual({ action: "die", name: "web", exitCode: 137, at: 1_800_000_000_000 });
    expect(parseDockerEvent(line("oom", "web"))).toMatchObject({ action: "oom", exitCode: null });
    expect(parseDockerEvent(JSON.stringify({ Type: "network", Action: "connect", Actor: { Attributes: { name: "x" } } }))).toBeNull();
    expect(parseDockerEvent("bozuk")).toBeNull();
  });

  it("beklenmedik çökme ve OOM bildirilir; istenen durdurma ve 0 çıkışı sessiz; yeniden başlama yalnız olay; tekrarlar bastırılır", async () => {
    const { app, auth, store, notifier, sent } = await testApp();
    const w = new DockerEventWatcher({ store, notifier });
    const t0 = 1_800_000_000;
    const feed = async (a: string, n: string, extra: Record<string, string> = {}, sec = t0) => w.handle(parseDockerEvent(line(a, n, extra, sec))!);
    await feed("kill", "db", { signal: "15" });
    await feed("die", "db", { exitCode: "143" }, t0 + 2); // docker stop
    await feed("die", "job", { exitCode: "0" });
    expect(sent).toEqual([]);
    await feed("die", "web", { exitCode: "1" }, t0 + 10);
    await feed("die", "web", { exitCode: "1" }, t0 + 20); // crash loop: suppressed
    await feed("oom", "web", {}, t0 + 21);
    await feed("restart", "api", {}, t0 + 30);
    expect(keys(sent)).toEqual(["docker.died", "docker.oom"]);
    expect(sent[0]).toMatchObject({ params: { host: "test", container: "web", code: 1 }, priority: "high" });
    await feed("die", "web", { exitCode: "1" }, t0 + 30 + DOCKER_DEBOUNCE_MS / 1000);
    expect(keys(sent)).toEqual(["docker.died", "docker.oom", "docker.died"]);
    const ev = (await app.inject({ method: "GET", url: "/v1/events", headers: auth })).json().events;
    expect(ev.map((e: { key: string }) => e.key)).toEqual(["docker.died", "docker.restarted", "docker.oom", "docker.died"]);
    await app.close();
  });
  it("Tiphys'in kendi araç container'ları (Trivy, gitleaks, geri yükleme testi) bildirim ve olay üretmez", async () => {
    expect(parseDockerEvent(line("die", "eager_banach", { exitCode: "1", "tiphys.tool": "trivy" }))).toMatchObject({ tool: true });
    expect(parseDockerEvent(line("die", "web", { exitCode: "1" }))).not.toHaveProperty("tool");
    const { app, auth, store, notifier, sent } = await testApp();
    store.get().features.incidents = true;
    const w = new DockerEventWatcher({ store, notifier });
    const t0 = 1_800_000_000;
    const feed = async (a: string, n: string, extra: Record<string, string> = {}, sec = t0) => w.handle(parseDockerEvent(line(a, n, extra, sec))!);
    for (let i = 0; i < 4; i++) await feed("die", "eager_banach", { exitCode: "1", "tiphys.tool": "trivy" }, t0 + i);
    await feed("oom", "eager_banach", { "tiphys.tool": "trivy" }, t0 + 5);
    await feed("die", "brave_curie", { exitCode: "1", "tiphys.tool": "gitleaks" }, t0 + 6);
    await feed("die", "tiphys-restore-x", { exitCode: "1", "tiphys.restore": "1" }, t0 + 7);
    expect(sent).toEqual([]);
    await feed("die", "web", { exitCode: "1" }, t0 + 8);
    expect(keys(sent)).toEqual(["docker.died"]);
    const ev = (await app.inject({ method: "GET", url: "/v1/events", headers: auth })).json().events;
    expect(ev.map((e: { key: string }) => e.key)).toEqual(["docker.died"]);
    await app.close();
  });
});

describe("yedek durumu: ayrıştırma", () => {
  it("systemctl show ve zaman damgaları", () => {
    const p = parseSystemctlShow("Result=exit-code\nExecMainStatus=1\nExecMainExitTimestamp=@1794670853\nActiveEnterTimestamp=\nLoadState=loaded\n");
    expect(p).toEqual({ Result: "exit-code", ExecMainStatus: "1", ExecMainExitTimestamp: "@1794670853", ActiveEnterTimestamp: "", LoadState: "loaded" });
    expect(parseSystemdTimestamp("@1794670853")).toBe(1794670853000);
    expect(parseSystemdTimestamp("")).toBeNull();
    expect(parseSystemdTimestamp("n/a")).toBeNull();
    expect(parseSystemdTimestamp("Sat 2026-11-14 03:00:05 +03")).toBe(new Date("2026-11-14T03:00:05").getTime());
  });

  it("birim durumu", () => {
    const now = 1794670853000 + 3600_000;
    const ok = { LoadState: "loaded", ActiveState: "inactive", Result: "success", ExecMainExitTimestamp: "@1794670853" };
    expect(unitState(ok, "user", { maxAgeHours: 26 }, now)).toMatchObject({ status: "ok", lastAt: new Date(1794670853000).toISOString(), target: "user", running: false });
    expect(unitState(ok, "user", { maxAgeHours: 0.5 }, now).status).toBe("stale");
    expect(unitState({ ...ok, ActiveState: "failed", Result: "exit-code" }, "system", { maxAgeHours: 26 }, now)).toMatchObject({ status: "failed", detail: "exit-code" });
    expect(unitState({ LoadState: "loaded", ActiveState: "inactive", Result: "success", ExecMainExitTimestamp: "", InactiveEnterTimestamp: "", ActiveEnterTimestamp: "" }, "user", { maxAgeHours: 26 }, now)).toMatchObject({ status: "missing", detail: "never-ran" });
    expect(unitState(null, null, { maxAgeHours: 26 }, now)).toMatchObject({ status: "missing", detail: "not-found" });
    expect(unitState({ ...ok, ActiveState: "activating" }, "user", { maxAgeHours: 26 }, now)).toMatchObject({ status: "ok", running: true });
  });

  it("glob ve en yeni dosya", async () => {
    expect(globToRegExp("obsidian-*.json.gz").test("obsidian-2026-11-14.json.gz")).toBe(true);
    expect(globToRegExp("obsidian-*.json.gz").test("obsidian-x.jsonXgz")).toBe(false);
    expect(globToRegExp("a?.tar").test("ab.tar")).toBe(true);
    const { dir } = await testApp();
    const b = join(dir, "b");
    await mkdir(b);
    await mkdir(join(b, "x-dir.gz"));
    for (const [n, age, size] of [["x-1.gz", 3, 10], ["x-2.gz", 1, 2000], ["y-3.gz", 0, 5]] as const) {
      await writeFile(join(b, n), "z".repeat(size));
      const t = new Date(Date.now() - age * 3600_000);
      await utimes(join(b, n), t, t);
    }
    const f = await newestFile(join(b, "x-*.gz"));
    expect(f).toMatchObject({ path: join(b, "x-2.gz"), size: 2000 });
    expect(fileState(f, { maxAgeHours: 26, minBytes: 1000 }).status).toBe("ok");
    expect(fileState(f, { maxAgeHours: 0.5, minBytes: 0 }).status).toBe("stale");
    expect(fileState(f, { maxAgeHours: 26, minBytes: 5000 })).toMatchObject({ status: "failed", detail: "too-small" });
    expect(fileState(await newestFile(join(b, "none-*")), { maxAgeHours: 26, minBytes: 0 })).toMatchObject({ status: "missing", detail: "no-match" });
    expect(await newestFile(join(dir, "yok", "*.gz"))).toBeNull();
  });
});

describe("yedek durumu: izleme ve uçlar", () => {
  it("eski systemd (< 251) --timestamp=unix tanımaz: bayraksız yeniden sorulur, yerel saat biçimi okunur", async () => {
    const t = await testApp((c) => ({ ...c, features: { ...c.features, backups: true } }));
    const calls: string[][] = [];
    const runner = (async (_cmd: string, args: string[]): Promise<ExecResult> => {
      calls.push(args);
      if (args.includes("--timestamp=unix")) return { stdout: "", stderr: "Invalid value for --timestamp: unix", code: 1 };
      if (args[0] === "--user") return { stdout: "LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainExitTimestamp=Sat 2026-11-14 03:00:05 +03\n", stderr: "", code: 0 };
      return { stdout: "", stderr: "", code: 1 };
    }) as typeof import("../src/exec.ts").run;
    const monitor = new BackupMonitor({ store: t.store, notifier: t.notifier }, runner);
    const u = await monitor.unitProps("obsidian-backup.service");
    expect(u).toMatchObject({ scope: "user", props: { LoadState: "loaded", Result: "success" } });
    expect(calls.slice(0, 2)).toEqual([
      ["--user", "show", "--timestamp=unix", "-p", "LoadState,ActiveState,Result,ExecMainStatus,ExecMainExitTimestamp,InactiveEnterTimestamp,ActiveEnterTimestamp", "--", "obsidian-backup.service"],
      ["--user", "show", "-p", "LoadState,ActiveState,Result,ExecMainStatus,ExecMainExitTimestamp,InactiveEnterTimestamp,ActiveEnterTimestamp", "--", "obsidian-backup.service"],
    ]);
    const now = new Date("2026-11-14T05:00:00").getTime();
    expect(unitState(u!.props, u!.scope, { maxAgeHours: 26 }, now)).toMatchObject({ status: "ok", lastAt: new Date("2026-11-14T03:00:05").toISOString() });
    await t.app.close();
  });

  it("ilk değerlendirme sessiz; geçişler bildirilir; uçlar ve ayar", async () => {
    const t = await testApp((c) => ({ ...c, features: { ...c.features, backups: true } }));
    const dir = join(t.dir, "bk");
    await mkdir(dir);
    let unitProps = "LoadState=loaded\nActiveState=inactive\nResult=success\nExecMainExitTimestamp=@" + Math.floor(Date.now() / 1000 - 3600);
    const calls: string[][] = [];
    const runner = (async (_cmd: string, args: string[]): Promise<ExecResult> => {
      calls.push(args);
      if (args[0] === "--user") return { stdout: "LoadState=not-found\nResult=success\n", stderr: "", code: 0 };
      return { stdout: unitProps, stderr: "", code: 0 };
    }) as typeof import("../src/exec.ts").run;
    const monitor = new BackupMonitor({ store: t.store, notifier: t.notifier }, runner);
    await t.app.close();
    // Set up the endpoints with a real server and a fake systemctl.
    const { buildApp } = await import("../src/server.ts");
    const app = await buildApp({ store: t.store, notifier: t.notifier, extraRoutes: [(a, ctx) => backupRoutes(a, ctx, monitor, false)] });
    const patch = (checks: unknown) => app.inject({ method: "PATCH", url: "/v1/config", headers: t.auth, payload: { backups: { checks } } });
    expect((await patch([{ id: "bad", name: "x", kind: "file" }])).statusCode).toBe(400);
    expect((await patch([{ id: "bad", name: "x", kind: "file", path: "/a/*/b.gz" }])).statusCode).toBe(400);
    const res = await patch([
      { id: "obsidian", name: "Obsidian", kind: "file", path: join(dir, "obsidian-*.json.gz"), maxAgeHours: 26, minBytes: 100 },
      { id: "db", name: "Veritabanı", kind: "unit", unit: "db-backup.service" },
    ]);
    expect(res.statusCode).toBe(200);
    expect(res.json().restartRequired).toBe(false);
    expect(res.json().config.backups.checks[1]).toMatchObject({ id: "db", maxAgeHours: 26, minBytes: 0 });
    const list = (await app.inject({ method: "GET", url: "/v1/backups", headers: t.auth })).json();
    expect(list.intervalMinutes).toBe(15);
    expect(list.checks.map((c: { id: string; state: { status: string } }) => [c.id, c.state.status])).toEqual([
      ["obsidian", "missing"],
      ["db", "ok"],
    ]);
    expect(list.checks[1].state.target).toBe("system"); // not a user unit → system unit
    expect(calls.at(-1)).toEqual(["show", "--timestamp=unix", "-p", "LoadState,ActiveState,Result,ExecMainStatus,ExecMainExitTimestamp,InactiveEnterTimestamp,ActiveEnterTimestamp", "--", "db-backup.service"]);
    expect(t.sent).toEqual([]); // the first evaluation is silent

    await writeFile(join(dir, "obsidian-1.json.gz"), "z".repeat(500));
    const r = await app.inject({ method: "POST", url: "/v1/backups/obsidian/check", headers: t.auth });
    expect(r.json().check.state).toMatchObject({ status: "ok", sizeBytes: 500 });
    expect(t.sent.at(-1)).toMatchObject({ key: "backup.ok", params: { name: "Obsidian", host: "test", id: "obsidian" }, link: "tiphys://system/backups" });

    unitProps = unitProps.replace("Result=success", "Result=exit-code").replace("ActiveState=inactive", "ActiveState=failed");
    await monitor.checkAll();
    expect(t.sent.at(-1)).toMatchObject({ key: "backup.failed", params: { name: "Veritabanı", reason: "exit-code" }, priority: "high" });
    const n = t.sent.length;
    await monitor.checkAll(); // no change → no notification
    expect(t.sent.length).toBe(n);
    await monitor.checkAll(Date.now() + 30 * 3600_000); // obsidian went stale
    expect(t.sent.at(-1)).toMatchObject({ key: "backup.stale", params: { name: "Obsidian", hours: 30 } });

    expect((await app.inject({ method: "POST", url: "/v1/backups/yok/check", headers: t.auth })).statusCode).toBe(404);
    const ev = (await app.inject({ method: "GET", url: "/v1/events", headers: t.auth })).json().events;
    expect(ev.map((e: { key: string }) => e.key)).toEqual(["backup.stale", "backup.failed", "backup.ok"]);
    // When a check is deleted, its state is forgotten too.
    await patch([]);
    await monitor.checkAll();
    expect(monitor.states.size).toBe(0);
    const saved = JSON.parse(await readFile(t.store.path, "utf8")) as AgentConfig;
    expect(saved.backups.checks).toEqual([]);
    await app.close();
  });

  it("özellik kapalıyken uç yok, olay ucu her zaman var", async () => {
    const { app, auth } = await testApp();
    expect((await app.inject({ method: "GET", url: "/v1/backups", headers: auth })).statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: "/v1/events", headers: auth })).statusCode).toBe(200);
    expect((await app.inject({ method: "GET", url: "/v1/health" })).json().features.backups).toBe(false);
    await app.close();
  });
});
