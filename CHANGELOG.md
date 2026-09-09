# Changelog

All notable user-facing changes to Sleepwing are documented here.

## [Unreleased]

- Public beta distribution and lifecycle acceptance remain release gates; see
  [the release checklist](docs/RELEASE_CHECKLIST.md).

## [0.6.4-beta.1] - 2026-09-09

### Fixed

- Phantom "Codex needs your approval": hooks arrive as independent
  processes, so a pre-Stop PermissionRequest could be delivered after the
  turn's Stop — it then cancelled the gated completion and left the session
  stuck in "waiting for input" with nothing to approve. The completion gate
  now drops an ask that arrives while that turn's completion is pending;
  genuine new asks are unaffected because their turn's prompt/tool events
  clear the gate first.

## [0.6.3-beta.1] - 2026-09-07

### Fixed

- The exact terminal tab return now also works for OpenCode and pi: their
  plugin/extension spawns the relay detached (a new session with no
  controlling terminal), so the tab route was never generated on those
  surfaces. The hosting process now captures its own terminal device name
  once at load and ships it in the payload; the relay validates it exactly
  like a process-derived name, and a process-derived name still wins.
  Restart OpenCode / pi once so the upgraded plugin loads.

## [0.6.2-beta.1] - 2026-09-07

### Fixed

- The exact terminal tab route shipped in 0.6.1 was never actually attached:
  on macOS, `ttyname` on an opened `/dev/tty` reports the alias itself, so
  the relay found no routable device and every click fell back to app
  activation. The relay now reads the controlling terminal from the
  process's own record, and the route survives an end-to-end pty test.

## [0.6.1-beta.1] - 2026-09-06

### Added

- Terminal-hosted tasks now route back to the exact terminal tab: hooks
  capture the session's controlling tty device name (never contents or
  paths), it travels as an allowlisted `perch-tty://` resume route, and
  clicking “Open task” selects that tab in Terminal.app or iTerm2 instead
  of only activating the app and explaining where the session lives.
  Unscriptable terminals keep the app-activation fallback. First use asks
  for macOS automation consent.

### Changed

- "Open OpenCode" (and other terminal-hosted returns) no longer dead-clicks:
  if the right terminal is already frontmost the pet says where the session
  lives instead of silently re-activating it, failures now answer at the pet
  instead of only in the menu-bar inbox, and any known terminal (Ghostty,
  kitty, Alacritty, WezTerm…) is now eligible for recall, not just the
  hardcoded three.
- Spoken announcements yield to live calls: when any other app is using the
  microphone, the pet stays quiet and retries on the follow-up cadence —
  banners and the visual state still deliver. Subagent completions are
  pinned by test to read as ongoing work, so they can never celebrate or
  recall. The Integrations page now states the reversibility guarantee
  where installs happen.
- "Installed but silently dead" can no longer happen quietly: Sleepwing
  rescans host configurations about once a minute, and if a hook that has
  delivered real events before disappears (removed by another tool or an
  update), the menu bar warns and points to reconnection. Disconnecting
  inside Sleepwing never triggers the warning.
- The pet now yields full-screen apps by default: while agents work it stays
  off other apps' full-screen Spaces, and surfaces there only when an agent
  needs you (or fails). A new setting restores the old always-visible
  behavior.

### Fixed

- The Pet Studio sheet is sized clearly below its fixed host window instead
  of covering it edge to edge.

## [0.6.0-beta.1] - 2026-09-03

### Added

- Optional macOS banners for agent lifecycle edges: one when a task starts
  waiting for you (or fails), one when a task finishes. Banners are skipped
  while the app hosting that session is frontmost (frontmost stops counting
  as watching once keyboard and mouse have been idle for a few minutes),
  during quiet hours, and for muted sessions; parallel completions from one
  source collapse into a single banner per 30-second window, and a resolved ask withdraws its own
  stale banner. Clicking a banner follows the task's allowlisted resume
  route or activates the hosting app. Both edges have independent toggles
  in Settings, on by default.
- An opt-in spoken announcement (off by default) when a task starts needing
  you: the on-device voice speaks a full sentence — naming the agent, what
  it is waiting for, and the bounded task label when one exists — so it
  reaches you away from the screen, without any network synthesis. Agents
  that stop within a couple of seconds of each other are merged into one
  spoken summary instead of talking over each other, and while the ask
  stays unresolved and you stay away it repeats up to two follow-ups at
  two-minute intervals; any sign of presence, quiet hours, or mute ends
  the ladder. It follows the same suppression rules as banners and works
  even when notification permission is denied.

### Changed

- The product is now named **Sleepwing** (formerly Perch). The bundle
  identifier moved to `app.sleepwing.Sleepwing`; existing hook installs keep
  working because integration markers and local data paths are unchanged.
- The completion celebration is one deliberate pass instead of a 1.8-second
  sprint: the frames hold roughly twice as long, so the same arc lasts about
  three seconds and no longer reads as fast-forward next to its caption. The
  celebration window, the caption, and the demo pacing all derive from one
  constant, so they cannot drift apart.
- Tightened the final release candidate across its trust boundaries: canonical
  HTTP rejects ambiguous framing and pipelined bytes, provider configuration
  and persisted state reads are size-bounded and refuse symbolic links,
  managed secrets and backups use owner-only permissions, and Codex return
  routes accept exactly one bounded unreserved thread identifier. Diagnostic
  exports now use owner-only storage and prune only verified report files;
  selected reference photos are decoded through a bounded thumbnail rather
  than loading an arbitrarily large raster into memory.
- Moved integration inventory and custom-pet discovery away from the main
  actor, removed automatic Downloads/Desktop scans that could block on large
  or cloud-backed folders, made overlapping pet
  refreshes cancellation-safe, and reduced idle window/pointer polling while
  preserving responsive docking and drag behavior. A saved custom pet now
  displays the built-in cat while its package is resolving instead of exposing
  a generic paw placeholder.
- Restored the centered `Sleepwing` window title with one compact navigation row,
  removing the duplicate brand treatment from the Settings content area.
- Stale lifecycle signals no longer become a false completion or remain a
  falsely active task. Sleepwing keeps the task visible as "status unconfirmed",
  pauses health timing and sleep protection, and resumes it on the next real
  provider event.
- Hardened local input boundaries: the relay now reads hook stdin with a fixed
  cap, Agent-backed pet chat drains both output pipes with bounded retention and
  a hard-kill fallback, and custom-pet dimensions are checked before raster
  decoding.
- New custom pets must carry the passing `qa-summary.json` produced by Sleepwing Pet
  Skill with `--require-visual-qa`; installation is staged atomically. Existing
  locally installed pets remain usable and are labeled when no visual-QA record
  exists.
- Pi integration now relies on Pi's documented automatic extension discovery
  directory instead of redundantly invoking `pi install` and mutating Pi's
  package settings.
- First-run and `--show-settings` launches now use one retained native settings
  window and reliably move it to the active Space and foreground.
- Agent configuration reads are capped at 2 MB and fail closed: an unreadable,
  invalidly encoded, or unexpectedly large existing configuration is never
  treated as empty or overwritten.
- Distribution resources now resolve only from the signed app bundle. The
  release build no longer falls back to the developer's SwiftPM build folder,
  and every build verifies the bundled characters, brand assets, localization,
  Sleepwing Pet Skill, and deterministic packager before it can be shipped.
- `hatch-pet` is explicitly optional. Sleepwing ships its own agent-neutral skill
  and structural validator instead of claiming a developer-local Codex skill
  will exist on an end user's Mac.

- Sleep protection now covers the whole live agent session: the screen
  stays awake while a verified session is waiting for the user's input,
  not only while it is actively working — interactive sessions alternate
  between the two constantly. Power safeguards and the continuous-hours
  cap are unchanged. In conversation mode the chat bubble hides the
  redundant "say more" button, and the agent CLI path is cached and
  prewarmed so replies start faster.
- Reorganized Pet Studio around two clear starting points — "Start from
  a photo" and "Start from an idea", each with its own agent picker — and
  folded the standalone skill-install, copy-prompt, and Codex cards into
  them; importing moved next to the library heading. Creation prompts now
  ship with an editable default character instead of empty brackets,
  Codex prompts are also copied to the clipboard in case the deep-linked
  task opens empty or truncated, and the whole studio now follows the
  in-app language setting.
- The privacy policy and the landing page privacy section now state the
  no-outbound-network guarantee explicitly: Sleepwing's only network surface is
  the local loopback listener, with no telemetry endpoint and no automatic
  update check.
- Sharpened the two built-in companions' health-reminder copy so each reads
  as a distinct character instead of the same lines with different word
  choices: Sleepwing Bird leans into a terse, recurring "I've got this
  stretch/I'm watching" night-watch voice, and Moontail Cat leans into a
  recurring library of specific cat body-language details (tail, blinking)
  instead of generic warmth. Required tool-name and duration disclosures are
  unchanged.
- Gave each built-in companion its own signature line for the moment work
  completes, instead of both sharing one generic "this round is done" line.
  Custom pets keep the original generic line, since an imported pet has no
  inherent personality to lean into.

### Added

- The voice bridge learned dispatch: say "tell codex to run the tests"
  (or Chinese equivalents) and a confirmation card shows the exact
  message and the target agent — always the user-designated one, never a
  built-in preference — before anything is sent. Confirmed dispatches
  start the agent's CLI fire-and-forget, and the resulting task flows
  into the inbox through the normal lifecycle hooks.
- An experimental push-to-talk voice bridge (off by default): hold the
  companion for 0.4 s and ask about task status. The microphone lives
  only during the physical hold, recognition is strictly on-device (the
  feature hides itself where that is unsupported), transcripts are
  discarded with the bubble, and nothing is sent anywhere.
- Built-in celebrations now play as real 24 fps alpha-channel video
  overlays (about 0.6 MB each), cropped in the same coordinate system as
  the sprite cells so the hand-off does not jump; the rebuilt eight-frame
  success rows remain the Reduce Motion and custom-pet path. The
  transform-layer hop no longer stacks on top, and an experimental
  frame cross-fade was removed after it proved to cause compositing
  judder.
- Brand tints now resolve per appearance: deep accent text gets a light
  variant in dark mode and faint fills gain enough opacity to stay
  visible, so the character cards and studio chrome read correctly in
  both modes.
- Chat degrades by real capability instead of collapsing silently: when
  the configured reply source is unavailable (for example the on-device
  model on an unsupported system), free-form input now falls back to the
  user's own agent before giving up, so the input field stays available.
  Personality editing starts from the effective default persona instead
  of a blank box, and every presentation-state switch now settles with a
  brief bottom-anchored transition instead of a hard sprite cut.
- Pet Studio rows can now edit a pet's personality and delete installed
  pets; the skill copy follows the app language (a maintained Chinese
  translation ships beside the English skill); the Settings character
  picker lays every pet out in one uniform grid; the companion's
  double-click is recognized reliably; and the idle bubble now invites a
  quick chat.
- First launch now ends with a clearly-labeled demo: the companion acts
  out working, a health nudge, and the completion celebration before any
  agent is connected, so the first minute shows real value. The demo
  drives only the visual states — never the task inbox or statistics —
  cancels the moment a real event arrives, and can be replayed from
  Settings.
- A custom pet's `pet.json` can now carry an optional first-person
  `personality`, which becomes the pet's chat persona; the creation
  prompts and skill spec ask agents to include one.
- The Pet Studio skill button now copies the full perch-pet skill text
  (usable in any agent), and the Settings character picker lists every
  installed custom pet instead of only the active one.
- The photo flow now offers an art-style choice before production —
  faithful-to-photo (default, maximizing likeness), pixel, plush, sticker,
  or 3D toy — passed to the producing agent as concrete hatch-pet style
  presets.
- Pet Studio now discovers installed Sleepwing and Codex `.perchpet` packages on
  its own and refreshes when Sleepwing becomes active. Packages created by other
  agents use the explicit Import action, avoiding startup scans across large
  or cloud-backed Downloads and Desktop folders.
- The companion's gaze now behaves like a living thing instead of a
  tracker: it loses interest in a stationary pointer after a few seconds,
  re-engages the moment the pointer moves, and takes occasional brief
  glances around while idle. Dropping the companion after a drag lands
  with a quick squash-and-settle instead of snapping straight to idle.
  All of it respects the motion setting and Reduce Motion.
- The companion chat grew quick replies ("say more", and a jump to the
  waiting task) plus free-form input. Replies stay strictly in character;
  they come from the on-device model or — only when the user explicitly
  selects it in Settings — from one of the user's own agent CLIs (Claude
  Code, Codex, or Gemini). The reply source is a Settings choice, no
  transcripts are stored, and the privacy policy documents the
  agent-engine exception.
- Double-click small talk can be turned off in Settings, and the
  on-device-model reply generation has its own toggle where the system
  supports it. The chat bubble now hugs its text instead of always
  stretching to the maximum width.
- Double-clicking the companion now makes it say one short in-character
  line grounded in the real current state (task running, waiting for
  input, quiet night). On macOS 26 with Apple Intelligence, the line is
  generated by the on-device model in the character's voice; everywhere
  else a built-in line library answers. Fully local either way — nothing
  is sent anywhere and nothing is stored.
- Each built-in companion now performs its own brief signature move when
  work completes: Sleepwing Bird gives one quiet hop with a soft landing,
  and Moontail Cat leans into a slow contented settle. Custom pets keep the
  generic celebration, and the moves follow the existing motion and
  Reduce Motion settings.
- Pet Studio gained "Start from a photo": Sleepwing lifts the subject from a
  chosen photo fully on device (background removed, centered on a
  transparent canvas) and saves it as reference art for the perch-pet
  skill. The photo never leaves the Mac.
- After "Start from a photo" produces reference art, Pet Studio asks which
  detected agent should continue production instead of assuming Codex: the
  chosen agent receives a creation prompt that embeds the reference-art
  path (Codex opens a prefilled task; other agents get it on the
  clipboard). The prompt and the perch-pet skill now demand exact
  likeness: the produced pet must remain the same recognizable animal as
  the photo — same colors, markings, and shapes — never a redesigned
  character.
- Published a community pet gallery page on the landing site with a
  submission guide; the app itself remains offline, and gallery packages
  are always imported manually through Pet Studio validation.
- Named the official distribution channels on the landing page, in
  `llms.txt`, and in both READMEs: the GitHub Pages site and GitHub Releases
  are the only official sources for Sleepwing and its downloads.
- Added an opt-in "dock beside the working agent's window" setting: while a
  verified agent session is working, the companion perches on the window
  belonging to whichever app the user was last actually working in (a GUI
  agent app, or any terminal hosting a CLI-based agent such as iTerm,
  Terminal.app, or Warp), using only window bounds and owning-app identity
  from `CGWindowListCopyWindowInfo`, which needs no Accessibility or Screen
  Recording permission and never reads window titles or content. It mostly
  sits still near the window's top-right corner and occasionally takes a
  short, eased walk to a new spot along the top edge, rather than pacing
  back and forth continuously; pins to one specific window per app instead
  of flipping between several of the same app's windows tick to tick; hides
  its name label while perched so it doesn't add visual footprint below the
  character; backs off for 15 seconds after the user manually moves the
  panel instead of overriding the drag; requires the frontmost app to hold
  for 1.5 seconds before switching targets, so a quick glance at another
  app doesn't yank it away and back; fades to the new spot (rather than
  "walking" there) when it first docks or switches to a different app's
  window, since that gap can span monitors where no walking speed looks
  natural; and leaves the companion exactly where it is whenever no agent
  is working or no matching window is found.
- Added a "copy a creation prompt" action to Pet Studio for agents other than
  Codex: it installs the `perch-pet` skill and copies a ready-to-paste prompt
  to the clipboard, since only Codex supports the deep link that opens with a
  prompt pre-filled automatically.
- Added an upfront note in Pet Studio explaining that creating a pet from
  scratch needs an agent with image generation and visual inspection, and
  that a host without those can still validate and package an
  already-complete sprite atlas.
- Added an explicit "just a companion, no tools" choice to onboarding's
  connect-agents step: it switches the reminder strategy to the fixed-timer
  mode (which does not depend on any agent) and finishes onboarding, instead
  of leaving agent-free use as an implicit side effect of skipping through.

## [0.5.4-beta.2] - 2026-07-31

### Fixed

- Fixed a gap in a settings-persistence optimization where most settings
  changes only flagged a pending save for the next 15-second tick instead of
  writing immediately; quitting within that window right after a change
  could lose it. Added a termination-time flush.
- Bounded local file accumulation: config-edit backup sidecars, diagnostic
  reports, and stale per-display companion position entries for
  disconnected monitors are now pruned instead of growing forever.
- Fixed "keep the system awake while tasks run" not actually keeping the
  screen on: it only requested `.idleSystemSleepDisabled` (like
  `caffeinate -i`), which stops the Mac from fully sleeping but leaves the
  display's own idle timeout running, so the screen still turned off on
  schedule. It now also requests `.idleDisplaySleepDisabled`.
- Kept long-running pi sessions visibly working by subscribing the Sleepwing
  extension to pi's official `turn_start` and `tool_execution_start` events as
  throttled, content-free liveness signals. Previously a single long agent
  loop produced no events between `agent_start` and `agent_settled`, so the
  working session expired as stale after ten minutes and the companion
  appeared to show only another provider's activity (for example OpenCode
  running in a second terminal).
- Applied the same protection to OpenCode: `message.updated` and
  `message.part.updated` now act as a throttled busy heartbeat during long
  stretches in which no repeated `session.status` event is emitted.
- Corrected the mascot brand mark to a level, centered stance (level beak and
  feet) across the app icon, the in-app vector mark, and the menu bar
  template icon, and showed the mark next to the app name in the Settings
  window header.
- Normalized integration provider icons to one visual grid: bundled logo
  tiles are inset and clipped to the macOS icon-grid proportions so they
  match real application icons, and fallback marks share the same tile.
- Fixed the OpenCode and Gemini CLI integration rows rendering larger than
  every other provider icon: their bundled logos are full-bleed artwork with
  no built-in margin, so they now get the same inset the fallback marks
  already had instead of filling their tile edge to edge.

### Changed

- Made the "keep the system awake while tasks run" continuous-hours limit
  configurable (1-12 hours, default 4) instead of a fixed 4-hour cutoff, and
  surfaced paused states (low power, low battery, timed out) in the menu bar
  panel, not just the active state.
- Reworked the Settings window header: the brand mark, app name, and tab
  navigation now live in a single row instead of a toolbar item that could
  render as two stacked, illegible rows on some systems.
- Turned the menu bar panel's sleep-protection card into a persistent toggle
  with live status, so it can be turned on or off without opening Settings.
- Replaced the settings and menu bar accent color's dependence on the active
  companion role (which turned most interactive controls orange for the cat
  companion) with a single fixed brand teal used everywhere except the
  companion's own preview surfaces (portrait backdrop, role picker swatches),
  which still reflect the selected companion. The Custom Pet Studio's
  unrelated purple accent is retired in favor of the same fixed teal.
- Swapped the Custom Pet Studio's generic "sparkles" icon for a paw-print
  icon that matches its own empty-state artwork.

### Docs

- Updated `docs/BETA_TEST.md`: stopped pinning the test target to a stale
  version number, corrected the Settings window description to match the
  merged header/nav row, added a regression row for the sleep-protection
  toggle, and flagged that Cursor IDE and Cursor CLI currently share one
  hook config in code so both need to be verified independently rather than
  assumed to behave the same.

### Added

- Bilingual landing and download page in `Site/`, covering features, setup
  tutorials for all seven supported agent surfaces, the privacy contract,
  known beta limitations, and the distribution gates from the release
  checklist (requirements, Beta status, SHA-256, policy links, feedback and
  vulnerability-reporting channels).

## [0.5.4-beta.1] - 2026-07-29

### Fixed

- Kept Codex sessions active when a `Stop` hook is followed by continued work,
  instead of prematurely showing “这一轮结束了”.
- Cancelled an in-progress completion celebration as soon as the same Codex
  session resumes.
- Added the official `SessionEnd` lifecycle observer and stopped treating a
  subagent boundary as root-session completion.
- Reframed a visible health reminder when the last Agent stops, so its copy no
  longer claims that ChatGPT or another provider is still running.
- Kept health reminders actionable after work ends without classifying the
  companion itself as an active Agent task.
- Removed attachment names, paths, UUID-like identifiers, malformed Unicode,
  and prompt wrappers from live task labels; unreadable labels now fall back to
  the workspace or an explicit untitled-task label.
- Marked workspace fallbacks explicitly in the task inbox, so a folder name
  such as `shi` is never presented as though it were a session title.

## [0.5.3-beta.1] - 2026-07-29

### Added

- One shared desktop companion for seven supported local Agent surfaces.
- Privacy-safe task inbox with lifecycle state, attention actions, task return,
  and lifecycle-scoped mute.
- Health-opportunity reminders, local daily and seven-day statistics, quiet
  hours, reduced motion, and optional verified-work idle-sleep protection.
- Two built-in characters and validated local `.perchpet` imports.
- Reversible integration installers, local diagnostics, notification health,
  launch-at-login guidance, and display-aware companion recovery.

### Changed

- Unified ChatGPT desktop and Codex lifecycle presentation under the current
  ChatGPT/Codex product family.
- Coordinated companion bubbles and system notifications to avoid duplicate
  reminder delivery.
- Bounded sprite-atlas caching and frame scheduling to reduce idle CPU and
  animation instability.

### Security and privacy

- Reduced provider events before local transport and rejected unsupported
  fields, routes, oversized payloads, and unauthenticated requests.
- Restricted the receiver to `127.0.0.1`, protected its random token with
  owner-only permissions, and made integration removal ownership-safe.
- Added a bilingual privacy policy and fail-closed Developer ID/notarization
  release checks.
