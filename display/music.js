// Music: the Drive scene's now-playing card and the Music scene (big cover, karaoke lyrics, up next, wave ring).
import { icon } from './icons.js';
import { fmtSongTime } from './format.js';

const $ = (s) => document.querySelector(s);
const BANDS = 24;

/** Text that fits in its box (1 or 2 lines), or a gentle back-and-forth marquee when it doesn't. */
export function fitText(el, text) {
  const span = el.querySelector('.mq');
  if (span.textContent === text && el.dataset.fitW === String(el.clientWidth)) return;
  span.textContent = text;
  el.title = text;
  el.dataset.fitW = String(el.clientWidth);
  el._mq?.cancel();
  el._mq = null;
  el.classList.remove('marquee');
  const lh = parseFloat(getComputedStyle(el).lineHeight) || 0;
  const overflow = el.classList.contains('clamp2') ? el.scrollHeight > lh * 2.5 : el.scrollWidth > el.clientWidth + 1;
  if (!overflow || !el.clientWidth) return;
  el.classList.add('marquee');
  const dist = span.scrollWidth - el.clientWidth * 0.9;
  if (dist <= 0) { el.classList.remove('marquee'); return; }
  const move = (dist / 38) * 1000; // ~38 px/s
  const pause = 2200;
  const total = move * 2 + pause * 2;
  el._mq = span.animate([
    { transform: 'translateX(0)', offset: 0 },
    { transform: 'translateX(0)', offset: pause / total },
    { transform: `translateX(${-dist}px)`, offset: (pause + move) / total },
    { transform: `translateX(${-dist}px)`, offset: (pause * 2 + move) / total },
    { transform: 'translateX(0)', offset: 1 },
  ], { duration: total, iterations: Infinity, easing: 'ease-in-out' });
}

function makeBars(host) {
  host.innerHTML = '';
  const wrap = document.createElement('div');
  wrap.className = 'spec';
  const bars = [];
  for (let i = 0; i < BANDS; i++) { const b = document.createElement('i'); wrap.append(b); bars.push(b); }
  host.append(wrap);
  return { bars, last: new Float32Array(BANDS).fill(-1) };
}

function writeBars(set, values) {
  for (let i = 0; i < BANDS; i++) {
    const v = Math.round(Math.max(0.04, values[i]) * 100) / 100;
    if (v !== set.last[i]) { set.last[i] = v; set.bars[i].style.transform = `scaleY(${v})`; }
  }
}

/** Index of the active synced line at position `pos` (-1 before the first). */
function activeLine(lines, pos) {
  let lo = 0, hi = lines.length - 1, ans = -1;
  while (lo <= hi) {
    const mid = (lo + hi) >> 1;
    if (lines[mid].t <= pos + 0.15) { ans = mid; lo = mid + 1; } else hi = mid - 1;
  }
  return ans;
}

export function createMusic({ onCoverLoaded }) {
  const np = { card: $('#np-card'), cover: $('#np-cover'), title: $('#np-title'), artist: $('#np-artist'), state: $('#np-state'),
    glow: $('#np-cover .cover-glow'), lyrics: $('#np-lyrics'), empty: $('#np-empty'), spec: makeBars($('#np-spec')) };
  const mu = { scene: $('#scene-music'), cover: $('#mu-cover'), title: $('#mu-title'), artist: $('#mu-artist'), overline: $('#mu-overline'),
    lyrics: $('#mu-lyrics'), track: $('#mu-lyrics .ly-track'), specBox: $('#mu-spec'), spec: makeBars($('#mu-spec')), next: $('#next-row'),
    wave: $('#mu-wave') };
  for (const n of document.querySelectorAll('.cover-none')) n.innerHTML = icon('music', n.closest('#mu-cover') ? 120 : 46);
  const progress = [$('#np-progress'), $('#mu-progress')].map((el) => ({ fill: el.querySelector('.fill'), pos: el.querySelector('.pos'), dur: el.querySelector('.dur'), lastK: -1, lastS: '' }));

  let music = null;           // last music message (or null / {none})
  let base = { pos: 0, t: 0 }; // position anchor in performance.now() time
  let lyrics = null;          // lyrics message matching the current track
  let pendingLyrics = null;
  let artId = undefined, artUrl = null;
  let curLine = -2, lineEls = [];
  let settings = { lyrics: true, spectrum: true, motion: 'normal' };
  let pausedAt = 0;
  const spec = new Float32Array(BANDS), specTarget = new Float32Array(BANDS);
  let specAt = 0, bass = 0, lastBarWrite = 0, lastWave = 0;
  const wctx = mu.wave.getContext('2d');
  let toneStr = '165,180,252';

  const hasMusic = () => !!music && !music.none;
  const position = () => {
    if (!hasMusic()) return 0;
    const p = base.pos + (music.playing ? (performance.now() - base.t) / 1000 : 0);
    return Math.max(0, Math.min(music.duration || p, p));
  };

  function lyricsMatch(l) {
    if (!l || !hasMusic()) return false;
    if (l.artId != null && music.artId != null) return l.artId === music.artId;
    return l.title === music.title;
  }

  function setMusic(m) {
    const prevPlaying = hasMusic() && music.playing;
    music = m;
    if (!hasMusic()) {
      np.card.classList.add('empty'); np.empty.hidden = false;
      setArt(null);
      lyrics = null; renderLyrics();
      return;
    }
    np.card.classList.remove('empty'); np.empty.hidden = true;
    // Position anchored when sampled (`at`, ms epoch on the source host); clamp clock skew to 0..5 s.
    const age = m.playing && m.at ? Math.min(5, Math.max(0, (Date.now() - m.at) / 1000)) : 0;
    base = { pos: (m.position ?? 0) + age, t: performance.now() };
    if (m.playing) pausedAt = 0;
    else if (prevPlaying || !pausedAt) pausedAt = Date.now();
    np.card.classList.toggle('paused', !m.playing);
    np.state.textContent = m.playing ? 'Şimdi çalıyor' : 'Duraklatıldı';
    mu.overline.textContent = m.playing ? 'ŞİMDİ ÇALIYOR · VELOUR' : 'DURAKLATILDI · VELOUR';
    fitText(np.title, m.title || 'Bilinmeyen şarkı');
    fitText(np.artist, m.artist || '');
    fitText(mu.title, m.title || 'Bilinmeyen şarkı');
    fitText(mu.artist, [m.artist, m.album].filter(Boolean).join(' · '));
    for (const p of progress) p.dur.textContent = fmtSongTime(m.duration);
    renderNext(m.next ?? []);
    setArt(m.artId ?? null);
    if (pendingLyrics && lyricsMatch(pendingLyrics)) { lyrics = pendingLyrics; renderLyrics(); }
    else if (lyrics && !lyricsMatch(lyrics)) { lyrics = null; renderLyrics(); }
  }

  function renderNext(next) {
    mu.scene.classList.toggle('no-next', next.length === 0);
    mu.next.innerHTML = '';
    next.slice(0, 2).forEach((n, i) => {
      const c = document.createElement('div');
      c.className = 'card next-card';
      c.innerHTML = `<div class="nb">${i + 1}</div><div class="nt"><div class="t1"></div><div class="t2"></div></div>`;
      c.querySelector('.t1').textContent = n.title ?? '';
      c.querySelector('.t2').textContent = n.artist ?? '';
      mu.next.append(c);
    });
  }

  function setArt(id) {
    if (id === artId) return;
    artId = id;
    const boxes = [np.cover, mu.cover];
    if (id == null) {
      artUrl = null;
      for (const b of boxes) b.classList.remove('has-art');
      onCoverLoaded(null);
      return;
    }
    const url = `/v1/gamemode/art?t=${encodeURIComponent(window.__tphToken ?? '')}&id=${encodeURIComponent(id)}`;
    const img = new Image();
    img.decoding = 'async';
    img.onload = () => {
      if (artId !== id) return;
      artUrl = url;
      for (const b of boxes) { const el = b.querySelector('img'); el.src = url; b.classList.add('has-art'); }
      onCoverLoaded(img);
    };
    img.onerror = () => {
      if (artId !== id) return;
      artUrl = null;
      for (const b of boxes) b.classList.remove('has-art');
      onCoverLoaded(null);
    };
    img.src = url;
  }

  function setLyrics(l) {
    pendingLyrics = l;
    lyrics = lyricsMatch(l) ? l : null;
    renderLyrics();
  }

  const usable = () => settings.lyrics && lyrics && lyrics.kind !== 'none' && (lyrics.lines?.length ?? 0) > 0;

  function renderLyrics() {
    curLine = -2;
    const show = usable();
    np.lyrics.hidden = !show || lyrics.kind !== 'synced';
    mu.lyrics.hidden = !show;
    mu.specBox.hidden = show || !settings.spectrum || !hasMusic();
    mu.track.innerHTML = '';
    mu.track.style.transform = 'translateY(0)';
    lineEls = [];
    if (!show) return;
    for (const line of lyrics.lines) {
      const d = document.createElement('div');
      d.className = 'ly far';
      if (line.text) d.textContent = line.text; else d.innerHTML = icon('music', 34);
      mu.track.append(d);
      lineEls.push(d);
    }
    if (lyrics.kind === 'plain') {
      for (const d of lineEls) d.className = 'ly plain';
      mu.track.style.transform = 'translateY(40px)';
    }
  }

  function updateLyrics(pos) {
    if (!usable() || lyrics.kind !== 'synced') return;
    const i = activeLine(lyrics.lines, pos);
    if (i === curLine) return;
    curLine = i;
    const L = lyrics.lines;
    const txt = (k) => (k >= 0 && k < L.length ? (L[k].text || '♪') : '');
    const [a, b, c] = np.lyrics.children;
    a.textContent = txt(i - 1); b.textContent = i < 0 ? (L[0]?.text ? '…' : '') : txt(i); c.textContent = txt(i < 0 ? 0 : i + 1);
    lineEls.forEach((el, k) => {
      const d = k - i;
      el.className = 'ly' + (d === 0 ? ' cur' : d < 0 ? ' past' : '') + (Math.abs(d) > 7 ? ' far' : '');
    });
    const target = lineEls[Math.max(0, i)];
    if (target) {
      const h = mu.lyrics.clientHeight;
      const y = h * 0.36 - (target.offsetTop + target.offsetHeight / 2);
      mu.track.style.transform = `translateY(${Math.round(y)}px)`;
    }
  }

  function setSpectrumFrame(bytes) {
    for (let i = 0; i < BANDS; i++) specTarget[i] = (bytes[i + 1] ?? 0) / 255;
    specAt = performance.now();
  }

  function drawWave(now) {
    const dpr = Math.min(2, devicePixelRatio || 1);
    const W = mu.wave.clientWidth, H = mu.wave.clientHeight;
    if (!W) return;
    if (mu.wave.width !== Math.round(W * dpr)) { mu.wave.width = Math.round(W * dpr); mu.wave.height = Math.round(H * dpr); }
    wctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    wctx.clearRect(0, 0, W, H);
    if (!hasMusic()) return;
    const tone = toneStr;
    // The cover's rounded square, offset outward along its normal. Each side bulges gently with the music (bass at the
    // side's middle, mids as a slow travelling ripple); the rounded corners stay put, so the outline breathes calmly.
    const cx = W / 2, cy = H / 2, half = 260, rc = 26;
    const mid = (spec[6] + spec[8] + spec[10] + spec[12]) / 4;
    const t = now / 1000;
    const base = 24;
    const side = half - rc;          // half length of a straight part
    const R = rc + base;              // corner radius of the ring
    const PER_SIDE = 40, PER_ARC = 10;
    const pts = [];
    for (let q = 0; q < 4; q++) {
      const a = (q * Math.PI) / 2;    // side normal: 0 = right, then down, left, up (canvas y down)
      const nx = Math.cos(a), ny = Math.sin(a), tx = -ny, ty = nx;
      for (let k = 0; k < PER_SIDE; k++) {
        const u = k / PER_SIDE;       // 0..1 along the side
        const w = Math.sin(Math.PI * u);
        const off = base + w * w * (bass * 14 + mid * 6 * (0.5 + 0.5 * Math.sin(u * 9 - t * 2.2 + q)));
        const along = -side + 2 * side * u;
        pts.push([cx + nx * (half + off) + tx * along, cy + ny * (half + off) + ty * along]);
      }
      for (let k = 0; k < PER_ARC; k++) {
        const ang = a + (k / PER_ARC) * (Math.PI / 2);
        const ccx = cx + nx * side + tx * side, ccy = cy + ny * side + ty * side; // corner centre
        pts.push([ccx + Math.cos(ang) * R, ccy + Math.sin(ang) * R]);
      }
    }
    const N = pts.length;
    const path = () => {
      wctx.beginPath();
      for (let k = 0; k <= N; k++) {
        const p = pts[k % N], q = pts[(k + 1) % N];
        const mx = (p[0] + q[0]) / 2, my = (p[1] + q[1]) / 2;
        if (k === 0) wctx.moveTo(mx, my); else wctx.quadraticCurveTo(p[0], p[1], mx, my);
      }
      wctx.closePath();
    };
    path();
    wctx.lineJoin = 'round';
    wctx.strokeStyle = `rgba(${tone},${0.07 + bass * 0.10})`;
    wctx.lineWidth = 16;
    wctx.stroke();
    wctx.strokeStyle = `rgba(${tone},${0.55 + bass * 0.35})`;
    wctx.lineWidth = 2.5;
    wctx.stroke();
  }

  /** Per animation frame. `scene` = visible scene; returns the bass level (0..1) for the ambient pulse. */
  function frame(now, scene) {
    const playing = hasMusic() && music.playing;
    const fresh = now - specAt < 350 && playing && settings.spectrum;
    for (let i = 0; i < BANDS; i++) {
      const tgt = fresh ? specTarget[i] : 0;
      spec[i] += (tgt - spec[i]) * (tgt > spec[i] ? 0.55 : 0.14);
    }
    const b = (spec[0] * 1.2 + spec[1] + spec[2] * 0.8) / 3;
    bass += (Math.min(1, b) - bass) * 0.35;

    const pos = position();
    const dur = hasMusic() ? music.duration || 0 : 0;
    const k = dur > 0 ? Math.round((pos / dur) * 1000) / 1000 : 0;
    const label = fmtSongTime(pos);
    const vis = scene === 'drive' ? [progress[0]] : scene === 'music' ? [progress[1]] : [];
    for (const p of vis) {
      if (p.lastK !== k) { p.lastK = k; p.fill.style.transform = `scaleX(${k})`; }
      if (p.lastS !== label) { p.lastS = label; p.pos.textContent = label; }
    }
    if (scene === 'drive' || scene === 'music') updateLyrics(pos);

    const barFps = settings.motion === 'low' ? 15 : settings.motion === 'high' ? 60 : 30;
    if (now - lastBarWrite >= 1000 / barFps - 2) {
      lastBarWrite = now;
      if (scene === 'drive' && settings.spectrum) {
        writeBars(np.spec, spec);
        const g = settings.motion === 'low' ? 0 : Math.round(bass * 100) / 100;
        np.glow.style.opacity = String(Math.min(0.95, g * 1.4));
        np.glow.style.transform = `scale(${1 + g * 0.035})`;
      }
      if (scene === 'music' && !mu.specBox.hidden) writeBars(mu.spec, spec);
    }
    if (scene === 'music' && settings.motion !== 'low' && now - lastWave >= 33) { lastWave = now; drawWave(now); }
    return settings.spectrum ? bass : 0;
  }

  return {
    setMusic, setLyrics, setSpectrumFrame, frame,
    setTone(rgb) { toneStr = rgb.map(Math.round).join(','); },
    setSettings(s) {
      settings = s;
      document.querySelector('#np-spec').hidden = !s.spectrum;
      if (s.motion === 'low') { lastWave = 0; drawWave(0); }
      renderLyrics();
    },
    refit() {
      if (!hasMusic()) return;
      for (const el of [np.title, np.artist, mu.title, mu.artist]) { el.dataset.fitW = ''; fitText(el, el.querySelector('.mq').textContent); }
      curLine = -2;
    },
    get hasMusic() { return hasMusic(); },
    get playing() { return hasMusic() && music.playing; },
    get pausedAt() { return pausedAt; },
    get hasArt() { return artUrl != null; },
    get artUrl() { return artUrl; },
    get title() { return hasMusic() ? music.title : null; },
  };
}
