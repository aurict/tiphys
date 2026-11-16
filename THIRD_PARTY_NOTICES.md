# Third-party notices

Tiphys itself is licensed under the [MIT License](LICENSE). The repository also contains the following
third-party files, each under its own license.

## Bundled in the repository

### Mozilla Readability

- **Files:** `firefox/src/vendor/Readability.js`, license text in `firefox/src/vendor/LICENSE.md`
- **Version:** 0.6.0 (npm `@mozilla/readability`, byte-identical to the upstream `0.6.0` tag; the SHA-256 is pinned
  in `firefox/scripts/vendor.mjs` and re-checked by `firefox/scripts/build.mjs`)
- **Copyright:** 2010 Arc90 Inc (as stated in the file header); maintained by Mozilla
- **License:** Apache License 2.0
- **Source:** <https://github.com/mozilla/readability>
- Used unmodified in the Firefox extension's reader view and packaged into the XPI.

### Plus Jakarta Sans

- **Files:** `app/assets/fonts/PlusJakartaSans-*.ttf`, license text in `app/assets/fonts/OFL-PlusJakartaSans.txt`
- **Copyright:** 2020 The Plus Jakarta Sans Project Authors
- **License:** SIL Open Font License 1.1
- **Source:** <https://github.com/tokotype/PlusJakartaSans>

### JetBrains Mono

- **Files:** `app/assets/fonts/JetBrainsMono-*.ttf`, license text in `app/assets/fonts/OFL-JetBrainsMono.txt`
- **Copyright:** 2020 The JetBrains Mono Project Authors
- **License:** SIL Open Font License 1.1
- **Source:** <https://github.com/JetBrains/JetBrainsMono>

## Package dependencies

Libraries installed by package managers are not stored in this repository. Their licenses are listed in their
package metadata:

| Part | Manifest | Lock file |
|---|---|---|
| Agent (npm) | `agent/package.json` | `agent/package-lock.json` |
| Firefox extension, dev only (npm) | `firefox/package.json` | `firefox/package-lock.json` |
| App (pub) | `app/pubspec.yaml` | `app/pubspec.lock` |
| Native plugin (pub) | `app/packages/tiphys_native/pubspec.yaml` | `app/packages/tiphys_native/pubspec.lock` |
| Uptime Kuma seeding tool (npm) | `tools/uptime-kuma/package.json` | `tools/uptime-kuma/package-lock.json` |

Notable runtime dependencies include Fastify, Zod, systeminformation, web-push, yaml, socket.io-client, qrcode-terminal
and `@anthropic-ai/claude-agent-sdk` (agent), and Flutter, Riverpod, go_router, dartssh2, xterm, cryptography,
unifiedpush, flutter_local_notifications, mobile_scanner, fl_chart and flutter_markdown_plus (app).

`@anthropic-ai/claude-agent-sdk` and the Claude Code binary it installs are distributed by Anthropic under their own
terms (its `package.json` says "SEE LICENSE IN README.md"). They are downloaded by `npm ci` and are not part of this repository.

To inspect dependency licenses, see each package's `LICENSE` file under `agent/node_modules/` (after `npm ci`)
or in the pub cache (after `flutter pub get`; `flutter pub deps` lists the packages).
