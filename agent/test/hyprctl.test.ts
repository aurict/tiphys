// Hyprland command adapter: mode detection, classic and Lua command strings (exact), Lua string escaping and
// validation. Uses a fake runner; real Hyprland is never touched.
import { describe, expect, it } from "vitest";
import { AppError } from "../src/errors.ts";
import { Hyprctl, LAUNCH_ID, dispatchArgs, gradientLua, legacyDispatch, lookArgs, luaDispatch, luaString, type HyprCmd } from "../src/hyprctl.ts";

describe("Lua dizge kaçışı", () => {
  it("tırnak, ters bölü, satır sonu, denetim ve ASCII dışı baytlar kaçılır; çıktı yalnız yazdırılabilir ASCII", () => {
    expect(luaString("firefox")).toBe('"firefox"');
    expect(luaString('a"b')).toBe('"a\\"b"');
    expect(luaString("a\\b")).toBe('"a\\\\b"');
    expect(luaString("x\ny\r\u0000")).toBe('"x\\010y\\013\\000"');
    expect(luaString('"); os.execute("rm -rf ~") --')).toBe('"\\"); os.execute(\\"rm -rf ~\\") --"');
    expect(luaString("]]..[[")).toBe('"]]..[["');
    expect(luaString("ğ")).toBe('"\\196\\159"'); // UTF-8 bytes
    for (const s of ["a\u007f", "çok\tsatır\n", "\\\\\"\""]) expect(luaString(s)).toMatch(/^"[\x20-\x7e]*"$/);
  });

  it("uygulama kimliği ve parametre doğrulaması", () => {
    for (const ok of ["firefox", "org.gnome.Nautilus", "code-url-handler", "steam_app_1"]) expect(LAUNCH_ID.test(ok)).toBe(true);
    for (const bad of ["", "-x", ".x", "a b", "a;b", 'a"b', "a+b", "a/b", "ğ", "a\nb", "$(x)"]) expect(LAUNCH_ID.test(bad), bad).toBe(false);
    const bad: HyprCmd[] = [
      { op: "launch", appId: 'x"); os.execute("id' },
      { op: "focusWindow", address: '0x1" }) hl.exit() --' },
      { op: "moveToWorkspace", address: "0x1", workspace: 1.5 },
      { op: "workspace", workspace: 0 },
      { op: "cursor", x: 1.5, y: 0 },
    ];
    for (const c of bad) {
      expect(() => luaDispatch(c), JSON.stringify(c)).toThrow(AppError);
      expect(() => legacyDispatch(c), JSON.stringify(c)).toThrow(AppError);
    }
  });
});

describe("komut dizgeleri", () => {
  const all: HyprCmd[] = [
    { op: "focusWindow", address: "0xab" },
    { op: "closeWindow", address: "0xab" },
    { op: "fullscreen", address: "0xab" },
    { op: "toggleFloat", address: "0xab" },
    { op: "setFloat", address: "0xab" },
    { op: "pin", address: "0xab" },
    { op: "moveToWorkspace", address: "0xab", workspace: 3 },
    { op: "workspace", workspace: 7 },
    { op: "dpms", on: false },
    { op: "dpms", on: true },
    { op: "launch", appId: "org.gnome.Nautilus" },
    { op: "cursor", x: 10, y: -20 },
  ];

  it("klasik", () => {
    expect(all.map((c) => legacyDispatch(c).join(" "))).toEqual([
      "focuswindow address:0xab",
      "closewindow address:0xab",
      "fullscreen 0",
      "togglefloating address:0xab",
      "setfloating address:0xab",
      "pin address:0xab",
      "movetoworkspacesilent 3,address:0xab",
      "workspace 7",
      "dpms off",
      "dpms on",
      "exec gtk-launch org.gnome.Nautilus",
      "movecursor 10 -20",
    ]);
    expect(dispatchArgs("legacy", [all[7]!])).toEqual(["dispatch", "workspace", "7"]);
    expect(dispatchArgs("legacy", [all[0]!, all[2]!])).toEqual(["--batch", "dispatch focuswindow address:0xab ; dispatch fullscreen 0"]);
  });

  it("Lua", () => {
    expect(all.map(luaDispatch)).toEqual([
      'hl.dsp.focus({ window = "address:0xab" })',
      'hl.dsp.window.close({ window = "address:0xab" })',
      'hl.dsp.window.fullscreen({ window = "address:0xab", mode = "fullscreen", action = "toggle" })',
      'hl.dsp.window.float({ window = "address:0xab", action = "toggle" })',
      'hl.dsp.window.float({ window = "address:0xab", action = "enable" })',
      'hl.dsp.window.pin({ window = "address:0xab", action = "toggle" })',
      'hl.dsp.window.move({ window = "address:0xab", workspace = "3", follow = false })',
      'hl.dsp.focus({ workspace = "7" })',
      'hl.dsp.dpms({ action = "disable" })',
      'hl.dsp.dpms({ action = "enable" })',
      'hl.dsp.exec_cmd("gtk-launch org.gnome.Nautilus")',
      "hl.dsp.cursor.move({ x = 10, y = -20 })",
    ]);
    expect(dispatchArgs("lua", [all[0]!, all[2]!])).toEqual([
      "eval",
      'hl.dispatch(hl.dsp.focus({ window = "address:0xab" })); hl.dispatch(hl.dsp.window.fullscreen({ window = "address:0xab", mode = "fullscreen", action = "toggle" }))',
    ]);
    expect(() => dispatchArgs("lua", [])).toThrow(AppError);
  });

  it("kenarlık: klasik keyword, Lua hl.config (gradyan tablosu); geçersiz değer reddedilir", () => {
    expect(lookArgs("legacy", { border: "0xffff3b30 0xffff9f0a 45deg", size: 3 })).toEqual([
      ["keyword", "general:col.active_border", "0xffff3b30 0xffff9f0a 45deg"],
      ["keyword", "general:border_size", "3"],
    ]);
    expect(lookArgs("legacy", { border: "0xffffffff 0deg" })).toEqual([["keyword", "general:col.active_border", "0xffffffff 0deg"]]);
    expect(lookArgs("lua", { border: "0xffff3b30 0xffff9f0a 45deg", size: 3 })).toEqual([
      ["eval", 'hl.config({ general = { col = { active_border = { colors = { "0xffff3b30", "0xffff9f0a" }, angle = 45 } }, border_size = 3 } })'],
    ]);
    expect(lookArgs("lua", { border: "0xFFFFFFFF 0deg" })).toEqual([["eval", 'hl.config({ general = { col = { active_border = { colors = { "0xffffffff" }, angle = 0 } } } })']]);
    expect(gradientLua("0xee33ccff")).toBe('{ colors = { "0xee33ccff" } }');
    for (const bad of ["", "rgba(1,2,3)", '0xffffffff"} } })', "0xffffffff 0deg 45deg", "45deg", "ffffffff"]) {
      expect(() => gradientLua(bad), bad).toThrow(AppError);
      expect(() => lookArgs("legacy", { border: bad }), bad).toThrow(AppError);
    }
    expect(() => lookArgs("lua", { border: "0xffffffff", size: 1.5 })).toThrow(AppError);
  });
});

describe("kip algılama ve çalıştırma", () => {
  function fake(evalOut: { stdout: string; code: number }, out = "ok\n") {
    const calls: string[] = [];
    let sig = "a";
    const h = new Hyprctl(
      async (cmd, args) => {
        calls.push(`${cmd} ${args.join(" ")}`);
        if (args[0] === "eval" && args[1] === "return 1") return { ...evalOut, stderr: "" };
        return { stdout: out, stderr: "", code: 0 };
      },
      async () => ({ HYPRLAND_INSTANCE_SIGNATURE: sig }),
    );
    return { h, calls, setSig: (s: string) => (sig = s) };
  }

  it("eval 'return 1' → ok ise Lua; yoksa klasik; imza başına bir kez yoklanır", async () => {
    const lua = fake({ stdout: "ok\n", code: 0 });
    expect(await lua.h.mode()).toBe("lua");
    await lua.h.dispatch([{ op: "workspace", workspace: 2 }]);
    await lua.h.setLook({ border: "0xffffffff 0deg", size: 1 });
    expect(lua.calls).toEqual([
      "hyprctl eval return 1",
      'hyprctl eval hl.dispatch(hl.dsp.focus({ workspace = "2" }))',
      'hyprctl eval hl.config({ general = { col = { active_border = { colors = { "0xffffffff" }, angle = 0 } }, border_size = 1 } })',
    ]);
    lua.setSig("b"); // Hyprland restarted: probed again
    await lua.h.mode();
    expect(lua.calls.filter((c) => c === "hyprctl eval return 1")).toHaveLength(2);

    const legacy = fake({ stdout: "unknown request\n", code: 0 });
    expect(await legacy.h.mode()).toBe("legacy");
    await legacy.h.dispatch([{ op: "workspace", workspace: 2 }]);
    expect(legacy.calls).toEqual(["hyprctl eval return 1", "hyprctl dispatch workspace 2"]);
    // A transient error (socket busy) isn't cached: the next call probes again.
    const busy = fake({ stdout: "", code: 1 });
    expect(await busy.h.mode()).toBe("legacy");
    await busy.h.mode();
    expect(busy.calls.filter((c) => c === "hyprctl eval return 1")).toHaveLength(2);
  });

  it("'ok' dışı yanıt hata: dağıtıcı 502, gösterge 503", async () => {
    const f = fake({ stdout: "ok\n", code: 0 }, "error: something\n");
    await expect(f.h.dispatch([{ op: "dpms", on: true }])).rejects.toMatchObject({ code: "agent.desktop.hyprctlFailed", status: 502 });
    await expect(f.h.setLook({ border: "0xffffffff" })).rejects.toMatchObject({ code: "agent.control.indicatorFailed", status: 503 });
  });
});
