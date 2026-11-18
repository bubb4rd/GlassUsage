import Foundation

/// Lenient accessors over `JSONSerialization` output; provider payloads add keys often.
nonisolated struct JSON: @unchecked Sendable {
    let raw: Any?

    init(_ raw: Any?) { self.raw = raw is NSNull ? nil : raw }

    init(data: Data) throws {
        self.init(try JSONSerialization.jsonObject(with: data))
    }

    subscript(key: String) -> JSON { JSON((raw as? [String: Any])?[key]) }

    var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    var string: String? { raw as? String }
    var double: Double? { (raw as? NSNumber).flatMap { CFGetTypeID($0) == CFBooleanGetTypeID() ? nil : $0.doubleValue } }
    var bool: Bool? { raw as? Bool }
    var exists: Bool { raw != nil }

    /// ISO-8601 with any number of fractional digits (Anthropic sends microseconds).
    var isoDate: Date? {
        guard let string else { return nil }
        let trimmed = string.replacing(/\.\d+/, with: "")
        return try? Date(trimmed, strategy: .iso8601)
    }
}

nonisolated enum HTTP {
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["Accept": "application/json"]
        return URLSession(configuration: config)
    }()

    static func get(_ url: URL, headers: [String: String], provider: ProviderID) async throws -> JSON {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 401, 403: throw ProviderError.unauthorized(provider)
        case 429: throw ProviderError.rateLimited(until: retryDate((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After")))
        default: throw ProviderError.http(status)
        }
        do { return try JSON(data: data) } catch { throw ProviderError.malformed("not JSON") }
    }

    /// A `Retry-After` header, given either as seconds or as an HTTP date.
    static func retryDate(_ header: String?, now: Date = .now) -> Date? {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return now.addingTimeInterval(max(seconds, 0)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
    }
}

nonisolated enum Shell {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a process off the main actor. After `timeout` it's asked to quit, then killed. Output is collected as
    /// it arrives rather than read to the end: a helper the CLI started (a language server, a Node worker) can
    /// keep the pipes open long after the CLI is gone, and reading to their end would then never return.
    @concurrent
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval = 15) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        let stdout = PipeReader()
        let stderr = PipeReader()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe
        process.standardInput = FileHandle.nullDevice

        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            guard process.isRunning else { return }
            process.terminate()
            try await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        defer { watchdog.cancel() }
        try await withCheckedThrowingContinuation { (exited: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in exited.resume() }
            do { try process.run() } catch { exited.resume(throwing: error) }
        }
        // The pipes close as the process exits, unless something it started still holds them: wait a second at most.
        var waited = 0
        while !(stdout.isAtEnd && stderr.isAtEnd), waited < 20 {
            try? await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
        return Output(status: process.terminationStatus, stdout: String(decoding: stdout.finish(), as: UTF8.self),
                      stderr: String(decoding: stderr.finish(), as: UTF8.self))
    }

    /// Collects a pipe's output as it arrives, until its end or until `finish`.
    private final class PipeReader: @unchecked Sendable {
        let pipe = Pipe()
        private let lock = NSLock()
        private var data = Data()
        private var ended = false

        init() {
            pipe.fileHandleForReading.readabilityHandler = { [self] handle in
                let chunk = handle.availableData
                lock.withLock {
                    if chunk.isEmpty { ended = true } else { data.append(chunk) }
                }
                if chunk.isEmpty { handle.readabilityHandler = nil }
            }
        }

        var isAtEnd: Bool { lock.withLock { ended } }

        func finish() -> Data {
            pipe.fileHandleForReading.readabilityHandler = nil
            return lock.withLock { data }
        }
    }

    /// Resolves a CLI the way the user's terminal would (nvm, Homebrew, ~/.local/bin…). Remembered, so the
    /// login-shell lookup doesn't run on every refresh.
    static func which(_ command: String) async -> String? {
        await CommandPaths.shared.resolve(command)
    }

    fileprivate static func lookUp(_ command: String) async -> String? {
        let home = URL.homeDirectory.path
        let candidates = [
            "\(home)/.local/bin/\(command)",
            "\(home)/.\(command)/local/\(command)",
            "/opt/homebrew/bin/\(command)",
            "/usr/local/bin/\(command)",
        ]
        if let hit = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) { return hit }
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        guard let output = try? await run(shell, ["-lic", "command -v \(command)"], timeout: 10) else { return nil }
        let path = output.stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces)
        guard let path, path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

/// Where each CLI was last found. A found path is reused while it stays executable; a miss is retried
/// after a few minutes, so installing a CLI is picked up without restarting GlassUsage.
private actor CommandPaths {
    static let shared = CommandPaths()
    private static let missRetry: TimeInterval = 10 * 60

    private var found: [String: String] = [:]
    private var missedAt: [String: Date] = [:]

    func resolve(_ command: String) async -> String? {
        if let path = found[command], FileManager.default.isExecutableFile(atPath: path) { return path }
        if let missed = missedAt[command], Date.now.timeIntervalSince(missed) < Self.missRetry { return nil }
        let path = await Shell.lookUp(command)
        found[command] = path
        missedAt[command] = path == nil ? .now : nil
        return path
    }
}

/// Limits read through a provider's own CLI (`agy -p /usage`, `muse usage`): the CLI owns the
/// sign-in and its refresh, so GlassUsage never touches the credentials.
nonisolated enum ProviderCLI {
    /// Maps a failed run to "not signed in" when the CLI says so, otherwise to its first error line.
    static func failure(_ provider: ProviderID, command: String, output: Shell.Output) -> ProviderError {
        let text = output.stderr + "\n" + output.stdout
        let lowered = text.lowercased()
        let signInPhrases = ["not logged in", "not signed in", "log in", "sign in", "login", "unauthenticated", "authentication required"]
        if signInPhrases.contains(where: lowered.contains) { return .notSignedIn(provider) }
        let line = text.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("{") }
        guard let line else { return .commandFailed("`\(command)` failed (exit \(output.status)).") }
        return .commandFailed("`\(command)` failed: \(line.prefix(120))")
    }
}
