import SwiftUI

/// Token spend for the selected range: totals share the range picker's row, then the days drawn as a
/// ledger (one bar per day) or a calendar (weeks by weekday), then the token mix and top models.
struct SpendSection: View {
    let summary: SpendSummary
    @Binding var range: SpendRange
    @Binding var breakdown: SpendBreakdown
    let style: SpendView
    let colors: SpendColors
    /// The lists offered under the chart, in tab order; none hides the list.
    let lists: [SpendBreakdown]
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
                let palette = SpendPalette(style: colors, providers: summary.providers)
                switch style {
                case .ledger: SpendLedger(summary: summary, range: range, breakdown: $breakdown, lists: lists, palette: palette)
                case .calendar: SpendCalendar(summary: summary, range: range, breakdown: $breakdown, lists: lists, palette: palette)
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
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(Format.dollars(summary.cost))
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .contentTransition(.numericText(value: summary.cost))
                Text("API VALUE")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            .monospacedDigit()
            .animation(.smooth(duration: 0.3), value: summary.cost)
            .help(costNote)
            .accessibilityElement(children: .combine)
        }
    }

    private var costNote: String {
        var note = "\(Format.usd(summary.cost)): the tokens priced at API list rates (LiteLLM). Subscriptions bill differently."
        if !summary.sources.isEmpty { note += " From \(summary.sources.map(\.source.displayName).formatted())." }
        if summary.hasUnpriced { note += " Some models have no list price and count as $0." }
        return note
    }
}

// MARK: Ledger

/// One column per day stacked by provider, scaled to the busiest day, with the daily average dashed across;
/// a date axis that turns into the hovered day's numbers, and the range's token mix under it.
private struct SpendLedger: View {
    let summary: SpendSummary
    let range: SpendRange
    @Binding var breakdown: SpendBreakdown
    let lists: [SpendBreakdown]
    let palette: SpendPalette

    @State private var hovered: Date?
    @Environment(\.revealDelay) private var base
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let chartHeight: CGFloat = 52

    var body: some View {
        // Dollars, like the headline; tokens only when no model in the chart has a price.
        let byCost = summary.days.contains { $0.cost > 0 }
        let value: (DaySpend) -> Double = byCost ? { $0.cost } : { Double($0.tokens) }
        let peak = max(summary.days.map(value).max() ?? 0, .leastNonzeroMagnitude)
        let average = summary.days.map(value).reduce(0, +) / Double(max(summary.days.count, 1))
        let spacing: CGFloat = summary.days.count > 14 ? 2 : 4
        // Columns grow from the baseline left to right, the whole sweep within a quarter second.
        let stagger = min(0.015, 0.25 / Double(max(summary.days.count, 1)))
        VStack(alignment: .leading, spacing: 0) {
            let amount: (Double) -> String = byCost ? Format.dollars : { Format.tokens(Int($0)) }
            let full = "avg \(amount(average))/day · peak \(amount(peak))"
            // With many providers the key takes the room: then only the average, then only the key.
            ViewThatFits(in: .horizontal) {
                keyRow(averageLabel: full)
                keyRow(averageLabel: "avg \(amount(average))")
                keyRow(averageLabel: nil)
            }
            .help((summary.days.count > range.dayCount ? "Over the last \(summary.days.count) days: " : "Over the \(range.phrase): ") + full)
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .frame(height: 14)
            .padding(.top, 8)

            Revealing { grown in
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(summary.days.enumerated()), id: \.element.id) { index, day in
                        DayBar(segments: day.segments(summary.providers, byCost: byCost), palette: palette,
                               height: Self.chartHeight * value(day) / peak,
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
                    .stroke(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(height: 1)
                    .offset(y: Self.chartHeight * (1 - average / peak) - 0.5)
                    .allowsHitTesting(false)
            }
            .padding(.top, 6)

            axis(spacing: spacing)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(height: 12)
                .padding(.top, 5)

            Group {
                if summary.tokens.total > 0 {
                    Text("\(emphasis(Format.tokens(summary.tokens.total))) tokens · \(emphasis(share(summary.tokens.cacheRead, of: summary.tokens.total))) cache reads · \(emphasis(Format.tokens(summary.tokens.output))) output")
                        .help(mixNote(summary.tokens))
                } else {
                    Text("No usage \(range.inPhrase) yet")
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.top, 9)

            if !lists.isEmpty {
                BreakdownRows(summary: summary, breakdown: $breakdown, lists: lists, palette: palette).padding(.top, 8)
            }
        }
        .monospacedDigit()
    }

    /// The provider key on the left, the dashed average's label on the right.
    private func keyRow(averageLabel: String?) -> some View {
        HStack(spacing: 10) {
            if summary.providers.count > 1 { ProviderLegend(palette: palette) }
            Spacer(minLength: 0)
            if let averageLabel {
                HStack(spacing: 5) {
                    HorizontalRule()
                        .stroke(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .frame(width: 12, height: 1)
                    Text(averageLabel).fixedSize()
                }
            }
        }
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
    /// Provider slices, top of the stack first, with their share of the column.
    let segments: [(provider: ProviderID, share: Double)]
    let palette: SpendPalette
    let height: CGFloat
    /// 0 folds the column to its baseline, 1 draws it at full height.
    let progress: CGFloat

    var body: some View {
        if height < 1 || segments.isEmpty {
            Capsule().fill(Theme.track).frame(height: 2).opacity(progress)
        } else {
            let slit: CGFloat = segments.count > 1 && height >= CGFloat(segments.count) * 4 ? 1 : 0
            let inner = height - slit * CGFloat(segments.count - 1)
            VStack(spacing: slit) {
                ForEach(segments, id: \.provider) { segment in
                    Rectangle()
                        .fill(palette.color(for: segment.provider))
                        .frame(height: inner * segment.share * progress)
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
    let lists: [SpendBreakdown]
    let palette: SpendPalette

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

            if !summary.models.isEmpty, !lists.isEmpty {
                BreakdownRows(summary: summary, breakdown: $breakdown, lists: lists, palette: palette).padding(.top, 8)
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
            let segments = day.segments(summary.providers)
            let slit = segments.count > 1 ? palette.slit : 0
            let inner = height - slit * CGFloat(segments.count - 1)
            VStack(spacing: slit) {
                ForEach(segments, id: \.provider) { segment in
                    Rectangle()
                        .fill(day.inRange ? palette.color(for: segment.provider) : Color.primary)
                        .opacity(day.inRange ? intensity : intensity * 0.45)
                        .frame(height: inner * segment.share)
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
            chip(Format.tokens(tokens.output), "out", color: palette.output, help: "Output tokens")
            chip(Format.tokens(tokens.input), "in", color: palette.input, help: "Fresh input tokens")
            chip(share(tokens.cacheRead, of: tokens.total), "cache hits", color: palette.cacheHits,
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

/// Fills for the spend charts' provider stacks and legend, and the calendar's token-mix dots.
private struct SpendPalette {
    let style: SpendColors
    /// Providers in the chart, bottom of the stack first.
    let providers: [ProviderID]

    /// Gray steps by stack position for one to four providers, spread as far apart as the count allows.
    private static let grays: [[Double]] = [[0.8], [0.8, 0.38], [0.85, 0.55, 0.3], [0.85, 0.62, 0.42, 0.24]]

    func color(for provider: ProviderID) -> Color {
        switch style {
        case .providers:
            return Theme.color(for: provider)
        case .graphite:
            let steps = Self.grays[min(max(providers.count, 1), Self.grays.count) - 1]
            return Color.primary.opacity(steps[min(providers.firstIndex(of: provider) ?? 0, steps.count - 1)])
        }
    }

    var output: Color { style == .graphite ? Color.primary.opacity(0.8) : Theme.s2 }
    var input: Color { style == .graphite ? Color.primary.opacity(0.5) : Theme.s1 }
    var cacheHits: Color { style == .graphite ? Color.primary.opacity(0.28) : Theme.s3 }

    /// Gray slices are parted by a hairline so neighboring steps still read as separate providers.
    var slit: CGFloat { style == .graphite ? 1 : 0 }
}

/// Top models, projects or sources for the range, by cost, each with its share of the range and a bar
/// that long under it. Tokens are in the tooltip.
private struct BreakdownRows: View {
    let summary: SpendSummary
    @Binding var breakdown: SpendBreakdown
    /// The lists turned on in Settings, in tab order; never empty.
    let lists: [SpendBreakdown]
    let palette: SpendPalette
    @Environment(\.appSettings) private var settings
    @Environment(\.panelRevealed) private var revealed
    /// The row whose name slides to show all of it.
    @State private var hovered: String?

    /// Bars for rows that belong to no single provider.
    private static let neutral = Color.primary.opacity(0.4)

    var body: some View {
        // The last pick may have been turned off since; then the first list still on.
        let shown = lists.contains(breakdown) ? breakdown : lists[0]
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 14) {
                ForEach(lists, id: \.self) { tab in
                    let selected = tab == shown
                    Button { breakdown = tab } label: {
                        // Sized for the bold label, so the tabs don't shift as the selection moves.
                        Text(tab.label).fontWeight(.semibold).hidden()
                            .overlay(alignment: .leading) { Text(tab.label).fontWeight(selected ? .semibold : .regular) }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selected ? .primary : .tertiary)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .font(.system(size: 12))
            .frame(height: 22)
            VStack(spacing: 0) {
                switch shown {
                case .models:
                    ForEach(Array(summary.models.prefix(5).enumerated()), id: \.element.id) { index, model in
                        row(model.id, model.displayName, tokens: model.tokens.total, cost: model.cost, help: model.model,
                            bar: palette.color(for: model.provider)) {
                            ProviderLogo(provider: model.provider, size: 12)
                        }
                        .reveal(after: Self.rowDelay(index))
                    }
                case .projects:
                    ForEach(Array(summary.projects.enumerated()), id: \.element.id) { index, project in
                        row(project.id, project.name, tokens: project.tokens.total, cost: project.cost,
                            help: project.path.isEmpty ? "Smaller projects, temporary folders and sessions without a project folder" : project.path,
                            bar: Self.neutral) {
                            ProjectIcon(project: project)
                        }
                        .reveal(after: Self.rowDelay(index))
                    }
                    if let settings, !settings.readProtectedFolders, !settings.logoHintDismissed,
                       summary.projects.contains(where: { ProjectIcons.isProtected($0.path) }) {
                        LogoHint(settings: settings)
                            .reveal(after: Self.rowDelay(summary.projects.count))
                    }
                case .sources:
                    ForEach(Array(summary.sources.enumerated()), id: \.element.id) { index, source in
                        let provider = source.source.provider
                        row(source.source.rawValue, source.source.displayName, tokens: source.tokens.total, cost: source.cost,
                            help: source.source.displayName, bar: provider.map(palette.color) ?? Self.neutral) {
                            if let provider {
                                ProviderLogo(provider: provider, size: 12)
                            } else {
                                Image(systemName: "terminal").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                            }
                        }
                        .reveal(after: Self.rowDelay(index))
                    }
                }
            }
        }
        .monospacedDigit()
    }

    /// Rows follow the chart above them, one after another.
    private static func rowDelay(_ index: Int) -> Double { 0.1 + 0.03 * Double(index) }

    /// Share of the range's cost, or of its tokens when nothing in it is priced.
    private func fraction(tokens: Int, cost: Double) -> Double {
        summary.cost > 0 ? cost / summary.cost : Double(tokens) / Double(max(summary.tokens.total, 1))
    }

    private func row<Icon: View>(_ id: String, _ name: String, tokens: Int, cost: Double, help: String, bar: Color,
                                 @ViewBuilder icon: () -> Icon) -> some View {
        let fraction = fraction(tokens: tokens, cost: cost)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                icon()
                    .frame(width: 14)
                SlidingLabel(text: name, sliding: hovered == id && revealed)
                    .fontWeight(.medium)
                Spacer(minLength: 6)
                Text(fraction > 0 && fraction < 0.01 ? "<1%" : Format.percent(fraction * 100))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                Text(Format.usd(cost))
                    .fontWeight(.semibold)
                    .frame(width: SpendColumn.cost, alignment: .trailing)
            }
            .frame(height: 21)
            RoundedRectangle(cornerRadius: 1)
                .fill(bar)
                .frame(height: 2)
                .scaleEffect(x: min(max(fraction, 0), 1), anchor: .leading)
                .animation(.smooth(duration: 0.3), value: fraction)
        }
        .font(.system(size: 12.5))
        .frame(height: 26, alignment: .top)
        .contentShape(.rect)
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        .help("\(help) · \(Format.tokens(tokens)) tokens")
        .accessibilityElement(children: .combine)
    }
}

private extension LocalSource {
    /// The provider whose models the tool runs; nil for omp, which runs any.
    var provider: ProviderID? {
        switch self {
        case .claudeCode: .claude
        case .codexCLI: .codex
        case .antigravity: .antigravity
        case .museCode: .muse
        case .omp: nil
        }
    }
}

/// Offered under the projects while some are in folders macOS guards and reading them is off. Turning
/// it on here is what sets off macOS's permission prompt; the panel never does on its own.
private struct LogoHint: View {
    let settings: AppSettings

    var body: some View {
        HStack(spacing: 8) {
            Button {
                settings.readProtectedFolders = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 14)
                    Text("Read projects in Documents & Desktop")
                }
                .contentShape(.rect)
            }
            .foregroundStyle(.secondary)
            .pointingHand()
            .help("Show each project's logo and count subfolders and worktrees toward their repository. macOS asks for access to these folders first.")
            Spacer(minLength: 6)
            Button {
                withAnimation(.easeOut(duration: 0.2)) { settings.logoHintDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 16, height: 16)
                    .contentShape(.rect)
            }
            .foregroundStyle(.tertiary)
            .pointingHand()
            .help("Hide. This can be turned on in Settings.")
        }
        .buttonStyle(.plain)
        .font(.system(size: 11.5))
        .frame(height: 22)
        .transition(.opacity)
    }
}

/// Which fill is which provider: a small swatch before each name, kept on one line.
private struct ProviderLegend: View {
    let palette: SpendPalette

    var body: some View {
        HStack(spacing: 10) {
            ForEach(palette.providers) { provider in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(palette.color(for: provider)).frame(width: 7, height: 7)
                    Text(provider.displayName)
                }
            }
        }
        .fixedSize()
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

    /// Provider slices with their share of the day's tokens or cost, top of the stack first (providers are in
    /// fixed order, bottom first).
    func segments(_ providers: [ProviderID], byCost: Bool = false) -> [(provider: ProviderID, share: Double)] {
        let total = byCost ? cost : Double(tokens)
        guard total > 0 else { return [] }
        return providers.reversed().compactMap { provider in
            let value = byCost ? costByProvider[provider] ?? 0 : Double(tokensByProvider[provider] ?? 0)
            return value > 0 ? (provider, value / total) : nil
        }
    }
}
