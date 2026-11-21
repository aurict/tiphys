// Turkish formatting helpers (numbers, money, clock, game time).
const LOCALE = 'tr-TR';
const int = new Intl.NumberFormat(LOCALE, { maximumFractionDigits: 0 });
const one = new Intl.NumberFormat(LOCALE, { maximumFractionDigits: 1, minimumFractionDigits: 0 });

export const fmtInt = (n) => (n == null || !Number.isFinite(n) ? '–' : int.format(Math.round(n)));
export const fmtOne = (n) => (n == null || !Number.isFinite(n) ? '–' : one.format(n));

/** Turkish upper case (i → İ), like the app's upper(). */
export const upper = (s) => s.toLocaleUpperCase(LOCALE);

const SYMBOL = { EUR: '€', USD: '$', GBP: '£', TRY: '₺', PLN: 'zł', CHF: 'CHF', CZK: 'Kč', HUF: 'Ft', SEK: 'kr', NOK: 'kr', DKK: 'kr' };
/** Money: the contract's `currency` may be an ISO code ("EUR") or a symbol ("€"); both read well. */
export function fmtMoney(amount, currency) {
  if (amount == null || !Number.isFinite(amount)) return '–';
  const sym = currency ? (SYMBOL[currency] ?? currency) : '€';
  const n = int.format(Math.round(amount));
  return sym.length === 1 ? `${sym}${n}` : `${n} ${sym}`;
}

/** Distance from metres: ≥ 10 km whole km, otherwise one decimal; under 1 km in metres. */
export function fmtDistance(m) {
  if (m == null || !Number.isFinite(m)) return { value: '–', unit: 'km' };
  if (m < 1000) return { value: int.format(Math.round(m / 10) * 10), unit: 'm' };
  const km = m / 1000;
  return { value: km >= 10 ? int.format(Math.round(km)) : one.format(km), unit: 'km' };
}

const pad = (n) => String(n).padStart(2, '0');

/** Wall clock "14:32" / "2:32" + optional "ÖS/ÖÖ" suffix for the 12 h setting. */
export function fmtClock(date, clock24) {
  const h = date.getHours();
  const m = pad(date.getMinutes());
  if (clock24) return { time: `${pad(h)}:${m}`, suffix: '' };
  return { time: `${h % 12 || 12}:${m}`, suffix: h < 12 ? 'ÖÖ' : 'ÖS' };
}

/** App header overline: "PERŞEMBE, 20 KASIM". */
export function fmtOverline(date) {
  const wd = date.toLocaleDateString(LOCALE, { weekday: 'long' });
  const dm = date.toLocaleDateString(LOCALE, { day: 'numeric', month: 'long' });
  return upper(`${wd}, ${dm}`);
}

const DAYS = ['Pzt', 'Sal', 'Çar', 'Per', 'Cum', 'Cmt', 'Paz'];
/** Game time (minutes since Monday 00:00 of week 1, SCS convention) → "Çar 14:20" / "Çar 2:20 ÖS". */
export function fmtGameTime(minutes, clock24, withDay = true) {
  if (minutes == null || !Number.isFinite(minutes)) return '–';
  const total = Math.floor(minutes);
  const day = DAYS[Math.floor(total / 1440) % 7];
  const h = Math.floor((total % 1440) / 60);
  const m = pad(total % 60);
  const t = clock24 ? `${pad(h)}:${m}` : `${h % 12 || 12}:${m} ${h < 12 ? 'ÖÖ' : 'ÖS'}`;
  return withDay ? `${day} ${t}` : t;
}

/** Hour of day (0..24, fractional) from game minutes. */
export const gameHour = (minutes) => ((minutes % 1440) + 1440) % 1440 / 60;

/** Duration in minutes → "3 sa 20 dk" / "45 dk". */
export function fmtDuration(min) {
  if (min == null || !Number.isFinite(min)) return '–';
  const m = Math.max(0, Math.round(min));
  if (m < 60) return `${m} dk`;
  const h = Math.floor(m / 60);
  return m % 60 ? `${h} sa ${m % 60} dk` : `${h} sa`;
}

/** Song time "3:07". */
export function fmtSongTime(s) {
  if (s == null || !Number.isFinite(s) || s < 0) return '0:00';
  const t = Math.floor(s);
  return `${Math.floor(t / 60)}:${pad(t % 60)}`;
}

/** Displayed gear: 0 = N, < 0 = R (R1, R2 when there are several reverse gears). */
export function fmtGear(g) {
  if (g == null) return '–';
  if (g === 0) return 'N';
  if (g < 0) return g === -1 ? 'R' : `R${-g}`;
  return String(g);
}
