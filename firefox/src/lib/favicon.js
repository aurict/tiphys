// Tab icon: only `data:` URLs, downscaled to at most 32 px as PNG data:. Remote icons are NOT downloaded
// (no network request); data: URLs are decoded by hand (no fetch). Undecodable (SVG etc.) → null.

const MAX_INPUT = 512 * 1024;
const SIZE = 32;

/** "data:image/png;base64,…" → {mime, bytes} or null. */
export function decodeDataUrl(u) {
  if (typeof u !== "string" || u.length > MAX_INPUT || !u.startsWith("data:")) return null;
  const comma = u.indexOf(",");
  if (comma < 0) return null;
  const meta = u.slice(5, comma).split(";");
  const mime = (meta[0] || "").toLowerCase();
  if (!/^image\/[a-z0-9.+-]+$/.test(mime)) return null;
  const data = u.slice(comma + 1);
  try {
    if (meta.includes("base64")) {
      const bin = atob(data);
      const bytes = new Uint8Array(bin.length);
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
      return { mime, bytes };
    }
    return { mime, bytes: new TextEncoder().encode(decodeURIComponent(data)) };
  } catch {
    return null;
  }
}

/** Size whose sides are at most [size]. */
export function fitSize(w, h, size = SIZE) {
  const s = Math.min(1, size / Math.max(w, h, 1));
  return { w: Math.max(1, Math.round(w * s)), h: Math.max(1, Math.round(h * s)) };
}

function toBase64(bytes) {
  let bin = "";
  for (let i = 0; i < bytes.length; i += 0x8000) bin += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(bin);
}

/** Cached downscaler; [g] supplies fake createImageBitmap/OffscreenCanvas in tests. */
export function makeFavicon(g = globalThis) {
  const cache = new Map();
  return async (u) => {
    if (typeof u !== "string" || !u.startsWith("data:")) return null;
    if (cache.has(u)) return cache.get(u);
    let out = null;
    const d = decodeDataUrl(u);
    if (d) {
      try {
        const bmp = await g.createImageBitmap(new Blob([d.bytes], { type: d.mime }));
        const { w, h } = fitSize(bmp.width, bmp.height);
        const canvas = new g.OffscreenCanvas(w, h);
        canvas.getContext("2d").drawImage(bmp, 0, 0, w, h);
        bmp.close?.();
        const blob = await canvas.convertToBlob({ type: "image/png" });
        out = `data:image/png;base64,${toBase64(new Uint8Array(await blob.arrayBuffer()))}`;
      } catch {
        out = null;
      }
    }
    if (cache.size > 300) cache.clear();
    cache.set(u, out);
    return out;
  };
}
