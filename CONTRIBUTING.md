# Contributing

1. `swift build` and `./scripts/test.sh` must pass (Command Line Tools are enough).
2. Keep the boundaries in `docs/architecture.md`: Claude Code knowledge stays in `packages/claude-code`, state transitions stay in `packages/core`, and the UI only consumes `AppState`.
3. New behaviour in the core or adapter comes with tests. UI changes come with a refreshed `--snapshot` render.
4. Check the PRD's MVP scope (§40/§41) before adding features.
