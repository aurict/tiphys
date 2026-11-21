// Sunucular card (PLAN.md §20 E-2, "Ek önerilerim" 3): hidden while nothing is known; one line "hepsi ayakta" while
// every monitor is up and no incident is open; grows into a list of the down hosts and the open incident count when
// something is wrong. A host going down / coming back → notification pill (not on the first message).
import { icon } from '../icons.js';
import { eventCopy } from '../notify.js';
import { cardFrame, relTime, sourceGate } from './common.js';

export function mount(el, ctx, { src = 'self' } = {}) {
  const f = cardFrame(el, { cls: 'srv-card', label: 'Sunucular', ic: 'server' });
  f.card.hidden = true;
  f.body.innerHTML = '<div class="srv-list"></div>';
  const list = f.body.querySelector('.srv-list');
  let last = null;
  const gate = sourceGate(src, () => draw());

  function draw() {
    const m = last;
    if (!m || !m.available) {
      // Optional card: not shown while connecting or when the source has no monitoring; a lost source is one line.
      f.card.hidden = !(gate.down && m?.available);
      f.card.classList.add('line');
      return f.setState('down', 'Sunucu durumu alınamıyor', 'Kaynağa ulaşılamıyor');
    }
    f.card.hidden = false;
    const down = m.hosts.filter((h) => !h.up);
    const bad = down.length > 0 || m.incidents > 0;
    f.card.classList.toggle('line', !bad);
    f.card.classList.toggle('bad', bad);
    if (!bad) {
      f.aside.innerHTML = '<span class="ok-dot"></span><span></span>';
      f.aside.lastChild.textContent = m.hosts.length ? `hepsi ayakta · ${m.hosts.length}` : 'izlenen sunucu yok';
    } else f.aside.textContent = [down.length ? `${down.length} sunucu düştü` : null, m.incidents ? `${m.incidents} açık olay` : null].filter(Boolean).join(' · ');
    list.replaceChildren(...down.slice(0, 4).map((h) => {
      const r = document.createElement('div');
      r.className = 'srv';
      r.innerHTML = `<span class="sd">${icon('server', 16)}</span><span class="sn"></span><span class="st"></span>`;
      r.children[1].textContent = h.name;
      r.children[2].textContent = h.since ? `${relTime(Date.parse(h.since))} düştü` : 'düştü';
      return r;
    }));
    f.setState(gate.down ? 'down' : 'ready', gate.down ? 'Kaynağa ulaşılamıyor' : '', gate.down ? 'Son bilinen durum' : '');
  }

  return {
    update(m) {
      if (!gate.mine(m) || m.type !== 'servers') return;
      if (last?.available) {
        const was = new Map(last.hosts.map((h) => [h.name, h.up]));
        for (const h of m.hosts) {
          if (was.get(h.name) === true && !h.up) ctx.pill(eventCopy({ kind: 'serverDown', detail: h.name }));
          if (was.get(h.name) === false && h.up) ctx.pill(eventCopy({ kind: 'serverUp', detail: h.name }));
        }
      }
      last = m;
      draw();
    },
    pause() {},
    resume() {},
    destroy() { f.card.remove(); },
  };
}
