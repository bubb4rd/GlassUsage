#!/usr/bin/env bash
# Builds, signs, notarizes and publishes a GitHub release.
#
#   Scripts/release.sh                 notarized release for the version in Support/Info.plist (tag v<version>)
#   Scripts/release.sh --no-notarize   Developer ID-signed only; Gatekeeper asks users to approve the first launch
#
# Re-running for a version that's already released replaces its assets (e.g. to swap in a notarized build).
# Needs: a "Developer ID Application" certificate in the keychain, an authenticated `gh`, and for
# notarization a notarytool keychain profile (default "notary", override with NOTARY_PROFILE).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARIZE=1
[[ "${1:-}" == "--no-notarize" ]] && NOTARIZE=0
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
if (( NOTARIZE )); then
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple build/GlassUsage.app
  spctl --assess --type execute --verbose build/GlassUsage.app
  # Re-zip so the download carries the stapled ticket (works offline on first launch).
  rm -f "$ZIP"
  ditto -c -k --keepParent build/GlassUsage.app "$ZIP"
  NOTES="Signed with Developer ID and notarized by Apple. Unzip, move GlassUsage.app to Applications, open it."
else
  NOTES="Signed with Developer ID, not yet notarized. On first launch macOS blocks it: open System Settings → Privacy & Security and click **Open Anyway** (or run \`xattr -dr com.apple.quarantine /Applications/GlassUsage.app\`)."
fi
shasum -a 256 "$ZIP" | sed 's|build/||' > "$ZIP.sha256"
cat "$ZIP.sha256"

if gh release view "$TAG" >/dev/null 2>&1; then
  gh release upload "$TAG" "$ZIP" "$ZIP.sha256" --clobber
  gh release edit "$TAG" --notes "$NOTES"
else
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "GlassUsage $VERSION"
  git push origin "$TAG"
  gh release create "$TAG" "$ZIP" "$ZIP.sha256" --title "GlassUsage $VERSION" --notes "$NOTES"
fi
