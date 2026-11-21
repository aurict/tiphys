// Çalışma mode draft: real city data (city.json, from make-snapshot.mjs) + a fake activity replay so the page is alive.
// In the real page these calls are driven by the {type:"touch"|"commit"|"claude"|"jobs"|"jobDone"|"diff"} messages.
import { createCity, KINDS } from './city.js';
import { everyMinute, every } from './sched.js';
import { renderDiff, shortPath } from './diff.js';
import { PENDING } from './samples.js';
import { icon, fillIcons } from './icons.js';

const $ = (s) => document.querySelector(s);
const qs = new URLSearchParams(location.search);
const STATE = qs.get('state') ?? 'city';
const REPLAY = qs.get('replay') !== '0' && STATE !== 'diff';
const nf = new Intl.NumberFormat('tr-TR');
fillIcons();

// ------------------------------------------------------------------ clock (once a minute)
everyMinute((d) => {
  $('#day-clock').textContent = d.toLocaleTimeString('tr-TR', { hour: '2-digit', minute: '2-digit' });
  const day = d.toLocaleDateString('tr-TR', { weekday: 'long' });
  $('#day-date').innerHTML = `${d.toLocaleDateString('tr-TR', { day: 'numeric', month: 'long' })} <span>· ${day}</span>`;
});

// ------------------------------------------------------------------ pill (Game mode's notification pill)
const pill = $('#pill');
let pillTimer = 0;
function notify(tone, ic, html) {
  pill.dataset.tone = tone;
  pill.querySelector('.pill-ic').innerHTML = icon(ic, 24);
  pill.querySelector('.pill-text').innerHTML = html;
  pill.classList.add('show');
  document.body.classList.add('pill-on');
  clearTimeout(pillTimer);
  pillTimer = setTimeout(() => { pill.classList.remove('show'); document.body.classList.remove('pill-on'); }, 3800);
}

// ------------------------------------------------------------------ resources (the `system` topic: every 2 s)
const sys = { cpu: 0.23, ram: 19.4, ramTotal: 31.3, gpu: 0.12, cpuTemp: 54, gpuTemp: 41 };
function setGauge(id, frac, text, sub) {
  const g = $(id);
  g.querySelector('.arc').style.strokeDasharray = `${Math.max(0.5, frac * 100).toFixed(1)} 100`;
  g.querySelector('.pct').innerHTML = `${Math.round(frac * 100)}<small>%</small>`;
  g.querySelector('.gs').textContent = sub;
  g.classList.toggle('hot', frac > 0.85);
  void text;
}
function renderSys() {
  setGauge('#g-cpu', sys.cpu, '', `${Math.round(sys.cpuTemp)} °C`);
  setGauge('#g-ram', sys.ram / sys.ramTotal, '', `${sys.ram.toFixed(1)} / ${Math.round(sys.ramTotal)} GB`);
  setGauge('#g-gpu', sys.gpu, '', `${Math.round(sys.gpuTemp)} °C · 1,2 GB`);
}
const walk = (v, lo, hi, step) => Math.min(hi, Math.max(lo, v + (Math.random() - 0.5) * step));

// ------------------------------------------------------------------ jobs (the `jobs` topic: every 3 s)
const MIN = 60000;
let jobs = [];
function resetJobs() {
  const now = Date.now();
  jobs = [
    { id: 'j1', name: 'flutter build apk --release', sub: 'limited.sh · app', startedAt: now - 12 * MIN - 20000, cpu: 1.84, icon: 'terminal' },
    { id: 'j2', name: 'hyperframes render --gpu', sub: 'arkaplan · tanıtım videosu', startedAt: now - 4 * MIN, cpu: 0.92, icon: 'play' },
    { id: 'j3', name: 'vitest run', sub: 'agent · 412 test', state: 'done', doneAt: now - 2 * MIN, durationSec: 48, icon: 'check' },
  ];
}
const fmtDur = (ms) => { const m = Math.floor(ms / MIN); return m < 1 ? `${Math.round(ms / 1000)} sn` : m < 60 ? `${m} dk` : `${Math.floor(m / 60)} sa ${m % 60} dk`; };
function renderJobs() {
  const now = Date.now();
  const running = jobs.filter((j) => !j.state);
  $('#jobs-aside').textContent = running.length ? `${running.length} çalışıyor` : 'iş yok';
  $('#hdr-jobs .lbl').textContent = `${running.length} iş`;
  $('#jobs').innerHTML = jobs.map((j) => {
    const right = !j.state
      ? `<div class="jt">${fmtDur(now - j.startedAt)}</div><div class="jc">${Math.round(j.cpu * 100)} % CPU</div><div class="cpu-bar"><i style="transform:scaleX(${Math.min(1, j.cpu / 4).toFixed(3)})"></i></div>`
      : j.state === 'done'
        ? `<div class="jt">bitti · ${j.durationSec} sn</div><div class="jc">${rel(j.doneAt)}</div>`
        : `<div class="jt">başarısız · çıkış ${j.exitCode}</div><div class="jc">${rel(j.doneAt)}</div>`;
    return `<div class="job ${j.state ?? ''}"><div class="jb">${icon(j.state === 'fail' ? 'x' : j.state === 'done' ? 'check' : j.icon, 20)}</div>
      <div style="min-width:0"><div class="jn">${j.name}</div><div class="js">${j.sub}</div></div><div class="jr">${right}</div></div>`;
  }).join('');
}

// ------------------------------------------------------------------ git (the `git` topic: on .git changes)
let git;
const rel = (at) => { const m = Math.max(0, Math.round((Date.now() - at) / MIN)); return m < 1 ? 'şimdi' : m < 60 ? `${m} dk önce` : m < 1440 ? `${Math.floor(m / 60)} sa önce` : `${Math.floor(m / 1440)} gün önce`; };
function renderGit() {
  $('#git-root').textContent = git.root;
  $('#git-branch').textContent = git.branch;
  $('#git-ahead').textContent = `↑${git.ahead}`;
  $('#git-ahead').classList.toggle('on', git.ahead > 0);
  $('#git-behind').textContent = `↓${git.behind}`;
  $('#git-changed').textContent = git.changed;
  $('#git-changed').parentElement.className = `gc${git.changed ? ' warn' : ''}`;
  $('#git-conflicts').parentElement.className = `gc${git.conflicts ? ' bad' : ''}`;
  $('#git-untracked').textContent = git.untracked;
  $('#git-conflicts').textContent = git.conflicts;
  $('#commits').innerHTML = git.commits.slice(0, 3).map((c, i) =>
    `<div class="commit${c.fresh && i === 0 ? ' fresh' : ''}"><span class="h">${c.hash7}</span><span class="s"></span><span class="t">${rel(c.at)}</span></div>`).join('');
  [...$('#commits').querySelectorAll('.s')].forEach((el, i) => { el.textContent = git.commits[i].subject; });
}

// ------------------------------------------------------------------ music (progress every 2 s; no spectrum)
const mu = { pos: 71, dur: 238 };
function renderMusic() {
  const el = $('#mu-progress');
  el.querySelector('.fill').style.transform = `scaleX(${(mu.pos / mu.dur).toFixed(4)})`;
  el.querySelector('.pos').textContent = `${Math.floor(mu.pos / 60)}:${String(Math.floor(mu.pos % 60)).padStart(2, '0')}`;
}

// ------------------------------------------------------------------ city
const data = await (await fetch('city.json')).json();
git = structuredClone(data.git);
// One file that doesn't exist yet: rises during the replay ("new file").
const NEW_FILE = 'display/cards/city.js';
data.files.push([NEW_FILE, 240, 'code']);
const city = createCity($('#city'), $('#orb-labels'), { files: data.files, hidden: [NEW_FILE] });

$('#ci-root').textContent = data.root;
$('#hdr-title').innerHTML = `${data.root}<span class="arrow">›</span>${git.branch}`;
$('#ci-files').textContent = `${nf.format(data.files.length - 1)} dosya`;
$('#ci-lines').textContent = `${nf.format(data.files.reduce((a, f) => a + (f[0] === NEW_FILE ? 0 : f[1]), 0))} satır`;
$('#city-legend').innerHTML = Object.values(KINDS).map((k) => `<span><i style="background:${k.color}"></i>${k.label}</span>`).join('');

city.addSession({ id: 's1', name: 'tiphys · ekran modları', status: 'running' });
city.addSession({ id: 's2', name: 'velour · çalma listesi', status: 'running' });
city.addSession({ id: 's3', name: 'belgeler', status: 'idle' });
const sessionCount = () => 3;
$('#hdr-claude .lbl').textContent = `${sessionCount()} Claude oturumu`;

// File tag above a building (edit/read/new), positioned once (the camera doesn't move).
function tag(path, kind, ms) {
  const p = city.screenOf(path);
  if (!p) return;
  const el = document.createElement('div');
  el.className = `file-tag ${kind}`;
  el.innerHTML = icon(kind === 'new' ? 'filePlus' : kind === 'read' ? 'code' : 'pencil', 15);
  el.append(shortPath(path, 46));
  el.style.transform = `translate(${p.x.toFixed(0)}px, ${(p.y - 12).toFixed(0)}px) translate(-50%, -100%)`;
  $('#file-tags').append(el);
  requestAnimationFrame(() => el.classList.add('on'));
  setTimeout(() => { el.classList.remove('on'); setTimeout(() => el.remove(), 450); }, ms);
}

// ------------------------------------------------------------------ diff layer
const layer = $('#diff-layer');
let tab = Number(qs.get('tab') ?? 0), waitTimer = 0, scrollTimer = 0;
function renderTabs() {
  $('#d-tabs').innerHTML = PENDING.map((p, i) => `<button class="d-tab${i === tab ? ' on' : ''}" data-i="${i}"><span class="dot"></span>${p.tool}<code>${p.tool === 'Bash' ? p.command.split(' ')[0] : p.path.split('/').pop()}</code></button>`).join('');
  for (const b of $('#d-tabs').children) b.onclick = () => { tab = Number(b.dataset.i); renderPending(); };
}
function renderPending() {
  renderTabs();
  const p = PENDING[tab];
  const c = $('#d-content');
  clearTimeout(scrollTimer);
  let head;
  if (p.tool === 'Bash') {
    head = `<div class="d-head"><div class="d-orb">${icon('terminal', 24)}</div><div class="d-titles"><div class="d-session">${p.session}<span class="d-tool">Bash</span></div><div class="d-path sans">Komut çalıştırma izni</div></div></div>`;
    c.style.cssText = 'flex:1;min-height:0;display:flex;flex-direction:column';
    c.innerHTML = `${head}<div class="bash"><div class="k">KOMUT</div><div class="cmd"><span class="pr">$</span></div>
      <div class="k">GEREKÇE</div><div class="reason"></div><div class="meta"><div class="chip">${icon('code', 16)}<span>${p.cwd}</span></div><div class="chip">${icon('sparkle', 16)}<span>Tiphys oturumu</span></div></div></div>`;
    c.querySelector('.cmd').append(p.command);
    c.querySelector('.reason').textContent = p.reason;
  } else {
    let added = 0, removed = 0;
    for (const h of p.hunks) for (const l of h.lines) { if (l[0] === '+') added++; else if (l[0] === '-') removed++; }
    const dir = p.path.includes('/') ? p.path.slice(0, p.path.lastIndexOf('/') + 1) : '';
    head = `<div class="d-head"><div class="d-orb">${icon('pencil', 22)}</div><div class="d-titles"><div class="d-session">${p.session}<span class="d-tool">${p.tool}</span></div>
      <div class="d-path"><span class="dir">${dir}</span>${p.path.slice(dir.length)}</div></div><div class="d-stat"><span class="a">+${added}</span><span class="r">−${removed}</span></div></div>`;
    c.style.cssText = 'flex:1;min-height:0;display:flex;flex-direction:column';
    c.innerHTML = `${head}<div class="d-body"><div class="d-rows">${renderDiff(p)}</div></div>`;
    autoScroll(c.querySelector('.d-body'), c.querySelector('.d-rows'));
  }
  let w = p.waitingSec;
  const paint = () => { $('#d-wait').textContent = `${w} sn'dir bekliyor`; };
  paint();
  clearInterval(waitTimer);
  waitTimer = setInterval(() => { w++; paint(); }, 1000);
}
// Long diffs move by ~60 % of the visible height every 5 s (a 0.9 s transform), then back to the top.
function autoScroll(body, rows) {
  let y = 0;
  const step = () => {
    const max = rows.scrollHeight - body.clientHeight + 40;
    if (max <= 0) return;
    y = y >= max ? 0 : Math.min(max, y + body.clientHeight * 0.6);
    rows.style.transform = `translateY(${-y}px)`;
    scrollTimer = setTimeout(step, y === 0 ? 6000 : 5000);
  };
  scrollTimer = setTimeout(step, 5000);
}
function openDiff() {
  const snap = city.blurredSnapshot();
  const bg = $('#diff-bg');
  bg.width = snap.width; bg.height = snap.height;
  bg.getContext('2d').drawImage(snap, 0, 0);
  renderPending();
  layer.classList.add('on');
  setTimeout(() => city.pause(), 500); // nothing behind the card needs drawing
}
function closeDiff() {
  city.resume();
  layer.classList.remove('on');
  clearInterval(waitTimer); clearTimeout(scrollTimer);
}

// ------------------------------------------------------------------ data timers
resetJobs();
renderSys(); renderJobs(); renderGit(); renderMusic();
every(2000, () => {
  const busy = jobs.some((j) => !j.state && j.id === 'j1');
  sys.cpu = walk(sys.cpu, busy ? 0.28 : 0.06, busy ? 0.55 : 0.22, 0.08);
  sys.ram = walk(sys.ram, 17.5, 22, 0.4);
  sys.gpu = walk(sys.gpu, 0.04, 0.4, 0.08);
  sys.cpuTemp = walk(sys.cpuTemp, 46, 68, 2);
  renderSys();
  mu.pos = (mu.pos + 2) % mu.dur;
  renderMusic();
});
every(3000, () => { for (const j of jobs) if (!j.state) j.cpu = walk(j.cpu, 0.6, 3.6, 0.5); renderJobs(); });

// ------------------------------------------------------------------ replay
const has = (p) => city.has(p);
const pick = (...ps) => ps.find(has) ?? ps[0];
const F = {
  source: pick('agent/src/gamemode/source.ts'),
  displayTs: pick('agent/src/gamemode/display.ts'),
  music: pick('display/music.js'),
  mainJs: pick('display/main.js'),
  appCss: pick('display/app.css'),
  ambient: pick('display/ambient.js'),
  card: pick('app/lib/features/gamemode/gamemode_card.dart'),
  docs: pick('docs/features/game-mode.md', 'README.md'),
};
const read = (s, p) => { city.beam(s, p, 'read'); tag(p, 'read', 1700); };
const edit = (s, p) => { city.beam(s, p, 'edit'); tag(p, 'edit', 3200); };

const SCRIPT = [
  [1.0, () => read('s1', F.source)],
  [2.6, () => read('s1', F.displayTs)],
  [4.2, () => read('s2', F.music)],
  [6.0, () => edit('s1', F.source)],
  [9.0, () => edit('s2', F.music)],
  [12.0, () => { city.rise(NEW_FILE); tag(NEW_FILE, 'new', 3200); git.untracked++; renderGit(); }],
  [16.0, () => {
    const j = jobs.find((x) => x.id === 'j1');
    Object.assign(j, { state: 'fail', exitCode: 1, doneAt: Date.now() });
    renderJobs(); city.alarm(2000);
    notify('danger', 'x', `<b>İş başarısız</b><span class="sub">flutter build apk · çıkış 1 · 12 dk</span>`);
  }],
  [21.0, () => {
    city.burst();
    git.commits.unshift({ hash7: 'a3e91c4', subject: 'screen: Topic subscriptions per source (W1)', at: Date.now(), fresh: true });
    git.ahead++; git.changed = 0; renderGit();
    notify('success', 'commit', `<b>Commit</b><span class="sub">a3e91c4 · screen: Topic subscriptions per source</span>`);
  }],
  [25.0, () => read('s1', F.mainJs)],
  [26.4, () => read('s1', F.appCss)],
  [28.0, () => read('s3', F.docs)],
  [30.0, () => {
    city.setStatus('s1', 'waiting');
    notify('warning', 'hourglass', `<b>Onay bekliyor</b><span class="sub">tiphys · ekran modları · Edit source.ts</span>`);
  }],
  [31.2, () => { tab = 0; openDiff(); }],
  [41.0, () => {
    closeDiff(); city.setStatus('s1', 'running');
    notify('success', 'check', `<b>Onaylandı</b><span class="sub">telefondan · Edit source.ts</span>`);
  }],
  [42.2, () => { edit('s1', F.source); git.changed++; renderGit(); }],
  [46.0, () => edit('s2', F.ambient)],
  [50.0, () => read('s1', F.card)],
  [53.0, () => { const j = jobs.find((x) => x.id === 'j2'); Object.assign(j, { state: 'done', durationSec: 312, doneAt: Date.now() }); renderJobs();
    notify('success', 'check', `<b>İş bitti</b><span class="sub">hyperframes render · 5 dk 12 sn</span>`); }],
];
const LOOP = 64;

function runReplay() {
  for (const [t, fn] of SCRIPT) setTimeout(fn, t * 1000);
  setTimeout(() => { resetJobs(); renderJobs(); git = structuredClone(data.git); git.untracked++; renderGit(); runReplay(); }, LOOP * 1000);
}
if (REPLAY) setTimeout(runReplay, 800);
if (STATE === 'diff') {
  city.setStatus('s1', 'waiting');
  setTimeout(openDiff, 600);
}

// ------------------------------------------------------------------ perf overlay (?perf)
if (qs.has('perf')) {
  const el = $('#perf'); el.hidden = false;
  let last = 0;
  setInterval(() => { const f = city.sched.stats.frames; el.textContent = `${f - last} fps · ${f} kare`; last = f; }, 1000);
}
window.__city = city;
