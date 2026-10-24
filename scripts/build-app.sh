#!/bin/bash
# Build Reel.app, sign it with a stable identity so macOS keeps the permissions across rebuilds.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${REEL_SIGN_IDENTITY:-Reel Local Signing}"
CONFIG="${1:-release}"
cd "$ROOT/App"
swift build -c "$CONFIG"
APP="$ROOT/dist/Reel.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/$CONFIG/Reel" "$APP/Contents/MacOS/Reel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --options runtime --entitlements "$ROOT/App/Resources/Reel.entitlements" --sign "$IDENTITY" "$APP"
echo "$APP"
