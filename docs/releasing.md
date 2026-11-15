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
4. Publishes `GlassUsage-<version>.zip`, its `.sha256` and `appcast.xml` as the GitHub release `v<version>`. If the release already exists, its assets are replaced.
5. Updates `Casks/glassusage.rb` in [bubb4rd/homebrew-tap](https://github.com/bubb4rd/homebrew-tap).

`--no-notarize` skips step 2. Gatekeeper then asks users to approve the first launch.

## How updates reach users

- **Sparkle:** the app's `SUFeedURL` is `https://github.com/bubb4rd/GlassUsage/releases/latest/download/appcast.xml`. Because every release carries its own appcast, publishing a release is all it takes. Sparkle compares `CFBundleVersion`, so that number must go up with every release.
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

The icon comes from `docs/logo/glassusage-logo.svg`. To regenerate it:

```sh
swift Scripts/make-icon.swift
```
