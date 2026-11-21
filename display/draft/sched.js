// Frame scheduler: nothing is drawn unless something changed (PLAN §20 "Kaynak tüketimi").
//  - invalidate(): one frame soon (data arrived, layout changed).
//  - animate(ms): an effect runs for `ms`; frames at ≤ 30 fps until it ends, then 2 s more (tails settle), then stop.
//  - setBreath(on): while nothing else runs, one frame per second (slow pulses); off = fully idle.
//  - pause()/resume(): page hidden or the agent says the screen isn't visible → no frames at all.
// Every frame calls draw(now, dt). Between frames there is no requestAnimationFrame pending, only one timer.
export function createScheduler(draw, { fps = 30, tailMs = 2000, breathMs = 1000 } = {}) {
  const minGap = 1000 / fps - 1;
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

  document.addEventListener('visibilitychange', () => (document.hidden ? api.pause() : api.resume()));

  const api = {
    stats,
    invalidate() { wantFrame = true; plan(); },
    animate(ms) { activeUntil = Math.max(activeUntil, performance.now() + ms); wantFrame = true; plan(); },
    /** True while an effect (not the tail) is running — callers use it to decide whether to keep easing. */
    busy: () => performance.now() < activeUntil,
    setBreath(on) { breath = on; plan(); },
    pause() { paused = true; clearTimeout(timer); timer = 0; if (raf) cancelAnimationFrame(raf); raf = 0; },
    resume() { if (!paused) return; paused = false; last = 0; wantFrame = true; plan(); },
  };
  return api;
}

/** Calls fn now and then at the start of every minute (one timer; the clock never wakes the page every second). */
export function everyMinute(fn) {
  const tick = () => { fn(new Date()); setTimeout(tick, 60000 - (Date.now() % 60000) + 50); };
  tick();
}

/** setInterval that stops while the page is hidden. */
export function every(ms, fn) {
  let id = 0;
  const start = () => { if (!id) id = setInterval(fn, ms); };
  const stop = () => { clearInterval(id); id = 0; };
  document.addEventListener('visibilitychange', () => (document.hidden ? stop() : start()));
  if (!document.hidden) start();
  return stop;
}
