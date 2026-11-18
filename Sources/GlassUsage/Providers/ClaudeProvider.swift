import Foundation

/// Plan limits from Anthropic's OAuth usage endpoint, using Claude Code's existing sign-in.
///
/// Claude Code owns its credentials (and rotates the refresh token), so GlassUsage never
/// refreshes or writes them. When the access token has expired it asks Claude Code to renew
/// it by running the local `/usage` command, which needs no model request.
nonisolated enum ClaudeProvider {
    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    struct Credentials: Sendable {
        let accessToken: String
        let expiresAt: Date?
        let plan: String?

        var isExpired: Bool { expiresAt.map { $0 < .now.addingTimeInterval(60) } ?? false }
    }

    static func fetch() async throws -> ProviderSnapshot {
        var credentials = try await loadCredentials()
        if credentials.isExpired, await TokenRenewal.shared.renew() {
            credentials = try await loadCredentials()
        }
        do {
            return try await fetchUsage(credentials)
        } catch ProviderError.unauthorized(.claude) {
            guard await TokenRenewal.shared.renew() else { throw ProviderError.unauthorized(.claude) }
            return try await fetchUsage(try await loadCredentials())
        } catch let error as URLError {
            // Offline: a renewal that just failed most likely failed for the same reason, so it shouldn't hold off
            // the next one, which would then show a working sign-in as expired.
            await TokenRenewal.shared.forgetAttempt()
            throw error
        }
    }

    // MARK: Credentials

    static func loadCredentials() async throws -> Credentials {
        // `/usr/bin/security` is on the item's access list (Claude Code writes it with that tool),
        // so reading through it avoids a Keychain prompt on every refresh.
        if let output = try? await Shell.run("/usr/bin/security", ["find-generic-password", "-s", keychainService, "-w"]),
           output.status == 0,
           let credentials = parseCredentials(Data(output.stdout.utf8)) {
            return credentials
        }
        if let data = try? Data(contentsOf: credentialsFileURL), let credentials = parseCredentials(data) {
            return credentials
        }
        throw ProviderError.notSignedIn(.claude)
    }

    private static var credentialsFileURL: URL {
        let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? URL.homeDirectory.appending(path: ".claude")
        return configDir.appending(path: ".credentials.json")
    }

    private static func parseCredentials(_ data: Data) -> Credentials? {
        guard let json = try? JSON(data: data) else { return nil }
        let oauth = json["claudeAiOauth"]
        guard let token = oauth["accessToken"].string, !token.isEmpty else { return nil }
        let expiresAt = oauth["expiresAt"].double.map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token, expiresAt: expiresAt,
                           plan: planName(subscription: oauth["subscriptionType"].string, tier: oauth["rateLimitTier"].string))
    }

    static func planName(subscription: String?, tier: String?) -> String? {
        let tier = tier?.lowercased() ?? ""
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        guard let subscription, !subscription.isEmpty else { return nil }
        return subscription.prefix(1).uppercased() + subscription.dropFirst()
    }

    // MARK: Usage

    private static func fetchUsage(_ credentials: Credentials) async throws -> ProviderSnapshot {
        let json = try await HTTP.get(usageURL, headers: [
            "Authorization": "Bearer \(credentials.accessToken)",
            "anthropic-beta": "oauth-2025-04-20",
            "User-Agent": "GlassUsage/1.0",
        ], provider: .claude)
        return try parseUsage(json, plan: credentials.plan, fetchedAt: .now)
    }

    static func parseUsage(_ json: JSON, plan: String?, fetchedAt: Date) throws -> ProviderSnapshot {
        func window(_ node: JSON, key: String, title: String, duration: TimeInterval) -> UsageWindow? {
            guard let percent = node["utilization"].double else { return nil }
            return UsageWindow(key: key, title: title, percent: percent, resetsAt: node["resets_at"].isoDate, duration: duration)
        }

        let week: TimeInterval = 7 * 86_400
        var windows: [UsageWindow] = []
        if let session = window(json["five_hour"], key: "session", title: "Session", duration: 5 * 3600) {
            windows.append(session)
        }
        if let weekly = window(json["seven_day"], key: "weekly", title: "Weekly", duration: week)
            ?? window(json["seven_day_oauth_apps"], key: "weekly", title: "Weekly", duration: week) {
            windows.append(weekly)
        }
        guard !windows.isEmpty else { throw ProviderError.noQuota(.claude) }
        return ProviderSnapshot(provider: .claude, plan: plan, windows: windows, fetchedAt: fetchedAt)
    }
}

/// Serializes and rate-limits delegated token renewal through the Claude Code CLI.
actor TokenRenewal {
    static let shared = TokenRenewal()
    private var lastAttempt: Date?
    private var inFlight: Task<Bool, Never>?

    func renew() async -> Bool {
        if let inFlight { return await inFlight.value }
        if let lastAttempt, Date.now.timeIntervalSince(lastAttempt) < 5 * 60 { return false }
        lastAttempt = .now
        let task = Task { await Self.runClaudeUsageCommand() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    func forgetAttempt() {
        if inFlight == nil { lastAttempt = nil }
    }

    private static func runClaudeUsageCommand() async -> Bool {
        guard let claude = await Shell.which("claude") else { return false }
        let probeDir = AppPaths.supportDirectory.appending(path: "claude-probe", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: probeDir, withIntermediateDirectories: true)

        // The CLI is usually a Node script; make its interpreter resolvable.
        var environment = ProcessInfo.processInfo.environment
        let binDir = URL(fileURLWithPath: claude).deletingLastPathComponent().path
        environment["PATH"] = [binDir, "/opt/homebrew/bin", "/usr/local/bin", environment["PATH"] ?? "/usr/bin:/bin"]
            .joined(separator: ":")

        let output = try? await Shell.run(claude, ["-p", "/usage"], cwd: probeDir, environment: environment, timeout: 45)
        return output?.status == 0
    }
}
