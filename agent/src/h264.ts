// Live screen H.264 (10.2 Stage C): splits the Annex-B byte stream into NAL units and access units (one frame),
// keyframe gate (when a P-frame is dropped under backpressure nothing is sent until the next IDR) and frame
// header. Source: `wf-recorder -c h264_nvenc -m h264 -f pipe:1` (raw Annex-B). On argo each frame is written in one
// piece (split only at the 64 KB pipe limit, <0.3 ms apart); so the end of a frame is detected when the stream goes
// quiet briefly (a few ms), without waiting for the next start code (one frame = ~33 ms delay): [AccessUnitParser.flush].
// If data after a quiet gap doesn't start with a start code, the previous frame was sent half → counted as [corrupt],
// and the caller waits for the next keyframe.

/** NAL types (ITU-T H.264 Table 7-1). */
export const NAL = { slice: 1, idr: 5, sei: 6, sps: 7, pps: 8, aud: 9 } as const;

export interface AccessUnit {
  /** Frame data: Annex-B (each NAL with a 4-byte start code); SPS/PPS/AUD removed. */
  data: Buffer;
  /** Contains an IDR slice. */
  key: boolean;
  /** SPS and PPS that came in this frame (if any; raw NAL, without start code). */
  sps: Buffer | null;
  pps: Buffer | null;
}

const START4 = Buffer.from([0, 0, 0, 1]);

/** Joins raw NALs as Annex-B (4-byte start codes). */
export function annexB(nals: Buffer[]): Buffer {
  const parts: Buffer[] = [];
  for (const n of nals) parts.push(START4, n);
  return Buffer.concat(parts);
}

/**
 * Annex-B → NAL units. A start code may be 3 or 4 bytes and may be split across chunk boundaries. A NAL is only
 * complete once the next start code is seen (or via [flush]). Trailing zeros at the end of a NAL (trailing_zero_8bits /
 * the first zero of a 4-byte code) are dropped.
 */
export class NalSplitter {
  #buf: Buffer = Buffer.alloc(0);
  /** Start of the pending NAL in #buf (after the start code); -1: no start code seen yet. */
  #start = -1;
  /** Where the search continues (scanned bytes aren't rescanned). */
  #scan = 0;
  /** Count of (discarded) data before a start code: garbage or the rest of a half-sent NAL. */
  corrupt = 0;
  readonly maxNal: number;

  constructor(maxNal = 4 * 1024 * 1024) {
    this.maxNal = maxNal;
  }

  push(chunk: Buffer): Buffer[] {
    const b = this.#buf.length ? Buffer.concat([this.#buf, chunk]) : chunk;
    const out: Buffer[] = [];
    for (let sc = findStart(b, this.#scan); sc >= 0; sc = findStart(b, sc + 3)) {
      if (this.#start >= 0) out.push(trimZeros(b.subarray(this.#start, sc)));
      else if (hasData(b.subarray(0, sc))) this.corrupt++;
      this.#start = sc + 3;
    }
    if (this.#start < 0) {
      // No start code: everything except the last 2 bytes (a possible "00 00" / "00" prefix) is dropped.
      const keep = Math.min(2, b.length);
      if (hasData(b.subarray(0, b.length - keep))) this.corrupt++;
      this.#buf = b.subarray(b.length - keep);
      this.#scan = 0;
      return out;
    }
    this.#buf = b.subarray(this.#start);
    this.#start = 0;
    // The last 2 bytes may form a start code with the next chunk.
    this.#scan = Math.max(0, this.#buf.length - 2);
    if (this.#buf.length > this.maxNal) {
      this.corrupt++;
      this.#reset();
    }
    return out;
  }

  /** The stream went quiet: the pending NAL counts as complete. */
  flush(): Buffer[] {
    const n = this.#start >= 0 ? trimZeros(this.#buf.subarray(this.#start)) : null;
    this.#reset();
    return n?.length ? [n] : [];
  }

  #reset() {
    this.#buf = Buffer.alloc(0);
    this.#start = -1;
    this.#scan = 0;
  }
}

function findStart(b: Buffer, from: number): number {
  let i = from;
  for (;;) {
    const j = b.indexOf(1, i + 2);
    if (j < 0) return -1;
    if (b[j - 1] === 0 && b[j - 2] === 0) return j - 2;
    i = j - 1;
  }
}

function trimZeros(n: Buffer): Buffer {
  let e = n.length;
  while (e > 0 && n[e - 1] === 0) e--;
  return n.subarray(0, e);
}

function hasData(b: Buffer): boolean {
  for (const x of b) if (x !== 0) return true;
  return false;
}

export const nalType = (n: Buffer) => n[0]! & 0x1f;
const isVcl = (t: number) => t >= 1 && t <= 5;
/** The first slice header field first_mb_in_slice ue(v): if 0, the first bit is 1. */
const firstSlice = (n: Buffer) => n.length > 1 && (n[1]! & 0x80) !== 0;

/**
 * Groups NALs into access units (H.264 7.4.1.2.3): after a unit containing VCL, an AUD/SPS/PPS/SEI or a slice with
 * first_mb_in_slice = 0 starts a new frame. [flush] (stream went quiet) also finishes the pending frame.
 */
export class AccessUnitParser {
  readonly nals = new NalSplitter();
  #cur: Buffer[] = [];
  #vcl = false;

  push(chunk: Buffer): AccessUnit[] {
    return this.#feed(this.nals.push(chunk));
  }

  flush(): AccessUnit[] {
    const out = this.#feed(this.nals.flush());
    if (this.#vcl) out.push(this.#close());
    return out;
  }

  get corrupt() {
    return this.nals.corrupt;
  }

  #feed(nals: Buffer[]): AccessUnit[] {
    const out: AccessUnit[] = [];
    for (const n of nals) {
      if (!n.length) continue;
      const t = nalType(n);
      const starts = t === NAL.aud || t === NAL.sps || t === NAL.pps || t === NAL.sei || (t >= 14 && t <= 18) || (isVcl(t) && firstSlice(n));
      if (this.#vcl && starts) out.push(this.#close());
      this.#cur.push(n);
      if (isVcl(t)) this.#vcl = true;
    }
    return out;
  }

  #close(): AccessUnit {
    const nals = this.#cur;
    this.#cur = [];
    this.#vcl = false;
    let sps: Buffer | null = null;
    let pps: Buffer | null = null;
    let key = false;
    const body: Buffer[] = [];
    for (const n of nals) {
      const t = nalType(n);
      if (t === NAL.sps) sps = Buffer.from(n);
      else if (t === NAL.pps) pps = Buffer.from(n);
      else if (t !== NAL.aud) {
        if (t === NAL.idr) key = true;
        body.push(n);
      }
    }
    return { data: annexB(body), key, sps, pps };
  }
}

/**
 * Keyframe gate: at the start and after a frame is dropped (socket buffer full) no frame is sent until the next IDR
 * (P-frames with missing references give a corrupt image). [offer] → "send" | "drop" | "wait" (waiting for IDR).
 */
export class KeyGate {
  /** Waiting for IDR. */
  waiting = true;

  offer(key: boolean, congested: boolean): "send" | "drop" | "wait" {
    if (congested) {
      this.waiting = true;
      return "drop";
    }
    if (this.waiting && !key) return "wait";
    this.waiting = false;
    return "send";
  }
}

// ---- frame header ----

/**
 * 16-byte frame header (big endian): u8 flags, u24 sequence, f64 time (ms, agent clock; pts for H.264), u16 width,
 * u16 height. Flags 0 = JPEG: same byte layout as the old u32 sequence header (sequence wraps at 2^24), old clients unaffected.
 */
export const FRAME = { h264: 0x10, key: 0x01, config: 0x02 } as const;
export const HEADER_SIZE = 16;

export function frameHeader(flags: number, seq: number, ts: number, w: number, h: number): Buffer {
  const head = Buffer.alloc(HEADER_SIZE);
  head.writeUInt32BE(((flags & 0xff) << 24 | (seq & 0xffffff)) >>> 0, 0);
  head.writeDoubleBE(ts, 4);
  head.writeUInt16BE(w, 12);
  head.writeUInt16BE(h, 14);
  return head;
}

export function parseHeader(b: Buffer): { flags: number; seq: number; ts: number; w: number; h: number } {
  return { flags: b[0]!, seq: b.readUInt32BE(0) & 0xffffff, ts: b.readDoubleBE(4), w: b.readUInt16BE(12), h: b.readUInt16BE(14) };
}
