// Müzik card, small (PLAN.md §20 E-2/E-3): cover, title, artist and a thin progress bar from the existing `music`
// message (no spectrum, no lyrics). The bar and position step every 5 s while playing (no per-frame animation); paused
// or hidden → no timer. The cover comes through the display agent's cover proxy like the Game mode player.
import { icon } from '../icons.js';
import { fmtSongTime } from '../format.js';
import { cardFrame, sourceGate, ticker } from './common.js';

export function mount(el, ctx, { src = 'self', size = 'normal' } = {}) {
  const f = cardFrame(el, { cls: `mu-card${size === 'big' ? ' big' : ''}`, label: 'Müzik', ic: 'music' });
  f.body.innerHTML = `<div class="cover-box mc-cover"><img alt="" decoding="async"><div class="cover-none">${icon('music', 30)}</div></div>
    <div class="mu-text"><div class="np-label"><span class="live-dot"></span><span class="mu-state"></span></div><div class="mu-t"></div><div class="mu-a"></div>
    <div class="progress"><div class="bar"><div class="fill"></div></div><div class="times"><span class="pos">0:00</span><span class="dur">0:00</span></div></div></div>`;
  const $ = (s) => f.body.querySelector(s);
  const cover = $('.mc-cover'), img = cover.querySelector('img');
  let m = null, artId = null;
  const gate = sourceGate(src, () => draw());
  const tick = ticker(5000, () => progress(), () => m?.playing === true && !m.none);

  img.onload = () => cover.classList.add('has-art');
  img.onerror = () => cover.classList.remove('has-art');

  function progress() {
    if (!m || m.none) return;
    const pos = Math.min(m.duration || 0, (m.position ?? 0) + (m.playing ? (Date.now() - (m.at ?? Date.now())) / 1000 : 0));
    $('.fill').style.transform = `scaleX(${m.duration ? (pos / m.duration).toFixed(4) : 0})`;
    $('.pos').textContent = fmtSongTime(pos);
  }

  function draw() {
    if (!m) return f.setState(gate.down ? 'down' : 'connecting', gate.down ? 'Kaynağa ulaşılamıyor' : 'Bağlanıyor…');
    if (m.none) {
      tick.arm();
      return f.setState('empty', 'Velour’da çalan bir şey yok', '');
    }
    f.card.classList.toggle('playing', m.playing === true);
    $('.mu-state').textContent = m.playing ? 'Şimdi çalıyor · Velour' : 'Duraklatıldı · Velour';
    $('.mu-t').textContent = m.title || '–';
    $('.mu-a').textContent = [m.artist, m.album].filter(Boolean).join(' · ');
    $('.dur').textContent = fmtSongTime(m.duration);
    if (m.artId !== artId) {
      artId = m.artId ?? null;
      cover.classList.remove('has-art');
      if (artId) img.src = `/v1/screen/art?t=${encodeURIComponent(window.__tphToken ?? '')}&id=${encodeURIComponent(artId)}`;
      else img.removeAttribute('src');
    }
    progress();
    tick.arm();
    f.setState(gate.down ? 'down' : 'ready', gate.down ? 'Kaynağa ulaşılamıyor' : '', gate.down ? 'Son bilinen şarkı' : '');
  }

  return {
    update(msg) {
      if (!gate.mine(msg)) return;
      if (msg.type === 'music') { m = msg; draw(); }
    },
    pause() { tick.pause(); },
    resume() { tick.resume(); progress(); },
    destroy() { tick.stop(); f.card.remove(); },
  };
}
