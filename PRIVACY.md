# Sleepwing Privacy Policy

[中文](PRIVACY.zh-Hans.md) | English

Effective date: 2026-07-29

Sleepwing is a local-first macOS companion for supported AI coding agents. It does
not require a Sleepwing account and does not send prompts, code, responses, or
health activity to a Sleepwing-operated server.

## Data Sleepwing processes

To show task state, Sleepwing accepts only the provider name, an opaque session
identifier, lifecycle phase, timestamp, an optional task label of at most 48
characters, its label kind, and an allowlisted local return route. Session
identifiers, task labels, and return routes are used for the live task view and
expire with the session; they are not included in statistics or diagnostic
reports.

Sleepwing stores app settings, companion position and appearance, reminder
responses, bounded task timing totals, completed-task counts, and aggregated
wellbeing statistics locally. Reminder and operational history is retained for
up to 30 days.

Sleepwing never stores full prompts, source code, assistant responses, tool inputs
or outputs, error bodies, or full file-system paths. It has no advertising,
cross-app tracking, product analytics, or telemetry.

## Local integrations

Sleepwing makes no outbound network connections — it has no server side, no
telemetry endpoint, and no automatic update check. Its only network surface is
a listener on the local loopback interface (`127.0.0.1`), and installed hooks
deliver sanitized events to that local address only. A random receiver token
is stored with owner-only permissions.

The optional companion chat is fully local by default (built-in lines, or
the system's on-device model). Only if the user explicitly selects "My
agent" as the chat engine are typed chat messages handed to that locally
installed agent CLI, which processes them under its own provider's terms;
Sleepwing itself still opens no network connections and stores no chat
transcripts. Supported Agent
integrations are installed only after user action and can be removed from
Sleepwing. Configuration edits are scoped to Sleepwing-owned entries and may create
adjacent local backup files to support recovery.

Imported `.perchpet` packages remain local. Sleepwing validates their size, paths,
manifest, assets, and visual-QA summary, and rejects symbolic links. Existing
legacy pets remain usable, but a new pet cannot be installed without a passing
visual-QA record.

## Notifications and wellbeing

Notification permission is managed by macOS. Sleepwing uses local notifications
for task and wellbeing reminders and may open System Settings or a supported
provider app when the user chooses an action. Wellbeing prompts are general
break suggestions, not medical advice or a medical service.

## Your controls

You can disable notifications, pause reminders, disconnect integrations, or
quit Sleepwing at any time. Before uninstalling, remove installed integrations from
Sleepwing so it can restore the entries it owns. Local Sleepwing data is stored in
`~/Library/Application Support/Perch`; app preferences are stored by macOS for
bundle identifier `app.sleepwing.Sleepwing`.

For vulnerability reports, follow [SECURITY.md](SECURITY.md). Material privacy
changes will be recorded in [CHANGELOG.md](CHANGELOG.md).
