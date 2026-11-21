// City points of the game map for the destination marker. MapLibre can only query tiles it has loaded (the ones in
// view), while the destination is usually far away; the z4 tiles hold every city (tippecanoe base zoom 4), so this reads
// them once with a minimal Mapbox Vector Tile decoder (points of layer `ets2` with type=city only).

function reader(buf) {
  let pos = 0;
  const varint = () => {
    let v = 0, mul = 1, b;
    do { b = buf[pos++]; v += (b & 0x7f) * mul; mul *= 128; } while (b & 0x80);
    return v;
  };
  return {
    get pos() { return pos; },
    done: () => pos >= buf.length,
    varint,
    bytes() { const n = varint(); const s = buf.subarray(pos, pos + n); pos += n; return s; },
    skip(wire) {
      if (wire === 0) varint();
      else if (wire === 1) pos += 8;
      else if (wire === 2) pos += varint();
      else if (wire === 5) pos += 4;
      else throw new Error(`wire type ${wire}`);
    },
  };
}

const utf8 = new TextDecoder();
const packed = (bytes) => { const r = reader(bytes), out = []; while (!r.done()) out.push(r.varint()); return out; };

function value(bytes) {
  const r = reader(bytes);
  while (!r.done()) {
    const tag = r.varint(), f = tag >> 3, w = tag & 7;
    if (f === 1) return utf8.decode(r.bytes());
    if (f === 2) { const v = new DataView(bytes.buffer, bytes.byteOffset + r.pos, 4).getFloat32(0, true); r.skip(5); return v; }
    if (f === 3) { const v = new DataView(bytes.buffer, bytes.byteOffset + r.pos, 8).getFloat64(0, true); r.skip(1); return v; }
    if (f === 4 || f === 5) return r.varint();
    if (f === 6) { const n = r.varint(); return n % 2 ? -(n + 1) / 2 : n / 2; }
    if (f === 7) return r.varint() !== 0;
    r.skip(w);
  }
  return null;
}

/** City points of one decoded (decompressed) tile: [{name, lngLat}]. */
export function citiesInTile(data, z, x, y) {
  const buf = new Uint8Array(data);
  const out = [];
  const t = reader(buf);
  while (!t.done()) {
    const tag = t.varint();
    if (tag >> 3 !== 3) { t.skip(tag & 7); continue; }
    const layer = reader(t.bytes());
    let name = '', extent = 4096;
    const keys = [], values = [], features = [];
    while (!layer.done()) {
      const lt = layer.varint(), f = lt >> 3;
      if (f === 1) name = utf8.decode(layer.bytes());
      else if (f === 2) features.push(layer.bytes());
      else if (f === 3) keys.push(utf8.decode(layer.bytes()));
      else if (f === 4) values.push(value(layer.bytes()));
      else if (f === 5) extent = layer.varint();
      else layer.skip(lt & 7);
    }
    if (name !== 'ets2') continue;
    const kType = keys.indexOf('type'), kName = keys.indexOf('name');
    for (const fb of features) {
      const fr = reader(fb);
      let tags = [], type = 0, geom = [];
      while (!fr.done()) {
        const ft = fr.varint(), f = ft >> 3;
        if (f === 2) tags = packed(fr.bytes());
        else if (f === 3) type = fr.varint();
        else if (f === 4) geom = packed(fr.bytes());
        else fr.skip(ft & 7);
      }
      if (type !== 1 || geom.length < 3) continue;
      let isCity = false, city = null;
      for (let i = 0; i + 1 < tags.length; i += 2) {
        if (tags[i] === kType && values[tags[i + 1]] === 'city') isCity = true;
        if (tags[i] === kName) city = values[tags[i + 1]];
      }
      if (!isCity || typeof city !== 'string') continue;
      const zz = (n) => (n % 2 ? -(n + 1) / 2 : n / 2);
      const px = (x + zz(geom[1]) / extent) / 2 ** z, py = (y + zz(geom[2]) / extent) / 2 ** z;
      out.push({ name: city, lngLat: [px * 360 - 180, (Math.atan(Math.sinh(Math.PI * (1 - 2 * py))) * 180) / Math.PI] });
    }
  }
  return out;
}

/** Folded form for matching telemetry city names against the map's (case, accents, punctuation). */
export const foldName = (s) => String(s).normalize('NFD').replace(/[̀-ͯ]/g, '').toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

/** The map city for a telemetry name: exact folded match, else one name being the start of the other ("Frankfurt"). */
export function findCity(cities, name) {
  const f = foldName(name);
  if (!f) return null;
  return cities.find((c) => foldName(c.name) === f)
    ?? cities.find((c) => { const g = foldName(c.name); return g.startsWith(f + ' ') || f.startsWith(g + ' '); }) ?? null;
}
