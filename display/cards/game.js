// Game mode card (PLAN.md §19 scenes inside the §20 shell): the Drive / Music / Idle scenes as one full-screen card,
// because they share the scene decision and the cover's shared-element move. The behaviour is the §19 page's: this
// is its former main.js with the socket, Esc-hold, pill and problem card moved to the shell (main.js).
// Card interface: mount(root, ctx) → { update(msg), pause(), resume(), destroy() }. Messages: settings, source
// (aggregated state of this layout's sources), link {up}, music, lyrics, truck, event, spectrum {bytes}.
import { createAmbient } from '../ambient.js';
import { createMap } from '../map.js';
import { createMusic } from '../music.js';
import { createCockpit } from '../cockpit.js';
import { eventCopy } from '../notify.js';
import { palette, imagePixels, accentTone } from '../color.js';
import { fmtClock, fmtOverline, fmtGameTime, gameHour } from '../format.js';
import { icon } from '../icons.js';

const DEFAULTS = { scene: 'auto', lyrics: true, spectrum: true, motion: 'normal', brightness: null, clock24: true, dimIdleMinutes: 10 };
const escapeHtml = (s) => String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

export function mount(root, ctx) {
  root.append(document.getElementById('tpl-game').content.cloneNode(true));
  const $ = (s) => root.querySelector(s);
  const dimEl = document.getElementById('dim');

  let settings = { ...DEFAULTS };
  let truck = null;
  let ready = false;          // first state arrived (or gave up waiting)
  let paused = false, destroyed = false;
  const timers = [];
  document.body.dataset.scene = 'connecting';

  const ambient = createAmbient($('#ambient'));
  const map = createMap($('#map-card'));
  const cockpit = createCockpit();
  const music = createMusic({ onCoverLoaded: coverLoaded });

  function coverLoaded(img) {
    let pal = null;
    if (img) { try { pal = palette(imagePixels(img)); } catch { pal = null; } }
    ambient.setPalette(pal);
    const tone = pal ? accentTone(pal[0]) : [165, 180, 252];
    document.documentElement.style.setProperty('--tone-rgb', tone.map(Math.round).join(', '));
    map.setTone(tone);
    music.setTone(tone);
    if (!pal) ambient.setPalette(null);
  }

  // ---------------------------------------------------------------- settings
  function applySettings(s) {
    settings = { ...DEFAULTS, ...settings, ...s };
    document.body.dataset.motion = settings.motion;
    ambient.setMotion(settings.motion);
    map.setMotion(settings.motion);
    music.setSettings(settings);
    cockpit.setClock24(settings.clock24);
    tickClock();
    decideScene(true);
  }

  // ---------------------------------------------------------------- source state (chips; pill/problem: shell)
  function applySource(msg) {
    for (const chip of [$('#hdr-source'), $('#idle-source')]) {
      chip.dataset.state = msg.state;
      chip.querySelector('.lbl').textContent = msg.state === 'ok' ? 'Kaynak bağlı' : msg.state === 'down' ? 'Kaynak yok' : 'Bağlanıyor';
    }
  }

  // ---------------------------------------------------------------- scenes
  let scene = 'connecting';
  let candidate = null, candidateSince = 0;
  let idleSince = 0;

  function wantedScene() {
    if (!ready) return 'connecting';
    const pausedRecently = music.hasMusic && !music.playing && music.pausedAt && Date.now() - music.pausedAt < 120_000;
    const musicOn = music.playing || pausedRecently;
    if (settings.scene === 'drive') return 'drive';
    if (settings.scene === 'music') return music.hasMusic ? 'music' : 'idle';
    if (truck?.state === 'driving') return 'drive';
    if (musicOn) return 'music';
    return 'idle';
  }

  function decideScene(immediate = false) {
    const want = wantedScene();
    if (want === scene) { candidate = null; return; }
    const now = performance.now();
    // Debounce automatic switches (a short pause in-game shouldn't flip the screen); first decision is immediate.
    if (!immediate && scene !== 'connecting') {
      if (candidate !== want) { candidate = want; candidateSince = now; return; }
      if (now - candidateSince < 1800) return;
    }
    candidate = null;
    switchScene(want);
  }

  function switchScene(next) {
    const prev = scene;
    const fromCover = prev === 'drive' ? $('#np-cover') : prev === 'music' ? $('#mu-cover') : null;
    const toCover = next === 'drive' ? $('#np-cover') : next === 'music' ? $('#mu-cover') : null;
    const first = fromCover && toCover && music.hasMusic && settings.motion !== 'low' ? fromCover.getBoundingClientRect() : null;
    scene = next;
    document.body.dataset.scene = next;
    if (next === 'idle') idleSince = Date.now();
    updateHeader();
    if (first) flipCover(first, fromCover, toCover);
    requestAnimationFrame(() => music.refit());
  }

  /** FLIP shared-element move of the cover between the Drive card and the Music scene (600 ms, transform only). */
  function flipCover(first, fromEl, toEl) {
    // Measure the target without the scene's entry scale.
    const sceneEl = toEl.closest('.scene');
    sceneEl.style.transition = 'none'; sceneEl.style.transform = 'none';
    const last = toEl.getBoundingClientRect();
    sceneEl.style.transform = ''; void sceneEl.offsetWidth; sceneEl.style.transition = '';
    const fly = document.createElement('div');
    fly.className = 'cover-box fly' + (music.hasArt ? ' has-art' : '');
    const radius = getComputedStyle(toEl).borderRadius;
    Object.assign(fly.style, { position: 'fixed', left: `${last.left}px`, top: `${last.top}px`, width: `${last.width}px`, height: `${last.height}px`,
      zIndex: 30, borderRadius: radius, boxShadow: getComputedStyle(toEl).boxShadow, transformOrigin: '0 0' });
    fly.innerHTML = music.hasArt ? `<img alt="" src="${music.artUrl}" style="opacity:1">` : `<div class="cover-none" style="opacity:1">${icon('music', last.width > 300 ? 120 : 46)}</div>`;
    root.append(fly);
    fromEl.style.opacity = '0'; toEl.style.opacity = '0';
    const s = first.width / last.width;
    const anim = fly.animate([
      { transform: `translate(${first.left - last.left}px, ${first.top - last.top}px) scale(${s})` },
      { transform: 'none' },
    ], { duration: 600, easing: 'cubic-bezier(.2, .8, .2, 1)' });
    anim.onfinish = anim.oncancel = () => { toEl.style.opacity = ''; fromEl.style.opacity = ''; fly.remove(); };
  }

  // ---------------------------------------------------------------- header + clocks
  function updateHeader() {
    const title = $('#hdr-title');
    if (scene === 'drive') {
      const t = cockpit.title();
      if (t) title.innerHTML = `${escapeHtml(t.from)}<span class="arrow">→</span>${escapeHtml(t.to)}`;
      else title.textContent = truck && truck.state !== 'none' ? 'Serbest sürüş' : 'Sürüş';
    } else title.textContent = 'Oyun Modu';
    const game = $('#hdr-game');
    const showGame = scene === 'drive' && truck && truck.state !== 'none' && truck.gameTime != null;
    game.hidden = !showGame;
    if (showGame) game.innerHTML = `${icon('clock', 18)}<span>Oyun saati ${fmtGameTime(truck.gameTime, settings.clock24)}</span>`;
  }

  function tickClock() {
    const now = new Date();
    const c = fmtClock(now, settings.clock24);
    $('#hdr-clock').innerHTML = c.time + (c.suffix ? `<small>${c.suffix}</small>` : '');
    $('#hdr-date').textContent = fmtOverline(now);
    $('#idle-date').textContent = fmtOverline(now);
    $('#idle-time').textContent = c.time;
    $('#idle-suffix').textContent = c.suffix;
    updateDim();
  }

  function updateIdleChips() {
    const t = $('#idle-truck .lbl');
    const st = truck?.state ?? 'none';
    t.textContent = st === 'none' ? (truck?.reason === 'noPlugin' ? 'ETS2 · eklenti yok' : truck?.reason === 'unsupported' ? 'ETS2 · eklenti sürümü uyumsuz' : 'ETS2 kapalı') : st === 'menu' ? 'ETS2 menüde' : st === 'paused' ? 'ETS2 duraklatıldı' : 'ETS2 yolda';
    const m = $('#idle-music .lbl');
    m.textContent = music.hasMusic ? (music.playing ? music.title : `Duraklatıldı · ${music.title}`) : "Velour'da çalan bir şey yok";
  }

  /** Screen dimming: idle after dimIdleMinutes → 30 %; game night (21:00–06:00) → 20 % and a cooler background. */
  function updateDim() {
    let n = 0;
    if (truck && truck.state !== 'none' && truck.gameTime != null) {
      const h = gameHour(truck.gameTime);
      const ramp = (x) => Math.max(0, Math.min(1, x));
      n = h >= 20.5 ? ramp((h - 20.5) / 1) : h < 6.5 ? ramp((6.5 - h) / 1) : 0;
    }
    ambient.setNight(n);
    const idleDim = scene === 'idle' && settings.dimIdleMinutes > 0 && Date.now() - idleSince > settings.dimIdleMinutes * 60_000 ? 0.3 : 0;
    const v = Math.max(idleDim, n * 0.2);
    if (dimEl.style.opacity !== String(v)) dimEl.style.opacity = String(v);
  }

  // The agent sends layout (with settings), source, music, lyrics, truck right after connecting: pick the first scene
  // once they're in, so the page doesn't flash Music before the truck message arrives.
  let settleTimer = 0;
  function settle() {
    if (ready || settleTimer) return;
    settleTimer = setTimeout(() => { ready = true; decideScene(true); }, 250);
  }
  const readyTimer = setTimeout(() => { ready = true; decideScene(true); }, 2500);
  let headerAt = 0;
  function updateHeaderThrottled() { const n = performance.now(); if (n - headerAt > 1000) { headerAt = n; updateHeader(); updateDim(); } }

  function update(m) {
    switch (m.type) {
      case 'settings': { const { type, ...s } = m; void type; applySettings(s); break; }
      case 'source': applySource(m); if (m.state === 'down') settle(); break;
      case 'link': if (!m.up) { clearTimeout(readyTimer); ready = true; decideScene(true); } break;
      case 'music': music.setMusic(m); updateIdleChips(); settle(); decideScene(); break;
      case 'lyrics': music.setLyrics(m); break;
      case 'spectrum': music.setSpectrumFrame(m.bytes); break;
      case 'truck': {
        const prevState = truck?.state;
        truck = m;
        cockpit.setTruck(m);
        map.update(m);
        map.setDestination(m.job?.to ?? null);
        settle();
        if (prevState !== m.state) { updateIdleChips(); decideScene(); }
        if (scene === 'drive') updateHeaderThrottled();
        break;
      }
      case 'event': ctx.pill(eventCopy(m, truck)); break;
      default: break;
    }
  }

  // ---------------------------------------------------------------- frame loop
  let lastT = performance.now();
  let raf = 0;
  const perfEl = document.getElementById('perf');
  const frames = [];
  let perfAt = 0;
  function loop(now) {
    raf = 0;
    if (paused || destroyed) return;
    const dt = Math.min(100, now - lastT);
    lastT = now;
    const bass = music.frame(now, scene);
    ambient.setBass(bass);
    ambient.frame(now);
    if (scene === 'drive') { map.frame(now); cockpit.frame(dt); }
    if (candidate) decideScene();
    if (ctx.debug) {
      frames.push(dt);
      if (now - perfAt > 1000) {
        perfAt = now;
        const s = frames.splice(0).sort((a, b) => a - b);
        const p95 = s[Math.floor(s.length * 0.95)] ?? 0;
        perfEl.hidden = false;
        perfEl.textContent = `${s.length} fps · p95 ${p95.toFixed(1)} ms · ${scene} · ${settings.motion}`;
      }
    }
    raf = requestAnimationFrame(loop);
  }

  function startTimers() {
    timers.push(setInterval(tickClock, 1000));
    // Re-evaluate the auto scene now and then (a paused song becomes "idle" after 2 minutes).
    timers.push(setInterval(() => { decideScene(); if (scene === 'idle') updateIdleChips(); }, 5000));
  }
  function stopTimers() { for (const t of timers.splice(0)) clearInterval(t); }

  document.fonts.ready.then(() => { if (!destroyed) music.refit(); });
  tickClock();
  startTimers();
  raf = requestAnimationFrame(loop);

  return {
    update,
    pause() {
      if (paused) return;
      paused = true;
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
      stopTimers();
    },
    resume() {
      if (!paused || destroyed) return;
      paused = false;
      lastT = performance.now();
      tickClock();
      decideScene();
      startTimers();
      raf = requestAnimationFrame(loop);
    },
    destroy() {
      destroyed = true;
      if (raf) cancelAnimationFrame(raf);
      stopTimers();
      clearTimeout(readyTimer); clearTimeout(settleTimer);
      map.destroy();
      ambient.destroy();
      delete document.body.dataset.scene;
      dimEl.style.opacity = '0';
      perfEl.hidden = true;
      document.documentElement.style.removeProperty('--tone-rgb');
    },
  };
}
