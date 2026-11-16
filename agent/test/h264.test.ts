// 10.2 Phase C: Annex-B parser (3/4-byte start codes, splits at chunk boundaries, AUD/SPS/PPS/SEI/IDR/
// non-IDR slices), access unit boundaries, finishing a frame on silence, keyframe gate, frame header.
import { describe, expect, it } from "vitest";
import { AccessUnitParser, FRAME, KeyGate, NalSplitter, annexB, frameHeader, nalType, parseHeader } from "../src/h264.ts";

const AUD = Buffer.from([0x09, 0xf0]);
const SPS = Buffer.from([0x67, 0x64, 0x00, 0x1f, 0xac, 0xd9, 0x40, 0x48]);
const PPS = Buffer.from([0x68, 0xee, 0x3c, 0x80]);
const SEI = Buffer.from([0x06, 0x05, 0x03, 0x11, 0x22, 0x33, 0x80]);
/** first_mb_in_slice = 0 → the top bit of the second byte is 1. */
const idr = (n: number) => Buffer.concat([Buffer.from([0x65, 0x88, 0x84]), Buffer.alloc(n, 0x5a), Buffer.from([0x80])]);
const pslice = (tag: number, n = 20) => Buffer.concat([Buffer.from([0x41, 0x9a, tag]), Buffer.alloc(n, tag), Buffer.from([0x40])]);
/** Second slice of the same frame (first_mb_in_slice ≠ 0). */
const pslice2 = Buffer.from([0x41, 0x40, 0x11, 0x22, 0x80]);

const sc3 = Buffer.from([0, 0, 1]);
const sc4 = Buffer.from([0, 0, 0, 1]);

/** Stream with mixed 3/4-byte codes: frame 1 (AUD SPS PPS SEI IDR), frame 2 (SEI P P2), frame 3 (P). */
function stream(): { bytes: Buffer; frames: Buffer[][] } {
  const f1 = [AUD, SPS, PPS, SEI, idr(300)];
  const f2 = [SEI, pslice(1), pslice2];
  const f3 = [pslice(2, 5)];
  const parts: Buffer[] = [];
  let i = 0;
  for (const n of [...f1, ...f2, ...f3]) parts.push(i++ % 2 ? sc3 : sc4, n);
  return { bytes: Buffer.concat(parts), frames: [f1, f2, f3] };
}

describe("Annex-B NAL ayırıcı", () => {
  it("3 ve 4 baytlık başlangıç kodları, her bölme noktası, bayt bayt", () => {
    const { bytes, frames } = stream();
    const all = frames.flat();
    for (let cut = 1; cut < bytes.length; cut++) {
      const s = new NalSplitter();
      const out = [...s.push(bytes.subarray(0, cut)), ...s.push(bytes.subarray(cut)), ...s.flush()];
      expect(out.map((n) => n.toString("hex")), `kesim ${cut}`).toEqual(all.map((n) => n.toString("hex")));
      expect(s.corrupt).toBe(0);
    }
    const s = new NalSplitter();
    const got: Buffer[] = [];
    for (const b of bytes) got.push(...s.push(Buffer.from([b])));
    got.push(...s.flush());
    expect(got.map(nalType)).toEqual([9, 7, 8, 6, 5, 6, 1, 1, 1]);
  });

  it("başlangıç kodundan önceki çöp ve susmadan sonra başlangıç kodsuz devam bozuk sayılır", () => {
    const s = new NalSplitter();
    expect(s.push(Buffer.concat([Buffer.from([0x12, 0x34]), sc4, SPS, sc3]))).toEqual([SPS]);
    expect(s.corrupt).toBe(1);
    expect(s.flush()).toEqual([]); // empty NAL
    // A half frame was finished on silence, the rest arrived without a start code → dropped.
    expect(s.push(Buffer.concat([sc4, pslice(3).subarray(0, 10)]))).toEqual([]);
    expect(s.flush()).toHaveLength(1);
    expect(s.push(Buffer.concat([pslice(3).subarray(10), sc4, PPS]))).toEqual([]);
    expect(s.corrupt).toBe(2);
    expect(s.flush()).toEqual([PPS]);
    // A NAL over the limit is dropped.
    const small = new NalSplitter(50);
    expect(small.push(Buffer.concat([sc4, idr(100)]))).toEqual([]);
    expect(small.corrupt).toBe(1);
    expect(small.push(Buffer.concat([sc4, PPS, sc4]))).toEqual([PPS]);
  });
});

describe("erişim birimleri", () => {
  it("kare sınırları: AUD/SPS/PPS/SEI ve first_mb=0 dilim yeni kare; SPS/PPS/AUD gövdeden çıkar", () => {
    const { bytes, frames } = stream();
    for (const cut of [1, 7, 30, bytes.length - 3]) {
      const p = new AccessUnitParser();
      const aus = [...p.push(bytes.subarray(0, cut)), ...p.push(bytes.subarray(cut)), ...p.flush()];
      expect(aus.map((a) => a.key), `kesim ${cut}`).toEqual([true, false, false]);
      expect(aus[0]!.sps).toEqual(SPS);
      expect(aus[0]!.pps).toEqual(PPS);
      expect(aus[1]!.sps).toBeNull();
      expect(aus[0]!.data).toEqual(annexB([SEI, idr(300)]));
      expect(aus[1]!.data).toEqual(annexB(frames[1]!));
      expect(aus[2]!.data).toEqual(annexB(frames[2]!));
    }
  });

  it("kare, bir sonraki başlangıç beklenmeden susmayla biter (gecikme yok)", () => {
    const p = new AccessUnitParser();
    expect(p.push(annexB([SPS, PPS, idr(50)]))).toEqual([]);
    const a = p.flush();
    expect(a).toHaveLength(1);
    expect(a[0]!.key).toBe(true);
    expect(p.push(annexB([pslice(4)]))).toEqual([]);
    expect(p.flush().map((x) => x.key)).toEqual([false]);
    // A partial unit without VCL (SEI only) isn't sent on silence; it is merged with the next frame.
    expect(p.push(annexB([SEI]))).toEqual([]);
    expect(p.flush()).toEqual([]);
    p.push(annexB([pslice(5)]));
    expect(p.flush()[0]!.data).toEqual(annexB([SEI, pslice(5)]));
  });
});

describe("anahtar kare kapısı", () => {
  it("IDR'ye kadar bekler; tıkanınca atlar ve bir sonraki IDR'ye kadar P-kare göndermez", () => {
    const g = new KeyGate();
    expect(g.offer(false, false)).toBe("wait");
    expect(g.offer(true, false)).toBe("send");
    expect(g.offer(false, false)).toBe("send");
    expect(g.offer(false, true)).toBe("drop");
    expect(g.offer(false, false)).toBe("wait"); // the buffer drained but the reference is missing
    expect(g.offer(true, true)).toBe("drop"); // an IDR is skipped too under congestion
    expect(g.offer(false, false)).toBe("wait");
    expect(g.offer(true, false)).toBe("send");
    expect(g.offer(false, false)).toBe("send");
  });
});

describe("kare başlığı", () => {
  it("bayrak + 24 bit sıra; JPEG'de (bayrak 0) eski u32 sıra düzeniyle aynı", () => {
    const j = frameHeader(0, 7, 1234.5, 1152, 648);
    expect([j.readUInt32BE(0), j.readDoubleBE(4), j.readUInt16BE(12), j.readUInt16BE(14), j.length]).toEqual([7, 1234.5, 1152, 648, 16]);
    const h = frameHeader(FRAME.h264 | FRAME.key, 0x1234567, 99.25, 1280, 720);
    expect(h[0]).toBe(0x11);
    expect(parseHeader(h)).toEqual({ flags: 0x11, seq: 0x234567, ts: 99.25, w: 1280, h: 720 });
    expect(parseHeader(frameHeader(FRAME.h264 | FRAME.config, 1, 0, 2, 2)).flags).toBe(0x12);
  });
});
