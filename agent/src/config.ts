// The agent's own settings: ~/.config/tiphys/agent.json (or TIPHYS_AGENT_CONFIG).
// The file is written with mode 600, atomically (temp file + rename).
import { mkdir, readFile, rename, writeFile, chmod } from "node:fs/promises";
import { dirname, join } from "node:path";
import { homedir } from "node:os";
import { z } from "zod";

const id = z.string().regex(/^[a-z0-9][a-z0-9-]{0,62}$/);

export const deviceSchema = z.object({
  id,
  name: z.string().min(1).max(80),
  tokenHash: z.string().regex(/^[a-f0-9]{64}$/),
  createdAt: z.string(),
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
  }),
  devices: z.array(deviceSchema).default([]),
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
});

export type AgentConfig = z.infer<typeof agentConfigSchema>;
export type Device = z.infer<typeof deviceSchema>;

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
