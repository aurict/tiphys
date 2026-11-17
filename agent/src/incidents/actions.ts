// Incident actions (PLAN.md §13.1, I-1): an allowlist. The agent derives the candidates from the incident's parts and
// the discovered stacks only (never from logs or model output); each runs without a shell, after a preview and an
// explicit confirmation. I-1 kinds: container.restart, compose.recreate (`up -d --no-deps <svc>`, which also applies
// .env changes, unlike `compose restart`), unit.restart (user and system units, as the services feature allows).
// I-2 kinds: compose.rollback (only when the service's `tiphys-rollback/…:prev` tag exists: re-tag the previous image
// as the service's image reference, then `up -d --no-deps --pull never <svc>`), disk.cleanup (chosen sub-options).
import { createHash } from "node:crypto";
import { SERVICE_NAME, type Stack } from "../stacks.ts";
import { stableJson } from "../preview.ts";
import { CONTAINER_RE, UNIT_RE } from "./context.ts";
import { IMAGE_REF_RE } from "./deploys.ts";
import { CLEANUP_ARGV, type CleanupOption } from "./disk_cleanup.ts";
import type { Incident } from "./types.ts";

export type ActionKind = "container.restart" | "compose.recreate" | "unit.restart" | "compose.rollback" | "disk.cleanup";

export type ActionTarget = { container: string } | { stack: string; service: string } | { scope: "user" | "system"; unit: string } | { mount: string };

/** What a rollback would do: the service's current image and the one tagged `:prev`. */
export interface RollbackInfo {
  tag: string;
  imageRef: string;
  current: { imageId: string; created: string | null };
  previous: { imageId: string; created: string | null };
}

/** Inputs some kinds need besides the candidate: rollback details, the chosen cleanup options. */
export interface StepExtras {
  rollback?: RollbackInfo | null;
  cleanup?: CleanupOption[];
}

export interface Candidate {
  id: string;
  kind: ActionKind;
  target: ActionTarget;
  risk: "low" | "medium";
}

export interface Step {
  argv: string[];
  cwd?: string;
}

export const candidateId = (kind: ActionKind, target: ActionTarget) =>
  "c-" + createHash("sha256").update(`${kind}|${stableJson(target)}`).digest("hex").slice(0, 12);

const make = (kind: ActionKind, target: ActionTarget, risk: Candidate["risk"]): Candidate => ({ id: candidateId(kind, target), kind, target, risk });

/** Rollback is offered for a service whose image can be re-tagged (a tag reference, not a digest or an id). */
export const rollbackable = (r: RollbackInfo | null | undefined): r is RollbackInfo =>
  !!r && IMAGE_REF_RE.test(r.imageRef) && !r.imageRef.startsWith("sha256:") && !r.imageRef.includes("@") && r.current.imageId !== r.previous.imageId;

/**
 * Candidates for an incident; `stack` is the incident's discovered stack (or undefined), `rollback` what the
 * service's `:prev` tag points at (null/undefined → no rollback offered).
 */
export function candidatesFor(i: Incident, stack: Stack | undefined, rollback?: RollbackInfo | null): Candidate[] {
  if (i.test) return [];
  const out = new Map<string, Candidate>();
  const add = (c: Candidate) => out.set(c.id, c);
  for (const p of i.parts) {
    if (p.targetType === "container" && CONTAINER_RE.test(p.target)) add(make("container.restart", { container: p.target }, "low"));
    if (p.targetType === "unit" && UNIT_RE.test(p.target) && !p.target.startsWith("-")) add(make("unit.restart", { scope: p.unitScope ?? "user", unit: p.target }, "low"));
    if (p.targetType === "mount" && p.target.startsWith("/")) add(make("disk.cleanup", { mount: p.target }, "medium"));
  }
  const diskHint = i.hints.find((h) => h.code === "diskFull");
  if (diskHint && typeof diskHint.params.mount === "string" && diskHint.params.mount.startsWith("/")) add(make("disk.cleanup", { mount: diskHint.params.mount }, "medium"));
  if (stack && i.service && SERVICE_NAME.test(i.service) && stack.services.includes(i.service)) {
    add(make("compose.recreate", { stack: stack.id, service: i.service }, "medium"));
    if (rollbackable(rollback)) add(make("compose.rollback", { stack: stack.id, service: i.service }, "medium"));
  }
  return [...out.values()];
}

/** The commands a candidate runs; null → not runnable (missing stack, no rollback image, no cleanup option). */
export function stepsFor(c: Candidate, stack: Stack | undefined, x: StepExtras = {}): Step[] | null {
  const t = c.target as Record<string, string>;
  switch (c.kind) {
    case "container.restart":
      return CONTAINER_RE.test(t.container ?? "") ? [{ argv: ["docker", "restart", t.container!] }] : null;
    case "unit.restart":
      if (!UNIT_RE.test(t.unit ?? "") || t.unit!.startsWith("-")) return null;
      return [{ argv: ["systemctl", ...(t.scope === "user" ? ["--user"] : []), "--no-ask-password", "restart", t.unit!] }];
    case "compose.recreate": {
      if (!stack || stack.id !== t.stack || !stack.services.includes(t.service ?? "")) return null;
      const files = stack.composeFiles.flatMap((f) => ["-f", f]);
      return [{ argv: ["docker", "compose", ...files, "up", "-d", "--no-deps", t.service!], cwd: stack.dir }];
    }
    case "compose.rollback": {
      if (!stack || stack.id !== t.stack || !stack.services.includes(t.service ?? "") || !rollbackable(x.rollback)) return null;
      const files = stack.composeFiles.flatMap((f) => ["-f", f]);
      return [
        { argv: ["docker", "tag", x.rollback.previous.imageId, x.rollback.imageRef] },
        { argv: ["docker", "compose", ...files, "up", "-d", "--no-deps", "--pull", "never", t.service!], cwd: stack.dir },
      ];
    }
    case "disk.cleanup": {
      const opts = (x.cleanup ?? []).filter((o): o is keyof typeof CLEANUP_ARGV => o in CLEANUP_ARGV);
      return opts.length ? opts.map((o) => ({ argv: [...CLEANUP_ARGV[o]] })) : null;
    }
  }
}
