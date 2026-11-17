// Fake `agy` / `claude` for research tests: logs its arguments and environment, then follows the scenario
// in $FAKE_RESEARCH_DIR/scenario.json ({agy: [step…], claude: [step…]}, one step per call).
// FAKE_RESEARCH_DIR is set by the wrapper script (the agent passes only allowlisted variables).
import { spawn } from "node:child_process";
import { appendFileSync, existsSync, readdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [tool, ...args] = process.argv.slice(2);
const dir = process.env.FAKE_RESEARCH_DIR;
const callsFile = join(dir, "calls.jsonl");
const scenario = JSON.parse(readFileSync(join(dir, "scenario.json"), "utf8"));
const n = existsSync(callsFile) ? readFileSync(callsFile, "utf8").split("\n").filter((l) => l.includes(`"tool":"${tool}"`)).length : 0;
const step = scenario[tool]?.[n] ?? { mode: "error" };

const call = { tool, n, args, cwd: process.cwd(), envKeys: Object.keys(process.env).filter((k) => !["FAKE_RESEARCH_DIR", "PWD", "OLDPWD", "SHLVL", "_"].includes(k)) /* set by the wrapper shell */, cwdFiles: readdirSync(process.cwd()) };
if (tool === "claude") {
  const i = args.indexOf("--mcp-config");
  call.mcp = JSON.parse(args[i + 1]);
  call.draft = JSON.parse(readFileSync(join(process.cwd(), "draft.json"), "utf8"));
}
appendFileSync(callsFile, JSON.stringify(call) + "\n");

if (step.notes) writeFileSync(join(process.cwd(), "notes.md"), step.notes);

// stream-json like the real tools. step.tools: [{server, tool, args, output, failed?}] become tool calls.
const emit = (e) => process.stdout.write(JSON.stringify(e) + "\n");
function toolEvents(tools = []) {
  tools.forEach((t, i) => {
    if (tool === "agy") {
      const tool_info = { name: "call_mcp_tool", parameters: { ServerName: t.server, ToolName: t.tool, Arguments: t.args ?? {} } };
      emit({ event: "step_update", step_update: { step_index: 10 + i, state: "ACTIVE", step_type: "tool", tool_name: "call_mcp_tool", tool_info } });
      emit({ event: "step_update", step_update: { step_index: 10 + i, state: t.failed ? "ERROR" : "DONE", step_type: "tool", tool_name: "call_mcp_tool", tool_info: { ...tool_info, ...(t.failed ? { error: t.output } : { output: t.output }) } } });
    } else {
      const id = `toolu_${i}`;
      emit({ type: "assistant", message: { content: [{ type: "tool_use", id, name: `mcp__${t.server}__${t.tool}`, input: t.args ?? {} }] } });
      emit({ type: "user", message: { content: [{ type: "tool_result", tool_use_id: id, ...(t.failed ? { is_error: true } : {}), content: [{ type: "text", text: t.output }] }] } });
    }
  });
}

switch (step.mode) {
  case "ok":
    if (tool === "agy") {
      emit({ event: "init", conversation_id: "x", init: { model: "gemini" } });
      // Reading a local file that mentions a URL is not a web tool result.
      emit({ event: "step_update", step_update: { state: "DONE", step_type: "tool", tool_name: "read_file", tool_info: { name: "read_file", parameters: { Path: "/x" }, output: "see https://readfile.example/x" } } });
      toolEvents(step.tools);
      emit({ event: "step_update", step_update: { state: "DONE", step_type: "agent_response", text_delta: JSON.stringify(step.output) } });
      emit({ event: "result", result: { status: "SUCCESS", response: JSON.stringify(step.output), structured_output: step.output } });
    } else {
      emit({ type: "system", subtype: "init" });
      toolEvents(step.tools);
      emit({ type: "assistant", message: { content: [{ type: "text", text: JSON.stringify(step.output) }] } });
      emit({ type: "result", subtype: "success", is_error: false, result: JSON.stringify(step.output), structured_output: step.output });
    }
    break;
  case "denied":
    // Headless agy after a call to a tool that isn't allowed: the turn ends with an empty response.
    emit({ event: "step_update", step_update: { state: "DONE", step_type: "tool", tool_name: "call_mcp_tool", tool_info: { name: "call_mcp_tool", parameters: { ServerName: "firecrawl", ToolName: "firecrawl_map", Arguments: { url: "https://x.example" } } } } });
    emit({ event: "result", result: { status: "SUCCESS", response: "", denied_actions: [{ action: "mcp", display_name: "McpTool" }] } });
    break;
  case "error":
    emit(tool === "agy" ? { event: "result", result: { status: "ERROR", response: "boom" } } : { type: "result", subtype: "error_max_turns", is_error: true });
    break;
  case "invalid":
    process.stdout.write("this is not json");
    process.exitCode = step.exitCode ?? 0;
    break;
  case "hang":
  case "stubborn": {
    // A grandchild in the same process group, like an MCP server; both pids are recorded for the test.
    const child = spawn("sleep", ["600"], { stdio: "ignore" });
    writeFileSync(join(dir, `pids-${tool}-${n}.json`), JSON.stringify([process.pid, child.pid]));
    if (step.mode === "stubborn") process.on("SIGTERM", () => {});
    setInterval(() => {}, 1000);
    break;
  }
}
