#!/usr/bin/env bash
# Builds a universal GlassUsage.app into ./build.
#
#   Scripts/build-app.sh            ad-hoc signed, for running locally
#   Scripts/build-app.sh --open     same, then (re)launch it
#   SIGN_IDENTITY="Developer ID Application: …" Scripts/build-app.sh
#                                   Developer ID + hardened runtime, ready to notarize
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/GlassUsage.app"
IDENTITY="${SIGN_IDENTITY:--}"
ARCHS=(--arch arm64 --arch x86_64)

cd "$ROOT"
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/GlassUsage"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GlassUsage"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

if [[ "$IDENTITY" == "-" ]]; then
  codesign --force --sign - --timestamp=none "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/GlassUsage"))"
if [[ "${1:-}" == "--open" ]]; then
  pkill -x GlassUsage 2>/dev/null || true
  open "$APP"
fi
