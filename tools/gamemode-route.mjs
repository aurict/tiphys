#!/usr/bin/env node
// Builds the Game mode route data (route.json) from the map build's routing graph and parsed game data. The display
// page loads it from /gamemode/map/route.json and draws the route to the job's destination company (display/route.js).
// Dependency-free (node: built-ins only). The inputs come from truckermudgeon/maps run as a separate tool
// (docs/features/game-mode.md › Map data); only its output files are read here.
//
//   node tools/gamemode-route.mjs [--graph=FILE] [--parsed=DIR] [--out=FILE]
//     --graph   default ~/.cache/tiphys-mapbuild/graph/europe-graph.json  (`npx generator graph -m europe …`)
//     --parsed  default ~/.cache/tiphys-mapbuild/parsed                   (`npx parser …`: nodes + companies)
//     --out     default ~/.local/share/tiphys/gamemode/map/route.json
//
// route.json (v1). Nodes are indexed 0…n−1; a routing state is (node, travel direction): s = 2·node + (backward ? 1 : 0).
//   x, z         node positions, game metres (0.1 m)
//   off, to, t   adjacency of the states: the edges of s are off[s] … off[s+1]−1, edge e leads to state to[e] and takes
//                t[e] seconds (the graph's estimated duration)
//   companies    "<company token>.<city token>" → node index of the company's entrance (the telemetry's
//                job.toCompanyId and job.toCityId)

import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const args = Object.fromEntries(process.argv.slice(2).map((a) => {
  const m = /^--(graph|parsed|out)=(.+)$/.exec(a);
  if (!m) { console.error(`unknown argument: ${a}\nusage: node tools/gamemode-route.mjs [--graph=FILE] [--parsed=DIR] [--out=FILE]`); process.exit(2); }
  return [m[1], m[2]];
}));
const home = os.homedir();
const GRAPH = path.resolve(args.graph ?? path.join(home, '.cache/tiphys-mapbuild/graph/europe-graph.json'));
const PARSED = path.resolve(args.parsed ?? path.join(home, '.cache/tiphys-mapbuild/parsed'));
const OUT = path.resolve(args.out ?? path.join(process.env.XDG_DATA_HOME || path.join(home, '.local/share'), 'tiphys/gamemode/map/route.json'));
const COMPANY_SNAP = 500; // m: a company whose own node isn't routable takes the nearest graph node within this

const read = (f) => JSON.parse(fs.readFileSync(f, 'utf8'));
const graph = read(GRAPH).graph; // [[uid, {forward: Neighbor[], backward: Neighbor[]}], …]
const pos = new Map();
for (const n of read(path.join(PARSED, 'europe-nodes.json'))) pos.set(n.uid, [n.x, n.y]);

// Every graph node (sources and neighbours) with a known position gets an index.
const index = new Map();
const add = (uid) => { if (!index.has(uid) && pos.has(uid)) index.set(uid, index.size); };
for (const [uid, n] of graph) { add(uid); for (const e of [...n.forward, ...n.backward]) add(e.nodeUid); }
const n = index.size;
const x = new Array(n), z = new Array(n);
for (const [uid, i] of index) { const [a, b] = pos.get(uid); x[i] = Math.round(a * 10) / 10; z[i] = Math.round(b * 10) / 10; }

const edges = Array.from({ length: 2 * n }, () => []);
const routable = new Uint8Array(n); // has an edge into it
let dropped = 0;
for (const [uid, nb] of graph) {
  const i = index.get(uid);
  if (i === undefined) { dropped += nb.forward.length + nb.backward.length; continue; }
  for (const [dir, list] of [[0, nb.forward], [1, nb.backward]]) for (const e of list) {
    const j = index.get(e.nodeUid);
    if (j === undefined) { dropped++; continue; }
    edges[2 * i + dir].push([2 * j + (e.direction === 'backward' ? 1 : 0), Math.round(e.duration * 10) / 10]);
    routable[j] = 1;
  }
}
const off = [0], to = [], t = [];
for (const list of edges) { for (const [s, d] of list) { to.push(s); t.push(d); } off.push(to.length); }

// Company entrances. Grid over routable nodes for the nearest-node fallback.
const CELL = 1000, grid = new Map();
const key = (a, b) => `${Math.floor(a / CELL)},${Math.floor(b / CELL)}`;
for (let i = 0; i < n; i++) if (routable[i]) { const k = key(x[i], z[i]); if (!grid.has(k)) grid.set(k, []); grid.get(k).push(i); }
function nearest(a, b) {
  let best = -1, bd = COMPANY_SNAP ** 2;
  for (let dx = -1; dx <= 1; dx++) for (let dz = -1; dz <= 1; dz++) {
    for (const i of grid.get(key(a + dx * CELL, b + dz * CELL)) ?? []) { const d = (x[i] - a) ** 2 + (z[i] - b) ** 2; if (d < bd) { bd = d; best = i; } }
  }
  return best;
}
const companies = {};
let unplaced = 0;
for (const c of read(path.join(PARSED, 'europe-companies.json'))) {
  const own = index.get(c.nodeUid);
  const i = own !== undefined && routable[own] ? own : nearest(c.x, c.y);
  if (i < 0) { unplaced++; continue; }
  companies[`${c.token}.${c.cityToken}`] = i;
}

fs.mkdirSync(path.dirname(OUT), { recursive: true });
const tmp = `${OUT}.${process.pid}.tmp`;
fs.writeFileSync(tmp, JSON.stringify({ v: 1, x, z, off, to, t, companies }));
fs.renameSync(tmp, OUT);
console.log(`route.json: ${n} nodes, ${to.length} edges (${dropped} without a node position dropped), ` +
  `${Object.keys(companies).length} companies (${unplaced} too far from a road), ${(fs.statSync(OUT).size / 1e6).toFixed(1)} MB → ${OUT}`);
