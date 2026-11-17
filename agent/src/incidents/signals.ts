// Notification → incident signal (PLAN.md §13.1). The incident room doesn't watch anything itself: it observes the
// notifications the existing monitors send (alerts, docker events, watch, backups, the Uptime Kuma bridge).
import type { AgentConfig } from "../config.ts";
import type { Notice } from "../notify.ts";
import type { Severity, Signal, TargetType } from "./types.ts";

interface Rule {
  role: "open" | "close";
  kind: string;
  targetType: TargetType;
  /** Param holding the target. */
  target: string;
  severity: Severity;
}

const RULES: Record<string, Rule> = {
  "disk.full": { role: "open", kind: "disk", targetType: "mount", target: "mount", severity: "critical" },
  "disk.ok": { role: "close", kind: "disk", targetType: "mount", target: "name", severity: "critical" },
  "service.failed": { role: "open", kind: "service", targetType: "unit", target: "unit", severity: "critical" },
  "service.recovered": { role: "close", kind: "service", targetType: "unit", target: "name", severity: "critical" },
  "grafana.alert": { role: "open", kind: "grafana", targetType: "alert", target: "name", severity: "warning" },
  "grafana.resolved": { role: "close", kind: "grafana", targetType: "alert", target: "name", severity: "warning" },
  "docker.died": { role: "open", kind: "docker.died", targetType: "container", target: "container", severity: "critical" },
  "docker.oom": { role: "open", kind: "docker.oom", targetType: "container", target: "container", severity: "critical" },
  "docker.unhealthy": { role: "open", kind: "docker.unhealthy", targetType: "container", target: "container", severity: "warning" },
  "docker.restartLoop": { role: "open", kind: "docker.restartLoop", targetType: "container", target: "container", severity: "critical" },
  "host.offline": { role: "open", kind: "host", targetType: "host", target: "host", severity: "critical" },
  "host.online": { role: "close", kind: "host", targetType: "host", target: "host", severity: "critical" },
  "backup.failed": { role: "open", kind: "backup", targetType: "backup", target: "id", severity: "critical" },
  "backup.stale": { role: "open", kind: "backup", targetType: "backup", target: "id", severity: "warning" },
  "backup.ok": { role: "close", kind: "backup", targetType: "backup", target: "id", severity: "warning" },
  "uptime.down": { role: "open", kind: "uptime", targetType: "monitor", target: "monitor", severity: "critical" },
  "uptime.up": { role: "close", kind: "uptime", targetType: "monitor", target: "monitor", severity: "critical" },
};

export const SIGNAL_KEYS = Object.keys(RULES);
export const OPENER_KEYS = SIGNAL_KEYS.filter((k) => RULES[k]!.role === "open");

/** null when the notification isn't an incident signal. */
export function signalOf(n: Notice, config: Pick<AgentConfig, "name"> & { incidents: Pick<AgentConfig["incidents"], "links"> }): Signal | null {
  const rule = RULES[n.key];
  if (!rule) return null;
  const p = n.params ?? {};
  const target = String(p[rule.target] ?? "").slice(0, 200);
  if (!target) return null;
  // host.offline/online are about another host; everything else about this one.
  const host = String(p.host ?? config.name).slice(0, 100);
  const severity: Severity = n.key === "grafana.alert" && /^(critical|crit|page|high)$/i.test(String(p.severity ?? "")) ? "critical" : rule.severity;
  const sig: Signal = {
    key: n.key,
    role: rule.role,
    kind: rule.kind,
    fingerprint: `${rule.kind}|${host}|${target}`,
    host,
    target,
    targetType: rule.targetType,
    severity,
    params: p,
  };
  const ctx = n.context ?? {};
  if (rule.targetType === "container") {
    if (ctx.project) sig.stack = ctx.project;
    if (ctx.service) sig.service = ctx.service;
    if (ctx.workingDir) sig.workingDir = ctx.workingDir;
  }
  if (rule.targetType === "unit" && (p.scope === "user" || p.scope === "system")) sig.unitScope = p.scope;
  if (rule.targetType === "monitor") {
    const link = config.incidents.links.find((l) => l.uptimeMonitor === target);
    if (link) {
      sig.stack = link.stack;
      if (link.service) sig.service = link.service;
    }
  }
  if (ctx.test === "1") sig.test = true;
  return sig;
}
