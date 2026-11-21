// Sleep mode sound (PLAN.md §21 E-2, S1 draft): WebAudio synthesis, no files, no network.
// Layers: coal hum (brown noise through a low-pass, very quiet), crackles (one per timeline crackle, same timestamp as
// the pop on screen), rarer deep log cracks, an optional wind layer (swells with the timeline's gusts) and rain;
// the alarm: birds (FM chirps, sparse → dense) or a soft chime, each one paired with a light mote on screen.
// Spatial: each event has a scene position; timeline.spatial() turns it into this machine's gain (equal-power
// cross-fade between machines, distance balance) and an in-machine stereo pan. A spark that crosses to the other
// screen carries a faint hiss whose gain/pan follow its path, so its sound moves between machines with it.
//
// Cost (see focus/sound.js for the laptop numbers that set this design): noise is generated once into buffers and
// looped by AudioBufferSourceNodes (no AudioWorklet computing every block); crackles/logs are pre-rendered variants,
// each event is one buffer source → gain → panner, scheduled ahead: every 2 s the next 4 s. latencyHint "playback"
// (large buffers). When nothing is audible (night with nightSound "off", sunrise) the context is suspended, and
// resumed 60 s before the alarm.
// Sync: the timeline speaks the shared clock (epoch ms + the group's offset). ctxTimeFor() maps it to AudioContext
// time through getOutputTimestamp() (the context time leaving the speaker at a performance.now() instant; latency
// included), else currentTime − outputLatency.
//
// Alarm (S4): the plan's ring spans give the alarm bus its level (ramp from each ring's start, quiet after the
// auto-stop); `alarmGain` scales the birds/chime on this machine (0 while Velour plays the song on the leader, 0.4 on
// the other members of a Velour alarm). A plan change (snooze, dismiss) re-plans at once: the alarm bus follows the
// new plan within 0.3 s, so chirps already scheduled past a snooze are not heard.
// Ducking (S5): while the leader's Velour sleep playlist plays, the fire bus (hum, crackles, logs, wind, rain; not the
// alarm) sits DUCK_DB (−12 dB) lower: down in DUCK_DOWN_S, back up slowly (DUCK_UP_S) when the music ends.
// createAudio(tl, {now, offsetMs, volume, layers, trace, alarmGain, duck}) → {start(), tick(), replan(), setAlarmGain(g),
//   setDuck(on), unlock(), pause(), resume(), destroy(), state}
// trace (test only, S3 sync measurement): every crackle's planned onset is reported once it has played as
// ['a', id, eventT, wall, outputLatencyMs]: `wall` = when it left the speaker on this host's Date.now() clock, from a
// fresh getOutputTimestamp() (else currentTime + outputLatency), so a stale clock mapping shows up as an error.
// renderOffline(tl, {from, seconds, ...}) → {buffer, events}: the same graph in an OfflineAudioContext (tests).

const ALARM_LEAD_MS = 60_000;
export const DUCK_DB = -12;
export const DUCK_GAIN = 10 ** (DUCK_DB / 20);
export const DUCK_DOWN_S = 3;
export const DUCK_UP_S = 20;

/** Ramps a duck gain param from where it is now: to DUCK_GAIN (on) or 1 (off). */
export function duckRamp(param, on, t) {
  param.cancelScheduledValues(t);
  param.setValueAtTime(param.value, t);
  param.linearRampToValueAtTime(on ? DUCK_GAIN : 1, t + (on ? DUCK_DOWN_S : DUCK_UP_S));
}

// ---- clock mapping (pure)
/**
 * AudioContext time at which a shared-clock instant T (ms) should leave the speaker.
 * o: {perfNow, dateNow, offsetMs, ts: getOutputTimestamp() | null, currentTime, outputLatency}
 */
export function ctxTimeFor(T, o) {
  const perfT = T - o.offsetMs - (o.dateNow - o.perfNow); // T on the performance.now() clock
  if (o.ts && o.ts.performanceTime > 0) return o.ts.contextTime + (perfT - o.ts.performanceTime) / 1000;
  return o.currentTime + (perfT - o.perfNow) / 1000 - (o.outputLatency || 0);
}

/** 0..100 → gain, squared so the low end stays usable. */
export const level = (v) => Math.pow(Math.max(0, Math.min(100, v)) / 100, 2);

// ---- sample synthesis (seeded; the same on every machine, though nothing depends on that)
function rng(seed) {
  let s = seed >>> 0;
  return () => ((s = (Math.imul(s, 1664525) + 1013904223) >>> 0) / 4294967296) * 2 - 1;
}
function normalize(a, peak = 1) {
  let m = 0;
  for (const v of a) m = Math.max(m, Math.abs(v));
  if (m) for (let i = 0; i < a.length; i++) a[i] *= peak / m;
  return a;
}
function loopNoise(kind, rate, sec, seed) {
  const n = Math.round(sec * rate), seam = Math.round(0.5 * rate);
  const raw = new Float32Array(n + seam), w = rng(seed);
  if (kind === 'brown') { let b = 0; for (let i = 0; i < raw.length; i++) { b = (b + 0.02 * w()) / 1.02; raw[i] = b; } }
  else {
    let b0 = 0, b1 = 0, b2 = 0;
    for (let i = 0; i < raw.length; i++) {
      const x = w();
      b0 = 0.99765 * b0 + x * 0.099046; b1 = 0.963 * b1 + x * 0.2965164; b2 = 0.57 * b2 + x * 1.0526913;
      raw[i] = b0 + b1 + b2 + x * 0.1848;
    }
    if (kind === 'rain') {
      let lp = 0;
      for (let i = 0; i < raw.length; i++) { lp += 0.2 * (raw[i] - lp); raw[i] = lp * 0.5; }
      const d = rng(seed + 1);
      for (let k = 0, drops = Math.round(sec * 30); k < drops; k++) {
        const at = Math.floor(((d() + 1) / 2) * (raw.length - rate * 0.02));
        const amp = ((d() + 1) / 2) ** 3 * 0.8, len = Math.round(rate * (0.004 + 0.006 * (d() + 1) / 2));
        let prev = 0;
        for (let j = 0; j < len; j++) { const x = d(); raw[at + j] += (x - prev) * amp * Math.exp(-6 * j / len); prev = x; }
      }
    }
  }
  const out = raw.subarray(0, n);
  for (let i = 0; i < seam; i++) { const k = i / seam; out[i] = out[i] * k + raw[n + i] * (1 - k); }
  let mean = 0; for (const v of out) mean += v; mean /= n;
  for (let i = 0; i < n; i++) out[i] -= mean;
  return normalize(Float32Array.from(out), 0.9);
}
/** One click: a few ms of differenced noise plus a short resonant ring; written into `a` from `at`. */
function click(a, at, rate, amp, w, f) {
  const len = Math.round(rate * (0.0015 + 0.004 * Math.abs(w())));
  const ringLen = Math.round(rate * 0.012);
  let prev = 0;
  for (let j = 0; j < len + ringLen && at + j < a.length; j++) {
    let v = 0;
    if (j < len) { const x = w(); v += (x - prev) * Math.exp(-5 * j / len); prev = x; }
    v += 0.35 * Math.sin(2 * Math.PI * f * j / rate) * Math.exp(-j / (rate * 0.0025));
    a[at + j] += v * amp;
  }
}
/** A crackle: 1–5 clicks over ~10–220 ms, the loudest first (its onset is sample 0). */
function crackleBuf(rate, variant) {
  const w = rng(0xc4a0 + variant * 7919);
  const a = new Float32Array(Math.round(rate * 0.3));
  const n = 1 + Math.floor(((w() + 1) / 2) * 5);
  click(a, 0, rate, 1, w, 1800 + 2400 * (w() + 1) / 2);
  for (let k = 1; k < n; k++) {
    const at = Math.round(rate * (0.008 + 0.2 * ((w() + 1) / 2) ** 2));
    click(a, at, rate, 0.15 + 0.4 * (w() + 1) / 2, w, 1500 + 3000 * (w() + 1) / 2);
  }
  return normalize(a);
}
/** A log crack: a low thump, a hard crack and a trickle of small crackles over ~1 s. */
function logBuf(rate, variant) {
  const w = rng(0x1065 + variant * 104729);
  const a = new Float32Array(Math.round(rate * 1.4));
  const f = 55 + 30 * (w() + 1) / 2;
  let lp = 0;
  for (let j = 0; j < rate * 0.5; j++) {
    lp += 0.04 * (w() - lp);
    a[j] += (Math.sin(2 * Math.PI * f * j / rate) * 0.9 + lp * 3) * Math.exp(-j / (rate * 0.11));
  }
  click(a, 0, rate, 1.4, w, 900 + 600 * (w() + 1) / 2);
  click(a, Math.round(rate * 0.012), rate, 0.8, w, 1400);
  for (let k = 0; k < 9; k++) click(a, Math.round(rate * (0.05 + 1.1 * ((w() + 1) / 2) ** 1.5)), rate, 0.1 + 0.25 * (w() + 1) / 2, w, 1500 + 3000 * (w() + 1) / 2);
  return normalize(a);
}
/** A soft hiss for a spark crossing screens (high-passed noise, 1 s, looped). */
function fizzBuf(rate) {
  const w = rng(0xf122), a = new Float32Array(rate);
  let prev = 0;
  for (let i = 0; i < a.length; i++) { const x = w(); a[i] = x - prev * 0.97; prev = x; }
  return normalize(a, 0.5);
}
/** A bird call from the event's parameters (FM chirps). */
export function chirpSamples(ev, rate) {
  const note = ev.noteMs / 1000, gap = ev.gapMs / 1000;
  const n = Math.round(rate * (ev.notes * (note + gap) + 0.02));
  const a = new Float32Array(n);
  const fm = [38, 55, 24][ev.species], dev = [0.06, 0.12, 0.03][ev.species];
  for (let k = 0; k < ev.notes; k++) {
    const at = Math.round(rate * k * (note + gap)), len = Math.round(rate * note);
    const down = k % 2 === 1 && ev.species === 1;
    let ph = 0;
    for (let j = 0; j < len && at + j < n; j++) {
      const u = j / len;
      const f = ev.f0 * (1 + dev * Math.sin(2 * Math.PI * fm * j / rate)) + ev.sweep * (down ? 1 - u : u) * (ev.species === 2 ? 0.4 : 1);
      ph += 2 * Math.PI * f / rate;
      const env = Math.sin(Math.PI * u) ** 2;
      a[at + j] += Math.sin(ph) * env * (k === 0 ? 1 : 0.8);
    }
  }
  return normalize(a, 1);
}
/** A soft bell: inharmonic partials with long decays. */
function chimeSamples(f0, rate) {
  const a = new Float32Array(Math.round(rate * 6));
  const parts = [[1, 1, 2.2], [2.01, 0.35, 1.4], [2.76, 0.2, 1.0], [5.4, 0.08, 0.5]];
  for (let j = 0; j < a.length; j++) {
    const t = j / rate, att = Math.min(1, t / 0.006);
    let v = 0;
    for (const [m, g, d] of parts) v += g * Math.sin(2 * Math.PI * f0 * m * t) * Math.exp(-t / d);
    a[j] = v * att;
  }
  return normalize(a, 1);
}

// ---- the graph (shared by the live context and the offline renderer)
const EV_GAIN = { crackle: 0.5, log: 0.75, chirp: 0.32, chime: 0.3, fizz: 0.05 };

function buildGraph(ac, { volume = 35, layers = {} }) {
  const rate = ac.sampleRate;
  const buf = (data) => { const b = ac.createBuffer(1, data.length, rate); b.copyToChannel(data, 0); return b; };
  const master = ac.createGain(); master.gain.value = level(volume); master.connect(ac.destination);
  const duck = ac.createGain(); duck.gain.value = 1; duck.connect(master);
  const fire = ac.createGain(); fire.gain.value = 0; fire.connect(duck);
  const alarm = ac.createGain(); alarm.gain.value = 0; alarm.connect(master);
  const loop = (data, filter, gain) => {
    const src = ac.createBufferSource(); src.buffer = buf(data); src.loop = true;
    const g = ac.createGain(); g.gain.value = gain;
    src.connect(filter); filter.connect(g); g.connect(fire);
    src.start(0);
    return { src, g };
  };
  const L = { hum: true, crackle: true, logs: true, wind: false, rain: false, ...layers };
  const g = { ac, rate, master, duck, fire, alarm, L, nodes: [], chimes: new Map(), alarmGain: 1 };
  if (L.hum) {
    const lp = ac.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 170; lp.Q.value = 0.5;
    g.hum = loop(loopNoise('brown', rate, 8, 0x4a11), lp, 0.22);
  }
  if (L.wind) {
    const bp = ac.createBiquadFilter(); bp.type = 'bandpass'; bp.frequency.value = 380; bp.Q.value = 0.6;
    g.wind = loop(loopNoise('pink', rate, 11, 0x3d1d), bp, 0.05);
    g.windBp = bp;
  }
  if (L.rain) {
    const lp = ac.createBiquadFilter(); lp.type = 'lowpass'; lp.frequency.value = 5000;
    g.rain = loop(loopNoise('rain', rate, 12, 0x2a17), lp, 0.07);
  }
  g.crackles = Array.from({ length: 16 }, (_, i) => buf(crackleBuf(rate, i)));
  g.logs = Array.from({ length: 6 }, (_, i) => buf(logBuf(rate, i)));
  g.fizz = buf(fizzBuf(rate));
  g.buf = buf;
  return g;
}

/** Plays one sample buffer at ctx time c with a gain and a pan; the nodes disconnect themselves when done. */
function voice(g, b, c, gain, pan, bus, rate = 1) {
  const src = g.ac.createBufferSource(); src.buffer = b; src.playbackRate.value = rate;
  const v = g.ac.createGain(); v.gain.value = gain;
  const p = g.ac.createStereoPanner(); p.pan.value = pan;
  src.connect(v); v.connect(p); p.connect(bus);
  src.onended = () => { src.disconnect(); v.disconnect(); p.disconnect(); };
  src.start(Math.max(0, c));
  return { src, v, p };
}

/** Schedules the sound of one timeline event at ctx time c. Returns true if something was played. */
function playEvent(g, tl, ev, c) {
  const { gain, pan } = tl.spatial(ev.x);
  if (ev.kind === 'crackle' && g.L.crackle) {
    if (gain < 0.01) return false;
    voice(g, g.crackles[ev.variant], c, EV_GAIN.crackle * ev.amp * gain, pan, g.fire);
    return true;
  }
  if (ev.kind === 'log' && g.L.logs) {
    if (gain < 0.01) return false;
    voice(g, g.logs[ev.variant], c, EV_GAIN.log * ev.amp * gain, pan, g.fire);
    return true;
  }
  if (ev.kind === 'spark' && ev.cross && g.L.crackle) {
    // The hiss follows the spark's path: gain and pan curves sampled every 100 ms of its life.
    const n = Math.max(2, Math.round(ev.life / 100)), gains = new Float32Array(n), pans = new Float32Array(n);
    for (let i = 0; i < n; i++) {
      const u = i / (n - 1), x = ev.x + ev.vx * u * ev.life / 1000;
      const s = tl.spatial(x);
      gains[i] = EV_GAIN.fizz * s.gain * (1 - u) ** 1.5 * Math.min(1, u * 8 + 0.2);
      pans[i] = s.pan;
    }
    const vce = voice(g, g.fizz, c, 0, 0, g.fire);
    vce.src.loop = true;
    const dur = ev.life / 1000, at = Math.max(c, g.ac.currentTime);
    vce.v.gain.setValueCurveAtTime(gains, at, dur);
    vce.p.pan.setValueCurveAtTime(pans, at, dur);
    vce.src.stop(at + dur + 0.05);
    return true;
  }
  if (ev.kind === 'gust' && g.wind) {
    const d = ev.dur / 1000, peak = 1 + 2.2 * ev.amp;
    const gg = g.wind.g.gain, f = g.windBp.frequency;
    gg.setValueAtTime(0.05, c); gg.linearRampToValueAtTime(0.05 * peak, c + d * 0.45); gg.linearRampToValueAtTime(0.05, c + d);
    f.setValueAtTime(380, c); f.linearRampToValueAtTime(380 + 420 * ev.amp, c + d * 0.45); f.linearRampToValueAtTime(380, c + d);
    return true;
  }
  if (ev.kind === 'chirp') {
    const rate = g.rate;
    const b = g.buf(chirpSamples(ev, rate));
    if (!(g.alarmGain > 0)) return false;
    voice(g, b, c, EV_GAIN.chirp * ev.amp * Math.max(gain, 0.15) * g.alarmGain, pan, g.alarm);
    return true;
  }
  if (ev.kind === 'chime') {
    if (!(g.alarmGain > 0)) return false;
    let b = g.chimes.get(ev.f0);
    if (!b) { b = g.buf(chimeSamples(ev.f0, g.rate)); g.chimes.set(ev.f0, b); }
    voice(g, b, c, EV_GAIN.chime * ev.amp * Math.max(gain, 0.3) * g.alarmGain, pan, g.alarm);
    return true;
  }
  return false;
}

/** Bus levels at shared time T, ramped to by ctx time c. */
function rampLevels(g, tl, T, c) {
  const L = tl.levels(T);
  g.fire.gain.linearRampToValueAtTime(L.sound, c);
  g.alarm.gain.linearRampToValueAtTime(L.alarm, c);
  return L;
}

export function createAudio(tl, { now, offsetMs = () => 0, volume = 35, layers = {}, trace = null, alarmGain = 1, duck = false } = {}) {
  let ac = null, g = null, timer = 0, paused = false, suspended = false, blocked = false;
  let gainNow = alarmGain, duckNow = duck;
  const done = new Set();
  let traced = []; // trace: [{id, t, c}] scheduled crackles not reported yet

  /** trace: the crackles whose onset has passed, with when they left the speaker (wall clock of this host). */
  function report() {
    if (!traced.length) return;
    const ts = ac.getOutputTimestamp ? ac.getOutputTimestamp() : null;
    const perf = performance.now(), wall = Date.now(), lat = ac.outputLatency ?? ac.baseLatency ?? 0;
    const playedBefore = ts && ts.performanceTime > 0 ? ts.contextTime : ac.currentTime - lat;
    const r1 = (v) => Math.round(v * 10) / 10;
    traced = traced.filter((x) => {
      if (x.c > playedBefore) return true;
      const outPerf = ts && ts.performanceTime > 0 ? ts.performanceTime + (x.c - ts.contextTime) * 1000 : perf + (x.c - ac.currentTime + lat) * 1000;
      trace(['a', x.id, r1(x.t), r1(wall - perf + outPerf), r1(lat * 1000)]);
      return false;
    });
  }
  let horizon = 0; // shared time up to which events are scheduled

  const clock = () => ({
    perfNow: performance.now(), dateNow: Date.now(), offsetMs: offsetMs(),
    ts: ac.getOutputTimestamp ? ac.getOutputTimestamp() : null,
    currentTime: ac.currentTime, outputLatency: ac.outputLatency ?? ac.baseLatency ?? 0,
  });

  /** Is anything audible around T (or the alarm coming soon)? */
  function wanted(T) {
    const a = tl.levels(T), b = tl.levels(T + 4000);
    const ringSoon = tl.plan.ringAt != null && T >= tl.plan.ringAt - ALARM_LEAD_MS;
    return a.sound > 0 || b.sound > 0 || a.alarm > 0 || ringSoon;
  }

  function tick() {
    clearTimeout(timer); timer = 0;
    if (paused || !ac) return;
    const T = now();
    const want = wanted(T);
    if (!want && !suspended && ac.state === 'running') {
      // Fade the buses out, then suspend: nothing plays (night "off", sunrise), the audio thread sleeps.
      const c = ac.currentTime;
      g.fire.gain.cancelScheduledValues(c); g.fire.gain.setValueAtTime(g.fire.gain.value, c); g.fire.gain.linearRampToValueAtTime(0, c + 1);
      setTimeout(() => { if (!wanted(now())) { ac.suspend(); suspended = true; } }, 1300);
    } else if (want && (suspended || ac.state === 'suspended')) {
      suspended = false;
      ac.resume().then(() => { blocked = false; }, () => { blocked = true; });
    }
    if (want && ac.state === 'running') {
      if (trace) report();
      const o = clock();
      const from = Math.max(T, horizon), to = T + 4000;
      const map = (t) => ctxTimeFor(t, o);
      rampLevels(g, tl, T + 2000, map(T + 2000));
      for (const ev of tl.between(from, to)) {
        if (done.has(ev.id)) continue;
        done.add(ev.id);
        const c = map(ev.t);
        if (c < ac.currentTime - 0.03) continue; // too late (page was busy): skip rather than play it off-sync
        if (trace && ev.kind === 'crackle' && traced.length < 500) traced.push({ id: ev.id, t: ev.t, c });
        playEvent(g, tl, ev, c);
      }
      horizon = to;
      if (done.size > 4000) done.clear();
    }
    timer = setTimeout(tick, 2000);
  }

  return {
    get state() { return { ctx: ac?.state ?? 'none', blocked, suspended }; },
    /** Creates the context (autoplay may leave it suspended until a key press: then unlock()). */
    start() {
      if (ac) return;
      ac = new AudioContext({ latencyHint: 'playback' });
      g = buildGraph(ac, { volume, layers });
      g.alarmGain = gainNow;
      g.duck.gain.value = duckNow ? DUCK_GAIN : 1;
      if (ac.state !== 'running') ac.resume().then(() => { blocked = false; tick(); }, () => { blocked = true; });
      blocked = ac.state !== 'running';
      tick();
    },
    unlock() { if (ac && ac.state !== 'running' && !suspended) ac.resume().then(() => { blocked = false; tick(); }); },
    /** Re-plans at once (phase change): drops nothing already scheduled. */
    tick,
    /** The plan changed (tl.setPlan): the alarm bus jumps to the new level (a snooze silences what was scheduled). */
    replan() {
      if (ac && g && ac.state === 'running') {
        const c = ac.currentTime, L = tl.levels(now());
        g.alarm.gain.cancelScheduledValues(c); g.alarm.gain.setValueAtTime(g.alarm.gain.value, c); g.alarm.gain.linearRampToValueAtTime(L.alarm, c + 0.3);
        g.fire.gain.cancelScheduledValues(c); g.fire.gain.setValueAtTime(g.fire.gain.value, c); g.fire.gain.linearRampToValueAtTime(L.sound, c + 0.3);
      }
      horizon = 0;
      tick();
    },
    /** This machine's share of the birds/chime (0..1). */
    setAlarmGain(v) { gainNow = Number.isFinite(v) ? Math.max(0, Math.min(1, v)) : 1; if (g) g.alarmGain = gainNow; },
    /** Music on the leader (S5): the fire bus ducks −12 dB, back up slowly after. */
    setDuck(on) {
      on = on === true;
      if (on === duckNow) return;
      duckNow = on;
      if (g && ac) duckRamp(g.duck.gain, on, ac.currentTime);
    },
    get ducked() { return duckNow; },
    pause() { paused = true; clearTimeout(timer); if (ac?.state === 'running') ac.suspend(); },
    resume() { if (!paused) return; paused = false; horizon = 0; if (ac) ac.resume().then(tick); },
    destroy() { paused = true; clearTimeout(timer); ac?.close(); ac = null; },
  };
}

/**
 * Test hook: renders [from, from + seconds) of the timeline offline. Returns {buffer, events: [{id, kind, t, at}]}
 * where `at` is the planned onset in seconds from the start of the render.
 */
export async function renderOffline(tl, { from, seconds = 30, sampleRate = 48000, volume = 100, layers = {}, alarmGain = 1 }) {
  const ac = new OfflineAudioContext(2, Math.round(seconds * sampleRate), sampleRate);
  const g = buildGraph(ac, { volume, layers });
  g.alarmGain = alarmGain;
  const map = (t) => (t - from) / 1000;
  const L0 = tl.levels(from);
  g.fire.gain.setValueAtTime(L0.sound, 0); g.alarm.gain.setValueAtTime(L0.alarm, 0);
  for (let s = 0.5; s <= seconds; s += 0.5) rampLevels(g, tl, from + s * 1000, s);
  const events = [];
  for (const ev of tl.between(from, from + seconds * 1000)) {
    if (playEvent(g, tl, ev, map(ev.t))) events.push({ id: ev.id, kind: ev.kind, t: ev.t, at: map(ev.t), x: ev.x, amp: ev.amp ?? null, gain: tl.spatial(ev.x).gain });
  }
  const buffer = await ac.startRendering();
  return { buffer, events };
}

/** 16-bit PCM WAV of an AudioBuffer. */
export function toWav(buffer) {
  const ch = buffer.numberOfChannels, n = buffer.length, rate = buffer.sampleRate;
  const out = new DataView(new ArrayBuffer(44 + n * ch * 2));
  const str = (o, s) => [...s].forEach((c, i) => out.setUint8(o + i, c.charCodeAt(0)));
  str(0, 'RIFF'); out.setUint32(4, 36 + n * ch * 2, true); str(8, 'WAVE'); str(12, 'fmt ');
  out.setUint32(16, 16, true); out.setUint16(20, 1, true); out.setUint16(22, ch, true); out.setUint32(24, rate, true);
  out.setUint32(28, rate * ch * 2, true); out.setUint16(32, ch * 2, true); out.setUint16(34, 16, true);
  str(36, 'data'); out.setUint32(40, n * ch * 2, true);
  const data = Array.from({ length: ch }, (_, c) => buffer.getChannelData(c));
  let o = 44;
  for (let i = 0; i < n; i++) for (let c = 0; c < ch; c++) { out.setInt16(o, Math.max(-1, Math.min(1, data[c][i])) * 32767, true); o += 2; }
  return out.buffer;
}
