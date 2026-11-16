// Tiphys logo: a ship's wheel (Tiphys = helmsman of the Argo). Generates all icon files from one source.
// Color icon: a 3D wheel on a dark background (layered thickness, soft shadow, light from the top left,
// metallic surface, spherical hub). Monochrome/notification icons are flat silhouettes (Android only uses the shape there).
// Usage: node tools/logo/logo.mjs <resvg-js module path>  → SVG + PNG under tools/logo/out/.
import { mkdirSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const here = dirname(fileURLToPath(import.meta.url));
const { Resvg } = createRequire(import.meta.url)(process.argv[2] ?? '@resvg/resvg-js');

export const BRAND = { deep: '#1E1B4B', indigo: '#4338CA', violet: '#6D5EF5', light: '#F5F5FA', peach: '#F2A985' };

const RING = 0.62;
const angles = Array.from({ length: 8 }, (_, i) => (i * Math.PI) / 4 - Math.PI / 2); // i=0 → up
const pt = (a, r) => [(r * Math.cos(a)).toFixed(4), (r * Math.sin(a)).toFixed(4)];
const line = (a, r1, r2, stroke, w, extra = '') => {
  const [x1, y1] = pt(a, r1), [x2, y2] = pt(a, r2);
  return `<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${stroke}" stroke-width="${w}" stroke-linecap="round"${extra}/>`;
};

/** Flat wheel: center (0,0), outer radius ~1. `fg` main color, `hl` color of the top spoke, `hole` hub hole. */
function wheel({ fg, hl, hole }) {
  return `
    ${angles.map((a, i) => line(a, 0.2, 0.8, fg, 0.11) + line(a, 0.8, 0.93, i === 0 ? hl : fg, 0.19)).join('\n    ')}
    <circle r="${RING}" fill="none" stroke="${fg}" stroke-width="0.16"/>
    <circle r="0.23" fill="${fg}"/>
    <circle r="0.075" fill="${hole}"/>`;
}

/** 3D wheel (unit coordinates). Gradients are in the same coordinate system (userSpaceOnUse). */
function wheel3d() {
  const defs = `
    <linearGradient id="metal" gradientUnits="userSpaceOnUse" x1="-0.7" y1="-0.95" x2="0.7" y2="0.95">
      <stop offset="0" stop-color="#FFFFFF"/><stop offset="0.35" stop-color="#E4E1FF"/>
      <stop offset="0.7" stop-color="#A9A1F7"/><stop offset="1" stop-color="#7268E8"/>
    </linearGradient>
    <linearGradient id="peach" gradientUnits="userSpaceOnUse" x1="-0.1" y1="-1" x2="0.1" y2="-0.75">
      <stop offset="0" stop-color="#FFE3CF"/><stop offset="1" stop-color="#E9895A"/>
    </linearGradient>
    <linearGradient id="side" gradientUnits="userSpaceOnUse" x1="0" y1="-1" x2="0" y2="1">
      <stop offset="0" stop-color="#4B43C7"/><stop offset="1" stop-color="#231E66"/>
    </linearGradient>
    <radialGradient id="hub" gradientUnits="userSpaceOnUse" cx="-0.07" cy="-0.08" r="0.3" fx="-0.09" fy="-0.11">
      <stop offset="0" stop-color="#FFFFFF"/><stop offset="0.45" stop-color="#CFC9FF"/>
      <stop offset="0.85" stop-color="#6E63E6"/><stop offset="1" stop-color="#4A40C9"/>
    </radialGradient>
    <radialGradient id="hole" gradientUnits="userSpaceOnUse" cx="0.02" cy="0.03" r="0.08">
      <stop offset="0" stop-color="#0B0920"/><stop offset="1" stop-color="#2A2470"/>
    </radialGradient>
    <linearGradient id="gloss" gradientUnits="userSpaceOnUse" x1="0" y1="-0.75" x2="0" y2="0.1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.9"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <filter id="soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="0.045"/></filter>`;
  // Silhouette: a single color for thickness layers and shadow
  const silhouette = (paint) => `
      ${angles.map((a) => line(a, 0.2, 0.8, paint, 0.11) + line(a, 0.8, 0.93, paint, 0.19)).join('')}
      <circle r="${RING}" fill="none" stroke="${paint}" stroke-width="0.16"/><circle r="0.23" fill="${paint}"/>`;
  const depth = 0.075, steps = 9;
  const extrusion = Array.from({ length: steps }, (_, k) => `<g transform="translate(0 ${(depth * (steps - k)) / steps})">${silhouette('url(#side)')}</g>`).join('');
  const face = `
      ${angles.map((a) => line(a, 0.2, 0.8, 'url(#metal)', 0.11)).join('')}
      <circle r="${RING}" fill="none" stroke="url(#metal)" stroke-width="0.16"/>
      <!-- boru hissi: çemberin iç ve dış kenarı hafif koyu -->
      <circle r="${RING + 0.068}" fill="none" stroke="#5148C9" stroke-width="0.024" opacity="0.45"/>
      <circle r="${RING - 0.068}" fill="none" stroke="#5148C9" stroke-width="0.024" opacity="0.45"/>
      ${angles.map((a, i) => line(a, 0.8, 0.93, i === 0 ? 'url(#peach)' : 'url(#metal)', 0.19)).join('')}
      <circle r="0.23" fill="url(#hub)"/>
      <circle r="0.075" fill="url(#hole)"/>`;
  // Light: highlight on the top arc of the rim and the top-left edge of the handles
  const shine = `
      <circle r="${RING + 0.035}" fill="none" stroke="url(#gloss)" stroke-width="0.03" opacity="0.8"/>
      ${angles.map((a) => line(a, 0.82, 0.91, '#FFFFFF', 0.045, ' opacity="0.45" transform="translate(-0.018 -0.022)"')).join('')}
      <ellipse cx="-0.07" cy="-0.1" rx="0.07" ry="0.045" fill="#FFFFFF" opacity="0.55"/>`;
  const body = `
      <g transform="translate(0.03 0.16)" opacity="0.6" filter="url(#soft)">${silhouette('#000000')}</g>
      ${extrusion}${face}${shine}`;
  return { defs, body };
}

// Dark background: slightly lit indigo in the middle, fading to black toward the edges; the wheel's glow behind
const darkBg = `
    <radialGradient id="bg" cx="0.5" cy="0.42" r="0.75">
      <stop offset="0" stop-color="#25205A"/><stop offset="0.55" stop-color="#110E2C"/><stop offset="1" stop-color="#05040D"/>
    </radialGradient>
    <linearGradient id="rim" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#FFFFFF" stop-opacity="0.22"/><stop offset="0.4" stop-color="#FFFFFF" stop-opacity="0"/>
    </linearGradient>
    <radialGradient id="glow" cx="0.5" cy="0.47" r="0.42">
      <stop offset="0" stop-color="#6D5EF5" stop-opacity="0.55"/><stop offset="1" stop-color="#6D5EF5" stop-opacity="0"/>
    </radialGradient>`;
const darkBody = (rx) =>
  `<rect width="1024" height="1024" rx="${rx}" fill="url(#bg)"/><rect width="1024" height="1024" rx="${rx}" fill="url(#glow)"/>` +
  (rx > 0 ? `<rect x="3" y="3" width="1018" height="1018" rx="${rx - 3}" fill="none" stroke="url(#rim)" stroke-width="6"/>` : '');

const svg = (body, defs = '') => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>${defs}</defs>${body}
</svg>`;

// scale: wheel radius (px, on a 1024 canvas); the 3D wheel sits slightly higher for shadow/thickness
const placed = (scale, opts) => `<g transform="translate(512 512) scale(${scale})">${wheel(opts)}</g>`;
const w3 = wheel3d();
const placed3d = (scale) => `<g transform="translate(512 ${512 - scale * 0.05}) scale(${scale})">${w3.body}</g>`;

const files = {
  // Full icon (old Android, splash, lock screen): dark rounded square + 3D wheel
  'icon.svg': svg(`${darkBody(230)}${placed3d(325)}`, darkBg + w3.defs),
  // Adaptive icon foreground: fits the central 66dp safe zone of the 108dp canvas
  'adaptive_fg.svg': svg(placed3d(290), w3.defs),
  'adaptive_bg.svg': svg(darkBody(0), darkBg),
  // Android 13 themed icon: monochrome silhouette (mask so the hole is transparent)
  'monochrome.svg': svg(
    `<mask id="m"><rect width="1024" height="1024" fill="#fff"/><circle cx="512" cy="512" r="${0.075 * 300}" fill="#000"/></mask>
  <g mask="url(#m)">${placed(300, { fg: '#000', hl: '#000', hole: '#000' })}</g>`,
  ),
  // Small notification icon: white silhouette, transparent background (Android only uses the alpha channel)
  'notification.svg': svg(
    `<mask id="m"><rect width="1024" height="1024" fill="#fff"/><circle cx="512" cy="512" r="${0.075 * 460}" fill="#000"/></mask>
  <g mask="url(#m)">${placed(460, { fg: '#fff', hl: '#fff', hole: '#fff' })}</g>`,
  ),
};

const out = join(here, 'out');
mkdirSync(out, { recursive: true });
const render = (name, size) => new Resvg(files[name], { fitTo: { mode: 'width', value: size } }).render().asPng();
for (const [name, text] of Object.entries(files)) {
  writeFileSync(join(out, name), text);
  writeFileSync(join(out, name.replace('.svg', '.png')), render(name, 1024));
}

// Android resources
const res = join(here, '../../app/android/app/src/main/res');
const dens = { mdpi: 1, hdpi: 1.5, xhdpi: 2, xxhdpi: 3, xxxhdpi: 4 };
for (const [d, k] of Object.entries(dens)) {
  const dir = join(res, `mipmap-${d}`);
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, 'ic_launcher.png'), render('icon.svg', Math.round(48 * k)));
  writeFileSync(join(dir, 'ic_launcher_foreground.png'), render('adaptive_fg.svg', Math.round(108 * k)));
  writeFileSync(join(dir, 'ic_launcher_background.png'), render('adaptive_bg.svg', Math.round(108 * k)));
  writeFileSync(join(dir, 'ic_launcher_monochrome.png'), render('monochrome.svg', Math.round(108 * k)));
  const dd = join(res, `drawable-${d}`);
  mkdirSync(dd, { recursive: true });
  writeFileSync(join(dd, 'ic_notification.png'), render('notification.svg', Math.round(24 * k)));
  writeFileSync(join(dd, 'splash_logo.png'), render('icon.svg', Math.round(96 * k)));
}
// In-app logo (lock screen)
const assets = join(here, '../../app/assets/brand');
mkdirSync(assets, { recursive: true });
writeFileSync(join(assets, 'icon.png'), render('icon.svg', 384));
console.log('ok');
