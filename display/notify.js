// Notification pill (one at a time, queued), the problem card (source down / page connection lost) and Esc-hold to stop.
import { icon } from './icons.js';
import { fmtMoney, fmtInt } from './format.js';

const dur = (sec) => (sec == null ? null : sec < 60 ? `${sec} sn` : sec < 3600 ? `${Math.floor(sec / 60)} dk` : `${Math.floor(sec / 3600)} sa ${Math.floor((sec % 3600) / 60)} dk`);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);

/** Turkish copy for an `event` message (or a local one) → {icon, tone, html}; null for unknown kinds. */
export function eventCopy(ev, truck) {
  const money = ev.amount != null ? fmtMoney(ev.amount, ev.currency) : null;
  const sub = (t) => (t ? `<span class="sub">${esc(t)}</span>` : '');
  switch (ev.kind) {
    case 'fine': return { icon: 'fine', tone: 'danger', html: `<b>Ceza${money ? ' ' + money : ''}</b>${sub(ev.detail)}` };
    case 'ferry': return { icon: 'ferry', tone: 'accent', html: `<b>Feribot</b>${sub(ev.detail ?? 'Yolculuk başladı')}` };
    case 'train': return { icon: 'train', tone: 'accent', html: `<b>Tren</b>${sub(ev.detail ?? 'Yolculuk başladı')}` };
    case 'toll': return { icon: 'toll', tone: 'accent', html: `<b>Gişe${money ? ' ' + money : ''}</b>${sub(ev.detail)}` };
    case 'delivered': return { icon: 'delivered', tone: 'success', html: `Teslim edildi <b>${money ? '+' + money : ''}</b>${sub(ev.detail)}` };
    case 'cancelled': return { icon: 'cancelled', tone: 'danger', html: `<b>İş iptal edildi${money ? ' −' + money : ''}</b>${sub(ev.detail)}` };
    case 'fuelLow': {
      const range = truck && truck.fuelRange != null ? `menzil ${fmtInt(truck.fuelRange)} km` : ev.detail;
      return { icon: 'fuel', tone: 'warning', html: `<b>Yakıt azaldı</b>${sub(range)}` };
    }
    case 'rest': return { icon: 'rest', tone: 'warning', html: `<b>Mola zamanı</b>${sub(ev.detail ?? 'Bir dinlenme yerine uğra')}` };
    case 'linkDown': return { icon: 'linkOff', tone: 'danger', html: `<b>Bağlantı koptu</b>${sub(ev.detail)}` };
    case 'linkUp': return { icon: 'link', tone: 'success', html: `<b>Bağlantı geri geldi</b>` };
    // Work mode (W2): jobs, commits, servers.
    case 'jobDone': return { icon: 'check', tone: 'success', html: `<b>İş bitti</b>${sub([ev.detail, dur(ev.durationSec)].filter(Boolean).join(' · '))}` };
    case 'jobFail': return { icon: 'x', tone: 'danger', html: `<b>İş başarısız · çıkış ${esc(ev.exitCode)}</b>${sub(ev.detail)}` };
    case 'commit': return { icon: 'commit', tone: 'accent', html: `<b>Commit</b>${sub(ev.detail)}` };
    case 'serverDown': return { icon: 'server', tone: 'danger', html: `<b>Sunucu düştü</b>${sub(ev.detail)}` };
    case 'serverUp': return { icon: 'server', tone: 'success', html: `<b>Sunucu geri geldi</b>${sub(ev.detail)}` };
    // W4: Claude sessions.
    case 'claudeWaiting': return { icon: 'hourglass', tone: 'warning', html: `<b>Claude onay bekliyor</b>${sub(ev.detail)}` };
    case 'claudeDone': return { icon: 'sparkle', tone: 'success', html: `<b>Claude bitirdi</b>${sub(ev.detail)}` };
    default: return null;
  }
}

export function createPill(el) {
  const ic = el.querySelector('.pill-ic');
  const text = el.querySelector('.pill-text');
  const queue = [];
  let busy = false;
  function next() {
    const item = queue.shift();
    if (!item) { busy = false; return; }
    busy = true;
    el.dataset.tone = item.tone;
    ic.innerHTML = icon(item.icon, 24);
    text.innerHTML = item.html;
    el.classList.add('show');
    setTimeout(() => {
      el.classList.remove('show');
      setTimeout(next, 600);
    }, 4000);
  }
  return {
    /** Drops the queue and hides the current pill (the privacy veil). */
    clear() { queue.length = 0; el.classList.remove('show'); },
    push(item) {
      if (!item) return;
      if (queue.length > 6) queue.shift(); // a burst doesn't keep the pill busy for minutes
      queue.push(item);
      if (!busy) next();
    },
  };
}

/** Problem card with a retry countdown ring. show({title, text, retryInSec}) / hide(). */
export function createProblem(el) {
  const t = el.querySelector('#problem-t'), s = el.querySelector('#problem-s'), r = el.querySelector('#problem-retry');
  const arc = el.querySelector('.retry-ring .arc');
  let timer = null;
  el.querySelector('.problem-ic').innerHTML = icon('linkOff', 34);
  function hide() { el.hidden = true; document.body.classList.remove('has-problem'); clearInterval(timer); timer = null; }
  function show({ title, text, retryInSec }) {
    el.hidden = false;
    document.body.classList.add('has-problem');
    t.textContent = title;
    s.textContent = text;
    clearInterval(timer);
    if (!retryInSec) { r.textContent = 'Yeniden deneniyor…'; arc.style.strokeDasharray = '100 100'; return; }
    const end = Date.now() + retryInSec * 1000;
    const tick = () => {
      const left = Math.max(0, Math.ceil((end - Date.now()) / 1000));
      r.textContent = left > 0 ? `${left} sn sonra yeniden denenecek` : 'Yeniden deneniyor…';
      arc.style.strokeDasharray = `${(left / retryInSec) * 100} 100`;
      if (left <= 0) { clearInterval(timer); timer = null; }
    };
    tick();
    timer = setInterval(tick, 250);
  }
  return { show, hide, get visible() { return !el.hidden; } };
}

/** Hold Esc for 1 s → onStop(). A ring fills while it's held. */
export function setupEscHold(el, onStop) {
  const arc = el.querySelector('.arc');
  const label = el.querySelector('.esc-t');
  el.querySelector('.esc-ic').innerHTML = icon('power', 40);
  let start = 0, raf = 0, done = false;
  const reset = () => {
    cancelAnimationFrame(raf); raf = 0; start = 0;
    if (!done) { el.classList.remove('on'); arc.style.strokeDasharray = '0 100'; }
  };
  const step = (now) => {
    const k = Math.min(1, (now - start) / 1000);
    arc.style.strokeDasharray = `${k * 100} 100`;
    if (k >= 1) {
      done = true;
      label.textContent = 'Kapatılıyor…';
      onStop();
      setTimeout(() => { done = false; label.textContent = 'Kapatmak için basılı tut'; reset(); }, 3000);
      return;
    }
    raf = requestAnimationFrame(step);
  };
  addEventListener('keydown', (e) => {
    if (e.key !== 'Escape' || e.repeat || start || done) return;
    e.preventDefault();
    start = performance.now();
    el.classList.add('on');
    raf = requestAnimationFrame(step);
  });
  addEventListener('keyup', (e) => { if (e.key === 'Escape') reset(); });
  addEventListener('blur', reset);
}
