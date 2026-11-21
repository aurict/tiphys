// Code city card (PLAN.md §20 E-2, E-5): the selected project's files as a city (city/scene3d.js, or the flat
// city/flat.js with the `city: "2d"` setting or without WebGL). Messages of the `city` topic: `city` (whole snapshot,
// also after a page reload), `cityPatch` (incremental), `touch` (edit glow / rise / sink, a file tag and a gentle
// refocus), `commit` (burst); `jobDone` with a non-zero exit code tints the city red for 2 s. States: connecting,
// no project / not a repository / not allowed, huge repository (folder-level city + note), masked names (the source
// doesn't share code), source unreachable (the last city stays, dimmed, with a note). The renderer draws only on
// changes; pause() stops it. W4: the `claude` topic's sessions float above the city as orbs (city/brain.js; beams to
// the buildings they read/edit), and a `diff` turns the area into the approval preview (diff/card.js) with the city
// frozen behind it; a session waiting without a diff gets a banner. Pills: "Claude onay bekliyor", "Claude bitirdi".
import { icon } from '../icons.js';
import { fmtInt } from '../format.js';
import { sourceGate } from './common.js';
import { KINDS } from '../city/kinds.js';
import { createCityFlat } from '../city/flat.js';
import { createBrain } from '../city/brain.js';
import { createApproval } from '../diff/card.js';
import { eventCopy } from '../notify.js';

const NONE = {
  noProject: ['Proje seçilmedi', 'Bir Claude oturumu açınca ya da terminalde bir depoya geçince kendiliğinden seçilir; telefondan sabit bir proje de seçilebilir.'],
  notRepo: ['Git deposu değil', 'Seçilen klasörde .git yok; şehir git’in bildiği dosyalardan kurulur.'],
  notAllowed: ['Bu klasöre izin yok', 'Sabit proje, ajanın izinli klasörlerinden birinde olmalı.'],
};
const TAG = { edit: ['pencil', 'edit'], create: ['filePlus', 'new'], delete: ['fileMinus', 'gone'] };

export function mount(el, ctx, { src = 'self' } = {}) {
  const root = document.createElement('div');
  root.className = 'city';
  root.dataset.state = 'connecting';
  root.innerHTML = `<div class="city-gl"></div><div class="file-tags"></div><div class="orb-labels"></div>
    <div class="overlay-strip city-info"><span class="ci-ic">${icon('code', 17)}</span><b class="ci-root"></b><span class="sep"></span><span class="ci-files"></span><span class="sep ci-l"></span><span class="ci-lines ci-l"></span></div>
    <div class="overlay-strip city-note"></div>
    <div class="overlay-strip city-legend"></div>
    <div class="overlay-strip city-down">${icon('linkOff', 17)}<span>Kaynağa ulaşılamıyor · son bilinen durum</span></div>
    <div class="city-empty" role="status"><div class="ce-ic">${icon('code', 40)}</div><div class="t1">Bağlanıyor…</div><div class="t2"></div></div>`;
  el.append(root);
  const $ = (s) => root.querySelector(s);
  const glHost = $('.city-gl'), tagsEl = $('.file-tags');

  let motion = 'normal', mode = '3d', paused = false, frozen = false;
  let meta = null;                 // {root, truncated, total, masked}
  const files = new Map();         // path → [path, lines, kind]
  let r = null, rGen = 0, building = null;
  const tags = [];
  let infoTimer = 0, perfTimer = 0;

  const gate = sourceGate(src, () => root.classList.toggle('down', gate.down));
  const brain = createBrain($('.orb-labels'));
  const approval = createApproval(root, {
    snapshot: () => r?.blurredSnapshot?.() ?? flatSnapshot(),
    freeze: () => { frozen = true; r?.pause(); },
    thaw: () => { frozen = false; if (!paused) r?.resume(); },
  });
  /** The flat city has no snapshot of its own: a small blurred copy of its canvas. */
  function flatSnapshot() {
    const c = glHost.querySelector('canvas');
    if (!c?.width) return null;
    const out = document.createElement('canvas');
    out.width = Math.round(c.clientWidth / 4); out.height = Math.round(c.clientHeight / 4);
    const g = out.getContext('2d');
    g.filter = 'blur(10px) brightness(.7)';
    g.drawImage(c, -20, -20, out.width + 40, out.height + 40);
    return out;
  }

  function setEmpty(t1, t2 = '') {
    $('.city-empty .t1').textContent = t1;
    $('.city-empty .t2').textContent = t2;
  }

  // ---- renderer (created when a city arrives; replaced when 3D/2D changes; dropped with no project)
  async function ensureRenderer() {
    const want = mode === '2d' ? '2d' : '3d';
    if (r && (r.kind === want || r.fellBack)) return r;
    if (building) return building;
    const gen = ++rGen;
    building = (async () => {
      dropRenderer();
      const canvas = document.createElement('canvas');
      canvas.setAttribute('aria-label', 'Kod şehri');
      glHost.replaceChildren(canvas);
      let made = null;
      if (want === '3d') {
        try {
          const { createCity3d } = await import('../city/scene3d.js');
          if (gen === rGen) made = createCity3d(canvas, { motion, onFrame });
        } catch (e) {
          if (ctx.debug) console.warn('WebGL şehir açılamadı, düz şehre geçiliyor', e);
          const c2 = document.createElement('canvas');
          glHost.replaceChildren(c2);
          made = createCityFlat(c2, { motion, onFrame });
          made.fellBack = true;
        }
      } else made = createCityFlat(canvas, { motion, onFrame });
      if (gen !== rGen) { made?.destroy(); return r; }
      r = made;
      if (paused || frozen) r.pause();
      r.setFiles([...files.values()]);
      brain.attach(r);
      return r;
    })().finally(() => { if (gen === rGen) building = null; });
    return building;
  }
  function dropRenderer() {
    brain.detach();
    r?.destroy();
    r = null;
    glHost.replaceChildren();
    for (const t of tags.splice(0)) t.el.remove();
  }

  // ---- overlays
  function drawInfo() {
    infoTimer = 0;
    if (!meta) return;
    $('.ci-root').textContent = meta.root;
    let lines = 0;
    const kinds = new Set();
    for (const f of files.values()) { lines += f[1]; kinds.add(f[2]); }
    $('.ci-files').textContent = meta.truncated ? `${fmtInt(meta.total)} dosya` : `${fmtInt(files.size)} dosya`;
    $('.ci-lines').textContent = `${meta.truncated ? '≈ ' : ''}${fmtInt(lines)} satır`;
    const notes = [];
    if (meta.truncated) notes.push(`${icon('folder', 16)}<span>Büyük depo · klasör düzeyinde (${fmtInt(files.size)} klasör)</span>`);
    if (meta.masked) notes.push(`${icon('eyeOff', 16)}<span>Dosya adları gizli · kaynakta kod paylaşımı kapalı</span>`);
    $('.city-note').innerHTML = notes.join('<span class="sep"></span>');
    $('.city-note').hidden = !notes.length;
    $('.city-legend').innerHTML = Object.entries(KINDS).filter(([k]) => kinds.has(k))
      .map(([, k]) => `<span><i style="background:${k.color}"></i>${k.label}</span>`).join('');
  }
  const info = () => { if (!infoTimer) infoTimer = setTimeout(drawInfo, 500); };

  /** A file tag over the building (not for masked names), kept on the roof while the camera moves. */
  function tag(path, kind, ms) {
    if (!r || meta?.masked || motion === 'low' || !TAG[kind]) return;
    const p = r.screenOf(path);
    if (!p) return;
    while (tags.length >= 3) tags.shift().el.remove();
    const el = document.createElement('div');
    el.className = `file-tag ${TAG[kind][1]}`;
    el.innerHTML = icon(TAG[kind][0], 15);
    const name = document.createElement('span');
    name.textContent = path.length > 48 ? `…${path.slice(-47)}` : path;
    el.append(name);
    tagsEl.append(el);
    const t = { el, path };
    tags.push(t);
    place(t, p);
    requestAnimationFrame(() => el.classList.add('on'));
    setTimeout(() => {
      el.classList.remove('on');
      setTimeout(() => { el.remove(); const i = tags.indexOf(t); if (i >= 0) tags.splice(i, 1); }, 450);
    }, ms);
  }
  function place(t, p = r?.screenOf(t.path)) {
    if (p) t.el.style.transform = `translate(${p.x.toFixed(0)}px, ${(p.y - 12).toFixed(0)}px) translate(-50%, -100%)`;
  }
  function onFrame() {
    for (const t of tags) place(t);
    brain.frame();
  }

  function onClaude(m) {
    const sessions = Array.isArray(m.sessions) ? m.sessions.filter((x) => x && typeof x.id === 'string') : [];
    for (const { s, from } of brain.update(sessions)) {
      if (s.status === 'waiting' && from !== 'waiting') {
        const file = s.waiting?.path && !meta?.masked ? s.waiting.path.split('/').pop() : null;
        ctx.pill(eventCopy({ kind: 'claudeWaiting', detail: [s.name, [s.waiting?.tool, file].filter(Boolean).join(' ')].filter(Boolean).join(' · ') }));
      } else if (s.status === 'idle' && (from === 'running' || from === 'waiting')) ctx.pill(eventCopy({ kind: 'claudeDone', detail: s.name }));
    }
    approval.sessions(sessions, meta?.masked === true);
  }

  // ---- messages
  function onCity(m) {
    if (m.none) {
      meta = null;
      files.clear();
      rGen++;
      dropRenderer();
      root.dataset.state = 'none';
      const [t1, t2] = NONE[m.none] ?? NONE.notRepo;
      return setEmpty(t1, t2);
    }
    meta = { root: m.root, truncated: m.truncated === true, total: m.total ?? 0, masked: m.masked === true };
    files.clear();
    for (const f of m.files ?? []) if (Array.isArray(f) && typeof f[0] === 'string') files.set(f[0], f);
    root.dataset.state = files.size ? 'ready' : 'none';
    if (!files.size) setEmpty('Bu depoda dosya yok', 'Git’in bildiği bir dosya eklenince şehir kurulur.');
    drawInfo();
    if (r) r.setFiles([...files.values()]);
    else void ensureRenderer();
  }

  function onPatch(m) {
    if (!meta) return;
    const up = (m.upsert ?? []).filter((f) => Array.isArray(f) && typeof f[0] === 'string');
    const rm = (m.remove ?? []).filter((p) => typeof p === 'string');
    for (const f of up) files.set(f[0], f);
    for (const p of rm) files.delete(p);
    r?.patch(up, rm);
    if (files.size && root.dataset.state === 'none') { root.dataset.state = 'ready'; void ensureRenderer(); }
    info();
  }

  function onTouch(m) {
    if (!r || typeof m.path !== 'string') return;
    r.touch(m.path, m.kind);
    if (m.kind === 'create') {
      // The new building gets its place with the next layout (≈ 0.6 s): tag and look at it then.
      setTimeout(() => { if (r) { r.focus(m.path); tag(m.path, 'create', 3200); } }, 900);
    } else {
      r.focus(m.path);
      tag(m.path, m.kind, m.kind === 'delete' ? 2200 : 3200);
    }
  }

  function settings(m) {
    const nextMotion = m.motion ?? motion, nextMode = m.city ?? mode;
    if (nextMotion !== motion) { motion = nextMotion; r?.setMotion(motion); brain.setMotion(motion); }
    if (m.diff !== undefined) approval.setEnabled(m.diff !== false);
    if (nextMode !== mode) {
      mode = nextMode;
      if (r && meta) { rGen++; building = null; dropRenderer(); void ensureRenderer(); }
    }
  }

  if (ctx.debug) {
    const perf = document.getElementById('perf');
    perf.hidden = false;
    let last = 0;
    perfTimer = setInterval(() => {
      const f = r?.sched.stats.frames ?? 0;
      perf.textContent = `şehir ${r?.kind ?? '–'} · ${f - last} fps · ${r?.count ?? 0} bina`;
      last = f;
    }, 1000);
  }

  return {
    /** The renderer (W4: orbs, beams, focus); null until a city arrived. */
    get city() { return r; },
    update(m) {
      if (m.type === 'settings') return settings(m);
      if (!gate.mine(m)) return;
      switch (m.type) {
        case 'city': return onCity(m);
        case 'cityPatch': return onPatch(m);
        case 'touch': return onTouch(m);
        case 'commit': return r?.commit();
        case 'jobDone': if (typeof m.exitCode === 'number' && m.exitCode !== 0) r?.alarm(2000); return;
        case 'claude': return onClaude(m);
        case 'diff': return approval.diff(m);
        case 'diffResolved': return approval.resolved(m);
        default: return;
      }
    },
    pause() { paused = true; r?.pause(); approval.pause(); brain.pause(); },
    resume() { paused = false; if (!frozen) r?.resume(); approval.resume(); brain.resume(); },
    destroy() {
      rGen++;
      brain.destroy();
      approval.destroy();
      clearTimeout(infoTimer);
      clearInterval(perfTimer);
      dropRenderer();
      root.remove();
    },
  };
}
