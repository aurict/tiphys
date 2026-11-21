// Code city + Claude brain (one WebGL canvas). Buildings: one InstancedMesh (one draw call) with a per-instance glow
// attribute; districts: a second InstancedMesh of flat plates. Sessions: glowing orbs with HTML labels; beams to the
// buildings they read/edit; commit → particle burst; failed job → 2 s red tint. Nothing animates by itself: every
// effect asks the frame scheduler for frames for as long as it lasts (sched.animate), idle = breath at ≤ 1 fps.
import * as THREE from '../vendor/three/three.module.js';
import { layoutCity, heightOf } from './treemap.js';
import { createScheduler } from './sched.js';

// Six tones from the Tiphys tokens (accent, host-1/2/3, warning, label grey), darkened for the city base so the
// accent-coloured lights stand out on top.
export const KINDS = {
  code: { color: '#A5B4FC', label: 'TS / JS' },
  dart: { color: '#87D4B0', label: 'Dart' },
  docs: { color: '#F4B89B', label: 'Belge' },
  config: { color: '#FFB340', label: 'Ayar' },
  web: { color: '#A39DF1', label: 'HTML / CSS' },
  other: { color: '#98989F', label: 'Diğer' },
};
const BASE_DIM = 0.42;
const EDIT_GLOW = new THREE.Color('#E0E7FF');
const READ_GLOW = new THREE.Color('#A5B4FC');
const NEW_GLOW = new THREE.Color('#30D158');
const ORB = { running: new THREE.Color('#C7D2FE'), idle: new THREE.Color('#8E8E93'), waiting: new THREE.Color('#FFB340') };

const W = 96, D = 84; // city footprint (world units)

function glowTexture(inner = 'rgba(255,255,255,1)') {
  const c = document.createElement('canvas'); c.width = c.height = 64;
  const g = c.getContext('2d');
  const grd = g.createRadialGradient(32, 32, 0, 32, 32, 32);
  grd.addColorStop(0, inner); grd.addColorStop(0.25, 'rgba(255,255,255,.55)'); grd.addColorStop(1, 'rgba(255,255,255,0)');
  g.fillStyle = grd; g.fillRect(0, 0, 64, 64);
  const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace;
  return t;
}

/** Adds the glow attribute (top faces bright, sides faint) and the alarm tint to a Lambert material. */
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

export function createCity(canvas, labelsEl, data, { onFrame } = {}) {
  const renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: false, powerPreference: 'low-power' });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 1.25));
  const BG = new THREE.Color('#06060a');
  renderer.setClearColor(BG);
  const scene = new THREE.Scene();
  scene.fog = new THREE.Fog('#06060a', 200, 330);
  const camera = new THREE.PerspectiveCamera(30, 1, 1, 500);
  const target = new THREE.Vector3(1, 6, 8);
  // Fixed oblique view from the front-left (motion: high would orbit slowly; not in the draft).
  camera.position.set(-50, 150, 188);
  camera.lookAt(target);
  camera.updateMatrixWorld();

  scene.add(new THREE.HemisphereLight('#d6dbff', '#14141c', 0.95));
  const sun = new THREE.DirectionalLight('#ffffff', 2.6);
  sun.position.set(-30, 100, 55);
  scene.add(sun);

  const uniforms = { uAlarm: { value: 0 } };

  // ---- ground + district plates
  const ground = new THREE.Mesh(new THREE.PlaneGeometry(600, 600), new THREE.MeshBasicMaterial({ color: '#09090e' }));
  ground.rotation.x = -Math.PI / 2; ground.position.y = -0.05;
  scene.add(ground);

  const hidden = new Set(data.hidden ?? []);
  const files = data.files.map(([path, lines, kind]) => ({ path, lines, kind, hidden: hidden.has(path) }));
  const { buildings, districts } = layoutCity(files, W, D);
  const box = new THREE.BoxGeometry(1, 1, 1); box.translate(0, 0.5, 0);

  const plateMat = new THREE.MeshLambertMaterial({ color: '#ffffff' });
  patchMaterial(plateMat, uniforms, false);
  const plates = new THREE.InstancedMesh(box, plateMat, districts.length);
  const m = new THREE.Matrix4(), q = new THREE.Quaternion(), s = new THREE.Vector3(), p = new THREE.Vector3(), c = new THREE.Color();
  districts.forEach((d, i) => {
    const h = 0.12 + Math.max(0, 3 - d.depth) * 0.08;
    m.compose(p.set(d.x, 0, d.z), q, s.set(d.w, h, d.d));
    plates.setMatrixAt(i, m);
    plates.setColorAt(i, c.set(d.depth === 1 ? '#1d1d26' : d.depth === 2 ? '#22222c' : '#272732'));
  });
  scene.add(plates);

  // ---- buildings
  const mat = new THREE.MeshLambertMaterial({ color: '#ffffff' });
  patchMaterial(mat, uniforms, true);
  const N = buildings.length;
  const mesh = new THREE.InstancedMesh(box, mat, N);
  const glow = new Float32Array(N * 4);
  const glowAttr = new THREE.InstancedBufferAttribute(glow, 4);
  glowAttr.setUsage(THREE.DynamicDrawUsage);
  mesh.geometry = box.clone();
  mesh.geometry.setAttribute('aGlow', glowAttr);
  const byPath = new Map();
  buildings.forEach((b, i) => {
    b.i = i;
    b.h = heightOf(b.file.lines);
    b.hidden = !!b.file.hidden;
    byPath.set(b.file.path, b);
    m.compose(p.set(b.x, 0, b.z), q, s.set(b.w, b.hidden ? 0.0001 : b.h, b.d));
    mesh.setMatrixAt(i, m);
    // Slight per-building variation so a district isn't one flat colour.
    const v = 0.85 + ((i * 2654435761) % 1000) / 1000 * 0.3;
    mesh.setColorAt(i, c.set(KINDS[b.file.kind]?.color ?? KINDS.other.color).multiplyScalar(BASE_DIM * v));
  });
  mesh.instanceMatrix.setUsage(THREE.DynamicDrawUsage);
  scene.add(mesh);

  // ---- sessions (brain)
  const haloTex = glowTexture();
  const sessions = new Map();
  const constel = new THREE.LineSegments(new THREE.BufferGeometry(),
    new THREE.LineBasicMaterial({ color: '#A5B4FC', transparent: true, opacity: 0.22, fog: false }));
  scene.add(constel);

  function placeSessions() {
    const list = [...sessions.values()];
    const n = list.length;
    list.forEach((s, i) => {
      const t = n === 1 ? 0.5 : i / (n - 1);
      s.group.position.set(-26 + t * 56, 32 + (i % 2) * 6, -4 - (i % 2) * 14);
    });
    const pts = [];
    for (let i = 0; i + 1 < n; i++) pts.push(list[i].group.position.clone(), list[i + 1].group.position.clone());
    constel.geometry.dispose();
    constel.geometry = new THREE.BufferGeometry().setFromPoints(pts);
    positionLabels();
  }

  function addSession({ id, name, status = 'running' }) {
    const group = new THREE.Group();
    const core = new THREE.Mesh(new THREE.SphereGeometry(1.15, 20, 14), new THREE.MeshBasicMaterial({ color: ORB[status], fog: false }));
    const halo = new THREE.Sprite(new THREE.SpriteMaterial({ map: haloTex, color: ORB[status], transparent: true, opacity: 0.85,
      blending: THREE.AdditiveBlending, depthWrite: false, fog: false }));
    halo.scale.setScalar(11);
    group.add(halo, core);
    scene.add(group);
    const label = document.createElement('div');
    label.className = 'orb-label';
    label.innerHTML = `<span class="dot"></span><span class="nm"></span><span class="st"></span>`;
    label.querySelector('.nm').textContent = name;
    labelsEl.append(label);
    sessions.set(id, { id, name, status, group, core, halo, label, phase: Math.random() * 6 });
    setStatus(id, status);
    placeSessions();
    sched.invalidate();
  }

  const STATUS_TEXT = { running: 'çalışıyor', idle: 'boşta', waiting: 'onay bekliyor' };
  function setStatus(id, status) {
    const s = sessions.get(id); if (!s) return;
    s.status = status;
    s.core.material.color.copy(ORB[status]);
    s.halo.material.color.copy(ORB[status]);
    s.label.dataset.status = status;
    s.label.querySelector('.st').textContent = STATUS_TEXT[status];
    sched.setBreath([...sessions.values()].some((x) => x.status !== 'idle'));
    sched.invalidate();
  }

  // ---- effects
  const effects = []; // {until, step(now) → bool alive}
  const v3 = new THREE.Vector3();

  function topOf(b) { return v3.set(b.x, b.h + 0.2, b.z).clone(); }

  function beam(sessionId, path, kind) {
    const s = sessions.get(sessionId), b = byPath.get(path);
    if (!s || !b) return;
    const from = s.group.position.clone(), to = topOf(b);
    const len = from.distanceTo(to);
    const strong = kind === 'edit';
    const mk = (r, op) => {
      const mm = new THREE.Mesh(new THREE.CylinderGeometry(r, r * (strong ? 0.6 : 0.8), len, 10, 1, true),
        new THREE.MeshBasicMaterial({ color: strong ? '#E0E7FF' : '#A5B4FC', transparent: true, opacity: 0, blending: THREE.AdditiveBlending,
          depthWrite: false, fog: false }));
      mm.position.copy(from).add(to).multiplyScalar(0.5);
      mm.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), to.clone().sub(from).normalize());
      mm.userData.max = op;
      scene.add(mm);
      return mm;
    };
    const parts = strong ? [mk(0.16, 0.95), mk(0.6, 0.28)] : [mk(0.1, 0.45), mk(0.45, 0.12)];
    if (!strong) { const sp = spot(to, '#A5B4FC', 6); sp.userData.max = 0.6; parts.push(sp); }
    const t0 = performance.now(), hold = strong ? 1800 : 1300, total = 300 + hold + 900;
    effects.push((now) => {
      const t = now - t0;
      const k = t < 300 ? t / 300 : t < 300 + hold ? 1 : Math.max(0, 1 - (t - 300 - hold) / 900);
      for (const pp of parts) pp.material.opacity = pp.userData.max * k;
      if (t >= total) { for (const pp of parts) { scene.remove(pp); if (!pp.isSprite) pp.geometry.dispose(); pp.material.dispose(); } return false; }
      return true;
    });
    sched.animate(total);
    if (strong) { lightUp(path, EDIT_GLOW, 8000); afterglow(to, '#C7D2FE', 14, 8000); }
    else lightUp(path, READ_GLOW, 2200, 0.35);
  }

  /** Building top lights up and fades out over `ms`. */
  const lit = new Map(); // instance → {color, t0, ms, peak}; the newest light on a building wins
  function lightUp(path, color, ms, peak = 1) {
    const b = byPath.get(path); if (!b) return;
    if (!lit.size) effects.push(glowTick);
    lit.set(b.i, { color, t0: performance.now(), ms, peak });
    sched.animate(ms);
  }
  function glowTick(now) {
    for (const [i, g] of lit) {
      const t = (now - g.t0) / g.ms;
      const k = t < 0.04 ? t / 0.04 : Math.pow(Math.max(0, 1 - t), 1.6);
      glow[i * 4] = g.color.r; glow[i * 4 + 1] = g.color.g; glow[i * 4 + 2] = g.color.b; glow[i * 4 + 3] = k * g.peak;
      if (t >= 1) lit.delete(i);
    }
    glowAttr.needsUpdate = true;
    return lit.size > 0;
  }

  function spot(at, color, size) {
    const sp = new THREE.Sprite(new THREE.SpriteMaterial({ map: haloTex, color, transparent: true, opacity: 0,
      blending: THREE.AdditiveBlending, depthWrite: false, fog: false }));
    sp.position.copy(at); sp.scale.setScalar(size);
    scene.add(sp);
    return sp;
  }
  /** Soft light over a building that fades with its glow (the building itself is only a few pixels wide). */
  function afterglow(at, color, size, ms) {
    const sp = spot(at, color, size), t0 = performance.now();
    effects.push((now) => {
      const t = (now - t0) / ms;
      sp.material.opacity = t < 0.04 ? t / 0.04 : Math.pow(Math.max(0, 1 - t), 1.6) * 0.9;
      if (t >= 1) { scene.remove(sp); sp.material.dispose(); return false; }
      return true;
    });
  }

  /** A file that was hidden in the layout rises from the ground. */
  function rise(path) {
    const b = byPath.get(path); if (!b) return;
    const t0 = performance.now(), ms = 2200;
    b.hidden = false;
    effects.push((now) => {
      const t = Math.min(1, (now - t0) / ms);
      const e = 1 - Math.pow(1 - t, 3);
      m.compose(p.set(b.x, 0, b.z), q, s.set(b.w, Math.max(0.0001, b.h * e), b.d));
      mesh.setMatrixAt(b.i, m); mesh.instanceMatrix.needsUpdate = true;
      return t < 1;
    });
    lightUp(path, NEW_GLOW, 6000, 0.9);
    afterglow(topOf(b), '#30D158', 12, 6000);
    sched.animate(ms);
  }

  // Commit burst: 220 points, ballistic, fading over 2.4 s.
  const burstTex = glowTexture();
  function burst() {
    const n = 220, pos = new Float32Array(n * 3), vel = new Float32Array(n * 3), col = new Float32Array(n * 3);
    const ca = new THREE.Color('#30D158'), cb = new THREE.Color('#A5B4FC'), cc = new THREE.Color('#ffffff');
    for (let i = 0; i < n; i++) {
      pos[i * 3] = 0; pos[i * 3 + 1] = 26; pos[i * 3 + 2] = -4;
      const th = Math.random() * Math.PI * 2, ph = Math.acos(2 * Math.random() - 1), sp = 14 + Math.random() * 16;
      vel[i * 3] = Math.sin(ph) * Math.cos(th) * sp; vel[i * 3 + 1] = Math.abs(Math.cos(ph)) * sp * 0.9 + 4; vel[i * 3 + 2] = Math.sin(ph) * Math.sin(th) * sp;
      const cl = i % 3 === 0 ? ca : i % 3 === 1 ? cb : cc;
      col.set([cl.r, cl.g, cl.b], i * 3);
    }
    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.BufferAttribute(pos, 3).setUsage(THREE.DynamicDrawUsage));
    g.setAttribute('color', new THREE.BufferAttribute(col, 3));
    const pm = new THREE.PointsMaterial({ size: 4, map: burstTex, vertexColors: true, transparent: true, opacity: 1,
      blending: THREE.AdditiveBlending, depthWrite: false, fog: false });
    const pts = new THREE.Points(g, pm);
    scene.add(pts);
    const t0 = performance.now(), ms = 2400;
    // Closed form (drag k, gravity G), so the burst looks the same at any frame rate.
    const k = 0.9, G = 16;
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

  /** Failed job: the whole city turns reddish for 2 s. */
  function alarm(ms = 2000) {
    const t0 = performance.now();
    effects.push((now) => {
      const t = (now - t0) / ms;
      uniforms.uAlarm.value = t < 0.12 ? t / 0.12 : Math.max(0, 1 - (t - 0.12) / 0.88) ** 1.5;
      renderer.setClearColor(c.copy(BG).lerp(new THREE.Color('#1a0606'), uniforms.uAlarm.value));
      return t < 1;
    });
    sched.animate(ms);
  }

  // ---- labels (HTML, positioned only when the camera or the session set changes)
  let size = { w: 1, h: 1 };
  function positionLabels() {
    for (const s of sessions.values()) {
      v3.copy(s.group.position).project(camera);
      const x = (v3.x * 0.5 + 0.5) * size.w, y = (-v3.y * 0.5 + 0.5) * size.h;
      s.label.style.transform = `translate(${x.toFixed(1)}px, ${(y - 34).toFixed(1)}px) translate(-50%, -100%)`;
    }
  }
  /** Screen position (CSS px within the canvas) of a building's top, for the file tag. */
  function screenOf(path) {
    const b = byPath.get(path); if (!b) return null;
    v3.set(b.x, b.h, b.z).project(camera);
    return { x: (v3.x * 0.5 + 0.5) * size.w, y: (-v3.y * 0.5 + 0.5) * size.h };
  }

  // ---- frame
  function draw(now) {
    for (let i = effects.length - 1; i >= 0; i--) if (!effects[i](now)) effects.splice(i, 1);
    // Breath (≤ 1 fps while idle): running orbs pulse a little, waiting orbs blink.
    const sec = Math.floor(now / 1000);
    for (const s of sessions.values()) {
      if (s.status === 'running') s.halo.scale.setScalar(11 * (1 + 0.07 * Math.sin(now / 900 + s.phase)));
      else if (s.status === 'waiting') { const on = sec % 2 === 0; s.halo.material.opacity = on ? 1 : 0.35; s.halo.scale.setScalar(on ? 14 : 10); }
      else { s.halo.scale.setScalar(8); s.halo.material.opacity = 0.45; }
    }
    renderer.render(scene, camera);
    onFrame?.(now);
  }
  const sched = createScheduler(draw);

  function resize() {
    const r = canvas.parentElement.getBoundingClientRect();
    size = { w: r.width, h: r.height };
    renderer.setSize(r.width, r.height, false);
    camera.aspect = r.width / r.height;
    // Fit the footprint: wider canvases see the city a bit closer.
    camera.updateProjectionMatrix();
    camera.updateMatrixWorld();
    positionLabels();
    sched.invalidate();
  }
  new ResizeObserver(resize).observe(canvas.parentElement);
  resize();

  /** Renders once and returns a small, blurred copy of the canvas (the diff card's pre-blurred background). */
  function blurredSnapshot(scale = 0.25, blur = 10) {
    renderer.render(scene, camera);
    const out = document.createElement('canvas');
    out.width = Math.round(size.w * scale); out.height = Math.round(size.h * scale);
    const g = out.getContext('2d');
    g.filter = `blur(${blur}px) brightness(.7) saturate(1.2)`;
    g.drawImage(canvas, -blur * 2, -blur * 2, out.width + blur * 4, out.height + blur * 4);
    return out;
  }

  const stats = { files: files.filter((f) => !f.hidden).length, lines: files.reduce((a, f) => a + (f.hidden ? 0 : f.lines), 0),
    districts: districts.filter((d) => d.depth === 1).length };

  return {
    stats, sched, addSession, setStatus, beam, lightUp, rise, burst, alarm, screenOf, blurredSnapshot,
    has: (path) => byPath.has(path),
    pause: () => sched.pause(), resume: () => sched.resume(),
    renderer,
  };
}
