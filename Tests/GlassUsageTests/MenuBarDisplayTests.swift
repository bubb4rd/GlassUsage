import Foundation
import Testing
@testable import GlassUsage

/// What the menu bar draws and reads for a layout.
@MainActor @Suite struct MenuBarDisplayTests {
    private func window(_ key: String, _ percent: Double, group: String? = nil) -> UsageWindow {
        UsageWindow(key: key, title: key, percent: percent, resetsAt: nil,
                    duration: key == "session" ? 18_000 : 604_800, group: group)
    }

    private func state(_ provider: ProviderID, _ windows: [UsageWindow], fetchedAt: Date = .now,
                       error: ProviderError? = nil) -> ProviderState {
        ProviderState(snapshot: ProviderSnapshot(provider: provider, plan: nil, windows: windows, fetchedAt: fetchedAt),
                      error: error)
    }

    private func resolve(_ layout: MenuBarLayout, _ states: [ProviderID: ProviderState], now: Date = .now) -> [ResolvedIcon] {
        layout.resolve(now: now) { states[$0] }
    }

    private func text(_ state: ProviderState, _ percent: IconPercent, group: String? = nil, now: Date = .now) -> String? {
        var icon = MenuBarIcon.both(state.snapshot!.provider, group: group, percent: percent)
        icon.percent = percent
        return resolve(MenuBarLayout(icons: [icon]), [state.snapshot!.provider: state], now: now)[0].percentText
    }

    @Test func percentagesFollowTheGroupClosestToItsLimit() {
        let antigravity = state(.antigravity, [
            window("session", 10, group: "Gemini"), window("weekly", 95, group: "Gemini"),
            window("session", 60, group: "Claude and GPT"), window("weekly", 20, group: "Claude and GPT"),
        ])

        #expect(text(antigravity, .highest) == "95%")
        #expect(text(antigravity, .inner) == "10%", "session of the group the rings show")
        #expect(text(antigravity, .outer) == "95%")
        #expect(text(antigravity, .both) == "95% · 10%")
        #expect(text(antigravity, .off) == nil)
    }

    @Test func aChosenGroupDrivesTheRingsEvenWhenAnotherIsCloserToItsLimit() {
        let antigravity = state(.antigravity, [
            window("session", 10, group: "Gemini"), window("weekly", 30, group: "Gemini"),
            window("session", 60, group: "Claude and GPT"), window("weekly", 95, group: "Claude and GPT"),
        ])

        #expect(text(antigravity, .highest) == "95%")
        #expect(text(antigravity, .highest, group: "Gemini") == "30%")
        #expect(text(antigravity, .both, group: "Gemini") == "30% · 10%")
        #expect(text(antigravity, .highest, group: "Argon") == "95%",
                "a group the provider no longer reports falls back to the one closest to its limit")
    }

    @Test func aWindowTheProviderDoesNotReportDropsItsRing() {
        let muse = state(.muse, [window("weekly", 12)])
        let icon = resolve(.classic(.muse), [.muse: muse])[0]

        #expect(icon.rings.map(\.source.window) == [.long], "no session ring left empty for good")
        #expect(text(muse, .both) == "12%")
        #expect(text(muse, .inner) == nil)
    }

    @Test func readingFromBeforeAResetShowsTheWindowEmpty() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let claude = ProviderState(snapshot: ProviderSnapshot(provider: .claude, plan: nil, windows: [
            UsageWindow(key: "session", title: "Session", percent: 95, resetsAt: now.addingTimeInterval(-60), duration: 18_000),
            UsageWindow(key: "weekly", title: "Weekly", percent: 40, resetsAt: now.addingTimeInterval(86_400), duration: 604_800),
        ], fetchedAt: now.addingTimeInterval(-60)))

        #expect(text(claude, .highest, now: now) == "40%", "the reset session no longer counts")
        #expect(text(claude, .both, now: now) == "40% · 0%")
        #expect(claude.snapshot!.current(at: now).windows.first?.resetsAt == nil, "the next reset is unknown until a fresh reading")
        #expect(claude.snapshot!.nextReset(after: now) == now.addingTimeInterval(86_400))
    }

    @Test func duoReadsTwoProvidersInOneIcon() {
        let layout = MenuBarLayout.preset(.duo, providers: [.claude, .codex])!
        let icon = resolve(layout, [.claude: state(.claude, [window("session", 34), window("weekly", 62)]),
                                    .codex: state(.codex, [window("session", 12), window("weekly", 88)])])[0]

        #expect(icon.rings.map { $0.window?.percent } == [62, 88])
        #expect(icon.percentText == "62% · 88%")
        #expect(StatusIcon.description([icon]) == ["Claude: weekly 62% · Codex: weekly 88%"])
    }

    @Test func aProviderWithoutAFreshReadingDimsOnlyItsOwnRing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let layout = MenuBarLayout.preset(.duo, providers: [.claude, .codex])!
        let claude = state(.claude, [window("weekly", 62)], fetchedAt: now)

        let missing = resolve(layout, [.claude: claude], now: now)[0]
        #expect(missing.rings.map(\.dimmed) == [false, true])
        #expect(missing.rings[1].window == nil, "an empty track, not another provider's reading")
        #expect(missing.percentText == "62%")

        let stale = resolve(layout, [.claude: claude, .codex: state(.codex, [window("weekly", 88)], fetchedAt: now.addingTimeInterval(-3600))],
                            now: now)[0]
        #expect(stale.rings.map(\.dimmed) == [false, true])
        let failed = resolve(layout, [.claude: claude, .codex: state(.codex, [window("weekly", 88)], fetchedAt: now, error: .http(500))],
                             now: now)[0]
        #expect(failed.rings.map(\.dimmed) == [false, true])
    }

    @Test func sideBySideShowsAtMostThreeProvidersWithoutPercentages() {
        let layout = MenuBarLayout.preset(.sideBySide, providers: ProviderID.allCases)!

        #expect(layout.icons.map(\.outer.provider) == [.claude, .codex, .antigravity])
        #expect(layout.icons.allSatisfy { $0.percent == .off && $0.inner?.window == .session })
        #expect(MenuBarLayout.preset(.sideBySide, providers: [.claude]) == nil)
    }

    @Test func presetsLeadWithTheProvidersTheMenuBarShowsAndKeepTheirGroups() {
        let layout = MenuBarLayout.classic(.antigravity, group: "Gemini")
        let presets = layout.presets(tracked: [.claude, .antigravity])

        #expect(presets[0].layout == layout, "the current layout is still the Classic preset")
        #expect(presets[1].layout.icons[0].outer == RingSource(provider: .antigravity, window: .long, group: "Gemini"))
        #expect(presets[1].layout.icons[0].inner?.provider == .claude)
        #expect(layout.ordered([.claude, .codex, .antigravity]) == [.antigravity, .claude, .codex], "the panel's order")
    }

    @Test func oneFourSettingsCarryOver() {
        #expect(MenuBarLayout.legacy(provider: .codex, group: nil, rings: nil, percent: nil) == .classic(.codex))
        let sessionOnly = MenuBarLayout.legacy(provider: .claude, group: nil, rings: "session", percent: "both")
        #expect(sessionOnly.icons[0].rings.map(\.window) == [.session])
        #expect(sessionOnly.icons[0].percent == .highest, "the one ring drawn")
        let weekPercent = MenuBarLayout.legacy(provider: .antigravity, group: "Gemini", rings: "both", percent: "weekly")
        #expect(weekPercent.icons[0].percent == .outer)
        #expect(weekPercent.icons[0].rings.allSatisfy { $0.group == "Gemini" })
        #expect(MenuBarLayout.legacy(provider: .claude, group: nil, rings: "weekly", percent: "off").icons[0].percent == .off)
    }

    @Test func addingFillsTheIconFirstThenAddsIconsForProvidersNotShownUpToThree() {
        var layout = MenuBarLayout(icons: [MenuBarIcon(outer: RingSource(provider: .claude, window: .long), inner: nil, percent: .highest)])

        #expect(layout.add(tracked: [.claude, .codex, .muse]) == 0)
        #expect(layout.icons[0].inner?.window == .session)
        #expect(layout.add(tracked: [.claude, .codex, .muse]) == 1)
        #expect(layout.icons[1].outer.provider == .codex)
        #expect(layout.add(tracked: [.claude, .codex, .muse]) == 2)
        #expect(!layout.canAdd)
        #expect(layout.add(tracked: [.claude, .codex, .muse]) == nil)
    }

    @Test func removingTheOuterRingMovesTheInnerOneOut() {
        var icon = MenuBarIcon(outer: RingSource(provider: .claude, window: .long),
                               inner: RingSource(provider: .codex, window: .long), percent: .inner)
        icon.removeRing(.outer)

        #expect(icon.outer.provider == .codex && icon.inner == nil)
        #expect(icon.percent == .highest, "a single ring's percentage is on or off")
    }
}
