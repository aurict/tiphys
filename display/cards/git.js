// Git card (PLAN.md §20 E-2): the selected project's branch, ahead/behind, changed/untracked/conflict counts, the
// last 3 commits and (setting on) the CI dot. The source sends only the root's basename and no file paths. A new head
// commit → notification pill; the view title becomes "proje › dal". Relative times are redrawn once a minute.
import { icon } from '../icons.js';
import { everyMinute } from '../sched.js';
import { eventCopy } from '../notify.js';
import { cardFrame, relTime, sourceGate } from './common.js';

const NONE = {
  noProject: ['Proje seçilmedi', 'Bir Claude oturumu açınca ya da terminalde bir depoya geçince kendiliğinden seçilir; telefondan sabit bir proje de seçilebilir.'],
  notRepo: ['Git deposu değil', 'Seçilen klasörde .git yok.'],
  notAllowed: ['Bu klasöre izin yok', 'Sabit proje, ajanın izinli klasörlerinden birinde olmalı.'],
};
const CI = { ok: 'CI geçti', fail: 'CI başarısız', running: 'CI çalışıyor', none: 'CI yok' };

export function mount(el, ctx, { src = 'self' } = {}) {
  const f = cardFrame(el, { cls: 'git-card', label: 'Git', ic: 'branch' });
  f.body.innerHTML = `<div class="git-top"><div class="branch">${icon('branch', 19)}<span class="bn"></span></div>
    <div class="ab"><span class="up"></span><span class="down"></span></div>
    <div class="git-counts"><div class="gc gc-ch"><b></b><span>değişti</span></div><div class="gc gc-un"><b></b><span>yeni</span></div><div class="gc gc-co"><b></b><span>çakışma</span></div></div></div>
    <div class="commits"></div>`;
  const $ = (s) => f.body.querySelector(s);
  let last = null;
  const gate = sourceGate(src, () => last ? draw(last) : f.setState(gate.down ? 'down' : 'connecting', gate.down ? 'Kaynağa ulaşılamıyor' : 'Bağlanıyor…'));
  const minute = everyMinute(() => last?.commits && drawCommits(last.commits));

  function drawCommits(commits) {
    const now = Date.now();
    $('.commits').replaceChildren(...commits.slice(0, 3).map((c) => {
      const r = document.createElement('div');
      r.className = `commit${now - c.at < 10 * 60_000 ? ' fresh' : ''}`;
      r.innerHTML = '<span class="h"></span><span class="s"></span><span class="t"></span>';
      r.children[0].textContent = c.hash7;
      r.children[1].textContent = c.subject;
      r.children[2].textContent = relTime(c.at, now);
      return r;
    }));
  }

  function draw(m) {
    const prev = last;
    last = m;
    if (m.none) {
      const [t, s] = NONE[m.none] ?? NONE.notRepo;
      f.aside.textContent = m.root ?? '';
      ctx.title?.(null);
      return f.setState('empty', t, s);
    }
    f.aside.innerHTML = '<span class="root"></span>';
    f.aside.firstChild.textContent = m.root;
    if (m.ci) {
      const ci = document.createElement('span');
      ci.className = `ci ci-${m.ci.state}`;
      ci.title = CI[m.ci.state] ?? '';
      ci.innerHTML = `<i></i>${CI[m.ci.state] ?? ''}`;
      f.aside.prepend(ci);
    }
    $('.bn').textContent = m.branch ?? `ayrık · ${m.head ?? '–'}`;
    $('.up').textContent = `↑${m.ahead}`;
    $('.up').classList.toggle('on', m.ahead > 0);
    $('.down').textContent = `↓${m.behind}`;
    $('.down').classList.toggle('on', m.behind > 0);
    $('.ab').hidden = !m.upstream;
    $('.gc-ch b').textContent = m.changed;
    $('.gc-un b').textContent = m.untracked;
    $('.gc-co b').textContent = m.conflicts;
    $('.gc-ch').classList.toggle('warn', m.changed > 0);
    $('.gc-co').classList.toggle('bad', m.conflicts > 0);
    drawCommits(m.commits ?? []);
    if (!m.commits?.length) $('.commits').innerHTML = '<div class="commit none">Henüz commit yok</div>';
    ctx.title?.(m.root, m.branch);
    // A new head commit on the same project (not the first message, not a branch switch).
    const top = m.commits?.[0];
    if (prev && !prev.none && prev.root === m.root && prev.branch === m.branch && top && !(prev.commits ?? []).some((c) => c.hash7 === top.hash7)) {
      ctx.pill(eventCopy({ kind: 'commit', detail: top.subject }));
    }
    f.setState(gate.down ? 'down' : 'ready', gate.down ? 'Kaynağa ulaşılamıyor' : '', gate.down ? 'Son bilinen durum' : '');
  }

  return {
    update(m) {
      if (!gate.mine(m)) return;
      if (m.type === 'git') draw(m);
    },
    pause() { minute.pause(); },
    resume() { minute.resume(); },
    destroy() { minute.stop(); ctx.title?.(null); f.card.remove(); },
  };
}
