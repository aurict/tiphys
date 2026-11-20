// Velour remote: a fake Velour listens on a temporary unix socket (the real player and its socket are never touched).
// Covers request framing, per-op validation, error mapping, unavailable/timeout and the owner check.
import { mkdtemp } from "node:fs/promises";
import type { AddressInfo } from "node:net";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { AppError } from "../src/errors.ts";
import { velourRequest, velourRoutes, velourSocketPath, velourTimeout, withSleepThen, type VelourOpts } from "../src/routes/velour.ts";
import { testApp } from "./helpers.ts";

const cleanups: Array<() => unknown> = [];
afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
});

/** Fake Velour: records request lines, answers with `answer(req)` (a string is sent raw; undefined = never answers). */
async function fakeVelour(answer: (req: Record<string, unknown>) => unknown) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-velour-"));
  const path = join(dir, "control.sock");
  const got: Array<Record<string, unknown>> = [];
  const server: Server = createServer((sock) => {
    let buf = "";
    sock.on("data", (b) => {
      buf += b.toString("utf8");
      const nl = buf.indexOf("\n");
      if (nl === -1) return;
      const req = JSON.parse(buf.slice(0, nl));
      got.push(req);
      const a = answer(req);
      if (a === undefined) return;
      sock.end((typeof a === "string" ? a : JSON.stringify(a)) + "\n");
    });
    sock.on("error", () => {});
  });
  await new Promise<void>((r) => server.listen(path, r));
  cleanups.push(() => new Promise((r) => server.close(() => r(undefined))));
  return { path, got, dir };
}

/** `ctl` header: a valid control session (fake ControlSessions: only "tpc_ok" passes). `power`: the power feature. */
async function app(path: string, o: Omit<VelourOpts, "socketPath"> & { power?: boolean } = {}) {
  const focused: string[] = [];
  const t = await testApp(
    (c) => ({ ...c, features: { ...c.features, control: true, power: !!o.power } }),
    [
      (a, ctx) => {
        ctx.control = {
          check: async (token?: string) => {
            if (token !== "tpc_ok") throw new AppError("agent.control.sessionRequired", 403);
            return { device: "phone" };
          },
        } as unknown as NonNullable<typeof ctx.control>;
        ctx.focusClass = async (cls) => (focused.push(cls), true);
        velourRoutes(a, ctx, { socketPath: path, ...o });
      },
    ],
  );
  cleanups.push(() => t.app.close());
  const post = (body: unknown, url = "/v1/velour", headers: Record<string, string> = {}) =>
    t.app.inject({ method: "POST", url, headers: { ...t.auth, ...headers }, payload: body as object });
  return { ...t, post, focused, ctl: { "x-tiphys-control": "tpc_ok" } };
}

const until = async (f: () => boolean, ms = 3000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
};

const ok = (result: unknown) => ({ v: 1, ok: true, result });

describe("velour: requests", () => {
  it("sends the op with the protocol version and returns the result", async () => {
    const v = await fakeVelour((req) => ok({ echo: req.op, playing: true }));
    const a = await app(v.path);
    const r = await a.post({ op: "state" });
    expect(r.statusCode).toBe(200);
    expect(r.json()).toEqual({ result: { echo: "state", playing: true } });
    expect(v.got).toEqual([{ v: 1, op: "state" }]);

    // Defaults are filled in, unknown fields dropped.
    await a.post({ op: "play", tracks: [{ videoId: "a", title: "A", junk: 1 }] });
    expect(v.got[1]).toEqual({ v: 1, op: "play", tracks: [{ videoId: "a", title: "A" }], start: 0, shuffle: false });
    await a.post({ op: "search", query: "  sezen aksu " });
    expect(v.got[2]).toEqual({ v: 1, op: "search", query: "sezen aksu" });
  });

  it("needs a paired device", async () => {
    const v = await fakeVelour(() => ok(null));
    const a = await app(v.path);
    const r = await a.app.inject({ method: "POST", url: "/v1/velour", payload: { op: "state" } });
    expect(r.statusCode).toBe(401);
    expect(v.got).toHaveLength(0);
  });

  it("rejects invalid ops before they reach Velour", async () => {
    const v = await fakeVelour(() => ok(null));
    const a = await app(v.path);
    for (const body of [
      { op: "format-disk" },
      { op: "seek" },
      { op: "seek", seconds: -1 },
      { op: "volume", percent: 101 },
      { op: "search", query: "   " },
      { op: "play", tracks: [] },
      { op: "play-target", target: { kind: "browse", id: "MPRE1", pageType: "album" } },
      { op: "library", tab: "everything" },
      { op: "rate", videoId: "x", like: "love" },
      { op: "add-to-playlist", playlistId: "PL", videoIds: [] },
      { op: "wait" },
      { op: "wait", since: -1 },
      { op: "wait", since: 1, timeout: 26 },
      { op: "set-eq", preset: "" },
      { op: "sleep", minutes: 0 },
      { op: "sleep", minutes: 721 },
      { op: "sleep", minutes: 1.5 },
      { op: "save-queue", title: "  " },
      { op: "save-to-library", playlistId: "PL" },
      { op: "remove-from-playlist", playlistId: "PL", videoId: "a" },
    ]) {
      const r = await a.post(body);
      expect(r.statusCode, JSON.stringify(body)).toBe(400);
      expect(r.json().error.code).toBe("agent.request.invalid");
    }
    expect(v.got).toHaveLength(0);
  });

  it("maps Velour errors to agent.velour.<code>", async () => {
    const answers: Record<string, unknown> = {
      jump: { v: 1, ok: false, error: { code: "notFound", message: "no song at that queue position" } },
      search: { v: 1, ok: false, error: { code: "notSignedIn", message: "not signed in" } },
      next: { v: 1, ok: false, error: { code: "somethingNew", message: "?" } },
      prev: "not json",
    };
    const v = await fakeVelour((req) => answers[req.op as string]);
    const a = await app(v.path);
    const jump = await a.post({ op: "jump", index: 99 });
    expect([jump.statusCode, jump.json().error.code]).toEqual([404, "agent.velour.notFound"]);
    const search = await a.post({ op: "search", query: "x" });
    expect([search.statusCode, search.json().error.code]).toEqual([409, "agent.velour.notSignedIn"]);
    const next = await a.post({ op: "next" });
    expect([next.statusCode, next.json().error.code]).toEqual([502, "agent.velour.failed"]);
    const prev = await a.post({ op: "prev" });
    expect([prev.statusCode, prev.json().error.code]).toEqual([502, "agent.velour.failed"]);
  });

  it("no socket → unavailable; no answer → timeout", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-velour-"));
    const a = await app(join(dir, "control.sock"));
    const r = await a.post({ op: "state" });
    expect([r.statusCode, r.json().error.code]).toEqual([503, "agent.velour.unavailable"]);

    const silent = await fakeVelour(() => undefined);
    await expect(velourRequest(silent.path, { op: "state" }, 100)).rejects.toMatchObject({ code: "agent.velour.timeout", status: 504 });
  });

  it("refuses a path that isn't a socket", async () => {
    const v = await fakeVelour(() => ok(null));
    await expect(velourRequest(v.dir, { op: "state" })).rejects.toMatchObject({ code: "agent.velour.unavailable" });
  });

  it("socket path from XDG_RUNTIME_DIR", () => {
    expect(velourSocketPath({ XDG_RUNTIME_DIR: "/run/user/1000" })).toBe("/run/user/1000/velour/control.sock");
    expect(velourSocketPath({ XDG_RUNTIME_DIR: "relative" })).toMatch(/^\/run\/user\/\d+\/velour\/control\.sock$/);
  });
});

describe("velour: new ops", () => {
  it("forwards wait, explore, eq, sleep, show and playlist ops as given", async () => {
    const v = await fakeVelour(() => ok({}));
    const a = await app(v.path);
    for (const body of [
      { op: "wait", since: 7 },
      { op: "wait", since: 0, timeout: 25 },
      { op: "explore" },
      { op: "eq" },
      { op: "set-eq", preset: "Bass boost" },
      { op: "sleep", minutes: 30 },
      { op: "sleep", endOfTrack: true },
      { op: "sleep" },
      { op: "show" },
      { op: "save-queue", title: " Gece " },
      { op: "save-to-library", playlistId: "PL1", save: true },
      { op: "remove-from-playlist", playlistId: "PL1", videoId: "a", setVideoId: "S1" },
    ]) {
      const r = await a.post(body);
      expect(r.statusCode, JSON.stringify(body)).toBe(200);
    }
    expect(v.got.map(({ v: _, ...rest }) => rest)).toEqual([
      { op: "wait", since: 7 },
      { op: "wait", since: 0, timeout: 25 },
      { op: "explore" },
      { op: "eq" },
      { op: "set-eq", preset: "Bass boost" },
      { op: "sleep", minutes: 30 },
      { op: "sleep", endOfTrack: true },
      { op: "sleep" },
      { op: "show" },
      { op: "save-queue", title: "Gece" },
      { op: "save-to-library", playlistId: "PL1", save: true },
      { op: "remove-from-playlist", playlistId: "PL1", videoId: "a", setVideoId: "S1" },
    ]);
  });

  it("wait gets a longer timeout than its own; network ops the long one", () => {
    expect(velourTimeout({ op: "wait", since: 1 })).toBe(25_000);
    expect(velourTimeout({ op: "wait", since: 1, timeout: 5 })).toBe(10_000);
    expect(velourTimeout({ op: "explore" })).toBe(35_000);
    expect(velourTimeout({ op: "toggle" })).toBe(5_000);
  });

  it("adds the pending sleep action only to a state with a timer", () => {
    expect(withSleepThen({ sleep: { endsAt: 5, endOfTrack: false }, rev: 1 }, "suspend")).toEqual({ sleep: { endsAt: 5, endOfTrack: false, then: "suspend" }, rev: 1 });
    expect(withSleepThen({ sleep: null }, "suspend")).toEqual({ sleep: null });
    expect(withSleepThen({ sections: [] }, "none")).toEqual({ sections: [] });
    expect(withSleepThen(null, "none")).toBe(null);
  });
});

/** A fake Velour with a real `rev`/`wait`/`sleep`: `bump()` changes the state, `fire()` ends the sleep timer. */
function statefulVelour() {
  const s = { rev: 1, playing: true, sleep: null as null | Record<string, unknown>, slept: 0 };
  const waiters: Array<{ since: number; send: () => void }> = [];
  const answer = () => {
    for (const w of waiters.splice(0)) if (w.since !== s.rev) w.send();
      else waiters.push(w);
  };
  const bump = (patch: Partial<typeof s> = {}) => {
    Object.assign(s, patch, { rev: s.rev + 1 });
    answer();
  };
  return {
    s,
    bump,
    fire: () => bump({ sleep: null, slept: s.slept + 1, playing: false }),
    handler: (req: Record<string, unknown>, send: (x: unknown) => void) => {
      if (req.op === "wait") {
        if (req.since !== s.rev) return send(ok({ ...s }));
        waiters.push({ since: req.since as number, send: () => send(ok({ ...s })) });
        return;
      }
      if (req.op === "sleep") {
        if (req.minutes || req.endOfTrack) Object.assign(s, { sleep: { endsAt: req.minutes ? 1000 : null, endOfTrack: !!req.endOfTrack } });
        else s.sleep = null;
        s.rev++;
        answer();
      }
      send(ok({ ...s }));
    },
  };
}

/** Like fakeVelour, but the answer can come later (for `wait`). */
async function asyncVelour(handler: (req: Record<string, unknown>, send: (x: unknown) => void) => void) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-velour-"));
  const path = join(dir, "control.sock");
  const got: Array<Record<string, unknown>> = [];
  const server: Server = createServer((sock) => {
    let buf = "";
    sock.on("data", (b) => {
      buf += b.toString("utf8");
      const nl = buf.indexOf("\n");
      if (nl === -1) return;
      const req = JSON.parse(buf.slice(0, nl));
      got.push(req);
      handler(req, (x) => !sock.destroyed && sock.end(JSON.stringify(x) + "\n"));
    });
    sock.on("error", () => {});
  });
  await new Promise<void>((r) => server.listen(path, r));
  cleanups.push(() => new Promise((r) => (server.close(() => r(undefined)), server.unref())));
  return { path, got };
}

describe("velour: live state (SSE)", () => {
  async function stream(a: Awaited<ReturnType<typeof app>>) {
    await a.app.listen({ host: "127.0.0.1", port: 0 });
    const port = (a.app.server.address() as AddressInfo).port;
    const ctrl = new AbortController();
    cleanups.push(() => ctrl.abort());
    const res = await fetch(`http://127.0.0.1:${port}/v1/velour/events`, { headers: a.auth, signal: ctrl.signal });
    const reader = res.body!.getReader();
    let text = "";
    const read = async (want: string) => {
      while (!text.includes(want)) {
        const { value, done } = await reader.read();
        if (done) return false;
        text += new TextDecoder().decode(value);
      }
      return true;
    };
    return { res, read, text: () => text, close: () => ctrl.abort() };
  }

  it("sends the state, then a new one each time rev changes", async () => {
    const f = statefulVelour();
    const v = await asyncVelour(f.handler);
    const a = await app(v.path, { pingMs: 50 });
    const s = await stream(a);
    expect(s.res.headers.get("content-type")).toContain("text/event-stream");
    expect(await s.read('"rev":1')).toBe(true);
    await until(() => v.got.some((r) => r.op === "wait"));
    expect(v.got[0]).toEqual({ v: 1, op: "state" });
    expect(v.got[1]).toEqual({ v: 1, op: "wait", since: 1, timeout: 20 });
    f.bump({ playing: false });
    expect(await s.read('"rev":2')).toBe(true);
    expect(s.text()).toContain('"playing":false');
    expect(await s.read(": ping")).toBe(true);
    // Each rev once.
    expect(s.text().match(/event: state/g)).toHaveLength(2);
  });

  it("reports an unreachable Velour once and recovers", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-velour-"));
    const path = join(dir, "control.sock");
    const a = await app(path, { retryMs: 30 });
    const s = await stream(a);
    expect(await s.read('event: error\ndata: {"code":"agent.velour.unavailable"}')).toBe(true);
    await new Promise((r) => setTimeout(r, 120));
    expect(s.text().match(/event: error/g)).toHaveLength(1);
    const f = statefulVelour();
    const server = createServer((sock) => {
      let buf = "";
      sock.on("data", (b) => {
        buf += b.toString("utf8");
        const nl = buf.indexOf("\n");
        if (nl !== -1) f.handler(JSON.parse(buf.slice(0, nl)), (x) => !sock.destroyed && sock.end(JSON.stringify(x) + "\n"));
      });
      sock.on("error", () => {});
    });
    await new Promise<void>((r) => server.listen(path, r));
    cleanups.push(() => new Promise((r) => (server.close(() => r(undefined)), server.unref())));
    expect(await s.read("event: state")).toBe(true);
  });

  it("an older Velour without rev is polled", async () => {
    let n = 0;
    const v = await fakeVelour(() => ok({ playing: true, n: ++n }));
    const a = await app(v.path, { pollMs: 20 });
    const s = await stream(a);
    expect(await s.read('"n":3')).toBe(true);
    expect(v.got.every((r) => r.op === "state")).toBe(true);
  });
});

describe("velour: sleep timer with a PC action", () => {
  it("screen off needs a control session; the action runs once when the timer fires", async () => {
    const f = statefulVelour();
    const v = await asyncVelour(f.handler);
    const actions: string[] = [];
    const a = await app(v.path, { sleepAction: async (t) => void actions.push(t) });
    const no = await a.post({ minutes: 30, then: "screenOff" }, "/v1/velour/sleep");
    expect([no.statusCode, no.json().error.code]).toEqual([403, "agent.control.sessionRequired"]);
    expect(v.got).toHaveLength(0);

    const r = await a.post({ minutes: 30, then: "screenOff" }, "/v1/velour/sleep", a.ctl);
    expect(r.statusCode).toBe(200);
    expect(r.json().result.sleep).toEqual({ endsAt: 1000, endOfTrack: false, then: "screenOff" });
    // The plain state shows the pending action too.
    expect((await a.post({ op: "state" })).json().result.sleep.then).toBe("screenOff");
    await until(() => v.got.some((x) => x.op === "wait"));
    f.bump(); // unrelated change: no action
    await new Promise((r) => setTimeout(r, 50));
    expect(actions).toEqual([]);
    f.fire();
    await until(() => actions.length === 1);
    expect(actions).toEqual(["screenOff"]);
    expect((await a.post({ op: "state" })).json().result.sleep).toBe(null);
  });

  it("cancelling (here or through the plain op) drops the action", async () => {
    const f = statefulVelour();
    const v = await asyncVelour(f.handler);
    const actions: string[] = [];
    const a = await app(v.path, { sleepAction: async (t) => void actions.push(t), power: true });
    await a.post({ endOfTrack: true, then: "suspend", confirm: true }, "/v1/velour/sleep");
    expect((await a.post({ op: "state" })).json().result.sleep).toEqual({ endsAt: null, endOfTrack: true, then: "suspend" });
    await a.post({}, "/v1/velour/sleep");
    expect((await a.post({ op: "state" })).json().result.sleep).toBe(null);
    f.fire();
    await new Promise((r) => setTimeout(r, 50));
    expect(actions).toEqual([]);

    await a.post({ minutes: 5, then: "suspend", confirm: true }, "/v1/velour/sleep");
    await a.post({ op: "sleep" });
    f.fire();
    await new Promise((r) => setTimeout(r, 50));
    expect(actions).toEqual([]);
  });

  it("a timer cancelled in Velour drops the action", async () => {
    const f = statefulVelour();
    const v = await asyncVelour(f.handler);
    const actions: string[] = [];
    const a = await app(v.path, { sleepAction: async (t) => void actions.push(t), power: true });
    await a.post({ minutes: 5, then: "suspend", confirm: true }, "/v1/velour/sleep");
    await until(() => v.got.some((x) => x.op === "wait"));
    f.bump({ sleep: null });
    await until(() => (f.s.rev, true));
    await new Promise((r) => setTimeout(r, 50));
    f.fire();
    await new Promise((r) => setTimeout(r, 50));
    expect(actions).toEqual([]);
  });

  it("suspend needs the power feature and confirmation; both modes at once are invalid", async () => {
    const f = statefulVelour();
    const v = await asyncVelour(f.handler);
    const off = await app(v.path);
    const r = await off.post({ minutes: 5, then: "suspend", confirm: true }, "/v1/velour/sleep");
    expect([r.statusCode, r.json().error.code]).toEqual([403, "agent.velour.powerDisabled"]);
    const on = await app(v.path, { power: true });
    const c = await on.post({ minutes: 5, then: "suspend" }, "/v1/velour/sleep");
    expect([c.statusCode, c.json().error.code]).toEqual([400, "agent.power.confirmRequired"]);
    const both = await on.post({ minutes: 5, endOfTrack: true }, "/v1/velour/sleep");
    expect(both.statusCode).toBe(400);
    expect(v.got).toHaveLength(0);
    // Without an action: no session, no confirmation.
    expect((await on.post({ minutes: 5 }, "/v1/velour/sleep")).json().result.sleep).toEqual({ endsAt: 1000, endOfTrack: false, then: "none" });
  });
});

describe("velour: show on PC", () => {
  it("needs a control session, then shows and focuses Velour", async () => {
    const v = await fakeVelour(() => ok({}));
    const a = await app(v.path);
    const no = await a.post({}, "/v1/velour/show");
    expect([no.statusCode, no.json().error.code]).toEqual([403, "agent.control.sessionRequired"]);
    expect(v.got).toHaveLength(0);
    expect((await a.post({}, "/v1/velour/show", a.ctl)).json()).toEqual({ ok: true });
    expect(v.got.map((x) => x.op)).toEqual(["show"]);
    expect(a.focused).toEqual(["io.github.mikailustuner.Velour"]);
  });
});

describe("velour: busy Velour", () => {
  it("a wait answered at once with the same rev doesn't make the stream spin", async () => {
    // Velour with too many parked waits answers each wait immediately with the unchanged state.
    const v = await fakeVelour(() => ok({ rev: 5, playing: true }));
    const a = await app(v.path, { pollMs: 200 });
    await a.app.listen({ host: "127.0.0.1", port: 0 });
    const port = (a.app.server.address() as AddressInfo).port;
    const ctrl = new AbortController();
    cleanups.push(() => ctrl.abort());
    await fetch(`http://127.0.0.1:${port}/v1/velour/events`, { headers: a.auth, signal: ctrl.signal });
    await new Promise((r) => setTimeout(r, 500));
    // state + a few waits, not hundreds.
    expect(v.got.length).toBeLessThan(6);
  });
});
