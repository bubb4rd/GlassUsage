import Foundation

nonisolated enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude, codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }

    var symbol: String {
        switch self {
        case .claude: "sparkle"
        case .codex: "chevron.left.forwardslash.chevron.right"
        }
    }

    var signInHint: String {
        switch self {
        case .claude: "Sign in with Claude Code (run `claude`) to see your plan limits."
        case .codex: "Sign in with Codex (run `codex`) using your ChatGPT account."
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

    var id: String { key }
    var fraction: Double { min(max(percent / 100, 0), 1) }
    var windowStart: Date? { resetsAt.map { $0.addingTimeInterval(-duration) } }

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

nonisolated struct ProviderSnapshot: Codable, Hashable, Sendable {
    let provider: ProviderID
    let plan: String?
    /// Account-wide windows, shortest first (session, weekly, monthly).
    let windows: [UsageWindow]
    let fetchedAt: Date

    /// The window closest to blocking the user.
    var mostConstrained: UsageWindow? { windows.max { $0.percent < $1.percent } }
}

nonisolated enum ProviderError: LocalizedError, Sendable {
    case notSignedIn(ProviderID)
    case unauthorized(ProviderID)
    case rateLimited
    case http(Int)
    case malformed(String)
    case noQuota(ProviderID)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn(let id): "Not connected. \(id.signInHint)"
        case .unauthorized(let id): "Sign-in expired. \(id.signInHint)"
        case .rateLimited: "The usage service is rate limiting requests. Retrying later."
        case .http(let code): "The usage service returned HTTP \(code)."
        case .malformed(let what): "Unexpected response: \(what)."
        case .noQuota(let id): "\(id.displayName) did not report plan limits for this account."
        case .network(let message): message
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
    static var supportDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "GlassUsage", directoryHint: .isDirectory)
    }
}
