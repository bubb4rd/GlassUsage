import Foundation
import SQLite3

/// Token usage from Cline and its forks Roo Code and Kilo Code. They run inside VS Code and every editor
/// built on it, each keeping its tasks under that editor's `globalStorage/<extension id>/tasks/`; Cline now
/// also keeps them in `~/.cline/data`, and Kilo Code 7 in an OpenCode-style database. Formats follow the
/// extensions' sources and tokscale's parsers.
///
/// Calls count toward the plan their model belongs to (Claude or GPT); calls through Cline's Claude Code
/// provider are skipped, since Claude Code logs them itself.
nonisolated enum ClineLogs {
    // MARK: Discovery

    /// Editors built on VS Code; any of them can host these extensions.
    private static let editors = ["Code", "Code - Insiders", "VSCodium", "Cursor", "Windsurf", "Antigravity", "Kiro",
                                  "Trae", "Void", "Positron"]

    static func directories(for source: LocalSource) -> [URL] {
        let extensionID = switch source {
        case .cline: "saoudrizwan.claude-dev"
        case .rooCode: "rooveterinaryinc.roo-cline"
        default: "kilocode.kilo-code"
        }
        var directories = editors.map {
            URL.applicationSupportDirectory.appending(path: "\($0)/User/globalStorage/\(extensionID)/tasks", directoryHint: .isDirectory)
        }
        switch source {
        case .cline:
            directories += [clineDataDirectory.appending(path: "tasks"), clineDataDirectory.appending(path: "sessions")]
        case .kiloCode:
            // `kilo.db`, or `kilo-<channel>.db` for preview builds; the folder's other contents aren't usage.
            let files = (try? FileManager.default.contentsOfDirectory(at: kiloDataDirectory, includingPropertiesForKeys: nil)) ?? []
            directories += files.filter { $0.lastPathComponent.hasPrefix("kilo") && $0.pathExtension == "db" }
        default:
            break
        }
        return directories
    }

    static func isLog(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == "ui_messages.json" || name.hasSuffix(".messages.json") || url.pathExtension == "db"
    }

    /// `$CLINE_DATA_DIR`, else `$CLINE_DIR/data`, else `~/.cline/data`.
    private static var clineDataDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let dir = env["CLINE_DATA_DIR"] { return URL(fileURLWithPath: dir, isDirectory: true) }
        let root = env["CLINE_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? URL.homeDirectory.appending(path: ".cline")
        return root.appending(path: "data", directoryHint: .isDirectory)
    }

    private static var kiloDataDirectory: URL {
        let data = ProcessInfo.processInfo.environment["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? URL.homeDirectory.appending(path: ".local/share")
        return data.appending(path: "kilo", directoryHint: .isDirectory)
    }

    // MARK: Parsing

    /// Each of these files is rewritten whole, so it's read whole.
    static func entries(in url: URL, source: LocalSource, since cutoff: Date) -> [UsageEntry] {
        if url.pathExtension == "db" { return kiloEntries(in: url, since: cutoff) }
        if url.lastPathComponent.hasSuffix(".messages.json") { return sessionEntries(in: url) }
        return taskEntries(in: url, source: source)
    }

    /// Roo Code and Kilo Code record `tokensIn` including cache reads and writes from Roo 3.29.5
    /// (2025-11-02) on; before that only over the OpenAI protocol. Cline keeps them apart throughout.
    private static let grossInputSince = Date(timeIntervalSince1970: 1_762_041_600)

    /// One task's `ui_messages.json`: each API call is an `api_req_started` message whose `text` is its usage as JSON.
    static func taskEntries(in url: URL, source: LocalSource) -> [UsageEntry] {
        guard let data = try? Data(contentsOf: url), let messages = try? JSON(data: data) else { return [] }
        let taskDirectory = url.deletingLastPathComponent()
        let taskID = taskDirectory.lastPathComponent
        let project = workspace(ofTask: taskDirectory, source: source)
        // Roo and Kilo name the model only in the conversation's environment details; read it once, if needed.
        var conversationModel: String??
        func modelFromConversation() -> String? {
            if conversationModel == nil { conversationModel = .some(lastModelTag(in: taskDirectory)) }
            return conversationModel!
        }

        var entries: [UsageEntry] = []
        for message in messages.array where message["type"].string == "say" && message["say"].string == "api_req_started" {
            guard message["partial"].bool != true, let text = message["text"].string,
                  let usage = try? JSON(data: Data(text.utf8)), let at = date(message["ts"]) else { continue }
            let reads = usage["cacheReads"].int
            let writes = usage["cacheWrites"].int
            var input = usage["tokensIn"].int
            if source != .cline, at >= grossInputSince || usage["apiProtocol"].string?.split(separator: "/").last == "openai" {
                input = max(input - reads - writes, 0)
            }
            let tokens = TokenCounts(input: input, output: usage["tokensOut"].int, cacheRead: reads, cacheWrite: writes)
            // In flight: written first without usage, then rewritten in place when the response ends.
            guard tokens.total > 0 else { continue }
            let modelInfo = message["modelInfo"]
            guard modelInfo["providerId"].string != "claude-code",
                  let model = (modelInfo["modelId"].string ?? modelFromConversation()).map(modelID),
                  let provider = LogParsers.provider(vendor: nil, model: model) else { continue }
            let stamp = message["ts"].double.map { String(Int($0)) } ?? message["ts"].string ?? ""
            entries.append(UsageEntry(key: "\(source.rawValue):\(taskID):\(stamp)", at: at, provider: provider, source: source,
                                      model: model, tokens: tokens, cacheWrite1h: 0,
                                      recordedCost: usage["cost"].double.flatMap { $0 > 0 ? $0 : nil }, project: project))
        }
        return entries
    }

    /// Roo and Kilo keep each task's `HistoryItem` beside it; Cline keeps all of them in `state/taskHistory.json`.
    private static func workspace(ofTask taskDirectory: URL, source: LocalSource) -> String? {
        if source != .cline {
            let item = (try? Data(contentsOf: taskDirectory.appending(path: "history_item.json"))).flatMap { try? JSON(data: $0) }
            return item?["workspace"].string
        }
        let historyURL = taskDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "state/taskHistory.json")
        guard let data = try? Data(contentsOf: historyURL), let history = try? JSON(data: data) else { return nil }
        let id = taskDirectory.lastPathComponent
        return history.array.first { $0["id"].string == id }?["cwdOnTaskInitialization"].string
    }

    /// The last `<model>` tag inside `<environment_details>` in a task's `api_conversation_history.json`.
    private static func lastModelTag(in taskDirectory: URL) -> String? {
        guard let data = try? Data(contentsOf: taskDirectory.appending(path: "api_conversation_history.json")) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        var model: String?
        for block in text.matches(of: /<environment_details>(.*?)<\/environment_details>/.dotMatchesNewlines()) {
            if let tag = block.output.1.firstMatch(of: /<model>\s*(.*?)\s*<\/model>/), !tag.output.1.isEmpty {
                model = String(tag.output.1)
            }
        }
        return model
    }

    /// A Cline session in `~/.cline/data/sessions/<id>/<id>.messages.json`; its folder and starting model are
    /// in the `<id>.json` manifest beside it. Assistant messages carry `metrics`, whose input includes the cache.
    static func sessionEntries(in url: URL) -> [UsageEntry] {
        guard let data = try? Data(contentsOf: url), let file = try? JSON(data: data) else { return [] }
        let stem = String(url.lastPathComponent.dropLast(".messages.json".count))
        let manifest = (try? Data(contentsOf: url.deletingLastPathComponent().appending(path: "\(stem).json")))
            .flatMap { try? JSON(data: $0) }
        let sessionID = file["sessionId"].string ?? manifest?["session_id"].string ?? stem
        let project = manifest?["workspace_root"].string ?? manifest?["cwd"].string
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .now
        var model = manifest?["model"].string
        var vendor = manifest?["provider"].string

        var entries: [UsageEntry] = []
        for (index, message) in file["messages"].array.enumerated() where message["role"].string == "assistant" {
            if let id = message["modelInfo"]["id"].string { model = id }
            if let id = message["modelInfo"]["provider"].string { vendor = id }
            let metrics = message["metrics"]
            let reads = metrics["cacheReadTokens"].int
            let writes = metrics["cacheWriteTokens"].int
            let tokens = TokenCounts(input: max(metrics["inputTokens"].int - reads - writes, 0), output: metrics["outputTokens"].int,
                                     cacheRead: reads, cacheWrite: writes)
            guard tokens.total > 0, vendor != "claude-code", let name = model.map(modelID),
                  let provider = LogParsers.provider(vendor: nil, model: name) else { continue }
            entries.append(UsageEntry(key: "cline:\(sessionID):\(message["id"].string ?? String(index))",
                                      at: date(message["ts"]) ?? modified, provider: provider, source: .cline, model: name,
                                      tokens: tokens, cacheWrite1h: 0,
                                      recordedCost: metrics["cost"].double.flatMap { $0 > 0 ? $0 : nil }, project: project))
        }
        return entries
    }

    /// Kilo Code 7's `kilo.db`, in OpenCode's schema: assistant messages carry `tokens` (input without the
    /// cache, reasoning apart from output), and their session its folder. Tasks Kilo imported from older
    /// versions carry no tokens, so the `tasks/` folders are still read for those.
    static func kiloEntries(in url: URL, since cutoff: Date) -> [UsageEntry] {
        guard let db = SQLiteRead.open(url) else { return [] }
        defer { sqlite3_close(db) }
        let since = cutoff.timeIntervalSince1970 * 1000
        let filter = "WHERE json_extract(m.data, '$.role') = 'assistant' AND json_extract(m.data, '$.time.created') >= ?"
        var entries: [UsageEntry] = []
        let row = { (row: OpaquePointer) in
            guard let id = SQLiteRead.text(row, 0), let text = SQLiteRead.text(row, 1),
                  let message = try? JSON(data: Data(text.utf8)), let created = message["time"]["created"].double else { return }
            let usage = message["tokens"]
            let tokens = TokenCounts(input: usage["input"].int, output: usage["output"].int + usage["reasoning"].int,
                                     cacheRead: usage["cache"]["read"].int, cacheWrite: usage["cache"]["write"].int)
            guard tokens.total > 0, message["providerID"].string != "claude-code",
                  let model = message["modelID"].string.map(modelID),
                  let provider = LogParsers.provider(vendor: nil, model: model) else { return }
            entries.append(UsageEntry(key: "kilo:\(id)", at: Date(timeIntervalSince1970: created / 1000), provider: provider,
                                      source: .kiloCode, model: model, tokens: tokens, cacheWrite1h: 0, recordedCost: nil,
                                      project: SQLiteRead.text(row, 2) ?? message["path"]["root"].string))
        }
        // Older schemas have no session folder.
        if !SQLiteRead.query(db, "SELECT m.id, m.data, s.directory FROM message m LEFT JOIN session s ON s.id = m.session_id \(filter)",
                             since, row: row) {
            SQLiteRead.query(db, "SELECT m.id, m.data, NULL FROM message m \(filter)", since, row: row)
        }
        return entries
    }

    // MARK: Helpers

    /// "anthropic/claude-sonnet-4.5" → "claude-sonnet-4-5"; Bedrock's "us.anthropic.claude-sonnet-4-20250514-v1:0"
    /// → "claude-sonnet-4-20250514", so one model prices and lists the same through any router.
    static func modelID(_ raw: String) -> String {
        var id = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        if let vendor = id.range(of: "anthropic.") { id = String(id[vendor.upperBound...]) }
        id = id.replacing(/-v\d+:\d+$/, with: "")
        if id.hasPrefix("claude-") { id = id.replacing(".", with: "-") }
        return id
    }

    /// Epoch milliseconds, or an ISO-8601 string in some older tasks.
    private static func date(_ json: JSON) -> Date? {
        json.double.map { Date(timeIntervalSince1970: $0 / 1000) } ?? json.isoDate
    }
}
