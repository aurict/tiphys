// Security center S-1 (PLAN.md §15): audit.sh contract, parser, rules/score, baseline/diff, collectors, service, routes.
import { execFile } from "node:child_process";
import { mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import { createServiceToken } from "../src/service_tokens.ts";
import { signalOf } from "../src/incidents/signals.ts";
import { diff, snapshotOf } from "../src/security/baseline.ts";
import { collectAgent, collectLocal, HELPER_PATH, knownHostsPath, sshArgs, type Spawner } from "../src/security/collect.ts";
import { classifyAddress, parseListen, parseReport, parseSshd } from "../src/security/report.ts";
import { securityRoutes } from "../src/security/routes.ts";
import { evaluate, exposures, score } from "../src/security/rules.ts";
import { SecurityService, UNREACHABLE_NOTIFY_MS } from "../src/security/service.ts";
import { testApp } from "./helpers.ts";

const pexec = promisify(execFile);

/** Synthetic audit output; `over` replaces whole sections. Names and addresses are examples only. */
function auditText(over: Record<string, string> = {}, mode = "report") {
  const base: Record<string, string> = {
    meta: "hostname atlas\nkernel 6.8.0\narch aarch64\nos Ubuntu 26.04 LTS\nuptime 1234.5\nroot 1\ntime 2026-11-18T10:00:00Z",
    listen: [
      "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:((\"sshd\",pid=1,fd=3))",
      "tcp LISTEN 0 128 [::]:22 [::]:* users:((\"sshd\",pid=1,fd=4))",
      "tcp LISTEN 0 4096 127.0.0.1:5432 0.0.0.0:*",
      "tcp LISTEN 0 4096 100.100.1.2%tailscale0:443 0.0.0.0:*",
      "tcp LISTEN 0 4096 [fd7a:115c:a1e0::1]%tailscale0:443 [::]:*",
      "udp UNCONN 0 0 0.0.0.0:41641 0.0.0.0:*",
    ].join("\n"),
    sshd: "@@mode effective\nport 22\npermitrootlogin no\npasswordauthentication no\nkbdinteractiveauthentication no\nusepam yes\nx11forwarding no\nallowtcpforwarding no\nmaxauthtries 3\nallowusers ubuntu",
    users: "root 0 0 /bin/bash\nubuntu 1001 1001 /bin/bash",
    passwords: "",
    groups: "sudo ubuntu\ndocker ubuntu",
    sudoers: `${"a".repeat(64)}  /etc/sudoers\n${"b".repeat(64)}  /etc/sudoers.d/90-cloud-init-users`,
    authkeys: "ubuntu /home/ubuntu/.ssh/authorized_keys 256 SHA256:AAAAexampleFingerprint admin (ED25519)",
    cron: `${"c".repeat(64)}  /etc/cron.d/e2scrub_all`,
    timers: "system apt-daily.timer apt-daily.service",
    autostart: "@@unavailable user",
    updates: "pending 3\nsecurity 0\nunattended 1\nlistsUpdated 1794994030\nrebootRequired no",
    services: "auditd active enabled\napparmor active enabled\nufw inactive disabled\nnftables active disabled",
    sysctl: "kernel.randomize_va_space 2\nkernel.kptr_restrict 1\nfs.protected_symlinks 1\nnet.ipv4.ip_forward 1",
    logins: "ubuntu pts/0 100.100.1.9 Wed Nov 18 08:50:31 2026",
    docker:
      "@@version 29.1.3\n" +
      "c|/web|ghcr.io/example/web:1|sha256:" + "1".repeat(64) + "|false|app_default||false|||/srv/web:/data:true;|100.100.1.2:8080->80/tcp;|app|web\n" +
      "i|sha256:" + "1".repeat(64) + "|ghcr.io/example/web:1|ghcr.io/example/web@sha256:" + "2".repeat(64) + "|1000|2026-11-01T00:00:00Z",
    ...over,
  };
  let out = `@@tiphys-audit 1 ${mode}\n`;
  for (const [k, v] of Object.entries(base)) out += `\n@@section ${k}\n${v}\n`;
  return `${out}\n@@end\n`;
}

describe("audit.sh", () => {
  it("rejects anything but the fixed modes without running commands", async () => {
    for (const args of [["report; id"], ["image-save", "x"], ["--help"], ["report", "report"], ["$(id)"]]) {
      const r = await pexec("sh", [HELPER_PATH, ...args]).catch((e: { code: number; stdout: string; stderr: string }) => e);
      expect((r as { code: number }).code, args.join(" ")).toBe(2);
      expect((r as { stdout: string }).stdout).toBe("");
    }
  });

  it("produces a parseable report without root", async () => {
    const { stdout } = await pexec("sh", [HELPER_PATH, "report"], { timeout: 120_000, maxBuffer: 8 << 20 });
    const r = parseReport(stdout);
    expect(r.mode).toBe("report");
    expect(r.meta.hostname).not.toBe("");
    if (process.getuid?.() !== 0) {
      expect(r.root).toBe(false);
      expect(r.passwords).toBeNull();
      expect(r.unavailable).toContain("passwords");
    }
    // Every running container's image is listed (docker 29 broke `join` on these fields once).
    if (r.docker && r.docker.containers.length) {
      expect(r.docker.images.length).toBeGreaterThan(0);
      for (const c of r.docker.containers) expect(r.docker.images.map((i) => i.id)).toContain(c.imageId);
    }
    // Never key material or hashes from /etc/shadow.
    expect(stdout).not.toMatch(/PRIVATE KEY|\$6\$|\$y\$/);
  }, 130_000);

  it("contains no environment dump in the docker template", async () => {
    const src = await readFile(HELPER_PATH, "utf8");
    expect(src).not.toMatch(/\.Config\.Env|\.Config\.Cmd|\{\{json \.\}\}/);
    expect(src).toMatch(/^set -u$/m);
    expect(src).toMatch(/^PATH=\/usr\/sbin:\/usr\/bin:\/sbin:\/bin$/m);
  });
});

describe("parser", () => {
  it("parses every section", () => {
    const r = parseReport(auditText());
    expect(r.root).toBe(true);
    expect(r.meta).toMatchObject({ hostname: "atlas", arch: "aarch64", uptimeSec: 1235 });
    expect(r.listen!.map((l) => `${l.proto}/${l.port}/${l.scope}`)).toEqual([
      "tcp/22/wildcard",
      "tcp/22/wildcard",
      "tcp/5432/loopback",
      "tcp/443/tailscale",
      "tcp/443/tailscale",
      "udp/41641/wildcard",
    ]);
    expect(r.listen![0]!.process).toBe("sshd");
    expect(r.sshd!.settings.passwordauthentication).toEqual(["no"]);
    expect(r.passwords).toEqual([]);
    expect(r.sudoers).toHaveLength(2);
    expect(r.authKeys[0]).toMatchObject({ user: "ubuntu", bits: 256, comment: "admin", type: "ED25519" });
    expect(r.updates).toMatchObject({ pending: 3, security: 0, unattended: true, rebootRequiredSince: null });
    expect(r.autostart).toBeNull();
    expect(r.unavailable).toEqual(["autostart"]);
    expect(r.docker!.containers[0]).toMatchObject({ name: "web", project: "app", service: "web", ports: [{ hostIp: "100.100.1.2", hostPort: 8080, container: "80/tcp" }] });
    expect(r.docker!.containers[0]!.mounts).toEqual([{ source: "/srv/web", destination: "/data", rw: true }]);
    expect(r.docker!.images[0]!.digests[0]).toMatch(/@sha256:/);
    // audit.sh v2 prints lists with a trailing comma ({{range}}); an image without tags has an empty field.
    const r2 = parseReport(auditText({ docker: "@@version 1\ni|sha256:" + "3".repeat(64) + "|a:1,b:2,||5|2026-01-01" }));
    expect(r2.docker!.images[0]).toMatchObject({ tags: ["a:1", "b:2"], digests: [] });
    expect(r.suid).toBeNull();
  });

  it("rejects non-reports and truncated output", () => {
    expect(() => parseReport("hello")).toThrow();
    expect(() => parseReport(auditText().replace("@@end", ""))).toThrow(/truncated/);
  });

  it("classifies addresses", () => {
    expect(classifyAddress("0.0.0.0", null)).toBe("wildcard");
    expect(classifyAddress("*", null)).toBe("wildcard");
    expect(classifyAddress("::", null)).toBe("wildcard");
    expect(classifyAddress("127.0.0.53", "lo")).toBe("loopback");
    expect(classifyAddress("100.82.1.1", null)).toBe("tailscale");
    expect(classifyAddress("fd7a:115c:a1e0::5", null)).toBe("tailscale");
    expect(classifyAddress("10.0.0.26", "enp0s6")).toBe("private");
    expect(classifyAddress("fe80::1", "eth0")).toBe("linklocal");
    expect(classifyAddress("203.0.113.5", null)).toBe("public");
    expect(parseListen(["udp UNCONN 0 0 [fe80::e6b9:aa17:3d7b:3ed]%enp37s0:546 [::]:*", "tcp LISTEN 0 50 *:1716 *:*"]).map((l) => l.scope)).toEqual(["linklocal", "wildcard"]);
  });

  it("sshd config mode: drop-ins at Include, first value wins, Match ends, defaults", () => {
    const s = parseSshd([
      "@@mode config",
      "@@file /etc/ssh/sshd_config",
      "PasswordAuthentication yes",
      "Include /etc/ssh/sshd_config.d/*.conf",
      "PermitRootLogin yes",
      "Match User git",
      "PasswordAuthentication no",
      "@@file /etc/ssh/sshd_config.d/10-hardening.conf",
      "PermitRootLogin no",
      "PasswordAuthentication no",
    ])!;
    expect(s.mode).toBe("config");
    expect(s.settings.passwordauthentication).toEqual(["yes"]);
    expect(s.settings.permitrootlogin).toEqual(["no"]);
  });
});

describe("rules", () => {
  const policy = { role: "server" as const, allowedPorts: [] };

  it("flags exposed ports except allowed and defaults; docker wildcard publishes count", () => {
    const r = parseReport(
      auditText({
        docker:
          "@@version 1\nc|/gitea|gitea/gitea:1|sha256:x|false|bridge||false|||/var/run/docker.sock:/var/run/docker.sock:false;|0.0.0.0:2222->22/tcp;:::2222->22/tcp;|g|gitea",
      }),
    );
    expect(exposures(r).map((e) => `${e.proto}/${e.port}`)).toEqual(["tcp/22", "tcp/2222", "udp/41641"]);
    const f = evaluate(r, policy);
    expect(f.filter((x) => x.rule === "port.exposed").map((x) => x.id)).toEqual(["port.exposed:tcp/22", "port.exposed:tcp/2222"]);
    expect(f.find((x) => x.id === "port.exposed:tcp/2222")!.params.process).toBe("docker:gitea");
    expect(f.some((x) => x.rule === "docker.socket")).toBe(true);
    const allowed = evaluate(r, { role: "server", allowedPorts: ["tcp/22", "tcp/2222"] });
    expect(allowed.some((x) => x.rule === "port.exposed")).toBe(false);
    expect(allowed.some((x) => x.rule === "firewall.none")).toBe(false);
  });

  it("clean server scores high; risky settings lower it", () => {
    const clean = evaluate(parseReport(auditText()), { role: "server", allowedPorts: ["tcp/22"] });
    expect(clean.map((x) => x.rule)).toEqual(["updates.pending"]);
    expect(score(clean)).toBe(98);
    const bad = parseReport(
      auditText({
        sshd: "@@mode config\n@@file /etc/ssh/sshd_config\nUsePAM yes",
        users: "root 0 0 /bin/bash\ntoor 0 0 /bin/sh",
        passwords: "ubuntu empty",
        updates: "pending 9\nsecurity 2\nunattended 0\nrebootRequired 1",
        services: "auditd inactive enabled\napparmor active enabled",
        sysctl: "kernel.randomize_va_space 0\nfs.suid_dumpable 2",
      }),
    );
    const f = evaluate(bad, policy);
    const rules = f.map((x) => x.rule);
    expect(rules.slice(0, 2).sort()).toEqual(["users.emptyPassword", "users.uid0"]);
    for (const r of ["ssh.passwordAuth", "ssh.kbdInteractive", "ssh.rootLogin", "ssh.tcpForwarding", "ssh.maxAuthTries", "updates.security", "updates.reboot", "updates.unattendedOff", "service.auditd", "sysctl.weak", "firewall.none"]) {
      expect(rules, r).toContain(r);
    }
    expect(f.find((x) => x.rule === "ssh.rootLogin")!.severity).toBe("low");
    expect(f.find((x) => x.rule === "updates.reboot")!.severity).toBe("medium");
    expect(f.find((x) => x.rule === "sysctl.weak")!.params.count).toBe(2);
    expect(score(f)).toBe(0);
  });

  it("auditd/apparmor: installed-but-stopped only", () => {
    const r = parseReport(auditText({ services: "auditd inactive not-found\napparmor inactive enabled" }));
    const rules = evaluate(r, { role: "server", allowedPorts: ["tcp/22"] }).map((x) => x.rule);
    expect(rules).not.toContain("service.auditd");
    expect(rules).toContain("service.apparmor");
  });

  it("agent file permissions", () => {
    const r = parseReport(auditText().replace("\n@@end", "\n@@section agentfiles\n700 /home/u/.config/tiphys\n644 /home/u/.config/tiphys/agent.json\n@@end"));
    const f = evaluate(r, { role: "desktop", allowedPorts: ["tcp/22"] });
    expect(f.filter((x) => x.rule === "files.agentPerms").map((x) => x.params.path)).toEqual(["/home/u/.config/tiphys/agent.json"]);
  });
});

describe("baseline", () => {
  it("ephemeral UDP client ports don't count as port changes (still findings)", () => {
    const a = snapshotOf(parseReport(auditText({ listen: "udp UNCONN 0 0 0.0.0.0:33257 0.0.0.0:*\nudp UNCONN 0 0 0.0.0.0:4242 0.0.0.0:*" })));
    const b = snapshotOf(parseReport(auditText({ listen: "udp UNCONN 0 0 0.0.0.0:54670 0.0.0.0:*\nudp UNCONN 0 0 0.0.0.0:4242 0.0.0.0:*" })));
    expect(diff(a, b)).toEqual([]);
    expect(evaluate(parseReport(auditText({ listen: "udp UNCONN 0 0 0.0.0.0:54670 0.0.0.0:*" })), { role: "desktop", allowedPorts: [] }).map((f) => f.id)).toContain("port.exposed:udp/54670");
  });

  it("diffs added/removed/changed, skips unknown categories, keeps first-seen", () => {
    const a = snapshotOf(parseReport(auditText()));
    const b = snapshotOf(
      parseReport(
        auditText({
          listen: "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\ntcp LISTEN 0 128 0.0.0.0:8765 0.0.0.0:*",
          users: "root 0 0 /bin/bash\nubuntu 1001 1001 /bin/bash\nmallory 1003 1003 /bin/bash",
          sudoers: `${"a".repeat(64)}  /etc/sudoers\n${"d".repeat(64)}  /etc/sudoers.d/90-cloud-init-users`,
          authkeys: "",
          passwords: "@@unavailable root",
        }),
      ),
    );
    const t0 = new Date("2026-11-18T10:00:00Z");
    const d = diff(a, b, [], t0);
    expect(d.map((c) => `${c.kind}:${c.id}`)).toEqual([
      "removed:authKeys|ubuntu SHA256:AAAAexampleFingerprint",
      "added:ports|tcp/8765",
      "changed:sudoers|/etc/sudoers.d/90-cloud-init-users",
      "added:users|mallory",
    ]);
    expect(d.some((c) => c.category === "passwords")).toBe(false);
    const d2 = diff(a, b, d, new Date("2026-11-18T11:00:00Z"));
    expect(d2.every((c) => c.firstSeenAt === t0.toISOString())).toBe(true);
  });
});

describe("collectors", () => {
  it("ssh arguments pin host keys, no agent, no forwarding, mode only", () => {
    const a = sshArgs({ host: "atlas", user: "tiphys-audit", port: 22, keyPath: "/k/id" }, "/c/security-known-hosts", "report");
    expect(a.slice(-4)).toEqual(["tiphys-audit", "--", "atlas", "report"]);
    for (const o of ["BatchMode=yes", "StrictHostKeyChecking=yes", "UserKnownHostsFile=/c/security-known-hosts", "IdentitiesOnly=yes", "IdentityAgent=none", "ClearAllForwardings=yes"]) {
      expect(a).toContain(o);
    }
    expect(a).toContain("/dev/null");
  });

  it("sudo mode refuses a script the agent user could change", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-sec-"));
    const fake = join(dir, "audit.sh");
    await writeFile(fake, "#!/bin/sh\n", { mode: 0o755 });
    let called = false;
    const spawner: Spawner = async () => {
      called = true;
      return { stdout: "", stderr: "", code: 0 };
    };
    await expect(collectLocal({ mode: "report", sudo: true, configPath: join(dir, "agent.json"), spawner, installedPath: fake })).rejects.toMatchObject({
      code: process.getuid?.() === 0 ? "agent.security.scriptUnsafe" : "agent.security.scriptUnsafe",
    });
    await expect(collectLocal({ mode: "report", sudo: true, configPath: join(dir, "agent.json"), spawner, installedPath: join(dir, "none") })).rejects.toMatchObject({
      code: "agent.security.scriptMissing",
    });
    expect(called).toBe(false);
  });

  it("agent source: bearer token, error mapping, size", async () => {
    let auth = "";
    const ok = (async (_u: string, init: RequestInit) => {
      auth = String((init.headers as Record<string, string>).authorization);
      return new Response(JSON.stringify({ text: auditText() }), { status: 200 });
    }) as unknown as typeof fetch;
    const tok = "tps_" + "x".repeat(30);
    expect(await collectAgent({ mode: "report", source: { url: "https://argo.example.ts.net:7443", token: tok }, fetch: ok })).toContain("@@tiphys-audit");
    expect(auth).toBe(`Bearer ${tok}`);
    const st = (s: number) => (async () => new Response("{}", { status: s })) as unknown as typeof fetch;
    await expect(collectAgent({ mode: "report", source: { url: "https://a", token: tok }, fetch: st(403) })).rejects.toMatchObject({ code: "agent.security.unauthorized" });
    await expect(collectAgent({ mode: "report", source: { url: "https://a", token: tok }, fetch: st(429) })).rejects.toMatchObject({ code: "agent.security.busy" });
    const down = (async () => {
      throw new TypeError("fetch failed");
    }) as unknown as typeof fetch;
    await expect(collectAgent({ mode: "report", source: { url: "https://a", token: tok }, fetch: down })).rejects.toMatchObject({ code: "agent.security.unreachable" });
  });
});

describe("config store", () => {
  it("parallel updates all land and none fails (shared temp file name used to race)", async () => {
    const t = await testApp();
    await Promise.all(Array.from({ length: 20 }, (_, i) => t.store.update((c) => ((c.allowedRoots = [...c.allowedRoots, `/r${i}`]), c))));
    expect(t.store.get().allowedRoots).toHaveLength(21);
    const disk = JSON.parse(await readFile(t.store.path, "utf8"));
    expect(disk.allowedRoots).toHaveLength(21);
  });
});

describe("incident signal", () => {
  it("security.change opens, critical by param; accepted closes", () => {
    const cfg = { name: "atlas", incidents: { links: [] } };
    const s = signalOf({ key: "security.change", params: { host: "atlas", count: 1, categories: "users", severity: "critical" } }, cfg)!;
    expect(s).toMatchObject({ role: "open", kind: "security", fingerprint: "security|atlas|atlas", severity: "critical", targetType: "host" });
    expect(signalOf({ key: "security.change", params: { host: "atlas", severity: "warning" } }, cfg)!.severity).toBe("warning");
    expect(signalOf({ key: "security.accepted", params: { host: "atlas" } }, cfg)!.role).toBe("close");
  });
});

describe("service + routes", () => {
  const sshHost = { id: "atlas", name: "atlas", role: "server" as const, allowedPorts: ["tcp/22"], source: { kind: "ssh" as const, host: "atlas", user: "tiphys-audit", port: 22, keyPath: "~/.ssh/audit" }, traps: false };

  async function setup(texts: { self?: () => string; atlas?: () => string | Error } = {}) {
    let now = Date.parse("2026-11-18T10:00:00Z");
    const calls: string[][] = [];
    const spawner: Spawner = async (cmd, args) => {
      calls.push([cmd, ...args]);
      if (cmd === "ssh") {
        const t = texts.atlas?.() ?? auditText();
        if (t instanceof Error) return { stdout: "", stderr: "ssh: connect to host atlas port 22: Connection refused", code: 255 };
        return { stdout: t.replace(/^@@tiphys-audit 1 \S+/, `@@tiphys-audit 1 ${args.at(-1)}`), stderr: "", code: 0 };
      }
      return { stdout: texts.self?.() ?? auditText({}, args.at(-1)!), stderr: "", code: 0 };
    };
    const t = await testApp(
      (c) => {
        c.security.hosts.push(sshHost);
        return c;
      },
      [securityRoutes({ spawner, now: () => now, startTimer: false })],
    );
    await writeFile(knownHostsPath(t.store.path), "atlas ssh-ed25519 AAAA\n");
    return { ...t, calls, setNow: (n: number) => (now = n), now: () => now };
  }

  it("first report is the silent baseline; a new port notifies once; accepting clears", async () => {
    let listen = auditText();
    const t = await setup({ atlas: () => listen });
    let r = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(r.statusCode).toBe(200);
    expect(r.json().host).toMatchObject({ id: "atlas", score: 98, changes: 0 });
    expect(t.calls[0]![0]).toBe("ssh");
    expect(t.calls[0]!.at(-1)).toBe("report-full"); // first run of the day is full
    expect(t.sent).toEqual([]);

    listen = auditText({ listen: "tcp LISTEN 0 128 0.0.0.0:22 0.0.0.0:*\ntcp LISTEN 0 5 0.0.0.0:4444 0.0.0.0:*", users: "root 0 0 /bin/bash\nubuntu 1001 1001 /bin/bash\nx 1002 1002 /bin/sh" });
    t.setNow(t.now() + 60_000);
    r = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(t.calls[1]!.at(-1)).toBe("report");
    expect(r.json().changes.map((c: { id: string }) => c.id)).toEqual(["ports|tcp/4444", "users|x"]);
    expect(r.json().findings.map((f: { id: string }) => f.id)).toContain("port.exposed:tcp/4444");
    expect(t.sent).toEqual([
      {
        key: "security.change",
        params: { host: "atlas", hostId: "atlas", agent: "test", count: 2, categories: "ports,users", severity: "critical" },
        link: "tiphys://security/atlas",
        priority: "high",
      },
    ]);
    // Same state again: no repeat.
    await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(t.sent).toHaveLength(1);

    expect((await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/baseline", headers: t.auth, payload: {} })).statusCode).toBe(400);
    r = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/baseline", headers: t.auth, payload: { confirm: true, expected: 1 } });
    expect(r.json().error).toMatchObject({ code: "agent.security.changesMoved", params: { expected: 1, current: 2 } });
    r = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/baseline", headers: t.auth, payload: { confirm: true, expected: 2 } });
    expect(r.json()).toMatchObject({ accepted: 2, changes: [] });
    expect(t.sent.at(-1)).toMatchObject({ key: "security.accepted", params: { host: "atlas", count: 2 } });

    const st = await stat(join(t.dir, "security-state.json"));
    expect(st.mode & 0o777).toBe(0o600);
    const audit = await readFile(join(t.dir, "audit.jsonl"), "utf8");
    expect(audit).toContain('"accepted":2');
  });

  it("a report with a different privilege level starts a new baseline silently", async () => {
    let text = auditText({ meta: "hostname atlas\nroot 0", passwords: "@@unavailable root", cron: "" });
    const t = await setup({ atlas: () => text });
    await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    text = auditText();
    const r = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(r.json().changes).toEqual([]);
    expect(t.sent).toEqual([]);
    text = auditText({ cron: "" });
    const r2 = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(r2.json().changes.map((c: { id: string }) => c.id)).toEqual(["cron|/etc/cron.d/e2scrub_all"]);
  });

  it("garbled output: 502 badReport; world-writable list carried from the full report", async () => {
    let text = auditText({ worldwritable: "666 root /etc/x" }, "report-full");
    const t = await setup({ atlas: () => text });
    let r = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(r.json().findings.map((f: { rule: string }) => f.rule)).toContain("files.worldWritable");
    text = auditText();
    r = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(r.json().findings.map((f: { rule: string }) => f.rule)).toContain("files.worldWritable");
    expect(r.json().report.worldWritable).toHaveLength(1);
    text = "garbage";
    r = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(r.statusCode).toBe(502);
    expect(r.json().error.code).toBe("agent.security.badReport");
  });

  it("unreachable: keeps last report, notifies once after 6 h, then reachable", async () => {
    let fail = false;
    const t = await setup({ atlas: () => (fail ? new Error("down") : auditText()) });
    await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    fail = true;
    t.setNow(t.now() + 3600_000);
    let r = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(r.statusCode).toBe(502);
    expect(r.json().error.code).toBe("agent.security.sshFailed");
    expect(t.sent).toEqual([]);
    t.setNow(t.now() + UNREACHABLE_NOTIFY_MS);
    await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(t.sent.map((n) => (n as { key: string }).key)).toEqual(["security.unreachable"]);
    r = await t.app.inject({ method: "GET", url: "/v1/security/hosts/atlas", headers: t.auth });
    expect(r.json().host).toMatchObject({ stale: true, lastError: { code: "agent.security.sshFailed" } });
    expect(r.json().report.meta.hostname).toBe("atlas");
    expect(r.json().report).toHaveProperty("firewall", null);
    fail = false;
    await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} }).catch(() => {});
    await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    // 6 checks in 10 min per device: the 7th is rate limited.
    r = await t.app.inject({ method: "POST", url: "/v1/security/hosts/atlas/check", headers: t.auth, payload: {} });
    expect(r.statusCode).toBe(429);
    expect(t.sent.map((n) => (n as { key: string }).key)).toEqual(["security.unreachable", "security.reachable"]);
  });

  it("host settings: token hidden, kept on same URL, required on new URL, self permanent", async () => {
    const t = await setup();
    const tok = "tps_" + "y".repeat(40);
    let r = await t.app.inject({
      method: "POST",
      url: "/v1/security/hosts",
      headers: t.auth,
      payload: { id: "argo", name: "argo (PC)", role: "desktop", source: { kind: "agent", url: "https://argo.example.ts.net:7443", token: tok } },
    });
    expect(r.statusCode).toBe(201);
    expect(r.body).not.toContain(tok);
    r = await t.app.inject({ method: "GET", url: "/v1/security/hosts", headers: t.auth });
    expect(r.body).not.toContain(tok);
    expect(r.json().hosts[1].source).toEqual({ kind: "agent", url: "https://argo.example.ts.net:7443", hasToken: true });
    r = await t.app.inject({ method: "PATCH", url: "/v1/security/hosts/argo", headers: t.auth, payload: { source: { kind: "agent", url: "https://argo.example.ts.net:7443" } } });
    expect(r.statusCode).toBe(200);
    expect(t.store.get().security.hosts[1]!.source).toMatchObject({ token: tok });
    r = await t.app.inject({ method: "PATCH", url: "/v1/security/hosts/argo", headers: t.auth, payload: { source: { kind: "agent", url: "https://evil.example:7443" } } });
    expect(r.json().error.code).toBe("agent.security.tokenRequired");
    r = await t.app.inject({ method: "POST", url: "/v1/security/hosts", headers: t.auth, payload: { id: "bad", name: "b", source: { kind: "ssh", host: "-oProxyCommand=x", user: "a", keyPath: "/k" } } });
    expect(r.statusCode).toBe(400);
    r = await t.app.inject({ method: "POST", url: "/v1/security/hosts", headers: t.auth, payload: { id: "plain", name: "p", source: { kind: "agent", url: "http://argo:7443", token: tok } } });
    expect(r.statusCode).toBe(400);
    expect((await t.app.inject({ method: "DELETE", url: "/v1/security/hosts/self", headers: t.auth })).statusCode).toBe(409);
    r = await t.app.inject({ method: "PATCH", url: "/v1/security/hosts/self", headers: t.auth, payload: { role: "desktop", allowedPorts: ["tcp/22"], sudo: true } });
    expect(r.json().self).toMatchObject({ role: "desktop", allowedPorts: ["tcp/22"], sudo: true });
    for (const bad of ["tcp/0", "tcp/65536", "tcp/99999", "icmp/1"]) {
      r = await t.app.inject({ method: "PATCH", url: "/v1/security/hosts/self", headers: t.auth, payload: { allowedPorts: [bad] } });
      expect(r.statusCode, bad).toBe(400);
    }
    r = await t.app.inject({ method: "PATCH", url: "/v1/security/hosts/self", headers: t.auth, payload: { name: "x" } });
    expect(r.statusCode).toBe(400);
    // GET /v1/config never carries the security section.
    r = await t.app.inject({ method: "GET", url: "/v1/config", headers: t.auth });
    expect(r.body).not.toContain(tok);
    // state file and audit log carry no token either
    expect(await readFile(join(t.dir, "audit.jsonl"), "utf8")).not.toContain(tok);
  });

  it("raw endpoint: security-report scope only; other routes deny it; overview lists self + hosts", async () => {
    const t = await setup();
    const { token } = await createServiceToken(t.store, "atlas", ["security-report"]);
    const { token: research } = await createServiceToken(t.store, "x", ["research"]);
    const svc = { authorization: `Bearer ${token}` };
    let r = await t.app.inject({ method: "GET", url: "/v1/security/raw?mode=report", headers: svc });
    expect(r.statusCode).toBe(200);
    expect(r.json().text).toContain("@@section agentfiles");
    expect((await t.app.inject({ method: "GET", url: "/v1/security/raw", headers: { authorization: `Bearer ${research}` } })).statusCode).toBe(403);
    expect((await t.app.inject({ method: "GET", url: "/v1/security/overview", headers: svc })).statusCode).toBe(403);
    expect((await t.app.inject({ method: "POST", url: "/v1/security/hosts/self/check", headers: svc, payload: {} })).statusCode).toBe(403);
    expect((await t.app.inject({ method: "GET", url: "/v1/security/raw?mode=all", headers: svc })).statusCode).toBe(400);
    r = await t.app.inject({ method: "GET", url: "/v1/security/overview", headers: t.auth });
    expect(r.json().hosts.map((h: { id: string; source: string }) => `${h.id}:${h.source}`)).toEqual(["self:local", "atlas:ssh"]);
  });

  it("feature off: no routes", async () => {
    const t = await testApp();
    expect((await t.app.inject({ method: "GET", url: "/v1/security/overview", headers: t.auth })).statusCode).toBe(404);
  });

  it("missing known_hosts file blocks ssh (no trust on first use)", async () => {
    const t = await setup();
    const svc = new SecurityService({ store: t.store, notifier: t.notifier }, {
      spawner: async () => ({ stdout: auditText(), stderr: "", code: 0 }),
    });
    await (await import("node:fs/promises")).rm(knownHostsPath(t.store.path));
    await expect(svc.check("atlas")).rejects.toMatchObject({ code: "agent.security.knownHostsMissing" });
  });
});
