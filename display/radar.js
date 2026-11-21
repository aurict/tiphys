// Map fallback: a dark "radar" in game coordinates (heading-up, subtle world grid, range rings, the truck as an accent
// arrow and an in-memory breadcrumb trail, never stored). map.js shows it while the real map loads and keeps it when the
// map data is missing or WebGL fails. Same interface as createMap (update, setDestination, setMotion, setTone, frame)
// plus destroy().

const TRAIL_STEP = 8;        // m between breadcrumbs
const TRAIL_MAX = 5000;      // points (~40 km)
const JUMP = 3000;           // m: a bigger jump (ferry, train, teleport) breaks the trail

export function createRadar(el) {
  const canvas = document.createElement('canvas');
  canvas.className = 'map-canvas';
  el.prepend(canvas);
  const g = canvas.getContext('2d');
  let w = 0, h = 0, dpr = 1;
  let tone = [165, 180, 252];
  let motion = 'normal';
  let destination = null;

  // Interpolation: from the rendered pose toward the newest sample over the measured sample interval.
  let pose = null;            // {x, z, hd} as drawn
  let from = null, to = null, t0 = 0, dur = 50, lastArrival = 0;
  let speed = 0, mpp = 0.9;   // metres per CSS pixel (zoom), eased with speed
  const trail = [];
  let lastDraw = 0, dirty = true;

  function resize() {
    const r = el.getBoundingClientRect();
    dpr = motion === 'high' ? Math.min(2, devicePixelRatio || 1) : 1; // soft content: CSS-pixel canvas is enough
    w = r.width; h = r.height;
    canvas.width = Math.round(w * dpr);
    canvas.height = Math.round(h * dpr);
    dirty = true;
  }
  const ro = new ResizeObserver(resize);
  ro.observe(el);

  const angleOf = (heading) => heading * Math.PI * 2; // SCS: 0 = north, counter-clockwise
  const lerpAngle = (a, b, t) => {
    let d = (b - a) % (Math.PI * 2);
    if (d > Math.PI) d -= Math.PI * 2;
    if (d < -Math.PI) d += Math.PI * 2;
    return a + d * t;
  };

  function update(tr) {
    if (!tr || tr.state === 'none' || tr.x == null) return;
    const now = performance.now();
    const sample = { x: tr.x, z: tr.z, hd: angleOf(tr.heading ?? 0) };
    speed = Math.abs(tr.speed ?? 0);
    if (!pose || Math.hypot(sample.x - pose.x, sample.z - pose.z) > JUMP) {
      pose = { ...sample };
      from = to = sample;
      if (trail.length) trail.push(null);
    } else {
      from = { ...pose };
      to = sample;
      if (lastArrival) dur = Math.min(250, Math.max(16, now - lastArrival));
    }
    t0 = now;
    lastArrival = now;
    const lp = trail[trail.length - 1];
    if (!lp || Math.hypot(lp.x - sample.x, lp.z - sample.z) >= TRAIL_STEP) {
      trail.push({ x: sample.x, z: sample.z });
      if (trail.length > TRAIL_MAX) trail.splice(0, trail.length - TRAIL_MAX);
    }
    dirty = true;
  }

  function draw(now) {
    if (!w || !h) return;
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    g.clearRect(0, 0, w, h);
    if (!pose) return;
    const k = Math.min(1, (now - t0) / dur);
    pose = { x: from.x + (to.x - from.x) * k, z: from.z + (to.z - from.z) * k, hd: lerpAngle(from.hd, to.hd, k) };
    // Zoom out with speed: ~0.9 m/px parked → ~2.4 m/px at 90 km/h and above.
    const target = 0.9 + Math.min(1, speed / 25) * 1.5;
    mpp += (target - mpp) * 0.03;

    const cx = w / 2, cy = h * 0.66; // truck sits low: more road ahead
    const s = 1 / mpp;
    // World → screen: translate to truck, rotate so heading points up, scale. Game z grows southward.
    g.save();
    g.translate(cx, cy);
    g.rotate(pose.hd);
    g.scale(s, s);
    g.translate(-pose.x, -pose.z);

    // World grid (100 m minor, 500 m major) over the visible circle.
    const R = Math.hypot(w, h) * mpp;
    const lw = mpp;
    const grid = (step, alpha) => {
      g.beginPath();
      const x0 = Math.floor((pose.x - R) / step) * step, z0 = Math.floor((pose.z - R) / step) * step;
      for (let x = x0; x <= pose.x + R; x += step) { g.moveTo(x, pose.z - R); g.lineTo(x, pose.z + R); }
      for (let z = z0; z <= pose.z + R; z += step) { g.moveTo(pose.x - R, z); g.lineTo(pose.x + R, z); }
      g.strokeStyle = `rgba(255,255,255,${alpha})`;
      g.lineWidth = lw;
      g.stroke();
    };
    grid(100, 0.035);
    grid(500, 0.07);

    // Trail: wide soft stroke under a crisp one, fading toward the oldest points.
    if (trail.length > 1) {
      const [r, gg, b] = tone.map(Math.round);
      const n = trail.length;
      const BAND = 6;
      g.lineCap = 'round'; g.lineJoin = 'round';
      // Soft glow in age bands (older = fainter), then one crisp line (a single path: no doubled alpha at joins).
      g.lineWidth = 14 * lw;
      {
        const pass = 0;
        for (let i0 = 0; i0 < n - 1; i0 += Math.ceil(n / BAND)) {
          const i1 = Math.min(n - 1, i0 + Math.ceil(n / BAND));
          const age = i1 / (n - 1);
          g.beginPath();
          let pen = false;
          for (let i = i0; i <= i1; i++) {
            const p = trail[i];
            if (!p) { pen = false; continue; }
            if (pen) g.lineTo(p.x, p.z); else { g.moveTo(p.x, p.z); pen = true; }
          }
          if (i1 === n - 1 && pen) g.lineTo(pose.x, pose.z);
          g.strokeStyle = `rgba(${r},${gg},${b},${0.10 * (0.15 + 0.85 * age) * (pass + 1)})`;
          g.stroke();
        }
      }
      g.beginPath();
      let pen = false;
      for (const p of trail) {
        if (!p) { pen = false; continue; }
        if (pen) g.lineTo(p.x, p.z); else { g.moveTo(p.x, p.z); pen = true; }
      }
      if (pen) g.lineTo(pose.x, pose.z);
      g.lineWidth = 4.5 * lw;
      g.strokeStyle = `rgba(${r},${gg},${b},0.7)`;
      g.stroke();
    }
    g.restore();

    // Range rings around the truck (screen space), labelled in metres/km.
    const ringStep = mpp < 1.4 ? 250 : 500;
    g.font = '600 12px JetBrainsMono, monospace';
    g.textAlign = 'center';
    for (let i = 1; i <= 4; i++) {
      const rr = (ringStep * i) / mpp;
      if (rr > Math.hypot(w, h)) break;
      g.beginPath();
      g.arc(cx, cy, rr, 0, Math.PI * 2);
      g.strokeStyle = 'rgba(255,255,255,0.06)';
      g.lineWidth = 1;
      g.setLineDash(i % 2 ? [2, 6] : []);
      g.stroke();
      g.setLineDash([]);
      const m = ringStep * i;
      if (cy - rr > 70) {
        g.fillStyle = 'rgba(245,245,247,0.32)';
        g.fillText(m >= 1000 ? `${m / 1000} km` : `${m} m`, cx, cy - rr - 6);
      }
    }

    // North marker on an inner circle, rotating with the map.
    const nr = Math.min(w, h) * 0.5 - 40;
    const na = -Math.PI / 2 + pose.hd;
    const nx = cx + Math.cos(na) * nr, ny = cy + Math.sin(na) * nr;
    if (nx > 24 && nx < w - 24 && ny > 90 && ny < h - 24) {
      g.fillStyle = 'rgba(245,245,247,0.55)';
      g.font = '700 13px PlusJakartaSans, sans-serif';
      g.textBaseline = 'middle';
      g.fillText('K', nx, ny);
      g.textBaseline = 'alphabetic';
    }

    // Truck: halo + arrow (always pointing up).
    const [r, gg, b] = tone.map(Math.round);
    const halo = g.createRadialGradient(cx, cy, 0, cx, cy, 46);
    halo.addColorStop(0, `rgba(${r},${gg},${b},0.35)`);
    halo.addColorStop(1, `rgba(${r},${gg},${b},0)`);
    g.fillStyle = halo;
    g.beginPath(); g.arc(cx, cy, 46, 0, Math.PI * 2); g.fill();
    g.beginPath();
    g.moveTo(cx, cy - 17);
    g.lineTo(cx + 12, cy + 13);
    g.lineTo(cx, cy + 7);
    g.lineTo(cx - 12, cy + 13);
    g.closePath();
    g.fillStyle = '#F5F5F7';
    g.shadowColor = 'rgba(0,0,0,0.6)'; g.shadowBlur = 8;
    g.fill();
    g.shadowBlur = 0;
    g.strokeStyle = `rgb(${r},${gg},${b})`;
    g.lineWidth = 2.5;
    g.lineJoin = 'round';
    g.stroke();
  }

  return {
    update,
    destroy() { ro.disconnect(); canvas.remove(); },
    setDestination(name) { destination = name; },
    get destination() { return destination; },
    setMotion(m) { if (m !== motion) { motion = m; resize(); } },
    setTone(rgb) { tone = rgb; dirty = true; },
    frame(now) {
      const moving = pose && to && (now - t0 < dur + 20 || speed > 0.1);
      if (!dirty && !moving) return;
      // 30 fps (the radar moves slowly; each 2D canvas frame costs a texture upload), 60 only with motion=high.
      if (motion !== 'high' && now - lastDraw < 30) return;
      lastDraw = now;
      dirty = false;
      draw(now);
    },
  };
}
