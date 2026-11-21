// Shared parts of the Work/Focus cards (PLAN.md §20 E-2, E-5): the card frame (header + body + state note), the
// source state each card follows (connecting → data; source down keeps the last data dimmed with a note), middle
// ellipsis for paths and commands, and Turkish relative times / sizes. Cards draw only when a message arrives.
import { icon } from '../icons.js';
import { fmtInt, fmtOne } from '../format.js';

/**
 * Card frame: <article class="card wcard {cls}"> with a header (icon, title, aside), a body and a note.
 * setState(state, title?, text?): 'connecting' | 'down' | 'empty' | 'ready'; the note shows for all but 'ready'.
 */
export function cardFrame(el, { cls, label, ic }) {
  const card = document.createElement('article');
  card.className = `card wcard ${cls}`;
  card.setAttribute('aria-label', label);
  card.dataset.state = 'connecting';
  card.innerHTML = `<div class="card-k">${icon(ic, 18)}<span class="card-t"></span><span class="aside"></span></div>
    <div class="card-body"></div><div class="card-note" role="status"><div class="n1"></div><div class="n2"></div></div>`;
  card.querySelector('.card-t').textContent = label;
  el.append(card);
  const note = card.querySelector('.card-note');
  const n1 = note.querySelector('.n1'), n2 = note.querySelector('.n2');
  function setState(state, title = '', text = '') {
    card.dataset.state = state;
    n1.textContent = title;
    n2.textContent = text;
  }
  setState('connecting', 'Bağlanıyor…');
  return { card, aside: card.querySelector('.aside'), body: card.querySelector('.card-body'), setState };
}

/**
 * Source following for a card that reads `src`: topic messages of other sources are dropped; a `srcstate` of its
 * source switches between the data and "unreachable". Returns {mine(m), down} and calls onState(state) on a change.
 */
export function sourceGate(src, onState) {
  let state = src === 'self' ? 'ok' : 'connecting';
  return {
    get down() { return state === 'down'; },
    /** true for this card's topic messages; handles srcstate itself. */
    mine(m) {
      if (m.type === 'srcstate') {
        if (m.name === src && m.state !== state) { state = m.state === 'off' ? 'connecting' : m.state; onState(state); }
        return false;
      }
      return m.src === src;
    },
  };
}

/** Middle ellipsis: the head shrinks with "…", the last `tail` characters always stay (file name, last argument). */
export function midText(el, text, tail = 16) {
  const t = String(text ?? '');
  const cut = Math.max(0, t.length - tail);
  el.classList.add('mid');
  if (el.childElementCount !== 2) el.innerHTML = '<span class="a"></span><span class="b"></span>';
  el.firstChild.textContent = t.slice(0, cut);
  el.lastChild.textContent = t.slice(cut);
  el.title = t;
}

const MIN = 60_000;
/** "şimdi", "5 dk önce", "3 sa önce", "2 gün önce". */
export function relTime(at, now = Date.now()) {
  const m = Math.max(0, Math.round((now - at) / MIN));
  if (m < 1) return 'şimdi';
  if (m < 60) return `${m} dk önce`;
  if (m < 1440) return `${Math.floor(m / 60)} sa önce`;
  return `${Math.floor(m / 1440)} gün önce`;
}

/** Elapsed seconds → "45 sn", "12 dk", "1 sa 5 dk". */
export function fmtElapsed(sec) {
  const s = Math.max(0, Math.round(sec));
  if (s < 60) return `${s} sn`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m} dk`;
  return m % 60 ? `${Math.floor(m / 60)} sa ${m % 60} dk` : `${Math.floor(m / 60)} sa`;
}

/** Bytes → "512 MB" / "19,6 GB". */
export function fmtBytes(b) {
  if (b == null || !Number.isFinite(b)) return '–';
  if (b < 1024 ** 2) return '<1 MB';
  const gb = b / 1024 ** 3;
  return gb >= 1 ? `${fmtOne(gb)} GB` : `${fmtInt(b / 1024 ** 2)} MB`;
}

/** One timer that calls fn every `ms` while `want()` is true; pause/resume/stop. */
export function ticker(ms, fn, want = () => true) {
  let t = 0, paused = false;
  const arm = () => { clearInterval(t); t = 0; if (!paused && want()) t = setInterval(() => { fn(); if (!want()) arm(); }, ms); };
  return {
    arm,
    pause() { paused = true; arm(); },
    resume() { paused = false; arm(); },
    stop() { paused = true; clearInterval(t); t = 0; },
  };
}
