// Screen modes (PLAN.md §20 W1): config migration (gamemode → screen), feature/scope aliases, topic registry and
// layouts, the topic-subscribed feed, hot mode switches with the in-process `self` source, the scratch placement in
// classic and Lua Hyprland (keybind, rule, special workspace), visibility → pause/resume, crash recovery and the
// fallback to a 0.5 source. Fake exec, fake sockets; no real Hyprland, Firefox or Velour.
import { EventEmitter } from "node:events";
import { mkdir, mkdtemp, readFile, stat, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { agentConfigSchema, ConfigStore, defaultConfig, defaultLayout, migrateConfig } from "../src/config.ts";
import type { ExecResult } from "../src/exec.ts";
import type { EventSocket } from "../src/focus.ts";
import { displayRoutes, userJs, type DisplayIo, type Upstream } from "../src/screen/display.ts";
import { bindOffArgs, bindOnArgs, bindTaken, kioskWindow, moveToSpecialArgs, parseBind, ruleOnArgs, toggleSpecialArgs } from "../src/screen/placement.ts";
import type { StateProducer } from "../src/screen/producers/common.ts";
import { sourceRoutes, type FeedProducer, type Producers, type SourceIo } from "../src/screen/source.ts";
import { checkLayout, layoutTopics, parseTopics } from "../src/screen/topics.ts";
import { relevantEvent, visibleIn } from "../src/screen/visibility.ts";
import { createServiceToken } from "../src/service_tokens.ts";
import { testApp } from "./helpers.ts";

const cleanups: Array<() => unknown> = [];
afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
});

const until = async (f: () => boolean, ms = 3000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
};

// ---------------------------------------------------------------- migration

describe("config migration gamemode → screen", () => {
  const old = {
    version: 1, name: "x", listen: {},
    features: { system: true, gamemode: true },
    gamemode: { source: { url: "https://argo.example.com:7443", token: "tps_secret" }, display: { brightness: 40, scene: "drive" } },
  };

  it("moves the flag, the source and the display settings; idempotent; never writes the old keys", () => {
    const m = migrateConfig(old);
    expect(m.changed).toBe(true);
    const c = agentConfigSchema.parse(m.raw);
    expect(c.features.screen).toBe(true);
    expect("gamemode" in c.features).toBe(false);
    expect("gamemode" in c).toBe(false);
    expect(c.screen.sources).toEqual({ main: { url: "https://argo.example.com:7443", token: "tps_secret" } });
    expect(c.screen.modes.game).toMatchObject({ brightness: 40, scene: "drive", lyrics: true });
    // The game cards read "main", as Game mode did; the other modes read this host.
    expect(c.screen.modes.game.layout.cards.every((x) => x.source === "main")).toBe(true);
    expect(c.screen.modes.work.layout.cards.every((x) => x.source === "self")).toBe(true);
    expect(c.screen.lastMode).toBe("game");
    // Again: nothing to do, same result.
    const again = migrateConfig(JSON.parse(JSON.stringify(c)));
    expect(again.changed).toBe(false);
    expect(agentConfigSchema.parse(again.raw)).toEqual(c);
  });

  it("flag off stays off; values already under screen win; no source → game cards stay on self", () => {
    const off = agentConfigSchema.parse(migrateConfig({ ...old, features: { gamemode: false }, gamemode: { source: null, display: {} } }).raw);
    expect(off.features.screen).toBe(false);
    expect(off.screen.sources).toEqual({});
    expect(off.screen.modes.game.layout).toEqual(defaultLayout("game"));
    const both = agentConfigSchema.parse(migrateConfig({ ...old, features: { gamemode: true, screen: false }, screen: { placement: "scratch" } }).raw);
    expect(both.features.screen).toBe(false);
    expect(both.screen.placement).toBe("scratch");
    expect(both.screen.sources).toEqual({});
    expect(migrateConfig(null)).toEqual({ raw: null, changed: false });
  });

  it("ConfigStore.load writes the migrated file at once", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-screen-cfg-"));
    const path = join(dir, "agent.json");
    await writeFile(path, JSON.stringify(old));
    const store = await ConfigStore.load(path);
    expect(store.get().features.screen).toBe(true);
    const file = JSON.parse(await readFile(path, "utf8"));
    expect(file.gamemode).toBeUndefined();
    expect(file.features.gamemode).toBeUndefined();
    expect(file.screen.sources.main.url).toBe("https://argo.example.com:7443");
    expect((await stat(path)).mode & 0o777).toBe(0o600);
  });

  it("health and /v1/config report features.gamemode for one release; PATCH gamemode sets screen", async () => {
    const t = await testApp();
    cleanups.push(() => t.app.close());
    expect((await t.app.inject({ url: "/v1/health" })).json().features).toMatchObject({ screen: false, gamemode: false });
    const r = await t.app.inject({ method: "PATCH", url: "/v1/config", headers: t.auth, payload: { features: { gamemode: true } } });
    expect(r.json().config.features).toMatchObject({ screen: true, gamemode: true });
    expect(t.store.get().features.screen).toBe(true);
    expect("gamemode" in t.store.get().features).toBe(false);
  });
});

// ---------------------------------------------------------------- topics, layouts, placement commands

describe("topics and layouts", () => {
  it("only enabled, drawn cards subscribe; spectrum follows the game setting; paused drops it", () => {
    const c = defaultConfig("x").screen.modes;
    const { layout: gl, ...gs } = c.game;
    expect([...layoutTopics("game", gl, gs).get("self")!]).toEqual(["truck", "music", "spectrum"]);
    expect([...layoutTopics("game", gl, { ...gs, spectrum: false }).get("self")!]).toEqual(["truck", "music"]);
    expect([...layoutTopics("game", gl, gs, true).get("self")!]).toEqual(["truck", "music"]);
    const off = { ...gl, cards: gl.cards.map((x) => ({ ...x, enabled: x.kind === "lyrics" })) };
    expect([...layoutTopics("game", off, gs).get("self")!]).toEqual(["music"]);
    const split = { ...gl, cards: gl.cards.map((x) => ({ ...x, source: x.kind === "map" ? "argo" : "self" })) };
    expect([...layoutTopics("game", split, gs).entries()].map(([k, v]) => [k, [...v]])).toEqual([["argo", ["truck"]], ["self", ["truck", "music", "spectrum"]]]);
    // Work (W2, W3): the topics of its cards; hidden → no system gauge (the city keeps its state).
    const { layout: wl, ...ws } = c.work;
    expect([...layoutTopics("work", wl, ws).get("self")!]).toEqual(["city", "system", "jobs", "git", "music", "servers"]);
    expect([...layoutTopics("work", wl, ws, true).get("self")!]).toEqual(["city", "jobs", "git", "music", "servers"]);
  });

  it("checkLayout and parseTopics", () => {
    expect(() => checkLayout("work", defaultLayout("work"))).not.toThrow();
    expect(() => checkLayout("work", { template: "game", cards: [] })).toThrow(/badLayout/);
    expect(() => checkLayout("work", { template: "work", cards: [{ kind: "map", source: "self", enabled: true }] })).toThrow(/badLayout/);
    expect(() => checkLayout("focus", { template: "focus", cards: [{ kind: "day", source: "self", enabled: true }, { kind: "day", source: "self", enabled: true }] })).toThrow(/badLayout/);
    expect(parseTopics(["music", "nope", "music", 3], ["music", "truck"])).toEqual(["music"]);
    expect(parseTopics("music", ["music"])).toBeNull();
  });

  it("placement commands: classic and Lua, fixed constants only", () => {
    expect(parseBind("SUPER SHIFT,grave")).toEqual({ mods: ["SUPER", "SHIFT"], key: "grave", mask: 65 });
    expect(() => parseBind("SUPER,grave,exec,rm -rf ~")).toThrow();
    expect(() => parseBind('SUPER,a") hl.exec("x')).toThrow();
    expect(bindOnArgs("legacy", "SUPER,grave")).toEqual(["keyword", "bind", "SUPER,grave,togglespecialworkspace,tiphys"]);
    expect(bindOffArgs("legacy", "SUPER_ALT,F12")).toEqual(["keyword", "unbind", "SUPER ALT,F12"]);
    expect(bindOnArgs("lua", "SUPER,grave")).toEqual(["eval", 'hl.bind("SUPER + grave", hl.dsp.workspace.toggle_special("tiphys"), { description = "Tiphys" })']);
    expect(bindOffArgs("lua", "SUPER,grave")).toEqual(["eval", 'hl.unbind("SUPER + grave")']);
    expect(toggleSpecialArgs("legacy")).toEqual(["dispatch", "togglespecialworkspace", "tiphys"]);
    expect(moveToSpecialArgs("legacy", "0xabc")).toEqual(["dispatch", "movetoworkspacesilent", "special:tiphys,address:0xabc"]);
    expect(() => moveToSpecialArgs("lua", "0xabc; x")).toThrow();
    expect(ruleOnArgs("legacy", "scratch", "tiphys")).toContainEqual(["keyword", "windowrule[tiphys-screen]:workspace", "special:tiphys silent"]);
    expect(ruleOnArgs("lua", "fullscreen", "is")[0]![1]).toContain('workspace = "name:is"');
    const binds = JSON.stringify([{ modmask: 64, key: "S", submap: "" }, { modmask: 64, key: "GRAVE", submap: "resize" }]);
    expect(bindTaken(binds, "SUPER,s")).toBe(true);
    expect(bindTaken(binds, "SUPER,grave")).toBe(false); // only inside a submap
    expect(bindTaken(binds, "SUPER SHIFT,s")).toBe(false);
    expect(kioskWindow(JSON.stringify([{ address: "0x1", class: "kitty" }, { address: "0x2f", class: "tiphys-screen", workspace: { name: "special:tiphys" } }]))).toEqual({ address: "0x2f", workspace: "special:tiphys" });
  });

  it("visibility from hyprctl monitors", () => {
    const mon = (active: string, special: string, dpms = true) => JSON.stringify([{ activeWorkspace: { name: active }, specialWorkspace: { name: special }, dpmsStatus: dpms }]);
    expect(visibleIn(mon("3", "special:tiphys"), { placement: "scratch" })).toBe(true);
    expect(visibleIn(mon("3", ""), { placement: "scratch" })).toBe(false);
    expect(visibleIn(mon("3", "special:tiphys", false), { placement: "scratch" })).toBe(false);
    expect(visibleIn(mon("is", ""), { placement: "fullscreen", workspace: "is" })).toBe(true);
    expect(visibleIn(mon("is", "special:magic"), { placement: "fullscreen", workspace: "is" })).toBe(false);
    expect(visibleIn("nope", { placement: "scratch" })).toBeNull();
    expect(relevantEvent("activespecial>>special:tiphys,eDP-1")).toBe(true);
    expect(relevantEvent("openwindow>>abc,1,kitty,x")).toBe(false);
  });

  it("light Firefox profile prefs", () => {
    const js = userJs();
    for (const p of ['"dom.ipc.processCount", 1', '"fission.autostart", false', '"dom.ipc.processPrelaunch.enabled", false', '"browser.cache.disk.enable", false', '"browser.cache.memory.capacity", 32768', '"network.prefetch-next", false', '"app.update.auto", false']) {
      expect(js).toContain(`user_pref(${p});`);
    }
  });
});

// ---------------------------------------------------------------- fakes

interface Call {
  cmd: string;
  args: string[];
}

class FakeEvents extends EventEmitter implements EventSocket {
  destroyed = false;
  destroy() {
    this.destroyed = true;
  }
}

class FakeUpstream implements Upstream {
  readyState = 0;
  binaryType = "blob";
  onopen: (() => void) | null = null;
  onmessage: ((ev: { data: unknown }) => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  sent: string[] = [];
  closed = false;
  readonly url: string;
  constructor(url: string) {
    this.url = url;
  }
  send(d: string) {
    this.sent.push(d);
  }
  close() {
    this.closed = true;
    this.readyState = 3;
  }
  open() {
    this.readyState = 1;
    this.onopen?.();
  }
}

/** A state producer that sends one `{type: topic}` message on start (Work mode topics without /proc, git or Kuma). */
class FakeState implements StateProducer {
  active = false;
  readonly topic: string;
  constructor(topic: string) {
    this.topic = topic;
  }
  start(emit: (m: Record<string, unknown>) => void) {
    this.active = true;
    emit({ type: this.topic, fake: true });
  }
  async stop() {
    this.active = false;
  }
}

function fakeProducers(): Producers {
  return {
    make: { system: () => new FakeState("system"), jobs: () => new FakeState("jobs"), servers: () => new FakeState("servers") },
    git: {
      io: { run: async () => ({ stdout: "", code: 128 }), watch: () => ({ close() {} }), read: async () => null, list: async () => [], has: () => false },
      selector: (onChange) => {
        const sel = { root: null, known: false, active: false, start: () => ((sel.active = sel.known = true), onChange(null)), stop: () => (sel.active = false) };
        return sel;
      },
      resolve: async () => ({ none: "notRepo" }),
    },
  };
}

function velourIdle() {
  // State once, then wait until aborted (a quiet Velour).
  return async (op: { op: string }, signal?: AbortSignal) => {
    if (op.op !== "wait") return { rev: 1, playing: false, track: null };
    await new Promise<void>((r) => signal?.addEventListener("abort", () => r(), { once: true }));
    return {};
  };
}

async function screenApp(o: { lua?: boolean; placement?: "fullscreen" | "scratch"; bindsTaken?: boolean; sources?: Record<string, { url: string; token: string }> } = {}) {
  const runtime = await mkdtemp(join(tmpdir(), "tiphys-screen-run-"));
  const calls: Call[] = [];
  let special = ""; // shown special workspace
  let active = "3";
  const exec = async (cmd: string, args: string[]): Promise<ExecResult> => {
    calls.push({ cmd, args });
    const ok = (stdout = "") => ({ stdout, stderr: "", code: 0 });
    if (cmd === "hyprctl") {
      const a = args.join(" ");
      if (a === "eval return 1") return o.lua ? ok("ok") : ok("eval is only supported with the lua config manager");
      if (a === "-j binds") return ok(JSON.stringify(o.bindsTaken ? [{ modmask: 64, key: "grave", submap: "" }] : [{ modmask: 64, key: "Q", submap: "" }]));
      if (a === "-j monitors") return ok(JSON.stringify([{ activeWorkspace: { name: active }, specialWorkspace: { name: special }, dpmsStatus: true }]));
      if (a === "-j activeworkspace") return ok(JSON.stringify({ id: active === "3" ? 3 : -1337, name: active }));
      if (a === "-j clients") return ok(JSON.stringify([{ address: "0xbeef", class: "tiphys-screen", workspace: { name: "3" } }]));
      if (/^dispatch togglespecialworkspace|^eval hl\.dispatch\(hl\.dsp\.workspace\.toggle_special/.test(a)) special = special ? "" : "special:tiphys";
      if (/^dispatch workspace name:|hl\.dsp\.focus/.test(a)) active = a.includes("name:is") ? "is" : a.includes("name:yol") ? "yol" : "odak";
      return ok("ok");
    }
    if (cmd === "systemctl" && args[1] === "is-active") return ok("active\n");
    return ok("");
  };
  const ups: FakeUpstream[] = [];
  const events: FakeEvents[] = [];
  const io: DisplayIo = {
    exec,
    runtimeDir: runtime,
    hyprEnv: async () => ({ XDG_RUNTIME_DIR: runtime, HYPRLAND_INSTANCE_SIGNATURE: "sig" }),
    waylandEnv: async () => ({ WAYLAND_DISPLAY: "wayland-1", XDG_RUNTIME_DIR: runtime }),
    busEnv: () => ({}),
    which: (c) => c !== "brightnessctl",
    connect: (url) => (ups.push(new FakeUpstream(url)), ups.at(-1)!),
    fetch,
    hyprEvents: () => (events.push(new FakeEvents()), events.at(-1)!),
  };
  const sio: SourceIo = {
    velour: velourIdle() as SourceIo["velour"],
    exec,
    spawn: () => {
      throw new Error("no spectrum in these tests");
    },
    telemetry: async () => ({ running: false, buf: null }),
  };
  let feed!: FeedProducer;
  const t = await testApp(
    (c) => {
      c.screen.placement = o.placement ?? "fullscreen";
      c.screen.sources = o.sources ?? {};
      return c;
    },
    [
      async (a, ctx) => {
        feed = sourceRoutes(a, ctx, { io: sio, idleMs: 30, heartbeatMs: 40, producers: fakeProducers() });
        await displayRoutes(a, ctx, { io, feed, displayDir: null, mapDir: runtime, backoff: [0.02], watchMs: 60_000, visibility: { debounceMs: 5 } });
      },
    ],
  );
  cleanups.push(() => t.app.close());
  await t.app.ready();
  const req = (method: "GET" | "PUT" | "POST", url: string, payload?: object) => t.app.inject({ method, url, headers: t.auth, ...(payload ? { payload } : {}) });
  const hypr = () => calls.filter((c) => c.cmd === "hyprctl").map((c) => c.args.join(" "));
  const page = async () => {
    const html = await readFile(join(runtime, "tiphys-screen", "start.html"), "utf8");
    const token = /#t=([a-f0-9]{64})/.exec(html)![1]!;
    const got: string[] = [];
    const ws = await t.app.injectWS(`/v1/screen/live?t=${token}`, {}, { onInit: (w) => w.on("message", (d: Buffer, bin: boolean) => got.push(bin ? `bin:${d.length}` : d.toString())) });
    return { ws, got, msgs: () => got.filter((g) => !g.startsWith("bin:")).map((g) => JSON.parse(g) as Record<string, unknown>) };
  };
  return { ...t, runtime, calls, hypr, ups, events, req, page, feed: () => feed, setActive: (w: string) => (active = w), setSpecial: (s: string) => (special = s) };
}

// ---------------------------------------------------------------- feed

describe("screen feed", () => {
  it("subscribe replaces the topic set; loops start and stop per topic; gamemode tokens get the game topics only", async () => {
    const t = await screenApp();
    const feed = t.feed();
    const { token: screenTok } = await createServiceToken(t.store, "laptop", ["screen"]);
    const { token: gmTok } = await createServiceToken(t.store, "old", ["gamemode"]);
    const { token: research } = await createServiceToken(t.store, "r", ["research"]);
    await expect(t.app.injectWS("/v1/screen/feed", { headers: { authorization: `Bearer ${research}` } })).rejects.toThrow(/403/);
    const got: string[] = [];
    const ws = await t.app.injectWS("/v1/screen/feed", { headers: { authorization: `Bearer ${screenTok}` } }, { onInit: (w) => w.on("message", (d: Buffer) => got.push(d.toString())) });
    await until(() => got.includes('{"type":"hb"}'));
    expect(feed.running).toBe(false); // no topics yet: nothing runs
    ws.send(JSON.stringify({ type: "subscribe", topics: ["truck", "bogus"] }));
    await until(() => got.some((m) => m.includes('"type":"truck"')));
    expect(feed.producing).toEqual(["truck"]);
    ws.send(JSON.stringify({ type: "subscribe", topics: ["music"] }));
    await until(() => feed.producing.join() === "music");
    ws.send(JSON.stringify({ type: "subscribe", topics: [] }));
    await until(() => !feed.running);
    ws.terminate();
    await until(() => feed.subscribers === 0);
    // The older scope: only music/spectrum/truck, also on the new feed (W2 topics would be dropped).
    const gm = await t.app.injectWS("/v1/screen/feed", { headers: { authorization: `Bearer ${gmTok}` } });
    gm.send(JSON.stringify({ type: "subscribe", topics: ["truck"] }));
    await until(() => feed.producing.join() === "truck");
    gm.terminate();
    await until(() => !feed.running);
  });
});

// ---------------------------------------------------------------- display

describe("screen display", () => {
  it("start work → hot switch to game (self source subscribed in-process) → back → stop; events carry the mode", async () => {
    const t = await screenApp();
    const feed = t.feed();
    const s = await t.req("POST", "/v1/screen/start", { mode: "work" });
    expect(s.statusCode).toBe(200);
    expect(s.json()).toMatchObject({ running: true, mode: "work", placement: "fullscreen", sources: [{ name: "self", state: "ok", topics: ["city", "git", "jobs", "music", "servers", "system"] }] });
    expect(t.hypr()).toContain("keyword windowrule[tiphys-screen]:workspace name:is");
    expect(t.hypr()).toContain("dispatch workspace name:is");
    await until(() => ["system", "jobs", "servers", "git"].every((x) => feed.producing.includes(x as never)));
    const p = await t.page();
    await until(() => p.msgs().some((m) => m.type === "layout"));
    expect(p.msgs()[0]).toMatchObject({ type: "layout", mode: "work", template: "work", settings: { clock24: true, project: "auto" } });
    // The producers' state, sent before the page connected, is replayed to it tagged "self"; no project → git says so.
    await until(() => ["system", "jobs", "servers"].every((x) => p.msgs().some((m) => m.type === x && m.src === "self")));
    await until(() => p.msgs().some((m) => m.type === "git" && m.none === "noProject"));

    const runs = t.calls.filter((c) => c.cmd === "systemd-run").length;
    const sw = await t.req("POST", "/v1/screen/mode", { mode: "game" });
    expect(sw.json()).toMatchObject({ running: true, mode: "game", sources: [{ name: "self", state: "ok", topics: ["music", "spectrum", "truck"] }] });
    await until(() => p.msgs().some((m) => m.type === "layout" && m.mode === "game"));
    await until(() => feed.producing.includes("truck") && feed.producing.includes("music"));
    // Relayed from the in-process source, tagged "self".
    await until(() => p.msgs().some((m) => m.type === "truck" && m.src === "self"));
    expect(t.calls.filter((c) => c.cmd === "systemd-run").length).toBe(runs); // Firefox not restarted
    expect(t.store.get().screen.lastMode).toBe("game");

    // Focus (W2): Day and Music cards; the timer is W5.
    await t.req("POST", "/v1/screen/mode", { mode: "focus" });
    await until(() => feed.producing.join() === "music");
    expect((await t.req("POST", "/v1/screen/start", { mode: "focus" })).json().mode).toBe("focus"); // idempotent
    const stopped = await t.req("POST", "/v1/screen/stop");
    expect(stopped.json()).toMatchObject({ running: false, mode: null });
    await until(() => !feed.running);
    expect(await stat(join(t.runtime, "tiphys-screen")).catch(() => null)).toBeNull();
    // Still on "is" (the start mode's workspace): the previous one comes back.
    expect(t.hypr()).toContain("dispatch workspace 3");
    expect(t.hypr()).toContain("keyword windowrule[tiphys-screen]:enable false");
    const events = await readFile(join(t.dir, "events.jsonl"), "utf8");
    const keys = events.trim().split("\n").map((l) => JSON.parse(l) as { key: string; params: Record<string, string> });
    expect(keys.map((e) => [e.key, e.params.mode ?? null])).toEqual([["screen.started", "work"], ["screen.stopped", null]]);
  });

  it("noSource for a layout naming a missing source; badLayout; sources are write-only", async () => {
    const t = await screenApp();
    const bad = await t.req("PUT", "/v1/screen", { settings: { modes: { work: { layout: { template: "work", cards: [{ kind: "map", source: "self", enabled: true }] } } } } });
    expect([bad.statusCode, bad.json().error.code]).toEqual([400, "agent.screen.badLayout"]);
    expect((await t.req("PUT", "/v1/screen", { sources: { self: { url: "https://a.example.com", token: "tps_x" } } })).statusCode).toBe(400);
    const cards = defaultLayout("game", "argo").cards;
    await t.req("PUT", "/v1/screen", { settings: { modes: { game: { layout: { template: "game", cards } } } } });
    const r = await t.req("POST", "/v1/screen/start", { mode: "game" });
    expect([r.statusCode, r.json().error.code, r.json().error.params.sources]).toEqual([409, "agent.screen.noSource", ["argo"]]);
    const put = await t.req("PUT", "/v1/screen", { sources: { argo: { url: "https://argo.example.com:7443", token: "tps_secretsecret" } } });
    expect(put.body).not.toContain("tps_secretsecret");
    expect(put.json().sources).toContainEqual({ name: "argo", url: "https://argo.example.com:7443", state: "off", topics: [] });
    expect((await t.req("POST", "/v1/screen/start", { mode: "game" })).statusCode).toBe(200);
    expect(t.ups[0]!.url).toBe("wss://argo.example.com:7443/v1/screen/feed");
    await t.req("PUT", "/v1/screen", { sources: { argo: null } });
    expect(t.ups[0]!.closed).toBe(true);
    await t.req("POST", "/v1/screen/stop");
  });

  it("work: the git card's source gets the project and CI setting; a change resubscribes; relative paths refused", async () => {
    const t = await screenApp({ sources: { argo: { url: "https://argo.example.com:7443", token: "tps_x" } } });
    const cards = defaultLayout("work").cards.map((c) => ({ ...c, source: c.kind === "git" ? "argo" : "self" }));
    const put = await t.req("PUT", "/v1/screen", { settings: { modes: { work: { layout: { template: "work", cards }, project: { path: "/home/u/p" } } } } });
    expect(put.statusCode).toBe(200);
    await t.req("POST", "/v1/screen/start", { mode: "work" });
    t.ups[0]!.open();
    expect(JSON.parse(t.ups[0]!.sent[0]!)).toEqual({ type: "subscribe", topics: ["git"], project: "/home/u/p", ci: false });
    await t.req("PUT", "/v1/screen", { settings: { modes: { work: { ci: true } } } });
    expect(JSON.parse(t.ups[0]!.sent.at(-1)!)).toEqual({ type: "subscribe", topics: ["git"], project: "/home/u/p", ci: true });
    expect(t.feed().producing).not.toContain("git"); // this host's feed: no git subscriber
    const bad = await t.req("PUT", "/v1/screen", { settings: { modes: { work: { project: { path: "relative/p" } } } } });
    expect(bad.statusCode).toBe(400);
    await t.req("POST", "/v1/screen/stop");
  });

  it("work: the city card's source gets the project; patches are folded into the replayed city; a big snapshot passes", async () => {
    const t = await screenApp({ sources: { argo: { url: "https://argo.example.com:7443", token: "tps_x" } } });
    const cards = defaultLayout("work").cards.map((c) => ({ ...c, source: c.kind === "city" ? "argo" : "self" }));
    await t.req("PUT", "/v1/screen", { settings: { modes: { work: { layout: { template: "work", cards }, project: { path: "/home/u/p" } } } } });
    await t.req("POST", "/v1/screen/start", { mode: "work" });
    const up = t.ups[0]!;
    up.open();
    expect(JSON.parse(up.sent[0]!)).toEqual({ type: "subscribe", topics: ["city"], project: "/home/u/p", ci: false });
    const p = await t.page();
    // ~1.6 MB: over the 1 MB limit of other messages.
    const files = Array.from({ length: 20_000 }, (_, i) => [`packages/module-${i % 50}/src/some/deeper/folder/file-${i}.ts`, i % 300, "code"]);
    up.onmessage!({ data: JSON.stringify({ type: "city", root: "p", files, truncated: false, masked: false }) });
    up.onmessage!({ data: JSON.stringify({ type: "cityPatch", upsert: [["new.ts", 3, "code"], [files[0]![0], 999, "code"]], remove: [files[1]![0]] }) });
    up.onmessage!({ data: JSON.stringify({ type: "touch", path: "new.ts", kind: "create", by: null }) });
    await until(() => p.msgs().some((m) => m.type === "touch" && m.src === "argo"));
    expect(p.msgs().find((m) => m.type === "city")).toMatchObject({ src: "argo", root: "p" });
    // A second page gets the city with the patch in it (and no stale touch).
    const q = await t.page();
    await until(() => q.msgs().some((m) => m.type === "city"));
    const c = q.msgs().find((m) => m.type === "city")!;
    const got = new Map((c.files as Array<[string, number]>).map((f) => [f[0], f[1]]));
    expect(got.size).toBe(20_000);
    expect(got.get("new.ts")).toBe(3);
    expect(got.get(files[0]![0] as string)).toBe(999);
    expect(got.has(files[1]![0] as string)).toBe(false);
    expect(q.msgs().some((m) => m.type === "touch" || m.type === "cityPatch")).toBe(false);
    await t.req("POST", "/v1/screen/stop");
  });

  it("a source that never opens /v1/screen/feed is tried on the 0.5 feed next", async () => {
    const t = await screenApp({ sources: { main: { url: "https://argo.example.com:7443", token: "tps_x" } } });
    await t.req("PUT", "/v1/screen", { settings: { modes: { game: { layout: defaultLayout("game", "main") } } } });
    await t.req("POST", "/v1/screen/start", { mode: "game" });
    t.ups[0]!.onclose!(); // 404 on the upgrade
    await until(() => t.ups.length === 2);
    expect(t.ups[1]!.url).toBe("wss://argo.example.com:7443/v1/gamemode/feed");
    t.ups[1]!.open();
    expect(t.ups[1]!.sent).toEqual([]); // the 0.5 feed takes no subscribe
    const p = await t.page();
    t.ups[1]!.onmessage!({ data: JSON.stringify({ type: "truck", state: "none", reason: "noGame", at: 1 }) });
    await until(() => p.msgs().some((m) => m.type === "truck" && m.src === "main"));
    await t.req("POST", "/v1/screen/stop");
  });

  for (const lua of [false, true]) {
    it(`scratch placement (${lua ? "Lua" : "classic"}): keybind + rule, shown once, pause/resume from Hyprland events, all undone`, async () => {
      const t = await screenApp({ lua, placement: "scratch" });
      const feed = t.feed();
      const s = await t.req("POST", "/v1/screen/start", { mode: "game" });
      expect(s.json()).toMatchObject({ running: true, placement: "scratch" });
      const h = t.hypr();
      if (lua) {
        expect(h).toContain('eval hl.bind("SUPER + grave", hl.dsp.workspace.toggle_special("tiphys"), { description = "Tiphys" })');
        expect(h.some((x) => x.includes('workspace = "special:tiphys silent"') && x.includes("enabled = true"))).toBe(true);
      } else {
        expect(h).toContain("keyword bind SUPER,grave,togglespecialworkspace,tiphys");
        expect(h).toContain("keyword windowrule[tiphys-screen]:workspace special:tiphys silent");
      }
      expect(h.some((x) => x.startsWith("dispatch workspace") || x.includes("hl.dsp.focus"))).toBe(false); // no workspace switch
      const state = JSON.parse(await readFile(join(t.runtime, "tiphys-screen", "state.json"), "utf8"));
      expect(state).toMatchObject({ placement: "scratch", bind: "SUPER,grave", rules: true, hypr: lua ? "lua" : "legacy" });
      // Hidden at start: paused, spectrum not subscribed.
      await until(() => t.events.length === 1);
      await until(() => (feed.producing.includes("truck")));
      let visible: unknown = null;
      for (let i = 0; i < 100 && visible !== false; i++) {
        visible = (await t.req("GET", "/v1/screen")).json().visible;
        await new Promise((r) => setTimeout(r, 10));
      }
      expect(visible).toBe(false);
      const p = await t.page();
      await until(() => p.msgs().some((m) => m.type === "pause"));
      // First page: the window is moved into special:tiphys and the workspace shown once.
      await until(() => t.hypr().some((x) => /togglespecialworkspace tiphys|toggle_special\("tiphys"\)\)$/.test(x)));
      expect(t.hypr().some((x) => x.includes("special:tiphys,address:0xbeef") || x.includes('window = "address:0xbeef", workspace = "special:tiphys"'))).toBe(true);
      t.events[0]!.emit("connect");
      t.events[0]!.emit("data", Buffer.from("activespecial>>special:tiphys,eDP-1\n"));
      await until(() => p.msgs().some((m) => m.type === "resume"));
      expect((await t.req("GET", "/v1/screen")).json().visible).toBe(true);
      // Hidden with the keybind: pause.
      t.setSpecial("");
      t.events[0]!.emit("data", Buffer.from("activespecialv2>>,,eDP-1\n"));
      const lastOf = (type: string) => p.msgs().map((m) => m.type).lastIndexOf(type);
      await until(() => lastOf("pause") > lastOf("resume"));
      expect((await t.req("GET", "/v1/screen")).json().sources[0].topics).toEqual(["music", "truck"]);
      await t.req("POST", "/v1/screen/stop");
      const after = t.hypr();
      expect(after).toContain(lua ? 'eval hl.unbind("SUPER + grave")' : "keyword unbind SUPER,grave");
      expect(after.some((x) => x.includes("tiphys-screen") && (x.includes("enabled = false") || x.endsWith(":enable false")))).toBe(true);
      expect(t.events[0]!.destroyed).toBe(true);
      expect(feed.running).toBe(false);
    });
  }

  it("scratch: a bind already in use is refused and nothing is left", async () => {
    const t = await screenApp({ placement: "scratch", bindsTaken: true });
    const r = await t.req("POST", "/v1/screen/start", { mode: "work" });
    expect([r.statusCode, r.json().error.code, r.json().error.params.bind]).toEqual([409, "agent.screen.bindTaken", "SUPER,grave"]);
    expect(t.hypr().some((x) => x.startsWith("keyword bind") || x.includes("windowrule"))).toBe(false);
    expect(t.calls.some((c) => c.cmd === "systemd-run")).toBe(false);
    expect(await stat(join(t.runtime, "tiphys-screen")).catch(() => null)).toBeNull();
  });

  it("crash recovery: the scratch keybind and rule of a dead agent are undone at start", async () => {
    const runtime = await mkdtemp(join(tmpdir(), "tiphys-screen-run-"));
    const work = join(runtime, "tiphys-screen");
    await mkdir(join(work, "profile"), { recursive: true });
    await writeFile(join(work, "state.json"), JSON.stringify({ startedAt: "x", mode: "work", hypr: "legacy", placement: "scratch", ws: "tiphys", rules: true, bind: "SUPER,grave,exec,evil", workspace: null, brightness: null }));
    const calls: string[] = [];
    const io: DisplayIo = {
      exec: async (cmd, args) => (calls.push(`${cmd} ${args.join(" ")}`), { stdout: "ok", stderr: "", code: 0 }),
      runtimeDir: runtime, hyprEnv: async () => ({ HYPRLAND_INSTANCE_SIGNATURE: "sig" }), waylandEnv: async () => ({}),
      busEnv: () => ({}), which: () => true, connect: (u) => new FakeUpstream(u), fetch,
    };
    const t = await testApp((c) => c, [async (a, ctx) => void (await displayRoutes(a, ctx, { io, displayDir: null, mapDir: runtime }))]);
    cleanups.push(() => t.app.close());
    await until(() => calls.includes("hyprctl keyword windowrule[tiphys-screen]:enable false"));
    expect(calls).toContain("systemctl --user stop tiphys-screen.service");
    // An invalid saved bind is never passed on.
    expect(calls.some((c) => c.includes("unbind"))).toBe(false);
    expect(await stat(work).catch(() => null)).toBeNull();

    await mkdir(work, { recursive: true });
    await writeFile(join(work, "state.json"), JSON.stringify({ startedAt: "x", mode: "game", hypr: "legacy", placement: "scratch", ws: "tiphys", rules: true, bind: "SUPER,grave", workspace: null, brightness: null }));
    const t2 = await testApp((c) => c, [async (a, ctx) => void (await displayRoutes(a, ctx, { io, displayDir: null, mapDir: runtime }))]);
    cleanups.push(() => t2.app.close());
    await until(() => calls.includes("hyprctl keyword unbind SUPER,grave"));
  });
});
