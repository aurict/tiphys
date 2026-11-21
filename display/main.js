// Tiphys screen mode kiosk page (PLAN.md §20 E-1): the mode/layout manager. Connects to the display agent's
// WS /v1/screen/live with the one-time display token from the URL fragment (#t=…). The agent sends `layout`
// ({mode, template, cards, settings}); the page builds that template and mounts its cards (cards/*.js:
// mount(el, ctx) → {update, pause, resume, destroy}). Another `layout` is a hot mode switch: the old view fades out and
// is destroyed, the new one fades in, no reload. `pause`/`resume` (the kiosk isn't on screen) stop every card's
// drawing and timers and freeze CSS animations. Topic messages (tagged with their source `src`) and spectrum frames
// go to the mounted cards. The socket, the Esc-hold stop, the notification pill and the problem card live here.
import { createPill, createProblem, setupEscHold, eventCopy } from './notify.js';
import { createScheduler } from './sched.js';
import * as game from './cards/game.js';
import * as day from './cards/day.js';
import * as system from './cards/system.js';
import * as jobs from './cards/jobs.js';
import * as git from './cards/git.js';
import * as music from './cards/music.js';
import * as servers from './cards/servers.js';
import { icon } from './icons.js';

const $ = (s) => document.querySelector(s);
const hash = new URLSearchParams(location.hash.slice(1));
const token = hash.get('t') ?? '';
window.__tphToken = token;
const DEBUG = hash.has('debug');

const pill = createPill($('#pill'));
const problem = createProblem($('#problem'));
const viewsEl = $('#views');

let view = null;             // { key, mode, template, root, cards, sources: Set<name> }
const sources = new Map();   // source name → { state, retryInSec }
let agg = { state: 'ok' };   // the current view's sources, worst first
let linkUp = false, everConnected = false, failures = 0, pageRetryAt = 0;
let agentPaused = false, paused = false;

// Cards that draw frames (W2+: system rings, the city) get them from one scheduler: nothing runs between changes.
const sched = createScheduler((now, dt) => { for (const c of view?.cards ?? []) c.frame?.(now, dt); });
const ctx = { pill: (item) => pill.push(item), debug: DEBUG, frames: sched, title: setTitle };

/** The Work view's title: "proje › dal" from the Git card; null → the mode name. */
function setTitle(rootName, branch) {
  const t = view?.root.querySelector('.topbar .title');
  if (!t) return;
  if (!rootName) { t.textContent = t.dataset.mode ?? ''; return; }
  t.innerHTML = '<span></span><span class="arrow">›</span><span></span>';
  t.firstChild.textContent = rootName;
  t.lastChild.textContent = branch ?? '';
  if (!branch) t.querySelector('.arrow').remove();
}

// ------------------------------------------------------------------ templates
// A template fills the view's root and returns its mounted cards. Card kinds the page can't draw yet are skipped.
const shell = (cls, overline, title, inner) =>
  `<main class="stage ${cls}"><header class="topbar"><div class="hdr"><div class="overline">${overline}</div><h1 class="title" data-mode="${title}">${title}</h1></div></header>${inner}</main>`;
/** Mounts the enabled card of `kind` (with its source) into `el`; nothing if the layout has none. */
const mountCard = (out, layout, kind, mod, el, opts = {}) => {
  const c = layout.cards.find((x) => x.kind === kind && x.enabled);
  if (c) out.push(mod.mount(el, ctx, { src: c.source, ...opts }));
};

const TEMPLATES = {
  game: (root) => [game.mount(root, ctx)],
  work(root, layout) {
    // The left area is the code city's (W3); until then a quiet placeholder.
    root.innerHTML = shell('tpl-work', 'ÇALIŞMA MODU', 'Çalışma', `<section class="work-grid"><div class="card hero work-main"><div class="city-soon">${icon('code', 40)}<div class="t1">Kod şehri</div><div class="t2">Projenin dosyaları ve Claude oturumları burada canlanacak.</div></div></div><div class="side-col"></div></section>`);
    const side = root.querySelector('.side-col');
    const out = [];
    mountCard(out, layout, 'day', day, side, { size: 'compact' });
    mountCard(out, layout, 'system', system, side);
    mountCard(out, layout, 'jobs', jobs, side);
    mountCard(out, layout, 'git', git, side);
    mountCard(out, layout, 'music', music, side);
    mountCard(out, layout, 'servers', servers, side);
    return out;
  },
  focus(root, layout) {
    // The timer and the task line are W5: the clock, music and (if something is wrong) the servers for now.
    root.innerHTML = shell('tpl-focus', 'ODAK MODU', 'Odak', '<section class="focus-center"><div class="focus-side"></div></section>');
    const center = root.querySelector('.focus-center'), below = root.querySelector('.focus-side');
    const out = [];
    mountCard(out, layout, 'day', day, center, { size: 'big' });
    center.append(below);
    mountCard(out, layout, 'music', music, below);
    mountCard(out, layout, 'servers', servers, below);
    return out;
  },
};

function applyLayout(m) {
  const key = JSON.stringify([m.mode, m.template, m.cards]);
  if (view?.key === key) { broadcast({ type: 'settings', ...m.settings }); return; }
  const build = TEMPLATES[m.template];
  const old = view;
  // The old cards stop first (the Game card resets page-wide state it set); their DOM fades out below.
  for (const c of old?.cards ?? []) c.destroy();
  const root = document.createElement('div');
  root.className = 'view entering';
  // Same template again (its cards changed): the old DOM goes at once, the new one must not find the old elements.
  if (old && (old.template === m.template || m.settings?.motion === 'low')) old.root.remove();
  viewsEl.append(root);
  document.body.dataset.mode = m.mode;
  document.body.dataset.motion = m.settings?.motion ?? 'normal';
  const names = new Set(m.cards.filter((c) => c.enabled && c.source !== 'self').map((c) => c.source));
  view = { key, mode: m.mode, template: m.template, root, cards: [], sources: names };
  view.cards = build ? build(root, m) : [];
  broadcast({ type: 'settings', ...m.settings });
  for (const [name, s] of sources) broadcast({ type: 'srcstate', name, state: s.state });
  updateAgg(false);
  broadcast({ type: 'source', ...agg });
  if (paused) for (const c of view.cards) c.pause();
  requestAnimationFrame(() => requestAnimationFrame(() => root.classList.remove('entering')));
  if (old?.root.isConnected) {
    old.root.classList.add('leaving');
    setTimeout(() => old.root.remove(), 600);
  }
  showProblem();
}

function broadcast(m) {
  for (const c of view?.cards ?? []) c.update(m);
}

// ------------------------------------------------------------------ sources
const RANK = { ok: 0, connecting: 1, off: 1, down: 2 };
/** Worst state of the view's remote sources (none: "ok", the view reads this host only). */
function updateAgg(pills = true) {
  const prev = agg.state;
  let next = { state: 'ok' };
  for (const n of view?.sources ?? []) {
    const s = sources.get(n) ?? { state: 'connecting' };
    if (RANK[s.state] > RANK[next.state]) next = { state: s.state === 'off' ? 'connecting' : s.state, ...(s.retryInSec !== undefined ? { retryInSec: s.retryInSec } : {}) };
  }
  agg = next;
  if (pills && prev === 'ok' && next.state === 'down') pill.push(eventCopy({ kind: 'linkDown', detail: 'Kaynak bilgisayar' }));
  if (pills && prev === 'down' && next.state === 'ok') pill.push(eventCopy({ kind: 'linkUp' }));
}

function applySource(m) {
  sources.set(m.name, { state: m.state, retryInSec: m.retryInSec });
  broadcast({ type: 'srcstate', name: m.name, state: m.state }); // cards that read this source follow it
  if (!view?.sources.has(m.name)) return;
  updateAgg();
  broadcast({ type: 'source', ...agg });
  showProblem();
}

function showProblem() {
  if (!linkUp && (everConnected || failures >= 2)) {
    problem.show({ title: everConnected ? 'Ekran bağlantısı koptu' : 'Ekran bağlanamıyor', text: 'Bu bilgisayardaki Tiphys ajanı yanıt vermiyor. Ajan yeniden açılınca ekran kendiliğinden döner.',
      retryInSec: Math.max(1, Math.round((pageRetryAt - Date.now()) / 1000)) });
  } else if (linkUp && agg.state === 'down') {
    const what = view?.mode === 'game' ? 'Oyun ve müzik bilgisinin' : 'Ekrandaki bilgilerin';
    problem.show({ title: 'Kaynağa ulaşılamıyor', text: `${what} geldiği bilgisayardaki Tiphys ajanına bağlanılamadı. Açık ve Tailscale’de mi?`,
      retryInSec: agg.retryInSec ?? 0 });
  } else problem.hide();
}

// ------------------------------------------------------------------ pause / resume
function setPaused() {
  const p = agentPaused || document.hidden;
  if (p === paused) return;
  paused = p;
  document.body.classList.toggle('paused', p);
  if (p) sched.pause(); else sched.resume();
  for (const c of view?.cards ?? []) (p ? c.pause() : c.resume());
}
document.addEventListener('visibilitychange', setPaused);

// ------------------------------------------------------------------ socket
let ws = null, backoff = 1000;
function connect() {
  if (!token) {
    problem.show({ title: 'Ekran jetonu yok', text: 'Bu sayfa Tiphys › Ekran modu › Başlat ile açılır.', retryInSec: 0 });
    return;
  }
  const url = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/v1/screen/live?t=${encodeURIComponent(token)}`;
  ws = new WebSocket(url);
  ws.binaryType = 'arraybuffer';
  ws.onopen = () => { linkUp = true; backoff = 1000; failures = 0; if (everConnected) pill.push(eventCopy({ kind: 'linkUp' })); everConnected = true; showProblem(); };
  ws.onmessage = (e) => {
    if (typeof e.data !== 'string') {
      const b = new Uint8Array(e.data);
      if (b[0] === 0x01 && b.length >= 25) broadcast({ type: 'spectrum', bytes: b });
      return;
    }
    let m;
    try { m = JSON.parse(e.data); } catch { return; }
    onMessage(m);
  };
  ws.onclose = () => {
    const wasUp = linkUp;
    linkUp = false;
    failures++;
    pageRetryAt = Date.now() + backoff;
    if (wasUp) pill.push(eventCopy({ kind: 'linkDown', detail: 'Ekran ajanı' }));
    broadcast({ type: 'link', up: false });
    showProblem();
    setTimeout(connect, backoff);
    backoff = Math.min(10_000, backoff * 2);
  };
}

function onMessage(m) {
  switch (m.type) {
    case 'layout': applyLayout(m); break;
    case 'source': applySource(m); break;
    case 'pause': agentPaused = true; setPaused(); break;
    case 'resume': agentPaused = false; setPaused(); break;
    default: broadcast(m); break; // settings and topic messages
  }
}

// ------------------------------------------------------------------ Esc hold → stop
setupEscHold($('#esc-hold'), () => { if (ws && ws.readyState === 1) ws.send(JSON.stringify({ type: 'stop' })); });

connect();
