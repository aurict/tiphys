// Odak draft: countdown (fake state; the real one comes from {type:"focus"}), a very slow background painted at
// quarter resolution. Everything runs on the frame scheduler's 1 fps breath: one frame per second updates the time,
// the ring and the background together; nothing else wakes the page.
import { createScheduler, everyMinute } from './sched.js';
import { fillIcons } from './icons.js';

const $ = (s) => document.querySelector(s);
const qs = new URLSearchParams(location.search);
const phase = qs.get('phase') === 'break' ? 'break' : 'focus';
document.body.dataset.phase = phase;
fillIcons();

const P = phase === 'focus'
  ? { label: 'ODAK', total: 25 * 60, left: 18 * 60 + 42, sub: '25 dakikalık tur', round: 2 }
  : { label: 'KISA MOLA', total: 5 * 60, left: 4 * 60 + 12, sub: '5 dakikalık mola', round: 2 };
const endsAt = performance.now() + P.left * 1000;
$('#f-phase').textContent = P.label;
$('#f-sub').textContent = P.sub;
$('#f-mode').textContent = phase === 'focus' ? 'ODAK MODU' : 'ODAK MODU · MOLA';
$('#f-round').textContent = `${P.round}. tur · 4 turda uzun mola`;
$('#f-dots').innerHTML = [1, 2, 3, 4].map((i) => `<i class="${i < P.round ? 'done' : i === P.round ? 'cur' : ''}"></i>`).join('');

everyMinute((d) => {
  $('#f-clock').textContent = d.toLocaleTimeString('tr-TR', { hour: '2-digit', minute: '2-digit' });
  $('#f-date').textContent = d.toLocaleDateString('tr-TR', { weekday: 'long', day: 'numeric', month: 'long' });
});

// ---- background: three soft blobs drifting a few pixels per second (focus: indigo/teal, break: warm)
const cv = $('#fbg');
const g = cv.getContext('2d', { alpha: false });
const SCALE = 0.25;
const BLOBS = phase === 'focus'
  ? [[124, 116, 240, 0.30], [80, 200, 150, 0.12], [94, 92, 230, 0.16]]
  : [[242, 169, 133, 0.34], [255, 179, 64, 0.16], [240, 120, 110, 0.14]];
function resize() { cv.width = Math.round(innerWidth * SCALE); cv.height = Math.round(innerHeight * SCALE); }
resize();
addEventListener('resize', () => { resize(); sched.invalidate(); });
function paintBg(t) {
  const w = cv.width, h = cv.height;
  g.fillStyle = '#000'; g.fillRect(0, 0, w, h);
  const s = t / 1000;
  const spots = [
    [0.5 + 0.06 * Math.sin(s / 47), 0.45 + 0.05 * Math.cos(s / 59), 0.55],
    [0.08 + 0.04 * Math.cos(s / 71), 0.85 + 0.04 * Math.sin(s / 53), 0.45],
    [0.92 + 0.04 * Math.sin(s / 67), 0.12 + 0.05 * Math.cos(s / 61), 0.42],
  ];
  spots.forEach(([x, y, r], i) => {
    const [cr, cg, cb, a] = BLOBS[i];
    const grd = g.createRadialGradient(x * w, y * h, 0, x * w, y * h, r * h);
    grd.addColorStop(0, `rgba(${cr},${cg},${cb},${a})`); grd.addColorStop(1, `rgba(${cr},${cg},${cb},0)`);
    g.fillStyle = grd; g.fillRect(0, 0, w, h);
  });
}

// ---- countdown
let lastText = '', lastBg = -1e9;
function draw(now) {
  const left = Math.max(0, Math.ceil((endsAt - now) / 1000));
  const text = `${Math.floor(left / 60)}:${String(left % 60).padStart(2, '0')}`;
  if (text !== lastText) {
    lastText = text;
    $('#f-time').textContent = text;
    $('#f-arc').style.strokeDasharray = `${((left / P.total) * 100).toFixed(2)} 100`;
  }
  // The background drifts a few pixels a minute: repainting it every 10 s is enough (full-screen layer).
  if (now - lastBg > 10000) { lastBg = now; paintBg(now); }
  $('#f-progress .fill').style.transform = `scaleX(${(((now / 1000) % 214) / 214).toFixed(3)})`;
}
const sched = createScheduler(draw);
sched.setBreath(true); // one frame per second
sched.invalidate();

if (qs.has('perf')) {
  const el = $('#perf'); el.hidden = false;
  let last = 0;
  setInterval(() => { const f = sched.stats.frames; el.textContent = `${f - last} fps · ${f} kare`; last = f; }, 1000);
}
