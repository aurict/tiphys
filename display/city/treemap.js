// Squarified treemap for the code city (PLAN.md §20 E-2; from the W0 draft): folder = district (rectangle with a
// street around it), file = building. Area ∝ lines^0.8 (+ a floor so one-liners stay visible); single-child folder
// chains are collapsed (app/lib/… → one district). Output is in world units on the XZ plane, centred on the origin.
// Shared by the WebGL city (scene3d.js) and the flat fallback (flat.js).

const weight = (lines) => 6 + Math.pow(Math.max(1, lines), 0.8);

function buildTree(files) {
  const root = { name: '', children: new Map(), files: [], value: 0 };
  for (const f of files) {
    const parts = f.path.split('/');
    let node = root;
    for (let i = 0; i < parts.length - 1; i++) {
      let c = node.children.get(parts[i]);
      if (!c) { c = { name: parts[i], children: new Map(), files: [], value: 0 }; node.children.set(parts[i], c); }
      node = c;
    }
    node.files.push(f);
  }
  const sum = (n) => {
    n.value = n.files.reduce((a, f) => a + weight(f.lines), 0);
    for (const c of n.children.values()) n.value += sum(c);
    return n.value;
  };
  sum(root);
  return root;
}

function worst(areas, side) {
  let s = 0, mx = 0, mn = Infinity;
  for (const a of areas) { s += a; if (a > mx) mx = a; if (a < mn) mn = a; }
  const s2 = s * s, w2 = side * side;
  return Math.max((w2 * mx) / s2, s2 / (w2 * mn));
}

/** Squarify `items` ({value}) into rect; calls place(item, x, y, w, h). */
function squarify(items, x, y, w, h, place) {
  const total = items.reduce((a, i) => a + i.value, 0);
  if (!total || w <= 0 || h <= 0) return;
  const k = (w * h) / total;
  let rest = items.slice().sort((a, b) => b.value - a.value);
  while (rest.length) {
    const side = Math.min(w, h);
    const row = [rest[0].value * k];
    let n = 1, cur = worst(row, side);
    while (n < rest.length) {
      row.push(rest[n].value * k);
      const nw = worst(row, side);
      if (nw > cur) { row.pop(); break; }
      cur = nw; n++;
    }
    const rowArea = row.reduce((a, b) => a + b, 0);
    if (w >= h) {
      const cw = rowArea / h; let yy = y;
      for (let i = 0; i < n; i++) { const rh = row[i] / cw; place(rest[i], x, yy, cw, rh); yy += rh; }
      x += cw; w -= cw;
    } else {
      const rh = rowArea / w; let xx = x;
      for (let i = 0; i < n; i++) { const rw = row[i] / rh; place(rest[i], xx, y, rw, rh); xx += rw; }
      y += rh; h -= rh;
    }
    rest = rest.slice(n);
  }
}

/**
 * files: [{path, lines, …}] → { buildings: [{file, x, z, w, d, depth}], districts: [{name, x, z, w, d, depth}] }
 * Building/district x,z are centres.
 */
export function layoutCity(files, W, D) {
  const root = buildTree(files);
  const buildings = [], districts = [];
  const STREET = [1.6, 0.9, 0.55, 0.4]; // street width by depth
  const GAP = 0.16;                    // space between buildings, as a fraction of the smaller side (max 0.6)

  function visit(node, x, y, w, h, depth, label) {
    // Collapse a folder that only contains one folder.
    while (node.files.length === 0 && node.children.size === 1) {
      const only = [...node.children.values()][0];
      label = label ? `${label}/${only.name}` : only.name;
      node = only;
    }
    if (depth > 0) {
      districts.push({ name: label, x: x + w / 2, z: y + h / 2, w, d: h, depth });
      const p = Math.min(STREET[Math.min(depth - 1, STREET.length - 1)], w * 0.12, h * 0.12);
      x += p; y += p; w -= 2 * p; h -= 2 * p;
    }
    const items = [
      ...[...node.children.values()].map((c) => ({ value: c.value, folder: c })),
      ...node.files.map((f) => ({ value: weight(f.lines), file: f })),
    ];
    squarify(items, x, y, w, h, (it, ix, iy, iw, ih) => {
      if (it.folder) return visit(it.folder, ix, iy, iw, ih, depth + 1, it.folder.name);
      const g = Math.min(0.6, Math.min(iw, ih) * GAP);
      buildings.push({ file: it.file, x: ix + iw / 2, z: iy + ih / 2, w: Math.max(0.2, iw - g), d: Math.max(0.2, ih - g), depth });
    });
  }
  visit(root, -W / 2, -D / 2, W, D, 0, '');
  return { buildings, districts };
}

/** Building height in world units: log of the line count. */
export const heightOf = (lines) => 0.4 + Math.log2(Math.max(1, lines) + 1) * 0.78;
