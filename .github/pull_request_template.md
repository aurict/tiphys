## What and why

<!-- Short description of the change and the motivation. -->

## Checklist

- [ ] Tests added or updated (agent: vitest; app: unit/widget/golden; helper: unittest)
- [ ] `npx tsc --noEmit`, `npx vitest run`, `flutter analyze`, `flutter test --exclude-tags real` pass locally
- [ ] New UI strings added to both `app_en.arb` and `app_tr.arb`
- [ ] Anything that acts on a machine is behind a feature flag / control session and is documented in `docs/security.md`
- [ ] No secrets, host names or IP addresses in code, tests or screenshots
