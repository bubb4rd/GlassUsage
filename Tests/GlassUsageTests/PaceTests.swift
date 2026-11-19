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

    @MainActor @Test func paceReachesFullTipSeverityWithoutCoolingUsage() {
        #expect(Theme.Band(window: window(47, resets: Self.date(23, 6, 30), duration: Self.week), now: now) == .critical,
                "out for over a quarter of the week heats the tip to red while the body stays green")
        #expect(Theme.Band(window: window(80, resets: Self.date(23, 6, 30), duration: Self.week), now: now) == .critical,
                "80% used and out for days heats from orange into red")
        #expect(Theme.Band(window: window(61, resets: Self.date(20, 14, 0), duration: Self.week), now: now) == .serious,
                "out for under a quarter of the week heats yellow into orange")
        #expect(Theme.Band(window: window(28, resets: Self.date(17, 13, 26), duration: Self.session), now: now) == .serious,
                "28% used ~75m into a 5h session runs out early and heats green into orange")
        #expect(Theme.Band(window: window(48, resets: Self.date(17, 12, 11), duration: Self.session), now: now) == .warning,
                "on pace for ~96% by reset warms green toward yellow")
        #expect(Theme.Band(window: window(92, resets: Self.date(17, 9, 51), duration: Self.session), now: now) == .critical,
                "92% used stays red even on pace")
        #expect(Theme.Band(window: window(12, resets: Self.date(17, 14, 12), duration: Self.session), now: now) == .good)
    }

    @MainActor @Test func gradientRampFlowsThroughIntermediateBands() {
        #expect(Theme.Band.good.ramp(to: .critical) == [.good, .warning, .serious, .critical])
        #expect(Theme.Band.warning.ramp(to: .critical) == [.warning, .serious, .critical])
        #expect(Theme.Band.good.ramp(to: .warning) == [.good, .warning])
        #expect(Theme.Band.serious.ramp(to: .serious) == [.serious])
        #expect(Theme.Band.critical.ramp(to: .good) == [.critical])
    }

    @MainActor @Test func gradientStopsStayMonotonicAndGuardStartSeam() {
        #expect(abs(Theme.Band.tipPower(warmth: 0) - 1.75) < 0.001)
        #expect(abs(Theme.Band.tipPower(warmth: 1) - 1.20) < 0.001)
        #expect(abs(Theme.Band.tipPower(warmth: -1) - 1.75) < 0.001)
        #expect(abs(Theme.Band.tipPower(warmth: 2) - 1.20) < 0.001)

        #expect(Theme.Band.color(from: .good, to: .critical, at: 0) == Theme.Band.good.color)
        #expect(Theme.Band.color(from: .good, to: .critical, at: 1) == Theme.Band.critical.color)
        #expect(Theme.Band.color(from: .good, to: .critical, at: 1.0 / 3.0, power: 1) == Theme.Band.warning.color)
        #expect(Theme.Band.color(from: .good, to: .critical, at: 2.0 / 3.0, power: 1) == Theme.Band.serious.color)

        let flat = Theme.Band.gradientStops(from: .serious, to: .serious, fraction: 0.84)
        #expect(flat.count == 2)
        #expect(flat.first?.location == 0)
        #expect(flat.last?.location == 1)

        for fraction in [0.01, 0.28, 0.65, 0.89, 0.98] {
            let stops = Theme.Band.gradientStops(from: .good, to: .critical, fraction: fraction)
            #expect(stops.first?.location == 0)
            #expect(stops.last?.location == 1)
            #expect(stops.first?.color == Theme.Band.good.color)
            #expect(stops.last?.color == Theme.Band.good.color, "start cap wrap-around must stay in the usage color")
            for (prev, next) in zip(stops, stops.dropFirst()) {
                #expect(prev.location <= next.location, "stops must be monotonic for fraction \(fraction)")
                #expect(prev.location >= 0 && next.location <= 1)
            }
        }
    }
}
