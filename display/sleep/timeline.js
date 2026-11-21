// Sleep mode shared timeline (PLAN.md §21 "Ortak zaman çizelgesi", S1 draft; S3 builds the group sync on it).
// Every machine computes the same scene from {seed, t0, members} and the shared clock alone: no event stream on the
// network. Pure functions only (no DOM, no Date.now): runs in the page and under `node --test`.
//
// How events are made (what S3 can rely on):
//  - Time after t0 is cut into fixed slots of SLOT_MS per event kind. A slot's events depend only on
//    (seed, kind, slot index, the rate at the slot's start). So any window [a, b) can be asked for in any order or
//    chunking and gives the same events, and a later change of the plan (snooze, dismiss) never rewrites the past.
//  - The decisions (is there an event, when, where, which variant) use only 32-bit integer hashing and + − × ÷ on
//    doubles, never Math.exp/sin/pow: those may differ in the last bit between Firefox and Chromium, IEEE basic
//    arithmetic may not. Transcendental functions appear only in rendering (sparkAt's wobble, spatial gains).
//  - Every event has a stable id `${kind}:${slot}` (+ `.n` for a log's sparks): a group message can name one.
//  - Scene coordinates: x runs across all screens of the group, each screen 1 unit wide, a virtual gap of GAP units
//    between neighbours (ordered left → foot/head → right, then by id); y is 0 at the bottom, 1 at the top of a
//    screen. A spark keeps its own path in scene space, so it leaves one screen's edge and enters the next one's at
//    the shared time; each screen draws only what falls inside its span.
//
// Plan (phases; built by the agent in S2, here by the demo): {t0, settleMs, fadeMs, soundFadeMs, nightSound,
//   sunriseAt|null, ringAt|null, rampMs, alarmSound: "birds"|"chime"}; times are shared-clock epoch ms.

export const SLOT_MS = 125;
export const GAP = 0.4;
const SIDE_ORDER = { left: 0, foot: 1, head: 1, right: 2 };
const KIND = { crackle: 1, log: 2, flare: 3, gust: 4, chirp: 5, chime: 6 };
const LIFE_MAX_MS = 7000; // longest visible life of any event (a spark); windows reach back this far

// ---- integer hashing (identical on every engine)
function mix32(h) {
  h ^= h >>> 16; h = Math.imul(h, 0x7feb352d);
  h ^= h >>> 15; h = Math.imul(h, 0x846ca68b);
  h ^= h >>> 16;
  return h >>> 0;
}
/** A small PRNG stream for one (seed, kind, slot): returns floats in [0, 1) from 32-bit integers. */
export function stream(seed, kind, slot) {
  let s = mix32((seed >>> 0) ^ mix32(Math.imul(kind, 0x9e3779b1) ^ mix32(slot | 0)));
  return () => {
    s = (s + 0x6d2b79f5) >>> 0;
    let z = s;
    z = Math.imul(z ^ (z >>> 15), z | 1);
    z ^= z + Math.imul(z ^ (z >>> 7), z | 61);
    return ((z ^ (z >>> 14)) >>> 0) / 4294967296;
  };
}

// ---- easing without transcendental functions
const clamp01 = (v) => (v < 0 ? 0 : v > 1 ? 1 : v);
const smooth = (k) => k * k * (3 - 2 * k);
const easeOut = (k) => 1 - (1 - k) * (1 - k) * (1 - k);
const easeIn = (k) => k * k;
const lerp = (a, b, k) => a + (b - a) * k;

// ---- room layout
/** Members [{id, side, distance}] → [{id, side, distance, x0, x1, cx}] in scene order. */
export function layoutOf(members) {
  const list = [...members].sort((a, b) => (SIDE_ORDER[a.side] ?? 1) - (SIDE_ORDER[b.side] ?? 1) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return list.map((m, i) => {
    const x0 = i * (1 + GAP);
    return { id: m.id, side: m.side, distance: m.distance ?? 'mid', x0, x1: x0 + 1, cx: x0 + 0.5 };
  });
}

const DIST = { near: 0.5, mid: 0.71, far: 1 };
/**
 * How loud an event at scene x is on machine `id`: {gain, pan}. Between two neighbouring screens an equal-power
 * cross-fade (gains² sum to 1); inside a machine a stereo pan toward the event's side; the distance setting balances
 * the machines (the nearest is turned down, the farthest stays at 1).
 */
export function spatial(layout, id, x) {
  const me = layout.findIndex((m) => m.id === id);
  if (me < 0) return { gain: 0, pan: 0 };
  let g = 0;
  if (layout.length === 1) g = 1;
  else {
    const c = layout.map((m) => m.cx);
    if (x <= c[0]) g = me === 0 ? 1 : 0;
    else if (x >= c[c.length - 1]) g = me === c.length - 1 ? 1 : 0;
    else {
      let i = 0;
      while (x > c[i + 1]) i++;
      const f = (x - c[i]) / (c[i + 1] - c[i]);
      g = me === i ? Math.cos(f * Math.PI / 2) : me === i + 1 ? Math.sin(f * Math.PI / 2) : 0;
    }
  }
  const far = Math.max(...layout.map((m) => DIST[m.distance] ?? DIST.mid));
  g *= (DIST[layout[me].distance] ?? DIST.mid) / far;
  const pan = Math.max(-1, Math.min(1, (x - layout[me].cx) / 0.6)) * 0.8;
  return { gain: g, pan };
}

// ---- phases and levels
export const PHASES = ['settle', 'fade', 'night', 'sunrise', 'ring'];

/** Phase boundaries of a plan: [{phase, start, end}] (end Infinity for the last). */
export function phasesOf(plan) {
  const out = [];
  const settleEnd = plan.t0 + plan.settleMs, fadeEnd = settleEnd + plan.fadeMs;
  out.push({ phase: 'settle', start: plan.t0, end: settleEnd });
  out.push({ phase: 'fade', start: settleEnd, end: fadeEnd });
  if (plan.ringAt == null) { out.push({ phase: 'night', start: fadeEnd, end: Infinity }); return out; }
  const sunStart = Math.max(fadeEnd, plan.sunriseAt ?? plan.ringAt);
  out.push({ phase: 'night', start: fadeEnd, end: sunStart });
  out.push({ phase: 'sunrise', start: sunStart, end: plan.ringAt });
  out.push({ phase: 'ring', start: plan.ringAt, end: Infinity });
  return out.filter((p) => p.end > p.start);
}

/** {phase, k (0..1 progress; 0 for the open-ended last phase), start, end} at time t. */
export function phaseAt(plan, t) {
  const list = phasesOf(plan);
  if (t < plan.t0) return { phase: 'off', k: 0, start: -Infinity, end: plan.t0 };
  for (const p of list) {
    if (t < p.end) return { ...p, k: p.end === Infinity ? 0 : (t - p.start) / (p.end - p.start) };
  }
  return { ...list[list.length - 1], k: 0 };
}

const NIGHT_FIRE = 0.14;   // the bed's heat at night (a few clusters only)
const NIGHT_HUM = 0.07;    // the hum at night when nightSound is "hum"

/**
 * Everything that changes slowly with the phase, at time t (pure; only + − × ÷):
 *  fire (bed heat 0..1), night (0..1 blend to the night clusters), sun (sunrise light 0..1), shimmer (0..1),
 *  sound (0..1 master level of the fire sounds), alarm (0..1 alarm level, ramps over rampMs), and event rates per
 *  second: crackle, spark (share of crackles that throw one), log, flare, gust, chirp, chime.
 */
export function levelsAt(plan, t) {
  const p = phaseAt(plan, t);
  const L = { phase: p.phase, k: p.k, fire: 0, night: 0, sun: 0, shimmer: 0, sound: 0, alarm: 0, crackle: 0, spark: 0, log: 0, flare: 0, gust: 0, chirp: 0, chime: 0 };
  if (p.phase === 'off') return L;
  // Sound fades on its own (longer) clock from the end of settle.
  const sStart = plan.t0 + plan.settleMs;
  const sk = clamp01((t - sStart) / plan.soundFadeMs);
  const nightSound = plan.nightSound === 'off' ? 0 : NIGHT_HUM;
  const fireSound = t < sStart ? 1 : lerp(1, nightSound, easeOut(sk));
  if (p.phase === 'settle' || p.phase === 'fade') {
    const f = p.phase === 'settle' ? 0 : 1 - (1 - p.k) * (1 - p.k); // ease-out, gentler than the sound
    L.fire = lerp(1, NIGHT_FIRE, f);
    L.night = p.phase === 'settle' ? 0 : smooth(clamp01((p.k - 0.45) / 0.55));
    L.shimmer = p.phase === 'settle' ? 1 : clamp01(1 - p.k * 2);
    L.sound = fireSound;
    const live = (L.fire - NIGHT_FIRE) / (1 - NIGHT_FIRE); // 1 → 0 over the fade
    L.crackle = 1.7 * live * live + 0.05 * live;
    L.spark = 0.4 * live;
    L.log = 0.022 * live * live;
    L.flare = 0.35 * live + 0.03;
    L.gust = 0.025 * live;
  } else if (p.phase === 'night') {
    L.fire = NIGHT_FIRE; L.night = 1; L.sound = fireSound;
    L.flare = 0.03; // the clusters brighten now and then; no sparks, no crackles
  } else if (p.phase === 'sunrise') {
    L.sun = easeIn(p.k) * 0.55 + p.k * 0.45; // starts gently, reaches 1 at the alarm
    L.fire = lerp(NIGHT_FIRE, 1, smooth(clamp01(p.k * 1.6)));
    L.night = 1 - smooth(clamp01(p.k * 2.5));
    L.flare = 0.08 + 0.3 * p.k;
  } else if (p.phase === 'ring') {
    L.sun = 1; L.fire = 1; L.flare = 0.3;
    const rk = clamp01((t - plan.ringAt) / plan.rampMs);
    L.alarm = 0.08 + 0.92 * smooth(rk);
    if (plan.alarmSound === 'chime') L.chime = 1 / 9;
    else L.chirp = 0.25 + 2.2 * rk * rk;
  }
  return L;
}

// ---- events
const KINDS = Object.keys(KIND);
const rateKey = { crackle: 'crackle', log: 'log', flare: 'flare', gust: 'gust', chirp: 'chirp', chime: 'chime' };

/** A random scene x on one of the screens (not in a gap): [x, member index]. */
function onScreen(layout, r1, r2, margin = 0.02) {
  const i = Math.min(layout.length - 1, Math.floor(r1 * layout.length));
  return [layout[i].x0 + margin + r2 * (1 - 2 * margin), i];
}

/**
 * A spark's path parameters, born at (x, y) at time t. Sometimes (more than one screen, born near an inner edge)
 * it is aimed across the gap at the neighbour: then `cross` is the neighbour's id.
 */
function makeSpark(id, t, x, y, layout, i, rnd) {
  const life = 2600 + rnd() * 3800;
  let vx = (rnd() - 0.5) * 0.05;
  let cross = null;
  const m = layout[i];
  const wantCross = layout.length > 1 && rnd() < 0.3;
  if (wantCross) {
    const right = i < layout.length - 1 && (i === 0 || rnd() < 0.5);
    const n = layout[right ? i + 1 : i - 1];
    // Re-seat near the facing edge, then a drift that clears the gap with ~0.1–0.3 units to spare inside its life.
    x = right ? m.x1 - 0.02 - rnd() * 0.12 : m.x0 + 0.02 + rnd() * 0.12;
    const dist = (right ? m.x1 - x : x - m.x0) + GAP + 0.1 + rnd() * 0.2;
    vx = (right ? 1 : -1) * dist / (life / 1000) * 1.15;
    cross = n.id;
  }
  return {
    id, kind: 'spark', t, x, y, life, vx,
    vy: 0.10 + rnd() * 0.16,        // screen heights per second, slowing as it cools
    wob: 0.004 + rnd() * 0.01,      // side wobble amplitude (render only)
    wf: 1.5 + rnd() * 3, ph: rnd() * 6.283,
    size: 0.7 + rnd() * 0.6,
    cross,
  };
}

function slotEvents(seed, kind, slot, plan, layout) {
  const ts = plan.t0 + slot * SLOT_MS;
  const L = levelsAt(plan, ts);
  const rate = L[rateKey[kind]];
  if (!(rate > 0)) return [];
  const rnd = stream(seed, KIND[kind], slot);
  if (rnd() >= rate * SLOT_MS / 1000) return [];
  const t = ts + rnd() * SLOT_MS;
  const id = `${kind}:${slot}`;
  const out = [];
  if (kind === 'crackle') {
    const [x, i] = onScreen(layout, rnd(), rnd());
    const y = 0.06 + rnd() * 0.16;
    const ev = { id, kind, t, x, y, amp: 0.25 + rnd() * rnd() * 0.75, variant: Math.floor(rnd() * 16), spark: false };
    out.push(ev);
    if (rnd() < L.spark) {
      ev.spark = true;
      const s = makeSpark(`${id}.s`, t, x, y + 0.04, layout, i, rnd);
      ev.x = s.x; // a spark aimed across the gap is re-seated at the edge: the crackle (its sound) goes with it
      out.push(s);
    }
  } else if (kind === 'log') {
    const [x, i] = onScreen(layout, rnd(), rnd(), 0.12);
    const ev = { id, kind, t, x, y: 0.1, amp: 0.6 + rnd() * 0.4, variant: Math.floor(rnd() * 6), sparks: 3 + Math.floor(rnd() * 5) };
    out.push(ev);
    for (let n = 0; n < ev.sparks; n++) {
      const dt = rnd() * 450;
      out.push(makeSpark(`${id}.${n}`, t + dt, x + (rnd() - 0.5) * 0.08, 0.16 + rnd() * 0.06, layout, i, rnd));
    }
  } else if (kind === 'flare') {
    let x, y;
    if (L.night > 0.5) { // at night only the clusters glow up
      const c = nightCoals(seed, layout);
      const n = c[Math.floor(rnd() * c.length)];
      x = n.x + (rnd() - 0.5) * n.r; y = n.y;
    } else { [x] = onScreen(layout, rnd(), rnd()); y = 0.05 + rnd() * 0.15; }
    out.push({ id, kind, t, x, y, amp: 0.3 + rnd() * 0.7, dur: 2500 + rnd() * 4000, r: 0.05 + rnd() * 0.08 });
  } else if (kind === 'gust') {
    out.push({ id, kind, t, x: rnd() * (layout[layout.length - 1].x1), y: 0.5, amp: 0.4 + rnd() * 0.6, dur: 3000 + rnd() * 5000 });
  } else if (kind === 'chirp') {
    const [x] = onScreen(layout, rnd(), rnd(), 0.08);
    const notes = 1 + Math.floor(rnd() * 5);
    out.push({ id, kind, t, x, y: 0.5 + rnd() * 0.38, species: Math.floor(rnd() * 3), notes, f0: 2600 + rnd() * 2600,
      sweep: (rnd() - 0.35) * 2200, gapMs: 60 + rnd() * 90, noteMs: 45 + rnd() * 70, amp: 0.4 + rnd() * 0.6 });
  } else if (kind === 'chime') {
    const [x] = onScreen(layout, rnd(), 0.5);
    out.push({ id, kind, t, x, y: 0.6, f0: [392, 440, 523.25, 587.33][Math.floor(rnd() * 4)], amp: 0.6 + rnd() * 0.4 });
  }
  return out;
}

/** All events whose time falls in [a, b), sorted by time (sparks of a log may start up to 450 ms after it). */
export function eventsIn(session, plan, layout, a, b) {
  const out = [];
  const k0 = Math.floor((a - 500 - plan.t0) / SLOT_MS), k1 = Math.floor((b - plan.t0) / SLOT_MS);
  for (const kind of KINDS) {
    for (let k = Math.max(0, k0); k <= k1; k++) {
      for (const ev of slotEvents(session.seed, kind, k, plan, layout)) if (ev.t >= a && ev.t < b) out.push(ev);
    }
  }
  return out.sort((p, q) => p.t - q.t || (p.id < q.id ? -1 : 1));
}

/** Night clusters: two per screen at seeded places in the bed: [{x, y, r, ph}] in scene units. */
export function nightCoals(seed, layout) {
  const out = [];
  layout.forEach((m, i) => {
    const rnd = stream(seed, 99, i);
    for (let n = 0; n < 2; n++) {
      out.push({ x: m.x0 + 0.15 + (n * 0.45) + rnd() * 0.25, y: 0.05 + rnd() * 0.05, r: 0.05 + rnd() * 0.04, ph: rnd() });
    }
  });
  return out;
}

/** Where a spark is at time t: {x, y, heat 0..1, vx, vy} in scene units, or null before birth / after death. */
export function sparkAt(ev, t) {
  const tau = (t - ev.t) / 1000;
  const life = ev.life / 1000;
  if (tau < 0 || tau > life) return null;
  const u = tau / life;
  const x = ev.x + ev.vx * tau + ev.wob * Math.sin(tau * ev.wf + ev.ph);
  const y = ev.y + ev.vy * tau * (1 - 0.35 * u);
  const vx = ev.vx + ev.wob * ev.wf * Math.cos(tau * ev.wf + ev.ph);
  const vy = ev.vy * (1 - 0.7 * u);
  const flash = tau < 0.12 ? 1 + (0.12 - tau) * 4 : 1;
  const heat = Math.pow(1 - u, 1.4) * flash;
  return { x, y, heat, vx, vy };
}

/**
 * The timeline of one machine: caches 2 s windows of events (a frame asks for the last ~7 s every time).
 * session {seed, t0, members:[{id, side, distance}]}, me: this machine's id.
 */
export function createTimeline(session, plan, me) {
  const layout = layoutOf(session.members);
  const WIN = 2000;
  const cache = new Map();
  const win = (i) => {
    let w = cache.get(i);
    if (!w) {
      w = eventsIn(session, plan, layout, plan.t0 + i * WIN, plan.t0 + (i + 1) * WIN);
      cache.set(i, w);
      if (cache.size > 16) cache.delete(cache.keys().next().value);
    }
    return w;
  };
  return {
    session, plan, layout, me,
    mine: layout.find((m) => m.id === me),
    levels: (t) => levelsAt(plan, t),
    phase: (t) => phaseAt(plan, t),
    spatial: (x) => spatial(layout, me, x),
    coals: nightCoals(session.seed, layout),
    /** Events in [a, b) from the cache (sorted). */
    between(a, b) {
      const out = [];
      for (let i = Math.floor((a - plan.t0) / WIN); i <= Math.floor((b - plan.t0) / WIN); i++) {
        for (const ev of win(i)) if (ev.t >= a && ev.t < b) out.push(ev);
      }
      return out;
    },
    /** Events that may still be visible at t (born in the last LIFE_MAX_MS). */
    live(t) { return this.between(t - LIFE_MAX_MS, t + 1); },
    /** Time of the first event after t (within `ms`), or null. */
    next(t, ms = 4000) { const e = this.between(t + 0.001, t + ms); return e.length ? e[0].t : null; },
  };
}
