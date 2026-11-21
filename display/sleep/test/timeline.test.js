// node --test display/sleep/test/
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTimeline, eventsIn, layoutOf, levelsAt, phaseAt, sparkAt, spatial, stream, GAP } from '../timeline.js';

const T0 = Date.UTC(2026, 10, 21, 21, 30); // 23:30 local-ish; any integer ms works
const MIN = 60_000;
const plan = {
  t0: T0, settleMs: 3 * MIN, fadeMs: 30 * MIN, soundFadeMs: 45 * MIN, nightSound: 'hum',
  sunriseAt: T0 + 455 * MIN, ringAt: T0 + 480 * MIN, rampMs: 3 * MIN, alarmSound: 'birds',
};
const two = { seed: 0x5eed1234, t0: T0, members: [{ id: 'laptop', side: 'right', distance: 'near' }, { id: 'theloth', side: 'left', distance: 'mid' }] };
const L2 = layoutOf(two.members);
const strip = (evs) => JSON.stringify(evs);

test('the same seed gives the same events on every machine, whatever the window chunking', () => {
  const a = eventsIn(two, plan, L2, T0, T0 + 60_000);
  const chunks = [];
  for (let t = T0; t < T0 + 60_000; t += 4000) chunks.push(...eventsIn(two, plan, L2, t, t + 4000));
  assert.equal(strip(chunks), strip(a));
  // Another machine (the other member) builds its own timeline from the same session: identical list.
  const m1 = createTimeline(two, plan, 'theloth'), m2 = createTimeline(two, plan, 'laptop');
  assert.equal(strip(m1.between(T0 + 5000, T0 + 25_000)), strip(m2.between(T0 + 5000, T0 + 25_000)));
  // Member order in the session doesn't matter.
  const swapped = { ...two, members: [...two.members].reverse() };
  assert.equal(strip(eventsIn(swapped, plan, layoutOf(swapped.members), T0, T0 + 30_000)), strip(eventsIn(two, plan, L2, T0, T0 + 30_000)));
  assert.ok(a.length > 50, `settle should be lively, got ${a.length}`);
});

test('another seed gives other events; ids are unique and stable', () => {
  const a = eventsIn(two, plan, L2, T0, T0 + 60_000);
  const b = eventsIn({ ...two, seed: 7 }, plan, L2, T0, T0 + 60_000);
  assert.notEqual(strip(a), strip(b));
  assert.equal(new Set(a.map((e) => e.id)).size, a.length);
  for (let i = 1; i < a.length; i++) assert.ok(a[i].t >= a[i - 1].t, 'sorted by time');
});

test('a later plan change (snooze, dismiss) never rewrites past events', () => {
  const later = { ...plan, ringAt: T0 + 20 * MIN, sunriseAt: T0 + 10 * MIN };
  assert.equal(strip(eventsIn(two, later, L2, T0, T0 + 9 * MIN)), strip(eventsIn(two, plan, L2, T0, T0 + 9 * MIN)));
});

test('rates follow the phases: night has no sparks or crackles, settle about the planned crackle rate', () => {
  const settle = eventsIn(two, plan, L2, T0, T0 + 3 * MIN);
  const crackles = settle.filter((e) => e.kind === 'crackle').length;
  assert.ok(crackles > 1.75 * 180 * 0.85 && crackles < 1.75 * 180 * 1.15, `crackles ${crackles}`);
  assert.ok(settle.some((e) => e.kind === 'spark'));
  const night = eventsIn(two, plan, L2, T0 + 60 * MIN, T0 + 90 * MIN);
  assert.equal(night.filter((e) => e.kind !== 'flare').length, 0);
  assert.ok(night.length > 10 && night.length < 120, `night flares ${night.length}`);
  const ring = eventsIn(two, plan, L2, plan.ringAt, plan.ringAt + MIN);
  assert.ok(ring.filter((e) => e.kind === 'chirp').length > 10);
  assert.equal(ring.filter((e) => e.kind === 'crackle').length, 0);
});

test('every crackle that throws a spark shares its timestamp', () => {
  const evs = eventsIn(two, plan, L2, T0, T0 + 2 * MIN);
  const byId = new Map(evs.map((e) => [e.id, e]));
  for (const e of evs.filter((x) => x.kind === 'crackle' && x.spark)) {
    const s = byId.get(`${e.id}.s`);
    assert.ok(s, 'spark present');
    assert.equal(s.t, e.t);
    assert.equal(s.x, e.x);
  }
});

test('phases: boundaries and levels', () => {
  assert.equal(phaseAt(plan, T0 - 1).phase, 'off');
  assert.equal(phaseAt(plan, T0).phase, 'settle');
  assert.equal(phaseAt(plan, T0 + 3 * MIN).phase, 'fade');
  assert.equal(phaseAt(plan, T0 + 33 * MIN).phase, 'night');
  assert.equal(phaseAt(plan, plan.sunriseAt).phase, 'sunrise');
  assert.equal(phaseAt(plan, plan.ringAt).phase, 'ring');
  assert.equal(phaseAt({ ...plan, ringAt: null }, T0 + 600 * MIN).phase, 'night');
  // Fire falls monotonically over the fade; sound reaches the night hum only after its own (longer) fade.
  let last = 2;
  for (let m = 3; m <= 33; m++) { const f = levelsAt(plan, T0 + m * MIN).fire; assert.ok(f <= last); last = f; }
  assert.ok(levelsAt(plan, T0 + 33 * MIN).sound > 0.07);
  assert.ok(Math.abs(levelsAt(plan, T0 + 48 * MIN).sound - 0.07) < 1e-9);
  assert.equal(levelsAt({ ...plan, nightSound: 'off' }, T0 + 120 * MIN).sound, 0);
  assert.equal(levelsAt(plan, plan.sunriseAt + MIN).sound, 0);
  assert.ok(levelsAt(plan, plan.ringAt).alarm < 0.1 && levelsAt(plan, plan.ringAt + 3 * MIN).alarm === 1);
  assert.equal(levelsAt(plan, plan.ringAt - 1).sun < 1, true);
});

test('layout: left → right with a virtual gap; spatial gains are equal-power and follow the distance', () => {
  assert.deepEqual(L2.map((m) => m.id), ['theloth', 'laptop']);
  assert.equal(L2[1].x0, 1 + GAP);
  const eq = [{ id: 'a', side: 'left', distance: 'mid' }, { id: 'b', side: 'right', distance: 'mid' }];
  const L = layoutOf(eq);
  for (const x of [0, 0.5, 0.8, 1.1, 1.4, 1.9, 2.4]) {
    const g = spatial(L, 'a', x).gain ** 2 + spatial(L, 'b', x).gain ** 2;
    assert.ok(Math.abs(g - 1) < 1e-9, `power at ${x}: ${g}`);
  }
  assert.equal(spatial(L, 'a', 0.2).gain, 1);
  assert.equal(spatial(L, 'b', 0.2).gain, 0);
  assert.ok(spatial(L, 'a', 0.2).pan < 0 && spatial(L, 'a', 0.8).pan > 0);
  // The near machine is turned down relative to the far one at the same relative position.
  assert.ok(spatial(L2, 'laptop', L2[1].cx).gain < spatial(L2, 'theloth', L2[0].cx).gain);
  assert.equal(spatial([{ id: 'x', cx: 0.5, distance: 'mid' }], 'x', 3).gain, 1);
});

test('a spark aimed at the neighbour leaves one screen and enters the other within its life', () => {
  const evs = eventsIn(two, plan, L2, T0, T0 + 10 * MIN).filter((e) => e.kind === 'spark' && e.cross);
  assert.ok(evs.length > 5, `crossing sparks: ${evs.length}`);
  for (const s of evs) {
    const from = L2.find((m) => s.x >= m.x0 && s.x <= m.x1);
    const to = L2.find((m) => m.id === s.cross);
    assert.notEqual(from.id, to.id);
    let entered = false;
    for (let t = s.t; t <= s.t + s.life; t += 50) {
      const p = sparkAt(s, t);
      if (p && p.x > to.x0 + 0.02 && p.x < to.x1 - 0.02) { entered = true; break; }
    }
    assert.ok(entered, `${s.id} never reached ${to.id}`);
  }
  assert.equal(sparkAt(evs[0], evs[0].t - 1), null);
  assert.equal(sparkAt(evs[0], evs[0].t + evs[0].life + 1), null);
});

test('one screen alone: no crossing sparks, everything on the screen', () => {
  const one = { seed: 42, t0: T0, members: [{ id: 'solo', side: 'left' }] };
  const evs = eventsIn(one, plan, layoutOf(one.members), T0, T0 + 5 * MIN);
  assert.ok(evs.every((e) => !e.cross));
  assert.ok(evs.filter((e) => e.kind !== 'gust').every((e) => e.x >= 0 && e.x <= 1));
});

test('the PRNG stream is pure 32-bit integer math (pinned values)', () => {
  const r = stream(1, 2, 3);
  const v = [r(), r(), r()];
  assert.ok(v.every((x) => x >= 0 && x < 1));
  assert.deepEqual(v, (() => { const s = stream(1, 2, 3); return [s(), s(), s()]; })());
  // Pinned: if these change, machines running different versions would disagree (bump a protocol version in S3).
  assert.deepEqual(v.map((x) => Math.round(x * 4294967296)), PINNED);
});
const PINNED = [1833320036, 2575520017, 745957700];
