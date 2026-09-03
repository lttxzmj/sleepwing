# Development hook setup

This setup is for local development. The beta app will provide reversible installers and backups.

Resolve the repository path first and use the absolute path to `Scripts/perch-hook`; agent hook commands should not depend on the current working directory.

## Claude Code

Add commands for these events in `~/.claude/settings.json`: `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Notification`, `Stop`, `StopFailure`, and `SessionEnd`. Each command is:

```sh
/bin/sh /absolute/path/to/Sleepwing/Scripts/perch-hook claude
```

Follow the current official shape at <https://code.claude.com/docs/en/hooks>; merge into the existing `hooks` object and never replace unrelated user hooks.

Sleepwing limits `Notification` to the attention-bearing `permission_prompt`, `idle_prompt`, `elicitation_dialog`, and `agent_needs_input` types. `StopFailure` is treated as a content-free failure rather than completion, and a concurrently delivered `SessionEnd` cannot erase it immediately.

## Cursor IDE

Add the relay to `~/.cursor/hooks.json` for `beforeSubmitPrompt`, `preToolUse`, `postToolUse`, `afterAgentResponse`, `stop`, and `sessionEnd`:

```json
{
  "version": 1,
  "hooks": {
    "beforeSubmitPrompt": [
      { "command": "/bin/sh /absolute/path/to/Sleepwing/Scripts/perch-hook cursor" }
    ]
  }
}
```

Repeat the entry for the other events and preserve existing commands. See <https://cursor.com/docs/hooks>.

Cursor Agents 3.11.13 desktop has been verified end to end with `beforeSubmitPrompt`, `afterAgentResponse`, and `stop`. Cursor CLI and cloud agents have changed hook coverage across releases and require separate compatibility tests.

## ChatGPT desktop / Codex CLI / IDE

Sleepwing installs current Codex lifecycle Hooks and keeps the top-level `notify` command only as a completion-only compatibility path. It does not replace an existing notifier; the installer chains it through a wrapper and restores it on removal.

Current Codex releases document lifecycle Hooks in `~/.codex/hooks.json` or user-level `config.toml`, including `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `Stop`, and `SessionEnd`. Let Sleepwing manage its own entries so install and removal remain reversible. `Stop` is a turn boundary and another Stop hook may continue the turn, so Sleepwing waits for a five-second quiet window before presenting completion; any resumed work cancels that pending completion immediately.

Codex lifecycle Hooks apply to coding-task surfaces that load the user's local Codex configuration, including supported work inside ChatGPT desktop. They do not imply passive monitoring of ordinary ChatGPT conversations.

## OpenCode

Use Sleepwing's Integrations page to connect OpenCode. Sleepwing writes an owned local plugin to:

```text
~/.config/opencode/plugins/perch.ts
```

The plugin listens to official local events including `session.status`, `session.idle`, and `permission.asked`, reduces them locally, and invokes the same best-effort relay. Restart OpenCode after connecting. Sleepwing will not overwrite an unrelated existing `perch.ts`, and removal deletes only a file carrying the Sleepwing ownership marker.

The adapter and privacy fixtures pass locally. OpenCode 1.18.4 has been verified for plugin loading, working traffic, and content-free error traffic; permission and successful completion still require a usable model on the test account. See <https://dev.opencode.ai/docs/plugins/>.

After installation, Sleepwing sends a reserved, content-free idle probe through the local relay. “Local connection passed” confirms the relay and receiver, while “Real state received” is shown only after a non-probe OpenCode event arrives.

## Gemini CLI

Use Sleepwing's Integrations page to connect Gemini CLI. Sleepwing merges its command hooks into `~/.gemini/settings.json` for `SessionStart`, `BeforeAgent`, `BeforeTool`, `AfterTool`, `Notification`, `AfterAgent`, and `SessionEnd`. Existing Gemini settings and unrelated hooks are preserved.

Gemini hook payloads can contain prompts, tool inputs, and responses. Sleepwing's native relay discards all of that before transport and keeps only provider, opaque session identifier, phase, and timestamp. See <https://geminicli.com/docs/hooks/reference/>.

## TRAE IDE

Sleepwing supports both official global locations:

```text
~/.trae/hooks.json
~/.trae-cn/hooks.json
```

It installs `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Stop`, and `Notification` observers using TRAE's version-1 hook schema. Sleepwing chooses the China path when `~/.trae-cn` already exists; otherwise it uses the international path. Removal touches only Sleepwing-owned command entries. See <https://docs.trae.ai/ide/hook-configuration-reference?_lang=en>.
