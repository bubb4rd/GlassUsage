import Foundation

/// Plan limits from Google's Antigravity CLI. `agy -p /usage --output-format json` answers from the
/// CLI's own sign-in without starting an agent turn or spending quota, so GlassUsage never reads
/// or refreshes Google credentials.
///
/// Antigravity meters model groups separately ("Gemini", "Claude and GPT", "Gemini 4 Argon"), each
/// with its own 5-hour and/or weekly window; every window carries its group.
nonisolated enum AntigravityProvider {
    /// Where the CLI keeps its state; its presence means Antigravity has been set up on this Mac.
    static var stateDirectory: URL { URL.homeDirectory.appending(path: ".gemini/antigravity-cli") }

    private static let command = "agy -p /usage"

    static func fetch() async throws -> ProviderSnapshot {
        guard let agy = await Shell.which("agy") else { throw ProviderError.commandNotFound(.antigravity, command: "agy") }
        // Print mode never leaves a conversation behind, but run it outside any project anyway.
        let workDir = AppPaths.supportDirectory.appending(path: "agy-probe", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let output = try await Shell.run(agy, ["-p", "/usage", "--output-format", "json"], cwd: workDir, timeout: 30)
        guard output.status == 0, let json = try? JSON(data: Data(output.stdout.utf8)),
              json["status"].string == "SUCCESS" else {
            throw ProviderCLI.failure(.antigravity, command: command, output: output)
        }
        return try parseUsage(json["command"]["data"], fetchedAt: .now)
    }

    /// `data` is the `/usage` payload: `groups[].buckets[]` with `window` ("5h", "weekly"),
    /// `remaining_fraction` (0–1) and `reset_time` (ISO-8601).
    static func parseUsage(_ data: JSON, fetchedAt: Date) throws -> ProviderSnapshot {
        var windows: [UsageWindow] = []
        for group in data["groups"].array {
            guard let rawName = group["name"].string else { continue }
            let name = groupName(rawName)
            let buckets = group["buckets"].array.compactMap { bucket -> UsageWindow? in
                guard let remaining = bucket["remaining_fraction"].double,
                      let duration = duration(of: bucket["window"].string) else { return nil }
                let (key, title) = UsageWindow.titleAndKey(forSeconds: duration)
                return UsageWindow(key: key, title: title, percent: min(max((1 - remaining) * 100, 0), 100),
                                   resetsAt: bucket["reset_time"].isoDate, duration: duration, group: name)
            }
            windows += buckets.sorted { $0.duration < $1.duration }
        }
        guard !windows.isEmpty else { throw ProviderError.noQuota(.antigravity) }
        return ProviderSnapshot(provider: .antigravity, plan: nil, windows: windows, fetchedAt: fetchedAt)
    }

    /// "5h", "24h", "7d", "weekly", "daily", "monthly" → seconds.
    static func duration(of window: String?) -> TimeInterval? {
        guard let window = window?.lowercased() else { return nil }
        switch window {
        case "daily": return 86_400
        case "weekly": return 7 * 86_400
        case "monthly": return 30 * 86_400
        default:
            guard let match = window.wholeMatch(of: /(\d+)\s*([hdm])/), let count = Double(match.1) else { return nil }
            switch match.2 {
            case "h": return count * 3600
            case "d": return count * 86_400
            default: return count * 60
            }
        }
    }

    /// "Gemini Models" → "Gemini", "Claude and GPT models" → "Claude and GPT".
    static func groupName(_ name: String) -> String {
        name.replacing(/(?i)\s+models$/, with: "")
    }
}
