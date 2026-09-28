# Changelog

Each release on GitHub uses its section below as the release description.
Add a `## <version>` section here before tagging a release.

## 0.1.2

**Fixes**
- The open notch panel responds to clicks again. The Usage tab, the Settings button and the rest of the panel used to ignore clicks and close the notch.
- The panel no longer closes as soon as the pointer drifts off it. It now waits a little longer.
- Context usage is accurate for models with a 1M-token window. Before, a compacted session could show about 94% when it was really near 19%.

**Improvements**
- The Usage tab explains that weekly and 5-hour limits appear only when Claude Code runs in Terminal.
- Settings has an About section with the version and links to GitHub, X and LinkedIn.
- Release downloads are now named with their version, for example `Claude-Notch-0.1.2.zip`.

## 0.1.1

**Fixes**
- The notch now connects to Claude Code for downloaded copies of the app. macOS was blocking the helper that Claude Code runs, so no updates reached the notch and macOS could show a "notch-hook Not Opened" warning.
- Connect now checks that the helper actually runs, and shows a clear error if macOS blocks it.
- Opening the new version repairs an existing broken connection automatically.

## 0.1.0

- First release. It shows when Claude Code is working, needs you or is done, lets you answer questions from the notch in Terminal sessions, shows usage and celebrates finished tasks.
