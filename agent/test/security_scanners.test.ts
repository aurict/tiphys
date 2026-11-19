// Security center S-2 (PLAN.md §15): Trivy image scanning and secret scanning, with fake docker/ssh/git/GitHub/Loki.
import { execFile } from "node:child_process";
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import { describe, expect, it } from "vitest";
import type { Spawner } from "../src/security/collect.ts";
import { knownHostsPath } from "../src/security/collect.ts";
import { parseReport } from "../src/security/report.ts";
import { securityRoutes } from "../src/security/routes.ts";
import { gitleaksArgs, localRules, parseGitleaks, SecretScanner } from "../src/security/secrets.ts";
import { classifyTrivyError, inventory, parseTrivy, remoteRefs, TRIVY_IMAGE, trivyArgs, VulnScanner, type InventoryHost, type Saver } from "../src/security/vulns.ts";
import { testApp } from "./helpers.ts";

const pexec = promisify(execFile);
const ID = (c: string) => `sha256:${c.repeat(64)}`;
// Fake token built at runtime so the source never holds a token-shaped literal.
const fakeGithubToken = () => ["gh", "p_", "Z".repeat(18), "9".repeat(18)].join("");

function report(images: { id: string; tags?: string[]; digests?: string[] }[], containers: [string, string][], arch = "aarch64") {
  const c = containers.map(([name, img]) => `c|/${name}|x|${img}|false|bridge||false|||||p|s`).join("\n");
  const i = images.map((x) => `i|${x.id}|${(x.tags ?? []).join(",")}|${(x.digests ?? []).join(",")}|100|2026-11-01T00:00:00Z`).join("\n");
  return parseReport(`@@tiphys-audit 2 report\n@@section meta\nhostname h\narch ${arch}\nroot 1\n@@section docker\n@@version 29\n${c}\n${i}\n@@end\n`);
}

function trivyJson(vulns: Array<[string, string, string | null]>) {
  return JSON.stringify({
    Metadata: { OS: { Family: "debian", Name: "13.7" } },
    Results: [{ Target: "img (debian 13.7)", Vulnerabilities: vulns.map(([id, sev, fixed]) => ({ VulnerabilityID: id, PkgName: "zlib1g", InstalledVersion: "1.0", FixedVersion: fixed, Severity: sev, Title: "t" })) }],
  });
}

describe("trivy helpers", () => {
  it("arguments: pinned image, resource limits, `--` before the reference, credentials only by name", () => {
    const a = trivyArgs({ target: { ref: "ghcr.io/example/web@sha256:" + "a".repeat(64) }, platform: "linux/arm64", credentials: true });
    expect(a).toContain(TRIVY_IMAGE);
    expect(TRIVY_IMAGE).toMatch(/@sha256:[a-f0-9]{64}$/);
    for (const x of ["--read-only", "--memory", "2g", "--skip-java-db-update", "**/*.jar", "--platform", "linux/arm64", "--image-src", "remote"]) expect(a).toContain(x);
    const j = trivyArgs({ target: { ref: "x@sha256:" + "a".repeat(64) }, platform: "", credentials: false, javaDb: true });
    expect(j).not.toContain("--skip-java-db-update");
    expect(j).not.toContain("**/*.jar");
    expect(a.slice(-2)).toEqual(["--", "ghcr.io/example/web@sha256:" + "a".repeat(64)]);
    expect(a.join(" ")).toMatch(/-e TRIVY_USERNAME -e TRIVY_PASSWORD/);
    expect(a.join(" ")).not.toMatch(/TRIVY_PASSWORD=/);
    const b = trivyArgs({ target: { input: "/tmp/x/image.tar" }, platform: "", credentials: false });
    expect(b).toContain("/tmp/x/image.tar:/in/image.tar:ro");
    expect(b.slice(-2)).toEqual(["--input", "/in/image.tar"]);
  });

  it("only well-formed digest references are fetched", () => {
    const d = "a".repeat(64);
    expect(remoteRefs({ id: ID("1"), tags: [], digests: [`postgres@sha256:${d}`, `-oops@sha256:${d}`, `x y@sha256:${d}`, "postgres:16", `ghcr.io/a/b@sha256:${d}`], size: 0, created: "" })).toEqual([
      `postgres@sha256:${d}`,
      `ghcr.io/a/b@sha256:${d}`,
    ]);
  });

  it("parses, dedups, sorts and caps results", () => {
    const many = Array.from({ length: 310 }, (_, n) => [`CVE-1-${n}`, "HIGH", null] as [string, string, string | null]);
    const r = parseTrivy(trivyJson([["CVE-9", "LOW", null], ["CVE-2", "HIGH", null], ["CVE-1", "CRITICAL", "2.0"], ["CVE-1", "CRITICAL", "2.0"], ...many]));
    expect(r.os).toBe("debian 13.7");
    expect(r.counts).toEqual({ critical: 1, high: 311, fixable: 1 });
    expect(r.vulns[0]).toMatchObject({ id: "CVE-1", severity: "CRITICAL", fixed: "2.0" });
    expect(r.vulns).toHaveLength(300);
    expect(r.truncated).toBe(true);
  });

  it("classifies registry errors", () => {
    expect(classifyTrivyError("GET https://ghcr.io/...: UNAUTHORIZED: authentication required")).toBe("needsCredentials");
    expect(classifyTrivyError("MANIFEST_UNKNOWN: manifest unknown")).toBe("notFound");
    expect(classifyTrivyError("panic")).toBe("failed");
  });

  it("inventory dedups shared images and keeps where they run", () => {
    const a = report([{ id: ID("1"), digests: ["postgres@sha256:" + "a".repeat(64)] }], [["db", ID("1")]]);
    const b = report([{ id: ID("1") }, { id: ID("2") }], [["db2", ID("1")], ["app", ID("2")]]);
    const inv = inventory([
      { hostId: "self", host: "atlas", kind: "local", arch: "aarch64", report: a },
      { hostId: "orion", host: "orion", kind: "ssh", arch: "aarch64", report: b },
    ]);
    expect([...inv.keys()]).toEqual([ID("1"), ID("2")]);
    expect(inv.get(ID("1"))!.hosts.map((h) => `${h.hostId}:${h.containers.join(",")}`)).toEqual(["self:db", "orion:db2"]);
  });
});

describe("VulnScanner", () => {
  async function setup(hosts: InventoryHost[], trivy: (args: string[], env?: Record<string, string>) => { code: number; stdout: string; stderr: string }) {
    const t = await testApp((c) => {
      c.security.scanners.trivy = true;
      c.security.hosts.push({ id: "orion", name: "orion", role: "server", allowedPorts: [], source: { kind: "ssh", host: "orion", user: "tiphys-audit", port: 22, keyPath: "/k" }, traps: false });
      c.security.scanners.registryAuth.push({ registry: "ghcr.io", username: "u", token: "registry-secret-value" });
      return c;
    });
    await writeFile(knownHostsPath(t.store.path), "orion ssh-ed25519 AAAA\n");
    const calls: { cmd: string; args: string[]; env?: Record<string, string> }[] = [];
    const saves: { cmd: string; args: string[] }[] = [];
    const spawner: Spawner = async (cmd, args, o) => {
      calls.push({ cmd, args, env: o.env });
      return trivy(args, o.env);
    };
    const saver: Saver = async (cmd, args, file) => {
      saves.push({ cmd, args });
      await writeFile(file, "tar");
      return { code: 0, stderr: "", bytes: 3 };
    };
    const now = Date.parse("2026-11-19T01:30:00Z");
    const v = new VulnScanner({ store: t.store, notifier: t.notifier }, () => hosts, { spawner, saver, now: () => now, nightHours: [0, 24] });
    await v.refresh();
    return { t, v, calls, saves };
  }

  it("remote by digest; notification for critical; credentials only in the child env", async () => {
    const r = report([{ id: ID("1"), tags: ["ghcr.io/example/web:1"], digests: ["ghcr.io/example/web@sha256:" + "b".repeat(64)] }], [["web", ID("1")]]);
    const { t, v, calls, saves } = await setup([{ hostId: "orion", host: "orion", kind: "ssh", arch: "aarch64", report: r }], () => ({ code: 0, stdout: trivyJson([["CVE-1", "CRITICAL", "2"]]), stderr: "" }));
    const s = await v.scanOne(ID("1"));
    expect(s).toMatchObject({ status: "ok", source: "remote", counts: { critical: 1, high: 0, fixable: 1 } });
    expect(saves).toEqual([]);
    expect(calls[0]!.env).toEqual({ TRIVY_USERNAME: "u", TRIVY_PASSWORD: "registry-secret-value" });
    expect(calls[0]!.args.join(" ")).not.toContain("registry-secret-value");
    expect(t.sent).toEqual([expect.objectContaining({ key: "security.vulns", params: expect.objectContaining({ host: "orion", image: "ghcr.io/example/web:1", critical: 1 }) })]);
    // Same result again: no repeat notification.
    await v.scanOne(ID("1"));
    expect(t.sent).toHaveLength(1);
    const state = await readFile(v.file, "utf8");
    expect(state).not.toContain("registry-secret-value");
  });

  it("not in a registry: local image → docker save; SSH host → image-save, at most 2 a day", async () => {
    const local = report([{ id: ID("1") }], [["a", ID("1")]]);
    const remote = report([{ id: ID("2") }, { id: ID("3") }, { id: ID("4") }], [["b", ID("2")], ["c", ID("3")], ["d", ID("4")]]);
    const { v, calls, saves } = await setup(
      [
        { hostId: "self", host: "atlas", kind: "local", arch: "aarch64", report: local },
        { hostId: "orion", host: "orion", kind: "ssh", arch: "aarch64", report: remote },
      ],
      (args) => (args.includes("--input") ? { code: 0, stdout: trivyJson([]), stderr: "" } : { code: 1, stdout: "", stderr: "MANIFEST_UNKNOWN" }),
    );
    expect((await v.scanOne(ID("1"))).source).toBe("local");
    expect(saves[0]).toEqual({ cmd: "docker", args: ["save", ID("1")] });
    expect(calls.at(-1)!.args).toContain("--input");
    for (const id of [ID("2"), ID("3")]) expect((await v.scanOne(id)).source).toBe("ssh");
    expect(saves[1]!.cmd).toBe("ssh");
    expect(saves[1]!.args.at(-1)).toBe(`image-save ${ID("2")}`);
    expect(saves[1]!.args).toContain("StrictHostKeyChecking=yes");
    expect(await v.scanOne(ID("4"))).toMatchObject({ status: "pending", error: "saveLimit" });
    expect(await v.scanOne(ID("4"), { allowSave: false })).toMatchObject({ status: "pending", error: "nightOnly" });
    expect(saves).toHaveLength(3);
  });

  it("private image without credentials → needsCredentials; unknown registries are never contacted", async () => {
    const r = report([{ id: ID("5"), digests: ["quay.io/x/y@sha256:" + "c".repeat(64)] }, { id: ID("6"), digests: ["169.254.169.254/x@sha256:" + "d".repeat(64)] }], [["x", ID("5")], ["y", ID("6")]]);
    const { v, calls } = await setup([{ hostId: "orion", host: "orion", kind: "agent", arch: "x86_64", report: r }], () => ({ code: 1, stdout: "", stderr: "UNAUTHORIZED" }));
    expect(await v.scanOne(ID("5"))).toMatchObject({ status: "needsCredentials", error: "quay.io" });
    const n = calls.length;
    expect(await v.scanOne(ID("6"))).toMatchObject({ status: "notAvailable" });
    expect(calls.length).toBe(n);
  });
});

describe("secret scanning", () => {
  it("gitleaks report parsing drops Secret/Match; container is offline and redacting", () => {
    const hits = parseGitleaks(JSON.stringify([{ RuleID: "github-pat", File: "a.txt", StartLine: 2, Commit: "abc", Secret: "s3cr3t-value", Match: "x=s3cr3t-value" }]));
    expect(JSON.stringify(hits)).not.toContain("s3cr3t");
    const a = gitleaksArgs("git", "/tmp/r.git");
    for (const x of ["--network", "none", "--read-only", "--redact"]) expect(a).toContain(x);
    expect(a).toContain("/tmp/r.git:/repo:ro");
  });

  it("local rules: well-known formats only", () => {
    expect(localRules(`token = "${fakeGithubToken()}"`)).toEqual(["github"]);
    expect(localRules("const password = form.password;")).toEqual([]);
    expect(localRules("hello")).toEqual([]);
  });

  it("local repos: findings with location only; tracked .env; dismiss", async () => {
    const root = await mkdtemp(join(tmpdir(), "tiphys-secrets-"));
    const repo = join(root, "proj");
    await mkdir(repo);
    const tok = fakeGithubToken();
    await writeFile(join(repo, "config.js"), `module.exports = {\n  key: "${tok}",\n};\n`);
    await writeFile(join(repo, ".env"), "A=1\n");
    await writeFile(join(repo, ".env.example"), "A=\n");
    await pexec("git", ["init", "-q"], { cwd: repo });
    await pexec("git", ["add", "-A"], { cwd: repo });
    const t = await testApp((c) => {
      c.allowedRoots = [root];
      c.security.scanners.localRoots = [root];
      return c;
    });
    const s = new SecretScanner({ store: t.store, notifier: t.notifier });
    expect(await s.run()).toEqual({ fresh: 2 });
    const l = s.list();
    expect(l.findings.map((f) => `${f.rule}:${f.file}:${f.line}`).sort()).toEqual([".env:null".replace(/^/, "env-file-tracked:"), "github:config.js:2"].sort());
    const state = await readFile(s.file, "utf8");
    expect(state).not.toContain(tok);
    expect(t.sent).toEqual([expect.objectContaining({ key: "security.secretFound", priority: "high", params: expect.objectContaining({ count: 2, sources: "local" }) })]);
    expect((await s.run()).fresh).toBe(0);
    const f = await s.dismiss(l.findings[0]!.id, true);
    expect(f.dismissed).toBe(true);
    const gh = s.list().findings.find((x) => x.rule === "github")!;
    await s.dismiss(gh.id, false);
    expect(await s.dismissGroup({ source: "local", where: gh.where, rule: "github", pathPrefix: "other/" }, true)).toBe(0);
    expect(await s.dismissGroup({ source: "local", where: gh.where, rule: "github", pathPrefix: "config" }, true)).toBe(1);
    expect(s.list().findings.find((x) => x.rule === "github")!.dismissed).toBe(true);
    // Roots outside allowedRoots are skipped.
    await t.store.update((c) => ((c.allowedRoots = [join(root, "nope")]), c));
    const s2 = new SecretScanner({ store: t.store, notifier: t.notifier });
    expect(await s2.run()).toEqual({ fresh: 0 });
  });

  it("github: token only in git's environment, unchanged heads skipped", async () => {
    const t = await testApp((c) => {
      c.security.scanners.gitleaks = true;
      c.security.scanners.github = { owners: ["example"], token: "gh-token-value" };
      return c;
    });
    const calls: { cmd: string; args: string[]; env?: Record<string, string> }[] = [];
    let auth = "";
    const fetchFake = (async (u: string, init: RequestInit) => {
      auth = String((init.headers as Record<string, string>).authorization ?? "");
      if (String(u).includes("/user/repos")) return new Response(JSON.stringify([{ full_name: "example/app", default_branch: "main", private: true }, { full_name: "other/x", default_branch: "main" }]));
      return new Response(JSON.stringify([{ full_name: "example/app", default_branch: "main" }, { full_name: "example/fork", fork: true }]));
    }) as unknown as typeof fetch;
    const spawner: Spawner = async (cmd, args, o) => {
      calls.push({ cmd, args, env: o.env });
      if (args[0] === "ls-remote") return { code: 0, stdout: "abc123\trefs/heads/main\n", stderr: "" };
      if (cmd === "docker") return { code: 0, stdout: JSON.stringify([{ RuleID: "aws-access-token", File: "x.env", StartLine: 3, Commit: "c0ffee1234567890", Secret: "zzz" }]), stderr: "" };
      return { code: 0, stdout: "", stderr: "" };
    };
    const s = new SecretScanner({ store: t.store, notifier: t.notifier }, { spawner, fetch: fetchFake });
    expect(await s.run()).toEqual({ fresh: 1 });
    expect(auth).toBe("Bearer gh-token-value");
    expect(calls.map((c) => c.args.join(" ")).join("\n")).not.toContain("gh-token-value");
    const clone = calls.find((c) => c.args[0] === "clone")!;
    expect(clone.args).toEqual(["clone", "--bare", "--quiet", "--", "https://github.com/example/app.git", expect.stringMatching(/r\.git$/)]);
    expect(clone.env!.GIT_CONFIG_VALUE_0).toMatch(/^AUTHORIZATION: basic /);
    expect(s.list().findings[0]).toMatchObject({ source: "github", where: "example/app", file: "x.env", line: 3, commit: "c0ffee123456" });
    expect(JSON.stringify(s.list())).not.toContain("zzz");
    calls.length = 0;
    await s.run();
    expect(calls.some((c) => c.args[0] === "clone")).toBe(false);
  });

  it("loki: per-host logs through gitleaks stdin, finding mapped to stream and time", async () => {
    const t = await testApp((c) => {
      c.security.scanners.gitleaks = true;
      c.security.scanners.loki = { url: "http://loki.example:3100" };
      return c;
    });
    const urls: string[] = [];
    const fetchFake = (async (u: string) => {
      urls.push(String(u));
      if (String(u).includes("/label/host/values")) return new Response(JSON.stringify({ data: ["atlas", "bad host"] }));
      return new Response(JSON.stringify({ data: { result: [{ stream: { container: "web-1" }, values: [["1794998587000000000", "ok"], ["1794998588000000000", "leak here"]] }] } }));
    }) as unknown as typeof fetch;
    let input = "";
    const s = new SecretScanner(
      { store: t.store, notifier: t.notifier },
      {
        fetch: fetchFake,
        gitleaksStdin: async (d) => {
          input = d;
          return JSON.stringify([{ RuleID: "generic-api-key", StartLine: 2, Secret: "x" }]);
        },
      },
    );
    expect(await s.run()).toEqual({ fresh: 1 });
    expect(input).toBe("ok\nleak here\n");
    expect(urls.filter((u) => u.includes("query_range")).every((u) => decodeURIComponent(u).includes('{host="atlas"}'))).toBe(true);
    expect(s.list().findings[0]).toMatchObject({ source: "loki", where: "atlas", stream: "web-1", rule: "generic-api-key" });
  });
});

describe("routes", () => {
  it("scanner settings hide tokens; keep/replace/remove; off → 409", async () => {
    const t = await testApp((c) => c, [securityRoutes({ startTimer: false, spawner: async () => ({ code: 0, stdout: "", stderr: "" }) })]);
    let r = await t.app.inject({ method: "POST", url: "/v1/security/vulns/scan", headers: t.auth, payload: {} });
    expect(r.statusCode).toBe(409);
    expect(r.json().error.code).toBe("agent.security.scannerOff");
    r = await t.app.inject({
      method: "PATCH",
      url: "/v1/security/scanners",
      headers: t.auth,
      payload: { trivy: true, github: { owners: ["example"], token: "tok-1" }, registryAuth: [{ registry: "ghcr.io", username: "u", token: "tok-2" }] },
    });
    expect(r.statusCode).toBe(200);
    expect(r.body).not.toMatch(/tok-1|tok-2/);
    expect(r.json().scanners).toMatchObject({ trivy: true, github: { owners: ["example"], hasToken: true }, registryAuth: [{ registry: "ghcr.io", username: "u", hasToken: true }] });
    r = await t.app.inject({ method: "PATCH", url: "/v1/security/scanners", headers: t.auth, payload: { github: { owners: ["example", "x"] }, registryAuth: [{ registry: "ghcr.io", username: "u" }] } });
    expect(t.store.get().security.scanners.github.token).toBe("tok-1");
    expect(t.store.get().security.scanners.registryAuth[0]!.token).toBe("tok-2");
    r = await t.app.inject({ method: "PATCH", url: "/v1/security/scanners", headers: t.auth, payload: { registryAuth: [{ registry: "ghcr.io", username: "other" }] } });
    expect(r.json().error.code).toBe("agent.security.tokenRequired");
    await t.app.inject({ method: "PATCH", url: "/v1/security/scanners", headers: t.auth, payload: { github: { owners: [], token: null } } });
    expect(t.store.get().security.scanners.github.token).toBeNull();
    r = await t.app.inject({ method: "GET", url: "/v1/config", headers: t.auth });
    expect(r.body).not.toMatch(/tok-1|tok-2/);
    expect((await readFile(join(t.dir, "audit.jsonl"), "utf8")).match(/tok-/)).toBeNull();
    r = await t.app.inject({ method: "GET", url: "/v1/security/vulns", headers: t.auth });
    expect(r.json()).toMatchObject({ enabled: true, images: [] });
    expect((await t.app.inject({ method: "GET", url: "/v1/security/vulns/xyz", headers: t.auth })).statusCode).toBe(400);
    expect((await t.app.inject({ method: "POST", url: "/v1/security/secrets/zz/dismiss", headers: t.auth, payload: { dismissed: true } })).statusCode).toBe(400);
  });
});
