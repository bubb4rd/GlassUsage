#!/usr/bin/env bash
# Builds, signs, notarizes and publishes a release, then updates the Sparkle feed (appcast branch) and Homebrew cask.
#
#   Scripts/release.sh                 notarized release for the version in Support/Info.plist (tag v<version>)
#   Scripts/release.sh --no-notarize   Developer ID-signed only; Gatekeeper asks users to approve the first launch
#   Scripts/release.sh --hotfix        allow a release within 24 hours of the previous one (docs/releasing.md, Cadence)
#
# Runs only on main, in sync with origin/main.
# Re-running for a version that's already released replaces its assets (e.g. to swap in a notarized build).
# Needs: a "Developer ID Application" certificate, the Sparkle EdDSA key in the login keychain
# (account io.github.bubb4rd.GlassUsage), an authenticated `gh` with push access to bubb4rd/homebrew-tap,
# and for notarization a notarytool keychain profile (default "notary", override with NOTARY_PROFILE).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REPO="bubb4rd/GlassUsage"
TAP="bubb4rd/homebrew-tap"
BUNDLE_ID="io.github.bubb4rd.GlassUsage"
NOTARIZE=1
HOTFIX=0
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=0 ;;
    --hotfix) HOTFIX=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/Info.plist)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' Support/Info.plist)"
TAG="v$VERSION"
PROFILE="${NOTARY_PROFILE:-notary}"
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)}"
[[ -n "$IDENTITY" ]] || { echo "No Developer ID Application certificate found" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "Working tree is dirty; commit first" >&2; exit 1; }

# Releases ship from main only, matching origin/main, so what users get is what's pushed.
[[ "$(git symbolic-ref --short -q HEAD)" == main ]] || { echo "Release from main (fast-forward it to dev first)" >&2; exit 1; }
git fetch -q origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || { echo "main and origin/main differ; push or pull first" >&2; exit 1; }

# At most one release a day; urgent fixes pass --hotfix. Re-running an existing release is always allowed.
if ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && (( ! HOTFIX )); then
  LAST="$(git for-each-ref --sort=-creatordate --count=1 --format='%(refname:short) %(creatordate:unix)' 'refs/tags/v*')"
  if [[ -n "$LAST" ]] && (( $(date +%s) - ${LAST#* } < 86400 )); then
    echo "${LAST% *} shipped under 24 hours ago. Let changes collect on dev, or pass --hotfix for an urgent fix." >&2
    exit 1
  fi
fi

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
  NOTES="Signed with Developer ID and notarized by Apple. Install with \`brew install --cask bubb4rd/tap/glassusage\`, or unzip and move GlassUsage.app to Applications. Existing installs update themselves."
else
  NOTES="Signed with Developer ID, not yet notarized. On first launch macOS blocks it: open System Settings → Privacy & Security and click **Open Anyway** (or run \`xattr -dr com.apple.quarantine /Applications/GlassUsage.app\`)."
fi
# What changed: commit subjects since the previous release tag, minus version bumps and repo housekeeping.
PREV="$(git describe --tags --abbrev=0 --match 'v*' --exclude "$TAG" HEAD 2>/dev/null || true)"
CHANGES="$(git log --no-merges --format='- %s' "${PREV:+$PREV..}HEAD" | grep -vE '^- (Bump version|release:|README)' || true)"
[[ -n "$CHANGES" ]] && NOTES="## What's changed"$'\n\n'"$CHANGES"$'\n\n'"$NOTES"
SHA256="$(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo "$SHA256  $(basename "$ZIP")" > "$ZIP.sha256"
cat "$ZIP.sha256"

# Sparkle feed. The app reads appcast.xml from the appcast branch (raw.githubusercontent.com), which isn't a
# release asset, so update checks don't count as downloads. Releases still carry a copy for v1.4.1 and earlier,
# which read releases/latest/download/appcast.xml.
SPARKLE_SIG="$(.build/artifacts/sparkle/Sparkle/bin/sign_update --account "$BUNDLE_ID" "$ZIP")"
cat > build/appcast.xml <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>GlassUsage</title>
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -R)</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <enclosure url="https://github.com/$REPO/releases/download/$TAG/$(basename "$ZIP")" $SPARKLE_SIG type="application/octet-stream"/>
    </item>
  </channel>
</rss>
EOF

ASSETS=("$ZIP" "$ZIP.sha256" build/appcast.xml)
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "${ASSETS[@]}" -R "$REPO" --clobber
  gh release edit "$TAG" -R "$REPO" --notes "$NOTES"
else
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || git tag -a "$TAG" -m "GlassUsage $VERSION"
  git push origin "$TAG"
  gh release create "$TAG" "${ASSETS[@]}" -R "$REPO" --title "GlassUsage $VERSION" --notes "$NOTES"
fi

# Point the feed at the new release only once its zip is published.
git fetch -q origin appcast
FEED_TREE="$(printf '100644 blob %s\tappcast.xml\n' "$(git hash-object -w build/appcast.xml)" | git mktree)"
git push -q origin "$(git commit-tree "$FEED_TREE" -p FETCH_HEAD -m "appcast: $VERSION")":refs/heads/appcast

# Homebrew cask in the tap.
TAPDIR="$(mktemp -d)"
gh repo clone "$TAP" "$TAPDIR" -- --quiet
mkdir -p "$TAPDIR/Casks"
cat > "$TAPDIR/Casks/glassusage.rb" <<EOF
cask "glassusage" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$REPO/releases/download/v#{version}/GlassUsage-#{version}.zip"
  name "GlassUsage"
  desc "Coding agent plan limits and token spend in the menu bar"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :tahoe

  app "GlassUsage.app"

  uninstall quit: "$BUNDLE_ID"

  zap trash: [
    "~/Library/Application Support/GlassUsage",
    "~/Library/Caches/$BUNDLE_ID",
    "~/Library/HTTPStorages/$BUNDLE_ID",
    "~/Library/Preferences/$BUNDLE_ID.plist",
  ]
end
EOF
git -C "$TAPDIR" add Casks/glassusage.rb
if ! git -C "$TAPDIR" diff --cached --quiet; then
  git -C "$TAPDIR" commit -q -m "glassusage $VERSION"
  git -C "$TAPDIR" push -q
fi
rm -rf "$TAPDIR"
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
