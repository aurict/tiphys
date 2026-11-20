// Read-only Tailscale queries used by `pair` (own URL), `init --detect` and the doctor (K4/K5/K6/K10).
// Nothing here changes Tailscale; the `tailscale serve` command is only suggested.
import { existsSync } from "node:fs";
import { run, type ExecResult } from "./exec.ts";

export type Exec = (cmd: string, args: string[], opts?: { timeoutMs?: number }) => Promise<ExecResult>;

/** run() with allowFail; a missing command resolves with code 127 instead of throwing. */
export const defaultExec: Exec = (cmd, args, opts) =>
  run(cmd, args, { timeoutMs: opts?.timeoutMs ?? 5000, allowFail: true }).catch((e: { code?: string }) => {
    if (e.code === "agent.exec.commandMissing") return { stdout: "", stderr: "", code: 127 };
    if (e.code === "agent.exec.timeout") return { stdout: "", stderr: "timeout", code: 124 };
    throw e;
  });

/** The CLI binary: on macOS the App Store / standalone app does not put `tailscale` on PATH. */
export function tailscaleBin(): string {
  const mac = "/Applications/Tailscale.app/Contents/MacOS/Tailscale";
  return process.platform === "darwin" && existsSync(mac) ? mac : "tailscale";
}

export interface TailscaleState {
  installed: boolean;
  /** BackendState is "Running". */
  running: boolean;
  /** Logged in (has a node key / not NeedsLogin). */
  loggedIn: boolean;
  /** This machine's MagicDNS name without the trailing dot, e.g. argo.my-tailnet.ts.net. */
  dnsName: string | null;
  backendState: string | null;
}

export async function tailscaleState(exec: Exec = defaultExec): Promise<TailscaleState> {
  const r = await exec(tailscaleBin(), ["status", "--json"]);
  if (r.code === 127) return { installed: false, running: false, loggedIn: false, dnsName: null, backendState: null };
  let j: { BackendState?: string; Self?: { DNSName?: string }; HaveNodeKey?: boolean } = {};
  try {
    j = JSON.parse(r.stdout);
  } catch {
    // `tailscale status --json` prints JSON even when stopped; anything else means the daemon is not reachable.
  }
  const state = typeof j.BackendState === "string" ? j.BackendState : null;
  const dns = j.Self?.DNSName?.replace(/\.$/, "") || null;
  return {
    installed: true,
    running: state === "Running",
    loggedIn: state !== null && state !== "NeedsLogin" && state !== "NoState" && j.HaveNodeKey !== false,
    dnsName: dns,
    backendState: state,
  };
}

type ServeConfig = { Web?: Record<string, { Handlers?: Record<string, { Proxy?: string }> }>; Foreground?: Record<string, ServeConfig> };

/**
 * HTTPS port(s) on which `tailscale serve` proxies to the agent's local port, from `tailscale serve status --json`
 * (`Web["host:port"].Handlers["/"].Proxy` = http://127.0.0.1:<agentPort>). Empty when nothing maps to it.
 */
export function servePortsFor(serveJson: string, agentPort: number): number[] {
  let cfg: ServeConfig;
  try {
    cfg = JSON.parse(serveJson || "{}") as ServeConfig;
  } catch {
    return [];
  }
  const webs = [cfg.Web ?? {}, ...Object.values(cfg.Foreground ?? {}).map((f) => f.Web ?? {})];
  const target = new RegExp(`^(https?://)?(127\\.0\\.0\\.1|localhost|\\[::1\\]):${agentPort}/?$`);
  const out = new Set<number>();
  for (const web of webs) {
    for (const [hostPort, v] of Object.entries(web)) {
      const proxy = v.Handlers?.["/"]?.Proxy;
      const port = Number(/:(\d+)$/.exec(hostPort)?.[1]);
      if (proxy && target.test(proxy) && Number.isInteger(port)) out.add(port);
    }
  }
  return [...out].sort((a, b) => a - b);
}

export async function servePorts(agentPort: number, exec: Exec = defaultExec): Promise<number[] | null> {
  const r = await exec(tailscaleBin(), ["serve", "status", "--json"]);
  if (r.code !== 0) return null;
  return servePortsFor(r.stdout, agentPort);
}

/** The command that publishes the agent in the tailnet (K10). Linux needs root unless `tailscale set --operator`. */
export function serveCommand(agentPort: number, httpsPort = 7443): string {
  const sudo = process.platform === "linux" ? "sudo " : "";
  return `${sudo}tailscale serve --bg --https=${httpsPort} http://127.0.0.1:${agentPort}`;
}

/**
 * The agent's own address for pairing: https://<MagicDNS name>:<serve port>. The serve port is the one mapped to the
 * agent (7443 preferred), else 7443. Null when Tailscale is missing, stopped or has no DNS name.
 */
export async function ownAgentUrl(agentPort: number, exec: Exec = defaultExec): Promise<{ url: string | null; state: TailscaleState; served: boolean }> {
  const state = await tailscaleState(exec);
  if (!state.installed || !state.running || !state.dnsName) return { url: null, state, served: false };
  const ports = (await servePorts(agentPort, exec)) ?? [];
  const port = ports.includes(7443) ? 7443 : (ports[0] ?? 7443);
  return { url: `https://${state.dnsName}:${port}`, state, served: ports.length > 0 };
}
