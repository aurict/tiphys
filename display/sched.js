// Frame scheduler of the kiosk shell (PLAN.md §20 "Kaynak tüketimi"; from the W0 draft, display/draft/sched.js):
// nothing is drawn unless something changed.
//  - invalidate(): one frame soon (data arrived, layout changed).
//  - animate(ms): an effect runs for `ms`; frames at ≤ fps until it ends, then `tailMs` more, then stop.
//  - setBreath(on, ms?): while nothing else runs, one frame per `ms` (default 1 s); off = fully idle.
//  - setFps(n): the effect frame rate (30; 60 only with motion "high").
//  - pause()/resume(): the agent says the screen isn't visible → no frames and no timers at all.
// Every frame calls draw(now, dt). Between frames there is no requestAnimationFrame pending, only one timer.
// Cards that draw continuously (the Game mode scenes) keep their own loop and stop it in their pause().
export function createScheduler(draw, { fps = 30, tailMs = 2000, breathMs = 1000 } = {}) {
  let minGap = 1000 / fps - 1;
  let activeUntil = 0, breath = false, paused = false, wantFrame = false;
  let raf = 0, timer = 0, last = 0;
  const stats = { frames: 0 };

  function frame(now) {
    raf = 0;
    if (paused) return;
    const dt = last ? Math.min(100, now - last) : 16;
    last = now;
    wantFrame = false;
    stats.frames++;
    draw(now, dt);
    plan();
  }

  function at(ms) { // next frame after `ms`, via one timer then rAF (vsync-aligned)
    clearTimeout(timer);
    timer = setTimeout(() => { timer = 0; if (!raf) raf = requestAnimationFrame(frame); }, Math.max(0, ms));
  }

  function plan() {
    if (paused || raf) return;
    const now = performance.now();
    const sinceLast = now - last;
    if (wantFrame || now < activeUntil + tailMs) return at(minGap - sinceLast);
    if (breath) return at(breathMs - sinceLast);
    clearTimeout(timer); timer = 0; // idle: nothing scheduled
  }

  return {
    stats,
    invalidate() { wantFrame = true; plan(); },
    animate(ms) { activeUntil = Math.max(activeUntil, performance.now() + ms); wantFrame = true; plan(); },
    busy: () => performance.now() < activeUntil,
    setBreath(on, ms = 1000) { breath = on; breathMs = ms; plan(); },
    setFps(n) { minGap = 1000 / n - 1; },
    get paused() { return paused; },
    pause() { paused = true; clearTimeout(timer); timer = 0; if (raf) cancelAnimationFrame(raf); raf = 0; },
    resume() { if (!paused) return; paused = false; last = 0; wantFrame = true; plan(); },
  };
}

/**
 * Calls fn(now) at once and then at the start of every minute (one timer; a clock without seconds never wakes the page
 * every second). Returns {pause, resume, stop}; resume calls fn at once (the minute may have changed meanwhile).
 */
export function everyMinute(fn) {
  let t = 0;
  const tick = () => { fn(new Date()); t = setTimeout(tick, 60000 - (Date.now() % 60000) + 50); };
  const stop = () => { clearTimeout(t); t = 0; };
  tick();
  return { pause: stop, resume() { if (!t) tick(); }, stop };
}
