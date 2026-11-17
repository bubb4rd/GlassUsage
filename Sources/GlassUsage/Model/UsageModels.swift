import Foundation

nonisolated enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex, antigravity, muse

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .antigravity: "Antigravity"
        case .muse: "Muse Code"
        }
    }

    var signInHint: String {
        switch self {
        case .claude: "Sign in with Claude Code (run `claude`) to see your plan limits."
        case .codex: "Sign in with Codex (run `codex`) using your ChatGPT account."
        case .antigravity: "Sign in with the Antigravity CLI (run `agy`) to see your plan limits."
        case .muse: "Sign in with Muse Code (run `muse login`) on a Muse Code subscription."
        }
    }
}

/// One quota window exactly as the provider reported it.
nonisolated struct UsageWindow: Codable, Hashable, Identifiable, Sendable {
    /// "session", "weekly", "monthly", or "window-<n>d/h".
    let key: String
    let title: String
    /// 0–100 as reported by the provider.
    let percent: Double
    let resetsAt: Date?
    let duration: TimeInterval
    /// Model group the window belongs to, for providers that meter groups separately
    /// (Antigravity: "Gemini", "Claude and GPT"). Nil for account-wide windows.
    var group: String? = nil

    var id: String { group.map { "\($0)/\(key)" } ?? key }
    var fraction: Double { min(max(percent / 100, 0), 1) }
    var windowStart: Date? { resetsAt.map { $0.addingTimeInterval(-duration) } }

    /// The provider's reset time has passed, so this reading no longer describes the window.
    func hasReset(at now: Date) -> Bool { resetsAt.map { $0 <= now } ?? false }

    static func titleAndKey(forSeconds seconds: TimeInterval) -> (key: String, title: String) {
        let hours = seconds / 3600
        switch hours {
        case ..<24: return ("session", "Session")
        case 24 * 6...24 * 8: return ("weekly", "Weekly")
        case 24 * 27...24 * 32: return ("monthly", "Monthly")
        default:
            let days = Int((hours / 24).rounded())
            return days >= 1 ? ("window-\(days)d", "\(days)-Day") : ("window-\(Int(hours))h", "\(Int(hours))-Hour")
        }
    }
}

/// Where a window is heading at the rate it has been used so far.
nonisolated enum Pace: Hashable, Sendable {
    /// Too little of the window has passed, or nothing is used yet, to tell.
    case early
    /// Ends the window at `projected` of the limit (0–1).
    case onPace(projected: Double)
    /// Reaches the limit at `emptyAt`, `lockout` before the window resets.
    case runsOut(emptyAt: Date, lockout: TimeInterval)
}

nonisolated extension UsageWindow {
    /// Projects the use so far across the whole window. Read it on `ProviderSnapshot.current(at:)` windows, so a
    /// window whose reset has passed (no reset time) has no projection.
    func pace(at now: Date) -> Pace? {
        guard let resetsAt, duration > 0 else { return nil }
        let elapsed = min(max(1 - resetsAt.timeIntervalSince(now) / duration, 0), 1)
        guard elapsed >= 0.15, percent > 0 else { return .early }
        let projected = fraction / elapsed
        guard projected >= 1 else { return .onPace(projected: projected) }
        let emptyAt = now.addingTimeInterval((1 - fraction) * elapsed * duration / fraction)
        return .runsOut(emptyAt: emptyAt, lockout: resetsAt.timeIntervalSince(emptyAt))
    }
}

nonisolated struct ProviderSnapshot: Codable, Hashable, Sendable {
    let provider: ProviderID
    let plan: String?
    /// Windows shortest first (session, weekly, monthly); grouped windows keep the provider's group order.
    let windows: [UsageWindow]
    let fetchedAt: Date

    /// The window closest to blocking the user.
    var mostConstrained: UsageWindow? { windows.max { $0.percent < $1.percent } }

    /// Group names in the provider's order; empty when the windows are account-wide.
    var groups: [String] {
        var seen = Set<String>()
        return windows.compactMap(\.group).filter { seen.insert($0).inserted }
    }

    /// The windows the menu bar ring draws: the group holding the most constrained window, or all of them.
    var iconWindows: [UsageWindow] {
        guard let group = mostConstrained?.group else { return windows }
        return windows.filter { $0.group == group }
    }

    /// The menu bar group's session window (shorter than a day), if the provider reported one.
    var sessionWindow: UsageWindow? { iconWindows.first { $0.key == "session" } }

    /// The menu bar group's longest window: the week, or the month on some Codex plans.
    var longWindow: UsageWindow? { iconWindows.last { $0.key != "session" } }

    /// The reading as of `now`: a window whose reset has passed reads 0% with no known reset until the next
    /// fetch, so an old reading never shows a limit that has already reset.
    func current(at now: Date) -> ProviderSnapshot {
        guard windows.contains(where: { $0.hasReset(at: now) }) else { return self }
        let windows = windows.map { window in
            window.hasReset(at: now)
                ? UsageWindow(key: window.key, title: window.title, percent: 0, resetsAt: nil,
                              duration: window.duration, group: window.group)
                : window
        }
        return ProviderSnapshot(provider: provider, plan: plan, windows: windows, fetchedAt: fetchedAt)
    }

    /// The earliest reset still ahead of `now`, when a fresh reading is worth fetching.
    func nextReset(after now: Date) -> Date? {
        windows.compactMap(\.resetsAt).filter { $0 > now }.min()
    }
}

nonisolated enum ProviderError: LocalizedError, Sendable {
    case notSignedIn(ProviderID)
    case unauthorized(ProviderID)
    /// `until` is when to ask again: the service's Retry-After, or GlassUsage's own backoff.
    case rateLimited(until: Date?)
    case http(Int)
    case malformed(String)
    case noQuota(ProviderID)
    case network(String)
    /// A provider CLI that reports limits for GlassUsage exited with an error.
    case commandFailed(String)
    /// The provider CLI GlassUsage asks for limits isn't installed, or isn't on the login shell's PATH.
    case commandNotFound(ProviderID, command: String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn(let id): "Not connected. \(id.signInHint)"
        case .unauthorized(let id): "Sign-in expired. \(id.signInHint)"
        case .rateLimited(let until):
            "The usage service is rate limiting requests. Retrying "
                + (until.map { "at \($0.formatted(date: .omitted, time: .shortened))." } ?? "later.")
        case .http(let code): "The usage service returned HTTP \(code)."
        case .malformed(let what): "Unexpected response: \(what)."
        case .noQuota(let id): "\(id.displayName) did not report plan limits for this account."
        case .network(let message): message
        case .commandFailed(let message): message
        case .commandNotFound(let id, let command):
            "`\(command)` wasn't found. Install the \(id.displayName) CLI, or add it to your shell's PATH."
        }
    }

    var isNotConnected: Bool {
        if case .notSignedIn = self { return true }
        return false
    }
}

nonisolated struct ProviderState: Sendable {
    var snapshot: ProviderSnapshot?
    var error: ProviderError?
    var isLoading = false
}

nonisolated enum AppPaths {
    /// A dev build (bundle id `….dev`) keeps its own folder: the log cache drops files from other cache
    /// versions, so a dev build and the installed app sharing one would keep reparsing each other's logs.
    static var supportDirectory: URL {
        let name = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true ? "GlassUsage Dev" : "GlassUsage"
        return URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }
}
