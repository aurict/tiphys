// PLAN.md §13.0: stacks, preview tokens, redaction, tool-less claude -p, audit detail, the "analysis" scope.
import { chmod, mkdir, mkdtemp, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { readFile as rf } from "node:fs/promises";
import { claudePrint, claudePrintArgs } from "../src/llm/claude_print.ts";
import { PreviewTokens } from "../src/preview.ts";
import { redact, setKnownSecrets } from "../src/redact.ts";
import { createServiceToken } from "../src/service_tokens.ts";
import { composeProjectName, discoverStacks } from "../src/stacks.ts";
import { testApp } from "./helpers.ts";

describe("stacks", () => {
  let root = "";
  let outside = "";
  beforeAll(async () => {
    root = await mkdtemp(join(tmpdir(), "tiphys-stacks-"));
    outside = await mkdtemp(join(tmpdir(), "tiphys-outside-"));
    await writeFile(join(outside, "secret.env"), "A=1\n");
    await writeFile(join(outside, "compose.yaml"), "services:\n  evil: {image: x}\n");
    // web: compose.yaml + override + .env + env_file forms, inside a git repo at the root
    await mkdir(join(root, ".git"));
    await mkdir(join(root, "web", "conf"), { recursive: true });
    await writeFile(
      join(root, "web", "compose.yaml"),
      [
        "services:",
        "  app:",
        "    image: nginx",
        "    env_file: conf/app.env",
        "  db:",
        "    image: postgres",
        "    env_file: [conf/db.env, {path: conf/missing.env, required: false}]",
        "  leak:",
        "    image: x",
        `    env_file: ${join(outside, "secret.env")}`,
        "  sneaky:",
        "    image: x",
        "    env_file: ../../" + outside.split("/").pop() + "/secret.env",
      ].join("\n"),
    );
    await writeFile(join(root, "web", "compose.override.yml"), "services:\n  worker: {image: y}\n");
    await writeFile(join(root, "web", ".env"), "X=1\n");
    await writeFile(join(root, "web", "conf", "app.env"), "Y=1\n");
    await writeFile(join(root, "web", "conf", "db.env"), "Z=1\n");
    // Old name, named project
    await mkdir(join(root, "Old_Stack"));
    await writeFile(join(root, "Old_Stack", "docker-compose.yml"), "name: legacy\nservices:\n  svc: {image: z}\n");
    // Symlinked .env pointing out of the root is dropped
    await symlink(join(outside, "secret.env"), join(root, "Old_Stack", ".env"));
    // Symlinked stack directory escaping the root
    await symlink(outside, join(root, "escape"));
    // Compose file symlinked out of the root
    await mkdir(join(root, "linked"));
    await symlink(join(outside, "compose.yaml"), join(root, "linked", "compose.yaml"));
    // No compose file / broken YAML
    await mkdir(join(root, "empty"));
    await mkdir(join(root, "broken"));
    await writeFile(join(root, "broken", "compose.yaml"), "services: [: :\n");
  });

  it("discovers stacks, env files, services and git repo inside the root only", async () => {
    const stacks = await discoverStacks({ stacks: { roots: [root, join(root, "nope")] } });
    expect(stacks.map((s) => s.id)).toEqual(["Old_Stack", "web"]);
    const web = stacks.find((s) => s.id === "web")!;
    expect(web.composeFiles.map((f) => f.slice(root.length))).toEqual(["/web/compose.yaml", "/web/compose.override.yml"]);
    expect(web.services).toEqual(["app", "db", "leak", "sneaky", "worker"]);
    expect(web.envFiles.map((f) => f.slice(root.length))).toEqual(["/web/.env", "/web/conf/app.env", "/web/conf/db.env"]);
    expect(web.gitRepo).toBe(root);
    expect(web.project).toBe("web");
    const old = stacks.find((s) => s.id === "Old_Stack")!;
    expect(old.project).toBe("legacy");
    expect(old.envFiles).toEqual([]);
    for (const s of stacks) for (const f of [...s.composeFiles, ...s.envFiles, s.dir]) expect(f.startsWith(root)).toBe(true);
  });

  it("normalizes project names like compose", () => {
    expect(composeProjectName("Old_Stack")).toBe("old_stack");
    expect(composeProjectName("-My.App")).toBe("myapp");
  });
});

describe("preview tokens", () => {
  it("binds device, kind and input; single use; expires after 120 s", () => {
    let now = 1_000_000;
    const p = new PreviewTokens({ now: () => now });
    const input = { b: [1, 2], a: "x" };
    const t1 = p.issue("phone", "k", input);
    expect(t1.previewToken).toMatch(/^tpv_[A-Za-z0-9_-]{43}$/);
    // Key order doesn't matter
    expect(() => p.consume(t1.previewToken, "phone", "k", { a: "x", b: [1, 2] })).not.toThrow();
    expect(() => p.consume(t1.previewToken, "phone", "k", input)).toThrow("agent.preview.invalid");
    for (const [dev, kind, inp] of [["tablet", "k", input], ["phone", "other", input], ["phone", "k", { ...input, a: "y" }]] as const) {
      const t = p.issue("phone", "k", input);
      expect(() => p.consume(t.previewToken, dev, kind, inp)).toThrow("agent.preview.invalid");
      // a mismatch spends the token
      expect(() => p.consume(t.previewToken, "phone", "k", input)).toThrow("agent.preview.invalid");
    }
    const t2 = p.issue("phone", "k", input);
    now += 120_000;
    expect(() => p.consume(t2.previewToken, "phone", "k", input)).toThrow("agent.preview.invalid");
    expect(() => p.consume("tpv_nope", "phone", "k", input)).toThrow("agent.preview.invalid");
  });
});

describe("redact", () => {
  const cases: Array<[string, string]> = [
    ["Authorization: Bearer abcdefghijklmnop.qrstu", "abcdefghijklmnop"],
    ["curl -H 'Authorization: Basic dXNlcjpwYXNzd29yZA=='", "dXNlcjpwYXNzd29yZA"],
    ["token=s3cr3tT0k3n&x=1", "s3cr3tT0k3n"],
    ['{"password":"hunter2-long","user":"bob"}', "hunter2-long"],
    ["DB_PASSWORD = 'quoted value here'", "quoted value here"],
    ["POSTGRES_PASSWORD=pgpass123", "pgpass123"],
    ["connecting to postgres://admin:SuperS3cret@db:5432/app", "SuperS3cret"],
    ["redis://:onlypass99@cache:6379", "onlypass99"],
    ["jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U", "dozjgNryP4J3jVmNHl0w5N"],
    ["key AKIAIOSFODNN7EXAMPLE used", "AKIAIOSFODNN7EXAMPLE"],
    ["aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", "wJalrXUtnFEMI"],
    ["ghp_abcdefghijklmnopqrstuvwxyz0123456789", "ghp_abcdefghijklmnopqrstuvwxyz0123456789"],
    ["github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz", "github_pat_11ABCDEFG"],
    ["sk_" + "live_51Habcdefghijklmnopqrstu", "sk_" + "live_51Habcdefghij"], // split: no key-shaped literal in git
    ["anthropic sk-ant-api03-abcdefghijklmnopqrstuvwxyz", "sk-ant-api03"],
    ["mysql -uroot -pTopSecret1 db", "TopSecret1"],
    ["--password hunter22 --token=abcabc", "hunter22"],
    ["--password hunter22 --token=abcabc", "abcabc"],
    ["tph_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", "tph_AAAAAAAAAAAA"],
    [
      "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----",
      "b3BlbnNzaC1rZXktdjEAAAAA",
    ],
    ["-----BEGIN RSA PRIVATE KEY-----\nMIIEtruncatedKEYDATA", "MIIEtruncatedKEYDATA"],
  ];
  it.each(cases)("hides the secret in %j", (input, secret) => {
    const out = redact(input);
    expect(out).not.toContain(secret);
    expect(out).toContain("[GİZLİ");
  });

  it("leaves ordinary log lines alone", () => {
    for (const l of ["GET /api/users 200 12ms", "author: bob", "Listening on :8080", "tokenizer loaded 3 models", "passed 12 tests"]) {
      expect(redact(l)).toBe(l);
    }
  });

  it("replaces registered known values with the key name, and can clear them", () => {
    setKnownSecrets("stack:web", [{ key: "SMTP_PASS", value: "plain-but-known" }, { key: "SHORT", value: "abc" }]);
    expect(redact("login with plain-but-known ok abc")).toBe("login with [GİZLİ:SMTP_PASS] ok abc");
    setKnownSecrets("stack:web", []);
    expect(redact("plain-but-known")).toBe("plain-but-known");
  });

  it("stays fast on hostile input", () => {
    const hostile = [
      "a".repeat(200_000),
      "password".repeat(20_000),
      "token=" + "=".repeat(100_000),
      "postgres://" + "a:".repeat(50_000),
      "eyJ" + "a".repeat(100_000) + ".",
      "Bearer " + " ".repeat(50_000) + "x",
      "-----BEGIN PRIVATE KEY-----" + "A".repeat(100_000),
      ("x_password_" + "-".repeat(39)).repeat(2000),
    ];
    const t = Date.now();
    for (const h of hostile) redact(h);
    expect(Date.now() - t).toBeLessThan(3000);
  });
});

describe("claude_print (fake claude)", () => {
  const origPath = process.env.PATH;
  let bin = "";
  beforeAll(async () => {
    bin = await mkdtemp(join(tmpdir(), "tiphys-fakeclaude-"));
    const log = join(bin, "log.json");
    // Records argv, stdin, cwd and env keys; answers like `claude -p --output-format json`.
    await writeFile(
      join(bin, "claude.mjs"),
      `import { readFileSync, writeFileSync, readdirSync } from "node:fs";
const stdin = readFileSync(0, "utf8");
writeFileSync(${JSON.stringify(log)}, JSON.stringify({ argv: process.argv.slice(2), stdin, cwd: process.cwd(), cwdFiles: readdirSync(process.cwd()), env: Object.keys(process.env) }));
const mode = stdin.includes("FAIL") ? "fail" : "ok";
process.stdout.write(JSON.stringify(mode === "ok" ? { type: "result", subtype: "success", is_error: false, structured_output: { summary: "ok" } } : { type: "result", subtype: "error_max_turns", is_error: true }) + "\\n");
`,
    );
    await writeFile(join(bin, "claude"), `#!/bin/sh\nexec "${process.execPath}" "${join(bin, "claude.mjs")}" "$@"\n`);
    await chmod(join(bin, "claude"), 0o755);
    process.env.PATH = `${bin}:${origPath}`;
    process.env.TIPHYS_TEST_SECRET = "must-not-leak";
  });
  afterAll(() => {
    process.env.PATH = origPath;
    delete process.env.TIPHYS_TEST_SECRET;
  });

  it("runs tool-less with the prompt on stdin in an empty 0700 dir that is removed", async () => {
    const root = join(bin, "work");
    const r = await claudePrint({ prompt: "Özetle: veri", jsonSchema: { type: "object" }, timeoutMs: 20_000, root });
    expect(r.output).toEqual({ summary: "ok" });
    const log = JSON.parse(await rf(join(bin, "log.json"), "utf8"));
    expect(log.argv).toEqual(claudePrintArgs({ type: "object" }));
    expect(log.argv.slice(log.argv.indexOf("--tools"), log.argv.indexOf("--tools") + 2)).toEqual(["--tools", ""]);
    expect(log.argv).toContain("--strict-mcp-config");
    expect(log.stdin).toBe("Özetle: veri");
    expect(log.cwdFiles).toEqual([]);
    expect(log.env).not.toContain("TIPHYS_TEST_SECRET");
    expect(await readFile(log.cwd).catch((e) => e.code)).toBe("ENOENT");
  });

  it("maps failures to agent.llm.* codes", async () => {
    await expect(claudePrint({ prompt: "FAIL", jsonSchema: {}, timeoutMs: 20_000, root: join(bin, "work") })).rejects.toThrow("agent.llm.toolFailed");
    process.env.PATH = "/nonexistent";
    await expect(claudePrint({ prompt: "x", jsonSchema: {}, timeoutMs: 1000, root: join(bin, "work") })).rejects.toThrow("agent.llm.toolMissing");
    process.env.PATH = `${bin}:${origPath}`;
  });
});

describe("audit detail and scopes", () => {
  it("writes req.auditDetail (bounded) and never the body", async () => {
    const { app, auth, dir } = await testApp((c) => c, [
      (a) => {
        a.post("/v1/x", async (req) => {
          req.auditDetail = { file: "web/.env", keys: ["A", "B"], long: "y".repeat(500) };
          return { ok: true };
        });
      },
    ]);
    await app.inject({ method: "POST", url: "/v1/x", headers: auth, payload: { value: "SECRETVALUE" } });
    await app.inject({ method: "POST", url: "/v1/push/test", headers: auth });
    const res = await app.inject({ method: "GET", url: "/v1/audit", headers: auth });
    const [plain, withDetail] = res.json().entries;
    expect(withDetail.detail).toEqual({ file: "web/.env", keys: ["A", "B"], long: "y".repeat(200) });
    expect(plain.detail).toBeUndefined();
    expect(await readFile(join(dir, "audit.jsonl"), "utf8")).not.toContain("SECRETVALUE");
    await app.close();
  });

  it("an analysis-scoped service token opens no other route", async () => {
    const { app, store } = await testApp((c) => {
      c.features.research = true;
      return c;
    });
    const { token } = await createServiceToken(store, "atlas", ["analysis"]);
    const h = { authorization: `Bearer ${token}` };
    expect((await app.inject({ method: "POST", url: "/v1/research/jobs", headers: h, payload: {} })).json().error.code).toBe("agent.auth.scopeDenied");
    expect((await app.inject({ method: "GET", url: "/v1/incidents", headers: h })).statusCode).toBe(403);
    await app.close();
  });
});
