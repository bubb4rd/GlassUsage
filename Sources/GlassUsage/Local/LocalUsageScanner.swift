import Foundation

/// Reads token usage from local agent session logs, ccusage-style.
///
/// Logs are append-only, so each file is parsed once and then only from its last offset;
/// parsed entries are cached on disk. Only files touched within the report range are read.
actor LocalUsageScanner {
    static let shared = LocalUsageScanner()
    static let reportDays = 30

    private struct FileState: Codable {
        /// Bytes consumed so far (through the last complete line).
        var size: Int
        var codex: LogParsers.CodexState?
        var entries: [UsageEntry]
    }

    private struct Cache: Codable {
        static let currentVersion = 1
        var version = currentVersion
        var files: [String: FileState] = [:]
    }

    private var cache: Cache?
    private var pricing: PricingTable?

    private var cacheURL: URL { AppPaths.supportDirectory.appending(path: "local-usage-cache.plist") }

    func scan(now: Date = .now) async -> [ProviderID: LocalUsageReport] {
        if pricing == nil || pricing!.fetchedAt.map({ now.timeIntervalSince($0) > 24 * 3600 }) ?? true {
            pricing = await PricingTable.load()
        }
        var cache = self.cache ?? loadCache()
        let cutoff = now.addingTimeInterval(-Double(Self.reportDays + 1) * 86_400)
        var seen = Set<String>()
        var changed = false

        for (source, roots) in Self.roots() {
            for file in Self.logFiles(in: roots, source: source, modifiedAfter: cutoff) {
                seen.insert(file.path)
                let previous = cache.files[file.path]
                // Same length means no new lines (in-place header rewrites such as session titles).
                if let previous, previous.size == file.size { continue }
                // Grown files continue from the last parsed line; shrunk ones start over.
                let resume = previous.flatMap { $0.size < file.size ? $0 : nil }
                cache.files[file.path] = Self.parse(file, source: source, resume: resume)
                changed = true
            }
        }
        for path in cache.files.keys where !seen.contains(path) {
            cache.files[path] = nil
            changed = true
        }
        self.cache = cache
        if changed { saveCache(cache) }

        var keys = Set<String>()
        var entries: [UsageEntry] = []
        for state in cache.files.values {
            for entry in state.entries where entry.at >= cutoff && keys.insert(entry.key).inserted {
                entries.append(entry)
            }
        }
        let pricing = self.pricing ?? .builtIn
        return Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { provider in
            (provider, LocalUsageReport.build(provider: provider, entries: entries, pricing: pricing,
                                              days: Self.reportDays, now: now))
        })
    }

    // MARK: Discovery

    private struct LogFile {
        let url: URL
        let size: Int
        var path: String { url.path }
    }

    private static func roots() -> [(LocalSource, [URL])] {
        let home = URL.homeDirectory
        let env = ProcessInfo.processInfo.environment
        let claudeRoots = env["CLAUDE_CONFIG_DIR"].map {
            $0.split(separator: ",").map { URL(fileURLWithPath: String($0)).appending(path: "projects") }
        } ?? [home.appending(path: ".claude/projects"), home.appending(path: ".config/claude/projects")]
        let codexHome = CodexProvider.codexHome
        return [
            (.claudeCode, claudeRoots),
            (.codexCLI, [codexHome.appending(path: "sessions"), codexHome.appending(path: "archived_sessions")]),
            (.museCode, [MuseProvider.sessionsDirectory]),
            (.omp, [home.appending(path: ".omp/agent/sessions")]),
        ]
    }

    private static func logFiles(in roots: [URL], source: LocalSource, modifiedAfter cutoff: Date) -> [LogFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var files: [LogFile] = []
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if source == .codexCLI && !url.lastPathComponent.hasPrefix("rollout-") { continue }
                if source == .museCode && url.lastPathComponent != "session.jsonl" { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      let mtime = values.contentModificationDate, mtime >= cutoff,
                      let size = values.fileSize else { continue }
                files.append(LogFile(url: url, size: size))
            }
        }
        return files
    }

    // MARK: Parsing

    private static func parse(_ file: LogFile, source: LocalSource, resume: FileState?) -> FileState {
        var state = resume ?? FileState(size: 0, codex: nil, entries: [])
        guard let data = try? Data(contentsOf: file.url, options: .alwaysMapped) else { return state }
        var codex = state.codex ?? LogParsers.CodexState()
        let stem = file.url.deletingPathExtension().lastPathComponent
        // Muse Code names the session's directory, not the file.
        let sessionDir = file.url.deletingLastPathComponent().lastPathComponent
        let needles = LogParsers.needles(for: source)

        // Recording only what was consumed means a half-written last line is read next time.
        state.size = forEachLine(in: data, from: state.size, containingAny: needles) { line in
            guard let json = try? JSON(data: line) else { return }
            let entry: UsageEntry? = switch source {
            case .claudeCode: LogParsers.claudeCode(json)
            case .omp: LogParsers.omp(json)
            case .codexCLI: LogParsers.codex(json, state: &codex, fileStem: stem)
            case .museCode: LogParsers.muse(json, sessionID: sessionDir)
            }
            if let entry { state.entries.append(entry) }
        }
        if source == .codexCLI { state.codex = codex }
        return state
    }

    /// Calls `body` for each complete line after `offset` that contains one of `needles`.
    /// Returns the offset just past the last complete line.
    private static func forEachLine(in data: Data, from offset: Int, containingAny needles: [[UInt8]],
                                    body: (Data) -> Void) -> Int {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress, offset < raw.count else { return offset }
            var start = offset
            while start < raw.count {
                guard let newline = memchr(base + start, 0x0A, raw.count - start) else { break }
                let end = base.distance(to: UnsafeRawPointer(newline))
                let length = end - start
                if length > 0 {
                    let line = base + start
                    let relevant = needles.contains { needle in
                        needle.withUnsafeBytes { memmem(line, length, $0.baseAddress, needle.count) != nil }
                    }
                    if relevant { body(Data(bytes: line, count: length)) }
                }
                start = end + 1
            }
            return start
        }
    }

    // MARK: Cache persistence

    private func loadCache() -> Cache {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? PropertyListDecoder().decode(Cache.self, from: data),
              cache.version == Cache.currentVersion else { return Cache() }
        return cache
    }

    private func saveCache(_ cache: Cache) {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
            try encoder.encode(cache).write(to: cacheURL, options: .atomic)
        } catch {
            NSLog("GlassUsage: failed to save local usage cache: \(error)")
        }
    }
}
