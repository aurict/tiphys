// Görev card (PLAN.md §20 "Ek önerilerim" 2, W5): the one line "what am I doing now" from the phone, big under the
// timer. It comes with the agent's `focus` message (memory only there; gone when the mode stops). Hidden without a
// task and during a break (the break card shows it as "Sonra: …"). Long text ends with an ellipsis on one line.
export function mount(el) {
  const card = document.createElement('div');
  card.className = 'f-task';
  card.hidden = true;
  card.innerHTML = '<div class="overline">ŞU AN</div><div class="f-task-t"></div>';
  el.append(card);
  const t = card.querySelector('.f-task-t');
  return {
    update(m) {
      if (m.type !== 'focus') return;
      const task = typeof m.task === 'string' && m.task ? m.task : null;
      card.hidden = !task || m.phase === 'short' || m.phase === 'long';
      t.textContent = task ?? '';
      t.title = task ?? '';
    },
    pause() {},
    resume() {},
    destroy() { card.remove(); },
  };
}
