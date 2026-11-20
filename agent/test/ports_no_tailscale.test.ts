// /v1/ports without Tailscale installed: the list still works (nothing shared, no tailnet URL) instead of a 500.
import { existsSync } from "node:fs";
import { mkdtemp, symlink } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { portRoutes } from "../src/routes/ports.ts";
import { testApp } from "./helpers.ts";

const which = (cmd: string) => (process.env.PATH ?? "").split(":").map((d) => join(d, cmd)).find((p) => existsSync(p));

describe.skipIf(process.platform !== "linux" || !which("ss"))("ports without Tailscale", () => {
  const oldPath = process.env.PATH;
  afterEach(() => {
    process.env.PATH = oldPath;
  });

  it("lists ports with host null and nothing shared", async () => {
    const bin = await mkdtemp(join(tmpdir(), "tiphys-path-"));
    await symlink(which("ss")!, join(bin, "ss"));
    process.env.PATH = bin; // ss only: no tailscale
    const server = createServer().listen(0, "127.0.0.1");
    await new Promise((r) => server.once("listening", r));
    const port = (server.address() as { port: number }).port;
    const { app, auth } = await testApp((c) => c, [(a, ctx) => portRoutes(a, ctx)]);
    const res = await app.inject({ url: "/v1/ports", headers: auth });
    expect(res.statusCode).toBe(200);
    expect(res.json().host).toBeNull();
    expect(res.json().ports.find((p: { port: number }) => p.port === port)).toMatchObject({ localOnly: true, shared: false, url: null });
    server.close();
    await app.close();
  });
});
