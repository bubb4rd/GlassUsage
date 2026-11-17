import Foundation
import SQLite3

/// Token usage from Antigravity conversation databases, one SQLite file per conversation.
///
/// Usage records (2 input without cache reads, 3 output, 4 cache writes, 5 cache reads, 9/10 thinking
/// and response output, 1 model id, 11/12/7 response ids) appear in two tables, often both:
/// - `gen_metadata.data`: field 1 is the call; 1.4 its usage, 1.17[].2 retries, 1.19/1.21 model id and
///   name, 1.9.4 its time, and the 1.20 label `last_step_index` the step it answered.
/// - `steps.metadata`: 9 usage, 28[].2 retries, 24.12/24.8 model id and name, 8 or 1 its time.
/// `trajectory_metadata_blob.data` holds the conversation's start time (2) and workspace URI (7, also 1.1).
/// Copies of one call share a response id, so each is counted once.
nonisolated enum AntigravityLogs {
    /// T3 Code runs Antigravity with `GEMINI_HOME` at `<T3 home>/userdata/providers/antigravity/<sha256(instance id)>`,
    /// one profile per account, each keeping its history under `antigravity-acp/`.
    static var t3ProfilesDirectory: URL {
        let t3Home = ProcessInfo.processInfo.environment["T3CODE_HOME"].map { URL(fileURLWithPath: $0) }
            ?? URL.homeDirectory.appending(path: ".t3")
        return t3Home.appending(path: "userdata/providers/antigravity", directoryHint: .isDirectory)
    }

    /// The Antigravity CLI, desktop app and IDE share one conversation format, each in its own app data folder
    /// (`~/.gemini/antigravity-backup` only holds copies). Plus every T3 Code Antigravity account.
    static func conversationDirectories() -> [URL] {
        let gemini = URL.homeDirectory.appending(path: ".gemini", directoryHint: .isDirectory)
        var directories = ["antigravity-cli", "antigravity", "antigravity-ide"].map {
            gemini.appending(path: "\($0)/conversations", directoryHint: .isDirectory)
        }
        let profiles = (try? FileManager.default.contentsOfDirectory(at: t3ProfilesDirectory, includingPropertiesForKeys: nil)) ?? []
        for profile in profiles {
            directories.append(profile.appending(path: "antigravity-acp/conversations", directoryHint: .isDirectory))
        }
        return directories
    }

    struct Record: Equatable {
        let id: String?
        let modelID: Int
        /// Nil when the row names no model, or a retry ran a different model than its row.
        let model: String?
        let tokens: TokenCounts
    }

    struct Metadata: Equatable {
        var records: [Record]
        var at: Date?
        var lastStepIndex: Int?
        /// The row's own model, for naming model-less records elsewhere in the conversation.
        var modelID: Int
        var model: String?
    }

    static func entries(in url: URL) -> [UsageEntry] {
        guard let db = SQLiteRead.open(url) else { return [] }
        defer { sqlite3_close(db) }

        var tables = Set<String>()
        SQLiteRead.query(db, "SELECT name FROM sqlite_master WHERE type = 'table'") { row in
            if let name = SQLiteRead.text(row, 0) { tables.insert(name) }
        }
        var generations: [(idx: Int64, metadata: Metadata)] = []
        if tables.contains("gen_metadata") {
            SQLiteRead.query(db, "SELECT idx, data FROM gen_metadata ORDER BY idx") { row in
                if let metadata = generation(SQLiteRead.blob(row, 1)) { generations.append((sqlite3_column_int64(row, 0), metadata)) }
            }
        }
        var steps: [(idx: Int64, metadata: Metadata)] = []
        if tables.contains("steps") {
            SQLiteRead.query(db, "SELECT idx, metadata FROM steps WHERE metadata IS NOT NULL ORDER BY idx") { row in
                if let metadata = step(SQLiteRead.blob(row, 1)) { steps.append((sqlite3_column_int64(row, 0), metadata)) }
            }
        }
        var conversationTime: Date?
        var project: String?
        if tables.contains("trajectory_metadata_blob") {
            SQLiteRead.query(db, "SELECT data FROM trajectory_metadata_blob") { row in
                let metadata = ProtoMessage(SQLiteRead.blob(row, 0))
                conversationTime = conversationTime ?? metadata.message(2).flatMap(timestamp)
                project = project ?? workspace(metadata)
            }
        }
        conversationTime = conversationTime
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        guard let conversationTime else { return [] }

        let stepTimes = Dictionary(steps.map { ($0.idx, $0.metadata.at) }, uniquingKeysWith: { first, _ in first })
        var models: [Int: String] = [:]
        for (_, metadata) in generations + steps where metadata.modelID > 0 {
            if let model = metadata.model, models[metadata.modelID] == nil { models[metadata.modelID] = model }
        }

        let conversation = url.deletingPathExtension().lastPathComponent
        var seen = Set<String>()
        var entries: [UsageEntry] = []
        // Generations first: they name the model where steps from the Antigravity CLI don't.
        for (source, rows) in [("gen", generations), ("step", steps)] {
            for (idx, metadata) in rows {
                var at = metadata.at
                if at == nil, let last = metadata.lastStepIndex.map(Int64.init) {
                    at = (stepTimes[last + 1] ?? nil) ?? (stepTimes[last] ?? nil)
                }
                for (attempt, record) in metadata.records.enumerated() {
                    let key = "agy:" + (record.id ?? "\(conversation):\(source):\(idx):\(attempt)")
                    guard seen.insert(key).inserted else { continue }
                    let model = record.model ?? models[record.modelID]
                        ?? (record.modelID > 0 ? "antigravity-model-\(record.modelID)" : "antigravity")
                    entries.append(UsageEntry(key: key, at: at ?? conversationTime, provider: .antigravity,
                                              source: .antigravity, model: model, tokens: record.tokens,
                                              cacheWrite1h: 0, recordedCost: nil, project: project))
                }
            }
        }
        return entries
    }

    /// The folder a conversation ran in, from its `trajectory_metadata_blob` row.
    static func workspace(_ metadata: ProtoMessage) -> String? {
        guard let uri = metadata.string(7) ?? metadata.message(1)?.string(1),
              let url = URL(string: uri), url.isFileURL else { return nil }
        return url.path
    }

    /// One `gen_metadata.data` blob.
    static func generation(_ blob: ArraySlice<UInt8>) -> Metadata? {
        guard let call = ProtoMessage(blob).message(1) else { return nil }
        let placeholder = call.messages(20).first { $0.string(1) == "model_enum" }?.string(2)
        let model = modelName(id: call.string(19), name: call.string(21), placeholder: placeholder)
        let modelID = call.int(3) != 0 ? call.int(3) : call.message(4)?.int(1) ?? 0
        let lastStep = call.messages(20).first { $0.string(1) == "last_step_index" }?.string(2).flatMap { Int($0) }
        return Metadata(records: records(call, usage: 4, retries: 17, modelID: modelID, model: model),
                        at: call.message(9)?.message(4).flatMap(timestamp), lastStepIndex: lastStep,
                        modelID: modelID, model: model)
    }

    /// One `steps.metadata` blob.
    static func step(_ blob: ArraySlice<UInt8>) -> Metadata? {
        let step = ProtoMessage(blob)
        let info = step.message(24)
        let model = modelName(id: info?.string(12), name: info?.string(8))
        let modelID = info?.int(1) ?? 0
        return Metadata(records: records(step, usage: 9, retries: 28, modelID: modelID, model: model),
                        at: (step.message(8) ?? step.message(1)).flatMap(timestamp), lastStepIndex: nil,
                        modelID: modelID, model: model)
    }

    private static func records(_ row: ProtoMessage, usage: Int, retries: Int, modelID: Int, model: String?) -> [Record] {
        let usages = row.messages(usage) + row.messages(retries).compactMap { $0.message(2) }
        return usages.compactMap { usage in
            // Output includes thinking; take the parts' sum when a runtime reports only those.
            let tokens = TokenCounts(input: usage.int(2), output: max(usage.int(3), usage.int(9) + usage.int(10)),
                                     cacheRead: usage.int(5), cacheWrite: usage.int(4))
            guard tokens.total > 0 else { return nil }
            let usageModel = usage.int(1)
            return Record(id: usage.string(11) ?? usage.string(12) ?? usage.string(7),
                          modelID: usageModel != 0 ? usageModel : modelID,
                          model: usageModel == 0 || usageModel == modelID ? model : nil, tokens: tokens)
        }
    }

    /// Prefers a catalog-style id ("gemini-3.8-flash-n") and falls back to the display name
    /// ("Claude 5.5 Opus (Thinking)" → "claude-opus-5-5-thinking"), then to a known placeholder, skipping
    /// placeholders ("MODEL_…") and config ids ("gemini-pro-default") when that names the model.
    static func modelName(id: String?, name: String?, placeholder: String? = nil) -> String? {
        let candidates = [id, name].compactMap { raw -> String? in
            guard var model = raw?.trimmingCharacters(in: .whitespaces).lowercased(), !model.isEmpty else { return nil }
            model = model.replacing(/\s*\(([^)]*)\)$/) { "-\($0.1)" }.replacing(/\s+/, with: "-")
            if model.hasPrefix("claude-") {
                model = model.replacing(/^claude-(\d+(?:\.\d+)?)-(sonnet|opus|haiku)/) { "claude-\($0.2)-\($0.1)" }
                    .replacing(".", with: "-")
            }
            return model
        }
        return candidates.first { $0.contains(/^(?:gemini-\d|claude-(?:sonnet|opus|haiku)-\d|gpt-)/) }
            ?? placeholder.flatMap { placeholderModels[$0] }
            ?? candidates.first { !$0.hasPrefix("model_") && !$0.hasPrefix("model-") }
    }

    /// The desktop app names its models only by placeholder and config id ("gemini-pro-default"). These are
    /// its own catalog's models as of app 2.19.1 (per codeburn); a later build can repoint a placeholder.
    private static let placeholderModels: [String: String] = [
        "MODEL_PLACEHOLDER_M16": "gemini-3.1-pro-high",
        "MODEL_PLACEHOLDER_M37": "gemini-3.1-pro-high",
        "MODEL_PLACEHOLDER_M36": "gemini-3.1-pro-low",
        "MODEL_PLACEHOLDER_M84": "gemini-3.5-flash-high",
        "MODEL_PLACEHOLDER_M18": "gemini-3-flash",
        "MODEL_PLACEHOLDER_M35": "claude-sonnet-4-6",
        "MODEL_PLACEHOLDER_M26": "claude-opus-4-6-thinking",
    ]

    private static func timestamp(_ stamp: ProtoMessage) -> Date? {
        guard let seconds = stamp.varint(1), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(seconds) + Double(stamp.varint(2) ?? 0) / 1e9)
    }
}

/// Reads protobuf wire format without a schema. Malformed input ends the field list early.
nonisolated struct ProtoMessage {
    enum Value {
        case varint(UInt64)
        case bytes(ArraySlice<UInt8>)
    }

    private let bytes: ArraySlice<UInt8>

    init(_ bytes: ArraySlice<UInt8>) { self.bytes = bytes }

    func forEach(_ body: (Int, Value) -> Void) {
        var i = bytes.startIndex
        while i < bytes.endIndex {
            guard let key = readVarint(&i), key >> 3 > 0 else { return }
            let field = Int(key >> 3)
            switch key & 7 {
            case 0:
                guard let value = readVarint(&i) else { return }
                body(field, .varint(value))
            case 1, 5:
                let width = key & 7 == 1 ? 8 : 4
                guard bytes.endIndex - i >= width else { return }
                i += width
            case 2:
                guard let length = readVarint(&i), length <= UInt64(bytes.endIndex - i) else { return }
                let end = i + Int(length)
                body(field, .bytes(bytes[i..<end]))
                i = end
            default:
                return
            }
        }
    }

    /// Last occurrence, as protobuf merges repeated scalars.
    func varint(_ field: Int) -> UInt64? {
        var result: UInt64?
        forEach { if $0 == field, case .varint(let value) = $1 { result = value } }
        return result
    }

    func int(_ field: Int) -> Int { varint(field).map { Int(truncatingIfNeeded: $0) } ?? 0 }

    func message(_ field: Int) -> ProtoMessage? { messages(field).last }

    func messages(_ field: Int) -> [ProtoMessage] {
        var result: [ProtoMessage] = []
        forEach { if $0 == field, case .bytes(let value) = $1 { result.append(ProtoMessage(value)) } }
        return result
    }

    func string(_ field: Int) -> String? {
        message(field).map { String(decoding: $0.bytes, as: UTF8.self) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private func readVarint(_ i: inout ArraySlice<UInt8>.Index) -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while i < bytes.endIndex, shift < 64 {
            let byte = bytes[i]
            i += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte < 0x80 { return result }
            shift += 7
        }
        return nil
    }
}
