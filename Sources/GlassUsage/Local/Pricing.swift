import Foundation

/// Per-token list prices in USD.
nonisolated struct ModelPrice: Codable, Hashable, Sendable {
    let input: Double
    let output: Double
    let cacheRead: Double?
    let cacheWrite: Double?
    let cacheWrite1h: Double?
}

/// Model prices from LiteLLM's public catalog (the table ccusage uses), cached for a day,
/// with a small built-in table for offline first launches.
nonisolated struct PricingTable: Codable, Sendable {
    let prices: [String: ModelPrice]
    let fetchedAt: Date?

    func price(for model: String) -> ModelPrice? {
        var id = model.lowercased()
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        id = id.replacing(/\[[^\]]*\]$/, with: "")          // "claude-opus-4-6[1m]"
        if let price = prices[id] { return price }
        let undated = id.replacing(/-\d{8}$/, with: "")
        if let price = prices[undated] { return price }
        // Longest catalog id that prefixes the model ("gpt-5.1-codex-max-high" → "gpt-5.1-codex-max").
        let match = prices.keys.filter { undated.hasPrefix($0) }.max { $0.count < $1.count }
        if let match { return prices[match] }
        // A cached catalog from before a family was added still prices it from the built-in table.
        return fetchedAt == nil ? nil : Self.builtIn.price(for: model)
    }

    /// API-equivalent cost, or nil when the model isn't in the catalog.
    func cost(model: String, tokens: TokenCounts, cacheWrite1h: Int) -> Double? {
        guard let price = price(for: model) else { return nil }
        let write5m = tokens.cacheWrite - cacheWrite1h
        let writeRate = price.cacheWrite ?? price.input * 1.25
        let write1hRate = price.cacheWrite1h ?? writeRate * 1.6
        return Double(tokens.input) * price.input
            + Double(tokens.output) * price.output
            + Double(tokens.cacheRead) * (price.cacheRead ?? price.input * 0.1)
            + Double(write5m) * writeRate
            + Double(cacheWrite1h) * write1hRate
    }

    // MARK: Loading

    private static let catalogURL = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private static var cacheURL: URL { AppPaths.supportDirectory.appending(path: "pricing.json") }
    private static let maxAge: TimeInterval = 24 * 3600

    static func load() async -> PricingTable {
        let cached = (try? Data(contentsOf: cacheURL)).flatMap { try? JSONDecoder().decode(PricingTable.self, from: $0) }
        if let cached, let fetched = cached.fetchedAt, Date.now.timeIntervalSince(fetched) < maxAge {
            return cached
        }
        if let fresh = try? await fetchCatalog() {
            try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(fresh).write(to: cacheURL, options: .atomic)
            return fresh
        }
        return cached ?? builtIn
    }

    private static func fetchCatalog() async throws -> PricingTable {
        let (data, response) = try await HTTP.session.data(from: catalogURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.badServerResponse)
        }
        var prices: [String: ModelPrice] = [:]
        for (key, value) in catalog {
            // Only the families local agent logs contain. Bare ids only (no "bedrock/…" variants), except
            // Muse models, which LiteLLM lists only as "meta/muse-…".
            var id = key.lowercased()
            if id.hasPrefix("meta/muse-") { id.removeFirst("meta/".count) }
            guard !id.contains("/"),
                  ["claude-", "gpt-", "codex", "o3", "o4", "muse-"].contains(where: id.hasPrefix),
                  let entry = value as? [String: Any],
                  let input = entry["input_cost_per_token"] as? Double,
                  let output = entry["output_cost_per_token"] as? Double else { continue }
            prices[id] = ModelPrice(input: input, output: output,
                                    cacheRead: entry["cache_read_input_token_cost"] as? Double,
                                    cacheWrite: entry["cache_creation_input_token_cost"] as? Double,
                                    cacheWrite1h: entry["cache_creation_input_token_cost_above_1hr"] as? Double)
        }
        guard !prices.isEmpty else { throw URLError(.cannotParseResponse) }
        return PricingTable(prices: prices, fetchedAt: .now)
    }

    /// Snapshot of LiteLLM list prices (per token) for current families, used only when the catalog is unreachable.
    static let builtIn: PricingTable = {
        func p(_ input: Double, _ output: Double, _ read: Double, _ write: Double, _ write1h: Double) -> ModelPrice {
            ModelPrice(input: input / 1e6, output: output / 1e6, cacheRead: read / 1e6, cacheWrite: write / 1e6, cacheWrite1h: write1h / 1e6)
        }
        return PricingTable(prices: [
            "claude-fable-5-2": p(8, 40, 0.2, 10, 16),
            "claude-fable-5-1": p(10, 50, 0.25, 12.5, 20),
            "claude-fable-5": p(10, 50, 1, 12.5, 20),
            "claude-opus-5-5": p(4, 20, 0.2, 5, 8),
            "claude-opus-5": p(5, 25, 0.5, 6.25, 10),
            "claude-opus-4": p(5, 25, 0.5, 6.25, 10),
            "claude-sonnet-5-5": p(2, 10, 0.1, 2.5, 4),
            "claude-sonnet-5": p(2, 10, 0.2, 2.5, 4),
            "claude-sonnet-4": p(3, 15, 0.3, 3.75, 6),
            "claude-haiku-5-5": p(0.1, 0.5, 0.01, 0.125, 0.2),
            "claude-haiku-4-5": p(1, 5, 0.1, 1.25, 2),
            "gpt-5.2": p(1.75, 14, 0.175, 1.75, 1.75),
            "gpt-5.1-codex-mini": p(0.25, 2, 0.025, 0.25, 0.25),
            "gpt-5.1": p(1.25, 10, 0.125, 1.25, 1.25),
            "gpt-5": p(1.25, 10, 0.125, 1.25, 1.25),
            // Meta's list prices; Muse has no cache-write tariff, so writes bill as input.
            "muse-spark-1.3": p(1.25, 4.25, 0.15, 1.25, 1.25),
            "muse-spark-1.3-contributor": p(0.1, 0.2, 0.002, 0.1, 0.1),
            "muse-spark-1.2": p(1.25, 4.25, 0.15, 1.25, 1.25),
            "muse-spark-1.2-contributor": p(0.1, 0.2, 0.002, 0.1, 0.1),
            "muse-spark-1.1": p(1.25, 4.25, 0.15, 1.25, 1.25),
            "muse-wonder-1.0": p(4, 20, 0.2, 4, 4),
            "muse-ember-1.0": p(0.1, 0.5, 0.004, 0.1, 0.1),
        ], fetchedAt: nil)
    }()
}
