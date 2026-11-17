// Research job input (contract in PLAN.md §12 "Ajanlar arası sözleşme") and the model output schemas.
import { z } from "zod";

const domain = z
  .string()
  .trim()
  .toLowerCase()
  .regex(/^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,62}$/, "invalid domain");

const httpUrl = z.url({ protocol: /^https?$/ }).max(2048);

/** excludeUrls go into the agy prompt (a single argv string, Linux limit 128 KiB): their total size is bounded. */
const MAX_EXCLUDE_CHARS = 100_000;

export const jobInputSchema = z
  .strictObject({
    topic: z.string().trim().min(1).max(500),
    instructions: z.string().max(4000).default(""),
    windowHours: z.number().int().min(1).max(720),
    language: z.string().regex(/^[a-z]{2}(-[A-Z]{2})?$/).default("tr"),
    minItems: z.number().int().min(1).max(20).default(1),
    maxItems: z.number().int().min(1).max(20),
    maxSourcesPerItem: z.number().int().min(1).max(5).default(3),
    allowDomains: z.array(domain).max(50).default([]),
    blockDomains: z.array(domain).max(50).default([]),
    excludeUrls: z.array(httpUrl).max(500).default([]),
    editor: z.boolean().default(true),
  })
  .refine((j) => j.minItems <= j.maxItems, { message: "minItems > maxItems", path: ["minItems"] })
  .refine((j) => j.excludeUrls.reduce((n, u) => n + u.length + 1, 0) <= MAX_EXCLUDE_CHARS, { message: "excludeUrls too large", path: ["excludeUrls"] });

export type JobInput = z.infer<typeof jobInputSchema>;

// Lenient parsing of model output: wrong items are dropped later, unknown keys ignored.
const sourceSchema = z.object({ title: z.string().default(""), url: z.string() });
export const itemSchema = z.object({
  headline: z.string(),
  summary: z.string(),
  published: z.string().optional(),
  sources: z.array(sourceSchema).default([]),
});
export type Item = z.infer<typeof itemSchema>;

// The models' own URL lists are not trusted: seenUrls come from tool outputs only (streams.ts).
export const draftOutputSchema = z.object({ items: z.array(itemSchema) });
export const editorOutputSchema = draftOutputSchema.extend({ followups: z.array(z.string()).default([]) });

const itemJsonSchema = {
  type: "object",
  properties: {
    headline: { type: "string" },
    summary: { type: "string" },
    published: { type: "string", description: "Publication date/time, ISO 8601" },
    sources: {
      type: "array",
      items: { type: "object", properties: { title: { type: "string" }, url: { type: "string" } }, required: ["title", "url"] },
    },
  },
  required: ["headline", "summary", "published", "sources"],
};

/** Schema handed to agy (--json-schema <file>). */
export const draftJsonSchema = {
  type: "object",
  properties: {
    items: { type: "array", items: itemJsonSchema },
  },
  required: ["items"],
};

/** Schema handed to claude (--json-schema '<json>'). */
export const editorJsonSchema = {
  type: "object",
  properties: {
    ...draftJsonSchema.properties,
    followups: { type: "array", items: { type: "string" }, description: "Questions that need more research (may be empty)" },
  },
  required: ["items"],
};
