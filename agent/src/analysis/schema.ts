// Incident analysis contract (PLAN.md §13.1 I-3), shared by the server that builds the bundle and the PC that runs
// the model. The bundle is redacted data with evidence ids; the model's output is validated against it: unknown
// candidate ids are dropped, hypotheses whose evidenceRefs name no bundle evidence are flagged `unsupported`, every
// text is capped and reduced to plain text (no markdown, links, HTML or control characters).
import { z } from "zod";

export const EVIDENCE_SECTIONS = ["signals", "inspect", "logs", "deploys", "events", "metrics", "git", "config"] as const;
/** log:<source>#<line>, deploy:<n>, event:<n>, metric:<name>, signal:<n>, git:<hash>, config:<n>, inspect:container. */
export const EVIDENCE_ID_RE = /^(?:log|deploy|event|metric|signal|git|config|inspect):[A-Za-z0-9_.:@/#-]{1,200}$/;
export const CANDIDATE_ID_RE = /^c-[a-f0-9]{12}$/;
/** Upper bound of a serialized bundle accepted by the PC (the server aims for ≤120 KB). */
export const MAX_BUNDLE_BYTES = 192 * 1024;

export const LIMITS = { summary: 600, cause: 300, why: 300, question: 200, hypotheses: 5, actions: 5, questions: 5, refs: 10 } as const;

const s = (max: number) => z.string().max(max);
const param = z.union([z.string().max(500), z.number()]);

export const bundleSchema = z.strictObject({
  v: z.literal(1),
  language: z.enum(["tr", "en"]).default("tr"),
  incident: z.strictObject({
    id: s(40),
    host: s(100),
    kind: s(60),
    target: s(300),
    severity: s(20),
    status: s(20),
    openedAt: s(40),
    stack: s(100).optional(),
    service: s(100).optional(),
    parts: z.array(z.strictObject({ kind: s(60), target: s(300), firstAt: s(40), lastAt: s(40), recoveredAt: s(40).optional() })).max(50),
  }),
  hints: z.array(z.strictObject({ code: s(40), params: z.record(s(60), param) })).max(20),
  evidence: z.array(z.strictObject({ id: z.string().regex(EVIDENCE_ID_RE), section: z.enum(EVIDENCE_SECTIONS), text: s(4000) })).max(1500),
  candidates: z.array(z.strictObject({ id: z.string().regex(CANDIDATE_ID_RE), kind: s(40), target: z.record(s(40), s(300)), risk: z.enum(["low", "medium"]) })).max(20),
  similar: z
    .array(z.strictObject({ id: s(40), kind: s(60), openedAt: s(40), resolvedAt: s(40).nullable(), resolutionNote: s(2000).nullable(), workedAction: s(40).nullable() }))
    .max(5),
  /** Sections cut to fit the size budget. */
  truncated: z.array(s(20)).max(20),
});
export type AnalysisBundle = z.infer<typeof bundleSchema>;
export type BundleInput = z.input<typeof bundleSchema>;

export interface Hypothesis {
  cause: string;
  confidence: number;
  evidenceRefs: string[];
  /** No evidenceRef names evidence in the bundle: the app shows it as "kanıtsız". */
  unsupported: boolean;
}

export interface AnalysisResult {
  summary: string;
  hypotheses: Hypothesis[];
  suggestedActions: Array<{ candidateId: string; kind: string; why: string }>;
  questions: string[];
  /** What validation removed: suggested actions with unknown candidate ids, evidence refs not in the bundle. */
  dropped: { actions: number; refs: number };
}

/** JSON schema for `claude -p --json-schema`; candidate ids are limited to the bundle's candidates. */
export function outputJsonSchema(b: Pick<AnalysisBundle, "candidates">): object {
  const ids = b.candidates.map((c) => c.id);
  const str = (maxLength: number) => ({ type: "string", maxLength });
  return {
    type: "object",
    additionalProperties: false,
    required: ["summary", "hypotheses", "suggestedActions", "questions"],
    properties: {
      summary: str(LIMITS.summary),
      hypotheses: {
        type: "array",
        maxItems: LIMITS.hypotheses,
        items: {
          type: "object",
          additionalProperties: false,
          required: ["cause", "confidence", "evidenceRefs"],
          properties: {
            cause: str(LIMITS.cause),
            confidence: { type: "number", minimum: 0, maximum: 1 },
            evidenceRefs: { type: "array", maxItems: LIMITS.refs, items: str(200) },
          },
        },
      },
      suggestedActions: {
        type: "array",
        maxItems: ids.length ? LIMITS.actions : 0,
        items: {
          type: "object",
          additionalProperties: false,
          required: ["candidateId", "why"],
          properties: { candidateId: ids.length ? { type: "string", enum: ids } : { type: "string" }, why: str(LIMITS.why) },
        },
      },
      questions: { type: "array", maxItems: LIMITS.questions, items: str(LIMITS.question) },
    },
  };
}

/** Lenient shape of the model output (or of a result coming back from the PC); everything is cleaned afterwards. */
const rawSchema = z.object({
  summary: z.string().max(20_000),
  hypotheses: z
    .array(z.object({ cause: z.string().max(20_000), confidence: z.number().catch(0), evidenceRefs: z.array(z.unknown()).max(100).catch([]) }))
    .max(50)
    .catch([]),
  suggestedActions: z.array(z.object({ candidateId: z.unknown(), why: z.string().max(20_000).catch("") })).max(50).catch([]),
  questions: z.array(z.unknown()).max(50).catch([]),
  /** Present when a validated result is validated again (the server re-checks the PC's result): counts add up. */
  dropped: z.object({ actions: z.number().int().min(0).max(1000), refs: z.number().int().min(0).max(1000) }).optional().catch(undefined),
});

// Zero-width, bidi and other format characters, and C0/C1 controls (newlines are folded to spaces separately).
const INVISIBLE = /[\u0000-\u001f\u007f-\u009f­؜᠎​-‏‪-‮⁠-⁯﻿￹-￻]/g;

/** Plain text: markdown, links, HTML and control characters removed, whitespace folded, capped at `max` characters. */
export function plainText(text: string, max: number): string {
  let t = text.slice(0, 20_000).replace(/\r\n?/g, "\n");
  t = t.replace(/<[^<>\n]{0,300}>/g, " "); // HTML tags and <autolinks>
  t = t.replace(/!?\[([^\]\n]{0,300})\]\([^)\n]{0,2000}\)/g, "$1"); // [text](url), ![alt](src)
  t = t.replace(/\[([^\]\n]{0,300})\]\[[^\]\n]{0,100}\]/g, "$1"); // [text][ref]
  t = t.replace(/^\s{0,3}\[[^\]\n]{1,100}\]:\s*\S+.*$/gm, ""); // [ref]: url
  t = t.replace(/\b(?:https?|ftp|file|javascript|data|vbscript|mailto|tel):[^\s)\]]+/gi, "[link]");
  t = t.replace(/\bwww\.[^\s)\]]+/gi, "[link]");
  t = t
    .split("\n")
    .map((l) => l.replace(/^\s{0,3}(?:#{1,6}\s+|>\s?|[-*+]\s+|\d{1,3}[.)]\s+)/, "").replace(/^\s{0,3}(?:[-*_]\s*){3,}$/, ""))
    .join("\n");
  t = t.replace(/(\*{1,3}|_{2,3}|~~|`+)/g, "");
  t = t.replace(INVISIBLE, " ").replace(/\s+/g, " ").trim();
  return t.length > max ? t.slice(0, max - 1).trimEnd() + "…" : t;
}

/**
 * Validates and cleans the model output against the bundle. Throws (zod) when the shape is unusable; the caller turns
 * that into `<prefix>.invalidOutput`.
 */
export function validateAnalysis(raw: unknown, b: Pick<AnalysisBundle, "evidence" | "candidates">): AnalysisResult {
  const r = rawSchema.parse(raw);
  const evidence = new Set(b.evidence.map((e) => e.id));
  const candidates = new Map(b.candidates.map((c) => [c.id, c]));
  let droppedRefs = r.dropped?.refs ?? 0;
  let droppedActions = r.dropped?.actions ?? 0;
  const hypotheses: Hypothesis[] = [];
  for (const h of r.hypotheses) {
    const cause = plainText(h.cause, LIMITS.cause);
    if (!cause) continue;
    const refs = [...new Set(h.evidenceRefs.filter((x): x is string => typeof x === "string").map((x) => x.trim()))];
    const valid = refs.filter((x) => evidence.has(x)).slice(0, LIMITS.refs);
    droppedRefs += refs.length - valid.length;
    const confidence = Number.isFinite(h.confidence) ? Math.min(1, Math.max(0, Math.round(h.confidence * 100) / 100)) : 0;
    hypotheses.push({ cause, confidence, evidenceRefs: valid, unsupported: valid.length === 0 });
    if (hypotheses.length >= LIMITS.hypotheses) break;
  }
  const suggestedActions: AnalysisResult["suggestedActions"] = [];
  for (const a of r.suggestedActions) {
    const c = typeof a.candidateId === "string" ? candidates.get(a.candidateId) : undefined;
    if (!c || suggestedActions.some((x) => x.candidateId === c.id) || suggestedActions.length >= LIMITS.actions) {
      droppedActions++;
      continue;
    }
    suggestedActions.push({ candidateId: c.id, kind: c.kind, why: plainText(a.why, LIMITS.why) });
  }
  const questions = r.questions
    .filter((q): q is string => typeof q === "string")
    .map((q) => plainText(q, LIMITS.question))
    .filter(Boolean)
    .slice(0, LIMITS.questions);
  return { summary: plainText(r.summary, LIMITS.summary), hypotheses, suggestedActions, questions, dropped: { actions: droppedActions, refs: droppedRefs } };
}
