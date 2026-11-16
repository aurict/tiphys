// Firefox native messaging frame: 4-byte length (machine byte order) + UTF-8 JSON. The same frame is used both between
// Firefox ⇄ helper (stdin/stdout) and helper ⇄ agent (unix socket); the helper forwards the payload without parsing it.
// Messages are at most 1 MB in both directions; a larger one breaks the stream (after the length is read) → the
// connection is closed.
import { endianness } from "node:os";

export const FRAME_MAX = 1024 * 1024;
const LE = endianness() === "LE";

export class FrameTooLarge extends Error {
  readonly size: number;
  constructor(size: number) {
    super(`ileti çok büyük: ${size} bayt`);
    this.size = size;
  }
}

export function encodeFrame(payload: Buffer | string | object): Buffer {
  const body = Buffer.isBuffer(payload) ? payload : Buffer.from(typeof payload === "string" ? payload : JSON.stringify(payload), "utf8");
  if (body.length > FRAME_MAX) throw new FrameTooLarge(body.length);
  const head = Buffer.alloc(4);
  if (LE) head.writeUInt32LE(body.length);
  else head.writeUInt32BE(body.length);
  return Buffer.concat([head, body]);
}

/**
 * Extracts complete payloads from split/merged chunks. Throws FrameTooLarge for an over-limit length; if [onOversize]
 * is given it doesn't throw: that frame's bytes are skipped unread (the stream stays intact since the length is known)
 * and [onOversize] is called.
 */
export class FrameDecoder {
  #buf: Buffer = Buffer.alloc(0);
  #skip = 0;
  readonly max: number;
  readonly onOversize: ((size: number) => void) | null;

  constructor(max = FRAME_MAX, onOversize: ((size: number) => void) | null = null) {
    this.max = max;
    this.onOversize = onOversize;
  }

  push(chunk: Buffer): Buffer[] {
    if (this.#skip > 0) {
      const n = Math.min(this.#skip, chunk.length);
      this.#skip -= n;
      chunk = chunk.subarray(n);
    }
    this.#buf = this.#buf.length ? Buffer.concat([this.#buf, chunk]) : chunk;
    const out: Buffer[] = [];
    while (this.#buf.length >= 4) {
      const len = LE ? this.#buf.readUInt32LE(0) : this.#buf.readUInt32BE(0);
      if (len > this.max) {
        if (!this.onOversize) throw new FrameTooLarge(len);
        this.onOversize(len);
        const n = Math.min(len, this.#buf.length - 4);
        this.#skip = len - n;
        this.#buf = this.#buf.subarray(4 + n);
        continue;
      }
      if (this.#buf.length < 4 + len) break;
      out.push(this.#buf.subarray(4, 4 + len));
      this.#buf = this.#buf.subarray(4 + len);
    }
    return out;
  }
}
