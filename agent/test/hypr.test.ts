// 10.1 Desktop panel: hyprctl parsing, allowed actions, .desktop and icon resolution, control session
// (PC indicator, duration, events), auth and rate limit. All with a fake runner; the real PC is never touched.
import { existsSync } from "node:fs";
import { mkdir, mkdtemp, readFile, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { describe, expect, it } from "vitest";
import { hashToken, newToken } from "../src/auth.ts";
import { ControlSessions, RateLimit, gradientValue, indicatorStatePath, type Indicator } from "../src/control.ts";
import { IconResolver, appForClass, candidateDirs, parseDesktopFile, parseIndexTheme, scanApps, themesFrom, toApp } from "../src/desktop_apps.ts";
import { AppError } from "../src/errors.ts";
import { legacyDispatch, luaDispatch } from "../src/hyprctl.ts";
import { ADDRESS, desktopState, dispatchFor, hyprRoutes, isVisible, parseClients, parseMonitors, parseWorkspaces, type HyprIo, type HyprOpts } from "../src/routes/hypr.ts";
import { testApp } from "./helpers.ts";

const PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13]);
const WEBP = Buffer.from("RIFF\0\0\0\0WEBPVP8 ");

const client = (o: Record<string, unknown>) => ({
  address: "0x55d1a0",
  mapped: true,
  hidden: false,
  at: [10, 60],
  size: [900, 700],
  workspace: { id: 1, name: "1" },
  floating: false,
  pseudo: false,
  monitor: 0,
  class: "firefox",
  title: "Tiphys — Mozilla Firefox",
  initialClass: "firefox",
  initialTitle: "Mozilla Firefox",
  pid: 4321,
  xwayland: false,
  pinned: false,
  fullscreen: 0,
  fullscreenClient: 0,
  focusHistoryID: 0,
  ...o,
});

const CLIENTS = [
  client({}),
  client({ address: "0x55d1b0", class: "foot", title: "~/Desktop", focusHistoryID: 1, at: [920, 60], size: [990, 1010] }),
  client({ address: "0x55d1c0", class: "org.gnome.Nautilus", title: "Ev", workspace: { id: 2, name: "2" }, focusHistoryID: 2, fullscreen: 2 }),
  client({ address: "garip", class: "x" }), // invalid address: skipped
];
const MONITORS = [
  { id: 0, name: "DVI-D-1", width: 1920, height: 1080, x: 0, y: 0, scale: 1, focused: true, activeWorkspace: { id: 1, name: "1" }, specialWorkspace: { id: 0, name: "" }, dpmsStatus: true, disabled: false },
];
const WORKSPACES = [
  { id: 2, name: "2", monitor: "DVI-D-1", windows: 1 },
  { id: 1, name: "1", monitor: "DVI-D-1", windows: 2 },
];

interface FakeOpts {
  /** Hyprland with a Lua config (0.55+): keyword/classic dispatch is rejected, eval works. */
  lua?: boolean;
  clients?: unknown[];
  noHypr?: boolean;
  dispatchOut?: string;
  has?: string[];
  border?: string;
  borderSize?: number;
}

function fakeIo(o: FakeOpts = {}) {
  const calls: Array<{ cmd: string; args: string[] }> = [];
  const has = new Set(o.has ?? ["ffmpeg", "gtk-launch"]);
  const io: HyprIo = {
    exec: async (cmd, args) => {
      calls.push({ cmd, args });
      const ok = (stdout: string) => ({ stdout, stderr: "", code: 0 });
      if (cmd === "hyprctl" && args[0] === "-j") {
        switch (args[1]) {
          case "clients":
            return ok(JSON.stringify(o.clients ?? CLIENTS));
          case "activewindow":
            return ok(JSON.stringify(CLIENTS[0]));
          case "workspaces":
            return ok(JSON.stringify(WORKSPACES));
          case "monitors":
            return ok(JSON.stringify(MONITORS));
          case "getoption":
            return ok(
              args[2] === "general:border_size"
                ? JSON.stringify({ option: "general:border_size", int: o.borderSize ?? 1, set: true })
                : JSON.stringify({ option: "general:col.active_border", gradient: o.border ?? "ffffffff 0deg", set: false }),
            );
        }
      }
      if (cmd === "hyprctl" && args[0] === "eval") return o.lua ? ok("ok\n") : { stdout: "unknown request\n", stderr: "", code: 0 };
      if (cmd === "hyprctl" && o.lua && (args[0] === "keyword" || args[0] === "dispatch" || args[0] === "--batch")) {
        return { stdout: "keyword can't work with non-legacy parsers. Use eval.\n", stderr: "", code: 1 };
      }
      if (cmd === "hyprctl" && args[0] === "keyword") return ok("ok\n");
      if (cmd === "hyprctl" && args[0] === "dispatch") return ok(o.dispatchOut ?? "ok\n");
      if (cmd === "hyprctl" && args[0] === "--batch") return ok(args[1]!.split(";").map(() => "ok").join("\n\n") + "\n");
      if (cmd === "notify-send") return ok("");
      if (cmd === "gsettings") return ok("'Adwaita'\n");
      throw new Error(`beklenmeyen komut ${cmd} ${args.join(" ")}`);
    },
    bytes: async (cmd, args) => {
      calls.push({ cmd, args });
      if (cmd === "grim") return { out: PNG, code: 0, err: "" };
      if (cmd === "ffmpeg" && args.includes("libwebp")) return { out: WEBP, code: 0, err: "" };
      if (cmd === "ffmpeg" || cmd === "rsvg-convert") return { out: Buffer.concat([PNG, Buffer.from(cmd)]), code: 0, err: "" };
      throw new Error(`beklenmeyen komut ${cmd}`);
    },
    has: async (c) => has.has(c),
    hyprEnv: async () => {
      if (o.noHypr) throw new AppError("agent.desktop.noHyprland", 503);
      return { HYPRLAND_INSTANCE_SIGNATURE: "sig" };
    },
    screenEnv: async () => ({ WAYLAND_DISPLAY: "wayland-1" }),
  };
  // The mode probe (eval return 1) isn't listed.
  return { io, calls, hyprctl: () => calls.filter((c) => c.cmd === "hyprctl" && c.args[0] !== "-j" && c.args.join(" ") !== "eval return 1").map((c) => c.args.join(" ")) };
}

/** Temporary app and icon folders. */
async function fixtures() {
  const root = await mkdtemp(join(tmpdir(), "tiphys-hypr-"));
  const user = join(root, "user", "applications");
  const sys = join(root, "sys", "applications");
  const w = async (p: string, text: string | Buffer) => {
    await mkdir(dirname(p), { recursive: true });
    await writeFile(p, text);
  };
  await w(
    join(sys, "firefox.desktop"),
    "[Desktop Entry]\nType=Application\nName=Firefox\nName[tr]=Firefox Tarayıcı\nGenericName=Web Browser\nGenericName[tr]=Web Tarayıcısı\nExec=firefox %u\nIcon=firefox\nCategories=Network;WebBrowser;\nStartupWMClass=firefox\n\n[Desktop Action new-window]\nName=Yeni pencere\nExec=firefox --new-window\n",
  );
  await w(join(sys, "foot.desktop"), "[Desktop Entry]\nType=Application\nName=Foot\nName[tr_TR]=Foot Uçbirim\nComment=Hızlı\\sterminal\nExec=foot\nIcon=foot\nCategories=System;TerminalEmulator;\nKeywords=shell;prompt;\n");
  await w(join(sys, "hidden-tool.desktop"), "[Desktop Entry]\nType=Application\nName=Gizli\nExec=gizli\nNoDisplay=true\n");
  await w(join(sys, "gnome-only.desktop"), "[Desktop Entry]\nType=Application\nName=Sadece GNOME\nExec=x\nOnlyShowIn=GNOME;\n");
  await w(join(sys, "link.desktop"), "[Desktop Entry]\nType=Link\nName=Bağlantı\nURL=https://example.com\n");
  await w(join(sys, "overridden.desktop"), "[Desktop Entry]\nType=Application\nName=Sistemdeki\nExec=y\n");
  await w(join(user, "overridden.desktop"), "[Desktop Entry]\nType=Application\nName=Sistemdeki\nExec=y\nHidden=true\n");
  await w(join(sys, "kde", "dolphin.desktop"), "[Desktop Entry]\nType=Application\nName=Dolphin\nExec=dolphin %U\nIcon=/opt/dolphin.svg\nCategories=System;FileManager;\n");
  await w(join(sys, "bad;id.desktop"), "[Desktop Entry]\nType=Application\nName=Kötü\nExec=z\n");
  await w(join(user, "nautilus.desktop"), "[Desktop Entry]\nType=Application\nName=Files\nName[tr]=Dosyalar\nExec=nautilus --new-window %U\nIcon=org.gnome.Nautilus\nCategories=GTK;Utility;\n");

  const icons = join(root, "icons");
  await w(join(icons, "Tema", "index.theme"), "[Icon Theme]\nName=Tema\nInherits=Ust\nDirectories=apps/48,apps/128,apps/scalable,apps/symbolic\n\n[apps/48]\nSize=48\nContext=Applications\nType=Fixed\n\n[apps/128]\nSize=128\nContext=Applications\nType=Fixed\n\n[apps/scalable]\nSize=64\nContext=Applications\nType=Scalable\nMinSize=16\nMaxSize=512\n\n[apps/symbolic]\nSize=16\nContext=Applications\nType=Scalable\n");
  await w(join(icons, "Tema", "apps", "48", "firefox.png"), PNG);
  await w(join(icons, "Tema", "apps", "128", "firefox.png"), PNG);
  await w(join(icons, "Tema", "apps", "symbolic", "foot.svg"), "<svg/>");
  await w(join(icons, "Ust", "index.theme"), "[Icon Theme]\nName=Ust\nDirectories=scalable/apps\n\n[scalable/apps]\nSize=64\nContext=Applications\nType=Scalable\n");
  await w(join(icons, "Ust", "scalable", "apps", "foot.svg"), '<svg xmlns="http://www.w3.org/2000/svg"/>');
  await w(join(icons, "hicolor", "index.theme"), "[Icon Theme]\nName=Hicolor\nDirectories=256x256/apps,16x16/apps\n\n[256x256/apps]\nSize=256\nContext=Applications\nType=Threshold\n\n[16x16/apps]\nSize=16\nContext=Applications\nType=Threshold\n");
  await w(join(icons, "hicolor", "256x256", "apps", "org.gnome.Nautilus.png"), PNG);
  await w(join(icons, "hicolor", "16x16", "apps", "tiny.png"), PNG);
  const pixmaps = join(root, "pixmaps");
  await w(join(pixmaps, "tiny.png"), PNG);
  return { root, user, sys, icons, pixmaps, opts: { appDirs: [user, sys], icons: { iconBases: [icons], pixmapDirs: [pixmaps] }, themes: async () => ["Tema"] } satisfies HyprOpts };
}

async function hyprApp(f: ReturnType<typeof fakeIo>, opts: HyprOpts = {}, control = true) {
  return testApp(
    (c) => {
      c.features.control = control;
      return c;
    },
    [(a, ctx) => hyprRoutes(a, ctx, f.io, opts)],
  );
}

describe("hyprctl ayrıştırma", () => {
  it("pencereler, monitörler, çalışma alanları, görünürlük ve uygulama eşleşmesi", () => {
    const ws = parseClients(CLIENTS);
    expect(ws.map((w) => w.address)).toEqual(["0x55d1a0", "0x55d1b0", "0x55d1c0"]);
    expect(ws[2]).toMatchObject({ class: "org.gnome.Nautilus", fullscreen: true, workspace: { id: 2, name: "2" } });
    expect(parseClients([client({ fullscreen: true })])[0]!.fullscreen).toBe(true); // old boolean format
    expect(parseClients("garip")).toEqual([]);
    const ms = parseMonitors(MONITORS);
    expect(ms[0]).toMatchObject({ name: "DVI-D-1", activeWorkspace: 1, dpms: true, focused: true });
    expect(parseWorkspaces(WORKSPACES).map((w) => w.id)).toEqual([1, 2]);
    expect(isVisible(ws[0]!, ms)).toBe(true);
    expect(isVisible(ws[2]!, ms)).toBe(false);
    expect(isVisible({ ...ws[0]!, hidden: true }, ms)).toBe(false);
    const apps = [{ id: "org.gnome.Nautilus", name: "Dosyalar", genericName: null, comment: null, categories: [], keywords: [], icon: "org.gnome.Nautilus", wmClass: null, path: "" }];
    const s = desktopState(ws, CLIENTS[0], parseWorkspaces(WORKSPACES), ms, apps);
    expect(s.activeWorkspace).toBe(1);
    expect(s.workspaces).toEqual([
      { id: 1, name: "1", monitor: "DVI-D-1", windows: 2, visible: true, focused: true },
      { id: 2, name: "2", monitor: "DVI-D-1", windows: 1, visible: false, focused: false },
    ]);
    expect(s.windows.map((w) => [w.address, w.focused, w.visible, w.appId])).toEqual([
      ["0x55d1a0", true, true, null],
      ["0x55d1b0", false, true, null],
      ["0x55d1c0", false, false, "org.gnome.Nautilus"],
    ]);
  });

  it("izinli eylemler: yalnız sabit komutlar (klasik ve Lua), adres ve çalışma alanı doğrulanır", () => {
    const [w] = parseClients([client({})]);
    const legacy = (a: Parameters<typeof dispatchFor>[0], ws?: number, x = w!) => dispatchFor(a, x, ws).map(legacyDispatch);
    const lua = (a: Parameters<typeof dispatchFor>[0], ws?: number, x = w!) => dispatchFor(a, x, ws).map(luaDispatch);
    expect(legacy("focus")).toEqual([["focuswindow", "address:0x55d1a0"]]);
    expect(legacy("close")).toEqual([["closewindow", "address:0x55d1a0"]]);
    expect(legacy("fullscreen")).toEqual([["focuswindow", "address:0x55d1a0"], ["fullscreen", "0"]]);
    expect(legacy("float")).toEqual([["togglefloating", "address:0x55d1a0"]]);
    expect(legacy("pin")).toEqual([["setfloating", "address:0x55d1a0"], ["pin", "address:0x55d1a0"]]);
    expect(legacy("pin", undefined, { ...w!, floating: true })).toEqual([["pin", "address:0x55d1a0"]]);
    expect(legacy("move-to-workspace", 3)).toEqual([["movetoworkspacesilent", "3,address:0x55d1a0"]]);
    expect(lua("focus")).toEqual(['hl.dsp.focus({ window = "address:0x55d1a0" })']);
    expect(lua("close")).toEqual(['hl.dsp.window.close({ window = "address:0x55d1a0" })']);
    expect(lua("fullscreen")).toEqual(['hl.dsp.focus({ window = "address:0x55d1a0" })', 'hl.dsp.window.fullscreen({ window = "address:0x55d1a0", mode = "fullscreen", action = "toggle" })']);
    expect(lua("float")).toEqual(['hl.dsp.window.float({ window = "address:0x55d1a0", action = "toggle" })']);
    expect(lua("pin")).toEqual(['hl.dsp.window.float({ window = "address:0x55d1a0", action = "enable" })', 'hl.dsp.window.pin({ window = "address:0x55d1a0", action = "toggle" })']);
    expect(lua("move-to-workspace", 3)).toEqual(['hl.dsp.window.move({ window = "address:0x55d1a0", workspace = "3", follow = false })']);
    expect(() => dispatchFor("move-to-workspace", w!, 0)).toThrow();
    expect(() => dispatchFor("move-to-workspace", w!, 101)).toThrow();
    expect(() => dispatchFor("focus", { ...w!, address: "0x1;exec rm" })).toThrow(AppError);
    for (const ok of ["0x1", "0x55d1a0b2c3"]) expect(ADDRESS.test(ok)).toBe(true);
    for (const bad of ["0X1", "55d1", "0x", "0xg1", "0x1 ", "0x1,workspace", "0x12345678901234567"]) expect(ADDRESS.test(bad)).toBe(false);
  });

  it("kenarlık değeri geri yazılabilir biçime çevrilir", () => {
    expect(gradientValue({ gradient: "ffffffff 0deg" })).toBe("0xffffffff 0deg");
    expect(gradientValue({ gradient: "ee33ccff ee00ff99 45deg" })).toBe("0xee33ccff 0xee00ff99 45deg");
    expect(gradientValue({ gradient: "rgba(1,2,3) ; exec x" })).toBeNull();
    expect(gradientValue({})).toBeNull();
  });
});

describe(".desktop ve simgeler", () => {
  it("yerelleştirilmiş adlar, gizliler atlanır, kullanıcı kopyası öncelikli, Exec yanıtta yok", async () => {
    const f = await fixtures();
    const tr = await scanApps([f.user, f.sys], "tr");
    expect(tr.map((a) => a.id)).toEqual(["kde-dolphin", "nautilus", "firefox", "foot"]);
    expect(tr.map((a) => a.name)).toEqual(["Dolphin", "Dosyalar", "Firefox Tarayıcı", "Foot Uçbirim"]);
    const foot = tr.find((a) => a.id === "foot")!;
    expect(foot).toMatchObject({ comment: "Hızlı terminal", categories: ["System", "TerminalEmulator"], keywords: ["shell", "prompt"] });
    expect(tr.find((a) => a.id === "firefox")).toMatchObject({ genericName: "Web Tarayıcısı", wmClass: "firefox" });
    const en = await scanApps([f.user, f.sys], "en");
    expect(en.map((a) => a.name)).toEqual(["Dolphin", "Files", "Firefox", "Foot"]);
    // A [Desktop Action] group doesn't break the main entry; Type=Link, NoDisplay, OnlyShowIn and entries Hidden by the
    // user are excluded.
    const fields = parseDesktopFile("[Desktop Entry]\nName=A\nExec=a\n[Desktop Action x]\nName=B\nExec=b\n");
    expect(fields.get("Name")).toBe("A");
    expect(toApp(fields, "a", "/a.desktop", "tr", "GNOME")).toMatchObject({ name: "A" });
    expect(toApp(parseDesktopFile("[Desktop Entry]\nName=A\nExec=a\nNotShowIn=Hyprland;\n"), "a", "", "tr")).toBeNull();
    expect(appForClass(tr, "Firefox")?.id).toBe("firefox");
    expect(appForClass(tr, "org.gnome.Nautilus")?.id).toBe("nautilus");
    expect(appForClass(tr, "")).toBeNull();
  });

  it("simge teması: tercih edilen boyut, miras, hicolor, pixmaps, mutlak yol; sembolikler atlanır", async () => {
    const f = await fixtures();
    const r = new IconResolver(f.opts.icons, f.opts.themes);
    expect((await r.chain()).map(([n]) => n)).toEqual(["Tema", "Ust", "hicolor"]);
    expect(await r.resolve("firefox")).toBe(join(f.icons, "Tema", "apps", "128", "firefox.png"));
    expect(await r.resolve("foot")).toBe(join(f.icons, "Ust", "scalable", "apps", "foot.svg"));
    expect(await r.resolve("org.gnome.Nautilus")).toBe(join(f.icons, "hicolor", "256x256", "apps", "org.gnome.Nautilus.png"));
    expect(await r.resolve("tiny")).toBe(join(f.pixmaps, "tiny.png")); // 16 px hicolor isn't picked
    expect(await r.resolve("yok")).toBeNull();
    expect(await r.resolve("../../etc/passwd")).toBeNull();
    await writeFile(join(f.root, "abs.svg"), "<svg/>");
    expect(await r.resolve(join(f.root, "abs.svg"))).toBe(join(f.root, "abs.svg"));
    expect(await r.resolve(join(f.root, "abs.txt"))).toBeNull();
    const t = parseIndexTheme("[Icon Theme]\nDirectories=a\nScaledDirectories=a@2\n[a]\nSize=48\nContext=Applications\n[a@2]\nSize=48\nScale=2\nContext=Applications\n");
    expect(candidateDirs(t, false).map((d) => d.sub)).toEqual(["a@2", "a"]); // 96 px, closer to 128
    expect(themesFrom(["[Settings]\ngtk-icon-theme-name=WhiteSur-dark\n", ""], "'Adwaita'\n")).toEqual(["WhiteSur-dark", "Adwaita"]);
    expect(themesFrom([], null)).toEqual([]);
  });

  it("bozuk sembolik bağlantılı tema klasörü hata vermez", async () => {
    const f = await fixtures();
    await symlink(join(f.root, "yok"), join(f.icons, "Tema", "apps", "kirik"));
    await writeFile(join(f.icons, "Tema", "index.theme"), "[Icon Theme]\nInherits=Ust\nDirectories=apps/kirik\n[apps/kirik]\nSize=64\nType=Scalable\nContext=Applications\n");
    const r = new IconResolver(f.opts.icons, f.opts.themes);
    expect(await r.resolve("foot")).toBe(join(f.icons, "Ust", "scalable", "apps", "foot.svg"));
  });
});

describe("masaüstü uçları (salt okunur)", () => {
  it("pencere listesi, küçük resim (WebP, 2 sn önbellek, görünmeyene 409), uygulamalar ve simgeler", async () => {
    const fx = await fixtures();
    let t = 1_000_000;
    const f = fakeIo({ has: ["ffmpeg"] });
    const { app, auth } = await hyprApp(f, { ...fx.opts, now: () => t });
    const res = await app.inject({ method: "GET", url: "/v1/desktop/windows", headers: auth });
    expect(res.statusCode, res.body).toBe(200);
    const body = res.json();
    expect(body.windows).toHaveLength(3);
    expect(body.windows[2]).toMatchObject({ class: "org.gnome.Nautilus", appId: "nautilus", visible: false });
    expect(body.monitors[0]).toMatchObject({ name: "DVI-D-1", dpms: true });

    const thumb = await app.inject({ method: "GET", url: "/v1/desktop/windows/0x55d1a0/thumb?w=300", headers: auth });
    expect(thumb.statusCode).toBe(200);
    expect(thumb.headers["content-type"]).toBe("image/webp");
    const grim = f.calls.filter((c) => c.cmd === "grim");
    expect(grim[0]!.args).toEqual(["-g", "10,60 900x700", "-s", "0.3333", "-t", "png", "-l", "0", "-"]);
    await app.inject({ method: "GET", url: "/v1/desktop/windows/0x55d1a0/thumb?w=300", headers: auth });
    expect(f.calls.filter((c) => c.cmd === "grim")).toHaveLength(1); // from cache
    t += 2500;
    await app.inject({ method: "GET", url: "/v1/desktop/windows/0x55d1a0/thumb?w=300", headers: auth });
    expect(f.calls.filter((c) => c.cmd === "grim")).toHaveLength(2);
    expect((await app.inject({ method: "GET", url: "/v1/desktop/windows/0x55d1c0/thumb", headers: auth })).json().error.code).toBe("agent.desktop.windowNotVisible");
    expect((await app.inject({ method: "GET", url: "/v1/desktop/windows/0x999/thumb", headers: auth })).statusCode).toBe(404);
    expect((await app.inject({ method: "GET", url: "/v1/desktop/windows/0x1%3Bx/thumb", headers: auth })).json().error.code).toBe("agent.desktop.badAddress");

    const apps = (await app.inject({ method: "GET", url: "/v1/desktop/apps", headers: auth })).json().apps;
    expect(apps.map((a: { name: string }) => a.name)).toEqual(["Dolphin", "Dosyalar", "Firefox Tarayıcı", "Foot Uçbirim"]);
    expect(apps[2]).toEqual({ id: "firefox", name: "Firefox Tarayıcı", genericName: "Web Tarayıcısı", comment: null, categories: ["Network", "WebBrowser"], keywords: [], hasIcon: true });
    expect(JSON.stringify(apps)).not.toContain("%u"); // Exec and path are not in the response
    expect(JSON.stringify(apps)).not.toContain(fx.root);

    const png = await app.inject({ method: "GET", url: "/v1/desktop/apps/firefox/icon", headers: auth });
    expect(png.statusCode).toBe(200);
    expect(png.headers["content-type"]).toBe("image/png");
    // SVG: no rsvg-convert, PNG via ffmpeg (librsvg).
    const svg = await app.inject({ method: "GET", url: "/v1/desktop/apps/foot/icon?size=96", headers: auth });
    expect(svg.headers["content-type"]).toBe("image/png");
    expect(svg.rawPayload.subarray(PNG.length).toString()).toBe("ffmpeg");
    expect(f.calls.find((c) => c.cmd === "ffmpeg" && c.args.includes("librsvg"))!.args).toContain("96");
    expect((await app.inject({ method: "GET", url: "/v1/desktop/apps/kde-dolphin/icon", headers: auth })).json().error.code).toBe("agent.desktop.iconNotFound");
    expect((await app.inject({ method: "GET", url: "/v1/desktop/apps/hidden-tool/icon", headers: auth })).statusCode).toBe(404);
    await app.close();
  });

  it("SVG: rsvg-convert varsa o; hiçbiri yoksa SVG olduğu gibi", async () => {
    const fx = await fixtures();
    for (const [tools, type, tail] of [
      [["rsvg-convert", "ffmpeg"], "image/png", "rsvg-convert"],
      [[], "image/svg+xml", null],
    ] as const) {
      const { app, auth } = await hyprApp(fakeIo({ has: [...tools] }), fx.opts);
      const r = await app.inject({ method: "GET", url: "/v1/desktop/apps/foot/icon", headers: auth });
      expect(r.headers["content-type"]).toBe(type);
      if (tail) expect(r.rawPayload.subarray(PNG.length).toString()).toBe(tail);
      else expect(r.body).toContain("<svg");
      await app.close();
    }
  });

  it("küçük resim: ffmpeg yoksa PNG; Hyprland yoksa 503", async () => {
    const { app, auth } = await hyprApp(fakeIo({ has: [] }));
    expect((await app.inject({ method: "GET", url: "/v1/desktop/windows/0x55d1a0/thumb", headers: auth })).headers["content-type"]).toBe("image/png");
    await app.close();
    const off = await hyprApp(fakeIo({ noHypr: true }));
    const r = await off.app.inject({ method: "GET", url: "/v1/desktop/windows", headers: off.auth });
    expect(r.statusCode).toBe(503);
    expect(r.json().error.code).toBe("agent.desktop.noHyprland");
    await off.app.close();
  });
});

describe("kontrol oturumu ve yetki", () => {
  it("desktop kapalı: uçlar yok (404); control kapalı: oturum ve eylemler 403, okuma serbest", async () => {
    const plain = await testApp();
    for (const url of ["/v1/desktop/windows", "/v1/desktop/apps"]) expect((await plain.app.inject({ method: "GET", url, headers: plain.auth })).statusCode).toBe(404);
    expect((await plain.app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: plain.auth, payload: {} })).statusCode).toBe(404);
    await plain.app.close();

    const f = fakeIo();
    const { app, auth } = await hyprApp(f, {}, false);
    expect((await app.inject({ method: "GET", url: "/v1/desktop/windows", headers: auth })).statusCode).toBe(200);
    for (const [url, payload] of [
      ["/v1/desktop/control/session", {}],
      ["/v1/desktop/windows/0x55d1a0/focus", {}],
      ["/v1/desktop/workspace/2", {}],
      ["/v1/desktop/dpms/off", {}],
    ] as const) {
      const r = await app.inject({ method: "POST", url, headers: auth, payload });
      expect(r.statusCode, url).toBe(403);
      expect(r.json().error.code).toBe("agent.control.disabled");
    }
    expect(f.hyprctl()).toEqual([]);
    await app.close();
  });

  it("oturum: gösterge açılır, eylem belirteçle çalışır, uzatılır, süresi dolunca kapanır ve kenarlık geri döner", async () => {
    let t = 1_000_000;
    const f = fakeIo({ border: "ee33ccff ee00ff99 45deg", borderSize: 2 });
    const { app, auth, store } = await hyprApp(f, { now: () => t });
    const stateFile = indicatorStatePath(store.path);

    // A mutating call without a token is rejected.
    const noSession = await app.inject({ method: "POST", url: "/v1/desktop/windows/0x55d1a0/focus", headers: auth, payload: {} });
    expect(noSession.json().error.code).toBe("agent.control.sessionRequired");

    const start = await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} });
    expect(start.statusCode, start.body).toBe(200);
    const { token, expiresAt } = start.json();
    expect(token).toMatch(/^tpc_/);
    expect(Date.parse(expiresAt)).toBe(t + 15 * 60_000);
    expect(f.hyprctl()).toEqual(["keyword general:col.active_border 0xffff3b30 0xffff9f0a 45deg", "keyword general:border_size 3"]);
    expect(JSON.parse(await readFile(stateFile, "utf8"))).toEqual({ border: "0xee33ccff 0xee00ff99 45deg", size: 2 });
    expect(f.calls.find((c) => c.cmd === "notify-send")!.args).toContain("Tiphys uzaktan kontrol açık");

    const h = { ...auth, "x-tiphys-control": token };
    const act = (url: string, payload: object = {}, headers = h) => app.inject({ method: "POST", url, headers, payload });
    expect((await act("/v1/desktop/windows/0x55d1a0/focus")).json()).toEqual({ ok: true });
    expect((await act("/v1/desktop/windows/0x55d1a0/move-to-workspace", { workspace: 4 })).statusCode).toBe(200);
    expect((await act("/v1/desktop/windows/0x55d1a0/move-to-workspace")).statusCode).toBe(400);
    expect((await act("/v1/desktop/windows/0x55d1a0/fullscreen")).statusCode).toBe(200);
    expect((await act("/v1/desktop/windows/0x55d1a0/exec")).statusCode).toBe(400); // not in the allowed list
    expect((await act("/v1/desktop/windows/0x999/close")).statusCode).toBe(404);
    expect((await act("/v1/desktop/workspace/3")).statusCode).toBe(200);
    expect((await act("/v1/desktop/workspace/1;exec")).statusCode).toBe(400);
    expect((await act("/v1/desktop/dpms/off")).statusCode).toBe(200);
    expect((await act("/v1/desktop/windows/0x55d1a0/focus", {}, { ...auth, "x-tiphys-control": "tpc_yanlis" })).json().error.code).toBe("agent.control.sessionRequired");
    expect(f.hyprctl().slice(2)).toEqual([
      "dispatch focuswindow address:0x55d1a0",
      "dispatch movetoworkspacesilent 4,address:0x55d1a0",
      "--batch dispatch focuswindow address:0x55d1a0 ; dispatch fullscreen 0",
      "dispatch workspace 3",
      "dispatch dpms off",
    ]);

    // Extension: remaining time is at most 60 min.
    t += 10 * 60_000;
    const ext = (await app.inject({ method: "POST", url: "/v1/desktop/control/session/extend", headers: h, payload: { minutes: 15 } })).json();
    expect(Date.parse(ext.expiresAt)).toBe(t + 15 * 60_000);
    expect(Date.parse((await app.inject({ method: "POST", url: "/v1/desktop/control/session/extend", headers: h, payload: { minutes: 60 } })).json().expiresAt)).toBe(t + 60 * 60_000);

    // On expiry: actions are rejected, border colour and width return to their old values, the state file is deleted.
    t += 61 * 60_000;
    expect((await act("/v1/desktop/workspace/2")).json().error.code).toBe("agent.control.sessionRequired");
    expect(f.hyprctl().slice(-2)).toEqual(["keyword general:col.active_border 0xee33ccff 0xee00ff99 45deg", "keyword general:border_size 2"]);
    expect(existsSync(stateFile)).toBe(false);
    expect(f.calls.filter((c) => c.cmd === "notify-send").at(-1)!.args).toContain("Tiphys uzaktan kontrol kapandı");

    const events = (await app.inject({ method: "GET", url: "/v1/events", headers: auth })).json().events;
    expect(events.map((e: { key: string; params: object }) => [e.key, e.params])).toEqual([
      ["control.ended", { device: "Telefon", seconds: 71 * 60, reason: "expired" }],
      ["control.started", { device: "Telefon", minutes: 15 }],
    ]);
    expect(JSON.stringify(events)).not.toContain(token);
    await app.close();
  });

  it("Lua yapılandırmalı Hyprland: gösterge hl.config ile açılır/geri yüklenir, eylemler hl.dispatch, başlatma kaçışlı", async () => {
    let t = 1_000_000;
    const f = fakeIo({ lua: true, border: "ee33ccff ee00ff99 45deg", borderSize: 2 });
    const fx = await fixtures();
    const { app, auth } = await hyprApp(f, { ...fx.opts, now: () => t });
    const start = await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} });
    expect(start.statusCode, start.body).toBe(200);
    const h = { ...auth, "x-tiphys-control": start.json().token };
    const act = (url: string, payload: object = {}) => app.inject({ method: "POST", url, headers: h, payload });
    expect((await act("/v1/desktop/windows/0x55d1a0/pin")).statusCode).toBe(200);
    expect((await act("/v1/desktop/windows/0x55d1a0/move-to-workspace", { workspace: 4 })).statusCode).toBe(200);
    expect((await act("/v1/desktop/workspace/3")).statusCode).toBe(200);
    expect((await act("/v1/desktop/dpms/off")).statusCode).toBe(200);
    expect((await act("/v1/desktop/apps/firefox/launch")).statusCode).toBe(200);
    t += 16 * 60_000;
    expect((await act("/v1/desktop/workspace/2")).statusCode).toBe(403); // expired → restore
    expect(f.hyprctl()).toEqual([
      'eval hl.config({ general = { col = { active_border = { colors = { "0xffff3b30", "0xffff9f0a" }, angle = 45 } }, border_size = 3 } })',
      'eval hl.dispatch(hl.dsp.window.float({ window = "address:0x55d1a0", action = "enable" })); hl.dispatch(hl.dsp.window.pin({ window = "address:0x55d1a0", action = "toggle" }))',
      'eval hl.dispatch(hl.dsp.window.move({ window = "address:0x55d1a0", workspace = "4", follow = false }))',
      'eval hl.dispatch(hl.dsp.focus({ workspace = "3" }))',
      'eval hl.dispatch(hl.dsp.dpms({ action = "disable" }))',
      'eval hl.dispatch(hl.dsp.exec_cmd("gtk-launch firefox"))',
      'eval hl.config({ general = { col = { active_border = { colors = { "0xee33ccff", "0xee00ff99" }, angle = 45 } }, border_size = 2 } })',
    ]);
    // keyword or classic dispatch is never tried; the mode is probed once.
    expect(f.calls.filter((c) => c.cmd === "hyprctl" && ["keyword", "dispatch", "--batch"].includes(c.args[0]!))).toEqual([]);
    expect(f.calls.filter((c) => c.args.join(" ") === "eval return 1")).toHaveLength(1);
    await app.close();
  });

  it("control ayardan kapatılınca açık oturum hemen biter (kenarlık geri döner)", async () => {
    const f = fakeIo({ border: "ee33ccff ee00ff99 45deg", borderSize: 2 });
    const { app, auth } = await hyprApp(f);
    const { token } = (await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} })).json();
    const off = await app.inject({ method: "PATCH", url: "/v1/config", headers: auth, payload: { features: { control: false } } });
    expect(off.statusCode, off.body).toBe(200);
    expect(f.hyprctl().slice(-2)).toEqual(["keyword general:col.active_border 0xee33ccff 0xee00ff99 45deg", "keyword general:border_size 2"]);
    const h = { ...auth, "x-tiphys-control": token };
    expect((await app.inject({ method: "POST", url: "/v1/desktop/workspace/2", headers: h, payload: {} })).statusCode).toBe(403);
    await app.close();
  });

  it("tek oturum: başka cihaz 409, DELETE her cihaza açık, aynı cihaz yeniden açınca belirteç yenilenir", async () => {
    const f = fakeIo();
    const { app, auth, store } = await hyprApp(f);
    const other = newToken();
    await store.update((c) => {
      c.devices.push({ id: "tablet", name: "Tablet", tokenHash: hashToken(other), createdAt: new Date().toISOString() });
      return c;
    });
    const otherAuth = { authorization: `Bearer ${other}` };
    const a = (await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: { minutes: 5 } })).json();
    const busy = await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: otherAuth, payload: {} });
    expect(busy.statusCode).toBe(409);
    expect(busy.json().error).toEqual({ code: "agent.control.busy", params: { device: "Telefon" } });
    // Another device's token doesn't work even with its own header.
    expect((await app.inject({ method: "POST", url: "/v1/desktop/workspace/2", headers: { ...otherAuth, "x-tiphys-control": a.token }, payload: {} })).statusCode).toBe(403);
    const b = (await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} })).json();
    expect(b.token).not.toBe(a.token);
    expect((await app.inject({ method: "POST", url: "/v1/desktop/workspace/2", headers: { ...auth, "x-tiphys-control": a.token }, payload: {} })).statusCode).toBe(403);
    expect(f.hyprctl().filter((c) => c.startsWith("keyword general:col.active_border"))).toHaveLength(1); // PC indicator once
    expect((await app.inject({ method: "DELETE", url: "/v1/desktop/control/session", headers: otherAuth })).json()).toEqual({ ended: true });
    expect((await app.inject({ method: "DELETE", url: "/v1/desktop/control/session", headers: otherAuth })).json()).toEqual({ ended: false });
    expect((await app.inject({ method: "POST", url: "/v1/desktop/workspace/2", headers: { ...auth, "x-tiphys-control": b.token }, payload: {} })).statusCode).toBe(403);
    await app.close();
  });

  it("hız sınırı: panel çağrıları 5 sn'de 10, oturum açma dakikada 5", async () => {
    let t = 1_000_000;
    const f = fakeIo();
    const { app, auth } = await hyprApp(f, { now: () => t });
    const { token } = (await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} })).json();
    const h = { ...auth, "x-tiphys-control": token };
    const codes: number[] = [];
    for (let i = 0; i < 11; i++) codes.push((await app.inject({ method: "POST", url: "/v1/desktop/workspace/2", headers: h, payload: {} })).statusCode);
    expect(codes).toEqual([...Array(10).fill(200), 429]);
    t += 5000;
    expect((await app.inject({ method: "POST", url: "/v1/desktop/workspace/2", headers: h, payload: {} })).statusCode).toBe(200);
    const starts: number[] = [];
    for (let i = 0; i < 5; i++) starts.push((await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} })).statusCode);
    expect(starts).toEqual([200, 200, 200, 200, 429]); // the first one is above
    const rl = new RateLimit(2, 1000, () => t);
    expect([rl.take("a"), rl.take("a"), rl.take("a"), rl.take("b")]).toEqual([true, true, false, true]);
    await app.close();
  });

  it("uygulama başlatma: yalnız listedeki kimlik, gtk-launch Hyprland üzerinden", async () => {
    const fx = await fixtures();
    const f = fakeIo();
    const { app, auth } = await hyprApp(f, fx.opts);
    const { token } = (await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} })).json();
    const h = { ...auth, "x-tiphys-control": token };
    expect((await app.inject({ method: "POST", url: "/v1/desktop/apps/firefox/launch", headers: h, payload: {} })).json()).toEqual({ ok: true });
    expect(f.hyprctl().at(-1)).toBe("dispatch exec gtk-launch firefox");
    for (const id of ["hidden-tool", "yok", "firefox%3Brm%20-rf", "bad%3Bid"]) {
      expect((await app.inject({ method: "POST", url: `/v1/desktop/apps/${id}/launch`, headers: h, payload: {} })).statusCode, id).toBe(404);
    }
    expect(f.hyprctl().filter((c) => c.includes("exec"))).toHaveLength(1);
    await app.close();
    const noLauncher = await hyprApp(fakeIo({ has: [] }), fx.opts);
    const s = (await noLauncher.app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: noLauncher.auth, payload: {} })).json();
    const r = await noLauncher.app.inject({ method: "POST", url: "/v1/desktop/apps/foot/launch", headers: { ...noLauncher.auth, "x-tiphys-control": s.token }, payload: {} });
    expect(r.json().error).toEqual({ code: "agent.exec.commandMissing", params: { command: "gtk-launch" } });
    await noLauncher.app.close();
  });

  it("hyprctl hata dönerse 502; gösterge açılamazsa oturum açılmaz; ajan çöktüyse kenarlık açılışta geri döner", async () => {
    const f = fakeIo({ dispatchOut: "Invalid dispatcher\n" });
    const { app, auth, store } = await hyprApp(f);
    const { token } = (await app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: auth, payload: {} })).json();
    const r = await app.inject({ method: "POST", url: "/v1/desktop/workspace/2", headers: { ...auth, "x-tiphys-control": token }, payload: {} });
    expect(r.statusCode).toBe(502);
    expect(r.json().error.code).toBe("agent.desktop.hyprctlFailed");
    await app.close(); // on shutdown the session ends and the PC indicator is restored
    expect(f.hyprctl().slice(-2)).toEqual(["keyword general:col.active_border 0xffffffff 0deg", "keyword general:border_size 1"]);

    const off = await hyprApp(fakeIo({ noHypr: true }));
    const s = await off.app.inject({ method: "POST", url: "/v1/desktop/control/session", headers: off.auth, payload: {} });
    expect(s.statusCode).toBe(503);
    expect(s.json().error.code).toBe("agent.desktop.noHyprland");
    await off.app.close();

    // State file left over from a previous run: the new agent writes the old look back as soon as it starts.
    const stale = fakeIo();
    const again = await testApp((c) => {
      c.features.control = true;
      return c;
    });
    await again.app.close();
    await writeFile(indicatorStatePath(again.store.path), JSON.stringify({ border: "0xff112233 0deg", size: 4 }));
    const { buildApp } = await import("../src/server.ts");
    const app2 = await buildApp({ store: again.store, notifier: again.notifier, extraRoutes: [(a, ctx) => hyprRoutes(a, ctx, stale.io)] });
    await new Promise((res) => setTimeout(res, 50));
    expect(stale.hyprctl()).toEqual(["keyword general:col.active_border 0xff112233 0deg", "keyword general:border_size 4"]);
    expect(existsSync(indicatorStatePath(again.store.path))).toBe(false);
    await app2.close();
    void store;
  });

  it("ControlSessions: süre dolumu zamanlayıcısız da (expireIfDue) kapanır, gösterge hatası 503", async () => {
    let t = 0;
    const log: string[] = [];
    const ind: Indicator = { on: async () => void log.push("on"), off: async (i) => void log.push(`off:${i.reason}`) };
    const c = new ControlSessions({ indicator: ind, events: null, now: () => t });
    await c.start({ id: "p", name: "P" }, 1);
    expect(c.active?.device).toBe("p");
    t = 60_000;
    expect(c.active).toBeNull();
    await c.expireIfDue();
    expect(log).toEqual(["on", "off:expired"]);
    const bad = new ControlSessions({ indicator: { on: async () => Promise.reject(new Error("x")), off: async () => {} }, events: null });
    await expect(bad.start({ id: "p", name: "P" })).rejects.toMatchObject({ code: "agent.control.indicatorFailed", status: 503 });
    expect(bad.active).toBeNull();
  });
});
