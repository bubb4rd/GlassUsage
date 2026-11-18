# Releasing

Releases are cut from a Mac with the signing credentials. One command builds and ships everything:

```sh
# 1. Bump CFBundleShortVersionString and CFBundleVersion in Support/Info.plist, then commit.
# 2. Release:
Scripts/release.sh
```

`Scripts/release.sh`:

1. Builds a universal `GlassUsage.app` with Sparkle embedded, signed inside-out with the Developer ID certificate and hardened runtime (`Scripts/build-app.sh`).
2. Notarizes the zip with `notarytool`, staples the ticket and checks it with `spctl`.
3. Signs the zip for Sparkle (EdDSA) and writes `appcast.xml`.
4. Publishes `GlassUsage-<version>.zip`, its `.sha256` and `appcast.xml` as the GitHub release `v<version>`, with a *What's changed* list built from the commit subjects since the previous tag (version bumps, `release:` and `README` commits left out). If the release already exists, its assets and notes are replaced.
5. Commits `appcast.xml` to the `appcast` branch, which is where the app looks for updates.
6. Updates `Casks/glassusage.rb` in [bubb4rd/homebrew-tap](https://github.com/bubb4rd/homebrew-tap).

`--no-notarize` skips step 2. Gatekeeper then asks users to approve the first launch.

The README never names a version: its badge and download links point at the latest release, so a release needs no README edit.

## How updates reach users

- **Sparkle:** the app's `SUFeedURL` is `https://raw.githubusercontent.com/bubb4rd/GlassUsage/appcast/appcast.xml`, so publishing a release is all it takes. Sparkle compares `CFBundleVersion`, so that number must go up with every release. The feed lives on a branch rather than as a release asset because GitHub counts every asset fetch as a download, and every daily update check would count. v1.4.1 and earlier still read `releases/latest/download/appcast.xml`, so each release keeps attaching a copy until they've updated.
- **Homebrew:** the cask declares `auto_updates true`, so `brew upgrade` leaves updating to Sparkle. New installs get the version in the tap.

## One-time setup

| Credential | Where it lives | How to create it |
| --- | --- | --- |
| Developer ID Application certificate | login keychain | Xcode → Settings → Accounts → Manage Certificates |
| Notary profile `notary` | login keychain | `xcrun notarytool store-credentials notary --key AuthKey_<id>.p8 --key-id <id> --issuer <issuer>` (App Store Connect API key) |
| Sparkle EdDSA private key | login keychain, account `io.github.bubb4rd.GlassUsage` | `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.github.bubb4rd.GlassUsage` |
| GitHub access | `gh auth login` | needs push to this repo and to `bubb4rd/homebrew-tap` |

**Back up the Sparkle private key.** Without it, existing installs can't verify new updates:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account io.github.bubb4rd.GlassUsage -x sparkle-private-key.txt
```

Keep that file somewhere safe and offline, never in the repo. Restore it on a new Mac with `-f sparkle-private-key.txt`.

## App icon

The app icon and the README's `docs/icon.png` come from the square artwork in `docs/logo/glassusage-icon.png`, clipped to the macOS icon shape. `docs/logo/glassusage-logo.svg` is the white mark alone. To regenerate the icons:

```sh
swift Scripts/make-icon.swift
```
