// Config & secrets, PLAN.md §13.3 C-1: parser round trip, classification, discovery rules, masked read, reveal limits,
// preview → save, conflicts, atomic write, TOCTOU, backups/restore, affected services, metadata, and a leak check.
import { mkdir, mkdtemp, readdir, readFile, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it, vi } from "vitest";
import { hashToken, newServiceToken, newToken } from "../src/auth.ts";
import { ConfigStore } from "../src/config.ts";
import { referencedVars } from "../src/configfiles/affected.ts";
import { classify, looksRandom } from "../src/configfiles/classify.ts";
import { applyOps, effective, parseEnv, serializeEnv, type EnvOp } from "../src/configfiles/dotenv.ts";
import { KEEP_BACKUPS, type WriteHooks } from "../src/configfiles/files.ts";
import { configFilesRoutes } from "../src/configfiles/routes.ts";
import { Notifier } from "../src/notify.ts";
import { redact } from "../src/redact.ts";
import { buildApp } from "../src/server.ts";

// --- Parser ---------------------------------------------------------------------------------------------------------

const TRICKY = [
  "# leading comment",
  "",
  "   ",
  "PLAIN=value",
  "SPACED = spaced value  ",
  "INLINE=abc # a comment",
  "HASH_NO_SPACE=abc#def",
  "export EXPORTED=1",
  "  INDENTED=yes",
  "EMPTY=",
  "INHERITED",
  "SINGLE='it is $literal \\n'",
  "SINGLE_ESC='it\\'s'",
  'DOUBLE="a \\"quoted\\" \\\\ \\n line \\$HOME ${X}" # trailing',
  'MULTI="line one',
  "line two",
  'line three"',
  "MULTI_SINGLE='a",
  "b'",
  "DOTTED.KEY=v",
  "DUP=first",
  "bad-key=1",
  "YAML: style",
  'TRAIL="x" y=z',
  "\tTABBED=\t tab",
  "OCT=\"\\0101\"",
  "DUP=second",
  "UNTERMINATED=\"never closed",
  "LAST=no newline at end",
].join("\n");

describe("dotenv parser", () => {
  it("round-trips tricky files byte for byte (LF, CRLF, no final newline, empty)", () => {
    for (const t of [TRICKY, TRICKY + "\n", TRICKY.replace(/\n/g, "\r\n") + "\r\n", "", "\n", "A=1", "#only"]) {
      expect(serializeEnv(parseEnv(t))).toBe(t);
    }
  });

  it("reads values like compose", () => {
    const doc = parseEnv(TRICKY + "\n");
    const v = Object.fromEntries([...effective(doc)].map(([k, e]) => [k, e.value]));
    expect(v).toMatchObject({
      PLAIN: "value",
      SPACED: "spaced value",
      INLINE: "abc",
      HASH_NO_SPACE: "abc#def",
      EXPORTED: "1",
      INDENTED: "yes",
      EMPTY: "",
      INHERITED: "",
      SINGLE: "it is $literal \\n",
      SINGLE_ESC: "it's",
      DOUBLE: 'a "quoted" \\ \n line $$HOME ${X}',
      MULTI: "line one\nline two\nline three",
      MULTI_SINGLE: "a\nb",
      "DOTTED.KEY": "v",
      DUP: "second",
      TABBED: "tab",
      OCT: "A",
      LAST: "no newline at end",
    });
    expect(effective(doc).get("INHERITED")!.inherited).toBe(true);
    expect(effective(doc).get("MULTI")!.line).toBe(15);
    const invalid = doc.nodes.filter((n) => n.type === "invalid").map((n) => [n.line, (n as { reason?: string }).reason]);
    expect(invalid).toEqual([
      [22, "syntax"],
      [23, "syntax"],
      [24, "trailingText"],
      [28, "unterminatedQuote"],
    ]);
    expect(effective(doc).has("TRAIL")).toBe(false);
  });

  it("refuses edits while an unterminated quote is open (compose would swallow the lines below)", () => {
    expect(() => applyOps(parseEnv(TRICKY), [{ op: "set", key: "PLAIN", value: "x" }])).toThrow("unterminatedQuote");
  });

  it("edits only the touched lines and keeps quoting, export, comments", () => {
    const doc = parseEnv(TRICKY.replace('UNTERMINATED="never closed\n', "") + "\n");
    const out = applyOps(doc, [
      { op: "set", key: "INLINE", value: "xyz" },
      { op: "set", key: "EXPORTED", value: "2" },
      { op: "set", key: "DOUBLE", value: "new ${X}" },
      { op: "unset", key: "PLAIN" },
      { op: "rename", key: "SPACED", newKey: "SPACED2" },
      { op: "set", key: "NEW", value: "p@ss word$1'\"" },
      { op: "set", key: "DUP", value: "third" },
    ]);
    const lines = out.split("\n");
    expect(lines).toContain("INLINE=xyz # a comment");
    expect(lines).toContain("export EXPORTED=2");
    expect(lines).toContain('DOUBLE="new ${X}" # trailing');
    expect(lines).toContain("SPACED2 = spaced value  ");
    expect(lines).not.toContain("PLAIN=value");
    expect(lines).toContain("DUP=first"); // only the effective (last) occurrence changes
    expect(lines).toContain("DUP=third");
    const after = effective(parseEnv(out));
    expect(after.get("NEW")!.value).toBe("p@ss word$$1'\"" /* literal $ written as \$ in double quotes → compose's $$ */);
    expect(out.replace(/^(INLINE|export EXPORTED|DOUBLE|SPACED2|DUP|NEW)\b.*$\n?/gm, "")).toBe(
      (TRICKY.replace('UNTERMINATED="never closed\n', "") + "\n").replace(/^(PLAIN|INLINE|export EXPORTED|DOUBLE|SPACED|DUP)\b.*$\n?/gm, ""),
    );
  });

  it("set values read back unchanged", () => {
    const values = ["", "plain", "with space", "a#b", "a #b", "trailing ", " leading", "it's", 'dq"', "back\\slash", "end\\", "multi\nline", "cr\r\nlf", "$dollar", "${REF}", "ünïcødé ✓", "'quoted'", '"dq"', "=eq=", "tab\there"];
    for (const v of values) {
      for (const base of ["", "K=old\n", "K='old'\n", 'K="old"\n', "export K=old # c\n", "K\n"]) {
        const out = applyOps(parseEnv(base), [{ op: "set", key: "K", value: v }]);
        const got = effective(parseEnv(out)).get("K")!.value;
        // New/single-quoted entries are literal: a `$` that needs double quotes is written as \$ (compose's $$).
        const literalDq = (base === "" || base.startsWith("K='") || base === "K\n") && /['\r\n]|\\$/.test(v) && v.includes("$");
        expect(got, `${JSON.stringify(base)} ← ${JSON.stringify(v)}`).toBe(literalDq ? v.replace(/\$/g, "$$$$") : v);
        expect(serializeEnv(parseEnv(out))).toBe(out);
      }
    }
  });

  it("rejects unknown keys and rename onto an existing key", () => {
    const doc = parseEnv("A=1\nB=2\n");
    expect(() => applyOps(doc, [{ op: "unset", key: "C" }])).toThrow("keyNotFound");
    expect(() => applyOps(doc, [{ op: "rename", key: "A", newKey: "B" }])).toThrow("keyExists");
  });
});

describe("classification and references", () => {
  it("classifies by name, URI password, entropy and mark", () => {
    expect(classify("DB_PASSWORD", "x")).toEqual({ secret: true, reason: "name" });
    expect(classify("API_KEY", "")).toMatchObject({ secret: true });
    expect(classify("POSTGRES_PASSWORD_FILE", "/run/secrets/db")).toEqual({ secret: false, reason: null });
    expect(classify("DATABASE_URL", "postgres://u:hunter2@db/x")).toEqual({ secret: true, reason: "uriPassword" });
    expect(classify("DATABASE_URL", "postgres://db/x")).toMatchObject({ secret: false });
    expect(classify("SESSION", "Zq3vX9pL2mT7wR4kY8nB1cD6")).toEqual({ secret: true, reason: "entropy" });
    expect(classify("HEXY", "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")).toMatchObject({ secret: true });
    expect(looksRandom("nginx-1.25.3-alpine-bookworm")).toBe(false);
    expect(looksRandom("/var/lib/postgresql/data/pgdata1")).toBe(false);
    expect(classify("TZ", "Europe/Istanbul")).toMatchObject({ secret: false });
    expect(classify("DB_PASSWORD", "x", false)).toEqual({ secret: false, reason: "mark" });
    expect(classify("TZ", "x", true)).toEqual({ secret: true, reason: "mark" });
  });

  it("finds compose interpolation references", () => {
    expect([...referencedVars({ a: "${A} $B ${C:-x} ${D?err} $$E $${F}", list: ["$G"], "${H}": 1 })].sort()).toEqual(["A", "B", "C", "D", "G", "H"]);
  });
});

// --- Routes ---------------------------------------------------------------------------------------------------------

const COMPOSE = `services:
  app:
    image: nginx
    env_file: db.env
    environment:
      DATABASE_URL: postgres://u:\${DB_PASSWORD}@db/x
  db:
    image: postgres
    environment:
      - POSTGRES_PASSWORD=\${DB_PASSWORD:-x}
  worker:
    image: busybox
    command: echo $$HOME \${OTHER}
  cache:
    image: redis
    env_file:
      - path: ./db.env
        required: false
`;
const S1 = "S1-original-Secret-Value-4821";
const ENV = `# web stack\nDB_PASSWORD=${S1}\nOTHER=plain\nexport APP_NAME="My App" # name\nAPI_TOKEN='tok-Alpha-Bravo-9931'\n`;

let restoreUid: (() => void) | null = null;
afterEach(() => {
  restoreUid?.();
  restoreUid = null;
});

async function setup(o: { hooks?: WriteHooks; now?: () => number; extraPaths?: (dir: string) => string[]; more?: (dir: string) => Promise<void> } = {}) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-configfiles-"));
  const web = join(dir, "stack", "web");
  await mkdir(web, { recursive: true });
  await writeFile(join(web, "compose.yaml"), COMPOSE);
  await writeFile(join(web, ".env"), ENV, { mode: 0o640 });
  await writeFile(join(web, "db.env"), "POSTGRES_DB=app\n", { mode: 0o600 });
  await o.more?.(dir);
  const store = await ConfigStore.loadOrCreate(join(dir, "cfg", "agent.json"), "atlas");
  const token = newToken();
  const service = newServiceToken();
  await store.update((c) => {
    c.features.configfiles = true;
    c.stacks.roots = [join(dir, "stack")];
    c.configFiles.extraPaths = o.extraPaths?.(dir) ?? [];
    c.devices.push({ id: "phone", name: "Telefon", tokenHash: hashToken(token), createdAt: new Date().toISOString() });
    c.serviceTokens.push({ id: "atlas", name: "atlas", scopes: ["research", "analysis"], tokenHash: hashToken(service), createdAt: new Date().toISOString() });
    return c;
  });
  const logs: string[] = [];
  const notifier = new Notifier(() => store.get(), () => {});
  const stateDir = join(dir, "state");
  const app = await buildApp(
    { store, notifier, extraRoutes: [configFilesRoutes({ stateDir, hooks: o.hooks, now: o.now })] },
    { logger: true, logStream: { write: (l: string) => void logs.push(l) } },
  );
  const auth = { authorization: `Bearer ${token}` };
  const responses: string[] = [];
  const call = async (method: "GET" | "POST" | "PUT", url: string, payload?: unknown) => {
    const res = await app.inject({ method, url, headers: auth, ...(payload === undefined ? {} : typeof payload === "string" ? { payload, headers: { ...auth, "content-type": "application/json" } } : { payload: payload as object }) });
    responses.push(res.body);
    return { status: res.statusCode, body: res.json() as Record<string, any> };
  };
  const files = async () => (await call("GET", "/v1/config-files")).body;
  const idOf = async (label: string) => ((await files()).files as Array<{ fileId: string; file: string }>).find((f) => f.file === label)!.fileId;
  return { dir, web, app, store, auth, service, logs, stateDir, call, files, idOf, responses, notifier };
}

type T = Awaited<ReturnType<typeof setup>>;

async function saveOps(t: T, fileId: string, ops: EnvOp[]) {
  const d = await t.call("GET", `/v1/config-files/${fileId}`);
  const p = await t.call("POST", `/v1/config-files/${fileId}/preview`, { baseHash: d.body.hash, ops });
  expect(p.status, JSON.stringify(p.body)).toBe(200);
  return t.call("PUT", `/v1/config-files/${fileId}`, { previewToken: p.body.previewToken, confirm: true, restart: "none" });
}

describe("config files routes", () => {
  it("lists the stack .env and env_file, reads masked, never returns secret values", async () => {
    const t = await setup();
    const l = await t.files();
    expect(l.files.map((f: { file: string }) => f.file).sort()).toEqual(["web/.env", "web/db.env"]);
    const env = l.files.find((f: { file: string }) => f.file === "web/.env");
    expect(env).toMatchObject({ source: "stack", stack: "web", keys: 4, secrets: 2, worldReadable: false });
    expect(env.fileId).toMatch(/^cf-[a-f0-9]{24}$/);
    const d = await t.call("GET", `/v1/config-files/${env.fileId}`);
    expect(d.body.mode).toBe("0640");
    const byKey = Object.fromEntries(d.body.entries.map((e: { key: string }) => [e.key, e]));
    expect(byKey.DB_PASSWORD).toMatchObject({ secret: true, reason: "name", masked: `••••${S1.length}`, length: S1.length, line: 2 });
    expect(byKey.DB_PASSWORD.value).toBeUndefined();
    expect(byKey.API_TOKEN.value).toBeUndefined();
    expect(byKey.OTHER).toMatchObject({ secret: false, value: "plain" });
    expect(byKey.APP_NAME).toMatchObject({ value: "My App", quote: '"' });
    expect(JSON.stringify(d.body)).not.toContain(S1);
    // The value is now a known secret for redaction (incident context).
    expect(redact(`conn failed password ${S1} x`)).toBe("conn failed password [GİZLİ:DB_PASSWORD] x");
    await t.app.close();
  });

  it("applies the file rules: symlink escape, .., wrong name, too big, other owner, extra paths", async () => {
    const t = await setup({
      more: async (dir) => {
        await writeFile(join(dir, "outside.env"), "LEAK=1\n");
        // symlinked .env pointing out of the root, env_file with .., wrong name, too big
        await mkdir(join(dir, "stack", "esc"), { recursive: true });
        await writeFile(join(dir, "stack", "esc", "compose.yaml"), "services:\n  a:\n    image: x\n    env_file: [../../outside.env, secrets.txt, big.env, link.env]\n");
        await symlink(join(dir, "outside.env"), join(dir, "stack", "esc", ".env"));
        await writeFile(join(dir, "stack", "esc", "secrets.txt"), "A=1\n");
        await writeFile(join(dir, "stack", "esc", "big.env"), "A=" + "x".repeat(256 * 1024) + "\n");
        await symlink(join(dir, "stack", "web", "db.env"), join(dir, "stack", "esc", "link.env")); // inside the root: allowed
        await mkdir(join(dir, "extra"));
        await writeFile(join(dir, "extra", "app.env"), "X=1\n");
        await symlink(join(dir, "outside.env"), join(dir, "extra", "escape.env"));
        await writeFile(join(dir, "extra", "notes.txt"), "X=1\n");
      },
      extraPaths: (dir) => [join(dir, "extra", "app.env"), join(dir, "extra", "escape.env"), join(dir, "extra", "notes.txt"), join(dir, "extra", "missing.env")],
    });
    const l = await t.files();
    const labels = l.files.map((f: { file: string }) => f.file).sort();
    expect(labels).toEqual(["web/.env", "web/db.env", expect.stringMatching(/extra\/app\.env$/)].sort());
    expect(labels.some((x: string) => x.includes("outside"))).toBe(false);
    const reasons = Object.fromEntries(l.skipped.map((s: { file: string; reason: string }) => [s.file.split("/").pop(), s.reason]));
    expect(reasons).toMatchObject({ "secrets.txt": "badName", "big.env": "tooLarge", "escape.env": "outsideRoot", "notes.txt": "badName", "missing.env": "missing" });
    // A skipped file can't be read by id; routes take no paths.
    const big = l.skipped.find((s: { file: string }) => s.file.endsWith("big.env"));
    expect((await t.call("GET", `/v1/config-files/${big.fileId}`)).body.error).toEqual({ code: "agent.configfiles.notEditable", params: { reason: "tooLarge" } });
    expect((await t.call("GET", "/v1/config-files/..%2F..%2Fetc%2Fpasswd")).status).toBe(400);
    expect((await t.call("GET", `/v1/config-files/cf-${"0".repeat(24)}`)).status).toBe(404);
    // Other owner
    const spy = vi.spyOn(process, "getuid").mockReturnValue(4242);
    restoreUid = () => spy.mockRestore();
    const l2 = await t.files();
    expect(l2.files).toEqual([]);
    expect(l2.skipped.filter((s: { reason: string }) => s.reason === "notOwner").length).toBeGreaterThanOrEqual(3);
    await t.app.close();
  });

  it("preview shows a masked diff and affected services; save writes atomically with a backup", async () => {
    const t = await setup();
    const id = await t.idOf("web/.env");
    const d = await t.call("GET", `/v1/config-files/${id}`);
    const S2 = "S2-new-Secret-Value-forty-chars-long-xyz";
    const p = await t.call("POST", `/v1/config-files/${id}/preview`, {
      baseHash: d.body.hash,
      ops: [
        { op: "set", key: "DB_PASSWORD", value: S2 },
        { op: "set", key: "OTHER", value: "changed" },
        { op: "rename", key: "API_TOKEN", newKey: "API_TOKEN2" },
        { op: "set", key: "NEW_KEY", value: "n" },
      ],
    });
    expect(p.status).toBe(200);
    expect(p.body.previewToken).toMatch(/^tpv_/);
    const ch = Object.fromEntries(p.body.changes.map((c: { key: string }) => [c.key, c]));
    expect(ch.DB_PASSWORD).toEqual({ key: "DB_PASSWORD", change: "changed", secret: true, line: 2, oldLine: 2, before: { length: S1.length }, after: { length: S2.length } });
    expect(ch.OTHER).toMatchObject({ change: "changed", secret: false, before: { value: "plain" }, after: { value: "changed" } });
    expect(ch.API_TOKEN2).toMatchObject({ change: "renamed", from: "API_TOKEN", secret: true });
    expect(ch.API_TOKEN2.after.value).toBeUndefined();
    expect(ch.NEW_KEY).toMatchObject({ change: "added", line: 6 });
    expect(p.body.affected).toEqual([{ stack: "web", project: "web", services: ["app", "db", "worker"] }]);
    expect(JSON.stringify(p.body)).not.toContain(S2);
    // Without confirm nothing happens and the token isn't spent (restart binding: configfiles_c2.test.ts).
    expect((await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken })).body.error.code).toBe("agent.configfiles.confirmRequired");
    const s = await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true, restart: "none" });
    expect(s.status).toBe(200);
    expect(s.body).toMatchObject({ restart: "none", warnings: [], keys: ["DB_PASSWORD", "OTHER", "API_TOKEN", "API_TOKEN2", "NEW_KEY"] });
    const text = await readFile(join(t.web, ".env"), "utf8");
    expect(text).toBe(`# web stack\nDB_PASSWORD=${S2}\nOTHER=changed\nexport APP_NAME="My App" # name\nAPI_TOKEN2='tok-Alpha-Bravo-9931'\nNEW_KEY=n\n`);
    expect((await stat(join(t.web, ".env"))).mode & 0o777).toBe(0o640);
    expect((await readdir(t.web)).filter((f) => f.endsWith(".tmp"))).toEqual([]);
    // Token is single use.
    expect((await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true })).body.error.code).toBe("agent.preview.invalid");
    // Backup holds the previous version, 0600 in a 0700 directory.
    const b = await t.call("GET", `/v1/config-files/${id}/backups`);
    expect(b.body.backups).toHaveLength(1);
    expect(b.body.backups[0].id).toBe(s.body.backupId);
    const bdir = join(t.stateDir, "config-backups", id);
    expect((await stat(bdir)).mode & 0o777).toBe(0o700);
    expect((await stat(join(bdir, s.body.backupId))).mode & 0o777).toBe(0o600);
    expect(await readFile(join(bdir, s.body.backupId), "utf8")).toBe(ENV);
    // db.env (env_file) → services loading it
    const dbId = await t.idOf("web/db.env");
    const dd = await t.call("GET", `/v1/config-files/${dbId}`);
    const p2 = await t.call("POST", `/v1/config-files/${dbId}/preview`, { baseHash: dd.body.hash, ops: [{ op: "set", key: "POSTGRES_DB", value: "x" }] });
    expect(p2.body.affected).toEqual([{ stack: "web", project: "web", services: ["app", "cache"] }]);
    // Audit: file label, key names, restart; no values.
    const audit = await readFile(join(t.dir, "cfg", "audit.jsonl"), "utf8");
    const put = audit.split("\n").filter(Boolean).map((l) => JSON.parse(l)).find((e) => e.method === "PUT" && e.status === 200);
    expect(put.detail).toMatchObject({ file: "web/.env", keys: ["DB_PASSWORD", "OTHER", "API_TOKEN", "API_TOKEN2", "NEW_KEY"], restart: "none" });
    await t.app.close();
  });

  it("rejects a stale baseHash (preview and save) and leaves the file alone", async () => {
    const t = await setup();
    const id = await t.idOf("web/.env");
    const d = await t.call("GET", `/v1/config-files/${id}`);
    const p = await t.call("POST", `/v1/config-files/${id}/preview`, { baseHash: d.body.hash, ops: [{ op: "set", key: "OTHER", value: "mine" }] });
    await writeFile(join(t.web, ".env"), ENV.replace("plain", "theirs"));
    const s = await t.call("PUT", `/v1/config-files/${id}`, { previewToken: p.body.previewToken, confirm: true });
    expect(s.status).toBe(409);
    expect(s.body.error.code).toBe("agent.configfiles.conflict");
    expect(await readFile(join(t.web, ".env"), "utf8")).toContain("OTHER=theirs");
    const p2 = await t.call("POST", `/v1/config-files/${id}/preview`, { baseHash: d.body.hash, ops: [{ op: "set", key: "OTHER", value: "mine" }] });
    expect(p2.body.error.code).toBe("agent.configfiles.conflict");
    expect((await t.call("POST", `/v1/config-files/${id}/preview`, { baseHash: s.body.error.params.hash, ops: [{ op: "unset", key: "NOPE" }] })).body.error).toEqual({ code: "agent.configfiles.keyNotFound", params: { key: "NOPE" } });
    expect((await t.call("POST", `/v1/config-files/${id}/preview`, { baseHash: s.body.error.params.hash, ops: [{ op: "set", key: "OTHER", value: "theirs" }] })).body.error.code).toBe("agent.configfiles.noChange");
    await t.app.close();
  });

  it("keeps the original when the write fails midway, and refuses a file swapped before the rename", async () => {
    let mode: "fail" | "swap" | "none" = "fail";
    let dir = "";
    const t = await setup({
      hooks: {
        beforeRename: async () => {
          if (mode === "fail") throw new Error("disk full (simulated)");
          if (mode === "swap") {
            await rm(join(dir, "stack", "web", ".env"));
            await symlink(join(dir, "victim.env"), join(dir, "stack", "web", ".env"));
          }
        },
      },
      more: async (d) => {
        dir = d;
        await writeFile(join(d, "victim.env"), "VICTIM=1\n");
      },
    });
    const id = await t.idOf("web/.env");
    const r = await saveOps(t, id, [{ op: "set", key: "OTHER", value: "x" }]);
    expect(r.status).toBe(500);
    expect(r.body.error.code).toBe("agent.internal");
    expect(await readFile(join(t.web, ".env"), "utf8")).toBe(ENV);
    expect((await readdir(t.web)).filter((f) => f.endsWith(".tmp"))).toEqual([]);
    mode = "swap";
    const r2 = await saveOps(t, id, [{ op: "set", key: "OTHER", value: "x" }]);
    expect(r2.status).toBe(409);
    expect(r2.body.error.code).toBe("agent.configfiles.fileChanged");
    expect(await readFile(join(dir, "victim.env"), "utf8")).toBe("VICTIM=1\n");
    expect((await readdir(t.web)).filter((f) => f.endsWith(".tmp"))).toEqual([]);
    await t.app.close();
  });

  it("keeps the last 10 backups and restores one through preview + confirm", async () => {
    const t = await setup();
    const id = await t.idOf("web/.env");
    for (let i = 1; i <= 12; i++) expect((await saveOps(t, id, [{ op: "set", key: "OTHER", value: `v${i}` }])).status).toBe(200);
    const b = (await t.call("GET", `/v1/config-files/${id}/backups`)).body.backups;
    expect(b).toHaveLength(KEEP_BACKUPS);
    // Newest first: the newest backup holds v11 (the version before v12); the oldest kept holds v2.
    const bdir = join(t.stateDir, "config-backups", id);
    expect(await readFile(join(bdir, b[0].id), "utf8")).toContain("OTHER=v11");
    expect(await readFile(join(bdir, b[9].id), "utf8")).toContain("OTHER=v2");
    const target = b[9].id;
    const p = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: target });
    expect(p.status).toBe(200);
    expect(p.body.changes).toEqual([{ key: "OTHER", change: "changed", secret: false, line: 3, oldLine: 3, before: { length: 3, value: "v12" }, after: { length: 2, value: "v2" } }]);
    expect(p.body.affected).toEqual([{ stack: "web", project: "web", services: ["worker"] }]);
    expect((await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: b[0].id, previewToken: p.body.previewToken, confirm: true })).body.error.code).toBe("agent.preview.invalid");
    const p3 = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: target });
    const r = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: target, previewToken: p3.body.previewToken, confirm: true, restart: "none" });
    expect(r.status).toBe(200);
    expect(r.body).toMatchObject({ restoredFrom: target, keys: ["OTHER"] });
    expect(await readFile(join(t.web, ".env"), "utf8")).toContain("OTHER=v2\n");
    expect((await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: "2020-01-01T00-00-00-000Z" })).status).toBe(404);
    expect((await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: "../../x" })).status).toBe(400);
    await t.app.close();
  });

  it("reveal: ≤10 keys, 10 per minute per device, event with key names only", async () => {
    const t = await setup();
    const id = await t.idOf("web/.env");
    const keys = Array.from({ length: 11 }, (_, i) => `K${i}`);
    expect((await t.call("POST", `/v1/config-files/${id}/reveal`, { keys })).status).toBe(400);
    const r = await t.call("POST", `/v1/config-files/${id}/reveal`, { keys: ["DB_PASSWORD", "NOPE"] });
    expect(r.body).toEqual({ fileId: id, file: "web/.env", values: { DB_PASSWORD: S1 }, missing: ["NOPE"] });
    for (let i = 0; i < 9; i++) expect((await t.call("POST", `/v1/config-files/${id}/reveal`, { keys: ["OTHER"] })).status).toBe(200);
    const limited = await t.call("POST", `/v1/config-files/${id}/reveal`, { keys: ["OTHER"] });
    expect(limited.status).toBe(429);
    expect(limited.body.error.code).toBe("agent.configfiles.rateLimited");
    const ev = (await t.notifier.events!.list()).filter((e) => e.key === "secrets.revealed");
    expect(ev).toHaveLength(10);
    expect(ev.at(-1)).toMatchObject({ params: { file: "web/.env", keys: "DB_PASSWORD", count: 1 }, device: "phone" });
    await t.app.close();
  });

  it("secrets meta: fingerprints, user marks, max age, external changes", async () => {
    let now = Date.parse("2026-11-17T10:00:00Z");
    const t = await setup({ now: () => now });
    const id = await t.idOf("web/.env");
    let m = (await t.call("GET", "/v1/secrets/meta")).body.files.find((f: { fileId: string }) => f.fileId === id);
    expect(m.keys.map((k: { key: string }) => k.key).sort()).toEqual(["API_TOKEN", "DB_PASSWORD"]);
    expect(JSON.stringify(m)).not.toContain("fingerprint");
    const put = await t.call("PUT", "/v1/secrets/meta", {
      updates: [
        { fileId: id, key: "DB_PASSWORD", maxAgeDays: 30 },
        { fileId: id, key: "API_TOKEN", secret: false },
        { fileId: id, key: "OTHER", secret: true },
      ],
    });
    expect(put.status).toBe(200);
    const d = await t.call("GET", `/v1/config-files/${id}`);
    const byKey = Object.fromEntries(d.body.entries.map((e: { key: string }) => [e.key, e]));
    expect(byKey.API_TOKEN).toMatchObject({ secret: false, reason: "mark", value: "tok-Alpha-Bravo-9931" });
    expect(byKey.OTHER).toMatchObject({ secret: true, reason: "mark" });
    expect(byKey.OTHER.value).toBeUndefined();
    expect(byKey.DB_PASSWORD).toMatchObject({ maxAgeDays: 30, ageDays: 0, due: false });
    now += 31 * 86_400_000;
    m = (await t.call("GET", "/v1/secrets/meta")).body.files.find((f: { fileId: string }) => f.fileId === id);
    expect(m.keys.find((k: { key: string }) => k.key === "DB_PASSWORD")).toMatchObject({ due: true, ageDays: 31 });
    // Changed outside Tiphys → noticed on the next read.
    await writeFile(join(t.web, ".env"), ENV.replace(S1, "rotated-by-hand-Value-77"));
    await t.call("GET", `/v1/config-files/${id}`);
    m = (await t.call("GET", "/v1/secrets/meta")).body.files.find((f: { fileId: string }) => f.fileId === id);
    expect(m.keys.find((k: { key: string }) => k.key === "DB_PASSWORD")).toMatchObject({ changedBy: "external", due: false, ageDays: 0 });
    // Saved through Tiphys
    now += 86_400_000;
    await saveOps(t, id, [{ op: "set", key: "DB_PASSWORD", value: "via-tiphys-Value-88" }]);
    m = (await t.call("GET", "/v1/secrets/meta")).body.files.find((f: { fileId: string }) => f.fileId === id);
    expect(m.keys.find((k: { key: string }) => k.key === "DB_PASSWORD")).toMatchObject({ changedBy: "tiphys", lastChangedAt: new Date(now).toISOString() });
    expect((await t.call("PUT", "/v1/secrets/meta", { updates: [{ fileId: id, key: "NOPE", maxAgeDays: 1 }] })).status).toBe(404);
    expect((await stat(join(t.dir, "cfg", "secrets-meta.json"))).mode & 0o777).toBe(0o600);
    expect((await stat(join(t.dir, "cfg", "secrets-hmac.key"))).mode & 0o777).toBe(0o600);
    await t.app.close();
  });

  it("rejects service tokens on every route", async () => {
    const t = await setup();
    const id = await t.idOf("web/.env");
    const h = { authorization: `Bearer ${t.service}` };
    for (const [method, url] of [
      ["GET", "/v1/config-files"],
      ["GET", `/v1/config-files/${id}`],
      ["POST", `/v1/config-files/${id}/reveal`],
      ["POST", `/v1/config-files/${id}/preview`],
      ["PUT", `/v1/config-files/${id}`],
      ["GET", `/v1/config-files/${id}/backups`],
      ["POST", `/v1/config-files/${id}/restore`],
      ["GET", "/v1/secrets/meta"],
      ["PUT", "/v1/secrets/meta"],
    ] as const) {
      const res = await t.app.inject({ method, url, headers: h, ...(method === "GET" ? {} : { payload: { keys: ["DB_PASSWORD"] } }) });
      expect(res.statusCode, `${method} ${url}`).toBe(403);
      expect(res.json().error.code).toBe("agent.auth.scopeDenied");
    }
    await t.app.close();
  });

  it("LEAK: a known secret appears only in the .env file and the reveal response", async () => {
    const SECRET = "LeakCanary-7f3Kq9Zx2Wm8Rt5Yp1";
    const t = await setup();
    const id = await t.idOf("web/.env");
    await t.call("GET", `/v1/config-files/${id}`);
    // Failing requests carrying the value: validation error, malformed JSON, stale hash, unknown key, bad op.
    await t.call("POST", `/v1/config-files/${id}/preview`, { baseHash: "0".repeat(64), ops: [{ op: "set", key: "DB_PASSWORD", value: SECRET }] });
    await t.call("POST", `/v1/config-files/${id}/preview`, { baseHash: "bad", ops: [{ op: "set", key: "DB_PASSWORD", value: SECRET, extra: SECRET }] });
    await t.call("POST", `/v1/config-files/${id}/preview`, `{"ops":[{"op":"set","key":"DB_PASSWORD","value":"${SECRET}"}`);
    await t.call("POST", `/v1/config-files/${id}/preview`, { ops: [{ op: SECRET, key: SECRET, value: 1 }] });
    await t.call("POST", `/v1/config-files/${id}/reveal`, { keys: [SECRET] });
    await t.call("PUT", "/v1/secrets/meta", { updates: [{ fileId: id, key: "DB_PASSWORD", maxAgeDays: SECRET }] });
    // Full flow
    const s = await saveOps(t, id, [{ op: "set", key: "DB_PASSWORD", value: SECRET }, { op: "rename", key: "OTHER", newKey: "OTHER2" }]);
    expect(s.status).toBe(200);
    await t.call("GET", `/v1/config-files/${id}`);
    await t.call("GET", "/v1/config-files");
    await t.call("PUT", "/v1/secrets/meta", { updates: [{ fileId: id, key: "DB_PASSWORD", maxAgeDays: 90 }] });
    await t.call("GET", "/v1/secrets/meta");
    const b = (await t.call("GET", `/v1/config-files/${id}/backups`)).body.backups;
    const rp = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: b[0].id });
    // An edit after the secret is in place (its line is untouched but reparsed), then a restore back to the original.
    await saveOps(t, id, [{ op: "set", key: "NEW", value: "1" }]);
    const rp2 = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: b[0].id });
    expect(rp.status).toBe(200);
    const restored = await t.call("POST", `/v1/config-files/${id}/restore`, { backupId: b[0].id, previewToken: rp2.body.previewToken, confirm: true });
    expect(restored.status).toBe(200);
    await saveOps(t, id, [{ op: "set", key: "DB_PASSWORD", value: SECRET }]);
    const reveal = await t.call("POST", `/v1/config-files/${id}/reveal`, { keys: ["DB_PASSWORD"] });
    expect(reveal.body.values.DB_PASSWORD).toBe(SECRET);
    await t.app.close();
    await new Promise((r) => setTimeout(r, 50));

    // Everywhere except the .env itself, the backups (copies of it) and the one reveal response.
    expect(await readFile(join(t.web, ".env"), "utf8")).toContain(SECRET);
    const nonReveal = t.responses.filter((r) => r !== JSON.stringify(reveal.body));
    expect(t.responses.length - nonReveal.length).toBe(1);
    for (const r of nonReveal) expect(r).not.toContain(SECRET);
    expect(t.logs.length).toBeGreaterThan(10);
    expect(t.logs.join("")).not.toContain(SECRET);
    const scan = async (d: string, skip: (p: string) => boolean): Promise<string[]> => {
      const out: string[] = [];
      for (const e of await readdir(d, { withFileTypes: true })) {
        const p = join(d, e.name);
        if (skip(p)) continue;
        if (e.isDirectory()) out.push(...(await scan(p, skip)));
        else if (e.isFile()) out.push(p);
      }
      return out;
    };
    const all = await scan(t.dir, (p) => p === join(t.web, ".env") || p.startsWith(join(t.stateDir, "config-backups")));
    expect(all).toEqual(expect.arrayContaining([join(t.dir, "cfg", "audit.jsonl"), join(t.dir, "cfg", "events.jsonl"), join(t.dir, "cfg", "secrets-meta.json")]));
    for (const f of all) expect(await readFile(f, "utf8"), f).not.toContain(SECRET);
    // Not even split across a line break or JSON-escaped
    for (const f of all) expect(await readFile(f, "utf8"), f).not.toContain(SECRET.slice(0, 12));
  });
});
