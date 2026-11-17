// Fake docker / systemctl / journalctl for the incident tests. State: $FAKE_OPS_DIR/state.json; every call is appended
// to $FAKE_OPS_DIR/calls.jsonl as {tool, argv, cwd}.
import { appendFileSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const [tool, ...argv] = process.argv.slice(2);
const dir = process.env.FAKE_OPS_DIR;
appendFileSync(join(dir, "calls.jsonl"), JSON.stringify({ tool, argv, cwd: process.cwd() }) + "\n");
let state = {};
try {
  state = JSON.parse(readFileSync(join(dir, "state.json"), "utf8"));
} catch {}
const out = (s) => process.stdout.write(s);
const save = () => writeFileSync(join(dir, "state.json"), JSON.stringify(state));
// Images (I-2): state.images = {"sha256:…": {Created, tags: ["repo:tag"], Containers?}}.
const images = () => (state.images ??= {});
const findImage = (ref) => (images()[ref] ? ref : Object.keys(images()).find((id) => images()[id].tags.includes(ref)));
const fail = (code, msg) => {
  process.stderr.write(msg);
  process.exit(code);
};

if (tool === "docker") {
  const [cmd, ...rest] = argv;
  const name = rest.at(-1);
  if (cmd === "inspect") {
    const names = rest.filter((a, i) => !a.startsWith("-") && rest[i - 1] !== "--type");
    const found = names.map((n) => state.containers?.[n]).filter(Boolean);
    if (names.length === 1 && !found.length) fail(1, `Error: No such object: ${name}`);
    out(JSON.stringify(found));
    if (found.length < names.length) process.exit(1);
  } else if (cmd === "image" && rest[0] === "inspect") {
    const id = findImage(name);
    if (!id) fail(1, `Error: No such image: ${name}`);
    out(`${id} ${images()[id].Created}\n`);
  } else if (cmd === "tag") {
    const [src, ref] = rest;
    const id = findImage(src);
    if (!id) fail(1, `Error response from daemon: No such image: ${src}`);
    for (const img of Object.values(images())) img.tags = img.tags.filter((t) => t !== ref);
    images()[id].tags.push(ref);
    save();
  } else if (cmd === "image" && rest[0] === "ls") {
    if (rest.includes("dangling=true")) out((state.danglingJson ?? []).map((j) => JSON.stringify(j)).join("\n") + "\n");
    else {
      const repo = rest[1];
      const lines = Object.entries(images()).flatMap(([id, img]) => img.tags.filter((t) => t.startsWith(repo + ":")).map((t) => `${t} ${id}`));
      out(lines.join("\n") + "\n");
    }
  } else if (cmd === "image" && rest[0] === "rm") {
    const id = findImage(name);
    if (!id) fail(1, `Error: No such image: ${name}`);
    images()[id].tags = images()[id].tags.filter((t) => t !== name);
    save();
  } else if (cmd === "image" && rest[0] === "prune") {
    // Like docker: without -a only dangling (untagged) images that no container uses.
    const all = rest.includes("-a") || rest.includes("--all");
    for (const [id, img] of Object.entries(images())) if ((all || !img.tags.length) && !img.Containers) delete images()[id];
    save();
    out("Total reclaimed space: 0B\n");
  } else if ((cmd === "builder" || cmd === "container") && rest[0] === "prune") {
    out("Total reclaimed space: 0B\n");
  } else if (cmd === "system" && rest[0] === "df") {
    if (state.noDocker) fail(1, "Cannot connect to the Docker daemon");
    out(state.systemDf ?? "");
  } else if (cmd === "logs") {
    const c = state.logs?.[name] ?? [];
    out(c.map((l) => `2026-11-17T10:00:00.000000000Z ${l}`).join("\n") + "\n");
  } else if (cmd === "restart") {
    if (state.failRestart) fail(1, "Error response from daemon: boom password=leaky123");
    if (state.slowMs) await new Promise((r) => setTimeout(r, state.slowMs));
    out(name + "\n");
  } else if (cmd === "compose") {
    // `up … <svc>` recreates the service's containers from whatever image their reference points at now.
    if (rest.includes("up") && state.images && !state.composeNoop) {
      for (const c of Object.values(state.containers ?? {})) {
        if (c.Config?.Labels?.["com.docker.compose.service"] !== name) continue;
        const id = findImage(c.Config.Image);
        if (id) Object.assign(c, { Image: id, State: { ...c.State, Status: "running", Running: true } });
      }
      save();
    }
    out("");
  } else if (cmd === "ps") {
    out((state.psNames ?? []).join("\n") + "\n");
  } else if (cmd === "stats") {
    out("");
  } else fail(1, "unknown docker command");
} else if (tool === "systemctl") {
  if (argv.includes("is-active")) out((state.unitState ?? "active") + "\n");
  else out("");
} else if (tool === "journalctl") {
  if (argv.includes("--disk-usage")) {
    out(state.journalUsage ?? "Archived and active journals take up 8.0M in the file system.\n");
    process.exit(0);
  }
  out((state.journal ?? []).join("\n") + "\n");
} else if (tool === "git") {
  out("");
}
