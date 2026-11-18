// Findings and score for one host's report (PLAN.md §15, S-1). Pure functions; the app localizes findings by `rule`.
//
// Exposure is judged from the host's own point of view: a listener on 0.0.0.0/::/a public address (or a Docker port
// published on one) is "exposed" unless it is in the host's allowedPorts. Whether a cloud firewall blocks it is not
// visible from inside; the weekly outside scan (S-5) answers that.
import type { Container, Listener, SecurityReport } from "./report.ts";

export type FindingSeverity = "critical" | "high" | "medium" | "low";
export type HostRole = "server" | "desktop";

export interface Finding {
  /** Stable id (rule + subject), e.g. "port.exposed:tcp/2222". */
  id: string;
  rule: string;
  severity: FindingSeverity;
  params: Record<string, string | number>;
}

export interface HostPolicy {
  role: HostRole;
  /** "tcp/22", "udp/41641": exposed listeners that are expected. */
  allowedPorts: string[];
}

/** Always expected on any host: Tailscale's WireGuard port, DHCP clients, mDNS. */
export const DEFAULT_ALLOWED = ["udp/41641", "udp/68", "udp/546", "udp/5353"];

const WEIGHT: Record<FindingSeverity, number> = { critical: 30, high: 15, medium: 6, low: 2 };

/** Hardening sysctls: key → predicate on the value. ip_forward is not listed (Docker needs it). */
const SYSCTL: Record<string, (v: number) => boolean> = {
  "kernel.randomize_va_space": (v) => v === 2,
  "kernel.kptr_restrict": (v) => v >= 1,
  "kernel.dmesg_restrict": (v) => v === 1,
  "kernel.yama.ptrace_scope": (v) => v >= 1,
  "kernel.unprivileged_bpf_disabled": (v) => v >= 1,
  "fs.protected_hardlinks": (v) => v === 1,
  "fs.protected_symlinks": (v) => v === 1,
  "fs.suid_dumpable": (v) => v === 0,
  "net.ipv4.tcp_syncookies": (v) => v === 1,
  "net.ipv4.conf.all.accept_redirects": (v) => v === 0,
  "net.ipv4.conf.all.accept_source_route": (v) => v === 0,
};

const EXPOSED_SCOPES = new Set(["wildcard", "public"]);
const isWildcardIp = (ip: string) => ip === "" || ip === "0.0.0.0" || ip === "::" || ip === "[::]";

export interface Exposure {
  proto: "tcp" | "udp";
  port: number;
  addr: string;
  process: string | null;
}

/** Exposed listeners + Docker ports published on all interfaces (Docker bypasses host firewalls), one per proto/port. */
export function exposures(report: SecurityReport): Exposure[] {
  const out = new Map<string, Exposure>();
  for (const l of report.listen ?? []) {
    if (!EXPOSED_SCOPES.has(l.scope) || l.firewall === "filtered") continue;
    const k = `${l.proto}/${l.port}`;
    if (!out.has(k)) out.set(k, { proto: l.proto, port: l.port, addr: l.addr, process: l.process });
  }
  for (const c of report.docker?.containers ?? []) {
    for (const p of c.ports) {
      if (!isWildcardIp(p.hostIp) && !EXPOSED_SCOPES.has(scopeOfIp(p.hostIp))) continue;
      const proto = p.container.endsWith("/udp") ? "udp" : "tcp";
      const k = `${proto}/${p.hostPort}`;
      const prev = out.get(k);
      if (!prev) out.set(k, { proto, port: p.hostPort, addr: p.hostIp || "0.0.0.0", process: `docker:${c.name}` });
      else if (!prev.process || prev.process === "docker-proxy") prev.process = `docker:${c.name}`;
    }
  }
  return [...out.values()].sort((a, b) => a.proto.localeCompare(b.proto) || a.port - b.port);
}

function scopeOfIp(ip: string): string {
  const a = ip.replace(/^\[|\]$/g, "");
  if (/^127\./.test(a) || a === "::1") return "loopback";
  if (/^100\.(6[4-9]|[7-9]\d|1[01]\d|12[0-7])\./.test(a)) return "tailscale";
  if (/^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)/.test(a)) return "private";
  return "public";
}

const first = (s: Record<string, string[]>, k: string) => s[k]?.[0]?.toLowerCase();

function sshdFindings(report: SecurityReport, add: (f: Finding) => void) {
  const sshd = report.sshd;
  if (!sshd) return;
  const s = sshd.settings;
  // Config mode: unset keys take OpenSSH's defaults.
  const pw = first(s, "passwordauthentication") ?? "yes";
  if (pw === "yes") add({ id: "ssh.passwordAuth", rule: "ssh.passwordAuth", severity: "high", params: {} });
  if ((first(s, "permitemptypasswords") ?? "no") === "yes") add({ id: "ssh.emptyPasswords", rule: "ssh.emptyPasswords", severity: "critical", params: {} });
  const root = first(s, "permitrootlogin") ?? "prohibit-password";
  if (root === "yes") add({ id: "ssh.rootLogin", rule: "ssh.rootLogin", severity: "high", params: { value: root } });
  else if (root !== "no") add({ id: "ssh.rootLogin", rule: "ssh.rootLogin", severity: "low", params: { value: root } });
  const kbd = first(s, "kbdinteractiveauthentication") ?? first(s, "challengeresponseauthentication") ?? "yes";
  if (kbd === "yes" && (first(s, "usepam") ?? "no") === "yes") add({ id: "ssh.kbdInteractive", rule: "ssh.kbdInteractive", severity: "medium", params: {} });
  if ((first(s, "x11forwarding") ?? "no") === "yes") add({ id: "ssh.x11Forwarding", rule: "ssh.x11Forwarding", severity: "low", params: {} });
  const tcp = first(s, "allowtcpforwarding") ?? "yes";
  if (tcp !== "no" && tcp !== "local") add({ id: "ssh.tcpForwarding", rule: "ssh.tcpForwarding", severity: "low", params: { value: tcp } });
  const tries = Number(first(s, "maxauthtries") ?? "6");
  if (tries > 4) add({ id: "ssh.maxAuthTries", rule: "ssh.maxAuthTries", severity: "low", params: { value: tries } });
}

function dockerFindings(containers: Container[], add: (f: Finding) => void) {
  for (const c of containers) {
    if (c.privileged) add({ id: `docker.privileged:${c.name}`, rule: "docker.privileged", severity: "medium", params: { container: c.name } });
    if (c.mounts.some((m) => /(^|\/)docker\.sock$/.test(m.source)))
      add({ id: `docker.socket:${c.name}`, rule: "docker.socket", severity: "medium", params: { container: c.name } });
    if (c.pidMode === "host") add({ id: `docker.hostPid:${c.name}`, rule: "docker.hostPid", severity: "medium", params: { container: c.name } });
    if (c.networkMode === "host") add({ id: `docker.hostNetwork:${c.name}`, rule: "docker.hostNetwork", severity: "low", params: { container: c.name } });
  }
}

export function evaluate(report: SecurityReport, policy: HostPolicy): Finding[] {
  const out = new Map<string, Finding>();
  const add = (f: Finding) => {
    if (!out.has(f.id)) out.set(f.id, f);
  };
  const allowed = new Set([...DEFAULT_ALLOWED, ...policy.allowedPorts]);
  const exp = exposures(report).filter((e) => !allowed.has(`${e.proto}/${e.port}`));
  for (const e of exp) {
    const params: Record<string, string | number> = { proto: e.proto, port: e.port, addr: e.addr };
    if (e.process) params.process = e.process;
    if (!report.firewall && !e.process?.startsWith("docker:")) params.firewall = "unknown";
    add({ id: `port.exposed:${e.proto}/${e.port}`, rule: "port.exposed", severity: "medium", params });
  }

  sshdFindings(report, add);

  for (const u of report.users) {
    if (u.uid === 0 && u.name !== "root") add({ id: `users.uid0:${u.name}`, rule: "users.uid0", severity: "critical", params: { user: u.name } });
  }
  for (const p of report.passwords ?? []) {
    if (p.status === "empty") add({ id: `users.emptyPassword:${p.name}`, rule: "users.emptyPassword", severity: "critical", params: { user: p.name } });
  }

  const u = report.updates;
  if (u.security && u.security > 0) add({ id: "updates.security", rule: "updates.security", severity: "medium", params: { count: u.security } });
  else if (u.pending && u.pending > 0) add({ id: "updates.pending", rule: "updates.pending", severity: "low", params: { count: u.pending } });
  if (u.rebootRequiredSince) {
    const days = Math.floor((Date.now() - Date.parse(u.rebootRequiredSince)) / 86_400_000);
    add({ id: "updates.reboot", rule: "updates.reboot", severity: days >= 7 ? "medium" : "low", params: { days: Math.max(0, days) } });
  }
  if (policy.role === "server" && u.unattended === false) add({ id: "updates.unattendedOff", rule: "updates.unattendedOff", severity: "medium", params: {} });
  if (u.listsUpdatedAt && Date.now() - Date.parse(u.listsUpdatedAt) > 7 * 86_400_000) {
    add({ id: "updates.listsStale", rule: "updates.listsStale", severity: "low", params: { days: Math.floor((Date.now() - Date.parse(u.listsUpdatedAt)) / 86_400_000) } });
  }

  const active = (n: string) => report.services[n]?.active === "active";
  const hasFirewall = report.firewall ? report.firewall.defaultDeny : ["ufw", "firewalld", "nftables"].some(active);
  if (exp.length > 0 && !hasFirewall) {
    add({ id: "firewall.none", rule: "firewall.none", severity: policy.role === "desktop" ? "medium" : "low", params: { exposed: exp.length } });
  }
  if (policy.role === "server") {
    // Only an installed but stopped service is reported; a unit that doesn't exist ("not-found") is a package choice.
    const installed = (n: string) => !!report.services[n] && report.services[n]!.enabled !== "not-found" && report.services[n]!.enabled !== "";
    if (installed("auditd") && !active("auditd")) add({ id: "service.auditd", rule: "service.auditd", severity: "low", params: {} });
    if (installed("apparmor") && !active("apparmor")) add({ id: "service.apparmor", rule: "service.apparmor", severity: "low", params: {} });
  }

  const weak = Object.entries(SYSCTL)
    .filter(([k, ok]) => report.sysctl[k] !== undefined && /^-?\d+$/.test(report.sysctl[k]!) && !ok(Number(report.sysctl[k])))
    .map(([k]) => k);
  if (weak.length) add({ id: "sysctl.weak", rule: "sysctl.weak", severity: "low", params: { keys: weak.join(","), count: weak.length } });

  dockerFindings(report.docker?.containers ?? [], add);

  if (report.worldWritable && report.worldWritable.length > 0) {
    add({ id: "files.worldWritable", rule: "files.worldWritable", severity: "low", params: { count: report.worldWritable.length, example: report.worldWritable[0]!.path } });
  }
  for (const f of report.agentFiles ?? []) {
    const mode = parseInt(f.mode, 8);
    if (mode & 0o077) add({ id: `files.agentPerms:${f.path}`, rule: "files.agentPerms", severity: "medium", params: { path: f.path, mode: f.mode } });
  }

  const order: FindingSeverity[] = ["critical", "high", "medium", "low"];
  return [...out.values()].sort((a, b) => order.indexOf(a.severity) - order.indexOf(b.severity) || a.id.localeCompare(b.id));
}

export function score(findings: Finding[]): number {
  return Math.max(0, 100 - findings.reduce((s, f) => s + WEIGHT[f.severity], 0));
}

export function countBySeverity(findings: Finding[]): Record<FindingSeverity, number> {
  const c: Record<FindingSeverity, number> = { critical: 0, high: 0, medium: 0, low: 0 };
  for (const f of findings) c[f.severity]++;
  return c;
}

export type { Listener };
