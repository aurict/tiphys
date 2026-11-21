// İşler card (PLAN.md §20 E-2): long-running jobs of the source (arkaplan scopes, limited.sh, known build/test
// processes) with elapsed time and CPU, and the finished ones for 2 minutes. `jobs` replaces the running list;
// `jobDone` adds a finished row and a notification pill. Elapsed times are redrawn every 15 s only while a row shows;
// paused → no timer. Long commands keep their end visible (middle ellipsis).
import { icon } from '../icons.js';
import { eventCopy } from '../notify.js';
import { cardFrame, fmtBytes, fmtElapsed, midText, relTime, sourceGate, ticker } from './common.js';

const KEEP_MS = 2 * 60_000;
const MAX_ROWS = 4;
const VIA = { scope: 'arkaplan', limited: 'limited.sh', proc: 'süreç', tiphys: 'Tiphys' };

export function mount(el, ctx, { src = 'self' } = {}) {
  const f = cardFrame(el, { cls: 'jobs-card', label: 'İşler', ic: 'terminal' });
  f.body.innerHTML = '<div class="jobs"></div><div class="jobs-more"></div>';
  const list = f.body.querySelector('.jobs'), more = f.body.querySelector('.jobs-more');
  let running = null; // null until the first message
  let done = [];      // {id, name, cmd, kind, durationSec, exitCode, at}
  const gate = sourceGate(src, () => render());
  const tick = ticker(15_000, () => render(), () => (running?.length ?? 0) + done.length > 0);

  function row(j, fin) {
    const fail = fin && j.exitCode != null && j.exitCode !== 0;
    const r = document.createElement('div');
    r.className = `job${fin ? (fail ? ' fail' : ' done') : ''}`;
    const ic = fin ? (fail ? 'x' : 'check') : j.kind === 'scope' ? 'play' : 'terminal';
    r.innerHTML = `<div class="jb">${icon(ic, 20)}</div><div class="jm"><div class="jn"></div><div class="js"></div></div><div class="jr"><div class="jt"></div><div class="jc"></div>${fin ? '' : '<div class="cpu-bar"><i></i></div>'}</div>`;
    midText(r.querySelector('.jn'), j.cmd || j.name, 18);
    r.querySelector('.js').textContent = [VIA[j.kind] ?? j.kind, j.dir, j.cmd && j.name && !j.cmd.startsWith(j.name) ? j.name : null].filter(Boolean).join(' · ');
    const now = Date.now();
    if (fin) {
      r.querySelector('.jt').textContent = fail ? `başarısız · çıkış ${j.exitCode}` : `bitti · ${fmtElapsed(j.durationSec)}`;
      r.querySelector('.jc').textContent = relTime(j.at, now);
    } else {
      r.querySelector('.jt').textContent = fmtElapsed((now - j.startedAt) / 1000);
      r.querySelector('.jc').textContent = `${Math.round(j.cpu * 100)} % CPU · ${fmtBytes(j.mem)}`;
      r.querySelector('.cpu-bar i').style.transform = `scaleX(${Math.min(1, j.cpu / 4).toFixed(3)})`;
    }
    return r;
  }

  function render() {
    const now = Date.now();
    done = done.filter((d) => now - d.at < KEEP_MS);
    if (gate.down && running === null) return f.setState('down', 'Kaynağa ulaşılamıyor', 'İşler, kaynak bilgisayar geri gelince görünür');
    if (running === null) return f.setState('connecting', 'Bağlanıyor…');
    const rows = [...running.map((j) => row(j, false)), ...done.map((j) => row(j, true))];
    list.replaceChildren(...rows.slice(0, MAX_ROWS));
    more.textContent = rows.length > MAX_ROWS ? `+${rows.length - MAX_ROWS} iş daha` : '';
    f.aside.textContent = running.length ? `${running.length} çalışıyor` : done.length ? 'hepsi bitti' : '';
    if (gate.down) f.setState('down', 'Kaynağa ulaşılamıyor', 'Son bilinen durum');
    else if (!rows.length) f.setState('empty', 'Uzun süren iş yok', 'arkaplan, limited.sh ve 30 sn’yi geçen derleme/test işleri burada görünür');
    else f.setState('ready');
    tick.arm();
  }

  return {
    update(m) {
      if (!gate.mine(m)) return;
      if (m.type === 'jobs') {
        running = Array.isArray(m.running) ? m.running : [];
        render();
      } else if (m.type === 'jobDone') {
        running = (running ?? []).filter((j) => j.id !== m.id);
        done = [{ ...m, at: Date.now() }, ...done.filter((d) => d.id !== m.id)];
        const fail = m.exitCode != null && m.exitCode !== 0;
        ctx.pill(eventCopy({ kind: fail ? 'jobFail' : 'jobDone', detail: m.name || m.cmd, durationSec: m.durationSec, exitCode: m.exitCode }));
        render();
      }
    },
    pause() { tick.pause(); },
    resume() { tick.resume(); render(); },
    destroy() { tick.stop(); f.card.remove(); },
  };
}
