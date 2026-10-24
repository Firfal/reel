#!/bin/bash
# Build Reel.app, sign it with a stable identity so macOS keeps the permissions across rebuilds.
# Like ~/insomnia: default to the first *valid* code signing identity, whose key the Keychain already lets
# codesign use. An untrusted or ad-hoc identity makes macOS ask for the password on every build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${REEL_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' 'NR==1 && NF>2 {print $2}')}"
IDENTITY="${IDENTITY:--}"
CONFIG="${1:-release}"
cd "$ROOT/App"
swift build -c "$CONFIG"
APP="$ROOT/dist/Reel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Reel" "$APP/Contents/MacOS/Reel"
cp ".build/$CONFIG/reel-mcp" "$APP/Contents/MacOS/reel-mcp"
codesign --force --options runtime --sign "$IDENTITY" "$APP/Contents/MacOS/reel-mcp"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/Fonts/*.ttf "$APP/Contents/Resources/"
codesign --force --options runtime --entitlements "$ROOT/App/Resources/Reel.entitlements" --sign "$IDENTITY" "$APP"
echo "$APP"
