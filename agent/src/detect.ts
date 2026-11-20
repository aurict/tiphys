// `tiphys-agent init --detect` (K5): looks at what this machine has and turns on the safe features only.
// Risky features (anything that runs code, drives the desktop, cuts power or reaches other machines) are never turned
// on automatically; they are printed as suggestions. Also holds the init feature semantics:
//   --features a,b      ADDS to the current list            --disable a,b   turns these off
//   --set-features a,b  exact list (everything else off)    --detect        adds the detected safe features
import { constants, existsSync } from "node:fs";
import { access } from "node:fs/promises";
import { join, delimiter } from "node:path";
import { homedir, hostname } from "node:os";
import { agentConfigSchema, ConfigStore, defaultConfig, expandHome, type AgentConfig } from "./config.ts";
import { defaultExec, tailscaleState, type Exec } from "./tailscale.ts";

export type FeatureName = keyof AgentConfig["features"];
export const FEATURE_NAMES = Object.keys(agentConfigSchema.shape.features.shape) as FeatureName[];

/** Never enabled by --detect: they run code, drive the desktop, cut power, read secrets or reach other machines. */
export const RISKY_FEATURES: readonly FeatureName[] = [
  "control", "claude", "power", "securityFix", "databases", "research", "agy", "analysis", "configfiles",
  "security", "telegram", "incidents", "wake", "homepage", "uptime", "watch", "alerts", "backups",
];

export interface Detected {
  session: "hyprland" | "sway" | "gnome" | "kde" | "x11" | "wayland" | null;
  systemdUser: boolean;
  docker: boolean;
  pipewire: boolean;
  playerctl: boolean;
  velour: boolean;
  firefox: boolean;
  claude: boolean;
  git: boolean;
  tailscale: { installed: boolean; running: boolean; dnsName: string | null };
  transcribe: boolean;
  /** Running from an install.sh layout (versions/<v> + current). */
  managed: boolean;
}

export interface DetectEnv {
  env: NodeJS.ProcessEnv;
  exec: Exec;
  /** Command on PATH? */
  which: (cmd: string) => boolean;
  exists: (p: string) => boolean;
  /** Read+write access (docker socket). */
  canUse: (p: string) => Promise<boolean>;
  managed: () => boolean;
}

export function whichIn(pathVar: string | undefined, cmd: string): boolean {
  const exts = process.platform === "win32" ? ["", ".exe", ".cmd", ".bat"] : [""];
  return (pathVar ?? "").split(delimiter).some((d) => d && exts.some((e) => existsSync(join(d, cmd + e))));
}

export function defaultDetectEnv(): DetectEnv {
  return {
    env: process.env,
    exec: defaultExec,
    which: (c) => whichIn(process.env.PATH, c),
    exists: existsSync,
    canUse: (p) => access(p, constants.R_OK | constants.W_OK).then(() => true, () => false),
    managed: () => false,
  };
}

function sessionOf(env: NodeJS.ProcessEnv, exists: (p: string) => boolean): Detected["session"] {
  const desk = (env.XDG_CURRENT_DESKTOP ?? env.XDG_SESSION_DESKTOP ?? "").toLowerCase();
  const runtime = env.XDG_RUNTIME_DIR;
  if (env.HYPRLAND_INSTANCE_SIGNATURE || desk.includes("hyprland") || (runtime && exists(join(runtime, "hypr")))) return "hyprland";
  if (env.SWAYSOCK || desk.includes("sway")) return "sway";
  if (desk.includes("gnome")) return "gnome";
  if (desk.includes("kde") || desk.includes("plasma")) return "kde";
  if (env.WAYLAND_DISPLAY) return "wayland";
  if (env.DISPLAY) return "x11";
  return null;
}

export async function detect(config: AgentConfig, d: DetectEnv = defaultDetectEnv()): Promise<Detected> {
  const dockerSock = d.env.DOCKER_HOST?.startsWith("unix://") ? d.env.DOCKER_HOST.slice(7) : "/var/run/docker.sock";
  const runtime = d.env.XDG_RUNTIME_DIR;
  const [systemd, docker, ts, transcribe] = await Promise.all([
    d.which("systemctl") ? d.exec("systemctl", ["--user", "show-environment"]).then((r) => r.code === 0) : Promise.resolve(false),
    d.which("docker") || d.exists(dockerSock) ? d.canUse(dockerSock) : Promise.resolve(false),
    tailscaleState(d.exec),
    Promise.resolve(d.exists(expandHome(config.transcribe.command))),
  ]);
  return {
    session: sessionOf(d.env, d.exists),
    systemdUser: systemd,
    docker,
    pipewire: d.which("wpctl"),
    playerctl: d.which("playerctl"),
    velour: !!runtime && d.exists(join(runtime, "velour")),
    firefox: d.which("firefox") || d.which("firefox-esr"),
    claude: d.which("claude") || d.exists(join(homedir(), ".claude", "local", "claude")),
    git: d.which("git"),
    tailscale: { installed: ts.installed, running: ts.running, dnsName: ts.dnsName },
    transcribe,
    managed: d.managed(),
  };
}

/** Safe features the detection supports turning on. */
export function safeFeatures(x: Detected): FeatureName[] {
  const out: FeatureName[] = ["system"];
  if (x.systemdUser) out.push("services");
  if (x.docker) out.push("docker");
  if (x.git) out.push("git");
  if (x.session) out.push("desktop");
  if (x.tailscale.installed) out.push("ports");
  if (x.transcribe) out.push("transcribe");
  if (x.managed) out.push("update");
  return out;
}

/** Risky features worth a look on this machine, with the reason (printed, never applied). */
export function suggestions(x: Detected): Array<{ feature: FeatureName; reason: string }> {
  const s: Array<{ feature: FeatureName; reason: string }> = [];
  if (x.claude) s.push({ feature: "claude", reason: "Claude CLI found" });
  if (x.session) s.push({ feature: "control", reason: `desktop session (${x.session}): remote control inside a timed control session` });
  if (x.systemdUser) s.push({ feature: "power", reason: "suspend/reboot/shutdown from the phone" });
  if (x.docker) s.push({ feature: "databases", reason: "database console for containers" });
  return s;
}

export class FeatureError extends Error {}

function parseList(v: string | undefined): FeatureName[] {
  if (v === undefined) return [];
  const names = v.split(",").map((s) => s.trim()).filter(Boolean);
  const bad = names.filter((n) => !(FEATURE_NAMES as string[]).includes(n));
  if (bad.length) throw new FeatureError(`unknown feature(s): ${bad.join(", ")} (known: ${FEATURE_NAMES.join(", ")})`);
  return names as FeatureName[];
}

export interface FeaturePlan {
  features: AgentConfig["features"];
  enabled: FeatureName[];
  disabled: FeatureName[];
}

/**
 * Applies the init options to the current feature map. `fresh`: the config file was created by this command, so with
 * --detect the list starts empty (only detected + listed features) instead of the schema defaults.
 */
export function planFeatures(
  current: AgentConfig["features"],
  o: { features?: string; setFeatures?: string; disable?: string; detected?: FeatureName[]; fresh?: boolean },
): FeaturePlan {
  if (o.features !== undefined && o.setFeatures !== undefined) throw new FeatureError("use either --features (add) or --set-features (exact list), not both");
  const add = parseList(o.features);
  const exact = o.setFeatures !== undefined ? parseList(o.setFeatures) : null;
  const off = parseList(o.disable);
  const clash = off.filter((f) => add.includes(f) || exact?.includes(f));
  if (clash.length) throw new FeatureError(`both enabled and disabled: ${clash.join(", ")}`);
  const next = { ...current };
  const startEmpty = exact !== null || (o.fresh === true && o.detected !== undefined);
  if (startEmpty) for (const k of FEATURE_NAMES) next[k] = false;
  for (const k of [...(exact ?? []), ...(o.detected ?? []), ...add]) next[k] = true;
  for (const k of off) next[k] = false;
  return {
    features: next,
    enabled: FEATURE_NAMES.filter((k) => next[k] && !current[k]),
    disabled: FEATURE_NAMES.filter((k) => !next[k] && current[k]),
  };
}

export function describeDetected(x: Detected): string[] {
  const yes = (b: boolean) => (b ? "yes" : "no");
  return [
    `  desktop session: ${x.session ?? "none"}`,
    `  systemd user services: ${yes(x.systemdUser)}`,
    `  docker socket usable: ${yes(x.docker)}`,
    `  PipeWire (wpctl): ${yes(x.pipewire)}   playerctl: ${yes(x.playerctl)}   Velour: ${yes(x.velour)}`,
    `  Firefox: ${yes(x.firefox)}   Claude CLI: ${yes(x.claude)}   git: ${yes(x.git)}`,
    `  Tailscale: ${x.tailscale.installed ? (x.tailscale.running ? `running (${x.tailscale.dnsName ?? "no DNS name"})` : "installed, not running") : "not installed"}`,
    `  transcription command: ${yes(x.transcribe)}`,
    `  installed with install.sh (self-update): ${yes(x.managed)}`,
  ];
}

export interface InitOptions {
  name?: string;
  tailscaleLogin?: string;
  features?: string;
  setFeatures?: string;
  disable?: string;
  detect?: boolean;
}

/** `tiphys-agent init`: creates the settings file if missing and applies the options. Throws FeatureError on bad lists. */
export async function initCommand(configPath: string, o: InitOptions, log: (s: string) => void = console.log, env?: DetectEnv): Promise<FeaturePlan> {
  // Validate the lists before anything is written.
  planFeatures(defaultConfig("x").features, { features: o.features, setFeatures: o.setFeatures, disable: o.disable });
  const fresh = !existsSync(configPath);
  const store = await ConfigStore.loadOrCreate(configPath, o.name ?? hostname());
  let detected: FeatureName[] | undefined;
  let suggested: Array<{ feature: FeatureName; reason: string }> = [];
  if (o.detect) {
    let denv = env;
    if (!denv) {
      const { managedRoot } = await import("./update.ts");
      denv = { ...defaultDetectEnv(), managed: () => managedRoot() !== null };
    }
    const x = await detect(store.get(), denv);
    log("Detected on this machine:\n" + describeDetected(x).join("\n"));
    detected = safeFeatures(x);
    suggested = suggestions(x);
    if (!x.tailscale.installed) log("\nTailscale is not installed: the phone can only reach this agent through Tailscale (https://tailscale.com/download).");
  }
  const plan = planFeatures(store.get().features, { features: o.features, setFeatures: o.setFeatures, disable: o.disable, detected, fresh });
  await store.update((c) => {
    if (o.name) c.name = o.name;
    if (o.tailscaleLogin) c.requireTailscaleLogin = o.tailscaleLogin;
    c.features = plan.features;
    return c;
  });
  log(`Settings file: ${configPath}`);
  if (!fresh && plan.enabled.length) log(`Turned on: ${plan.enabled.join(", ")}`);
  if (!fresh && plan.disabled.length) log(`Turned off: ${plan.disabled.join(", ")}`);
  log(`Features now on: ${FEATURE_NAMES.filter((k) => plan.features[k]).join(", ") || "none"}`);
  const rest = suggested.filter((s) => !plan.features[s.feature]);
  if (rest.length) {
    log("\nNot turned on automatically (they can run code, drive the desktop or cut power). If you want them:");
    for (const s of rest) log(`  tiphys-agent init --features ${s.feature}    # ${s.reason}`);
  }
  if (!fresh && (plan.enabled.length || plan.disabled.length)) log("\nRestart the agent for feature changes to take effect.");
  return plan;
}
