// Decoys (PLAN.md §15 S-3). Every trigger is a critical `security.trap` notice (push high + the owner's Telegram).
//   token: a decoy service token (tps_…) whose hash is kept in security.traps.tokens; anyone presenting it gets the
//          ordinary 401 and the alarm goes off (server.ts calls ctx.onRejectedToken).
//   file:  a decoy file this agent creates (fake .env backup or SSH key). Reads are seen through the access time:
//          the file is "armed" with atime < mtime, and relatime updates atime on the first read. Checked every 30 s;
//          after a trigger it is re-armed. A noatime mount can't work and is reported. Backup tools that read the
//          home directory will trigger it too.
//   audit: SSH-audited hosts with `traps: true`: the `traps` request returns today's auditd events with key
//          tiphys_trap (a read watch on a decoy file, installed with tools/install-audit.sh --trap).
//   db:    login attempts with a decoy database user name (only present in decoy files) in the logs on Loki.
import { generateKeyPairSync, randomBytes } from "node:crypto";
import { open, readFile, stat, utimes } from "node:fs/promises";
import { basename, dirname, resolve } from "node:path";
import { hashToken, newServiceToken } from "../auth.ts";
import { expandHome } from "../config.ts";
import { AppError } from "../errors.ts";
import { allowedPath } from "../paths.ts";
import type { Ctx } from "../server.ts";
import { knownHostsPath, spawnCapped, sshArgs, type Fetch, type Spawner } from "./collect.ts";

export interface TrapOpts {
  spawner?: Spawner;
  fetch?: Fetch;
  now?: () => number;
  mounts?: () => Promise<string>;
}

export type FileTrapStatus = "armed" | "noatime" | "missing" | "error";

/** Mount options of the filesystem holding `path` (longest mount point prefix) from /proc/mounts text. */
export function mountOptions(mounts: string, path: string): string[] {
  let best = "";
  let opts: string[] = [];
  for (const line of mounts.split("\n")) {
    const f = line.split(" ");
    if (f.length < 4) continue;
    const mp = f[1]!.replace(/\\040/g, " ");
    if ((path === mp || path.startsWith(mp.endsWith("/") ? mp : `${mp}/`)) && mp.length >= best.length) {
      best = mp;
      opts = f[3]!.split(",");
    }
  }
  return opts;
}

/** ausearch --format csv lines → events (serial + time + who + object). */
export function parseAusearchCsv(text: string): { key: string; at: string; who: string; how: string; object: string }[] {
  const out: { key: string; at: string; who: string; how: string; object: string }[] = [];
  for (const line of text.split("\n")) {
    if (!line || line.startsWith("@@") || line.startsWith("NODE,")) continue;
    // NODE,EVENT,DATE,TIME,SERIAL_NUM,EVENT_KIND,SESSION,SUBJ_PRIME,SUBJ_SEC,SUBJ_KIND,ACTION,RESULT,OBJ_PRIME,OBJ_SEC,OBJ_KIND,HOW
    const f = line.split(",");
    if (f.length < 16) continue;
    const [, , date, time, serial] = f;
    if (!date || !time || !serial || !/^\d+$/.test(serial)) continue;
    out.push({ key: `${date} ${time}#${serial}`, at: `${date} ${time}`, who: `${f[7]}/${f[8]}`.slice(0, 80), how: (f[15] ?? "").slice(0, 120), object: (f[12] ?? "").slice(0, 200) });
  }
  return out;
}

function decoyEnv(dbUser: string | null, token: string): string {
  const pw = randomBytes(18).toString("base64url");
  const aws = ["AK", "IA", randomBytes(10).toString("hex").toUpperCase().slice(0, 16)].join("");
  return [
    "# production settings backup — do not commit",
    `DATABASE_URL=postgres://${dbUser ?? "app_backup"}:${pw}@db:5432/app`,
    `AWS_ACCESS_KEY_ID=${aws}`,
    `AWS_SECRET_ACCESS_KEY=${randomBytes(30).toString("base64").slice(0, 40)}`,
    `TIPHYS_TOKEN=${token}`,
    "",
  ].join("\n");
}

function decoyKey(): string {
  const { privateKey } = generateKeyPairSync("ed25519");
  return privateKey.export({ type: "pkcs8", format: "pem" }).toString();
}

export class TrapService {
  #ctx: Ctx;
  #o: TrapOpts;
  /** Armed access time per file trap id. */
  #armed = new Map<string, number>();
  readonly status = new Map<string, { status: FileTrapStatus; lastTriggeredAt: string | null }>();
  /** Per SSH host: did the last `traps` poll work (a host without auditd answers "unavailable"). */
  readonly auditStatus = new Map<string, { status: "ok" | "unavailable" | "error"; at: string }>();
  /** Already reported audit events / Loki lines (bounded). */
  #seen = new Set<string>();
  #lokiFrom: number | null = null;

  constructor(ctx: Ctx, o: TrapOpts = {}) {
    this.#ctx = ctx;
    this.#o = o;
  }

  #now() {
    return this.#o.now?.() ?? Date.now();
  }

  #name() {
    return this.#ctx.store.get().name;
  }

  async #alarm(params: Record<string, string | number>) {
    await this.#ctx.notifier.send({
      key: "security.trap",
      params: { host: this.#name(), agent: this.#name(), ...params },
      link: "tiphys://security/traps",
      priority: "high",
    });
  }

  #remember(k: string): boolean {
    if (this.#seen.has(k)) return false;
    this.#seen.add(k);
    if (this.#seen.size > 5000) this.#seen = new Set([...this.#seen].slice(-2500));
    return true;
  }

  // ---- tokens ----

  /** Server hook: a rejected token that is a decoy raises the alarm (at most once a minute per decoy). */
  onRejectedToken(token: string, info: { ip: string; path: string }) {
    if (!token.startsWith("tps_") && !token.startsWith("tph_")) return;
    const h = hashToken(token);
    const t = this.#ctx.store.get().security.traps.tokens.find((x) => x.tokenHash === h);
    if (!t) return;
    if (!this.#remember(`token|${t.id}|${Math.floor(this.#now() / 60_000)}`)) return;
    void this.#alarm({ trap: "token", name: t.name, from: info.ip.slice(0, 64), path: info.path.slice(0, 120) }).catch(() => {});
  }

  async createToken(name: string): Promise<{ id: string; token: string }> {
    const token = newServiceToken();
    const id = `trap-${randomBytes(4).toString("hex")}`;
    await this.#ctx.store.update((c) => {
      if (c.security.traps.tokens.length >= 20) throw new AppError("agent.security.tooManyTraps", 409);
      c.security.traps.tokens.push({ id, name, tokenHash: hashToken(token), createdAt: new Date(this.#now()).toISOString() });
      return c;
    });
    return { id, token };
  }

  // ---- files ----

  /** Creates a decoy file (never overwrites) inside allowedRoots, arms it and records it. */
  async createFile(path: string, kind: "env" | "sshkey"): Promise<{ id: string; path: string; status: FileTrapStatus }> {
    const cfg = this.#ctx.store.get();
    if (cfg.security.traps.files.length >= 20 || cfg.security.traps.tokens.length >= 20) throw new AppError("agent.security.tooManyTraps", 409);
    const full = resolve(expandHome(path));
    const dir = await allowedPath(cfg, dirname(full));
    const target = resolve(dir, basename(full));
    let content: string;
    let tokenId: string | null = null;
    if (kind === "env") {
      const { id: tid, token } = await this.createToken(`decoy in ${basename(target)}`);
      tokenId = tid;
      content = decoyEnv(cfg.security.traps.dbUsers[0] ?? null, token);
    } else content = decoyKey();
    let fh;
    try {
      fh = await open(target, "wx", 0o600);
    } catch (e) {
      if (tokenId) await this.#dropToken(tokenId);
      throw new AppError((e as NodeJS.ErrnoException).code === "EEXIST" ? "agent.security.trapExists" : "agent.security.trapCreateFailed", 409);
    }
    await fh.writeFile(content);
    await fh.close();
    const id = `file-${randomBytes(4).toString("hex")}`;
    await this.#ctx.store.update((c) => {
      c.security.traps.files.push({ id, path: target, kind, createdAt: new Date(this.#now()).toISOString() });
      return c;
    });
    return { id, path: target, status: await this.#arm(id, target) };
  }

  async #dropToken(id: string) {
    await this.#ctx.store.update((c) => ((c.security.traps.tokens = c.security.traps.tokens.filter((t) => t.id !== id)), c));
  }

  async #arm(id: string, path: string): Promise<FileTrapStatus> {
    const mounts = await (this.#o.mounts ?? (() => readFile("/proc/mounts", "utf8")))().catch(() => "");
    const opts = mountOptions(mounts, path);
    if (opts.includes("noatime")) {
      this.status.set(id, { status: "noatime", lastTriggeredAt: this.status.get(id)?.lastTriggeredAt ?? null });
      return "noatime";
    }
    try {
      // atime one minute before mtime: relatime (and strictatime) update it on the next read.
      const now = this.#now() / 1000;
      await utimes(path, now - 60, now);
      const s = await stat(path);
      this.#armed.set(id, s.atimeMs);
      this.status.set(id, { status: "armed", lastTriggeredAt: this.status.get(id)?.lastTriggeredAt ?? null });
      return "armed";
    } catch {
      this.status.set(id, { status: "missing", lastTriggeredAt: this.status.get(id)?.lastTriggeredAt ?? null });
      return "missing";
    }
  }

  async removeFile(id: string) {
    const f = this.#ctx.store.get().security.traps.files.find((x) => x.id === id);
    if (!f) throw new AppError("agent.security.trapNotFound", 404);
    // The file itself stays (the user deletes it); only watching stops.
    await this.#ctx.store.update((c) => ((c.security.traps.files = c.security.traps.files.filter((x) => x.id !== id)), c));
    this.#armed.delete(id);
    this.status.delete(id);
  }

  async removeToken(id: string) {
    if (!this.#ctx.store.get().security.traps.tokens.some((t) => t.id === id)) throw new AppError("agent.security.trapNotFound", 404);
    await this.#dropToken(id);
  }

  async checkFiles() {
    for (const f of this.#ctx.store.get().security.traps.files) {
      const prev = this.status.get(f.id);
      const armed = this.#armed.get(f.id);
      const s = await stat(f.path).catch(() => null);
      if (!s) {
        // Missing (also when the agent starts and finds it gone): one alarm until it comes back.
        if (prev?.status !== "missing") {
          this.status.set(f.id, { status: "missing", lastTriggeredAt: prev?.lastTriggeredAt ?? null });
          this.#armed.delete(f.id);
          await this.#alarm({ trap: "fileMissing", path: f.path });
        }
        continue;
      }
      if (armed === undefined) {
        // First look after start, or the file is back: arm it without an alarm.
        await this.#arm(f.id, f.path);
        continue;
      }
      if (s.atimeMs > armed + 500) {
        const at = new Date(this.#now()).toISOString();
        this.status.set(f.id, { status: "armed", lastTriggeredAt: at });
        await this.#alarm({ trap: "file", path: f.path });
        await this.#arm(f.id, f.path);
      }
    }
  }

  // ---- audited hosts (auditd) ----

  /**
   * The audited host returns its last 10 minutes of tiphys_trap events; each is announced once (one alarm per host and
   * poll, with a count, so a flood of reads doesn't become a flood of notifications).
   */
  async checkAudit() {
    const cfg = this.#ctx.store.get();
    const known = knownHostsPath(this.#ctx.store.path);
    for (const h of cfg.security.hosts) {
      if (!h.traps || h.source.kind !== "ssh") continue;
      const args = sshArgs(h.source, known, "report");
      args.splice(args.length - 1, 1, "traps");
      const r = await (this.#o.spawner ?? spawnCapped)("ssh", args, { timeoutMs: 60_000, maxBytes: 1 << 20 }).catch(() => null);
      const at = new Date(this.#now()).toISOString();
      if (!r || r.code !== 0) {
        this.auditStatus.set(h.id, { status: r?.code === 3 ? "unavailable" : "error", at });
        continue;
      }
      this.auditStatus.set(h.id, { status: "ok", at });
      const fresh = parseAusearchCsv(r.stdout).filter((e) => this.#remember(`audit|${h.id}|${e.key}`));
      if (!fresh.length) continue;
      const e = fresh[fresh.length - 1]!;
      await this.#alarm({ trap: "audit", host: h.name, who: e.who, how: e.how, object: e.object, at: e.at, count: fresh.length });
    }
  }

  // ---- decoy database users in the logs (Loki) ----

  async checkDbUsers(lokiUrl: () => Promise<string>) {
    const users = this.#ctx.store.get().security.traps.dbUsers;
    if (!users.length) return;
    const end = this.#now() * 1_000_000;
    // Two minutes of overlap: lines reach Loki late; #seen keeps them from being announced twice.
    const start = (this.#lokiFrom ?? end - 10 * 60 * 1e9) - 2 * 60 * 1e9;
    const alt = users.join("|");
    const query = `{host=~".+"} |~ "(?i)(password authentication failed|authentication failed|role .* does not exist|access denied).*(${alt})"`;
    const base = await lokiUrl();
    const f = this.#o.fetch ?? fetch;
    const res = await f(`${base}/loki/api/v1/query_range?${new URLSearchParams({ query, start: String(start), end: String(end), limit: "200", direction: "forward" })}`, {
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) throw new AppError("agent.security.lokiFailed", 502, { status: res.status });
    const data = (await res.json()) as { data?: { result?: Array<{ stream?: Record<string, string>; values?: [string, string][] }> } };
    this.#lokiFrom = end + 1;
    for (const s of data.data?.result ?? []) {
      for (const [ts, line] of s.values ?? []) {
        const user = users.find((u) => line.includes(u));
        if (!user || !this.#remember(`db|${ts}|${s.stream?.container ?? ""}`)) continue;
        await this.#alarm({ trap: "db", user, host: String(s.stream?.host ?? "?").slice(0, 100), stream: String(s.stream?.container ?? s.stream?.unit ?? "").slice(0, 80) });
      }
    }
  }

  list() {
    const c = this.#ctx.store.get().security.traps;
    return {
      tokens: c.tokens.map(({ tokenHash: _, ...t }) => t),
      files: c.files.map((f) => ({ ...f, ...(this.status.get(f.id) ?? { status: "missing" as const, lastTriggeredAt: null }) })),
      dbUsers: c.dbUsers,
      auditHosts: this.#ctx.store.get().security.hosts.filter((h) => h.traps).map((h) => ({ id: h.id, ...(this.auditStatus.get(h.id) ?? { status: "pending", at: null }) })),
    };
  }
}
