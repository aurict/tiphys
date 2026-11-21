// ETS2 game coordinates (x, z in metres) → WGS84 [lon, lat], the projection the map tiles were generated with
// (truckermudgeon/maps "fromEts2CoordsToWgs84"; only the published constants are used, the code is ours).
// The game world is a Lambert conformal conic map on a sphere, scaled and offset; the UK is drawn at a different scale.

const R = 6370997;                  // sphere radius (m)
const L = (R * Math.PI) / 180;      // metres per degree
const D2R = Math.PI / 180;
const OFFSET_X = 16660, OFFSET_Z = 4150;
const FACTOR_X = 0.0001729241463, FACTOR_Z = -0.000171570875;
const UK_X = -31100, UK_Z = -5500, UK_SCALE = 0.75;

// Spherical LCC, two standard parallels (Snyder, "Map Projections: A Working Manual", eq. 15-1…15-5, inverse 14-…).
const phi1 = 37 * D2R, phi2 = 65 * D2R, phi0 = 50 * D2R, lam0 = 15 * D2R;
const t = (phi) => Math.tan(Math.PI / 4 + phi / 2);
const n = Math.log(Math.cos(phi1) / Math.cos(phi2)) / Math.log(t(phi2) / t(phi1));
const F = (Math.cos(phi1) * t(phi1) ** n) / n;
const rho0 = (R * F) / t(phi0) ** n;

/** Inverse LCC: projected metres (X east, Y north) → [lon, lat] in degrees. */
export function lccInverse(X, Y) {
  const dy = rho0 - Y;
  const rho = Math.sign(n) * Math.hypot(X, dy);
  const theta = Math.atan2(Math.sign(n) * X, Math.sign(n) * dy);
  const phi = 2 * Math.atan((R * F / rho) ** (1 / n)) - Math.PI / 2;
  return [(lam0 + theta / n) / D2R, phi / D2R];
}

/** Forward LCC (used by the tests to check the inverse): [lon, lat] → projected metres. */
export function lccForward(lon, lat) {
  const rho = (R * F) / t(lat * D2R) ** n;
  const theta = n * (lon * D2R - lam0);
  return [rho * Math.sin(theta), rho0 - rho * Math.cos(theta)];
}

/** Game (x, z) → [lon, lat]. */
export function gameToLngLat(gx, gz) {
  const sx = Math.floor(gx / 4000), sz = Math.floor(gz / 4000);   // sector, from the raw coordinates
  let x = gx - OFFSET_X, z = gz - OFFSET_Z;
  if (sx <= -8 && sz <= -2 && !(sx === -8 && sz === -2)) {        // Great Britain
    x = (x + UK_X / 2) * UK_SCALE;
    z = (z + UK_Z / 2) * UK_SCALE;
  }
  return lccInverse(x * FACTOR_X * L, z * FACTOR_Z * L);
}

/** Compass bearing (degrees, clockwise from north) from a to b, both [lon, lat]. */
export function bearing(a, b) {
  const [l1, p1] = [a[0] * D2R, a[1] * D2R], [l2, p2] = [b[0] * D2R, b[1] * D2R];
  const y = Math.sin(l2 - l1) * Math.cos(p2);
  const x = Math.cos(p1) * Math.sin(p2) - Math.sin(p1) * Math.cos(p2) * Math.cos(l2 - l1);
  return (Math.atan2(y, x) / D2R + 360) % 360;
}

/**
 * Map bearing for the truck's heading. SCS heading: 0..1, 0 = north (−z), counter-clockwise, so the forward vector
 * is (−sin a, −cos a) in (x, z). The bearing is measured on the projected map, so the LCC convergence and the UK
 * rescale are taken into account.
 */
export function headingBearing(gx, gz, heading) {
  const a = heading * Math.PI * 2;
  return bearing(gameToLngLat(gx, gz), gameToLngLat(gx - Math.sin(a) * 20, gz - Math.cos(a) * 20));
}
