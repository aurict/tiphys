// Parses the sectioned output of helpers/audit.sh (PLAN.md §15) into a typed report. The same parser serves all three
// sources (local, restricted SSH key, another agent's /v1/security/raw), so remote hosts never send structured data
// the agent would have to trust: they send text, and this file decides what it means. Unknown lines are ignored.

import { defaultDeny, parseRuleset, probe } from "./firewall.ts";

export type Scope = "loopback" | "tailscale" | "wildcard" | "private" | "linklocal" | "public";

export interface Listener {
  proto: "tcp" | "udp";
  addr: string;
  iface: string | null;
  port: number;
  scope: Scope;
  process: string | null;
  /** For wildcard/public listeners when the host firewall is known: would a new outside connection get through? */
  firewall?: "open" | "filtered";
}

export interface Container {
  name: string;
  image: string;
  imageId: string;
  privileged: boolean;
  networkMode: string;
  pidMode: string;
  readOnlyRootfs: boolean;
  user: string;
  capAdd: string[];
  mounts: { source: string; destination: string; rw: boolean }[];
  ports: { hostIp: string; hostPort: number; container: string }[];
  project: string | null;
  service: string | null;
}

export interface Image {
  id: string;
  tags: string[];
  digests: string[];
  size: number;
  created: string;
}

export interface HashedFile {
  path: string;
  sha256: string;
}

export interface SecurityReport {
  version: number;
  mode: "report" | "report-full";
  root: boolean;
  meta: { hostname: string; kernel: string; arch: string; os: string; uptimeSec: number | null; time: string | null; ipv6Global: number | null };
  listen: Listener[] | null;
  /** Host firewall from nftables (null = not readable, e.g. without root). */
  firewall: { source: "nft"; defaultDeny: boolean; inputChains: number } | null;
  sshd: { mode: "effective" | "config"; settings: Record<string, string[]> } | null;
  users: { name: string; uid: number; gid: number; shell: string }[];
  /** Accounts with a usable password: "empty" or "set" (locked ones are not listed). null = needs root. */
  passwords: { name: string; status: "empty" | "set" }[] | null;
  groups: Record<string, string[]>;
  sudoers: HashedFile[] | null;
  authKeys: { user: string; path: string; bits: number; fingerprint: string; comment: string; type: string }[];
  cron: HashedFile[];
  timers: { scope: "system" | "user"; name: string; unit: string }[];
  autostart: HashedFile[] | null;
  updates: {
    pending: number | null;
    security: number | null;
    unattended: boolean | null;
    listsUpdatedAt: string | null;
    rebootRequiredSince: string | null;
  };
  services: Record<string, { active: string; enabled: string }>;
  sysctl: Record<string, string>;
  logins: { user: string; tty: string; from: string; raw: string }[];
  docker: { version: string; containers: Container[]; images: Image[] } | null;
  suid: { mode: string; owner: string; path: string }[] | null;
  worldWritable: { mode: string; owner: string; path: string }[] | null;
  /** Agent's own files (local source only): path + octal mode. */
  agentFiles: { path: string; mode: string }[] | null;
  /** Sections the script could not produce (e.g. "passwords" without root). */
  unavailable: string[];
}

export class ReportParseError extends Error {}

/** Splits the output into sections; throws if it isn't an audit report. */
export function splitSections(text: string): { version: number; mode: string; sections: Map<string, string[]>; complete: boolean } {
  const lines = text.split("\n");
  const head = /^@@tiphys-audit (\d+) (report|report-full)$/.exec(lines.find((l) => l.trim() !== "")?.trim() ?? "");
  if (!head) throw new ReportParseError("not an audit report");
  const sections = new Map<string, string[]>();
  let cur: string[] | null = null;
  let complete = false;
  for (const raw of lines) {
    const line = raw.replace(/\r$/, "");
    const s = /^@@section ([a-z]+)$/.exec(line);
    if (s) {
      cur = [];
      sections.set(s[1]!, cur);
      continue;
    }
    if (line === "@@end") {
      complete = true;
      cur = null;
      continue;
    }
    if (cur && line.trim() !== "") cur.push(line);
  }
  return { version: Number(head[1]), mode: head[2]!, sections, complete };
}

const isUnavailable = (lines: string[] | undefined) => !lines || lines.some((l) => l.startsWith("@@unavailable"));

function int(v: string | undefined): number | null {
  if (v === undefined || !/^-?\d+$/.test(v)) return null;
  return Number(v);
}

export function classifyAddress(addr: string, iface: string | null): Scope {
  const a = addr.replace(/^\[|\]$/g, "").toLowerCase();
  if (a === "*" || a === "0.0.0.0" || a === "::") return "wildcard";
  if (iface === "tailscale0") return "tailscale";
  if (a === "::1" || /^127\./.test(a)) return "loopback";
  const m = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/.exec(a);
  if (m) {
    const [b1, b2] = [Number(m[1]), Number(m[2])];
    if (b1 === 100 && b2 >= 64 && b2 <= 127) return "tailscale";
    if (b1 === 10 || (b1 === 172 && b2 >= 16 && b2 <= 31) || (b1 === 192 && b2 === 168)) return "private";
    if (b1 === 169 && b2 === 254) return "linklocal";
    return "public";
  }
  if (a.startsWith("fd7a:115c:a1e0:")) return "tailscale";
  if (/^fe[89ab]/.test(a)) return "linklocal";
  if (/^f[cd]/.test(a)) return "private";
  return "public";
}

/** "0.0.0.0:22", "[::]:22", "*:1716", "100.1.2.3%tailscale0:443", "[fd7a::1]%tailscale0:443", "[fe80::1]%eth0:546". */
export function parseLocalAddress(s: string): { addr: string; iface: string | null; port: number } | null {
  const m = /^(.*):(\d+|\*)$/.exec(s);
  if (!m || m[2] === "*") return null;
  let host = m[1]!;
  let iface: string | null = null;
  const pct = /^(.*)%([A-Za-z0-9_.-]+)$/.exec(host);
  if (pct) {
    host = pct[1]!;
    iface = pct[2]!;
  }
  return { addr: host.replace(/^\[|\]$/g, ""), iface, port: Number(m[2]) };
}

export function parseListen(lines: string[]): Listener[] {
  const out: Listener[] = [];
  const seen = new Set<string>();
  for (const l of lines) {
    const f = l.trim().split(/\s+/);
    if (f.length < 5 || (f[0] !== "tcp" && f[0] !== "udp")) continue;
    const local = parseLocalAddress(f[4]!);
    if (!local) continue;
    const proc = /users:\(\("([^"]{1,64})"/.exec(l)?.[1] ?? null;
    const key = `${f[0]}|${local.addr}|${local.iface}|${local.port}`;
    if (seen.has(key)) continue;
    seen.add(key);
    out.push({ proto: f[0], ...local, scope: classifyAddress(local.addr, local.iface), process: proc });
  }
  return out;
}

/**
 * sshd uses the first value it sees for most keywords. In config mode the files are given in order; an `Include` in
 * the main file pulls in the drop-ins at that point. Everything after the first `Match` line is conditional → ignored.
 */
export function parseSshd(lines: string[]): SecurityReport["sshd"] {
  if (isUnavailable(lines)) return null;
  const mode = lines.includes("@@mode effective") ? "effective" : "config";
  const settings: Record<string, string[]> = {};
  const multi = new Set(["listenaddress", "port", "allowusers", "allowgroups", "denyusers", "authorizedkeysfile"]);
  if (mode === "effective") {
    for (const l of lines) {
      if (l.startsWith("@@")) continue;
      const [k, ...rest] = l.trim().split(/\s+/);
      if (!k) continue;
      const key = k.toLowerCase();
      (settings[key] ??= []).push(rest.join(" "));
    }
    return { mode, settings };
  }
  const files: { path: string; lines: string[] }[] = [];
  for (const l of lines) {
    const f = /^@@file (.+)$/.exec(l);
    if (f) files.push({ path: f[1]!, lines: [] });
    else if (!l.startsWith("@@") && files.length) files[files.length - 1]!.lines.push(l);
  }
  const main = files.find((f) => f.path === "/etc/ssh/sshd_config");
  const dropins = files.filter((f) => f !== main);
  const order: string[] = [];
  let includedDropins = false;
  if (main) {
    for (const l of main.lines) {
      if (/^\s*include\s/i.test(l)) {
        if (!includedDropins) for (const d of dropins) order.push(...d.lines);
        includedDropins = true;
      } else order.push(l);
    }
  }
  if (!includedDropins) order.push(...dropins.flatMap((d) => d.lines));
  for (const l of order) {
    const m = /^\s*([A-Za-z]+)\s*(?:=\s*|\s+)(.*?)\s*$/.exec(l);
    if (!m) continue;
    const key = m[1]!.toLowerCase();
    if (key === "match") break;
    if (multi.has(key)) (settings[key] ??= []).push(m[2]!);
    else if (!(key in settings)) settings[key] = [m[2]!.toLowerCase()];
  }
  return { mode, settings };
}

function hashed(lines: string[]): HashedFile[] {
  const out: HashedFile[] = [];
  for (const l of lines) {
    const m = /^([a-f0-9]{64})\s+\*?(.+)$/.exec(l.trim());
    if (m) out.push({ sha256: m[1]!, path: m[2]! });
  }
  return out;
}

function kv(lines: string[]): Record<string, string> {
  const out: Record<string, string> = {};
  for (const l of lines) {
    if (l.startsWith("@@")) continue;
    const i = l.indexOf(" ");
    if (i > 0) out[l.slice(0, i)] = l.slice(i + 1).trim();
    else out[l.trim()] = "";
  }
  return out;
}

const epochIso = (v: string | undefined) => {
  const n = int(v);
  return n && n > 0 ? new Date(n * 1000).toISOString() : null;
};

function parseDocker(lines: string[] | undefined): SecurityReport["docker"] {
  if (isUnavailable(lines) || !lines) return null;
  const version = lines.find((l) => l.startsWith("@@version "))?.slice(10).trim() ?? "";
  const containers: Container[] = [];
  const images: Image[] = [];
  for (const l of lines) {
    const f = l.split("|");
    if (f[0] === "c" && f.length >= 14) {
      const noValue = (s: string) => (s === "<no value>" || s === "" ? null : s);
      containers.push({
        name: f[1]!.replace(/^\//, ""),
        image: f[2]!,
        imageId: f[3]!,
        privileged: f[4] === "true",
        networkMode: f[5]!,
        pidMode: f[6]!,
        readOnlyRootfs: f[7] === "true",
        user: f[8]!,
        capAdd: f[9] ? f[9].split(",").filter(Boolean) : [],
        mounts: f[10]!
          .split(";")
          .filter(Boolean)
          .map((m) => {
            const p = m.split(":");
            return { source: p.slice(0, -2).join(":"), destination: p[p.length - 2] ?? "", rw: p[p.length - 1] === "true" };
          }),
        ports: f[11]!
          .split(";")
          .filter(Boolean)
          .flatMap((p) => {
            const m = /^(.*):(\d+)->(.+)$/.exec(p);
            return m ? [{ hostIp: m[1]!, hostPort: Number(m[2]), container: m[3]! }] : [];
          }),
        project: noValue(f[12]!),
        service: noValue(f.slice(13).join("|")),
      });
    } else if (f[0] === "i" && f.length >= 6) {
      images.push({ id: f[1]!, tags: f[2]!.split(",").filter(Boolean), digests: f[3]!.split(",").filter(Boolean), size: Number(f[4]) || 0, created: f[5]! });
    }
  }
  return { version, containers, images };
}

function permList(lines: string[] | undefined) {
  if (isUnavailable(lines) || !lines) return null;
  return lines.flatMap((l) => {
    const m = /^(\d{3,4}) (\S+) (\/.*)$/.exec(l);
    return m ? [{ mode: m[1]!, owner: m[2]!, path: m[3]! }] : [];
  });
}

/** Listeners plus, when the nft ruleset is there, whether outside connections to wildcard/public ones get through. */
function listenAndFirewall(sections: Map<string, string[]>, ipv6Global: number | null): Pick<SecurityReport, "listen" | "firewall"> {
  const listen = isUnavailable(sections.get("listen")) ? null : parseListen(sections.get("listen") ?? []);
  const nft = sections.get("nft");
  const rs = !nft || isUnavailable(nft) ? null : parseRuleset(nft.join(""));
  if (!rs) return { listen, firewall: null };
  for (const l of listen ?? []) {
    if (l.scope !== "wildcard" && l.scope !== "public") continue;
    const v6 = l.addr.includes(":") || l.addr === "*";
    // A wildcard IPv6 socket usually takes IPv4 too; IPv6 itself only counts with a global IPv6 address.
    const families: ("ip" | "ip6")[] = [];
    if (!v6 || l.addr === "*" || l.addr === "::") families.push("ip");
    if (v6 && (ipv6Global ?? 1) > 0) families.push("ip6");
    l.firewall = families.some((f) => probe(rs, l.proto, l.port, f) === "open") ? "open" : "filtered";
  }
  return { listen, firewall: { source: "nft", defaultDeny: defaultDeny(rs), inputChains: rs.base.length } };
}

export function parseReport(text: string): SecurityReport {
  const { version, mode, sections, complete } = splitSections(text);
  if (!complete) throw new ReportParseError("truncated report");
  const sec = (n: string) => sections.get(n) ?? [];
  const meta = kv(sec("meta"));
  const unavailable = [...sections.entries()].filter(([, l]) => l.some((x) => x.startsWith("@@unavailable"))).map(([n]) => n);
  const upd = kv(sec("updates"));
  const services: Record<string, { active: string; enabled: string }> = {};
  for (const l of sec("services")) {
    const [n, active = "", enabled = ""] = l.trim().split(/\s+/);
    if (n) services[n] = { active, enabled };
  }
  const groups: Record<string, string[]> = {};
  for (const l of sec("groups")) {
    const [g, members = ""] = l.trim().split(/\s+/);
    if (g) groups[g] = members.split(",").filter(Boolean);
  }
  return {
    version,
    mode: mode as SecurityReport["mode"],
    root: meta.root === "1",
    meta: {
      hostname: meta.hostname ?? "",
      kernel: meta.kernel ?? "",
      arch: meta.arch ?? "",
      os: meta.os ?? "",
      uptimeSec: meta.uptime ? Math.round(Number(meta.uptime)) || null : null,
      time: meta.time ?? null,
      ipv6Global: int(meta.ipv6Global),
    },
    ...listenAndFirewall(sections, int(meta.ipv6Global)),
    sshd: parseSshd(sec("sshd")),
    users: sec("users").flatMap((l) => {
      const [name, uid, gid, shell] = l.trim().split(/\s+/);
      return name && int(uid) !== null ? [{ name, uid: int(uid)!, gid: int(gid) ?? -1, shell: shell ?? "" }] : [];
    }),
    passwords: isUnavailable(sections.get("passwords"))
      ? null
      : sec("passwords").flatMap((l) => {
          const [name, status] = l.trim().split(/\s+/);
          return name && (status === "empty" || status === "set") ? [{ name, status: status as "empty" | "set" }] : [];
        }),
    groups,
    sudoers: isUnavailable(sections.get("sudoers")) ? null : hashed(sec("sudoers")),
    authKeys: sec("authkeys").flatMap((l) => {
      const m = /^(\S+) (\S+) (\d+) (\S+) (.*?) ?\(([A-Z0-9-]+)\)$/.exec(l.trim());
      return m ? [{ user: m[1]!, path: m[2]!, bits: Number(m[3]), fingerprint: m[4]!, comment: m[5]!, type: m[6]! }] : [];
    }),
    cron: hashed(sec("cron")),
    timers: sec("timers").flatMap((l) => {
      const [scope, name, unit] = l.trim().split(/\s+/);
      return (scope === "system" || scope === "user") && name ? [{ scope: scope as "system" | "user", name, unit: unit ?? "" }] : [];
    }),
    autostart: isUnavailable(sections.get("autostart")) ? null : hashed(sec("autostart")),
    updates: {
      pending: int(upd.pending),
      security: int(upd.security),
      unattended: upd.unattended === undefined ? null : upd.unattended === "1",
      listsUpdatedAt: epochIso(upd.listsUpdated),
      rebootRequiredSince: upd.rebootRequired && upd.rebootRequired !== "no" ? epochIso(upd.rebootRequired) ?? new Date(0).toISOString() : null,
    },
    services,
    sysctl: kv(sec("sysctl")),
    logins: isUnavailable(sections.get("logins"))
      ? []
      : sec("logins").map((l) => {
          const f = l.trim().split(/\s+/);
          return { user: f[0] ?? "", tty: f[1] ?? "", from: f[2] ?? "", raw: l.trim().slice(0, 200) };
        }),
    docker: parseDocker(sections.get("docker")),
    suid: sections.has("suid") ? permList(sections.get("suid")) : null,
    worldWritable: sections.has("worldwritable") ? permList(sections.get("worldwritable")) : null,
    agentFiles: sections.has("agentfiles")
      ? sec("agentfiles").flatMap((l) => {
          const m = /^(\d{3,4}) (\/.*)$/.exec(l);
          return m ? [{ mode: m[1]!, path: m[2]! }] : [];
        })
      : null,
    unavailable,
  };
}
