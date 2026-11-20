// Inline SVG icons (drawn for this page; 24×24, 2 px rounded strokes like the app's Lucide set).
const P = {
  music: '<path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
  fine: '<path d="M12 3 2.5 20h19L12 3Z"/><path d="M12 10v4.5"/><path d="M12 17.5h.01"/>',
  ferry: '<path d="M3 16.5c1.5 1.3 3 1.3 4.5 0s3-1.3 4.5 0 3 1.3 4.5 0 3-1.3 4.5 0"/><path d="M5 14 4 10h16l-1 4"/><path d="M8 10V6h8v4"/><path d="M12 6V3"/>',
  train: '<rect x="5" y="3" width="14" height="13" rx="3"/><path d="M5 10h14"/><path d="M8.5 13.2h.01M15.5 13.2h.01"/><path d="m8 20-2 2M16 20l2 2M8 16l-1 4h10l-1-4"/>',
  toll: '<path d="M4 21V9"/><path d="M4 9h16"/><path d="M8 9V5h8v4"/><path d="M20 9v12"/><path d="M4 14h16"/>',
  delivered: '<circle cx="12" cy="12" r="9"/><path d="m8 12.3 2.7 2.7L16 9.7"/>',
  cancelled: '<circle cx="12" cy="12" r="9"/><path d="m9 9 6 6M15 9l-6 6"/>',
  fuel: '<path d="M4 21V5a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v16"/><path d="M3 21h12"/><path d="M4 10h10"/><path d="M14 8h2a2 2 0 0 1 2 2v6a1.5 1.5 0 0 0 3 0V8l-3-3"/>',
  rest: '<path d="M17 8h1a3 3 0 0 1 0 6h-1"/><path d="M3 8h14v6a5 5 0 0 1-5 5H8a5 5 0 0 1-5-5V8Z"/><path d="M7 2v2M11 2v2"/>',
  linkOff: '<path d="M9 15 15 9"/><path d="m11 6 1.5-1.5a4.2 4.2 0 0 1 6 6L17 12"/><path d="m7 12-1.5 1.5a4.2 4.2 0 0 0 6 6L13 18"/><path d="M3 3l18 18"/>',
  link: '<path d="M9 15 15 9"/><path d="m11 6 1.5-1.5a4.2 4.2 0 0 1 6 6L17 12"/><path d="m7 12-1.5 1.5a4.2 4.2 0 0 0 6 6L13 18"/>',
  truck: '<path d="M2 6h11v10H2z"/><path d="M13 9h4l4 4v3h-8"/><circle cx="6.5" cy="17.5" r="2"/><circle cx="16.5" cy="17.5" r="2"/>',
  flag: '<path d="M5 21V4"/><path d="M5 4h11l-2 4 2 4H5"/>',
  route: '<circle cx="6" cy="19" r="2.5"/><circle cx="18" cy="5" r="2.5"/><path d="M8.5 19H15a3.5 3.5 0 0 0 0-7H9a3.5 3.5 0 0 1 0-7h6.5"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  coins: '<ellipse cx="9" cy="7" rx="6" ry="3"/><path d="M3 7v5c0 1.7 2.7 3 6 3s6-1.3 6-3V7"/><path d="M9 15v3c0 1.7 2.7 3 6 3s6-1.3 6-3v-5c0-1.6-2.4-2.9-5.5-3"/>',
  cruise: '<path d="M4.5 16a8 8 0 1 1 15 0"/><path d="m12 13 4-4"/><path d="M12 13h.01"/>',
  parking: '<rect x="3" y="3" width="18" height="18" rx="5"/><path d="M9.5 17V7H13a3 3 0 0 1 0 6H9.5"/>',
  beam: '<path d="M10 5C6 5 4 8.2 4 12s2 7 6 7c1.3 0 2-1.6 2-7s-.7-7-2-7Z"/><path d="M15 7h6M15 12h6M15 17h6"/>',
  highBeam: '<path d="M10 5C6 5 4 8.2 4 12s2 7 6 7c1.3 0 2-1.6 2-7s-.7-7-2-7Z"/><path d="M15 6h6M15 10h6M15 14h6M15 18h6"/>',
  wrench: '<path d="M14.7 6.3a4 4 0 0 0 5 5L21 13l-8 8a2.8 2.8 0 0 1-4-4l8-8-1.3-1.3Z" transform="translate(-2 -2)"/>',
  beacon: '<path d="M7 18v-5a5 5 0 0 1 10 0v5"/><path d="M5 18h14v3H5z"/><path d="M12 3v2M4.5 6l1.4 1.4M19.5 6l-1.4 1.4"/>',
  box: '<path d="m3 7.5 9-4.5 9 4.5v9L12 21l-9-4.5v-9Z"/><path d="m3 7.5 9 4.5 9-4.5"/><path d="M12 12v9"/>',
  plug: '<path d="M9 2v6M15 2v6"/><path d="M6 8h12v4a6 6 0 0 1-12 0V8Z"/><path d="M12 18v4"/>',
  power: '<path d="M12 3v9"/><path d="M6.3 6.6a8 8 0 1 0 11.4 0"/>',
  gauge: '<path d="M4.5 17a8.5 8.5 0 1 1 15 0"/><path d="m12 14 3.5-5"/>',
};

/** SVG markup for an icon name (falls back to the music note). */
export function icon(name, size = 22, extra = '') {
  return `<svg class="ic" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true" ${extra}>${P[name] ?? P.music}</svg>`;
}
