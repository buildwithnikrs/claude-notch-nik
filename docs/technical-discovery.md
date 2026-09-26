# Technical discovery

Findings for PRD §57 / §62. Each answer says **how we know**:

- **Docs**: current Claude Code documentation (code.claude.com/docs, fetched 2026-09-26).
- **Verified**: demonstrated on a real Mac (macOS 26.6, Apple Silicon) in this repo.
- **Assumed**: reasonable but **not yet observed live**. Listed again at the end as open items.

## 1. Claude Code hook / event capabilities

Claude Code runs user-configured **hooks** (shell commands) at lifecycle points and passes a JSON payload on stdin (Docs: *Hooks reference*). Hooks are configured in `~/.claude/settings.json` and apply to every Claude Code host that reads user settings: the terminal CLI, the Claude desktop app's Code tab and the IDE extensions.

Common payload fields: `session_id`, `transcript_path`, `cwd`, `permission_mode`, `hook_event_name`, plus event-specific fields.

Hooks may be `async: true` (fire-and-forget, never slows Claude) or synchronous with a `timeout` (default 600 s for command hooks).

Events we use:

| Claude Code event | Normalized event | Mode |
|---|---|---|
| `SessionStart` | `session.started` | sync, 5 s |
| `UserPromptSubmit` | `session.working` (reason: prompt) | sync, 5 s |
| `PreToolUse` (`*`) | `session.working` + activity text | async |
| `PreToolUse` (`AskUserQuestion`) | `session.needs_input` (question) | **sync, blocks while the notch waits** |
| `PostToolUse` / `PostToolUseFailure` | `session.working` heartbeat; for `AskUserQuestion`, `session.input_resolved` | async |
| `PermissionRequest` | `session.needs_input` (permission, answered in host) | sync, 5 s, no decision returned |
| `Notification` `elicitation_dialog` | `session.needs_input` (elicitation) | async |
| `Notification` `idle_prompt` | `session.idle` (covers interrupted turns) | async |
| `Stop` / `StopFailure` | `session.completed` (failed for StopFailure) | sync, 5 s |
| `SessionEnd` | `session.ended` | sync, 2 s |

## 2. Session lifecycle

- **Start:** `SessionStart`. Sessions already running when the app launches are picked up by their next event of any kind (every event carries `session_id` and `cwd`).
- **End:** `SessionEnd`. As a backup the app also removes a session when its Claude Code process disappears. The hook records its parent Claude process id; the app checks `kill(pid, 0)` every 20 s. Sessions with no known pid are forgotten after 3 h of silence.
- **Verified:** the full event path (hook binary → socket → state machine → persisted state) with synthetic hook payloads against the running app.

## 3. Detecting user questions

Claude asks structured questions through the built-in **`AskUserQuestion`** tool, so a `PreToolUse` hook with matcher `AskUserQuestion` sees the whole question before any UI appears (Docs: *Agent SDK: handle approvals and user input*):

```json
{ "questions": [ { "question": "…", "header": "…", "multiSelect": false,
                   "options": [ { "label": "…", "description": "…" } ] } ] }
```

Each call has 1–4 questions with 2–4 options. Permission prompts are reported by `PermissionRequest`, and MCP elicitations by `Notification` (`elicitation_dialog`).

## 4. Structured answer options

Yes: the `options[].label` values above. Free text is supported by returning the user's own text as the answer value (the same contract as the SDK's "Other" option).

## 5. Returning answers safely

A `PreToolUse` hook can return `permissionDecision: "allow"` with an `updatedInput` (Docs: *Hooks reference*). For `AskUserQuestion`, the documented answer contract (Docs: *Agent SDK user input*) is: pass the original `questions` through and add `answers`, keyed by question text, with the chosen label or free text as the value.

```json
{ "hookSpecificOutput": { "hookEventName": "PreToolUse", "permissionDecision": "allow",
  "updatedInput": { "questions": [ … ], "answers": { "Which database should I use?": "SQLite" } } } }
```

**Verified:** the hook emits exactly this JSON when the app replies, and emits nothing (so Claude Code shows its normal prompt) on timeout, on "answer in Terminal", when the app isn't running, or on malformed input.

**Assumed:** that the interactive CLI accepts `answers` through a *hook's* `updatedInput` the same way the SDK's `canUseTool` does. The SDK documents that path; for hooks it's supported by `updatedInput` semantics and community reports, but we haven't watched it happen in a live CLI session yet. **This is the first thing to confirm.** If it doesn't hold, the fallback is a `deny` decision whose reason carries the answer ("The user answered: SQLite"). Claude reads that reason, so the experience survives.

**Where answering is enabled:** only when `CLAUDE_CODE_ENTRYPOINT` is `cli`. In the desktop app (`claude-desktop`, **verified** in this environment) and the IDE extensions, the host has its own question UI. Holding the question in a hook there could make the host look frozen or ask twice, so the notch notifies and offers "Open <app>" instead.

**Why this is safe:**
- The reply travels back on the same socket connection the hook opened, so an answer for session A can't reach session B.
- Replies are checked against the question id.
- A stale question (hook gone, timed out or resolved) is never answered.
- UI text is never executed.

## 6. Completion

`Stop` fires when Claude finishes responding (every turn). `StopFailure` fires when a turn ends on an API error. The app celebrates only turns of 15 s or more ("meaningful work"); shorter turns finish quietly. `idle_prompt` (Claude has been waiting at its prompt) quietly ends turns that never got a `Stop`, such as when the user pressed Esc.

## 7. Identifying multiple sessions

`session_id` is unique per session and present on every hook and status line payload. Display names come from the enclosing git repository name, falling back to the last component of `cwd`. `session_id` is validated (`[A-Za-z0-9._-]{1,128}`) at the bridge.

## 8. Reliable usage limits

Claude Code passes this JSON to **status line** commands (Docs: *Customize your status line*):

- `context_window.used_percentage`: per session. Computed from input tokens only.
- `rate_limits.five_hour.{used_percentage,resets_at}` and `rate_limits.seven_day.{…}`: account-wide. **Only for claude.ai Pro/Max subscribers, only after the first API response, and each window may be absent.**

These are shown as **verified**. To receive them, Claude Notch installs a status line command. If the user already has one, we store it and run it, so their status line keeps working unchanged. This is opt-in during onboarding ("Show plan usage") because a custom status line replaces some footer hints in the terminal.

**Not available:**
- **Daily usage:** no reliable source exists, so it's shown as "daily limits aren't reported" rather than invented.
- **Usage in desktop-app sessions:** **assumed** that the desktop app doesn't run status line commands.

**Estimated:** when no status line data exists for a session, the hook reads the tail of the transcript after each turn and estimates context usage from the last assistant message's token counts. The window size is guessed (200k, or 1M for `[1m]` models), so the value is always labeled **Estimated** and can never overwrite a verified value.

## 9. Reset windows

`rate_limits.*.resets_at` (Unix seconds). The countdown is computed locally with no polling, and windows are dropped once their reset time passes, mirroring Claude Code.

## 10. Native notch / window technology

We chose **AppKit `NSPanel` + SwiftUI** (see `architecture.md`). Notch geometry comes from `NSScreen.safeAreaInsets.top` and `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (macOS 12+).

**Verified:** on a 14" MacBook Pro the notch is 185 × 32 pt, and the panel sits centered at the top edge at window layer 27 (above the menu bar). On displays without a notch, a notch-like shape is drawn in the center of the menu bar.

Clicks pass through everywhere except the visible shape. That hit area is driven by mouse-moved monitoring, which needs no Accessibility permission.

## 11. Local IPC

A **Unix domain socket** at `~/Library/Application Support/ClaudeNotch/bridge.sock` carrying newline-delimited JSON.

- No TCP port, so nothing is reachable from the network (AC-019).
- **Verified:** the socket is `0600` inside a `0700` directory.
- Peers must pass `getpeereid` with the same uid.
- Messages are capped at 256 KB and validated before touching state.
- The hook connects, writes one line, and exits. The one exception is a question, where it waits on the same connection for the reply.
- **Verified:** a hook invocation takes about 30 ms, and returns immediately and silently when the app isn't running.

We rejected:
- **localhost HTTP:** it needs a port plus auth to stop other local processes and web pages.
- **XPC:** it needs a signed launch agent/Mach service and is overkill for a helper that lives 30 ms.
- **Named pipes:** they have no request/reply per connection.

## 12. Security implications

- The bridge accepts events only from the same user. Events can't make the app run anything: there is no code path from event or UI text to process execution. The only processes the app starts are its own bundled helper (demo) and, inside the hook, the user's own previous status line command, taken from their own settings.
- Activity text is built from tool names, file base names and the tool's own `description`. **Raw shell commands are never shown or stored**, and leading `VAR=value` assignments are skipped so secrets can't leak into the UI. Prompts and code are never stored.
- `settings.json` edits:
  - touch only entries containing `notch-hook`;
  - back up the file once to `settings.json.claude-notch-backup`;
  - refuse to edit a file that isn't strict JSON;
  - are fully reversible (Disconnect).
- Permission prompts are **never** approved from the notch (PRD §32 / V2). The app only points the user to the host.

## 13. Branding / mascot

The mascot is an **original** pixel critter drawn in code (`apps/macos/Mascot.swift`). It uses no Anthropic artwork. It sits behind a `MascotRenderer` protocol, so official art can be swapped in if permitted.

**Before public distribution:** review Anthropic's trademark and brand guidelines. The product name contains "Claude" and the app uses a Claude-like orange. Don't imply the app is made or endorsed by Anthropic. The bundle id deliberately avoids `com.anthropic`.

## 14. macOS versions

- **Minimum macOS 14 (Sonoma):** SwiftUI `onChange` two-parameter form, `SMAppService`, `.push` transitions.
- **Built and tested:** macOS 26.6 (Apple Silicon) with only the Command Line Tools (Swift 6.3); Xcode isn't required.

## Open items to verify live

1. The CLI accepts `updatedInput.answers` from a `PreToolUse` hook for `AskUserQuestion` (see §5; the fallback is ready).
2. The `CLAUDE_CODE_ENTRYPOINT` value for the terminal CLI is `cli`, and for the VS Code / JetBrains extensions contains `vscode` / `jetbrains`.
3. `PermissionRequest` and `idle_prompt` fire in the desktop app.
4. Whether the desktop app runs status line commands (if yes, plan usage also appears for desktop sessions, with no code change).
5. Run a multi-hour soak with real sessions (PRD §38).
