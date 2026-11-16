import Foundation
import Testing
@testable import GlassUsage

/// Parsing of the provider payloads GlassUsage reads through CLIs and logs. The Antigravity payload is
/// a capture of `agy -p /usage --output-format json` (1.5.7); the Muse Code shapes come from
/// third-party integrations because Meta doesn't document them, so these pin what the app expects.
@Suite struct ProviderParsingTests {
    private func json(_ text: String) throws -> JSON { try JSON(data: Data(text.utf8)) }

    @Test func antigravityGroupsBecomeGroupedWindows() throws {
        let data = try json("""
        {"groups": [
          {"name": "Gemini Models", "buckets": [
            {"id": "gemini-weekly", "window": "weekly", "remaining_fraction": 0.75, "reset_time": "2026-11-22T22:36:04Z"},
            {"id": "gemini-5h", "window": "5h", "remaining_fraction": 0.1, "reset_time": "2026-11-16T03:36:04Z"}]},
          {"name": "Claude and GPT models", "buckets": [
            {"id": "3p-weekly", "window": "weekly", "remaining_fraction": 1, "reset_time": "2026-11-22T22:36:04Z"},
            {"id": "3p-5h", "window": "5h", "remaining_fraction": 1, "reset_time": "2026-11-16T03:36:04Z"}]},
          {"name": "Gemini 4 Argon", "buckets": [
            {"id": "gemini-argon-wtu-weekly", "window": "weekly", "remaining_fraction": 0.5, "reset_time": "2026-11-22T22:36:04Z"}]}
        ]}
        """)
        let snapshot = try AntigravityProvider.parseUsage(data, fetchedAt: .now)

        #expect(snapshot.groups == ["Gemini", "Claude and GPT", "Gemini 4 Argon"])
        #expect(snapshot.windows.count == 5)
        #expect(Set(snapshot.windows.map(\.id)).count == 5, "window ids must stay unique across groups")

        let gemini = snapshot.windows.filter { $0.group == "Gemini" }
        #expect(gemini.map(\.key) == ["session", "weekly"], "shortest window first within a group")
        #expect(gemini.map(\.percent) == [90, 25])
        #expect(gemini.first?.duration == 18_000)
        #expect(gemini.first?.resetsAt == Date(timeIntervalSince1970: 1_794_800_164))

        // The menu bar ring follows the group closest to its limit.
        #expect(snapshot.mostConstrained?.id == "Gemini/session")
        #expect(snapshot.iconWindows.map(\.id) == ["Gemini/session", "Gemini/weekly"])
    }

    @Test func antigravityWithoutBucketsHasNoQuota() throws {
        #expect(throws: ProviderError.self) {
            try AntigravityProvider.parseUsage(try json(#"{"groups": []}"#), fetchedAt: .now)
        }
    }

    private func bytes(_ hex: String) -> ArraySlice<UInt8> {
        ArraySlice(stride(from: 0, to: hex.count, by: 2).map {
            let start = hex.index(hex.startIndex, offsetBy: $0)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        })
    }

    /// A `gen_metadata.data` row from Antigravity CLI 1.5.9, trimmed to the fields GlassUsage reads.
    @Test func antigravityGenerationSeparatesCacheReadsFromInput() throws {
        let row = bytes("0ac601225708f50b10f05618d21128946c30183a28626f742d62366566383335392d303634632d343435352d383633622d37363364333264323364386348f10650e10a5a1731597a37616f4b32475a5849694c4d50796347733641499a011167656d696e692d342d687964726f67656ea201240a0a6d6f64656c5f656e756d12164d4f44454c5f504c414345484f4c4445525f4d353235a201140a0f6c6173745f737465705f696e646578120132aa011847656d696e69203420487964726f67656e20284869676829")
        let generation = try #require(AntigravityLogs.generation(row))
        #expect(generation.model == "gemini-4-hydrogen")
        #expect(generation.tokens == TokenCounts(input: 11120, output: 2258, cacheRead: 13844, cacheWrite: 0),
                "output already includes the 881 thinking tokens")
        #expect(generation.lastStepIndex == 2)
        #expect(generation.id == "bot-b6ef8359-064c-4455-863b-763d32d23d8c")
    }

    @Test func antigravityCancelledGenerationHasNoUsage() {
        #expect(AntigravityLogs.generation(bytes("0a05220308a70a")) == nil)
    }

    @Test func antigravityFlashPricesWithoutTheCatalog() throws {
        let price = try #require(PricingTable.builtIn.price(for: "gemini-3.8-flash-n"))
        #expect(price.output == 3.75 / 1e6)
    }

    @Test func museAllowanceMapsToSessionAndWeek() throws {
        let snapshot = try MuseProvider.parseUsage(try json("""
        {"schema": 1, "allowance": {"tier": "Muse Code Power Usage",
          "window": {"usedPercent": 24, "resetsAtMs": 1763030400000},
          "weekly": {"usedPercent": 61, "resetsAtMs": 1763337600000}}}
        """), fetchedAt: .now)

        #expect(snapshot.plan == "Power")
        #expect(snapshot.windows.map(\.key) == ["session", "weekly"])
        #expect(snapshot.windows.map(\.percent) == [24, 61])
        let durations: [TimeInterval] = [18_000, 604_800]
        #expect(snapshot.windows.map(\.duration) == durations)
        #expect(snapshot.windows.first?.resetsAt == Date(timeIntervalSince1970: 1_763_030_400))
    }

    @Test func museIdleSessionWindowLeavesWeekOnly() throws {
        let snapshot = try MuseProvider.parseUsage(try json("""
        {"allowance": {"tier": "Muse Code Everyday Usage", "weekly": {"usedPercent": 12, "resetsAtMs": 1763337600000}}}
        """), fetchedAt: .now)
        #expect(snapshot.windows.map(\.key) == ["weekly"])
    }

    @Test func museWithoutAllowanceIsNotZeroPercent() throws {
        #expect(throws: ProviderError.self) {
            try MuseProvider.parseUsage(try json(#"{"allowance": null, "reason": "api_key"}"#), fetchedAt: .now)
        }
    }

    @Test func museLogCountsCachedInsideInput() throws {
        let line = try json("""
        {"schema_version":1,"stream":{"kind":"session","id":"01a0b7d1"},"sequence":39,"recorded_at":1789790455896395,\
        "payload_type":"runtime.session","payload":{"kind":"run","event":{"kind":"model_completed",\
        "usage":{"input_tokens":26964,"output_tokens":379,"cached_tokens":5105,"cache_write_tokens":0,"cache_read_tokens":5105,"reasoning_tokens":278},\
        "duration_ms":5819,"model":"muse-spark-1.3-contributor"}}}
        """)
        let entry = try #require(LogParsers.muse(line, sessionID: "dir-name"))

        #expect(entry.provider == .muse)
        #expect(entry.model == "muse-spark-1.3-contributor")
        #expect(entry.tokens == TokenCounts(input: 26964 - 5105, output: 379, cacheRead: 5105, cacheWrite: 0))
        #expect(abs(entry.at.timeIntervalSince1970 - 1_789_790_455.896) < 0.001)
        #expect(entry.key.hasPrefix("muse:01a0b7d1:39:"), "dedupe on the stream id and sequence")
    }

    @Test func museLogIgnoresOtherEvents() throws {
        let line = try json("""
        {"recorded_at":1789790455896395,"payload":{"event":{"kind":"workflow_child_lifecycle","model":"muse-spark-1.3",\
        "usage":{"input_tokens":10,"output_tokens":5}}}}
        """)
        #expect(LogParsers.muse(line, sessionID: "s") == nil)
    }

    @Test func museModelsPriceWithoutTheCatalog() throws {
        let price = try #require(PricingTable.builtIn.price(for: "muse-spark-1.3-contributor"))
        #expect(price.input == 0.1 / 1e6, "contributor must not fall back to the 12x pricier base model")
    }
}
