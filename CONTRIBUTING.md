# Contributing

Thanks for your interest in Tiphys. It is a small personal project, so please keep changes focused.

## Before you start

- **Bugs:** open an issue using the bug report template. Include the agent version (`GET /v1/health`), the Android
  version and relevant agent logs (`journalctl --user -u tiphys-agent`), **with tokens, host names and IP addresses
  removed**.
- **Features:** open a feature request first, especially for anything that lets the phone do something new on a
  machine. Describe how it should be gated (feature flag, control session, confirmation).
- **Security issues:** never in public issues. See [SECURITY.md](SECURITY.md).

## Development setup

Everything you need to build, run and test the agent, the app, the Firefox extension and the AT-SPI helper is in
[docs/development.md](docs/development.md). Setting up a real environment is covered in
[docs/getting-started.md](docs/getting-started.md).

## Pull requests

1. Fork, then create a branch from `main`.
2. Make the change, with tests:
   - agent: vitest (`agent/test/`)
   - app: unit/widget tests, and golden tests for UI changes (`app/test/`)
   - AT-SPI helper: `unittest` (`agent/test/py/`)
3. Run locally. CI runs the same:

   ```sh
   (cd agent && npx tsc --noEmit -p . && npx vitest run)
   (cd agent/test/py && python3 -I -m unittest)
   (cd firefox && npm run lint && npm run build)
   (cd app && flutter gen-l10n && flutter analyze && flutter test --exclude-tags real)
   ```

4. For UI changes, regenerate goldens (`flutter test test/goldens --update-goldens`), check the changed PNGs and
   commit them with the change.
5. Fill in the PR template checklist.

## Rules of thumb

- **Security first.** New capabilities that act on a machine go behind a feature flag (off by default for risky
  ones), and if they change the desktop, behind a control session. Explain the gating in the PR and update
  [docs/security.md](docs/security.md).
- **No hard-coded text.** Every UI string goes into both `app/lib/l10n/app_en.arb` and `app_tr.arb`. If you cannot
  write Turkish, add your best attempt and say so in the PR. The agent sends error codes, not text.
- **No hard-coded addresses, ports, paths or keys** in the app. Everything comes from settings or the profile.
- **Profile format changes** start in `agent/src/profile/schema.ts` and are synced with `tools/sync-schema.sh`.
- **Match the existing style**: wide lines, no `dart format` over existing files, English comments, small focused
  diffs. See [`.editorconfig`](.editorconfig) and [docs/development.md](docs/development.md#code-style).
- **No personal data** in code, tests, fixtures or screenshots: use `argo`, `atlas`, `example.com`,
  `my-tailnet.ts.net`.
- New dependencies need a good reason. Prefer what the project already uses.

## Commit messages

A short imperative subject (≤ 72 characters), optionally followed by a blank line and a body with bullet points
explaining what and why. One logical change per commit.

## License

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE).
