#!/usr/bin/env bash
# Builds a universal GlassUsage.app (with Sparkle.framework embedded) into ./build.
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
PRODUCTS="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$PRODUCTS/GlassUsage" "$APP/Contents/MacOS/GlassUsage"
cp "$ROOT/Support/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Support/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
ditto "$PRODUCTS/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"

# Sign inside-out: Sparkle's helpers, the framework, then the app (codesign --deep is unreliable).
sign() {
  if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - --timestamp=none "$@"
  else
    codesign --force --sign "$IDENTITY" --options runtime --timestamp "$@"
  fi
}
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
sign "$SPARKLE/XPCServices/Installer.xpc"
sign --preserve-metadata=entitlements "$SPARKLE/XPCServices/Downloader.xpc"
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/GlassUsage"))"
if [[ "${1:-}" == "--open" ]]; then
  pkill -x GlassUsage 2>/dev/null || true
  open "$APP"
fi
