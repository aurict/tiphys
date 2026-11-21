// `tiphys-agent doctor` and GET /v1/doctor (K6): read-only health checks of the install.
// Each check returns a code (the app translates it) plus params; `fix` is a shell command *suggestion* that the
// agent never runs. No secrets in the output: only paths, ports, versions, feature and tool names.
import { constants } from "node:fs";
import { access, stat, statfs } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { expandHome, type AgentConfig } from "./config.ts";
import { FEATURE_NAMES, whichIn } from "./detect.ts";
import { dockerFallbacks } from "./platform/common.ts";
import { isSupported } from "./platform/support.ts";
import { defaultExec, servePorts, serveCommand, tailscaleState, type Exec } from "./tailscale.ts";
import type { UpdateInfo } from "./update.ts";
import { VERSION } from "./version.ts";

export type CheckStatus = "ok" | "warn" | "fail";
export interface Check {
  id: string;
  status: CheckStatus;
  code: string;
  params: Record<string, unknown>;
  fix?: string;
}
export interface DoctorReport {
  version: string;
  checks: Check[];
}

export interface DoctorDeps {
  config: AgentConfig | null;
  configPath: string;
  exec: Exec;
  which: (cmd: string) => boolean;
  exists: (p: string) => Promise<boolean>;
  /** Read+write access (docker socket). */
  canUse: (p: string) => Promise<boolean>;
  stat: (p: string) => Promise<{ mode: number; uid: number }>;
  freeBytes: (p: string) => Promise<{ free: number; total: number }>;
  /** GET /v1/health on the agent's own listen address; true when it answers. */
  healthy: (host: string, port: number) => Promise<boolean>;
  update: () => Promise<UpdateInfo>;
  nodeVersion: string;
  platform: NodeJS.Platform;
  uid: number | null;
  /** Directory of bundled helpers (desktop helper binary). */
  helpersDir: string;
}

export function defaultDoctorDeps(config: AgentConfig | null, configPath: string): DoctorDeps {
  return {
    config,
    configPath,
    exec: defaultExec,
    which: (c) => whichIn(process.env.PATH, c),
    exists: (p) => access(p).then(() => true, () => false),
    canUse: (p) => access(p, constants.R_OK | constants.W_OK).then(() => true, () => false),
    stat: (p) => stat(p),
    freeBytes: async (p) => {
      const s = await statfs(p);
      return { free: s.bavail * s.bsize, total: s.blocks * s.bsize };
    },
    healthy: async (host, port) => {
      const h = host === "0.0.0.0" || host === "::" ? "127.0.0.1" : host.includes(":") ? `[${host}]` : host;
      try {
        const r = await fetch(`http://${h}:${port}/v1/health`, { signal: AbortSignal.timeout(2000) });
        return r.ok;
      } catch {
        return false;
      }
    },
    update: async () => (await import("./update.ts")).checkUpdate(),
    nodeVersion: process.versions.node,
    platform: process.platform,
    uid: process.getuid?.() ?? null,
    helpersDir: fileURLToPath(new URL("../helpers", import.meta.url)),
  };
}

const ok = (id: string, code: string, params: Record<string, unknown> = {}): Check => ({ id, status: "ok", code, params });
const warn = (id: string, code: string, params: Record<string, unknown> = {}, fix?: string): Check => ({ id, status: "warn", code, params, ...(fix ? { fix } : {}) });
const fail = (id: string, code: string, params: Record<string, unknown> = {}, fix?: string): Check => ({ id, status: "fail", code, params, ...(fix ? { fix } : {}) });

const INSTALL_TAILSCALE = "curl -fsSL https://tailscale.com/install.sh | sh";
const REINSTALL = "curl -fsSL https://raw.githubusercontent.com/aurict/tiphys/main/install.sh | sh";

function restartCommand(platform: NodeJS.Platform): string {
  if (platform === "darwin") return "launchctl kickstart -k gui/$(id -u)/com.tiphys.agent";
  if (platform === "win32") return 'Start-Process powershell -WindowStyle Hidden -ArgumentList "-NoProfile","-ExecutionPolicy","Bypass","-File","$env:LOCALAPPDATA\\Tiphys\\agent\\run-agent.ps1"';
  return "systemctl --user restart tiphys-agent";
}

async function tailscaleChecks(d: DoctorDeps, port: number): Promise<Check[]> {
  const ts = await tailscaleState(d.exec);
  if (!ts.installed) return [fail("tailscale", "doctor.tailscale.missing", {}, INSTALL_TAILSCALE)];
  const up = d.platform === "linux" ? "sudo tailscale up" : "tailscale up";
  if (!ts.loggedIn) return [fail("tailscale", "doctor.tailscale.loggedOut", { state: ts.backendState }, up)];
  if (!ts.running) return [fail("tailscale", "doctor.tailscale.stopped", { state: ts.backendState }, up)];
  const out: Check[] = [ok("tailscale", "doctor.tailscale.ok", { dnsName: ts.dnsName })];
  const ports = await servePorts(port, d.exec);
  if (ports === null) out.push(warn("tailscale.serve", "doctor.tailscale.serveUnknown", { port }, serveCommand(port)));
  else if (ports.length === 0) out.push(fail("tailscale.serve", "doctor.tailscale.notServed", { port }, serveCommand(port)));
  else out.push(ok("tailscale.serve", "doctor.tailscale.served", { port, httpsPorts: ports }));
  return out;
}

async function configChecks(d: DoctorDeps): Promise<Check[]> {
  if (!d.config) return [fail("config", "doctor.config.missing", { path: d.configPath }, "tiphys-agent init --detect")];
  if (d.platform === "win32") return [ok("config", "doctor.config.ok", { path: d.configPath })];
  try {
    const s = await d.stat(d.configPath);
    const mode = s.mode & 0o777;
    if (d.uid !== null && s.uid !== d.uid) return [fail("config", "doctor.config.wrongOwner", { path: d.configPath, uid: s.uid }, `sudo chown $(id -u):$(id -g) ${d.configPath}`)];
    if (mode & 0o077) return [fail("config", "doctor.config.permissions", { path: d.configPath, mode: mode.toString(8) }, `chmod 600 ${d.configPath}`)];
    return [ok("config", "doctor.config.ok", { path: d.configPath })];
  } catch {
    return [fail("config", "doctor.config.missing", { path: d.configPath }, "tiphys-agent init --detect")];
  }
}

async function timeCheck(d: DoctorDeps): Promise<Check> {
  if (d.platform !== "linux" || !d.which("timedatectl")) return ok("time", "doctor.time.unchecked");
  const r = await d.exec("timedatectl", ["show", "-p", "NTPSynchronized", "--value"]);
  const v = r.stdout.trim();
  if (r.code !== 0 || !v) return ok("time", "doctor.time.unchecked");
  return v === "yes" ? ok("time", "doctor.time.synced") : warn("time", "doctor.time.notSynced", {}, "sudo timedatectl set-ntp true");
}

async function diskCheck(d: DoctorDeps): Promise<Check> {
  try {
    const { free, total } = await d.freeBytes(dirname(d.configPath));
    const params = { freeMb: Math.round(free / 1048576), totalMb: Math.round(total / 1048576) };
    if (free < 512 * 1048576) return fail("disk", "doctor.disk.full", params);
    if (free < 2 * 1024 * 1048576 || free / total < 0.05) return warn("disk", "doctor.disk.low", params);
    return ok("disk", "doctor.disk.ok", params);
  } catch {
    return ok("disk", "doctor.disk.unchecked");
  }
}

function nodeCheck(d: DoctorDeps): Check {
  const major = Number(d.nodeVersion.split(".")[0]);
  const params = { node: d.nodeVersion };
  if (major < 22) return fail("node", "doctor.node.tooOld", params, REINSTALL);
  if (major < 24) return warn("node", "doctor.node.old", params);
  return ok("node", "doctor.node.ok", params);
}

/** Enabled features whose tools are missing. */
async function featureChecks(d: DoctorDeps): Promise<Check[]> {
  const c = d.config;
  if (!c) return [];
  const f = c.features;
  const out: Check[] = [];
  const missing = (feature: string, tools: string[], fix?: string) =>
    out.push(fail(`feature.${feature}`, "doctor.feature.toolsMissing", { feature, tools }, fix));
  if (f.desktop) {
    const helper = d.which("tiphys-desktop") || (await d.exists(join(d.helpersDir, d.platform === "win32" ? "tiphys-desktop.exe" : "tiphys-desktop")));
    if (!d.which("hyprctl") && !helper) missing("desktop", ["hyprctl", "tiphys-desktop"]);
  }
  for (const feature of FEATURE_NAMES) {
    if (f[feature] && !isSupported(feature, d.platform)) {
      out.push(fail(`feature.${feature}`, "doctor.feature.unsupported", { feature, platform: d.platform }, `tiphys-agent init --disable ${feature}`));
    }
  }
  const native = d.platform === "darwin" || d.platform === "win32";
  if (f.docker && native && !process.env.DOCKER_HOST?.startsWith("unix://")) {
    // Docker Desktop: a socket under ~/.docker or a named pipe; the daemon answering is what counts.
    let bin: string | null = d.which("docker") ? "docker" : null;
    for (const p of dockerFallbacks(d.platform)) if (!bin && (await d.exists(p))) bin = p;
    if (!bin) missing("docker", ["docker"], "tiphys-agent init --disable docker");
    else if ((await d.exec(bin, ["version", "--format", "{{.Server.Version}}"])).code !== 0) out.push(fail("feature.docker", "doctor.feature.dockerUnreachable", {}));
  }
  // A TCP DOCKER_HOST (e.g. a socket proxy) is not checked here.
  else if (f.docker && !(process.env.DOCKER_HOST && !process.env.DOCKER_HOST.startsWith("unix://"))) {
    const sock = process.env.DOCKER_HOST?.startsWith("unix://") ? process.env.DOCKER_HOST.slice(7) : "/var/run/docker.sock";
    if (!(await d.exists(sock))) missing("docker", ["docker"], "tiphys-agent init --disable docker");
    else if (!(await d.canUse(sock))) out.push(fail("feature.docker", "doctor.feature.dockerDenied", { socket: sock }, "sudo usermod -aG docker $USER   # then log out and in"));
  }
  if (f.services && d.platform === "linux" && !d.which("systemctl")) missing("services", ["systemctl"]);
  if (f.git && !d.which("git")) missing("git", ["git"]);
  if (f.claude && !d.which("claude") && !(await d.exists(expandHome("~/.claude/local/claude")))) missing("claude", ["claude"], "npm install -g @anthropic-ai/claude-code");
  if (f.screen && d.platform === "linux") out.push(...(await screenChecks(d, c)));
  if (f.transcribe && !(await d.exists(expandHome(c.transcribe.command)))) {
    out.push(fail("feature.transcribe", "doctor.feature.transcribeMissing", { command: c.transcribe.command }));
  }
  return out;
}

/**
 * Screen modes: the kiosk tools on a display host (missing = failure when remote sources are set, as on the laptop;
 * a warning otherwise, the host may only be a source), brightnessctl optional; the source side's pw-record (spectrum)
 * and the ETS2 plugin when the game is installed.
 */
async function screenChecks(d: DoctorDeps, c: AgentConfig): Promise<Check[]> {
  const out: Check[] = [];
  const display = Object.keys(c.screen.sources).length > 0;
  const need = ["systemd-run", "systemd-inhibit", "hyprctl"].filter((t) => !d.which(t));
  if (!d.which("firefox") && !d.which("firefox-esr")) need.push("firefox");
  if (need.length) {
    const check = display || c.screen.placement === "scratch" ? fail : warn;
    out.push(check("feature.screen", "doctor.feature.toolsMissing", { feature: "screen", tools: need }));
  }
  if (display && !d.which("brightnessctl")) out.push(warn("feature.screen.brightness", "doctor.feature.toolsMissing", { feature: "screen", tools: ["brightnessctl"] }));
  if (!d.which("pw-record")) out.push(warn("feature.screen.audio", "doctor.feature.toolsMissing", { feature: "screen", tools: ["pw-record"] }));
  const { findGameDir, pluginStatus } = await import("./screen/ets2.ts");
  const game = await findGameDir();
  if (game) {
    const p = await pluginStatus(game);
    if (p.plugin !== "installed") out.push(warn("feature.screen.ets2", "doctor.gamemode.pluginMissing", { status: p.plugin }, "tiphys-agent gamemode install-plugin"));
  }
  return out;
}

function pushCheck(d: DoctorDeps): Check | null {
  if (!d.config) return null;
  const n = d.config.push.endpoints.length;
  return n > 0 ? ok("push", "doctor.push.ok", { endpoints: n }) : warn("push", "doctor.push.notConfigured");
}

async function versionCheck(d: DoctorDeps): Promise<Check> {
  try {
    const u = await d.update();
    if (u.latest === null) return ok("version", "doctor.version.unchecked", { current: u.current });
    if (!u.available) return ok("version", "doctor.version.latest", { current: u.current, latest: u.latest });
    return warn("version", "doctor.version.outdated", { current: u.current, latest: u.latest, managed: u.managed }, u.managed ? REINSTALL : undefined);
  } catch {
    return ok("version", "doctor.version.unchecked", { current: VERSION });
  }
}

export async function runDoctor(d: DoctorDeps): Promise<DoctorReport> {
  const listen = d.config?.listen ?? { host: "127.0.0.1", port: 7443 };
  const [ts, cfg, time, disk, features, version, listening] = await Promise.all([
    tailscaleChecks(d, listen.port),
    configChecks(d),
    timeCheck(d),
    diskCheck(d),
    featureChecks(d),
    versionCheck(d),
    d.config ? d.healthy(listen.host, listen.port) : Promise.resolve(false),
  ]);
  const agent = !d.config
    ? null
    : listening
      ? ok("agent", "doctor.agent.listening", { host: listen.host, port: listen.port })
      : fail("agent", "doctor.agent.notListening", { host: listen.host, port: listen.port }, restartCommand(d.platform));
  const push = pushCheck(d);
  const checks = [...ts, ...(agent ? [agent] : []), ...cfg, time, disk, nodeCheck(d), ...features, ...(push ? [push] : []), version];
  return { version: VERSION, checks };
}

const TEXT: Record<string, string> = {
  "doctor.tailscale.missing": "Tailscale is not installed. Tiphys reaches this machine only through your tailnet.",
  "doctor.tailscale.loggedOut": "Tailscale is installed but not logged in.",
  "doctor.tailscale.stopped": "Tailscale is not running.",
  "doctor.tailscale.ok": "Tailscale is running as {dnsName}.",
  "doctor.tailscale.serveUnknown": "Could not read `tailscale serve status`.",
  "doctor.tailscale.notServed": "`tailscale serve` does not publish the agent (port {port}) in the tailnet.",
  "doctor.tailscale.served": "`tailscale serve` publishes the agent on HTTPS port(s) {httpsPorts}.",
  "doctor.agent.listening": "Agent answers on {host}:{port}.",
  "doctor.agent.notListening": "Agent does not answer on {host}:{port}.",
  "doctor.config.missing": "No settings file at {path}.",
  "doctor.config.wrongOwner": "{path} belongs to another user (uid {uid}).",
  "doctor.config.permissions": "{path} has mode {mode}; it must be 600 (it holds credentials).",
  "doctor.config.ok": "Settings file {path} is private.",
  "doctor.time.unchecked": "Clock sync not checked.",
  "doctor.time.synced": "Clock is synchronized.",
  "doctor.time.notSynced": "Clock is not synchronized (TLS and schedules need the right time).",
  "doctor.disk.full": "Only {freeMb} MB free disk space.",
  "doctor.disk.low": "Low disk space: {freeMb} MB free.",
  "doctor.disk.ok": "{freeMb} MB free disk space.",
  "doctor.disk.unchecked": "Disk space not checked.",
  "doctor.node.tooOld": "Node.js {node} is too old (22 or newer needed).",
  "doctor.node.old": "Node.js {node} works; 24 is recommended.",
  "doctor.node.ok": "Node.js {node}.",
  "doctor.feature.toolsMissing": "Feature \"{feature}\" is on but needs: {tools}.",
  "doctor.feature.dockerDenied": "Feature \"docker\" is on but {socket} is not accessible to this user.",
  "doctor.feature.unsupported": "Feature \"{feature}\" is on but does not work on {platform}.",
  "doctor.feature.dockerUnreachable": "Feature \"docker\" is on but the Docker daemon does not answer (is Docker Desktop running?).",
  "doctor.feature.transcribeMissing":"Feature \"transcribe\" is on but {command} does not exist.",
  "doctor.gamemode.pluginMissing": "Game mode: the ETS2 telemetry plugin is {status}.",
  "doctor.push.ok": "Push notifications: {endpoints} device(s) registered.",
  "doctor.push.notConfigured": "No device registered for push notifications (set up ntfy in the app).",
  "doctor.version.unchecked": "Version {current}; latest release not reachable.",
  "doctor.version.latest": "Version {current} is the latest.",
  "doctor.version.outdated": "Version {current}; {latest} is available.",
};

export function formatCheck(c: Check): string {
  const text = (TEXT[c.code] ?? c.code).replace(/\{(\w+)\}/g, (_, k: string) => {
    const v = c.params[k];
    return Array.isArray(v) ? v.join(", ") : String(v ?? "");
  });
  const mark = c.status === "ok" ? "[ ok ]" : c.status === "warn" ? "[warn]" : "[FAIL]";
  return `${mark} ${text}${c.fix ? `\n       fix: ${c.fix}` : ""}`;
}
