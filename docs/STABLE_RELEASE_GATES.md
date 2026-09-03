# Sleepwing stable-release gates

“Stable” is an evidence threshold, not a version label. All public-beta gates
must pass first for the same code line. Because Sleepwing has no telemetry, the
following measurements are recorded locally by consenting testers using the
release acceptance template; no prompts, code, paths, or session identifiers
may be collected.

## Required observation window

- At least 7 calendar days on the notarized release candidate or a candidate
  differing only by a documented critical fix followed by a focused rerun.
- At least 50 real completed Agent tasks in total.
- At least 5 real tasks on every advertised surface. A surface that cannot meet
  this gate must be labeled experimental or removed from stable claims.
- At least 2 clean macOS user accounts and 2 Apple Silicon Macs, including the
  oldest supported macOS major version.

## Reliability thresholds

- Lifecycle accuracy: at least 99% of observed transitions match the provider's
  real state, with zero known false “needs attention” or false “completed”
  states remaining open at release time.
- Notification delivery: at least 95% of eligible reminders produce the
  configured visible channel when notifications and banners are enabled; 100%
  of missing-permission cases show actionable guidance.
- Stability: zero reproducible crashes, hangs, persistent high-CPU loops, or
  data-loss defects; at least 99% crash-free test launches.
- Integration safety: 100% of install/remove trials preserve unrelated provider
  configuration, and hooks return promptly when Sleepwing is not running.
- Uninstall success: 100% across at least 2 trials per supported integration,
  including restoration from a configuration that already contains unrelated
  hooks.
- Resource baseline: while idle for 30 minutes, no sustained CPU wake-up loop
  and no unbounded memory growth; exact measurements and hardware are recorded.

## Automatic NO-GO conditions

- Any unresolved security or privacy defect.
- Any release artifact without Developer ID signing, Hardened Runtime,
  notarization, stapling, Gatekeeper acceptance, and a published SHA-256.
- Any advertised platform without real lifecycle evidence.
- A download page, feedback channel, or private vulnerability channel that is
  unavailable.
- A release decision that cannot be tied to an immutable commit and manifest.
