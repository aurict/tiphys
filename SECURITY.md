# Security policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report them privately through GitHub's private vulnerability reporting:
**[Report a vulnerability](https://github.com/aurict/tiphys/security/advisories/new)** (repository *Security* tab ›
*Report a vulnerability*).

Please include:

- the affected component (app, agent, Firefox extension, AT-SPI helper, tools) and version or commit,
- the feature flags involved and how the agent was exposed,
- steps to reproduce or a proof of concept,
- the impact you expect (for example "a tailnet member without a token can …").

Remove real host names, tokens, IP addresses and personal data from logs and screenshots.

This is a one-person project maintained in spare time. You should get an acknowledgement within a week. Fixes land
on `main`. A GitHub security advisory is published once a fix is available, with credit if you want it.

## Supported versions

There are no binary releases. Only the latest commit on `main` is supported. Agent and app are meant to be built
from the same commit. The app warns when an agent is older than the version it expects.

| Version | Supported |
|---|---|
| `main` (latest) | yes |
| older commits | no |

## Scope

The threat model, what Tiphys protects against, and what it explicitly does **not** protect against (for example a
paired device token plus tailnet access being fully trusted) are described in [docs/security.md](docs/security.md).
Reports about behaviour documented there as a known limitation are still welcome if you see a practical way to
improve it.
