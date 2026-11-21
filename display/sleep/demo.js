// S1 demo page for the sleep view (PLAN.md §21 S1): stands in for the agent (S2) and the group (S3).
// URL parameters:
//   ?phase=settle|fade|night|sunrise|ring|morning  start inside that phase (real durations), ?p=0..1 how far in
//   ?fast=1        the whole night compressed: settle 15 s → fade 30 s → night 30 s → sunrise 30 s → ring (≈ 2 min)
//   ?side=left|right&peer=1   be one of two screens (a spark aimed at the peer leaves this screen's edge)
//   ?distance=near|mid|far, ?brightness=0..1, ?audio=0, ?volume=0..100, ?layers=wind,rain, ?alarm=birds|chime
//   ?seed=N, ?nightSound=off, ?test=1 (exposes window.__sleep for the headless checks)
import { mount } from './sleep.js';
import { createTimeline } from './timeline.js';
import { renderOffline, toWav } from './audio.js';

const q = new URLSearchParams(location.search);
const MIN = 60_000;
const num = (k, d) => (q.has(k) && Number.isFinite(+q.get(k)) ? +q.get(k) : d);

/** Default (real) durations from PLAN §21 Kararlar 4; fast = the ~2 minute walk through every phase. */
export function planFor({ phase = 'settle', p = null, fast = false, now, alarmSound = 'birds', nightSound = 'hum' }) {
  const d = fast
    ? { settle: 15_000, fade: 30_000, soundFade: 45_000, night: 30_000, sunrise: 30_000, ramp: 10_000 }
    : { settle: 3 * MIN, fade: 30 * MIN, soundFade: 45 * MIN, night: 480 * MIN - 33 * MIN - 25 * MIN, sunrise: 25 * MIN, ramp: 3 * MIN };
  const startOf = { settle: 0, fade: d.settle, night: d.settle + d.fade, sunrise: d.settle + d.fade + d.night };
  startOf.ring = startOf.sunrise + d.sunrise;
  const len = { ...d, ring: d.ramp };
  const P = p ?? { settle: 0.5, fade: 0.35, night: 0.5, sunrise: 0.6, ring: 0.4 }[phase] ?? 0;
  const t0 = Math.round(fast && p == null && phase === 'settle' ? now : now - (startOf[phase] ?? 0) - P * len[phase]);
  return {
    t0, settleMs: d.settle, fadeMs: d.fade, soundFadeMs: d.soundFade, nightSound,
    sunriseAt: t0 + startOf.sunrise, ringAt: t0 + startOf.ring, rampMs: d.ramp, alarmSound,
  };
}

const side = q.get('side') === 'right' ? 'right' : 'left';
const members = [{ id: 'bu', side, distance: q.get('distance') ?? 'mid' }];
if (q.get('peer') === '1') members.push({ id: 'eş', side: side === 'left' ? 'right' : 'left', distance: 'mid' });
const phaseQ = q.get('phase') ?? 'settle';
const fast = q.get('fast') === '1';
const seed = num('seed', 0x51ee9) >>> 0;
const now = () => Date.now();
const layerList = (q.get('layers') ?? '').split(',').filter(Boolean);
const layers = { wind: layerList.includes('wind'), rain: layerList.includes('rain') };
const plan = planFor({ phase: phaseQ === 'morning' ? 'ring' : phaseQ, p: q.has('p') ? num('p', 0) : null, fast, now: now(), alarmSound: q.get('alarm') ?? 'birds', nightSound: q.get('nightSound') ?? 'hum' });
const session = { seed, t0: plan.t0, members };

document.body.style.cursor = 'none';
const view = mount(document.getElementById('app'), {}, {
  session, plan, me: 'bu', now, offsetMs: () => 0,
  brightness: num('brightness', 1), audio: q.get('audio') !== '0', volume: num('volume', 35), layers,
  morning: phaseQ === 'morning',
  onStop: () => console.info('[sleep] stop (the agent will end the mode in S2)'),
  onAlarm: (a) => console.info('[sleep] alarm', a),
});
document.addEventListener('visibilitychange', () => (document.hidden ? view.pause() : view.resume()));

if (q.get('test') === '1') {
  // Headless checks: frame stats, and an offline render of N seconds of a phase to a WAV (base64) with the planned
  // onsets of what was scheduled.
  window.__sleep = {
    view, plan, session,
    async render({ phase, p = null, seconds = 30, layers: ly = {}, alarm = 'birds', nightSound = 'hum', volume = 100 }) {
      const T = Date.UTC(2026, 10, 21, 21, 0);
      const pl = planFor({ phase, p, now: T, alarmSound: alarm, nightSound });
      const tl = createTimeline({ seed, t0: pl.t0, members }, pl, 'bu');
      const { buffer, events } = await renderOffline(tl, { from: T, seconds, layers: ly, volume });
      const bytes = new Uint8Array(toWav(buffer));
      let bin = '';
      for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      return { wav: btoa(bin), events, rate: buffer.sampleRate };
    },
  };
}
