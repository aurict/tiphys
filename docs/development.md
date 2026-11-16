# Development

## Prerequisites

| Part | Tools |
|---|---|
| Agent | Node.js 22+ (CI and development use 24), npm |
| App | Flutter 3.47.9 stable, JDK 17, Android SDK platform 36 / build-tools 36.0.0. `tools/setup-dev.sh` installs all of these under `~/opt` without sudo; then `source ~/opt/tiphys-env.sh` |
| Firefox extension | Node.js, npm. Optional: Firefox 140 ESR for manual testing |
| AT-SPI helper | Python 3. For real tests: `python3-gi`, `gir1.2-atspi-2.0`, Xvfb, mousepad |

No emulator is needed. Most behaviour is verified with unit, widget and golden tests on the development machine.
The final check is on a real phone.

CI (`.github/workflows/ci.yml`) runs the same commands as below for the agent, the Python helper, the extension
and the app.

## Agent

```sh
cd agent
npm ci
npx tsc --noEmit -p .        # type check
npx vitest run               # all tests (fake hyprctl/grim/wf-recorder/ydotool/SDK; no real desktop needed)
npx vitest run test/stream.test.ts   # one file
npm run build                # → dist/
node dist/cli.js serve --config /tmp/tiphys-dev/agent.json   # run against a throwaway config
```

Sources are TypeScript run directly by vitest. `npm run build` compiles them to `dist/` with `tsconfig.build.json`.

### Real desktop tests

Tests that touch the real desktop are skipped unless `TIPHYS_REAL=1` is set. They need a running Hyprland session
and real tools. They cover the clipboard, screenshots, ports, audio, the window list, a short live-screen capture
(MJPEG and H.264), a 5 px cursor move that is undone, and a Claude PC screenshot.

```sh
TIPHYS_REAL=1 npx vitest run test/real_desktop.test.ts
```

Run them only on a machine where that is acceptable.

### AT-SPI helper (Python)

```sh
cd agent/test/py
python3 -I -m unittest -v                 # unit tests on recorded/fake accessibility trees
TIPHYS_REAL=1 python3 -I -m unittest -v   # + real test: private Xvfb, private D-Bus with only the a11y bus,
                                          #   temporary HOME, mousepad
```

The real test never uses your display, your D-Bus session or your accessibility settings.

## App

```sh
cd app
flutter pub get
flutter gen-l10n
flutter analyze
flutter test --exclude-tags real          # unit + widget + golden tests
flutter test test/goldens/desktop_test.dart
```

### Golden tests

Screens are rendered inside tests with the real fonts (see `test/flutter_test_config.dart`) and compared against
PNGs in `app/test/goldens/png/`. They come in light/dark, Turkish/English, phone widths of 375–390 px, and some
landscape layouts. Fake agents and fixtures live in `test/helpers/`.

- After an intentional UI change, regenerate and **look at** the diff:

  ```sh
  flutter test test/goldens --update-goldens
  git diff --stat app/test/goldens/png/
  ```

- Some screens show local times, so goldens are rendered in `TZ=Europe/Berlin` (CI sets this). Run
  `TZ=Europe/Berlin flutter test` if your machine is in another time zone.
- Failed comparisons write images to `app/test/goldens/failures/` (git-ignored; uploaded as a CI artifact).
- Golden data must be fictional: example host names (`argo`, `atlas`, `orion`), `example.com` URLs, no real tokens,
  paths or personal content. The README screenshots in `docs/images/` are composites of these goldens.

### Real-server integration tests

Tests tagged `real` (`app/test/integration/`) connect to real hosts over SSH and to real agents, Grafana and Dozzle.
They read their targets from `~/.config/tiphys/real-test.json`. Copy
`app/test/integration/real-test.example.json` and fill in your own hosts and token files.

```sh
flutter test test/integration --tags real
```

### Building

See [getting-started.md](getting-started.md#4-build-the-app). On a machine you are also working on, use
`tools/limited.sh` (`LIMIT_GB`, default 4) so Gradle cannot take all memory.

## Firefox extension

```sh
cd firefox
npm ci --include=dev
npm audit signatures   # verify registry signatures of the pinned dev dependencies
npm run vendor         # copy @mozilla/readability into src/vendor and verify its hash (only when updating it)
npm run lint           # web-ext lint
npm run build          # → dist/tiphys-bridge-<version>.xpi (deterministic, re-checks the Readability hash)
```

The extension's logic is tested from the agent suite (`agent/test/firefox_ext.test.ts`, with a fake `browser`
object; page script in a VM) and `agent/test/firefox_bridge.test.ts` (framing, native host, socket, routes).

## Localisation

The UI is fully bilingual. **No user-visible string is hard-coded.**

1. Add the key to **both** `app/lib/l10n/app_en.arb` (template) and `app/lib/l10n/app_tr.arb`, with an `@key`
   placeholder block where needed.
2. Run `flutter gen-l10n` (output in `app/lib/l10n/gen/`).
3. Use it as `AppLocalizations.of(context).yourKey`.

`test/core/l10n_test.dart` fails if a key or placeholder exists in only one language. The agent never sends
user-facing text. It sends error codes (`agent.*`) and notification keys with parameters, and the app translates
them. New agent error codes therefore need a translation in the app as well. Dates, numbers and sizes are formatted
per locale. Remember Turkish casing rules (`i → İ`, `ı → I`) when comparing or searching.

## Profile schema sync

The profile format is defined once, in Zod, in `agent/src/profile/schema.ts`. After changing it:

```sh
tools/sync-schema.sh
```

This builds the agent, regenerates `schema/tiphys.schema.json`, and copies it plus `tiphys.example.json` into
`app/assets/profile/`. If the change is not backwards compatible, bump `schemaVersion` and add a migration in
`app/lib/core/profile/codec.dart`.

## Code style

- **Language:** UI strings in Turkish and English (ARB files). Code comments, identifiers, commit messages and
  documentation in English.
- **Formatting:** 2-space indentation in Dart, TypeScript, JavaScript, JSON and YAML; 4 spaces in Python and Kotlin;
  LF line endings; UTF-8. See [`.editorconfig`](../.editorconfig). Lines are deliberately wide (around 120
  characters, sometimes more). **Do not run `dart format`** over existing files. Its 80-column default would
  rewrap everything.
- **Lints:** `flutter analyze` (flutter_lints) and `tsc --noEmit` must be clean.
- **Agent conventions:**
  - Every new area goes behind a feature flag; if off, the module is not loaded.
  - New settings go into the Zod schema in `config.ts`.
  - Errors are `AppError("agent.<area>.<reason>", status, params)`.
  - External commands are run with argument arrays and timeouts, never through a shell.
  - Anything that changes the desktop requires a control session.
- **SSH features in the app:** shell-quote every argument, put a timeout on every command, and handle hosts without
  an agent.
- **Tests with every change:** vitest for the agent, unit/widget/golden for the app, unittest for the helper.

## Commits

- One logical change per commit. A short imperative subject line (≤ 72 characters), e.g. `Add Sunshine PIN pairing`.
- An optional body with bullet points explaining what changed and why.
- Commit regenerated goldens together with the change that caused them.
- Never commit secrets, real host names, tailnet names, IP addresses or personal data. Personal files such as
  `PLAN.md`, `*.local.json`, signing keys and `*.env` are git-ignored.

See also [CONTRIBUTING.md](../CONTRIBUTING.md).
