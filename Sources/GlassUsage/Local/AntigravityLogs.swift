import Foundation
import SQLite3

/// Token usage from Antigravity CLI conversations, one SQLite database per conversation in
/// `~/.gemini/antigravity-cli/conversations/<cascade>.db`.
///
/// `gen_metadata` holds one protobuf row per model call. Its field 1.4 is the usage record
/// (2 input without cache reads, 3 output including thinking, 4 cache writes, 5 cache reads,
/// 7 message id), 1.19 the model id, and the 1.20 labels include `last_step_index`. The call's
/// response is the step after that index, whose metadata (field 1) is a protobuf Timestamp.
nonisolated enum AntigravityLogs {
    static var conversationsDirectory: URL { AntigravityProvider.stateDirectory.appending(path: "conversations") }

    struct Generation: Equatable {
        let id: String?
        let model: String
        let tokens: TokenCounts
        let lastStepIndex: Int?
    }

    static func entries(in url: URL) -> [UsageEntry] {
        var db: OpaquePointer?
        // Read-only, not immutable: the CLI keeps recent calls in the write-ahead log.
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return []
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 1000)

        let conversation = url.deletingPathExtension().lastPathComponent
        var entries: [UsageEntry] = []
        query(db, "SELECT idx, data FROM gen_metadata ORDER BY idx") { row in
            guard let generation = generation(blob(row, 1)) else { return }
            let step = generation.lastStepIndex
            guard let at = step.flatMap({ stepTime(db, index: $0 + 1) ?? stepTime(db, index: $0) }) else { return }
            let key = "agy:" + (generation.id ?? "\(conversation):\(sqlite3_column_int64(row, 0))")
            entries.append(UsageEntry(key: key, at: at, provider: .antigravity, source: .antigravityCLI,
                                      model: generation.model, tokens: generation.tokens,
                                      cacheWrite1h: 0, recordedCost: nil))
        }
        return entries
    }

    /// One `gen_metadata.data` blob; nil when the call recorded no tokens (cancelled or failed).
    static func generation(_ blob: ArraySlice<UInt8>) -> Generation? {
        guard let call = ProtoMessage(blob).message(1), let usage = call.message(4) else { return nil }
        let tokens = TokenCounts(input: usage.int(2), output: usage.int(3),
                                 cacheRead: usage.int(5), cacheWrite: usage.int(4))
        guard tokens.total > 0, let model = call.string(19) ?? call.string(21) else { return nil }
        let lastStep = call.messages(20).first { $0.string(1) == "last_step_index" }?.string(2).flatMap { Int($0) }
        return Generation(id: usage.string(7) ?? usage.string(11), model: model, tokens: tokens, lastStepIndex: lastStep)
    }

    private static func stepTime(_ db: OpaquePointer?, index: Int) -> Date? {
        var time: Date?
        query(db, "SELECT metadata FROM steps WHERE idx = ?", bind: index) { row in
            guard let stamp = ProtoMessage(blob(row, 0)).message(1), let seconds = stamp.varint(1), seconds > 0 else { return }
            time = Date(timeIntervalSince1970: Double(seconds) + Double(stamp.varint(2) ?? 0) / 1e9)
        }
        return time
    }

    // MARK: SQLite

    private static func query(_ db: OpaquePointer?, _ sql: String, bind: Int? = nil, row: (OpaquePointer) -> Void) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return }
        defer { sqlite3_finalize(statement) }
        if let bind { sqlite3_bind_int64(statement, 1, Int64(bind)) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
    }

    private static func blob(_ row: OpaquePointer, _ column: Int32) -> ArraySlice<UInt8> {
        let count = Int(sqlite3_column_bytes(row, column))
        guard count > 0, let bytes = sqlite3_column_blob(row, column) else { return [] }
        return ArraySlice(UnsafeRawBufferPointer(start: bytes, count: count))
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
