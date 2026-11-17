import Foundation

/// Agent tools whose local session logs GlassUsage reads for token counts.
nonisolated enum LocalSource: String, Codable, CaseIterable, Sendable {
    case claudeCode, codexCLI, antigravity, museCode, omp, cline, rooCode, kiloCode

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codexCLI: "Codex CLI"
        case .antigravity: "Antigravity"
        case .museCode: "Muse Code"
        case .omp: "omp"
        case .cline: "Cline"
        case .rooCode: "Roo Code"
        case .kiloCode: "Kilo Code"
        }
    }
}

nonisolated struct TokenCounts: Codable, Hashable, Sendable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite = 0

    var total: Int { input + output + cacheRead + cacheWrite }

    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheWrite += rhs.cacheWrite
    }
}

/// One model response read from a local log.
nonisolated struct UsageEntry: Codable, Hashable, Sendable {
    /// Cross-file dedupe key (forked sessions and streamed chunks repeat entries).
    let key: String
    let at: Date
    let provider: ProviderID
    let source: LocalSource
    let model: String
    let tokens: TokenCounts
    /// Portion of `cacheWrite` billed at the 1-hour cache rate (Anthropic).
    let cacheWrite1h: Int
    /// Cost the tool itself recorded, when it records one.
    let recordedCost: Double?
    /// Folder the session ran in, for tools whose logs record it (Claude Code, Codex CLI, omp).
    var project: String? = nil
}

nonisolated struct ModelUsage: Hashable, Sendable {
    let model: String
    var tokens = TokenCounts()
    var cost: Double = 0
    var unpricedTokens = 0
}

nonisolated struct ProjectUsage: Hashable, Sendable {
    var tokens = TokenCounts()
    var cost: Double = 0
}

nonisolated struct DayUsage: Identifiable, Hashable, Sendable {
    let day: Date
    var byModel: [String: ModelUsage] = [:]
    /// Keyed by project folder; "" collects usage from logs that don't record one.
    var byProject: [String: ProjectUsage] = [:]
    var id: Date { day }
    var cost: Double { byModel.values.reduce(0) { $0 + $1.cost } }
    var tokens: Int { byModel.values.reduce(0) { $0 + $1.tokens.total } }
}

/// Token and API-equivalent spend for one provider, per calendar day.
nonisolated struct LocalUsageReport: Sendable {
    let provider: ProviderID
    /// Oldest first, one per calendar day including empty days; the last one is today.
    let days: [DayUsage]
    let sources: [LocalSource]
    let hasUnpriced: Bool

    static func build(provider: ProviderID, entries: [UsageEntry], pricing: PricingTable,
                      days dayCount: Int, now: Date, calendar: Calendar = .current) -> LocalUsageReport {
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today)!
        var days: [Date: DayUsage] = [:]
        var sources = Set<LocalSource>()
        var hasUnpriced = false
        // Matching a model id against the catalog scans every key, so do it once per model, not per entry.
        var prices: [String: ModelPrice?] = [:]

        for entry in entries where entry.provider == provider && entry.at >= firstDay {
            let price: ModelPrice?
            if let known = prices[entry.model] {
                price = known
            } else {
                price = pricing.price(for: entry.model)
                prices[entry.model] = .some(price)
            }
            let cost = entry.recordedCost ?? price?.cost(tokens: entry.tokens, cacheWrite1h: entry.cacheWrite1h)
            if cost == nil { hasUnpriced = true }
            sources.insert(entry.source)
            let day = calendar.startOfDay(for: entry.at)
            var usage = days[day, default: DayUsage(day: day)].byModel[entry.model, default: ModelUsage(model: entry.model)]
            usage.tokens += entry.tokens
            if let cost { usage.cost += cost } else { usage.unpricedTokens += entry.tokens.total }
            days[day, default: DayUsage(day: day)].byModel[entry.model] = usage
            let project = entry.project.flatMap { ProjectNames.isTemporary($0) ? nil : $0 } ?? ""
            days[day, default: DayUsage(day: day)].byProject[project, default: ProjectUsage()].tokens += entry.tokens
            days[day, default: DayUsage(day: day)].byProject[project, default: ProjectUsage()].cost += cost ?? 0
        }

        let allDays = (0..<dayCount).map { offset -> DayUsage in
            let day = calendar.date(byAdding: .day, value: offset, to: firstDay)!
            return days[day] ?? DayUsage(day: day)
        }
        return LocalUsageReport(provider: provider, days: allDays,
                                sources: LocalSource.allCases.filter(sources.contains), hasUnpriced: hasUnpriced)
    }
}

nonisolated enum SpendRange: String, CaseIterable, Identifiable, Sendable {
    case today, week, month

    var id: String { rawValue }
    var dayCount: Int { switch self { case .today: 1; case .week: 7; case .month: 30 } }
    var label: String { switch self { case .today: "Today"; case .week: "7d"; case .month: "30d" } }
    var phrase: String { switch self { case .today: "today"; case .week: "last 7 days"; case .month: "last 30 days" } }
}

/// What the list under the spend chart ranks.
nonisolated enum SpendBreakdown: String, CaseIterable, Sendable {
    case models, projects

    var label: String { switch self { case .models: "Models"; case .projects: "Projects" } }
}

nonisolated struct ModelSpend: Identifiable, Sendable {
    let model: String
    let provider: ProviderID
    var tokens = TokenCounts()
    var cost: Double = 0
    var id: String { "\(provider.rawValue):\(model)" }
    var displayName: String { ModelNames.display(model) }
}

nonisolated struct ProjectSpend: Identifiable, Sendable {
    /// Project folder; "" for Other: logs without a folder, temporary folders, and projects too small for a row.
    let path: String
    var tokens = TokenCounts()
    var cost: Double = 0
    /// Folder name, with its parent when another project has the same name.
    var name = ""
    var id: String { path }
}

nonisolated struct DaySpend: Identifiable, Sendable {
    let day: Date
    var tokensByProvider: [ProviderID: Int] = [:]
    var cost: Double = 0
    /// Inside the selected range (the chart shows a week of context for "Today").
    let inRange: Bool
    var id: Date { day }
    var tokens: Int { tokensByProvider.values.reduce(0, +) }
}

/// Everything the spend sections show for one range, combined across providers.
nonisolated struct SpendSummary: Sendable {
    var tokens = TokenCounts()
    var cost: Double = 0
    /// Oldest first; at least a week so "Today" still has context.
    var days: [DaySpend] = []
    /// Highest token count first.
    var models: [ModelSpend] = []
    /// At most `projectRows`, highest token count first, adding up to the range: projects with at least
    /// `minProjectShare` of its tokens, then Other for the rest.
    var projects: [ProjectSpend] = []
    /// Providers with any usage in the chart, in fixed order.
    var providers: [ProviderID] = []
    var sources: [LocalSource] = []
    var hasUnpriced = false

    static let projectRows = 5
    /// Smaller projects fold into Other, so one-off folders don't take a row.
    static let minProjectShare = 0.01

    init(reports: [LocalUsageReport], range: SpendRange) {
        let chartCount = max(range.dayCount, 7)
        var byDay: [Date: DaySpend] = [:]
        var models: [String: ModelSpend] = [:]
        var projects: [String: ProjectSpend] = [:]
        var providers = Set<ProviderID>()
        var sources = Set<LocalSource>()

        for report in reports {
            sources.formUnion(report.sources)
            hasUnpriced = hasUnpriced || report.hasUnpriced
            let chartDays = report.days.suffix(chartCount)
            for (index, day) in chartDays.enumerated() {
                let inRange = index >= chartDays.count - range.dayCount
                var spend = byDay[day.day] ?? DaySpend(day: day.day, inRange: inRange)
                if day.tokens > 0 {
                    spend.tokensByProvider[report.provider, default: 0] += day.tokens
                    providers.insert(report.provider)
                }
                spend.cost += day.cost
                byDay[day.day] = spend
                guard inRange else { continue }
                cost += day.cost
                for usage in day.byModel.values {
                    tokens += usage.tokens
                    let key = "\(report.provider.rawValue):\(usage.model)"
                    models[key, default: ModelSpend(model: usage.model, provider: report.provider)].tokens += usage.tokens
                    models[key, default: ModelSpend(model: usage.model, provider: report.provider)].cost += usage.cost
                }
                for (path, usage) in day.byProject {
                    projects[path, default: ProjectSpend(path: path)].tokens += usage.tokens
                    projects[path, default: ProjectSpend(path: path)].cost += usage.cost
                }
            }
        }
        days = byDay.values.sorted { $0.day < $1.day }
        self.models = models.values.sorted { $0.tokens.total > $1.tokens.total }
        let ranked = projects.values.sorted { $0.tokens.total > $1.tokens.total }
        let minTokens = Double(tokens.total) * Self.minProjectShare
        let large = ranked.filter { !$0.path.isEmpty && Double($0.tokens.total) >= minTokens }
        let fitsAll = large.count == ranked.count && large.count <= Self.projectRows
        var shown = Array(large.prefix(fitsAll ? Self.projectRows : Self.projectRows - 1))
        if shown.count < ranked.count {
            let shownPaths = Set(shown.map(\.path))
            var other = ProjectSpend(path: "")
            for project in ranked where !shownPaths.contains(project.path) {
                other.tokens += project.tokens
                other.cost += project.cost
            }
            shown.append(other)
        }
        let names = ProjectNames.display(shown.map(\.path))
        self.projects = shown.map { project in var project = project; project.name = names[project.path] ?? project.path; return project }
        self.providers = ProviderID.allCases.filter(providers.contains)
        self.sources = LocalSource.allCases.filter(sources.contains)
    }
}

nonisolated enum ProjectNames {
    /// "/Users/me/SWE/app" → "app"; "work/app" and "personal/app" when two folders share a name;
    /// "~" for the home folder and "Other" for usage without a folder.
    static func display(_ paths: [String], home: String = URL.homeDirectory.path) -> [String: String] {
        func components(_ path: String) -> [Substring] { path.split(separator: "/") }
        let lastCounts = Dictionary(paths.map { (components($0).last.map(String.init) ?? "", 1) }, uniquingKeysWith: +)
        return Dictionary(uniqueKeysWithValues: paths.map { path -> (String, String) in
            if path.isEmpty { return (path, "Other") }
            if path == home { return (path, "~") }
            let parts = components(path)
            guard let last = parts.last else { return (path, path) }
            if lastCounts[String(last), default: 0] > 1, parts.count > 1 { return (path, "\(parts[parts.count - 2])/\(last)") }
            return (path, String(last))
        })
    }

    /// Scratch folders scripts run agents in (`$TMPDIR`, `/tmp`) aren't projects anyone would recognise.
    static func isTemporary(_ path: String) -> Bool {
        path == "/tmp" || path == "/private/tmp"
            || ["/tmp/", "/private/tmp/", "/var/folders/", "/private/var/folders/"].contains { path.hasPrefix($0) }
    }
}

nonisolated enum ModelNames {
    /// "claude-opus-5-5-20260101" → "Opus 5.5", "gpt-5.1-codex-max" → "GPT-5.1 Codex Max",
    /// "muse-spark-1.3-contributor" → "Muse Spark 1.3 Contributor", "gemini-4-hydrogen" → "Gemini 4 Hydrogen".
    static func display(_ model: String) -> String {
        var id = model.lowercased()
        if let slash = id.lastIndex(of: "/") { id = String(id[id.index(after: slash)...]) }
        id = id.replacing(/-\d{8}$/, with: "")

        if id.hasPrefix("claude-") {
            let parts = id.dropFirst("claude-".count).split(separator: "-")
            guard let family = parts.first else { return model }
            let version = parts.dropFirst().filter { $0.allSatisfy(\.isNumber) }.joined(separator: ".")
            return version.isEmpty ? family.capitalized : "\(family.capitalized) \(version)"
        }
        if id.hasPrefix("gpt-") {
            let parts = id.dropFirst("gpt-".count).split(separator: "-")
            guard let version = parts.first else { return model }
            return (["GPT-\(version)"] + parts.dropFirst().map { $0.capitalized }).joined(separator: " ")
        }
        if id.hasPrefix("muse-") || id.hasPrefix("gemini-") {
            return id.split(separator: "-").map { $0.first?.isNumber == true ? String($0) : $0.capitalized }.joined(separator: " ")
        }
        return model
    }
}
