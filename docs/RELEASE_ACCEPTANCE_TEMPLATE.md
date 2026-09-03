# Sleepwing release acceptance record

Copy this file for one immutable release candidate. Keep the record out of the
product bundle if it contains tester or machine details. A checked result must
link to a screenshot, command output, or concise observation note that contains
no prompt, code, path, token, or session identifier.

## Candidate

- Git commit:
- Sleepwing version/build:
- macOS version and architecture:
- Test date:
- Tester:
- Notarized archive SHA-256:

## Automated evidence

- [ ] `swift test -Xswiftc -warnings-as-errors`
- [ ] `swift build -c release -Xswiftc -warnings-as-errors`
- [ ] `sh Scripts/release-preflight.sh`
- [ ] `codesign --verify --deep --strict`
- [ ] `xcrun stapler validate`
- [ ] `spctl --assess --type execute`

## Real lifecycle evidence

| Surface | Version | Start | Attention | Complete | Failure | Return/focus | Remove/reinstall | Notes/evidence |
|---|---|---:|---:|---:|---:|---:|---:|---|
| ChatGPT / Codex | | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] | |
| Claude Code | | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] | |
| Cursor IDE and CLI | | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] | |
| OpenCode | | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] | |
| Gemini CLI | | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] | |
| TRAE / TRAE CN | | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] | |
| pi coding agent | | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] | |

Use `N/A — provider does not expose this state` only when the product UI and
release notes state the same limitation. A connection probe is not lifecycle
evidence.

## Clean-account and desktop evidence

- [ ] First-run onboarding and notification guidance
- [ ] Launch at login, quit, restart, update, and uninstall
- [ ] Light, dark, and complex desktop backgrounds
- [ ] Reduce Motion
- [ ] Lock/unlock and sleep/wake
- [ ] Multiple displays, display removal, Spaces, and full screen
- [ ] Idle CPU and memory observation
- [ ] Valid and invalid custom-pet import, including required visual QA
- [ ] Fresh downloaded ZIP opens without a Gatekeeper workaround

## Decision

- Blocking defects:
- Known limitations included in release notes:
- Rollback artifact and manifest:
- Decision (`NO-GO`, `BETA GO`, or `STABLE GO`):
- Decision owner and date:
