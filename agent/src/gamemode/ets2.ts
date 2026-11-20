// Euro Truck Simulator 2 telemetry for Game mode (PLAN.md §19).
// - Plugin: truckermudgeon/scs-sdk-plugin v1.12.1 (MIT; the Linux/macOS port of RenCloud's scs-sdk-plugin), pinned by
//   SHA-256 (release zip and the .so inside). Installed into <game>/bin/linux_x64/plugins/.
// - It writes RenCloud's shared-memory layout, revision 12 (scs-telemetry/inc/scs-telemetry-common.hpp at v1.12.1),
//   to POSIX shm /SCSTelemetry. Only the fields of the contract's truck message are read, at fixed offsets
//   (offsets checked with offsetof() on the header compiled for x86_64 Linux). Another revision → "unsupported".
// - Flatpak Steam has a private /dev/shm: /dev/shm/SCSTelemetry if present, else /proc/<eurotrucks2 pid>/root/dev/shm/…
//   (readable for a same-user process).
// - Nothing is written to logs: job/city names are game content only sent on the feed.
import { createHash } from "node:crypto";
import { mkdir, open, readdir, readFile, rename, rm, stat, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { inflateRawSync } from "node:zlib";
import { AppError } from "../errors.ts";

export const LAYOUT_REVISION = 12;
export const PLUGIN = {
  version: "1.12.1",
  url: "https://github.com/truckermudgeon/scs-sdk-plugin/releases/download/v1.12.1/build-ubuntu-latest.zip",
  zipSha256: "ac2f9871e2fa14edbf6c6c9c408fada04376545bdf83838d9fb59652e9b50a7e",
  file: "libscs-telemetry.so",
  soSha256: "ca18a9b32b99c79942f5cdd35e0236b070a5ff10fe3d17b3edf8ac2436b2aecc",
} as const;
export const GAME_BINARY = "eurotrucks2";
const GAME_FOLDER = "Euro Truck Simulator 2";
const SHM_NAME = "SCSTelemetry";

/** Byte offsets in scsTelemetryMap_t (revision 12). */
export const OFF = {
  sdkActive: 0, paused: 4, revision: 40, game: 52,
  timeAbs: 64, gears: 68, timeAbsDelivery: 88,
  restStop: 500, gearDashboard: 508,
  scale: 700, fuelCapacity: 704, engineRpmMax: 740,
  speed: 948, engineRpm: 952, cruiseSpeed: 988, fuel: 1000, fuelRange: 1008,
  wearEngine: 1036, wearTransmission: 1040, wearCabin: 1044, wearChassis: 1048, wearWheels: 1052,
  routeDistance: 1060, routeTime: 1064, speedLimit: 1068, jobCargoDamage: 1468,
  parkBrake: 1566, blinkerLeft: 1578, blinkerRight: 1579, lowBeam: 1583, highBeam: 1584, beacon: 1585,
  x: 2200, z: 2216, heading: 2224,
  cargo: 2620, cityDst: 2748, citySrc: 3004,
  fineOffence: 3436, ferryTarget: 3532, trainTarget: 3788,
  jobIncome: 4000, cancelPenalty: 4200, deliveredRevenue: 4208, fineAmount: 4216, tollAmount: 4224, ferryAmount: 4232, trainAmount: 4240,
  onJob: 4300, jobCancelled: 4302, jobDelivered: 4303, fined: 4304, tollgate: 4305, ferry: 4306, train: 4307,
} as const;
/** Bytes read per poll (everything up to the special-events zone; the trailers aren't used). */
export const READ_BYTES = 4400;
const STR = 64;

export type TruckState = "none" | "menu" | "paused" | "driving";
/** Why there is no telemetry (state "none"): game not running, running without the plugin's shared memory, other layout. */
export type NoneReason = "noGame" | "noPlugin" | "unsupported";

export interface TruckMessage {
  type: "truck";
  state: TruckState;
  at: number;
  [k: string]: unknown;
}

/** Everything read from one sample, including the event fields (not all are sent). */
export interface Sample {
  telemetry: "ok" | "unsupported" | "none";
  msg: TruckMessage;
  /** Raw values for event derivation (absent unless telemetry is ok). */
  ev?: {
    flags: Record<"jobCancelled" | "jobDelivered" | "fined" | "tollgate" | "ferry" | "train", boolean>;
    amounts: { cancel: number; delivered: number; fine: number; toll: number; ferry: number; train: number };
    fineOffence: string;
    ferryTarget: string;
    trainTarget: string;
    currency: string;
    fuelRatio: number | null;
    restStop: number;
  };
}

function str(b: Buffer, off: number, len = STR): string {
  const s = b.subarray(off, off + len);
  const end = s.indexOf(0);
  return s.subarray(0, end === -1 ? len : end).toString("utf8");
}

const round = (v: number, d = 2) => Math.round(v * 10 ** d) / 10 ** d;

/** One shared-memory sample → the contract's truck message (+ event fields). `running`: the game process exists. */
export function parseTelemetry(buf: Buffer | null, running: boolean, at = Date.now()): Sample {
  if (!running) return { telemetry: "none", msg: { type: "truck", state: "none", reason: "noGame", at } };
  if (!buf || buf.length < READ_BYTES) return { telemetry: "none", msg: { type: "truck", state: "none", reason: "noPlugin", at } };
  const d = new DataView(buf.buffer, buf.byteOffset, buf.byteLength);
  const u8 = (o: number) => d.getUint8(o) !== 0;
  const u32 = (o: number) => d.getUint32(o, true);
  const i32 = (o: number) => d.getInt32(o, true);
  const f32 = (o: number) => d.getFloat32(o, true);
  const f64 = (o: number) => d.getFloat64(o, true);
  const i64 = (o: number) => Number(d.getBigInt64(o, true));
  const u64 = (o: number) => Number(d.getBigUint64(o, true));
  // The plugin clears sdkActive and the revision when the game shuts the SDK down.
  if (!u8(OFF.sdkActive)) return { telemetry: "none", msg: { type: "truck", state: "menu", at } };
  if (u32(OFF.revision) !== LAYOUT_REVISION) return { telemetry: "unsupported", msg: { type: "truck", state: "none", reason: "unsupported", at } };
  const gameTime = u32(OFF.timeAbs);
  // Paused before a profile is loaded (no game time yet) = main menu.
  const state: TruckState = u8(OFF.paused) ? (gameTime === 0 ? "menu" : "paused") : "driving";
  const currency = u32(OFF.game) === 2 ? "USD" : "EUR";
  const fuel = f32(OFF.fuel);
  const fuelCap = f32(OFF.fuelCapacity);
  const onJob = u8(OFF.onJob);
  const deadline = u32(OFF.timeAbsDelivery);
  const speedLimit = f32(OFF.speedLimit);
  const navDistance = f32(OFF.routeDistance);
  const navTime = f32(OFF.routeTime);
  const restStop = i32(OFF.restStop);
  // Time compression (game s per real s, 19 by default; ~3 on ferries/trains). Absent when the game reports none.
  const timeScale = f32(OFF.scale);
  const msg: TruckMessage = {
    type: "truck",
    state,
    at,
    speed: round(f32(OFF.speed)),
    speedLimit: speedLimit > 0 ? round(speedLimit) : null,
    rpm: Math.round(f32(OFF.engineRpm)),
    rpmMax: Math.round(f32(OFF.engineRpmMax)),
    gear: i32(OFF.gearDashboard),
    gears: u32(OFF.gears),
    fuel: round(fuel, 1),
    fuelCap: round(fuelCap, 1),
    fuelRange: Math.round(f32(OFF.fuelRange)),
    cruise: round(f32(OFF.cruiseSpeed)),
    parkingBrake: u8(OFF.parkBrake),
    lowBeam: u8(OFF.lowBeam),
    highBeam: u8(OFF.highBeam),
    beacon: u8(OFF.beacon),
    blinkerL: u8(OFF.blinkerLeft),
    blinkerR: u8(OFF.blinkerRight),
    wear: round(Math.max(...[OFF.wearEngine, OFF.wearTransmission, OFF.wearCabin, OFF.wearChassis, OFF.wearWheels].map(f32)), 3),
    cargoDamage: onJob ? round(f32(OFF.jobCargoDamage), 3) : null,
    x: round(f64(OFF.x)),
    z: round(f64(OFF.z)),
    heading: round(f64(OFF.heading), 4),
    gameTime,
    ...(timeScale > 0 && timeScale < 1000 ? { timeScale: round(timeScale) } : {}),
    restMinutes: restStop,
    job: onJob
      ? { from: str(buf, OFF.citySrc), to: str(buf, OFF.cityDst), cargo: str(buf, OFF.cargo), income: u64(OFF.jobIncome), currency, deadlineGameTime: deadline === 0 || deadline === 0xffffffff ? null : deadline }
      : null,
    nav: navDistance > 0 || navTime > 0 ? { distance: Math.round(navDistance), time: Math.round(navTime) } : null,
  };
  return {
    telemetry: "ok",
    msg,
    ev: {
      flags: { jobCancelled: u8(OFF.jobCancelled), jobDelivered: u8(OFF.jobDelivered), fined: u8(OFF.fined), tollgate: u8(OFF.tollgate), ferry: u8(OFF.ferry), train: u8(OFF.train) },
      amounts: { cancel: i64(OFF.cancelPenalty), delivered: i64(OFF.deliveredRevenue), fine: i64(OFF.fineAmount), toll: i64(OFF.tollAmount), ferry: i64(OFF.ferryAmount), train: i64(OFF.trainAmount) },
      fineOffence: str(buf, OFF.fineOffence, 32),
      ferryTarget: str(buf, OFF.ferryTarget),
      trainTarget: str(buf, OFF.trainTarget),
      currency,
      fuelRatio: fuelCap > 0 ? fuel / fuelCap : null,
      restStop,
    },
  };
}

export interface TruckEvent {
  type: "event";
  kind: "fine" | "ferry" | "train" | "toll" | "delivered" | "cancelled" | "fuelLow" | "rest";
  amount?: number;
  currency?: string;
  detail?: string;
}

const FUEL_LOW = 0.15;
const FUEL_REARM = 0.17;
const REST_SOON_MIN = 60;

/**
 * Events from consecutive samples. The plugin flips (XOR) a flag per gameplay event, so any change of a flag is one
 * event; the first sample after (re)connecting only sets the baseline. fuelLow / rest fire once when the value crosses
 * below the threshold and re-arm after it recovers.
 */
export class TruckEvents {
  #prev: Sample["ev"] | null = null;
  #fuelArmed = false;
  #restArmed = false;

  update(s: Sample): TruckEvent[] {
    const e = s.ev;
    if (!e) {
      this.#prev = null;
      return [];
    }
    const p = this.#prev;
    this.#prev = e;
    const out: TruckEvent[] = [];
    const fuel = e.fuelRatio;
    const rest = e.restStop;
    if (!p) {
      this.#fuelArmed = fuel !== null && fuel >= FUEL_LOW;
      this.#restArmed = rest >= REST_SOON_MIN;
      return out;
    }
    const money = (kind: TruckEvent["kind"], amount: number, detail?: string): TruckEvent => ({
      type: "event", kind, amount, currency: e.currency, ...(detail ? { detail } : {}),
    });
    if (e.flags.fined !== p.flags.fined) out.push(money("fine", e.amounts.fine, e.fineOffence));
    if (e.flags.tollgate !== p.flags.tollgate) out.push(money("toll", e.amounts.toll));
    if (e.flags.ferry !== p.flags.ferry) out.push(money("ferry", e.amounts.ferry, e.ferryTarget));
    if (e.flags.train !== p.flags.train) out.push(money("train", e.amounts.train, e.trainTarget));
    if (e.flags.jobDelivered !== p.flags.jobDelivered) out.push(money("delivered", e.amounts.delivered));
    if (e.flags.jobCancelled !== p.flags.jobCancelled) out.push(money("cancelled", e.amounts.cancel));
    if (fuel !== null) {
      if (this.#fuelArmed && fuel < FUEL_LOW) {
        this.#fuelArmed = false;
        out.push({ type: "event", kind: "fuelLow" });
      } else if (fuel >= FUEL_REARM) this.#fuelArmed = true;
    }
    if (this.#restArmed && rest < REST_SOON_MIN) {
      this.#restArmed = false;
      out.push({ type: "event", kind: "rest" });
    } else if (rest >= REST_SOON_MIN) this.#restArmed = true;
    return out;
  }
}

// ---- the game process and its shared memory ----

/** Pid of a running eurotrucks2 owned by this user (null if none). */
export async function findGamePid(proc = "/proc"): Promise<number | null> {
  const uid = process.getuid?.();
  for (const name of await readdir(proc).catch(() => [] as string[])) {
    if (!/^\d+$/.test(name)) continue;
    const comm = await readFile(join(proc, name, "comm"), "utf8").catch(() => "");
    if (comm.trim() !== GAME_BINARY) continue;
    const st = await stat(join(proc, name)).catch(() => null);
    if (st && (uid === undefined || st.uid === uid)) return Number(name);
  }
  return null;
}

/** Shared-memory reader: re-finds the process at most once a second, reads READ_BYTES per call. */
export class TelemetryReader {
  #pid: number | null = null;
  #checkedAt = 0;
  readonly #proc: string;
  readonly #shm: string;
  readonly #now: () => number;

  constructor(o: { proc?: string; shm?: string; now?: () => number } = {}) {
    this.#proc = o.proc ?? "/proc";
    this.#shm = o.shm ?? "/dev/shm";
    this.#now = o.now ?? Date.now;
  }

  async read(): Promise<{ running: boolean; buf: Buffer | null }> {
    const now = this.#now();
    if (now - this.#checkedAt >= 1000 || (this.#pid !== null && !(await exists(join(this.#proc, String(this.#pid)))))) {
      this.#checkedAt = now;
      this.#pid = await findGamePid(this.#proc);
    }
    if (this.#pid === null) return { running: false, buf: null };
    for (const p of [join(this.#shm, SHM_NAME), join(this.#proc, String(this.#pid), "root", "dev", "shm", SHM_NAME)]) {
      const buf = await readHead(p);
      if (buf) return { running: true, buf };
    }
    return { running: true, buf: null };
  }
}

const exists = (p: string) => stat(p).then(() => true, () => false);

async function readHead(path: string): Promise<Buffer | null> {
  const fh = await open(path, "r").catch(() => null);
  if (!fh) return null;
  try {
    const buf = Buffer.alloc(READ_BYTES);
    const { bytesRead } = await fh.read(buf, 0, READ_BYTES, 0);
    return bytesRead === READ_BYTES ? buf : null;
  } catch {
    return null;
  } finally {
    await fh.close();
  }
}

// ---- game directory and plugin ----

/** Steam roots: native (~/.local/share/Steam, ~/.steam/…) and Flatpak / Snap Steam. */
export function steamRoots(home = homedir()): string[] {
  return [
    join(home, ".local/share/Steam"),
    join(home, ".steam/steam"),
    join(home, ".steam/root"),
    join(home, ".var/app/com.valvesoftware.Steam/.local/share/Steam"),
    join(home, ".var/app/com.valvesoftware.Steam/data/Steam"),
    join(home, "snap/steam/common/.local/share/Steam"),
  ];
}

/** `"path"  "…"` entries of libraryfolders.vdf. */
export function parseLibraryFolders(vdf: string): string[] {
  return [...vdf.matchAll(/"path"\s+"((?:[^"\\]|\\.)*)"/g)].map((m) => m[1]!.replace(/\\(.)/g, "$1"));
}

/** ETS2's install directory (has bin/linux_x64/eurotrucks2), from the Steam libraries; null if not installed. */
export async function findGameDir(home = homedir()): Promise<string | null> {
  const libs: string[] = [];
  for (const root of steamRoots(home)) {
    libs.push(root);
    for (const f of ["steamapps/libraryfolders.vdf", "config/libraryfolders.vdf"]) {
      const vdf = await readFile(join(root, f), "utf8").catch(() => "");
      libs.push(...parseLibraryFolders(vdf));
    }
  }
  for (const lib of [...new Set(libs)]) {
    const dir = join(lib, "steamapps", "common", GAME_FOLDER);
    if (await exists(join(dir, "bin", "linux_x64", GAME_BINARY))) return dir;
  }
  return null;
}

export const pluginDir = (gameDir: string) => join(gameDir, "bin", "linux_x64", "plugins");

const sha256 = (b: Buffer) => createHash("sha256").update(b).digest("hex");

/** "installed" (the pinned build), "outdated" (another file of that name), "missing". */
export async function pluginStatus(gameDir: string | null): Promise<{ plugin: "installed" | "missing" | "outdated"; version: string | null }> {
  if (!gameDir) return { plugin: "missing", version: null };
  const b = await readFile(join(pluginDir(gameDir), PLUGIN.file)).catch(() => null);
  if (!b) return { plugin: "missing", version: null };
  return sha256(b) === PLUGIN.soSha256 ? { plugin: "installed", version: PLUGIN.version } : { plugin: "outdated", version: null };
}

/** Compressed size of the local header at `local`, from the central directory (for entries with a data descriptor). */
function centralSize(zip: Buffer, local: number): number | null {
  const eocd = zip.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
  if (eocd < 0 || eocd + 22 > zip.length) return null;
  let off = zip.readUInt32LE(eocd + 16);
  for (let i = zip.readUInt16LE(eocd + 10); i > 0 && off + 46 <= zip.length && zip.readUInt32LE(off) === 0x02014b50; i--) {
    if (zip.readUInt32LE(off + 42) === local) return zip.readUInt32LE(off + 20);
    off += 46 + zip.readUInt16LE(off + 28) + zip.readUInt16LE(off + 30) + zip.readUInt16LE(off + 32);
  }
  return null;
}

/** One entry of a zip by name (local file header; stored or deflated). */
export function unzipSingle(zip: Buffer, name: string): Buffer {
  let off = 0;
  while (off + 30 <= zip.length && zip.readUInt32LE(off) === 0x04034b50) {
    const flags = zip.readUInt16LE(off + 6);
    const method = zip.readUInt16LE(off + 8);
    const nlen = zip.readUInt16LE(off + 26);
    const xlen = zip.readUInt16LE(off + 28);
    const fname = zip.subarray(off + 30, off + 30 + nlen).toString("utf8");
    const start = off + 30 + nlen + xlen;
    // Data descriptor (the pinned zip has one): the header's sizes are 0, the central directory has the real ones.
    const csize = flags & 0x08 ? centralSize(zip, off) : zip.readUInt32LE(off + 18);
    if (csize === null) break;
    if (fname === name) {
      const data = zip.subarray(start, start + csize);
      if (method === 0) return Buffer.from(data);
      if (method === 8) return inflateRawSync(data, { maxOutputLength: 4 * 1024 * 1024 });
      break;
    }
    off = start + csize;
    if (flags & 0x08) off += off + 4 <= zip.length && zip.readUInt32LE(off) === 0x08074b50 ? 16 : 12; // crc + sizes, optional signature
  }
  throw new AppError("agent.gamemode.pluginBadArchive", 502);
}

export type Fetch = typeof fetch;

/** Downloads the pinned release, checks both hashes and writes the .so atomically. */
export async function installPlugin(gameDir: string, f: Fetch = fetch): Promise<void> {
  let zip: Buffer;
  try {
    const res = await f(PLUGIN.url, { signal: AbortSignal.timeout(60_000) });
    if (!res.ok) throw new Error(String(res.status));
    zip = Buffer.from(await res.arrayBuffer());
  } catch {
    throw new AppError("agent.gamemode.pluginDownloadFailed", 502);
  }
  if (zip.length > 1024 * 1024 || sha256(zip) !== PLUGIN.zipSha256) throw new AppError("agent.gamemode.pluginHashMismatch", 502);
  const so = unzipSingle(zip, PLUGIN.file);
  if (sha256(so) !== PLUGIN.soSha256) throw new AppError("agent.gamemode.pluginHashMismatch", 502);
  const dir = pluginDir(gameDir);
  await mkdir(dir, { recursive: true });
  const tmp = join(dir, `.${PLUGIN.file}.${process.pid}.tmp`);
  await writeFile(tmp, so, { mode: 0o755 });
  await rename(tmp, join(dir, PLUGIN.file));
}

export async function removePlugin(gameDir: string): Promise<void> {
  await rm(join(pluginDir(gameDir), PLUGIN.file), { force: true });
}

/** `tiphys-agent gamemode install-plugin|remove-plugin`. */
export async function pluginCli(action: string | undefined): Promise<string> {
  if (action !== "install-plugin" && action !== "remove-plugin") throw new Error("kullanım: tiphys-agent gamemode install-plugin|remove-plugin");
  const dir = await findGameDir();
  if (!dir) throw new Error("Euro Truck Simulator 2 (Linux) bulunamadı: Steam kütüphanelerinde yok");
  if (action === "install-plugin") {
    await installPlugin(dir);
    return `ETS2 telemetri eklentisi ${PLUGIN.version} kuruldu: ${join(pluginDir(dir), PLUGIN.file)} (oyunu yeniden başlatın)`;
  }
  await removePlugin(dir);
  return `ETS2 telemetri eklentisi kaldırıldı: ${join(pluginDir(dir), PLUGIN.file)}`;
}
