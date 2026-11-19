# Releasing

Releases are cut from `main` on a Mac with the signing credentials. Work collects on `dev`, and `main` only moves on release day (see [Cadence](#cadence)). One command builds and ships everything:

```sh
# 1. On dev: bump CFBundleShortVersionString and CFBundleVersion in Support/Info.plist, then commit.
# 2. Move main up to dev and push both:
git checkout main && git merge --ff-only dev && git push origin main dev
# 3. Release:
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

`--hotfix` allows a release within 24 hours of the previous one. Without it the script refuses, and it always refuses to run off `main` or when `main` differs from `origin/main`.

The README never names a version: its badge and download links point at the latest release, so a release needs no README edit.

## Versioning

From 1.6.0 on, the middle number moves only for headline releases: a new area of the app or a change existing users have to relearn. Everything else, features included, bumps the last number: 1.6.0, 1.6.1, 1.6.2… It can climb as high as it needs to, and after 1.9 comes 1.10, so no number needs padding. 2.0 is for a break, such as dropping a macOS version.

`CFBundleVersion` is a separate build number that goes up by one with every release whatever the version, since it's what Sparkle compares.

## Cadence

Every release puts an update prompt in front of every user, so changes ship in batches, not one release per change.

- **Weekly train:** feature branches merge into `dev` when they're done. On Tuesday, if `dev` has something a user would notice, fast-forward `main` to it and release one patch. If nothing is user-facing, there's no release that week.
- **Hotfix:** crashes, wrong numbers and broken updates ship the same day. Branch from `main`, fix, fast-forward `main` to the fix, run `Scripts/release.sh --hotfix`, then merge `main` back into `dev`.
- **Headline (1.x.0):** planned ahead. Its feature branch merges into `dev` only once it's finished, then rides the next train.
- **Freeze:** no trains over holidays or while away. Hotfixes still ship.

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

The app icon and the README's `docs/app-icon.png` come from the square artwork in `docs/logo/glassusage-icon.png`, clipped to the macOS icon shape. `docs/logo/glassusage-logo.svg` is the white mark alone. To regenerate the icons:

```sh
swift Scripts/make-icon.swift
```
