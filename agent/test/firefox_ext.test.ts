// 11.2/11.3 Pure logic of the Firefox extension (firefox/src): URL filters, tab mapping, operations, merging, the
// native messaging connection and the page script's text/password checks. Uses a fake `browser` object; no Firefox
// needed.
import { readFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { runInNewContext } from "node:vm";
import { describe, expect, it } from "vitest";

const SRC = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "firefox", "src");
const lib = await import(pathToFileURL(join(SRC, "lib", "protocol.js")).href);
const fav = await import(pathToFileURL(join(SRC, "lib", "favicon.js")).href);

type Fn = (...a: any[]) => any;
function event() {
  const fns: Fn[] = [];
  return { addListener: (f: Fn) => fns.push(f), fire: (...a: unknown[]) => fns.forEach((f) => f(...a)), fns };
}

const tab = (o: Record<string, unknown>) => ({ id: 1, windowId: 1, index: 0, title: "Sekme", url: "https://example.com/", pinned: false, audible: false, mutedInfo: { muted: false }, active: false, lastAccessed: 1000, incognito: false, ...o });

function fakeBrowser(o: { tabs?: any[]; granted?: boolean; page?: unknown; execThrows?: boolean } = {}) {
  const tabs = o.tabs ?? [tab({ id: 1 }), tab({ id: 2, windowId: 2, index: 0, title: "Gizli", incognito: true }), tab({ id: 3, index: 1, url: "moz-extension://x/y", pinned: true, mutedInfo: { muted: true }, favIconUrl: "https://example.com/favicon.ico" })];
  const calls: unknown[][] = [];
  const posted: any[] = [];
  const ports: any[] = [];
  const b = {
    calls,
    posted,
    ports,
    tabs: {
      query: async () => tabs,
      get: async (id: number) => {
        const t = tabs.find((x) => x.id === id);
        if (!t) throw new Error("yok");
        return t;
      },
      create: async (x: unknown) => (calls.push(["create", x]), { id: 99, windowId: 1 }),
      update: async (id: number, x: unknown) => void calls.push(["update", id, x]),
      remove: async (ids: number[]) => void calls.push(["remove", ids]),
      reload: async (id: number) => void calls.push(["reload", id]),
      goBack: async (id: number) => void calls.push(["back", id]),
      goForward: async (id: number) => void calls.push(["forward", id]),
      onCreated: event(),
      onUpdated: event(),
      onRemoved: event(),
      onActivated: event(),
      onAttached: event(),
      onDetached: event(),
    },
    windows: { update: async (id: number, x: unknown) => void calls.push(["window", id, x]) },
    sessions: {
      getRecentlyClosed: async () => [{ tab: { sessionId: "s1" } }],
      restore: async (sid: string) => void calls.push(["restore", sid]),
    },
    permissions: { contains: async () => o.granted ?? false, onAdded: event(), onRemoved: event() },
    scripting: {
      executeScript: async (x: { files?: string[]; args?: unknown[] }) => {
        if (o.execThrows) throw new Error("Missing host permission");
        calls.push(["exec", x.files ?? x.args]);
        return [{ result: x.files ? undefined : (o.page ?? { ok: true }) }];
      },
    },
    runtime: {
      getManifest: () => ({ version: "0.1.0" }),
      connectNative: (name: string) => {
        const p = { name, disconnected: false, onMessage: event(), onDisconnect: event(), postMessage: (m: unknown) => posted.push(m), disconnect: () => void (p.disconnected = true) };
        ports.push(p);
        return p;
      },
    },
  };
  return b;
}

function fakeTimers() {
  const q: Array<{ fn: Fn; ms: number; id: number }> = [];
  let n = 0;
  return {
    q,
    setTimeout: (fn: Fn, ms: number) => (q.push({ fn, ms, id: ++n }), n),
    clearTimeout: (id: number) => {
      const i = q.findIndex((x) => x.id === id);
      if (i >= 0) q.splice(i, 1);
    },
    run() {
      const all = q.splice(0);
      all.forEach((x) => x.fn());
      return all.map((x) => x.ms);
    },
  };
}
const flush = () => new Promise((r) => setTimeout(r, 0));

describe("eklenti: süzgeçler ve eşleme", () => {
  it("raporlanan adres yalnız http/https/file/about; yeni sekme yalnız http/https", () => {
    for (const u of ["https://a.b/c?d", "http://x/", "file:///home/x.pdf", "about:blank"]) expect(lib.reportUrl(u)).toBe(u);
    for (const u of ["moz-extension://id/p.html", "view-source:https://a", "data:text/html,x", "javascript:1", "garip", 42, null]) expect(lib.reportUrl(u)).toBeNull();
    expect(lib.createUrl("https://örnek.com/a")).toBe("https://xn--rnek-4qa.com/a");
    for (const u of ["file:///etc/passwd", "about:config", "javascript:alert(1)", "https://a b", "https://x\n", "x".repeat(5000)]) expect(lib.createUrl(u)).toBeNull();
  });

  it("sekme listesi: gizli pencere yok, sıralı, favicon yalnız data:", async () => {
    const b = fakeBrowser();
    const seen: unknown[] = [];
    const tabs = await lib.listTabs(b, async (u: unknown) => (seen.push(u), u ? "data:image/png;base64,AA==" : null));
    expect(tabs.map((t: any) => t.id)).toEqual([1, 3]);
    expect(tabs[1]).toEqual({ id: 3, windowId: 1, index: 1, title: "Sekme", url: null, pinned: true, audible: false, muted: true, active: false, lastAccessed: 1000, favicon: "data:image/png;base64,AA==" });
    const real = fav.makeFavicon({});
    expect(await real("https://example.com/favicon.ico")).toBeNull(); // remote icons aren't downloaded
  });

  it("sekme listesi UTF-8 bayta göre sığdırılır: favicon → uzun adres/başlık → sondaki sekmeler", async () => {
    const big = (i: number) => tab({ id: i, index: i, title: "ş".repeat(400), url: `https://a.example/${"ğ".repeat(3000)}`, favIconUrl: "x" });
    const b = fakeBrowser({ tabs: Array.from({ length: 300 }, (_, i) => big(i)) });
    const tabs = await lib.listTabs(b, async () => "data:image/png;base64," + "A".repeat(2000));
    // Measured by String.length it would seem to fit; it must be under the limit in UTF-8 bytes.
    expect(lib.jsonBytes(tabs)).toBeLessThanOrEqual(lib.SOFT_LIMIT);
    expect(tabs.length).toBeGreaterThan(100);
    expect(tabs.every((t: any) => t.favicon === null)).toBe(true);
    const few = await lib.listTabs(fakeBrowser({ tabs: [tab({ id: 1, favIconUrl: "x" })] }), async () => "data:image/png;base64,AA==");
    expect(few[0].favicon).toBe("data:image/png;base64,AA=="); // a small list is left alone
    // Many tabs: the last ones are dropped, the first ones stay.
    const many = Array.from({ length: 1000 }, (_, i) => ({ id: i, windowId: 1, index: i, title: "ç".repeat(500), url: null, pinned: false, audible: false, muted: false, active: false, lastAccessed: 1, favicon: null }));
    const fit = lib.fitTabs(many, 100_000);
    expect(lib.jsonBytes(fit)).toBeLessThanOrEqual(100_000);
    expect(fit[0].id).toBe(0);
  });

  it("favicon: data: çözülür ve 32 px'e küçültülür; bozuk/SVG → null; önbellek", async () => {
    expect(fav.decodeDataUrl("data:image/png;base64,iVBO")).toMatchObject({ mime: "image/png" });
    expect(fav.decodeDataUrl("data:text/html;base64,AA==")).toBeNull();
    expect(fav.decodeDataUrl("data:image/svg+xml,%3Csvg%2F%3E")!.bytes.length).toBe(6);
    expect(fav.fitSize(64, 32)).toEqual({ w: 32, h: 16 });
    expect(fav.fitSize(16, 16)).toEqual({ w: 16, h: 16 });
    const sizes: number[][] = [];
    let bitmaps = 0;
    const g = {
      createImageBitmap: async (blob: Blob) => {
        bitmaps++;
        if (blob.type === "image/svg+xml") throw new Error("desteklenmiyor");
        return { width: 64, height: 64, close() {} };
      },
      OffscreenCanvas: class {
        constructor(w: number, h: number) {
          sizes.push([w, h]);
        }
        getContext() {
          return { drawImage() {} };
        }
        async convertToBlob() {
          return new Blob([new Uint8Array([1, 2, 3])], { type: "image/png" });
        }
      },
    };
    const f = fav.makeFavicon(g);
    const u = "data:image/png;base64,iVBORw0KGgo=";
    expect(await f(u)).toBe("data:image/png;base64,AQID");
    expect(await f(u)).toBe("data:image/png;base64,AQID");
    expect(bitmaps).toBe(1);
    expect(sizes).toEqual([[32, 32]]);
    expect(await f("data:image/svg+xml,%3Csvg%2F%3E")).toBeNull();
  });
});

describe("eklenti: işlemler", () => {
  const req = (b: any, op: string, args: object = {}) => lib.handleRequest(b, { id: 1, op, args });

  it("sekme eylemleri; gizli/olmayan sekme tabNotFound; bilinmeyen işlem badRequest", async () => {
    const b = fakeBrowser();
    expect(await req(b, "tabs.activate", { id: 1 })).toEqual({ type: "res", id: 1, ok: true, result: { title: "Sekme" } });
    expect(b.calls.slice(0, 2)).toEqual([["update", 1, { active: true }], ["window", 1, { focused: true }]]);
    expect(await req(b, "tabs.activate", { id: 2 })).toMatchObject({ ok: false, error: "tabNotFound" });
    expect(await req(b, "tabs.activate", { id: 77 })).toMatchObject({ ok: false, error: "tabNotFound" });
    expect(await req(b, "tabs.activate", { id: "1" })).toMatchObject({ ok: false, error: "badRequest" });
    expect(await req(b, "tabs.close", { ids: [1, 2] })).toMatchObject({ ok: false, error: "tabNotFound" });
    expect(b.calls.some((c) => c[0] === "remove")).toBe(false); // none get closed
    expect(await req(b, "tabs.close", { ids: [1, 3] })).toMatchObject({ ok: true });
    expect(await req(b, "tabs.pin", { id: 3 })).toMatchObject({ ok: true, result: { pinned: false } });
    expect(await req(b, "tabs.mute", { id: 3 })).toMatchObject({ ok: true, result: { muted: false } });
    for (const op of ["tabs.reload", "tabs.back", "tabs.forward"]) expect(await req(b, op, { id: 1 })).toMatchObject({ ok: true });
    expect(await req(b, "sessions.restore")).toMatchObject({ ok: true });
    expect(await req(b, "tabs.create", { url: "https://a.example/" })).toEqual({ type: "res", id: 1, ok: true, result: { id: 99 } });
    expect(await req(b, "tabs.create", { url: "file:///etc/passwd" })).toMatchObject({ ok: false, error: "badUrl" });
    expect(await req(b, "eval", {})).toMatchObject({ ok: false, error: "badRequest" });
    // Inherited keys are not operations (OPS[msg.op] must not reach into the prototype).
    for (const op of ["constructor", "__proto__", "toString", "hasOwnProperty", 5]) expect(await req(b, op as string, {}), String(op)).toMatchObject({ ok: false, error: "badRequest" });
    expect(b.calls.filter((c) => c[0] !== "window")).toEqual([
      ["update", 1, { active: true }],
      ["remove", [1, 3]],
      ["update", 3, { pinned: false }],
      ["update", 3, { muted: false }],
      ["reload", 1],
      ["back", 1],
      ["forward", 1],
      ["restore", "s1"],
      ["create", { url: "https://a.example/", active: true }],
    ]);
  });

  it("sayfa işlemleri: izin, sayfa türü, enjeksiyon ve hata kodları", async () => {
    expect(await req(fakeBrowser(), "page.reader", { id: 1 })).toMatchObject({ ok: false, error: "permissionRequired" });
    const b = fakeBrowser({ granted: true, page: { title: "T", text: "metin" } });
    expect(await req(b, "page.reader", { id: 1 })).toMatchObject({ ok: true, result: { title: "T", text: "metin" } });
    expect(b.calls).toEqual([["exec", ["vendor/Readability.js", "content/page.js"]], ["exec", ["reader", {}]]]);
    expect(await req(b, "page.reader", { id: 3 })).toMatchObject({ ok: false, error: "unsupported" }); // moz-extension:
    expect(await req(b, "page.reader", { id: 2 })).toMatchObject({ ok: false, error: "tabNotFound" }); // private
    const pw = fakeBrowser({ granted: true, page: { error: "passwordField" } });
    expect(await req(pw, "page.text", { id: 1, text: "x" })).toMatchObject({ ok: false, error: "passwordField" });
    expect(pw.calls).toEqual([["exec", ["content/page.js"]], ["exec", ["text", { text: "x" }]]]);
    expect(await req(fakeBrowser({ granted: true, execThrows: true }), "page.scroll", { id: 1, fraction: 1 })).toMatchObject({ ok: false, error: "unsupported" });
  });
});

describe("eklenti: bağlantı ve olaylar", () => {
  it("birleştirici: süre içindeki dürtmeler tek çağrı", () => {
    const t = fakeTimers();
    let n = 0;
    const c = new lib.Coalescer(() => n++, 300, t);
    c.poke();
    c.poke();
    c.poke();
    expect(t.run()).toEqual([300]);
    expect(n).toBe(1);
    c.poke();
    c.cancel();
    expect(t.run()).toEqual([]);
  });

  it("varsayılan zamanlayıcı setTimeout'u yöntem olarak çağırmaz (tarayıcıda 'interface Window' hatası)", () => {
    const orig = globalThis.setTimeout;
    const seen: unknown[] = [];
    globalThis.setTimeout = function (this: unknown) {
      seen.push(this);
      return 0;
    } as unknown as typeof setTimeout;
    try {
      new lib.Coalescer(() => {}, 300).poke();
    } finally {
      globalThis.setTimeout = orig;
    }
    expect(seen).toEqual([undefined]);
  });

  it("hello yalnız ajan bağlanınca; istek → yanıt; olaylar 300 ms birleştirilir; gizli sekme olayı yok sayılır", async () => {
    const b = fakeBrowser({ granted: true });
    const t = fakeTimers();
    const br = new lib.Bridge(b, { timers: t });
    br.start();
    const port = b.ports[0];
    expect(port.name).toBe("dev.tiphys.bridge");
    b.tabs.onCreated.fire(tab({ id: 4 }));
    t.run();
    await flush();
    expect(b.posted).toEqual([]); // no events are sent while the agent is absent
    port.onMessage.fire({ type: "host", agent: true });
    await flush();
    expect(b.posted).toEqual([{ type: "hello", version: 1, ext: "0.1.0", permissions: { content: true } }]);
    port.onMessage.fire({ type: "req", id: 5, op: "tabs.reload", args: { id: 1 } });
    await flush();
    expect(b.posted.at(-1)).toEqual({ type: "res", id: 5, ok: true, result: {} });
    b.tabs.onUpdated.fire(2, { title: "x" }, tab({ id: 2, incognito: true }));
    b.tabs.onUpdated.fire(1, { status: "loading" }, tab({ id: 1 }));
    expect(t.q).toHaveLength(0);
    b.tabs.onUpdated.fire(1, { title: "y" }, tab({ id: 1 }));
    b.tabs.onRemoved.fire(3, {});
    b.tabs.onActivated.fire({ tabId: 1 });
    expect(t.run()).toEqual([300]);
    await flush();
    await flush();
    const ev = b.posted.at(-1);
    expect(ev.type).toBe("event");
    expect(ev.tabs.map((x: any) => x.id)).toEqual([1, 3]);
    b.permissions.onRemoved.fire({});
    await flush();
    expect(b.posted.at(-1)).toEqual({ type: "permissions", permissions: { content: true } });
  });

  it("ajan hello'yu reddederse (busy/version) bağlantı kapanır, 5 sn → 10 dk artan aralıkla yeniden denenir", async () => {
    const b = fakeBrowser();
    const t = fakeTimers();
    const br = new lib.Bridge(b, { timers: t });
    br.start();
    const delays: number[] = [];
    for (let i = 0; i < 9; i++) {
      const port = b.ports.at(-1);
      port.onMessage.fire({ type: "host", agent: true }); // the helper sends this on every connect
      await flush();
      port.onMessage.fire({ type: "error", code: "busy" });
      await flush();
      expect(port.disconnected).toBe(true);
      expect(br.status).toEqual({ host: false, agent: false });
      delays.push(...t.run());
    }
    expect(delays).toEqual([5000, 10000, 20000, 40000, 80000, 160000, 320000, 600000, 600000]);
    // We were accepted (the agent sent a request): the backoff is reset.
    const port = b.ports.at(-1);
    port.onMessage.fire({ type: "host", agent: true });
    port.onMessage.fire({ type: "req", id: 1, op: "tabs.reload", args: { id: 1 } });
    await flush();
    port.onMessage.fire({ type: "error", code: "version" });
    await flush();
    expect(t.run()).toEqual([5000]);
    // A late message from the old connection is ignored.
    b.ports[0].onMessage.fire({ type: "error", code: "busy" });
    expect(t.q).toHaveLength(0);
  });

  it("1 MB'a yaklaşan yanıt yerine hata gider (yardımcı çerçeveyi atmasın)", async () => {
    const b = fakeBrowser({ tabs: [tab({ id: 1 })], granted: true, page: { title: "T", text: "ğ".repeat(500_000) } });
    const t = fakeTimers();
    const br = new lib.Bridge(b, { timers: t });
    br.start();
    const port = b.ports[0];
    port.onMessage.fire({ type: "host", agent: true });
    await flush();
    port.onMessage.fire({ type: "req", id: 9, op: "page.reader", args: { id: 1 } });
    await flush();
    await flush();
    expect(b.posted.at(-1)).toEqual({ type: "res", id: 9, ok: false, error: "failed" });
  });

  it("yardımcı koparsa 5 sn'den başlayıp 60 sn'ye kadar artan aralıkla yeniden bağlanır", () => {
    const b = fakeBrowser();
    const t = fakeTimers();
    const br = new lib.Bridge(b, { timers: t });
    br.start();
    const delays: number[] = [];
    for (let i = 0; i < 6; i++) {
      b.ports.at(-1).onDisconnect.fire();
      delays.push(...t.run());
    }
    expect(delays).toEqual([5000, 10000, 20000, 40000, 60000, 60000]);
    expect(b.ports).toHaveLength(7);
    expect(br.status).toEqual({ host: true, agent: false });
  });
});

describe("eklenti: sayfa betiği", async () => {
  const code = await readFile(join(SRC, "content", "page.js"), "utf8");
  const load = (doc: unknown = {}) => {
    const sandbox: Record<string, any> = { document: doc, TextEncoder };
    runInNewContext(code, sandbox);
    return sandbox;
  };
  const el = (name: string, kids: any[] = []) => {
    const n: any = { nodeType: 1, nodeName: name, childNodes: kids, parentNode: null, previousSibling: null };
    kids.forEach((k, i) => {
      k.parentNode = n;
      k.previousSibling = kids[i - 1] ?? null;
    });
    return n;
  };
  const txt = (s: string) => ({ nodeType: 3, nodeValue: s });

  it("düz metin: başlıklar, listeler, bloklar; form ve betik atlanır", () => {
    const p = load();
    const root = el("DIV", [
      el("H2", [txt("Başlık")]),
      el("P", [txt("Birinci   paragraf\n devam.")]),
      el("UL", [el("LI", [txt("elma")]), el("LI", [txt("armut")])]),
      el("OL", [el("LI", [txt("bir")]), el("LI", [txt("iki")])]),
      el("SCRIPT", [txt("alert(1)")]),
      el("INPUT", []),
      el("TEXTAREA", [txt("form değeri")]),
      el("P", [txt("satır"), el("BR"), txt("sonu")]),
    ]);
    expect(p.tiphysToText(root)).toBe("## Başlık\n\nBirinci paragraf devam.\n\n• elma\n• armut\n\n1. bir\n2. iki\n\nsatır\nsonu");
  });

  it("şifre alanı: odakta ya da doluysa okuma/yazma reddedilir; metin 200 KB'de kesilir", () => {
    const pw = { value: "" };
    const doc = { activeElement: null as unknown, querySelectorAll: () => [pw] };
    const p = load(doc);
    expect(p.tiphysPasswordActive(doc)).toBe(false);
    doc.activeElement = pw;
    expect(p.tiphysPage("reader", {})).toEqual({ error: "passwordField" });
    expect(p.tiphysPage("text", { text: "x" })).toEqual({ error: "passwordField" });
    doc.activeElement = null;
    pw.value = "dolu";
    expect(p.tiphysPasswordActive(doc)).toBe(true);
    expect(p.tiphysPage("bilinmeyen", {})).toEqual({ error: "badRequest" });
    const c = p.tiphysClip("ç".repeat(150 * 1024), 200 * 1024);
    expect(c.truncated).toBe(true);
    expect(Buffer.byteLength(c.text)).toBeLessThanOrEqual(200 * 1024);
    expect(p.tiphysClip("kısa", 100)).toEqual({ text: "kısa", truncated: false });
  });

  it("yazı yalnız odaktaki düzenlenebilir alana: odak iframe'de ya da alan yoksa noInput (ilk görünen alana yazılmaz)", () => {
    const typed: string[] = [];
    const input = (o: Record<string, unknown> = {}) => ({ nodeName: "INPUT", type: "text", disabled: false, readOnly: false, matches: () => true, focus() {}, getClientRects: () => [1], isContentEditable: false, ...o });
    const visible = input();
    const doc: Record<string, any> = {
      activeElement: null,
      querySelectorAll: (q: string) => (q.includes("password") ? [] : [visible]),
      execCommand: (_c: string, _u: boolean, v: string) => (typed.push(v), true),
    };
    const p = load(doc);
    for (const active of [null, { nodeName: "IFRAME", matches: () => false }, { nodeName: "FRAME", matches: () => false }, { nodeName: "BODY", matches: () => false }, input({ readOnly: true })]) {
      doc.activeElement = active;
      expect(p.tiphysPage("text", { text: "merhaba" })).toEqual({ error: "noInput" });
    }
    expect(typed).toEqual([]);
    doc.activeElement = visible;
    expect(p.tiphysPage("text", { text: "merhaba" })).toEqual({ ok: true, target: "input" });
    expect(typed).toEqual(["merhaba"]);
  });
});
