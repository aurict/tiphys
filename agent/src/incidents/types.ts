// Incident room data shapes (PLAN.md §13.1). Stored as incidents/<id>.json; incidents/index.json holds the summaries.
import type { AnalysisResult } from "../analysis/schema.ts";
import type { DeployRecord } from "./deploys.ts";

export type IncidentStatus = "open" | "acknowledged" | "resolved";
export type Severity = "critical" | "warning";
export type TargetType = "container" | "unit" | "mount" | "host" | "backup" | "monitor" | "alert";

/** A notification interpreted as an incident signal. */
export interface Signal {
  /** Notification key, e.g. docker.died. */
  key: string;
  role: "open" | "close";
  /** Fingerprint kind: docker.died, docker.oom, docker.unhealthy, docker.restartLoop, disk, service, grafana, host, backup, uptime. */
  kind: string;
  /** `kind|host|target` */
  fingerprint: string;
  host: string;
  target: string;
  targetType: TargetType;
  severity: Severity;
  /** Stack id (or compose project name when the stack isn't discovered) and compose service. */
  stack?: string;
  service?: string;
  /** For containers: the compose working directory label (a hint only). */
  workingDir?: string;
  unitScope?: "user" | "system";
  params: Record<string, string | number>;
  test?: boolean;
}

/** One fingerprint inside an incident (an incident can group several, e.g. uptime down + container died). */
export interface IncidentPart {
  fingerprint: string;
  kind: string;
  target: string;
  targetType: TargetType;
  unitScope?: "user" | "system";
  workingDir?: string;
  firstAt: string;
  lastAt: string;
  /** Set when the signal cleared (closer notification, or the container runs healthy again); cleared by a new signal. */
  recoveredAt?: string;
}

export type TimelineType =
  | "opened" | "signal" | "merged" | "recovered" | "acknowledged" | "resolved" | "reopened" | "note" | "context"
  | "action" | "actionResult" | "postCheck" | "analysis" | "analysisResult";

export interface TimelineEntry {
  at: string;
  type: TimelineType;
  /** "device:<id>", "agent" or "auto". */
  by?: string;
  key?: string;
  text?: string;
  data?: Record<string, string | number | boolean | null>;
}

export interface Hint {
  /** Translated by the app: incident.hint.<code>. */
  code: "oom" | "recentDeploy" | "diskFull" | "portUnreachable" | "portInUse" | "restartLoop" | "unhealthy" | "exitCode";
  params: Record<string, string | number>;
  /** Context sections the hint is based on (logs, inspect, metrics, git, events, signals, deploys). */
  evidence: string[];
}

export interface InspectSummary {
  name: string;
  image: string;
  imageId: string;
  created: string;
  startedAt: string | null;
  finishedAt: string | null;
  status: string;
  running: boolean;
  exitCode: number | null;
  oomKilled: boolean;
  restartCount: number;
  restartPolicy: string | null;
  health: string | null;
  project: string | null;
  service: string | null;
}

export interface HostSample {
  t: number;
  cpu: number;
  load1: number;
  memPct: number;
  swapPct: number;
  disks: Array<{ mount: string; pct: number }>;
}

export interface ContainerSample {
  t: number;
  cpu: number;
  memPct: number;
  memBytes: number;
}

export interface IncidentContext {
  collectedAt: string;
  logs?: { source: "docker" | "journal"; target: string; lines: string[]; truncated: boolean };
  inspect?: InspectSummary;
  git?: { repo: string; log: Array<{ hash: string; date: string; subject: string }>; status: string[] };
  metrics?: { host: HostSample[]; container?: { name: string; samples: ContainerSample[] } };
  events?: Array<{ at: string; key: string; params: Record<string, string | number> }>;
  /** Deploy history of the incident's compose project (last 7 days, newest first, at most 20). */
  deploys?: DeployRecord[];
  /** config.saved / config.restored events of the last 48 hours (the stack's files when the stack is known): key names only. */
  configChanges?: Array<{ at: string; key: string; file: string; keys: string[] }>;
  /** Same fingerprint, last 90 days; `kind`/`status` since I-3 (older records lack them). */
  similar?: Array<{ id: string; kind?: string; status?: IncidentStatus; openedAt: string; resolvedAt: string | null; resolutionNote: string | null; workedAction: string | null }>;
  /** Sections that failed to collect: {section: error code}. */
  errors?: Record<string, string>;
}

/**
 * AI analysis state (I-3). queued/running → done (result) | failed (the model or validation failed: error) |
 * unavailable (remote PC unreachable, busy, refused, timed out: reason). The rule hints stay either way.
 */
export interface IncidentAnalysis {
  status: "queued" | "running" | "done" | "failed" | "unavailable";
  mode: "local" | "remote";
  /** "device:<id>" or "auto" (on open, after context collection). */
  by: string;
  requestedAt: string;
  finishedAt?: string;
  /** Job id on the PC (remote) or in the local queue. */
  jobId?: string;
  result?: AnalysisResult;
  error?: { code: string; params: Record<string, unknown> };
  reason?: string;
}

export interface Incident {
  id: string;
  status: IncidentStatus;
  severity: Severity;
  host: string;
  /** Key and target of the first signal (the app builds the title from them). */
  kind: string;
  target: string;
  stack?: string;
  service?: string;
  parts: IncidentPart[];
  openedAt: string;
  updatedAt: string;
  lastSignalAt: string;
  acknowledgedAt?: string;
  resolvedAt?: string;
  resolvedBy?: string;
  /** All parts recovered at this time; auto-resolved after 10 stable minutes. */
  recoveredAt?: string;
  resolutionNote?: string;
  /** Kind of the last action whose post-check passed. */
  workedAction?: string;
  signalCount: number;
  signals: Array<{ at: string; key: string; params: Record<string, string | number> }>;
  timeline: TimelineEntry[];
  context?: IncidentContext;
  hints: Hint[];
  analysis?: IncidentAnalysis;
  test?: boolean;
}

export interface IncidentSummary {
  id: string;
  status: IncidentStatus;
  severity: Severity;
  host: string;
  kind: string;
  target: string;
  stack: string | null;
  service: string | null;
  openedAt: string;
  updatedAt: string;
  lastSignalAt: string;
  resolvedAt: string | null;
  signalCount: number;
  fingerprints: string[];
  resolutionNote: string | null;
  workedAction: string | null;
  test: boolean;
}

export function summaryOf(i: Incident): IncidentSummary {
  return {
    id: i.id,
    status: i.status,
    severity: i.severity,
    host: i.host,
    kind: i.kind,
    target: i.target,
    stack: i.stack ?? null,
    service: i.service ?? null,
    openedAt: i.openedAt,
    updatedAt: i.updatedAt,
    lastSignalAt: i.lastSignalAt,
    resolvedAt: i.resolvedAt ?? null,
    signalCount: i.signalCount,
    fingerprints: i.parts.map((p) => p.fingerprint),
    resolutionNote: i.resolutionNote ?? null,
    workedAction: i.workedAction ?? null,
    test: i.test === true,
  };
}
