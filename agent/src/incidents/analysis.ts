// Rule-based hints (PLAN.md §13.1, always on; the AI analysis comes in I-3). Each hint is a code the app translates,
// with the context sections it is based on. Hints never select or change actions.
import type { Hint, Incident, IncidentContext } from "./types.ts";

const RECENT_DEPLOY_MS = 3600_000;
const DISK_FULL_PCT = 95;

export function ruleHints(i: Pick<Incident, "parts" | "signals" | "openedAt"> & Partial<Pick<Incident, "service">>, ctx: IncidentContext | undefined): Hint[] {
  const hints: Hint[] = [];
  const kinds = new Set(i.parts.map((p) => p.kind));
  const insp = ctx?.inspect;
  const opened = Date.parse(i.openedAt);

  if (kinds.has("docker.oom") || insp?.oomKilled || insp?.exitCode === 137) {
    hints.push({ code: "oom", params: insp?.exitCode != null ? { exitCode: insp.exitCode } : {}, evidence: insp ? ["inspect", "signals"] : ["signals"] });
  } else if (insp && insp.exitCode !== null && insp.exitCode !== 0 && !insp.running) {
    hints.push({ code: "exitCode", params: { exitCode: insp.exitCode }, evidence: ["inspect"] });
  }
  if (kinds.has("docker.restartLoop") || (insp && insp.restartCount >= 3)) {
    hints.push({ code: "restartLoop", params: insp ? { restartCount: insp.restartCount } : {}, evidence: insp ? ["inspect", "signals"] : ["signals"] });
  }
  if (kinds.has("docker.unhealthy") || insp?.health === "unhealthy") {
    hints.push({ code: "unhealthy", params: {}, evidence: insp ? ["inspect"] : ["signals"] });
  }
  // An image change of the incident's service (or, without a service, of its stack) within the hour before the
  // incident. The container's creation time is the deploy time (the snapshot can come a few seconds later).
  const deploy = ctx?.deploys?.find((r) => {
    if (r.kind !== "changed" || (i.service && r.service !== i.service)) return false;
    const t = Date.parse(r.createdAt);
    return t <= opened && opened - t < RECENT_DEPLOY_MS;
  });
  if (deploy) {
    hints.push({
      code: "recentDeploy",
      params: { service: deploy.service, created: deploy.createdAt, image: deploy.imageRef, imageId: deploy.imageId, ...(deploy.prevImageId ? { prevImageId: deploy.prevImageId } : {}) },
      evidence: ["deploys"],
    });
  }
  const latest = ctx?.metrics?.host.at(-1);
  const fullDisk = latest?.disks.filter((d) => d.pct >= DISK_FULL_PCT).sort((a, b) => b.pct - a.pct)[0];
  const diskSignal = i.signals.find((s) => s.key === "disk.full" && Number(s.params.percent) >= DISK_FULL_PCT);
  if (fullDisk) hints.push({ code: "diskFull", params: { mount: fullDisk.mount, percent: fullDisk.pct }, evidence: ["metrics"] });
  else if (diskSignal) hints.push({ code: "diskFull", params: { mount: String(diskSignal.params.mount ?? ""), percent: Number(diskSignal.params.percent) }, evidence: ["signals"] });

  const logs = ctx?.logs?.lines ?? [];
  if (logs.some((l) => /address already in use|EADDRINUSE|bind: address/i.test(l))) {
    hints.push({ code: "portInUse", params: {}, evidence: ["logs"] });
  } else if (kinds.has("uptime") || logs.some((l) => /ECONNREFUSED|connection refused|ETIMEDOUT|no route to host/i.test(l))) {
    hints.push({ code: "portUnreachable", params: {}, evidence: logs.length ? ["logs", "signals"] : ["signals"] });
  }
  return hints;
}
