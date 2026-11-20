# Game mode

Game mode turns a laptop next to your PC into an ambient second screen while you play Euro Truck Simulator 2:

- the song playing in **Velour** on the PC: cover, colours taken from the cover, a spectrum of the PC's audio output
  and optional synced lyrics;
- the **ETS2 cockpit**: speed and speed limit, gear and RPM, fuel and range, cruise control, lights, damage, the
  current job and the in-game clock;
- a **live map** with the truck's position (or a built-in "radar" when no map data is installed);
- short notices for fines, tolls, ferries/trains, deliveries, low fuel and rest stops.

You start and stop it from the phone. When it stops, nothing is left running and no file is left behind on either
machine.

Two agents take part:

```
phone ──> display agent (laptop) ──systemd-run──> Firefox kiosk ──127.0.0.1──> display agent
              display agent ──WS /v1/gamemode/feed (service token)──> source agent (PC: Velour, PipeWire, ETS2)
```

API details: [api.md › gamemode](../agent/api.md#gamemode). Security rationale: [Security › Game mode](../security.md#game-mode).

## Requirements

| Host | Need | Used for |
|---|---|---|
| Both | Linux, the agent with the **`gamemode`** feature on | the routes on each side (the flag is off on macOS/Windows) |
| Display host (laptop) | Hyprland, with the agent running as the logged-in user | the fullscreen window rule and the `yol` workspace (`hyprctl`) |
| Display host | Firefox (`firefox` or `firefox-esr`) | the kiosk page (`firefox --kiosk`, empty temporary profile) |
| Display host | `systemd-run` and `systemd-inhibit` (systemd user session) | one transient unit for the kiosk; no idle/sleep while it runs |
| Display host | `brightnessctl` (optional) | the brightness setting. Without it, or without permission on the backlight, the brightness is left alone |
| Display host | Map data in `~/.local/share/tiphys/gamemode/map/` (optional) | the map; see [Map data](#map-data). Without it the driving scene shows the radar |
| Source host (PC) | [Velour](system.md) running | music, lyrics, the next two songs |
| Source host | PipeWire with `pw-record` | the spectrum (the default output's monitor; the microphone is never opened) |
| Source host | ETS2, native Linux version (Steam, including Flatpak and Snap Steam) | the cockpit, map position and notices |
| Source host | The ETS2 telemetry plugin ([truckermudgeon/scs-sdk-plugin](https://github.com/truckermudgeon/scs-sdk-plugin) v1.12.1, MIT) | telemetry from the game's shared memory; see [ETS2 plugin](#ets2-plugin) |

`tiphys-agent doctor` checks these: on a display host (a source is configured) `systemd-run`, `systemd-inhibit`,
`hyprctl` and Firefox, with a warning for a missing `brightnessctl`; on a source host `pw-record` and the plugin.

## Setup

### 1. Turn on the feature on both hosts

`gamemode` is a risky feature, so `tiphys-agent init --detect` (and `install.sh`) never turns it on. On the laptop
and on the PC, either:

- in the app: *Settings › Hosts › (host) › Agent settings › Features* › **Game mode**, or
- on the machine: `tiphys-agent init --features gamemode` (adds it; nothing else is turned off).

Then restart the agent. Without the flag the app shows *Game mode is off on this host* with a link to the agent
settings. All keys: [Agent configuration](../agent/configuration.md#gamemode).

### 2. Connect the two hosts (setup wizard)

Open **Game mode** (home card, or the Game mode screen) and tap **Set up**. Pick the **display PC** (laptop) and the
**source PC** (music and game) and tap **Connect**. The app:

1. creates a service token with the `gamemode` scope on the source agent (the same API as
   `tiphys-agent service-token create --name <laptop> --scope gamemode`);
2. writes the source URL and that token to the display agent (`PUT /v1/gamemode`);
3. tests the connection and shows *Connected* or *Saved, but the display PC cannot reach …*.

The token is not stored on the phone. The display agent keeps it in its `agent.json` and never returns it from an
API. Revoking it on the source (`tiphys-agent service-token list` / `revoke <id>`) cuts the link; run the wizard
again (*Set up again*) to make a new one.

### 3. ETS2 plugin

On the Game mode screen, *Setup › ETS2 plugin › Install*, or on the PC:

```sh
tiphys-agent gamemode install-plugin     # remove: tiphys-agent gamemode remove-plugin
```

The agent finds the game through Steam's `libraryfolders.vdf` (native `~/.steam`, Flatpak and Snap Steam), downloads
the pinned release asset of scs-sdk-plugin v1.12.1, checks the SHA-256 of the zip and of `libscs-telemetry.so`
inside, and writes the `.so` to `<game>/bin/linux_x64/plugins/`. Nothing is run at install time.

The next time ETS2 starts it shows a dialog about **SDK / advanced SDK features** (a plugin is loaded). Accept it;
otherwise the game does not load the plugin and Game mode gets no telemetry. The game shows this dialog on every
start while a plugin is installed.

### 4. Map data

Optional; see [Map data](#map-data) below. Until it is installed, the driving scene shows the radar.

## Usage

- **Start / stop:** the big button on the Game mode screen, or the toggle on the **Game mode** home card. Every
  paired device can stop it. On the laptop, **hold Esc for 1 second** to stop. Closing Firefox also stops the mode
  (checked every 5 s), and so does stopping the display agent.
- On start the laptop switches to a workspace named `yol`, opens Firefox fullscreen there, holds an idle/sleep
  inhibitor and, if set, changes the brightness. On stop all of that is undone: the previous workspace and the
  brightness come back.
- **Scenes:**
  - **Drive**: map card, now-playing card with mini spectrum and three lyric lines, and the cockpit tiles (speed with
    limit ring, gear/RPM ring, fuel and range, status chips). Shown while ETS2 is being driven.
  - **Music**: big cover, title/artist/album, karaoke lyrics, the next two songs. Shown while music plays (or was
    paused less than 2 minutes ago) and you are not driving.
  - **Idle** (*Standby* in the app): big clock and date, very slow background; dims after the set time.
  - **Auto** picks between them as above. Choosing *Drive* or *Music* in the app pins that scene (*Music* falls back
    to Idle when nothing is loaded).
- **Settings** (*Display* section; every change reaches the open page at once): scene, lyrics, spectrum, animation
  intensity (low/normal/high; low stops the moving background and lowers the frame rates), brightness (5–100 %, or
  *Leave brightness alone*), 12/24-hour clock, dim after (0–120 min, 0 = never).
- The **Connections** section shows both hosts and the source link state (*Idle*, *Connecting*, *Connected*,
  *Unreachable*); **Setup** shows the plugin and map status and a shortcut to the Velour remote.

## Map data

The map is generated **once, by you, from your own game files**, with
[truckermudgeon/maps](https://github.com/truckermudgeon/maps) (GPL-3.0). It is run as a **separate tool**: Tiphys
does not include, link to or download it, and the generated files stay on your machines. The page renders them with
MapLibre GL JS and PMTiles (vendored in `display/vendor/`).

What the page loads from `~/.local/share/tiphys/gamemode/map/` (`$XDG_DATA_HOME` respected) under
`/gamemode/map/`:

| File | What |
|---|---|
| `ets2.pmtiles` | the game map (roads, prefabs, map areas, ferries/trains, cities, countries, POIs) |
| `world.pmtiles` | the background: water, country and state borders |
| `sprites.json`, `sprites.png`, `sprites@2x.json`, `sprites@2x.png` | the icon sprite sheet (POIs, road shields); built by the tool, not used by the page's style yet |
| `fonts/PlusJakartaSans Regular/<range>.pbf`, `fonts/PlusJakartaSans SemiBold/<range>.pbf` | glyphs for map labels |
| `SCHEMA.md` (optional) | your own notes: tool commit, game version, layers |

### Build it

Tested with maps commit `d56d0e3` (2026-05-16), tippecanoe v2.82.0 and ETS2 1.62.3.3 with all installed DLC. Needs
git, Node.js, a C++ toolchain for tippecanoe and a few GB of free disk. Run it on the PC that has the game (heavy: run
it with low priority, e.g. `nice -n 15`), then copy the result to the laptop.

```sh
W=~/.cache/tiphys-mapbuild && mkdir -p "$W/tmp" && cd "$W"

# tippecanoe (if your distribution doesn't package it; needs the sqlite3 and zlib development headers)
git clone https://github.com/felt/tippecanoe && git -C tippecanoe checkout a888304b19cf1ed144341a8218a9421f47248d4e  # v2.82.0
make -C tippecanoe -j2
export PATH="$W/tippecanoe:$PATH"

# the map tool, at the tested commit
git clone https://github.com/truckermudgeon/maps && cd maps
git checkout d56d0e3fb319230e84284f3029f8bda2c4b572a2
npm ci
# apply the two local patches below, then:

GAME="$HOME/.local/share/Steam/steamapps/common/Euro Truck Simulator 2"
# Flatpak Steam: GAME="$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/common/Euro Truck Simulator 2"
npx parser -i "$GAME" -o ../parsed
# The generator writes the tiles to $TMPDIR and then renames them into -o; with /tmp on a tmpfs that rename fails
# with EXDEV, so keep TMPDIR on the same file system as the output.
TMPDIR="$W/tmp" npx generator map -m europe -i ../parsed -o ../out
npx generator spritesheet -m europe -i ../parsed -o ../out
R=packages/clis/generator/resources
tippecanoe -Z4 -z8 -y name -b 10 -X -o ../out/world.pmtiles "$R/water.geojson" "$R/countries.geojson" "$R/states.geojson"
```

**Local patches for game 1.62.** The parser at that commit stops on two things in ETS2 1.62. Two small edits in your
clone (not committed anywhere) get past them:

1. `packages/clis/parser/game-files/def-parser.ts`, in `parseDefFiles`: skip the obsolete `def/world/model.stable.sii`,
   which the parser cannot read. In the loop over `defWorld.files`, add `|| f === 'model.stable.sii'` to the
   condition that `continue`s:

   ```ts
   if (!/^(prefab|road_look|sign|model)\./.test(f) || !f.endsWith('.sii') || f === 'model.stable.sii') {
   ```

2. `packages/clis/parser/game-files/map-files-parser.ts`, in `parseIconMatFiles`: skip icons whose `.tobj` holds a
   DDS texture in format 93 (BC7), which the DDS decoder does not support (13 icons in 1.62, e.g. `weigh_ico`). Wrap
   the decode in a `try`/`catch` that logs and moves on:

   ```ts
   try {
     pngs.set(key, parseDds(tobj.read(), sdfAuxData.get(key)));
   } catch (e) {
     logger.warn('skipping unreadable icon', key, String(e));
   }
   ```

   Those icons are then missing from the sprite sheet; the map works without them.

**Glyphs.** MapLibre needs the label font as glyph PBFs. Generate them from the page's own font
(`display/fonts/PlusJakartaSans-*.ttf`, OFL) with [fontnik](https://github.com/mapbox/node-fontnik), in a scratch
directory:

```sh
mkdir -p "$W/fonttool" && cd "$W/fonttool" && npm init -y >/dev/null && npm install fontnik
cat > gen.js <<'EOF'
// node gen.js <font.ttf> <font name> <out dir>: writes <out dir>/<font name>/<start>-<end>.pbf
const fontnik = require('fontnik'), fs = require('fs'), path = require('path');
const [, , ttf, name, outRoot] = process.argv;
const font = fs.readFileSync(ttf), dir = path.join(outRoot, name);
fs.mkdirSync(dir, { recursive: true });
// Latin, Latin Extended, IPA/modifiers, Greek, Cyrillic, Latin Extended Additional, Greek Extended, punctuation, symbols
const starts = [0, 256, 512, 768, 1024, 7680, 7936, 8192, 8448];
(async () => {
  for (const s of starts) await new Promise((ok, fail) => fontnik.range({ font, start: s, end: s + 255 }, (e, d) =>
    e ? fail(e) : (fs.writeFileSync(path.join(dir, `${s}-${s + 255}.pbf`), d), ok())));
})().catch((e) => { console.error(e); process.exit(1); });
EOF
T=/path/to/tiphys/display/fonts
node gen.js "$T/PlusJakartaSans-Regular.ttf" "PlusJakartaSans Regular" "$W/out/fonts"
node gen.js "$T/PlusJakartaSans-SemiBold.ttf" "PlusJakartaSans SemiBold" "$W/out/fonts"
```

(The font has no Greek or Cyrillic, so those ranges come out empty; that is fine.)

**Install on the display host:**

```sh
ssh laptop 'mkdir -p ~/.local/share/tiphys/gamemode/map'
rsync -a "$W/out/" laptop:.local/share/tiphys/gamemode/map/
```

No agent restart is needed; the page loads the files when the mode starts. Rebuild after game updates or new map
DLC. The build cache (`~/.cache/tiphys-mapbuild`, several GB with `parsed/`) can be deleted afterwards.

## Privacy

Nothing about your music or your drives is saved:

- The drive history (the trail behind the truck), telemetry, the song, lyrics and the spectrum exist only in memory:
  on the source while someone is subscribed, on the display agent while the mode runs, and in the page while it is
  open. Titles, lyrics and job details are never logged.
- The event log records only **Game mode started** and **Game mode stopped** (`gamemode.started` /
  `gamemode.stopped`), with no content.
- The kiosk Firefox uses an empty profile in a tmpfs directory under `$XDG_RUNTIME_DIR`, deleted on stop (or on the
  next agent start after a crash); its output goes to `/dev/null`, not the journal.
- The **display token** the page uses is made at each start, kept only in memory and invalid after stop.
- The **source token** lives in the display agent's `agent.json` and is never returned by any API (the app sees only
  whether a source is configured and its URL).
- The settings (scene, brightness, …) and the map data are configuration and program data, not traces.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| *Game mode is off on this host* | The `gamemode` flag is off on that agent (or the agent was not restarted after turning it on). See [step 1](#1-turn-on-the-feature-on-both-hosts). |
| *No source is set up yet* (`agent.gamemode.noSource`, 409) | Run the setup wizard. |
| *The display PC has no graphical session* (`agent.gamemode.noDisplay`, 503) | Hyprland is not running on the laptop, or the agent cannot reach the session (it must run as the logged-in user). Log in to Hyprland and try again. |
| `agent.exec.commandMissing` (`firefox`) | Install Firefox on the laptop. |
| *The ambient display could not be started* (`agent.gamemode.startFailed`, 502) | `systemd-run --user` failed; the error carries its stderr. Check that the systemd user session works (`systemctl --user status`). Everything done so far is undone. |
| Page shows the source as unreachable, with a retry counter (app: *Unreachable*) | The display agent cannot reach the source agent: the PC is off or asleep, its agent is down or has `gamemode` off, the URL changed, or the token was revoked. It retries after 1, 2, 4, 8, 15, 30 s. Fix the PC side, or run *Set up again*. |
| No music, *Velour is not running* | Start Velour on the PC. The source retries every 3 s. |
| No spectrum | `pw-record` missing on the PC (doctor warns), the spectrum setting is off, or nothing is playing (frames are sent only while Velour plays). |
| Cockpit stays empty, truck state `none` | `reason` says why: `noGame`: ETS2 is not running; `noPlugin`: the game runs but the plugin's shared memory is missing (plugin not installed, or the SDK dialog was not accepted; restart the game); `unsupported`: the plugin has a different layout revision than the agent reads (12); install the pinned version from the app. |
| *ETS2 was not found on the source PC* (`agent.gamemode.noGame`, 404) | No native Linux ETS2 in the Steam libraries the agent knows. The Windows version under Proton is not supported. |
| Plugin *Outdated* | A different `libscs-telemetry.so` is in the plugins folder; tap *Update*. |
| `agent.gamemode.pluginDownloadFailed` / `pluginHashMismatch` / `pluginBadArchive` (502) | The PC could not download the pinned release, or the file did not match the pinned SHA-256; nothing was written. Check the PC's internet connection and retry. |
| Radar instead of a map | No (or incomplete) map data in `~/.local/share/tiphys/gamemode/map/` on the **laptop** (see [Map data](#map-data)), or Firefox has no WebGL2 (check `about:support` → Graphics). The reason is logged in the page console. |
| No destination marker | The marker is placed by matching the job's destination name against the map's city names (English, from the game data). A city name the game shows in another language (e.g. *München* for *Munich*) is not matched; the rest of the map works. |
| Brightness does not change | `brightnessctl` is missing or your user may not write the backlight (e.g. not in the `video` group). The mode runs without changing it. |
| The screen went to sleep / Firefox window is not fullscreen | `systemd-inhibit` is missing, or another tool overrides the Hyprland window rule. `tiphys-agent doctor` on the laptop lists missing tools. |
| The mode stopped by itself | Firefox exited (closed, crashed) or the agent restarted; start it again. |

See also [Troubleshooting](../troubleshooting.md).
