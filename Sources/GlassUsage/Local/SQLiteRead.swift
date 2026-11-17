import Foundation
import SQLite3

/// Read-only access to other apps' SQLite databases, which may be open and mid-write.
nonisolated enum SQLiteRead {
    /// Opens `url` without ever writing to it; close with `sqlite3_close`. With a write-ahead log, opens
    /// read-only so its recent rows are read too. Without one (the writer closed cleanly), read-only would
    /// need to create `-shm`, so it opens immutable: nothing is pending.
    static func open(_ url: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        let hasLog = FileManager.default.fileExists(atPath: url.path + "-wal")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: hasLog ? "mode" : "immutable", value: hasLog ? "ro" : "1")]
        guard sqlite3_open_v2(components.string, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        sqlite3_busy_timeout(db, 1000)
        return db
    }

    /// Runs `sql` with `doubles` bound in order and calls `row` for each result.
    /// Returns false when the statement doesn't compile, e.g. against an older schema.
    @discardableResult
    static func query(_ db: OpaquePointer?, _ sql: String, _ doubles: Double..., row: (OpaquePointer) -> Void) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        for (index, value) in doubles.enumerated() { sqlite3_bind_double(statement, Int32(index + 1), value) }
        while sqlite3_step(statement) == SQLITE_ROW { row(statement) }
        return true
    }

    static func blob(_ row: OpaquePointer, _ column: Int32) -> ArraySlice<UInt8> {
        let count = Int(sqlite3_column_bytes(row, column))
        guard count > 0, let bytes = sqlite3_column_blob(row, column) else { return [] }
        return ArraySlice(UnsafeRawBufferPointer(start: bytes, count: count))
    }

    static func text(_ row: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(row, column).map { String(cString: $0) }
    }
}
