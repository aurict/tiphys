// 11.4 Mobile view: helper process manager (fake helper script), IsEnabled enable/restore (including crash
// recovery), endpoints (auth/control, visibility, stale id, unsupported, password confirmation, typing fallback, SSE)
// and the VS Code launcher rewrite. The real PC, D-Bus and the user's home directory are never touched.
import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { A11yStatus, AtspiHelper, HELPER_PATH, atspiRoutes, type HelperChild, type UiIo } from "../src/atspi.ts";
import { RateLimit, type Exec, type Indicator } from "../src/control.ts";
import { AppError } from "../src/errors.ts";
import { hyprRoutes, type HyprIo } from "../src/routes/hypr.ts";
import type { Ctx } from "../src/server.ts";
import { A11Y_FLAG, addA11yFlag, vscodeA11y, vscodePaths } from "../src/vscode_a11y.ts";
import { testApp } from "./helpers.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const FAKE = join(HERE, "fake_atspi_helper.mjs");

const fakeChild = (mode = "ok", logFile?: string): HelperChild =>
  spawn(process.execPath, [FAKE], { env: { ...process.env, FAKE_MODE: mode, FAKE_LOG: logFile ?? "" }, stdio: ["pipe", "pipe", "ignore"] });

const client = (o: Record<string, unknown>) => ({
  address: "0x55d1a0", mapped: true, hidden: false, at: [0, 0], size: [900, 700], workspace: { id: 1, name: "1" }, floating: false,
  monitor: 0, class: "firefox", title: "Giriş — Mozilla Firefox", pid: 4321, pinned: false, fullscreen: 0, focusHistoryID: 0, ...o,
});
const CLIENTS = [
  client({}),
  client({ address: "0x55d1b0", class: "kitty", title: "~", pid: 999 }),
  client({ address: "0x55d1c0", class: "org.gnome.Nautilus", title: "Ev", pid: 555, workspace: { id: 2, name: "2" } }),
  client({ address: "0x55d1d0", class: "boş", title: "Boş", pid: 777 }),
  client({ address: "0x55d1e0", class: "pidsiz", title: "?", pid: 0 }),
  client({ address: "0x55d1f0", class: "Mousepad", title: "Not", pid: 31 }),
];
const MONITORS = [{ id: 0, name: "DP-1", width: 1920, height: 1080, x: 0, y: 0, scale: 1, focused: true, activeWorkspace: { id: 1 }, specialWorkspace: { id: 0 } }];

/** Fake outside world: hyprctl, busctl (IsEnabled state kept in memory), ydotool/wtype. */
function world(o: { enabled?: boolean; busFails?: boolean; clientsGate?: () => Promise<void>; setDelayMs?: number; clients?: unknown[] } = {}) {
  const calls: string[] = [];
  const typed: string[] = [];
  const bus = { enabled: o.enabled ?? false };
  const ok = (stdout: string) => ({ stdout, stderr: "", code: 0 });
  const exec: Exec = async (cmd, args) => {
    calls.push(`${cmd} ${args.join(" ")}`);
    if (cmd === "hyprctl" && args[0] === "-j" && args[1] === "clients") {
      await o.clientsGate?.();
      return ok(JSON.stringify(o.clients ?? CLIENTS));
    }
    if (cmd === "hyprctl" && args[0] === "-j" && args[1] === "monitors") return ok(JSON.stringify(MONITORS));
    if (cmd === "hyprctl" && args[0] === "eval") return ok("unknown request\n");
    if (cmd === "hyprctl") return ok("ok\n");
    if (cmd === "busctl") {
      if (o.busFails) throw new AppError("agent.exec.commandMissing", 500);
      expect(args.slice(0, 1).concat(args.slice(2, 6))).toEqual(["--user", "org.a11y.Bus", "/org/a11y/bus", "org.a11y.Status", "IsEnabled"]);
      if (args[1] === "get-property") return ok(`b ${bus.enabled}\n`);
      if (args[1] === "set-property") {
        if (o.setDelayMs) await new Promise((r) => setTimeout(r, o.setDelayMs));
        bus.enabled = args[7] === "true";
        return ok("");
      }
    }
    if (cmd === "ydotool" || cmd === "notify-send") return ok("");
    throw new Error(`beklenmeyen komut ${cmd} ${args.join(" ")}`);
  };
  const hyprIo: HyprIo = {
    exec,
    bytes: async () => ({ out: Buffer.alloc(0), code: 0, err: "" }),
    has: async () => false,
    hyprEnv: async () => ({ HYPRLAND_INSTANCE_SIGNATURE: "sig" }),
    screenEnv: async () => ({}),
  };
  return { calls, typed, bus, exec, hyprIo };
}

const indicator: Indicator = { on: async () => {}, off: async () => {} };

async function uiApp(w = world(), opts: { mode?: string; control?: boolean; idleMs?: number; stateFile?: string; log?: string; recheckMs?: number; onSpawn?: () => void } = {}) {
  let ctx: Ctx | null = null;
  const io: UiIo = {
    exec: w.exec,
    hyprEnv: w.hyprIo.hyprEnv,
    input: {
      exec: w.exec,
      bytes: async (cmd, _args, o) => {
        w.typed.push(`${cmd}:${o.input?.toString("utf8")}`);
        return { out: Buffer.alloc(0), code: 0, err: "" };
      },
      inputEnv: async () => ({}),
    },
    spawnHelper: () => (opts.onSpawn?.(), fakeChild(opts.mode, opts.log)),
  };
  const t = await testApp(
    (c) => {
      c.features.control = opts.control ?? true;
      return c;
    },
    [
      (a, c) => {
        ctx = c;
        hyprRoutes(a, c, w.hyprIo, { indicator });
        atspiRoutes(a, c, io, { idleMs: opts.idleMs, stateFile: opts.stateFile, limit: new RateLimit(1000, 1000), recheckMs: opts.recheckMs });
      },
    ],
  );
  await t.app.ready();
  const session = async () => {
    const r = await t.app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: t.auth, payload: {} });
    return { ...t.auth, "x-tiphys-control": r.json().token as string };
  };
  const state = join(t.dir, "a11y-state.json");
  return { ...t, w, session, state, ctx: ctx! };
}

const until = async (fn: () => boolean | Promise<boolean>, ms = 3000) => {
  const end = Date.now() + ms;
  while (!(await fn())) {
    if (Date.now() > end) throw new Error("zaman aşımı");
    await new Promise((r) => setTimeout(r, 20));
  }
};

describe("AtspiHelper (sahte yardımcı)", () => {
  it("istek/yanıt, olaylar, hata kodları; durdurunca süreç ölür", async () => {
    const log = join(await mkdtemp(join(tmpdir(), "tiphys-ui-")), "log");
    const h = new AtspiHelper(() => fakeChild("ok", log));
    const events: string[] = [];
    h.onEvent = (e) => events.push(e);
    expect(h.running).toBe(false);
    const s = await h.request("snapshot", { pid: 4321, title: "x" });
    expect(s).toMatchObject({ ok: true, gen: 1, partial: true });
    await expect(h.request("act", { gen: 9, node: "0.0", action: "press" })).rejects.toMatchObject({ code: "agent.ui.stale", status: 409 });
    await expect(h.request("snapshot", { pid: 999 })).rejects.toMatchObject({ code: "agent.ui.unsupported" });
    await h.request("act", { gen: 1, node: "0.0", action: "press" });
    await until(() => events.includes("changed"));
    h.stop();
    expect(h.running).toBe(false);
    expect((await readFile(log, "utf8")).match(/^start/gm)).toHaveLength(1);
  });

  it("python3-gi yok → helperMissing, yeniden başlatılmaz", async () => {
    let spawned = 0;
    const h = new AtspiHelper(() => (spawned++, fakeChild("missing")));
    await expect(h.request("snapshot", { pid: 1 })).rejects.toMatchObject({ code: "agent.ui.helperMissing", status: 503 });
    await expect(h.request("snapshot", { pid: 1 })).rejects.toMatchObject({ code: "agent.ui.helperMissing" });
    expect(spawned).toBe(1);
    const none = new AtspiHelper(() => spawn("/yok/python3-tiphys", [], { stdio: ["pipe", "pipe", "ignore"] }));
    await expect(none.request("snapshot", { pid: 1 })).rejects.toMatchObject({ code: "agent.ui.helperMissing" });
    const old = new AtspiHelper(() => fakeChild("version"));
    await expect(old.request("snapshot", { pid: 1 })).rejects.toMatchObject({ code: "agent.ui.helperMissing" });
    old.stop();
  });

  it("çökme: bekleyen istek düşer, bir kez yeniden başlar, ikinci çöküşten sonra durur; stop() sıfırlar", async () => {
    let spawned = 0;
    const h = new AtspiHelper(() => (spawned++, fakeChild("crash")));
    const events: string[] = [];
    h.onEvent = (e) => events.push(e);
    await expect(h.request("snapshot", { pid: 4321 })).rejects.toMatchObject({ code: "agent.ui.helperFailed" });
    await until(() => events.includes("changed"));
    await expect(h.request("snapshot", { pid: 4321 })).rejects.toMatchObject({ code: "agent.ui.helperFailed" });
    await expect(h.request("snapshot", { pid: 4321 })).rejects.toMatchObject({ code: "agent.ui.helperFailed" });
    expect(spawned).toBe(2);
    h.stop();
    await expect(h.request("snapshot", { pid: 4321 })).rejects.toMatchObject({ code: "agent.ui.helperFailed" });
    expect(spawned).toBe(3);
  });

  it("zaman aşımı ve satır sınırı", async () => {
    const hang = new AtspiHelper(() => fakeChild("hang"), { timeoutMs: 200 });
    await expect(hang.request("snapshot", { pid: 4321 })).rejects.toMatchObject({ code: "agent.ui.timeout", status: 504 });
    hang.stop();
    const big = new AtspiHelper(() => fakeChild("big"), { maxLine: 100_000 });
    await expect(big.request("snapshot", { pid: 4321 })).rejects.toMatchObject({ code: "agent.ui.helperFailed" });
    expect(big.running).toBe(false);
  });

  it("zaman aşımında askıdaki yardımcı öldürülür (çöküş sayılır), sonraki istek yeniden başlatır", async () => {
    let spawned = 0;
    const h = new AtspiHelper(() => (spawned++, fakeChild("hang")), { timeoutMs: 150 });
    const events: string[] = [];
    h.onEvent = (e) => events.push(e);
    await expect(h.request("snapshot", { pid: 4321 })).rejects.toMatchObject({ code: "agent.ui.timeout" });
    await until(() => !h.running);
    expect(events).toContain("changed");
    await expect(h.request("snapshot", { pid: 4321 })).rejects.toMatchObject({ code: "agent.ui.timeout" });
    expect(spawned).toBe(2);
    await until(() => !h.running);
    await expect(h.request("snapshot", { pid: 4321 })).rejects.toMatchObject({ code: "agent.ui.helperFailed" }); // two crashes
    h.stop();
  });

  it("yardımcı yolu paket içinde (src/ ve dist/ aynı helpers/ klasörünü gösterir)", () => {
    expect(HELPER_PATH).toBe(join(HERE, "..", "helpers", "atspi_helper.py"));
    expect(existsSync(HELPER_PATH)).toBe(true);
    const r = spawnSync("python3", ["-I", "-c", "import ast,sys; ast.parse(open(sys.argv[1]).read())", HELPER_PATH]);
    expect(r.status).toBe(0);
  });
});

describe("org.a11y.Status.IsEnabled", () => {
  it("aç: eski değer kaydedilir; kapat: geri yazılır ve kayıt silinir; zaten açıksa dokunulmaz", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-a11y-"));
    const w = world();
    const a = new A11yStatus(w.exec, join(dir, "a11y-state.json"));
    await a.enable();
    expect(w.bus.enabled).toBe(true);
    expect(JSON.parse(await readFile(join(dir, "a11y-state.json"), "utf8"))).toEqual({ previous: false });
    await a.enable(); // the second start doesn't mistake the "old value" for true
    expect(JSON.parse(await readFile(join(dir, "a11y-state.json"), "utf8"))).toEqual({ previous: false });
    await a.restore();
    expect(w.bus.enabled).toBe(false);
    expect(existsSync(join(dir, "a11y-state.json"))).toBe(false);

    const on = world({ enabled: true });
    const b = new A11yStatus(on.exec, join(dir, "b.json"));
    await b.enable();
    await b.restore();
    expect(on.bus.enabled).toBe(true);
    expect(on.calls.filter((c) => c.includes("set-property"))).toEqual([]);
  });

  it("çökme kurtarma: açılışta kayıt varsa geri yazılır", async () => {
    const w = world({ enabled: true }); // the previous run set it to true and crashed
    const dir = await mkdtemp(join(tmpdir(), "tiphys-a11y-"));
    const stateFile = join(dir, "a11y-state.json");
    await writeFile(stateFile, JSON.stringify({ previous: false }) + "\n");
    const t = await uiApp(w, { stateFile });
    await until(() => !existsSync(stateFile));
    expect(w.bus.enabled).toBe(false);
    await t.app.close();
  });
});

describe("uçlar /v1/desktop/ui", () => {
  it("yetki: cihaz belirteci, control özelliği, kontrol oturumu", async () => {
    const t = await uiApp();
    expect((await t.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0" })).statusCode).toBe(401);
    const r = await t.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: t.auth });
    expect(r.json().error.code).toBe("agent.control.sessionRequired");
    const bad = await t.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: { ...t.auth, "x-tiphys-control": "tpc_yanlis" } });
    expect(bad.statusCode).toBe(403);
    for (const url of ["/v1/desktop/ui/act", "/v1/desktop/ui/text", "/v1/desktop/ui/value"]) {
      const p = await t.app.inject({ method: "POST", url, headers: t.auth, payload: { address: "0x55d1a0", gen: 1, id: "0", action: "press", text: "x", value: 1 } });
      expect(p.json().error.code).toBe("agent.control.sessionRequired");
    }
    expect(t.w.calls.filter((c) => c.startsWith("busctl"))).toEqual([]);
    const off = await uiApp(world(), { control: false });
    const o = await off.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: off.auth });
    expect(o.json().error.code).toBe("agent.control.disabled");
    await t.app.close();
    await off.app.close();
  });

  it("anlık görüntü, görünürlük, desteklenmeyen, eski kimlik, eylemler, şifre onayı, yazma yedeği; olay kaydında içerik yok", async () => {
    const log = join(await mkdtemp(join(tmpdir(), "tiphys-ui-")), "log");
    const t = await uiApp(world(), { log });
    const h = await t.session();
    const get = (address: string) => t.app.inject({ method: "GET", url: `/v1/desktop/ui?address=${address}`, headers: h });
    const post = (what: string, payload: object) => t.app.inject({ method: "POST", url: `/v1/desktop/ui/${what}`, headers: h, payload });

    expect((await get("0x55d1c0")).json().error.code).toBe("agent.desktop.windowNotVisible"); // another workspace
    expect((await get("0xdead")).json().error.code).toBe("agent.desktop.windowNotFound");
    expect((await get("garip")).statusCode).toBe(400);
    expect((await get("0x55d1e0")).json().error.code).toBe("agent.ui.unsupported"); // no pid
    expect(existsSync(log)).toBe(false); // the helper doesn't start when there is no visible window

    const k = await get("0x55d1b0"); // kitty: no tree
    expect([k.statusCode, k.json().error.code]).toEqual([422, "agent.ui.unsupported"]);
    expect((await get("0x55d1d0")).json().error.code).toBe("agent.ui.unsupported"); // tree without nodes
    expect(t.w.bus.enabled).toBe(true);
    expect(JSON.parse(await readFile(t.state, "utf8"))).toEqual({ previous: false });

    const s = await get("0x55d1a0");
    expect(s.statusCode).toBe(200);
    const snap = s.json();
    expect(snap).toMatchObject({ address: "0x55d1a0", class: "firefox", title: "Giriş — Mozilla Firefox", partial: true });
    expect(snap.nodes.find((n: { role: string }) => n.role === "password text")).toMatchObject({ text: null, password: true });
    const gen = snap.gen as number;

    // Stale generation, another window, unknown id → refresh.
    expect((await post("act", { address: "0x55d1a0", gen: gen - 1, id: "0.0", action: "press" })).json().error.code).toBe("agent.ui.stale");
    expect((await post("act", { address: "0x55d1f0", gen, id: "0.0", action: "press" })).json().error.code).toBe("agent.ui.stale");
    expect((await post("act", { address: "0x55d1a0", gen, id: "9", action: "press" })).json().error.code).toBe("agent.ui.stale");
    expect((await post("act", { address: "0x55d1a0", gen, id: "0;rm", action: "press" })).statusCode).toBe(400);
    expect((await post("act", { address: "0x55d1a0", gen, id: "0.0", action: "$(x)" })).statusCode).toBe(400);
    expect((await post("act", { address: "0x55d1a0", gen, id: "0.0" })).statusCode).toBe(400);

    expect((await post("act", { address: "0x55d1a0", gen, id: "0.0", action: "press" })).json()).toEqual({ ok: true });
    expect((await post("act", { address: "0x55d1a0", gen, id: "1", op: "focus" })).json()).toEqual({ ok: true });
    expect((await post("value", { address: "0x55d1a0", gen, id: "3", value: 7 })).json()).toEqual({ ok: true });

    const pw = await post("text", { address: "0x55d1a0", gen, id: "2", text: "gizli" });
    expect([pw.statusCode, pw.json().error.code]).toEqual([409, "agent.ui.confirmRequired"]);
    expect((await post("text", { address: "0x55d1a0", gen, id: "2", text: "gizli", confirm: true })).json()).toEqual({ ok: true, typed: false });
    expect((await post("text", { address: "0x55d1a0", gen, id: "1", text: "a\u0001" })).statusCode).toBe(400);
    expect(t.w.typed).toEqual([]);
    // No editable interface: the window is raised and the text is typed with wtype.
    expect((await post("text", { address: "0x55d1a0", gen, id: "4", text: "Çağrı" })).json()).toEqual({ ok: true, typed: true });
    expect(t.w.calls).toContain("hyprctl dispatch focuswindow address:0x55d1a0");
    expect(t.w.typed).toEqual(["wtype:Çağrı"]);

    const events = await readFile(join(t.dir, "events.jsonl"), "utf8");
    const opened = events.split("\n").filter(Boolean).map((l) => JSON.parse(l)).filter((e) => e.key === "ui.opened");
    expect(opened.map((e) => e.params)).toEqual([{ class: "kitty" }, { class: "boş" }, { class: "firefox" }]);
    for (const secret of ["gizli", "Çağrı", "Giriş", "Şifre"]) expect(events).not.toContain(secret);
    await t.app.close();
    expect(t.w.bus.enabled).toBe(false); // written back when the agent shuts down
    expect(existsSync(t.state)).toBe(false);
  });

  it("SSE: eylem sonrası changed; kontrol bitince akış kapanır, yardımcı ölür, IsEnabled geri yazılır", async () => {
    const log = join(await mkdtemp(join(tmpdir(), "tiphys-ui-")), "log");
    const t = await uiApp(world(), { log });
    const h = await t.session();
    await t.app.listen({ port: 0, host: "127.0.0.1" });
    const base = `http://127.0.0.1:${(t.app.server.address() as AddressInfo).port}`;
    const unauth = await fetch(`${base}/v1/desktop/ui/events?address=0x55d1a0`, { headers: t.auth });
    expect(unauth.status).toBe(403);
    const gen = (await t.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: h })).json().gen;
    const res = await fetch(`${base}/v1/desktop/ui/events?address=0x55d1a0`, { headers: h });
    expect(res.headers.get("content-type")).toBe("text/event-stream");
    const reader = res.body!.getReader();
    let text = "";
    const readUntil = async (s: string) => {
      while (!text.includes(s)) {
        const { value, done } = await reader.read();
        if (done) break;
        text += new TextDecoder().decode(value);
      }
      return text.includes(s);
    };
    await t.app.inject({ method: "POST", url: "/v1/desktop/ui/act", headers: h, payload: { address: "0x55d1a0", gen, id: "0.0", action: "press" } });
    expect(await readUntil("event: changed")).toBe(true);
    expect(t.w.bus.enabled).toBe(true);
    await t.app.inject({ method: "DELETE", url: "/v1/desktop/control/session", headers: t.auth });
    expect(await readUntil("event: closed")).toBe(true);
    await until(() => !t.w.bus.enabled && !existsSync(t.state));
    // A request without a new session can't restart the helper.
    expect((await t.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: h })).statusCode).toBe(403);
    expect((await readFile(log, "utf8")).match(/^start/gm)).toHaveLength(1);
    await t.app.close();
  });

  it("boşta kalınca ve DELETE ile görünüm kapanır", async () => {
    const t = await uiApp(world(), { idleMs: 100 });
    const h = await t.session();
    await t.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: h });
    expect(t.w.bus.enabled).toBe(true);
    await until(() => !t.w.bus.enabled);
    await t.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: h });
    expect(t.w.bus.enabled).toBe(true);
    expect((await t.app.inject({ method: "DELETE", url: "/v1/desktop/ui", headers: t.auth })).json()).toEqual({ closed: true });
    expect(t.w.bus.enabled).toBe(false);
    expect((await t.app.inject({ method: "DELETE", url: "/v1/desktop/ui", headers: t.auth })).json()).toEqual({ closed: false });
    await t.app.close();
  });

  it("klavye yedeği yalnız odak doğrulanınca; gizli Firefox penceresi reddedilir", async () => {
    const t = await uiApp(world(), { mode: "unfocused" });
    const h = await t.session();
    const gen = (await t.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: h })).json().gen;
    const r = await t.app.inject({ method: "POST", url: "/v1/desktop/ui/text", headers: h, payload: { address: "0x55d1a0", gen, id: "4", text: "Çağrı" } });
    expect([r.statusCode, r.json().error.code]).toEqual([400, "agent.ui.noAction"]);
    expect(t.w.typed).toEqual([]);
    await t.app.close();

    for (const title of ["Giriş — Mozilla Firefox Private Browsing", "Mozilla Firefox Gizli Gezinti", "Giriş — Mozilla Firefox Gizli Gezinti"]) {
      const p = await uiApp(world({ clients: [client({ title })] }));
      const ph = await p.session();
      const g = await p.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: ph });
      expect([g.statusCode, g.json().error.code], title).toEqual([422, "agent.ui.unsupported"]);
      const ev = await p.app.inject({ method: "GET", url: "/v1/desktop/ui/events?address=0x55d1a0", headers: ph });
      expect(ev.json().error.code).toBe("agent.ui.unsupported");
      expect(p.w.calls.filter((c) => c.startsWith("busctl"))).toEqual([]); // the helper/IsEnabled were never turned on
      await p.app.close();
    }
  });

  it("anlık görüntü sürerken görünüm kapanırsa yeniden açılmaz; ikinci istemci IsEnabled açılışını bekler", async () => {
    let release = () => {};
    let gate: Promise<void> | null = null;
    const log = join(await mkdtemp(join(tmpdir(), "tiphys-ui-")), "log");
    const t = await uiApp(world({ clientsGate: () => gate ?? Promise.resolve() }), { log });
    const h = await t.session();
    gate = new Promise<void>((r) => (release = r));
    const pending = t.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: h });
    await new Promise((r) => setTimeout(r, 50));
    await t.app.inject({ method: "DELETE", url: "/v1/desktop/control/session", headers: t.auth }); // control ends
    gate = null;
    release();
    const r = await pending;
    expect(r.statusCode).toBe(409);
    expect(existsSync(log)).toBe(false); // the helper didn't start
    expect(t.w.bus.enabled).toBe(false);
    await t.app.close();

    const enabledAtSpawn: boolean[] = [];
    const w = world({ setDelayMs: 150 });
    const u = await uiApp(w, { onSpawn: () => enabledAtSpawn.push(w.bus.enabled) });
    const uh = await u.session();
    const [a, b] = await Promise.all([
      u.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: uh }),
      (async () => {
        await new Promise((r) => setTimeout(r, 20));
        return u.ctx.ui!.client("claude:x").snapshot("0x55d1a0");
      })(),
    ]);
    expect(a.statusCode).toBe(200);
    expect(b.nodes.length).toBeGreaterThan(0);
    expect(enabledAtSpawn).toEqual([true, true]);
    await u.app.close();
  });

  it("SSE: görünüm yokken kontrol bitince, belirteç yenilenince ve control kapanınca kapanır", async () => {
    const t = await uiApp(world(), { recheckMs: 50 });
    await t.app.listen({ port: 0, host: "127.0.0.1" });
    const base = `http://127.0.0.1:${(t.app.server.address() as AddressInfo).port}`;
    const open = async (h: Record<string, string>) => {
      const res = await fetch(`${base}/v1/desktop/ui/events?address=0x55d1a0`, { headers: h });
      expect(res.status).toBe(200);
      return res.text(); // ends when the stream closes
    };
    // 1) the view was never opened (no snapshot), control ends
    let h = await t.session();
    let body = open(h);
    await new Promise((r) => setTimeout(r, 50));
    await t.app.inject({ method: "DELETE", url: "/v1/desktop/control/session", headers: t.auth });
    expect(await body).toContain("event: closed");
    // 2) the same device renews its session (new token) → the stream with the old token closes
    h = await t.session();
    body = open(h);
    await new Promise((r) => setTimeout(r, 50));
    await t.session();
    expect(await body).toContain("event: closed");
    // 3) the "control" feature is turned off
    h = await t.session();
    body = open(h);
    await new Promise((r) => setTimeout(r, 50));
    await t.store.update((c) => ((c.features.control = false), c));
    expect(await body).toContain("event: closed");
    await t.app.close();
  });

  it("a11y veri yolu yoksa görünüm yine açılır", async () => {
    const t = await uiApp(world({ busFails: true }));
    const h = await t.session();
    expect((await t.app.inject({ method: "GET", url: "/v1/desktop/ui?address=0x55d1a0", headers: h })).statusCode).toBe(200);
    await t.app.close();
  });
});

const VSCODE_DESKTOP = `[Desktop Entry]
Name=Visual Studio Code
Exec=/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=code --file-forwarding com.visualstudio.code @@ %F @@
Icon=com.visualstudio.code
Actions=new-empty-window;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=/usr/bin/flatpak run --branch=stable --arch=x86_64 --command=code --file-forwarding com.visualstudio.code --new-window @@ %F @@
`;

describe("vscode-a11y", () => {
  it("bayrak her Exec satırına, uygulama kimliğinden sonra; bir kez", () => {
    const out = addA11yFlag(VSCODE_DESKTOP);
    expect(out).toContain(`com.visualstudio.code ${A11Y_FLAG} @@ %F @@`);
    expect(out).toContain(`com.visualstudio.code ${A11Y_FLAG} --new-window @@ %F @@`);
    expect(out).toContain("Icon=com.visualstudio.code\n");
    expect(out.split(A11Y_FLAG)).toHaveLength(3);
    expect(addA11yFlag(out.split("\n").slice(1).join("\n")).split(A11Y_FLAG)).toHaveLength(3);
    expect(() => addA11yFlag("[Desktop Entry]\nExec=code %F\n")).toThrow();
  });

  it("kur/kaldır (geçici XDG_DATA_HOME); elle yazılmış dosyaya dokunmaz; CLI", async () => {
    const home = await mkdtemp(join(tmpdir(), "tiphys-vscode-"));
    const data = join(home, "share");
    const env = { HOME: home, XDG_DATA_HOME: data };
    const p = vscodePaths(env);
    expect(p.target).toBe(join(data, "applications", "com.visualstudio.code.desktop"));
    await expect(vscodeA11y("install", { ...p, sources: [join(home, "yok.desktop")] })).rejects.toThrow(/bulunamadı/);
    await mkdir(dirname(p.sources[0]!), { recursive: true });
    await writeFile(p.sources[0]!, VSCODE_DESKTOP);

    // Node on this machine doesn't run .ts: the CLI is compiled into a temp folder (under agent/ so node_modules
    // resolves).
    const cache = join(HERE, "..", "node_modules", ".cache");
    await mkdir(cache, { recursive: true });
    const out = await mkdtemp(join(cache, "tiphys-cli-"));
    const tsc = spawnSync(join(HERE, "..", "node_modules", ".bin", "tsc"), ["-p", join(HERE, "..", "tsconfig.build.json"), "--outDir", out, "--sourceMap", "false"], { encoding: "utf8" });
    expect(tsc.status, tsc.stdout).toBe(0);
    await writeFile(join(out, "package.json"), '{"type":"module"}\n');
    const cli = (...args: string[]) => spawnSync(process.execPath, [join(out, "cli.js"), ...args], { env: { ...process.env, ...env }, encoding: "utf8" });
    const inst = cli("vscode-a11y", "install");
    expect(inst.status, inst.stderr).toBe(0);
    expect(await readFile(p.target, "utf8")).toContain(`com.visualstudio.code ${A11Y_FLAG} @@ %F @@`);
    expect(cli("vscode-a11y", "install").status).toBe(0); // reinstalling is safe
    expect(cli("vscode-a11y", "remove").stdout).toContain("kaldırıldı");
    expect(existsSync(p.target)).toBe(false);
    expect(cli("vscode-a11y", "remove").stdout).toContain("kurulu değil");
    expect(cli("vscode-a11y").status).not.toBe(0);

    await mkdir(dirname(p.target), { recursive: true });
    await writeFile(p.target, "[Desktop Entry]\nExec=kendi\n");
    await expect(vscodeA11y("install", p)).rejects.toThrow(/elle/);
    await expect(vscodeA11y("remove", p)).rejects.toThrow(/elle/);
    expect(await readFile(p.target, "utf8")).toBe("[Desktop Entry]\nExec=kendi\n");
    await rm(out, { recursive: true, force: true });
  }, 30_000);
});
