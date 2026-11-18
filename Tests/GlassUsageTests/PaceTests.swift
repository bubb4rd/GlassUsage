import Foundation
import Testing
@testable import GlassUsage

/// Where a limit is heading at the rate it has been used so far. Now is Tue Nov 17 2026, 9:41.
@Suite struct PaceTests {
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private let now = date(17, 9, 41)
    private static let week: TimeInterval = 7 * 86_400
    private static let session: TimeInterval = 5 * 3600

    private static func date(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func window(_ percent: Double, resets: Date?, duration: TimeInterval) -> UsageWindow {
        UsageWindow(key: duration == Self.session ? "session" : "weekly", title: "", percent: percent,
                    resetsAt: resets, duration: duration)
    }

    private func expectRunsOut(_ pace: Pace?, emptyAt: Date, lockout: TimeInterval) {
        guard case .runsOut(let actualEmpty, let actualLockout) = pace else {
            Issue.record("expected runsOut, got \(String(describing: pace))")
            return
        }
        #expect(abs(actualEmpty.timeIntervalSince(emptyAt)) <= 60)
        #expect(abs(actualLockout - lockout) <= 60)
    }

    @Test func weekUsedFasterThanItLastsRunsOutBeforeTheReset() {
        let codex = window(47, resets: Self.date(23, 6, 30), duration: Self.week)
        expectRunsOut(codex.pace(at: now), emptyAt: Self.date(18, 16, 20), lockout: 4 * 86_400 + 14 * 3600 + 10 * 60)

        let claude = window(61, resets: Self.date(20, 14, 0), duration: Self.week)
        expectRunsOut(claude.pace(at: now), emptyAt: Self.date(19, 20, 18), lockout: 17 * 3600 + 42 * 60)
    }

    @Test func slowerUseEndsTheWindowUnderTheLimit() {
        guard case .onPace(let projected) = window(38, resets: Self.date(17, 11, 55), duration: Self.session).pace(at: now) else {
            Issue.record("expected onPace")
            return
        }
        #expect(abs(projected - 0.687) < 0.001)
    }

    @Test func tooEarlyOrUnusedHasNoProjection() {
        #expect(window(12, resets: Self.date(17, 14, 12), duration: Self.session).pace(at: now) == .early,
                "under 15% of the window has passed")
        #expect(window(0, resets: Self.date(20, 14, 0), duration: Self.week).pace(at: now) == .early)
        #expect(window(61, resets: nil, duration: Self.week).pace(at: now) == nil, "no reset time, nothing to project")
    }

    @MainActor @Test func paceWarmsTheRingAtMostOneStepPastItsUsage() {
        #expect(Theme.Band(window: window(47, resets: Self.date(23, 6, 30), duration: Self.week), now: now) == .warning,
                "out for over a quarter of the week, but 47% used reads yellow, not red")
        #expect(Theme.Band(window: window(80, resets: Self.date(23, 6, 30), duration: Self.week), now: now) == .critical,
                "80% used and out for days goes red")
        #expect(Theme.Band(window: window(61, resets: Self.date(20, 14, 0), duration: Self.week), now: now) == .serious,
                "out for under a quarter of the week")
        #expect(Theme.Band(window: window(92, resets: Self.date(17, 9, 51), duration: Self.session), now: now) == .critical,
                "92% used stays red even on pace")
        #expect(Theme.Band(window: window(12, resets: Self.date(17, 14, 12), duration: Self.session), now: now) == .good)
    }
}
