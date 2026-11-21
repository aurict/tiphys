// Sleep mode view (PLAN.md §21 E; S1 draft, S4 alarm). Shaped like a kiosk card (cards/*.js); the mode shell's card
// (cards/sleep.js) mounts it: mount(el, ctx, opts) → {update, setPlan(plan), setAlarm(gain), setMusic(on),
//   setMorning(summary), setBrightness(b), pause, resume, destroy}.
//   opts: {session {seed, t0, members}, plan (timeline.js), me (member id), now() (shared clock, ms),
//          brightness 0..1, audio (bool), volume 0..100, layers, alarmGain 0..1, music (bool), morningSummary,
//          onStop(), onAlarm(action),
//          trace(line) (test only: ['v', id, eventT, wall] for the first frame that draws a crackle, and audio.js's
//          ['a', …] lines)}
// The phases come from the plan alone (the agent's plan, with its snoozes and dismiss): sunrise light rising, ring
// (light at its peak, breathing; bird chirps each with a light mote), snoozed (bright and quiet, "Ertelendi · yeniden HH:MM"),
// morning (warm screen, clock and date, the night's length t0 → dismiss and the agent's morning summary: morning.js).
// S5: `music` (the leader's Velour sleep playlist plays) ducks the ember sounds −12 dB (audio.js setDuck).
// Content brightness (the agent's half of the dimming, 0..1): the shader's `bright`, eased linearly over 2 s to each new
// value inside the frames the phase draws anyway; the text (hint, snooze line, morning) gets it as a plain opacity.
// Not a CSS transition on a layer over the canvas: S7 measured that one recomposited the full screen at the display's
// refresh rate for the whole fade (it gets a new value every 2 s), ~57 % of a laptop core instead of the canvas' 20 fps.
// Frames (its own loop, like the Game scenes: one timer then one rAF, nothing pending between frames): settle 30 fps →
// fade 20 fps at 1/3 resolution; night 1/6 resolution at 2 fps while a flare glows, 1 fps when nothing happens (S7:
// the clusters breathe at 0.05 Hz; each frame also costs Firefox's compositor and the Wayland round trip, which
// dominated the night once the sound was off); content brightness 0: no frames at all until it rises;
// sunrise 10 fps, ring 15; morning: no canvas at all (a DOM clock once a minute). A frame is also placed on the next
// event's time, so a crackle's pop is drawn with its sound, not up to a frame interval later. Timers are measured from
// the frame's start (performance.now()), not from the rAF timestamp: that one is the vsync that may be most of a frame
// earlier, and sched.js's breath measured from it ran this loop at ~41 fps instead of 30 (measured headless).
// Keys (cursor hidden; the agent focuses the kiosk window when the page connects): any key/mouse → a dim clock and
// "Uyku modu açık · Esc basılı tut: kapat" for 5 s; in ring: Space = snooze; in ring or snoozed: Esc held 1 s =
// dismiss (the agent answers with the new plan: morning, or the mode ends); at other times Esc held 1 s = stop.
import { everyMinute } from '../sched.js';
import { createTimeline } from './timeline.js';
import { createEmbers } from './embers.js';
import { createAudio } from './audio.js';
import { morningView } from './morning.js';

const FPS = { settle: 30, fade: 20, night: 2, sunrise: 10, ring: 15, snoozed: 10 };
const SCALE = { settle: 1 / 3, fade: 1 / 3, night: 1 / 6, sunrise: 1 / 3, ring: 1 / 3, snoozed: 1 / 3 };
const NIGHT_IDLE_MS = 1000;
const DARK_MS = 1000; // content brightness 0: look again this often (one black frame was drawn)
const BRIGHT_MS = 2000;
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
    <div class="sl-snooze" role="status" aria-live="polite" hidden></div>
    <section class="sl-morning" hidden aria-label="Sabah">
      <div class="sl-m-date"></div>
      <div class="sl-m-clock" role="timer"></div>
      <ul class="sl-m-sum" aria-label="Sabah özeti"></ul>
      <ul class="sl-m-titles" aria-label="Bekleyen bildirimler" hidden></ul>
      <p class="sl-m-note"></p>
    </section>`;
  el.append(root);
  const $ = (s) => root.querySelector(s);
  const canvas = $('.sl-embers'), hint = $('.sl-hint'), hintClock = $('.sl-clock'), hintMsg = $('.sl-msg');
  const morning = $('.sl-morning'), snoozeLine = $('.sl-snooze');

  const embers = createEmbers(canvas, tl);
  // Content brightness: from `bFrom` at `bAt` (performance.now) linearly to `bTo` over BRIGHT_MS.
  let bFrom = opts.brightness ?? 1, bTo = bFrom, bAt = 0, dark = false;
  const brightAt = (t) => bFrom + (bTo - bFrom) * Math.min(1, Math.max(0, (t - bAt) / BRIGHT_MS));
  const dimText = (b) => { for (const e of [hint, snoozeLine, morning]) e.style.opacity = String(b); };
  embers.setBrightness(bTo);
  dimText(bTo);
  const audio = opts.audio === false ? null : createAudio(tl, { now, offsetMs: opts.offsetMs, volume: opts.volume ?? 35, layers: opts.layers, trace: opts.trace, alarmGain: opts.alarmGain ?? 1, duck: opts.music === true });
  audio?.start();

  let phase = null, morningOn = false, minute = null, paused = false;
  let summary = opts.morningSummary ?? null;
  const stats = { frames: 0, phase: null };
  let lastT = null; // trace: the shared time up to which crackles were reported

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
    const b = brightAt(start);
    // Fully dark content (a night light of 0): one black frame, then nothing to draw until the brightness rises.
    if (b === 0 && bTo === 0 && dark) return arm(DARK_MS - (performance.now() - start));
    dark = b === 0 && bTo === 0;
    embers.setBrightness(b);
    const s = embers.draw(T);
    stats.frames++;
    if (opts.trace) {
      // Test only: when (this host's wall clock) each crackle first reached the screen.
      if (lastT != null) for (const ev of tl.between(lastT, T + 0.001)) if (ev.kind === 'crackle') opts.trace(['v', ev.id, ev.t, Date.now()]);
      lastT = T + 0.001;
    }
    // Next frame: the phase rate; in the night slower when nothing glows; never later than the next event.
    let gap = 1000 / (FPS[phase] ?? 10);
    if (phase === 'night' && !s.fl.length && !s.sp.length) gap = NIGHT_IDLE_MS;
    const next = tl.next(T, gap);
    const spent = performance.now() - start;
    if (next != null && next - T < gap - 12) arm(next - T - spent);
    else arm(gap - spent);
  }
  function enterPhase(p) {
    const was = phase;
    phase = p; stats.phase = p;
    root.dataset.phase = p;
    if (p === 'morning') return showMorning();
    embers.setScale(SCALE[p] ?? 1 / 3);
    audio?.tick();
    // Snoozed: one quiet line until it rings again.
    const sp = tl.phase(now());
    snoozeLine.hidden = p !== 'snoozed';
    if (p === 'snoozed') snoozeLine.textContent = `Ertelendi · yeniden ${clock(new Date(sp.end - (opts.offsetMs?.() ?? 0)))}`;
    if (p === 'ring' && was !== null && was !== 'ring') showHint();
  }

  // ---- interaction
  let hintTimer = 0, holdTimer = 0;
  function showHint(msg) {
    hintClock.textContent = clock(new Date(now()));
    hintMsg.textContent = msg ?? (phase === 'ring'
      ? 'Günaydın · Boşluk: ertele · Esc basılı tut: kapat'
      : phase === 'snoozed' ? 'Esc basılı tut: alarmı kapat' : 'Uyku modu açık · Esc basılı tut: kapat');
    hint.hidden = false;
    clearTimeout(hintTimer);
    hintTimer = setTimeout(() => { hint.hidden = true; }, HINT_MS);
  }
  function showMorning() {
    morningOn = true;
    stop();
    audio?.destroy();
    canvas.hidden = true; hint.hidden = true; snoozeLine.hidden = true;
    morning.hidden = false;
    root.dataset.phase = 'morning';
    drawMorning();
    minute = everyMinute((d) => { $('.sl-m-clock').textContent = clock(d); $('.sl-m-date').textContent = dateLine(d); });
  }
  /** The summary rows (the agent's summary, else the night's length from the plan) and up to three held titles. */
  function drawMorning() {
    const v = morningView(summary, tl.plan ?? plan, now());
    const list = $('.sl-m-sum'), titles = $('.sl-m-titles'), note = $('.sl-m-note');
    list.replaceChildren(...v.rows.map((r) => {
      const li = document.createElement('li');
      const a = document.createElement('span'); a.textContent = r.label;
      const b = document.createElement('b'); b.textContent = r.value;
      if (r.warn) li.classList.add('warn');
      li.append(a, b);
      return li;
    }));
    titles.replaceChildren(...v.titles.map((t) => { const li = document.createElement('li'); li.textContent = t; return li; }));
    titles.hidden = !v.titles.length;
    note.textContent = v.note ?? '';
    note.hidden = !v.note;
  }
  function onKey(e) {
    if (morningOn) return;
    audio?.unlock();
    const alarming = phase === 'ring' || phase === 'snoozed';
    if (e.key === 'Escape') {
      e.preventDefault();
      if (e.repeat || holdTimer) return;
      showHint(alarming ? 'Alarmı kapatmak için basılı tut…' : 'Kapatmak için basılı tut…');
      holdTimer = setTimeout(() => {
        holdTimer = 0;
        // The agent answers with the new plan (morning) or ends the mode.
        if (alarming) { showHint('Alarm kapatıldı'); opts.onAlarm?.('dismiss'); }
        else { showHint('Uyku modu kapatılıyor…'); opts.onStop?.(); }
      }, HOLD_MS);
      return;
    }
    if (e.key === ' ' && phase === 'ring') { e.preventDefault(); if (!e.repeat) opts.onAlarm?.('snooze'); return; }
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
    /** Agent `phase` messages: the plan already says it; a frame now picks it up. */
    update() { if (!paused && !morningOn && !raf) { stop(); raf = requestAnimationFrame(frame); } },
    /** A new plan (snooze, dismiss, the leader's): events and levels from now on follow it. */
    setPlan(next) {
      tl.setPlan(next, now());
      audio?.replan();
      phase = null; // re-enter (the snooze line, the morning)
      if (!paused && !morningOn) { stop(); raf = requestAnimationFrame(frame); }
    },
    setAlarm(gain) { audio?.setAlarmGain(gain); },
    /** The agent's content brightness (0..1): eased in over 2 s by the frames already drawn; the text at once. */
    setBrightness(b) {
      if (typeof b !== 'number' || !Number.isFinite(b)) return;
      const v = Math.max(0, Math.min(1, b));
      if (v === bTo) return;
      const t = performance.now();
      bFrom = brightAt(t); bTo = v; bAt = t;
      dimText(v);
    },
    setMusic(on) { audio?.setDuck(on === true); },
    setMorning(s) {
      const next = s ?? null;
      if (JSON.stringify(next) === JSON.stringify(summary)) return;
      summary = next;
      if (morningOn) drawMorning();
    },
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
