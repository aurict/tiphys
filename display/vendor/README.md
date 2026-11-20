# Vendored libraries (Game mode display)

Unmodified upstream release files, loaded directly by `map.js` (no build step). Update by replacing the files from the
npm tarball of the new version and refreshing this table (`sha256sum *`).

| File | Package | Version | License | SHA-256 |
|---|---|---|---|---|
| maplibre-gl.mjs | [maplibre-gl](https://github.com/maplibre/maplibre-gl-js) `dist/` | 6.19.0 | BSD-3-Clause (LICENSE-maplibre-gl.txt) | `01590c9875ea5bb0e8cdc534479f607f7d1695ca5debbccaf730edf5fa5f39e5` |
| maplibre-gl-worker.mjs | maplibre-gl `dist/` (loaded by maplibre-gl.mjs from the same folder) | 6.19.0 | BSD-3-Clause | `c8564c4a4147326a587c9cc4c2a871c4b02a6c37c3f1ea51da55be3220d4b112` |
| maplibre-gl.css | maplibre-gl `dist/` | 6.19.0 | BSD-3-Clause | `a90798a1953017790e590f7e1bd35ff103a8a4263972cb47290b78adf86f8c20` |
| LICENSE-maplibre-gl.txt | maplibre-gl `LICENSE.txt` | 6.19.0 | | `ee5fc05a0677eaf69601d2c7db0d9ecd6cc27c3abc1d0733bc9ed34707cf8ef2` |
| pmtiles.js | [pmtiles](https://github.com/protomaps/PMTiles) `dist/pmtiles.js` (IIFE, global `pmtiles`) | 4.5.0 | BSD-3-Clause (LICENSE-pmtiles.txt) | `caf981bc46f6327ee7e65d5dc964d89d38a69f60edca2bd4c5c890c21b554c6c` |
| LICENSE-pmtiles.txt | PMTiles repository `LICENSE` (the npm package ships none) | main @ 2026-11-20 | | `0371c38f338835f7fc13ed71176f3d92144e22c8b736a31cced57adbbeb647b3` |

The `.map` source maps are not vendored (the agent doesn't serve that extension).
