// Sleep mode view (PLAN.md §21 E, S1 draft). Shaped like a kiosk card (cards/*.js) so S2/S3 can mount it from the
// mode shell: mount(el, ctx, opts) → {update, pause, resume, destroy}.
//   opts: {session {seed, t0, members}, plan (timeline.js), me (member id), now() (shared clock, ms),
//          brightness 0..1, audio (bool), volume 0..100, layers, onStop(), onAlarm(action)}
// Frames (its own loop, like the Game scenes: one timer then one rAF, nothing pending between frames): settle 30 fps →
// fade 20 fps at 1/3 resolution; night 1/6 resolution at 5 fps while a flare glows, 2 fps when nothing happens;
// sunrise 10 fps, ring 15; morning: no canvas at all (a DOM clock once a minute). A frame is also placed on the next
// event's time, so a crackle's pop is drawn with its sound, not up to a frame interval later. Timers are measured from
// the frame's start (performance.now()), not from the rAF timestamp: that one is the vsync that may be most of a frame
// earlier, and sched.js's breath measured from it ran this loop at ~41 fps instead of 30 (measured headless).
// Keys (cursor hidden): any key/mouse → a dim clock and "Uyku modu açık · Esc basılı tut: kapat" for 5 s; in ring:
// Space = ertele, Esc held 1 s = kapat → morning; at other times Esc held 1 s = stop (the agent will do it; here UI).
import { everyMinute } from '../sched.js';
import { createTimeline } from './timeline.js';
import { createEmbers } from './embers.js';
import { createAudio } from './audio.js';

const FPS = { settle: 30, fade: 20, night: 5, sunrise: 10, ring: 15 };
const SCALE = { settle: 1 / 3, fade: 1 / 3, night: 1 / 6, sunrise: 1 / 3, ring: 1 / 3 };
const NIGHT_IDLE_MS = 500;
const HINT_MS = 5000, HOLD_MS = 1000;

const pad = (n) => String(n).padStart(2, '0');
const clock = (d) => `${pad(d.getHours())}:${pad(d.getMinutes())}`;
const dateLine = (d) => d.toLocaleDateString('tr-TR', { weekday: 'long', day: 'numeric', month: 'long' });

export function mount(el, ctx, opts) {
  const { session, plan, me, now } = opts;
  const tl = createTimeline(session, plan, me);
  const root = document.createElement('div');
  root.className = 'sleep';
  root.innerHTML = `
    <canvas class="sl-embers" aria-hidden="true"></canvas>
    <div class="sl-hint" role="status" aria-live="polite" hidden>
      <div class="sl-clock"></div>
      <div class="sl-msg"></div>
    </div>
    <section class="sl-morning" hidden aria-label="Sabah">
      <div class="sl-m-date"></div>
      <div class="sl-m-clock" role="timer"></div>
      <ul class="sl-m-sum" aria-label="Sabah özeti">
        <li><span>Uyku</span><b class="sl-m-dur"></b></li>
        <li><span>Gece biten işler</span><b>2 iş · ikisi başarılı</b></li>
        <li><span>Yedekler</span><b>Başarılı</b></li>
        <li><span>Bekletilen bildirimler</span><b>3</b></li>
      </ul>
      <p class="sl-m-note">Taslak: özet örnek verilerle.</p>
    </section>`;
  el.append(root);
  const $ = (s) => root.querySelector(s);
  const canvas = $('.sl-embers'), hint = $('.sl-hint'), hintClock = $('.sl-clock'), hintMsg = $('.sl-msg');
  const morning = $('.sl-morning');

  const embers = createEmbers(canvas, tl);
  embers.setBrightness(opts.brightness ?? 1);
  const audio = opts.audio === false ? null : createAudio(tl, { now, offsetMs: opts.offsetMs, volume: opts.volume ?? 35, layers: opts.layers });
  audio?.start();

  let phase = null, morningOn = false, minute = null, paused = false;
  let snoozed = false;
  const stats = { frames: 0, phase: null };

  let timer = 0, raf = 0;
  /** The next frame `ms` from now: a timer a little early, then the vsync after it. */
  function arm(ms, early = 2) {
    clearTimeout(timer);
    timer = setTimeout(() => { timer = 0; if (!raf) raf = requestAnimationFrame(frame); }, Math.max(0, ms - early));
  }
  function stop() { clearTimeout(timer); timer = 0; if (raf) cancelAnimationFrame(raf); raf = 0; }
  function frame() {
    raf = 0;
    if (paused) return;
    const start = performance.now();
    const T = now();
    const L = tl.levels(T);
    if (L.phase !== phase) enterPhase(L.phase);
    if (morningOn) return;
    const s = embers.draw(T);
    stats.frames++;
    // Next frame: the phase rate; in the night slower when nothing glows; never later than the next event.
    let gap = 1000 / (FPS[phase] ?? 10);
    if (phase === 'night' && !s.fl.length && !s.sp.length) gap = NIGHT_IDLE_MS;
    const next = tl.next(T, gap);
    const spent = performance.now() - start;
    if (next != null && next - T < gap - 12) arm(next - T - spent);
    else arm(gap - spent);
  }
  function enterPhase(p) {
    phase = p; stats.phase = p;
    root.dataset.phase = p;
    embers.setScale(SCALE[p] ?? 1 / 3);
    audio?.tick();
  }

  // ---- interaction
  let hintTimer = 0, holdTimer = 0;
  function showHint(msg) {
    hintClock.textContent = clock(new Date(now()));
    hintMsg.textContent = msg ?? (phase === 'ring'
      ? (snoozed ? 'Ertelendi · 9 dk sonra yeniden' : 'Günaydın · Boşluk: ertele · Esc basılı tut: kapat')
      : 'Uyku modu açık · Esc basılı tut: kapat');
    hint.hidden = false;
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => { hint.hidden = true; }, HINT_MS);
  }
  function showMorning() {
    morningOn = true;
    stop();
    audio?.destroy();
    canvas.hidden = true; hint.hidden = true;
    morning.hidden = false;
    root.dataset.phase = 'morning';
    const slept = Math.max(0, now() - plan.t0) / 60000;
    $('.sl-m-dur').textContent = `${Math.floor(slept / 60)} sa ${Math.round(slept % 60)} dk`;
    minute = everyMinute((d) => { $('.sl-m-clock').textContent = clock(d); $('.sl-m-date').textContent = dateLine(d); });
  }
  function onKey(e) {
    if (morningOn) return;
    audio?.unlock();
    if (e.key === 'Escape') {
      e.preventDefault();
      if (e.repeat || holdTimer) return;
      showHint(phase === 'ring' ? 'Alarmı kapatmak için basılı tut…' : 'Kapatmak için basılı tut…');
      holdTimer = setTimeout(() => {
        holdTimer = 0;
        if (phase === 'ring') { opts.onAlarm?.('dismiss'); showMorning(); }
        else { showHint('Uyku modu kapatılıyor…'); opts.onStop?.(); }
      }, HOLD_MS);
      return;
    }
    if (e.key === ' ' && phase === 'ring') { e.preventDefault(); snoozed = true; opts.onAlarm?.('snooze'); showHint(); return; }
    showHint();
  }
  function onKeyUp(e) { if (e.key === 'Escape' && holdTimer) { clearTimeout(holdTimer); holdTimer = 0; showHint(); } }
  let lastMove = 0;
  function onMouse() { const t = performance.now(); if (t - lastMove > 1000) { lastMove = t; audio?.unlock(); if (!morningOn) showHint(); } }
  addEventListener('keydown', onKey);
  addEventListener('keyup', onKeyUp);
  addEventListener('pointerdown', onMouse);
  addEventListener('mousemove', onMouse);

  if (opts.morning) showMorning(); else raf = requestAnimationFrame(frame);

  return {
    stats, timeline: tl, audio,
    /** Agent messages (S2): a phase or plan change. The draft has none. */
    update() {},
    pause() { if (paused) return; paused = true; stop(); audio?.pause(); minute?.pause(); },
    resume() { if (!paused) return; paused = false; if (!morningOn) raf = requestAnimationFrame(frame); audio?.resume(); minute?.resume(); },
    destroy() {
      paused = true; stop(); audio?.destroy(); minute?.stop(); embers.destroy();
      clearTimeout(hintTimer); clearTimeout(holdTimer);
      removeEventListener('keydown', onKey); removeEventListener('keyup', onKeyUp);
      removeEventListener('pointerdown', onMouse); removeEventListener('mousemove', onMouse);
      root.remove();
    },
  };
}
