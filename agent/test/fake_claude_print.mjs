// Fake `claude -p` for the analysis tests: stores argv and stdin in $FAKE_CLAUDE_DIR, prints a print-mode JSON result
// whose structured_output is $FAKE_CLAUDE_DIR/out.json.
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const dir = process.env.FAKE_CLAUDE_DIR;
let input = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d) => (input += d));
process.stdin.on("end", () => {
  writeFileSync(join(dir, "stdin.txt"), input);
  writeFileSync(join(dir, "args.json"), JSON.stringify({ argv: process.argv.slice(2), cwd: process.cwd() }));
  const out = JSON.parse(readFileSync(join(dir, "out.json"), "utf8"));
  process.stdout.write(JSON.stringify({ type: "result", subtype: "success", is_error: false, structured_output: out }) + "\n");
});
