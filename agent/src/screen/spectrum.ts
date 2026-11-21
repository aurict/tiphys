// Game mode spectrum (PLAN.md §19): the default output's monitor (pw-record, 16 kHz mono s16) → 1024-point FFT →
// 24 log bands 0..255 → binary frames [0x01, 24 bytes] at ~30 fps. Plain TS, no dependency.
// pw-record targets the default sink's node name with stream.capture.sink=true, so it records what the PC plays
// (silent while nothing plays), never the microphone.

export const RATE = 16_000;
export const FFT_N = 1024;
export const BANDS = 24;
export const FRAME_SPECTRUM = 0x01;
const LO_HZ = 40;
const HI_HZ = 7600;
/** Dynamic range shown by the bars (dB below the moving ceiling). */
const RANGE_DB = 48;
/** Ceiling decay per frame (dB): ~4.5 dB/s at 30 fps, so quiet songs fill the bars again within seconds. */
const CEIL_DECAY_DB = 0.15;
const CEIL_MIN_DB = -60;
/** Below this window RMS (≈ -80 dBFS) the frame is silence. */
const SILENCE_RMS = 1e-4;
const ATTACK = 0.7;
const RELEASE = 0.2;

/** In-place iterative radix-2 FFT (re/im of length n, a power of two). */
export function fft(re: Float64Array, im: Float64Array): void {
  const n = re.length;
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1;
    for (; j & bit; bit >>= 1) j ^= bit;
    j ^= bit;
    if (i < j) {
      [re[i], re[j]] = [re[j]!, re[i]!];
      [im[i], im[j]] = [im[j]!, im[i]!];
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const ang = (-2 * Math.PI) / len;
    const wr = Math.cos(ang);
    const wi = Math.sin(ang);
    for (let i = 0; i < n; i += len) {
      let cr = 1;
      let ci = 0;
      for (let k = 0; k < len / 2; k++) {
        const a = i + k;
        const b = a + len / 2;
        const tr = re[b]! * cr - im[b]! * ci;
        const ti = re[b]! * ci + im[b]! * cr;
        re[b] = re[a]! - tr;
        im[b] = im[a]! - ti;
        re[a] = re[a]! + tr;
        im[a] = im[a]! + ti;
        const nr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = nr;
      }
    }
  }
}

/** FFT bin ranges [from, to) of the 24 log-spaced bands between 40 Hz and 7.6 kHz (each at least one bin). */
export function bandBins(n = FFT_N, rate = RATE, bands = BANDS): Array<[number, number]> {
  const hz = rate / n;
  const out: Array<[number, number]> = [];
  let prev = Math.max(1, Math.floor(LO_HZ / hz));
  for (let i = 0; i < bands; i++) {
    const hi = LO_HZ * (HI_HZ / LO_HZ) ** ((i + 1) / bands);
    const from = prev;
    const to = Math.max(from + 1, Math.round(hi / hz));
    out.push([from, Math.min(to, n / 2)]);
    prev = to;
  }
  return out;
}

/** Ring buffer of the latest samples + band levels with a moving ceiling (auto gain) and attack/release smoothing. */
export class SpectrumAnalyzer {
  readonly #ring = new Float64Array(FFT_N);
  #pos = 0;
  #odd: number | null = null;
  readonly #win = Float64Array.from({ length: FFT_N }, (_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (FFT_N - 1)));
  readonly #bins = bandBins();
  readonly #re = new Float64Array(FFT_N);
  readonly #im = new Float64Array(FFT_N);
  readonly #level = new Float64Array(BANDS);
  #ceil = CEIL_MIN_DB;

  /** Raw s16le bytes (chunks may split a sample). */
  pushBytes(b: Buffer): void {
    let i = 0;
    if (this.#odd !== null && b.length > 0) {
      this.#add(Buffer.from([this.#odd, b[0]!]).readInt16LE(0));
      this.#odd = null;
      i = 1;
    }
    for (; i + 1 < b.length; i += 2) this.#add(b.readInt16LE(i));
    if (i < b.length) this.#odd = b[i]!;
  }

  push(samples: ArrayLike<number>): void {
    for (let i = 0; i < samples.length; i++) this.#add(samples[i]!);
  }

  #add(v: number) {
    this.#ring[this.#pos] = v / 32768;
    this.#pos = (this.#pos + 1) % FFT_N;
  }

  /** The current 24 bands, 0..255 (smoothed over calls). */
  bands(): Uint8Array {
    let sq = 0;
    for (let i = 0; i < FFT_N; i++) {
      const v = this.#ring[(this.#pos + i) % FFT_N]!;
      sq += v * v;
      this.#re[i] = v * this.#win[i]!;
      this.#im[i] = 0;
    }
    const silent = Math.sqrt(sq / FFT_N) < SILENCE_RMS;
    const target = new Float64Array(BANDS);
    if (!silent) {
      fft(this.#re, this.#im);
      // A full-scale sine peaks at N/4 with a Hann window: normalise so that is 0 dB.
      const norm = FFT_N / 4;
      const db = this.#bins.map(([a, b]) => {
        let p = 0;
        for (let k = a; k < b; k++) p = Math.max(p, (this.#re[k]! ** 2 + this.#im[k]! ** 2) / (norm * norm));
        return 10 * Math.log10(p + 1e-12);
      });
      this.#ceil = Math.max(Math.max(...db), this.#ceil - CEIL_DECAY_DB, CEIL_MIN_DB);
      for (let i = 0; i < BANDS; i++) target[i] = Math.min(1, Math.max(0, (db[i]! - (this.#ceil - RANGE_DB)) / RANGE_DB));
    } else {
      this.#ceil = Math.max(CEIL_MIN_DB, this.#ceil - CEIL_DECAY_DB);
    }
    const out = new Uint8Array(BANDS);
    for (let i = 0; i < BANDS; i++) {
      const prev = this.#level[i]!;
      const t = target[i]!;
      this.#level[i] = prev + (t - prev) * (t > prev ? ATTACK : RELEASE);
      out[i] = Math.round(this.#level[i]! * 255);
    }
    return out;
  }

  /** Binary spectrum frame: byte 0 = 0x01, bytes 1..24 = bands. */
  frame(): Buffer {
    return Buffer.concat([Buffer.from([FRAME_SPECTRUM]), this.bands()]);
  }
}

/** pw-record arguments: the default sink's monitor (by node name), 16 kHz mono s16 raw to stdout. */
export function pwRecordArgs(sinkName: string): string[] {
  return [
    "--target", sinkName,
    "-P", "{ stream.capture.sink=true node.name=tiphys-gamemode-spectrum }",
    "--rate", String(RATE), "--channels", "1", "--format", "s16", "--latency", "20ms", "--raw", "-",
  ];
}

/** `wpctl inspect @DEFAULT_AUDIO_SINK@` → node.name (null if not a sink). */
export function parseSinkName(out: string): string | null {
  if (!/media\.class = "Audio\/Sink"/.test(out)) return null;
  const m = /node\.name = "([^"\n]{1,200})"/.exec(out);
  return m ? m[1]! : null;
}
