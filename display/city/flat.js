// Code city, flat (PLAN.md §20 E-2 fallback: the `city: "2d"` setting, no WebGL, later the battery saver). The same
// treemap seen from above on a 2D canvas: districts as dark plates, buildings as tiles whose brightness follows their
// height. The static city is drawn once into an offscreen canvas and only re-drawn when the data changes; an effect
// frame copies it and paints the effects on top: edit → the tile glows and fades over 8 s; create → it grows in;
// delete → it shrinks away in red; commit → a ring from the centre; failed job → 2 s red tint. Same scheduler rules as
// the 3D city (no idle frames, 30 fps while an effect runs, 60 with motion "high", pause() stops everything).
import { layoutCity, heightOf } from './treemap.js';
import { createScheduler } from '../sched.js';
import { kindColor, variation } from './kinds.js';

const W = 96, D = 84;
const PLATE = ['#15151c', '#1a1a22', '#1f1f28'];
const fade = (t) => (t < 0.04 ? t / 0.04 : Math.pow(Math.max(0, 1 - t), 1.6));
const easeOut = (t) => 1 - Math.pow(1 - t, 3);

function shade(hex, k) {
  const n = parseInt(hex.slice(1), 16);
  const f = (v) => Math.max(0, Math.min(255, Math.round(v * k)));
  return `rgb(${f(n >> 16)},${f((n >> 8) & 255)},${f(n & 255)})`;
}

export function createCityFlat(canvas, { motion = 'normal', onFrame } = {}) {
  const g = canvas.getContext('2d', { alpha: false });
  const base = document.createElement('canvas');
  const bg = base.getContext('2d', { alpha: false });
  let dpr = Math.min(devicePixelRatio, 1.25), size = { w: 1, h: 1 }, s = 1, ox = 0, oy = 0;
  let baseDirty = true, maxH = 1;
  const byPath = new Map();      // path → {path, lines, kind, x, z, w, d, placed}
  let districts = [];
  const fx = new Map();          // building → {type, t0, ms}
  const rings = [];              // commit rings: t0
  let alarmT0 = 0, alarmMs = 0, relayoutTimer = 0;

  const px = (x) => ox + (x + W / 2) * s;
  const pz = (z) => oy + (z + D / 2) * s;

  function layout() {
    const { buildings, districts: ds } = layoutCity([...byPath.values()].filter((b) => b.state !== 'gone'), W, D);
    districts = ds;
    for (const r of buildings) Object.assign(r.file, { x: r.x, z: r.z, w: r.w, d: r.d, placed: true });
    maxH = Math.max(1, ...[...byPath.values()].map((b) => heightOf(b.lines)));
    baseDirty = true;
  }

  function tileColor(b) {
    const k = 0.45 + 0.55 * (heightOf(b.lines) / maxH);
    return shade(kindColor(b.kind), k * variation(b.path) * 0.85);
  }

  function drawBase() {
    bg.setTransform(dpr, 0, 0, dpr, 0, 0);
    bg.fillStyle = '#06060a';
    bg.fillRect(0, 0, size.w, size.h);
    for (const d of districts) {
      bg.fillStyle = PLATE[Math.min(d.depth - 1, 2)];
      bg.fillRect(px(d.x - d.w / 2), pz(d.z - d.d / 2), d.w * s, d.d * s);
    }
    for (const b of byPath.values()) {
      if (!b.placed || b.state === 'gone' || fx.get(b)?.type === 'rise') continue;
      bg.fillStyle = tileColor(b);
      bg.fillRect(px(b.x - b.w / 2), pz(b.z - b.d / 2), Math.max(1, b.w * s), Math.max(1, b.d * s));
    }
    baseDirty = false;
  }

  function rect(b, k, fill) {
    const w = Math.max(1, b.w * s * k), h = Math.max(1, b.d * s * k);
    g.fillStyle = fill;
    g.fillRect(px(b.x) - w / 2, pz(b.z) - h / 2, w, h);
  }

  function draw(now) {
    if (baseDirty) drawBase();
    g.setTransform(1, 0, 0, 1, 0, 0);
    g.drawImage(base, 0, 0);
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    for (const [b, e] of fx) {
      const t = Math.min(1, (now - e.t0) / e.ms);
      if (e.type === 'rise') {
        rect(b, easeOut(Math.min(1, t * 3)), tileColor(b));
        g.globalAlpha = fade(t) * 0.8; rect(b, 1, '#30D158'); g.globalAlpha = 1;
      } else if (e.type === 'sink') {
        g.globalAlpha = 1 - t; rect(b, 1 - easeOut(t) * 0.9, '#FF6961'); g.globalAlpha = 1;
      } else {
        g.globalAlpha = fade(t) * 0.9; rect(b, 1, '#E0E7FF'); g.globalAlpha = 1;
      }
      if (t >= 1) {
        fx.delete(b);
        if (e.type === 'rise') baseDirty = true;
        if (e.type === 'sink') { byPath.get(b.path) === b && byPath.delete(b.path); }
      }
    }
    for (let i = rings.length - 1; i >= 0; i--) {
      const t = (now - rings[i]) / 1800;
      if (t >= 1) { rings.splice(i, 1); continue; }
      g.strokeStyle = `rgba(165,180,252,${(1 - t) * 0.8})`;
      g.lineWidth = 6 * (1 - t) + 1;
      g.beginPath(); g.arc(size.w / 2, size.h / 2, 20 + easeOut(t) * Math.max(size.w, size.h) * 0.6, 0, Math.PI * 2); g.stroke();
    }
    if (alarmMs) {
      const t = (now - alarmT0) / alarmMs;
      const k = t >= 1 ? 0 : t < 0.12 ? t / 0.12 : Math.max(0, 1 - (t - 0.12) / 0.88) ** 1.5;
      if (t >= 1) alarmMs = 0;
      g.fillStyle = `rgba(255,70,60,${0.22 * k})`;
      g.fillRect(0, 0, size.w, size.h);
    }
    onFrame?.(now);
  }
  const sched = createScheduler(draw, { fps: motion === 'high' ? 60 : 30 });

  function effect(b, type, ms) {
    fx.set(b, { type, t0: performance.now(), ms });
    sched.animate(ms);
  }

  function setFiles(entries) {
    byPath.clear(); fx.clear();
    clearTimeout(relayoutTimer); relayoutTimer = 0;
    for (const [path, lines, kind] of entries) byPath.set(path, { path, lines, kind, placed: false });
    layout();
    sched.invalidate();
  }

  function patch(upsert = [], remove = []) {
    let structural = false;
    for (const [path, lines, kind] of upsert) {
      const b = byPath.get(path);
      if (b && b.state !== 'gone') { b.lines = lines; b.kind = kind; baseDirty = true; continue; }
      byPath.set(path, { path, lines, kind, placed: false, fresh: true });
      structural = true;
    }
    for (const path of remove) {
      const b = byPath.get(path);
      if (!b) continue;
      structural = true;
      if (!b.placed) { byPath.delete(path); continue; }
      b.state = 'gone';
      baseDirty = true;
      effect(b, 'sink', 1100);
    }
    if (structural) {
      clearTimeout(relayoutTimer);
      relayoutTimer = setTimeout(() => {
        relayoutTimer = 0;
        for (const b of [...byPath.values()]) if (b.state === 'gone' && !fx.has(b)) byPath.delete(b.path);
        layout();
        for (const b of byPath.values()) if (b.fresh) { b.fresh = false; effect(b, 'rise', 6000); }
        sched.invalidate();
      }, 1200);
    }
    sched.invalidate();
  }

  function touch(path, kind) {
    const b = byPath.get(path);
    if (b?.placed && kind === 'edit' && fx.get(b)?.type !== 'rise') effect(b, 'glow', 8000);
  }

  function resize() {
    const r = canvas.parentElement.getBoundingClientRect();
    if (!r.width || !r.height) return;
    dpr = Math.min(devicePixelRatio, 1.25);
    size = { w: r.width, h: r.height };
    canvas.width = base.width = Math.round(r.width * dpr);
    canvas.height = base.height = Math.round(r.height * dpr);
    const m = 28;
    s = Math.min((r.width - 2 * m) / W, (r.height - 2 * m - 60) / D);
    ox = (r.width - W * s) / 2;
    oy = (r.height - D * s) / 2;
    baseDirty = true;
    sched.invalidate();
  }
  const ro = new ResizeObserver(resize);
  ro.observe(canvas.parentElement);
  resize();

  return {
    kind: '2d', sched,
    setFiles, patch, touch,
    commit() { rings.push(performance.now()); sched.animate(1800); },
    alarm(ms = 2000) { alarmT0 = performance.now(); alarmMs = ms; sched.animate(ms); },
    focus() {}, beam(_id, path) { touch(path, 'edit'); }, setAnchor() {}, setBreath() {},
    setMotion(m) { sched.setFps(m === 'high' ? 60 : 30); },
    screenOf(path) {
      const b = byPath.get(path);
      return b?.placed ? { x: px(b.x), y: pz(b.z - b.d / 2) } : null;
    },
    get count() { return byPath.size; },
    pause: () => sched.pause(),
    resume: () => sched.resume(),
    destroy() { sched.pause(); ro.disconnect(); clearTimeout(relayoutTimer); },
  };
}
