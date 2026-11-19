// Velour remote: a fake Velour listens on a temporary unix socket (the real player and its socket are never touched).
// Covers request framing, per-op validation, error mapping, unavailable/timeout and the owner check.
import { mkdtemp } from "node:fs/promises";
import { createServer, type Server } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { velourRequest, velourRoutes, velourSocketPath } from "../src/routes/velour.ts";
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

async function app(path: string) {
  const t = await testApp((c) => c, [(a, ctx) => velourRoutes(a, ctx, { socketPath: path })]);
  cleanups.push(() => t.app.close());
  const post = (body: unknown) => t.app.inject({ method: "POST", url: "/v1/velour", headers: t.auth, payload: body as object });
  return { ...t, post };
}

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
