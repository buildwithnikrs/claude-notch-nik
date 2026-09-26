# Architecture

```
Claude Code ──hooks / status line──▶ notch-hook (≈30 ms process per event)
                                        │  ClaudeCodeAdapter: Claude JSON → NormalizedEvent
                                        ▼
                              Unix socket, newline JSON  (0600, same-uid only)
                                        │
                                        ▼
ClaudeNotch.app ── BridgeServer ──▶ NotchModel ──▶ AppState (state machine, source of truth)
                        ▲                │                 │ effects: attention / completed
                        │                ▼                 ▼
                        └── reply ── Question UI     SwiftUI notch views, mascot, sounds
```

## Modules

| Path | Target | Knows about | Must not know about |
|---|---|---|---|
| `packages/core` | `NotchCore` | Normalized events, sessions, questions, usage, priority, timers | Claude Code, sockets, UI |
| `packages/bridge` | `NotchBridge` | Unix socket wire protocol, paths | Claude Code, UI |
| `packages/claude-code` | `ClaudeCodeAdapter` | Hook/status line payloads, `settings.json`, process tree | UI |
| `apps/notch-hook` | `notch-hook` | Glue: stdin → adapter → bridge → stdout | UI |
| `apps/macos` | `ClaudeNotch` | Windows, SwiftUI, sounds, settings | Claude Code JSON (only via normalized events) |

Boundaries from PRD §48 hold by construction. The UI never parses Claude Code output. The adapter never touches UI. Usage lives in session state but can't change session status. `AppState.apply(_:)` is the only thing that moves a session between states.

## Decisions

### Native AppKit + SwiftUI, not a web UI
The notch needs a borderless panel above the menu bar on every Space and in full-screen apps, precise notch geometry, click-through outside its shape, and minimal idle CPU. `NSPanel` (non-activating, level `mainMenu + 3`) gives all of that. SwiftUI gives spring animations and a cheap `Canvas` for the pixel mascot. A web view would add ~100 MB and still need the same AppKit shell.

### SwiftPM only (no Xcode project)
Contributors can build with the Command Line Tools: `swift build`, `scripts/test.sh`, `scripts/build-app.sh`. The `.app` bundle is assembled by the script. It's ad-hoc signed. Notarization is a release-pipeline concern.

### Hooks, not terminal scraping
Following PRD §27, every signal comes from a documented Claude Code hook or the status line JSON. See `technical-discovery.md` for the mapping.

### A tiny helper binary, not a script
The hook runs on every tool call, so it must be fast and dependency-free. It's a ~0.8 MB Swift binary that:
- runs in about 30 ms;
- needs no Python, Node or jq;
- is copied to `~/Library/Application Support/ClaudeNotch/bin/`, so `settings.json` doesn't depend on where the app lives.

### Unix domain socket for IPC
It's the simplest mechanism that is local-only by construction and supports request/reply on one connection. Answers go back on the connection that asked, which makes cross-session delivery impossible rather than merely unlikely. Alternatives are discussed in `technical-discovery.md` §11.

### Answer from the notch only in the terminal CLI
The hook blocks while the notch waits. In the terminal that's invisible: the prompt simply appears later if you don't answer in the notch (120 s). Hosts with their own question UI (desktop app, IDEs) get notify + "Open <app>" instead, so they never look frozen or ask twice.

### Sync vs async hooks
- **Sync** (~30 ms, keeps ordering): `SessionStart`, `UserPromptSubmit`, `PermissionRequest`, `Stop`, `SessionEnd`.
- **Async** (never slow Claude down): tool heartbeats.

The reducer also guards against out-of-order delivery using hook timestamps. A heartbeat older than a completion is ignored.

### State persistence
`AppState` is saved (debounced) to `state.json`. On relaunch, sessions are restored, marked `restored`, and pruned if their process is gone. Restored state never produces celebrations (AC-018). Questions whose hook connection died with the old process are shown as "answer in Terminal".

### Usage provenance
Every metric carries `verified` or `estimated`. The reducer never lets an estimate overwrite a verified value, and the UI badges estimates. Missing data renders as "unavailable" (AC-016).

### Performance
- Event-driven; nothing polls Claude Code. Two timers run: housekeeping every 20 s and a settings check every 60 s, both with tolerance.
- The mascot redraws at 6 fps only while visible, and pauses when displays sleep or with Reduced Motion.

Measured on an M1 Pro:
- **Idle:** ~60 MB RSS, near-0% CPU.
- **Animating:** a few percent.
- **Burst:** 200 hook events in 3.4 s end to end, no growth.

## Adding a new Claude Code signal
1. Map it in `ClaudeCodeAdapter.normalize(hook:context:)` to an existing `NormalizedEvent.Kind`, or add a kind and handle it in `AppState.apply`.
2. Register the hook in `HookInstaller.desiredHooks()`. Existing installs show "needs an update" and reconnect with one click.
3. Add adapter and reducer tests.
