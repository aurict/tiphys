// Fake `agy acp` for tests: line-delimited JSON-RPC over stdio, the subset Tiphys uses.
import { createInterface } from "node:readline";
const out = (m) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...m }) + "\n");
const update = (sessionId, u) => out({ method: "session/update", params: { sessionId, update: u } });
const modes = { currentModeId: "default", availableModes: [{ id: "default", name: "Default" }, { id: "auto", name: "Auto" }, { id: "plan", name: "Plan" }] };
const config = (v) => [{ id: "model", currentValue: v, options: [{ value: "gemini-4-neon", name: "Neon" }, { value: "gemini-3.8-flash", name: "Flash" }] }];
let pendingPrompt = null;
let permId = 1000;
const rl = createInterface({ input: process.stdin });
rl.on("line", (line) => {
  const m = JSON.parse(line);
  if (m.id !== undefined && !m.method) {
    // answer to our permission request
    if (pendingPrompt && m.id === pendingPrompt.permId) {
      const sel = m.result?.outcome;
      update(pendingPrompt.sid, { sessionUpdate: "tool_call_update", toolCallId: "t1", status: sel?.optionId === "allow" ? "completed" : "failed" });
      update(pendingPrompt.sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: sel?.optionId === "allow" ? "ran it" : "denied" } });
      out({ id: pendingPrompt.id, result: { stopReason: sel?.outcome === "cancelled" ? "cancelled" : "end_turn" } });
      pendingPrompt = null;
    }
    return;
  }
  const p = m.params ?? {};
  switch (m.method) {
    case "initialize":
      return out({ id: m.id, result: { protocolVersion: 1, agentCapabilities: { loadSession: true } } });
    case "session/new":
      update("s-new-0001", { sessionUpdate: "available_commands_update", availableCommands: [{ name: "goal", description: "Run until done" }] });
      return out({ id: m.id, result: { sessionId: "s-new-0001", modes, configOptions: config("gemini-4-neon") } });
    case "session/load":
      update(p.sessionId, { sessionUpdate: "user_message_chunk", content: { type: "text", text: "old question" } });
      update(p.sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "old " } });
      update(p.sessionId, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "answer" } });
      return out({ id: m.id, result: { modes, configOptions: config("gemini-4-neon") } });
    case "session/list":
      return out({ id: m.id, result: { sessions: [{ sessionId: "s-old-0002", cwd: process.cwd(), title: "Old one", updatedAt: "2026-11-18T10:00:00Z" }, { sessionId: "bad id!", cwd: "/", title: "x" }] } });
    case "session/prompt": {
      const text = p.prompt?.[0]?.text ?? "";
      const sid = p.sessionId;
      update(sid, { sessionUpdate: "session_info_update", title: "Fake title" });
      update(sid, { sessionUpdate: "agent_thought_chunk", content: { type: "text", text: "thinking" } });
      if (text.includes("run")) {
        update(sid, { sessionUpdate: "tool_call", toolCallId: "t1", title: "echo hi", kind: "execute", status: "pending", rawInput: { CommandLine: "echo hi" } });
        pendingPrompt = { id: m.id, sid, permId: ++permId };
        return out({ id: permId, method: "session/request_permission", params: { sessionId: sid, toolCall: { toolCallId: "t1", title: "echo hi", kind: "execute", rawInput: { CommandLine: "echo hi" } }, options: [{ optionId: "allow", name: "Allow", kind: "allow_once" }, { optionId: "deny", name: "Deny", kind: "reject_once" }] } });
      }
      update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "hel" } });
      update(sid, { sessionUpdate: "agent_message_chunk", content: { type: "text", text: "lo" } });
      update(sid, { sessionUpdate: "usage_update", used: 10, size: 100 });
      return out({ id: m.id, result: { stopReason: "end_turn" } });
    }
    case "session/cancel":
      if (pendingPrompt) {
        out({ id: pendingPrompt.id, result: { stopReason: "cancelled" } });
        pendingPrompt = null;
      }
      return;
    case "session/set_mode":
      update(p.sessionId, { sessionUpdate: "current_mode_update", currentModeId: p.modeId });
      return out({ id: m.id, result: {} });
    case "session/set_config_option":
      return out({ id: m.id, result: { configOptions: config(p.value) } });
    case "session/close":
      out({ id: m.id, result: {} });
      return setTimeout(() => process.exit(0), 10);
    default:
      if (m.id !== undefined) out({ id: m.id, error: { code: -32601, message: "nope" } });
  }
});
