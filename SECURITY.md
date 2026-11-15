# Security

GlassUsage reads Claude Code and Codex credentials and local session logs to show your plan limits and token spend. Please report anything that could expose those credentials or log contents, or that lets a third party tamper with an update.

## Reporting a vulnerability

Report privately through [GitHub's private vulnerability reporting](https://github.com/bubb4rd/GlassUsage/security/advisories/new). Don't open a public issue.

Include the GlassUsage version (Settings → footer), your macOS version, and steps to reproduce. You'll get a reply within a week.

## Scope

In scope:

- Credential handling (Keychain and `auth.json` reads, the `claude` token renewal)
- Local log parsing and the on-disk cache
- The update path: Sparkle appcast, EdDSA signatures, Developer ID signing and notarization

Out of scope: the Anthropic and OpenAI usage endpoints themselves. Report those to the provider.

## Release integrity

Every release is:

- signed with a Developer ID certificate (team `87BJQUWN86`) and notarized by Apple
- published with its SHA-256 next to the zip
- signed with an EdDSA key for Sparkle updates (the public key is `SUPublicEDKey` in `Support/Info.plist`)

Builds are published on [GitHub Releases](https://github.com/bubb4rd/GlassUsage/releases) and through the [Homebrew tap](https://github.com/bubb4rd/homebrew-tap), and nowhere else.
