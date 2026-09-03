# Sleepwing public beta release checklist

This checklist is the release authority for the first public beta. A release is
**GO** only when every required item below is complete for the exact Git commit
recorded in `release-manifest.json`. An implemented adapter or fixture test is
not a substitute for a real lifecycle acceptance run.

## 1. Source and automated gates

- [ ] The release commit is reviewed and the worktree is clean.
- [ ] `swift test` passes without new warnings.
- [ ] `sh Scripts/release-preflight.sh` passes.
- [ ] The zipped-and-extracted app passes `Scripts/verify-app-bundle.sh`, opens
  Connection and Pet Studio outside the source tree, and contains no build-Mac
  absolute path.
- [ ] Privacy-sensitive fixtures prove prompts, code, responses, tool
  inputs/outputs, error bodies, and full paths are discarded.
- [ ] The OpenCode API credential that previously appeared in local
  audit-tool output has been rotated at its provider and the old value
  revoked. It never entered the repository or the app bundle (verified
  against the full git history), but any credential that reached a tool
  log is treated as exposed until rotated.
- [ ] A clean macOS user account completes onboarding, connection, notification
  authorization, launch-at-login guidance, restart, update, and uninstall.
- [ ] Companion idle CPU, memory, drag/restore, sleep/wake, unlock, display
  change, Space change, and Reduce Motion behavior pass `docs/BETA_TEST.md`.
- [ ] The exact results and environment are recorded in
  `docs/RELEASE_ACCEPTANCE_TEMPLATE.md` (copy it for each candidate; do not
  check boxes without evidence).

## 2. Real Agent lifecycle acceptance

Run the matrix in `docs/BETA_TEST.md` on the release build. Record the tested
provider version, Sleepwing version/build, macOS version, date, and tester. Each
supported surface must exercise the states it claims.

| Surface | Required public-beta proof | Current gate |
|---|---|---|
| ChatGPT desktop / Codex | working, attention when available, completed, error, return action | Required |
| Claude Code | working, permission/attention, completed, error, return action | Required |
| Cursor IDE / CLI | working, attention when available, completed, error, app focus | Required |
| OpenCode | working, permission, completed, error, removal/reinstall | Required |
| Gemini CLI | working, attention when available, completed, error, removal/reinstall | Required |
| TRAE IDE | working, attention when available, completed, error, app focus | Required |
| pi coding agent | working, attention when available, completed, error, removal/reinstall | Required |

If a provider does not expose a lifecycle state, the UI and release notes must
say so. Do not simulate unavailable states or label a content-free connection
check as real activity.

## 3. Signing, notarization, and artifact gates

- [ ] The build Mac has a valid **Developer ID Application** certificate.
- [ ] `PERCH_SIGN_IDENTITY` selects that certificate.
- [ ] `PERCH_NOTARY_PROFILE` names a working `notarytool` Keychain profile.
- [ ] `sh Scripts/build-beta.sh` succeeds without bypasses.
- [ ] Apple notarization status is `Accepted` and the ticket is stapled.
- [ ] `codesign --verify --deep --strict` and `spctl --assess --type execute`
  pass for the stapled app.
- [ ] The archive contains only `arm64` executables. The current public beta is
  explicitly Apple Silicon only.
- [ ] The published ZIP SHA-256 matches `release-manifest.json`.
- [ ] A fresh download opens on a clean Apple Silicon Mac without Gatekeeper
  workarounds.

The release pipeline follows Apple's current guidance for
[Developer ID](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/),
[notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution),
and [common notarization issues](https://developer.apple.com/documentation/security/resolving-common-notarization-issues).

## 4. Distribution and support gates

- [ ] The download page states: macOS 14 or later, Apple Silicon, Beta, local
  Agent lifecycle limitations, and the SHA-256 checksum.
- [ ] `PRIVACY.md`, `SECURITY.md`, `CHANGELOG.md`, setup instructions, known
  limitations, and removal instructions are linked from the download page.
- [ ] The release notes list only real, accepted capabilities.
- [ ] A feedback channel and private vulnerability-reporting channel are live.
- [ ] The previous signed build and its manifest remain available for rollback.

## Release decision

- **NO-GO** if any required lifecycle row, clean-account flow, Developer ID
  signature, notarization, Gatekeeper assessment, or privacy gate is incomplete.
- **GO for public beta** after all required boxes are checked for one immutable
  commit and its notarized artifact.
- **Stable release** additionally requires every threshold in
  [STABLE_RELEASE_GATES.md](STABLE_RELEASE_GATES.md). Passing this public-beta
  checklist alone does not declare the product stable.
