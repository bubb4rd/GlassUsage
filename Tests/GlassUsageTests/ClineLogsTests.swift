import Foundation
import SQLite3
import Testing
@testable import GlassUsage

/// Cline, Roo Code and Kilo Code logs, laid out as the extensions write them (record shapes from their
/// sources and tokscale's fixtures).
@Suite struct ClineLogsTests {
    private let root = FileManager.default.temporaryDirectory.appending(path: "ClineLogsTests-\(UUID().uuidString)")

    private func write(_ text: String, to path: String) throws -> URL {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// An `api_req_started` message; `text` is its usage as a JSON string.
    private func request(ts: Int, _ usage: String, extra: String = "") -> String {
        let text = usage.replacing("\"", with: "\\\"")
        return #"{"type":"say","say":"api_req_started","ts":\#(ts),"text":"\#(text)"\#(extra)}"#
    }

    @Test func rooTasksTakeModelAndFolderFromTheirConversation() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let task = "rooveterinaryinc.roo-cline/tasks/t1"
        let messages = try write("[" + [
            // 2025-12: tokensIn includes the cache.
            request(ts: 1_765_000_000_000, #"{"tokensIn":1000,"tokensOut":10,"cacheReads":600,"cacheWrites":100,"cost":0.5,"apiProtocol":"anthropic"}"#),
            // 2025-10, Anthropic protocol: tokensIn was still without the cache.
            request(ts: 1_760_000_000_000, #"{"tokensIn":1000,"tokensOut":10,"cacheReads":600,"cacheWrites":100,"apiProtocol":"anthropic"}"#),
            // Still streaming: no usage yet.
            request(ts: 1_765_000_000_001, #"{"apiProtocol":"anthropic"}"#),
            #"{"type":"say","say":"text","ts":1765000000002,"text":"done"}"#,
        ].joined(separator: ",") + "]", to: "\(task)/ui_messages.json")
        _ = try write(#"[{"role":"user","content":[{"type":"text","text":"<environment_details>\n<model>anthropic/claude-sonnet-4.5</model>\n</environment_details>"}]}]"#,
                      to: "\(task)/api_conversation_history.json")
        _ = try write(#"{"id":"t1","workspace":"/work/app","tokensIn":2000}"#, to: "\(task)/history_item.json")

        let entries = ClineLogs.taskEntries(in: messages, source: .rooCode)

        #expect(entries.map(\.tokens) == [TokenCounts(input: 300, output: 10, cacheRead: 600, cacheWrite: 100),
                                          TokenCounts(input: 1000, output: 10, cacheRead: 600, cacheWrite: 100)])
        #expect(entries.allSatisfy { $0.model == "claude-sonnet-4-5" && $0.provider == .claude && $0.project == "/work/app" })
        #expect(entries.first?.recordedCost == 0.5)
        #expect(entries.first?.key == "rooCode:t1:1765000000000")
    }

    @Test func clineTasksKeepCacheApartAndSkipClaudeCode() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let messages = try write("[" + [
            request(ts: 1_765_000_000_000, #"{"tokensIn":40,"tokensOut":15,"cacheReads":7,"cacheWrites":3,"cost":0.05}"#,
                    extra: #","modelInfo":{"providerId":"anthropic","modelId":"claude-opus-4-6","mode":"act"}"#),
            // Run through the Claude Code CLI, which logs the call itself.
            request(ts: 1_765_000_000_100, #"{"tokensIn":40,"tokensOut":15}"#,
                    extra: #","modelInfo":{"providerId":"claude-code","modelId":"claude-opus-4-6"}"#),
            // A model outside the tracked plans.
            request(ts: 1_765_000_000_200, #"{"tokensIn":40,"tokensOut":15}"#,
                    extra: #","modelInfo":{"providerId":"openrouter","modelId":"deepseek/deepseek-v3.2"}"#),
        ].joined(separator: ",") + "]", to: "data/tasks/c1/ui_messages.json")
        _ = try write(#"[{"id":"c0","cwdOnTaskInitialization":"/elsewhere"},{"id":"c1","cwdOnTaskInitialization":"/work/api"}]"#,
                      to: "data/state/taskHistory.json")

        let entries = ClineLogs.taskEntries(in: messages, source: .cline)

        #expect(entries.count == 1)
        #expect(entries.first?.tokens == TokenCounts(input: 40, output: 15, cacheRead: 7, cacheWrite: 3), "Cline's tokensIn never includes the cache")
        #expect(entries.first?.project == "/work/api")
        #expect(entries.first?.model == "claude-opus-4-6")
    }

    @Test func clineSessionsSubtractTheCacheAndReadTheirManifest() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write(#"{"version":1,"session_id":"s1","provider":"openai-native","model":"gpt-5.2","cwd":"/work/api/sub","workspace_root":"/work/api"}"#,
                      to: "sessions/s1/s1.json")
        let messages = try write("""
        {"version":1,"sessionId":"s1","agent":"lead","messages":[
         {"id":"u1","role":"user","ts":1785320470000,"content":[{"type":"text","text":"hi"}]},
         {"id":"a1","role":"assistant","ts":1785320475705,"metrics":{"inputTokens":7507,"outputTokens":131,"cacheReadTokens":50,"cacheWriteTokens":0,"cost":0.011}},
         {"id":"a2","role":"assistant","ts":1785320480000,"modelInfo":{"id":"anthropic/claude-sonnet-4.5","provider":"openrouter"},
          "metrics":{"inputTokens":100,"outputTokens":5,"cacheReadTokens":60,"cacheWriteTokens":10}}]}
        """, to: "sessions/s1/s1.messages.json")

        let entries = ClineLogs.sessionEntries(in: messages)

        #expect(entries.map(\.model) == ["gpt-5.2", "claude-sonnet-4-5"], "the manifest's model until a message names another")
        #expect(entries.map(\.provider) == [.codex, .claude])
        #expect(entries.map(\.tokens.input) == [7457, 30])
        #expect(entries.allSatisfy { $0.project == "/work/api" })
        #expect(entries.first?.key == "cline:s1:a1")
    }

    @Test func kiloDatabaseCountsReasoningAsOutputWithinTheRange() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appending(path: "kilo.db")
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        func exec(_ sql: String) { #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK) }
        exec("CREATE TABLE session (id TEXT PRIMARY KEY, directory TEXT NOT NULL)")
        exec("CREATE TABLE message (id TEXT PRIMARY KEY, session_id TEXT NOT NULL, data TEXT NOT NULL)")
        exec("INSERT INTO session VALUES ('s1', '/work/kilo')")
        func message(_ id: String, _ data: String) { exec("INSERT INTO message VALUES ('\(id)', 's1', '\(data)')") }
        message("m1", #"{"role":"assistant","modelID":"anthropic/claude-sonnet-4","providerID":"kilo","tokens":{"input":1200,"output":300,"reasoning":40,"cache":{"read":75,"write":25}},"time":{"created":1765000000000}}"#)
        message("m2", #"{"role":"user","time":{"created":1765000000001}}"#)
        // Imported from an older Kilo: no tokens.
        message("m3", #"{"role":"assistant","modelID":"legacy","tokens":{"input":0,"output":0,"cache":{"read":0,"write":0}},"time":{"created":1765000000002}}"#)
        // Before the report range.
        message("m4", #"{"role":"assistant","modelID":"claude-sonnet-4","tokens":{"input":5,"output":5},"time":{"created":1700000000000}}"#)
        sqlite3_close(db)

        let entries = ClineLogs.kiloEntries(in: url, since: Date(timeIntervalSince1970: 1_764_000_000))

        #expect(entries.count == 1)
        #expect(entries.first?.tokens == TokenCounts(input: 1200, output: 340, cacheRead: 75, cacheWrite: 25))
        #expect(entries.first?.project == "/work/kilo")
        #expect(entries.first?.provider == .claude)
    }

    @Test func routedModelIDsMatchTheirDirectName() {
        #expect(ClineLogs.modelID("anthropic/claude-sonnet-4.5") == "claude-sonnet-4-5")
        #expect(ClineLogs.modelID("us.anthropic.claude-sonnet-4-20250514-v1:0") == "claude-sonnet-4-20250514")
        #expect(ClineLogs.modelID("openai/gpt-5.2") == "gpt-5.2")
    }
}
