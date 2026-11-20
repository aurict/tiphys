#!/usr/bin/env node
// Development mock for the Game mode display (PLAN.md § 19, "Sözleşme"). Dependency-free (node: built-ins only).
// Serves display/ at /gamemode/, the map data dir at /gamemode/map/ (range requests, like the agent), a fake
// GET /v1/gamemode/art and WS /v1/gamemode/live emitting contract messages: music with progress, placeholder synced
// lyrics, spectrum frames, a truck with events. The truck drives a real route (Kassel → Nuremberg by default, shortest
// path over the road graph) when the parsed game data of the map build is present, else a synthetic curvy road.
//
//   node tools/gamemode-mock.mjs [--port=8787] [--host=127.0.0.1] [--token=dev]
//     --scene=auto|drive|music   --motion=low|normal|high   --clock12   --dim-idle=MIN   --no-lyrics-setting
//     --no-truck | --truck-state=driving|paused|menu|none   --truck-reason=noGame|noPlugin|unsupported (state none)
//     --night   --game-time=HH:MM   --no-job   --time-scale=N (default 19; 0 = leave timeScale out)
//     --map-dir=DIR (default ~/.local/share/tiphys/gamemode/map)   --parsed=DIR (default ~/.cache/tiphys-mapbuild/parsed)
//     --route=Kassel,Nuremberg (city names from the parsed data)   --speed=KMH (cap the simulated speed)
//     --no-music | --paused   --no-cover   --long-title   --no-lyrics   --plain-lyrics   --seek=SEC
//     --source-down   --events=fine,toll,ferry,train,delivered,cancelled,fuelLow,rest | --no-events   --event-every=SEC
//     --art-url=https://…  (serve this image as the cover instead of the generated ones)
//     --live-music          (read the current Velour state + lyrics from $XDG_RUNTIME_DIR/velour/control.sock, read-only)
// Open: http://HOST:PORT/gamemode/#t=TOKEN   (add &debug for an fps overlay)
// Nothing is written to disk; covers are generated in memory; lyrics are neutral placeholder lines.

import http from 'node:http';
import net from 'node:net';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const args = Object.fromEntries(process.argv.slice(2).map((a) => {
  const m = /^--([^=]+)(?:=(.*))?$/.exec(a);
  if (!m) { console.error(`unknown argument: ${a}`); process.exit(2); }
  return [m[1], m[2] ?? true];
}));
const PORT = Number(args.port ?? 8787);
const HOST = String(args.host ?? '127.0.0.1');
const TOKEN = String(args.token ?? 'dev');
const DISPLAY = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../display');
const MAP_DIR = path.resolve(String(args['map-dir'] ?? path.join(os.homedir(), '.local/share/tiphys/gamemode/map')));
const PARSED = path.resolve(String(args.parsed ?? path.join(os.homedir(), '.cache/tiphys-mapbuild/parsed')));

// ------------------------------------------------------------------ PNG covers (generated, nothing copyrighted)
const CRC = new Uint32Array(256).map((_, n) => { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1; return c >>> 0; });
const crc32 = (buf) => { let c = 0xffffffff; for (const b of buf) c = CRC[(c ^ b) & 0xff] ^ (c >>> 8); return (c ^ 0xffffffff) >>> 0; };
function chunk(type, data) {
  const len = Buffer.alloc(4); len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type), data]);
  const crc = Buffer.alloc(4); crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png(w, h, pixel) {
  const raw = Buffer.alloc((w * 3 + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (w * 3 + 1)] = 0;
    for (let x = 0; x < w; x++) {
      const [r, g, b] = pixel(x / w, y / h);
      const o = y * (w * 3 + 1) + 1 + x * 3;
      raw[o] = r; raw[o + 1] = g; raw[o + 2] = b;
    }
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 2;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw)), chunk('IEND', Buffer.alloc(0))]);
}
const hex = (s) => [1, 3, 5].map((i) => parseInt(s.slice(i, i + 2), 16));
function cover(colors) {
  const [a, b, c, d] = colors.map(hex);
  const clamp = (v) => Math.max(0, Math.min(255, Math.round(v)));
  return png(400, 400, (x, y) => {
    const t = (x + y) / 2;
    let col = a.map((v, i) => v * (1 - t) + d[i] * t);
    const blob = (cx, cy, r, k, cc) => { const dd = ((x - cx) ** 2 + (y - cy) ** 2) / (r * r); const w = Math.exp(-dd) * k; col = col.map((v, i) => v * (1 - w) + cc[i] * w); };
    blob(0.72, 0.28, 0.32, 0.95, b);
    blob(0.25, 0.78, 0.28, 0.85, c);
    const ring = Math.abs(Math.hypot(x - 0.5, y - 0.52) - 0.3);
    if (ring < 0.006) col = col.map((v) => v * 0.6 + 255 * 0.4);
    const grain = (Math.sin(x * 913 + y * 377) * 43758.5453) % 1;
    return col.map((v) => clamp(v + grain * 6));
  });
}

// ------------------------------------------------------------------ fake library (fictional titles, placeholder lyrics)
const TRACKS = [
  { title: 'Gece Yolu', artist: 'Deneme Topluluğu', album: 'Ara Duraklar', duration: 214, colors: ['#1B1F4B', '#E86A5C', '#F2B66D', '#3B2A6E'] },
  { title: 'Kuzey Işıkları', artist: 'Mavi Örnek', album: 'Sessiz Kanal', duration: 187, colors: ['#0C2B2E', '#3FD0B4', '#7A8CFF', '#102040'] },
  { title: 'Sabaha Karşı', artist: 'Yer Tutucu', album: 'Demo Kayıtlar', duration: 236, colors: ['#2E1630', '#FF7AB6', '#FFD36E', '#3C1F55'] },
];
const LONG = { title: 'Uzun Bir Şarkı Adı: Sisli Vadiden Geçen Son Otobüsün Ardından Gelen Sabah ve Yolun Sonundaki Işıklar', artist: 'Çok Uzun Sanatçı Adıyla Bir Topluluk ve Konuk Sanatçılar', album: 'Uzun Albüm Adı', duration: 248, colors: ['#1E2A10', '#B7E35A', '#3FA7D6', '#203018'] };
const PLACEHOLDER = [
  'Yol uzun, gece sakin', 'Farlar çiziyor karanlığı', 'Bir şehir daha geride kaldı', '',
  'Radyoda eski bir melodi', 'Saat ilerliyor, yol bitmiyor', 'Uzakta ışıklar yanıp sönüyor', 'Bir kahve molası, sonra devam',
  '', 'Rüzgâr camda ince bir ses', 'Harita sessizce dönüyor', 'Her virajda yeni bir manzara', 'Sabah olmadan varacağız',
  'Yol uzun, gece sakin', 'Farlar çiziyor karanlığı', '', 'Ve yine yola, yine yola',
];
const lyricsFor = (t) => ({ kind: 'synced', lines: PLACEHOLDER.map((text, i) => ({ t: 9 + i * 3.6 + (i > 3 ? 4 : 0) + (i > 8 ? 4 : 0), text })) });

const tracks = args['long-title'] ? [LONG, ...TRACKS] : TRACKS;
const covers = new Map(); // artId → Buffer
tracks.forEach((t, i) => { t.artId = `mock-${i}`; });

// ------------------------------------------------------------------ music state
const music = {
  index: 0, playing: !args.paused, pos: Number(args.seek ?? 34), at: Date.now(),
  get track() { return tracks[this.index]; },
  position() { return this.pos + (this.playing ? (Date.now() - this.at) / 1000 : 0); },
};
function musicMsg() {
  if (args['no-music'] || args['source-down']) return { type: 'music', none: true };
  if (live.state) return live.msg;
  const t = music.track;
  const next = [1, 2].map((k) => tracks[(music.index + k) % tracks.length]).map((n) => ({ title: n.title, artist: n.artist }));
  return { type: 'music', playing: music.playing, title: t.title, artist: t.artist, album: t.album, artId: args['no-cover'] ? null : t.artId,
    duration: t.duration, position: Math.round(music.position() * 1000) / 1000, at: Date.now(), next };
}
function lyricsMsg() {
  if (live.state) return live.lyrics;
  const t = music.track;
  if (args['no-lyrics']) return { type: 'lyrics', artId: t.artId, title: t.title, kind: 'none', lines: [] };
  if (args['plain-lyrics']) return { type: 'lyrics', artId: t.artId, title: t.title, kind: 'plain', lines: PLACEHOLDER.map((text) => ({ t: 0, text })) };
  return { type: 'lyrics', artId: args['no-cover'] ? null : t.artId, title: t.title, ...lyricsFor(t) };
}

// ------------------------------------------------------------------ --live-music: Velour control socket (read-only ops)
const live = { state: null, msg: null, lyrics: null, art: new Map(), key: null };
function velour(op) {
  return new Promise((resolve) => {
    const s = net.connect(path.join(process.env.XDG_RUNTIME_DIR ?? '/run/user/1000', 'velour/control.sock'));
    let buf = '';
    s.setTimeout(3000, () => { s.destroy(); resolve(null); });
    s.on('data', (d) => { buf += d; });
    s.on('end', () => { try { resolve(JSON.parse(buf).result ?? null); } catch { resolve(null); } });
    s.on('error', () => resolve(null));
    s.write(JSON.stringify({ v: 1, op }) + '\n');
  });
}
async function pollVelour() {
  const st = await velour('state');
  if (!st?.track) { live.state = null; return; }
  const tr = st.track;
  const key = `${st.rev}:${tr.videoId}:${st.playing}`;
  live.state = st;
  const artId = tr.thumbnail?.startsWith('https://') ? tr.videoId : null;
  if (artId) live.art.set(artId, tr.thumbnail);
  live.msg = { type: 'music', playing: !!st.playing, title: tr.title, artist: (tr.artists ?? []).map((a) => a.name).join(', '), album: tr.album?.name ?? null,
    artId, duration: st.duration ?? tr.duration ?? 0, position: st.position ?? 0, at: Date.now(), next: [] };
  if (key !== live.key) {
    const trackChanged = !live.key || live.key.split(':')[1] !== tr.videoId;
    live.key = key;
    if (trackChanged) {
      const ly = await velour('lyrics');
      const lines = (ly?.lines ?? []).map((l) => ({ t: l.time, text: l.text }));
      live.lyrics = { type: 'lyrics', artId, title: tr.title, kind: ly?.kind === 'synced' && lines.length ? 'synced' : ly?.kind === 'plain' ? 'plain' : 'none',
        lines: ly?.kind === 'plain' ? String(ly.text ?? '').split('\n').map((text) => ({ t: 0, text })) : lines };
      broadcast(live.msg); broadcast(live.lyrics);
    } else broadcast(live.msg);
  }
}
if (args['live-music']) { setInterval(pollVelour, 1000); pollVelour(); }

// ------------------------------------------------------------------ truck simulation
const KMH = 1 / 3.6;
const parseHM = (s) => { const [h, m] = String(s).split(':').map(Number); return h * 60 + (m || 0); };

/**
 * A real route over the game's road graph (roads + prefab junctions from the map build's parsed JSON), shortest path
 * by length. Returns [[x, z], …] in game metres or null when the data isn't there. Read once at start, memory only.
 */
function loadRoute(names) {
  const read = (f) => JSON.parse(fs.readFileSync(path.join(PARSED, `europe-${f}.json`), 'utf8'));
  try {
    if (!fs.existsSync(path.join(PARSED, 'europe-nodes.json'))) return null;
    const t0 = Date.now();
    const cities = read('cities');
    const ends = names.map((n) => {
      const c = cities.find((x) => x.name === n);
      if (!c) throw new Error(`no city "${n}" in the parsed data`);
      const ar = c.areas.find((x) => !x.hidden) ?? { width: 0, height: 0 };
      return [c.x + ar.width / 2, c.y + ar.height / 2];
    });
    const pos = new Map();
    for (const n of read('nodes')) pos.set(n.uid, [n.x, n.y, n.rotation]);
    const adj = new Map();
    const link = (u, v) => {
      const a = pos.get(u), b = pos.get(v);
      if (!a || !b) return;
      const w = Math.hypot(a[0] - b[0], a[1] - b[1]);
      if (!adj.has(u)) adj.set(u, []);
      if (!adj.has(v)) adj.set(v, []);
      adj.get(u).push([v, w]); adj.get(v).push([u, w]);
    };
    const roads = new Map(); // "u>v" of a road's start>end node: the path follows its curve
    for (const r of read('roads')) if (!r.hidden) { link(r.startNodeUid, r.endNodeUid); roads.set(`${r.startNodeUid}>${r.endNodeUid}`, true); }
    for (const p of read('prefabs')) for (let i = 0; i < p.nodeUids.length; i++) for (let j = i + 1; j < p.nodeUids.length; j++) link(p.nodeUids[i], p.nodeUids[j]);
    const nearest = ([x, z]) => { let best = null, bd = Infinity; for (const u of adj.keys()) { const [a, b] = pos.get(u); const d = (a - x) ** 2 + (b - z) ** 2; if (d < bd) { bd = d; best = u; } } return best; };
    const [src, dst] = ends.map(nearest);
    // Dijkstra with a binary heap.
    const dist = new Map([[src, 0]]), prev = new Map(), heap = [[0, src]];
    const push = (e) => { heap.push(e); let i = heap.length - 1; while (i > 0) { const q = (i - 1) >> 1; if (heap[q][0] <= heap[i][0]) break; [heap[q], heap[i]] = [heap[i], heap[q]]; i = q; } };
    const pop = () => { const top = heap[0], last = heap.pop(); if (heap.length) { heap[0] = last; let i = 0; for (;;) { const l = 2 * i + 1, r = l + 1; let m = i; if (l < heap.length && heap[l][0] < heap[m][0]) m = l; if (r < heap.length && heap[r][0] < heap[m][0]) m = r; if (m === i) break; [heap[m], heap[i]] = [heap[i], heap[m]]; i = m; } } return top; };
    while (heap.length) {
      const [d, u] = pop();
      if (u === dst) break;
      if (d > dist.get(u)) continue;
      for (const [v, w] of adj.get(u)) if (d + w < (dist.get(v) ?? Infinity)) { dist.set(v, d + w); prev.set(v, u); push([d + w, v]); }
    }
    if (!prev.has(dst)) throw new Error('no road path');
    const ids = [];
    for (let u = dst; u; u = prev.get(u)) ids.push(u);
    ids.reverse();
    // Roads are cubic Hermite curves between their nodes (tangent = node rotation × chord length), as the map draws them.
    const curve = (a, b) => {
      const [p0, p1] = [pos.get(a), pos.get(b)];
      const d = Math.hypot(p1[0] - p0[0], p1[1] - p0[1]);
      const m0 = [Math.cos(p0[2]) * d, Math.sin(p0[2]) * d], m1 = [Math.cos(p1[2]) * d, Math.sin(p1[2]) * d];
      const steps = Math.max(1, Math.min(16, Math.ceil(d / 25)));
      const pts = [];
      for (let i = 1; i <= steps; i++) {
        const t = i / steps, t2 = t * t, t3 = t2 * t;
        const h = [2 * t3 - 3 * t2 + 1, t3 - 2 * t2 + t, -2 * t3 + 3 * t2, t3 - t2];
        pts.push([0, 1].map((k) => h[0] * p0[k] + h[1] * m0[k] + h[2] * p1[k] + h[3] * m1[k]));
      }
      return pts;
    };
    const out = [pos.get(ids[0]).slice(0, 2)];
    for (let i = 1; i < ids.length; i++) {
      const [a, b] = [ids[i - 1], ids[i]];
      if (roads.has(`${a}>${b}`)) out.push(...curve(a, b));
      else if (roads.has(`${b}>${a}`)) out.push(...curve(b, a).reverse().slice(1), pos.get(b).slice(0, 2)); // walked backwards
      else out.push(pos.get(b).slice(0, 2));
    }
    console.log(`[mock] route ${names.join(' → ')}: ${out.length} nodes, ${Math.round(dist.get(dst) / 1000)} km (${Date.now() - t0} ms)`);
    return out;
  } catch (e) {
    console.log(`[mock] no real route (${e.message}); using a synthetic road`);
    return null;
  }
}
const routeNames = String(args.route ?? 'Kassel,Nuremberg').split(',');
const ROUTE = args['no-truck'] ? null : loadRoute(routeNames);
const routeLen = ROUTE ? ROUTE.slice(1).reduce((a, p, i) => a + Math.hypot(p[0] - ROUTE[i][0], p[1] - ROUTE[i][1]), 0) : 0;
const headingOf = (dx, dz) => ((Math.atan2(-dx, -dz) / (Math.PI * 2)) % 1 + 1) % 1; // SCS: 0 = north (−z), CCW

const sim = {
  x: -31250, z: 4120, hd: 0.12, speed: 0, dist: 0, fuel: 512, fuelCap: 740,
  gameTime: 2 * 1440 + parseHM(args.night ? '22:40' : args['game-time'] ?? '14:20'), // Wed
  navLeft: 412_000, wear: 0.034, cruise: 0, gear: 0,
  seg: 0, segT: 0, // position on ROUTE: segment index + metres into it
};
const truckState = args['no-truck'] ? 'none' : String(args['truck-state'] ?? 'driving');
const TIME_SCALE = Number(args['time-scale'] ?? 19);
const MAX_KMH = Number(args.speed ?? 999);
const LIMITS = [{ until: 1800, limit: 80 }, { until: 2600, limit: 60 }, { until: 6000, limit: 90 }, { until: 6800, limit: 80 }];
function limitAt(d) { const m = d % 6800; return (LIMITS.find((l) => m < l.until) ?? LIMITS[0]).limit; }
function placeOnRoute(advance) {
  sim.segT += advance;
  while (sim.seg < ROUTE.length - 1) {
    const [a, b] = [ROUTE[sim.seg], ROUTE[sim.seg + 1]];
    const len = Math.hypot(b[0] - a[0], b[1] - a[1]);
    if (sim.segT <= len) {
      const k = len ? sim.segT / len : 0;
      sim.x = a[0] + (b[0] - a[0]) * k; sim.z = a[1] + (b[1] - a[1]) * k;
      if (len > 0.5) {
        // Ease the heading toward the segment's (nodes are corners; a real truck turns smoothly).
        const want = headingOf(b[0] - a[0], b[1] - a[1]);
        let d = want - sim.hd; d -= Math.round(d);
        sim.hd = ((sim.hd + d * Math.min(1, advance / 25)) % 1 + 1) % 1;
      }
      return;
    }
    sim.segT -= len; sim.seg++;
  }
  sim.seg = 0; sim.segT = 0; sim.dist = 0; // arrived: start over (the page sees a jump and breaks its trail)
  sim.hd = headingOf(ROUTE[1][0] - ROUTE[0][0], ROUTE[1][1] - ROUTE[0][1]);
  placeOnRoute(0);
}
if (ROUTE) { sim.hd = headingOf(ROUTE[1][0] - ROUTE[0][0], ROUTE[1][1] - ROUTE[0][1]); placeOnRoute(Number(args['route-start'] ?? 0)); }
let lastSim = Date.now();
function stepSim() {
  const now = Date.now();
  const dt = Math.min(0.2, (now - lastSim) / 1000);
  lastSim = now;
  if (truckState !== 'driving') return;
  const limit = limitAt(sim.dist);
  // Mostly at the limit, sometimes a bit over (shows the warning ring).
  const over = Math.sin(sim.dist / 900) > 0.75 ? 9 : 0;
  const target = Math.min(MAX_KMH, limit + over - 2 + Math.sin(now / 4000) * 2) * KMH;
  sim.speed += Math.max(-2.5 * dt, Math.min(1.2 * dt, target - sim.speed));
  sim.dist += sim.speed * dt;
  if (ROUTE) {
    placeOnRoute(sim.speed * dt);
    sim.navLeft = Math.max(0, routeLen - sim.dist);
  } else {
    const curve = Math.sin(sim.dist / 700) * 0.000045 + Math.sin(sim.dist / 2300 + 1) * 0.00003;
    sim.hd = (sim.hd + curve * sim.speed * dt + 1) % 1;
    const a = sim.hd * Math.PI * 2;
    sim.x += -Math.sin(a) * sim.speed * dt;
    sim.z += -Math.cos(a) * sim.speed * dt;
    sim.navLeft = Math.max(0, sim.navLeft - sim.speed * dt);
  }
  sim.fuel = Math.max(0, sim.fuel - sim.speed * dt * 0.00034);
  sim.gameTime += dt * (TIME_SCALE || 19) / 60;
  sim.cruise = sim.dist % 5000 > 2500 ? limit * KMH : 0;
  sim.gear = Math.max(1, Math.min(12, Math.round(3 + sim.speed / 2.4)));
}
function truckMsg() {
  const at = Date.now();
  if (truckState === 'none' || args['source-down']) return { type: 'truck', state: 'none', reason: String(args['truck-reason'] ?? 'noGame'), at };
  const kmh = sim.speed / KMH;
  const rpm = truckState === 'driving' ? 1050 + ((kmh % 12) / 12) * 450 + Math.sin(at / 700) * 40 : 650;
  const [from, to] = ROUTE ? routeNames : ['Kassel', 'Nürnberg'];
  return {
    type: 'truck', state: truckState, at,
    speed: sim.speed, speedLimit: limitAt(sim.dist) * KMH, rpm, rpmMax: 2500, gear: truckState === 'driving' ? sim.gear : 0, gears: 12,
    fuel: sim.fuel, fuelCap: sim.fuelCap, fuelRange: sim.fuel / 0.34, cruise: sim.cruise, parkingBrake: truckState !== 'driving',
    lowBeam: args.night ? true : false, highBeam: false, beacon: false, blinkerL: false, blinkerR: false,
    wear: sim.wear, cargoDamage: 0.01,
    x: sim.x, z: sim.z, heading: sim.hd, gameTime: sim.gameTime, ...(TIME_SCALE > 0 ? { timeScale: TIME_SCALE } : {}), restMinutes: 205,
    job: args['no-job'] ? null : { from, to, cargo: 'Elektronik', income: 12400, currency: 'EUR', deadlineGameTime: sim.gameTime + 600 },
    nav: args['no-job'] ? null : { distance: sim.navLeft, time: sim.navLeft / 22 }, // real s
  };
}

// ------------------------------------------------------------------ spectrum synth (beat + band shape)
function spectrumFrame() {
  const t = Date.now() / 1000;
  const beat = Math.pow(Math.max(0, Math.cos(((t * 2) % 1) * Math.PI * 0.5)), 6); // 120 bpm kick
  const b = Buffer.alloc(25);
  b[0] = 0x01;
  for (let i = 0; i < 24; i++) {
    const shape = 0.85 - i / 34;
    const kick = i < 4 ? beat * (1 - i / 5) : 0;
    const wob = 0.22 * (0.5 + 0.5 * Math.sin(t * (2.2 + i * 0.37) + i));
    const v = Math.max(0, Math.min(1, shape * 0.55 + kick * 0.5 + wob * shape + (Math.random() - 0.5) * 0.06));
    b[i + 1] = Math.round(v * 255);
  }
  return b;
}

// ------------------------------------------------------------------ minimal WebSocket server (RFC 6455, server side)
const clients = new Set();
function frame(opcode, payload) {
  const len = payload.length;
  const head = len < 126 ? Buffer.from([0x80 | opcode, len]) : len < 65536 ? Buffer.from([0x80 | opcode, 126, len >> 8, len & 255]) : null;
  if (!head) { const h = Buffer.alloc(10); h[0] = 0x80 | opcode; h[1] = 127; h.writeBigUInt64BE(BigInt(len), 2); return Buffer.concat([h, payload]); }
  return Buffer.concat([head, payload]);
}
const sendText = (sock, obj) => { if (!sock.destroyed && sock.writableLength < 256 * 1024) sock.write(frame(1, Buffer.from(JSON.stringify(obj)))); };
const sendBin = (sock, buf) => { if (!sock.destroyed && sock.writableLength < 64 * 1024) sock.write(frame(2, buf)); };
function broadcast(obj) { for (const c of clients) sendText(c, obj); }

function onUpgrade(req, sock) {
  const url = new URL(req.url, 'http://x');
  if (url.pathname !== '/v1/gamemode/live' || url.searchParams.get('t') !== TOKEN || !req.headers['sec-websocket-key']) {
    sock.end('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n');
    return;
  }
  const accept = crypto.createHash('sha1').update(req.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64');
  sock.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`);
  sock.setNoDelay(true);
  clients.add(sock);
  let buf = Buffer.alloc(0);
  sock.on('data', (d) => {
    buf = Buffer.concat([buf, d]);
    while (buf.length >= 2) {
      const op = buf[0] & 0x0f;
      let len = buf[1] & 0x7f, off = 2;
      if (len === 126) { if (buf.length < 4) return; len = buf.readUInt16BE(2); off = 4; }
      else if (len === 127) { if (buf.length < 10) return; len = Number(buf.readBigUInt64BE(2)); off = 10; }
      const masked = buf[1] & 0x80;
      if (buf.length < off + (masked ? 4 : 0) + len) return;
      const mask = masked ? buf.subarray(off, off + 4) : null;
      off += masked ? 4 : 0;
      const data = Buffer.from(buf.subarray(off, off + len));
      if (mask) for (let i = 0; i < data.length; i++) data[i] ^= mask[i & 3];
      buf = buf.subarray(off + len);
      if (op === 8) { sock.end(frame(8, Buffer.alloc(0))); return; }
      if (op === 9) { sock.write(frame(10, data)); continue; }
      if (op === 1) {
        let m; try { m = JSON.parse(data.toString()); } catch { continue; }
        if (m.type === 'stop') { console.log('[mock] page sent {"type":"stop"} (Esc held). The real agent stops the mode here.'); }
      }
    }
  });
  const bye = () => clients.delete(sock);
  sock.on('close', bye); sock.on('error', bye);

  // Contract: on connect the server sends the latest settings, source, music, lyrics, truck.
  sendText(sock, { type: 'settings', ...settings });
  sendText(sock, args['source-down'] ? { type: 'source', state: 'down', retryInSec: 15 } : { type: 'source', state: 'ok' });
  if (args['source-down']) return;
  sendText(sock, musicMsg());
  if (!args['no-music']) sendText(sock, lyricsMsg());
  sendText(sock, truckMsg());
}

// ------------------------------------------------------------------ settings + stdin control
// Type on stdin while it runs:  set scene=music | set motion=low | set lyrics=false | event fine | source down | source ok
const settings = { scene: String(args.scene ?? 'auto'), lyrics: !args['no-lyrics-setting'], spectrum: !args['no-spectrum'],
  motion: String(args.motion ?? 'normal'), brightness: null, clock24: !args.clock12, dimIdleMinutes: Number(args['dim-idle'] ?? 10) };
let stdinBuf = '';
process.stdin.on('data', (d) => {
  stdinBuf += d;
  let i;
  while ((i = stdinBuf.indexOf('\n')) >= 0) {
    const [cmd, arg = ''] = stdinBuf.slice(0, i).trim().split(/\s+/, 2);
    stdinBuf = stdinBuf.slice(i + 1);
    if (cmd === 'set') {
      const [k, v] = arg.split('=');
      settings[k] = v === 'true' ? true : v === 'false' ? false : /^\d+$/.test(v) ? Number(v) : v;
      broadcast({ type: 'settings', ...settings });
    } else if (cmd === 'event' && EVENTS[arg]) broadcast({ type: 'event', ...EVENTS[arg] });
    else if (cmd === 'source') broadcast(arg === 'down' ? { type: 'source', state: 'down', retryInSec: 15 } : { type: 'source', state: 'ok' });
    else if (cmd) console.log('[mock] commands: set key=value | event <kind> | source down|ok');
  }
});
process.stdin.on('error', () => {});

// ------------------------------------------------------------------ periodic emitters
let lastTrack = -1;
setInterval(() => {
  if (args['no-music'] || args['source-down'] || live.state || args['live-music']) return;
  const t = music.track;
  if (music.position() >= t.duration) { music.index = (music.index + 1) % tracks.length; music.pos = 0; music.at = Date.now(); }
  if (music.index !== lastTrack) { lastTrack = music.index; broadcast(musicMsg()); broadcast(lyricsMsg()); }
}, 250);
setInterval(() => { if (!args['source-down'] && !args['no-music']) broadcast(musicMsg()); }, 10_000);
setInterval(() => {
  stepSim();
  if (args['source-down']) return;
  const driving = truckState === 'driving';
  if (driving || Date.now() % 1000 < 50) broadcast(truckMsg());
}, 50);
setInterval(() => {
  if (args['no-music'] || args['source-down'] || !clients.size) return;
  const playing = live.state ? live.state.playing : music.playing;
  if (!playing) return;
  const f = spectrumFrame();
  for (const c of clients) sendBin(c, f);
}, 33);
const EVENTS = {
  fine: { kind: 'fine', amount: 750, currency: 'EUR', detail: 'Hız sınırı aşıldı' },
  toll: { kind: 'toll', amount: 42, currency: 'EUR' },
  ferry: { kind: 'ferry', detail: 'Calais → Dover' },
  train: { kind: 'train', detail: 'Folkestone → Calais' },
  delivered: { kind: 'delivered', amount: 12400, currency: 'EUR', detail: 'Nürnberg · Elektronik' },
  cancelled: { kind: 'cancelled', amount: 2100, currency: 'EUR' },
  fuelLow: { kind: 'fuelLow' },
  rest: { kind: 'rest' },
};
if (!args['no-events'] && !args['source-down']) {
  const list = String(args.events ?? 'fine,toll,ferry,delivered,fuelLow,rest').split(',').filter((k) => EVENTS[k]);
  let i = 0;
  const every = Number(args['event-every'] ?? 14) * 1000;
  setTimeout(function tick() { if (clients.size) broadcast({ type: 'event', ...EVENTS[list[i++ % list.length]] }); setTimeout(tick, every); }, Math.min(every, 5000));
}

// ------------------------------------------------------------------ HTTP
const TYPES = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.ttf': 'font/ttf', '.txt': 'text/plain; charset=utf-8', '.png': 'image/png', '.svg': 'image/svg+xml', '.json': 'application/json',
  '.pbf': 'application/x-protobuf', '.pmtiles': 'application/octet-stream' };
/** A file below root (no escaping it), or null. */
function fileIn(root, rel) {
  const file = path.resolve(root, rel);
  return file.startsWith(root + path.sep) && fs.existsSync(file) && fs.statSync(file).isFile() ? file : null;
}
async function artFor(id) {
  if (args['art-url']) return fetchImage(String(args['art-url']));
  if (live.art.has(id)) return fetchImage(live.art.get(id));
  const t = tracks.find((x) => x.artId === id);
  if (!t) return null;
  if (!covers.has(id)) covers.set(id, cover(t.colors));
  return { type: 'image/png', body: covers.get(id) };
}
const fetched = new Map();
async function fetchImage(url) {
  if (fetched.has(url)) return fetched.get(url);
  if (!url.startsWith('https://')) return null;
  try {
    const r = await fetch(url, { signal: AbortSignal.timeout(10_000) });
    const body = Buffer.from(await r.arrayBuffer());
    if (!r.ok || body.length > 5 * 1024 * 1024) return null;
    const type = body[0] === 0xff && body[1] === 0xd8 ? 'image/jpeg' : body[0] === 0x89 && body[1] === 0x50 ? 'image/png' : body.subarray(8, 12).toString() === 'WEBP' ? 'image/webp' : null;
    if (!type) return null;
    const v = { type, body };
    fetched.set(url, v);
    if (fetched.size > 8) fetched.delete(fetched.keys().next().value);
    return v;
  } catch { return null; }
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  if (url.pathname === '/v1/gamemode/art') {
    const img = url.searchParams.get('t') === TOKEN ? await artFor(url.searchParams.get('id') ?? '') : null;
    if (!img) { res.writeHead(404).end(); return; }
    res.writeHead(200, { 'content-type': img.type, 'cache-control': 'no-store' }).end(img.body);
    return;
  }
  if (url.pathname === '/gamemode') { res.writeHead(301, { location: '/gamemode/' }).end(); return; }
  if (url.pathname.startsWith('/gamemode/map/')) {
    // Map data, with single byte ranges (PMTiles reads the archive in pieces), like the agent.
    const file = fileIn(MAP_DIR, decodeURIComponent(url.pathname.slice('/gamemode/map/'.length)));
    if (!file) { res.writeHead(404).end(); return; }
    const size = fs.statSync(file).size;
    const type = TYPES[path.extname(file)] ?? 'application/octet-stream';
    const m = /^bytes=(\d*)-(\d*)$/.exec(req.headers.range ?? '');
    if (!m) { res.writeHead(200, { 'content-type': type, 'content-length': size, 'accept-ranges': 'bytes', 'cache-control': 'no-cache' }); fs.createReadStream(file).pipe(res); return; }
    const start = m[1] === '' ? Math.max(0, size - Number(m[2])) : Number(m[1]);
    const end = m[1] === '' || m[2] === '' ? size - 1 : Math.min(Number(m[2]), size - 1);
    if (start > end || start >= size) { res.writeHead(416, { 'content-range': `bytes */${size}` }).end(); return; }
    res.writeHead(206, { 'content-type': type, 'content-length': end - start + 1, 'content-range': `bytes ${start}-${end}/${size}`, 'accept-ranges': 'bytes', 'cache-control': 'no-cache' });
    fs.createReadStream(file, { start, end }).pipe(res);
    return;
  }
  if (url.pathname.startsWith('/gamemode/')) {
    const file = fileIn(DISPLAY, decodeURIComponent(url.pathname.slice('/gamemode/'.length)) || 'index.html');
    if (!file) { res.writeHead(404).end(); return; }
    res.writeHead(200, { 'content-type': TYPES[path.extname(file)] ?? 'application/octet-stream', 'cache-control': 'no-store' });
    fs.createReadStream(file).pipe(res);
    return;
  }
  res.writeHead(404).end();
});
server.on('upgrade', onUpgrade);
server.listen(PORT, HOST, () => console.log(`[mock] http://${HOST}:${PORT}/gamemode/#t=${TOKEN}`));
const quit = () => { for (const c of clients) c.destroy(); server.close(); process.exit(0); };
process.on('SIGINT', quit); process.on('SIGTERM', quit);
