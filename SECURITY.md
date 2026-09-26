# Security policy

Claude Notch sits between Claude Code and you, so it holds itself to a few hard rules:

- **No network.** The only channel is a Unix domain socket in `~/Library/Application Support/ClaudeNotch/` (directory `0700`, socket `0600`), and connections from other users are refused (`getpeereid`).
- **Validated input.** Every message is size-capped (256 KB), schema-decoded and validated (session id format, string lengths, question shape) before it reaches app state.
- **Nothing executes.** No event or UI text can cause the app to run a command. The hook runs one external command, the user's own previous status line from their settings, so it keeps working.
- **Answers only go where they came from.** The reply travels on the connection the asking hook opened, is checked against the question id, and is never sent for a stale question.
- **Permission prompts are never approved from the notch.** Any future approval feature needs its own security review (PRD §32).
- **Minimal data.** Raw shell commands, prompts and code are never stored or shown. `state.json` holds session names, states, timestamps and the current question text only. Diagnostic logging is opt-in and never logs payloads, environment variables or tokens.

Report vulnerabilities privately to the maintainers rather than opening a public issue.
