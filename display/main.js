// Tiphys screen mode kiosk page (PLAN.md §20 E-1): the mode/layout manager. Connects to the display agent's
// WS /v1/screen/live with the one-time display token from the URL fragment (#t=…). The agent sends `layout`
// ({mode, template, cards, settings}); the page builds that template and mounts its cards (cards/*.js:
// mount(el, ctx) → {update, pause, resume, destroy}). Another `layout` is a hot mode switch: the old view fades out and
// is destroyed, the new one fades in, no reload. `pause`/`resume` (the kiosk isn't on screen) stop every card's
// drawing and timers and freeze CSS animations. Topic messages (tagged with their source `src`) and spectrum frames
// go to the mounted cards. The socket, the Esc-hold stop, the notification pill and the problem card live here.
// Focus mode shows only critical pills (danger/warning tones and the timer's own). The privacy veil (`veil` {on})
// destroys the view at once and shows a dim clock; the agent sends nothing else until it lifts, then a fresh layout.
import { createPill, createProblem, setupEscHold, eventCopy } from './notify.js';
import { createScheduler } from './sched.js';
import * as game from './cards/game.js';
import * as day from './cards/day.js';
import * as city from './cards/city.js';
import * as system from './cards/system.js';
import * as jobs from './cards/jobs.js';
import * as git from './cards/git.js';
import * as music from './cards/music.js';
import * as servers from './cards/servers.js';
import * as focus from './cards/focus.js';
import * as task from './cards/task.js';
import { icon } from './icons.js';
import { fmtClock, fmtOverline } from './format.js';
import { everyMinute } from './sched.js';

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

// Cards that draw frames get them from one scheduler: nothing runs between changes (the city has its own, with its
// effect frame rate and pause).
const sched = createScheduler((now, dt) => { for (const c of view?.cards ?? []) c.frame?.(now, dt); });
/** Focus: only what can't wait (server down, Claude waiting, a failed job, the link) and the timer's own pills. */
const critical = (item) => item && (item.always || item.tone === 'danger' || item.tone === 'warning');
const ctx = { pill: (item) => { if (view?.mode !== 'focus' || critical(item)) pill.push(item); }, debug: DEBUG, frames: sched, title: setTitle };

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
    // The left area is the code city's; with the city card off, a quiet note.
    root.innerHTML = shell('tpl-work', 'ÇALIŞMA MODU', 'Çalışma', `<section class="work-grid"><div class="card hero work-main"><div class="city-soon">${icon('code', 40)}<div class="t1">Kod şehri kapalı</div><div class="t2">Telefondan Ekran modu › Çalışma › Düzen’de açılabilir.</div></div></div><div class="side-col"></div></section>`);
    const side = root.querySelector('.side-col');
    const out = [];
    const main = root.querySelector('.work-main');
    if (layout.cards.some((c) => c.kind === 'city' && c.enabled)) main.replaceChildren();
    mountCard(out, layout, 'city', city, main);
    mountCard(out, layout, 'day', day, side, { size: 'compact' });
    mountCard(out, layout, 'system', system, side);
    mountCard(out, layout, 'jobs', jobs, side);
    mountCard(out, layout, 'git', git, side);
    mountCard(out, layout, 'music', music, side);
    mountCard(out, layout, 'servers', servers, side);
    return out;
  },
  focus(root, layout) {
    // The W0 draft: the ring in the middle with the task under it, small clock top right, round line top left, music
    // bottom left, servers (only when something is wrong) and the "critical only" chip bottom right. Without the
    // timer card the day card takes the middle (a big clock).
    const timer = layout.cards.some((c) => c.kind === 'focus' && c.enabled);
    root.innerHTML = `<main class="stage tpl-focus"><canvas class="f-bg" aria-hidden="true"></canvas>
      <div class="f-corner f-tl"><div class="overline f-mode">ODAK MODU</div><div class="f-round"></div></div>
      <div class="f-corner f-tr"></div><section class="f-center"></section><div class="f-bl"></div>
      <div class="f-br"><div class="f-quiet chip">${icon('bell', 16)}<span>Yalnız kritik bildirimler</span></div></div></main>`;
    const stage = root.querySelector('.stage'), center = root.querySelector('.f-center');
    const out = [];
    const srv = layout.cards.some((c) => c.kind === 'servers' && c.enabled);
    mountCard(out, layout, 'focus', focus, center, { stage, servers: srv });
    mountCard(out, layout, 'task', task, center);
    if (center.querySelector('.f-break')) center.append(center.querySelector('.f-break')); // under the task line
    mountCard(out, layout, 'day', day, timer ? root.querySelector('.f-tr') : center, { size: timer ? 'corner' : 'big' });
    mountCard(out, layout, 'music', music, root.querySelector('.f-bl'));
    mountCard(out, layout, 'servers', servers, root.querySelector('.f-br'));
    root.querySelector('.f-br').append(root.querySelector('.f-quiet'));
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
  if (p) veilClock?.pause(); else veilClock?.resume();
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

// ------------------------------------------------------------------ privacy veil
let veiled = false, veilClock = null, clock24 = true;
const veilEl = $('#veil');
function setVeil(on) {
  if (on === veiled) return;
  veiled = on;
  document.body.classList.toggle('veiled', on);
  veilEl.hidden = !on;
  if (on) {
    // Nothing of the view survives: its cards stop (sound included) and its DOM goes.
    for (const c of view?.cards ?? []) c.destroy();
    for (const v of viewsEl.querySelectorAll('.view')) v.remove();
    view = null;
    pill.clear();
    const t = veilEl.querySelector('.veil-time'), sfx = veilEl.querySelector('.veil-suffix'), d = veilEl.querySelector('.veil-date');
    veilClock = everyMinute((now) => {
      const c = fmtClock(now, clock24);
      t.textContent = c.time; sfx.textContent = c.suffix; d.textContent = fmtOverline(now);
    });
    if (paused) veilClock.pause();
  } else {
    veilClock?.stop();
    veilClock = null; // the agent sends the layout and the state again
  }
}

function onMessage(m) {
  if (typeof m.clock24 === 'boolean') clock24 = m.clock24;
  else if (typeof m.settings?.clock24 === 'boolean') clock24 = m.settings.clock24;
  if (m.type === 'veil') return setVeil(m.on === true);
  // While veiled the agent sends no layout or topic; anything else (settings, sources) has no view to go to.
  if (veiled && m.type !== 'pause' && m.type !== 'resume' && m.type !== 'source') return;
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
