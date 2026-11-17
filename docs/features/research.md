# Research

The PC agent can run **web research jobs** for another agent. The first user is the Telegram digest feature on the
server (atlas): at the scheduled time atlas asks the PC "research this topic with these rules" and gets back
structured, sourced items. The AI tools (Antigravity CLI `agy` with Gemini, and Claude Code) are installed and logged
in only on the PC, so the research runs there.

API reference: [../agent/api.md#research](../agent/api.md#research). Configuration: feature flag `research`
(default off) and `serviceTokens` in [../agent/configuration.md](../agent/configuration.md).

## Setup

1. Install and log in to `agy` and `claude` on the PC. Both must be on the agent's `PATH`.
2. Add the `searxng` and `firecrawl` MCP servers to both tools: `agy mcp add …` for Gemini, and the user's
   `~/.claude.json` `mcpServers` for Claude (the agent copies only these two entries for each editor run).
3. Turn on the `research` feature and restart the agent.
4. Create a service token for atlas and put it into atlas's agent config (`research: {url, token}`):

   ```sh
   tiphys-agent service-token create --name atlas --scope research
   ```

   The token (`tps_…`) is printed once. List and revoke with `service-token list` / `service-token revoke <id>`,
   or from the app (`/v1/service-tokens`). "Lock everything" revokes service tokens too.

## Service tokens

A service token opens **only** the routes of its scope. With scope `research` that is starting a job and reading
its status or cancelling it (`POST /v1/research/jobs`, `GET`/`DELETE /v1/research/jobs/:id`), and only for jobs
started with the same token.
Every other route answers `403 agent.auth.scopeDenied`: no system info, desktop, files, Claude sessions or settings.
The Tailscale identity check (`requireTailscaleLogin`) applies to service tokens as it does to devices. Tokens are
stored as SHA-256 hashes; the audit log records the caller as `service:<id>`, and the token itself is never logged.

## Pipeline

One job runs at a time; up to 5 more wait (`429 agent.research.busy` beyond that). Each job:

1. **Work directory** `$XDG_RUNTIME_DIR/tiphys/research/<id>` (mode `0700`; fallback `~/.cache/tiphys/research`).
2. **Gemini drafts** (`agy`, model `gemini-4-argon-high`). The prompt holds the time window (with the current date,
   time and time zone), topic, instructions, item and source counts, allowed/blocked domains and the URLs already
   sent. The model must only cite pages it actually opened and keep publication dates inside the window. Output is
   forced to a JSON schema (`--json-schema`); with `--output-format stream-json` the final `result` event must report
   `status: SUCCESS`.
3. **Claude edits** (when `editor: true`, model `sonnet`). It reads `draft.json`, opens the sources to verify facts
   and dates, drops weak, unsourced or out-of-window items, merges duplicates, fixes the language and shortens the
   summaries. If it keeps fewer than `minItems` items it may return `followups`; then Gemini runs **one** extra
   round with those questions and Claude makes a final pass.
4. **Result**: the agent enforces the rules on the final items itself (http(s) sources only, allow/block lists,
   source and item limits, no already-sent stories, no duplicates).

**`seenUrls` come only from real tool output**, never from text a model wrote (its answer, notes or any URL list it
claims). The agent reads both tools' event streams (`agy --output-format stream-json`; `claude --output-format
stream-json --verbose`) and collects URLs from the output of **successful** searxng/firecrawl calls, plus the `url`
argument of a successful fetch/scrape. Failed calls, other tools (e.g. agy reading local files) and search query
arguments don't count. URLs are normalized (no fragment, no `utm_*` parameters, no trailing slash) — item source URLs
get the same normalization — and capped at 5000. atlas can therefore drop any item whose source is not in
`seenUrls` as unverified.

A job is limited to 20 minutes in total. Jobs and their work directories are deleted 24 hours after they finish.
If the agent stops, running and waiting jobs fail with `agent.research.interrupted`.

## Sandboxing

Web pages may contain hidden instructions, so the research tools get no shell and can write only in the job's
directory:

- Only four web tools are allowed: `searxng_web_search`, `web_url_read` (searxng), `firecrawl_search`,
  `firecrawl_scrape` (firecrawl); the prompts name them. Every other tool of these servers (crawl, map, agent,
  monitor, …) stays denied.
- `agy` runs headless with permissions given **only for that run** through `--settings`: allow
  `mcp(searxng/searxng_web_search)`, `mcp(searxng/web_url_read)`, `mcp(firecrawl/firecrawl_search)`,
  `mcp(firecrawl/firecrawl_scrape)` and `write_file(<work dir>)`, deny `command(*)`. Headless `agy` rejects every
  other tool that would need approval (and then ends the turn: the job fails with `toolFailed`, status `denied`).
  `--dangerously-skip-permissions` is never used. The user's `~/.gemini/antigravity-cli/settings.json` is not touched;
  its MCP servers (`agy mcp add`) should use the pinned packages below.
- `claude` runs with `--setting-sources ""` (the user's settings, hooks and permission rules are not loaded),
  `--strict-mcp-config --mcp-config '<inline JSON>'` (only searxng and firecrawl as pinned `npx -y mcp-searxng@2.10.1`
  / `firecrawl-mcp@3.40.0`, with the `env` of the user's `~/.claude.json` entries; never written into the work
  directory, which the editor can read), `--tools Read Write`, and allow rules only for the four web tools plus
  `Read`/`Edit` inside the work directory, in `--permission-mode default`.
- Both run in the work directory, in their own process group, with an allowlisted environment only (`HOME`, `PATH`,
  `LANG`, `LANGUAGE`, `LC_*`, `USER`, `LOGNAME`, `TERM`, `TZ`, `XDG_*_HOME`/`XDG_RUNTIME_DIR`,
  `NODE_EXTRA_CA_CERTS`). On timeout, cancel or agent shutdown the whole group gets `SIGTERM`, then `SIGKILL` after 5 s.
- `seenUrls` come only from structured fields of successful calls of those four tools: search result URLs, and the
  requested (and final) URL of a page read that didn't answer with an HTTP error. URLs inside page text never count.
  URLs over 2048 characters are ignored.
- Prompts are not logged at `info` level; job logs contain ids, counts and error codes only.

## In the app

System › (PC) › Tools › Research: *Connect to a Telegram agent* (creates a service token and stores it in that
agent's `research` config; see [Telegram › Using it in the app](telegram.md#using-it-in-the-app)), *Test the
connection*, the service tokens (revoke) and the recent jobs (`GET /v1/research/jobs`: topic, status, duration, item
count, requesting token, error). A queued or running job can be cancelled (`DELETE /v1/research/jobs/:id`).

## Testing

`test/research.test.ts` runs the pipeline against fake `agy`/`claude` executables placed first on `PATH`; they check
the safety flags and emit canned output. `test/research_real.test.ts` runs one tiny job with the real tools and only
runs with `TIPHYS_REAL=1` (it uses the user's subscriptions).
