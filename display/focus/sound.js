// Focus mode sound (PLAN.md §20 A-3, E-3): ambient noise and the end-of-round chime, synthesized with WebAudio — no
// files, no network. Noise: a 12 s mono loop generated once per kind (the end cross-faded into the start: no click at
// the seam) and looped by one AudioBufferSourceNode → gain → output; an AudioWorklet would compute every block.
// Measured on the laptop (Firefox ESR + PipeWire): ~7.5 % of one core while playing, almost all of it Firefox's audio
// stack (pulse mainloop, audio IPC, graph thread) — the same at 16 kHz, and a looping <audio> WAV was worse (~19 %,
// its decoder pipeline). So the context runs at the device rate (no resampling anywhere) and exists only while
// something plays: fades are gain ramps (in 1.5 s, out 0.6 s), then the context is closed (the PipeWire stream goes
// away); the chime gets its own short-lived one.
// One per page: createSound(): {setAmbient({kind, volume, on}), chime(volume), stop()}.

const LOOP_SEC = 12, SEAM_SEC = 0.5, FADE_IN = 1.5, FADE_OUT = 0.6;

/** Seeded PRNG (the same loop each time; Math.random would do too). */
function rng(seed) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 4294967296) * 2 - 1;
}

/** Fills `n + seam` samples with the kind's noise, then folds the tail into the head (seamless loop of n). */
function synth(kind, rate) {
  const n = Math.round(LOOP_SEC * rate), seam = Math.round(SEAM_SEC * rate);
  const raw = new Float32Array(n + seam);
  const white = rng(0x7189);
  if (kind === 'brown') {
    let b = 0;
    for (let i = 0; i < raw.length; i++) { b = (b + 0.02 * white()) / 1.02; raw[i] = b; }
  } else {
    // Pink (Paul Kellet's economy filter).
    let b0 = 0, b1 = 0, b2 = 0;
    for (let i = 0; i < raw.length; i++) {
      const w = white();
      b0 = 0.99765 * b0 + w * 0.099046; b1 = 0.963 * b1 + w * 0.2965164; b2 = 0.57 * b2 + w * 1.0526913;
      raw[i] = b0 + b1 + b2 + w * 0.1848;
    }
    if (kind === 'rain') {
      // Soft, darker hiss (one-pole low-pass) + drops: short decaying bursts, mostly faint, now and then a near one.
      let lp = 0;
      for (let i = 0; i < raw.length; i++) { lp += 0.18 * (raw[i] - lp); raw[i] = lp * 0.55; }
      const drop = rng(0x2a17);
      const drops = Math.round(raw.length / rate * 38);
      for (let k = 0; k < drops; k++) {
        const at = Math.floor(((drop() + 1) / 2) * (raw.length - rate * 0.02));
        const amp = Math.pow((drop() + 1) / 2, 3) * 0.9;
        const len = Math.round(rate * (0.004 + 0.008 * ((drop() + 1) / 2)));
        let prev = 0;
        for (let j = 0; j < len; j++) {
          const w = drop();
          raw[at + j] += (w - prev) * amp * Math.exp(-6 * j / len); // differenced noise: a bright tick
          prev = w;
        }
      }
    }
  }
  const out = raw.subarray(0, n);
  for (let i = 0; i < seam; i++) { const k = i / seam; out[i] = out[i] * k + raw[n + i] * (1 - k); }
  let peak = 0, mean = 0;
  for (let i = 0; i < n; i++) mean += out[i];
  mean /= n;
  for (let i = 0; i < n; i++) { out[i] -= mean; peak = Math.max(peak, Math.abs(out[i])); }
  const g = peak ? 0.9 / peak : 1;
  for (let i = 0; i < n; i++) out[i] *= g;
  return out;
}

/** 0..100 → gain; squared, so the low end of the slider stays usable. */
const level = (v) => Math.pow(Math.max(0, Math.min(100, v)) / 100, 2) * 0.6;

export function createSound() {
  let ac = null, gain = null, src = null, srcKind = null, closing = 0, want = { kind: 'off', volume: 30, on: false };
  const buffers = new Map(); // kind → samples (kept across contexts; the device rate doesn't change)

  const playing = () => want.on && want.kind !== 'off' && want.volume > 0;

  function ramp(to, sec) {
    const t = ac.currentTime;
    gain.gain.cancelScheduledValues(t);
    gain.gain.setValueAtTime(gain.gain.value, t);
    gain.gain.linearRampToValueAtTime(to, t + sec);
  }

  function close() {
    clearTimeout(closing);
    closing = 0;
    if (ac) void ac.close().catch(() => {});
    ac = null; gain = null; src = null; srcKind = null;
  }

  function apply() {
    if (!playing()) {
      if (!ac || closing) return;
      ramp(0, FADE_OUT);
      closing = setTimeout(() => { closing = 0; if (!playing()) close(); }, FADE_OUT * 1000 + 100);
      return;
    }
    clearTimeout(closing);
    closing = 0;
    if (!ac) {
      ac = new AudioContext({ latencyHint: 'playback' });
      gain = ac.createGain();
      gain.gain.value = 0;
      gain.connect(ac.destination);
    }
    if (srcKind !== want.kind) {
      let data = buffers.get(want.kind);
      if (!data) buffers.set(want.kind, (data = synth(want.kind, ac.sampleRate)));
      const b = ac.createBuffer(1, data.length, ac.sampleRate);
      b.copyToChannel(data, 0);
      if (src) src.stop(ac.currentTime + 0.3); // another kind: the old loop ends as the new one starts
      src = ac.createBufferSource();
      src.buffer = b;
      src.loop = true;
      src.connect(gain);
      src.start(ac.currentTime + (srcKind ? 0.3 : 0));
      srcKind = want.kind;
    }
    void ac.resume();
    ramp(level(want.volume), FADE_IN);
  }

  return {
    /** kind: off|brown|pink|rain; volume 0..100; on: the timer is focusing and the page is shown, unveiled, quiet. */
    setAmbient(next) {
      const was = JSON.stringify(want);
      want = { ...want, ...next };
      if (JSON.stringify(want) !== was) apply();
    },
    /** A soft two-note bell (E5, B5) with a long decay; its own short-lived context. */
    chime(volume = 30) {
      const c = new AudioContext();
      const t0 = c.currentTime + 0.05;
      const peak = 0.05 + 0.15 * (Math.max(0, Math.min(100, volume)) / 100);
      [[659.25, 0], [987.77, 0.22]].forEach(([f, d]) => {
        for (const [mul, a] of [[1, 1], [2.01, 0.18]]) {
          const o = c.createOscillator(), g = c.createGain();
          o.frequency.value = f * mul;
          g.gain.setValueAtTime(0, t0 + d);
          g.gain.linearRampToValueAtTime(peak * a, t0 + d + 0.012);
          g.gain.exponentialRampToValueAtTime(0.0001, t0 + d + 2.4);
          o.connect(g).connect(c.destination);
          o.start(t0 + d);
          o.stop(t0 + d + 2.5);
        }
      });
      setTimeout(() => void c.close().catch(() => {}), 3000);
    },
    stop() { want = { ...want, on: false }; close(); buffers.clear(); },
    get state() { return ac?.state ?? 'closed'; },
  };
}
