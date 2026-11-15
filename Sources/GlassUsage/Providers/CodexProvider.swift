import Foundation

/// Plan limits from ChatGPT's Codex usage endpoint, using the Codex CLI's existing sign-in.
/// The CLI owns `auth.json` and refreshes it; GlassUsage only reads it.
nonisolated enum CodexProvider {
    private static let defaultBaseURL = "https://chatgpt.com/backend-api"

    static var codexHome: URL {
        ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL.homeDirectory.appending(path: ".codex")
    }

    static var authFileURL: URL { codexHome.appending(path: "auth.json") }

    static func fetch() async throws -> ProviderSnapshot {
        guard let data = try? Data(contentsOf: authFileURL), let auth = try? JSON(data: data) else {
            throw ProviderError.notSignedIn(.codex)
        }
        guard let token = auth["tokens"]["access_token"].string, !token.isEmpty else {
            // API-key mode has no plan limits to report.
            throw ProviderError.notSignedIn(.codex)
        }
        var headers = [
            "Authorization": "Bearer \(token)",
            "User-Agent": "codex_cli_rs",
        ]
        if let account = auth["tokens"]["account_id"].string { headers["ChatGPT-Account-Id"] = account }

        let json = try await HTTP.get(usageURL(), headers: headers, provider: .codex)
        return try parseUsage(json, fetchedAt: .now)
    }

    /// Honors `chatgpt_base_url` in config.toml, like the CLI.
    private static func usageURL() -> URL {
        var base = defaultBaseURL
        if let config = try? String(contentsOf: codexHome.appending(path: "config.toml"), encoding: .utf8) {
            for line in config.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("#"), trimmed.hasPrefix("chatgpt_base_url") else { continue }
                if let match = trimmed.firstMatch(of: /"([^"]+)"/) { base = String(match.1) }
            }
        }
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !base.contains("/backend-api") { base += "/backend-api" }
        return URL(string: base + "/wham/usage") ?? URL(string: defaultBaseURL + "/wham/usage")!
    }

    static func parseUsage(_ json: JSON, fetchedAt: Date) throws -> ProviderSnapshot {
        let windows: [UsageWindow] = [json["rate_limit"]["primary_window"], json["rate_limit"]["secondary_window"]]
            .compactMap { node in
                guard let percent = node["used_percent"].double,
                      let seconds = node["limit_window_seconds"].double, seconds > 0 else { return nil }
                let resetsAt = node["reset_at"].double.map { Date(timeIntervalSince1970: $0) }
                    ?? node["reset_after_seconds"].double.map { fetchedAt.addingTimeInterval($0) }
                let (key, title) = UsageWindow.titleAndKey(forSeconds: seconds)
                return UsageWindow(key: key, title: title, percent: percent, resetsAt: resetsAt, duration: seconds)
            }
            .sorted { $0.duration < $1.duration }
        guard !windows.isEmpty else { throw ProviderError.noQuota(.codex) }

        let plan = json["plan_type"].string.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return ProviderSnapshot(provider: .codex, plan: plan, windows: windows, fetchedAt: fetchedAt)
    }
}
