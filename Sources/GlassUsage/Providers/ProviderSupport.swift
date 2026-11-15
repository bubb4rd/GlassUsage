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
        case 429: throw ProviderError.rateLimited
        default: throw ProviderError.http(status)
        }
        do { return try JSON(data: data) } catch { throw ProviderError.malformed("not JSON") }
    }
}

nonisolated enum Shell {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Runs a process off the main actor; kills it after `timeout`.
    @concurrent
    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil,
                    environment: [String: String]? = nil, timeout: TimeInterval = 15) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let cwd { process.currentDirectoryURL = cwd }
        if let environment { process.environment = environment }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let watchdog = Task {
            try await Task.sleep(for: .seconds(timeout))
            if process.isRunning { process.terminate() }
        }
        // Drain both pipes at once so a chatty stderr can't fill its buffer and stall the process.
        let errorHandle = stderr.fileHandleForReading
        let errors = Task.detached { errorHandle.readDataToEndOfFile() }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = await errors.value
        process.waitUntilExit()
        watchdog.cancel()
        return Output(status: process.terminationStatus, stdout: String(decoding: data, as: UTF8.self),
                      stderr: String(decoding: errorData, as: UTF8.self))
    }

    /// Resolves a CLI the way the user's terminal would (nvm, Homebrew, ~/.local/bin…).
    static func which(_ command: String) async -> String? {
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
