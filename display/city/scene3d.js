// Code city, WebGL (PLAN.md §20 E-2; from the W0 draft city). Buildings: ONE InstancedMesh (one draw call) with a
// per-instance glow attribute; districts: a second InstancedMesh of flat plates; fog for depth, no shadows.
// Incremental: setFiles() builds the city once; patch() changes heights in place (instance matrices only), and only
// added/removed files trigger a relayout (squarified treemap, debounced) whose buildings glide to their new places.
// Instances are packed (swap-remove) and the mesh grows by 25 % when full, so nothing is rebuilt per patch.
// Effects: edit → top glows and fades over 8 s; create → rises; delete → sinks and collapses; commit → particle
// burst; failed job → 2 s red tint; camera: fixed angle, slow orbit only with motion "high", a gentle refocus toward
// an event. Frames come from one scheduler: none while idle, 30 fps while an effect runs (60 with motion "high"),
// stopped 2 s after; with motion "high" the orbit runs at 15 fps; pause() stops everything.
//
// For W4 (Claude orbs and beams): `layer` (a THREE.Group drawn with the city), `topOf(path)` (world position of a
// building's roof), `setAnchor(id, Vector3|null)` + `beam(id, path, 'read'|'edit')` (a light beam from the anchor to the
// building; without an anchor only the building lights up), `focus(path)`, `addEffect(fn(now) → alive)`, `animate(ms)`,
// `setBreath(on)` (≤ 1 fps idle frames for slow pulses), `screenOf(path)` (CSS px in the canvas), `blurredSnapshot()`.
import * as THREE from '../vendor/three/three.module.js';
import { layoutCity, heightOf } from './treemap.js';
import { createScheduler } from '../sched.js';
import { kindColor, variation } from './kinds.js';

const BASE_DIM = 0.42;
const EDIT_GLOW = new THREE.Color('#E0E7FF');
const READ_GLOW = new THREE.Color('#A5B4FC');
const NEW_GLOW = new THREE.Color('#30D158');
const GONE_GLOW = new THREE.Color('#FF6961');
const BG = new THREE.Color('#06060a');
const ALARM_BG = new THREE.Color('#1a0606');
const W = 96, D = 84;            // city footprint (world units)
const T0 = new THREE.Vector3(1, 6, 8);
const EYE = new THREE.Vector3(-50, 150, 188);

const ease = (t) => (t < 0.5 ? 4 * t * t * t : 1 - Math.pow(-2 * t + 2, 3) / 2);
const easeOut = (t) => 1 - Math.pow(1 - t, 3);
const fade = (t) => (t < 0.04 ? t / 0.04 : Math.pow(Math.max(0, 1 - t), 1.6));

function glowTexture() {
  const c = document.createElement('canvas'); c.width = c.height = 64;
  const g = c.getContext('2d');
  const grd = g.createRadialGradient(32, 32, 0, 32, 32, 32);
  grd.addColorStop(0, 'rgba(255,255,255,1)'); grd.addColorStop(0.25, 'rgba(255,255,255,.55)'); grd.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = grd; g.fillRect(0, 0, 64, 64);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

/** Glow attribute (top faces bright, sides faint) and the alarm tint on a Lambert material. */
function patchMaterial(mat, uniforms, withGlow) {
  mat.onBeforeCompile = (sh) => {
    sh.uniforms.uAlarm = uniforms.uAlarm;
    if (withGlow) {
      sh.vertexShader = sh.vertexShader
        .replace('#include <common>', '#include <common>\nattribute vec4 aGlow;\nvarying vec4 vGlow;\nvarying float vTop;')
        .replace('#include <begin_vertex>', '#include <begin_vertex>\nvGlow = aGlow; vTop = step(0.5, normal.y);');
    }
    sh.fragmentShader = sh.fragmentShader
      .replace('#include <common>', `#include <common>\nuniform float uAlarm;\n${withGlow ? 'varying vec4 vGlow;\nvarying float vTop;' : ''}`)
      .replace('#include <fog_fragment>', `${withGlow ? 'gl_FragColor.rgb += vGlow.rgb * vGlow.a * mix(0.45, 1.1, vTop);' : ''}
#include <fog_fragment>
gl_FragColor.rgb *= mix(vec3(1.0), vec3(1.55, 0.42, 0.40), uAlarm);`);
  };
}

/** Throws when WebGL isn't available (the card falls back to the flat city). */
export function createCity3d(canvas, { motion = 'normal', onFrame } = {}) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false, powerPreference: 'low-power' });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 1.25));
  renderer.setClearColor(BG);
  const scene = new THREE.Scene();
  scene.fog = new THREE.Fog('#06060a', 200, 330);
  const camera = new THREE.PerspectiveCamera(30, 1, 1, 600);
  scene.add(new THREE.HemisphereLight('#d6dbff', '#14141c', 0.95));
  const sun = new THREE.DirectionalLight('#ffffff', 2.6);
  sun.position.set(-30, 100, 55);
  scene.add(sun);
  const uniforms = { uAlarm: { value: 0 } };
  const layer = new THREE.Group();
  scene.add(layer);

  const ground = new THREE.Mesh(new THREE.PlaneGeometry(600, 600), new THREE.MeshBasicMaterial({ color: '#09090e' }));
  ground.rotation.x = -Math.PI / 2; ground.position.y = -0.05;
  scene.add(ground);

  const box = new THREE.BoxGeometry(1, 1, 1); box.translate(0, 0.5, 0);
  const m4 = new THREE.Matrix4(), q = new THREE.Quaternion(), sv = new THREE.Vector3(), pv = new THREE.Vector3(), col = new THREE.Color();
  const v3 = new THREE.Vector3();

  // ---- district plates (rebuilt on relayout: a few hundred instances)
  const plateMat = new THREE.MeshLambertMaterial({ color: '#ffffff' });
  patchMaterial(plateMat, uniforms, false);
  let plates = null;
  function setPlates(districts) {
    if (plates) { scene.remove(plates); plates.dispose(); }
    plates = new THREE.InstancedMesh(box, plateMat, Math.max(1, districts.length));
    plates.count = districts.length;
    plates.frustumCulled = false;
    districts.forEach((d, i) => {
      const h = 0.12 + Math.max(0, 3 - d.depth) * 0.08;
      plates.setMatrixAt(i, m4.compose(pv.set(d.x, 0, d.z), q, sv.set(d.w, h, d.d)));
      plates.setColorAt(i, col.set(d.depth === 1 ? '#1d1d26' : d.depth === 2 ? '#22222c' : '#272732'));
    });
    scene.add(plates);
  }

  // ---- buildings: packed instances (list[i].i === i), grown in place
  const mat = new THREE.MeshLambertMaterial({ color: '#ffffff' });
  patchMaterial(mat, uniforms, true);
  const list = [];
  const byPath = new Map();   // path → building (placed or waiting for the next layout)
  let pendingNew = [];        // added since the last layout (no position yet)
  let mesh = null, glow = null, glowAttr = null, cap = 0;

  function ensureCapacity(n) {
    if (n <= cap) return;
    const ncap = Math.max(64, Math.ceil(n * 1.25));
    const geo = box.clone();
    const g = new Float32Array(ncap * 4);
    if (glow) g.set(glow);
    const attr = new THREE.InstancedBufferAttribute(g, 4);
    attr.setUsage(THREE.DynamicDrawUsage);
    geo.setAttribute('aGlow', attr);
    const nm = new THREE.InstancedMesh(geo, mat, ncap);
    nm.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
    nm.instanceColor = new THREE.InstancedBufferAttribute(new Float32Array(ncap * 3), 3);
    nm.frustumCulled = false; // instances move: the cached bounding sphere would go stale
    if (mesh) {
      nm.instanceMatrix.array.set(mesh.instanceMatrix.array);
      nm.instanceColor.array.set(mesh.instanceColor.array);
      scene.remove(mesh); mesh.geometry.dispose(); mesh.dispose();
    }
    nm.count = list.length;
    scene.add(nm);
    mesh = nm; glow = g; glowAttr = attr; cap = ncap;
  }

  function write(b) {
    mesh.setMatrixAt(b.i, m4.compose(pv.set(b.x, 0, b.z), q, sv.set(b.w * b.k, Math.max(0.0001, b.h), b.d * b.k)));
  }
  function paint(b) {
    mesh.setColorAt(b.i, col.set(kindColor(b.kind)).multiplyScalar(BASE_DIM * variation(b.path)));
  }
  let dirty = { m: false, c: false, g: false };
  function flushAttrs() {
    if (!mesh) return;
    if (dirty.m) mesh.instanceMatrix.needsUpdate = true;
    if (dirty.c) mesh.instanceColor.needsUpdate = true;
    if (dirty.g) glowAttr.needsUpdate = true;
    dirty = { m: false, c: false, g: false };
  }

  function addInstance(b) {
    ensureCapacity(list.length + 1);
    b.i = list.length;
    list.push(b);
    mesh.count = list.length;
    glow.fill(0, b.i * 4, b.i * 4 + 4);
    write(b); paint(b);
    dirty.m = dirty.c = dirty.g = true;
  }
  function removeInstance(b) {
    if (b.i < 0) return;
    lit.delete(b); moving.delete(b);
    const last = list.pop();
    if (last !== b) {
      const from = last.i;
      list[b.i] = last; last.i = b.i;
      glow.copyWithin(last.i * 4, from * 4, from * 4 + 4);
      write(last); paint(last);
    }
    b.i = -1;
    mesh.count = list.length;
    dirty.m = dirty.c = dirty.g = true;
  }

  const mk = (path, lines, kind) => ({ path, lines, kind, i: -1, x: 0, z: 0, w: 1, d: 1, h: 0, k: 1, th: heightOf(lines), state: 'new' });

  // ---- layout
  let districts = [];
  function layoutTargets() {
    const live = [...byPath.values()];
    const { buildings, districts: ds } = layoutCity(live, W, D);
    districts = ds;
    return buildings;
  }

  /** Whole new city: no animation. */
  function setFiles(entries) {
    for (const b of list) b.i = -1;
    list.length = 0; byPath.clear(); pendingNew = []; lit.clear(); moving.clear(); sinking.clear();
    clearTimeout(relayoutTimer); relayoutTimer = 0;
    if (mesh) mesh.count = 0;
    for (const [path, lines, kind] of entries) byPath.set(path, mk(path, lines, kind));
    const targets = layoutTargets();
    ensureCapacity(targets.length);
    for (const r of targets) {
      const b = r.file;
      Object.assign(b, { x: r.x, z: r.z, w: r.w, d: r.d, h: b.th, state: 'live' });
      addInstance(b);
    }
    setPlates(districts);
    flushAttrs();
    sched.invalidate();
  }

  // Movement and height animations: b.anim = {t0, ms, from:{x,z,w,d,h,k}, to:{…}, ease, done?}
  const moving = new Set();
  function animTo(b, to, ms, fn = ease, done = null) {
    b.anim = { t0: performance.now(), ms, from: { x: b.x, z: b.z, w: b.w, d: b.d, h: b.h, k: b.k }, to: { x: b.x, z: b.z, w: b.w, d: b.d, h: b.h, k: b.k, ...to }, fn, done };
    moving.add(b);
    sched.animate(ms);
  }
  function moveTick(now) {
    for (const b of moving) {
      const a = b.anim;
      const t = Math.min(1, (now - a.t0) / a.ms), e = a.fn(t);
      for (const key of ['x', 'z', 'w', 'd', 'h', 'k']) b[key] = a.from[key] + (a.to[key] - a.from[key]) * e;
      if (b.i >= 0) { write(b); dirty.m = true; }
      if (t >= 1) { moving.delete(b); b.anim = null; a.done?.(b); }
    }
  }

  let relayoutTimer = 0, sinkUntil = 0;
  function scheduleRelayout() {
    clearTimeout(relayoutTimer);
    relayoutTimer = setTimeout(relayout, Math.max(600, sinkUntil - performance.now() + 50));
  }
  /** Added/removed files: everyone glides to the new layout over 0.9 s; new buildings rise in their new places. */
  function relayout() {
    relayoutTimer = 0;
    const targets = layoutTargets();
    const fresh = new Set(pendingNew);
    pendingNew = [];
    for (const r of targets) {
      const b = r.file;
      if (fresh.has(b) || b.i < 0) {
        Object.assign(b, { x: r.x, z: r.z, w: r.w, d: r.d, h: 0, k: 1, state: 'live' });
        addInstance(b);
        animTo(b, { h: b.th }, 2200, easeOut);
        lightUp(b, NEW_GLOW, 6000, 0.9);
        afterglow(roof(b, b.th), '#30D158', 12, 6000);
      } else {
        animTo(b, { x: r.x, z: r.z, w: r.w, d: r.d, h: b.th }, 900);
      }
    }
    setPlates(districts);
    sched.animate(900);
  }

  function patch(upsert = [], remove = []) {
    let structural = false;
    for (const [path, lines, kind] of upsert) {
      const b = byPath.get(path);
      if (b) {
        b.lines = lines;
        if (b.kind !== kind) { b.kind = kind; if (b.i >= 0) { paint(b); dirty.c = true; } }
        const th = heightOf(lines);
        if (th !== b.th) { b.th = th; if (b.i >= 0) animTo(b, { h: th }, 700, easeOut); }
      } else {
        const nb = mk(path, lines, kind);
        byPath.set(path, nb);
        pendingNew.push(nb);
        structural = true;
      }
    }
    for (const path of remove) {
      const b = byPath.get(path);
      if (!b) continue;
      byPath.delete(path);
      structural = true;
      if (b.i < 0) { pendingNew = pendingNew.filter((x) => x !== b); continue; }
      sink(b);
    }
    if (structural) scheduleRelayout();
    flushAttrs();
    sched.invalidate();
  }

  /** Deleted: a red flash on the roof, then it drops (accelerating) and narrows, with a dust puff at its foot. */
  const sinking = new Set();
  function sink(b) {
    b.state = 'sink';
    sinking.add(b);
    lightUp(b, GONE_GLOW, 1800, 1);
    afterglow(roof(b), '#FF6961', 13, 2200);
    const ms = 1600;
    sinkUntil = Math.max(sinkUntil, performance.now() + ms);
    animTo(b, { h: 0, k: 0.82 }, ms, (t) => t * t * t, () => { sinking.delete(b); removeInstance(b); });
    puff(v3.set(b.x, 0.6, b.z).clone(), Math.max(4, Math.min(14, (b.w + b.d) * 1.6)));
  }

  // ---- lights
  const lit = new Map(); // building → {color, t0, ms, peak}; the newest light on a building wins
  function lightUp(b, color, ms, peak = 1) {
    if (!lit.size) effects.push(glowTick);
    lit.set(b, { color, t0: performance.now(), ms, peak });
    sched.animate(ms);
  }
  function glowTick(now) {
    for (const [b, g] of lit) {
      if (b.i < 0) { lit.delete(b); continue; }
      const t = (now - g.t0) / g.ms;
      const k = fade(t) * g.peak;
      const o = b.i * 4;
      glow[o] = g.color.r; glow[o + 1] = g.color.g; glow[o + 2] = g.color.b; glow[o + 3] = t >= 1 ? 0 : k;
      if (t >= 1) lit.delete(b);
    }
    dirty.g = true;
    return lit.size > 0;
  }

  const haloTex = glowTexture();
  function spot(at, color, size) {
    const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: haloTex, color, transparent: true, opacity: 0,
      blending: THREE.AdditiveBlending, depthWrite: false, fog: false }));
    sp.position.copy(at); sp.scale.setScalar(size);
    scene.add(sp);
    return sp;
  }
  /** Soft light over a building that fades with its glow (the building itself may be a few pixels wide). */
  function afterglow(at, color, size, ms) {
    const sp = spot(at, color, size), t0 = performance.now();
    effects.push((now) => {
      const t = (now - t0) / ms;
      sp.material.opacity = fade(t) * 0.9;
      if (t >= 1) { scene.remove(sp); sp.material.dispose(); return false; }
      return true;
    });
  }
  function puff(at, size) {
    const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: haloTex, color: '#B8A8A0', transparent: true, opacity: 0,
      blending: THREE.AdditiveBlending, depthWrite: false, fog: false }));
    sp.position.copy(at);
    scene.add(sp);
    const t0 = performance.now() + 500, ms = 1900; // the dust rises as the building comes down
    effects.push((now) => {
      const t = Math.max(0, (now - t0) / ms);
      sp.scale.setScalar(size * (0.4 + easeOut(Math.min(1, t)) * 1.1));
      sp.position.y = at.y + t * 2.5;
      sp.material.opacity = t < 0.15 ? (t / 0.15) * 0.55 : Math.max(0, 1 - (t - 0.15) / 0.85) * 0.55;
      if (t >= 1) { scene.remove(sp); sp.material.dispose(); return false; }
      return true;
    });
  }

  const roof = (b, h = b.h) => new THREE.Vector3(b.x, h + 0.2, b.z);

  function touch(path, kind) {
    const b = byPath.get(path);
    if (!b || b.i < 0 || kind !== 'edit') return; // create/delete are drawn from the patch (rise/sink)
    lightUp(b, EDIT_GLOW, 8000);
    afterglow(roof(b), '#C7D2FE', 14, 8000);
  }

  // ---- commit burst: 220 points, ballistic, fading over 2.4 s (closed form: same look at any frame rate)
  const burstTex = glowTexture();
  function commit() {
    const n = 220, pos = new Float32Array(n * 3), vel = new Float32Array(n * 3), cl = new Float32Array(n * 3);
    const ca = new THREE.Color('#30D158'), cb = new THREE.Color('#A5B4FC'), cc = new THREE.Color('#ffffff');
    for (let i = 0; i < n; i++) {
      pos[i * 3 + 1] = 26; pos[i * 3 + 2] = -4;
      const th = Math.random() * Math.PI * 2, ph = Math.acos(2 * Math.random() - 1), sp = 14 + Math.random() * 16;
      vel[i * 3] = Math.sin(ph) * Math.cos(th) * sp; vel[i * 3 + 1] = Math.abs(Math.cos(ph)) * sp * 0.9 + 4; vel[i * 3 + 2] = Math.sin(ph) * Math.sin(th) * sp;
      const c = i % 3 === 0 ? ca : i % 3 === 1 ? cb : cc;
      cl.set([c.r, c.g, c.b], i * 3);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('color', new THREE.BufferAttribute(cl, 3));
    const pm = new THREE.PointsMaterial({ size: 4, map: burstTex, vertexColors: true, transparent: true, opacity: 1,
      blending: THREE.AdditiveBlending, depthWrite: false, fog: false });
    const pts = new THREE.Points(g, pm);
    pts.frustumCulled = false;
    scene.add(pts);
    const t0 = performance.now(), ms = 2400, k = 0.9, G = 16;
    effects.push((now) => {
      const ts = (now - t0) / 1000, f = (1 - Math.exp(-k * ts)) / k;
      for (let i = 0; i < n; i++) {
        pos[i * 3] = vel[i * 3] * f;
        pos[i * 3 + 1] = 26 + vel[i * 3 + 1] * f - 0.5 * G * ts * ts;
        pos[i * 3 + 2] = -4 + vel[i * 3 + 2] * f;
      }
      g.attributes.position.needsUpdate = true;
      const t = (now - t0) / ms;
      pm.opacity = Math.max(0, 1 - t * t);
      if (t >= 1) { scene.remove(pts); g.dispose(); pm.dispose(); return false; }
      return true;
    });
    sched.animate(ms);
  }

  /** Failed job: the whole city turns reddish for `ms`. */
  function alarm(ms = 2000) {
    const t0 = performance.now();
    effects.push((now) => {
      const t = (now - t0) / ms;
      uniforms.uAlarm.value = t >= 1 ? 0 : t < 0.12 ? t / 0.12 : Math.max(0, 1 - (t - 0.12) / 0.88) ** 1.5;
      renderer.setClearColor(col.copy(BG).lerp(ALARM_BG, uniforms.uAlarm.value));
      return t < 1;
    });
    sched.animate(ms);
  }

  // ---- W4: anchors (orb positions) and beams
  const anchors = new Map();
  function beam(id, path, kind) {
    const b = byPath.get(path);
    if (!b || b.i < 0) return;
    const strong = kind === 'edit';
    if (strong) { lightUp(b, EDIT_GLOW, 8000); afterglow(roof(b), '#C7D2FE', 14, 8000); } else lightUp(b, READ_GLOW, 2200, 0.35);
    const from = anchors.get(id);
    if (!from) return;
    const to = roof(b), len = from.distanceTo(to);
    const part = (r, op) => {
      const mm = new THREE.Mesh(new THREE.CylinderGeometry(r, r * (strong ? 0.6 : 0.8), len, 10, 1, true),
        new THREE.MeshBasicMaterial({ color: strong ? '#E0E7FF' : '#A5B4FC', transparent: true, opacity: 0, blending: THREE.AdditiveBlending, depthWrite: false, fog: false }));
      mm.position.copy(from).add(to).multiplyScalar(0.5);
      mm.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), to.clone().sub(from).normalize());
      mm.userData.max = op;
      layer.add(mm);
      return mm;
    };
    const parts = strong ? [part(0.16, 0.95), part(0.6, 0.28)] : [part(0.1, 0.45), part(0.45, 0.12)];
    const t0 = performance.now(), hold = strong ? 1800 : 1300, total = 300 + hold + 900;
    effects.push((now) => {
      const t = now - t0;
      const k = t < 300 ? t / 300 : t < 300 + hold ? 1 : Math.max(0, 1 - (t - 300 - hold) / 900);
      for (const pp of parts) pp.material.opacity = pp.userData.max * k;
      if (t >= total) { for (const pp of parts) { layer.remove(pp); pp.geometry.dispose(); pp.material.dispose(); } return false; }
      return true;
    });
    sched.animate(total);
  }

  // ---- camera: fixed oblique view; motion "high" orbits slowly; events pull the view a little toward them
  let fit = 1, orbit = false, breathOn = false, mot = motion;
  const target = T0.clone();
  let pull = null; // {from, to, t0} — eases to `to` (1.6 s), holds, eases back (2.5 s)
  const ORBIT = (Math.PI * 2) / 360_000; // one turn in 6 min
  function placeCamera(now) {
    if (pull) {
      const t = now - pull.t0;
      const k = t < 1600 ? ease(t / 1600) : t < 7600 ? 1 : 1 - ease(Math.min(1, (t - 7600) / 2500));
      target.copy(T0).lerp(pull.to, k);
      if (t >= 10_100) { pull = null; target.copy(T0); }
    }
    const a = orbit ? now * ORBIT : 0;
    const off = v3.copy(EYE).sub(T0).multiplyScalar(fit).applyAxisAngle(THREE.Object3D.DEFAULT_UP, a);
    camera.position.copy(target).add(off);
    camera.lookAt(target);
    camera.updateMatrixWorld();
  }
  function focus(path) {
    if (mot === 'low') return;
    const b = byPath.get(path);
    if (!b || b.i < 0) return;
    pull = { to: T0.clone().lerp(new THREE.Vector3(b.x, 4, b.z), 0.18), t0: performance.now() };
    sched.animate(10_100);
  }
  function setMotion(m) {
    mot = m;
    orbit = m === 'high';
    sched.setFps(m === 'high' ? 60 : 30);
    if (m === 'low') pull = null;
    applyBreath();
  }
  function applyBreath() {
    if (mot === 'low') return sched.setBreath(false);
    if (orbit) return sched.setBreath(true, 1000 / 15);
    sched.setBreath(breathOn, 1000);
  }

  // ---- frame
  const effects = [];
  function draw(now) {
    for (let i = effects.length - 1; i >= 0; i--) if (!effects[i](now)) effects.splice(i, 1);
    if (moving.size) moveTick(now);
    flushAttrs();
    placeCamera(now);
    renderer.render(scene, camera);
    onFrame?.(now);
  }
  const sched = createScheduler(draw, { fps: motion === 'high' ? 60 : 30 });

  let size = { w: 1, h: 1 };
  function resize() {
    const r = canvas.parentElement.getBoundingClientRect();
    if (!r.width || !r.height) return;
    size = { w: r.width, h: r.height };
    renderer.setSize(r.width, r.height, false);
    camera.aspect = r.width / r.height;
    fit = Math.min(1.7, Math.max(0.85, 0.98 / camera.aspect));
    camera.updateProjectionMatrix();
    placeCamera(performance.now());
    sched.invalidate();
  }
  const ro = new ResizeObserver(resize);
  ro.observe(canvas.parentElement);
  resize();
  setMotion(motion);

  function screenOf(path) {
    const b = byPath.get(path);
    if (!b || b.i < 0) return null;
    v3.set(b.x, b.h, b.z).project(camera);
    return { x: (v3.x * 0.5 + 0.5) * size.w, y: (-v3.y * 0.5 + 0.5) * size.h };
  }

  /** Renders once and returns a small, blurred copy of the canvas (W4: the diff card's pre-blurred background). */
  function blurredSnapshot(scale = 0.25, blur = 10) {
    renderer.render(scene, camera);
    const out = document.createElement('canvas');
    out.width = Math.round(size.w * scale); out.height = Math.round(size.h * scale);
    const g = out.getContext('2d');
    g.filter = `blur(${blur}px) brightness(.7) saturate(1.2)`;
    g.drawImage(canvas, -blur * 2, -blur * 2, out.width + blur * 4, out.height + blur * 4);
    return out;
  }

  function destroy() {
    sched.pause();
    ro.disconnect();
    clearTimeout(relayoutTimer);
    scene.traverse((o) => { o.geometry?.dispose?.(); if (o.material) [].concat(o.material).forEach((m) => m.dispose()); });
    haloTex.dispose(); burstTex.dispose(); box.dispose();
    renderer.dispose();
    renderer.forceContextLoss();
  }

  return {
    kind: '3d', sched, layer, THREE,
    setFiles, patch, touch, commit, alarm, focus, beam, setMotion, screenOf, blurredSnapshot,
    setAnchor(id, pos) { if (pos) anchors.set(id, pos.clone()); else anchors.delete(id); },
    topOf: (path) => { const b = byPath.get(path); return b && b.i >= 0 ? roof(b) : null; },
    addEffect(fn) { effects.push(fn); },
    animate: (ms) => sched.animate(ms),
    setBreath(on) { breathOn = on; applyBreath(); },
    get count() { return list.length; },
    pause: () => sched.pause(),
    resume: () => sched.resume(),
    destroy,
  };
}
