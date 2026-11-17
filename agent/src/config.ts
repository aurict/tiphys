// The agent's own settings: ~/.config/tiphys/agent.json (or TIPHYS_AGENT_CONFIG).
// The file is written with mode 600, atomically (temp file + rename).
import { mkdir, readFile, rename, writeFile, chmod } from "node:fs/promises";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { z } from "zod";
import { whenSchema } from "./claude/schedules.ts";

const id = z.string().regex(/^[a-z0-9][a-z0-9-]{0,62}$/);

export const deviceSchema = z.object({
  id,
  name: z.string().min(1).max(80),
  tokenHash: z.string().regex(/^[a-f0-9]{64}$/),
  createdAt: z.string(),
});

/** "analysis": incident analysis jobs on the PC (PLAN.md §13.1 I-3, /v1/analysis/jobs). */
export const SERVICE_SCOPES = ["research", "analysis"] as const;

export const serviceTokenSchema = z.object({
  id,
  name: z.string().min(1).max(80),
  scopes: z.array(z.enum(SERVICE_SCOPES)).min(1),
  tokenHash: z.string().regex(/^[a-f0-9]{64}$/),
  createdAt: z.string(),
  lastUsedAt: z.string().optional(),
});

/** Backup check: "file" = age/size of the newest file matching the glob, "unit" = last result of a systemd unit. */
export const backupCheckSchema = z
  .object({
    id,
    name: z.string().min(1).max(80),
    kind: z.enum(["file", "unit"]),
    /** Only the last segment may contain * and ?, e.g. ~/backups/obsidian/*.json.gz */
    path: z.string().min(1).max(1024).optional(),
    /** e.g. obsidian-backup.service (user unit first, then system unit) */
    unit: z.string().regex(/^[A-Za-z0-9@_.:][A-Za-z0-9@_.:\\-]{0,199}$/).optional(),
    maxAgeHours: z.number().positive().max(24 * 366).default(26),
    minBytes: z.number().int().min(0).default(0),
  })
  .refine((c) => (c.kind === "file" ? !!c.path : !!c.unit), { message: "file için path, unit için unit gerekli" })
  .refine((c) => !c.path || !/[*?[]/.test(c.path.slice(0, c.path.lastIndexOf("/") + 1)), { message: "joker karakter yalnız son parçada olabilir", path: ["path"] });

const restoreId = z.string().regex(/^[a-z0-9][a-z0-9-]{0,62}$/);
/** Official images only, with an explicit tag (no `latest`, no digest, no registry/user prefix). */
export const RESTORE_IMAGE = /^(postgres|mysql|mariadb):(?!latest$)[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$/;

/**
 * Backup restore test (D-4): the newest dump matching dumpGlob is restored into a throwaway container of `image`
 * (no network, memory capped, data on tmpfs) and `sanity` queries are checked. anchorAt (set by the agent) is the start
 * of interval slots, like claude schedules.
 */
export const restoreTestSchema = z
  .strictObject({
    id: restoreId,
    name: z.string().min(1).max(80),
    connectionId: restoreId.optional(),
    engine: z.enum(["postgres", "mysql", "mariadb"]),
    image: z.string().regex(RESTORE_IMAGE),
    dumpGlob: z.string().min(1).max(1024),
    format: z.enum(["sql", "custom", "gz"]),
    sanity: z
      .array(
        z.strictObject({
          sql: z.string().min(1).max(4096),
          expect: z.strictObject({ op: z.enum([">", "=", ">=", "<", "<="]), value: z.number().finite() }),
        }),
      )
      .max(20)
      .default([]),
    schedule: whenSchema.nullable().default(null),
    enabled: z.boolean().default(true),
    anchorAt: z.string().optional(),
  })
  .refine((t) => t.image.startsWith(`${t.engine}:`), { message: "image engine ile uyuşmalı", path: ["image"] })
  .refine((t) => t.format !== "custom" || t.engine === "postgres", { message: "custom yalnız postgres için", path: ["format"] })
  .refine((t) => !/[*?[]/.test(t.dumpGlob.slice(0, t.dumpGlob.lastIndexOf("/") + 1)), { message: "joker karakter yalnız son parçada olabilir", path: ["dumpGlob"] })
  .refine((t) => !t.dumpGlob.split("/").includes("..") && !t.dumpGlob.includes("\0"), { message: "'..' olamaz", path: ["dumpGlob"] });

/** Container name (docker's rule), used by database connection targets. */
export const CONTAINER_NAME = /^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/;

export const dbCredentialSchema = z.union([
  z.strictObject({ user: z.string().min(1).max(128), password: z.string().max(1024).optional() }),
  z.strictObject({ fromContainerEnv: z.literal(true) }),
]);

export const dbTargetSchema = z.union([
  z.strictObject({
    container: z.string().regex(CONTAINER_NAME),
    network: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/).optional(),
    port: z.number().int().min(1).max(65535).optional(),
  }),
  z.strictObject({ host: z.string().min(1).max(253).regex(/^[A-Za-z0-9.:_-]+$/), port: z.number().int().min(1).max(65535).optional() }),
  z.strictObject({ path: z.string().min(1).max(1024) }),
]);

/**
 * A database connection (PLAN.md §13.2). postgres/mysql/mariadb: container or host target and readCredential
 * (writeCredential optional: the write mode uses it, else the read credential); sqlite: path target, no credentials.
 */
export const dbConnectionSchema = z
  .object({
    id,
    name: z.string().min(1).max(80),
    engine: z.enum(["postgres", "mysql", "mariadb", "sqlite"]),
    target: dbTargetSchema,
    database: z.string().min(1).max(128).optional(),
    readCredential: dbCredentialSchema.optional(),
    writeCredential: dbCredentialSchema.optional(),
  })
  .refine((c) => (c.engine === "sqlite" ? "path" in c.target && !c.readCredential && !c.writeCredential : !("path" in c.target) && !!c.readCredential), {
    message: "postgres/mysql/mariadb: container/host hedefi ve readCredential; sqlite: path hedefi, kimlik yok",
  })
  .refine((c) => ![c.readCredential, c.writeCredential].some((k) => k && "fromContainerEnv" in k) || "container" in c.target, {
    message: "fromContainerEnv yalnız container hedefiyle",
    path: ["readCredential"],
  });

export const agentConfigSchema = z.object({
  version: z.literal(1),
  name: z.string().min(1).max(80),
  listen: z.object({
    host: z.string().default("127.0.0.1"),
    port: z.number().int().min(1).max(65535).default(7443),
  }),
  /** The Tailscale-User-Login header added by Tailscale serve must equal this account (null = no check). */
  requireTailscaleLogin: z.string().nullable().default(null),
  features: z.object({
    system: z.boolean().default(true),
    services: z.boolean().default(true),
    docker: z.boolean().default(true),
    power: z.boolean().default(true),
    homepage: z.boolean().default(false),
    claude: z.boolean().default(false),
    uptime: z.boolean().default(false),
    wake: z.boolean().default(false),
    watch: z.boolean().default(false),
    git: z.boolean().default(false),
    desktop: z.boolean().default(false),
    /** Endpoints that change the desktop (window actions, app launch, later live screen input); needs "desktop". */
    control: z.boolean().default(false),
    ports: z.boolean().default(false),
    transcribe: z.boolean().default(false),
    alerts: z.boolean().default(false),
    backups: z.boolean().default(false),
    /** Web research jobs run with agy (Gemini) + Claude for another agent (PLAN.md §12); reached with a service token. */
    research: z.boolean().default(false),
    /** Telegram newsletters (PLAN.md §12): bot, recipients, feeds; research runs on another agent ("research" config). */
    telegram: z.boolean().default(false),
    /** Incident room (PLAN.md §13.1): groups alert notifications into incidents, collects context, offers actions. */
    incidents: z.boolean().default(false),
    /** Config & secrets (PLAN.md §13.3): view/edit the stacks' .env files with masked diffs, backups and reveal. */
    configfiles: z.boolean().default(false),
    /** Incident analysis jobs for other agents (PLAN.md §13.1 I-3): tool-less claude -p; reached with an "analysis" service token. */
    analysis: z.boolean().default(false),
    /** Database console (PLAN.md §13.2): connections, discovery, schema browser, read-only queries (D-1). */
    databases: z.boolean().default(false),
  }),
  devices: z.array(deviceSchema).default([]),
  /** Scoped service tokens (tps_…): they open only routes that declare one of their scopes. */
  serviceTokens: z.array(serviceTokenSchema).default([]),
  allowedRoots: z.array(z.string()).default(["~"]),
  claude: z
    .object({
      profiles: z.record(id, z.string()).default({ personal: "~/.claude" }),
      defaultProfile: id.default("personal"),
    })
    .default({ profiles: { personal: "~/.claude" }, defaultProfile: "personal" }),
  homepage: z
    .object({
      servicesPath: z.string().default("~/homepage/homepage/services.yaml"),
      checkTimeoutMs: z.number().int().min(500).max(30000).default(5000),
    })
    .default({ servicesPath: "~/homepage/homepage/services.yaml", checkTimeoutMs: 5000 }),
  /** UnifiedPush endpoints (each paired device registers one) and the ntfy access token. */
  push: z
    .object({
      endpoints: z.array(z.object({ deviceId: id, url: z.url(), pubKey: z.string().optional(), auth: z.string().optional() })).default([]),
      token: z.string().nullable().default(null),
    })
    .default({ endpoints: [], token: null }),
  uptimeKuma: z
    .object({ url: z.url(), username: z.string().min(1), password: z.string().min(1) })
    .nullable()
    .default(null),
  wake: z
    .object({
      targets: z
        .array(
          z.object({
            hostId: id,
            mac: z.string().regex(/^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$/),
            broadcast: z.string().default("255.255.255.255"),
            port: z.number().int().default(9),
          }),
        )
        .default([]),
    })
    .default({ targets: [] }),
  watch: z
    .object({
      hosts: z
        .array(
          z.object({
            hostId: id,
            url: z.url(),
            intervalSeconds: z.number().int().min(15).default(60),
            offlineAfterSeconds: z.number().int().min(30).default(180),
          }),
        )
        .default([]),
    })
    .default({ hosts: [] }),
  /** Local alerts (disk full, crashed service) and Grafana alerts; run while the "alerts" feature is on. */
  alerts: z
    .object({
      intervalSeconds: z.number().int().min(30).default(300),
      diskFullPercent: z.number().int().min(50).max(100).default(90),
      failedServices: z.boolean().default(true),
      grafana: z
        .object({ url: z.url(), token: z.string().min(1), datasourceUids: z.array(z.string()).default([]) })
        .nullable()
        .default(null),
    })
    .default({ intervalSeconds: 300, diskFullPercent: 90, failedServices: true, grafana: null }),
  /** Backup checks; evaluated every 15 min while the "backups" feature is on. */
  backups: z
    .object({
      checks: z
        .array(backupCheckSchema)
        .max(50)
        .refine((a) => new Set(a.map((c) => c.id)).size === a.length, { message: "denetim kimlikleri benzersiz olmalı" })
        .default([]),
    })
    .default({ checks: [] }),
  /**
   * Sunshine web UI (10.2 Phase B, Moonlight pairing): username/password are stored only in the agent.
   * A self-signed certificate is accepted only on a loopback address (see routes/sunshine.ts).
   */
  sunshine: z
    .object({ url: z.url({ protocol: /^https$/ }).default("https://127.0.0.1:47990"), username: z.string().min(1).max(128), password: z.string().min(1).max(256) })
    .nullable()
    .default(null),
  /** Desktop ("desktop" feature): silent notification to the phone when the PC clipboard changes (text only). */
  desktop: z.object({ clipboardSync: z.boolean().default(true) }).default({ clipboardSync: true }),
  transcribe: z
    .object({ command: z.string().default("~/.local/bin/transcribe"), model: z.enum(["small", "large-v3"]).default("small") })
    .default({ command: "~/.local/bin/transcribe", model: "small" }),
  /** Telegram bot ("telegram" feature): set with PUT /v1/telegram/bot after getMe; the token is never returned. */
  telegram: z
    .object({ botToken: z.string().min(1).max(200), botUsername: z.string().min(1).max(64), botId: z.number().int() })
    .nullable()
    .default(null),
  /**
   * The PC agent that runs research jobs for the "telegram" feature: its URL and a service token with the "research"
   * scope (never returned). wakeHostId: a wake.targets entry woken (Wake-on-LAN) when the PC can't be reached.
   */
  research: z
    .object({ url: z.url({ protocol: /^https?$/ }), token: z.string().min(1).max(200), wakeHostId: id.optional() })
    .nullable()
    .default(null),
  /**
   * Compose stacks (PLAN.md §13.0): every directory directly under a root holding a compose file is a stack.
   * Separate from allowedRoots: stack actions (compose recreate) only touch files inside these roots.
   */
  stacks: z.object({ roots: z.array(z.string().min(1).max(1024)).max(20).default(["~/stack"]) }).default({ roots: ["~/stack"] }),
  /** Incident room ("incidents" feature). links: ties an Uptime Kuma monitor to a stack/service for grouping and actions. */
  incidents: z
    .object({
      links: z
        .array(
          z.object({
            uptimeMonitor: z.string().min(1).max(150).optional(),
            stack: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/),
            service: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9_.-]{0,99}$/).optional(),
          }),
        )
        .max(200)
        .default([]),
      /**
       * AI analysis (I-3). local: tool-less claude -p in this agent; remote: jobs on the PC agent at `url` with a service
       * token of the "analysis" scope (never returned); off: rule hints only. The PC is never woken for an analysis.
       */
      analysis: z
        .object({
          mode: z.enum(["local", "remote", "off"]).default("off"),
          url: z.url({ protocol: /^https?$/ }).optional(),
          token: z.string().min(1).max(200).optional(),
          language: z.enum(["tr", "en"]).default("tr"),
        })
        .refine((a) => a.mode !== "remote" || (!!a.url && !!a.token), { message: "remote için url ve token gerekli" })
        .default({ mode: "off", language: "tr" }),
    })
    .default({ links: [], analysis: { mode: "off", language: "tr" } }),
  /**
   * Config files ("configfiles" feature). extraPaths: extra .env files besides the ones found in stacks; each must be a
   * regular file (not a symlink out of its directory), owned by the agent user, ≤256 KB, named .env / *.env / .env.*.
   */
  configFiles: z.object({ extraPaths: z.array(z.string().min(1).max(1024)).max(50).default([]) }).default({ extraPaths: [] }),
  /**
   * Database console ("databases" feature). Credentials live only here (never returned by the API); fromContainerEnv
   * reads POSTGRES_* / MYSQL_* / MARIADB_* from `docker inspect` at connect time and stores nothing. Saved queries
   * live in db-queries.json and the write log in db-writes.jsonl, both next to this file (0600).
   */
  databases: z
    .object({
      connections: z
        .array(dbConnectionSchema)
        .max(100)
        .refine((a) => new Set(a.map((c) => c.id)).size === a.length, { message: "bağlantı kimlikleri benzersiz olmalı" })
        .default([]),
      /** Backup restore tests (D-4); results live in db-restore-results.json next to this file. */
      restoreTests: z
        .array(restoreTestSchema)
        .max(20)
        .refine((a) => new Set(a.map((t) => t.id)).size === a.length, { message: "test kimlikleri benzersiz olmalı" })
        .default([]),
    })
    .default({ connections: [], restoreTests: [] }),
});

export type AgentConfig = z.infer<typeof agentConfigSchema>;
export type DbConnection = z.infer<typeof dbConnectionSchema>;
export type Device = z.infer<typeof deviceSchema>;
export type ServiceToken = z.infer<typeof serviceTokenSchema>;
export type ServiceScope = (typeof SERVICE_SCOPES)[number];

export function defaultConfigPath(): string {
  return process.env.TIPHYS_AGENT_CONFIG ?? join(homedir(), ".config", "tiphys", "agent.json");
}

export function expandHome(p: string): string {
  return p === "~" ? homedir() : p.startsWith("~/") ? join(homedir(), p.slice(2)) : p;
}

export function defaultConfig(name: string): AgentConfig {
  return agentConfigSchema.parse({ version: 1, name, listen: {}, features: {} });
}

export class ConfigStore {
  readonly path: string;
  #config: AgentConfig;

  private constructor(path: string, config: AgentConfig) {
    this.path = path;
    this.#config = config;
  }

  static async load(path = defaultConfigPath()): Promise<ConfigStore> {
    const raw = await readFile(path, "utf8");
    return new ConfigStore(path, agentConfigSchema.parse(JSON.parse(raw)));
  }

  static async loadOrCreate(path: string, name: string): Promise<ConfigStore> {
    try {
      return await ConfigStore.load(path);
    } catch (e) {
      if ((e as NodeJS.ErrnoException).code !== "ENOENT") throw e;
      const store = new ConfigStore(path, defaultConfig(name));
      await store.save();
      return store;
    }
  }

  get(): AgentConfig {
    return this.#config;
  }

  async update(fn: (c: AgentConfig) => AgentConfig): Promise<AgentConfig> {
    const next = agentConfigSchema.parse(fn(structuredClone(this.#config)));
    this.#config = next;
    await this.save();
    return next;
  }

  async save(): Promise<void> {
    await mkdir(dirname(this.path), { recursive: true, mode: 0o700 });
    const tmp = `${this.path}.${process.pid}.tmp`;
    await writeFile(tmp, JSON.stringify(this.#config, null, 2) + "\n", { mode: 0o600 });
    await chmod(tmp, 0o600);
    await rename(tmp, this.path);
  }
}
