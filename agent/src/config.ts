// The agent's own settings: ~/.config/tiphys/agent.json (Windows: %APPDATA%\Tiphys\agent.json; or TIPHYS_AGENT_CONFIG).
// The file is written with mode 600, atomically (temp file + rename). Windows ignores the mode bits: the file is
// protected by the user profile's default ACL only (no extra ACL is set).
import { existsSync, watch as fsWatch, type FSWatcher } from "node:fs";
import { mkdir, readFile, rename, writeFile, chmod, stat } from "node:fs/promises";
import { basename, dirname, join } from "node:path";
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
/** "security-report": another agent (the monitoring server) pulls this host's raw audit report (PLAN.md §15). */
/** "blackbox": an agent appends its records to this agent's black box; "lockdown": this agent revokes all access on request. */
/** "gamemode": the laptop's agent reads this PC's Game mode feed (PLAN.md §19, WS /v1/gamemode/feed). */
export const SERVICE_SCOPES = ["research", "analysis", "security-report", "blackbox", "lockdown", "gamemode"] as const;

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

export const securityRole = z.enum(["server", "desktop"]);
const allowedPorts = z.array(z.string().regex(/^(tcp|udp)\/([1-9]\d{0,3}|[1-5]\d{4}|6[0-4]\d{3}|65[0-4]\d{2}|655[0-2]\d|6553[0-5])$/)).max(100);
/** Hostname or IP for ssh (no leading "-", no user part, no spaces). */
const sshHost = z.string().regex(/^(?!-)[A-Za-z0-9.:_-]{1,253}$/);
/** ssh destination of a security fix target: "user@host" or a bare host/alias; no options, spaces or leading "-". */
export const SSH_DEST = /^(?:[A-Za-z0-9_][A-Za-z0-9_.-]{0,31}@)?[A-Za-z0-9_][A-Za-z0-9_.-]{0,252}$/;
export const securityFixTargetSchema = z.strictObject({
  /** Security host id as known on the monitoring server. */
  host: id,
  name: z.string().min(1).max(80),
  /** null = this machine (commands run locally). */
  ssh: z.string().regex(SSH_DEST).nullable(),
  port: z.number().int().min(1).max(65535).optional(),
});
export const securityFixSchema = z.object({
  targets: z
    .array(securityFixTargetSchema)
    .max(20)
    .refine((a) => new Set(a.map((t) => t.host)).size === a.length, { message: "hedef host kimlikleri benzersiz olmalı" })
    .default([]),
  sudoCacheMinutes: z.number().int().min(1).max(120).default(15),
});
export const securitySourceSchema = z.discriminatedUnion("kind", [
  z.strictObject({
    kind: z.literal("ssh"),
    host: sshHost,
    user: z.string().regex(/^[a-z_][a-z0-9_-]{0,31}$/),
    port: z.number().int().min(1).max(65535).default(22),
    /** Private key of the restricted audit key (on this machine). */
    keyPath: z.string().min(1).max(1024),
  }),
  z.strictObject({ kind: z.literal("agent"), url: z.url({ protocol: /^https$/ }), token: z.string().regex(/^tps_[A-Za-z0-9_-]{20,}$/) }),
]);
export const securityHostSchema = z.strictObject({
  id,
  name: z.string().min(1).max(80),
  role: securityRole.default("server"),
  allowedPorts: allowedPorts.default([]),
  source: securitySourceSchema,
  /** SSH hosts: poll `traps` (auditd key tiphys_trap) every minute. Needs the rule on the host (install-audit.sh --trap). */
  traps: z.boolean().default(false),
});

/** Decoys (S-3). Tokens are stored hashed; files are created by the agent and watched by access time. */
export const securityTrapsSchema = z.object({
  tokens: z
    .array(z.strictObject({ id, name: z.string().min(1).max(80), tokenHash: z.string().regex(/^[a-f0-9]{64}$/), createdAt: z.string() }))
    .max(20)
    .default([]),
  files: z
    .array(z.strictObject({ id, path: z.string().min(1).max(1024), kind: z.enum(["env", "sshkey"]), createdAt: z.string() }))
    .max(20)
    .default([]),
  /** Database user names that exist only in decoy files: a login attempt with one in the logs (Loki) is an alarm. */
  dbUsers: z.array(z.string().regex(/^[a-z_][a-z0-9_]{2,62}$/)).max(10).default([]),
});

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
    /** PostgreSQL: role user SQL reads switch to (SET LOCAL ROLE); the login user must be able to SET ROLE to it. */
    readRole: z.string().min(1).max(63).optional(),
    /** PostgreSQL: run user SQL reads with a superuser login and no readRole (otherwise agent.db.superuserReadsDisabled). */
    allowSuperuserReads: z.boolean().optional(),
  })
  .refine((c) => c.engine === "postgres" || (c.readRole === undefined && c.allowSuperuserReads === undefined), {
    message: "readRole/allowSuperuserReads yalnız postgres",
    path: ["readRole"],
  })
  .refine((c) => (c.engine === "sqlite" ? "path" in c.target && !c.readCredential && !c.writeCredential : !("path" in c.target) && !!c.readCredential), {
    message: "postgres/mysql/mariadb: container/host hedefi ve readCredential; sqlite: path hedefi, kimlik yok",
  })
  .refine((c) => ![c.readCredential, c.writeCredential].some((k) => k && "fromContainerEnv" in k) || "container" in c.target, {
    message: "fromContainerEnv yalnız container hedefiyle",
    path: ["readCredential"],
  });

/** Game mode display settings (PLAN.md §19 contract); pushed to the kiosk page as the `settings` message. */
export const gamemodeDisplaySchema = z.object({
  scene: z.enum(["auto", "drive", "music"]).default("auto"),
  lyrics: z.boolean().default(true),
  spectrum: z.boolean().default(true),
  motion: z.enum(["low", "normal", "high"]).default("normal"),
  /** Backlight percent while the mode runs; null = don't touch it. */
  brightness: z.number().int().min(5).max(100).nullable().default(null),
  clock24: z.boolean().default(true),
  /** Dim the idle scene after this many minutes; 0 = never. */
  dimIdleMinutes: z.number().int().min(0).max(120).default(10),
});
export type GamemodeDisplay = z.infer<typeof gamemodeDisplaySchema>;
export const GAMEMODE_DISPLAY_DEFAULTS: GamemodeDisplay = gamemodeDisplaySchema.parse({});

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
    /** Security center (PLAN.md §15): audits this host and others (restricted SSH key / another agent), score, changes. */
    security: z.boolean().default(false),
    /** Antigravity CLI (agy) sessions from the phone over its Agent Client Protocol (PC; agy installed and logged in). */
    agy: z.boolean().default(false),
    /** Claude "security" sessions fix security items on pinned targets over SSH (PLAN.md §16); needs "claude". */
    securityFix: z.boolean().default(false),
    /** Self-update from signed GitHub releases (only installs made by install.sh; see update.ts). */
    update: z.boolean().default(false),
    /** Game mode (PLAN.md §19): the source feed (Velour, spectrum, ETS2) and/or the kiosk display on this machine. */
    gamemode: z.boolean().default(false),
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
  /**
   * Desktop ("desktop" feature): silent notification to the phone when the PC clipboard changes (text only).
   * backend (read at startup; absent = "auto"): "hyprland" = the agent drives Hyprland itself, "helper" = the native
   * helper `tiphys-desktop` (other desktops, desktop_helper.ts), "auto" = Hyprland if an instance is found, else the
   * helper if its binary is found, else Hyprland. helperPath: the helper binary (absent = next to the agent, then PATH).
   * Both optional so existing configs and API answers stay the same; only the config file sets them (not PATCH).
   */
  desktop: z
    .object({
      clipboardSync: z.boolean().default(true),
      backend: z.enum(["auto", "hyprland", "helper"]).optional(),
      helperPath: z.string().min(1).max(4096).optional(),
    })
    .default({ clipboardSync: true }),
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
   * Game mode ("gamemode" feature). source: the agent that serves WS /v1/gamemode/feed (its URL and a service token
   * with the "gamemode" scope; the token is never returned by any API). display: the kiosk page settings.
   */
  gamemode: z
    .object({
      source: z.object({ url: z.url({ protocol: /^https?$/ }), token: z.string().min(1).max(200) }).nullable().default(null),
      display: gamemodeDisplaySchema.default(GAMEMODE_DISPLAY_DEFAULTS),
    })
    .default({ source: null, display: GAMEMODE_DISPLAY_DEFAULTS }),
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
  /** Claude security fix sessions ("securityFix" feature): targets reachable over SSH (or this machine). */
  securityFix: securityFixSchema.default({ targets: [], sudoCacheMinutes: 15 }),
  /** Security center ("security" feature). The token of an agent source is never returned by the API. */
  security: z
    .object({
      self: z
        .object({ role: securityRole.default("server"), allowedPorts: allowedPorts.default([]), sudo: z.boolean().default(false) })
        .default({ role: "server", allowedPorts: [], sudo: false }),
      hosts: z
        .array(securityHostSchema)
        .max(20)
        .refine((a) => new Set(a.map((h) => h.id)).size === a.length && !a.some((h) => h.id === "self"), { message: "host kimlikleri benzersiz olmalı (self ayrılmış)" })
        .default([]),
      intervalMinutes: z.number().int().min(5).max(1440).default(15),
      traps: securityTrapsSchema.default({ tokens: [], files: [], dbUsers: [] }),
      /**
       * Black box (S-4): "local" keeps the hash chain here (the monitoring server), "push" sends this agent's records to
       * another agent's chain (url + a "blackbox" service token, never returned), "off".
       */
      blackbox: z
        .object({
          mode: z.enum(["off", "local", "push"]).default("off"),
          url: z.url({ protocol: /^https$/ }).nullable().default(null),
          token: z.string().regex(/^tps_[A-Za-z0-9_-]{20,}$/).nullable().default(null),
        })
        .default({ mode: "off", url: null, token: null }),
      /** Lost phone (S-4): scrypt hash of the recovery code; agents that a lockdown fans out to ("lockdown" tokens). */
      recovery: z
        .object({ salt: z.string().regex(/^[a-f0-9]{32}$/), hash: z.string().regex(/^[a-f0-9]{64}$/), createdAt: z.string() })
        .nullable()
        .default(null),
      lockdownTargets: z
        .array(z.strictObject({ id, name: z.string().min(1).max(80), url: z.url({ protocol: /^https$/ }), token: z.string().regex(/^tps_[A-Za-z0-9_-]{20,}$/) }))
        .max(20)
        .default([]),
      /** Outside view (S-5): weekly from this machine; off by default. */
      exposure: z
        .object({
          enabled: z.boolean().default(false),
          targets: z
            .array(
              z.strictObject({
                id,
                kind: z.enum(["ip", "domain"]),
                value: z.string().regex(/^(?=.{1,253}$)(?!-)[A-Za-z0-9-]{1,63}(\.(?!-)[A-Za-z0-9-]{1,63})*$|^\d{1,3}(\.\d{1,3}){3}$/),
                /** ip: ports that are meant to be reachable from the internet. */
                expectedPorts: z.array(z.number().int().min(1).max(65535)).max(50).default([]),
              }),
            )
            .max(30)
            .default([]),
          extraPorts: z.array(z.number().int().min(1).max(65535)).max(100).default([]),
          intervalDays: z.number().int().min(1).max(30).default(7),
        })
        .default({ enabled: false, targets: [], extraPorts: [], intervalDays: 7 }),
      /** Attack detection from Cloudflare analytics (S-5); tokens are never returned by the API. */
      cloudflare: z
        .object({
          /** Zone › Analytics: Read + Zone › Zone: Read. */
          readToken: z.string().min(1).max(200).nullable().default(null),
          /** Zone › Firewall Services: Edit (only for blocking). */
          blockToken: z.string().min(1).max(200).nullable().default(null),
          block: z.boolean().default(false),
          blockHours: z.number().int().min(1).max(720).default(24),
          /** Zone names to watch (empty = every zone the token can read). */
          zones: z.array(z.string().min(1).max(253)).max(50).default([]),
          allowIps: z.array(z.string().regex(/^[0-9a-fA-F:.]{3,45}$/)).max(50).default([]),
        })
        .default({ readToken: null, blockToken: null, block: false, blockHours: 24, zones: [], allowIps: [] }),
      /** Critical security notices also go to this Telegram recipient (id from the telegram feature), title only. */
      alerts: z.object({ telegramRecipient: z.string().min(1).max(64).nullable().default(null) }).default({ telegramRecipient: null }),
      /** Heavy scanners on the monitoring server (S-2); off by default. Tokens are never returned by the API. */
      scanners: z
        .object({
          trivy: z.boolean().default(false),
          gitleaks: z.boolean().default(false),
          /** Download Trivy's Java DB (≈1 GB) and scan JARs; off = JAR/WAR/EAR files are skipped. */
          javaDb: z.boolean().default(false),
          /** Read-only registry credentials for private images (e.g. ghcr.io + a read:packages token). */
          registryAuth: z
            .array(z.strictObject({ registry: z.string().regex(/^[a-z0-9.-]+(:\d+)?$/), username: z.string().min(1).max(100), token: z.string().min(1).max(500) }))
            .max(10)
            .default([]),
          /** GitHub owners whose repositories gitleaks scans; token (contents:read) for private ones. */
          github: z
            .object({ owners: z.array(z.string().regex(/^[A-Za-z0-9-]{1,39}$/)).max(20).default([]), token: z.string().min(1).max(500).nullable().default(null) })
            .default({ owners: [], token: null }),
          /** Loki for the log secret scan: a container on this machine (its IP is looked up) or a URL. */
          loki: z
            .union([z.strictObject({ container: z.string().regex(/^[A-Za-z0-9][A-Za-z0-9_.-]{0,127}$/), port: z.number().int().min(1).max(65535).default(3100) }), z.strictObject({ url: z.url() })])
            .nullable()
            .default(null),
          /** Git repositories (a repo, or a folder of repos) inside allowedRoots scanned on this machine (e.g. the PC). */
          localRoots: z.array(z.string().min(1).max(1024)).max(20).default([]),
          /** Local hours [from, to) for heavy work. */
          nightHours: z.tuple([z.number().int().min(0).max(23), z.number().int().min(0).max(24)]).default([2, 6]),
        })
        .default({ trivy: false, gitleaks: false, javaDb: false, registryAuth: [], github: { owners: [], token: null }, loki: null, localRoots: [], nightHours: [2, 6] }),
    })
    .default({
      self: { role: "server", allowedPorts: [], sudo: false },
      hosts: [],
      intervalMinutes: 15,
      traps: { tokens: [], files: [], dbUsers: [] },
      blackbox: { mode: "off", url: null, token: null },
      recovery: null,
      lockdownTargets: [],
      exposure: { enabled: false, targets: [], extraPorts: [], intervalDays: 7 },
      cloudflare: { readToken: null, blockToken: null, block: false, blockHours: 24, zones: [], allowIps: [] },
      alerts: { telegramRecipient: null },
      scanners: { trivy: false, gitleaks: false, javaDb: false, registryAuth: [], github: { owners: [], token: null }, loki: null, localRoots: [], nightHours: [2, 6] },
    }),
});

export type AgentConfig = z.infer<typeof agentConfigSchema>;
export type DbConnection = z.infer<typeof dbConnectionSchema>;
export type Device = z.infer<typeof deviceSchema>;
export type ServiceToken = z.infer<typeof serviceTokenSchema>;
export type ServiceScope = (typeof SERVICE_SCOPES)[number];

/**
 * Linux and macOS: ~/.config/tiphys/agent.json. Windows: %APPDATA%\Tiphys\agent.json, unless an older install already
 * has %USERPROFILE%\.config\tiphys\agent.json (kept so its paired devices stay).
 */
export function defaultConfigPath(platform: NodeJS.Platform = process.platform, env: NodeJS.ProcessEnv = process.env, exists = existsSync): string {
  if (env.TIPHYS_AGENT_CONFIG) return env.TIPHYS_AGENT_CONFIG;
  const unix = join(homedir(), ".config", "tiphys", "agent.json");
  if (platform !== "win32" || !env.APPDATA || exists(unix)) return unix;
  return join(env.APPDATA, "Tiphys", "agent.json");
}

export function expandHome(p: string): string {
  if (p === "~") return homedir();
  if (p.startsWith("~/") || (process.platform === "win32" && p.startsWith("~\\"))) return join(homedir(), p.slice(2));
  return p;
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
    const st = await stat(path);
    const raw = await readFile(path, "utf8");
    const store = new ConfigStore(path, agentConfigSchema.parse(JSON.parse(raw)));
    store.#seen = fileId(st);
    return store;
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
    // Another process (e.g. `tiphys-agent pair`) may have written the file: start from its version, don't overwrite it.
    await this.reloadIfChanged().catch(() => false);
    const next = agentConfigSchema.parse(fn(structuredClone(this.#config)));
    this.#config = next;
    await this.save();
    return next;
  }

  #saving: Promise<void> = Promise.resolve();
  #seq = 0;

  /**
   * Writes the current settings. Saves are serialized and each uses its own temp file: two updates at once (e.g. a
   * service token's lastUsedAt and a revoke-all) used to share one temp name and fail with ENOENT on rename.
   */
  save(): Promise<void> {
    const run = async () => {
      await mkdir(dirname(this.path), { recursive: true, mode: 0o700 });
      const tmp = `${this.path}.${process.pid}.${++this.#seq}.tmp`;
      await writeFile(tmp, JSON.stringify(this.#config, null, 2) + "\n", { mode: 0o600 });
      await chmod(tmp, 0o600);
      await rename(tmp, this.path);
      this.#seen = fileId(await stat(this.path));
    };
    this.#pending++;
    const p = this.#saving.catch(() => {}).then(run).finally(() => this.#pending--);
    this.#saving = p.catch(() => {});
    return p;
  }

  /** Identity of the file version this store last read or wrote (inode, size, mtime). */
  #seen = "";
  #pending = 0;

  /**
   * Re-reads the file if another process changed it since this store last read/wrote it (K4: a device paired with
   * the CLI works without restarting the agent). An invalid file is ignored (the old settings stay) and reported
   * with `false`. Skipped while this store has unsaved writes queued. Returns true when the settings were replaced.
   */
  async reloadIfChanged(): Promise<boolean> {
    if (this.#pending > 0) return false;
    let st;
    try {
      st = await stat(this.path);
    } catch {
      return false;
    }
    const id = fileId(st);
    if (id === this.#seen) return false;
    const raw = await readFile(this.path, "utf8");
    const parsed = agentConfigSchema.safeParse((() => { try { return JSON.parse(raw); } catch { return null; } })());
    if (!parsed.success || this.#pending > 0) return false;
    this.#config = parsed.data;
    this.#seen = id;
    return true;
  }

  /**
   * Watches the settings file for changes made by other processes (debounced). The directory is watched because
   * writes replace the file (rename). Returns a function that stops watching.
   */
  watch(onReload?: (ok: boolean) => void, debounceMs = 250): () => void {
    let timer: NodeJS.Timeout | undefined;
    let w: FSWatcher | undefined;
    const name = basename(this.path);
    try {
      w = fsWatch(dirname(this.path), { persistent: false }, (_ev, file) => {
        if (file !== null && file !== name) return;
        clearTimeout(timer);
        timer = setTimeout(() => void this.reloadIfChanged().then((r) => r && onReload?.(true), () => onReload?.(false)), debounceMs);
      });
      w.on("error", () => {});
    } catch {
      // No watcher (e.g. unsupported file system): unknown tokens still trigger a re-read (server.ts).
    }
    return () => {
      clearTimeout(timer);
      w?.close();
    };
  }
}

function fileId(st: { ino: number; size: number; mtimeMs: number }): string {
  return `${st.ino}:${st.size}:${st.mtimeMs}`;
}
