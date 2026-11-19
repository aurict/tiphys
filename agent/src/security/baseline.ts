// Baseline and change detection (PLAN.md §15, S-1). A snapshot keeps only what matters for "something changed that
// shouldn't have": exposed ports, login accounts, passwords, sudoers, SSH keys, scheduled jobs, autostart, sshd
// settings, risky containers, SUID files and protection services. The first good report becomes the baseline
// silently; later differences stay listed until the user accepts the current state as the new baseline.
import type { SecurityReport } from "./report.ts";
import { exposures } from "./rules.ts";

export type Category =
  | "ports"
  | "users"
  | "passwords"
  | "sudoers"
  | "authKeys"
  | "cron"
  | "timers"
  | "autostart"
  | "sshd"
  | "containers"
  | "suid"
  | "services";

/** Item id → value (hash, mode, setting…); a missing category means "not known in this report" (e.g. needs root). */
export type Snapshot = Partial<Record<Category, Record<string, string>>>;

export interface Change {
  /** `category|item` */
  id: string;
  category: Category;
  item: string;
  kind: "added" | "removed" | "changed";
  firstSeenAt: string;
}

/** Changes that warrant a high-priority notification. */
export const CRITICAL_CATEGORIES: ReadonlySet<Category> = new Set(["users", "passwords", "sudoers", "authKeys", "ports", "sshd"]);

const SSHD_KEYS = [
  "passwordauthentication",
  "permitrootlogin",
  "permitemptypasswords",
  "pubkeyauthentication",
  "kbdinteractiveauthentication",
  "allowusers",
  "allowgroups",
  "authorizedkeysfile",
  "listenaddress",
  "port",
  "allowtcpforwarding",
  "gatewayports",
  "permittunnel",
];

const fromHashed = (l: { path: string; sha256: string }[]) => Object.fromEntries(l.map((f) => [f.path, f.sha256]));

export function snapshotOf(r: SecurityReport, carriedSuid: SecurityReport["suid"] = null): Snapshot {
  const s: Snapshot = {};
  if (r.listen) s.ports = Object.fromEntries(exposures(r).map((e) => [`${e.proto}/${e.port}`, "exposed"]));
  s.users = Object.fromEntries(r.users.map((u) => [u.name, `${u.uid}:${u.shell}`]));
  if (r.passwords) s.passwords = Object.fromEntries(r.passwords.map((p) => [p.name, p.status]));
  if (r.sudoers) s.sudoers = fromHashed(r.sudoers);
  s.authKeys = Object.fromEntries(r.authKeys.map((k) => [`${k.user} ${k.fingerprint}`, k.comment]));
  s.cron = fromHashed(r.cron);
  s.timers = Object.fromEntries(r.timers.map((t) => [`${t.scope} ${t.name}`, t.unit]));
  if (r.autostart) s.autostart = fromHashed(r.autostart);
  if (r.sshd) s.sshd = Object.fromEntries(SSHD_KEYS.filter((k) => r.sshd!.settings[k]).map((k) => [k, r.sshd!.settings[k]!.join(" ")]));
  if (r.docker) {
    const risky: Record<string, string> = {};
    for (const c of r.docker.containers) {
      const flags = [
        c.privileged && "privileged",
        c.mounts.some((m) => /(^|\/)docker\.sock$/.test(m.source)) && "docker.sock",
        c.pidMode === "host" && "pid=host",
        c.networkMode === "host" && "net=host",
        c.capAdd.length > 0 && `cap+${[...c.capAdd].sort().join(",")}`,
      ].filter(Boolean);
      if (flags.length) risky[c.name] = flags.join(" ");
    }
    s.containers = risky;
  }
  const suid = r.suid ?? carriedSuid;
  if (suid) s.suid = Object.fromEntries(suid.map((f) => [f.path, `${f.mode} ${f.owner}`]));
  s.services = Object.fromEntries(
    ["auditd", "apparmor", "ufw", "firewalld", "nftables", "fail2ban"].filter((n) => r.services[n]).map((n) => [n, r.services[n]!.active]),
  );
  return s;
}

/**
 * Differences baseline → current. Categories missing on either side are skipped (unknown ≠ removed). `previous`
 * keeps the first-seen time of changes that were already listed.
 */
export function diff(baseline: Snapshot, current: Snapshot, previous: Change[] = [], now = new Date()): Change[] {
  const prev = new Map(previous.map((c) => [c.id, c]));
  const out: Change[] = [];
  // A category this report couldn't read (docker restarting, a failed command) keeps the changes listed before.
  for (const c of previous) if (!current[c.category] && baseline[c.category]) out.push(c);
  for (const category of Object.keys(current) as Category[]) {
    const b = baseline[category];
    const c = current[category];
    if (!b || !c) continue;
    const push = (item: string, kind: Change["kind"]) => {
      const id = `${category}|${item}`;
      const old = prev.get(id);
      out.push({ id, category, item, kind, firstSeenAt: old && old.kind === kind ? old.firstSeenAt : now.toISOString() });
    };
    for (const [k, v] of Object.entries(c)) {
      if (!(k in b)) push(k, "added");
      else if (b[k] !== v) push(k, "changed");
    }
    for (const k of Object.keys(b)) if (!(k in c)) push(k, "removed");
  }
  return out.sort((a, b) => a.id.localeCompare(b.id));
}

/** Merges a fresh snapshot into the stored baseline for categories the baseline doesn't know yet (e.g. first SUID scan). */
export function fillBaseline(baseline: Snapshot, current: Snapshot): Snapshot {
  const out = { ...baseline };
  for (const k of Object.keys(current) as Category[]) if (!out[k]) out[k] = current[k];
  return out;
}
