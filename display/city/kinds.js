// File kinds of the code city (the `city` topic's third field) → one of six Tiphys tones (tokens.css: accent, host-1/2/3,
// warning, label grey). The 3D city darkens them so the accent-coloured lights stand out on top.
export const KINDS = {
  code: { color: '#A5B4FC', label: 'Kod' },
  dart: { color: '#87D4B0', label: 'Dart' },
  docs: { color: '#F4B89B', label: 'Belge' },
  config: { color: '#FFB340', label: 'Ayar' },
  web: { color: '#A39DF1', label: 'HTML / CSS' },
  other: { color: '#98989F', label: 'Diğer' },
};

export const kindColor = (k) => (KINDS[k] ?? KINDS.other).color;

/** Small stable per-path variation (0.85 … 1.15) so a district isn't one flat colour. */
export function variation(path) {
  let h = 2166136261;
  for (let i = 0; i < path.length; i++) h = Math.imul(h ^ path.charCodeAt(i), 16777619);
  return 0.85 + ((h >>> 0) % 1000) / 1000 * 0.3;
}
