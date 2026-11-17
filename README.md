<p align="center">
  <a href="https://github.com/bubb4rd/GlassUsage"><img src="docs/icon.png" alt="GlassUsage" width="128" height="128"></a>
</p>

<h1 align="center">GlassUsage</h1>

<p align="center">
  <a href="https://github.com/bubb4rd/GlassUsage/releases/latest"><img alt="Latest release" src="https://img.shields.io/github/v/release/bubb4rd/GlassUsage?label=Version&color=4a7fd4"></a>
  <a href="https://github.com/bubb4rd/GlassUsage/releases"><img alt="Downloads" src="https://img.shields.io/github/downloads/bubb4rd/GlassUsage/total?label=Downloads&color=2193d9"></a>
  <img alt="macOS 26+" src="https://img.shields.io/badge/macOS-26%2B-000?logo=apple">
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-fad318"></a>
</p>

<p align="center">Your Claude, Codex, Antigravity and Muse Code plan limits, plus the tokens you burn, one click away in the menu bar.</p>

<p align="center"><img src="docs/hero.jpg" alt="GlassUsage open from the macOS menu bar: Claude and Codex session and weekly limit rings, then 30 days of token spend by day and by model"></p>

GlassUsage is a native Liquid Glass menu bar app for macOS. It shows how much of your session and weekly limits you've used and when each one resets, so you're never surprised mid-task. Optionally, it also shows how many tokens you've burned and what they would cost at API prices.

It has no account or server of its own: it reuses the sign-ins your coding CLIs already keep on your Mac, and it never stores your credentials.

## Install

GlassUsage runs on macOS 26 (Tahoe) or later, on Apple silicon and Intel.

**Homebrew**

```sh
brew install --cask bubb4rd/tap/glassusage
```

**Manual download**

1. Download `GlassUsage-<version>.zip` from the [latest release](https://github.com/bubb4rd/GlassUsage/releases/latest) and unzip it.
2. Move **GlassUsage.app** to Applications and open it. It's signed and notarized by Apple, so it opens without a warning.
3. Look for a small double ring and a percentage in the menu bar. There's no Dock icon.

To check a download, keep the zip and the `.sha256` file published next to it in the same folder, then run:

```sh
shasum -a 256 -c GlassUsage-*.zip.sha256    # prints "GlassUsage-<version>.zip: OK"
```

### Before you start

GlassUsage reads limits from the tools you already use. Sign in to at least one:

- **Claude Code:** run `claude` and sign in with a Pro, Max, Team or Enterprise plan.
- **Codex CLI:** run `codex` and sign in with ChatGPT.
- **Antigravity CLI:** run `agy` and sign in with your Google account.
- **Muse Code:** run `muse login` with a Muse Code subscription.

### Updating

GlassUsage updates itself, Homebrew installs included. It checks GitHub for new releases and asks before installing. When a new version is out, a dot appears on the gear and Settings shows a green **Update** button with the new version number. To check by hand, click the download arrow in Settings or right-click the menu bar icon → **Check for Updates…**.

What changed in each version is on the [Releases](https://github.com/bubb4rd/GlassUsage/releases) page.

### Uninstalling

Quit GlassUsage (right-click the icon → Quit) and delete it from Applications, or run `brew uninstall --cask glassusage`. To also remove its settings and cache, run `brew uninstall --zap --cask glassusage`, or delete the files listed under [Files on disk](docs/how-it-works.md#files-on-disk).

## Features

- **Session and weekly limits:** a ring per window, with the time until it resets and the exact reset time. Codex plans with a monthly window show that instead. Antigravity meters each model group (Gemini, Claude and GPT, Argon) separately: arrows above its rings step between groups, starting on the one closest to its limit. Rings turn yellow at 50%, orange at 75% and red at 90%.
- **Menu bar at a glance:** two rings, the session inside and the week outside, with the percentage of whichever limit is closest to running out. It dims when the reading is stale. In Settings, pick which provider it shows, whether it draws both rings or only the session or week, and which percentage follows it: the highest, the session, the week, both side by side, or none.
- **Token spend** (toggle with **$**): tokens burned today, over 7 days and over 30 days, with what they would cost at API prices, output and cache share, and your top models or, with the arrows, projects (the folder each session ran in, shown with the project's own app icon, logo or favicon when its folder has one). Logos for projects in Documents, Desktop, Downloads, cloud storage or external drives need *Logos from Documents & Desktop* in Settings, since macOS asks before an app reads those folders. Pick how days are drawn in Settings: *Ledger* (a bar per day) or *Calendar* (weeks by weekday, with weekly totals).
- **Limit alerts:** pick 50%, 75% or 90% in Settings and get a notification when any tracked limit reaches it, and another when that window resets. Off by default.
- **Reads local logs:** spend comes from Claude Code, Codex CLI, Antigravity (its CLI or T3 Code), Muse Code and omp session logs, parsed incrementally like [ccusage](https://github.com/ryoppippi/ccusage).
- **Out of your way:** click to open, or turn on *Open on hover* to peek. ⌘R refreshes, ⌘, opens Settings, Esc closes.
- **Launch at login**, a selectable refresh interval, and automatic updates.

## Privacy

- **Credentials:** read from Claude Code's Keychain item and Codex's `auth.json`. Antigravity and Muse Code limits come from their own CLIs (`agy -p /usage`, `muse usage`), so GlassUsage never sees those logins. It never stores, refreshes or rewrites credentials.
- **Logs:** your session logs are read on your Mac and never uploaded.
- **Network:** only Anthropic and OpenAI (for your limits) and GitHub (for prices and updates); the Antigravity and Muse Code CLIs make their own requests. No analytics or telemetry.

See [How it works](docs/how-it-works.md) for the exact endpoints, files and formulas.

## FAQ

**Why are the costs so high on a subscription?**
Spend shows what the same tokens would cost on the pay-per-token API. Your plan doesn't bill per token. Treat it as a way to compare days and models, not as a bill.

**A provider shows "Sign in with…" instead of rings.**
Sign in with `claude`, `codex`, `agy` or `muse login` in Terminal, then click refresh (⌘R).

**Is this official?**
No. GlassUsage is an independent project and is not affiliated with Anthropic, OpenAI, Google or Meta. It uses the same undocumented usage endpoints and commands as the official CLIs, and those can change. Updates will follow when they do.

## Build from source

Requires macOS 26 and Xcode 26 (Swift 6.2).

```sh
git clone https://github.com/bubb4rd/GlassUsage.git
cd GlassUsage
Scripts/build-app.sh --open    # universal build/GlassUsage.app, ad-hoc signed, then launches it
```

`swift run` also works while developing, but *Launch at login* and updates only work from the `.app` bundle. `swift test` runs the provider parsing tests.

Maintainers: see [Releasing](docs/releasing.md).

## Contributing

Bug reports and pull requests are welcome. Please include your macOS version and which provider (Claude, Codex, Antigravity or Muse Code) is involved. To report a security issue, see [SECURITY.md](SECURITY.md).

## Credits

- Visual language: [TokenHell](https://github.com/ghostpengu/tokenhell) by ghostpengu
- Log parsing approach: [ccusage](https://github.com/ryoppippi/ccusage); prices: [LiteLLM](https://github.com/BerriAI/litellm)
- Updates: [Sparkle](https://sparkle-project.org)
- Provider marks: [Simple Icons](https://simpleicons.org) (CC0). Claude is a trademark of Anthropic; Codex and the OpenAI logo are trademarks of OpenAI; Google and Antigravity are trademarks of Google; Meta and Muse are trademarks of Meta.

## License

[MIT](LICENSE)
