// Sleep morning screen (PLAN.md §21 E-4, S5): the agent's summary → the rows; no summary yet → the night's length
// from the plan (t0 → the dismiss); the ember sounds' ducking under the leader's music (−12 dB, slow return).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { duration, morningView } from '../morning.js';
import { DUCK_DOWN_S, DUCK_GAIN, DUCK_UP_S, duckRamp } from '../audio.js';

const T0 = 1_000_000_000, MIN = 60_000;
const plan = { t0: T0, dismissedAt: T0 + 460 * MIN };

test('no summary yet: the night t0 → dismiss, the phone note', () => {
  const v = morningView(null, plan, T0 + 470 * MIN);
  assert.deepEqual(v.rows, [{ label: 'Uyku', value: '7 sa 40 dk', warn: false }]);
  assert.equal(v.note, 'Gecenin özeti telefonunda.');
  assert.deepEqual(v.titles, []);
  assert.equal(duration(59.6), '1 sa 0 dk');
});

test('a summary: its minutes and the non-zero numbers, failures marked, up to three titles, missing members', () => {
  const s = { minutes: 455, jobs: 3, jobsFailed: 1, backups: 2, backupsFailed: 0, incidents: 1, held: 5, titles: ['backup.stale · nas', 'claude.waiting · tiphys', 'x', 'y'], missing: 1 };
  const v = morningView(s, plan, T0 + 470 * MIN);
  assert.deepEqual(v.rows.map((r) => [r.label, r.value, r.warn]), [
    ['Uyku', '7 sa 35 dk', false], ['Biten işler', '3 · 1 başarısız', true], ['Yedekler', '2 tamam', false], ['Sunucu olayları', '1', true], ['Bekleyen bildirimler', '5', false],
  ]);
  assert.deepEqual(v.titles, ['backup.stale · nas', 'claude.waiting · tiphys', 'x']);
  assert.equal(v.note, '1 makineden bilgi gelmedi.');
  const quiet = morningView({ minutes: 30, jobs: 0, held: 0, titles: ['t'] }, plan, 0);
  assert.equal(quiet.rows.length, 1);
  assert.deepEqual(quiet.titles, []);
  assert.match(quiet.note, /Sakin/);
});

test('ducking: −12 dB down in a few seconds, back up slowly, from where it is', () => {
  assert.ok(Math.abs(20 * Math.log10(DUCK_GAIN) + 12) < 1e-9);
  const calls = [];
  const param = { value: 0.8, cancelScheduledValues: (t) => calls.push(['cancel', t]), setValueAtTime: (v, t) => calls.push(['set', v, t]), linearRampToValueAtTime: (v, t) => calls.push(['ramp', v, t]) };
  duckRamp(param, true, 10);
  assert.deepEqual(calls, [['cancel', 10], ['set', 0.8, 10], ['ramp', DUCK_GAIN, 10 + DUCK_DOWN_S]]);
  calls.length = 0;
  duckRamp(param, false, 50);
  assert.deepEqual(calls.at(-1), ['ramp', 1, 50 + DUCK_UP_S]);
  assert.ok(DUCK_UP_S > DUCK_DOWN_S);
});
