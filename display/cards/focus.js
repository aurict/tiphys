// Odak card (PLAN.md §20 E-3, W5): the big countdown ring with the phase, the round dots, the corner round line, the
// break card ("Kalk, su iç") and the very slow background; plus the mode's sound (ambient noise while focusing, the
// end-of-round chime) and its critical pills (Claude waiting for approval, a server down). The timer lives in the
// display agent (`focus` messages: phase, endsAt / pausedLeft, total, round, longEvery, task, cause).
// Cost: one timeout per second only while a phase runs and the page is shown (text + one stroke attribute); the
// background canvas (quarter resolution) is repainted every 10 s (W0: 10 % of a core when it was every second); a
// paused timer, the idle state and a hidden page wake nothing.
// mount(el, ctx, {src, stage, servers}) → {update, pause, resume, destroy}; `stage` is the template root (it gets
// data-phase), `servers`: a Sunucular card is mounted (it pills server changes itself).
import { icon } from '../icons.js';
import { eventCopy } from '../notify.js';
import { createSound } from '../focus/sound.js';
import { sourceGate } from './common.js';

const LABEL = { idle: 'HAZIR', focus: 'ODAK', short: 'KISA MOLA', long: 'UZUN MOLA' };
const BLOBS = {
  focus: [[124, 116, 240, 0.30], [80, 200, 150, 0.12], [94, 92, 230, 0.16]],
  break: [[242, 169, 133, 0.34], [255, 179, 64, 0.16], [240, 120, 110, 0.14]],
};
const BG_MS = 10_000;
/** One sound for the page: the AudioContext outlives a view (a veil or mode switch rebuilds the cards). */
let sound = null;

export function mount(el, ctx, { src = 'self', stage = el, servers = false } = {}) {
  sound ??= createSound();
  const root = document.createElement('section');
  root.className = 'f-timer';
  root.setAttribute('aria-label', 'Odak sayacı');
  root.innerHTML = `<div class="f-ring">
      <svg class="ring" viewBox="0 0 200 200" aria-hidden="true"><circle class="track" cx="100" cy="100" r="92"/><circle class="arc" cx="100" cy="100" r="92" pathLength="100"/></svg>
      <div class="f-inner"><div class="f-phase"></div><div class="f-time" role="timer"></div><div class="f-sub"></div></div>
    </div>
    <div class="f-dots" aria-hidden="true"></div>
    <article class="card f-break" hidden>
      <div class="fb-ic">${icon('droplet', 34)}</div>
      <div class="fb-txt"><div class="fb-t">Kalk, su iç</div><div class="fb-s"></div><div class="fb-next" hidden>Sonra: <span></span></div></div>
    </article>`;
  el.append(root);
  const $ = (s) => root.querySelector(s);
  const phaseEl = $('.f-phase'), timeEl = $('.f-time'), subEl = $('.f-sub'), arc = $('.arc'), dots = $('.f-dots');
  const brk = $('.f-break'), brkSub = $('.fb-s'), next = $('.fb-next');
  const round = stage.querySelector('.f-round'), modeEl = stage.querySelector('.f-mode');
  const cv = stage.querySelector('.f-bg');
  const g = cv?.getContext('2d', { alpha: false });

  let f = { phase: 'idle', endsAt: null, pausedLeft: null, total: null, round: 0, longEvery: 4, task: null };
  let skew = 0; // agent clock − page clock (the same host: ~0)
  let settings = { focusMin: 25, motion: 'normal', ambient: 'off', ambientVolume: 30, chime: true };
  let paused = false, tick = 0, bgTimer = 0, lastText = '', lastDash = '', music = false;
  const claudeWaiting = new Set();
  const hosts = new Map();
  const gate = sourceGate(src, () => {});

  const running = () => f.endsAt !== null;
  const isBreak = () => f.phase === 'short' || f.phase === 'long';
  const leftMs = () => (running() ? Math.max(0, f.endsAt - (Date.now() + skew)) : f.pausedLeft ?? (settings.focusMin * 60_000));

  // ---- countdown: text and ring, once a second while running and shown
  function drawTime() {
    const ms = leftMs();
    const s = Math.ceil(ms / 1000);
    const text = s >= 3600 ? `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}` : `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
    if (text !== lastText) { lastText = text; timeEl.textContent = text; }
    // The arc moves in 0.25 % steps (~6 px on the laptop): a 25 min round redraws it every ~4 s instead of every
    // second (each redraw of the 600 px arc cost ~0.8 % of a core on top of the text, measured on the laptop).
    const dash = f.total ? `${(Math.ceil((ms / f.total) * 400) / 4).toFixed(2)} 100` : '100 100';
    if (dash !== lastDash) { lastDash = dash; arc.style.strokeDasharray = dash; } // the CSS rule beats an attribute
  }
  function arm() {
    clearTimeout(tick); tick = 0;
    if (paused || !running()) return;
    drawTime();
    // Wake just after the next whole second of the remaining time.
    const ms = leftMs();
    if (ms <= 0) return;
    tick = setTimeout(arm, (ms % 1000 || 1000) + 15);
  }

  // ---- background: three soft blobs, repainted every 10 s (motion low: only on a phase change)
  function resize() {
    if (!cv) return;
    cv.width = Math.max(1, Math.round(innerWidth * 0.25));
    cv.height = Math.max(1, Math.round(innerHeight * 0.25));
  }
  function paintBg() {
    if (!g) return;
    const w = cv.width, h = cv.height, t = Date.now() / 1000;
    g.fillStyle = '#000'; g.fillRect(0, 0, w, h);
    const spots = [
      [0.5 + 0.06 * Math.sin(t / 47), 0.45 + 0.05 * Math.cos(t / 59), 0.55],
      [0.08 + 0.04 * Math.cos(t / 71), 0.85 + 0.04 * Math.sin(t / 53), 0.45],
      [0.92 + 0.04 * Math.sin(t / 67), 0.12 + 0.05 * Math.cos(t / 61), 0.42],
    ];
    const tone = BLOBS[isBreak() ? 'break' : 'focus'];
    const dim = f.phase === 'idle' || !running() ? 0.6 : 1;
    spots.forEach(([x, y, r], i) => {
      const [cr, cg, cb, a] = tone[i];
      const grd = g.createRadialGradient(x * w, y * h, 0, x * w, y * h, r * h);
      grd.addColorStop(0, `rgba(${cr},${cg},${cb},${a * dim})`); grd.addColorStop(1, `rgba(${cr},${cg},${cb},0)`);
      g.fillStyle = grd; g.fillRect(0, 0, w, h);
    });
  }
  function armBg() {
    clearInterval(bgTimer); bgTimer = 0;
    if (paused) return;
    paintBg();
    if (settings.motion !== 'low') bgTimer = setInterval(paintBg, BG_MS);
  }
  const onResize = () => { resize(); paintBg(); };
  resize();
  addEventListener('resize', onResize);

  // ---- sound
  function soundOn() {
    sound.setAmbient({ kind: settings.ambient, volume: settings.ambientVolume, on: !paused && f.phase === 'focus' && running() && !music });
  }

  // ---- static parts (on a message)
  function draw() {
    const phase = f.phase;
    stage.dataset.phase = isBreak() ? 'break' : phase;
    stage.classList.toggle('f-paused', phase !== 'idle' && !running());
    phaseEl.textContent = phase !== 'idle' && !running() ? `${LABEL[phase]} · DURAKLATILDI` : LABEL[phase];
    const min = Math.round((f.total ?? settings.focusMin * 60_000) / 60_000);
    subEl.textContent = phase === 'idle' ? 'Telefondan başlat' : isBreak() ? `${min} dakikalık mola` : `${min} dakikalık tur`;
    if (modeEl) modeEl.textContent = isBreak() ? 'ODAK MODU · MOLA' : 'ODAK MODU';
    const every = Math.max(2, f.longEvery || 4);
    const pos = f.round ? ((f.round - 1) % every) + 1 : 0;
    if (round) round.textContent = f.round ? `${f.round}. tur · ${every} turda uzun mola` : `${every} turda bir uzun mola`;
    if (dots.childElementCount !== every) dots.innerHTML = '<i></i>'.repeat(every);
    [...dots.children].forEach((d, i) => {
      const n = i + 1;
      d.className = n < pos || (n === pos && isBreak()) ? 'done' : n === pos ? 'cur' : '';
    });
    brk.hidden = !isBreak();
    brkSub.textContent = f.phase === 'long' ? 'Biraz yürü, pencereden dışarı bak; uzun mola.' : 'Omuzlarını gevşet, gözlerini 20 saniye uzağa çevir.';
    next.hidden = !f.task;
    next.lastElementChild.textContent = f.task ?? '';
    lastText = ''; lastDash = '';
    drawTime();
    arm();
    soundOn();
  }

  function onFocus(m, first) {
    const was = f.phase;
    f = { ...f, ...m };
    if (typeof m.now === 'number') skew = m.now - Date.now();
    draw();
    if (was !== f.phase) armBg();
    if (!first && m.cause === 'timer') {
      if (settings.chime && !paused) sound.chime(settings.ambientVolume);
      const toBreak = isBreak();
      ctx.pill({ icon: toBreak ? 'droplet' : 'hourglass', tone: toBreak ? 'warning' : 'accent', always: true,
        html: toBreak ? `<b>${f.phase === 'long' ? 'Uzun mola' : 'Mola'} zamanı</b><span class="sub">${f.round}. tur bitti</span>` : `<b>Odak zamanı</b><span class="sub">${f.round}. tur başladı</span>` });
    }
  }

  // ---- critical pills
  function onClaude(m) {
    for (const s of m.sessions ?? []) {
      if (s.status === 'waiting' && !claudeWaiting.has(s.id)) ctx.pill(eventCopy({ kind: 'claudeWaiting', detail: s.name }));
    }
    claudeWaiting.clear();
    for (const s of m.sessions ?? []) if (s.status === 'waiting') claudeWaiting.add(s.id);
  }
  function onServers(m) {
    if (!m.available) return;
    for (const h of m.hosts ?? []) {
      if (!servers && hosts.get(h.name) === true && !h.up) ctx.pill(eventCopy({ kind: 'serverDown', detail: h.name }));
      hosts.set(h.name, h.up);
    }
  }

  let gotFocus = false;
  draw();
  armBg();
  return {
    update(m) {
      if (m.type === 'focus') { onFocus(m, !gotFocus); gotFocus = true; return; }
      if (m.type === 'settings') {
        const before = JSON.stringify(settings);
        for (const k of Object.keys(settings)) if (m[k] !== undefined) settings[k] = m[k];
        if (JSON.stringify(settings) !== before) { draw(); armBg(); }
        return;
      }
      if (m.type === 'music') { music = m.playing === true && !m.none; soundOn(); return; }
      if (!gate.mine(m)) return;
      if (m.type === 'claude') onClaude(m);
      else if (m.type === 'servers') onServers(m);
    },
    pause() { paused = true; arm(); armBg(); soundOn(); },
    resume() { paused = false; draw(); armBg(); },
    destroy() {
      paused = true;
      clearTimeout(tick); clearInterval(bgTimer);
      removeEventListener('resize', onResize);
      sound.setAmbient({ on: false });
      delete stage.dataset.phase;
      root.remove();
    },
  };
}
