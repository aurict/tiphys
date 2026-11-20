// Route line to the job's destination company. ETS2's telemetry doesn't export the in-game GPS route, so it is planned
// here over route.json (tools/gamemode-route.mjs, built from the user's own map data; served at /gamemode/map/). Fastest
// path (A*) by the graph's estimated durations; it can differ from the in-game GPS. Memory only.
//
//   const nav = createNavigator(load)   load: async () => route.json object | null (null: no route data, stays off)
//   nav.update(truck, now)  every `truck` message; returns true when the line or the destination changed
//   nav.line(maxM)          [[x, z], …] game metres from the truck along the route, up to the first point past
//                           maxM (null: no route)
//   nav.dest                [x, z] of the destination company's entrance, or null

const VMAX = 40;           // m/s, A* heuristic (above the graph's road speeds)
const SNAP = [150, 600];   // m: search radii for the start node
const WRONG_WAY = 900;     // s: start cost of a state facing away from the truck (a U-turn is a last resort)
const OFF_ROUTE = 60;      // m from the line (chords cut curves a little)
const OFF_FOR = 3000;      // ms off the line before replanning
const REPLAN_GAP = 5000;   // ms between plans
const LOOKAHEAD = 60;      // route points searched ahead of the last match
const CELL = 500;

/** Graph over route.json: plan(x, z, heading, target) → node indices of the fastest path, or null. */
export function createGraph(d) {
  const n = d.x.length;
  const x = Float64Array.from(d.x), z = Float64Array.from(d.z);
  const off = Int32Array.from(d.off), to = Int32Array.from(d.to), t = Float32Array.from(d.t);
  const grid = new Map();
  const key = (a, b) => `${Math.floor(a / CELL)},${Math.floor(b / CELL)}`;
  for (let i = 0; i < n; i++) { const k = key(x[i], z[i]); if (!grid.has(k)) grid.set(k, []); grid.get(k).push(i); }
  function near(a, b, r) {
    const out = [], c = Math.ceil(r / CELL);
    for (let dx = -c; dx <= c; dx++) for (let dz = -c; dz <= c; dz++) {
      for (const i of grid.get(key(a + dx * CELL, b + dz * CELL)) ?? []) if ((x[i] - a) ** 2 + (z[i] - b) ** 2 <= r * r) out.push(i);
    }
    return out;
  }

  const g = new Float64Array(2 * n), prev = new Int32Array(2 * n);
  function plan(px, pz, heading, target) {
    if (!(target >= 0 && target < n)) return null;
    // SCS heading: 0 = north (−z), counter-clockwise → forward vector (−sin a, −cos a).
    const a = heading * Math.PI * 2, hx = -Math.sin(a), hz = -Math.cos(a);
    g.fill(Infinity); prev.fill(-1);
    const heap = new Heap();
    const h = (s) => Math.hypot(x[s >> 1] - x[target], z[s >> 1] - z[target]) / VMAX;
    for (const r of SNAP) {
      for (const i of near(px, pz, r)) {
        const vx = x[i] - px, vz = z[i] - pz, dist = Math.hypot(vx, vz);
        if (dist > 20 && (vx * hx + vz * hz) / dist < -0.3) continue; // behind the truck
        for (const s of [2 * i, 2 * i + 1]) {
          if (off[s] === off[s + 1] && i !== target) continue;
          // The state's travel direction: toward its next nodes.
          let ex = 0, ez = 0;
          for (let e = off[s]; e < off[s + 1]; e++) { const j = to[e] >> 1, l = Math.hypot(x[j] - x[i], z[j] - z[i]) || 1; ex += (x[j] - x[i]) / l; ez += (z[j] - z[i]) / l; }
          const el = Math.hypot(ex, ez);
          const cost = dist / 15 + (el && (ex * hx + ez * hz) / el < 0.2 ? WRONG_WAY : 0);
          if (cost < g[s]) { g[s] = cost; heap.push(cost + h(s), s); }
        }
      }
      if (heap.size) break;
    }
    while (heap.size) {
      const [f, s] = heap.pop();
      if ((s >> 1) === target) {
        const path = [];
        for (let u = s; u !== -1; u = prev[u]) path.push(u >> 1);
        return path.reverse();
      }
      if (f > g[s] + h(s) + 1e-6) continue;
      for (let e = off[s]; e < off[s + 1]; e++) {
        const v = to[e], c = g[s] + t[e];
        if (c < g[v]) { g[v] = c; prev[v] = s; heap.push(c + h(v), v); }
      }
    }
    return null;
  }
  return { plan, pos: (i) => [x[i], z[i]], company: (id) => d.companies?.[id] ?? -1 };
}

class Heap {
  constructor() { this.f = []; this.s = []; }
  get size() { return this.f.length; }
  push(f, s) {
    const F = this.f, S = this.s;
    let i = F.length; F.push(f); S.push(s);
    while (i > 0) { const p = (i - 1) >> 1; if (F[p] <= f) break; F[i] = F[p]; S[i] = S[p]; i = p; }
    F[i] = f; S[i] = s;
  }
  pop() {
    const F = this.f, S = this.s, top = [F[0], S[0]], f = F.pop(), s = S.pop();
    if (F.length) {
      let i = 0;
      for (;;) {
        const l = 2 * i + 1, r = l + 1;
        let m = i, mf = f;
        if (l < F.length && F[l] < mf) { m = l; mf = F[l]; }
        if (r < F.length && F[r] < mf) m = r;
        if (m === i) break;
        F[i] = F[m]; S[i] = S[m]; i = m;
      }
      F[i] = f; S[i] = s;
    }
    return top;
  }
}

/** Closest point on segment a→b to p: [distance², t 0…1]. */
function project(p, a, b) {
  const dx = b[0] - a[0], dz = b[1] - a[1], l2 = dx * dx + dz * dz;
  const k = l2 ? Math.max(0, Math.min(1, ((p[0] - a[0]) * dx + (p[1] - a[1]) * dz) / l2)) : 0;
  return [(a[0] + dx * k - p[0]) ** 2 + (a[1] + dz * k - p[1]) ** 2, k];
}

export function createNavigator(load) {
  let graph = null, loading = null;
  let jobKey = null, target = -1;
  let pts = null, seg = 0, cut = 0; // route points [x, z]; the truck is on segment seg at fraction cut
  let truckAt = null, offSince = 0, plannedAt = -Infinity;

  function replan(tr, now) {
    plannedAt = now;
    offSince = 0;
    const path = graph.plan(tr.x, tr.z, tr.heading ?? 0, target);
    pts = path ? path.map((i) => graph.pos(i)) : null;
    seg = 0; cut = 0;
    if (!path) console.warn('[route] no path to the destination');
  }

  function update(tr, now = performance.now()) {
    const ids = tr?.job?.toCompanyId && tr.job.toCityId ? `${tr.job.toCompanyId}.${tr.job.toCityId}` : null;
    if (ids && !graph && !loading) {
      loading = Promise.resolve(load()).then((d) => { graph = d ? createGraph(d) : false; }, (e) => { console.warn('[route] no route data:', e?.message ?? e); graph = false; });
    }
    if (ids !== jobKey) {
      jobKey = ids; pts = null; target = -1; plannedAt = -Infinity;
      if (!ids) return true;
    }
    if (!graph || !ids || tr.x == null || tr.state === 'none') return false;
    if (target < 0) {
      target = graph.company(ids);
      if (target < 0) { console.warn('[route] destination company not in route.json:', ids); target = -2; return false; }
    }
    if (target === -2) return false;
    truckAt = [tr.x, tr.z];
    if (!pts) {
      if (now - plannedAt < REPLAN_GAP) return false;
      replan(tr, now);
      return true;
    }
    // Progress: nearest segment a little ahead of the last match.
    let best = Infinity, bs = seg, bk = cut;
    for (let i = seg; i < Math.min(pts.length - 1, seg + LOOKAHEAD); i++) {
      const [d2, k] = project(truckAt, pts[i], pts[i + 1]);
      if (d2 < best) { best = d2; bs = i; bk = k; }
    }
    if (pts.length < 2 || best <= OFF_ROUTE ** 2) {
      offSince = 0;
      const moved = bs !== seg;
      seg = bs; cut = bk;
      return moved;
    }
    if (!offSince) offSince = now;
    if (now - offSince >= OFF_FOR && now - plannedAt >= REPLAN_GAP) { replan(tr, now); return true; }
    return false;
  }

  function line(maxM = Infinity) {
    if (!pts || !truckAt) return null;
    const a = pts[seg], b = pts[seg + 1] ?? a;
    const out = [truckAt, [a[0] + (b[0] - a[0]) * cut, a[1] + (b[1] - a[1]) * cut]];
    let len = 0;
    for (let i = seg + 1; i < pts.length && len < maxM; i++) {
      const p = out.at(-1);
      len += Math.hypot(pts[i][0] - p[0], pts[i][1] - p[1]);
      out.push(pts[i]);
    }
    return out;
  }

  return {
    update,
    line,
    get dest() { return pts ? pts.at(-1) : null; },
  };
}
