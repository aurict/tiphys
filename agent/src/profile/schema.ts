// The single source of truth for the .tiphys.json profile file. `npm run schema` generates JSON Schema from it
// (../schema/tiphys.schema.json); the Flutter app validates with the same schema.
// All top-level sections are optional: a partial file merges only the sections it contains.
import { z } from "zod";

export const SCHEMA_VERSION = 2;

const id = z.string().regex(/^[a-z0-9][a-z0-9-]{0,62}$/).describe("kebab-case kimlik");
const secretRef = z.string().regex(/^secret:[a-z0-9][a-z0-9-]{0,62}$/).describe("Telefon kasasındaki gizli bilgiye başvuru");
const color = z.string().regex(/^#[0-9A-Fa-f]{6}$/);
const url = z.string().regex(/^https?:\/\/\S+$/);
const path = z.string().min(1).max(1024);

export const homeCard = z.enum(["infra", "claude", "system", "grafana", "dozzle", "quickAccess", "events", "nowPlaying"]);
export const tab = z.enum(["home", "claude", "terminal", "files", "system"]);
// Home screen shortcuts; the default set is the rows of the old "Hızlı erişim" card.
export const shortcut = z.enum([
  "terminal", "files", "quickNote", "homepage", "vault", "desktop", "liveScreen", "media", "openOnPc", "newClaude", "schedules",
  "events", "compose", "logs", "backups", "dozzle", "grafana", "sites", "wake",
]);
const defaultShortcuts: z.infer<typeof shortcut>[] = ["terminal", "files", "quickNote", "homepage"];

const app = z.strictObject({
  theme: z.enum(["system", "light", "dark"]).default("system"),
  language: z.enum(["system", "tr", "en"]).default("system"),
  lock: z
    .strictObject({
      biometric: z.boolean().default(true),
      pin: z.boolean().default(true),
      autoLockSeconds: z.int().min(0).max(3600).default(60),
    })
    .default({ biometric: true, pin: true, autoLockSeconds: 60 }),
  home: z
    .strictObject({
      cards: z.array(homeCard).default(["infra", "claude", "system", "grafana", "dozzle", "quickAccess"]),
      tabs: z.array(tab).min(1).max(5).default(["home", "claude", "terminal", "files", "system"]),
      layout: z.enum(["cards", "grid", "focus"]).default("cards"),
      shortcuts: z.array(shortcut).default(defaultShortcuts),
    })
    .default({
      cards: ["infra", "claude", "system", "grafana", "dozzle", "quickAccess"],
      tabs: ["home", "claude", "terminal", "files", "system"],
      layout: "cards",
      shortcuts: defaultShortcuts,
    }),
});

const sshAuth = z.discriminatedUnion("type", [
  z.strictObject({ type: z.literal("key"), keyRef: secretRef }),
  z.strictObject({ type: z.literal("password"), passwordRef: secretRef }),
]);

const host = z.strictObject({
  id,
  name: z.string().min(1).max(80),
  color: color.default("#8F88EE"),
  address: z.string().min(1).max(253),
  ssh: z
    .strictObject({
      port: z.int().min(1).max(65535).default(22),
      user: z.string().min(1).max(64),
      auth: sshAuth,
      tmuxSession: z.string().regex(/^[A-Za-z0-9_.-]{1,64}$/).default("tiphys"),
    })
    .nullable()
    .default(null),
  agent: z
    .strictObject({ url, tokenRef: secretRef })
    .nullable()
    .default(null),
  wake: z
    .strictObject({ mac: z.string().regex(/^([0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}$/), viaHostId: id.nullable().default(null) })
    .nullable()
    .default(null),
  tags: z.array(z.string().max(32)).default([]),
  /** Roots where Compose stacks are looked for (SSH): compose.y*ml / docker-compose.y*ml in each root's subfolders. */
  composeRoots: z.array(path).max(10).default(["~/stack"]),
});

const key = z.strictObject({
  id,
  label: z.string().min(1).max(80),
  type: z.enum(["ssh-ed25519", "ssh-rsa", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521"]),
  publicKey: z.string().min(16).max(16384),
});

const claude = z.strictObject({
  agentHostId: id.nullable().default(null),
  defaults: z
    .strictObject({
      model: z.string().default("claude-opus-5-5"),
      effort: z.enum(["low", "medium", "high", "xhigh", "max"]).default("high"),
      permissionMode: z.enum(["default", "acceptEdits", "plan", "bypassPermissions"]).default("bypassPermissions"),
      profileId: id.default("personal"),
    })
    .default({ model: "claude-opus-5-5", effort: "high", permissionMode: "bypassPermissions", profileId: "personal" }),
  profiles: z.array(z.strictObject({ id, name: z.string().min(1), configDir: path })).default([]),
  favoriteFolders: z.array(path).default([]),
  pinnedCommands: z.array(z.string().regex(/^\/\S+$/)).default([]),
  notify: z
    .strictObject({ done: z.boolean().default(true), waiting: z.boolean().default(true), error: z.boolean().default(true) })
    .default({ done: true, waiting: true, error: true }),
});

const grafana = z.strictObject({
  id,
  name: z.string().min(1),
  url,
  auth: z.discriminatedUnion("type", [
    z.strictObject({ type: z.literal("token"), tokenRef: secretRef }),
    z.strictObject({ type: z.literal("none") }),
  ]),
  defaultDashboardUid: z.string().nullable().default(null),
  favorites: z.array(z.string()).default([]),
  refreshSeconds: z.int().min(0).max(3600).default(30),
  defaultRange: z.string().default("now-1h"),
});

const dozzle = z.strictObject({
  id,
  name: z.string().min(1),
  url,
  auth: z.discriminatedUnion("type", [
    z.strictObject({ type: z.literal("none") }),
    z.strictObject({ type: z.literal("basic"), username: z.string().min(1), passwordRef: secretRef }),
  ]),
});

const integrations = z.strictObject({
  grafana: z.array(grafana).default([]),
  dozzle: z.array(dozzle).default([]),
  homepage: z
    .strictObject({
      browserUrl: url,
      source: z.strictObject({ type: z.literal("agentFile"), hostId: id, path }),
      openIn: z.enum(["external", "inApp"]).default("external"),
    })
    .nullable()
    .default(null),
  uptimeKuma: z
    .strictObject({
      viaHostId: id,
      url,
      defaults: z
        .strictObject({
          intervalSeconds: z.int().min(20).max(86400).default(60),
          alertAfterSeconds: z.int().min(0).max(86400).default(120),
          certExpiryDays: z.int().min(0).max(365).default(14),
        })
        .default({ intervalSeconds: 60, alertAfterSeconds: 120, certExpiryDays: 14 }),
      notifyOnRecovery: z.boolean().default(true),
    })
    .nullable()
    .default(null),
  ntfy: z
    // tokenRef is accepted for compatibility with old files but unused: notification login is in the ntfy app on the phone.
    .strictObject({ url, tokenRef: secretRef.nullable().optional(), topics: z.array(z.string().min(1)).default([]) })
    .nullable()
    .default(null),
  scriberr: z
    // Voice is transcribed via the agent on the PC (the Scriberr key is on the agent). url/apiKeyRef are accepted for
    // compatibility with old files but unused.
    .strictObject({
      url: url.optional(),
      apiKeyRef: secretRef.optional(),
      language: z.enum(["tr", "en", "auto"]).default("tr"),
      model: z.enum(["small", "large-v3"]).default("small"),
    })
    .nullable()
    .default(null),
  obsidian: z
    // Quick note: the app has the note written to Obsidian on the phone via an obsidian:// link (LiveSync encryption is kept).
    .strictObject({
      vault: z.string().min(1).max(200),
      folder: z.string().max(500).default("Gelen kutusu"),
      mode: z.enum(["newNote", "dailyNote"]).default("newNote"),
      /** Daily note path; YYYY, MM, DD are replaced with the date. */
      dailyNotePath: z.string().min(1).max(500).default("Günlük/YYYY-MM-DD"),
    })
    .nullable()
    .default(null),
});

const terminal = z.strictObject({
  fontSize: z.number().min(8).max(32).default(13),
  theme: z.string().default("tiphys"),
  extraKeys: z.array(z.string().min(1).max(16)).default(["esc", "tab", "ctrl", "alt", "up", "down", "left", "right", "|", "~", "/"]),
  snippets: z.array(z.strictObject({ name: z.string().min(1), command: z.string().min(1), hostId: id.nullable().default(null) })).default([]),
});

const files = z.strictObject({
  bookmarks: z.array(z.strictObject({ hostId: id, path })).default([]),
  showHidden: z.boolean().default(false),
});

const quickAction = z.strictObject({
  id,
  name: z.string().min(1).max(80),
  icon: z.string().default("zap"),
  hostId: id,
  command: z.string().min(1),
  confirm: z.boolean().default(true),
});

// Live screen controls (11.1): the user's own buttons per window class. Shortcut text ("ctrl+shift+t", "F5") is
// validated on the phone with the agent's key table; a non-allowed key isn't saved. Text is typed with wtype.
export const remoteIcon = z.enum(["zap", "star", "play", "search", "save", "copy", "refresh", "close", "plus", "folder", "terminal", "globe"]);
const remoteCombo = z.string().min(1).max(40);
const remoteAction = z.discriminatedUnion("kind", [
  z.strictObject({ kind: z.literal("combo"), combo: remoteCombo }),
  z.strictObject({
    kind: z.literal("sequence"),
    steps: z.array(z.union([z.strictObject({ combo: remoteCombo }), z.strictObject({ text: z.string().min(1).max(500) })])).min(1).max(10),
  }),
  /** Text is asked on the phone: first [combo] (e.g. ctrl+l), then the text, Enter if [submit]. */
  z.strictObject({ kind: z.literal("prompt"), combo: remoteCombo.optional(), submit: z.boolean().default(true) }),
  /** Wheel: dy > 0 is down (notches). */
  z.strictObject({ kind: z.literal("scroll"), dy: z.int().min(-20).max(20) }),
]);
const desktopRemote = z.strictObject({
  id,
  /** Window class (Hyprland class/initialClass; case-insensitive). */
  windowClass: z.string().min(1).max(200),
  name: z.string().min(1).max(40),
  icon: remoteIcon.default("zap"),
  action: remoteAction,
  /** Confirm on the phone before sending (e.g. close/delete). */
  confirm: z.boolean().default(false),
});

const notifications = z.strictObject({
  longCommandSeconds: z.int().min(0).default(60),
  serviceDown: z.boolean().default(true),
  diskFullPercent: z.int().min(50).max(100).default(90),
  pcOffline: z.boolean().default(true),
  grafanaAlerts: z.boolean().default(true),
  siteDown: z.boolean().default(true),
  backupAlerts: z.boolean().default(true),
  /** Silent notification when the PC clipboard changes (with a Copy button). */
  clipboardFromPc: z.boolean().default(true),
  /** When the app comes to the foreground, the phone clipboard is sent to the PC if it changed. */
  clipboardToPc: z.boolean().default(false),
  /** PC whose clipboard is synced; null: the Claude host or the first host with an agent. */
  clipboardHostId: id.nullable().default(null),
  /** Telegram newsletter sent (summary). */
  telegramSent: z.boolean().default(true),
  /** Telegram newsletter needs approval, failed, or the research PC was unreachable. */
  telegramAlerts: z.boolean().default(true),
  /** Incident room: incident resolved / remediation failed (alerts themselves follow their own switches). */
  incidents: z.boolean().default(true),
});

const encryptedSecrets = z.strictObject({
  v: z.literal(1),
  kdf: z.strictObject({
    name: z.literal("argon2id"),
    memoryKiB: z.int().min(8192),
    iterations: z.int().min(1),
    parallelism: z.int().min(1),
    salt: z.base64(),
  }),
  cipher: z.literal("xchacha20-poly1305"),
  nonce: z.base64(),
  ciphertext: z.base64(),
});

export const profileSchema = z
  .strictObject({
    $schema: z.string().optional(),
    format: z.literal("tiphys-profile"),
    schemaVersion: z.int().min(1),
    exportedAt: z.iso.datetime().optional(),
    exportedFrom: z.string().optional(),
    app: app.optional(),
    hosts: z.array(host).optional(),
    keys: z.array(key).optional(),
    claude: claude.optional(),
    integrations: integrations.optional(),
    terminal: terminal.optional(),
    files: files.optional(),
    quickActions: z.array(quickAction).optional(),
    desktopRemotes: z.array(desktopRemote).optional(),
    notifications: notifications.optional(),
    /** Copy of each agent's own settings (hostId → editable part of agent.json). */
    agentConfigs: z.record(id, z.record(z.string(), z.unknown())).optional(),
    encryptedSecrets: encryptedSecrets.nullable().optional(),
  })
  .describe("Tiphys profil dosyası (.tiphys.json)");

export type Profile = z.infer<typeof profileSchema>;

export function profileJsonSchema(): unknown {
  return {
    $id: "https://tiphys.local/schema/tiphys.schema.json",
    ...z.toJSONSchema(profileSchema, { target: "draft-2020-12", io: "input" }),
  };
}
