import SwiftUI

/// Token spend for the selected range: totals share the range picker's row, then the days drawn as a
/// ledger (one bar per day) or a calendar (weeks by weekday), then the token mix and top models.
struct SpendSection: View {
    let summary: SpendSummary
    @Binding var range: SpendRange
    @Binding var breakdown: SpendBreakdown
    let style: SpendView
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                totals
                Spacer(minLength: 4)
                PillPicker(options: SpendRange.allCases.map { ($0, $0.label) }, selection: $range)
            }
            .frame(height: 26)

            if isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 64)
            } else if !summary.hasChartUsage {
                Text("Token counts from Claude Code, Codex CLI, Muse Code and omp logs show up here after your first session.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } else {
                switch style {
                case .ledger: SpendLedger(summary: summary, range: range, breakdown: $breakdown)
                case .calendar: SpendCalendar(summary: summary, range: range, breakdown: $breakdown)
                }
            }
        }
    }

    @ViewBuilder
    private var totals: some View {
        if isLoading {
            EmptyView()
        } else if !summary.hasChartUsage {
            Text("No usage \(range.inPhrase)").font(.system(size: 12.5)).foregroundStyle(.secondary)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Format.tokens(summary.tokens.total))
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .contentTransition(.numericText())
                Text(Format.usd(summary.cost))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                    .underline(pattern: .dot, color: Color.primary.opacity(0.22))
                    .contentTransition(.numericText())
                    .help(costNote)
            }
            .monospacedDigit()
            .animation(.smooth(duration: 0.3), value: summary.tokens.total)
        }
    }

    private var costNote: String {
        var note = "Tokens priced at API list rates (LiteLLM). Subscriptions bill differently."
        if !summary.sources.isEmpty { note += " From \(summary.sources.map(\.displayName).formatted())." }
        if summary.hasUnpriced { note += " Some models have no list price and count as $0." }
        return note
    }
}

// MARK: Ledger

/// One column per day stacked by provider, spanning the full width with the peak labelled above the
/// top rule, and a date axis that turns into the hovered day's numbers.
private struct SpendLedger: View {
    let summary: SpendSummary
    let range: SpendRange
    @Binding var breakdown: SpendBreakdown

    @State private var hovered: Date?
    @Environment(\.revealDelay) private var base
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let chartHeight: CGFloat = 52

    var body: some View {
        let peak = max(summary.days.map(\.tokens).max() ?? 0, 1)
        let spacing: CGFloat = summary.days.count > 14 ? 2 : 4
        // Columns grow from the baseline left to right, the whole sweep within a quarter second.
        let stagger = min(0.015, 0.25 / Double(max(summary.days.count, 1)))
        VStack(alignment: .leading, spacing: 0) {
            Revealing { grown in
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(summary.days.enumerated()), id: \.element.id) { index, day in
                        DayBar(day: day, providers: summary.providers,
                               height: Self.chartHeight * Double(day.tokens) / Double(peak),
                               progress: grown || reduceMotion ? 1 : 0)
                            .animation(Motion.curve(grown, Motion.draw, delay: base + 0.05 + stagger * Double(index)), value: grown)
                            .frame(maxWidth: .infinity, maxHeight: Self.chartHeight, alignment: .bottom)
                            .opacity(day.inRange ? 1 : 0.55)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { hovered = day.id } else if hovered == day.id { hovered = nil }
                            }
                            .accessibilityElement()
                            .accessibilityLabel(day.readout)
                    }
                }
            }
            .frame(height: Self.chartHeight)
            .overlay(alignment: .top) {
                HorizontalRule()
                    .stroke(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 0.5, dash: [2, 2]))
                    .frame(height: 0.5)
            }
            .overlay(alignment: .topTrailing) {
                Text(Format.tokens(peak))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
                    .alignmentGuide(.top) { $0[.bottom] + 2 }
            }
            .padding(.top, 16)

            axis(spacing: spacing)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(height: 12)
                .padding(.top, 5)

            HStack(spacing: 10) {
                if summary.tokens.total > 0 {
                    Text("\(emphasis(Format.tokens(summary.tokens.output))) output · \(emphasis(share(summary.tokens.cacheRead, of: summary.tokens.total))) from cache")
                        .help(mixNote(summary.tokens))
                } else {
                    Text("No usage \(range.inPhrase) yet")
                }
                Spacer(minLength: 0)
                if summary.providers.count > 1 { ProviderLegend(providers: summary.providers) }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .padding(.top, 10)

            BreakdownRows(summary: summary, breakdown: $breakdown).padding(.top, 8)
        }
        .monospacedDigit()
    }

    @ViewBuilder
    private func axis(spacing: CGFloat) -> some View {
        if let day = summary.days.first(where: { $0.id == hovered }) {
            Text(day.readout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
        } else if summary.days.count > 7, let first = summary.days.first {
            HStack {
                Text(first.shortDate)
                Spacer()
                Text(summary.days[summary.days.count / 2].shortDate)
                Spacer()
                Text("Today")
            }
        } else {
            HStack(spacing: spacing) {
                ForEach(summary.days) { day in
                    let today = Calendar.current.isDateInToday(day.day)
                    Text(day.day.formatted(.dateTime.weekday(.narrow)))
                        .fontWeight(today ? .semibold : .regular)
                        .foregroundStyle(today ? .secondary : .tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// A day's column, stacked by provider; empty days keep a baseline stub so the timeline stays readable.
private struct DayBar: View {
    let day: DaySpend
    let providers: [ProviderID]
    let height: CGFloat
    /// 0 folds the column to its baseline, 1 draws it at full height.
    let progress: CGFloat

    var body: some View {
        let segments = day.segments(providers)
        if height < 1 || segments.isEmpty {
            Capsule().fill(Theme.track).frame(height: 2).opacity(progress)
        } else {
            let slit: CGFloat = segments.count > 1 && height >= CGFloat(segments.count) * 4 ? 1 : 0
            let inner = height - slit * CGFloat(segments.count - 1)
            VStack(spacing: slit) {
                ForEach(segments, id: \.provider) { segment in
                    Rectangle()
                        .fill(Theme.color(for: segment.provider))
                        .frame(height: inner * Double(segment.tokens) / Double(day.tokens) * progress)
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
        }
    }
}

private struct HorizontalRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        }
    }
}

// MARK: Calendar

/// Weeks by weekday, each day shaded by its tokens, with each week's in-range total on the right.
/// Days outside the range stay gray for context.
private struct SpendCalendar: View {
    let summary: SpendSummary
    let range: SpendRange
    @Binding var breakdown: SpendBreakdown

    @State private var hovered: Date?
    @Environment(\.revealDelay) private var base
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let labelWidth: CGFloat = 40
    private static let cellWidth: CGFloat = 19
    private static let cellSpacing: CGFloat = 3

    private enum Slot {
        case empty, future, day(DaySpend)
    }

    private struct Week: Identifiable {
        let start: Date
        let slots: [Slot]
        var id: Date { start }

        var inRangeDays: [DaySpend] {
            slots.compactMap { slot in
                if case .day(let day) = slot, day.inRange { return day }
                return nil
            }
        }
    }

    var body: some View {
        let weeks = weeks()
        let peak = max(summary.days.map(\.tokens).max() ?? 0, 1)
        let cellHeight: CGFloat = weeks.count > 2 ? 14 : 20
        Revealing { grown in grid(weeks: weeks, peak: peak, cellHeight: cellHeight, grown: grown) }
    }

    private func grid(weeks: [Week], peak: Int, cellHeight: CGFloat, grown: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 0) {
                Color.clear.frame(width: Self.labelWidth, height: 1)
                HStack(spacing: Self.cellSpacing) {
                    ForEach(Array(weekdayLetters.enumerated()), id: \.offset) { _, letter in
                        Text(letter).frame(width: Self.cellWidth)
                    }
                }
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.tertiary)

            ForEach(Array(weeks.enumerated()), id: \.element.id) { index, week in
                weekRow(week, index: index, peak: peak, cellHeight: cellHeight, grown: grown)
            }

            readout.padding(.top, 2)

            if !summary.models.isEmpty {
                Rectangle().fill(Theme.hair).frame(height: 0.5).padding(.top, 5).padding(.bottom, 3)
                BreakdownRows(summary: summary, breakdown: $breakdown)
            }
            if summary.tokens.total > 0 {
                chips.padding(.top, 7)
            }
        }
        .padding(.top, 10)
        .monospacedDigit()
    }

    /// Cells pop in along a diagonal wave from the first week's first day.
    private func weekRow(_ week: Week, index: Int, peak: Int, cellHeight: CGFloat, grown: Bool) -> some View {
        HStack(spacing: 0) {
            Text(week.start.formatted(.dateTime.month(.abbreviated).day()))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            HStack(spacing: Self.cellSpacing) {
                ForEach(Array(week.slots.enumerated()), id: \.offset) { offset, slot in
                    cell(slot, peak: peak, height: cellHeight)
                        .frame(width: Self.cellWidth, height: cellHeight)
                        .scaleEffect(grown || reduceMotion ? 1 : 0.4)
                        .opacity(grown ? 1 : 0)
                        .animation(Motion.curve(grown, Motion.enter, delay: base + 0.04 + 0.025 * Double(index + offset)),
                                   value: grown)
                }
            }
            Spacer(minLength: 4)
            let days = week.inRangeDays
            if !days.isEmpty {
                let tokens = days.reduce(0) { $0 + $1.tokens }
                let cost = days.reduce(0) { $0 + $1.cost }
                HStack(spacing: 8) {
                    Text(Format.tokens(tokens))
                        .fontWeight(tokens > 0 ? .semibold : .regular)
                        .frame(width: SpendColumn.tokens, alignment: .trailing)
                    Text(Format.usd(cost))
                        .foregroundStyle(.secondary)
                        .frame(width: SpendColumn.cost, alignment: .trailing)
                }
                .font(.system(size: 11.5))
                .opacity(tokens > 0 ? 1 : 0.45)
            }
        }
    }

    @ViewBuilder
    private func cell(_ slot: Slot, peak: Int, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        switch slot {
        case .empty:
            Color.clear
        case .future:
            shape.strokeBorder(Theme.hair, lineWidth: 0.5)
        case .day(let day):
            let intensity = day.tokens > 0 ? 0.22 + 0.78 * pow(Double(day.tokens) / Double(peak), 0.7) : 0
            VStack(spacing: 0) {
                ForEach(day.segments(summary.providers), id: \.provider) { segment in
                    Rectangle()
                        .fill(day.inRange ? Theme.color(for: segment.provider) : Color.primary)
                        .opacity(day.inRange ? intensity : intensity * 0.45)
                        .frame(height: height * Double(segment.tokens) / Double(day.tokens))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
            .background(Theme.track)
            .clipShape(shape)
            .overlay {
                if Calendar.current.isDateInToday(day.day) {
                    shape.strokeBorder(Color.primary.opacity(0.55), lineWidth: 1)
                }
            }
            .contentShape(shape)
            .onHover { inside in
                if inside { hovered = day.id } else if hovered == day.id { hovered = nil }
            }
            .accessibilityElement()
            .accessibilityLabel(day.readout)
        }
    }

    private var readout: some View {
        Group {
            if let day = summary.days.first(where: { $0.id == hovered }) {
                Text(day.readout).foregroundStyle(.secondary)
            } else if range == .today {
                let prior = summary.days.filter { !$0.inRange }
                Text("Prior \(prior.count) days, in gray · \(Format.tokens(prior.reduce(0) { $0 + $1.tokens })) · "
                    + Format.usd(prior.reduce(0) { $0 + $1.cost }))
            } else if let peak = summary.days.filter(\.inRange).max(by: { $0.tokens < $1.tokens }), peak.tokens > 0 {
                Text("Peak \(peak.dayLabel) · \(Format.tokens(peak.tokens)) · \(Format.usd(peak.cost))")
            } else {
                Text("No usage \(range.inPhrase) yet")
            }
        }
        .font(.system(size: 10.5))
        .foregroundStyle(.tertiary)
    }

    private var chips: some View {
        let tokens = summary.tokens
        return HStack(spacing: 6) {
            chip(Format.tokens(tokens.output), "out", color: Theme.s2, help: "Output tokens")
            chip(Format.tokens(tokens.input), "in", color: Theme.s1, help: "Fresh input tokens")
            chip(share(tokens.cacheRead, of: tokens.total), "cache hits", color: Theme.s3,
                 help: "Cache read \(Format.tokens(tokens.cacheRead)) · cache write \(Format.tokens(tokens.cacheWrite)) "
                     + "(\(share(tokens.cacheWrite, of: tokens.total)))")
        }
    }

    private func chip(_ value: String, _ label: String, color: Color, help: String) -> some View {
        HStack(spacing: 5) {
            Dot(color: color, size: 6)
            Text("\(emphasis(value, weight: .semibold)) \(label)")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 7)
        .frame(height: 20)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.fill1))
        .help(help)
    }

    /// Whole weeks from the one holding the first charted day through the current one, in the
    /// locale's week order. Slots before the chart are empty; days after today are outlined.
    private func weeks() -> [Week] {
        let calendar = Calendar.current
        guard let first = summary.days.first?.day, let last = summary.days.last?.day,
              var start = calendar.dateInterval(of: .weekOfYear, for: first)?.start else { return [] }
        let byDay = Dictionary(summary.days.map { ($0.day, $0) }, uniquingKeysWith: { first, _ in first })
        var weeks: [Week] = []
        while start <= last {
            let slots = (0..<7).map { offset -> Slot in
                let date = calendar.date(byAdding: .day, value: offset, to: start)!
                if let day = byDay[date] { return .day(day) }
                return date > last ? .future : .empty
            }
            weeks.append(Week(start: start, slots: slots))
            start = calendar.date(byAdding: .weekOfYear, value: 1, to: start)!
        }
        return weeks
    }

    private var weekdayLetters: [String] {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }
}

// MARK: Shared

/// Widths shared by model rows and the calendar's weekly totals so their numbers line up.
private enum SpendColumn {
    static let tokens: CGFloat = 52
    static let cost: CGFloat = 72
}

/// Top models or projects for the range, stepped through with the arrows above them: tokens and cost.
/// Share of tokens is in the tooltip.
private struct BreakdownRows: View {
    let summary: SpendSummary
    @Binding var breakdown: SpendBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("TOP")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Spacer()
                CycleArrows(options: SpendBreakdown.allCases.map { ($0, $0.label) }, selection: breakdown,
                            noun: "list") { breakdown = $0 }
            }
            .frame(height: 22)
            VStack(spacing: 0) {
                switch breakdown {
                case .models:
                    ForEach(Array(summary.models.prefix(5).enumerated()), id: \.element.id) { index, model in
                        row(model.displayName, tokens: model.tokens.total, cost: model.cost, help: model.model) {
                            ProviderLogo(provider: model.provider, size: 12)
                        }
                        .reveal(after: Self.rowDelay(index))
                    }
                case .projects:
                    ForEach(Array(summary.projects.prefix(5).enumerated()), id: \.element.id) { index, project in
                        row(project.name, tokens: project.tokens.total, cost: project.cost,
                            help: project.path.isEmpty ? "Muse Code and Antigravity logs don't record a project folder" : project.path) {
                            Image(systemName: "folder")
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        }
                        .reveal(after: Self.rowDelay(index))
                    }
                }
            }
        }
        .monospacedDigit()
    }

    /// Rows follow the chart above them, one after another.
    private static func rowDelay(_ index: Int) -> Double { 0.12 + 0.035 * Double(index) }

    private func row<Icon: View>(_ name: String, tokens: Int, cost: Double, help: String,
                                 @ViewBuilder icon: () -> Icon) -> some View {
        HStack(spacing: 8) {
            icon()
            Text(name)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(Format.tokens(tokens))
                .fontWeight(.semibold)
                .frame(width: SpendColumn.tokens, alignment: .trailing)
            Text(Format.usd(cost))
                .foregroundStyle(.secondary)
                .frame(width: SpendColumn.cost, alignment: .trailing)
        }
        .font(.system(size: 12.5))
        .frame(height: 24)
        .help("\(help) · \(share(tokens, of: summary.tokens.total)) of tokens")
        .accessibilityElement(children: .combine)
    }
}

private struct ProviderLegend: View {
    let providers: [ProviderID]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(providers) { provider in
                HStack(spacing: 5) {
                    Dot(color: Theme.color(for: provider), size: 7)
                    Text(provider.displayName)
                }
            }
        }
    }
}

private func emphasis(_ value: String, weight: Font.Weight = .medium) -> Text {
    Text(value).foregroundStyle(.primary).fontWeight(weight)
}

private func share(_ value: Int, of total: Int) -> String {
    let percent = Double(value) / Double(max(total, 1)) * 100
    return value > 0 && percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
}

/// Every token count with its share, for the mix tooltip.
private func mixNote(_ tokens: TokenCounts) -> String {
    [("Input", tokens.input), ("Output", tokens.output), ("Cache read", tokens.cacheRead), ("Cache write", tokens.cacheWrite)]
        .map { "\($0.0) \(Format.tokens($0.1)) (\(share($0.1, of: tokens.total)))" }
        .joined(separator: " · ")
}

private extension SpendSummary {
    var hasChartUsage: Bool { days.contains { $0.tokens > 0 } }
}

private extension SpendRange {
    /// "today", "in the last 7 days".
    var inPhrase: String { self == .today ? "today" : "in the \(phrase)" }
}

private extension DaySpend {
    var dayLabel: String {
        Calendar.current.isDateInToday(day) ? "Today" : day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }

    var shortDate: String { day.formatted(.dateTime.month(.abbreviated).day()) }

    var readout: String { "\(dayLabel) · \(Format.tokens(tokens)) tokens · \(Format.usd(cost))" }

    /// Provider slices with tokens, top of the stack first (providers are in fixed order, bottom first).
    func segments(_ providers: [ProviderID]) -> [(provider: ProviderID, tokens: Int)] {
        providers.reversed().compactMap { provider in
            guard let tokens = tokensByProvider[provider], tokens > 0 else { return nil }
            return (provider, tokens)
        }
    }
}
