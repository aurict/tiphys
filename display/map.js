// Map card. Interface (main.js):
//   const map = createMap(el)      el: the element to fill
//   map.update(truck)              every `truck` message (contract fields x, z, heading, speed, state)
//   map.setDestination(name|null)  job destination city: marked on the map when the name matches a map city (until a
//                                  route to the destination company is known: route.js, /gamemode/map/route.json)
//   map.setMotion('low'|'normal'|'high'), map.setTone([r,g,b])
//   map.frame(now)                 called from the page's animation loop
// The real map is MapLibre GL (vendor/) over the PMTiles the agent serves from ~/.local/share/tiphys/gamemode/map/
// (/gamemode/map/…). Until it has loaded — and for good when the map files are missing or WebGL fails — the radar
// (radar.js) is shown instead. The camera follows the truck heading-up; MapLibre only renders when this module moves
// the camera (≤30 times a second, every frame with motion=high) or a tile arrives. The trail is in memory only.
import { createRadar } from './radar.js';
import { gameToLngLat, headingBearing } from './projection.js';
import { citiesInTile, findCity } from './cities.js';
import { createNavigator } from './route.js';

const MAP = new URL('map/', import.meta.url).href;      // /gamemode/map/
const VENDOR = new URL('vendor/', import.meta.url).href;
const TRAIL_STEP = 8;        // game m between trail points
const TRAIL_MAX = 5000;
const JUMP = 3000;           // game m: a bigger jump (ferry, train, teleport) breaks the trail
const PITCH = 50;
const ROUTE_AHEAD = 8000;    // game m of the route line drawn ahead of the truck
const ROUTE_EVERY = 250;     // ms between route line updates

const C = {                  // Tiphys dark tokens (tokens.css) mapped onto the map
  land: '#050507',
  water: '#0C0E26',          // deep indigo
  border: 'rgba(174, 174, 178, 0.20)',
  areaRoad: '#141417', areaLight: '#0D0D11', areaDark: '#0A0A0D', areaGreen: '#09100C',
  prefab: '#1B1B1F',
  local: '#262629', divided: '#333337', freeway: '#4A5070',          // accent #A5B4FC at ~42 % over the land, opaque (no doubled alpha at joins)
  ferry: '#454B69',
  label: '#E5E5EA', labelSoft: '#98989F', halo: 'rgba(0, 0, 0, 0.88)',
};

function style(tone) {
  const t = `rgb(${tone.map(Math.round).join(',')})`;
  const src = { source: 'ets2', 'source-layer': 'ets2' };
  const type = (v) => ['==', ['get', 'type'], v];
  const shown = ['!=', ['get', 'secret'], true];
  const road = (rt) => ['all', type('road'), ['==', ['get', 'roadType'], rt], ['!=', ['get', 'hidden'], true], shown];
  // Real road width (matches the junction polygons): ~20 px at z13.
  const width = (k) => ['interpolate', ['exponential', 1.5], ['zoom'], 4, 0.5 * k, 9, 1.6 * k, 13, 20 * k, 16, 120 * k];
  return {
    version: 8,
    glyphs: `${MAP}fonts/{fontstack}/{range}.pbf`,
    sources: {
      ets2: { type: 'vector', url: `pmtiles://${MAP}ets2.pmtiles` },
      world: { type: 'vector', url: `pmtiles://${MAP}world.pmtiles` },
      trail: { type: 'geojson', data: { type: 'Feature', geometry: { type: 'MultiLineString', coordinates: [] }, properties: {} } },
      dest: { type: 'geojson', data: { type: 'FeatureCollection', features: [] } },
      route: { type: 'geojson', data: { type: 'FeatureCollection', features: [] } },
    },
    layers: [
      { id: 'land', type: 'background', paint: { 'background-color': C.land } },
      { id: 'water', type: 'fill', source: 'world', 'source-layer': 'water', paint: { 'fill-color': C.water, 'fill-antialias': false } },
      { id: 'areas', type: 'fill', ...src, filter: ['all', type('mapArea'), shown], layout: { 'fill-sort-key': ['get', 'zIndex'] },
        paint: { 'fill-color': ['match', ['get', 'color'], 0, C.areaRoad, 1, C.areaLight, 2, C.areaDark, 3, C.areaGreen, C.areaLight], 'fill-antialias': false } },
      { id: 'prefabs', type: 'fill', ...src, minzoom: 8, filter: ['all', type('prefab'), shown], layout: { 'fill-sort-key': ['get', 'zIndex'] },
        paint: { 'fill-color': ['match', ['get', 'color'], 0, C.prefab, 1, C.areaLight, 2, C.areaDark, 3, C.areaGreen, C.prefab] } },
      { id: 'borders', type: 'line', source: 'world', 'source-layer': 'countries',
        paint: { 'line-color': C.border, 'line-width': 1.2, 'line-dasharray': [3, 2] } },
      { id: 'ferries', type: 'line', ...src, filter: ['any', type('ferry'), type('train')],
        paint: { 'line-color': C.ferry, 'line-width': 1.6, 'line-dasharray': [2, 2.5] } },
      { id: 'road-local', type: 'line', ...src, minzoom: 7, filter: road('local'), layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': C.local, 'line-width': width(0.8) } },
      { id: 'road-divided', type: 'line', ...src, filter: road('divided'), layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': C.divided, 'line-width': width(1) } },
      { id: 'road-freeway', type: 'line', ...src, filter: road('freeway'), layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': C.freeway, 'line-width': width(1) } },
      { id: 'route-casing', type: 'line', source: 'route', layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': C.land, 'line-opacity': 0.85, 'line-width': ['interpolate', ['linear'], ['zoom'], 4, 5, 9, 9, 13, 16] } },
      { id: 'route-glow', type: 'line', source: 'route', layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': t, 'line-opacity': 0.22, 'line-width': 22, 'line-blur': 8 } },
      { id: 'route', type: 'line', source: 'route', layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': t, 'line-width': ['interpolate', ['linear'], ['zoom'], 4, 2.5, 9, 5, 13, 10] } },
      { id: 'trail-glow', type: 'line', source: 'trail', layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': t, 'line-opacity': 0.16, 'line-width': 16, 'line-blur': 6 } },
      { id: 'trail', type: 'line', source: 'trail', layout: { 'line-cap': 'round', 'line-join': 'round' },
        paint: { 'line-color': t, 'line-opacity': 0.5, 'line-width': 4 } },
      { id: 'dest-glow', type: 'circle', source: 'dest', paint: { 'circle-radius': 26, 'circle-color': t, 'circle-opacity': 0.14, 'circle-blur': 0.6, 'circle-pitch-alignment': 'map' } },
      { id: 'dest', type: 'circle', source: 'dest',
        paint: { 'circle-radius': 9, 'circle-color': C.land, 'circle-stroke-color': t, 'circle-stroke-width': 3.5, 'circle-pitch-alignment': 'map' } },
      { id: 'ferry-names', type: 'symbol', ...src, minzoom: 8, filter: ['any', type('ferry'), type('train')],
        layout: { 'symbol-placement': 'line-center', 'text-field': ['get', 'name'], 'text-font': ['PlusJakartaSans Regular'], 'text-size': 13 },
        paint: { 'text-color': C.labelSoft, 'text-halo-color': C.halo, 'text-halo-width': 1.4 } },
      { id: 'countries', type: 'symbol', ...src, maxzoom: 6.5, filter: type('country'),
        layout: { 'text-field': ['upcase', ['get', 'name']], 'text-font': ['PlusJakartaSans SemiBold'], 'text-size': 13, 'text-letter-spacing': 0.18 },
        paint: { 'text-color': C.labelSoft, 'text-halo-color': C.halo, 'text-halo-width': 1.2 } },
      { id: 'cities', type: 'symbol', ...src, filter: ['all', type('city'), shown],
        layout: {
          'text-field': ['get', 'name'], 'text-font': ['PlusJakartaSans SemiBold'],
          'text-size': ['interpolate', ['linear'], ['zoom'], 5, ['case', ['<=', ['get', 'scaleRank'], 3], 15, 12], 10, ['case', ['<=', ['get', 'scaleRank'], 3], 22, 18], 13, ['case', ['<=', ['get', 'scaleRank'], 3], 26, 21]],
          'text-letter-spacing': 0.01, 'symbol-sort-key': ['get', 'scaleRank'], 'text-padding': 12, 'text-max-width': 8,
          'text-pitch-alignment': 'viewport', 'text-rotation-alignment': 'viewport',
        },
        paint: { 'text-color': C.label, 'text-halo-color': C.halo, 'text-halo-width': 1.8, 'text-halo-blur': 0.6 } },
    ],
  };
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src; s.onload = resolve; s.onerror = () => reject(new Error(`load ${src}`));
    document.head.append(s);
  });
}

/** MapLibre + PMTiles. Resolves once the style and the first tiles have rendered; rejects on missing data / no WebGL. */
async function createGl(el, opts) {
  // Map data present? (a 404 here is the normal "not generated yet" case: keep the radar, no console noise)
  const head = await fetch(`${MAP}ets2.pmtiles`, { headers: { Range: 'bytes=0-6' }, cache: 'no-store' });
  const magic = head.ok ? new TextDecoder().decode(await head.arrayBuffer()) : '';
  if (!magic.startsWith('PMTiles')) throw new Error('no map data');
  const probe = document.createElement('canvas').getContext('webgl2');
  if (!probe) throw new Error('no WebGL2');
  probe.getExtension('WEBGL_lose_context')?.loseContext();

  const link = document.createElement('link');
  link.rel = 'stylesheet'; link.href = `${VENDOR}maplibre-gl.css`;
  document.head.append(link);
  const [ml] = await Promise.all([import(`${VENDOR}maplibre-gl.mjs`), window.pmtiles ? null : loadScript(`${VENDOR}pmtiles.js`)]);
  const archive = new window.pmtiles.PMTiles(`${MAP}ets2.pmtiles`);
  const protocol = new window.pmtiles.Protocol();
  protocol.add(archive);
  ml.addProtocol('pmtiles', protocol.tile);

  const box = document.createElement('div');
  box.className = 'map-gl';
  el.prepend(box);
  let map;
  try {
    map = new ml.Map({
      container: box, style: style(opts.tone), interactive: false, attributionControl: false,
      center: [10, 50], zoom: 12, pitch: PITCH, maxPitch: 60,
      fadeDuration: 0, renderWorldCopies: false, pixelRatio: pixelRatioFor(opts.motion),
      canvasContextAttributes: { antialias: false, powerPreference: 'low-power' },
    });
  } catch (e) {
    box.remove();
    throw e;
  }
  if (/[#&]debug\b/.test(location.hash)) window.__tphMap = map; // console access while developing
  // Tile/glyph errors are logged by MapLibre and don't stop the map; only a map that never loads falls back.
  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => { map.remove(); box.remove(); reject(new Error('map load timeout')); }, 30_000);
    map.once('load', () => { clearTimeout(timer); resolve(); });
  });
  return { ml, map, box, archive };
}

const pixelRatioFor = (motion) => Math.min(motion === 'low' ? 1 : 2, devicePixelRatio || 1);

export function createMap(el) {
  let radar = createRadar(el);
  let gl = null;             // { ml, map, box, archive } once loaded
  let tone = [165, 180, 252];
  let motion = 'normal';
  let destination = null, destFound = null;
  let cities = null, citiesLoading = false;
  const nav = createNavigator(async () => {
    const r = await fetch(`${MAP}route.json`, { cache: 'no-store' });
    return r.ok ? r.json() : null; // 404: route data not generated (docs › Map data)
  });
  let routeDirty = false, routePushedAt = 0, routeDest = null;

  // Pose interpolation (game coordinates) from the rendered pose toward the newest sample over the sample interval.
  let pose = null, from = null, to = null, t0 = 0, dur = 50, lastArrival = 0;
  let speed = 0;
  let cam = null;            // eased camera {bearing, zoom}
  let lastJump = 0, lastFrame = 0;
  // Trail: lines of [lon, lat], split at jumps.
  const trail = [[]];
  let trailCount = 0, trailLast = null, trailDirty = false, trailPushedAt = 0;

  const truckEl = document.createElement('div');
  truckEl.className = 'map-truck';
  truckEl.innerHTML = '<svg viewBox="-24 -24 48 48" aria-hidden="true"><path d="M0 -17 L12 13 L0 7 L-12 13 Z"/></svg>';

  function layout() {
    if (!gl) return;
    const h = el.clientHeight;
    // Truck low in the card: more road ahead. MapLibre's padding moves the camera's focus point.
    const top = Math.round(h * 0.42);
    gl.map.setPadding({ top, bottom: 0, left: 0, right: 0 });
    truckEl.style.top = `${top + (h - top) / 2}px`;
  }

  createGl(el, { tone, motion }).then((g) => {
    gl = g;
    el.append(truckEl);
    new ResizeObserver(() => { gl.map.resize(); layout(); }).observe(el);
    layout();
    gl.map.on('webglcontextlost', () => fallBack('WebGL context lost'));
    pushTrail(true);
    applyTone();
    if (destination) locateDestination();
    // Swap: the radar fades out under the map.
    requestAnimationFrame(() => { gl.box.classList.add('on'); truckEl.classList.add('on'); });
    setTimeout(() => { radar?.destroy(); radar = null; }, 700);
  }).catch((e) => {
    if (String(e?.message) !== 'no map data') console.warn('[map] real map unavailable, radar fallback:', e?.message ?? e);
  });

  function fallBack(why) {
    console.warn('[map] falling back to the radar:', why);
    if (gl) { try { gl.map.remove(); } catch {} gl.box.remove(); gl = null; }
    truckEl.remove();
    if (!radar) {
      radar = createRadar(el);
      radar.setMotion(motion); radar.setTone(tone);
    }
  }

  const lerpAngle = (a, b, k) => { let d = ((b - a) % 360 + 540) % 360 - 180; return a + d * k; };

  function update(tr) {
    radar?.update(tr);
    if (gl && nav.update(tr)) routeDirty = true;
    if (!tr || tr.state === 'none' || tr.x == null) return;
    const now = performance.now();
    const sample = { x: tr.x, z: tr.z, heading: tr.heading ?? 0 };
    speed = Math.abs(tr.speed ?? 0);
    if (!pose || Math.hypot(sample.x - pose.x, sample.z - pose.z) > JUMP) {
      pose = { ...sample };
      from = to = sample;
      cam = null;
      if (trail.at(-1).length) trail.push([]);
    } else {
      from = { ...pose };
      to = sample;
      if (lastArrival) dur = Math.min(250, Math.max(16, now - lastArrival));
    }
    t0 = now;
    lastArrival = now;
    if (!trailLast || Math.hypot(trailLast.x - sample.x, trailLast.z - sample.z) >= TRAIL_STEP) {
      trailLast = { x: sample.x, z: sample.z };
      trail.at(-1).push(gameToLngLat(sample.x, sample.z));
      if (++trailCount > TRAIL_MAX) { trail[0].shift(); trailCount--; if (!trail[0].length && trail.length > 1) trail.shift(); }
      trailDirty = true;
    }
  }

  function pushTrail(force = false) {
    if (!gl || (!trailDirty && !force)) return;
    trailDirty = false;
    gl.map.getSource('trail')?.setData({ type: 'Feature', geometry: { type: 'MultiLineString', coordinates: trail.filter((l) => l.length > 1) }, properties: {} });
  }

  function applyTone() {
    if (!gl) return;
    const t = `rgb(${tone.map(Math.round).join(',')})`;
    for (const id of ['trail-glow', 'trail', 'dest-glow', 'route-glow', 'route']) gl.map.setPaintProperty(id, id.startsWith('dest') ? 'circle-color' : 'line-color', t);
    gl.map.setPaintProperty('dest', 'circle-stroke-color', t);
    truckEl.style.setProperty('--truck-tone', t);
  }

  async function locateDestination() {
    destFound = null;
    if (gl) gl.map.getSource('dest')?.setData({ type: 'FeatureCollection', features: [] });
    if (!gl || !destination) return;
    if (!cities && !citiesLoading) {
      citiesLoading = true;
      try {
        // Every city is in the z4 tiles (tippecanoe base zoom 4); read them once (memory only).
        const h = await gl.archive.getHeader();
        const tx = (lon) => Math.floor(((lon + 180) / 360) * 16);
        const ty = (lat) => Math.floor(((1 - Math.log(Math.tan((lat * Math.PI) / 180) + 1 / Math.cos((lat * Math.PI) / 180)) / Math.PI) / 2) * 16);
        const list = [];
        for (let x = tx(h.minLon); x <= tx(h.maxLon); x++) for (let y = ty(h.maxLat); y <= ty(h.minLat); y++) {
          const t = await gl.archive.getZxy(4, x, y);
          if (t?.data) list.push(...citiesInTile(t.data, 4, x, y));
        }
        cities = list;
      } catch (e) {
        console.warn('[map] city list unavailable:', e?.message ?? e);
        cities = [];
      }
      citiesLoading = false;
    }
    if (!cities || !gl) return;
    const c = findCity(cities, destination);
    destFound = c?.name ?? null;
    if (c && !routeDest) gl.map.getSource('dest')?.setData({ type: 'Feature', geometry: { type: 'Point', coordinates: c.lngLat }, properties: {} });
  }

  /** Route line from the drawn truck pose; the destination marker on the company once a route is known. */
  function pushRoute(now) {
    if (!gl || (!routeDirty && now - routePushedAt < ROUTE_EVERY)) return;
    routeDirty = false;
    routePushedAt = now;
    const line = nav.line(ROUTE_AHEAD);
    if (line && pose) {
      // Start at the interpolated pose; drop the first route points it has already passed.
      const a = (pose.heading ?? 0) * Math.PI * 2, hx = -Math.sin(a), hz = -Math.cos(a);
      let i = 1;
      while (i < Math.min(3, line.length - 1) && (line[i][0] - pose.x) * hx + (line[i][1] - pose.z) * hz < 0) i++;
      line.splice(0, i, [pose.x, pose.z]);
    }
    gl.map.getSource('route')?.setData(line
      ? { type: 'Feature', geometry: { type: 'LineString', coordinates: line.map(([x, z]) => gameToLngLat(x, z)) }, properties: {} }
      : { type: 'FeatureCollection', features: [] });
    const d = nav.dest;
    if (d !== routeDest) {
      routeDest = d;
      if (d) gl.map.getSource('dest')?.setData({ type: 'Feature', geometry: { type: 'Point', coordinates: gameToLngLat(d[0], d[1]) }, properties: {} });
      else void locateDestination();
    }
  }

  function frame(now) {
    radar?.frame(now);
    if (!gl || !pose) return;
    // 30 fps camera (MapLibre renders once per camera move), every frame only with motion=high.
    if (motion !== 'high' && now - lastJump < 32) return;
    const dt = Math.min(200, now - (lastFrame || now));
    lastFrame = now;
    lastJump = now;
    const k = Math.min(1, (now - t0) / dur);
    pose = { x: from.x + (to.x - from.x) * k, z: from.z + (to.z - from.z) * k, heading: to.heading };
    const center = gameToLngLat(pose.x, pose.z);
    const wantBearing = headingBearing(pose.x, pose.z, to.heading);
    // Parked: close (z12.6); 90 km/h and above: z11.2.
    const wantZoom = 12.6 - Math.min(1, speed / 25) * 1.4;
    if (!cam) cam = { bearing: wantBearing, zoom: wantZoom };
    cam.bearing = lerpAngle(cam.bearing, wantBearing, 1 - Math.exp(-dt / 220));
    cam.zoom += (wantZoom - cam.zoom) * (1 - Math.exp(-dt / 2500));
    gl.map.jumpTo({ center, bearing: cam.bearing, zoom: cam.zoom, pitch: PITCH });
    if (now - trailPushedAt > 1000) { trailPushedAt = now; pushTrail(); }
    pushRoute(now);
  }

  return {
    update,
    setDestination(name) {
      if (name === destination) return;
      destination = name;
      radar?.setDestination(name);
      void locateDestination();
    },
    get destination() { return destination; },
    /** Map city the destination matched (null: not found or no real map). */
    get destinationOnMap() { return destFound; },
    setMotion(m) {
      if (m === motion) return;
      motion = m;
      radar?.setMotion(m);
      if (gl) gl.map.setPixelRatio(pixelRatioFor(m));
    },
    setTone(rgb) { tone = rgb; radar?.setTone(rgb); applyTone(); },
    frame,
  };
}
