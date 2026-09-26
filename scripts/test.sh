#!/bin/sh
# Runs the test suite. With only the Command Line Tools installed (no Xcode), SwiftPM
# can't find the Testing framework on its own, so point it there explicitly.
set -e
cd "$(dirname "$0")/.."
DEV="$(xcode-select -p)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"
if [ -d "$FW/Testing.framework" ] && [ ! -d "$DEV/Platforms" ]; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$FW" \
    -Xlinker -F -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$FW" \
    -Xlinker -rpath -Xlinker "$LIB" "$@"
fi
exec swift test "$@"
