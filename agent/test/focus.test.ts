// 11 App context: parsing Hyprland event lines, activewindow → focus, title coalescing, subscriber counting, polling
// + reconnecting while there is no socket, no socket/timer left after stopping. Fake socket and fake hyprctl; real
// Hyprland is never touched.
import { EventEmitter } from "node:events";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { DesktopApp } from "../src/desktop_apps.ts";
import { FocusWatcher, TITLE_MAX, parseActive, parseEvent, type FocusIo } from "../src/focus.ts";

class Sock extends EventEmitter {
  destroyed = false;
  readonly path: string;
  constructor(path: string) {
    super();
    this.path = path;
  }
  destroy() {
    if (this.destroyed) return;
    this.destroyed = true;
    setTimeout(() => this.emit("close"), 0);
  }
  lines(...l: string[]) {
    this.emit("data", Buffer.from(l.map((x) => `${x}\n`).join(""), "utf8"));
  }
}

const win = (address: string, cls: string, title = "t", extra: object = {}) => ({ address, class: cls, initialClass: cls, title, pid: 4242, workspace: { id: 2, name: "2" }, ...extra });

function fake(o: { failConnect?: () => boolean } = {}) {
  const sockets: Sock[] = [];
  let active: unknown = win("0xa1", "firefox", "Ana sayfa");
  let sig = "imza1";
  let reads = 0;
  const io: FocusIo = {
    exec: async (cmd, args) => {
      if (cmd !== "hyprctl" || args.join(" ") !== "-j activewindow") throw new Error(`beklenmeyen ${cmd} ${args}`);
      reads++;
      return { stdout: JSON.stringify(active), stderr: "", code: 0 };
    },
    hyprEnv: async () => ({ XDG_RUNTIME_DIR: "/run/user/1000", HYPRLAND_INSTANCE_SIGNATURE: sig }),
    connect: (path) => {
      const s = new Sock(path);
      sockets.push(s);
      const fail = o.failConnect?.() ?? false;
      setTimeout(() => {
        if (s.destroyed) return;
        if (fail) {
          s.emit("error", new Error("ENOENT"));
          s.destroyed = true;
          s.emit("close");
        } else s.emit("connect");
      }, 0);
      return s;
    },
  };
  return {
    io,
    sockets,
    get reads() {
      return reads;
    },
    set active(v: unknown) {
      active = v;
    },
    set sig(v: string) {
      sig = v;
    },
  };
}

const apps = [{ id: "firefox-esr", name: "Firefox", wmClass: "firefox-esr", icon: "firefox-esr" }, { id: "org.mozilla.firefox", name: "Firefox", wmClass: "firefox", icon: "firefox" }] as DesktopApp[];

describe("olay satırları", () => {
  it("odak, başlık, kapanış; diğerleri yok sayılır", () => {
    expect(parseEvent("activewindowv2>>55d0c0e0e9b0", null)).toBe("focus");
    expect(parseEvent("activewindowv2>>", "0x55d0c0e0e9b0")).toBe("focus"); // focus cleared
    expect(parseEvent("activewindowv2>>55d0c0e0e9b0", "0x55d0c0e0e9b0")).toBe("title"); // same window: coalesced like a title change
    expect(parseEvent("activewindowv2>>aaaa", "0x55d0c0e0e9b0")).toBe("focus");
    expect(parseEvent("windowtitlev2>>55d0c0e0e9b0,Yeni, başlık >> içinde", "0x55d0c0e0e9b0")).toBe("title");
    expect(parseEvent("windowtitlev2>>aaaa,Başka pencere", "0x55d0c0e0e9b0")).toBeNull();
    expect(parseEvent("closewindow>>55d0c0e0e9b0", "0x55d0c0e0e9b0")).toBe("focus");
    expect(parseEvent("closewindow>>bbbb", "0x55d0c0e0e9b0")).toBeNull();
    expect(parseEvent("activewindow>>firefox,Başlık", "0x1")).toBeNull();
    expect(parseEvent("workspacev2>>2,2", "0x1")).toBeNull();
    expect(parseEvent("çöp", "0x1")).toBeNull();
    expect(parseEvent("windowtitlev2>>1,x", null)).toBeNull();
  });

  it("activewindow JSON → odak: boş, sınırlı başlık, uygulama kimliği, bozuk adres", () => {
    expect(parseActive({})).toEqual({ address: null, class: "", initialClass: "", title: "", pid: null, workspace: null, appId: null });
    expect(parseActive(null).address).toBeNull();
    const f = parseActive(win("0xa1", "firefox", "x".repeat(500)), apps);
    expect(f).toEqual({ address: "0xa1", class: "firefox", initialClass: "firefox", title: "x".repeat(TITLE_MAX), pid: 4242, workspace: 2, appId: "org.mozilla.firefox" });
    expect(parseActive(win("0xa1", "firefox-esr"), apps).appId).toBe("firefox-esr");
    expect(parseActive(win("0xa1", "", "t", { initialClass: "kitty" })).class).toBe("kitty");
    expect(parseActive(win("0xZZ;rm", "x")).address).toBeNull();
  });
});

describe("FocusWatcher", () => {
  beforeEach(() => void vi.useFakeTimers());
  afterEach(() => void vi.useRealTimers());

  it("ilk abone soketi açar ve odağı alır; olayla değişir, aynısı tekrar gitmez; son abone her şeyi kapatır", async () => {
    const f = fake();
    const w = new FocusWatcher(f.io, { apps: async () => apps });
    const got: unknown[] = [];
    const off = w.subscribe((x) => got.push(x));
    await vi.advanceTimersByTimeAsync(5);
    expect(f.sockets.map((s) => s.path)).toEqual(["/run/user/1000/hypr/imza1/.socket2.sock"]);
    expect(w.socketConnected).toBe(true);
    expect(got).toEqual([expect.objectContaining({ address: "0xa1", class: "firefox", appId: "org.mozilla.firefox" })]);

    f.active = win("0xb2", "kitty", "~");
    f.sockets[0]!.lines("activewindow>>kitty,~", "activewindowv2>>b2");
    await vi.advanceTimersByTimeAsync(5);
    expect(got).toHaveLength(2);
    expect(got[1]).toMatchObject({ address: "0xb2", class: "kitty", workspace: 2, pid: 4242 });
    // Refocusing the same window: no change, no message.
    f.sockets[0]!.lines("activewindowv2>>b2");
    await vi.advanceTimersByTimeAsync(5);
    expect(got).toHaveLength(2);

    // A second subscriber gets the known focus right away; the listener stays when the first leaves.
    const got2: unknown[] = [];
    const off2 = w.subscribe((x) => got2.push(x));
    await vi.advanceTimersByTimeAsync(0);
    expect(got2).toEqual([got[1]]);
    expect(w.subscribers).toBe(2);
    off();
    off(); // releasing twice is harmless
    expect(w.subscribers).toBe(1);
    expect(f.sockets[0]!.destroyed).toBe(false);
    off2();
    expect(w.subscribers).toBe(0);
    expect(f.sockets[0]!.destroyed).toBe(true);
    expect(w.active).toBe(false);
    expect(vi.getTimerCount()).toBeLessThanOrEqual(1); // only the fake socket's close notification
    await vi.advanceTimersByTimeAsync(2000);
    expect(f.sockets).toHaveLength(1); // doesn't reconnect after being closed
    expect(vi.getTimerCount()).toBe(0);
  });

  it("odaktaki pencerenin başlık değişimleri 250 ms birleştirilir; başka pencereninkiler yok sayılır", async () => {
    const f = fake();
    const w = new FocusWatcher(f.io);
    const got: Array<{ title: string }> = [];
    w.subscribe((x) => got.push(x));
    await vi.advanceTimersByTimeAsync(5);
    const reads = f.reads;
    for (let i = 1; i <= 5; i++) {
      f.active = win("0xa1", "firefox", `Sayfa ${i}`);
      f.sockets[0]!.lines(`windowtitlev2>>a1,Sayfa ${i}`, "windowtitlev2>>ffff,başka");
      await vi.advanceTimersByTimeAsync(40);
    }
    expect(f.reads).toBe(reads); // not read yet (200 ms since the first change)
    await vi.advanceTimersByTimeAsync(60);
    expect(f.reads).toBe(reads + 1);
    expect(got.map((g) => g.title)).toEqual(["Ana sayfa", "Sayfa 5"]);
    // A focus change doesn't wait while a title read is pending.
    f.sockets[0]!.lines("windowtitlev2>>a1,x");
    f.active = win("0xc3", "mpv", "film.mkv");
    f.sockets[0]!.lines("activewindowv2>>c3");
    await vi.advanceTimersByTimeAsync(5);
    expect(got.at(-1)).toMatchObject({ address: "0xc3", class: "mpv" });
    // Partial line: processed once the line ending arrives.
    f.active = win("0xd4", "code");
    f.sockets[0]!.emit("data", Buffer.from("activewind"));
    await vi.advanceTimersByTimeAsync(5);
    expect(got.at(-1)).toMatchObject({ class: "mpv" });
    f.sockets[0]!.emit("data", Buffer.from("owv2>>d4\n"));
    await vi.advanceTimersByTimeAsync(5);
    expect(got.at(-1)).toMatchObject({ class: "code" });
    // The focused window closed → re-read (focus empty).
    f.active = {};
    f.sockets[0]!.lines("closewindow>>d4");
    await vi.advanceTimersByTimeAsync(5);
    expect(got.at(-1)).toMatchObject({ address: null, class: "" });
    w.stop();
    expect(w.active).toBe(false);
  });

  it("soket açılamazsa 1 sn'de bir yoklar ve artan aralıkla yeniden dener; bağlanınca yoklama durur", async () => {
    let fails = 3;
    const f = fake({ failConnect: () => fails-- > 0 });
    const logs: string[] = [];
    const w = new FocusWatcher(f.io, { log: (m) => logs.push(m) });
    const got: Array<{ class: string }> = [];
    w.subscribe((x) => got.push(x));
    await vi.advanceTimersByTimeAsync(5);
    expect(w.socketConnected).toBe(false);
    expect(got).toHaveLength(1);
    // Polling: a window change is seen within 1 s even without a socket.
    f.active = win("0xb2", "org.gnome.Nautilus");
    await vi.advanceTimersByTimeAsync(1000);
    expect(got.at(-1)).toMatchObject({ class: "org.gnome.Nautilus" });
    // Connection attempts: 0, +1 s, +2 s, +4 s (the fourth succeeds).
    expect(f.sockets).toHaveLength(2);
    await vi.advanceTimersByTimeAsync(2000);
    expect(f.sockets).toHaveLength(3);
    await vi.advanceTimersByTimeAsync(4000);
    expect(f.sockets).toHaveLength(4);
    expect(w.socketConnected).toBe(true);
    expect(logs).toEqual(["Hyprland olay soketi açılamadı, odak yoklanıyor"]); // title/class aren't logged
    const reads = f.reads;
    await vi.advanceTimersByTimeAsync(5000);
    expect(f.reads).toBe(reads); // no polling while the socket is up
    w.stop();
    await vi.advanceTimersByTimeAsync(60_000);
    expect(f.sockets).toHaveLength(4);
    expect(vi.getTimerCount()).toBe(0);
  });

  it("soket kapanırsa (Hyprland yeniden başladı) yeni imzayla yeniden bağlanır", async () => {
    const f = fake();
    const w = new FocusWatcher(f.io);
    w.subscribe(() => {});
    await vi.advanceTimersByTimeAsync(5);
    f.sig = "imza2";
    f.sockets[0]!.emit("close");
    await vi.advanceTimersByTimeAsync(1005);
    expect(f.sockets.map((s) => s.path.split("/")[5])).toEqual(["imza1", "imza2"]);
    expect(w.socketConnected).toBe(true);
    w.stop();
    expect(f.sockets.every((s) => s.destroyed)).toBe(true);
  });

  it("okuma sürerken durdurulursa bildirim gitmez, zamanlayıcı kalmaz; yeniden abone olunca yine çalışır", async () => {
    const f = fake();
    let release: () => void = () => {};
    const slow: FocusIo = {
      ...f.io,
      exec: async (cmd, args, opts) => {
        await new Promise<void>((r) => (release = r));
        return f.io.exec(cmd, args, opts);
      },
    };
    const w = new FocusWatcher(slow);
    const got: unknown[] = [];
    const off = w.subscribe((x) => got.push(x));
    await vi.advanceTimersByTimeAsync(5);
    off();
    release();
    await vi.advanceTimersByTimeAsync(5);
    expect(got).toEqual([]);
    expect(w.active).toBe(false);
    await vi.advanceTimersByTimeAsync(5000);
    expect(vi.getTimerCount()).toBe(0);
    const off2 = w.subscribe((x) => got.push(x));
    await vi.advanceTimersByTimeAsync(5);
    release();
    await vi.advanceTimersByTimeAsync(5);
    expect(got).toHaveLength(1);
    off2();
  });
});
