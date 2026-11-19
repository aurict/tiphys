// Security center S-3 (PLAN.md §15): decoy tokens, decoy files (access time), auditd events, decoy DB users in Loki,
// critical relay to Telegram.
import { mkdtemp, readFile, rm, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { alertRelay, alertText, isCritical } from "../src/security/alerts.ts";
import { knownHostsPath, type Spawner } from "../src/security/collect.ts";
import { securityRoutes } from "../src/security/routes.ts";
import { mountOptions, parseAusearchCsv, TrapService } from "../src/security/traps.ts";
import { testApp } from "./helpers.ts";

const CSV_HEAD = "NODE,EVENT,DATE,TIME,SERIAL_NUM,EVENT_KIND,SESSION,SUBJ_PRIME,SUBJ_SEC,SUBJ_KIND,ACTION,RESULT,OBJ_PRIME,OBJ_SEC,OBJ_KIND,HOW";
const csvLine = (serial: number) => `atlas,SYSCALL,11/19/2026,10:00:0${serial % 10},${serial},audit-rule,3,mallory,mallory,user,opened-file,success,/opt/app/.env.backup,,file,/usr/bin/cat`;

describe("helpers", () => {
  it("mount options by longest prefix", () => {
    const m = "/dev/sda1 / ext4 rw,relatime 0 0\n/dev/sdb1 /home ext4 rw,noatime 0 0\ntmpfs /home/u/tmp tmpfs rw 0 0\n";
    expect(mountOptions(m, "/home/u/.env")).toContain("noatime");
    expect(mountOptions(m, "/home/u/tmp/x")).toEqual(["rw"]);
    expect(mountOptions(m, "/opt/x")).toContain("relatime");
  });

  it("ausearch CSV", () => {
    const e = parseAusearchCsv(`@@tiphys-audit 2 traps\n${CSV_HEAD}\n${csvLine(1)}\ngarbage\n@@end\n`);
    expect(e).toEqual([{ key: "11/19/2026 10:00:01#1", at: "11/19/2026 10:00:01", who: "mallory/mallory", how: "/usr/bin/cat", object: "/opt/app/.env.backup" }]);
  });

  it("critical notices and their short Telegram text", () => {
    expect(isCritical({ key: "security.trap", params: { host: "atlas", trap: "file", path: "/home/u/.env.backup" } })).toBe(true);
    expect(isCritical({ key: "security.change", params: { severity: "warning" } })).toBe(false);
    expect(isCritical({ key: "security.change", params: { severity: "critical" } })).toBe(true);
    expect(isCritical({ key: "security.vulns", params: {} })).toBe(false);
    const t = alertText({ key: "security.trap", params: { host: "atlas", trap: "file", path: "/home/u/.env.backup" } });
    expect(t).toBe("🚨 Tiphys güvenlik · atlas · tuzak tetiklendi");
    expect(t).not.toContain(".env");
  });
});

describe("traps", () => {
  async function setup(extra: { spawner?: Spawner; fetch?: typeof fetch } = {}) {
    const root = await mkdtemp(join(tmpdir(), "tiphys-traps-"));
    let now = Date.now();
    const t = await testApp(
      (c) => {
        c.allowedRoots = [root];
        c.security.traps.dbUsers = ["svc_report_ro"];
        c.security.scanners.loki = { url: "http://loki.example:3100" };
        return c;
      },
      [securityRoutes({ startTimer: false, trapOpts: { spawner: extra.spawner, fetch: extra.fetch, now: () => now } })],
    );
    const svc = new TrapService({ store: t.store, notifier: t.notifier }, { spawner: extra.spawner, fetch: extra.fetch, now: () => now });
    return { ...t, root, svc, tick: (ms: number) => (now += ms) };
  }
  const traps = (sent: unknown[]) => sent.filter((n) => (n as { key: string }).key === "security.trap") as Array<{ params: Record<string, unknown>; priority: string }>;

  it("decoy token: same 401 as any unknown token, alarm once a minute; other tokens no alarm", async () => {
    const t = await setup();
    const r = await t.app.inject({ method: "POST", url: "/v1/security/traps/tokens", headers: t.auth, payload: { name: "atlas .env.old" } });
    expect(r.statusCode).toBe(201);
    const { token, id } = r.json();
    expect(token).toMatch(/^tps_/);
    expect(JSON.stringify(t.store.get())).not.toContain(token);
    const use = () => t.app.inject({ method: "GET", url: "/v1/security/overview", headers: { authorization: `Bearer ${token}` } });
    const res = await use();
    expect(res.statusCode).toBe(401);
    expect(res.json().error.code).toBe("agent.auth.invalidToken");
    await use();
    await new Promise((x) => setTimeout(x, 20));
    expect(traps(t.sent)).toEqual([expect.objectContaining({ priority: "high", params: expect.objectContaining({ trap: "token", name: "atlas .env.old", path: "/v1/security/overview" }) })]);
    await t.app.inject({ method: "GET", url: "/v1/security/overview", headers: { authorization: `Bearer tps_${"x".repeat(43)}` } });
    expect(traps(t.sent)).toHaveLength(1);
    expect((await t.app.inject({ method: "GET", url: "/v1/security/traps", headers: t.auth })).json().tokens).toEqual([expect.objectContaining({ id, name: "atlas .env.old" })]);
    expect((await t.app.inject({ method: "GET", url: "/v1/security/traps", headers: t.auth })).body).not.toContain("tokenHash");
  });

  it("decoy .env: created once (0600) inside allowedRoots, its token is a trap, reads set off the alarm, re-armed", async () => {
    const t = await setup();
    const path = join(t.root, ".env.backup");
    const r = await t.svc.createFile(path, "env");
    expect(r.status).toBe("armed");
    expect((await stat(path)).mode & 0o777).toBe(0o600);
    const text = await readFile(path, "utf8"); // this read is the "intruder"
    expect(text).toMatch(/DATABASE_URL=postgres:\/\/svc_report_ro:/);
    await t.svc.checkFiles();
    expect(traps(t.sent).map((n) => n.params.trap)).toEqual(["file"]);
    await t.svc.checkFiles();
    expect(traps(t.sent)).toHaveLength(1);
    t.tick(120_000);
    await readFile(path);
    await t.svc.checkFiles();
    expect(traps(t.sent)).toHaveLength(2);
    // The token inside is a decoy too.
    const tok = /TIPHYS_TOKEN=(\S+)/.exec(text)![1]!;
    await t.app.inject({ method: "GET", url: "/v1/security/overview", headers: { authorization: `Bearer ${tok}` } });
    await new Promise((x) => setTimeout(x, 20));
    expect(traps(t.sent).at(-1)!.params.trap).toBe("token");
    await expect(t.svc.createFile(path, "env")).rejects.toMatchObject({ code: "agent.security.trapExists" });
    await expect(t.svc.createFile("/etc/decoy", "env")).rejects.toMatchObject({ code: "agent.path.notAllowed" });
    expect(t.store.get().security.traps.tokens).toHaveLength(1); // the failed create left no orphan token
    await rm(path);
    await t.svc.checkFiles();
    await t.svc.checkFiles();
    expect(traps(t.sent).filter((n) => n.params.trap === "fileMissing")).toHaveLength(1);
  });

  it("noatime mount: reported, never armed", async () => {
    const t = await setup();
    const svc = new TrapService({ store: t.store, notifier: t.notifier }, { mounts: async () => `/dev/x / ext4 rw,noatime 0 0\n` });
    expect((await svc.createFile(join(t.root, "id_backup"), "sshkey")).status).toBe("noatime");
    expect(await readFile(join(t.root, "id_backup"), "utf8")).toMatch(/BEGIN PRIVATE KEY/);
  });

  it("auditd events from SSH hosts: first poll only learns, then each event once", async () => {
    let lines = [csvLine(1)];
    const calls: string[][] = [];
    const spawner: Spawner = async (_cmd, args) => {
      calls.push(args);
      return { code: 0, stdout: `@@tiphys-audit 2 traps\n${CSV_HEAD}\n${lines.join("\n")}\n@@end\n`, stderr: "" };
    };
    const t = await setup({ spawner });
    await t.store.update((c) => {
      c.security.hosts.push({ id: "orion", name: "orion", role: "server", allowedPorts: [], source: { kind: "ssh", host: "orion", user: "tiphys-audit", port: 22, keyPath: "/k" }, traps: true });
      return c;
    });
    await writeFile(knownHostsPath(t.store.path), "orion x\n");
    await t.svc.checkAudit(false);
    expect(traps(t.sent)).toEqual([]);
    expect(calls[0]!.at(-1)).toBe("traps");
    lines = [csvLine(1), csvLine(2)];
    await t.svc.checkAudit();
    await t.svc.checkAudit();
    expect(traps(t.sent)).toEqual([expect.objectContaining({ params: expect.objectContaining({ trap: "audit", host: "orion", who: "mallory/mallory", how: "/usr/bin/cat" }) })]);
  });

  it("decoy database user in the logs", async () => {
    const urls: string[] = [];
    const fetchFake = (async (u: string) => {
      urls.push(decodeURIComponent(String(u)));
      return new Response(
        JSON.stringify({
          data: {
            result: [
              { stream: { host: "orion", container: "app-postgres-1" }, values: [["1794998587000000000", 'FATAL:  password authentication failed for user "svc_report_ro"'], ["1794998588000000000", 'FATAL: password authentication failed for user "bob"']] },
            ],
          },
        }),
      );
    }) as unknown as typeof fetch;
    const t = await setup({ fetch: fetchFake });
    await t.svc.checkDbUsers(async () => "http://loki.example:3100");
    await t.svc.checkDbUsers(async () => "http://loki.example:3100");
    expect(traps(t.sent)).toEqual([expect.objectContaining({ params: expect.objectContaining({ trap: "db", user: "svc_report_ro", host: "orion", stream: "app-postgres-1" }) })]);
    expect(urls[0]).toContain("(svc_report_ro)");
  });

  it("relay: critical notices go to the chosen Telegram recipient, title only", async () => {
    const t = await setup();
    await t.store.update((c) => {
      c.telegram = { botToken: `123456:${"A".repeat(35)}`, botUsername: "bot", botId: 1 };
      c.security.alerts.telegramRecipient = "r1";
      return c;
    });
    await writeFile(join(t.dir, "telegram-state.json"), JSON.stringify({ version: 1, updateOffset: 0, recipients: [{ id: "r1", chatId: 42, status: "active" }], invites: [], feeds: [], issues: [] }));
    const bodies: unknown[] = [];
    const fetchFake = (async (_u: string, init: RequestInit) => {
      bodies.push(JSON.parse(String(init.body)));
      return new Response(JSON.stringify({ ok: true, result: { message_id: 1 } }));
    }) as unknown as typeof fetch;
    const relay = alertRelay({ store: t.store, notifier: t.notifier }, { fetch: fetchFake });
    relay({ key: "security.trap", params: { host: "atlas", trap: "file", path: "/secret/place" } });
    relay({ key: "security.vulns", params: { host: "atlas" } });
    await new Promise((x) => setTimeout(x, 50));
    expect(bodies).toEqual([expect.objectContaining({ chat_id: 42, text: "🚨 Tiphys güvenlik · atlas · tuzak tetiklendi" })]);
  });
});
