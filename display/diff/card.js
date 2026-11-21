// Approval preview over the code city (PLAN.md §20 E-2 "Diff kartı"; the W0 draft's look). A `diff` message opens it:
// the city freezes behind a pre-blurred snapshot (no live blur, no frames), the card shows the session, the tool, the
// path, +/− counts and the line-numbered unified diff (diff/tokenizer.js), sliding slowly through long diffs; Bash
// shows the command and the reason; other tools a short summary. Several pending requests → tabs. The page has NO
// approval rights (Decision 3; tabs take turns every 10 s): the footer only says "Telefonda onayla" and how long it has been waiting. It closes
// 1 s after the last `diffResolved`. A session that waits without a diff (terminal session, code sharing off, a file
// outside the project, or the diff card turned off) gets the compact banner "Onay bekliyor · session · tool · file".
import { icon } from '../icons.js';
import { renderDiff, shortPath } from './tokenizer.js';

const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c]);
const waited = (ms) => {
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s} sn'dir bekliyor`;
  const m = Math.floor(s / 60);
  return m < 60 ? `${m} dk'dır bekliyor` : `${Math.floor(m / 60)} sa ${m % 60} dk'dır bekliyor`;
};
const tabLabel = (d) => (d.tool === 'Bash' ? (d.command ?? '').trim().split(/\s+/)[0] || 'komut' : d.path ? d.path.split('/').pop() : d.tool);

/**
 * host: the city's root element. hooks: snapshot() → canvas|null (the city, blurred), freeze()/thaw() (stop/restart
 * the city's frames). Returns {diff(m), resolved(m), sessions(list, masked), setEnabled(on), pause(), resume(), destroy()}.
 */
export function createApproval(host, hooks) {
  const layer = document.createElement('div');
  layer.className = 'diff-layer';
  layer.setAttribute('aria-live', 'polite');
  layer.innerHTML = `<canvas class="diff-bg" aria-hidden="true"></canvas><div class="diff-shade"></div>
    <div class="diff-card" role="dialog" aria-label="Onay bekleyen değişiklik">
      <div class="d-tabs"></div><div class="d-content"></div>
      <div class="d-foot"><div class="ph">${icon('phone', 24)}</div>
        <div><div class="t1">Telefonda onayla</div><div class="t2">Tiphys › Claude › bekleyen izin · bu ekranın onay yetkisi yok</div></div>
        <div class="wait">${icon('hourglass', 18)}<span class="d-wait">–</span></div></div>
    </div>`;
  const banner = document.createElement('div');
  banner.className = 'approval-banners';
  banner.setAttribute('role', 'status');
  host.append(layer, banner);
  const $ = (s) => layer.querySelector(s);
  const tabsEl = $('.d-tabs'), content = $('.d-content'), waitEl = $('.d-wait'), foot = $('.d-foot');

  const pending = new Map(); // requestId → diff message (arrival order)
  let current = null, open = false, enabled = true, paused = false;
  let waitTimer = 0, scrollTimer = 0, closeTimer = 0, freezeTimer = 0, rotateTimer = 0;
  let lastSessions = [], masked = false;

  function show() {
    clearTimeout(closeTimer); closeTimer = 0;
    foot.classList.remove('done');
    if (open) return;
    open = true;
    const snap = hooks.snapshot();
    const bg = $('.diff-bg');
    if (snap) { bg.width = snap.width; bg.height = snap.height; bg.getContext('2d').drawImage(snap, 0, 0); }
    layer.classList.add('on');
    freezeTimer = setTimeout(() => hooks.freeze(), 500); // the card covers the city: nothing behind needs frames
  }
  function hide() {
    if (!open) return;
    open = false;
    clearTimeout(freezeTimer);
    clearTimeout(waitTimer); clearTimeout(scrollTimer); clearTimeout(rotateTimer);
    layer.classList.remove('on');
    hooks.thaw();
  }

  function renderTabs() {
    tabsEl.hidden = pending.size < 2;
    if (pending.size < 2) { tabsEl.replaceChildren(); return; }
    tabsEl.innerHTML = [...pending.values()].map((d) =>
      `<div class="d-tab${d.requestId === current ? ' on' : ''}"><span class="dot"></span>${esc(d.tool)}<code>${esc(tabLabel(d))}</code></div>`).join('');
  }

  function render() {
    const d = pending.get(current);
    if (!d) return;
    renderTabs();
    clearTimeout(scrollTimer);
    // The kiosk can't be clicked: with several requests the tabs take turns (10 s each).
    clearTimeout(rotateTimer); rotateTimer = 0;
    if (pending.size > 1 && !paused) rotateTimer = setTimeout(() => {
      const ids = [...pending.keys()];
      current = ids[(ids.indexOf(current) + 1) % ids.length];
      render();
    }, 10_000);
    const session = `<div class="d-session"><span class="d-sname">${esc(d.session || d.sessionId)}</span><span class="d-tool">${esc(d.tool)}</span></div>`;
    if (d.tool === 'Bash') {
      content.innerHTML = `<div class="d-head"><div class="d-orb">${icon('terminal', 24)}</div><div class="d-titles">${session}<div class="d-path sans">Komut çalıştırma izni</div></div></div>
        <div class="bash"><div class="k">KOMUT</div><div class="cmd"><span class="pr">$</span><span class="c"></span></div>
        <div class="k reason-k">GEREKÇE</div><div class="reason"></div></div>`;
      content.querySelector('.cmd .c').textContent = d.command ?? '';
      content.querySelector('.reason').textContent = d.reason ?? '';
      content.querySelector('.reason-k').hidden = content.querySelector('.reason').hidden = !d.reason;
    } else if (d.path !== undefined) {
      const path = d.path ?? '';
      const short = shortPath(path, 72);
      const cut = short.lastIndexOf('/') + 1;
      content.innerHTML = `<div class="d-head"><div class="d-orb">${icon(d.created ? 'filePlus' : 'pencil', 22)}</div><div class="d-titles">${session}
        <div class="d-path" title="${esc(path)}"><span class="dir">${esc(short.slice(0, cut))}</span>${esc(short.slice(cut))}</div></div>
        <div class="d-stat"><span class="a">+${d.added ?? 0}</span><span class="r">−${d.removed ?? 0}</span></div></div>
        <div class="d-body"><div class="d-rows"></div></div>`;
      const rows = content.querySelector('.d-rows');
      if (d.binary) rows.innerHTML = `<div class="d-empty">${icon('code', 22)}<span>İkili dosya · önizleme yok</span></div>`;
      else if (!d.hunks?.length) rows.innerHTML = `<div class="d-empty">${icon('code', 22)}<span>${d.created ? 'Boş dosya oluşturulacak' : 'İçerik değişmiyor'}</span></div>`;
      else rows.innerHTML = renderDiff(d);
      autoScroll(content.querySelector('.d-body'), rows);
    } else {
      content.innerHTML = `<div class="d-head"><div class="d-orb">${icon('sparkle', 22)}</div><div class="d-titles">${session}<div class="d-path sans">Araç kullanım izni</div></div></div>
        <div class="bash"><div class="k">GİRDİ</div><div class="cmd summary"></div></div>`;
      content.querySelector('.cmd').textContent = d.summary ?? '';
    }
    tickWait();
  }

  // Long diffs move ~60 % of the visible height every 5 s (a 0.9 s transform), then back to the top.
  function autoScroll(body, rows) {
    let y = 0;
    const step = () => {
      scrollTimer = 0;
      if (paused) return;
      const max = rows.scrollHeight - body.clientHeight + 40;
      if (max <= 0) return;
      y = y >= max ? 0 : Math.min(max, y + body.clientHeight * 0.6);
      rows.style.transform = `translateY(${-y}px)`;
      scrollTimer = setTimeout(step, y === 0 ? 6000 : 5000);
    };
    scrollTimer = setTimeout(step, 5000);
  }
  // Waiting time: every second for the first minute, then every 15 s (minutes only).
  function tickWait() {
    clearTimeout(waitTimer); waitTimer = 0;
    const d = pending.get(current);
    if (!d || !open || paused || foot.classList.contains('done')) return;
    const ms = Date.now() - (d.at ?? Date.now());
    waitEl.textContent = waited(ms);
    waitTimer = setTimeout(tickWait, ms < 60_000 ? 1000 : 15_000);
  }

  function select() {
    if (!pending.has(current)) current = pending.keys().next().value ?? null;
  }

  /** Waiting sessions without a diff on screen → banners (at most 3). */
  function drawBanners() {
    const rows = [];
    for (const s of lastSessions) {
      if (s.status !== 'waiting' || !s.waiting) continue;
      if (enabled && (s.pending ?? []).some((id) => pending.has(id))) continue; // its diff is on the card
      rows.push(s);
    }
    banner.innerHTML = rows.slice(0, 3).map((s) => {
      const file = s.waiting.path ? (masked ? 'dosya adı gizli' : shortPath(s.waiting.path, 44)) : null;
      return `<div class="approval-banner"><span class="dot"></span><b>Onay bekliyor</b><span class="sep"></span><span class="nm">${esc(s.name)}</span>${s.waiting.tool ? `<span class="sep"></span><code class="tl">${esc(s.waiting.tool)}</code>` : ''}${file ? `<span class="sep"></span><span class="fl${s.waiting.path && masked ? ' masked' : ''}">${esc(file)}</span>` : ''}<span class="hint">${icon('phone', 16)}telefonda</span></div>`;
    }).join('');
  }

  function closeSoon() {
    // The last request was decided: the footer says so for 1 s, then the city comes back.
    foot.classList.add('done');
    clearTimeout(waitTimer);
    clearTimeout(closeTimer);
    closeTimer = setTimeout(() => { closeTimer = 0; if (!pending.size) hide(); }, 1000);
  }

  return {
    diff(m) {
      if (!enabled || typeof m.requestId !== 'string') return;
      pending.set(m.requestId, m);
      select();
      show();
      if (m.requestId === current || pending.size > 1) render();
      drawBanners();
    },
    resolved(m) {
      if (!pending.delete(m.requestId)) return;
      waitEl.textContent = m.allow ? 'onaylandı' : 'reddedildi';
      if (!pending.size) closeSoon();
      else { select(); render(); }
      drawBanners();
    },
    /** The `claude` state: banners, and diffs that are no longer pending are dropped. */
    sessions(list, isMasked) {
      lastSessions = list;
      masked = isMasked;
      const live = new Set(list.flatMap((s) => s.pending ?? []));
      let gone = false;
      for (const id of [...pending.keys()]) if (!live.has(id)) { pending.delete(id); gone = true; }
      if (gone) {
        if (!pending.size) closeSoon();
        else { select(); render(); }
      }
      drawBanners();
    },
    /** `screen.modes.work.diff` off: no card (the banner says what waits). */
    setEnabled(on) {
      enabled = on;
      if (!on) { pending.clear(); hide(); }
      drawBanners();
    },
    get open() { return open; },
    pause() { paused = true; clearTimeout(waitTimer); clearTimeout(scrollTimer); clearTimeout(rotateTimer); },
    resume() { paused = false; if (open && current) render(); },
    destroy() {
      clearTimeout(waitTimer); clearTimeout(scrollTimer); clearTimeout(closeTimer); clearTimeout(freezeTimer); clearTimeout(rotateTimer);
      layer.remove(); banner.remove();
    },
  };
}
