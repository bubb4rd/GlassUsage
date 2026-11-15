import Foundation

/// Parses one session log line at a time. Lines arrive in file order; parsers that carry
/// state across lines (Codex) persist it in `FileState.codex` so appends parse incrementally.
nonisolated enum LogParsers {
    /// Byte patterns a line must contain to be worth decoding.
    static func needles(for source: LocalSource) -> [[UInt8]] {
        switch source {
        case .claudeCode, .omp: [Array(#""usage""#.utf8)]
        case .codexCLI: [Array("token_count".utf8), Array("turn_context".utf8), Array("session_meta".utf8)]
        }
    }

    // MARK: Claude Code (~/.claude/projects/**/*.jsonl)

    static func claudeCode(_ json: JSON) -> UsageEntry? {
        guard json["type"].string == "assistant" else { return nil }
        let message = json["message"]
        let usage = message["usage"]
        guard let model = message["model"].string, model != "<synthetic>", usage.exists,
              let at = json["timestamp"].isoDate else { return nil }
        let tokens = TokenCounts(input: usage["input_tokens"].int, output: usage["output_tokens"].int,
                                 cacheRead: usage["cache_read_input_tokens"].int,
                                 cacheWrite: usage["cache_creation_input_tokens"].int)
        guard tokens.total > 0 else { return nil }
        // Claude Code writes one line per content block, all carrying the same message usage.
        let key = if let id = message["id"].string, let request = json["requestId"].string {
            "cc:\(id):\(request)"
        } else {
            "cc:\(at.timeIntervalSince1970):\(tokens.total)"
        }
        return UsageEntry(key: key, at: at, provider: .claude, source: .claudeCode, model: model, tokens: tokens,
                          cacheWrite1h: usage["cache_creation"]["ephemeral_1h_input_tokens"].int,
                          recordedCost: json["costUSD"].double)
    }

    // MARK: omp (~/.omp/agent/sessions/**/*.jsonl)

    static func omp(_ json: JSON) -> UsageEntry? {
        guard json["type"].string == "message" else { return nil }
        let message = json["message"]
        let usage = message["usage"]
        guard message["role"].string == "assistant", usage.exists,
              let model = message["model"].string,
              let provider = provider(vendor: message["provider"].string, model: model),
              let at = json["timestamp"].isoDate else { return nil }
        let tokens = TokenCounts(input: usage["input"].int, output: usage["output"].int,
                                 cacheRead: usage["cacheRead"].int, cacheWrite: usage["cacheWrite"].int)
        guard tokens.total > 0 else { return nil }
        let recorded = usage["cost"]["total"].double.flatMap { $0 > 0 ? $0 : nil }
        // Forked sessions copy earlier entries verbatim (same id and timestamp).
        let key = "omp:\(json["id"].string ?? ""):\(json["timestamp"].string ?? ""):\(tokens.total)"
        return UsageEntry(key: key, at: at, provider: provider, source: .omp, model: model, tokens: tokens,
                          cacheWrite1h: usage["cttl"]["ephemeral1h"].int, recordedCost: recorded)
    }

    private static func provider(vendor: String?, model: String) -> ProviderID? {
        switch vendor {
        case "anthropic": return .claude
        case "openai-codex", "openai": return .codex
        default:
            let id = model.lowercased()
            if id.hasPrefix("claude") { return .claude }
            if id.hasPrefix("gpt-") || id.contains("codex") { return .codex }
            return nil
        }
    }

    // MARK: Codex CLI (~/.codex/sessions/**/rollout-*.jsonl)

    struct CodexState: Codable, Sendable {
        var model = "gpt-5"
        var rootID: String?
        var forkedAt: Date?
        /// Last cumulative [input, cached, output, reasoning, total].
        var lastTotals: [Int]?
    }

    static func codex(_ json: JSON, state: inout CodexState, fileStem: String) -> UsageEntry? {
        let payload = json["payload"]
        switch json["type"].string {
        case "session_meta":
            state.rootID = payload["forked_from_id"].string ?? payload["id"].string
            if payload["forked_from_id"].exists { state.forkedAt = json["timestamp"].isoDate }
            return nil
        case "turn_context":
            if let model = payload["model"].string { state.model = model }
            return nil
        case "event_msg" where payload["type"].string == "token_count":
            break
        default:
            return nil
        }

        let info = payload["info"]
        guard info.exists, let at = json["timestamp"].isoDate else { return nil }
        if let model = info["model"].string { state.model = model }
        func fields(_ node: JSON) -> [Int] {
            [node["input_tokens"].int, node["cached_input_tokens"].int + node["cache_read_input_tokens"].int,
             node["output_tokens"].int, node["reasoning_output_tokens"].int, node["total_tokens"].int]
        }

        let root = state.rootID ?? fileStem
        let usage: [Int]
        let key: String
        if info["total_token_usage"].exists {
            // Cumulative totals: take the delta, skipping repeated snapshots.
            let current = fields(info["total_token_usage"])
            let previous = state.lastTotals ?? [0, 0, 0, 0, 0]
            state.lastTotals = current
            guard current != previous else { return nil }
            let delta = zip(current, previous).map { $0 - $1 }
            usage = delta.allSatisfy { $0 >= 0 } ? delta : fields(info["last_token_usage"])
            key = "cx:\(root):\(current.map(String.init).joined(separator: ":"))"
        } else {
            usage = fields(info["last_token_usage"])
            key = "cx:\(root):last:\(json["timestamp"].string ?? ""):\(usage.map(String.init).joined(separator: ":"))"
        }
        // A fork replays its parent's history right after session_meta.
        if let forkedAt = state.forkedAt, at.timeIntervalSince(forkedAt) < 5 { return nil }

        // OpenAI counts cached tokens inside input, and reasoning inside output.
        let tokens = TokenCounts(input: max(usage[0] - usage[1], 0), output: usage[2], cacheRead: usage[1], cacheWrite: 0)
        guard tokens.total > 0 else { return nil }
        return UsageEntry(key: key, at: at, provider: .codex, source: .codexCLI, model: state.model, tokens: tokens,
                          cacheWrite1h: 0, recordedCost: nil)
    }
}

extension JSON {
    nonisolated var int: Int { double.map { Int($0) } ?? 0 }
}
