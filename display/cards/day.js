// Day card (PLAN.md §20 E-2/E-3): the date and the clock, nothing else (weather was dropped from the plan). Redrawn
// once a minute (no seconds shown, so the page is never woken every second); paused while the screen isn't visible.
// mount(el, ctx, {size}) → { update(msg), pause(), resume(), destroy() }; size "big" = the Focus layout's centre clock,
// "compact" = the Work layout's side card (clock with the date under it).
import { fmtClock, fmtOverline } from '../format.js';
import { everyMinute } from '../sched.js';

export function mount(el, ctx, { size = 'normal' } = {}) {
  const card = document.createElement('article');
  card.className = `card day-card${size === 'normal' ? '' : ` ${size}`}`;
  card.setAttribute('aria-label', 'Gün');
  card.innerHTML = '<div class="overline day-date"></div><div class="day-clock"><span class="day-time"></span><span class="day-suffix"></span></div>';
  el.append(card);
  const date = card.querySelector('.day-date'), time = card.querySelector('.day-time'), suffix = card.querySelector('.day-suffix');
  let clock24 = true;

  function draw(now = new Date()) {
    const c = fmtClock(now, clock24);
    date.textContent = fmtOverline(now);
    time.textContent = c.time;
    suffix.textContent = c.suffix;
  }
  const minute = everyMinute(draw);

  return {
    update(m) {
      if (m.type === 'settings' && typeof m.clock24 === 'boolean' && m.clock24 !== clock24) { clock24 = m.clock24; draw(); }
    },
    pause() { minute.pause(); },
    resume() { minute.resume(); },
    destroy() { minute.stop(); card.remove(); },
  };
}
