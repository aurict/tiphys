// Parses the stream-json output of agy and claude. seenUrls come ONLY from structured fields of successful calls to
// the allowed searxng/firecrawl tools: the result URLs of a search, and the requested (and final) URL of a page read.
// Free text (page content, descriptions, the model's own text) never adds a URL.
import { AppError } from "../errors.ts";

export const MAX_SEEN_URLS = 5000;
/** Longer URLs are ignored everywhere (atlas drops them too). */
export const MAX_URL_LENGTH = 2048;

/** The only MCP tools the research models may call (server → tool → kind). Everything else stays denied. */
export const MCP_TOOLS: Record<string, Record<string, "search" | "read">> = {
  searxng: { searxng_web_search: "search", web_url_read: "read" },
  firecrawl: { firecrawl_search: "search", firecrawl_scrape: "read" },
};

const kindOf = (server: string, tool: string) =>
  Object.hasOwn(MCP_TOOLS, server) && Object.hasOwn(MCP_TOOLS[server]!, tool) ? MCP_TOOLS[server]![tool]! : null;

/** Pinned MCP packages (npx), so a research run never pulls an unreviewed "latest". */
export const MCP_PACKAGES: Record<string, string> = { searxng: "mcp-searxng@2.10.1", firecrawl: "firecrawl-mcp@3.40.0" };

/** http(s) URL without fragment, utm_* parameters and trailing slash (root path keeps "/"); null if invalid or too long. */
export function normalizeUrl(u: string): string | null {
  if (u.length > MAX_URL_LENGTH) return null;
  let url: URL;
  try {
    url = new URL(u.trim());
  } catch {
    return null;
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") return null;
  url.hash = "";
  for (const k of [...url.searchParams.keys()]) if (k.toLowerCase().startsWith("utm_")) url.searchParams.delete(k);
  if (url.pathname.length > 1) url.pathname = url.pathname.replace(/\/+$/, "") || "/";
  const out = url.toString();
  return out.length > MAX_URL_LENGTH ? null : out;
}

/** Bounded set of normalized URLs. */
export class UrlSet {
  readonly urls = new Set<string>();
  add(raw: unknown) {
    const n = typeof raw === "string" ? normalizeUrl(raw) : null;
    if (n && this.urls.size < MAX_SEEN_URLS) this.urls.add(n);
  }
}

function lines(stdout: string): Record<string, unknown>[] {
  const out: Record<string, unknown>[] = [];
  for (const l of stdout.split("\n")) {
    if (!l.trim().startsWith("{")) continue;
    try {
      const v = JSON.parse(l) as unknown;
      if (v && typeof v === "object") out.push(v as Record<string, unknown>);
    } catch {
      // not an event line
    }
  }
  return out;
}

const obj = (v: unknown): Record<string, unknown> => (v && typeof v === "object" ? (v as Record<string, unknown>) : {});
const text = (v: unknown): string => (typeof v === "string" ? v : v === undefined || v === null ? "" : JSON.stringify(v));

function parseJson(s: string): unknown {
  try {
    return JSON.parse(s) as unknown;
  } catch {
    return null;
  }
}

/**
 * URLs a successful call of an allowed tool proves were seen:
 * - searxng_web_search: `results[].url` (JSON format) or the `URL:` line of each Title/Description/URL block (text
 *   format; the server writes every value on one line, so page text can't forge such a line);
 * - firecrawl_search: `url` of the `web`/`news` result entries;
 * - web_url_read / firecrawl_scrape: the requested `url` (plus firecrawl's final `metadata.url`), unless the page
 *   answered with an HTTP error.
 */
export function toolUrls(server: string, tool: string, args: Record<string, unknown>, output: string): string[] {
  const kind = kindOf(server, tool);
  if (!kind || !output.trim()) return [];
  const json = parseJson(output);
  if (kind === "search") {
    if (server === "firecrawl") {
      const root = obj(json);
      const data = root.data && typeof root.data === "object" ? obj(root.data) : root;
      return ["web", "news"].flatMap((k) => (Array.isArray(data[k]) ? data[k].map((r) => obj(r).url) : [])).filter((u): u is string => typeof u === "string");
    }
    if (json && typeof json === "object") {
      const results = obj(json).results;
      return Array.isArray(results) ? results.map((r) => obj(r).url).filter((u): u is string => typeof u === "string") : [];
    }
    const ls = output.split("\n");
    const out: string[] = [];
    for (let i = 2; i < ls.length; i++) {
      if (ls[i]!.startsWith("URL: ") && ls[i - 1]!.startsWith("Description: ") && ls[i - 2]!.startsWith("Title: ")) out.push(ls[i]!.slice(5).trim());
    }
    return out;
  }
  if (typeof args.url !== "string") return [];
  if (server === "firecrawl") {
    // firecrawl_scrape answers with a JSON document; anything else is not a page.
    if (!json || typeof json !== "object") return [];
    const meta = obj(obj(json).metadata);
    if (typeof meta.statusCode === "number" && meta.statusCode >= 400) return [];
    return [args.url, ...(typeof meta.url === "string" ? [meta.url] : [])];
  }
  if (/^\s*(error|mcp error)\b/i.test(output)) return [];
  return [args.url];
}

function missingResult(tool: string, exitCode: number | null): never {
  if (exitCode !== 0) throw new AppError("agent.research.toolFailed", 500, { tool, exitCode: exitCode ?? -1 });
  throw new AppError("agent.research.invalidOutput", 500, { tool });
}

/**
 * agy --output-format stream-json: tool steps are `step_update` events (step_type "tool"); MCP calls are
 * `call_mcp_tool` with parameters {ServerName, ToolName, Arguments}. The final `result` event holds status and
 * structured_output.
 */
export function parseAgyStream(stdout: string, exitCode: number | null, seen: UrlSet): unknown {
  let result: Record<string, unknown> | null = null;
  for (const ev of lines(stdout)) {
    if (ev.event === "result") result = obj(ev.result);
    if (ev.event !== "step_update") continue;
    const s = obj(ev.step_update);
    if (s.step_type !== "tool" || s.state !== "DONE") continue;
    const info = obj(s.tool_info);
    const params = obj(info.parameters);
    if (info.name !== "call_mcp_tool" || !Object.hasOwn(MCP_TOOLS, String(params.ServerName))) continue;
    if (s.error !== undefined || info.error !== undefined || info.is_error === true) continue;
    for (const u of toolUrls(String(params.ServerName), String(params.ToolName ?? ""), obj(params.Arguments), text(info.output))) seen.add(u);
  }
  if (!result) missingResult("agy", exitCode);
  if (result.status !== "SUCCESS") throw new AppError("agent.research.toolFailed", 500, { tool: "agy", status: String(result.status ?? "") });
  // Headless agy ends the turn (status SUCCESS, empty response) when the model calls a tool that isn't allowed.
  if (result.structured_output === undefined && Array.isArray(result.denied_actions) && result.denied_actions.length > 0) {
    throw new AppError("agent.research.toolFailed", 500, { tool: "agy", status: "denied" });
  }
  return result.structured_output;
}

/**
 * claude --output-format stream-json --verbose: tool_use blocks arrive in assistant messages, their results as
 * tool_result blocks in user messages; the last line is the `result` event.
 */
export function parseClaudeStream(stdout: string, exitCode: number | null, seen: UrlSet): unknown {
  let result: Record<string, unknown> | null = null;
  const calls = new Map<string, { name: string; input: Record<string, unknown> }>();
  for (const ev of lines(stdout)) {
    if (ev.type === "result") result = ev;
    const content = obj(ev.message).content;
    if (!Array.isArray(content)) continue;
    for (const b of content.map(obj)) {
      if (ev.type === "assistant" && b.type === "tool_use" && typeof b.id === "string") {
        calls.set(b.id, { name: String(b.name ?? ""), input: obj(b.input) });
      }
      if (ev.type === "user" && b.type === "tool_result" && b.is_error !== true) {
        const call = calls.get(String(b.tool_use_id ?? ""));
        const m = call ? /^mcp__([a-z0-9_-]+?)__(.+)$/.exec(call.name) : null;
        if (!call || !m || !Object.hasOwn(MCP_TOOLS, m[1]!)) continue;
        const out = Array.isArray(b.content) ? b.content.map((c) => text(obj(c).text)).join("\n") : text(b.content);
        for (const u of toolUrls(m[1]!, m[2]!, call.input, out)) seen.add(u);
      }
    }
  }
  if (!result) missingResult("claude", exitCode);
  if (result.is_error === true || result.subtype !== "success") {
    throw new AppError("agent.research.toolFailed", 500, { tool: "claude", status: String(result.subtype ?? "") });
  }
  return result.structured_output;
}
