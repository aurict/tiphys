// Incident → analysis bundle (PLAN.md §13.1 I-3). Built on the host that owns the incident and redacted here, before
// anything leaves the host (patterns + known secret values of the stacks' .env files, which may have been registered
// after the context was collected). Every evidence line gets an id the model must cite:
//   log:<source>#<line>, signal:<n>, inspect:container, deploy:<n>, event:<n>, metric:<name>, git:<hash>, config:<n>.
// Size: per-section budgets, then the oldest lines of the biggest section go until the bundle is ≤120 KB.
import { bundleSchema, type AnalysisBundle } from "../analysis/schema.ts";
import { redact, type KnownSecret } from "../redact.ts";
import type { Candidate } from "./actions.ts";
import type { Incident, IncidentContext } from "./types.ts";

export const BUNDLE_MAX_BYTES = 120 * 1024;
const LINE_MAX = 1000;
const BUDGET = { signals: 6_000, inspect: 2_000, logs: 64_000, deploys: 6_000, events: 12_000, metrics: 4_000, git: 6_000, config: 4_000 } as const;
type Section = keyof typeof BUDGET;

type Evidence = AnalysisBundle["evidence"][number];
export type SimilarIncident = NonNullable<IncidentContext["similar"]>[number];

/** Redact first (a cut secret would no longer match its pattern), then cap. */
const clip = (s: string, max = LINE_MAX, secrets: KnownSecret[] = []) => {
  const r = redact(s, secrets);
  return r.length > max ? r.slice(0, max - 1) + "…" : r;
};
const idPart = (s: string) => s.replace(/[^A-Za-z0-9_.:@/-]/g, "_").slice(0, 120) || "_";
const kv = (o: Record<string, unknown>) =>
  Object.entries(o)
    .filter(([, v]) => v !== null && v !== undefined && v !== "")
    .map(([k, v]) => `${k}=${typeof v === "string" ? v : JSON.stringify(v)}`)
    .join(" ");

/** Keeps items within the byte budget: from the end (newest last) or from the start (newest first). */
function take(items: Evidence[], budget: number, fromEnd: boolean): { items: Evidence[]; cut: boolean } {
  const src = fromEnd ? [...items].reverse() : items;
  const out: Evidence[] = [];
  let bytes = 0;
  for (const e of src) {
    const b = Buffer.byteLength(e.text) + e.id.length + 24;
    if (bytes + b > budget) break;
    bytes += b;
    out.push(e);
  }
  return { items: fromEnd ? out.reverse() : out, cut: out.length < items.length };
}

function stats(values: number[]) {
  const r = (n: number) => Math.round(n * 10) / 10;
  return `min=${r(Math.min(...values))} max=${r(Math.max(...values))} last=${r(values.at(-1)!)} n=${values.length}`;
}

function metricEvidence(m: NonNullable<IncidentContext["metrics"]>): Evidence[] {
  const out: Evidence[] = [];
  const add = (name: string, values: number[], unit: string) => {
    if (values.length) out.push({ id: `metric:${idPart(name)}`, section: "metrics", text: `${name} (${unit}, ±30 min around the incident) ${stats(values)}` });
  };
  add("host.cpu", m.host.map((s) => s.cpu), "%");
  add("host.load1", m.host.map((s) => s.load1), "load");
  add("host.memPct", m.host.map((s) => s.memPct), "%");
  add("host.swapPct", m.host.map((s) => s.swapPct), "%");
  const mounts = new Set(m.host.flatMap((s) => s.disks.map((d) => d.mount)));
  for (const mount of [...mounts].slice(0, 10)) {
    add(`disk:${mount}`, m.host.flatMap((s) => s.disks.filter((d) => d.mount === mount).map((d) => d.pct)), "% used");
  }
  if (m.container?.samples.length) {
    add("container.cpu", m.container.samples.map((s) => s.cpu), "%");
    add("container.memPct", m.container.samples.map((s) => s.memPct), "% of limit");
    add("container.memMB", m.container.samples.map((s) => s.memBytes / 1048576), "MB");
  }
  return out;
}

/** Evidence of the incident's context, by section, before budgets. */
function evidenceOf(inc: Incident, secrets: KnownSecret[]): Record<Section, { items: Evidence[]; fromEnd: boolean }> {
  const ctx = inc.context;
  const ev = (section: Section, id: string, text: string): Evidence => ({ id, section, text: clip(text, LINE_MAX, secrets) });
  const logs = ctx?.logs;
  const src = logs ? idPart(logs.target) : "";
  return {
    signals: { items: inc.signals.map((s, n) => ev("signals", `signal:${n + 1}`, `${s.at} ${s.key} ${kv(s.params)}`)), fromEnd: true },
    inspect: {
      items: ctx?.inspect ? [ev("inspect", "inspect:container", kv({ ...ctx.inspect }))] : [],
      fromEnd: false,
    },
    // Redacted joined first: a PEM block spans lines.
    logs: { items: (logs?.lines.length ? redact(logs.lines.join("\n"), secrets).split("\n") : []).map((l, n) => ev("logs", `log:${src}#${n + 1}`, l)), fromEnd: true },
    deploys: {
      items: (ctx?.deploys ?? []).map((d, n) =>
        ev("deploys", `deploy:${n + 1}`, `${d.at} ${d.kind} ${d.project}/${d.service} image=${d.imageRef} id=${d.imageId.slice(0, 19)} created=${d.createdAt}${d.prevImageRef ? ` prev=${d.prevImageRef} prevId=${(d.prevImageId ?? "").slice(0, 19)}` : ""}`),
      ),
      fromEnd: false,
    },
    events: { items: (ctx?.events ?? []).map((e, n) => ev("events", `event:${n + 1}`, `${e.at} ${e.key} ${kv(e.params)}`)), fromEnd: false },
    metrics: { items: ctx?.metrics ? metricEvidence(ctx.metrics).map((e) => ({ ...e, text: clip(e.text, LINE_MAX, secrets) })) : [], fromEnd: false },
    git: {
      items: ctx?.git
        ? [
            ...ctx.git.log.map((c) => ev("git", `git:${idPart(c.hash.slice(0, 12))}`, `${c.date} ${c.subject}`)),
            ...(ctx.git.status.length ? [ev("git", "git:status", `uncommitted: ${ctx.git.status.slice(0, 30).join(" | ")}`)] : []),
          ]
        : [],
      fromEnd: false,
    },
    config: {
      items: (ctx?.configChanges ?? []).map((c, n) => ev("config", `config:${n + 1}`, `${c.at} ${c.key} file=${c.file} keys=${c.keys.join(",")}`)),
      fromEnd: false,
    },
  };
}

/** Past incidents with the same fingerprint that were resolved with a note or a working action. */
export function usefulSimilar(list: SimilarIncident[] | undefined): SimilarIncident[] {
  return (list ?? []).filter((s) => s.resolvedAt && (s.resolutionNote || s.workedAction)).slice(0, 5);
}

/** `secrets`: known values for this bundle only (the incident container's secret environment values). */
export function buildBundle(inc: Incident, candidates: Candidate[], similar: SimilarIncident[], language: "tr" | "en" = "tr", secrets: KnownSecret[] = []): AnalysisBundle {
  const cl = (s: string, max?: number) => clip(s, max, secrets);
  const truncated = new Set<string>();
  const evidence: Evidence[] = [];
  for (const [section, { items, fromEnd }] of Object.entries(evidenceOf(inc, secrets)) as Array<[Section, { items: Evidence[]; fromEnd: boolean }]>) {
    const t = take(items, BUDGET[section], fromEnd);
    if (t.cut) truncated.add(section);
    evidence.push(...t.items);
  }
  if (inc.context?.logs?.truncated) truncated.add("logs");
  const bundle: AnalysisBundle = {
    v: 1,
    language,
    incident: {
      id: inc.id,
      host: cl(inc.host, 100),
      kind: inc.kind,
      target: cl(inc.target, 300),
      severity: inc.severity,
      status: inc.status,
      openedAt: inc.openedAt,
      ...(inc.stack ? { stack: cl(inc.stack, 100) } : {}),
      ...(inc.service ? { service: cl(inc.service, 100) } : {}),
      parts: inc.parts.slice(0, 50).map((p) => ({ kind: p.kind, target: cl(p.target, 300), firstAt: p.firstAt, lastAt: p.lastAt, ...(p.recoveredAt ? { recoveredAt: p.recoveredAt } : {}) })),
    },
    hints: inc.hints.slice(0, 20).map((h) => ({ code: h.code, params: Object.fromEntries(Object.entries(h.params).map(([k, v]) => [k, typeof v === "string" ? cl(v, 300) : v])) })),
    evidence,
    candidates: candidates.slice(0, 20).map((c) => ({ id: c.id, kind: c.kind, target: Object.fromEntries(Object.entries(c.target).map(([k, v]) => [k, cl(String(v), 300)])), risk: c.risk })),
    similar: similar.slice(0, 5).map((s) => ({
      id: s.id,
      kind: s.kind ?? "",
      openedAt: s.openedAt,
      resolvedAt: s.resolvedAt,
      resolutionNote: s.resolutionNote ? cl(s.resolutionNote, 500) : null,
      workedAction: s.workedAction,
    })),
    truncated: [],
  };
  // Over the total cap: drop the oldest lines of the biggest section.
  const size = () => Buffer.byteLength(JSON.stringify(bundle));
  while (size() > BUNDLE_MAX_BYTES && bundle.evidence.length) {
    const bytes = new Map<string, number>();
    for (const e of bundle.evidence) bytes.set(e.section, (bytes.get(e.section) ?? 0) + e.text.length);
    const biggest = [...bytes.entries()].sort((a, b) => b[1] - a[1])[0]![0];
    const fromEnd = biggest === "logs" || biggest === "signals";
    const idx = fromEnd ? bundle.evidence.findIndex((e) => e.section === biggest) : bundle.evidence.findLastIndex((e) => e.section === biggest);
    bundle.evidence.splice(idx, 1);
    truncated.add(biggest);
  }
  bundle.truncated = [...truncated];
  // Same contract the PC enforces.
  return bundleSchema.parse(bundle);
}
