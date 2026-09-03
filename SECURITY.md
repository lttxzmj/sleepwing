# Sleepwing Security

Sleepwing is designed to observe supported AI tools locally and provide companion and
wellbeing reminders without sending session contents to a Sleepwing-operated server.

## Local security model

- The local event receiver listens only on `127.0.0.1`.
- Integration tokens are stored with owner-only permissions (`0600`).
- Hook payloads are bounded before buffering and reduced to a small canonical
  lifecycle event before they reach the app.
- Imported pet packages are size-checked before raster decoding, path-validated,
  installed atomically, and rejected when they contain symbolic links. New
  imports also require a passing bounded visual-QA attestation.
- Optional Agent-backed pet chat uses direct executable arguments, bounded
  output, drained pipes, and a hard timeout; Sleepwing stores no transcript.
- Sleepwing does not require users to paste AI provider API keys into the app.

## Reporting a vulnerability

Please use the repository's private security advisory feature to report a
vulnerability. Do not include access tokens, private prompts, session contents,
or other personal data in a public issue.

Include the affected Sleepwing version, macOS version, reproduction steps, and the
impact you observed. We will acknowledge a complete report as soon as practical.
