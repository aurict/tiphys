// Claude brain over the code city (PLAN.md §20 E-2): one light orb per session floating above the city, laid out as a
// constellation (thin lines between neighbours), with an HTML name label. Colour by status: running = pale indigo
// with a slow pulse, waiting = orange blinking, idle = dim grey, still. Tool uses from the `claude` topic: a read
// sends a dim beam to the building, an edit a bright one (and the camera leans toward it). Frames: the renderer's
// scheduler only — the pulse on a 0.5 fps breath while one runs, beams are short effects; nothing is drawn when every
// session is idle; pause stops everything with the city. The waiting blink is NOT a 3D frame (W7: a 1 fps breath
// cost ~6.5 % of a laptop core): the orb stays lit and the HTML label blinks (a class toggled once a second, stopped
// on pause, with motion "low" and when nothing waits).
// With the flat (2D) city there are no orbs: the labels sit in a row at the top and beams light the building.
const COLORS = { running: '#C7D2FE', idle: '#8E8E93', waiting: '#FFB340' };
const STATUS_TEXT = { running: 'çalışıyor', idle: 'boşta', waiting: 'onay bekliyor' };

export function createBrain(labelsEl) {
  let r = null, haloTex = null, constel = null, motion = 'normal', paused = false, blinkTimer = 0;
  const orbs = new Map(); // id → {id, name, status, group, core, halo, label, phase, seen}
  const seen = new Map(); // id → latest tool-use time already shown (beams only for newer ones)
  let first = true;

  function glow(THREE) {
    const c = document.createElement('canvas'); c.width = c.height = 64;
    const g = c.getContext('2d');
    const grd = g.createRadialGradient(32, 32, 0, 32, 32, 32);
    grd.addColorStop(0, 'rgba(255,255,255,1)'); grd.addColorStop(0.25, 'rgba(255,255,255,.5)'); grd.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = grd; g.fillRect(0, 0, 64, 64);
    const t = new THREE.CanvasTexture(c); t.colorSpace = THREE.SRGBColorSpace;
    return t;
  }

  const is3d = () => r && r.layer && r.THREE;

  function makeOrb(o) {
    if (!is3d()) return;
    const T = r.THREE;
    o.group = new T.Group();
    o.core = new T.Mesh(new T.SphereGeometry(1.15, 20, 14), new T.MeshBasicMaterial({ color: COLORS[o.status], fog: false }));
    o.halo = new T.Sprite(new T.SpriteMaterial({ map: haloTex, color: COLORS[o.status], transparent: true, opacity: 0.85, blending: T.AdditiveBlending, depthWrite: false, fog: false }));
    o.halo.scale.setScalar(11);
    o.group.add(o.halo, o.core);
    r.layer.add(o.group);
  }
  function dropOrb(o) {
    if (!o.group) return;
    r?.layer?.remove(o.group);
    o.core.geometry.dispose(); o.core.material.dispose(); o.halo.material.dispose();
    o.group = o.core = o.halo = null;
    r?.setAnchor?.(o.id, null);
  }

  /** Constellation: spread along the city's width above it, alternating height/depth so neighbours don't overlap. */
  function layout() {
    const list = [...orbs.values()];
    const n = list.length;
    if (is3d()) {
      const T = r.THREE;
      list.forEach((o, i) => {
        const t = n === 1 ? 0.5 : i / (n - 1);
        const span = Math.min(60, 18 * (n - 1));
        o.group.position.set(-span / 2 + t * span + 2, 34 + (i % 2) * 7, -6 - (i % 2) * 14);
        r.setAnchor(o.id, o.group.position);
      });
      if (constel) { r.layer.remove(constel); constel.geometry.dispose(); constel.material.dispose(); constel = null; }
      if (n > 1) {
        const pts = [];
        for (let i = 0; i + 1 < n; i++) pts.push(list[i].group.position.clone(), list[i + 1].group.position.clone());
        constel = new T.LineSegments(new T.BufferGeometry().setFromPoints(pts), new T.LineBasicMaterial({ color: '#A5B4FC', transparent: true, opacity: 0.22, fog: false }));
        r.layer.add(constel);
      }
    }
    labelsEl.classList.toggle('flat', !is3d());
    place();
    r?.sched?.invalidate();
  }

  function paint(o) {
    o.label.dataset.status = o.status;
    o.label.querySelector('.st').textContent = STATUS_TEXT[o.status];
    if (o.core) { o.core.material.color.set(COLORS[o.status]); o.halo.material.color.set(COLORS[o.status]); }
  }

  /**
   * Breath only while something lives; never with motion "low". A waiting orb blinks once a second; running ones
   * only pulse every 2 s (a session may run for hours: each breath is a whole 3D frame, ~6 % of a laptop core at 1 fps).
   */
  function breath() {
    const list = [...orbs.values()];
    r?.setBreath?.(motion !== 'low' && list.some((o) => o.status === 'running'), 2000);
    blink(!paused && motion !== 'low' && list.some((o) => o.status === 'waiting'));
  }

  /** The waiting labels blink (1 s on, 1 s dim) without drawing the 3D scene. */
  function blink(on) {
    if (on === !!blinkTimer) return;
    clearInterval(blinkTimer);
    blinkTimer = on ? setInterval(() => labelsEl.classList.toggle('blink-off'), 1000) : 0;
    if (!on) labelsEl.classList.remove('blink-off');
  }

  /** Per frame (city effect): halo pulse from the clock; frames come from the breath or other effects. */
  function tick(now) {
    for (const o of orbs.values()) {
      if (!o.halo) continue;
      if (o.status === 'running') {
        o.halo.scale.setScalar(11 * (1 + 0.08 * Math.sin(now / 2600 + o.phase)));
        o.halo.material.opacity = 0.85;
      } else if (o.status === 'waiting') {
        o.halo.material.opacity = 1;
        o.halo.scale.setScalar(14);
      } else {
        o.halo.scale.setScalar(7.5);
        o.halo.material.opacity = 0.4;
      }
    }
    return true;
  }

  /** Labels over the orbs (positions change only with the camera or the set). */
  function place() {
    if (!is3d()) { for (const o of orbs.values()) o.label.style.transform = ''; return; }
    for (const o of orbs.values()) {
      const p = r.pointOnScreen(o.group.position);
      // Never over the info/note strips at the top left (their bottom is ~110 px; the label is 36 px tall).
      const y = Math.max(160, p.y - 30);
      o.label.style.transform = `translate(${p.x.toFixed(0)}px, ${y.toFixed(0)}px) translate(-50%, -100%)`;
    }
  }

  return {
    /** A (new) renderer: orbs are rebuilt on it. */
    attach(renderer) {
      for (const o of orbs.values()) dropOrb(o);
      if (constel && r?.layer) { r.layer.remove(constel); constel.geometry.dispose(); constel.material.dispose(); }
      constel = null;
      haloTex?.dispose(); haloTex = null;
      r = renderer;
      if (is3d()) {
        haloTex = glow(r.THREE);
        r.addEffect(tick);
      }
      for (const o of orbs.values()) { makeOrb(o); paint(o); }
      layout();
      breath();
    },
    detach() {
      for (const o of orbs.values()) dropOrb(o);
      constel = null; haloTex?.dispose(); haloTex = null; r = null;
    },
    setMotion(m) { motion = m; breath(); },
    pause() { paused = true; breath(); },
    resume() { paused = false; breath(); },
    /** `claude` message → orbs; returns the sessions whose status changed ([{s, from}]) for the pills. */
    update(sessions) {
      const changes = [];
      const ids = new Set(sessions.map((s) => s.id));
      let moved = false;
      for (const [id, o] of orbs) {
        if (ids.has(id)) continue;
        dropOrb(o); o.label.remove(); orbs.delete(id); seen.delete(id); moved = true;
      }
      for (const s of sessions) {
        let o = orbs.get(s.id);
        if (!o) {
          o = { id: s.id, name: s.name, status: s.status, phase: Math.random() * 6 };
          o.label = document.createElement('div');
          o.label.className = 'orb-label';
          o.label.innerHTML = '<span class="dot"></span><span class="nm"></span><span class="st"></span>';
          labelsEl.append(o.label);
          orbs.set(s.id, o);
          makeOrb(o);
          moved = true;
          if (!first) changes.push({ s, from: null });
        } else if (o.status !== s.status) changes.push({ s, from: o.status });
        o.status = s.status;
        o.name = s.name;
        o.label.querySelector('.nm').textContent = s.name || s.project || 'Claude';
        paint(o);
        // Beams for tool uses newer than the last shown (none for what was there before the page knew it).
        const last = seen.has(s.id) ? seen.get(s.id) : first ? Math.max(0, ...s.recent.map((u) => u.at)) : 0;
        let top = last;
        for (const u of s.recent) {
          if (u.at <= last) continue;
          top = Math.max(top, u.at);
          if (!r || !u.path || !u.kind) continue;
          r.beam(s.id, u.path, u.kind);
          if (u.kind === 'edit') r.focus?.(u.path);
        }
        seen.set(s.id, top);
      }
      first = false;
      if (moved) layout();
      breath();
      r?.sched?.invalidate();
      return changes;
    },
    /** Called on every city frame (labels follow the camera). */
    frame: place,
    get count() { return orbs.size; },
    destroy() {
      blink(false);
      for (const o of orbs.values()) { dropOrb(o); o.label.remove(); }
      orbs.clear();
      if (constel && r?.layer) { r.layer.remove(constel); constel.geometry.dispose(); constel.material.dispose(); }
      haloTex?.dispose();
      r = null;
    },
  };
}
