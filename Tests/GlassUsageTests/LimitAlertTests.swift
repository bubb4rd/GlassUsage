import Foundation
import Testing
@testable import GlassUsage

/// When a reading earns a near-limit or reset notification.
@MainActor @Suite struct LimitAlertTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func claude(session: Double?, week: Double, sessionReset: TimeInterval = 3600) -> ProviderSnapshot {
        var windows: [UsageWindow] = []
        if let session {
            windows.append(UsageWindow(key: "session", title: "Session", percent: session,
                                       resetsAt: now.addingTimeInterval(sessionReset), duration: 18_000))
        }
        windows.append(UsageWindow(key: "weekly", title: "Weekly", percent: week,
                                   resetsAt: now.addingTimeInterval(4 * 86_400), duration: 604_800))
        return ProviderSnapshot(provider: .claude, plan: nil, windows: windows, fetchedAt: now)
    }

    @Test func crossingTheLevelAlertsOncePerWindow() {
        var pending: [String: LimitAlertRules.Pending] = [:]

        let first = LimitAlertRules.evaluate(claude(session: 92, week: 40), threshold: 90, now: now, pending: &pending)
        #expect(first.map(\.title) == ["Claude session at 92%"])

        let again = LimitAlertRules.evaluate(claude(session: 97, week: 40), threshold: 90, now: now.addingTimeInterval(300),
                                             pending: &pending)
        #expect(again.isEmpty, "climbing further in the same window doesn't alert again")
    }

    @Test func resetAlertsOnceTheAlertedWindowsResetPasses() {
        var pending: [String: LimitAlertRules.Pending] = [:]
        _ = LimitAlertRules.evaluate(claude(session: 92, week: 40), threshold: 90, now: now, pending: &pending)

        let before = LimitAlertRules.evaluate(claude(session: 95, week: 40), threshold: 90, now: now.addingTimeInterval(3000),
                                              pending: &pending)
        #expect(before.isEmpty)

        // Claude drops an idle session window entirely after it resets.
        let after = LimitAlertRules.evaluate(claude(session: nil, week: 40), threshold: 90, now: now.addingTimeInterval(3605),
                                             pending: &pending)
        #expect(after == [LimitAlertRules.Alert(id: "claude/session", title: "Claude session limit reset", body: "Back to 0% used.")])
        #expect(pending.isEmpty)

        let next = LimitAlertRules.evaluate(claude(session: 91, week: 40, sessionReset: 5 * 3600), threshold: 90,
                                            now: now.addingTimeInterval(4000), pending: &pending)
        #expect(next.map(\.title) == ["Claude session at 91%"], "the new window alerts on its own")
    }

    @Test func windowWithoutResetTimeResetsWhenBackUnderTheLevel() {
        var pending: [String: LimitAlertRules.Pending] = [:]
        func muse(_ percent: Double) -> ProviderSnapshot {
            ProviderSnapshot(provider: .muse, plan: nil, windows: [
                UsageWindow(key: "weekly", title: "Weekly", percent: percent, resetsAt: nil, duration: 604_800),
            ], fetchedAt: now)
        }
        #expect(LimitAlertRules.evaluate(muse(80), threshold: 75, now: now, pending: &pending).count == 1)
        #expect(LimitAlertRules.evaluate(muse(78), threshold: 75, now: now, pending: &pending).isEmpty)
        #expect(LimitAlertRules.evaluate(muse(5), threshold: 75, now: now, pending: &pending).map(\.title)
                == ["Muse Code weekly limit reset"])
    }

    @Test func providersKeepTheirOwnPendingWindows() {
        var pending: [String: LimitAlertRules.Pending] = [:]
        _ = LimitAlertRules.evaluate(claude(session: 92, week: 40), threshold: 90, now: now, pending: &pending)
        let codex = ProviderSnapshot(provider: .codex, plan: nil, windows: [], fetchedAt: now)

        #expect(LimitAlertRules.evaluate(codex, threshold: 90, now: now.addingTimeInterval(7200), pending: &pending).isEmpty,
                "another provider's reading never resolves Claude's pending reset")
        #expect(pending.keys.sorted() == ["claude/session"])
    }

    @Test func groupedWindowsNameTheirGroup() {
        var pending: [String: LimitAlertRules.Pending] = [:]
        let snapshot = ProviderSnapshot(provider: .antigravity, plan: nil, windows: [
            UsageWindow(key: "weekly", title: "Weekly", percent: 60, resetsAt: nil, duration: 604_800, group: "Gemini"),
            UsageWindow(key: "weekly", title: "Weekly", percent: 10, resetsAt: nil, duration: 604_800, group: "Claude and GPT"),
        ], fetchedAt: now)
        let alerts = LimitAlertRules.evaluate(snapshot, threshold: 50, now: now, pending: &pending)
        #expect(alerts.map(\.title) == ["Antigravity Gemini weekly at 60%"])
        #expect(alerts.first?.id == "antigravity/Gemini/weekly")
    }
}
