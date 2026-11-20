// CI smoke test on every OS (P3): after `npm run build`, starts the real CLI (`serve`) with a throwaway config on a
// free port, pairs a device with the CLI and calls /v1/health and /v1/system with its token. Never touches the real
// agent (own TIPHYS_AGENT_CONFIG, own port). Usage: node test/smoke.mjs
import { execFileSync, spawn } from "node:child_process";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

const dir = await mkdtemp(join(tmpdir(), "tiphys-smoke-"));
const config = join(dir, "agent.json");
const env = { ...process.env, TIPHYS_AGENT_CONFIG: config };
const cli = (...args) => execFileSync(process.execPath, ["dist/cli.js", ...args], { env, encoding: "utf8", timeout: 60_000 });
const fail = (msg) => {
  console.error(`smoke: ${msg}`);
  process.exitCode = 1;
};

const port = await new Promise((res) => {
  const s = createServer().listen(0, "127.0.0.1", () => {
    const p = s.address().port;
    s.close(() => res(p));
  });
});

cli("init", "--name", "smoke", "--set-features", "system");
const c = JSON.parse(await readFile(config, "utf8"));
c.listen = { host: "127.0.0.1", port };
await writeFile(config, JSON.stringify(c, null, 2));
const token = /Token: (\S+)/.exec(cli("pair", "--name", "ci", "--url", `https://smoke.invalid:${port}`))?.[1];
if (!token) throw new Error("pair printed no token");

const server = spawn(process.execPath, ["dist/cli.js", "serve"], { env, stdio: ["ignore", "ignore", "pipe"] });
let log = "";
server.stderr.on("data", (b) => (log += b));
const base = `http://127.0.0.1:${port}`;
try {
  let health = null;
  for (let i = 0; i < 80 && !health; i++) {
    health = await fetch(`${base}/v1/health`).then((r) => (r.ok ? r.json() : null), () => null);
    if (!health) await new Promise((r) => setTimeout(r, 250));
  }
  if (!health) throw new Error(`agent did not answer\n${log}`);
  if (health.name !== "smoke" || health.features?.system !== true || !Array.isArray(health.unsupported)) fail(`unexpected health ${JSON.stringify(health)}`);
  const anon = await fetch(`${base}/v1/system`);
  if (anon.status !== 401) fail(`/v1/system without token: ${anon.status}`);
  const res = await fetch(`${base}/v1/system`, { headers: { authorization: `Bearer ${token}` } });
  const sys = await res.json();
  if (res.status !== 200) fail(`/v1/system: ${res.status} ${JSON.stringify(sys)}`);
  else if (!(sys.cpu?.cores > 0 && sys.memory?.totalBytes > 0 && Array.isArray(sys.disks) && sys.disks.length > 0)) fail(`unexpected system ${JSON.stringify(sys)}`);
  else console.log(`ok: ${process.platform} health ${JSON.stringify({ version: health.version, unsupported: health.unsupported })}; system ${sys.os}, ${sys.cpu.cores} cores, ${sys.disks.length} disk(s)`);
} finally {
  server.kill();
  await new Promise((r) => (server.exitCode !== null ? r() : server.once("exit", r)));
  await rm(dir, { recursive: true, force: true }).catch(() => {});
}
