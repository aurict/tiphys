// Container vulnerability scanning with Trivy on the monitoring server (PLAN.md §15 S-2).
//
// Inventory: images of running containers from the hosts' latest security reports (this machine, SSH-audited hosts,
// other agents). Each image id is scanned once (shared images are deduplicated), in this order of sources:
//   remote: Trivy fetches `repo@sha256:<digest>` from the registry itself (no docker pull; pinned by digest, so a
//           same-named image elsewhere can never be picked up). Registry credentials only from security.scanners.
//   local:  an image of this machine that isn't in a registry → `docker save` to a private temp dir.
//   ssh:    an image of an SSH-audited host that isn't in a registry → `image-save` through the restricted audit key
//           (only at night, at most 2 per night, ≤ 3 GB, checked again on that host).
// Trivy runs in a pinned container (memory/CPU capped, read-only root, no Java DB download). Results keep only the
// fields needed for the app. State: security-vulns.json (0600, atomic).
import { mkdtemp, readFile, rename, rm, stat, writeFile, chmod } from "node:fs/promises";
import { createWriteStream } from "node:fs";
import { spawn } from "node:child_process";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";
import { expandHome } from "../config.ts";
import { knownHostsPath, spawnCapped, sshArgs, type Spawner } from "./collect.ts";
import type { Image, SecurityReport } from "./report.ts";

export const TRIVY_IMAGE = "aquasec/trivy@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb"; // 0.76.2
export const TRIVY_CACHE_VOLUME = "tiphys-trivy-cache";
const SCAN_TIMEOUT_MS = 15 * 60_000;
const SAVE_TIMEOUT_MS = 30 * 60_000;
export const MAX_SAVE_BYTES = 3 * 1024 ** 3;
export const RESCAN_MS = 7 * 24 * 3600_000;
const MAX_VULNS = 300;

const IMAGE_ID = /^sha256:[a-f0-9]{64}$/;
/** registry/repo@sha256:digest — no leading "-", no spaces, nothing Trivy could read as an option. */
const DIGEST_REF = /^(?![-/.])[a-z0-9][a-z0-9._/:-]{0,250}@sha256:[a-f0-9]{64}$/;

export type ScanSource = "remote" | "local" | "ssh";
export type ScanStatus = "ok" | "failed" | "needsCredentials" | "notAvailable" | "pending";

export interface Vuln {
  id: string;
  pkg: string;
  installed: string;
  fixed: string | null;
  severity: "CRITICAL" | "HIGH";
  title: string;
  target: string;
}

export interface ImageScan {
  imageId: string;
  refs: string[];
  hosts: { hostId: string; host: string; containers: string[] }[];
  status: ScanStatus;
  source: ScanSource | null;
  error: string | null;
  scannedAt: string | null;
  os: string | null;
  counts: { critical: number; high: number; fixable: number };
  vulns: Vuln[];
  truncated: boolean;
}

export interface InventoryHost {
  hostId: string;
  host: string;
  kind: "local" | "ssh" | "agent";
  arch: string;
  report: SecurityReport;
}

export interface InventoryItem {
  image: Image;
  hosts: { hostId: string; host: string; kind: InventoryHost["kind"]; arch: string; containers: string[] }[];
}

/** Images of running containers, deduplicated by image id. */
export function inventory(hosts: InventoryHost[]): Map<string, InventoryItem> {
  const out = new Map<string, InventoryItem>();
  for (const h of hosts) {
    const d = h.report.docker;
    if (!d) continue;
    for (const img of d.images) {
      if (!IMAGE_ID.test(img.id)) continue;
      const containers = d.containers.filter((c) => c.imageId === img.id).map((c) => c.name);
      const item = out.get(img.id) ?? { image: img, hosts: [] };
      if (!item.hosts.some((x) => x.hostId === h.hostId)) item.hosts.push({ hostId: h.hostId, host: h.host, kind: h.kind, arch: h.arch, containers });
      out.set(img.id, item);
    }
  }
  return out;
}

export function platformOf(arch: string): string {
  if (arch === "aarch64" || arch === "arm64") return "linux/arm64";
  if (arch === "x86_64" || arch === "amd64") return "linux/amd64";
  return "";
}

export function registryOf(ref: string): string {
  const first = ref.split("/")[0]!;
  return ref.includes("/") && (first.includes(".") || first.includes(":") || first === "localhost") ? first : "docker.io";
}

/** Public registries Trivy may contact; others only when credentials are configured for them (an audited host's report
 * must not make the monitoring server fetch from arbitrary addresses, e.g. a cloud metadata IP). */
export const PUBLIC_REGISTRIES = new Set(["docker.io", "ghcr.io", "gcr.io", "quay.io", "registry.k8s.io", "public.ecr.aws", "mcr.microsoft.com", "registry.gitlab.com", "lscr.io", "codeberg.org"]);

/** Digest references Trivy can fetch from a registry (allowed registries only). */
export function remoteRefs(img: Image, extraRegistries: string[] = []): string[] {
  return img.digests.filter((d) => {
    if (!DIGEST_REF.test(d)) return false;
    const reg = registryOf(d);
    return PUBLIC_REGISTRIES.has(reg) || extraRegistries.includes(reg);
  });
}

export function trivyArgs(o: { target: { ref: string } | { input: string }; platform: string; credentials: boolean; javaDb?: boolean }): string[] {
  const args = [
    "run",
    "--rm",
    "--memory",
    "2g",
    "--cpus",
    "2",
    "--read-only",
    "--security-opt",
    "no-new-privileges",
    "--tmpfs",
    "/tmp:size=4g",
    "-v",
    `${TRIVY_CACHE_VOLUME}:/cache`,
  ];
  if ("input" in o.target) args.push("-v", `${o.target.input}:/in/image.tar:ro`);
  // Credentials come from the docker client's environment (never argv).
  if (o.credentials) args.push("-e", "TRIVY_USERNAME", "-e", "TRIVY_PASSWORD");
  args.push(
    TRIVY_IMAGE,
    "image",
    "--cache-dir",
    "/cache",
    "--quiet",
    "--format",
    "json",
    "--scanners",
    "vuln",
    "--severity",
    "CRITICAL,HIGH",
    "--timeout",
    "14m",
  );
  // Without the Java DB (≈1 GB) Trivy can't analyze JARs at all (it fails on the first run), so they are skipped.
  if (!o.javaDb) args.push("--skip-java-db-update", "--skip-files", "**/*.jar", "--skip-files", "**/*.war", "--skip-files", "**/*.ear");
  if ("input" in o.target) args.push("--input", "/in/image.tar");
  else {
    if (o.platform) args.push("--platform", o.platform);
    args.push("--image-src", "remote", "--", o.target.ref);
  }
  return args;
}

const clip = (s: unknown, n: number) => String(s ?? "").replace(/[\u0000-\u001f\u007f]/g, " ").slice(0, n);

/** Trivy JSON → compact result (only CRITICAL/HIGH; values are package/version strings, never file content). */
export function parseTrivy(json: string): Pick<ImageScan, "os" | "counts" | "vulns" | "truncated"> {
  const data = JSON.parse(json) as {
    Metadata?: { OS?: { Family?: string; Name?: string } };
    Results?: Array<{ Target?: string; Vulnerabilities?: Array<Record<string, unknown>> }>;
  };
  const all: Vuln[] = [];
  const seen = new Set<string>();
  for (const r of data.Results ?? []) {
    for (const v of r.Vulnerabilities ?? []) {
      const sev = v.Severity;
      if (sev !== "CRITICAL" && sev !== "HIGH") continue;
      const id = clip(v.VulnerabilityID, 40);
      const pkg = clip(v.PkgName, 120);
      const k = `${id}|${pkg}|${clip(v.InstalledVersion, 80)}`;
      if (seen.has(k)) continue;
      seen.add(k);
      all.push({
        id,
        pkg,
        installed: clip(v.InstalledVersion, 80),
        fixed: v.FixedVersion ? clip(v.FixedVersion, 120) : null,
        severity: sev,
        title: clip(v.Title, 160),
        target: clip(r.Target, 160),
      });
    }
  }
  all.sort((a, b) => (a.severity === b.severity ? (a.fixed ? 0 : 1) - (b.fixed ? 0 : 1) || a.id.localeCompare(b.id) : a.severity === "CRITICAL" ? -1 : 1));
  const os = data.Metadata?.OS?.Family ? `${clip(data.Metadata.OS.Family, 40)} ${clip(data.Metadata.OS.Name, 40)}`.trim() : null;
  return {
    os,
    counts: { critical: all.filter((v) => v.severity === "CRITICAL").length, high: all.filter((v) => v.severity === "HIGH").length, fixable: all.filter((v) => v.fixed).length },
    vulns: all.slice(0, MAX_VULNS),
    truncated: all.length > MAX_VULNS,
  };
}

/** Registry errors from Trivy's stderr: credentials needed vs image not in that registry. */
export function classifyTrivyError(stderr: string): "needsCredentials" | "notFound" | "failed" {
  // \b keeps "401" inside a sha256 digest from counting.
  if (/unauthori[sz]ed|denied|authentication required|\b(401|403)\b/i.test(stderr)) return "needsCredentials";
  if (/manifest unknown|not found|MANIFEST_UNKNOWN|NAME_UNKNOWN|\b404\b/i.test(stderr)) return "notFound";
  return "failed";
}

/** Streams a command's stdout into a file (size-capped); used for docker save / image-save. */
export type Saver = (cmd: string, args: string[], file: string, o: { timeoutMs: number; maxBytes: number }) => Promise<{ code: number; stderr: string; bytes: number }>;

export const saveToFile: Saver = (cmd, args, file, o) =>
  new Promise((resolve, reject) => {
    const out = createWriteStream(file, { mode: 0o600 });
    const child = spawn(cmd, args, { stdio: ["ignore", "pipe", "pipe"] });
    let bytes = 0;
    let err = "";
    let failure: AppError | null = null;
    const kill = (e: AppError) => {
      failure ??= e;
      child.kill("SIGKILL");
    };
    const timer = setTimeout(() => kill(new AppError("agent.security.timeout", 504)), o.timeoutMs);
    child.stdout.on("data", (d: Buffer) => {
      bytes += d.length;
      if (bytes > o.maxBytes) kill(new AppError("agent.security.imageTooLarge", 502));
    });
    child.stdout.pipe(out);
    // A full disk must fail this save, not crash the agent (an unhandled stream error would).
    out.on("error", () => kill(new AppError("agent.security.saveFailed", 502)));
    child.stderr.on("data", (d: Buffer) => {
      if (err.length < 2000) err += d.toString("utf8");
    });
    child.on("error", (e) => {
      clearTimeout(timer);
      reject(e);
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      if (out.destroyed) return void (failure ? reject(failure) : reject(new AppError("agent.security.saveFailed", 502)));
      out.end(() => (failure ? reject(failure) : resolve({ code: code ?? -1, stderr: err, bytes })));
    });
  });

export interface VulnOpts {
  spawner?: Spawner;
  saver?: Saver;
  now?: () => number;
  /** Local hour window for heavy work [from, to). */
  nightHours?: [number, number];
}

interface State {
  images: Record<string, ImageScan>;
  /** Local date (YYYY-MM-DD) → image-save count, to keep SSH saves to 2 per night. */
  saves: Record<string, number>;
}

export class VulnScanner {
  readonly file: string;
  state: State = { images: {}, saves: {} };
  #ctx: Ctx;
  #o: VulnOpts;
  #busy: Promise<unknown> | null = null;
  #save: Promise<void> = Promise.resolve();
  #hosts: () => InventoryHost[];

  constructor(ctx: Ctx, hosts: () => InventoryHost[], o: VulnOpts = {}) {
    this.#ctx = ctx;
    this.#o = o;
    this.#hosts = hosts;
    this.file = join(dirname(ctx.store.path), "security-vulns.json");
  }

  #now() {
    return this.#o.now?.() ?? Date.now();
  }

  async load() {
    const raw = await readFile(this.file, "utf8").catch(() => null);
    if (!raw) return;
    try {
      const s = JSON.parse(raw) as State;
      this.state = { images: s.images ?? {}, saves: s.saves ?? {} };
    } catch {
      await rename(this.file, `${this.file}.corrupt-${Date.now()}`).catch(() => {});
    }
  }

  async #persist() {
    const data = JSON.stringify(this.state);
    this.#save = this.#save.catch(() => {}).then(async () => {
      const tmp = `${this.file}.${process.pid}.tmp`;
      await writeFile(tmp, data, { mode: 0o600 });
      await chmod(tmp, 0o600);
      await rename(tmp, this.file);
    });
    await this.#save.catch(() => {});
  }

  get running() {
    return this.#busy !== null;
  }

  /** Current inventory merged with stored results (images no longer running are dropped). */
  async refresh(): Promise<ImageScan[]> {
    const inv = inventory(this.#hosts());
    const next: Record<string, ImageScan> = {};
    for (const [id, item] of inv) {
      const prev = this.state.images[id];
      next[id] = {
        ...(prev ?? { status: "pending", source: null, error: null, scannedAt: null, os: null, counts: { critical: 0, high: 0, fixable: 0 }, vulns: [], truncated: false }),
        imageId: id,
        refs: item.image.tags.length ? item.image.tags : remoteRefs(item.image).map((r) => r.split("@")[0]!),
        hosts: item.hosts.map((h) => ({ hostId: h.hostId, host: h.host, containers: h.containers })),
      };
    }
    this.state.images = next;
    await this.#persist();
    return Object.values(next);
  }

  #isNight(): boolean {
    const [from, to] = this.#o.nightHours ?? this.#ctx.store.get().security.scanners.nightHours;
    const h = new Date(this.#now()).getHours();
    return from <= to ? h >= from && h < to : h >= from || h < to;
  }

  /** Due images: never scanned (or pending/failed) first, then older than a week. */
  due(): string[] {
    const now = this.#now();
    return Object.values(this.state.images)
      .filter((s) => s.status === "pending" || !s.scannedAt || now - Date.parse(s.scannedAt) >= RESCAN_MS || (s.status === "failed" && now - Date.parse(s.scannedAt) >= 24 * 3600_000))
      .sort((a, b) => (a.scannedAt ?? "").localeCompare(b.scannedAt ?? ""))
      .map((s) => s.imageId);
  }

  /** Night tick: scans due images one by one (stops at the end of the window). */
  async tick(force = false): Promise<void> {
    if (this.#busy) return;
    if (!force && !this.#isNight()) return;
    const run = (async () => {
      await this.refresh();
      for (const id of this.due()) {
        if (!force && !this.#isNight()) break;
        // Saving an image on an SSH-audited (production) host only happens at night, even for a manual run.
        await this.scanOne(id, { allowSave: this.#isNight() }).catch(() => {});
      }
    })();
    this.#busy = run;
    try {
      await run;
    } finally {
      this.#busy = null;
    }
  }

  #credentialsFor(ref: string): { username: string; token: string } | null {
    const reg = registryOf(ref);
    const c = this.#ctx.store.get().security.scanners.registryAuth.find((r) => r.registry === reg);
    return c ? { username: c.username, token: c.token } : null;
  }

  #trivy(args: string[], creds: { username: string; token: string } | null) {
    const sp = this.#o.spawner ?? spawnCapped;
    // Credentials go only into this docker client's environment (`-e NAME` forwards them), never into argv.
    const env = creds ? { TRIVY_USERNAME: creds.username, TRIVY_PASSWORD: creds.token } : undefined;
    return sp("docker", args, { timeoutMs: SCAN_TIMEOUT_MS, maxBytes: 64 * 1024 * 1024, ...(env ? { env } : {}) });
  }

  /** Manual single-image scan: refused while the batch runs (one Trivy at a time). */
  async scanManual(imageId: string): Promise<ImageScan> {
    if (this.#busy) throw new AppError("agent.security.scanBusy", 409);
    const p = this.scanOne(imageId);
    this.#busy = p;
    try {
      return await p;
    } finally {
      this.#busy = null;
    }
  }

  /** Scans one image now (manual or scheduled). */
  async scanOne(imageId: string, opts: { allowSave?: boolean } = {}): Promise<ImageScan> {
    if (!IMAGE_ID.test(imageId)) throw new AppError("agent.security.imageNotFound", 404);
    const s = this.state.images[imageId];
    if (!s) throw new AppError("agent.security.imageNotFound", 404);
    const item = inventory(this.#hosts()).get(imageId);
    if (!item) throw new AppError("agent.security.imageNotFound", 404);
    const platform = platformOf(item.hosts[0]?.arch ?? "");
    const prevCritical = s.scannedAt ? s.counts.critical : null;
    let outcome: { ok: true; json: string; source: ScanSource } | { ok: false; status: ScanStatus; error: string; source: ScanSource | null } = {
      ok: false,
      status: "notAvailable",
      error: "noSource",
      source: null,
    };

    // 1. Registry by digest.
    for (const ref of remoteRefs(item.image, this.#ctx.store.get().security.scanners.registryAuth.map((r) => r.registry))) {
      const creds = this.#credentialsFor(ref);
      const r = await this.#trivy(trivyArgs({ target: { ref }, platform, credentials: !!creds, javaDb: this.#ctx.store.get().security.scanners.javaDb }), creds);
      if (r.code === 0) {
        outcome = { ok: true, json: r.stdout, source: "remote" };
        break;
      }
      const kind = classifyTrivyError(r.stderr);
      outcome = kind === "needsCredentials" ? { ok: false, status: "needsCredentials", error: registryOf(ref), source: "remote" } : { ok: false, status: kind === "notFound" ? "notAvailable" : "failed", error: kind, source: "remote" };
    }

    // 2. Not in a registry (or no access): save the image from where it runs.
    if (!outcome.ok && outcome.status !== "failed") {
      const local = item.hosts.find((h) => h.kind === "local");
      const ssh = item.hosts.find((h) => h.kind === "ssh");
      if (local) outcome = await this.#scanSaved(imageId, "local", null);
      else if (ssh && !(opts.allowSave ?? this.#isNight())) outcome = { ok: false, status: "pending", error: "nightOnly", source: "ssh" };
      else if (ssh) {
        // One key per night, even when the window crosses midnight (22–06): the date 12 hours earlier.
        const day = new Date(this.#now() - 12 * 3600_000).toLocaleDateString("sv");
        if ((this.state.saves[day] ?? 0) >= 2) outcome = { ok: false, status: "pending", error: "saveLimit", source: "ssh" };
        else {
          this.state.saves = { [day]: (this.state.saves[day] ?? 0) + 1 };
          outcome = await this.#scanSaved(imageId, "ssh", ssh.hostId);
        }
      }
    }

    const nowIso = new Date(this.#now()).toISOString();
    const cur = this.state.images[imageId] ?? s;
    if (outcome.ok) {
      let parsed: ReturnType<typeof parseTrivy>;
      try {
        parsed = parseTrivy(outcome.json);
      } catch {
        Object.assign(cur, { status: "failed", error: "badOutput", source: outcome.source, scannedAt: nowIso });
        await this.#persist();
        return cur;
      }
      Object.assign(cur, { status: "ok", error: null, source: outcome.source, scannedAt: nowIso, ...parsed });
      if (parsed.counts.critical > 0 && (prevCritical === null || parsed.counts.critical > prevCritical)) {
        await this.#ctx.notifier.send({
          key: "security.vulns",
          params: {
            host: cur.hosts.map((h) => h.host).join(","),
            image: (cur.refs[0] ?? imageId.slice(7, 19)).slice(0, 120),
            critical: parsed.counts.critical,
            high: parsed.counts.high,
            agent: this.#ctx.store.get().name,
          },
          link: `tiphys://security/vulns/${imageId.slice(7)}`,
          priority: "default",
        });
      }
    } else {
      Object.assign(cur, { status: outcome.status, error: outcome.error, source: outcome.source, scannedAt: outcome.status === "pending" ? cur.scannedAt : nowIso });
    }
    await this.#persist();
    return cur;
  }

  async #scanSaved(imageId: string, kind: "local" | "ssh", hostId: string | null): Promise<{ ok: true; json: string; source: ScanSource } | { ok: false; status: ScanStatus; error: string; source: ScanSource }> {
    const dir = await mkdtemp(join(tmpdir(), "tiphys-trivy-"));
    const file = join(dir, "image.tar");
    try {
      const saver = this.#o.saver ?? saveToFile;
      let r: { code: number; stderr: string; bytes: number };
      try {
        if (kind === "local") r = await saver("docker", ["save", imageId], file, { timeoutMs: SAVE_TIMEOUT_MS, maxBytes: MAX_SAVE_BYTES });
        else {
          const h = this.#ctx.store.get().security.hosts.find((x) => x.id === hostId);
          if (!h || h.source.kind !== "ssh") return { ok: false, status: "notAvailable", error: "noSource", source: kind };
          const known = knownHostsPath(this.#ctx.store.path);
          if (!(await stat(known).catch(() => null))) return { ok: false, status: "failed", error: "knownHostsMissing", source: kind };
          const args = sshArgs({ ...h.source, keyPath: expandHome(h.source.keyPath) }, known, "report");
          // The forced command takes the whole request as one word list; replace the mode with the save request.
          args.splice(args.length - 1, 1, `image-save ${imageId}`);
          r = await saver("ssh", args, file, { timeoutMs: SAVE_TIMEOUT_MS, maxBytes: MAX_SAVE_BYTES });
        }
      } catch (e) {
        return { ok: false, status: "failed", error: e instanceof AppError ? e.code : "saveFailed", source: kind };
      }
      if (r.code !== 0 || r.bytes === 0) return { ok: false, status: "failed", error: r.code === 4 ? "imageTooLarge" : "saveFailed", source: kind };
      const t = await this.#trivy(trivyArgs({ target: { input: file }, platform: "", credentials: false, javaDb: this.#ctx.store.get().security.scanners.javaDb }), null);
      if (t.code !== 0) return { ok: false, status: "failed", error: "scanFailed", source: kind };
      return { ok: true, json: t.stdout, source: kind };
    } finally {
      await rm(dir, { recursive: true, force: true }).catch(() => {});
    }
  }

  list() {
    return Object.values(this.state.images)
      .map(({ vulns: _, ...rest }) => rest)
      .sort((a, b) => b.counts.critical - a.counts.critical || b.counts.high - a.counts.high || a.imageId.localeCompare(b.imageId));
  }

  get(imageId: string): ImageScan {
    const s = this.state.images[imageId];
    if (!s) throw new AppError("agent.security.imageNotFound", 404);
    return s;
  }
}
