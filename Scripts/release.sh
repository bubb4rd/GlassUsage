#!/usr/bin/env bash
# Builds, signs, notarizes and publishes a GitHub release.
#
#   Scripts/release.sh            uses the version in Support/Info.plist (tag v<version>)
#
# Needs: a "Developer ID Application" certificate in the keychain, a notarytool keychain
# profile (default name "notary", override with NOTARY_PROFILE), and an authenticated `gh`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
TAG="v$VERSION"
PROFILE="${NOTARY_PROFILE:-notary}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate found" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is dirty; commit first" >&2; exit 1; }

SIGN_IDENTITY="$IDENTITY" Scripts/build-app.sh

ZIP="build/GlassUsage-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --keepParent build/GlassUsage.app "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
xcrun stapler staple build/GlassUsage.app
spctl --assess --type execute --verbose build/GlassUsage.app

# Re-zip so the download carries the stapled ticket (works offline on first launch).
rm -f "$ZIP"
ditto -c -k --keepParent build/GlassUsage.app "$ZIP"
shasum -a 256 "$ZIP" | tee "$ZIP.sha256"

gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "GlassUsage $VERSION" --generate-notes --verify-tag 2>/dev/null \
  || { git tag -a "$TAG" -m "GlassUsage $VERSION" && git push origin "$TAG" \
       && gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "GlassUsage $VERSION" --generate-notes; }
