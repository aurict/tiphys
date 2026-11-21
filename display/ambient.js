// Ambient background: the app's AmbientBackground blobs, coloured from the cover and drifting slowly as a mesh gradient.
// WebGL at quarter resolution (stretched by the compositor: soft anyway, cheap on Iris Xe), capped at 30 fps.
// Bass pulses the blob brightness; colours cross-fade in 1.2 s; night dims and cools the tone.
import { FALLBACK, blobTone, lerpRgb } from './color.js';

const VERT = `attribute vec2 p; void main(){ gl_Position = vec4(p, 0.0, 1.0); }`;
const FRAG = `
precision mediump float;
uniform vec2 res; uniform float time; uniform float bass; uniform float dim; uniform float cool; uniform float drift;
uniform vec3 c0; uniform vec3 c1; uniform vec3 c2; uniform vec3 c3;
float glow(vec2 uv, vec2 c, float r){ float d = length(uv - c) / r; return pow(max(0.0, 1.0 - d), 2.2); }
float hash(vec2 p){ return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void main(){
  vec2 uv = gl_FragCoord.xy / res; uv.y = 1.0 - uv.y;
  float a = res.x / res.y; vec2 q = vec2(uv.x * a, uv.y);
  float t = time * drift;
  // Like the app's AmbientBackground: a few small soft glows near the edges (centres partly off-screen) on pure black;
  // most of the screen stays at #000–#050505. Faster than gaussian falloff so the tails don't wash the middle.
  vec2 p0 = vec2(a * 0.97 + 0.03 * sin(t * 0.21), 0.10 + 0.04 * cos(t * 0.17));
  vec2 p1 = vec2(a * 0.01 + 0.04 * cos(t * 0.15), 0.62 + 0.06 * sin(t * 0.19));
  vec2 p2 = vec2(a * 0.86 + 0.04 * cos(t * 0.13), 1.06 + 0.03 * sin(t * 0.23));
  vec2 p3 = vec2(a * (0.42 + 0.10 * sin(t * 0.07)), -0.04 + 0.05 * sin(t * 0.11));
  float pulse = 1.0 + bass * 0.30;
  vec3 col = c0 * glow(q, p0, 0.30) * 0.36 * pulse
           + c1 * glow(q, p1, 0.26) * 0.21 * pulse
           + c2 * glow(q, p2, 0.30) * 0.19 * pulse
           + c3 * glow(q, p3, 0.22) * 0.06;
  // Night: cooler (toward indigo), dimmer.
  vec3 night = vec3(dot(col, vec3(0.30, 0.45, 0.25))) * vec3(0.62, 0.70, 1.0);
  col = mix(col, night, cool * 0.55) * (1.0 - dim);
  col += (hash(gl_FragCoord.xy + fract(time)) - 0.5) / 255.0; // dither against banding
  gl_FragColor = vec4(col, 1.0);
}`;

export function createAmbient(canvas) {
  const SCALE = 0.25;
  const gl = canvas.getContext('webgl', { antialias: false, alpha: false, depth: false, powerPreference: 'low-power', preserveDrawingBuffer: false });
  let from = FALLBACK.map(blobTone), to = from, mixStart = 0;
  const MIX_MS = 1200;
  let bass = 0, dim = 0, cool = 0, dimTarget = 0, coolTarget = 0;
  let motion = 'normal';
  let last = 0, dirty = true;
  const t0 = performance.now();
  let u = null;

  function resize() {
    canvas.width = Math.max(2, Math.round(innerWidth * SCALE));
    canvas.height = Math.max(2, Math.round(innerHeight * SCALE));
    dirty = true;
  }

  if (gl) {
    const sh = (type, src) => { const s = gl.createShader(type); gl.shaderSource(s, src); gl.compileShader(s); return s; };
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
    u = Object.fromEntries(['res', 'time', 'bass', 'dim', 'cool', 'drift', 'c0', 'c1', 'c2', 'c3'].map((n) => [n, gl.getUniformLocation(prog, n)]));
  }
  resize();
  addEventListener('resize', resize);

  const current = (now) => {
    const k = Math.min(1, (now - mixStart) / MIX_MS);
    const e = k * k * (3 - 2 * k);
    return { cols: to.map((c, i) => lerpRgb(from[i], c, e)), mixing: k < 1 };
  };

  function draw(now, cols) {
    const time = (now - t0) / 1000;
    if (gl) {
      gl.viewport(0, 0, canvas.width, canvas.height);
      gl.uniform2f(u.res, canvas.width, canvas.height);
      gl.uniform1f(u.time, motion === 'low' ? 0 : time);
      gl.uniform1f(u.drift, motion === 'high' ? 1.6 : 1.0);
      gl.uniform1f(u.bass, motion === 'low' ? 0 : bass);
      gl.uniform1f(u.dim, dim);
      gl.uniform1f(u.cool, cool);
      cols.forEach((c, i) => gl.uniform3f(u['c' + i], c[0] / 255, c[1] / 255, c[2] / 255));
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    } else {
      // Canvas 2D fallback: three radial gradients, no drift.
      const g = canvas.getContext('2d');
      const w = canvas.width, h = canvas.height;
      g.fillStyle = '#000'; g.fillRect(0, 0, w, h);
      const spots = [[0.97, 0.1, 0.3, 0.3], [0.01, 0.62, 0.26, 0.17], [0.86, 1.06, 0.3, 0.15]];
      spots.forEach(([x, y, r, a], i) => {
        const grd = g.createRadialGradient(x * w, y * h, 0, x * w, y * h, r * h);
        const c = cols[i].map((v) => Math.round(v * (1 - dim)));
        grd.addColorStop(0, `rgba(${c},${a})`); grd.addColorStop(1, `rgba(${c},0)`);
        g.fillStyle = grd; g.fillRect(0, 0, w, h);
      });
    }
  }

  return {
    /** New cover palette (null = Tiphys defaults). */
    setPalette(pal) {
      const now = performance.now();
      from = current(now).cols;
      to = (pal ?? FALLBACK).map(blobTone);
      mixStart = now;
      dirty = true;
    },
    setBass(v) { bass = v; },
    /** Night (0..1): 20 % dimmer and cooler at full night. */
    setNight(n) { dimTarget = n * 0.2; coolTarget = n; },
    setMotion(m) { motion = m; dirty = true; },
    /** Unmounted (mode switch): the listener goes and the WebGL context is given back at once. */
    destroy() {
      removeEventListener('resize', resize);
      gl?.getExtension('WEBGL_lose_context')?.loseContext();
    },
    frame(now) {
      const step = (a, b) => (Math.abs(b - a) < 0.002 ? b : a + (b - a) * 0.04);
      const nd = step(dim, dimTarget), nc = step(cool, coolTarget);
      if (nd !== dim || nc !== cool) { dim = nd; cool = nc; dirty = true; }
      const { cols, mixing } = current(now);
      if (motion === 'low' && !mixing && !dirty) return; // static gradient
      if (now - last < 33) return; // 30 fps cap
      last = now;
      dirty = false;
      draw(now, cols);
    },
  };
}
