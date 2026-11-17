#!/usr/bin/env node
// Fake `docker` for the restore test (D-4): logs argv (and a stdin summary for `exec -i`) to $FAKE_DOCKER_LOG;
// behaviour from the JSON file $FAKE_DOCKER_CFG: {runFail, sourceImage, sanity: {<sql>: "<stdout>"}, sanityFail: [sql],
// hang: true (the stdin consumer never exits), readyFailures: n, runHang: true (`docker run` never returns),
// psDelayMs: n (`docker ps` answers late), restoreStderr: "<text>" (restore fails with it), sanityStderr: "<text>"
// (failed sanity stderr; $PWD is replaced by $MYSQL_PWD)}.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";

const argv = process.argv.slice(2);
const cfg = process.env.FAKE_DOCKER_CFG ? JSON.parse(readFileSync(process.env.FAKE_DOCKER_CFG, "utf8")) : {};
const log = (o) => appendFileSync(process.env.FAKE_DOCKER_LOG, JSON.stringify({ argv, env: { pg: process.env.POSTGRES_PASSWORD ? "set" : undefined, my: process.env.MYSQL_PWD ? "set" : undefined }, ...o }) + "\n");
const [cmd] = argv;

if (cmd === "run") {
  log({});
  if (cfg.runHang) setInterval(() => {}, 1000);
  if (cfg.runFail) {
    process.stderr.write("docker: Error response from daemon: pull access denied\n");
    process.exit(125);
  }
  else console.log("a".repeat(64));
} else if (cmd === "ps") {
  if (cfg.psDelayMs) await new Promise((r) => setTimeout(r, cfg.psDelayMs));
  log({});
} else if (cmd === "rm") {
  log({});
} else if (cmd === "inspect") {
  log({});
  console.log(cfg.sourceImage ?? "postgres:16-alpine");
} else if (cmd === "exec") {
  let i = 1;
  let stdin = false;
  while (argv[i]?.startsWith("-")) {
    if (argv[i] === "-i") stdin = true;
    if (argv[i] === "-e") i++;
    i++;
  }
  const tool = argv[i + 1];
  if (tool === "pg_isready" || tool === "mysqladmin" || tool === "mariadb-admin") {
    log({ tool });
    const f = process.env.FAKE_DOCKER_LOG + ".ready";
    const n = existsSync(f) ? Number(readFileSync(f, "utf8")) : 0;
    writeFileSync(f, String(n + 1));
    process.exit(n < (cfg.readyFailures ?? 0) ? 1 : 0);
  } else if (stdin) {
    const chunks = [];
    for await (const c of process.stdin) chunks.push(c);
    const body = Buffer.concat(chunks).toString("utf8");
    log({ tool, stdin: body.slice(0, 200), stdinBytes: body.length });
    if (cfg.hang) setInterval(() => {}, 1000);
    else if (cfg.restoreStderr) {
      process.stderr.write(cfg.restoreStderr);
      process.exit(3);
    } else if (body.includes("CORRUPT")) {
      process.stderr.write("psql: ERROR:  syntax error at or near \"CORRUPT\"\n");
      process.exit(3);
    } else process.exit(0);
  } else {
    const sql = argv[argv.length - 1];
    log({ tool, sql });
    if ((cfg.sanityFail ?? []).includes(sql)) {
      process.stderr.write(cfg.sanityStderr ? cfg.sanityStderr.replace("$PWD", process.env.MYSQL_PWD ?? "") : 'ERROR:  relation "nope" does not exist\n');
      process.exit(1);
    }
    process.stdout.write((cfg.sanity?.[sql] ?? "1") + "\n");
  }
} else process.exit(2);
