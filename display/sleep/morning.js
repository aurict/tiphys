// Sleep mode morning screen rows (PLAN.md §21 E-4, S5): the agent's morning summary (`morning` in the sleep message:
// the leader's merged summary, also relayed to the members) → the rows of the morning screen. Pure (runs under
// `node --test`). Without a summary yet (the leader still waiting for its members, or this member cut off from it)
// only the night's length shows, from the plan: t0 → the dismiss.

/** "7 sa 40 dk" (minutes, whole). */
export function duration(min) {
  const m = Math.max(0, Math.round(min));
  return `${Math.floor(m / 60)} sa ${m % 60} dk`;
}

const n = (v) => (Number.isFinite(v) && v > 0 ? Math.floor(v) : 0);

/**
 * {rows: [{label, value, warn}], titles: [string], note: string|null}. Rows with nothing to say are left out (a
 * quiet night is one row and a note); failures are marked `warn`.
 */
export function morningView(summary, plan, now) {
  const end = plan?.dismissedAt ?? now;
  const minutes = summary ? n(summary.minutes) : Math.max(0, (end - (plan?.t0 ?? end)) / 60000);
  const rows = [{ label: 'Uyku', value: duration(minutes), warn: false }];
  if (!summary) return { rows, titles: [], note: 'Gecenin özeti telefonunda.' };
  const jobs = n(summary.jobs), jobsFailed = n(summary.jobsFailed), backups = n(summary.backups), backupsFailed = n(summary.backupsFailed);
  const incidents = n(summary.incidents), held = n(summary.held), missing = n(summary.missing);
  if (jobs) rows.push({ label: 'Biten işler', value: jobsFailed ? `${jobs} · ${jobsFailed} başarısız` : String(jobs), warn: jobsFailed > 0 });
  if (backups || backupsFailed) rows.push({ label: 'Yedekler', value: backupsFailed ? `${backups} tamam · ${backupsFailed} başarısız` : `${backups} tamam`, warn: backupsFailed > 0 });
  if (incidents) rows.push({ label: 'Sunucu olayları', value: String(incidents), warn: true });
  if (held) rows.push({ label: 'Bekleyen bildirimler', value: String(held), warn: false });
  const titles = held && Array.isArray(summary.titles) ? summary.titles.filter((t) => typeof t === 'string' && t.trim()).slice(0, 3).map((t) => t.trim().slice(0, 120)) : [];
  const quiet = rows.length === 1;
  const note = missing ? `${missing} makineden bilgi gelmedi.` : quiet ? 'Sakin bir gece: iş, yedek, olay yok.' : null;
  return { rows, titles, note };
}
