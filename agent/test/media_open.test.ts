// 9.8 media control (with fake playerctl/wpctl; the real PC's audio/player is never touched) and
// 9.9 "Open on PC" (with a fake opener; no real browser is opened).
import { mkdtemp, readFile, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { describe, expect, it } from "vitest";
import { checkOpenUrl, openRoutes } from "../src/routes/desktop.ts";
import { METADATA_FORMAT, imageType, mediaRoutes, parseMetadata, parseOutputs, parsePlayerList, parseVolume, pickPlayer, type Exec } from "../src/routes/media.ts";
import { testApp } from "./helpers.ts";

const US = "\u001f";
const RS = "\u001e";
/** Like playerctl's --format output: the format + a newline for each player. */
const rec = (...f: string[]) => f.join(US) + RS + "\n";

/** pw-dump output: two sinks (the second is the default), a source and the "default" metadata. */
function pwDump(defaultSink = "bluez_output.AA") {
  const node = (id: number, cls: string, name: string, description?: string) => ({
    id,
    type: "PipeWire:Interface:Node",
    info: { props: { "media.class": cls, "node.name": name, ...(description ? { "node.description": description } : {}) } },
  });
  return JSON.stringify([
    { id: 0, type: "PipeWire:Interface:Core", info: {} },
    node(57, "Audio/Sink", "alsa_output.pci-0000_2b_00.3.analog-stereo", "Built-in Audio Analog Stereo"),
    node(81, "Audio/Sink", "bluez_output.AA", "WH-1000XM4"),
    node(60, "Audio/Source", "alsa_input.pci", "Mic"),
    node(90, "Audio/Sink", "nameless"),
    {
      id: 40,
      type: "PipeWire:Interface:Metadata",
      props: { "metadata.name": "default" },
      metadata: [
        { subject: 0, key: "default.audio.sink", type: "Spa:String:JSON", value: { name: defaultSink } },
        { subject: 0, key: "default.audio.source", type: "Spa:String:JSON", value: { name: "alsa_input.pci" } },
      ],
    },
  ]);
}

function fakeExec(o: { list?: string; meta?: string; volume?: string; failAction?: boolean } = {}) {
  const calls: Array<{ cmd: string; args: string[]; env?: NodeJS.ProcessEnv }> = [];
  let vol = o.volume ?? "Volume: 0.60\n";
  let sink = "bluez_output.AA";
  const exec: Exec = async (cmd, args, opts) => {
    calls.push({ cmd, args, env: opts.env });
    if (cmd === "pw-dump") return { stdout: pwDump(sink), stderr: "", code: 0 };
    if (cmd === "wpctl" && args[0] === "set-default") {
      sink = args[1] === "57" ? "alsa_output.pci-0000_2b_00.3.analog-stereo" : sink;
      return { stdout: "", stderr: "", code: 0 };
    }
    if (cmd === "playerctl" && args[0] === "-l") return o.list === undefined ? { stdout: "", stderr: "No players found\n", code: 1 } : { stdout: o.list, stderr: "", code: 0 };
    if (cmd === "playerctl" && args[1] === "metadata") return { stdout: o.meta ?? "", stderr: "", code: 0 };
    if (cmd === "playerctl") return o.failAction ? { stdout: "", stderr: "Could not execute command", code: 1 } : { stdout: "", stderr: "", code: 0 };
    if (cmd === "wpctl" && args[0] === "get-volume") return { stdout: vol, stderr: "", code: 0 };
    if (cmd === "wpctl" && args[0] === "set-volume") {
      vol = `Volume: ${args[4]}${vol.includes("MUTED") ? " [MUTED]" : ""}\n`;
      return { stdout: "", stderr: "", code: 0 };
    }
    if (cmd === "wpctl" && args[0] === "set-mute") {
      vol = vol.replace(/ \[MUTED\]/, "").trimEnd() + (args[2] === "1" ? " [MUTED]" : "") + "\n";
      return { stdout: "", stderr: "", code: 0 };
    }
    throw new Error(`beklenmeyen komut ${cmd} ${args.join(" ")}`);
  };
  return { exec, calls };
}

async function mediaApp(f: ReturnType<typeof fakeExec>) {
  return testApp((c) => c, [(a, ctx) => mediaRoutes(a, ctx, f.exec, { settleMs: 0 })]);
}

const twoPlayers = {
  list: "firefox.instance_1_42\nspotify\n",
  meta:
    rec("firefox.instance_1_42", "Paused", "Lo-fi beats", "Chillhop", "", "180000000", "61500000", "https://i.ytimg.com/vi/x/hq.jpg") +
    rec("spotify", "Playing", "Kaç Kadeh Kırıldı", "Sezen Aksu", "Gülümse", "245000000", "12345678", "https://i.scdn.co/image/ab67"),
};

describe("medya: çıktı ayrıştırma", () => {
  it("oynatıcı listesi, metadata (boş alanlar, ayraç) ve ses düzeyi", () => {
    expect(parsePlayerList("firefox.instance_1_42\nspotify\n\n")).toEqual(["firefox.instance_1_42", "spotify"]);
    expect(parsePlayerList("")).toEqual([]);
    const [a, b] = parseMetadata(twoPlayers.meta);
    expect(a).toMatchObject({ name: "firefox.instance_1_42", status: "Paused", title: "Lo-fi beats", album: null, length: 180, position: 61.5 });
    expect(b).toMatchObject({ name: "spotify", status: "Playing", artist: "Sezen Aksu", length: 245, position: 12.3 });
    // Length/position unknown, characters like "|" and ":" in the title.
    expect(parseMetadata(rec("mpv", "Stopped", "a | b: c", "", "", "", "", ""))[0]).toMatchObject({ title: "a | b: c", artist: null, length: null, position: null, art: null });
    expect(METADATA_FORMAT.startsWith("{{playerInstance}}" + US)).toBe(true);
    expect(parseVolume("Volume: 0.60\n")).toEqual({ percent: 60, muted: false });
    expect(parseVolume("Volume: 1.25 [MUTED]\n")).toEqual({ percent: 125, muted: true });
    expect(parseVolume("garip")).toBeNull();
  });

  it("oynatıcı seçimi: istenen > çalan > duraklatılmış > ilk", () => {
    const ps = parseMetadata(twoPlayers.meta);
    expect(pickPlayer(ps)?.name).toBe("spotify");
    expect(pickPlayer(ps, "firefox.instance_1_42")?.name).toBe("firefox.instance_1_42");
    expect(pickPlayer(ps, "yok")?.name).toBe("spotify");
    expect(pickPlayer([])).toBeNull();
  });

  it("resim türü baytlardan", () => {
    expect(imageType(Buffer.from([0xff, 0xd8, 0xff, 0xe0]))).toBe("image/jpeg");
    expect(imageType(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0]))).toBe("image/png");
    expect(imageType(Buffer.from("RIFF\0\0\0\0WEBPVP8 "))).toBe("image/webp");
    expect(imageType(Buffer.from("#!/bin/sh\n"))).toBeNull();
  });
});

describe("medya: uçlar", () => {
  it("oynatıcı yoksa 200 ve boş liste; D-Bus ortamı verilir", async () => {
    const f = fakeExec();
    const { app, auth } = await mediaApp(f);
    const r = await app.inject({ method: "GET", url: "/v1/media", headers: auth });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ players: [], player: null });
    expect(f.calls[0]!.env?.DBUS_SESSION_BUS_ADDRESS).toMatch(/^unix:path=/);
    expect((await app.inject({ method: "POST", url: "/v1/media/next", headers: auth, payload: {} })).statusCode).toBe(404);
    await app.close();
  });

  it("çalan oynatıcı seçilir; http kapak doğrudan, yerel yol yanıta konmaz", async () => {
    const f = fakeExec({
      list: twoPlayers.list + "vlc\n",
      meta: twoPlayers.meta + rec("vlc", "Paused", "Film", "", "", "", "", "file:///home/u/.cache/vlc/art/kapak.jpg"),
    });
    const { app, auth } = await mediaApp(f);
    const j = (await app.inject({ method: "GET", url: "/v1/media", headers: auth })).json();
    expect(j.players).toEqual([
      { name: "firefox.instance_1_42", status: "Paused" },
      { name: "spotify", status: "Playing" },
      { name: "vlc", status: "Paused" },
    ]);
    expect(j.player).toMatchObject({ name: "spotify", title: "Kaç Kadeh Kırıldı", artUrl: "https://i.scdn.co/image/ab67", localArt: false });
    const vlc = (await app.inject({ method: "GET", url: "/v1/media?player=vlc", headers: auth })).json().player;
    expect(vlc).toMatchObject({ name: "vlc", artUrl: null, localArt: true });
    expect(vlc.artId).toMatch(/^[0-9a-f]{12}$/);
    expect(JSON.stringify(vlc)).not.toContain("/home/u");
    await app.close();
  });

  it("eylemler playerctl'e doğru argümanlarla gider; geçersiz eylem/ayar reddedilir", async () => {
    const f = fakeExec(twoPlayers);
    const { app, auth } = await mediaApp(f);
    const post = (a: string, payload: object = {}) => app.inject({ method: "POST", url: `/v1/media/${a}`, headers: auth, payload });
    expect((await post("play-pause")).json().player.name).toBe("spotify");
    expect((await post("next", { player: "firefox.instance_1_42" })).statusCode).toBe(200);
    expect((await post("seek", { seconds: -10 })).statusCode).toBe(200);
    expect((await post("seek", { seconds: 10 })).statusCode).toBe(200);
    expect((await post("position", { seconds: 42.5 })).statusCode).toBe(200);
    const actions = f.calls.filter((c) => c.cmd === "playerctl" && c.args[0] === "-p").map((c) => c.args.join(" "));
    expect(actions).toEqual([
      "-p spotify play-pause",
      "-p firefox.instance_1_42 next",
      "-p spotify position 10-",
      "-p spotify position 10+",
      "-p spotify position 42.5",
    ]);
    expect((await post("rm")).statusCode).toBe(400);
    expect((await post("seek", {})).statusCode).toBe(400);
    expect((await post("position", { seconds: -1 })).statusCode).toBe(400);
    expect((await post("next", { player: "yok" })).statusCode).toBe(404);
    expect((await post("next", { player: "--help" })).statusCode).toBe(404);
    await app.close();
  });

  it("oynatıcı komutu başarısızsa 502", async () => {
    const f = fakeExec({ ...twoPlayers, failAction: true });
    const { app, auth } = await mediaApp(f);
    const r = await app.inject({ method: "POST", url: "/v1/media/next", headers: auth, payload: {} });
    expect(r.statusCode).toBe(502);
    expect(r.json().error.code).toBe("agent.media.failed");
    await app.close();
  });

  it("ses: oku, ayarla (en çok %150), sessize al", async () => {
    const f = fakeExec(twoPlayers);
    const { app, auth } = await mediaApp(f);
    expect((await app.inject({ method: "GET", url: "/v1/media/volume", headers: auth })).json()).toEqual({ percent: 60, muted: false });
    const put = (payload: object) => app.inject({ method: "PUT", url: "/v1/media/volume", headers: auth, payload });
    expect((await put({ percent: 35 })).json()).toEqual({ percent: 35, muted: false });
    expect((await put({ muted: true })).json()).toEqual({ percent: 35, muted: true });
    expect((await put({ percent: 151 })).statusCode).toBe(400);
    expect((await put({})).statusCode).toBe(400);
    const wp = f.calls.filter((c) => c.cmd === "wpctl" && c.args[0] !== "get-volume").map((c) => c.args.join(" "));
    expect(wp).toEqual(["set-volume -l 1.5 @DEFAULT_AUDIO_SINK@ 0.35", "set-mute @DEFAULT_AUDIO_SINK@ 1"]);
    await app.close();
  });

  it("yerel kapak: yalnız metadatadaki yoldan, yalnız resim, boyut sınırlı", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-art-"));
    const png = Buffer.concat([Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]), Buffer.alloc(32)]);
    await writeFile(join(dir, "kapak dosyası.png"), png);
    await writeFile(join(dir, "gizli.txt"), "parola=123");
    const metaFor = (art: string) => rec("vlc", "Playing", "Film", "", "", "", "", art);
    let art = pathToFileURL(join(dir, "kapak dosyası.png")).href;
    const f = fakeExec({ list: "vlc\n" });
    const exec: Exec = (cmd, args, opts) => (args[1] === "metadata" ? Promise.resolve({ stdout: metaFor(art), stderr: "", code: 0 }) : f.exec(cmd, args, opts));
    const { app, auth } = await testApp((c) => c, [(a, ctx) => mediaRoutes(a, ctx, exec, { settleMs: 0 })]);
    const get = (q = "") => app.inject({ method: "GET", url: `/v1/media/art${q}`, headers: auth });
    let r = await get();
    expect(r.statusCode).toBe(200);
    expect(r.headers["content-type"]).toBe("image/png");
    expect(r.rawPayload.equals(png)).toBe(true);
    // A path can't be given in the query (player name only); a non-image file isn't served.
    art = pathToFileURL(join(dir, "gizli.txt")).href;
    expect((await get(`?path=${encodeURIComponent(join(dir, "gizli.txt"))}`)).statusCode).toBe(400);
    r = await get();
    expect(r.statusCode).toBe(404);
    expect(r.body).not.toContain("parola");
    art = "https://i.scdn.co/image/ab67";
    expect((await get()).statusCode).toBe(404);
    art = pathToFileURL(join(dir, "yok.png")).href;
    expect((await get()).statusCode).toBe(404);
    await app.close();
  });
});

describe("medya: ses çıkışları", () => {
  it("pw-dump: yalnız Audio/Sink, varsayılan işaretli, ad yoksa node.name", () => {
    expect(parseOutputs(pwDump())).toEqual([
      { id: 57, name: "Built-in Audio Analog Stereo", default: false },
      { id: 81, name: "WH-1000XM4", default: true },
      { id: 90, name: "nameless", default: false },
    ]);
    expect(parseOutputs("bozuk")).toEqual([]);
    expect(parseOutputs("{}")).toEqual([]);
  });

  it("liste ve değiştirme: yalnız listedeki id, wpctl set-default", async () => {
    const f = fakeExec();
    const { app, auth } = await mediaApp(f);
    const list = await app.inject({ url: "/v1/media/outputs", headers: auth });
    expect(list.json().outputs.find((o: { default: boolean }) => o.default).id).toBe(81);
    const set = await app.inject({ method: "PUT", url: "/v1/media/output", headers: auth, payload: { id: 57 } });
    expect(set.statusCode).toBe(200);
    expect(set.json().outputs.find((o: { default: boolean }) => o.default).id).toBe(57);
    expect(f.calls.filter((c) => c.cmd === "wpctl").map((c) => c.args.join(" "))).toEqual(["set-default 57"]);
    // A source or an unknown id is refused without running wpctl.
    for (const id of [60, 999]) {
      const r = await app.inject({ method: "PUT", url: "/v1/media/output", headers: auth, payload: { id } });
      expect([r.statusCode, r.json().error.code]).toEqual([404, "agent.media.outputNotFound"]);
    }
    for (const payload of [{ id: "57" }, { id: -1 }, { id: 1.5 }, {}]) {
      expect((await app.inject({ method: "PUT", url: "/v1/media/output", headers: auth, payload })).statusCode).toBe(400);
    }
    expect(f.calls.filter((c) => c.cmd === "wpctl")).toHaveLength(1);
    await app.close();
  });

  it("pw-dump hatası → outputFailed", async () => {
    const exec: Exec = async () => ({ stdout: "", stderr: "no pipewire", code: 1 });
    const { app, auth } = await testApp((c) => c, [(a, ctx) => mediaRoutes(a, ctx, exec, { settleMs: 0 })]);
    const r = await app.inject({ url: "/v1/media/outputs", headers: auth });
    expect([r.statusCode, r.json().error.code]).toEqual([502, "agent.media.outputFailed"]);
    await app.close();
  });
});

describe("PC'de aç", () => {
  it("adres denetimi: yalnız http/https, boşluksuz, uzunluk sınırlı", () => {
    expect(checkOpenUrl("https://example.com/a b")).toBeNull();
    expect(checkOpenUrl("https://örnek.com.tr/yol?q=ç")).toBe("https://xn--rnek-4qa.com.tr/yol?q=%C3%A7");
    expect(checkOpenUrl("http://100.64.0.2:3000/")).toBe("http://100.64.0.2:3000/");
    for (const bad of ["file:///etc/passwd", "javascript:alert(1)", "ftp://x", "-help", "https://", "https://x\n.com", "x".repeat(10)]) {
      expect(checkOpenUrl(bad)).toBeNull();
    }
    expect(checkOpenUrl("https://e.com/" + "a".repeat(5000))).toBeNull();
  });

  it("açıcı Wayland ortamıyla çağrılır; adres olaylara ve işlem kaydına yazılmaz", async () => {
    const opened: Array<{ url: string; env: NodeJS.ProcessEnv }> = [];
    const { app, auth, dir } = await testApp((c) => c, [
      (a) => openRoutes(a, async (url, env) => void opened.push({ url, env }), async () => ({ WAYLAND_DISPLAY: "wayland-1", DBUS_SESSION_BUS_ADDRESS: "unix:path=/x" })),
    ]);
    const secret = "https://docs.example.com/d/gizli-belge-77?token=abc";
    const post = (url: unknown) => app.inject({ method: "POST", url: "/v1/desktop/open", headers: auth, payload: { url } });
    expect((await post(secret)).statusCode).toBe(200);
    expect(opened).toEqual([{ url: secret, env: { WAYLAND_DISPLAY: "wayland-1", DBUS_SESSION_BUS_ADDRESS: "unix:path=/x" } }]);
    const bad = await post("file:///etc/passwd");
    expect(bad.statusCode).toBe(400);
    expect(bad.json().error.code).toBe("agent.desktop.badUrl");
    expect((await post(42)).statusCode).toBe(400);
    expect(opened).toHaveLength(1);
    const files = await Promise.all(["events.jsonl", "audit.jsonl"].map((n) => readFile(join(dir, n), "utf8").catch(() => "")));
    expect(files[1]).toContain("/v1/desktop/open");
    for (const text of files) expect(text).not.toContain("gizli-belge");
    await app.close();
  });

  it("açıcı bulunamazsa okunur hata", async () => {
    const { app, auth } = await testApp((c) => c, [
      (a) => openRoutes(a, async () => Promise.reject(new (await import("../src/errors.ts")).AppError("agent.exec.commandMissing", 500, { command: "xdg-open" })), async () => ({})),
    ]);
    const r = await app.inject({ method: "POST", url: "/v1/desktop/open", headers: auth, payload: { url: "https://example.com" } });
    expect(r.statusCode).toBe(500);
    expect(r.json().error.code).toBe("agent.exec.commandMissing");
    await app.close();
  });
});
