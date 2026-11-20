// Easy install (PLAN K4–K6, K8): config reload without restart, init feature semantics, detection, Tailscale URL,
// doctor and signed self-update.
import { execFile } from "node:child_process";
import { generateKeyPairSync, createHash, sign, createPublicKey } from "node:crypto";
import { existsSync, readFileSync, readlinkSync } from "node:fs";
import { chmod, mkdir, mkdtemp, readFile, realpath, symlink, writeFile } from "node:fs/promises";
import { createServer, type Server } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { promisify } from "node:util";
import Fastify from "fastify";
import { describe, expect, it, afterAll } from "vitest";
import { hashToken, newToken } from "../src/auth.ts";
import { ConfigStore, defaultConfig } from "../src/config.ts";
import { detect, initCommand, planFeatures, safeFeatures, suggestions, FeatureError, RISKY_FEATURES, type DetectEnv } from "../src/detect.ts";
import { runDoctor, formatCheck, type DoctorDeps } from "../src/doctor.ts";
import { maintenanceRoutes } from "../src/routes/maintenance.ts";
import { ownAgentUrl, servePortsFor, type Exec } from "../src/tailscale.ts";
import { applyUpdate, bundleName, checkUpdate, clearUpdateCache, managedRoot, parseSums, platformId, settleUpdate, verifySums } from "../src/update.ts";
import { UPDATE_PUBLIC_KEY } from "../src/update_key.ts";
import { testApp } from "./helpers.ts";

const pexec = promisify(execFile);
const tmp = () => mkdtemp(join(tmpdir(), "tiphys-k-"));
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

describe("config reload (K4: pairing without restart)", () => {
  it("re-reads a file changed by another process, and update() keeps that change", async () => {
    const dir = await tmp();
    const path = join(dir, "agent.json");
    const agent = await ConfigStore.loadOrCreate(path, "a");
    expect(await agent.reloadIfChanged()).toBe(false);
    const cli = await ConfigStore.load(path);
    await cli.update((c) => {
      c.devices.push({ id: "p2", name: "P2", tokenHash: hashToken(newToken()), createdAt: "x" });
      return c;
    });
    // The agent writes something of its own without having reloaded first: the CLI's device must survive.
    await agent.update((c) => {
      c.name = "renamed";
      return c;
    });
    const disk = JSON.parse(await readFile(path, "utf8"));
    expect(disk.devices.map((d: { id: string }) => d.id)).toEqual(["p2"]);
    expect(disk.name).toBe("renamed");
  });

  it("ignores an invalid file (keeps the old settings)", async () => {
    const dir = await tmp();
    const path = join(dir, "agent.json");
    const agent = await ConfigStore.loadOrCreate(path, "a");
    await writeFile(path, "{ not json");
    expect(await agent.reloadIfChanged()).toBe(false);
    expect(agent.get().name).toBe("a");
  });

  it("watch() picks up the change by itself", async () => {
    const dir = await tmp();
    const path = join(dir, "agent.json");
    const agent = await ConfigStore.loadOrCreate(path, "a");
    let reloads = 0;
    const stop = agent.watch(() => reloads++, 50);
    try {
      const cli = await ConfigStore.load(path);
      await cli.update((c) => ({ ...c, name: "from-cli" }));
      for (let i = 0; i < 40 && agent.get().name !== "from-cli"; i++) await wait(50);
      expect(agent.get().name).toBe("from-cli");
      expect(reloads).toBeGreaterThan(0);
    } finally {
      stop();
    }
  });

  it("a device paired by the CLI is accepted at once (unknown token → one re-read)", async () => {
    const { app, store } = await testApp();
    const cli = await ConfigStore.load(store.path);
    const token = newToken();
    await cli.update((c) => {
      c.devices.push({ id: "new-phone", name: "New", tokenHash: hashToken(token), createdAt: "x" });
      return c;
    });
    const res = await app.inject({ url: "/v1/agent/status", headers: { authorization: `Bearer ${token}` } });
    expect(res.statusCode).toBe(200);
    // A wrong token still fails (and does not loop).
    const bad = await app.inject({ url: "/v1/agent/status", headers: { authorization: `Bearer ${newToken()}` } });
    expect(bad.statusCode).toBe(401);
  });
});

describe("init feature semantics (K5)", () => {
  const base = defaultConfig("x").features;

  it("--features adds and never turns anything off", () => {
    const p = planFeatures({ ...base, git: true }, { features: "claude" });
    expect(p.features.git).toBe(true);
    expect(p.features.claude).toBe(true);
    expect(p.features.system).toBe(true);
    expect(p.disabled).toEqual([]);
    expect(p.enabled).toEqual(["claude"]);
  });

  it("--set-features is an exact list, --disable turns off", () => {
    const p = planFeatures({ ...base, git: true }, { setFeatures: "system,claude" });
    expect(Object.entries(p.features).filter(([, v]) => v).map(([k]) => k).sort()).toEqual(["claude", "system"]);
    expect(p.disabled).toContain("git");
    const q = planFeatures(base, { disable: "power" });
    expect(q.features.power).toBe(false);
    expect(q.disabled).toEqual(["power"]);
  });

  it("rejects unknown names, add+set together, and on+off clashes", () => {
    expect(() => planFeatures(base, { features: "nope" })).toThrow(FeatureError);
    expect(() => planFeatures(base, { features: "git", setFeatures: "git" })).toThrow(FeatureError);
    expect(() => planFeatures(base, { features: "git", disable: "git" })).toThrow(FeatureError);
  });

  it("--detect on a fresh file starts from the detected set; on an existing file it only adds", () => {
    const fresh = planFeatures(base, { detected: ["system", "git"], fresh: true });
    expect(Object.entries(fresh.features).filter(([, v]) => v).map(([k]) => k).sort()).toEqual(["git", "system"]);
    const existing = planFeatures({ ...base, claude: true }, { detected: ["system", "git"] });
    expect(existing.features.claude).toBe(true);
    expect(existing.features.power).toBe(true);
    expect(existing.disabled).toEqual([]);
  });

  it("init command: --features adds to the list (no silent disabling)", async () => {
    const dir = await tmp();
    const cfg = join(dir, "agent.json");
    const lines: string[] = [];
    const init = (o: Parameters<typeof initCommand>[1]) => initCommand(cfg, o, (l) => lines.push(l));
    await init({ name: "box", setFeatures: "system,git" });
    await init({ features: "docker" });
    expect(lines).toContain("Turned on: docker");
    const f = JSON.parse(await readFile(cfg, "utf8")).features;
    expect([f.system, f.git, f.docker, f.claude]).toEqual([true, true, true, false]);
    await init({ disable: "git" });
    expect(JSON.parse(await readFile(cfg, "utf8")).features.git).toBe(false);
    await expect(init({ features: "bogus" })).rejects.toBeInstanceOf(FeatureError);
    // A bad list on a fresh path writes nothing.
    await expect(initCommand(join(dir, "other.json"), { features: "bogus" }, () => {})).rejects.toBeInstanceOf(FeatureError);
    expect(existsSync(join(dir, "other.json"))).toBe(false);
  });

  it("init --detect on a fresh file: detected safe set only, risky ones printed as suggestions", async () => {
    const dir = await tmp();
    const lines: string[] = [];
    const env: DetectEnv = {
      env: { XDG_CURRENT_DESKTOP: "KDE" },
      exec: fakeExec({ "systemctl --user": {} }),
      which: (c) => ["systemctl", "claude"].includes(c),
      exists: () => false,
      canUse: async () => false,
      managed: () => false,
    };
    await initCommand(join(dir, "agent.json"), { detect: true }, (l) => lines.push(l), env);
    const f = JSON.parse(await readFile(join(dir, "agent.json"), "utf8")).features;
    expect(Object.entries(f).filter(([, v]) => v).map(([k]) => k).sort()).toEqual(["desktop", "services", "system"]);
    const text = lines.join("\n");
    expect(text).toContain("tiphys-agent init --features claude");
    expect(text).toContain("tiphys-agent init --features power");
    expect(text).toContain("Tailscale is not installed");
  });
});

const fakeExec = (map: Record<string, { stdout?: string; code?: number }>): Exec => async (cmd, args) => {
  const key = [cmd.split("/").pop(), ...args].join(" ");
  const hit = Object.entries(map).find(([k]) => key.startsWith(k));
  return { stdout: hit?.[1].stdout ?? "", stderr: "", code: hit ? (hit[1].code ?? 0) : 127 };
};
const TS_STATUS = JSON.stringify({ BackendState: "Running", HaveNodeKey: true, Self: { DNSName: "argo.example-tailnet.ts.net." } });
const SERVE = (port: number, https = 7443) => JSON.stringify({ TCP: { [https]: { HTTPS: true } }, Web: { [`argo.example-tailnet.ts.net:${https}`]: { Handlers: { "/": { Proxy: `http://127.0.0.1:${port}` } } } } });

describe("detection (K5)", () => {
  const env = (over: Partial<DetectEnv> = {}): DetectEnv => ({
    env: { XDG_CURRENT_DESKTOP: "GNOME", XDG_RUNTIME_DIR: "/run/user/1000" },
    exec: fakeExec({ "systemctl --user": {}, "tailscale status": { stdout: TS_STATUS } }),
    which: (c) => ["systemctl", "git", "claude", "docker", "wpctl"].includes(c),
    exists: () => false,
    canUse: async () => true,
    managed: () => false,
    ...over,
  });

  it("enables safe features only and suggests the risky ones", async () => {
    const x = await detect(defaultConfig("x"), env());
    expect(x.session).toBe("gnome");
    expect(x.tailscale).toEqual({ installed: true, running: true, dnsName: "argo.example-tailnet.ts.net" });
    const safe = safeFeatures(x);
    expect(safe).toEqual(["system", "services", "docker", "git", "desktop", "ports"]);
    for (const r of RISKY_FEATURES) expect(safe).not.toContain(r);
    expect(suggestions(x).map((s) => s.feature)).toEqual(expect.arrayContaining(["claude", "control", "power"]));
  });

  it("no docker access, no session, managed install", async () => {
    const x = await detect(defaultConfig("x"), env({ env: {}, canUse: async () => false, managed: () => true }));
    const safe = safeFeatures(x);
    expect(safe).not.toContain("docker");
    expect(safe).not.toContain("desktop");
    expect(safe).toContain("update");
    expect(x.session).toBeNull();
  });

  it("Hyprland wins over the generic Wayland check", async () => {
    const x = await detect(defaultConfig("x"), env({ env: { HYPRLAND_INSTANCE_SIGNATURE: "abc", WAYLAND_DISPLAY: "wayland-1" } }));
    expect(x.session).toBe("hyprland");
  });
});

describe("own URL for pairing (K4)", () => {
  it("parses tailscale serve status", () => {
    expect(servePortsFor(SERVE(7443), 7443)).toEqual([7443]);
    expect(servePortsFor(SERVE(7443, 8443), 7443)).toEqual([8443]);
    expect(servePortsFor(SERVE(9999), 7443)).toEqual([]);
    expect(servePortsFor("garbage", 7443)).toEqual([]);
    const fg = JSON.stringify({ Foreground: { s1: JSON.parse(SERVE(7443, 10443)) } });
    expect(servePortsFor(fg, 7443)).toEqual([10443]);
  });

  it("builds https://<dns>:<serve port>, falls back to 7443, null without Tailscale", async () => {
    const r = await ownAgentUrl(7443, fakeExec({ "tailscale status": { stdout: TS_STATUS }, "tailscale serve": { stdout: SERVE(7443, 8443) } }));
    expect(r).toMatchObject({ url: "https://argo.example-tailnet.ts.net:8443", served: true });
    const none = await ownAgentUrl(7443, fakeExec({ "tailscale status": { stdout: TS_STATUS }, "tailscale serve": { stdout: "{}" } }));
    expect(none).toMatchObject({ url: "https://argo.example-tailnet.ts.net:7443", served: false });
    const missing = await ownAgentUrl(7443, fakeExec({}));
    expect(missing.url).toBeNull();
    expect(missing.state.installed).toBe(false);
  });
});

describe("doctor (K6)", () => {
  const deps = (over: Partial<DoctorDeps> = {}): DoctorDeps => {
    const config = defaultConfig("x");
    config.features = { ...config.features, docker: true, transcribe: true, desktop: true };
    config.push.token = "ntfy-SECRET-token";
    return {
      config,
      configPath: "/home/u/.config/tiphys/agent.json",
      exec: fakeExec({ "tailscale status": { stdout: TS_STATUS }, "tailscale serve": { stdout: SERVE(7443) }, "timedatectl show": { stdout: "yes\n" } }),
      which: (c) => ["systemctl", "hyprctl", "timedatectl", "git"].includes(c),
      exists: async () => true,
      canUse: async () => true,
      stat: async () => ({ mode: 0o100600, uid: 1000 }),
      freeBytes: async () => ({ free: 50e9, total: 100e9 }),
      healthy: async () => true,
      update: async () => ({ current: "0.3.0", latest: "0.3.0", available: false, managed: false, notesUrl: null }),
      nodeVersion: "24.1.0",
      platform: "linux",
      uid: 1000,
      helpersDir: "/x",
      ...over,
    };
  };

  it("all good: every check ok, no secrets in the report", async () => {
    const r = await runDoctor(deps());
    const bad = r.checks.filter((c) => c.status === "fail");
    expect(bad).toEqual([]);
    expect(r.checks.map((c) => c.id)).toEqual(expect.arrayContaining(["tailscale", "tailscale.serve", "agent", "config", "time", "disk", "node", "push", "version"]));
    expect(JSON.stringify(r)).not.toContain("SECRET");
    for (const c of r.checks) expect(formatCheck(c)).not.toMatch(/doctor\./);
  });

  it("reports failures with codes and fix suggestions", async () => {
    const r = await runDoctor(
      deps({
        exec: fakeExec({ "tailscale status": { stdout: TS_STATUS }, "tailscale serve": { stdout: "{}" }, "timedatectl show": { stdout: "no\n" } }),
        stat: async () => ({ mode: 0o100644, uid: 1000 }),
        canUse: async () => false,
        exists: async (p) => !p.includes("transcribe") && !p.includes("tiphys-desktop"),
        which: (c) => ["systemctl", "timedatectl"].includes(c),
        healthy: async () => false,
        nodeVersion: "20.0.0",
        update: async () => ({ current: "0.3.0", latest: "0.4.0", available: true, managed: true, notesUrl: null }),
      }),
    );
    const by = Object.fromEntries(r.checks.map((c) => [c.id, c]));
    expect(by["tailscale.serve"]).toMatchObject({ status: "fail", code: "doctor.tailscale.notServed", fix: "sudo tailscale serve --bg --https=7443 http://127.0.0.1:7443" });
    expect(by.config).toMatchObject({ status: "fail", code: "doctor.config.permissions", params: { mode: "644" } });
    expect(by.config!.fix).toContain("chmod 600");
    expect(by.time).toMatchObject({ status: "warn", code: "doctor.time.notSynced" });
    expect(by.agent).toMatchObject({ status: "fail", code: "doctor.agent.notListening" });
    expect(by.node).toMatchObject({ status: "fail", code: "doctor.node.tooOld" });
    expect(by["feature.docker"]).toMatchObject({ status: "fail", code: "doctor.feature.dockerDenied" });
    expect(by["feature.desktop"]).toMatchObject({ status: "fail", params: { feature: "desktop" } });
    expect(by["feature.transcribe"]).toMatchObject({ status: "fail", code: "doctor.feature.transcribeMissing" });
    expect(by.push).toMatchObject({ status: "warn", code: "doctor.push.notConfigured" });
    expect(by.version).toMatchObject({ status: "warn", code: "doctor.version.outdated" });
  });

  it("missing Tailscale and missing config", async () => {
    const r = await runDoctor(deps({ exec: fakeExec({}), config: null }));
    const by = Object.fromEntries(r.checks.map((c) => [c.id, c]));
    expect(by.tailscale).toMatchObject({ status: "fail", code: "doctor.tailscale.missing" });
    expect(by.config).toMatchObject({ status: "fail", code: "doctor.config.missing", fix: "tiphys-agent init --detect" });
  });

  it("GET /v1/doctor needs a token and returns {version, checks}", async () => {
    const prev = process.env.TIPHYS_RELEASE_URL;
    process.env.TIPHYS_RELEASE_URL = "http://127.0.0.1:9/none";
    clearUpdateCache();
    try {
      const { app, auth } = await testApp();
      expect((await app.inject({ url: "/v1/doctor" })).statusCode).toBe(401);
      const res = await app.inject({ url: "/v1/doctor", headers: auth });
      expect(res.statusCode).toBe(200);
      const body = res.json();
      expect(body.version).toBe("0.4.0");
      for (const c of body.checks) expect(["ok", "warn", "fail"]).toContain(c.status);
    } finally {
      if (prev === undefined) delete process.env.TIPHYS_RELEASE_URL;
      else process.env.TIPHYS_RELEASE_URL = prev;
      clearUpdateCache();
    }
  }, 20_000);
});

// ---- self-update ----------------------------------------------------------------------------------------------------

const keys = generateKeyPairSync("ed25519");
const PUB = keys.publicKey.export({ type: "spki", format: "pem" }).toString();
const other = generateKeyPairSync("ed25519");
const PID = platformId()!;

/** A release directory served over HTTP: <base>/download/v<v>/… and <base>/latest/download/VERSION. */
async function fakeRelease(version: string, o: { tamper?: "sig" | "bundle"; pkgVersion?: string } = {}) {
  const work = await tmp();
  const top = join(work, `tiphys-agent-${version}-${PID}`);
  await mkdir(join(top, "dist"), { recursive: true });
  await writeFile(join(top, "dist", "cli.js"), "// new\n");
  await writeFile(join(top, "package.json"), JSON.stringify({ name: "tiphys-agent", version: o.pkgVersion ?? version }));
  const name = bundleName(version, PID);
  await pexec("tar", ["-czf", join(work, name), "-C", work, `tiphys-agent-${version}-${PID}`]);
  let bundle = await readFile(join(work, name));
  const sums = Buffer.from(`${createHash("sha256").update(bundle).digest("hex")}  ${name}\n`);
  const sig = sign(null, sums, o.tamper === "sig" ? other.privateKey : keys.privateKey);
  if (o.tamper === "bundle") bundle = Buffer.concat([bundle, Buffer.from("x")]);
  const files: Record<string, Buffer> = {
    [`/download/v${version}/SHA256SUMS`]: sums,
    [`/download/v${version}/SHA256SUMS.sig`]: sig,
    [`/download/v${version}/${name}`]: bundle,
    "/latest/download/VERSION": Buffer.from(version + "\n"),
  };
  const server: Server = createServer((req, res) => {
    const f = files[req.url ?? ""];
    res.statusCode = f ? 200 : 404;
    res.end(f ?? "");
  });
  await new Promise<void>((r) => server.listen(0, "127.0.0.1", r));
  servers.push(server);
  const port = (server.address() as { port: number }).port;
  return `http://127.0.0.1:${port}`;
}
const servers: Server[] = [];
afterAll(() => servers.forEach((s) => s.close()));

/** An install.sh layout with the running version 0.3.0. */
async function managedInstall() {
  const root = await realpath(await tmp());
  await mkdir(join(root, "versions", "0.3.0", "dist"), { recursive: true });
  await symlink("versions/0.3.0", join(root, "current"));
  return root;
}

describe("self-update (K8)", () => {
  it("the shipped key is a real ed25519 public key; verification refuses a placeholder", () => {
    expect(createPublicKey(UPDATE_PUBLIC_KEY).asymmetricKeyType).toBe("ed25519");
    // A wrong signature with the real key is simply false; a placeholder refuses to run at all.
    expect(verifySums(Buffer.from("x"), Buffer.alloc(64), UPDATE_PUBLIC_KEY)).toBe(false);
    expect(() => verifySums(Buffer.from("x"), Buffer.alloc(64), "PLACEHOLDER")).toThrow(/noKey/);
  });

  it("this checkout (git) is not a managed install; an install.sh layout is", async () => {
    expect(managedRoot()).toBeNull();
    const root = await managedInstall();
    expect(managedRoot(join(root, "current"))).toBe(root);
    expect(managedRoot(join(root, "versions", "0.3.0"))).toBe(root);
  });

  it("checks the latest release (cached)", async () => {
    clearUpdateCache();
    const base = await fakeRelease("0.4.0");
    const u = await checkUpdate({ releases: base, root: null, current: "0.3.0" });
    expect(u).toEqual({ current: "0.3.0", latest: "0.4.0", available: true, managed: false, notesUrl: `${base}/tag/v0.4.0` });
    clearUpdateCache();
    const down = await checkUpdate({ releases: "http://127.0.0.1:9", root: null, current: "0.3.0" });
    expect(down).toMatchObject({ latest: null, available: false, error: "agent.update.unreachable" });
    clearUpdateCache();
  });

  it("applies a signed release: unpacks, switches current, leaves the guard marker; settle confirms", async () => {
    const base = await fakeRelease("0.4.0");
    const root = await managedInstall();
    const r = await applyUpdate("0.4.0", { releases: base, publicKey: PUB, root, current: "0.3.0" });
    expect(r.dir).toBe(join(root, "versions", "0.4.0"));
    expect(readlinkSync(join(root, "current"))).toBe(join("versions", "0.4.0"));
    expect(readFileSync(join(root, "current", "dist", "cli.js"), "utf8")).toBe("// new\n");
    expect(readFileSync(join(root, "update-pending"), "utf8")).toBe("from=0.3.0\nto=0.4.0\nattempts=0\n");
    await mkdir(join(root, "versions", "0.1.0"));
    expect(await settleUpdate(root, "0.4.0")).toBe("confirmed");
    expect(existsSync(join(root, "update-pending"))).toBe(false);
    expect(existsSync(join(root, "versions", "0.3.0"))).toBe(true);
    expect(existsSync(join(root, "versions", "0.1.0"))).toBe(false);
  });

  it("refuses: bad signature, bad checksum, wrong bundle content, not newer, placeholder key, not managed", async () => {
    const root = await managedInstall();
    const opts = (releases: string) => ({ releases, publicKey: PUB, root, current: "0.3.0" });
    await expect(applyUpdate("0.4.0", opts(await fakeRelease("0.4.0", { tamper: "sig" })))).rejects.toMatchObject({ code: "agent.update.badSignature" });
    await expect(applyUpdate("0.4.0", opts(await fakeRelease("0.4.0", { tamper: "bundle" })))).rejects.toMatchObject({ code: "agent.update.badChecksum" });
    await expect(applyUpdate("0.4.0", opts(await fakeRelease("0.4.0", { pkgVersion: "0.9.9" })))).rejects.toMatchObject({ code: "agent.update.badBundle" });
    const good = await fakeRelease("0.4.0");
    await expect(applyUpdate("0.5.0", opts(good))).rejects.toMatchObject({ code: "agent.update.missingAsset" });
    await expect(applyUpdate("0.3.0", opts(good))).rejects.toMatchObject({ code: "agent.update.notNewer" });
    await expect(applyUpdate("0.4.0", { releases: good, publicKey: "PLACEHOLDER", root, current: "0.3.0" })).rejects.toMatchObject({ code: "agent.update.noKey" });
    // The shipped key doesn't match the test release's key: refused as a bad signature.
    await expect(applyUpdate("0.4.0", { releases: good, root, current: "0.3.0" })).rejects.toMatchObject({ code: "agent.update.badSignature" });
    await expect(applyUpdate("0.4.0", { releases: good, publicKey: PUB, root: null })).rejects.toMatchObject({ code: "agent.update.notManaged" });
    // Nothing changed.
    expect(readlinkSync(join(root, "current"))).toBe("versions/0.3.0");
    expect(existsSync(join(root, "update-pending"))).toBe(false);
  });

  it("parses SHA256SUMS", () => {
    const h = "a".repeat(64);
    expect([...parseSums(`${h}  x.tar.gz\n${h} *y.zip\njunk\n`).keys()]).toEqual(["x.tar.gz", "y.zip"]);
  });

  it("routes: token, feature flag, managed, confirm; apply answers then restarts", async () => {
    const { app, auth } = await testApp();
    expect((await app.inject({ method: "POST", url: "/v1/update/apply", payload: { version: "0.4.0", confirm: true } })).statusCode).toBe(401);
    const off = await app.inject({ method: "POST", url: "/v1/update/apply", headers: auth, payload: { version: "0.4.0", confirm: true } });
    expect(off.json().error.code).toBe("agent.update.disabled");
    const { app: on, auth: auth2 } = await testApp((c) => ({ ...c, features: { ...c.features, update: true } }));
    const nm = await on.inject({ method: "POST", url: "/v1/update/apply", headers: auth2, payload: { version: "0.4.0", confirm: true } });
    expect(nm.statusCode).toBe(409);
    expect(nm.json().error.code).toBe("agent.update.notManaged");
    const nc = await on.inject({ method: "POST", url: "/v1/update/apply", headers: auth2, payload: { version: "0.4.0" } });
    expect(nc.json().error.code).toBe("agent.update.confirmRequired");

    // Full path on a bare app (the device is set by a hook standing in for authentication).
    const base = await fakeRelease("0.4.0");
    const root = await managedInstall();
    const dir = await tmp();
    const store = await ConfigStore.loadOrCreate(join(dir, "agent.json"), "t");
    await store.update((c) => ({ ...c, features: { ...c.features, update: true } }));
    const bare = Fastify();
    bare.addHook("onRequest", async (req) => {
      req.device = { id: "phone", name: "P", tokenHash: "0".repeat(64), createdAt: "x" };
    });
    let restarted = 0;
    const { Notifier } = await import("../src/notify.ts");
    maintenanceRoutes(bare, { store, notifier: new Notifier(() => store.get(), () => {}) }, { releases: base, publicKey: PUB, root, current: "0.3.0" }, () => restarted++);
    clearUpdateCache();
    const check = await bare.inject({ url: "/v1/update" });
    expect(check.json()).toMatchObject({ latest: "0.4.0", available: true, managed: true });
    const res = await bare.inject({ method: "POST", url: "/v1/update/apply", payload: { version: "0.4.0", confirm: true } });
    expect(res.json()).toEqual({ ok: true, version: "0.4.0", restarting: true });
    await wait(700);
    expect(restarted).toBe(1);
    clearUpdateCache();
  });
});

describe("guard marker format matches install.sh's guard", () => {
  it("guard.sh rolls back after 3 failed starts", async () => {
    const root = await managedInstall();
    await mkdir(join(root, "versions", "0.4.0", "dist"), { recursive: true });
    const { switchCurrent } = await import("../src/update.ts");
    await switchCurrent(root, join(root, "versions", "0.4.0"));
    await writeFile(join(root, "update-pending"), "from=0.3.0\nto=0.4.0\nattempts=0\n");
    // Extract the guard from install.sh (between the GUARD markers) and run it like ExecStartPre does.
    const install = await readFile(join(import.meta.dirname, "..", "..", "install.sh"), "utf8");
    const guard = /# BEGIN GUARD\n([\s\S]*?)# END GUARD/.exec(install)?.[1];
    expect(guard).toBeTruthy();
    const g = join(root, "guard.sh");
    await writeFile(g, guard!);
    await chmod(g, 0o755);
    for (let i = 0; i < 3; i++) await pexec("sh", [g, root]);
    expect(readlinkSync(join(root, "current"))).toBe("versions/0.4.0");
    await pexec("sh", [g, root]);
    expect(readlinkSync(join(root, "current"))).toBe("versions/0.3.0");
    expect(existsSync(join(root, "update-pending"))).toBe(false);
  });
});
