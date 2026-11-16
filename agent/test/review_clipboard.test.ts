// 9.5 reviewing changes from the phone (commit selected files, push errors, revert to HEAD) and
// 9.6 clipboard sync (PC → phone watcher; with a fake wl-paste, without touching the real clipboard).
import { createECDH, randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { EventEmitter } from "node:events";
import { mkdtemp, readFile, writeFile, unlink } from "node:fs/promises";
import { existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PassThrough } from "node:stream";
import { generateRequestDetails } from "web-push";
import { describe, expect, it } from "vitest";
import { createServer } from "node:http";
import { Notifier, payloadOf, type Notice } from "../src/notify.ts";
import { CLIP_MAX_PAYLOAD, ClipboardWatcher, desktopRoutes, type ClipboardIo } from "../src/routes/desktop.ts";
import { remoteErrorCode } from "../src/routes/git.ts";
import { testApp } from "./helpers.ts";

const gitEnv = { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@e", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@e" };

async function repo() {
  const root = await mkdtemp(join(tmpdir(), "tiphys-review-"));
  const g = (...a: string[]) => execFileSync("git", ["-C", root, ...a], { env: gitEnv }).toString();
  g("init", "-q", "-b", "main");
  g("config", "user.name", "T");
  g("config", "user.email", "t@e");
  for (const f of ["a.txt", "b.txt", "gone.txt"]) await writeFile(join(root, f), `${f}\n`);
  await writeFile(join(root, ".gitignore"), "*.log\n");
  g("add", ".");
  g("commit", "-q", "-m", "ilk");
  const { app, auth, sent, notifier } = await testApp((c) => {
    c.features.git = true;
    c.allowedRoots = [root];
    return c;
  });
  const post = (url: string, payload: object) => app.inject({ method: "POST", url, headers: auth, payload });
  const status = async () => (await app.inject({ method: "GET", url: `/v1/git/status?path=${encodeURIComponent(root)}`, headers: auth })).json();
  const events = async () => (await app.inject({ method: "GET", url: "/v1/events", headers: auth })).json().events as Array<{ key: string; params: Record<string, unknown> }>;
  return { root, g, app, auth, post, status, events, sent, notifier };
}

describe("oturum değişikliklerini commit + push", () => {
  it("yalnız seçili dosyalar (yeni ve silinen dahil) commit'lenir; önceden hazırlanan başka dosya dışarıda kalır", async () => {
    const { root, g, app, post, status, events } = await repo();
    await writeFile(join(root, "a.txt"), "a2\n");
    await writeFile(join(root, "b.txt"), "b2\n");
    g("add", "b.txt"); // a file the user staged themselves, unrelated to the session
    await writeFile(join(root, "yeni.txt"), "yeni\n");
    await unlink(join(root, "gone.txt"));

    const c = await post("/v1/git/commit", { path: root, message: "Oturum: düzeltmeler\n\nayrıntı", files: ["a.txt", "yeni.txt", "gone.txt"] });
    expect(c.statusCode).toBe(200);
    expect(g("show", "--name-status", "--format=", "HEAD").trim().split("\n").sort()).toEqual(["A\tyeni.txt", "D\tgone.txt", "M\ta.txt"]);
    const st = await status();
    expect(st.files.map((f: { path: string; index: string }) => `${f.path}:${f.index}`)).toEqual(["b.txt:M"]);
    const [ev] = await events();
    expect(ev).toMatchObject({ key: "git.committed", params: { branch: "main", files: 3, subject: "Oturum: düzeltmeler", hash: c.json().hash.slice(0, 7) } });

    // Invalid requests: path outside the repo, all + files together.
    expect((await post("/v1/git/commit", { path: root, message: "x", files: ["../dışarı"] })).statusCode).toBe(400);
    expect((await post("/v1/git/commit", { path: root, message: "x", files: ["/etc/passwd"] })).statusCode).toBe(400);
    expect((await post("/v1/git/commit", { path: root, message: "x", all: true, files: ["a.txt"] })).statusCode).toBe(400);
    await app.close();
  });

  it("HEAD'e göre diff hazırlanmış ve hazırlanmamış değişikliği birlikte gösterir", async () => {
    const { root, g, app, auth } = await repo();
    await writeFile(join(root, "a.txt"), "a2\n");
    g("add", "a.txt");
    await writeFile(join(root, "a.txt"), "a3\n");
    const get = async (q: string) => (await app.inject({ method: "GET", url: `/v1/git/diff?path=${encodeURIComponent(root)}&file=a.txt${q}`, headers: auth })).json().diff as string;
    expect(await get("")).toContain("+a3");
    expect(await get("")).toContain("-a2");
    const head = await get("&head=true");
    expect(head).toContain("-a.txt");
    expect(head).toContain("+a3");
    await writeFile(join(root, "yeni.txt"), "yeni\n");
    expect((await app.inject({ method: "GET", url: `/v1/git/diff?path=${encodeURIComponent(root)}&file=yeni.txt&head=true`, headers: auth })).json().diff).toContain("+yeni");
    await app.close();
  });

  it("push: uzak depo yok, upstream yok → okunur hata; setUpstream ile gönderilir ve olay yazılır", async () => {
    const { root, g, app, post, events } = await repo();
    const none = await post("/v1/git/push", { path: root });
    expect(none.statusCode).toBe(409);
    expect(none.json().error.code).toBe("agent.git.noRemote");
    expect((await post("/v1/git/push", { path: root, setUpstream: true })).json().error.code).toBe("agent.git.noRemote");

    const bare = await mkdtemp(join(tmpdir(), "tiphys-bare-"));
    execFileSync("git", ["init", "-q", "--bare", bare]);
    g("remote", "add", "origin", bare);
    g("switch", "-q", "-c", "tiphys/abc12345");
    const noUp = await post("/v1/git/push", { path: root });
    expect(noUp.statusCode).toBe(409);
    expect(noUp.json().error).toMatchObject({ code: "agent.git.noUpstream", params: { branch: "tiphys/abc12345" } });

    const ok = await post("/v1/git/push", { path: root, setUpstream: true });
    expect(ok.statusCode).toBe(200);
    expect(execFileSync("git", ["-C", bare, "branch", "--list"]).toString()).toContain("tiphys/abc12345");
    expect(g("rev-parse", "--abbrev-ref", "@{u}").trim()).toBe("origin/tiphys/abc12345");
    expect((await post("/v1/git/push", { path: root })).statusCode).toBe(200);
    const evs = await events();
    expect(evs.filter((e) => e.key === "git.pushed")).toHaveLength(2);
    expect(evs[0]).toMatchObject({ key: "git.pushed", params: { branch: "tiphys/abc12345" } });
    await app.close();
  });

  it("push hata metinleri koda çevrilir", () => {
    expect(remoteErrorCode("push", "fatal: Authentication failed for 'https://x/'")).toBe("agent.git.authFailed");
    expect(remoteErrorCode("push", "fatal: could not read Username for 'https://github.com': terminal prompts disabled")).toBe("agent.git.authFailed");
    expect(remoteErrorCode("push", "git@github.com: Permission denied (publickey).")).toBe("agent.git.authFailed");
    expect(remoteErrorCode("push", " ! [rejected]        main -> main (fetch first)")).toBe("agent.git.pushRejected");
    expect(remoteErrorCode("push", "fatal: The current branch x has no upstream branch.")).toBe("agent.git.noUpstream");
    expect(remoteErrorCode("pull", "fatal: something else")).toBe("agent.git.pullFailed");
  });
});

describe("oturum değişikliklerini geri al (HEAD)", () => {
  it("yeni dosyalar açık onay olmadan silinmez; onayla izlenen dosyalar HEAD'e döner, yeniler silinir", async () => {
    const { root, g, app, post } = await repo();
    await writeFile(join(root, "a.txt"), "a2\n");
    g("add", "a.txt");
    await writeFile(join(root, "a.txt"), "a3\n");
    await unlink(join(root, "gone.txt"));
    await writeFile(join(root, "b.txt"), "b2\n"); // unrelated to the session: must not be touched
    await writeFile(join(root, "yeni.txt"), "yeni\n");
    await writeFile(join(root, "hazir.txt"), "hazır\n");
    g("add", "hazir.txt");
    await writeFile(join(root, "debug.log"), "gizli\n");
    const files = ["a.txt", "gone.txt", "yeni.txt", "hazir.txt"];

    expect((await post("/v1/git/discard", { path: root, files, source: "head" })).json().error.code).toBe("agent.git.confirmRequired");
    const need = await post("/v1/git/discard", { path: root, files, source: "head", confirm: true });
    expect(need.statusCode).toBe(409);
    expect(need.json().error).toMatchObject({ code: "agent.git.newFilesNeedConfirm", params: { files: "yeni.txt\nhazir.txt" } });
    expect(await readFile(join(root, "a.txt"), "utf8")).toBe("a3\n"); // nothing changed

    const ok = await post("/v1/git/discard", { path: root, files, source: "head", confirm: true, deleteNew: true });
    expect(ok.statusCode).toBe(200);
    expect(ok.json()).toMatchObject({ restored: ["a.txt", "gone.txt"], deleted: ["yeni.txt", "hazir.txt"] });
    expect(await readFile(join(root, "a.txt"), "utf8")).toBe("a.txt\n");
    expect(await readFile(join(root, "gone.txt"), "utf8")).toBe("gone.txt\n");
    expect(existsSync(join(root, "yeni.txt")) || existsSync(join(root, "hazir.txt"))).toBe(false);
    expect(g("status", "--porcelain").trim()).toBe("M b.txt");
    expect(existsSync(join(root, "debug.log"))).toBe(true);
    await app.close();
  });

  it("dosya adları joker/sihirli yol olarak yorumlanmaz; depo dışı yol reddedilir", async () => {
    const { root, g, app, post } = await repo();
    await writeFile(join(root, "a.txt"), "a2\n");
    await writeFile(join(root, "yeni.txt"), "yeni\n");
    for (const f of [":/", ":(glob)*", "*"]) {
      expect((await post("/v1/git/discard", { path: root, files: [f], source: "head", confirm: true, deleteNew: true })).statusCode, f).toBe(200);
    }
    expect(g("status", "--porcelain").split("\n").filter(Boolean).sort()).toEqual([" M a.txt", "?? yeni.txt"]);
    expect((await post("/v1/git/discard", { path: root, files: ["../x"], source: "head", confirm: true })).statusCode).toBe(400);
    // Old behavior (Git screen): an unstaged change reverts to its state in the index.
    expect((await post("/v1/git/discard", { path: root, files: ["a.txt"], confirm: true })).statusCode).toBe(200);
    expect(await readFile(join(root, "a.txt"), "utf8")).toBe("a.txt\n");
    await app.close();
  });
});

/** Fake wl-paste: clipboard content, its types and the watcher process are driven by the test. */
function fakeIo(init: { display?: boolean; text?: string; types?: string[] } = {}) {
  const state = { display: init.display ?? true, text: init.text ?? "", types: init.types ?? ["text/plain;charset=utf-8", "UTF8_STRING"], spawned: 0, killed: 0, written: [] as string[] };
  let child: (EventEmitter & { stdout: PassThrough; kill(): void }) | null = null;
  const io: ClipboardIo = {
    env: async () => (state.display ? { WAYLAND_DISPLAY: "wayland-1" } : null),
    watch: () => {
      state.spawned++;
      const c = Object.assign(new EventEmitter(), {
        stdout: new PassThrough(),
        kill() {
          state.killed++;
          c.emit("close", null);
        },
      });
      child = c;
      return c;
    },
    types: async () => state.types,
    read: async () => (state.text ? Buffer.from(state.text, "utf8") : null),
    write: async (_env, text) => {
      state.written.push(text);
    },
  };
  return {
    io,
    state,
    /** Clipboard changed: the watcher writes a line. */
    copy(text: string, types?: string[]) {
      state.text = text;
      if (types) state.types = types;
      child!.stdout.write("data\n");
    },
    crash: () => child!.emit("close", 1),
  };
}

const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("pano eşitleme (PC → telefon)", () => {
  it("metin değişince sessiz bildirim; parola, metin dışı, büyük, aynı ve telefondan gelen içerik atlanır", async () => {
    const { app, store, notifier, sent } = await testApp();
    const f = fakeIo({ text: "başlangıç" });
    const w = new ClipboardWatcher({ store, notifier }, f.io, { debounceMs: 5, checkMs: 60_000 });
    await w.reconcile();
    expect(w.watching).toBe(true);
    // The content present at startup is not sent.
    expect(await w.check()).toBe("same");
    f.state.text = "ssh user@100.64.0.2";
    expect(await w.check()).toBe("sent");
    expect(sent.at(-1)).toEqual({ key: "clipboard.pc", params: { text: "ssh user@100.64.0.2" }, priority: "low", sensitive: true });
    expect(await w.check()).toBe("same");
    f.state.types = ["text/plain", "x-kde-passwordManagerHint"];
    f.state.text = "parola123";
    expect(await w.check()).toBe("password");
    f.state.types = ["image/png"];
    expect(await w.check()).toBe("not-text");
    f.state.types = ["text/plain;charset=utf-8"];
    f.state.text = "ç".repeat(1501); // 3002 bayt
    expect(await w.check()).toBe("too-big");
    f.state.text = "x".repeat(3000);
    expect(await w.check()).toBe("sent");
    f.state.text = "\n".repeat(2999) + "x"; // JSON escaping pushes it over the payload limit
    expect(await w.check()).toBe("too-big");
    f.state.text = "   \n";
    expect(await w.check()).toBe("empty");
    w.fromPhone("telefondan");
    f.state.text = "telefondan";
    expect(await w.check()).toBe("from-phone");
    // Setting off: not even read.
    await store.update((c) => ({ ...c, desktop: { clipboardSync: false } }));
    f.state.text = "yeni";
    expect(await w.check()).toBe("disabled");
    w.stop();
    expect(sent.filter((n) => (n as Notice).key === "clipboard.pc")).toHaveLength(2);
    await app.close();
  });

  it("izleyici satırı debounce edilir; ayar kapanınca süreç durur; çökünce yeniden başlar; ekran yoksa boşta", async () => {
    const { app, store, notifier, sent } = await testApp();
    const f = fakeIo({ display: false });
    const w = new ClipboardWatcher({ store, notifier }, f.io, { debounceMs: 20, checkMs: 30, retryMs: 10 });
    w.start();
    await wait(80);
    expect(f.state.spawned).toBe(0); // no display
    f.state.display = true;
    await wait(60);
    expect(f.state.spawned).toBe(1);
    f.copy("bir");
    f.copy("iki"); // rapid successive changes: one notification, last text
    await wait(60);
    expect(sent.map((n) => (n as Notice).params?.text)).toEqual(["iki"]);
    f.crash();
    await wait(40);
    expect(f.state.spawned).toBe(2);
    await store.update((c) => ({ ...c, desktop: { clipboardSync: false } }));
    await wait(60);
    expect(w.watching).toBe(false);
    expect(f.state.killed).toBe(1);
    await store.update((c) => ({ ...c, desktop: { clipboardSync: true } }));
    await wait(60);
    expect(w.watching).toBe(true);
    w.stop();
    await app.close();
  });

  it("telefondan gelen metin geri yollanmaz; pano metni olaylara ve işlem kaydına yazılmaz", async () => {
    const f = fakeIo({ text: "eski" });
    const secret = "gizli-pano-metni-42";
    const { app, auth, sent, dir } = await testApp(
      (c) => c,
      [(a, ctx) => desktopRoutes(a, ctx, f.io, { debounceMs: 5, checkMs: 60_000 })],
    );
    await wait(20); // watcher started
    expect((await app.inject({ method: "PUT", url: "/v1/desktop/clipboard", headers: auth, payload: { text: secret } })).statusCode).toBe(200);
    expect(f.state.written).toEqual([secret]);
    // If the same text is already on the clipboard, it is not rewritten.
    f.state.text = secret;
    expect((await app.inject({ method: "PUT", url: "/v1/desktop/clipboard", headers: auth, payload: { text: secret } })).statusCode).toBe(200);
    expect(f.state.written).toEqual([secret]);
    f.copy(secret);
    await wait(30);
    expect(sent).toEqual([]);
    f.copy("pc'de kopyalandı " + secret);
    await wait(30);
    expect(sent).toHaveLength(1);
    const files = await Promise.all(["events.jsonl", "audit.jsonl"].map((n) => readFile(join(dir, n), "utf8").catch(() => "")));
    expect(files[1]).toContain("/v1/desktop/clipboard");
    for (const text of files) expect(text).not.toContain(secret);
    await app.close();
  });

  it("en büyük pano yükü şifrelenince WebPush sınırına (4096 bayt) sığar", () => {
    const ecdh = createECDH("prime256v1");
    ecdh.generateKeys();
    const keys = { p256dh: ecdh.getPublicKey().toString("base64url"), auth: randomBytes(16).toString("base64url") };
    // Text closest to the payload limit: filled up to CLIP_MAX_PAYLOAD with ASCII that needs no escaping.
    const n: Notice = { key: "clipboard.pc", params: { text: "" }, priority: "low", sensitive: true };
    n.params!.text = "x".repeat(CLIP_MAX_PAYLOAD - Buffer.byteLength(payloadOf(n)));
    expect(Buffer.byteLength(payloadOf(n))).toBe(CLIP_MAX_PAYLOAD);
    const req = generateRequestDetails({ endpoint: "https://ntfy.example/up1", keys }, payloadOf(n), { TTL: 60, contentEncoding: "aes128gcm" });
    expect((req.body as Buffer).length).toBeLessThanOrEqual(4096);
  });

  it("hassas bildirim yalnız şifreli uç noktalara gider, olay olarak yazılmaz", async () => {
    const got: Array<{ url: string; body: Buffer }> = [];
    const server = createServer((req, res) => {
      const chunks: Buffer[] = [];
      req.on("data", (c: Buffer) => chunks.push(c));
      req.on("end", () => {
        got.push({ url: req.url!, body: Buffer.concat(chunks) });
        res.end();
      });
    });
    await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
    const base = `http://127.0.0.1:${(server.address() as { port: number }).port}`;
    const ecdh = createECDH("prime256v1");
    ecdh.generateKeys();
    const { store, dir } = await testApp((c) => {
      c.push.endpoints = [
        { deviceId: "duz", url: `${base}/duz` },
        { deviceId: "sifreli", url: `${base}/sifreli`, pubKey: ecdh.getPublicKey().toString("base64url"), auth: randomBytes(16).toString("base64url") },
      ];
      return c;
    });
    const { EventLog } = await import("../src/events.ts");
    const events = new EventLog(join(dir, "ev.jsonl"));
    const n = new Notifier(() => store.get(), () => {}, events);
    expect(await n.send({ key: "clipboard.pc", params: { text: "gizli-pano" }, sensitive: true })).toBe(1);
    expect(got.map((g) => g.url)).toEqual(["/sifreli"]);
    expect(got[0]!.body.includes("gizli-pano")).toBe(false);
    expect(await events.list()).toEqual([]);
    expect(await n.send({ key: "push.test", params: { device: "x" } })).toBe(2);
    expect((await events.list()).map((e) => e.key)).toEqual(["push.test"]);
    server.close();
  });

  it("ayar: varsayılan açık, PATCH ile kapanır", async () => {
    const { app, auth } = await testApp();
    expect((await app.inject({ method: "GET", url: "/v1/config", headers: auth })).json().desktop).toEqual({ clipboardSync: true });
    const r = await app.inject({ method: "PATCH", url: "/v1/config", headers: auth, payload: { desktop: { clipboardSync: false } } });
    expect(r.json()).toMatchObject({ config: { desktop: { clipboardSync: false } }, restartRequired: false });
    await app.close();
  });
});
