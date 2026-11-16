// High quality mode (10.2 Phase B, "desktop" feature): Sunshine (game streaming server on the PC, NVENC) status,
// start/stop (systemctl --user) and sending the Moonlight pairing PIN to Sunshine's web API.
// - Status needs only "desktop"; start/stop/pair also need "control" + an open control session (control.ts).
// - Web API: https://127.0.0.1:47990, HTTP Basic (web UI username/password, stored in the agent settings).
//   No Origin/Referer is sent: in that case Sunshine's CSRF check accepts a non-browser client.
// - A self-signed certificate is accepted ONLY on a loopback address, and if Sunshine's own certificate file is
//   readable the fingerprint is pinned to it: on mismatch the connection is cut before headers (password) are sent.
// - The PIN and password are never written to logs/events; they don't go into error parameters.
import { X509Certificate } from "node:crypto";
import { readFile } from "node:fs/promises";
import https from "node:https";
import { homedir, hostname } from "node:os";
import { isAbsolute, join } from "node:path";
import tls from "node:tls";
import type { FastifyInstance } from "fastify";
import { z } from "zod";
import { parseSystemctlShow } from "../backups.ts";
import type { AgentConfig } from "../config.ts";
import { RateLimit, requireControl, type Exec } from "../control.ts";
import { AppError } from "../errors.ts";
import { run } from "../exec.ts";
import type { Ctx } from "../server.ts";
import { sessionBusEnv } from "./desktop.ts";
import { realHyprIo } from "./hypr.ts";

/** User unit installed by the .deb; `sunshine.service` is its alias (Alias=). */
export const SUNSHINE_UNITS = ["app-dev.lizardbyte.app.Sunshine.service", "sunshine.service"];
/** Sunshine's TCP ports: 47984 (HTTPS pairing), 47989 (HTTP), 47990 (web UI), 48010 (RTSP). */
export const SUNSHINE_PORTS = [47984, 47989, 47990, 48010];

export interface HttpResult {
  status: number;
  body: string;
  location?: string;
}

export interface SunshineHttp {
  (url: URL, opts: { method: "GET" | "POST"; auth: { username: string; password: string }; body?: unknown; timeoutMs: number }): Promise<HttpResult>;
}

/** Outside world (a fake is given in tests). */
export interface SunshineIo {
  exec: Exec;
  has(cmd: string): Promise<boolean>;
  /** null if the file doesn't exist. */
  readText(path: string): Promise<string | null>;
  http: SunshineHttp;
  /** Sunshine config folder (~/.config/sunshine). */
  configDir: string;
  /** Machine name (Sunshine's default sunshine_name). */
  hostName: string;
}

export type ApiState = "ok" | "noCredentials" | "unauthorized" | "setupRequired" | "unreachable" | "stopped";

export interface SunshineStatus {
  installed: boolean;
  version: string | null;
  unit: string | null;
  running: boolean;
  enabled: boolean;
  ports: number[];
  capture: string | null;
  encoder: string | null;
  credentials: boolean;
  api: ApiState;
  pairedClients: number | null;
  pendingPairings: number | null;
  /** Sunshine server id (sunshine_state.json `root.uniqueid`): the Moonlight shortcut targets this PC. */
  uniqueId: string | null;
  /** PC name shown in Moonlight (sunshine_name, otherwise the machine name). */
  hostName: string;
}

/** sunshine.conf: `key = value` lines, `#` comments. */
export function parseSunshineConf(text: string): Record<string, string> {
  const r: Record<string, string> = {};
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const i = line.indexOf("=");
    if (i > 0) r[line.slice(0, i).trim()] = line.slice(i + 1).trim();
  }
  return r;
}

/** Listening Sunshine ports in `ss -Hltn` output (local address is column 4). */
export function listeningPorts(ssOut: string): number[] {
  const found = new Set<number>();
  for (const line of ssOut.split("\n")) {
    const local = line.trim().split(/\s+/)[3];
    const port = Number(local?.slice(local.lastIndexOf(":") + 1));
    if (SUNSHINE_PORTS.includes(port)) found.add(port);
  }
  return SUNSHINE_PORTS.filter((p) => found.has(p));
}

export function isLoopbackHost(hostname: string): boolean {
  const h = hostname.replace(/^\[|\]$/g, "");
  return h === "localhost" || h === "::1" || /^127(\.\d{1,3}){3}$/.test(h);
}

/** Turns a Sunshine HTTP response into an agent error (body text only on 400, Sunshine's own "error" field). */
export function apiError(r: HttpResult): AppError {
  if (r.status === 401) return new AppError("agent.sunshine.unauthorized", 409);
  if (r.status === 403) return new AppError("agent.sunshine.forbidden", 409);
  if (r.status >= 300 && r.status < 400 && (r.location ?? "").includes("welcome")) return new AppError("agent.sunshine.setupRequired", 409);
  if (r.status === 400) {
    let msg = "";
    try {
      msg = String((JSON.parse(r.body) as { error?: unknown }).error ?? "");
    } catch {
      /* body is not JSON */
    }
    return new AppError("agent.sunshine.badRequest", 400, { message: msg.slice(0, 200) });
  }
  return new AppError("agent.sunshine.apiFailed", 502, { status: r.status });
}

function json(r: HttpResult): Record<string, unknown> | null {
  try {
    const j = JSON.parse(r.body) as unknown;
    return j && typeof j === "object" && !Array.isArray(j) ? (j as Record<string, unknown>) : null;
  } catch {
    return null;
  }
}

export class Sunshine {
  readonly io: SunshineIo;
  readonly config: () => AgentConfig["sunshine"];

  constructor(io: SunshineIo, config: () => AgentConfig["sunshine"]) {
    this.io = io;
    this.config = config;
  }

  #systemctl(args: string[], timeoutMs = 10000) {
    return this.io.exec("systemctl", ["--user", "--no-ask-password", ...args], { env: { ...process.env, ...sessionBusEnv() }, timeoutMs, allowFail: true });
  }

  /** Loaded unit (LoadState=loaded) and its state; null if absent. */
  async unit(): Promise<{ name: string; active: boolean; enabled: boolean } | null> {
    for (const name of SUNSHINE_UNITS) {
      const r = await this.#systemctl(["show", "-p", "LoadState,ActiveState,UnitFileState", "--", name]).catch(() => null);
      if (!r) return null; // no systemctl
      const p = parseSystemctlShow(r.stdout);
      if (p.LoadState !== "loaded") continue;
      return { name, active: p.ActiveState === "active" || p.ActiveState === "activating", enabled: p.UnitFileState === "enabled" };
    }
    return null;
  }

  async #conf(): Promise<Record<string, string>> {
    const t = await this.io.readText(join(this.io.configDir, "sunshine.conf"));
    return t ? parseSunshineConf(t) : {};
  }

  /** Web API request; returns the response unparsed (network error → unreachable/timeout). */
  async api(path: string, method: "GET" | "POST" = "GET", body?: unknown, timeoutMs = 5000): Promise<HttpResult> {
    const c = this.config();
    if (!c) throw new AppError("agent.sunshine.noCredentials", 409);
    return this.io.http(new URL(path, c.url), { method, auth: { username: c.username, password: c.password }, body, timeoutMs });
  }

  /** Only the server id is read from the state file (other fields in the file are left untouched). */
  async #uniqueId(conf: Record<string, string>): Promise<string | null> {
    const rel = conf.file_state || "sunshine_state.json";
    const t = await this.io.readText(isAbsolute(rel) ? rel : join(this.io.configDir, rel));
    try {
      const id = (JSON.parse(t ?? "") as { root?: { uniqueid?: unknown } }).root?.uniqueid;
      return typeof id === "string" && /^[0-9A-Fa-f-]{8,64}$/.test(id) ? id : null;
    } catch {
      return null;
    }
  }

  async status(): Promise<SunshineStatus> {
    const [unit, hasBin, conf, ss, dpkg] = await Promise.all([
      this.unit(),
      this.io.has("sunshine"),
      this.#conf(),
      this.io.exec("ss", ["-Hltn"], { timeoutMs: 5000, allowFail: true }).catch(() => null),
      this.io.exec("dpkg-query", ["-W", "-f=${Version}", "sunshine"], { timeoutMs: 5000, allowFail: true }).catch(() => null),
    ]);
    const running = unit?.active ?? false;
    const ports = ss && ss.code === 0 ? listeningPorts(ss.stdout) : [];
    let version = dpkg && dpkg.code === 0 && dpkg.stdout.trim() ? dpkg.stdout.trim() : null;
    const s: SunshineStatus = {
      installed: hasBin || unit !== null || version !== null,
      version,
      unit: unit?.name ?? null,
      running,
      enabled: unit?.enabled ?? false,
      ports,
      capture: conf.capture || null,
      encoder: conf.encoder || null,
      credentials: this.config() !== null,
      api: running || ports.includes(47990) ? "unreachable" : "stopped",
      pairedClients: null,
      pendingPairings: null,
      uniqueId: null,
      hostName: (conf.sunshine_name || this.io.hostName).slice(0, 64),
    };
    if (s.installed) s.uniqueId = await this.#uniqueId(conf);
    if (s.api === "stopped") return s;
    if (!s.credentials) return { ...s, api: "noCredentials" };
    try {
      const clients = await this.api("/api/clients/list");
      if (clients.status !== 200) {
        const e = apiError(clients).code;
        s.api = e === "agent.sunshine.unauthorized" ? "unauthorized" : e === "agent.sunshine.setupRequired" ? "setupRequired" : "unreachable";
        return s;
      }
      s.api = "ok";
      const certs = json(clients)?.named_certs;
      s.pairedClients = Array.isArray(certs) ? certs.length : null;
      const pin = await this.api("/api/pin").catch(() => null);
      const pairings = pin && pin.status === 200 ? json(pin)?.pairings : null;
      s.pendingPairings = Array.isArray(pairings) ? pairings.length : null;
      if (!version) {
        const cfg = await this.api("/api/config").catch(() => null);
        const v = cfg && cfg.status === 200 ? json(cfg)?.version : null;
        if (typeof v === "string" && v) s.version = version = v.slice(0, 64);
      }
    } catch {
      s.api = "unreachable";
    }
    return s;
  }

  async setRunning(on: boolean): Promise<SunshineStatus> {
    const unit = await this.unit();
    if (!unit) throw new AppError("agent.sunshine.notInstalled", 404);
    // The unit has ExecStartPre=/bin/sleep 5: starting takes a few seconds.
    const r = await this.#systemctl([on ? "start" : "stop", "--", unit.name], 30000);
    if (r.code !== 0) throw new AppError("agent.sunshine.unitFailed", 502, { stderr: r.stderr.slice(0, 300) });
    return this.status();
  }

  /**
   * Passes the PIN shown by Moonlight to Sunshine. Newer Sunshine (2026+) wants the pending pairing by `pairing_id`
   * (GET /api/pin): 409 if none is pending, the newest (last) if there are several; a wrong PIN still won't
   * pair. Older versions (no GET /api/pin) get `{pin, name}`. The POST waits until Moonlight finishes the
   * handshake; `status:false` = wrong PIN, cancelled or timed out.
   */
  async pair(pin: string, name: string): Promise<{ paired: true; client: string | null }> {
    const pending = await this.api("/api/pin");
    let body: Record<string, string>;
    let client: string | null = null;
    const pairings = pending.status === 200 ? json(pending)?.pairings : undefined;
    if (Array.isArray(pairings)) {
      const last = pairings.at(-1) as { id?: unknown; name?: unknown } | undefined;
      if (!last || typeof last.id !== "string") throw new AppError("agent.sunshine.noPendingPairing", 409);
      client = typeof last.name === "string" ? last.name.slice(0, 128) : null;
      body = { pairing_id: last.id, pin, name };
    } else if (pending.status === 200 || pending.status === 404) {
      body = { pin, name };
    } else {
      throw apiError(pending);
    }
    const r = await this.api("/api/pin", "POST", body, 40000);
    if (r.status !== 200) throw apiError(r);
    if (json(r)?.status !== true) throw new AppError("agent.sunshine.pairFailed", 400);
    return { paired: true, client };
  }
}

// ---- real HTTP (TLS rule) ----

/** SHA-256 fingerprint of Sunshine's web cert (sunshine.conf `cert`, else credentials/cacert.pem); null if unreadable. */
async function pinnedFingerprint(configDir: string): Promise<string | null> {
  try {
    const conf = parseSunshineConf((await readFile(join(configDir, "sunshine.conf"), "utf8").catch(() => "")) || "");
    const rel = conf.cert || "credentials/cacert.pem";
    const pem = await readFile(isAbsolute(rel) ? rel : join(configDir, rel), "utf8");
    return new X509Certificate(pem).fingerprint256;
  } catch {
    return null;
  }
}

/**
 * Normal certificate verification outside loopback. On loopback a self-signed certificate is accepted; if the
 * certificate file is readable the server's certificate must match it. Checked before the request (Authorization) is sent.
 */
export function tlsHttp(configDir: string, fingerprint: (dir: string) => Promise<string | null> = pinnedFingerprint): SunshineHttp {
  return async (url, opts) => {
    const loop = isLoopbackHost(url.hostname);
    const pin = loop ? await fingerprint(configDir) : null;
    const payload = opts.body === undefined ? undefined : Buffer.from(JSON.stringify(opts.body));
    const headers: Record<string, string> = {
      authorization: `Basic ${Buffer.from(`${opts.auth.username}:${opts.auth.password}`).toString("base64")}`,
      accept: "application/json",
      ...(payload ? { "content-type": "application/json", "content-length": String(payload.length) } : {}),
    };
    return new Promise<HttpResult>((resolve, reject) => {
      let pending: tls.TLSSocket | null = null;
      const host = url.hostname.replace(/^\[|\]$/g, "");
      const port = Number(url.port || 443);
      const req = https.request(
        {
          host,
          port,
          path: url.pathname + url.search,
          method: opts.method,
          headers,
          timeout: opts.timeoutMs,
          ...(loop
            ? {
                createConnection: (_o: unknown, cb: (err: Error | null, s?: tls.TLSSocket) => void) => {
                  const s = tls.connect({ host, port, rejectUnauthorized: false });
                  pending = s;
                  s.once("error", (e) => cb(e));
                  s.once("secureConnect", () => {
                    if (pin && s.getPeerCertificate().fingerprint256 !== pin) {
                      s.destroy();
                      cb(new AppError("agent.sunshine.certMismatch", 502));
                    } else cb(null, s);
                  });
                  return undefined;
                },
              }
            : {}),
        } as https.RequestOptions,
        (res) => {
          const chunks: Buffer[] = [];
          let size = 0;
          res.on("data", (b: Buffer) => {
            size += b.length;
            if (size <= 1024 * 1024) chunks.push(b);
          });
          res.on("end", () => resolve({ status: res.statusCode ?? 0, body: Buffer.concat(chunks).toString("utf8"), location: res.headers.location }));
          res.on("error", (e) => reject(e instanceof AppError ? e : new AppError("agent.sunshine.unreachable", 502)));
          res.on("aborted", () => reject(new AppError("agent.sunshine.timeout", 504)));
        },
      );
      req.on("timeout", () => req.destroy(new AppError("agent.sunshine.timeout", 504)));
      // Overall time limit: the request fails even if the TLS handshake never ends (no socket timeout on custom connections).
      const total = setTimeout(() => {
        const e = new AppError("agent.sunshine.timeout", 504);
        pending?.destroy();
        req.destroy(e);
        reject(e);
      }, opts.timeoutMs + 1000);
      req.on("close", () => clearTimeout(total));
      req.on("error", (e) => reject(e instanceof AppError ? e : new AppError("agent.sunshine.unreachable", 502, { code: (e as NodeJS.ErrnoException).code ?? null })));
      req.end(payload);
    });
  };
}

function sunshineConfigDir(): string {
  return join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), "sunshine");
}

export function realSunshineIo(): SunshineIo {
  const configDir = sunshineConfigDir();
  return {
    exec: run,
    has: realHyprIo.has,
    readText: (p) => readFile(p, "utf8").catch(() => null),
    http: tlsHttp(configDir),
    configDir,
    hostName: hostname(),
  };
}

// ---- endpoints ----

export interface SunshineOpts {
  limit?: RateLimit;
}

export function sunshineRoutes(app: FastifyInstance, ctx: Ctx, io: SunshineIo = realSunshineIo(), opts: SunshineOpts = {}) {
  const control = ctx.control;
  if (!control) throw new Error("sunshineRoutes: önce hyprRoutes (kontrol oturumu) kaydedilmeli");
  const sun = new Sunshine(io, () => ctx.store.get().sunshine);
  // Start/stop/pair: at most 6 per minute (wrong PIN attempts are limited too).
  const limit = opts.limit ?? new RateLimit(6, 60_000);
  const guard = (req: Parameters<typeof requireControl>[2]) => requireControl(ctx, control, req, limit);

  app.get("/v1/desktop/sunshine", async () => sun.status());

  app.post("/v1/desktop/sunshine/:action", async (req) => {
    const action = z.enum(["start", "stop", "pair"]).parse((req.params as { action: string }).action);
    if (action !== "pair") {
      await guard(req);
      return sun.setRunning(action === "start");
    }
    const body = z.object({ pin: z.string().regex(/^\d{4}$/), name: z.string().trim().min(1).max(64).optional() }).safeParse(req.body ?? {});
    // Keep the PIN out of the error details (zod issue).
    if (!body.success) throw new AppError("agent.sunshine.badPin", 400);
    await guard(req);
    return sun.pair(body.data.pin, body.data.name ?? req.device!.name);
  });
}
