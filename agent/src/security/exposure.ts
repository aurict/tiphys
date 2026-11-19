// Outside view (PLAN.md §15 S-5, "self-attack test"), run from the monitoring server, gently:
//   ip:     TCP connect to a fixed list of common ports (8 at a time, 3 s timeout) — what the internet can reach.
//           (A machine probing its own public address may not see its cloud firewall; prefer probing the other one.)
//   domain: TLS certificate expiry, http→https redirect, security headers, and a short list of leak paths (/.env,
//           /.git/config, …). A single-page app answers every path with its index page, so a path counts only if its
//           content looks like the leak (e.g. KEY=value lines for .env, "ref:" for .git/HEAD).
// Weekly at night (or on demand). New open ports / new leaking paths since the previous run → security.exposure.
import { connect as netConnect } from "node:net";
import { connect as tlsConnect } from "node:tls";
import { chmod, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { AppError } from "../errors.ts";
import type { Ctx } from "../server.ts";

export const DEFAULT_PORTS = [
  21, 22, 23, 25, 53, 80, 110, 111, 135, 139, 143, 389, 443, 445, 465, 587, 631, 993, 995, 1080, 1433, 1521, 1723, 2049, 2375, 2376, 3000, 3001, 3306,
  3389, 4000, 4242, 5000, 5432, 5601, 5672, 5900, 5984, 6379, 6443, 6767, 6769, 7443, 8000, 8008, 8080, 8081, 8088, 8090, 8095, 8097, 8443, 8888, 9000,
  9090, 9093, 9095, 9100, 9200, 9443, 11211, 15672, 27017, 61208,
];

/** path → test that the body is really that file (not an SPA index page). */
export const LEAK_PATHS: Array<[string, (body: string, type: string) => boolean]> = [
  ["/.env", (b, t) => !/html/i.test(t) && /^[A-Z][A-Z0-9_]{1,60}=/m.test(b)],
  ["/.git/HEAD", (b) => /^ref: refs\//.test(b)],
  ["/.git/config", (b) => /\[core\]/.test(b)],
  ["/.DS_Store", (b) => b.startsWith("\u0000\u0000\u0000\u0001Bud1")],
  ["/server-status", (b) => /Apache Server Status/i.test(b)],
  ["/phpinfo.php", (b) => /phpinfo\(\)|PHP Version/i.test(b)],
  ["/actuator/env", (b, t) => /json/i.test(t) && /"propertySources"/.test(b)],
  ["/config.json", (b, t) => /json/i.test(t) && /(secret|password|token|apiKey)/i.test(b)],
  ["/service-account-key.json", (b) => /"private_key"/.test(b)],
  ["/backup.zip", (b, t) => /zip|octet-stream/i.test(t) || b.startsWith("PK\u0003\u0004")],
  ["/wp-config.php.bak", (b) => /DB_PASSWORD/.test(b)],
  ["/.aws/credentials", (b) => /aws_secret_access_key/i.test(b)],
];

export interface ExposureFinding {
  id: string;
  rule: "exposure.openPort" | "exposure.leakPath" | "exposure.tlsExpiry" | "exposure.noHttps" | "exposure.noHsts" | "exposure.headers" | "exposure.unreachable";
  severity: "critical" | "high" | "medium" | "low";
  target: string;
  params: Record<string, string | number>;
}

export interface ExposureRun {
  at: string;
  targets: Array<{ id: string; kind: "ip" | "domain"; value: string; openPorts?: number[]; error?: string }>;
  findings: ExposureFinding[];
}

export type PortProbe = (host: string, port: number, timeoutMs: number) => Promise<boolean>;
export type CertProbe = (host: string) => Promise<{ validTo: string } | null>;
export type Fetch = typeof fetch;

export const tcpProbe: PortProbe = (host, port, timeoutMs) =>
  new Promise((resolve) => {
    const s = netConnect({ host, port });
    const done = (ok: boolean) => {
      s.destroy();
      resolve(ok);
    };
    s.setTimeout(timeoutMs, () => done(false));
    s.once("connect", () => done(true));
    s.once("error", () => done(false));
  });

export const certProbe: CertProbe = (host) =>
  new Promise((resolve) => {
    // Not verifying: an expired or wrong certificate must still be read and reported, not count as "unreachable".
    const s = tlsConnect({ host, port: 443, servername: host, timeout: 10_000, rejectUnauthorized: false }, () => {
      const c = s.getPeerCertificate();
      s.end();
      resolve(c?.valid_to ? { validTo: new Date(c.valid_to).toISOString() } : null);
    });
    s.once("error", () => resolve(null));
    s.once("timeout", () => (s.destroy(), resolve(null)));
  });

/** First `max` bytes of a body, then the rest is cancelled (a real /backup.zip must not be downloaded). */
async function readHead(r: Response, max: number): Promise<string> {
  if (!r.body) return "";
  const reader = r.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    while (size < max) {
      const { done, value } = await reader.read();
      if (done) break;
      chunks.push(value);
      size += value.byteLength;
    }
  } catch {
    // partial body is fine
  }
  await reader.cancel().catch(() => {});
  return Buffer.concat(chunks).toString("latin1").slice(0, max);
}

async function pool<T>(items: T[], n: number, fn: (x: T) => Promise<void>) {
  let i = 0;
  await Promise.all(
    Array.from({ length: Math.min(n, items.length) }, async () => {
      while (i < items.length) await fn(items[i++]!);
    }),
  );
}

const HOST_RE = /^(?=.{1,253}$)(?!-)[A-Za-z0-9-]{1,63}(\.(?!-)[A-Za-z0-9-]{1,63})*$|^\d{1,3}(\.\d{1,3}){3}$/;

export interface ExposureOpts {
  probe?: PortProbe;
  cert?: CertProbe;
  fetch?: Fetch;
  now?: () => number;
  /** Pause between HTTP requests to one domain (ms). */
  spacingMs?: number;
}

export class ExposureScanner {
  readonly file: string;
  runs: ExposureRun[] = [];
  #ctx: Ctx;
  #o: ExposureOpts;
  #busy = false;

  constructor(ctx: Ctx, o: ExposureOpts = {}) {
    this.#ctx = ctx;
    this.#o = o;
    this.file = join(dirname(ctx.store.path), "security-exposure.json");
  }

  get running() {
    return this.#busy;
  }

  async load() {
    const raw = await readFile(this.file, "utf8").catch(() => null);
    if (!raw) return;
    try {
      this.runs = (JSON.parse(raw) as { runs?: ExposureRun[] }).runs ?? [];
    } catch {
      await rename(this.file, `${this.file}.corrupt-${Date.now()}`).catch(() => {});
    }
  }

  async #persist() {
    const tmp = `${this.file}.${process.pid}.tmp`;
    await writeFile(tmp, JSON.stringify({ runs: this.runs.slice(0, 12) }), { mode: 0o600 });
    await chmod(tmp, 0o600);
    await rename(tmp, this.file);
  }

  async #domain(value: string, findings: ExposureFinding[]) {
    const f = this.#o.fetch ?? fetch;
    const wait = () => new Promise((r) => setTimeout(r, this.#o.spacingMs ?? 1000));
    const get = (url: string) => f(url, { redirect: "manual", signal: AbortSignal.timeout(15_000), headers: { "user-agent": "tiphys-exposure-check" } });
    const add = (x: Omit<ExposureFinding, "id" | "target">) => findings.push({ ...x, id: `${x.rule}:${value}:${Object.values(x.params).join(",")}`, target: value });

    const cert = await (this.#o.cert ?? certProbe)(value);
    if (!cert) add({ rule: "exposure.unreachable", severity: "medium", params: { what: "tls" } });
    else {
      const days = Math.floor((Date.parse(cert.validTo) - (this.#o.now?.() ?? Date.now())) / 86_400_000);
      if (days < 14) add({ rule: "exposure.tlsExpiry", severity: days < 3 ? "critical" : "high", params: { days } });
    }
    const plain = await get(`http://${value}/`).catch(() => null);
    await plain?.body?.cancel().catch(() => {});
    await wait();
    if (plain && plain.status >= 200 && plain.status < 300) add({ rule: "exposure.noHttps", severity: "medium", params: { status: plain.status } });
    const root = await get(`https://${value}/`).catch(() => null);
    if (!root) {
      add({ rule: "exposure.unreachable", severity: "medium", params: { what: "https" } });
      return;
    }
    const h = root.headers;
    // A redirect (e.g. www → apex) is judged at its destination, which is a target of its own.
    const redirect = root.status >= 300 && root.status < 400;
    if (redirect) await root.body?.cancel().catch(() => {});
    if (!redirect && !h.get("strict-transport-security")) add({ rule: "exposure.noHsts", severity: "low", params: {} });
    const missing = [
      ["x-content-type-options", h.get("x-content-type-options")],
      ["frame-ancestors/x-frame-options", h.get("x-frame-options") ?? (/(^|;)\s*frame-ancestors/i.test(h.get("content-security-policy") ?? "") ? "csp" : null)],
      ["referrer-policy", h.get("referrer-policy")],
    ]
      .filter(([, v]) => !v)
      .map(([k]) => k);
    if (missing.length && !redirect) add({ rule: "exposure.headers", severity: "low", params: { missing: missing.join(",") } });
    await root.body?.cancel().catch(() => {});
    for (const [path, looksLike] of LEAK_PATHS) {
      await wait();
      const r = await get(`https://${value}${path}`).catch(() => null);
      if (!r || r.status !== 200) {
        await r?.body?.cancel().catch(() => {});
        continue;
      }
      const type = r.headers.get("content-type") ?? "";
      const body = await readHead(r, 64 * 1024);
      if (looksLike(body, type)) add({ rule: "exposure.leakPath", severity: "critical", params: { path } });
    }
  }

  async run(): Promise<ExposureRun> {
    if (this.#busy) throw new AppError("agent.security.scanBusy", 409);
    this.#busy = true;
    try {
      const cfg = this.#ctx.store.get().security.exposure;
      const at = new Date(this.#o.now?.() ?? Date.now()).toISOString();
      const run: ExposureRun = { at, targets: [], findings: [] };
      for (const t of cfg.targets) {
        if (!HOST_RE.test(t.value)) continue;
        if (t.kind === "ip") {
          const open: number[] = [];
          const ports = [...new Set([...DEFAULT_PORTS, ...cfg.extraPorts])];
          await pool(ports, 8, async (p) => {
            if (await (this.#o.probe ?? tcpProbe)(t.value, p, 3000)) open.push(p);
          });
          open.sort((a, b) => a - b);
          run.targets.push({ id: t.id, kind: t.kind, value: t.value, openPorts: open });
          const expected = new Set(t.expectedPorts);
          for (const p of open) {
            if (!expected.has(p)) run.findings.push({ id: `exposure.openPort:${t.value}:${p}`, rule: "exposure.openPort", severity: "high", target: t.value, params: { port: p } });
          }
        } else {
          try {
            await this.#domain(t.value, run.findings);
            run.targets.push({ id: t.id, kind: t.kind, value: t.value });
          } catch {
            run.targets.push({ id: t.id, kind: t.kind, value: t.value, error: "failed" });
          }
        }
      }
      const prev = this.runs[0];
      this.runs.unshift(run);
      await this.#persist();
      {
        // First run: only critical findings are announced; later runs: anything new that is serious.
        const before = new Set(prev?.findings.map((f) => f.id) ?? []);
        const fresh = run.findings.filter(
          (f) =>
            !before.has(f.id) &&
            (prev ? f.rule === "exposure.openPort" || f.rule === "exposure.leakPath" || f.rule === "exposure.tlsExpiry" || f.severity === "critical" : f.severity === "critical" || f.rule === "exposure.tlsExpiry"),
        );
        if (fresh.length) {
          await this.#ctx.notifier.send({
            key: "security.exposure",
            params: { host: this.#ctx.store.get().name, agent: this.#ctx.store.get().name, count: fresh.length, targets: [...new Set(fresh.map((f) => f.target))].slice(0, 3).join(", ") },
            link: "tiphys://security/exposure",
            priority: "high",
          });
        }
      }
      return run;
    } finally {
      this.#busy = false;
    }
  }

  due(): boolean {
    const last = this.runs[0] ? Date.parse(this.runs[0].at) : 0;
    return (this.#o.now?.() ?? Date.now()) - last >= this.#ctx.store.get().security.exposure.intervalDays * 86_400_000 - 3600_000;
  }
}
