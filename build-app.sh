#!/bin/bash
# Builds LevoitBar.app (and LevoitBar.zip for releases) into ./build.
# Requires Xcode or the Command Line Tools (Swift 5.9+).
#   VERSION=1.2.0 ./build-app.sh   stamps that version into the app.
set -euo pipefail
cd "$(dirname "$0")"

# The "native" build system works with Command Line Tools-only setups, where
# the default one fails to start.
swift build -c release --build-system native
BIN="$(swift build -c release --build-system native --show-bin-path)/LevoitBar"

APP="build/LevoitBar.app"
rm -rf "$APP" build/LevoitBar.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LevoitBar"
cp Support/Info.plist "$APP/Contents/Info.plist"

if [ -n "${VERSION:-}" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

# Ad-hoc sign so macOS will run it and the Keychain can identify it.
codesign --force --sign - "$APP"

ditto -c -k --keepParent "$APP" build/LevoitBar.zip

echo "Built $(pwd)/$APP"
echo "Install with:  cp -R \"$APP\" /Applications/ && open /Applications/LevoitBar.app"
