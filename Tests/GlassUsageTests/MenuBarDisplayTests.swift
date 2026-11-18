import Foundation
import Testing
@testable import GlassUsage

/// What the menu bar percentage reads for each setting.
@MainActor @Suite struct MenuBarDisplayTests {
    private func window(_ key: String, _ percent: Double, group: String? = nil) -> UsageWindow {
        UsageWindow(key: key, title: key, percent: percent, resetsAt: nil,
                    duration: key == "session" ? 18_000 : 604_800, group: group)
    }

    @Test func windowPercentsFollowTheMostConstrainedGroup() {
        let snapshot = ProviderSnapshot(provider: .antigravity, plan: nil, windows: [
            window("session", 10, group: "Gemini"), window("weekly", 95, group: "Gemini"),
            window("session", 60, group: "Claude and GPT"), window("weekly", 20, group: "Claude and GPT"),
        ], fetchedAt: .now)

        #expect(StatusIcon.percentText(for: snapshot, mode: .highest) == "95%")
        #expect(StatusIcon.percentText(for: snapshot, mode: .session) == "10%", "session of the group the rings show")
        #expect(StatusIcon.percentText(for: snapshot, mode: .weekly) == "95%")
        #expect(StatusIcon.percentText(for: snapshot, mode: .both) == "10% · 95%")
        #expect(StatusIcon.percentText(for: snapshot, mode: .off) == nil)
    }

    @Test func aChosenGroupDrivesRingsAndPercentEvenWhenAnotherIsCloserToItsLimit() {
        let snapshot = ProviderSnapshot(provider: .antigravity, plan: nil, windows: [
            window("session", 10, group: "Gemini"), window("weekly", 30, group: "Gemini"),
            window("session", 60, group: "Claude and GPT"), window("weekly", 95, group: "Claude and GPT"),
        ], fetchedAt: .now)

        #expect(StatusIcon.percentText(for: snapshot, mode: .highest) == "95%")
        #expect(StatusIcon.percentText(for: snapshot, mode: .highest, group: "Gemini") == "30%")
        #expect(StatusIcon.percentText(for: snapshot, mode: .both, group: "Gemini") == "10% · 30%")
        #expect(StatusIcon.percentText(for: snapshot, mode: .highest, group: "Argon") == "95%",
                "a group the provider no longer reports falls back to the one closest to its limit")
    }

    @Test func missingSessionWindowShowsOnlyTheWeek() {
        let snapshot = ProviderSnapshot(provider: .muse, plan: nil, windows: [window("weekly", 12)], fetchedAt: .now)

        #expect(StatusIcon.percentText(for: snapshot, mode: .session) == nil)
        #expect(StatusIcon.percentText(for: snapshot, mode: .both) == "12%")
    }

    @Test func readingFromBeforeAResetShowsTheWindowEmpty() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = ProviderSnapshot(provider: .claude, plan: nil, windows: [
            UsageWindow(key: "session", title: "Session", percent: 95, resetsAt: now.addingTimeInterval(-60), duration: 18_000),
            UsageWindow(key: "weekly", title: "Weekly", percent: 40, resetsAt: now.addingTimeInterval(86_400), duration: 604_800),
        ], fetchedAt: now.addingTimeInterval(-3600))

        #expect(StatusIcon.percentText(for: snapshot, mode: .highest, now: now) == "40%", "the reset session no longer counts")
        #expect(StatusIcon.percentText(for: snapshot, mode: .both, now: now) == "0% · 40%")
        #expect(snapshot.current(at: now).windows.first?.resetsAt == nil, "the next reset is unknown until a fresh reading")
        #expect(snapshot.nextReset(after: now) == now.addingTimeInterval(86_400))
    }
}
