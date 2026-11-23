import CryptoKit
import Foundation

/// Reads token usage from local agent session logs, ccusage-style.
///
/// Logs are append-only, so each file is parsed once and then only from its last offset;
/// parsed entries are cached on disk, one file per log, so a scan rewrites only the logs that grew.
/// Only files touched within the report range are read.
actor LocalUsageScanner {
    static let shared = LocalUsageScanner()
    static let reportDays = 30

    private struct FileState: Codable {
        /// Bytes consumed so far (through the last complete line); for SQLite, database plus WAL size.
        var size: Int
        /// Latest write to a SQLite database or its WAL, which can change without changing size.
        var modified: Date?
        var codex: LogParsers.CodexState?
        /// The session folder from an omp header or Muse Code metadata record.
        var project: String? = nil
        var entries: [UsageEntry]
    }

    /// One log's parse state as stored in `local-usage-cache/<SHA-1 of the log path>.plist`.
    private struct StoredFile: Codable {
        /// 2: entries carry their project folder. 3: Antigravity and Muse Code entries do too.
        /// 4: the Antigravity desktop app's placeholder models are named; its source is `antigravity`.
        /// 5: Antigravity conversations ignore T3 Code's attachments workspace so they credit their real project.
        static let currentVersion = 5
        var version = currentVersion
        let path: String
        let state: FileState
    }

    /// Parse state by log path; loaded from disk on the first scan.
    private var files: [String: FileState]?
    private var pricing: PricingTable?

    private var cacheDirectory: URL { AppPaths.supportDirectory.appending(path: "local-usage-cache", directoryHint: .isDirectory) }

    /// `readProtectedFolders`: whether project folders macOS guards may be read to find their repository.
    func scan(now: Date = .now, readProtectedFolders: Bool) async -> [ProviderID: LocalUsageReport] {
        if pricing == nil || pricing!.fetchedAt.map({ now.timeIntervalSince($0) > 24 * 3600 }) ?? true {
            pricing = await PricingTable.load()
        }
        var files = self.files ?? loadCache()
        let cutoff = now.addingTimeInterval(-Double(Self.reportDays + 1) * 86_400)
        var seen = Set<String>()
        var changed: [String] = []

        for (source, roots) in Self.roots() {
            for file in Self.logFiles(in: roots, source: source, modifiedAfter: cutoff) {
                seen.insert(file.path)
                let previous = files[file.path]
                // Same length means no new lines (in-place header rewrites such as session titles).
                if let previous, previous.size == file.size, previous.modified == file.modified { continue }
                // Grown files continue from the last parsed line; shrunk ones start over.
                let resume = previous.flatMap { $0.size < file.size ? $0 : nil }
                files[file.path] = Self.parse(file, source: source, resume: resume)
                changed.append(file.path)
            }
        }
        let removed = files.keys.filter { !seen.contains($0) }
        for path in removed { files[path] = nil }
        self.files = files
        saveCache(changed: changed, removed: removed, in: files)

        var keys = Set<String>()
        var entries: [UsageEntry] = []
        // Looked up on every scan rather than cached: repositories and worktrees come and go.
        var roots: [String: String] = [:]
        for state in files.values {
            for var entry in state.entries where entry.at >= cutoff && keys.insert(entry.key).inserted {
                if let project = entry.project {
                    let root = roots[project] ?? ProjectRoots.root(of: project, readProtected: readProtectedFolders)
                    roots[project] = root
                    entry.project = root
                }
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
        /// Set for SQLite databases only.
        var modified: Date?
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
            (.antigravity, AntigravityLogs.conversationDirectories()),
            (.museCode, [MuseProvider.sessionsDirectory]),
            (.omp, [home.appending(path: ".omp/agent/sessions")]),
        ]
    }

    private static func logFiles(in roots: [URL], source: LocalSource, modifiedAfter cutoff: Date) -> [LogFile] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        var files: [LogFile] = []
        let isDatabase = source == .antigravity
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == (isDatabase ? "db" : "jsonl") {
                if source == .codexCLI && !url.lastPathComponent.hasPrefix("rollout-") { continue }
                if source == .museCode && url.lastPathComponent != "session.jsonl" { continue }
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                      var mtime = values.contentModificationDate, var size = values.fileSize else { continue }
                if isDatabase {
                    // Recent writes sit in the WAL until SQLite checkpoints them into the database.
                    let wal = URL(fileURLWithPath: url.path + "-wal")
                    if let walValues = try? wal.resourceValues(forKeys: Set(keys)), let walSize = walValues.fileSize {
                        size += walSize
                        mtime = max(mtime, walValues.contentModificationDate ?? mtime)
                    }
                }
                guard mtime >= cutoff else { continue }
                files.append(LogFile(url: url, size: size, modified: isDatabase ? mtime : nil))
            }
        }
        return files
    }

    // MARK: Parsing

    private static func parse(_ file: LogFile, source: LocalSource, resume: FileState?) -> FileState {
        if source == .antigravity {
            // A database, not an append-only log: reread it whole whenever it changes.
            return FileState(size: file.size, modified: file.modified, entries: AntigravityLogs.entries(in: file.url))
        }
        var state = resume ?? FileState(size: 0, codex: nil, entries: [])
        guard let data = try? Data(contentsOf: file.url, options: .alwaysMapped) else { return state }
        var codex = state.codex ?? LogParsers.CodexState()
        var project = state.project
        let stem = file.url.deletingPathExtension().lastPathComponent
        // Muse Code names the session's directory, not the file.
        let sessionDir = file.url.deletingLastPathComponent().lastPathComponent
        let needles = LogParsers.needles(for: source)

        // Recording only what was consumed means a half-written last line is read next time.
        state.size = forEachLine(in: data, from: state.size, containingAny: needles) { line in
            guard let json = try? JSON(data: line) else { return }
            let entry: UsageEntry? = switch source {
            case .claudeCode: LogParsers.claudeCode(json)
            case .omp: LogParsers.omp(json, project: &project)
            case .codexCLI: LogParsers.codex(json, state: &codex, fileStem: stem)
            case .museCode: LogParsers.muse(json, sessionID: sessionDir, project: &project)
            case .antigravity: nil
            }
            if let entry { state.entries.append(entry) }
        }
        if source == .codexCLI { state.codex = codex }
        state.project = project
        // Muse Code can log its folder after the first completions; fill those in once, when it appears.
        if source == .museCode, let project, resume?.project == nil {
            for index in state.entries.indices where state.entries[index].project == nil {
                state.entries[index].project = project
            }
        }
        return state
    }

    /// Calls `body` for each complete line after `offset` that contains one of `needles`.
    /// Returns the offset just past the last complete line.
    static func forEachLine(in data: Data, from offset: Int, containingAny needles: [[UInt8]],
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

    private func cacheFileURL(for path: String) -> URL {
        let digest = Insecure.SHA1.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory.appending(path: "\(digest).plist")
    }

    private func loadCache() -> [String: FileState] {
        let fm = FileManager.default
        // Before 1.2.6 the whole cache was one plist, rewritten on every scan.
        try? fm.removeItem(at: AppPaths.supportDirectory.appending(path: "local-usage-cache.plist"))
        var files: [String: FileState] = [:]
        let urls = (try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil)) ?? []
        let decoder = PropertyListDecoder()
        for url in urls {
            guard let data = try? Data(contentsOf: url),
                  let stored = try? decoder.decode(StoredFile.self, from: data),
                  stored.version == StoredFile.currentVersion else {
                // Unreadable or from another version: its log is parsed afresh.
                try? fm.removeItem(at: url)
                continue
            }
            files[stored.path] = stored.state
        }
        return files
    }

    private func saveCache(changed: [String], removed: [String], in files: [String: FileState]) {
        guard !changed.isEmpty || !removed.isEmpty else { return }
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            for path in removed { try? FileManager.default.removeItem(at: cacheFileURL(for: path)) }
            for path in changed {
                guard let state = files[path] else { continue }
                try encoder.encode(StoredFile(path: path, state: state)).write(to: cacheFileURL(for: path), options: .atomic)
            }
        } catch {
            NSLog("GlassUsage: failed to save local usage cache: \(error)")
        }
    }
}
