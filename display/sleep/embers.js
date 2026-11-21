// Sleep mode embers scene (PLAN.md §21 E-1, S1 draft): one full-screen fragment shader drawn at reduced resolution
// (settle/fade 1/3, night 1/6) and stretched by the compositor (embers are soft anyway). Warm ramp only:
// #000 → #1A0300 → #4A0A00 → #8A2200 → #C24A0A → #E8862A (the hottest stop only in settle); blue ~0.
//  - coal bed: domain-warped fBm in the bottom ~quarter, glowing seams between dark crusts, regions breathing at
//    different phases; its noise runs in scene coordinates, so two screens show one continuous bed;
//  - events from the shared timeline (timeline.js): crackle pops, slow flares, log cracks, sparks (rising, cooling,
//    crossing to the other screen at the shared time), gusts (the bed brightens), alarm motes (one per chirp/chime);
//  - heat shimmer above the bed (settle + first half of fade);
//  - night: the bed shrinks to two clusters per screen breathing at 0.05 Hz, the rest pure black;
//  - sunrise: the coals swell into a warm light rising from the bottom (ember red → ~2000 K → ~3500 K), the top last;
//    ring: the light at its peak with a slow 0.1 Hz breath.
// `bright` multiplies everything (the content half of the brightness curve; the agent does the hardware half).
// No WebGL → a 2D canvas gradient (bed glow, night clusters, sunrise light).
// createEmbers(canvas, timeline) → {draw(T), setScale(s), setBrightness(b), destroy(), webgl}

import { sparkAt } from './timeline.js';

const MAX_FL = 16, MAX_SP = 32, MAX_MO = 8;

const VERT = 'attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }';
const FRAG = `
precision highp float;
uniform vec2 res; uniform float time; uniform float sx0; uniform float seed;
uniform float fire; uniform float night; uniform float sun; uniform float shimmer; uniform float bright; uniform float gust;
uniform float ring;
uniform vec4 fl[${MAX_FL}]; uniform int nf;
uniform vec4 sp[${MAX_SP}]; uniform vec4 spv[${MAX_SP}]; uniform int ns;
uniform vec4 co[4]; uniform int nc;
uniform vec4 mo[${MAX_MO}]; uniform int nm;

float hash(vec2 p){ p = fract(p * vec2(123.34, 456.21)); p += dot(p, p + 45.32); return fract(p.x * p.y); }
float noise(vec2 p){
  vec2 i = floor(p), f = fract(p); vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), u.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p){ float v = 0.0, a = 0.5; for (int i = 0; i < 4; i++){ v += a * noise(p); p = p * 2.03 + vec2(17.1, 9.2); a *= 0.5; } return v; }
// warm light by intensity: ember red → ~2000 K → ~3500 K (dim light stays red, never brown)
vec3 kelvin(float k){
  vec3 e = vec3(138.0, 34.0, 0.0) / 255.0, a = vec3(1.0, 0.54, 0.07), b = vec3(1.0, 0.77, 0.54);
  return k < 0.35 ? mix(e, a, k / 0.35) : mix(a, b, (k - 0.35) / 0.65);
}
vec3 ramp(float h){
  h = clamp(h, 0.0, 1.0) * 5.0;
  vec3 c1 = vec3(26.0, 3.0, 0.0) / 255.0, c2 = vec3(74.0, 10.0, 0.0) / 255.0, c3 = vec3(138.0, 34.0, 0.0) / 255.0;
  vec3 c4 = vec3(194.0, 74.0, 10.0) / 255.0, c5 = vec3(232.0, 134.0, 42.0) / 255.0;
  if (h < 1.0) return c1 * h;
  if (h < 2.0) return mix(c1, c2, h - 1.0);
  if (h < 3.0) return mix(c2, c3, h - 2.0);
  if (h < 4.0) return mix(c3, c4, h - 3.0);
  return mix(c4, c5, h - 4.0);
}
void main(){
  vec2 uv = gl_FragCoord.xy / res;
  float asp = res.x / res.y;
  float X = sx0 + uv.x, y = uv.y, t = time;
  vec2 P = vec2(X * 1.7, y);
  float top = 0.20 + 0.08 * fbm(vec2(P.x * 1.3 + seed, 0.5)) + sun * 0.16;
  // heat shimmer: the hot air ripples the top of the bed (the rows of the texture, not the bed's outline)
  P.x += shimmer * 0.006 * sin(y * 70.0 + t * 4.7 + noise(vec2(X * 5.0, t * 0.6)) * 4.0) * smoothstep(top - 0.12, top, y);
  float heat = 0.0, glow = 0.0;
  // night clusters (scene → local done in JS): soft masks
  float cm = 0.0;
  for (int i = 0; i < 4; i++){
    if (i >= nc) break;
    vec2 d = vec2((uv.x - co[i].x) * asp, (y - co[i].y) * 1.5);
    cm += co[i].w * exp(-dot(d, d) / (co[i].z * co[i].z));
  }
  cm = min(cm, 1.0);
  // At night only the clusters glow: skip the coal pattern (6 fBm + Worley) wherever no cluster reaches (S7).
  if (y < top + 0.06 && (night < 0.999 || cm > 0.002)) {
    // Coals: cells of a warped Worley pattern. The gaps between them glow hot, the crusts glow dim and mottled, each
    // coal at its own heat, breathing at its own phase.
    // Perspective: coals are smaller toward the back (top) of the bed.
    float back = clamp(y / max(top, 0.05), 0.0, 1.0);
    vec2 q = vec2(P.x * 5.5, y * 8.0) * (1.0 + 0.3 * back) + seed;
    vec2 w = vec2(fbm(q * 0.7 + vec2(0.0, t * 0.03)), fbm(q * 0.7 + vec2(5.2, 1.3) - vec2(t * 0.02, 0.0)));
    vec2 c = q + 2.4 * (w - 0.5);
    vec2 ci = floor(c), cf = fract(c);
    float f1 = 8.0, f2 = 8.0; vec2 id = vec2(0.0);
    for (int j = -1; j <= 1; j++) for (int i = -1; i <= 1; i++) {
      vec2 g = vec2(float(i), float(j));
      vec2 o = 0.15 + 0.7 * vec2(hash(ci + g), hash(ci + g + 7.3));
      float d = length(g + o - cf);
      if (d < f1) { f2 = f1; f1 = d; id = ci + g; } else if (d < f2) f2 = d;
    }
    float n = fbm(q * 1.1 + 1.7 * w + vec2(0.0, t * 0.012));
    float n2 = fbm(q * 0.6 - w + vec2(t * 0.01, 3.0));
    float hot = hash(id + 3.1);
    float breath = 0.7 + 0.3 * sin(t * (0.35 + 0.3 * hot) + hot * 6.283);
    // the gaps glow, but not all of them (ash covers some)
    float seam = (1.0 - smoothstep(0.0, 0.13, f2 - f1)) * smoothstep(0.3, 0.62, n2);
    // crusts: mostly dark, glowing in patches; some coals hot all through
    float crust = (0.08 + 1.1 * n * n) * (0.3 + 0.9 * hot * hot) * (1.0 - smoothstep(0.25, 1.0, f1)) * smoothstep(0.0, 0.12, f2 - f1);
    float depth = 1.0 - smoothstep(top - 0.12, top + 0.03, y);
    float raw = depth * (crust * breath * 1.4 + seam * (0.45 + 0.6 * n) * (0.75 + 0.25 * breath));
    float day = raw * fire * (1.0 + 0.22 * gust);
    float nightHeat = cm * (0.18 + 0.32 * raw) * depth;
    heat = mix(day, nightHeat, night);
  }
  // the bed's light on the room above it
  glow = mix(fire * 0.2, 0.05 * cm, night) * exp(-max(y - top, 0.0) * 6.0);
  // flares and crackle pops (fainter above the bed)
  float inBed = mix(0.35, 1.0, 1.0 - smoothstep(top - 0.02, top + 0.08, y));
  for (int i = 0; i < ${MAX_FL}; i++){
    if (i >= nf) break;
    vec2 d = vec2((uv.x - fl[i].x) * asp, (y - fl[i].y) * 1.4);
    heat += fl[i].w * exp(-dot(d, d) / (fl[i].z * fl[i].z)) * inBed;
  }
  vec3 col = ramp(heat) + ramp(glow) * 0.9;
  // sparks: a hot core with a short tail along the velocity
  vec2 pp = vec2(uv.x * asp, y);
  for (int i = 0; i < ${MAX_SP}; i++){
    if (i >= ns) break;
    vec2 c = vec2(sp[i].x * asp, sp[i].y);
    vec2 ba = -vec2(spv[i].x * asp, spv[i].y) * 0.05;
    vec2 pa = pp - c;
    float hh = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-7), 0.0, 1.0);
    vec2 dd = pa - ba * hh;
    float r = 0.0038 * sp[i].w;
    float k = exp(-dot(dd, dd) / (r * r)) * min(sp[i].z, 1.4) * (1.0 - 0.6 * hh);
    col += ramp(0.5 + 0.5 * min(sp[i].z, 1.0)) * k * 1.7;
  }
  // sunrise / ring light: rises from the bottom, the top lights last
  if (sun > 0.0) {
    float front = sun * 1.45;
    float L = sun * (1.0 - smoothstep(front - 0.7, front + 0.25, y));
    L *= 0.93 + ring * 0.06 * sin(t * 0.628);
    vec3 s = kelvin(L) * L;
    col = 1.0 - (1.0 - col * (1.0 - 0.85 * sun)) * (1.0 - s);
  }
  // alarm motes: small soft points of light
  for (int i = 0; i < ${MAX_MO}; i++){
    if (i >= nm) break;
    vec2 d = vec2((uv.x - mo[i].x) * asp, y - mo[i].y);
    col += vec3(1.0, 0.86, 0.62) * mo[i].w * exp(-dot(d, d) / (mo[i].z * mo[i].z));
  }
  col *= bright;
  // dither against banding in the dark gradients; pure black stays pure black
  col += (hash(gl_FragCoord.xy + fract(t * 7.0)) - 0.5) / 255.0 * step(0.004, col.r);
  gl_FragColor = vec4(col, 1.0);
}`;

// Kelvin-ish warm light for the sunrise: ember red → ~2000 K → ~3500 K.
const K_EMBER = [138 / 255, 34 / 255, 0], K2000 = [1, 0.54, 0.07], K3500 = [1, 0.77, 0.54];
const mixv = (a, b, k) => a.map((v, i) => v + (b[i] - v) * k);
export const sunColor = (s) => (s < 0.35 ? mixv(K_EMBER, K2000, s / 0.35) : mixv(K2000, K3500, (s - 0.35) / 0.65));

/** Envelope of a visual event at age tau (s): 0..1, or -1 when it is over. */
function envelope(ev, tau) {
  if (tau < 0) return 0;
  switch (ev.kind) {
    case 'crackle': return tau > 0.9 ? -1 : (tau < 0.025 ? tau / 0.025 : Math.exp(-(tau - 0.025) / 0.16));
    case 'log': return tau > 4 ? -1 : (tau < 0.06 ? tau / 0.06 : Math.exp(-(tau - 0.06) / 0.9));
    case 'flare': case 'gust': { const d = ev.dur / 1000; return tau > d ? -1 : Math.sin(Math.PI * tau / d) ** 2; }
    case 'chirp': { const on = (ev.notes * (ev.noteMs + ev.gapMs)) / 1000; return tau > on + 2 ? -1 : (tau < 0.04 ? tau / 0.04 : tau < on ? 1 : Math.exp(-(tau - on) / 0.5)); }
    case 'chime': return tau > 6 ? -1 : (tau < 0.05 ? tau / 0.05 : Math.exp(-(tau - 0.05) / 1.6));
    default: return -1;
  }
}

/** The per-frame scene for this screen at shared time T: uniforms in local coordinates (pure apart from Math). */
export function sceneAt(tl, T) {
  const L = tl.levels(T);
  const x0 = tl.mine.x0;
  const fl = [], sp = [], mo = [];
  let gust = 0;
  for (const ev of tl.live(T)) {
    const tau = (T - ev.t) / 1000;
    if (ev.kind === 'spark') {
      const s = sparkAt(ev, T);
      if (!s) continue;
      const lx = s.x - x0;
      if (lx < -0.03 || lx > 1.03 || s.y > 1.05) continue;
      sp.push([lx, s.y, s.heat, ev.size, s.vx, s.vy]);
      continue;
    }
    const e = envelope(ev, tau);
    if (e <= 0) continue;
    const lx = ev.x - x0;
    if (ev.kind === 'gust') { gust += ev.amp * e; continue; }
    if (lx < -0.3 || lx > 1.3) continue;
    if (ev.kind === 'crackle') fl.push([lx, ev.y, 0.02 + 0.012 * ev.amp, 0.55 * ev.amp * e]);
    else if (ev.kind === 'log') fl.push([lx, ev.y, 0.13, 0.55 * ev.amp * e]);
    else if (ev.kind === 'flare') fl.push([lx, ev.y, ev.r, (L.night > 0.5 ? 0.16 : 0.3) * ev.amp * e]);
    else if (ev.kind === 'chirp') mo.push([lx, ev.y, 0.012, 0.35 * ev.amp * e]);
    else if (ev.kind === 'chime') mo.push([lx, ev.y, 0.05, 0.25 * ev.amp * e]);
  }
  // keep the strongest when over budget
  fl.sort((a, b) => b[3] - a[3]); sp.sort((a, b) => b[2] - a[2]); mo.sort((a, b) => b[3] - a[3]);
  const t = (T - tl.plan.t0) / 1000;
  const co = tl.coals
    .map((c) => [c.x - x0, c.y, c.r, 0.75 + 0.25 * Math.sin(2 * Math.PI * 0.05 * t + c.ph * 6.283)])
    .filter((c) => c[0] > -0.2 && c[0] < 1.2).slice(0, 4);
  return { L, t, x0, gust: Math.min(1, gust), fl: fl.slice(0, MAX_FL), sp: sp.slice(0, MAX_SP), mo: mo.slice(0, MAX_MO), co };
}

export function createEmbers(canvas, tl) {
  let scale = 1 / 3, bright = 1;
  const gl = canvas.getContext('webgl', { antialias: false, alpha: false, depth: false, stencil: false, powerPreference: 'low-power', preserveDrawingBuffer: false });
  let u = null;
  const seed = ((tl.session.seed >>> 0) % 997) / 9.97;
  const flBuf = new Float32Array(MAX_FL * 4), spBuf = new Float32Array(MAX_SP * 4), spvBuf = new Float32Array(MAX_SP * 4);
  const coBuf = new Float32Array(16), moBuf = new Float32Array(MAX_MO * 4);

  function resize() {
    const w = Math.max(2, Math.round(innerWidth * scale)), h = Math.max(2, Math.round(innerHeight * scale));
    if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
  }

  if (gl) {
    const sh = (type, src) => {
      const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s);
      if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
      return s;
    };
    const prog = gl.createProgram();
    gl.attachShader(prog, sh(gl.VERTEX_SHADER, VERT));
    gl.attachShader(prog, sh(gl.FRAGMENT_SHADER, FRAG));
    gl.linkProgram(prog);
    gl.useProgram(prog);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 3, -1, -1, 3]), gl.STATIC_DRAW);
    const loc = gl.getAttribLocation(prog, 'p');
    gl.enableVertexAttribArray(loc);
    gl.vertexAttribPointer(loc, 2, gl.FLOAT, false, 0, 0);
    u = Object.fromEntries(['res', 'time', 'sx0', 'seed', 'fire', 'night', 'sun', 'shimmer', 'bright', 'gust', 'ring',
      'fl', 'nf', 'sp', 'spv', 'ns', 'co', 'nc', 'mo', 'nm'].map((n) => [n, gl.getUniformLocation(prog, n)]));
  }
  resize();
  addEventListener('resize', resize);

  function drawGL(s) {
    const { L } = s;
    gl.viewport(0, 0, canvas.width, canvas.height);
    gl.uniform2f(u.res, canvas.width, canvas.height);
    gl.uniform1f(u.time, s.t);
    gl.uniform1f(u.sx0, s.x0);
    gl.uniform1f(u.seed, seed);
    gl.uniform1f(u.fire, L.fire);
    gl.uniform1f(u.night, L.night);
    gl.uniform1f(u.sun, L.sun);
    gl.uniform1f(u.shimmer, L.shimmer);
    gl.uniform1f(u.bright, bright);
    gl.uniform1f(u.gust, s.gust);
    gl.uniform1f(u.ring, L.phase === 'ring' ? 1 : 0);
    s.fl.forEach((f, i) => flBuf.set(f, i * 4));
    s.sp.forEach((p, i) => { spBuf.set([p[0], p[1], p[2], p[3]], i * 4); spvBuf.set([p[4], p[5], 0, 0], i * 4); });
    s.co.forEach((c, i) => coBuf.set(c, i * 4));
    s.mo.forEach((m, i) => moBuf.set(m, i * 4));
    gl.uniform4fv(u.fl, flBuf); gl.uniform1i(u.nf, s.fl.length);
    gl.uniform4fv(u.sp, spBuf); gl.uniform4fv(u.spv, spvBuf); gl.uniform1i(u.ns, s.sp.length);
    gl.uniform4fv(u.co, coBuf); gl.uniform1i(u.nc, s.co.length);
    gl.uniform4fv(u.mo, moBuf); gl.uniform1i(u.nm, s.mo.length);
    gl.drawArrays(gl.TRIANGLES, 0, 3);
  }

  // 2D fallback: no noise, just the light of the bed, the night clusters and the sunrise.
  function draw2d(s) {
    const g = canvas.getContext('2d');
    const w = canvas.width, h = canvas.height, { L } = s;
    const rgb = (c, k) => `rgb(${c.map((v) => Math.round(v * 255 * k * bright)).join(',')})`;
    g.fillStyle = '#000'; g.fillRect(0, 0, w, h);
    const day = L.fire * (1 - L.night);
    if (day > 0.01) {
      const grd = g.createLinearGradient(0, h, 0, h * 0.6);
      grd.addColorStop(0, rgb([194 / 255, 74 / 255, 10 / 255], day)); grd.addColorStop(0.35, rgb([74 / 255, 10 / 255, 0], day)); grd.addColorStop(1, '#000');
      g.fillStyle = grd; g.fillRect(0, 0, w, h);
    }
    g.globalCompositeOperation = 'lighter'; // the light layers add up (an unlit cluster must not paint black)
    for (const c of (L.night > 0.01 ? s.co : [])) {
      const x = c[0] * w, y = h - c[1] * h, r = c[2] * h * 2.2;
      const grd = g.createRadialGradient(x, y, 0, x, y, r);
      grd.addColorStop(0, rgb([74 / 255, 10 / 255, 0], L.night * c[3])); grd.addColorStop(1, 'rgba(0,0,0,0)');
      g.fillStyle = grd; g.fillRect(0, 0, w, h);
    }
    if (L.sun > 0) {
      const grd = g.createLinearGradient(0, h, 0, 0);
      const sc = sunColor(L.sun);
      grd.addColorStop(0, rgb(sc, L.sun * 0.86)); grd.addColorStop(Math.min(1, L.sun * 0.9), rgb(sc, L.sun * 0.5)); grd.addColorStop(1, rgb(sc, L.sun * L.sun * 0.3));
      g.fillStyle = grd; g.fillRect(0, 0, w, h);
    }
    for (const p of s.sp) { g.fillStyle = rgb([232 / 255, 134 / 255, 42 / 255], Math.min(1, p[2])); g.fillRect(p[0] * w, h - p[1] * h, 1, 1); }
    g.globalCompositeOperation = 'source-over';
  }

  return {
    webgl: !!gl,
    /** Draw the scene at shared time T (ms). Returns the scene (the page reads its counts for frame pacing). */
    draw(T) {
      const s = sceneAt(tl, T);
      if (gl) drawGL(s); else draw2d(s);
      return s;
    },
    /** Internal resolution as a fraction of the screen (1/3 settle/fade, 1/6 night). */
    setScale(s) { if (s !== scale) { scale = s; resize(); } },
    setBrightness(b) { bright = Math.max(0, Math.min(1, b)); },
    destroy() {
      removeEventListener('resize', resize);
      gl?.getExtension('WEBGL_lose_context')?.loseContext();
    },
  };
}
