import Foundation

/// Plan limits from Meta's Muse Code CLI. `muse usage --json` reports the subscription allowance
/// (5-hour window, weekly window, tier) from the CLI's own sign-in without running a model turn.
/// The token sits in a Keychain item Meta re-locks on every refresh, so the CLI is the only
/// read-only way in; GlassUsage never touches the credentials.
nonisolated enum MuseProvider {
    /// Sign-in metadata (`$MUSE_AUTH_PATH`); its presence means Muse Code has been set up.
    static var authFileURL: URL {
        ProcessInfo.processInfo.environment["MUSE_AUTH_PATH"].map { URL(fileURLWithPath: $0) }
            ?? URL.homeDirectory.appending(path: ".config/muse/auth.json")
    }

    /// Session transcripts: `$MUSE_SESSIONS_DIR`, else `$XDG_DATA_HOME/muse/sessions` (default `~/.local/share`).
    static var sessionsDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["MUSE_SESSIONS_DIR"] { return URL(fileURLWithPath: dir) }
        let data = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) } ?? URL.homeDirectory.appending(path: ".local/share")
        return data.appending(path: "muse/sessions")
    }

    private static let command = "muse usage"

    static func fetch() async throws -> ProviderSnapshot {
        guard let muse = await Shell.which("muse") else { throw ProviderError.notSignedIn(.muse) }
        var environment = ProcessInfo.processInfo.environment
        environment["MUSE_NO_AUTO_UPDATE"] = "1"
        let output = try await Shell.run(muse, ["usage", "--json"], environment: environment, timeout: 20)
        guard output.status == 0, let json = try? JSON(data: Data(output.stdout.utf8)) else {
            throw ProviderCLI.failure(.muse, command: command, output: output)
        }
        return try parseUsage(json, fetchedAt: .now)
    }

    /// `{"allowance": {"tier", "window": {"usedPercent", "resetsAtMs", "windowDurationMins"?}, "weekly": {…}}}`.
    /// A null allowance (API-key login, no subscription) means there are no plan limits to show.
    static func parseUsage(_ json: JSON, fetchedAt: Date) throws -> ProviderSnapshot {
        let allowance = json["allowance"]
        func window(_ node: JSON, key: String, title: String, defaultMinutes: Double) -> UsageWindow? {
            guard let percent = node["usedPercent"].double else { return nil }
            return UsageWindow(key: key, title: title, percent: percent,
                               resetsAt: node["resetsAtMs"].double.map { Date(timeIntervalSince1970: $0 / 1000) },
                               duration: (node["windowDurationMins"].double ?? defaultMinutes) * 60)
        }
        // An idle 5-hour window is omitted, so the weekly window can arrive alone.
        let windows = [
            window(allowance["window"], key: "session", title: "Session", defaultMinutes: 300),
            window(allowance["weekly"], key: "weekly", title: "Weekly", defaultMinutes: 7 * 24 * 60),
        ].compactMap { $0 }
        guard !windows.isEmpty else { throw ProviderError.noQuota(.muse) }
        return ProviderSnapshot(provider: .muse, plan: allowance["tier"].string.flatMap(planName),
                                windows: windows, fetchedAt: fetchedAt)
    }

    /// "Muse Code Power Usage" → "Power".
    static func planName(_ tier: String) -> String? {
        let name = tier.replacing(/(?i)^muse code\s+/, with: "").replacing(/(?i)\s+usage$/, with: "")
        return name.isEmpty ? nil : name
    }
}
