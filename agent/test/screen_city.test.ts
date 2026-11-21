// Screen mode `city` topic (PLAN.md §20 W3): snapshot building (ls-files, line counts, binary/size skip, cap and
// folder-level truncation), the watcher set (directories from ls-files, ignore list, new directory pickup, teardown
// leaves zero watchers), patches and touches (create/edit/delete, per-file rate limit), path containment (no symlink
// followed, nothing outside the root), masking without code sharing, commit detection and the git refresh it drives.
// Real temp git repositories and real fs.watch; nothing outside the temp dirs is touched.
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, symlink, unlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { CityWatch, countLines, groupDepth, groupKey, insideRel, kindOf, maskPath, parseLsFiles, realCityIo, watchDirs, type CityIo } from "../src/screen/producers/city.ts";
import { GitTopic, realGitIo } from "../src/screen/producers/git.ts";
import type { Sock } from "../src/screen/source.ts";

const cleanups: Array<() => unknown> = [];
afterEach(async () => {
  for (const c of cleanups.splice(0).reverse()) await c();
});

const until = async (f: () => boolean, ms = 4000) => {
  const end = Date.now() + ms;
  while (!f()) {
    if (Date.now() > end) throw new Error("timed out");
    await new Promise((r) => setTimeout(r, 10));
  }
};
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

const git = (cwd: string, ...args: string[]) =>
  execFileSync("git", ["-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", ...args], { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });

/** A temp git repo with {path: content} committed (and `untracked` left out of the commit). */
async function repo(files: Record<string, string | Buffer>, untracked: Record<string, string> = {}) {
  const dir = await mkdtemp(join(tmpdir(), "tiphys-w3-"));
  cleanups.push(() => rm(dir, { recursive: true, force: true }));
  for (const [p, c] of Object.entries(files)) {
    await mkdir(join(dir, p, ".."), { recursive: true });
    await writeFile(join(dir, p), c);
  }
  git(dir, "init", "-q", "-b", "main");
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "first");
  for (const [p, c] of Object.entries(untracked)) {
    await mkdir(join(dir, p, ".."), { recursive: true });
    await writeFile(join(dir, p), c);
  }
  return dir;
}

/** Real io with a count of open watchers. */
function countingIo() {
  const open = new Set<string>();
  let opened = 0;
  const io: CityIo = {
    ...realCityIo,
    watch: (abs, fn, onError) => {
      const w = realCityIo.watch(abs, fn, onError);
      const id = `${abs}#${opened++}`;
      open.add(id);
      return { close: () => (open.delete(id), w.close()) };
    },
  };
  return { io, open };
}

type Msg = Record<string, unknown>;
function city(root: string, o: ConstructorParameters<typeof CityWatch>[3] = {}, io: CityIo = realCityIo) {
  const got: Msg[] = [];
  const w = new CityWatch(root, io, (d) => got.push(JSON.parse(d) as Msg), { settleMs: 30, maxWaitMs: 300, refsDebounceMs: 50, ...o });
  cleanups.push(() => w.stop());
  return { w, got, of: (t: string) => got.filter((m) => m.type === t) };
}

const lines = (n: number) => Array.from({ length: n }, (_, i) => `l${i}`).join("\n") + "\n";

describe("city: pure parts", () => {
  it("kinds, containment, ls-files parsing, watch dirs, folder grouping, masking", () => {
    expect(["a.ts", "b/c.dart", "README.md", "x.yaml", "s.css", "Makefile", ".gitignore", "p.py"].map(kindOf)).toEqual(["code", "dart", "docs", "config", "web", "other", "other", "code"]);
    expect(insideRel("a/b.ts")).toBe(true);
    for (const bad of ["", "/etc/passwd", "../x", "a/../../x", "a//b", "./a", "a\0b"]) expect(insideRel(bad)).toBe(false);
    // Untracked entries inside an ignored directory are dropped, tracked ones stay; duplicates once.
    expect(parseLsFiles("H src/a.ts\0? node_modules/x/i.js\0H build/keep.gradle\0? notes.md\0H src/a.ts\0? ../up\0")).toEqual(["src/a.ts", "build/keep.gradle", "notes.md"]);
    expect(watchDirs(["a/b/c.ts", "a/d.ts", "x.md", "node_modules/q/r.js", "p/build/z.ts"]).sort()).toEqual(["", "a", "a/b", "p"]);
    const paths = ["r.md", "a/1/x.ts", "a/1/y.ts", "a/2/z.ts", "b/w.ts"];
    expect(groupKey("a/1/x.ts", 1)).toBe("a");
    expect(groupKey("r.md", 1)).toBe("r.md");
    expect(groupDepth(paths, 3)).toBe(1); // depth 2 would make a/1, a/2, b, r.md = 4
    expect(groupDepth(paths, 10)).toBe(2);
    const k = Buffer.alloc(32, 7);
    expect(maskPath(k, "src/a.ts")).toMatch(/^[0-9a-f]{8}\/[0-9a-f]{8}$/);
    expect(maskPath(k, "src/a.ts").split("/")[0]).toBe(maskPath(k, "src/b.ts").split("/")[0]);
    expect(maskPath(k, "src/a.ts")).not.toContain("src");
  });

  it("line counting: newline rules, binary and size skip, no symlink or FIFO is read", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-w3-"));
    cleanups.push(() => rm(dir, { recursive: true, force: true }));
    await writeFile(join(dir, "a"), "x\ny\n");
    await writeFile(join(dir, "b"), "x\ny");
    await writeFile(join(dir, "e"), "");
    await writeFile(join(dir, "bin"), Buffer.from([1, 2, 0, 3, 10]));
    await writeFile(join(dir, "big"), "x\n".repeat(600));
    await writeFile(join(dir, "huge"), "y\n".repeat(100_000)); // > one 64 KB chunk
    await symlink(join(dir, "a"), join(dir, "link"));
    execFileSync("mkfifo", [join(dir, "fifo")]);
    expect(await countLines(join(dir, "a"), 1e6)).toBe(2);
    expect(await countLines(join(dir, "b"), 1e6)).toBe(2);
    expect(await countLines(join(dir, "e"), 1e6)).toBe(0);
    expect(await countLines(join(dir, "huge"), 1e6)).toBe(100_000);
    expect(await countLines(join(dir, "bin"), 1e6)).toBeNull();
    expect(await countLines(join(dir, "big"), 1000)).toBeNull();
    expect(await countLines(join(dir, "link"), 1e6)).toBeNull();
    expect(await countLines(join(dir, "fifo"), 1e6)).toBeNull();
    expect(await countLines(join(dir, "missing"), 1e6)).toBeNull();
  });
});

describe("city: snapshot", () => {
  it("tracked + untracked-not-ignored files with line counts; binary, too big and symlinks skipped; sent once", async () => {
    const outside = await mkdtemp(join(tmpdir(), "tiphys-w3-out-"));
    cleanups.push(() => rm(outside, { recursive: true, force: true }));
    await writeFile(join(outside, "secret.ts"), lines(9));
    const root = await repo(
      { "src/a.ts": lines(10), "src/deep/b.dart": lines(3), "README.md": lines(2), "img.png": Buffer.from([0x89, 0x50, 0, 1]), "big.txt": "z\n".repeat(2000), ".gitignore": "*.log\nout/\n" },
      { "notes.md": lines(4), "x.log": lines(5), "out/o.ts": lines(1), "node_modules/m/i.js": lines(1) },
    );
    await symlink(outside, join(root, "ext"));
    await symlink(join(outside, "secret.ts"), join(root, "src/s.ts"));
    git(root, "add", "ext", "src/s.ts");
    const { w, got } = city(root, { maxBytes: 3000 });
    await w.start();
    expect(got.length).toBe(1);
    const m = got[0]!;
    expect(m).toMatchObject({ type: "city", root: root.split("/").pop(), truncated: false, masked: false });
    const files = new Map((m.files as Array<[string, number, string]>).map((f) => [f[0], f]));
    expect([...files.keys()].sort()).toEqual([".gitignore", "README.md", "notes.md", "src/a.ts", "src/deep/b.dart"]);
    expect(files.get("src/a.ts")).toEqual(["src/a.ts", 10, "code"]);
    expect(files.get("src/deep/b.dart")).toEqual(["src/deep/b.dart", 3, "dart"]);
    // Nothing outside the root: the symlinked dir isn't watched, the symlinked file isn't read.
    expect(JSON.stringify(m)).not.toContain("secret");
    expect(w.watchedDirs.sort()).toEqual(["", "src", "src/deep"]);
    // A late subscriber gets the same snapshot.
    expect(JSON.parse(w.snapshot())).toEqual(m);
  });

  it("over the cap: folder-level city with estimated lines, truncated + total", async () => {
    const files: Record<string, string> = { "top.md": lines(1) };
    for (let i = 0; i < 6; i++) files[`a/x${i}/f.ts`] = lines(40);
    for (let i = 0; i < 3; i++) files[`b/g${i}.dart`] = lines(5);
    const root = await repo(files);
    const { w, got } = city(root, { maxFiles: 5, maxGroups: 4 });
    await w.start();
    const m = got[0]!;
    expect(m).toMatchObject({ type: "city", truncated: true, total: 10 });
    const entries = m.files as Array<[string, number, string]>;
    expect(entries.map((e) => e[0]).sort()).toEqual(["a", "b", "top.md"]);
    expect(entries.find((e) => e[0] === "b")![2]).toBe("dart");
    expect(entries.find((e) => e[0] === "a")![1]).toBeGreaterThan(6);
    // A change inside a folder touches the folder's building.
    await writeFile(join(root, "a/x3/f.ts"), lines(41));
    await until(() => got.some((x) => x.type === "touch"));
    expect(got.filter((x) => x.type === "touch")).toEqual([{ type: "touch", path: "a", kind: "edit", by: null }]);
  });

  it("not a repository: a none message", async () => {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-w3-"));
    cleanups.push(() => rm(dir, { recursive: true, force: true }));
    const { w, got } = city(dir);
    await w.start();
    expect(got).toEqual([{ type: "city", root: dir.split("/").pop(), none: "notRepo" }]);
    expect(w.watchCount).toBe(0);
  });
});

describe("city: activity", () => {
  it("edit / create / delete → touches + patches; new directories watched; ignored and scratch files silent; teardown leaves zero watchers", async () => {
    const root = await repo({ "src/a.ts": lines(10), "src/b.ts": lines(2), "docs/r.md": lines(1), ".gitignore": "*.log\n", "build/keep.txt": lines(1) });
    const { io, open } = countingIo();
    const { w, got, of } = city(root, {}, io);
    await w.start();
    // Root + src + docs dirs, the git dir and logs/; never build/.
    expect(w.watchedDirs.sort()).toEqual(["", "docs", "src"]);
    expect(open.size).toBe(5);

    await writeFile(join(root, "src/a.ts"), lines(12));
    await until(() => of("touch").length === 1);
    expect(of("touch")[0]).toEqual({ type: "touch", path: "src/a.ts", kind: "edit", by: null });
    expect(of("cityPatch")[0]).toEqual({ type: "cityPatch", upsert: [["src/a.ts", 12, "code"]], remove: [] });

    await mkdir(join(root, "src/new/deeper"), { recursive: true });
    await writeFile(join(root, "src/new/deeper/n.dart"), lines(7));
    await until(() => of("touch").some((t) => t.kind === "create"));
    expect(of("touch").find((t) => t.kind === "create")).toMatchObject({ path: "src/new/deeper/n.dart" });
    expect(w.watchedDirs).toEqual(expect.arrayContaining(["src/new", "src/new/deeper"]));
    // Later files in the new directory come from its own watcher.
    await writeFile(join(root, "src/new/deeper/m.ts"), lines(1));
    await until(() => of("touch").some((t) => t.path === "src/new/deeper/m.ts"));

    const before = got.length;
    await writeFile(join(root, "src/x.log"), "ignored\n");
    await writeFile(join(root, "src/.a.ts.swp"), "swap\n");
    await writeFile(join(root, "src/a.ts~"), "backup\n");
    await mkdir(join(root, "node_modules/q"), { recursive: true });
    await writeFile(join(root, "node_modules/q/i.js"), "x\n");
    await sleep(400);
    await w.idle();
    expect(got.length).toBe(before);

    await unlink(join(root, "docs/r.md"));
    await until(() => of("touch").some((t) => t.kind === "delete"));
    expect(of("touch").find((t) => t.kind === "delete")).toMatchObject({ path: "docs/r.md" });
    expect(of("cityPatch").at(-1)).toEqual({ type: "cityPatch", upsert: [], remove: ["docs/r.md"] });

    // A removed directory: its files go, its watchers close.
    await rm(join(root, "src/new"), { recursive: true });
    await until(() => of("cityPatch").some((p) => (p.remove as string[]).includes("src/new/deeper/m.ts")));
    await w.idle();
    expect(w.watchedDirs).not.toContain("src/new/deeper");
    const snap = JSON.parse(w.snapshot()) as Msg;
    expect((snap.files as Array<[string]>).map((f) => f[0]).sort()).toEqual([".gitignore", "build/keep.txt", "src/a.ts", "src/b.ts"]);

    w.stop();
    expect(open.size).toBe(0);
    expect(w.active).toBe(false);
  });

  it("at most one touch per file per second (the patch still follows the content)", async () => {
    const root = await repo({ "a.ts": lines(1), "b.ts": lines(1) });
    const { w, of } = city(root, { settleMs: 10, maxWaitMs: 50 });
    await w.start();
    await writeFile(join(root, "a.ts"), lines(2));
    await until(() => of("touch").length === 1);
    await sleep(120);
    await writeFile(join(root, "a.ts"), lines(3));
    await writeFile(join(root, "b.ts"), lines(3));
    await until(() => of("cityPatch").some((p) => JSON.stringify(p).includes('"a.ts",3')) && of("touch").length === 2);
    await sleep(150);
    expect(of("touch").map((t) => t.path)).toEqual(["a.ts", "b.ts"]);
    await sleep(1000);
    await writeFile(join(root, "a.ts"), lines(4));
    await until(() => of("touch").length === 3);
    expect(of("touch")[2]).toMatchObject({ path: "a.ts", kind: "edit" });
  });

  it("commit → commit event; moving HEAD back is not a commit", async () => {
    const root = await repo({ "a.ts": lines(1) });
    const { w, of } = city(root);
    await w.start();
    await writeFile(join(root, "a.ts"), lines(2));
    git(root, "commit", "-qam", "second commit subject");
    await until(() => of("commit").length === 1);
    const hash = git(root, "rev-parse", "HEAD").trim();
    expect(of("commit")[0]).toEqual({ type: "commit", hash7: hash.slice(0, 7), subject: "second commit subject" });
    git(root, "checkout", "-q", "HEAD~1");
    await sleep(400);
    expect(of("commit").length).toBe(1);
  });

  it("without code sharing every path is masked, the same way in the snapshot and the touches", async () => {
    const root = await repo({ "src/secret-name.ts": lines(3) });
    const { w, got, of } = city(root, { masked: true });
    await w.start();
    const m = got[0]!;
    expect(m.masked).toBe(true);
    expect(JSON.stringify(m)).not.toContain("secret");
    const [path, n, kind] = (m.files as Array<[string, number, string]>)[0]!;
    expect([n, kind]).toEqual([3, "code"]);
    await writeFile(join(root, "src/secret-name.ts"), lines(4));
    await until(() => of("touch").length === 1);
    expect(of("touch")[0]!.path).toBe(path);
    expect(JSON.stringify(got)).not.toContain("secret");
  });
});

describe("city + git topic", () => {
  const sock = (): Sock & { got: Msg[] } => {
    const got: Msg[] = [];
    return { readyState: 1, bufferedAmount: 0, got, send: (d) => got.push(JSON.parse(String(d)) as Msg), close() {} };
  };

  it("one city per root shared; worktree edits refresh git (no slow poll while the city runs); none messages; nothing left", async () => {
    const root = await repo({ "a.ts": lines(1), "lib/b.ts": lines(1) });
    const { io, open } = countingIo();
    let gitWatches = 0;
    const gio = { ...realGitIo, watch: (d: string, fn: (f: string | null) => void) => (gitWatches++, (() => { const w = realGitIo.watch(d, fn); return { close: () => (gitWatches--, w.close()) }; })()) };
    const topic = new GitTopic({
      io: gio,
      selector: () => ({ root: null, known: false, active: false, start() {}, stop() {} }),
      resolve: async (p) => (p === root ? { root } : { none: "notAllowed" }),
      watch: { debounceMs: 20, pokeMs: 50 },
      city: { io, share: () => true, watch: { settleMs: 20, maxWaitMs: 200 } },
    });
    const a = sock();
    const b = sock();
    const c = sock();
    topic.set(a, { project: root, ci: false }, ["git", "city"]);
    topic.set(b, { project: root, ci: false }, ["city"]);
    topic.set(c, { project: "/elsewhere", ci: false }, ["git", "city"]);
    await until(() => a.got.some((m) => m.type === "city") && b.got.some((m) => m.type === "city") && a.got.some((m) => m.type === "git"));
    expect(c.got).toEqual([{ type: "git", root: null, none: "notAllowed" }, { type: "city", root: null, none: "notAllowed" }]);
    expect(b.got.some((m) => m.type === "git")).toBe(false);
    expect(topic.roots).toEqual([root]);
    const gw = topic.watchOf(root)!;
    expect(gw.polling).toBe(false); // the city reports working tree changes
    const runs = gw.runs;
    await writeFile(join(root, "lib/b.ts"), lines(5));
    await until(() => gw.runs > runs && a.got.filter((m) => m.type === "git").length === 2);
    expect(a.got.filter((m) => m.type === "git")[1]).toMatchObject({ changed: 1 });
    expect(b.got.some((m) => m.type === "touch")).toBe(true);
    // City dropped by both: git goes back to its slow refresh; the city's watchers are closed.
    topic.set(a, { project: root, ci: false }, ["git"]);
    topic.set(b, null);
    expect(topic.cityOf(root)).toBeNull();
    expect(open.size).toBe(0);
    expect(gw.polling).toBe(true);
    // Wanting the city again: a fresh snapshot.
    const n = a.got.filter((m) => m.type === "city").length;
    topic.set(a, { project: root, ci: false }, ["git", "city"]);
    await until(() => a.got.filter((m) => m.type === "city").length === n + 1);
    topic.set(a, null);
    topic.set(c, null);
    expect(topic.active).toBe(false);
    expect(open.size).toBe(0);
    expect(gitWatches).toBe(0);
  });
});
