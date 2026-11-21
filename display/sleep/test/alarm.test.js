// Sleep alarm on the page (PLAN.md §21 S4): the plan's alarm phases (the same function as the agent's phasesOf, same
// cases as agent/test/screen_sleep_alarm.test.ts), the ring's ramp and auto-stop, snoozed/morning levels, and a plan
// change on a running timeline (snooze, dismiss) that keeps every past event.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createTimeline, eventsIn, layoutOf, levelsAt, phaseAt, phasesOf } from '../timeline.js';

const MIN = 60_000, H = 60 * MIN;
const T0 = 1_000_000_000;
const R = T0 + 8 * H;
const plan = {
  t0: T0, settleMs: 3 * MIN, fadeMs: 30 * MIN, soundFadeMs: 45 * MIN, nightSound: 'hum', sunriseAt: R - 25 * MIN, ringAt: R, rampMs: 3 * MIN,
  alarmSound: 'birds', snoozeMs: 9 * MIN, autoStopMs: 20 * MIN, morningMs: 10 * MIN, snoozes: [], dismissedAt: null,
};
const rel = (p) => phasesOf(p).map((x) => [x.phase, x.start - T0, x.end === Infinity ? null : x.end - T0]);

test('phases like the agent: sunrise → ring; snoozes; dismiss → morning; a short night cuts sunrise, then the fade', () => {
  assert.deepEqual(rel(plan), [['settle', 0, 3 * MIN], ['fade', 3 * MIN, 33 * MIN], ['night', 33 * MIN, 8 * H - 25 * MIN], ['sunrise', 8 * H - 25 * MIN, 8 * H], ['ring', 8 * H, null]]);
  const snoozed = { ...plan, snoozes: [R + 2 * MIN, R + 40 * MIN], dismissedAt: R + 50 * MIN };
  assert.deepEqual(rel(snoozed).slice(4), [
    ['ring', 8 * H, 8 * H + 2 * MIN], ['snoozed', 8 * H + 2 * MIN, 8 * H + 11 * MIN], ['ring', 8 * H + 11 * MIN, 8 * H + 40 * MIN],
    ['snoozed', 8 * H + 40 * MIN, 8 * H + 49 * MIN], ['ring', 8 * H + 49 * MIN, 8 * H + 50 * MIN], ['morning', 8 * H + 50 * MIN, 8 * H + 60 * MIN],
  ]);
  assert.equal(phaseAt(snoozed, R + 61 * MIN).phase, 'morning'); // over (the agent ends the mode)
  assert.deepEqual(rel({ ...plan, dismissedAt: R - 10 * MIN, morningMs: 0 }).at(-1), ['sunrise', 8 * H - 25 * MIN, 8 * H - 10 * MIN]);
  assert.deepEqual(rel({ ...plan, ringAt: T0 + 20 * MIN, sunriseAt: T0 - 5 * MIN }).map((x) => x[0]), ['settle', 'fade', 'ring']);
  assert.deepEqual(rel({ ...plan, ringAt: T0 + 45 * MIN, sunriseAt: T0 + 20 * MIN }).map((x) => [x[0], x[1]]), [['settle', 0], ['fade', 3 * MIN], ['sunrise', 33 * MIN], ['ring', 45 * MIN]]);
});

test('ring: the ramp starts again with every ring, quiet after the auto-stop (the light stays); snoozed is bright and silent', () => {
  const p = { ...plan, snoozes: [R + 2 * MIN] };
  assert.ok(levelsAt(p, R).alarm < 0.1);
  assert.ok(levelsAt(p, R + 3 * MIN - 1).alarm < 1 && levelsAt(p, R + MIN).chirp > 0);
  const sn = levelsAt(p, R + 5 * MIN);
  assert.equal(sn.phase, 'snoozed');
  assert.equal(sn.alarm, 0); assert.equal(sn.chirp, 0); assert.equal(sn.sun, 1);
  assert.ok(levelsAt(p, R + 11 * MIN).alarm < 0.1, 'second ring ramps from low again');
  assert.ok(levelsAt(p, R + 14 * MIN).alarm > 0.99);
  const quiet = levelsAt(p, R + 31 * MIN);
  assert.equal(quiet.phase, 'ring'); assert.equal(quiet.alarm, 0); assert.equal(quiet.chirp, 0); assert.equal(quiet.sun, 1);
  assert.ok(levelsAt({ ...plan, alarmSound: 'chime' }, R + MIN).chime > 0);
  // A Velour alarm still draws the birds' motes (chirp events); the page's gain decides how loud they are.
  assert.ok(levelsAt({ ...plan, alarmSound: 'velour' }, R + MIN).chirp > 0);
});

test('a snooze or dismiss on a running timeline keeps the past; from then on the new plan', () => {
  const members = [{ id: 'theloth', side: 'left', distance: 'mid' }, { id: 'laptop', side: 'right', distance: 'near' }];
  const session = { seed: 0x5eed, t0: T0, members };
  const tl = createTimeline(session, plan, 'laptop');
  const at = R + 2 * MIN;
  const before = JSON.stringify(tl.between(R, at));
  const ringing = tl.between(at, at + MIN).filter((e) => e.kind === 'chirp').length;
  assert.ok(ringing > 3);
  const next = { ...plan, snoozes: [at] };
  tl.setPlan(next, at);
  assert.equal(tl.plan, next);
  assert.equal(JSON.stringify(tl.between(R, at)), before);
  assert.equal(tl.between(at, at + MIN).filter((e) => e.kind === 'chirp').length, 0);
  assert.equal(tl.levels(at + MIN).phase, 'snoozed');
  // Built from scratch on the other member: the same events.
  assert.equal(JSON.stringify(eventsIn(session, next, layoutOf(members), R, at + 12 * MIN)), JSON.stringify(tl.between(R, at + 12 * MIN)));
});
