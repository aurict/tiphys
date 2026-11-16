// Unsigned XPI: src/ → dist/tiphys-bridge-<version>.xpi (zip; dependency-free writer, zlib deflate + crc32).
// The vendor files' hashes are rechecked before packaging.
import { createHash } from "node:crypto";
import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";
import { crc32, deflateRawSync } from "node:zlib";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const src = join(root, "src");
const READABILITY_SHA = "34dcab3d0832d0019f02990eed6b6124e029e8c32b9f0c6f2550544ff8dff174";

async function files(dir) {
  const out = [];
  for (const e of await readdir(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...(await files(p)));
    else if (e.isFile()) out.push(p);
  }
  return out.sort();
}

const vendored = await readFile(join(src, "vendor/Readability.js")).catch(() => null);
if (!vendored || createHash("sha256").update(vendored).digest("hex") !== READABILITY_SHA) {
  throw new Error("src/vendor/Readability.js yok ya da özeti tutmuyor: önce npm run vendor");
}

// Fixed timestamp (1980-01-01): the same source produces the same XPI.
const DOS_TIME = 0;
const DOS_DATE = (0 << 9) | (1 << 5) | 1;
const locals = [];
const centrals = [];
let offset = 0;
for (const f of await files(src)) {
  const name = Buffer.from(relative(src, f).split("\\").join("/"), "utf8");
  const data = await readFile(f);
  const comp = deflateRawSync(data, { level: 9 });
  const crc = crc32(data);
  const head = Buffer.alloc(30);
  head.writeUInt32LE(0x04034b50, 0);
  head.writeUInt16LE(20, 4);
  head.writeUInt16LE(0x0800, 6); // UTF-8 adlar
  head.writeUInt16LE(8, 8);
  head.writeUInt16LE(DOS_TIME, 10);
  head.writeUInt16LE(DOS_DATE, 12);
  head.writeUInt32LE(crc, 14);
  head.writeUInt32LE(comp.length, 18);
  head.writeUInt32LE(data.length, 22);
  head.writeUInt16LE(name.length, 26);
  locals.push(head, name, comp);
  const cen = Buffer.alloc(46);
  cen.writeUInt32LE(0x02014b50, 0);
  cen.writeUInt16LE(20, 4);
  cen.writeUInt16LE(20, 6);
  cen.writeUInt16LE(0x0800, 8);
  cen.writeUInt16LE(8, 10);
  cen.writeUInt16LE(DOS_TIME, 12);
  cen.writeUInt16LE(DOS_DATE, 14);
  cen.writeUInt32LE(crc, 16);
  cen.writeUInt32LE(comp.length, 20);
  cen.writeUInt32LE(data.length, 24);
  cen.writeUInt16LE(name.length, 28);
  cen.writeUInt32LE(offset, 42);
  centrals.push(cen, name);
  offset += head.length + name.length + comp.length;
}
const cdir = Buffer.concat(centrals);
const end = Buffer.alloc(22);
end.writeUInt32LE(0x06054b50, 0);
end.writeUInt16LE(centrals.length / 2, 8);
end.writeUInt16LE(centrals.length / 2, 10);
end.writeUInt32LE(cdir.length, 12);
end.writeUInt32LE(offset, 16);

const { version } = JSON.parse(await readFile(join(src, "manifest.json"), "utf8"));
const dist = join(root, "dist");
await rm(dist, { recursive: true, force: true });
await mkdir(dist, { recursive: true });
const out = join(dist, `tiphys-bridge-${version}.xpi`);
await writeFile(out, Buffer.concat([...locals, cdir, end]));
console.log(out);
