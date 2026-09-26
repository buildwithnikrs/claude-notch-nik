#!/bin/sh
# Builds "Claude Notch.app" (Apple Silicon) into ./build. Works with just the Command Line Tools.
#   ./scripts/build-app.sh            release build
#   ./scripts/build-app.sh --install  also copy to /Applications
set -e
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
APP="build/Claude Notch.app"

swift build -c release --arch arm64 --product ClaudeNotch
swift build -c release --arch arm64 --product notch-hook
BIN="$(swift build -c release --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources"
cp "$BIN/ClaudeNotch" "$APP/Contents/MacOS/ClaudeNotch"
cp "$BIN/notch-hook" "$APP/Contents/Helpers/notch-hook"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Notch</string>
  <key>CFBundleDisplayName</key><string>Claude Notch</string>
  <key>CFBundleIdentifier</key><string>dev.claude-notch.app</string>
  <key>CFBundleExecutable</key><string>ClaudeNotch</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
EOF

# Ad-hoc signature (sign the helper first, then the bundle).
codesign --force --options runtime -s - "$APP/Contents/Helpers/notch-hook"
codesign --force --options runtime -s - "$APP"

echo "Built $APP"

if [ "$1" = "--install" ]; then
  # Without admin rights /Applications isn't writable; ~/Applications works for everyone.
  DEST="/Applications"
  [ -w "$DEST" ] || DEST="$HOME/Applications"
  mkdir -p "$DEST"
  pkill -x ClaudeNotch 2>/dev/null || true
  rm -rf "$DEST/Claude Notch.app"
  cp -R "$APP" "$DEST/"
  echo "Installed to $DEST/Claude Notch.app"
  open "$DEST/Claude Notch.app"
fi
