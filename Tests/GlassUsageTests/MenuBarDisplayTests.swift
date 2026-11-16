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

    @Test func missingSessionWindowShowsOnlyTheWeek() {
        let snapshot = ProviderSnapshot(provider: .muse, plan: nil, windows: [window("weekly", 12)], fetchedAt: .now)

        #expect(StatusIcon.percentText(for: snapshot, mode: .session) == nil)
        #expect(StatusIcon.percentText(for: snapshot, mode: .both) == "12%")
    }
}
