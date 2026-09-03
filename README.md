# Sleepwing

> Formerly developed under the codename **Perch**; source modules keep that codename internally.

[中文](README.zh-Hans.md) | English

Sleepwing is a privacy-first macOS desktop companion that watches local AI coding agents while the user takes a real break. It turns verified Agent work time into bounded health opportunities, then recalls the user when an Agent needs input. One companion represents every connected Agent; the menu bar handles exact status, integrations, and local statistics.

> When AI takes over the work, Sleepwing gives the time back to your body—and calls you back when it is your turn.

Official downloads are published only on [GitHub Releases](https://github.com/lttxzmj/sleepwing/releases); the only official website is [lttxzmj.github.io/sleepwing](https://lttxzmj.github.io/sleepwing/).

## Current status

The repository contains the v0.6.0 Beta RC development build:

- one transparent, draggable desktop companion shared by every connected Agent
- two built-in characters with controlled personalities, role-adaptive accents, three sizes, floating/desktop layers, per-display position restore, and reduced-motion support
- native launch-at-login control with macOS approval-state guidance
- separate resting, working, attention, celebration, and health-reminder presentation states
- a privacy-safe task inbox built on provider + opaque session lifecycle, with per-task running time, attention state, return action, and lifecycle-scoped mute
- the same task semantics in the menu bar and companion bubble, instead of flattening every session into a generic Agent message
- wall-clock health opportunity timing that counts parallel work once and pauses for attention
- native relay sanitization before localhost transport; only provider, opaque session ID, phase, timestamp, a bounded project/task label, and an allowlisted local resume route enter the App
- current Claude Code, local Cursor, ChatGPT/Codex, OpenCode, Gemini CLI, TRAE, and pi coding agent lifecycle adapters with reversible installers and ownership-safe removal
- Codex turn-boundary debouncing that keeps resumed work active and reserves completion for a verified quiet window or session end
- status-bearing menu-bar label, onboarding, actionable macOS notifications, bilingual copy, local health/work statistics, and atomic persistence
- action-oriented status copy, app-focus recovery, and working-time versus post-completion reminder strategies
- automatic content-free connection checks that remain distinct from real Agent activity
- the last real lifecycle-event time so “verified before” is never confused with “active now”
- notification health that distinguishes authorization from banner availability without cluttering the primary UI with diagnostics
- one reminder-delivery coordinator that keeps companion bubbles, visible system banners, quiet hours, attention priority, and durable ten-minute snoozes mutually consistent
- a one-click, allowlisted diagnostic report that opens in Finder and cannot contain prompts, code, responses, tool inputs, paths, or identifiers
- optional verified-work sleep protection that keeps the display awake for the whole live agent session (working and waiting alike) and releases on power safeguards
- local seven-day timing comparisons for during-work and post-completion reminders, including an attention-response guardrail
- local daily and seven-day completed-task counts, kept separate from health outcomes
- role-specific continuity copy that remembers today's completed breaks and reclaimed time without gamifying screen time
- an Agent-skill Pet Studio that installs the bundled `perch-pet` workflow, imports validated `.perchpet` packages, and previews their real idle motion
- a bundled, agent-neutral `perch-pet` workflow and validator; Codex may delegate specialist production to `hatch-pet` only when that optional skill is already available
- display-aware companion recovery across screen changes, Space changes, unlock, and wake
- bounded, revision-aware sprite-atlas caching with state prewarming and frame-boundary scheduling matched to each animation's declared timing
- 114 deterministic tests, an ad-hoc signed development `.app`, and a fail-closed Developer ID/notarization release script

## Run locally

Requirements for development: macOS 14+, Xcode 16+.

The current public-beta distribution target is **macOS 14 or later on Apple
Silicon**. Intel compatibility is not claimed until a universal build completes
the same lifecycle and clean-device acceptance matrix.

```sh
swift test
swift run Sleepwing
```

Build a double-clickable, ad-hoc signed development app:

```sh
sh Scripts/build-app.sh
open .build/perch-app/Sleepwing.app
sh Scripts/smoke-event.sh claude PreToolUse
```

Send a development event:

```sh
printf '%s' '{"hook_event_name":"PreToolUse","session_id":"demo"}' \
  | sh Scripts/perch-hook claude
```

The first run guides the user through character selection, optional Agent connections, and live state previews. Integration changes happen only after the user presses Install.

The downloaded app has no npm, Node.js, Python, or developer-checkout runtime dependency. Monitoring, reminders, bundled characters, connection setup, and `.perchpet` import validation are native and self-contained. The optional agent-side custom-pet production workflow may use tools already provided by that agent host; `hatch-pet` is an enhancement, never an app dependency.

## Integration support

| Surface | Beta support | Boundary |
|---|---|---|
| Claude Code | Local lifecycle hooks | Local sessions only |
| Cursor IDE / CLI | Local Agent hooks | Cloud Agents remain out of scope |
| ChatGPT desktop / Codex CLI / IDE | Current Codex lifecycle hooks inside the ChatGPT product; legacy `notify` remains completion-only | First install may require `/hooks` trust; ordinary chats are not lifecycle tasks |
| OpenCode | Official local plugin lifecycle events | Implemented and fixture-tested; stable-session smoke test remains |
| Gemini CLI | Official local hooks | Installed and relay-verified on the test Mac; real task smoke test remains |
| TRAE IDE | Official local hooks | International and China config paths supported; fixture-tested, app smoke test remains |
| pi coding agent | Official local extension lifecycle | Implemented and fixture-tested; real task smoke test remains |

See [custom pet research and flow](docs/CUSTOM_PET_RESEARCH_AND_FLOW.md),
[product strategy](docs/PRODUCT_STRATEGY.md),
[product requirements](docs/PRODUCT_REQUIREMENTS.md),
[technical research](docs/TECHNICAL_RESEARCH.md), and
[hook setup](docs/HOOK_SETUP.md).

## Release

Run the source gate locally:

```sh
sh Scripts/release-preflight.sh
```

The public-beta build is intentionally fail-closed. It requires a Developer ID
Application certificate and an authenticated `notarytool` Keychain profile:

```sh
PERCH_SIGN_IDENTITY="Developer ID Application: …" \
PERCH_NOTARY_PROFILE="perch-notary" \
sh Scripts/build-beta.sh
```

The script runs tests and source checks, signs with Hardened Runtime and a secure
timestamp, submits the ZIP to Apple, staples and validates the ticket, runs
Gatekeeper assessment, and emits both the final ZIP and
`release-manifest.json` with its SHA-256 checksum. Release only after
[the public-beta checklist](docs/RELEASE_CHECKLIST.md) is complete.

See the [privacy policy](PRIVACY.md), [security policy](SECURITY.md),
[changelog](CHANGELOG.md), and [removal guide](docs/UNINSTALL.md).

## License

Sleepwing is source-available under the
[Functional Source License, Version 1.1, MIT Future License](LICENSE.md)
(FSL-1.1-MIT): you can read, audit, build, and modify the code for any
non-competing purpose, and each release becomes MIT-licensed two years after
it ships. Brand and artwork assets are licensed separately — see
[LICENSE-ASSETS.md](LICENSE-ASSETS.md).

## Privacy contract

Sleepwing records only provider, opaque session identifier, phase, timestamp,
reminder kind, reminder response, and bounded timing metrics. It does not
persist prompts, assistant responses, code, paths, tool arguments, or tool
output.

For the live task inbox, Sleepwing may keep a provider-supplied task title, a
deterministically cleaned Codex request label of at most 42 characters, or the
final component of `cwd` (for example, `Sleepwing`, never the full path) in memory
until that session expires. Attachment names, paths, UUID-like identifiers,
markup wrappers, and malformed Unicode are rejected before localhost
transport. Sleepwing never persists the full prompt. Codex resume links are
allowlisted `codex://threads/<session-id>` routes and are not written to
statistics or diagnostic reports.

The complete policy is in [PRIVACY.md](PRIVACY.md) (also available in [Chinese](PRIVACY.zh-Hans.md)).
