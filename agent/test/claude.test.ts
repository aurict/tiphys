// Claude modülü: SDK'yı taklit eden sahte query ile (gerçek API çağrısı yapmaz).
import { spawn } from "node:child_process";
import { mkdtemp, mkdir, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { Options, Query, SDKMessage, SDKUserMessage } from "@anthropic-ai/claude-agent-sdk";
import { describe, expect, it } from "vitest";
import { claudeRoutes } from "../src/claude/routes.ts";
import { Notifier } from "../src/notify.ts";
import { buildApp } from "../src/server.ts";
import { testApp } from "./helpers.ts";

/** Gelen her kullanıcı mesajına senaryodaki adımlarla cevap veren sahte query. */
function fakeQuery(script: (text: string, opts: Options) => AsyncGenerator<SDKMessage>) {
  const calls: Options[] = [];
  let interrupted = false;
  const fn = (p: { prompt: AsyncIterable<SDKUserMessage>; options: Options }): Query => {
    calls.push(p.options);
    async function* gen() {
      yield { type: "system", subtype: "init", session_id: "11111111-1111-4111-8111-111111111111", model: "claude-opus-5-5", cwd: p.options.cwd, permissionMode: p.options.permissionMode, slash_commands: ["review", "init"] } as unknown as SDKMessage;
      for await (const m of p.prompt) {
        const c = m.message.content;
        const text = typeof c === "string" ? c : (c as Array<{ type: string; text?: string }>).find((b) => b.type === "text")?.text ?? "";
        for await (const out of script(text, p.options)) {
          if (interrupted) break;
          yield out;
        }
        interrupted = false;
      }
    }
    const g = gen() as unknown as Query;
    Object.assign(g, {
      interrupt: async () => {
        interrupted = true;
        return undefined;
      },
      setPermissionMode: async () => {},
      supportedCommands: async () => [{ name: "review", description: "Kod incelemesi", argumentHint: "" }],
      close: () => {},
    });
    return g;
  };
  return { fn, calls };
}

const assistant = (blocks: unknown[]) =>
  ({ type: "assistant", parent_tool_use_id: null, message: { content: blocks }, session_id: "s", uuid: "u" }) as unknown as SDKMessage;
const result = (text: string) =>
  ({ type: "result", subtype: "success", is_error: false, result: text, total_cost_usd: 0.0123, num_turns: 2, duration_ms: 1500, session_id: "11111111-1111-4111-8111-111111111111" }) as unknown as SDKMessage;

async function setup(script: Parameters<typeof fakeQuery>[0]) {
  const root = await mkdtemp(join(tmpdir(), "tiphys-claude-"));
  await mkdir(join(root, "proje"));
  const claudeDir = await mkdtemp(join(tmpdir(), "tiphys-claude-config-"));
  const fq = fakeQuery(script);
  const t = await testApp(
    (c) => ({ ...c, allowedRoots: [root], features: { ...c.features, claude: true }, claude: { ...c.claude, profiles: { ...c.claude.profiles, [c.claude.defaultProfile]: claudeDir } }, push: { endpoints: [{ deviceId: "phone", url: "http://127.0.0.1:9/up" }], token: null } }),
    [claudeRoutes(fq.fn)],
  );
  return { ...t, root, fq, claudeDir };
}

async function waitFor<T>(fn: () => Promise<T | undefined>, ms = 3000): Promise<T> {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    const v = await fn();
    if (v !== undefined) return v;
    await new Promise((r) => setTimeout(r, 20));
  }
  throw new Error("zaman aşımı");
}

describe("Claude oturumları", () => {
  it("oturum açar, metin/araç/sonuç olaylarını sırayla üretir ve bitince bildirir", async () => {
    const { app, auth, root, fq, sent } = await setup(async function* (text) {
      yield assistant([{ type: "text", text: `Tamam: ${text}` }, { type: "tool_use", id: "t1", name: "Bash", input: { command: "ls" } }]);
      yield { type: "user", parent_tool_use_id: null, message: { role: "user", content: [{ type: "tool_result", tool_use_id: "t1", content: "a.txt\nb.txt" }] } } as unknown as SDKMessage;
      yield result("Bitti");
    });
    const res = await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: join(root, "proje"), prompt: "dosyaları listele", permissionMode: "bypassPermissions", effort: "high" } });
    expect(res.statusCode).toBe(200);
    const id = res.json().id as string;
    expect(fq.calls[0]).toMatchObject({ cwd: join(root, "proje"), permissionMode: "bypassPermissions", allowDangerouslySkipPermissions: true, effort: "high" });
    expect(fq.calls[0]!.canUseTool).toBeUndefined();

    const events = await waitFor(async () => {
      const r = (await app.inject({ url: `/v1/claude/sessions/${id}`, headers: auth })).json();
      return r.session.status === "idle" ? r.events : undefined;
    });
    const kinds = events.map((e: { kind: string }) => e.kind);
    expect(kinds).toContain("init");
    expect(kinds.indexOf("text")).toBeLessThan(kinds.indexOf("tool_result"));
    expect(events.find((e: { kind: string }) => e.kind === "result")).toMatchObject({ ok: true, text: "Bitti", costUsd: 0.0123 });
    expect(sent).toContainEqual(expect.objectContaining({ key: "claude.done" }));

    // Aynı oturuma yeni mesaj
    await app.inject({ method: "POST", url: `/v1/claude/sessions/${id}/messages`, headers: auth, payload: { text: "bir daha" } });
    await waitFor(async () => {
      const r = (await app.inject({ url: `/v1/claude/sessions/${id}`, headers: auth })).json();
      return r.events.filter((e: { kind: string }) => e.kind === "result").length === 2 ? true : undefined;
    });
  });

  it("mesajsız açılan oturum boşta bekler, ilk mesaj başlığı olur", async () => {
    const { app, auth, root } = await setup(async function* (text) {
      yield result(`Tamam: ${text}`);
    });
    const res = await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: join(root, "proje") } });
    expect(res.statusCode).toBe(200);
    expect(res.json()).toMatchObject({ status: "idle", title: "" });
    const id = res.json().id as string;
    await app.inject({ method: "POST", url: `/v1/claude/sessions/${id}/messages`, headers: auth, payload: { text: "testleri çalıştır" } });
    const s = await waitFor(async () => {
      const r = (await app.inject({ url: `/v1/claude/sessions/${id}`, headers: auth })).json();
      return r.events.some((e: { kind: string }) => e.kind === "result") ? r.session : undefined;
    });
    expect(s).toMatchObject({ title: "testleri çalıştır", status: "idle" });
  });

  it("terminalde açık oturumlar ayrı listede, geçmişte tekrar görünmez", async () => {
    const { app, auth, root, claudeDir } = await setup(async function* () {});
    const id = "22222222-2222-4222-8222-222222222222";
    await mkdir(join(claudeDir, "sessions"));
    // Bu test sürecinin kendisi "terminaldeki Claude" yerine geçer (yaşıyor; procStart verilmedi).
    await writeFile(join(claudeDir, "sessions", `${process.pid}.json`), JSON.stringify({ pid: process.pid, sessionId: id, cwd: root, status: "idle", name: "deneme" }));
    const r = (await app.inject({ url: "/v1/claude/sessions", headers: auth })).json();
    expect(r.terminal).toEqual([expect.objectContaining({ pid: process.pid, sdkSessionId: id, status: "idle", title: "deneme" })]);
    expect(r.history.some((h: { sdkSessionId: string }) => h.sdkSessionId === id)).toBe(false);
  });

  it("terminaldeki oturum telefona devralınır: süreç kapanır, aynı oturum burada sürer", async () => {
    const { app, auth, root, claudeDir, fq } = await setup(async function* () {});
    const id = "33333333-3333-4333-8333-333333333333";
    await mkdir(join(claudeDir, "sessions"));
    const term = spawn("sleep", ["30"]); // terminaldeki Claude yerine
    const exited = new Promise<number | null>((r) => term.on("exit", (_c, sig) => r(sig === "SIGTERM" ? 1 : 0)));
    const file = join(claudeDir, "sessions", `${term.pid}.json`);
    const write = (status: string) => writeFile(file, JSON.stringify({ pid: term.pid, sessionId: id, cwd: join(root, "proje"), status }));
    const takeover = (payload: object) => app.inject({ method: "POST", url: `/v1/claude/terminal/${id}/takeover`, headers: auth, payload });

    await write("idle");
    expect((await takeover({})).json().error.code).toBe("agent.claude.confirmRequired");
    await write("busy");
    expect((await takeover({ confirm: true })).statusCode).toBe(409); // Claude çalışırken kesilmez
    expect(term.exitCode).toBeNull();

    await write("idle");
    const res = await takeover({ confirm: true, permissionMode: "acceptEdits" });
    expect(res.statusCode).toBe(200);
    expect(await exited).toBe(1); // SIGTERM ile kapandı
    expect(fq.calls).toHaveLength(0); // Claude süreci ilk mesajla başlar
    await app.inject({ method: "POST", url: `/v1/claude/sessions/${res.json().id}/messages`, headers: auth, payload: { text: "devam" } });
    expect(fq.calls.at(-1)).toMatchObject({ resume: id, cwd: join(root, "proje"), permissionMode: "acceptEdits" });
    expect(res.json()).toMatchObject({ status: "idle" }); // telefondan ilk mesajı bekler
    expect((await takeover({ confirm: true })).statusCode).toBe(404); // artık terminalde değil
  });

  it("ajan yeniden başlayınca canlı oturum aynı kimlikle, geçmişiyle geri gelir ve kaldığı yerden sürer", async () => {
    const script = async function* (text: string) {
      yield assistant([{ type: "text", text: `Tamam: ${text}` }]);
      yield result("Bitti");
    };
    const { app, auth, root, claudeDir, store } = await setup(script);
    const sdkId = "11111111-1111-4111-8111-111111111111"; // sahte query'nin init kimliği
    const res = await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: join(root, "proje"), prompt: "merhaba", effort: "high" } });
    const id = res.json().id as string;
    await waitFor(async () => ((await app.inject({ url: `/v1/claude/sessions/${id}`, headers: auth })).json().session.status === "idle" ? true : undefined));
    // Claude'un kendi kaydı (geri yüklemede geçmiş buradan okunur)
    await mkdir(join(claudeDir, "projects", "p"), { recursive: true });
    await writeFile(
      join(claudeDir, "projects", "p", `${sdkId}.jsonl`),
      [
        { type: "user", uuid: "u1", parentUuid: null, message: { role: "user", content: "merhaba" } },
        { type: "assistant", uuid: "a1", parentUuid: "u1", message: { role: "assistant", content: [{ type: "text", text: "Tamam: merhaba" }] } },
      ].map((r) => JSON.stringify(r)).join("\n") + "\n",
    );
    await app.close(); // ajan kapanıyor (güncelleme/çökme)

    const fq2 = fakeQuery(script);
    const app2 = await buildApp({ store, notifier: new Notifier(() => store.get(), () => {}), extraRoutes: [claudeRoutes(fq2.fn)] });
    const back = (await app2.inject({ url: `/v1/claude/sessions/${id}`, headers: auth })).json();
    expect(back.session).toMatchObject({ id, sdkSessionId: sdkId, status: "idle", title: "merhaba" });
    expect(back.events.map((e: { kind: string }) => e.kind)).toEqual(["user", "text", "restored", "status"]);
    expect(fq2.calls).toHaveLength(0); // mesaj gelene kadar Claude süreci yok
    await app2.inject({ method: "POST", url: `/v1/claude/sessions/${id}/messages`, headers: auth, payload: { text: "devam et" } });
    expect(fq2.calls[0]).toMatchObject({ resume: sdkId, cwd: join(root, "proje"), effort: "high" });
    await app2.close();
  });

  it("Claude süreci çökerse sonraki mesaj yeni süreçle, aynı konuşmadan devam eder", async () => {
    let first = true;
    const { app, auth, root, fq } = await setup(async function* (text) {
      if (first) {
        first = false;
        throw new Error("süreç beklenmedik şekilde kapandı");
      }
      yield result(`Tamam: ${text}`);
    });
    const id = (await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: join(root, "proje"), prompt: "bir" } })).json().id as string;
    const get = async () => (await app.inject({ url: `/v1/claude/sessions/${id}`, headers: auth })).json();
    await waitFor(async () => ((await get()).session.status === "error" ? true : undefined));
    await app.inject({ method: "POST", url: `/v1/claude/sessions/${id}/messages`, headers: auth, payload: { text: "iki" } });
    await waitFor(async () => ((await get()).session.status === "idle" ? true : undefined));
    expect(fq.calls).toHaveLength(2);
    expect(fq.calls[1]).toMatchObject({ resume: "11111111-1111-4111-8111-111111111111" });
  });

  it("aynı clientId ile tekrar gönderilen mesaj ikinci kez işlenmez", async () => {
    const { app, auth, root } = await setup(async function* (text) {
      yield result(`Tamam: ${text}`);
    });
    const id = (await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: join(root, "proje") } })).json().id as string;
    const send = () => app.inject({ method: "POST", url: `/v1/claude/sessions/${id}/messages`, headers: auth, payload: { text: "bir kez", clientId: "abcdef0123456789" } });
    expect((await send()).json()).toEqual({ ok: true, duplicate: false });
    expect((await send()).json()).toEqual({ ok: true, duplicate: true }); // zaman aşımı sonrası yeniden deneme
    const r = (await app.inject({ url: `/v1/claude/sessions/${id}`, headers: auth })).json();
    expect(r.events.filter((e: { kind: string }) => e.kind === "user")).toHaveLength(1);
  });

  it("izin sorulur, telefon onaylayınca devam eder; reddedince araç çalışmaz", async () => {
    const decisions: string[] = [];
    const { app, auth, root, fq, sent } = await setup(async function* (_text, opts) {
      const r = await opts.canUseTool!("Bash", { command: "rm -rf build" }, { signal: new AbortController().signal, decisionReason: "yıkıcı komut" } as never);
      decisions.push(r?.behavior ?? "none");
      yield result(r?.behavior ?? "none");
    });
    const id = (await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: root, prompt: "temizle" } })).json().id;
    expect(fq.calls[0]!.permissionMode).toBe("default");
    const perm = await waitFor(async () => {
      const r = (await app.inject({ url: `/v1/claude/sessions/${id}`, headers: auth })).json();
      return r.events.find((e: { kind: string }) => e.kind === "permission");
    });
    expect(perm).toMatchObject({ toolName: "Bash", input: { command: "rm -rf build" }, reason: "yıkıcı komut" });
    expect(sent).toContainEqual(expect.objectContaining({ key: "claude.waiting", data: expect.objectContaining({ requestId: expect.any(String) }) }));
    const summary = (await app.inject({ url: "/v1/claude/sessions", headers: auth })).json();
    expect(summary.live[0]).toMatchObject({ status: "waiting", pendingPermissions: 1 });

    await app.inject({ method: "POST", url: `/v1/claude/sessions/${id}/permissions/${perm.requestId}`, headers: auth, payload: { allow: false } });
    await waitFor(async () => (decisions.length ? true : undefined));
    expect(decisions).toEqual(["deny"]);
    // Aynı isteğe ikinci kez cevap verilemez
    const again = await app.inject({ method: "POST", url: `/v1/claude/sessions/${id}/permissions/${perm.requestId}`, headers: auth, payload: { allow: true } });
    expect(again.json().error.code).toBe("agent.claude.permission.notFound");
  });

  it("worktree seçilirse oturum yeni dalda, kardeş klasörde açılır", async () => {
    const { execFileSync } = await import("node:child_process");
    const { writeFile } = await import("node:fs/promises");
    const { app, auth, root, fq } = await setup(async function* () {
      yield result("tamam");
    });
    const repo = join(root, "depo");
    await mkdir(join(repo, "alt"), { recursive: true });
    const g = (...a: string[]) => execFileSync("git", ["-C", repo, ...a], { encoding: "utf8" });
    g("init", "-q", "-b", "main");
    g("config", "user.name", "T");
    g("config", "user.email", "t@e");
    await writeFile(join(repo, "alt", "a.txt"), "x\n");
    g("add", ".");
    g("commit", "-q", "-m", "ilk");
    const res = await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: join(repo, "alt"), prompt: "deneme", worktree: true } });
    expect(res.statusCode, res.body).toBe(200);
    const cwd = fq.calls[0]!.cwd!;
    expect(cwd).toMatch(new RegExp(`${root.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}/depo-tiphys-[0-9a-f]{8}/alt$`));
    expect(g("worktree", "list")).toContain("tiphys/");
    const notRepo = await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: join(root, "proje"), prompt: "x", worktree: true } });
    expect(notRepo.json().error.code).toBe("agent.claude.notGitRepo");
    await app.close();
  });

  it("izinli kökler dışındaki klasörü reddeder", async () => {
    const { app, auth } = await setup(async function* () {});
    const r = await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: "/etc", prompt: "x" } });
    expect(r.statusCode).toBe(403);
    expect(r.json().error.code).toBe("agent.claude.folderNotAllowed");
    const r2 = await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: "/yok/boyle/bir/yer", prompt: "x" } });
    expect(r2.json().error.code).toBe("agent.claude.folderNotFound");
  });

  it("izinli kökü taklit eden yol (önek) kabul edilmez", async () => {
    const { app, auth, root } = await setup(async function* () {});
    await mkdir(`${root}-sahte`);
    const r = await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: `${root}-sahte`, prompt: "x" } });
    expect(r.json().error.code).toBe("agent.claude.folderNotAllowed");
  });

  it("izin sorarak başlayan oturum sonradan izinsize geçemez", async () => {
    const { app, auth, root } = await setup(async function* () {});
    const id = (await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: root, prompt: "x" } })).json().id;
    const r = await app.inject({ method: "POST", url: `/v1/claude/sessions/${id}/mode`, headers: auth, payload: { permissionMode: "bypassPermissions" } });
    expect(r.json().error.code).toBe("agent.claude.bypassNeedsNewSession");
    const ok = await app.inject({ method: "POST", url: `/v1/claude/sessions/${id}/mode`, headers: auth, payload: { permissionMode: "acceptEdits" } });
    expect(ok.json().permissionMode).toBe("acceptEdits");
  });

  it("slash komutları ve klasör listesi", async () => {
    const { app, auth, root } = await setup(async function* () {});
    const c = (await app.inject({ url: `/v1/claude/commands?cwd=${encodeURIComponent(root)}`, headers: auth })).json();
    expect(c.commands[0]).toMatchObject({ name: "review" });
    const d = (await app.inject({ url: `/v1/fs/dirs?path=${encodeURIComponent(root)}`, headers: auth })).json();
    expect(d.dirs.map((x: { name: string }) => x.name)).toEqual(["proje"]);
  });

  it("WebSocket akışı birikmiş olayları ve yenilerini gönderir", async () => {
    const { app, auth, root, token } = await setup(async function* (text) {
      await new Promise((r) => setTimeout(r, 200));
      yield assistant([{ type: "text", text: `yanıt ${text}` }]);
      yield result("ok");
    });
    const id = (await app.inject({ method: "POST", url: "/v1/claude/sessions", headers: auth, payload: { cwd: root, prompt: "selam", permissionMode: "acceptEdits" } })).json().id;
    await app.ready();
    const ws = await app.injectWS(`/v1/claude/sessions/${id}/stream?token=${token}`);
    const got: Array<{ kind: string; text?: string }> = [];
    ws.on("message", (d: Buffer) => got.push(JSON.parse(d.toString())));
    await waitFor(async () => (got.some((e) => e.kind === "result") ? true : undefined));
    expect(got.find((e) => e.kind === "user")?.text).toBe("selam");
    expect(got.find((e) => e.kind === "text")?.text).toBe("yanıt selam");
    ws.terminate();
  });
});
