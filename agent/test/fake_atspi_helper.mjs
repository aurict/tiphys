// Fake AT-SPI helper (atspi.test.ts): a small imitation of the real protocol (version 1). FAKE_MODE:
// ok | missing (no gi) | crash (dies on the first request) | hang (never replies) | big (unbounded lines) |
// version (version 99) | unfocused (is_focused always false: focus fallback after raising the window).
// If FAKE_LOG is set, every start and command name is appended to that file (contents are not written).
import { appendFileSync } from "node:fs";
import { createInterface } from "node:readline";

const mode = process.env.FAKE_MODE ?? "ok";
const log = (s) => process.env.FAKE_LOG && appendFileSync(process.env.FAKE_LOG, s + "\n");
const out = (o) => process.stdout.write(JSON.stringify(o) + "\n");
log(`start ${process.pid}`);

if (mode === "missing") {
  out({ event: "fatal", code: "helperMissing" });
  process.exit(3);
}
out({ event: "hello", version: mode === "version" ? 99 : 1 });

const NODES = [
  { id: "0", parent: null, depth: 0, role: "tool bar", name: "Gezinti", desc: "", states: ["enabled"], value: null, text: null, actions: [] },
  { id: "0.0", parent: "0", depth: 1, role: "button", name: "Geri", desc: "", states: ["enabled"], value: null, text: null, actions: ["press"] },
  { id: "1", parent: null, depth: 0, role: "entry", name: "Ara", desc: "", states: ["enabled", "editable"], value: null, text: "", actions: [] },
  { id: "2", parent: null, depth: 0, role: "password text", name: "Şifre", desc: "", states: ["enabled", "editable"], value: null, text: null, password: true, actions: [] },
  { id: "3", parent: null, depth: 0, role: "slider", name: "Ses", desc: "", states: ["enabled"], value: { now: 1, min: 0, max: 10, step: 1 }, text: null, actions: [] },
  { id: "4", parent: null, depth: 0, role: "label", name: "Yalnız yazılır", desc: "", states: [], value: null, text: null, actions: [] },
  { id: "5", parent: null, depth: 0, role: "push button", name: "Sil", desc: "", states: ["enabled"], value: null, text: null, actions: ["press"] },
];
let gen = 0;
let first = true;

createInterface({ input: process.stdin }).on("line", (line) => {
  const req = JSON.parse(line);
  log(`cmd ${req.cmd}`);
  if (mode === "crash" && first) process.exit(1);
  first = false;
  if (mode === "hang") return;
  if (mode === "big") {
    process.stdout.write("x".repeat(256 * 1024));
    return;
  }
  const err = (code) => out({ id: req.id, error: { code } });
  if (req.cmd === "snapshot") {
    if (req.pid === 999) return err("unsupported");
    gen++;
    return out({ id: req.id, ok: true, gen, title: req.title, partial: req.pid === 4321, nodes: req.pid === 777 ? [] : NODES });
  }
  if (req.gen !== gen) return err("stale");
  const node = NODES.find((n) => n.id === req.node);
  if (!node) return err("stale");
  switch (req.cmd) {
    case "act":
      out({ id: req.id, ok: true });
      setTimeout(() => out({ event: "changed" }), 30);
      return;
    case "set_text":
      if (node.password && req.confirm !== true) return err("confirmRequired");
      if (node.id === "4" && req.typing === false) return err("noAction"); // keyboard fallback not requested
      return out({ id: req.id, ok: true, needsTyping: node.id === "4" });
    case "is_focused":
      return out({ id: req.id, ok: true, focused: mode !== "unfocused" && node.id === "4" });
    case "set_value":
    case "focus":
    case "select":
      return out({ id: req.id, ok: true });
  }
  err("badRequest");
});
