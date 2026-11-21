// The shared clock → AudioContext time mapping (the audio half of the ±20 ms sync budget).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { ctxTimeFor, level } from '../audio.js';

const base = { perfNow: 10_000, dateNow: 1_800_000_000_000, offsetMs: 0, currentTime: 5, outputLatency: 0.04 };

test('with getOutputTimestamp: an instant 1 s ahead plays 1 s after the context time now leaving the speaker', () => {
  // At performance time 9 990 the speaker was playing context time 4.95.
  const o = { ...base, ts: { contextTime: 4.95, performanceTime: 9990 } };
  const T = base.dateNow + 1000; // shared clock, 1 s from now
  assert.ok(Math.abs(ctxTimeFor(T, o) - (4.95 + 1.01)) < 1e-9);
});

test('the group offset moves the instant on this machine\'s clock', () => {
  const o = { ...base, offsetMs: 25, ts: { contextTime: 5, performanceTime: 10_000 } };
  // This machine's clock is 25 ms behind the group's: the group's "now + 1 s" is local now + 975 ms.
  assert.ok(Math.abs(ctxTimeFor(base.dateNow + 1000, o) - 5.975) < 1e-9);
});

test('without an output timestamp: currentTime minus the output latency', () => {
  for (const ts of [null, { contextTime: 0, performanceTime: 0 }]) {
    const c = ctxTimeFor(base.dateNow + 500, { ...base, ts });
    assert.ok(Math.abs(c - (5 + 0.5 - 0.04)) < 1e-9);
  }
});

test('volume curve', () => {
  assert.equal(level(0), 0);
  assert.equal(level(100), 1);
  assert.ok(level(35) > 0.12 && level(35) < 0.13);
  assert.equal(level(150), 1);
});
