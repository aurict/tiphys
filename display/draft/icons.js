// Extra icons for the screen-mode draft (24×24, 2 px rounded strokes, Lucide-like), on top of ../icons.js.
import { icon as base } from '../icons.js';

const P = {
  cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M10 10h4v4h-4z"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
  branch: '<circle cx="6" cy="5" r="2.5"/><circle cx="6" cy="19" r="2.5"/><circle cx="18" cy="7" r="2.5"/><path d="M6 7.5v9"/><path d="M18 9.5c0 4-6 3-11 7.5"/>',
  commit: '<circle cx="12" cy="12" r="3.5"/><path d="M2 12h6.5M15.5 12H22"/>',
  terminal: '<path d="m5 7 5 5-5 5"/><path d="M12 17h7"/>',
  phone: '<rect x="6" y="2.5" width="12" height="19" rx="3"/><path d="M11 18h2"/>',
  check: '<path d="m5 12.5 4.5 4.5L19 7.5"/>',
  x: '<path d="M6 6l12 12M18 6 6 18"/>',
  sparkle: '<path d="M12 3c.6 4.6 2.4 6.4 7 7-4.6.6-6.4 2.4-7 7-.6-4.6-2.4-6.4-7-7 4.6-.6 6.4-2.4 7-7Z"/><path d="M19 3v3M17.5 4.5h3"/>',
  filePlus: '<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8l-5-5Z"/><path d="M14 3v5h5"/><path d="M12 11v6M9 14h6"/>',
  pencil: '<path d="M16.5 3.5a2.1 2.1 0 0 1 3 3L8 18l-4 1 1-4 11.5-11.5Z"/>',
  droplet: '<path d="M12 3s6 6.5 6 11a6 6 0 0 1-12 0c0-4.5 6-11 6-11Z"/>',
  target: '<circle cx="12" cy="12" r="9"/><circle cx="12" cy="12" r="5"/><circle cx="12" cy="12" r="1"/>',
  code: '<path d="m8 7-5 5 5 5"/><path d="m16 7 5 5-5 5"/><path d="m14 4-4 16"/>',
  gamepad: '<path d="M6 11h4M8 9v4"/><path d="M15 12h.01M18 10h.01"/><path d="M17.3 5H6.7a4 4 0 0 0-4 3.6l-.7 6.2a3 3 0 0 0 5.4 2.1L9 15h6l1.6 1.9a3 3 0 0 0 5.4-2.1l-.7-6.2A4 4 0 0 0 17.3 5Z"/>',
  monitor: '<rect x="2.5" y="4" width="19" height="13" rx="2.5"/><path d="M8 21h8M12 17v4"/>',
  laptop: '<rect x="4" y="5" width="16" height="11" rx="2"/><path d="M2 19h20"/>',
  play: '<path d="M7 4.5v15l12.5-7.5L7 4.5Z" fill="currentColor"/>',
  square: '<rect x="6" y="6" width="12" height="12" rx="2.5" fill="currentColor"/>',
  chevron: '<path d="m9 6 6 6-6 6"/>',
  hourglass: '<path d="M6 3h12M6 21h12"/><path d="M7 3v3a5 5 0 0 0 10 0V3"/><path d="M7 21v-3a5 5 0 0 1 10 0v3"/>',
  mirror: '<rect x="2.5" y="5" width="11" height="9" rx="2"/><rect x="14.5" y="9" width="7" height="10" rx="1.5"/><path d="M6 18h4"/>',
  sliders: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
  bell: '<path d="M6 9a6 6 0 0 1 12 0c0 6 2.5 7.5 2.5 7.5h-17S6 15 6 9Z"/><path d="M10 20a2 2 0 0 0 4 0"/>',
  pause: '<path d="M8 5v14M16 5v14"/>',
  skip: '<path d="M5 5v14l10-7L5 5Z"/><path d="M19 5v14"/>',
  home: '<path d="M3 11 12 3l9 8"/><path d="M5 10v10h14V10"/>',
  server: '<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><path d="M7 7.5h.01M7 16.5h.01"/>',
};

export function icon(name, size = 22, extra = '') {
  if (!P[name]) return base(name, size, extra);
  return `<svg class="ic" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ${extra}>${P[name]}</svg>`;
}

/** Replaces every [data-icon] placeholder's content with its SVG (size from data-size). */
export function fillIcons(root = document) {
  for (const el of root.querySelectorAll('[data-icon]')) el.innerHTML = icon(el.dataset.icon, Number(el.dataset.size) || 22);
}
