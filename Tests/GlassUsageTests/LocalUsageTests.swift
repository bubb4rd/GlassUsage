import Foundation
import Testing
@testable import GlassUsage

/// Token counting from local logs: dedupe keys, cumulative deltas, partial lines and day buckets.
@Suite struct LocalUsageTests {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    @Test func claudeCodeContentBlocksShareOneKey() throws {
        func line(_ block: String) throws -> JSON {
            try json("""
            {"type":"assistant","timestamp":"2026-11-16T10:00:00.123Z","requestId":"req_1","message":{"id":"msg_1",\
            "model":"claude-opus-5-5","content":[{"type":"\(block)"}],"usage":{"input_tokens":10,"output_tokens":20,\
            "cache_read_input_tokens":300,"cache_creation_input_tokens":40,"cache_creation":{"ephemeral_1h_input_tokens":40}}}}
            """)
        }
        let text = try #require(LogParsers.claudeCode(try line("text")))
        let tool = try #require(LogParsers.claudeCode(try line("tool_use")))

        #expect(text.key == tool.key, "one response is logged once per content block and must count once")
        #expect(text.tokens == TokenCounts(input: 10, output: 20, cacheRead: 300, cacheWrite: 40))
        #expect(text.cacheWrite1h == 40)
    }

    @Test func claudeCodeSyntheticMessagesDoNotCount() throws {
        let line = try json("""
        {"type":"assistant","timestamp":"2026-11-16T10:00:00Z","message":{"model":"<synthetic>","usage":{"input_tokens":5}}}
        """)
        #expect(LogParsers.claudeCode(line) == nil)
    }

    @Test func codexCountsDeltasOfCumulativeTotals() throws {
        var state = LogParsers.CodexState()
        func tokenCount(_ input: Int, _ cached: Int, _ output: Int, at second: Int) throws -> UsageEntry? {
            try LogParsers.codex(json("""
            {"type":"event_msg","timestamp":"2026-11-16T10:00:\(String(format: "%02d", second))Z","payload":{"type":"token_count",\
            "info":{"total_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),"output_tokens":\(output),"total_tokens":\(input + output)}}}}
            """), state: &state, fileStem: "rollout-a")
        }
        _ = LogParsers.codex(try json(#"{"type":"session_meta","timestamp":"2026-11-16T10:00:00Z","payload":{"id":"s1"}}"#),
                             state: &state, fileStem: "rollout-a")
        _ = LogParsers.codex(try json(#"{"type":"turn_context","payload":{"model":"gpt-5.1-codex-max"}}"#),
                             state: &state, fileStem: "rollout-a")

        let first = try #require(try tokenCount(1000, 600, 50, at: 1))
        #expect(first.tokens == TokenCounts(input: 400, output: 50, cacheRead: 600, cacheWrite: 0), "cached input is inside input")
        #expect(first.model == "gpt-5.1-codex-max")

        #expect(try tokenCount(1000, 600, 50, at: 2) == nil, "a repeated snapshot adds nothing")

        let second = try #require(try tokenCount(1500, 900, 80, at: 3))
        #expect(second.tokens == TokenCounts(input: 200, output: 30, cacheRead: 300, cacheWrite: 0))
    }

    @Test func codexForkSkipsReplayedHistory() throws {
        var state = LogParsers.CodexState()
        _ = LogParsers.codex(try json("""
        {"type":"session_meta","timestamp":"2026-11-16T10:00:00Z","payload":{"id":"child","forked_from_id":"parent"}}
        """), state: &state, fileStem: "rollout-b")
        let replay = try json("""
        {"type":"event_msg","timestamp":"2026-11-16T10:00:01Z","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":5000,"output_tokens":100,"total_tokens":5100}}}}
        """)
        #expect(LogParsers.codex(replay, state: &state, fileStem: "rollout-b") == nil)

        let fresh = try json("""
        {"type":"event_msg","timestamp":"2026-11-16T10:02:00Z","payload":{"type":"token_count",\
        "info":{"total_token_usage":{"input_tokens":5200,"output_tokens":130,"total_tokens":5330}}}}
        """)
        #expect(LogParsers.codex(fresh, state: &state, fileStem: "rollout-b")?.tokens.input == 200,
                "the first turn after the fork counts only what it added")
    }

    @Test func halfWrittenLastLineIsReadOnceComplete() {
        let needles = [Array("usage".utf8)]
        var lines: [String] = []
        let partial = Data(#"{"usage":1}\#n{"usage":2"#.utf8)
        let consumed = LocalUsageScanner.forEachLine(in: partial, from: 0, containingAny: needles) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }
        #expect(lines == [#"{"usage":1}"#])
        #expect(consumed == 12, "stops after the last newline")

        let complete = partial + Data("}\n{\"other\":3}\n".utf8)
        let end = LocalUsageScanner.forEachLine(in: complete, from: consumed, containingAny: needles) {
            lines.append(String(decoding: $0, as: UTF8.self))
        }
        #expect(lines == [#"{"usage":1}"#, #"{"usage":2}"#], "the finished line is read; lines without a needle are skipped")
        #expect(end == complete.count)
    }

    @Test func entriesLandOnTheirLocalDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Chicago"))
        func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
        }
        func entry(_ key: String, _ date: Date) -> UsageEntry {
            UsageEntry(key: key, at: date, provider: .claude, source: .claudeCode, model: "claude-opus-5-5",
                       tokens: TokenCounts(input: 1_000_000, output: 0, cacheRead: 0, cacheWrite: 0),
                       cacheWrite1h: 0, recordedCost: nil)
        }
        let report = LocalUsageReport.build(
            provider: .claude,
            entries: [entry("late", at(15, 23, 59)), entry("early", at(16, 0, 1)), entry("old", at(13, 12, 0))],
            pricing: .builtIn, days: 3, now: at(16, 9, 0), calendar: calendar)

        #expect(report.days.map(\.day) == [at(14, 0, 0), at(15, 0, 0), at(16, 0, 0)])
        #expect(report.days.map(\.tokens) == [0, 1_000_000, 1_000_000], "an entry before the first day is left out")
        #expect(abs((report.days.last?.cost ?? 0) - 4) < 1e-9, "priced from the built-in table at $4 per million input tokens")
        #expect(!report.hasUnpriced)
    }
}
