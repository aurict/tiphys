// Cover colours. Port of app/lib/features/system/velour_color.dart (12 hue buckets weighted by saturation), extended to
// return the 4 strongest buckets for the ambient background, plus helpers for tones that keep white text readable.

export const FALLBACK = [[124, 116, 240], [80, 200, 150], [242, 169, 133], [94, 92, 230]]; // AmbientBackground defaults

function rgbToHsl(r, g, b) {
  r /= 255; g /= 255; b /= 255;
  const max = Math.max(r, g, b), min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h;
  if (max === r) h = (g - b) / d + (g < b ? 6 : 0);
  else if (max === g) h = (b - r) / d + 2;
  else h = (r - g) / d + 4;
  return [h * 60, s, l];
}

function hslToRgb(h, s, l) {
  h = ((h % 360) + 360) % 360 / 360;
  if (s === 0) return [l * 255, l * 255, l * 255];
  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const f = (t) => {
    t = (t + 1) % 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  };
  return [f(h + 1 / 3) * 255, f(h) * 255, f(h - 1 / 3) * 255];
}

/** Up to 4 colours from RGBA pixels, strongest first; colourless covers give their grey tones. */
export function palette(rgba) {
  const weight = new Float64Array(13);
  const sum = Array.from({ length: 13 }, () => [0, 0, 0]);
  for (let i = 0; i + 3 < rgba.length; i += 4) {
    if (rgba[i + 3] < 128) continue;
    const r = rgba[i], g = rgba[i + 1], b = rgba[i + 2];
    const [h, s, l] = rgbToHsl(r, g, b);
    const colourful = s > 0.2 && l > 0.12 && l < 0.88;
    const bucket = colourful ? Math.floor(h / 30) % 12 : 12;
    const w = colourful ? 0.3 + s * (1 - Math.abs(l - 0.5)) : 0.08;
    weight[bucket] += w;
    sum[bucket][0] += r * w; sum[bucket][1] += g * w; sum[bucket][2] += b * w;
  }
  const order = [...weight.keys()].filter((i) => weight[i] > 0).sort((a, b) => weight[b] - weight[a]);
  const out = order.slice(0, 4).map((i) => sum[i].map((v) => v / weight[i]));
  if (!out.length) return null;
  while (out.length < 4) out.push(shiftHue(out[out.length % Math.max(1, out.length)] ?? out[0], 28 * out.length));
  return out;
}

function shiftHue(rgb, deg) {
  const [h, s, l] = rgbToHsl(...rgb);
  return hslToRgb(h + deg, s, l);
}

/** Ambient blob colour: the hue kept, saturation lifted a little, lightness in a range that glows on black. */
export function blobTone(rgb) {
  const [h, s, l] = rgbToHsl(...rgb);
  return hslToRgb(h, Math.min(0.85, Math.max(s, 0.18) * 1.1), Math.min(0.62, Math.max(0.42, l)));
}

/** Bright, readable accent from the cover (progress, spectrum, glow): ≥ 4.5:1 on near-black. */
export function accentTone(rgb) {
  const [h, s] = rgbToHsl(...rgb);
  return hslToRgb(h, Math.min(0.9, Math.max(s, 0.35)), 0.74);
}

/** Read 24×24 pixels from a loaded same-origin image. */
export function imagePixels(img) {
  const c = document.createElement('canvas');
  c.width = 24; c.height = 24;
  const g = c.getContext('2d', { willReadFrequently: true });
  g.drawImage(img, 0, 0, 24, 24);
  return g.getImageData(0, 0, 24, 24).data;
}

export const css = (rgb, a = 1) => `rgba(${rgb.map((v) => Math.round(v)).join(',')},${a})`;
export const lerpRgb = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);
