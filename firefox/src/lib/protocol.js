// Tiphys Köprüsü: extension ⇄ agent protocol and pure logic (tested with a fake `browser` object).
// Agent → extension: {type:"req", id, op, args}; extension → agent: {type:"res", id, ok, result|error},
// {type:"hello", version, ext, permissions}, {type:"event", name:"tabs", tabs}, {type:"permissions", permissions}.
// Helper (native host) → extension: {type:"host", agent:true|false} (agent socket connected/disconnected).
// Agent → extension: {type:"error", code:"busy"|"version"} (hello rejected: another Firefox is connected or the
// version doesn't match) → the native connection is closed and retried with a delay growing from 5 s to 10 min (so
// two Firefoxes don't keep knocking each other off).
// PRIVACY: private window tabs are never reported; an address is sent only if http/https/file/about; remote favicons
// are not downloaded; form values are not read.

export const PROTOCOL_VERSION = 1;
export const HOST_NAME = "dev.tiphys.bridge";
export const COALESCE_MS = 300;
export const CONTENT_PERMISSIONS = { permissions: ["scripting"], origins: ["<all_urls>"] };
const URL_SCHEMES = new Set(["http:", "https:", "file:", "about:"]);
const MAX_TABS = 1000;
/** Message upper limit (UTF-8 bytes; the helper's frame limit is 1 MB). A tab list over it is shrunk. */
export const SOFT_LIMIT = 900 * 1024;
const REFUSED_MAX_MS = 10 * 60_000;
const ENC = new TextEncoder();
/** UTF-8 byte length of JSON (String.length counts UTF-16 units; misleading for Turkish/CJK titles). */
export const jsonBytes = (v) => ENC.encode(JSON.stringify(v)).length;
// In the browser setTimeout can't be called with another `this` ("does not implement interface Window"): wrapped.
const TIMERS = { setTimeout: (fn, ms) => setTimeout(fn, ms), clearTimeout: (id) => clearTimeout(id) };

export class BridgeError extends Error {
  constructor(code) {
    super(code);
    this.code = code;
  }
}

/** Reportable address: http/https/file/about; others (moz-extension:, view-source:, data: …) null. */
export function reportUrl(u) {
  if (typeof u !== "string" || u.length > 8192) return null;
  try {
    return URL_SCHEMES.has(new URL(u).protocol) ? u : null;
  } catch {
    return null;
  }
}

/** New tab address: only http/https, no spaces/control characters, ≤ 4096. Normalized, or null. */
export function createUrl(u) {
  if (typeof u !== "string" || u.length > 4096 || /[\s\u0000-\u001f\u007f]/.test(u)) return null;
  try {
    const p = new URL(u);
    return (p.protocol === "http:" || p.protocol === "https:") && p.hostname ? p.href : null;
  } catch {
    return null;
  }
}

export function mapTab(t, favicon = null) {
  return {
    id: t.id,
    windowId: t.windowId,
    index: t.index,
    title: typeof t.title === "string" ? t.title.slice(0, 500) : "",
    url: reportUrl(t.url),
    pinned: !!t.pinned,
    audible: !!t.audible,
    muted: !!t.mutedInfo?.muted,
    active: !!t.active,
    lastAccessed: typeof t.lastAccessed === "number" ? t.lastAccessed : null,
    favicon,
  };
}

/** Coalescer: the first poke sets a timer; pokes within the delay fold into a single call. */
export class Coalescer {
  constructor(fn, ms = COALESCE_MS, timers = TIMERS) {
    this.fn = fn;
    this.ms = ms;
    this.timers = timers;
    this.timer = null;
  }
  poke() {
    if (this.timer !== null) return;
    this.timer = this.timers.setTimeout(() => {
      this.timer = null;
      this.fn();
    }, this.ms);
  }
  cancel() {
    if (this.timer !== null) this.timers.clearTimeout(this.timer);
    this.timer = null;
  }
}

const isId = (n) => Number.isInteger(n) && n >= 0 && n < 2 ** 31;

/**
 * Fits the list into [limit] bytes: first favicons, then long addresses/titles (address null if it doesn't fit,
 * title 120 characters), finally trailing tabs are dropped.
 */
export function fitTabs(out, limit = SOFT_LIMIT) {
  if (jsonBytes(out) <= limit) return out;
  for (const t of out) t.favicon = null;
  if (jsonBytes(out) <= limit) return out;
  for (const t of out) {
    if (t.url && t.url.length > 2048) t.url = null;
    t.title = t.title.slice(0, 120);
  }
  let size = jsonBytes(out);
  while (out.length && size > limit) size -= jsonBytes(out.pop()) + 1;
  return out;
}

export async function listTabs(browser, favicon = async () => null) {
  const tabs = (await browser.tabs.query({})).filter((t) => !t.incognito).slice(0, MAX_TABS);
  tabs.sort((a, b) => a.windowId - b.windowId || a.index - b.index);
  const out = [];
  for (const t of tabs) out.push(mapTab(t, await favicon(t.favIconUrl).catch(() => null)));
  return fitTabs(out);
}

export async function contentPermission(browser) {
  return !!(await browser.permissions.contains(CONTENT_PERMISSIONS).catch(() => false));
}

/** An existing, non-private tab; otherwise tabNotFound. */
async function tabOf(browser, id) {
  if (!isId(id)) throw new BridgeError("badRequest");
  const t = await browser.tabs.get(id).catch(() => null);
  if (!t || t.incognito) throw new BridgeError("tabNotFound");
  return t;
}

/** An 11.3 operation via the page script (content/page.js); permissionRequired without permission. */
async function pageOp(browser, id, op, args, files) {
  if (!(await contentPermission(browser))) throw new BridgeError("permissionRequired");
  const tab = await tabOf(browser, id);
  if (!/^(https?|file):/.test(tab.url ?? "")) throw new BridgeError("unsupported");
  let res;
  try {
    await browser.scripting.executeScript({ target: { tabId: id }, files });
    res = await browser.scripting.executeScript({ target: { tabId: id }, func: (o, a) => tiphysPage(o, a), args: [op, args] }); // eslint-disable-line no-undef
  } catch {
    throw new BridgeError("unsupported"); // privileged page, addons.mozilla.org etc.
  }
  const r = res?.[0]?.result;
  if (!r || typeof r !== "object") throw new BridgeError("failed");
  if (r.error) throw new BridgeError(String(r.error));
  return r;
}

const PAGE = ["content/page.js"];
const READER = ["vendor/Readability.js", "content/page.js"];

/** Operation table: op → (browser, args, deps) → result. */
export const OPS = {
  "tabs.list": (b, _a, d) => listTabs(b, d.favicon),
  "tabs.create": async (b, a) => {
    const url = createUrl(a.url);
    if (!url) throw new BridgeError("badUrl");
    const t = await b.tabs.create({ url, active: true });
    await b.windows.update(t.windowId, { focused: true }).catch(() => {});
    return { id: t.id };
  },
  "tabs.activate": async (b, a) => {
    const t = await tabOf(b, a.id);
    await b.tabs.update(t.id, { active: true });
    await b.windows.update(t.windowId, { focused: true }).catch(() => {});
    return { title: typeof t.title === "string" ? t.title.slice(0, 500) : null };
  },
  "tabs.close": async (b, a) => {
    if (!Array.isArray(a.ids) || a.ids.length === 0 || a.ids.length > 200) throw new BridgeError("badRequest");
    const tabs = [];
    for (const id of a.ids) tabs.push(await tabOf(b, id));
    await b.tabs.remove(tabs.map((t) => t.id));
    return {};
  },
  "tabs.reload": async (b, a) => (await b.tabs.reload((await tabOf(b, a.id)).id), {}),
  "tabs.back": async (b, a) => (await b.tabs.goBack((await tabOf(b, a.id)).id), {}),
  "tabs.forward": async (b, a) => (await b.tabs.goForward((await tabOf(b, a.id)).id), {}),
  "tabs.pin": async (b, a) => {
    const t = await tabOf(b, a.id);
    await b.tabs.update(t.id, { pinned: !t.pinned });
    return { pinned: !t.pinned };
  },
  "tabs.mute": async (b, a) => {
    const t = await tabOf(b, a.id);
    const muted = !t.mutedInfo?.muted;
    await b.tabs.update(t.id, { muted });
    return { muted };
  },
  "sessions.restore": async (b) => {
    const [last] = await b.sessions.getRecentlyClosed({ maxResults: 1 });
    const sid = last?.tab?.sessionId ?? last?.window?.sessionId;
    if (!sid) throw new BridgeError("tabNotFound");
    await b.sessions.restore(sid);
    return {};
  },
  "page.reader": (b, a) => pageOp(b, a.id, "reader", {}, READER),
  "page.media": (b, a) => pageOp(b, a.id, "media", { action: a.action, seconds: a.seconds, rate: a.rate }, PAGE),
  "page.scroll": (b, a) => pageOp(b, a.id, "scroll", { fraction: a.fraction }, PAGE),
  "page.text": (b, a) => pageOp(b, a.id, "text", { text: a.text }, PAGE),
};

/** Runs the request and returns the response message (never throws). */
export async function handleRequest(browser, msg, deps = {}) {
  // Only the table's own keys (not inherited ones like "constructor", "__proto__").
  const fn = typeof msg.op === "string" && Object.hasOwn(OPS, msg.op) ? OPS[msg.op] : null;
  if (!fn || !Number.isInteger(msg.id)) return { type: "res", id: msg.id, ok: false, error: "badRequest" };
  try {
    return { type: "res", id: msg.id, ok: true, result: await fn(browser, msg.args ?? {}, deps) };
  } catch (e) {
    return { type: "res", id: msg.id, ok: false, error: e instanceof BridgeError ? e.code : "failed" };
  }
}

/** Native messaging connection + events. background.js sets this up. */
export class Bridge {
  constructor(browser, { favicon = async () => null, timers = TIMERS, coalesceMs = COALESCE_MS } = {}) {
    this.browser = browser;
    this.favicon = favicon;
    this.timers = timers;
    this.port = null;
    this.agent = false;
    this.retryMs = 5000;
    /** Delay after the agent rejects hello (5 s → 10 min); reset when the agent sends a request (we were accepted). */
    this.refusedMs = 5000;
    this.events = new Coalescer(() => void this.sendTabs(), coalesceMs, timers);
  }

  start() {
    const t = this.browser.tabs;
    const poke = () => this.events.poke();
    const pokeTab = (tab) => tab && !tab.incognito && poke();
    t.onCreated.addListener(pokeTab);
    t.onUpdated.addListener((_id, change, tab) => {
      if (["url", "title", "pinned", "audible", "mutedInfo", "favIconUrl"].some((k) => k in change)) pokeTab(tab);
    });
    t.onRemoved.addListener(poke);
    t.onActivated.addListener(poke);
    t.onAttached.addListener(poke);
    t.onDetached.addListener(poke);
    const perms = () => void this.sendPermissions();
    this.browser.permissions.onAdded.addListener(perms);
    this.browser.permissions.onRemoved.addListener(perms);
    this.connect();
  }

  connect() {
    const port = this.browser.runtime.connectNative(HOST_NAME);
    this.port = port;
    port.onMessage.addListener((m) => void this.onMessage(port, m));
    port.onDisconnect.addListener(() => {
      if (this.port !== port) return;
      this.port = null;
      this.agent = false;
      this.events.cancel();
      // Helper missing/crashed: retry with a delay growing from 5 s to 60 s.
      this.timers.setTimeout(() => this.connect(), this.retryMs);
      this.retryMs = Math.min(this.retryMs * 2, 60_000);
    });
  }

  #post(m) {
    // The helper drops frames over 1 MB: an error goes instead of a large response, a large event is never sent.
    if (jsonBytes(m) > SOFT_LIMIT) {
      if (m.type !== "res") return;
      m = { type: "res", id: m.id, ok: false, error: "failed" };
    }
    try {
      this.port?.postMessage(m);
    } catch {
      // connection is closing
    }
  }

  /** The agent rejected us: this connection is closed and retried with a growing delay. */
  #refused(port) {
    this.port = null;
    this.agent = false;
    this.events.cancel();
    try {
      port.disconnect();
    } catch {
      // already closed
    }
    this.timers.setTimeout(() => this.connect(), this.refusedMs);
    this.refusedMs = Math.min(this.refusedMs * 2, REFUSED_MAX_MS);
  }

  async onMessage(port, m) {
    if (port !== this.port || !m || typeof m !== "object") return;
    if (m.type === "host") {
      this.agent = m.agent === true;
      this.retryMs = 5000;
      if (this.agent) {
        const ext = this.browser.runtime.getManifest().version;
        this.#post({ type: "hello", version: PROTOCOL_VERSION, ext, permissions: { content: await contentPermission(this.browser) } });
      }
    } else if (m.type === "error") {
      this.#refused(port);
    } else if (m.type === "req") {
      this.refusedMs = 5000;
      this.#post(await handleRequest(this.browser, m, { favicon: this.favicon }));
    }
  }

  async sendTabs() {
    if (!this.agent) return;
    this.#post({ type: "event", name: "tabs", tabs: await listTabs(this.browser, this.favicon) });
  }

  async sendPermissions() {
    if (this.agent) this.#post({ type: "permissions", permissions: { content: await contentPermission(this.browser) } });
  }

  get status() {
    return { host: this.port !== null, agent: this.agent };
  }
}
