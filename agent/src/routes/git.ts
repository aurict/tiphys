// Git: status, diff, log, branches, stage, commit, push/pull, branch switching. The path must be within allowed roots.
// Runs with GIT_TERMINAL_PROMPT=0 so operations asking for credentials don't hang.
import { basename } from "node:path";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { run } from "../exec.ts";
import { AppError } from "../errors.ts";
import { allowedPath } from "../paths.ts";
import type { Ctx } from "../server.ts";

const env = { GIT_TERMINAL_PROMPT: "0", GIT_OPTIONAL_LOCKS: "0", GIT_PAGER: "cat" };
const MAX_DIFF = 512 * 1024;

async function git(dir: string, args: string[], opts: { timeoutMs?: number; allowFail?: boolean } = {}) {
  const res = await run("git", ["-C", dir, ...args], { env, timeoutMs: opts.timeoutMs ?? 20000, allowFail: true });
  if (res.code !== 0 && !opts.allowFail) {
    throw new AppError("agent.git.failed", 502, { args: args.find((a) => !a.startsWith("-")) ?? "", stderr: res.stderr.slice(0, 2000) });
  }
  return res;
}

async function repoRoot(ctx: Ctx, p: string): Promise<string> {
  const dir = await allowedPath(ctx.store.get(), p);
  const res = await git(dir, ["rev-parse", "--show-toplevel"], { allowFail: true });
  if (res.code !== 0) throw new AppError("agent.git.notRepo", 404, { path: p });
  return allowedPath(ctx.store.get(), res.stdout.trim());
}

export interface GitFile {
  path: string;
  origPath: string | null;
  index: string; // status in the staging area: M, A, D, R, C, U or "."
  worktree: string; // status in the working tree
  untracked: boolean;
  conflicted: boolean;
}

export function parseStatus(out: string) {
  const r = { branch: null as string | null, upstream: null as string | null, ahead: 0, behind: 0, head: null as string | null, files: [] as GitFile[] };
  for (const line of out.split("\n")) {
    if (!line) continue;
    if (line.startsWith("# branch.head ")) r.branch = line.slice(14) === "(detached)" ? null : line.slice(14);
    else if (line.startsWith("# branch.oid ")) r.head = line.slice(13) === "(initial)" ? null : line.slice(13);
    else if (line.startsWith("# branch.upstream ")) r.upstream = line.slice(18);
    else if (line.startsWith("# branch.ab ")) {
      const m = /\+(\d+) -(\d+)/.exec(line);
      if (m) [r.ahead, r.behind] = [Number(m[1]), Number(m[2])];
    } else if (line.startsWith("1 ")) {
      const f = line.split(" ");
      r.files.push({ path: f.slice(8).join(" "), origPath: null, index: f[1]![0]!, worktree: f[1]![1]!, untracked: false, conflicted: false });
    } else if (line.startsWith("2 ")) {
      const f = line.split(" ");
      const [path, orig] = f.slice(9).join(" ").split("\t");
      r.files.push({ path: path!, origPath: orig ?? null, index: f[1]![0]!, worktree: f[1]![1]!, untracked: false, conflicted: false });
    } else if (line.startsWith("u ")) {
      const f = line.split(" ");
      r.files.push({ path: f.slice(10).join(" "), origPath: null, index: "U", worktree: "U", untracked: false, conflicted: true });
    } else if (line.startsWith("? ")) {
      r.files.push({ path: line.slice(2), origPath: null, index: ".", worktree: "?", untracked: true, conflicted: false });
    }
  }
  return r;
}

export function parseLog(out: string) {
  return out
    .split("\x1e")
    .map((x) => x.trim())
    .filter(Boolean)
    .map((rec) => {
      const [hash, author, date, subject, refs] = rec.split("\x1f");
      return { hash: hash!, author: author ?? "", date: date ?? "", subject: subject ?? "", refs: (refs ?? "").trim() };
    });
}

const pathQ = z.object({ path: z.string().min(1) });
const filesBody = z.object({ path: z.string().min(1), files: z.array(z.string().min(1)).min(1).max(1000), stage: z.boolean() });
/** File path relative to the repo root (for selected lists such as the files a Claude session changed). */
const relFile = z.string().min(1).max(4096).refine((f) => !f.startsWith("/") && !f.split("/").includes(".."), { message: "depo içinde göreli yol olmalı" });
const commitBody = z
  .object({
    path: z.string().min(1),
    message: z.string().trim().min(1).max(10000),
    all: z.boolean().default(false),
    /** If given, only these files are staged and committed; other previously staged files are not included. */
    files: z.array(relFile).min(1).max(1000).optional(),
  })
  .refine((b) => !(b.all && b.files), { message: "all ve files birlikte kullanılamaz" });
/** So file lists aren't interpreted as wildcards/magic pathspecs (":/", "*"). */
const literal = "--literal-pathspecs";

/** git push/pull error output → readable error code. */
export function remoteErrorCode(op: string, stderr: string): string {
  if (/has no upstream branch|no upstream configured/i.test(stderr)) return "agent.git.noUpstream";
  if (/No configured push destination|does not appear to be a git repository|No such remote/i.test(stderr)) return "agent.git.noRemote";
  if (/Authentication failed|could not read (Username|Password)|terminal prompts disabled|Permission denied \(publickey|Host key verification failed|403/i.test(stderr)) return "agent.git.authFailed";
  if (/\[rejected\]|non-fast-forward|fetch first/i.test(stderr)) return "agent.git.pushRejected";
  return `agent.git.${op}Failed`;
}

async function currentBranch(root: string): Promise<string | null> {
  const r = await git(root, ["symbolic-ref", "--short", "-q", "HEAD"], { allowFail: true });
  return r.code === 0 ? r.stdout.trim() : null;
}
const branchName = z.string().regex(/^(?!-)[A-Za-z0-9._/-]{1,200}$/);

export function gitRoutes(app: FastifyInstance, ctx: Ctx) {
  app.get("/v1/git/status", async (req) => {
    const root = await repoRoot(ctx, pathQ.parse(req.query).path);
    const res = await git(root, ["status", "--porcelain=v2", "--branch", "--untracked-files=all"]);
    return { root, ...parseStatus(res.stdout) };
  });

  app.get("/v1/git/diff", async (req) => {
    // head: sum of staged + unstaged changes (relative to HEAD; session changes screen).
    const q = z
      .object({ path: z.string().min(1), file: z.string().optional(), staged: z.coerce.boolean().default(false), head: z.coerce.boolean().default(false), commit: z.string().regex(/^[0-9a-f]{4,64}$/).optional() })
      .parse(req.query);
    const root = await repoRoot(ctx, q.path);
    let args: string[];
    if (q.commit) args = ["show", "--format=", "--no-color", q.commit];
    else args = ["diff", "--no-color", ...(q.head ? ["HEAD"] : q.staged ? ["--cached"] : [])];
    if (q.file) args.push("--", q.file);
    let { stdout } = await git(root, args);
    // An untracked file has no diff; its content is shown as a "new file".
    if (!stdout && q.file && !q.staged && !q.commit) {
      const r = await git(root, ["diff", "--no-color", "--no-index", "--", "/dev/null", q.file], { allowFail: true });
      stdout = r.stdout;
    }
    const truncated = stdout.length > MAX_DIFF;
    return { diff: truncated ? stdout.slice(0, MAX_DIFF) : stdout, truncated };
  });

  app.get("/v1/git/log", async (req) => {
    const q = z.object({ path: z.string().min(1), limit: z.coerce.number().int().min(1).max(500).default(50) }).parse(req.query);
    const root = await repoRoot(ctx, q.path);
    const res = await git(root, ["log", `-n${q.limit}`, "--format=%H%x1f%an%x1f%aI%x1f%s%x1f%D%x1e"], { allowFail: true });
    return { commits: res.code === 0 ? parseLog(res.stdout) : [] };
  });

  app.get("/v1/git/branches", async (req) => {
    const root = await repoRoot(ctx, pathQ.parse(req.query).path);
    const res = await git(root, ["branch", "--all", "--format=%(HEAD)%1f%(refname)%1f%(refname:short)%1f%(upstream:short)%1f%(committerdate:iso-strict)"]);
    return {
      branches: res.stdout
        .split("\n")
        .filter(Boolean)
        .map((l) => {
          const [head, full, name, upstream, date] = l.split("\x1f");
          return { name: name!, current: head === "*", remote: full!.startsWith("refs/remotes/"), upstream: upstream || null, date: date || null };
        }),
    };
  });

  app.post("/v1/git/stage", async (req) => {
    const b = filesBody.parse(req.body);
    const root = await repoRoot(ctx, b.path);
    await git(root, b.stage ? ["add", "--", ...b.files] : ["restore", "--staged", "--", ...b.files]);
    return { ok: true };
  });

  app.post("/v1/git/discard", async (req) => {
    const confirm = z.object({ confirm: z.literal(true) }).safeParse(req.body);
    if (!confirm.success) throw new AppError("agent.git.confirmRequired", 400);
    const b = z
      .object({
        path: z.string().min(1),
        files: z.array(z.string().min(1)).min(1).max(1000),
        /** "index" (default): unstaged changes are discarded. "head": the file reverts to its HEAD state (including staged). */
        source: z.enum(["index", "head"]).default("index"),
        /** head: files not in HEAD (new) are deleted only if this is explicitly true. */
        deleteNew: z.boolean().default(false),
      })
      .parse(req.body);
    const root = await repoRoot(ctx, b.path);
    if (b.source === "index") {
      await git(root, ["checkout", "--", ...b.files]);
      return { ok: true };
    }
    const files = z.array(relFile).parse(b.files);
    const inHead = new Set(
      (await git(root, [literal, "ls-tree", "-r", "-z", "--name-only", "HEAD", "--", ...files], { allowFail: true })).stdout.split("\0").filter(Boolean),
    );
    const tracked = files.filter((f) => inHead.has(f));
    const fresh = files.filter((f) => !inHead.has(f));
    if (fresh.length && !b.deleteNew) throw new AppError("agent.git.newFilesNeedConfirm", 409, { files: fresh.slice(0, 50).join("\n") });
    if (tracked.length) await git(root, [literal, "restore", "--source=HEAD", "--staged", "--worktree", "--", ...tracked]);
    if (fresh.length) {
      // If staged, first remove it from the index, then delete it as an untracked file (.gitignored ones are untouched).
      await git(root, [literal, "rm", "--cached", "-q", "--ignore-unmatch", "--", ...fresh]);
      await git(root, [literal, "clean", "-f", "-q", "--", ...fresh]);
    }
    return { ok: true, restored: tracked, deleted: fresh };
  });

  app.post("/v1/git/commit", async (req) => {
    const b = commitBody.parse(req.body);
    const root = await repoRoot(ctx, b.path);
    if (b.all) await git(root, ["add", "--all"]);
    // Selected files: new and deleted ones are staged too; the commit contains only these paths (--only).
    if (b.files) await git(root, [literal, "add", "--all", "--", ...b.files]);
    const res = await git(root, b.files ? [literal, "commit", "-m", b.message, "--only", "--", ...b.files] : ["commit", "-m", b.message], { allowFail: true });
    if (res.code !== 0) {
      const nothing = /nothing (added )?to commit|no changes added/i.test(res.stdout + res.stderr);
      throw new AppError(nothing ? "agent.git.nothingToCommit" : "agent.git.failed", nothing ? 409 : 502, { stderr: (res.stderr || res.stdout).slice(0, 2000) });
    }
    const hash = (await git(root, ["rev-parse", "HEAD"])).stdout.trim();
    const count = (await git(root, ["diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "--root", "HEAD"], { allowFail: true })).stdout.split("\0").filter(Boolean).length;
    await ctx.notifier.events?.record(
      {
        key: "git.committed",
        params: { repo: basename(root), branch: (await currentBranch(root)) ?? "", hash: hash.slice(0, 7), files: count, subject: b.message.split("\n")[0]!.slice(0, 120) },
        device: req.device?.id,
      },
      (err) => req.log.warn({ err }, "olay yazılamadı"),
    );
    return { ok: true, hash };
  });

  for (const op of ["push", "pull", "fetch"] as const) {
    app.post(`/v1/git/${op}`, async (req) => {
      // setUpstream (push only): if the branch isn't on the remote, push to origin (else the first remote) and track it.
      const b = z.object({ path: z.string().min(1), setUpstream: z.boolean().default(false) }).parse(req.body);
      const root = await repoRoot(ctx, b.path);
      let args = op === "pull" ? ["pull", "--ff-only"] : op === "fetch" ? ["fetch", "--all", "--prune"] : ["push"];
      if (op === "push" && b.setUpstream) {
        const remotes = (await git(root, ["remote"])).stdout.split("\n").filter(Boolean);
        const remote = remotes.includes("origin") ? "origin" : remotes[0];
        if (!remote) throw new AppError("agent.git.noRemote", 409);
        args = ["push", "--set-upstream", remote, "HEAD"];
      }
      const res = await git(root, args, { timeoutMs: 120000, allowFail: true });
      if (res.code !== 0) {
        const code = remoteErrorCode(op, res.stderr);
        throw new AppError(code, code === "agent.git.noUpstream" || code === "agent.git.noRemote" ? 409 : 502, { stderr: res.stderr.slice(0, 2000), ...(code === "agent.git.noUpstream" ? { branch: (await currentBranch(root)) ?? "" } : {}) });
      }
      if (op === "push") {
        await ctx.notifier.events?.record({ key: "git.pushed", params: { repo: basename(root), branch: (await currentBranch(root)) ?? "" }, device: req.device?.id }, (err) =>
          req.log.warn({ err }, "olay yazılamadı"),
        );
      }
      return { ok: true, output: (res.stdout + res.stderr).slice(0, 4000) };
    });
  }

  app.post("/v1/git/checkout", async (req) => {
    const b = z.object({ path: z.string().min(1), branch: branchName, create: z.boolean().default(false) }).parse(req.body);
    const root = await repoRoot(ctx, b.path);
    await git(root, b.create ? ["switch", "-c", b.branch] : ["switch", b.branch]);
    return { ok: true };
  });
}
