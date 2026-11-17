// Deploy history and rollback tags (PLAN.md §13.1, I-2). Every 5 minutes and on docker `start` events the agent
// snapshots its compose containers → {project, service, imageId, imageRef, createdAt} and appends changes to
// incidents/deploys.jsonl (0600, rotated at 1 MB to deploys.jsonl.1). When a service's image id changes, the previous
// image is tagged `tiphys-rollback/<project>-<service>-<hash>:prev` (one per service; <hash>: 8 hex of sha256 of
// project + NUL + service, so `a-b`/`c` and `a`/`b-c` never share a tag): `compose pull` / rebuilds leave the old
// image untagged, and `docker image prune` would delete it; a tagged image is never dangling, so it survives.
// Commands run without a shell.
import { spawn, type ChildProcess } from "node:child_process";
import { createHash } from "node:crypto";
import { appendFile, chmod, mkdir, readFile, rename, stat } from "node:fs/promises";
import { dirname } from "node:path";
import { createInterface } from "node:readline";
import { run as execRun } from "../exec.ts";

type Runner = typeof execRun;

export const SNAPSHOT_EVERY_MS = 5 * 60_000;
export const MAX_DEPLOY_BYTES = 1024 * 1024;
export const ROLLBACK_REPO_PREFIX = "tiphys-rollback/";
const START_DEBOUNCE_MS = 3000;
const IMAGE_ID_RE = /^sha256:[a-f0-9]{64}$/;
/** name[:tag] with an optional registry/path; digests (`@sha256:…`) can't be re-tagged, so they're not accepted. */
export const IMAGE_REF_RE = /^[a-z0-9][a-z0-9._\/:-]{0,254}$/i;

export interface ServiceImage {
  project: string;
  service: string;
  container: string;
  imageId: string;
  imageRef: string;
  /** Container creation time. */
  createdAt: string;
  running: boolean;
}

export interface DeployRecord {
  at: string;
  /** seen: first time the agent saw this service; changed: its image id changed. */
  kind: "seen" | "changed";
  project: string;
  service: string;
  container: string;
  imageId: string;
  imageRef: string;
  createdAt: string;
  prevImageId: string | null;
  prevImageRef: string | null;
  /** The rollback tag set on the previous image, or null (no previous image, or it was already gone). */
  rollbackTag: string | null;
}

/**
 * `tiphys-rollback/<project>-<service>-<hash>`: the readable part is lowercased, other characters become single dashes
 * (≤ 80 chars); the hash (8 hex of sha256("<project>\0<service>")) is always there, so distinct services never share a
 * repository even when their readable parts are equal.
 */
export function rollbackRepo(project: string, service: string): string {
  const clean = `${project}-${service}`.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 80).replace(/-+$/, "") || "x";
  return `${ROLLBACK_REPO_PREFIX}${clean}-${createHash("sha256").update(`${project}\u0000${service}`).digest("hex").slice(0, 8)}`;
}

export const rollbackTag = (project: string, service: string) => `${rollbackRepo(project, service)}:prev`;

const key = (project: string, service: string) => `${project}\u0000${service}`;

interface InspectJson {
  Id?: string;
  Name?: string;
  Created?: string;
  Image?: string;
  State?: { Running?: boolean; Status?: string };
  Config?: { Image?: string; Labels?: Record<string, string> };
}

/** Per compose service, its newest container (one-off `compose run` containers are skipped). */
export function servicesFromInspect(list: InspectJson[]): ServiceImage[] {
  const by = new Map<string, ServiceImage>();
  for (const c of list) {
    const l = c.Config?.Labels ?? {};
    const project = l["com.docker.compose.project"];
    const service = l["com.docker.compose.service"];
    if (!project || !service || /^true$/i.test(l["com.docker.compose.oneoff"] ?? "")) continue;
    if (!c.Image || !IMAGE_ID_RE.test(c.Image) || !c.Created) continue;
    const s: ServiceImage = {
      project,
      service,
      container: (c.Name ?? "").replace(/^\//, ""),
      imageId: c.Image,
      imageRef: c.Config?.Image ?? "",
      createdAt: c.Created,
      running: c.State?.Running === true,
    };
    const prev = by.get(key(project, service));
    if (!prev || s.createdAt > prev.createdAt) by.set(key(project, service), s);
  }
  return [...by.values()].sort((a, b) => key(a.project, a.service).localeCompare(key(b.project, b.service)));
}

/** Compose containers matching the `docker ps` filters, reduced to the newest container per service. */
export async function composeServices(run: Runner, filters: string[]): Promise<ServiceImage[]> {
  const ps = await run("docker", ["ps", "-a", "--no-trunc", ...filters.flatMap((f) => ["--filter", f]), "--format", "{{.ID}}"], { timeoutMs: 15_000 });
  const ids = ps.stdout.split("\n").map((s) => s.trim()).filter((s) => /^[A-Za-z0-9_.-]+$/.test(s));
  if (!ids.length) return [];
  // A container removed between ps and inspect makes inspect exit 1 but still print the others.
  const r = await run("docker", ["inspect", "--type", "container", ...ids], { allowFail: true, timeoutMs: 15_000 });
  try {
    const list = JSON.parse(r.stdout || "[]") as InspectJson[];
    return servicesFromInspect(Array.isArray(list) ? list : []);
  } catch {
    return [];
  }
}

/** The newest container of one compose service, or undefined. */
export async function serviceImage(run: Runner, project: string, service: string): Promise<ServiceImage | undefined> {
  return (await composeServices(run, [`label=com.docker.compose.project=${project}`, `label=com.docker.compose.service=${service}`]))[0];
}

/** `nginx` → `nginx:latest`, `docker.io/library/x:1` → `x:1` (how docker reads a reference without registry/tag). */
function normalRef(ref: string): string {
  let r = ref.replace(/^(?:docker\.io|index\.docker\.io)\//, "").replace(/^library\//, "");
  if (!r.includes("@") && !r.slice(r.lastIndexOf("/") + 1).includes(":")) r += ":latest";
  return r;
}

/** Containers (any, compose or not) configured with the image reference `ref`. */
export async function containersUsingRef(run: Runner, ref: string): Promise<Array<{ container: string; project: string | null; service: string | null }>> {
  const ps = await run("docker", ["ps", "-a", "--no-trunc", "--format", "{{.ID}}"], { timeoutMs: 15_000 });
  const ids = ps.stdout.split("\n").map((s) => s.trim()).filter((s) => /^[A-Za-z0-9_.-]+$/.test(s));
  if (!ids.length) return [];
  const r = await run("docker", ["inspect", "--type", "container", ...ids], { allowFail: true, timeoutMs: 15_000 });
  let list: InspectJson[];
  try {
    list = JSON.parse(r.stdout || "[]") as InspectJson[];
  } catch {
    return [];
  }
  const want = normalRef(ref);
  return (Array.isArray(list) ? list : [])
    .filter((c) => typeof c.Config?.Image === "string" && normalRef(c.Config.Image) === want)
    .map((c) => {
      const l = c.Config?.Labels ?? {};
      return { container: (c.Name ?? "").replace(/^\//, ""), project: l["com.docker.compose.project"] ?? null, service: l["com.docker.compose.service"] ?? null };
    });
}

/** `{id, created}` of an image (by id or reference), or null when it doesn't exist. */
export async function imageInfo(run: Runner, ref: string): Promise<{ id: string; created: string } | null> {
  const r = await run("docker", ["image", "inspect", "--format", "{{.Id}} {{.Created}}", ref], { allowFail: true, timeoutMs: 15_000 });
  const [id = "", created = ""] = r.stdout.trim().split(" ");
  return r.code === 0 && IMAGE_ID_RE.test(id) ? { id, created } : null;
}

export interface DeployTrackerOptions {
  /** deploys.jsonl path. */
  file: string;
  run?: Runner;
  now?: () => number;
  /** Only this compose project (the real test; never the user's stacks). */
  project?: string;
  log?: (msg: string, err?: unknown) => void;
}

export class DeployTracker {
  readonly file: string;
  #o: DeployTrackerOptions;
  #run: Runner;
  #now: () => number;
  #last = new Map<string, DeployRecord>();
  #chain: Promise<unknown> = Promise.resolve();
  #timer: NodeJS.Timeout | null = null;
  #debounce: NodeJS.Timeout | null = null;
  #child: ChildProcess | null = null;
  #retry: NodeJS.Timeout | null = null;
  #stopped = false;

  constructor(o: DeployTrackerOptions) {
    this.#o = o;
    this.file = o.file;
    this.#run = o.run ?? execRun;
    this.#now = o.now ?? Date.now;
  }

  /** Rebuilds the last known image of every service from the history files. */
  async load(): Promise<void> {
    await mkdir(dirname(this.file), { recursive: true, mode: 0o700 });
    for (const r of await this.#readAll()) this.#last.set(key(r.project, r.service), r);
  }

  /** Records, oldest first (the rotated file, then the current one). */
  async #readAll(): Promise<DeployRecord[]> {
    const out: DeployRecord[] = [];
    for (const f of [`${this.file}.1`, this.file]) {
      const text = await readFile(f, "utf8").catch(() => "");
      for (const l of text.split("\n")) {
        if (!l) continue;
        try {
          const r = JSON.parse(l) as DeployRecord;
          if (r && typeof r.project === "string" && typeof r.service === "string" && typeof r.imageId === "string") out.push(r);
        } catch {
          // a torn last line: skipped
        }
      }
    }
    return out;
  }

  /** Newest first. */
  async history(o: { project?: string; service?: string; since?: number; limit?: number } = {}): Promise<DeployRecord[]> {
    await this.#chain.catch(() => {});
    return (await this.#readAll())
      .reverse()
      .filter((r) => (!o.project || r.project === o.project) && (!o.service || r.service === o.service) && (o.since === undefined || Date.parse(r.at) >= o.since))
      .slice(0, o.limit ?? 100);
  }

  lastKnown(project: string, service: string): DeployRecord | undefined {
    return this.#last.get(key(project, service));
  }

  /** Current compose containers (newest per service). */
  current(): Promise<ServiceImage[]> {
    return composeServices(this.#run, this.#o.project ? [`label=com.docker.compose.project=${this.#o.project}`] : ["label=com.docker.compose.service"]);
  }

  /** Snapshots now (serialized with other snapshots); returns the appended records. */
  snapshot(): Promise<DeployRecord[]> {
    const p = this.#chain.catch(() => {}).then(() => this.#snapshot());
    this.#chain = p;
    return p;
  }

  async #snapshot(): Promise<DeployRecord[]> {
    const cur = await this.current();
    const at = new Date(this.#now()).toISOString();
    const runningIds = new Set(cur.filter((c) => c.running).map((c) => c.imageId));
    const out: DeployRecord[] = [];
    for (const c of cur) {
      const last = this.#last.get(key(c.project, c.service));
      if (last && last.imageId === c.imageId) continue;
      let tag: string | null = null;
      if (last) {
        const t = await this.#tagPrevious(c, last.imageId, runningIds);
        if (t === false) continue; // `docker tag` failed: not recorded, so the next snapshot tries again
        tag = t;
      }
      const r: DeployRecord = {
        at,
        kind: last ? "changed" : "seen",
        project: c.project,
        service: c.service,
        container: c.container,
        imageId: c.imageId,
        imageRef: c.imageRef,
        createdAt: c.createdAt,
        prevImageId: last?.imageId ?? null,
        prevImageRef: last?.imageRef ?? null,
        rollbackTag: tag,
      };
      out.push(r);
    }
    // Known only once written: after a failed append the next snapshot sees the change again.
    if (out.length) await this.#append(out);
    for (const r of out) this.#last.set(key(r.project, r.service), r);
    return out;
  }

  /**
   * Tags the previous image `…:prev` (moving the tag from an older image), then removes any other tag of the same
   * rollback repository, unless that image is used by a running container. Null when the previous image is gone,
   * false when `docker tag` failed.
   */
  async #tagPrevious(c: ServiceImage, prevId: string, runningIds: Set<string>): Promise<string | null | false> {
    if (!IMAGE_ID_RE.test(prevId)) return null;
    if (!(await imageInfo(this.#run, prevId))) return null;
    const repo = rollbackRepo(c.project, c.service);
    const tag = `${repo}:prev`;
    const r = await this.#run("docker", ["tag", prevId, tag], { allowFail: true, timeoutMs: 15_000 });
    if (r.code !== 0) {
      this.#o.log?.("geri alma etiketi konamadı", new Error(r.stderr.slice(0, 300)));
      return false;
    }
    const ls = await this.#run("docker", ["image", "ls", repo, "--no-trunc", "--format", "{{.Repository}}:{{.Tag}} {{.ID}}"], { allowFail: true, timeoutMs: 15_000 });
    for (const line of ls.stdout.split("\n")) {
      const [ref, id] = line.trim().split(" ");
      if (!ref || !id || ref === tag || !ref.startsWith(`${repo}:`) || runningIds.has(id)) continue;
      await this.#run("docker", ["image", "rm", "--no-prune", ref], { allowFail: true, timeoutMs: 15_000 });
    }
    return tag;
  }

  async #append(records: DeployRecord[]) {
    const size = await stat(this.file).then((s) => s.size, () => 0);
    if (size >= MAX_DEPLOY_BYTES) await rename(this.file, `${this.file}.1`);
    await appendFile(this.file, records.map((r) => JSON.stringify(r) + "\n").join(""), { mode: 0o600 });
    await chmod(this.file, 0o600);
  }

  /** Snapshots now, every 5 minutes, and a few seconds after each docker `start` event. */
  start() {
    const tick = () => void this.snapshot().catch((err) => this.#o.log?.("dağıtım anlık görüntüsü başarısız", err));
    tick();
    this.#timer = setInterval(tick, SNAPSHOT_EVERY_MS);
    this.#timer.unref();
    this.#watch(tick);
  }

  #watch(tick: () => void) {
    if (this.#stopped) return;
    const child = spawn("docker", ["events", "--format", "{{json .}}", "--filter", "type=container", "--filter", "event=start"], { stdio: ["ignore", "pipe", "ignore"] });
    this.#child = child;
    child.on("error", () => {}); // no docker: retried via close
    createInterface({ input: child.stdout! }).on("line", () => {
      if (this.#debounce) clearTimeout(this.#debounce);
      this.#debounce = setTimeout(tick, START_DEBOUNCE_MS);
      this.#debounce.unref();
    });
    child.on("close", () => {
      this.#child = null;
      if (this.#stopped) return;
      this.#retry = setTimeout(() => this.#watch(tick), 60_000);
      this.#retry.unref();
    });
  }

  async stop() {
    this.#stopped = true;
    for (const t of [this.#timer, this.#debounce, this.#retry]) if (t) clearTimeout(t);
    this.#child?.kill();
    await this.#chain.catch(() => {});
  }
}
