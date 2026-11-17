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
        _ = LogParsers.codex(try json(#"{"type":"session_meta","timestamp":"2026-11-16T10:00:00Z","payload":{"id":"s1","cwd":"/work/api"}}"#),
                             state: &state, fileStem: "rollout-a")
        _ = LogParsers.codex(try json(#"{"type":"turn_context","payload":{"model":"gpt-5.1-codex-max"}}"#),
                             state: &state, fileStem: "rollout-a")

        let first = try #require(try tokenCount(1000, 600, 50, at: 1))
        #expect(first.tokens == TokenCounts(input: 400, output: 50, cacheRead: 600, cacheWrite: 0), "cached input is inside input")
        #expect(first.model == "gpt-5.1-codex-max")
        #expect(first.project == "/work/api")

        #expect(try tokenCount(1000, 600, 50, at: 2) == nil, "a repeated snapshot adds nothing")

        let second = try #require(try tokenCount(1500, 900, 80, at: 3))
        #expect(second.tokens == TokenCounts(input: 200, output: 30, cacheRead: 300, cacheWrite: 0))
    }

    @Test func ompMessagesTakeTheSessionHeadersFolder() throws {
        var project: String?
        #expect(LogParsers.omp(try json(#"{"type":"session","version":3,"id":"s","cwd":"/work/app"}"#), project: &project) == nil)
        let entry = try #require(LogParsers.omp(try json("""
        {"type":"message","id":"m1","timestamp":"2026-11-16T10:00:00Z","message":{"role":"assistant","provider":"anthropic",\
        "model":"claude-opus-5-5","usage":{"input":10,"output":5,"cacheRead":0,"cacheWrite":0}}}
        """), project: &project))
        #expect(entry.project == "/work/app")
    }

    private func projectSummary(_ projects: [(String?, Int)]) -> [ProjectSpend] {
        let now = Date.now
        let entries = projects.enumerated().map { index, project in
            UsageEntry(key: "\(index)", at: now, provider: .claude, source: .omp, model: "unpriced-model",
                       tokens: TokenCounts(input: project.1, output: 0, cacheRead: 0, cacheWrite: 0),
                       cacheWrite1h: 0, recordedCost: nil, project: project.0)
        }
        return SpendSummary(reports: [LocalUsageReport.build(provider: .claude, entries: entries, pricing: .builtIn, days: 30, now: now)],
                            range: .today).projects
    }

    @Test func smallAndTemporaryProjectsFoldIntoOtherLast() {
        let projects = projectSummary([
            ("/w/a", 3000), ("/w/b", 2000), ("/w/c", 1000), ("/w/tiny", 10), (nil, 500),
            ("/private/var/folders/68/x/T/resume-llm", 400), ("/tmp/run", 100),
        ])
        #expect(projects.map(\.name) == ["a", "b", "c", "Other"], "below 1% and temporary folders aren't projects")
        #expect(projects.last?.tokens.total == 1010, "Other keeps their tokens so the rows add up")
    }

    @Test func projectRowsCapAtFiveIncludingOther() {
        let five = projectSummary((1...5).map { ("/w/p\($0)", 1000) })
        #expect(five.count == 5 && !five.contains { $0.path.isEmpty }, "five projects fit without an Other row")

        let six = projectSummary((1...6).map { ("/w/p\($0)", 1000 * $0) })
        #expect(six.map(\.name) == ["p6", "p5", "p4", "p3", "Other"])
        #expect(six.last?.tokens.total == 3000)
    }

    @Test func projectsRankAcrossProvidersWithDistinctNames() {
        let home = URL.homeDirectory.path
        let now = Date.now
        func entry(_ key: String, _ provider: ProviderID, _ project: String?, _ tokens: Int) -> UsageEntry {
            UsageEntry(key: key, at: now, provider: provider, source: .omp, model: "unpriced-model",
                       tokens: TokenCounts(input: tokens, output: 0, cacheRead: 0, cacheWrite: 0),
                       cacheWrite1h: 0, recordedCost: nil, project: project)
        }
        let entries = [
            entry("a", .claude, "\(home)/work/app", 300), entry("b", .codex, "\(home)/work/app", 200),
            entry("c", .claude, "\(home)/personal/app", 400), entry("d", .muse, nil, 100), entry("e", .claude, home, 50),
        ]
        let reports = [ProviderID.claude, .codex, .muse].map {
            LocalUsageReport.build(provider: $0, entries: entries, pricing: .builtIn, days: 30, now: now)
        }
        let projects = SpendSummary(reports: reports, range: .today).projects

        #expect(projects.map(\.name) == ["work/app", "personal/app", "~", "Other"], "one project across providers, Other last")
        #expect(projects.map(\.tokens.total) == [500, 400, 50, 100])
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
