// Security fix sessions (PLAN.md §16 F2): running commands on a pinned target and classifying them.
// - resolveSsh: at pin time `ssh -G` resolves the destination once (host name, user, port, identity and known_hosts
//   files, host key alias, certificates). Destinations needing ProxyCommand/ProxyJump/LocalCommand/
//   KnownHostsCommand are refused. Every later connection uses `-F /dev/null` plus those pinned values, so editing
//   ~/.ssh/config mid-session changes nothing.
// - execOn: a target with ssh null runs `/bin/sh -c` here (cwd /). Remote targets get `ssh -F /dev/null
//   -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 -o ForwardAgent=no -o ClearAllForwardings=yes
//   -o ForwardX11=no -o PermitLocalCommand=no <pinned -o values> -- host <wrapper>`. OpenSSH hands the command to the
//   remote LOGIN shell (which may be fish or csh), so the wrapper is `/bin/sh -c 'PATH=…; eval "$(printf %s <base64>
//   | base64 -d)"'`: only a single-quoted string without quotes or backslashes inside, read the same way by sh, bash,
//   zsh, fish and csh. The decoded script runs under /usr/bin/timeout -k 5 <n> so a killed ssh can't leave the
//   command running. PATH is set outright to /usr/sbin:/usr/bin:/sbin:/bin; sudo is /usr/bin/sudo (`command -v`
//   only if that is missing).
// - lex: a POSIX-style lexer (quotes, backslashes, $( ) and backticks as nested command lists, operators, redirects)
//   producing dequoted words. Both checks below work on its output, so quote tricks (-e''xec, -\exec) don't help.
// - isReadCommand: strict. No $, backtick, parentheses, redirection (except 2>/dev/null, 2>&1), &, newline, comment,
//   brace expansion or assignment; segments joined by | && || ; where the first command of every pipeline is an
//   allowlisted read (exact options and verbs per command) and piped commands are pure filters. With sudo only a
//   smaller root-safe set counts as a read. Anything else is a change (asks or is refused by the mode).
// - blockedReason: a denylist applied in every mode (bypassPermissions too): network tools anywhere in the command,
//   nested ssh, git/openssl/docker remote use, shells running scripts or stdin, interpreters, eval/source, command
//   names built from variables, remote-host options of systemctl & co, /dev/tcp. Wrappers (sudo, env, timeout,
//   xargs, find -exec, sh -c, su -c, watch, busybox…) are followed. It is a best-effort filter over the command text,
//   NOT a sandbox: a determined command can still reach the network. The real limits are host pinning, the mode and
//   approval rules, and the user watching.
import { spawn } from "node:child_process";

/** ssh settings resolved with `ssh -G` when the target was pinned. */
export interface SshResolved {
  hostname: string;
  user: string;
  port: number;
  identityFiles: string[];
  knownHosts: string;
  hostKeyAlias: string | null;
  certificateFiles: string[];
  identitiesOnly: boolean;
}

export interface Target {
  /** Security host id as known on the monitoring server. */
  host: string;
  name: string;
  /** "user@host" or an ssh alias; null = this machine. */
  ssh: string | null;
  port?: number;
  /** Pinned `ssh -G` result (remote targets). */
  resolved?: SshResolved;
}

export interface ExecOut {
  code: number;
  stdout: string;
  stderr: string;
  timedOut: boolean;
}

export interface ExecEnv {
  /** ssh binary (tests use a fake script that hands the command to a shell like OpenSSH does). */
  sshBin: string;
  /** Extra environment for spawned processes (tests: HOME, fake tool settings). */
  env?: Record<string, string>;
  /** PATH set inside every command (tests put their fakes first). */
  path?: string;
  sudoBin?: string;
  timeoutBin?: string;
}

export const SAFE_PATH = "/usr/sbin:/usr/bin:/sbin:/bin";

/** `"$S"` resolved to the sudo binary: the fixed path, `command -v sudo` only if it is missing. */
export const sudoPrefix = (env: ExecEnv) => `S=${q(env.sudoBin ?? "/usr/bin/sudo")}; [ -x "$S" ] || S=$(command -v sudo) || exit 127; LC_ALL=C "$S"`;

/** Bytes kept per stream (read_file needs 256 KB, write_file's previous content up to 1 MB for the diff). */
const CAPTURE = 1024 * 1024 + 4096;

/** POSIX shell single-quoting. */
export const q = (s: string) => `'${s.replace(/'/g, `'\\''`)}'`;

export const SSH_OPTIONS = [
  "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=10",
  "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no",
];

/** The remote command: valid in any login shell (one single-quoted string, no quotes inside), runs `script` under sh. */
export function remoteWrapper(script: string, timeoutSec: number, timeoutBin = "/usr/bin/timeout"): string {
  const inner = `T=${q(timeoutBin)}; [ -x "$T" ] || T=$(command -v timeout) || exit 127; exec "$T" -k 5 ${Math.max(1, Math.ceil(timeoutSec))} /bin/sh -c ${q(script)}`;
  return `/bin/sh -c 'PATH=${SAFE_PATH}; eval "$(printf %s ${Buffer.from(inner).toString("base64")} | base64 -d)"'`;
}

/** Pinned ssh arguments: no config file, only the resolved values (plus the safety options). */
export function sshArgs(r: SshResolved, fresh = false): string[] {
  return [
    "-F", "/dev/null", ...SSH_OPTIONS,
    "-o", `HostName=${r.hostname}`, "-o", `User=${r.user}`, "-o", `Port=${r.port}`,
    ...r.identityFiles.flatMap((f) => ["-o", `IdentityFile=${f}`]),
    "-o", `UserKnownHostsFile=${r.knownHosts}`,
    ...(r.hostKeyAlias ? ["-o", `HostKeyAlias=${r.hostKeyAlias}`] : []),
    ...r.certificateFiles.flatMap((f) => ["-o", `CertificateFile=${f}`]),
    "-o", `IdentitiesOnly=${r.identitiesOnly ? "yes" : "no"}`,
    ...(fresh ? ["-o", "ControlMaster=no", "-o", "ControlPath=none"] : []),
    "--", r.hostname,
  ];
}

const SSH_VALUE = /^[^\0\n\r"']{1,1024}$/;
/** Settings that make ssh run local commands or hop through other hosts: such destinations are refused. */
const SSH_REFUSE = ["proxycommand", "proxyjump", "localcommand", "knownhostscommand"];

/** `ssh -G` for a target (pin time). Throws an Error whose message is the reason. */
export async function resolveSsh(t: Target, env: ExecEnv): Promise<SshResolved> {
  const r = await new Promise<ExecOut>((resolve) => {
    const child = spawn(env.sshBin, ["-G", ...(t.port ? ["-p", String(t.port)] : []), "--", t.ssh!], { env: { ...process.env, LC_ALL: "C.UTF-8", ...env.env }, stdio: ["ignore", "pipe", "pipe"] });
    let out = "";
    let err = "";
    const timer = setTimeout(() => child.kill("SIGKILL"), 10_000);
    child.stdout.on("data", (b: Buffer) => (out += b));
    child.stderr.on("data", (b: Buffer) => (err += b));
    child.on("error", (e) => (clearTimeout(timer), resolve({ code: 127, stdout: "", stderr: e.message, timedOut: false })));
    child.on("close", (code) => (clearTimeout(timer), resolve({ code: code ?? -1, stdout: out, stderr: err, timedOut: false })));
  });
  if (r.code !== 0) throw new Error(`ssh -G failed: ${r.stderr.trim().slice(0, 300)}`);
  const all = new Map<string, string[]>();
  for (const line of r.stdout.split("\n")) {
    const m = /^(\S+)\s+(.*)$/.exec(line.trim());
    if (m) all.set(m[1]!.toLowerCase(), [...(all.get(m[1]!.toLowerCase()) ?? []), m[2]!]);
  }
  const one = (k: string) => all.get(k)?.[0];
  for (const k of SSH_REFUSE) if ((all.get(k) ?? []).some((v) => v.toLowerCase() !== "none")) throw new Error(`${k} is set for this destination`);
  const hostname = one("hostname") ?? "";
  const user = one("user") ?? "";
  const port = Number(one("port") ?? 22);
  if (!/^[A-Za-z0-9_.:-]{1,253}$/.test(hostname) || hostname.startsWith("-")) throw new Error("unusable hostname");
  if (!/^[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}$/.test(user)) throw new Error("unusable user");
  if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error("unusable port");
  const files = (k: string) => (all.get(k) ?? []).filter((v) => v.toLowerCase() !== "none");
  const values = [...files("identityfile"), ...files("certificatefile"), one("userknownhostsfile") ?? "", one("hostkeyalias") ?? ""];
  if (values.some((v) => v && !SSH_VALUE.test(v))) throw new Error("unusable file setting");
  const alias = one("hostkeyalias");
  return {
    hostname,
    user,
    port,
    identityFiles: files("identityfile"),
    knownHosts: one("userknownhostsfile") ?? "~/.ssh/known_hosts",
    hostKeyAlias: alias && alias.toLowerCase() !== "none" ? alias : null,
    certificateFiles: files("certificatefile"),
    identitiesOnly: one("identitiesonly") === "yes",
  };
}

/** Runs `cmd` on the target. `fresh`: a brand-new ssh connection (no ControlMaster reuse; safe_apply's test). */
export function execOn(
  t: Target,
  cmd: string,
  o: { stdin?: string; timeoutMs: number; signal?: AbortSignal; fresh?: boolean },
  env: ExecEnv,
): Promise<ExecOut> {
  const script = `PATH=${q(env.path ?? SAFE_PATH)}; export PATH\n${cmd}`;
  const remote = t.ssh !== null;
  if (remote && !t.resolved) return Promise.resolve({ code: 255, stdout: "", stderr: "target has no pinned ssh settings; open a new session", timedOut: false });
  const [file, args] = !remote ? ["/bin/sh", ["-c", script]] : [env.sshBin, [...sshArgs(t.resolved!, o.fresh), remoteWrapper(script, o.timeoutMs / 1000, env.timeoutBin)]];
  return new Promise((resolve) => {
    const child = spawn(file, args, { cwd: "/", env: { ...process.env, LC_ALL: "C.UTF-8", ...env.env }, detached: true, stdio: ["pipe", "pipe", "pipe"] });
    const out: Buffer[] = [];
    const err: Buffer[] = [];
    let outN = 0;
    let errN = 0;
    let timedOut = false;
    const kill = () => {
      try {
        process.kill(-child.pid!, "SIGKILL");
      } catch {
        child.kill("SIGKILL");
      }
    };
    // Remote: the remote `timeout` acts first; this one only catches a hung connection.
    const timer = setTimeout(() => ((timedOut = true), kill()), o.timeoutMs + (remote ? 15_000 : 0));
    const onAbort = () => kill();
    o.signal?.addEventListener("abort", onAbort, { once: true });
    child.stdout.on("data", (b: Buffer) => outN < CAPTURE && (out.push(b), (outN += b.length)));
    child.stderr.on("data", (b: Buffer) => errN < CAPTURE && (err.push(b), (errN += b.length)));
    child.stdin.on("error", () => {});
    child.stdin.end(o.stdin ?? "");
    const finish = (code: number, extraErr = "") => {
      clearTimeout(timer);
      o.signal?.removeEventListener("abort", onAbort);
      if (remote && (code === 124 || code === 137)) timedOut = true;
      resolve({ code, stdout: Buffer.concat(out).toString("utf8"), stderr: Buffer.concat(err).toString("utf8") + extraErr, timedOut });
    };
    child.on("error", (e) => finish(127, String(e.message)));
    child.on("close", (code) => finish(code ?? -1));
  });
}

// ---- lexer ----

export interface Word {
  t: "w";
  /** Dequoted text. */
  text: string;
  /** Contains an unquoted or double-quoted $ / substitution (value only known at run time). */
  dyn: boolean;
  /** Unquoted * ? [ (pathname expansion). */
  glob: boolean;
  /** Unquoted { or } (brace expansion, groups). */
  brace: boolean;
  /** Command lists of $( ), backticks, <( ), >( ) inside the word. */
  subs: Tok[][];
}
export type Tok = Word | { t: "op"; op: string; fd?: string };

const OPS = ["<<<", "&>>", "<<-", ">>", "<<", "&&", "||", ">&", "<&", "&>", ">|", "<>", ";;", "|&"];
export const REDIRECTS = new Set(["<<<", "&>>", "<<-", ">>", "<<", ">&", "<&", "&>", ">|", "<>", "<", ">"]);

/** Lexes a shell command; `bad` names the first construct the lexer couldn't follow (unterminated quote…). */
export function lex(s: string): { toks: Tok[]; bad: string | null } {
  let i = 0;
  let bad: string | null = null;
  let nest = 0;
  const run = (end: ")" | "`" | null): Tok[] => {
    if (++nest > 32) {
      bad ??= "nested too deeply";
      i = s.length;
      return [];
    }
    const toks: Tok[] = [];
    let w: Word | null = null;
    let depth = 0;
    const word = () => (w ??= { t: "w", text: "", dyn: false, glob: false, brace: false, subs: [] });
    const flush = () => {
      if (w) toks.push(w);
      w = null;
    };
    const sub = (closer: ")" | "`") => {
      const ww = word();
      ww.dyn = true;
      ww.subs.push(run(closer));
    };
    while (i < s.length) {
      const c = s[i]!;
      if (end === "`" && c === "`") return (i++, flush(), toks);
      if (end === ")" && c === ")" && depth === 0) return (i++, flush(), toks);
      if (c === "\\") {
        if (i + 1 >= s.length) {
          bad ??= "trailing backslash";
          i++;
          continue;
        }
        if (s[i + 1] !== "\n") word().text += s[i + 1];
        i += 2;
        continue;
      }
      if (c === "'") {
        const j = s.indexOf("'", i + 1);
        if (j < 0) {
          bad ??= "unterminated quote";
          word().text += s.slice(i + 1);
          i = s.length;
          break;
        }
        word().text += s.slice(i + 1, j);
        i = j + 1;
        continue;
      }
      if (c === '"') {
        const ww = word();
        i++;
        while (i < s.length && s[i] !== '"') {
          const d = s[i]!;
          if (d === "\\" && i + 1 < s.length && '$`"\\\n'.includes(s[i + 1]!)) {
            if (s[i + 1] !== "\n") ww.text += s[i + 1];
            i += 2;
          } else if (d === "$" && s[i + 1] === "(") {
            i += 2;
            sub(")");
          } else if (d === "`") {
            i++;
            sub("`");
          } else {
            if (d === "$") ww.dyn = true;
            ww.text += d;
            i++;
          }
        }
        if (i >= s.length) bad ??= "unterminated quote";
        else i++;
        continue;
      }
      if (c === "$" && s[i + 1] === "(") {
        i += 2;
        sub(")");
        continue;
      }
      if (c === "`") {
        i++;
        sub("`");
        continue;
      }
      if (c === "$") {
        word().dyn = true;
        word().text += c;
        i++;
        continue;
      }
      if (c === " " || c === "\t") {
        flush();
        i++;
        continue;
      }
      if (c === "#" && !w) {
        bad ??= "comment";
        while (i < s.length && s[i] !== "\n") i++;
        continue;
      }
      if ((c === "<" || c === ">") && s[i + 1] === "(") {
        flush();
        i += 2;
        toks.push({ t: "w", text: "", dyn: true, glob: false, brace: false, subs: [run(")")] });
        continue;
      }
      const op = OPS.find((o) => s.startsWith(o, i)) ?? (";&|<>()\n\r".includes(c) ? c : null);
      if (op) {
        const cur = w as Word | null;
        const fd = cur && /^\d+$/.test(cur.text) && !cur.dyn && /^[<>]/.test(op) ? cur.text : undefined;
        if (fd) w = null;
        flush();
        i += op.length;
        if (op === "(") depth++;
        if (op === ")" && depth > 0) depth--;
        toks.push({ t: "op", op: op === "\r" ? "\n" : op, ...(fd ? { fd } : {}) });
        continue;
      }
      if ("*?[".includes(c)) word().glob = true;
      if ("{}".includes(c)) word().brace = true;
      word().text += c;
      i++;
    }
    flush();
    if (end) bad ??= "unterminated substitution";
    return toks;
  };
  const toks = run(null);
  return { toks, bad };
}

/** Basename of a command word (a/b/curl → curl). */
const baseName = (w: string) => w.slice(w.lastIndexOf("/") + 1);
const BIN_PATH = /^\/(?:usr\/(?:local\/)?)?s?bin\/[A-Za-z0-9._+-]+$/;

// ---- read classification ----

interface OptSpec {
  /** Single-letter flags without a value. */
  flags?: string;
  /** Single-letter flags taking a value (attached or the next word). */
  valued?: string;
  long?: string[];
  longValued?: string[];
  /** Any option is fine (command has no writing/following option), except those matching deny. */
  any?: boolean;
  deny?: RegExp;
}

/** Positional words if every option is allowed, else null. */
function positionals(args: string[], o: OptSpec): string[] | null {
  const pos: string[] = [];
  for (let k = 0; k < args.length; k++) {
    const a = args[k]!;
    if (o.deny?.test(a)) return null;
    if (a === "--") {
      pos.push(...args.slice(k + 1));
      break;
    }
    if (a.startsWith("--")) {
      if (o.any) continue;
      const eq = a.indexOf("=");
      const name = eq < 0 ? a : a.slice(0, eq);
      if (eq < 0 && o.long?.includes(name)) continue;
      if (o.longValued?.includes(name)) {
        if (eq < 0) k++;
        continue;
      }
      return null;
    }
    if (a.startsWith("-") && a.length > 1) {
      if (o.any) continue;
      for (let j = 1; j < a.length; j++) {
        const ch = a[j]!;
        if (o.valued?.includes(ch)) {
          if (j === a.length - 1) k++;
          break;
        }
        if (!o.flags?.includes(ch)) return null;
      }
      continue;
    }
    pos.push(a);
  }
  return pos;
}

type Check = (args: string[]) => boolean;
const opts = (o: OptSpec, check: (pos: string[], args: string[]) => boolean = () => true): Check => (args) => {
  const p = positionals(args, o);
  return p !== null && check(p, args);
};
const anyOpts = (deny?: RegExp): Check => opts({ any: true, ...(deny ? { deny } : {}) });
/** A short-option word (or cluster) containing one of these letters. */
const has = (args: string[], ...letters: string[]) => args.some((a) => /^-[A-Za-z]+$/.test(a) && letters.some((l) => a.includes(l)));

const HEAD_TAIL: OptSpec = { flags: "qvz0123456789", valued: "nc", long: ["--quiet", "--silent", "--verbose", "--zero-terminated"], longValued: ["--lines", "--bytes"] };
const SED_SCRIPT = /^(?:(?:\d+|\$|\/(?:[^/\\\n]|\\.)*\/)(?:,(?:\d+|\$|\/(?:[^/\\\n]|\\.)*\/))?\s*[pd=]|s\/(?:[^/\\\n]|\\.)*\/(?:[^/\\\n]|\\.)*\/[gpI]*|q)$/;
const AWK_UNSAFE = /system|getline|\||>|close|fflush|ENVIRON|\/inet|@/;

/** Filters: may read stdin from a pipe; no writing, no following, no commands. */
const FILTERS: Record<string, Check> = {
  cat: anyOpts(),
  grep: anyOpts(),
  egrep: anyOpts(),
  fgrep: anyOpts(),
  zgrep: anyOpts(),
  head: opts(HEAD_TAIL),
  tail: opts(HEAD_TAIL),
  wc: anyOpts(),
  cut: opts({ flags: "sz", valued: "bcdf", long: ["--complement", "--only-delimited", "--zero-terminated"], longValued: ["--bytes", "--characters", "--delimiter", "--fields", "--output-delimiter"] }),
  tr: opts({ flags: "cdsCt" }),
  nl: anyOpts(),
  column: anyOpts(),
  jq: anyOpts(),
  md5sum: anyOpts(),
  sha256sum: anyOpts(),
  sort: opts({ flags: "bdfgiMhnRrsuVzc", valued: "kt", long: ["--numeric-sort", "--reverse", "--unique", "--human-numeric-sort", "--version-sort", "--ignore-case"], longValued: ["--key", "--field-separator"] }),
  uniq: opts({ flags: "cdDiuz", valued: "fsw", long: ["--count", "--repeated", "--unique", "--ignore-case"] }, (p) => p.length <= 1),
  awk: opts({ valued: "Fv" }, (p, a) => p.length >= 1 && !AWK_UNSAFE.test(p[0]!) && !a.some((x) => x.includes("@"))),
  sed: opts({ flags: "nEr", long: ["--quiet", "--silent", "--regexp-extended", "--posix"] }, (p) => p.length >= 1 && SED_SCRIPT.test(p[0]!.trim())),
};
FILTERS.gawk = FILTERS.awk!;
FILTERS.mawk = FILTERS.awk!;

const SYSTEMCTL_READ = new Set(["status", "is-active", "is-enabled", "is-failed", "show", "cat", "list-units", "list-unit-files", "list-timers", "list-sockets", "list-dependencies", "list-jobs"]);
const IP_OBJECTS = new Set(["a", "addr", "address", "r", "ro", "route", "l", "link", "n", "neigh", "neighbour", "neighbor", "ru", "rule", "maddr", "netconf"]);
const IP_GLOBAL = new Set(["-4", "-6", "-br", "-brief", "-s", "-stats", "-statistics", "-d", "-details", "-j", "-json", "-p", "-pretty", "-o", "-oneline", "-c", "-color", "-h", "-human"]);
const FIND_NOARG = new Set(["-print", "-print0", "-ls", "-xdev", "-mount", "-nouser", "-nogroup", "-readable", "-writable", "-executable", "-empty", "-o", "-a", "-or", "-and", "-not", "!", "(", ")", "-true", "-false", "-prune", "-depth", "-noleaf", "-daystart"]);
const FIND_ARG = new Set([
  "-name", "-iname", "-path", "-ipath", "-wholename", "-iwholename", "-type", "-xtype", "-user", "-group", "-uid", "-gid", "-perm", "-size", "-mtime", "-mmin",
  "-atime", "-amin", "-ctime", "-cmin", "-newer", "-maxdepth", "-mindepth", "-links", "-inum", "-samefile", "-regex", "-iregex", "-regextype", "-lname", "-ilname", "-fstype", "-used",
]);

function findOk(a: string[]): boolean {
  let k = 0;
  while (k < a.length && /^-[HLP]$/.test(a[k]!)) k++;
  while (k < a.length && !a[k]!.startsWith("-") && !["(", ")", "!"].includes(a[k]!)) k++;
  for (; k < a.length; k++) {
    if (FIND_NOARG.has(a[k]!)) continue;
    if (FIND_ARG.has(a[k]!) && k + 1 < a.length) {
      k++;
      continue;
    }
    return false;
  }
  return true;
}

/** `nft list` with a fixed shape and plain words only (nft parses its words as one command line: no ; { } \). */
const NFT_LIST: Record<string, number[]> = { ruleset: [0, 1], tables: [0, 1], chains: [0, 1], sets: [0, 1], maps: [0, 1], table: [1, 2], chain: [3], set: [3], map: [3] };
function nftListOk(p: string[]): boolean {
  if (p[0] !== "list" || !p.every((w) => /^[A-Za-z0-9_.-]{1,64}$/.test(w))) return false;
  const n = NFT_LIST[p[1] ?? ""];
  return !!n && Object.hasOwn(NFT_LIST, p[1]!) && n.includes(p.length - 2);
}

function ipOk(a: string[]): boolean {
  let k = 0;
  while (k < a.length && a[k]!.startsWith("-")) {
    if (IP_GLOBAL.has(a[k]!)) k++;
    else if (a[k] === "-f" || a[k] === "-family") k += 2;
    else return false;
  }
  if (!IP_OBJECTS.has(a[k] ?? "")) return false;
  const verb = a[k + 1];
  return verb === undefined || verb === "show" || verb === "list" || verb === "ls" || verb === "lst";
}

const DOCKER_LIST: OptSpec = { flags: "aqsl", valued: "fn", long: ["--all", "--quiet", "--size", "--latest", "--no-trunc", "--digests"], longValued: ["--filter", "--format", "--last", "--type"] };
const DOCKER_INSPECT: OptSpec = { flags: "s", valued: "f", long: ["--size"], longValued: ["--format", "--type"] };
const COMPOSE_GLOBAL = new Set(["-f", "--file", "-p", "--project-name", "--project-directory", "--env-file", "--profile", "--ansi", "--progress", "--parallel"]);
const COMPOSE_READ: Record<string, Check> = {
  ps: opts({ flags: "aq", long: ["--all", "--quiet", "--services", "--no-trunc"], longValued: ["--format", "--filter", "--status"] }),
  ls: opts({ flags: "aq", long: ["--all", "--quiet"], longValued: ["--format", "--filter"] }),
  images: opts({ flags: "q", long: ["--quiet"], longValued: ["--format"] }),
  version: opts({ long: ["--short"], longValued: ["--format"] }),
  config: opts({
    flags: "q",
    long: ["--quiet", "--services", "--volumes", "--images", "--profiles", "--networks", "--no-interpolate", "--no-normalize", "--resolve-image-digests", "--no-path-resolution", "--no-consistency", "--environment", "--variables"],
    longValued: ["--format", "--hash"],
  }),
};

function dockerOk(a: string[]): boolean {
  const [sub, ...rest] = a;
  if (!sub || sub.startsWith("-")) return false; // no global options: -H, --context, --config, -l…
  switch (sub) {
    case "ps":
    case "images":
      return opts(DOCKER_LIST)(rest);
    case "inspect":
      return opts(DOCKER_INSPECT, (p) => p.length >= 1)(rest);
    case "version":
    case "info":
      return opts({ valued: "f", longValued: ["--format"] }, (p) => p.length === 0)(rest);
    case "logs":
      return opts({ flags: "t", valued: "n", long: ["--timestamps", "--details"], longValued: ["--tail", "--since", "--until"] }, (p) => p.length === 1)(rest);
    case "container":
    case "image":
    case "network":
    case "volume": {
      const [verb, ...r] = rest;
      if (verb === "ls" || verb === "list" || verb === "ps") return opts(DOCKER_LIST)(r);
      return verb === "inspect" && opts(DOCKER_INSPECT, (p) => p.length >= 1)(r);
    }
    case "compose": {
      let k = 0;
      while (k < rest.length && rest[k]!.startsWith("-")) {
        const name = rest[k]!.split("=")[0]!;
        if (!COMPOSE_GLOBAL.has(name)) return false;
        k += rest[k]!.includes("=") ? 1 : 2;
      }
      const check = COMPOSE_READ[rest[k] ?? ""];
      return !!check && check(rest.slice(k + 1));
    }
    default:
      return false;
  }
}

/** Read sources (first command of a pipeline). Filters count as reads too. */
const READS: Record<string, Check> = {
  ...FILTERS,
  ls: anyOpts(),
  stat: anyOpts(),
  id: anyOpts(),
  uname: anyOpts(),
  df: anyOpts(),
  du: anyOpts(),
  ps: anyOpts(),
  who: anyOpts(),
  w: anyOpts(),
  last: anyOpts(),
  uptime: anyOpts(),
  whoami: anyOpts(),
  groups: anyOpts(),
  pwd: anyOpts(),
  nproc: anyOpts(),
  namei: anyOpts(),
  lsattr: anyOpts(),
  getfacl: anyOpts(),
  sha1sum: anyOpts(),
  sha512sum: anyOpts(),
  realpath: anyOpts(),
  readlink: anyOpts(),
  cmp: anyOpts(),
  diff: anyOpts(),
  lsblk: anyOpts(),
  findmnt: anyOpts(/^--poll|^-[A-Za-z]*p/),
  lsof: anyOpts(/^[-+]r/),
  echo: anyOpts(),
  printf: anyOpts(/^-[A-Za-z]*v/),
  which: anyOpts(),
  test: anyOpts(),
  true: anyOpts(),
  "aa-status": anyOpts(),
  apparmor_status: anyOpts(),
  getenforce: anyOpts(),
  sestatus: anyOpts(),
  free: opts({ flags: "bkmgthwlv", long: ["--human", "--wide", "--total", "--lohi", "--bytes", "--kilo", "--mega", "--giga", "--si"] }),
  ss: opts({ flags: "tulpnaexmoiHrs46wxOZ", valued: "fA", longValued: ["--family", "--query"] }),
  netstat: opts({ flags: "tulpnaresWiwx46g" }),
  getent: opts({}, (p) => p[0] === "passwd" || p[0] === "group"),
  command: opts({ flags: "vVp" }, (_p, a) => a.includes("-v") || a.includes("-V")),
  find: findOk,
  systemctl: opts(
    {
      flags: "alq",
      valued: "tpno",
      long: ["--no-pager", "--all", "--full", "--no-legend", "--plain", "--value", "--user", "--system", "--quiet", "--failed", "--recursive", "--reverse", "--after", "--before"],
      longValued: ["--type", "--state", "--property", "--lines", "--output"],
    },
    (p) => SYSTEMCTL_READ.has(p[0] ?? ""),
  ),
  journalctl: opts({
    flags: "rxeaqkmlb",
    valued: "unptSUgo",
    long: ["--no-pager", "--reverse", "--catalog", "--all", "--quiet", "--dmesg", "--merge", "--full", "--utc", "--no-hostname", "--list-boots", "--disk-usage", "--boot", "--no-full", "--pager-end"],
    longValued: ["--unit", "--lines", "--priority", "--identifier", "--since", "--until", "--grep", "--output", "--user-unit", "--facility"],
  }),
  sshd: opts({ flags: "Tt", valued: "Cf" }, (p, a) => p.length === 0 && (a.includes("-T") || a.includes("-t"))),
  nft: opts({ flags: "ansjtNy" }, nftListOk),
  iptables: opts({ flags: "LSnvx", valued: "t", long: ["--line-numbers", "--list", "--list-rules", "--numeric", "--verbose", "--exact"], longValued: ["--table"] }, (p, a) => p.length <= 1 && (has(a, "L", "S") || a.includes("--list") || a.includes("--list-rules"))),
  "iptables-save": opts({ flags: "c", valued: "t", long: ["--counters"], longValued: ["--table"] }, (p) => p.length === 0),
  ufw: opts({}, (p) => (p[0] === "status" && p.length <= 2 && (!p[1] || p[1] === "verbose" || p[1] === "numbered")) || (p[0] === "show" && p.length === 2)),
  sysctl: opts({ flags: "anNebq", valued: "r", long: ["--all", "--values", "--names", "--ignore", "--binary", "--quiet"], longValued: ["--pattern"] }, (p) => p.every((x) => !x.includes("="))),
  ip: ipOk,
  docker: dockerOk,
  apt: opts({ flags: "a", long: ["--installed", "--upgradable", "--all-versions", "--manual-installed"] }, (p) => p[0] === "list"),
  "apt-cache": opts({}, (p) => ["policy", "show", "madison", "depends", "rdepends", "showpkg"].includes(p[0] ?? "")),
  dpkg: opts({ flags: "lLsS", long: ["--list", "--listfiles", "--status", "--search"] }, (_p, a) => a.some((x) => x.startsWith("-"))),
  "dpkg-query": opts({ flags: "lLsSW", valued: "f", long: ["--list", "--listfiles", "--status", "--search", "--show"], longValued: ["--showformat"] }, (_p, a) => a.some((x) => x.startsWith("-"))),
  sudo: opts({ flags: "l", valued: "U" }, (p, a) => p.length === 0 && has(a, "l")),
  crontab: opts({ flags: "l", valued: "u" }, (p, a) => p.length === 0 && a.includes("-l")),
  loginctl: opts({ long: ["--no-pager", "--no-legend"] }, (p) => ["list-sessions", "list-users", "show-session", "show-user", "session-status", "user-status"].includes(p[0] ?? "")),
  "fail2ban-client": opts({}, (p) => p[0] === "status" || p[0] === "get" || p[0] === "banned"),
  passwd: opts({ flags: "Sa" }, (_p, a) => has(a, "S")),
  chage: opts({ flags: "l" }, (p, a) => p.length === 1 && a.includes("-l")),
};
READS.ip6tables = READS.iptables!;
READS["ip6tables-save"] = READS["iptables-save"]!;

/** Reads that stay reads with sudo:true (root). Everything else run as root counts as a change. */
const ROOT_READS = new Set([
  "cat", "ls", "stat", "head", "tail", "grep", "egrep", "fgrep", "zgrep", "find", "wc", "du", "namei", "getfacl", "lsattr", "md5sum", "sha256sum",
  "sshd", "nft", "iptables", "ip6tables", "iptables-save", "ip6tables-save", "ufw", "systemctl", "journalctl", "ss", "lsof", "crontab", "docker",
  "sed", "sort", "uniq", "cut", "tr", "nl", "column", "jq", "sysctl", "ip",
]);

/** Command name of a word if it names a command plainly (bare or /usr/bin-style path), else null. */
function plainCommand(w: Word): string | null {
  if (w.dyn || w.glob || w.brace) return null;
  if (!w.text.includes("/")) return w.text;
  return BIN_PATH.test(w.text) ? baseName(w.text) : null;
}

/** Read-only by the allowlist? Conservative: anything not clearly a read counts as a change. */
export function isReadCommand(cmd: string, sudo = false): boolean {
  const { toks, bad } = lex(cmd);
  if (bad) return false;
  const segs: Array<{ words: Word[]; piped: boolean }> = [];
  let cur: Word[] = [];
  let piped = false;
  for (let k = 0; k < toks.length; k++) {
    const t = toks[k]!;
    if (t.t === "w") {
      if (t.dyn || t.brace || t.subs.length) return false;
      // A glob must be anchored (/… or ./…): otherwise a file named like an option (-delete, -o) could expand into one.
      if (t.glob && !t.text.startsWith("/") && !t.text.startsWith("./")) return false;
      // Device files (a watchdog arms on open); /dev/null is fine.
      if (/(^|=)\/dev\//.test(t.text) && !/(^|=)\/dev\/null$/.test(t.text)) return false;
      cur.push(t);
      continue;
    }
    const next = toks[k + 1];
    const target = next?.t === "w" && !next.dyn && !next.glob ? next.text : null;
    if ((t.op === ">" && t.fd === "2" && target === "/dev/null") || (t.op === ">&" && t.fd === "2" && target === "1")) {
      k++;
      continue;
    }
    if (!["|", "&&", "||", ";"].includes(t.op) || !cur.length) return false;
    segs.push({ words: cur, piped });
    piped = t.op === "|";
    cur = [];
  }
  if (!cur.length) return false;
  segs.push({ words: cur, piped });
  return segs.every(({ words, piped: p }) => {
    const name = plainCommand(words[0]!);
    if (!name || /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0]!.text)) return false;
    if (sudo && !ROOT_READS.has(name)) return false;
    const check = (p ? FILTERS : READS)[name];
    return !!check && Object.hasOwn(p ? FILTERS : READS, name) && check(words.slice(1).map((w) => w.text));
  });
}

// ---- denylist ----

const NET = new Set([
  "curl", "wget", "nc", "ncat", "netcat", "socat", "telnet", "ssh", "scp", "sftp", "rsync", "ftp", "tftp", "lftp", "aria2c", "axel", "xh", "http", "https", "httpie",
  "dig", "nslookup", "host", "drill", "delv", "kdig", "whois", "ping", "ping6", "arping", "ssh-keyscan", "ssh-copy-id", "autossh", "mosh", "nmap", "traceroute",
  "traceroute6", "tracepath", "mtr", "sshpass", "torsocks", "tsocks", "proxychains", "proxychains4", "links", "lynx", "w3m", "elinks", "rclone", "s3cmd", "aws",
  "gsutil", "gcloud", "az", "iperf", "iperf3", "nsupdate", "smbclient", "machinectl", "ftpput", "ftpget",
]);
/** Run other commands later or interactively (schedulers, editors and pagers with shell escapes). */
const RUNNERS = new Set(["at", "batch", "systemd-run", "vim", "vi", "nvim", "view", "vimdiff", "ex", "rvim", "less", "more", "most", "man", "emacs", "nano", "ed", "red", "pg"]);
const crontabOk = (a: string[]) => {
  for (let k = 0; k < a.length; k++) {
    if (a[k] === "-l" || a[k] === "-r") continue;
    if (a[k] === "-u" && a[k + 1] && !a[k + 1]!.startsWith("-")) {
      k++;
      continue;
    }
    return false;
  }
  return true;
};
/** sed scripts with the e command (GNU: `1eid` runs id) or the e flag of s (runs the pattern space as a command). */
const SED_EXEC = /(^|[;\n{}])\s*(\d+|\$|\/(?:[^/\\]|\\.)*\/)?\s*(,\s*(\d+|\$|\/(?:[^/\\]|\\.)*\/))?\s*!?\s*e|s(.)(?:(?!\5)[^\\]|\\.)*\5(?:(?!\5)[^\\]|\\.)*\5[a-zA-Z0-9]*e/;
/** Blocked wherever they appear as a word (not only in command position: unknown wrappers, xargs -I, heredocs…). */
const NET_ANYWHERE = new Set(["curl", "wget", "nc", "ncat", "netcat", "socat", "telnet", "scp", "sftp", "rsync", "ssh-keyscan", "nslookup", "dig", "nmap", "sshpass", "torsocks", "proxychains", "proxychains4", "aria2c", "lftp"]);
const SHELLS = new Set(["sh", "bash", "dash", "zsh", "ksh", "mksh", "pdksh", "fish", "csh", "tcsh", "ash", "yash", "posh", "rbash"]);
const INTERPRETER = /^(python[0-9.]*|pypy[0-9.]*|perl[0-9.]*|ruby[0-9.]*|irb|node|nodejs|php[0-9.]*|lua[0-9.]*|luajit|deno|bun|tclsh[0-9.]*|wish|expect|Rscript|julia|pwsh|groovy|jshell)$/;
const BAD_ASSIGN = /^(LD_PRELOAD|LD_LIBRARY_PATH|LD_AUDIT|BASH_ENV|ENV|DOCKER_HOST|DOCKER_CONTEXT|DOCKER_CONFIG|GIT_SSH|GIT_SSH_COMMAND|GIT_PROXY_COMMAND|SYSTEMD_HOST|PROMPT_COMMAND)=/;
const KEYWORDS = new Set(["if", "then", "else", "elif", "do", "while", "until", "!", "{", "(", "time", "fi", "done", "esac", "}"]);
const GIT_REMOTE = new Set(["fetch", "pull", "push", "clone", "ls-remote", "remote", "submodule", "archive", "send-email", "request-pull", "svn", "p4", "daemon", "http-backend", "upload-pack", "receive-pack", "-c", "--config-env"]);
const REMOTE_HOST_OPT = /^(-H|-M|--host|--machine)(=|$)|^-[A-Za-z]*[HM]/;

interface Wrap {
  valued: string[];
  /** Positional words before the wrapped command (timeout's duration, chroot's root…). */
  positional?: number;
  /** Options whose value is a shell command string. */
  script?: string[];
  /** The remaining words are joined and run by a shell (watch). */
  joined?: boolean;
}
const WRAPPERS: Record<string, Wrap> = {
  sudo: { valued: ["-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T", "--user", "--group", "--close-from", "--chdir", "--host", "--prompt", "--role", "--type", "--other-user", "--command-timeout"] },
  doas: { valued: ["-u", "-C"] },
  env: { valued: ["-u", "-C", "--unset", "--chdir"], script: ["-S", "--split-string"] },
  nohup: { valued: [] },
  setsid: { valued: [] },
  exec: { valued: ["-a"] },
  command: { valued: [] },
  builtin: { valued: [] },
  time: { valued: ["-f", "-o", "--format", "--output"] },
  nice: { valued: ["-n", "--adjustment"] },
  ionice: { valued: ["-c", "-n", "-t", "--class", "--classdata"] },
  timeout: { valued: ["-s", "-k", "--signal", "--kill-after"], positional: 1 },
  stdbuf: { valued: ["-i", "-o", "-e", "--input", "--output", "--error"] },
  xargs: { valued: ["-a", "-d", "-E", "-e", "-I", "-i", "-L", "-l", "-n", "-P", "-s", "--arg-file", "--delimiter", "--eof", "--replace", "--max-lines", "--max-args", "--max-procs", "--max-chars", "--process-slot-var"] },
  watch: { valued: ["-n", "--interval", "-q", "--equexit"], joined: true },
  flock: { valued: ["-w", "-E", "--timeout", "--conflict-exit-code"], positional: 1, script: ["-c", "--command"] },
  su: { valued: ["-s", "-g", "-G", "--shell", "--group", "--supp-group", "-w", "--whitelist-environment"], script: ["-c", "--command", "--session-command"] },
  runuser: { valued: ["-u", "--user", "-s", "-g", "-G", "--shell", "--group", "--supp-group", "-w"], script: ["-c", "--command", "--session-command"] },
  chroot: { valued: ["--userspec", "--groups"], positional: 1 },
  unshare: { valued: ["--map-user", "--map-group", "-S", "-G", "--setuid", "--setgid", "--wd", "-R", "--root"] },
  nsenter: { valued: ["-t", "--target", "-S", "-G", "--setuid", "--setgid", "-w", "--wd", "-r", "--root"] },
  taskset: { valued: [], positional: 1 },
  chrt: { valued: [], positional: 1 },
  prlimit: { valued: ["-p", "--pid"] },
  cgexec: { valued: ["-g"] },
  "systemd-inhibit": { valued: ["--what", "--who", "--why", "--mode"] },
  sg: { valued: [], positional: 1, script: ["-c"] },
  script: { valued: ["-O", "-I", "-T", "-B", "-E", "--log-out", "--log-in", "--log-io", "--log-timing", "--echo", "-m", "--logging-format"], script: ["-c", "--command"], positional: Infinity },
  "dbus-run-session": { valued: ["--config-file", "--dbus-daemon"] },
  faketime: { valued: ["-m", "-f"], positional: 1 },
  strace: { valued: ["-o", "-e", "-p", "-s", "-u", "-E"] },
  ltrace: { valued: ["-o", "-e", "-p", "-s", "-u"] },
  unbuffer: { valued: [] },
  firejail: { valued: [] },
  catchsegv: { valued: [] },
};

/** Why this list of tokens is refused, or null. */
function scanToks(toks: Tok[], depth: number): string | null {
  if (depth > 8) return "commands nested too deeply";
  for (const t of toks) {
    if (t.t !== "w") continue;
    for (const sub of t.subs) {
      const r = scanToks(sub, depth + 1);
      if (r) return r;
    }
    const b = baseName(t.text);
    if (NET_ANYWHERE.has(t.text) || (BIN_PATH.test(t.text) && NET.has(b))) return `network tools are not allowed (${b})`;
    if (/\/dev\/(tcp|udp)\/|\/inet[46]?\/(tcp|udp)/.test(t.text)) return "/dev/tcp, /dev/udp and /inet are not allowed";
  }
  // Simple commands: words between separators; redirection targets are files, not commands.
  let words: Word[] = [];
  const done = () => {
    const r = words.length ? checkSimple(words, depth) : null;
    words = [];
    return r;
  };
  for (let k = 0; k < toks.length; k++) {
    const t = toks[k]!;
    if (t.t === "w") words.push(t);
    else if (REDIRECTS.has(t.op)) k++;
    else {
      const r = done();
      if (r) return r;
    }
  }
  return done();
}

const scanText = (s: string, depth: number) => scanToks(lex(s).toks, depth + 1);

function checkSimple(all: Word[], depth: number): string | null {
  let i = 0;
  for (;;) {
    while (i < all.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(all[i]!.text) && !all[i]!.text.startsWith("=")) {
      if (BAD_ASSIGN.test(all[i]!.text)) return `setting ${all[i]!.text.split("=")[0]} is not allowed`;
      i++;
    }
    const w = all[i];
    if (!w) return null;
    if (KEYWORDS.has(w.text) && !w.dyn) {
      i++;
      continue;
    }
    if (["for", "case", "select", "function"].includes(w.text)) return null;
    if (w.dyn) return "command names built from variables or substitutions are not allowed";
    const name = baseName(w.text);
    const args = all.slice(i + 1);
    const a = args.map((x) => x.text);
    if (name === "busybox" || name === "toybox") {
      if (!args.length) return null;
      i++;
      continue;
    }
    if (NET.has(name)) return `network tools and nested connections are not allowed (${name})`;
    if (RUNNERS.has(name)) return `${name} is not allowed (it runs commands later or has shell escapes)`;
    if (name === "getent" && a.some((x) => /^(hosts|ahosts|ahostsv4|ahostsv6|networks|services)$/.test(x))) return "getent name lookups are not allowed";
    if (name === "resolvectl" && a.some((x) => ["query", "resolve", "service", "openpgp", "tlsa"].includes(x))) return "resolvectl lookups are not allowed";
    if (name === "crontab" && !crontabOk(a)) return "crontab only with -l, -r and -u user (no files, stdin or editor)";
    if (name === "tar" && a.some((x) => /^--(checkpoint-action|to-command|use-compress-program|info-script|new-volume-script|rsh-command)|^-[A-Za-z]*[IF]/.test(x))) return "tar options that run commands are not allowed";
    if (name === "sed" && a.some((x, k) => !x.startsWith("-") || a[k - 1] === "-e" || a[k - 1] === "--expression" || x.startsWith("--expression=")) && a.some((x) => SED_EXEC.test(x.replace(/^--expression=/, "")))) return "sed's e command is not allowed";
    if (name === "git" && a.includes("config") && a.some((x) => /^(core\.|alias\.)|\.(sshcommand|pager|editor|helper|command|hookspath|fsmonitor)$/i.test(x))) return "git config of commands and hooks is not allowed";
    if (name === "eval" || name === "source" || name === ".") return `${name} is not allowed`;
    if (INTERPRETER.test(name)) return `interpreters are not allowed (${name}); use plain commands`;
    if (SHELLS.has(name)) {
      // Only `sh -c 'commands'` (checked like a command line); scripts and stdin are refused.
      let k = 0;
      while (k < a.length && a[k]!.startsWith("-") && !/^-[A-Za-z]*c[A-Za-z]*$/.test(a[k]!)) k += a[k] === "-o" || a[k] === "+o" ? 2 : 1;
      if (k < a.length && /^-[A-Za-z]*c[A-Za-z]*$/.test(a[k]!)) return a[k + 1] === undefined ? null : scanText(a[k + 1]!, depth);
      return `running shell scripts or commands from stdin is not allowed (${name}); use sh -c '…'`;
    }
    if (name === "openssl" && a.some((x) => ["s_client", "s_server", "s_time", "ocsp"].includes(x))) return "openssl network commands are not allowed";
    if (name === "git" && a.some((x) => GIT_REMOTE.has(x))) return "git network operations are not allowed";
    if (name === "docker" || name === "podman") {
      const sub = a.findIndex((x) => !x.startsWith("-"));
      if (a.slice(0, sub < 0 ? a.length : sub).some((x) => /^(-H|-c|--host|--context|--config|--tls)/.test(x))) return "docker remote hosts and contexts are not allowed";
      if (a.some((x) => x === "run" || x === "exec")) return "docker run/exec is not allowed";
    }
    if (["systemctl", "journalctl", "loginctl", "busctl", "timedatectl", "hostnamectl", "localectl", "systemd-run", "coredumpctl"].includes(name) && a.some((x) => REMOTE_HOST_OPT.test(x))) {
      return `${name} on another host is not allowed`;
    }
    if (name === "find") {
      for (let k = 0; k < a.length; k++) {
        if (!/^-(exec|execdir|ok|okdir)$/.test(a[k]!)) continue;
        const end = a.findIndex((x, j) => j > k && (x === ";" || x === "+"));
        const r = checkSimple(args.slice(k + 1, end < 0 ? args.length : end), depth + 1);
        if (r) return r;
      }
      return null;
    }
    const wrap = Object.hasOwn(WRAPPERS, name) ? WRAPPERS[name]! : null;
    if (!wrap) return null;
    // Wrapper: skip its options (and their values) and positionals; check the wrapped command or script.
    let k = 0;
    while (k < a.length) {
      const x = a[k]!;
      if (x === "--") {
        k++;
        break;
      }
      if (!x.startsWith("-") || x === "-") break;
      if (x.startsWith("--")) {
        const eq = x.indexOf("=");
        const opt = eq > 0 ? x.slice(0, eq) : x;
        if (wrap.script?.includes(opt)) return scanText(eq > 0 ? x.slice(eq + 1) : (a[k + 1] ?? ""), depth);
        k += wrap.valued.includes(opt) && eq < 0 ? 2 : 1;
        continue;
      }
      // Short options, also combined (-qc CMD, -c CMD, -cCMD, -n5).
      let step = 1;
      for (let j = 1; j < x.length; j++) {
        const opt = `-${x[j]}`;
        const rest = x.slice(j + 1);
        if (wrap.script?.includes(opt)) return scanText(rest || (a[k + 1] ?? ""), depth);
        if (wrap.valued.includes(opt)) {
          if (!rest) step = 2;
          break;
        }
      }
      k += step;
    }
    if (name === "env") {
      for (; k < a.length && a[k]!.includes("="); k++) if (BAD_ASSIGN.test(a[k]!)) return `setting ${a[k]!.split("=")[0]} is not allowed`;
    }
    if (name === "sudo" && a.some((x) => /^-[A-Za-z]*[si]/.test(x) || x === "--shell" || x === "--login")) return scanText(a.slice(k).join(" "), depth);
    if (wrap.joined) return scanText(a.slice(k).join(" "), depth);
    if (wrap.positional === Infinity) return null;
    i += 1 + k + (wrap.positional ?? 0);
  }
}

/** Why the command is refused in every mode, or null. Best effort, NOT a sandbox (see the top of this file). */
export function blockedReason(cmd: string): string | null {
  if (/\/dev\/(tcp|udp)\/|\/inet[46]?\/(tcp|udp)/.test(cmd)) return "/dev/tcp, /dev/udp and /inet are not allowed";
  const { toks, bad } = lex(cmd);
  if (bad === "nested too deeply") return "commands nested too deeply";
  return scanToks(toks, 0);
}
