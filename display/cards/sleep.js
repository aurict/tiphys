// Sleep mode card (PLAN.md §21 S2): the agent's side of the sleep view. The agent sends `sleep` (session, plan,
// phase, content brightness, settings), `phase` and `brightness` messages; this card mounts the S1 view
// (display/sleep/sleep.js: embers + sound, built from the same plan) and dims it by the content multiplier (opacity of
// a black-backed layer: the hardware dims the rest, see agent/src/screen/sleep.ts). It sends `heartbeat` every 10 s
// (the agent's WAV fallback in S4 listens for it) and `stop` when the view's Esc hold fires.
// The S1 view is imported on demand; if it can't be loaded the card shows a quiet placeholder with the phase and the
// brightness.
// Group (S3): the view gets every member's place (`session.layout`), this host's id (`me`) and the shared clock: this
// host's Date.now() + `offsetMs` (the leader's clock, measured by the agent; 0 unless it's off by more than 20 ms). A
// new offset changes the clock in place (no rebuild: the sound keeps playing). Test only (`syncLog` in the message,
// TIPHYS_SLEEP_SYNCLOG on the agent): the scheduled and drawn crackles go back as `syncLog` lines.
// TODO(S4): the view taking `phase` messages for snooze / dismiss; a brightness setter on the view instead of the
// layer opacity.
// mount(el, ctx) → { update(msg), pause(), resume(), destroy() }.
const HEARTBEAT_MS = 10_000;
const PHASE_TR = { settle: 'Yerleşme', fade: 'Sönüş', night: 'Gece', sunrise: 'Gün doğumu', ring: 'Alarm', snoozed: 'Ertelendi', morning: 'Sabah' };

let s1 = null; // the S1 module: a promise of it (null after a failed load: placeholder)
function loadView() {
  s1 ??= import('../sleep/sleep.js').catch(() => null);
  return s1;
}

export function mount(el, ctx) {
  const card = document.createElement('div');
  card.className = 'sleep-card';
  card.style.cssText = 'position:fixed;inset:0;background:#000;cursor:none;';
  const layer = document.createElement('div');
  layer.style.cssText = 'position:absolute;inset:0;opacity:1;transition:opacity 2s linear;';
  const placeholder = document.createElement('div');
  placeholder.setAttribute('role', 'status');
  placeholder.style.cssText = 'position:absolute;left:50%;top:50%;transform:translate(-50%,-50%);color:#A0581F;font-size:28px;text-align:center;';
  placeholder.hidden = true;
  card.append(layer);
  layer.append(placeholder);
  el.append(card);

  let msg = null;        // the latest `sleep` message, phase fields kept current
  let key = null;        // what the mounted view was built from
  let view = null;
  let css = null;
  let paused = false, destroyed = false;
  let content = 1;
  let offset = 0;        // shared clock = Date.now() + offset
  let trace = [];        // syncLog lines waiting to be sent (test only)

  const send = (m) => ctx.send?.(m);
  send({ type: 'heartbeat' });
  const beat = setInterval(() => send({ type: 'heartbeat' }), HEARTBEAT_MS);
  const flush = setInterval(() => {
    while (trace.length) send({ type: 'syncLog', lines: trace.splice(0, 16) });
  }, 2000);

  function drawPlaceholder() {
    if (!msg) return;
    placeholder.textContent = `Uyku · ${PHASE_TR[msg.phase] ?? msg.phase} · parlaklık %${Math.round(content * 100)}`;
  }

  async function build() {
    const k = JSON.stringify([msg.session, msg.plan, msg.me, msg.settings, msg.syncLog === true]);
    if (k === key) return;
    key = k;
    const mod = await loadView();
    if (destroyed || k !== key) return;
    view?.destroy();
    view = null;
    if (!mod) {
      placeholder.hidden = false;
      drawPlaceholder();
      return;
    }
    if (!css) {
      css = document.createElement('link');
      css.rel = 'stylesheet';
      css.href = 'sleep/sleep.css';
      document.head.append(css);
    }
    document.body.classList.add('sleep-view');
    placeholder.hidden = true;
    view = mod.mount(layer, ctx, {
      session: { seed: msg.session.seed, t0: msg.session.t0, members: msg.session.layout },
      plan: msg.plan,
      me: msg.me,
      now: () => Date.now() + offset,
      offsetMs: () => offset,
      brightness: 1,
      audio: true,
      volume: msg.settings?.volume ?? 35,
      layers: msg.settings?.layers ?? {},
      onStop: () => send({ type: 'stop' }),
      onAlarm: () => {}, // S4
      trace: msg.syncLog === true ? (line) => { if (trace.length < 2000) trace.push(line); } : null,
    });
    if (paused) view.pause();
  }

  function setContent(v) {
    if (typeof v !== 'number' || !Number.isFinite(v)) return;
    content = Math.max(0, Math.min(1, v));
    layer.style.opacity = String(content);
    drawPlaceholder();
  }

  return {
    update(m) {
      if (m.type === 'sleep') {
        msg = m;
        offset = Number.isFinite(m.offsetMs) ? m.offsetMs : 0;
        setContent(m.brightness);
        void build();
      } else if (m.type === 'phase' && msg) {
        msg = { ...msg, phase: m.phase, phaseStartedAt: m.phaseStartedAt, phaseEndsAt: m.phaseEndsAt };
        drawPlaceholder();
        view?.update(m);
      } else if (m.type === 'brightness') setContent(m.content);
    },
    pause() { paused = true; view?.pause(); },
    resume() { paused = false; view?.resume(); },
    destroy() {
      destroyed = true;
      clearInterval(beat);
      clearInterval(flush);
      view?.destroy();
      view = null;
      css?.remove();
      document.body.classList.remove('sleep-view');
      card.remove();
    },
  };
}
