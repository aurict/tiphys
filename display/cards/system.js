// Kaynaklar card (PLAN.md §20 E-2): CPU, RAM and GPU rings, CPU temperature, battery on hosts that have one. Drawn
// only when a `system` message arrives (the source sends one every 2 s at most, and only on a visible change); the
// agent drops the topic while the page is hidden, so nothing runs here between messages. No GPU → no GPU ring.
import { icon } from '../icons.js';
import { fmtInt } from '../format.js';
import { cardFrame, fmtBytes, sourceGate } from './common.js';

const ring = (cls, label) => `<div class="gauge ${cls}"><div class="gauge-ring"><svg class="ring" viewBox="0 0 120 120" aria-hidden="true"><circle class="track" cx="60" cy="60" r="50"/><circle class="arc" cx="60" cy="60" r="50" pathLength="100"/></svg><div class="pct"></div></div><div class="gtxt"><div class="gk">${label}</div><div class="gs"></div></div></div>`;

export function mount(el, ctx, { src = 'self' } = {}) {
  const f = cardFrame(el, { cls: 'sys-card', label: 'Kaynaklar', ic: 'cpu' });
  f.body.innerHTML = `<div class="rings">${ring('g-cpu', 'CPU')}${ring('g-ram', 'RAM')}${ring('g-gpu', 'GPU')}</div>`;
  const g = (cls) => {
    const e = f.body.querySelector(`.${cls}`);
    return { e, arc: e.querySelector('.arc'), pct: e.querySelector('.pct'), gs: e.querySelector('.gs') };
  };
  const cpu = g('g-cpu'), ram = g('g-ram'), gpu = g('g-gpu');
  let last = null;
  const gate = sourceGate(src, (s) => {
    if (s === 'down') f.setState('down', 'Kaynağa ulaşılamıyor', 'Son bilinen değerler');
    else if (s === 'connecting' && !last) f.setState('connecting', 'Bağlanıyor…');
    else if (last) f.setState('ready');
  });

  function set(x, frac, sub, hot = frac > 0.85) {
    const v = Math.max(0, Math.min(1, frac ?? 0));
    x.arc.style.strokeDasharray = `${Math.max(0.5, v * 100).toFixed(1)} 100`;
    x.arc.style.opacity = '1';
    x.pct.innerHTML = `${Math.round(v * 100)}<small>%</small>`;
    x.gs.textContent = sub;
    x.e.classList.toggle('hot', hot);
  }

  function draw(m) {
    last = m;
    const temp = m.temp != null ? `${fmtInt(m.temp)} °C` : `${m.cores} çekirdek`;
    set(cpu, m.cpu, temp, m.cpu > 0.85 || (m.temp ?? 0) >= 90);
    set(ram, m.mem.total ? m.mem.used / m.mem.total : 0, `${fmtBytes(m.mem.used).replace(' GB', '')} / ${fmtBytes(m.mem.total)}`);
    gpu.e.hidden = !m.gpu;
    f.body.querySelector('.rings').classList.toggle('two', !m.gpu);
    if (m.gpu) {
      const parts = [m.gpu.temp != null ? `${fmtInt(m.gpu.temp)} °C` : null, m.gpu.memUsed != null ? fmtBytes(m.gpu.memUsed) : null].filter(Boolean);
      set(gpu, m.gpu.util, parts.join(' · ') || 'entegre');
    }
    const b = m.battery;
    const cores = `${m.cores} çekirdek`;
    f.aside.innerHTML = b
      ? `<span class="batt${b.level <= 20 && !b.charging ? ' low' : ''}">${icon(b.charging ? 'bolt' : 'battery', 16)}<span></span></span><span class="sep"></span><span></span>`
      : '<span></span>';
    if (b) {
      f.aside.querySelector('.batt span').textContent = `%${fmtInt(b.level)}${b.charging ? ' · şarjda' : ''}`;
      f.aside.lastChild.textContent = cores;
    } else f.aside.firstChild.textContent = cores;
    if (!gate.down) f.setState('ready');
  }

  return {
    update(m) {
      if (!gate.mine(m)) return;
      if (m.type === 'system') draw(m);
    },
    pause() {},
    resume() {},
    destroy() { f.card.remove(); },
  };
}
