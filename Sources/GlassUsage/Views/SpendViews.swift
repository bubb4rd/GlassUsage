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

    @Environment(\.chartFill) private var fill
    @Environment(\.panelRevealed) private var revealed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                totals
                Spacer(minLength: 4)
                PillPicker(options: SpendRange.allCases.map { ($0, $0.label) }, selection: $range)
            }
            .frame(height: 26)

            if isLoading {
                if fill == .dither {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: !revealed || reduceMotion)) { timeline in
                        DitherScan(t: Dither.time(timeline.date), scanning: revealed && !reduceMotion)
                    }
                    .frame(height: ProviderShare.ditherHeight)
                    .padding(.top, 10)
                    .accessibilityLabel("Reading usage logs")
                } else {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 64)
                }
            } else if !summary.hasChartUsage {
                Text("Token counts from Claude Code, Codex CLI, Muse Code and omp logs show up here after your first session.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            } else {
                let palette = SpendPalette(style: colors, providers: summary.providers)
                if summary.providers.count > 1 {
                    ProviderShare(summary: summary, palette: palette).padding(.top, 10)
                }
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
            let byValue = summary.unit == .value
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(byValue ? Format.dollars(summary.cost) : Format.tokens(summary.tokens.total))
                    .font(.system(size: 22, weight: .bold))
                    .tracking(-0.5)
                    .contentTransition(.numericText(value: byValue ? summary.cost : Double(summary.tokens.total)))
                Text(byValue ? "API VALUE" : "TOKENS")
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
            }
            .monospacedDigit()
            .animation(.smooth(duration: 0.3), value: byValue ? summary.cost : Double(summary.tokens.total))
            .help(costNote)
            .accessibilityElement(children: .combine)
        }
    }

    private var costNote: String {
        var note = "\(Format.tokens(summary.tokens.total)) tokens, worth \(Format.usd(summary.cost)) at API list rates (LiteLLM). "
            + "Subscriptions bill differently."
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
        // Dollars, like the headline; tokens when they lead, or when no model in the chart has a price.
        let byCost = summary.chartsByCost
        let value: (DaySpend) -> Double = { $0.value(byCost: byCost) }
        let peak = max(summary.days.map(value).max() ?? 0, .leastNonzeroMagnitude)
        let average = summary.days.map(value).reduce(0, +) / Double(max(summary.days.count, 1))
        let spacing: CGFloat = summary.days.count > 14 ? 2 : 4
        // Columns grow from the baseline left to right, the whole sweep within a quarter second.
        let stagger = min(0.015, 0.25 / Double(max(summary.days.count, 1)))
        VStack(alignment: .leading, spacing: 0) {
            let amount: (Double) -> String = byCost ? Format.dollars : { Format.tokens(Int($0)) }
            let full = "avg \(amount(average))/day · peak \(amount(peak))"
            HStack(spacing: 5) {
                HorizontalRule()
                    .stroke(Color.primary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                    .frame(width: 12, height: 1)
                Text(full)
                Spacer(minLength: 0)
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
                               progress: grown || reduceMotion ? 1 : 0,
                               highlighted: hovered.map { $0 == day.id }, seed: index)
                            .animation(Motion.curve(grown, Motion.draw, delay: base + 0.05 + stagger * Double(index)), value: grown)
                            .frame(maxWidth: .infinity, maxHeight: Self.chartHeight, alignment: .bottom)
                            .opacity(day.inRange ? 1 : 0.55)
                            .contentShape(Rectangle())
                            .onHover { inside in
                                if inside { hovered = day.id } else if hovered == day.id { hovered = nil }
                            }
                            .accessibilityElement()
                            .accessibilityLabel(day.readout(byCost: byCost))
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

            axis(spacing: spacing, byCost: byCost)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(height: 12)
                .padding(.top, 5)

            Group {
                if summary.tokens.total > 0 {
                    // Whichever figure the headline doesn't show leads the mix.
                    let total = summary.unit == .tokens && summary.cost > 0
                        ? Text("\(emphasis(Format.dollars(summary.cost))) API value")
                        : Text("\(emphasis(Format.tokens(summary.tokens.total))) tokens")
                    Text("\(total) · \(emphasis(share(summary.tokens.cacheRead, of: summary.tokens.total))) cache reads · \(emphasis(Format.tokens(summary.tokens.output))) output")
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

    @ViewBuilder
    private func axis(spacing: CGFloat, byCost: Bool) -> some View {
        if let day = summary.days.first(where: { $0.id == hovered }) {
            Text(day.readout(byCost: byCost)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
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
    /// Nil while no day is hovered; else whether this one is. Dithered columns pick out the hovered day.
    let highlighted: Bool?
    /// The column's place in the chart, varying the dither texture.
    let seed: Int

    @Environment(\.chartFill) private var fill

    var body: some View {
        if fill == .dither {
            DitherColumn(slices: segments.reversed().map { (palette.color(for: $0.provider), $0.share) }, height: height,
                         progress: Double(progress), highlighted: highlighted, seed: seed)
        } else if height < 1 || segments.isEmpty {
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

/// Weeks by weekday, each day shaded by its cost (or tokens, as the ledger sizes its bars), with each week's
/// in-range total on the right. Days outside the range stay gray for context.
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
        let byCost = summary.chartsByCost
        let peak = max(summary.days.map { $0.value(byCost: byCost) }.max() ?? 0, .leastNonzeroMagnitude)
        let cellHeight: CGFloat = weeks.count > 2 ? 14 : 20
        Revealing { grown in grid(weeks: weeks, byCost: byCost, peak: peak, cellHeight: cellHeight, grown: grown) }
    }

    private func grid(weeks: [Week], byCost: Bool, peak: Double, cellHeight: CGFloat, grown: Bool) -> some View {
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
                weekRow(week, index: index, byCost: byCost, peak: peak, cellHeight: cellHeight, grown: grown)
            }

            readout(byCost: byCost).padding(.top, 2)

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
    private func weekRow(_ week: Week, index: Int, byCost: Bool, peak: Double, cellHeight: CGFloat, grown: Bool) -> some View {
        HStack(spacing: 0) {
            Text(week.start.formatted(.dateTime.month(.abbreviated).day()))
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .frame(width: Self.labelWidth, alignment: .leading)
            HStack(spacing: Self.cellSpacing) {
                ForEach(Array(week.slots.enumerated()), id: \.offset) { offset, slot in
                    cell(slot, byCost: byCost, peak: peak, height: cellHeight)
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
                let lead = byCost ? cost > 0 : tokens > 0
                let figures = SpendText.figures(tokens: tokens, cost: cost, byCost: byCost)
                // The lead figure sits in the lead column, under the list rows'.
                HStack(spacing: 8) {
                    Text(figures.other)
                        .foregroundStyle(.secondary)
                        .frame(width: SpendColumn.other, alignment: .trailing)
                    Text(figures.lead)
                        .fontWeight(lead ? .semibold : .regular)
                        .frame(width: SpendColumn.lead, alignment: .trailing)
                }
                .font(.system(size: 11.5))
                .opacity(lead ? 1 : 0.45)
            }
        }
    }

    @ViewBuilder
    private func cell(_ slot: Slot, byCost: Bool, peak: Double, height: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        switch slot {
        case .empty:
            Color.clear
        case .future:
            shape.strokeBorder(Theme.hair, lineWidth: 0.5)
        case .day(let day):
            let value = day.value(byCost: byCost)
            let intensity = value > 0 ? 0.22 + 0.78 * pow(value / peak, 0.7) : 0
            let segments = day.segments(summary.providers, byCost: byCost)
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
            .accessibilityLabel(day.readout(byCost: byCost))
        }
    }

    private func readout(byCost: Bool) -> some View {
        func amounts(tokens: Int, cost: Double) -> String { SpendText.amounts(tokens: tokens, cost: cost, byCost: byCost) }
        return Group {
            if let day = summary.days.first(where: { $0.id == hovered }) {
                Text(day.readout(byCost: byCost)).foregroundStyle(.secondary)
            } else if range == .today {
                let prior = summary.days.filter { !$0.inRange }
                Text("Prior \(prior.count) days, in gray · "
                    + amounts(tokens: prior.reduce(0) { $0 + $1.tokens }, cost: prior.reduce(0) { $0 + $1.cost }))
            } else if let peak = summary.days.filter(\.inRange).max(by: { $0.value(byCost: byCost) < $1.value(byCost: byCost) }),
                      peak.value(byCost: byCost) > 0 {
                Text("Peak \(peak.dayLabel) · \(amounts(tokens: peak.tokens, cost: peak.cost))")
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

/// Widths shared by list rows and the calendar's weekly totals so their numbers line up: the lead figure in
/// bold, the other unit beside it, and in rows the share between them.
private enum SpendColumn {
    static let other: CGFloat = 52
    static let share: CGFloat = 32
    static let lead: CGFloat = 72
}

private enum SpendText {
    /// "$153.62" leading "281.1M", or "281.1M" leading "$154".
    static func figures(tokens: Int, cost: Double, byCost: Bool) -> (lead: String, other: String) {
        byCost ? (Format.usd(cost), Format.tokens(tokens)) : (Format.tokens(tokens), Format.dollars(cost))
    }

    /// "$105.77 · 281.1M tokens", or tokens first when they lead.
    static func amounts(tokens: Int, cost: Double, byCost: Bool) -> String {
        byCost ? "\(Format.usd(cost)) · \(Format.tokens(tokens)) tokens" : "\(Format.tokens(tokens)) tokens · \(Format.usd(cost))"
    }
}

/// Fills for the spend charts' provider stacks and legend, and the calendar's token-mix dots.
struct SpendPalette {
    let style: SpendColors
    /// Providers in the chart, bottom of the stack first.
    let providers: [ProviderID]

    /// Gray steps by stack position for one to four providers, spread as far apart as the count allows.
    static let grays: [[Double]] = [[0.8], [0.8, 0.38], [0.85, 0.55, 0.3], [0.85, 0.62, 0.42, 0.24]]

    func color(for provider: ProviderID) -> Color {
        guard style == .graphite else { return Theme.color(for: provider, in: style) }
        let steps = Self.grays[min(max(providers.count, 1), Self.grays.count) - 1]
        return Color.primary.opacity(steps[min(providers.firstIndex(of: provider) ?? 0, steps.count - 1)])
    }

    var output: Color { style == .graphite ? Color.primary.opacity(0.8) : Theme.s2 }
    var input: Color { style == .graphite ? Color.primary.opacity(0.5) : Theme.s1 }
    var cacheHits: Color { style == .graphite ? Color.primary.opacity(0.28) : Theme.s3 }

    /// Gray slices are parted by a hairline so neighboring steps still read as separate providers.
    var slit: CGFloat { style == .graphite ? 1 : 0 }
}

/// Top models, projects or sources for the range, ranked by the lead figure (dollars or tokens), each with the
/// other figure, its share of the range and a bar that long under it.
private struct BreakdownRows: View {
    let summary: SpendSummary
    @Binding var breakdown: SpendBreakdown
    /// The lists turned on in Settings, in tab order; never empty.
    let lists: [SpendBreakdown]
    let palette: SpendPalette
    @Environment(\.appSettings) private var settings
    @Environment(\.panelRevealed) private var revealed
    @Environment(\.chartFill) private var fill
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
                    .pointingHand()
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

    /// Share of the range in the lead figure.
    private func fraction(tokens: Int, cost: Double) -> Double {
        summary.leadsWithCost ? cost / summary.cost : Double(tokens) / Double(max(summary.tokens.total, 1))
    }

    private func row<Icon: View>(_ id: String, _ name: String, tokens: Int, cost: Double, help: String, bar: Color,
                                 @ViewBuilder icon: () -> Icon) -> some View {
        let fraction = fraction(tokens: tokens, cost: cost)
        let figures = SpendText.figures(tokens: tokens, cost: cost, byCost: summary.leadsWithCost)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                icon()
                    .frame(width: 14)
                SlidingLabel(text: name, sliding: hovered == id && revealed)
                    .fontWeight(.medium)
                Spacer(minLength: 6)
                HStack(spacing: 0) {
                    Text(figures.other)
                        .foregroundStyle(.secondary)
                        .frame(width: SpendColumn.other, alignment: .trailing)
                    Text(fraction > 0 && fraction < 0.01 ? "<1%" : Format.percent(fraction * 100))
                        .foregroundStyle(.tertiary)
                        .frame(width: SpendColumn.share, alignment: .trailing)
                }
                .font(.system(size: 11.5))
                Text(figures.lead)
                    .fontWeight(.semibold)
                    .frame(width: SpendColumn.lead, alignment: .trailing)
            }
            .frame(height: 21)
            if fill == .dither {
                DitherLine(fraction: fraction, color: bar)
                    .animation(.smooth(duration: 0.3), value: fraction)
            } else {
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar)
                    .frame(height: 2)
                    .scaleEffect(x: min(max(fraction, 0), 1), anchor: .leading)
                    .animation(.smooth(duration: 0.3), value: fraction)
            }
        }
        .font(.system(size: 12.5))
        .frame(height: 26, alignment: .top)
        .contentShape(.rect)
        .onHover { inside in
            if inside { hovered = id } else if hovered == id { hovered = nil }
        }
        .help(help)
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

/// The range's lead figure by provider: one bar split across the panel, then each provider with its figure.
/// Hovering a slice or a name picks that provider out in both. The bar sweeps in as the charts grow.
private struct ProviderShare: View {
    let summary: SpendSummary
    let palette: SpendPalette

    @State private var hovered: ProviderID?
    @State private var width: CGFloat = 1
    @Environment(\.chartFill) private var fill
    @Environment(\.revealDelay) private var base
    @Environment(\.panelRevealed) private var revealed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let ditherHeight: CGFloat = 32

    var body: some View {
        let byCost = summary.leadsWithCost
        let totals = summary.providers.map { (provider: $0, value: summary.total(for: $0, byCost: byCost)) }
        let sum = max(totals.reduce(0) { $0 + $1.value }, .leastNonzeroMagnitude)
        let slices = totals.map { (color: palette.color(for: $0.provider), share: $0.value / sum) }
        let highlighted = hovered.flatMap { summary.providers.firstIndex(of: $0) }
        VStack(alignment: .leading, spacing: 6) {
            Revealing { shown in
                bar(slices, highlighted: highlighted, progress: shown || reduceMotion ? 1 : 0)
                    .animation(Motion.curve(shown, Motion.draw, delay: base + 0.05), value: shown)
            }
            .frame(height: fill == .dither ? Self.ditherHeight : 8)
            .contentShape(.rect)
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = max($0, 1) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    var edge = 0.0
                    hovered = totals.indices.first { index in
                        edge += slices[index].share
                        return point.x / width < edge
                    }.map { totals[$0].provider }
                case .ended:
                    hovered = nil
                }
            }
            legend(totals, byCost: byCost)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(totals.map { "\($0.provider.displayName) \(figure($0.value, byCost: byCost))" }.joined(separator: ", "))
    }

    @ViewBuilder
    private func bar(_ slices: [(color: Color, share: Double)], highlighted: Int?, progress: Double) -> some View {
        if fill == .dither {
            // The texture drifts while the panel is open.
            TimelineView(.animation(minimumInterval: 1 / 12, paused: !revealed || reduceMotion)) { timeline in
                DitherShareBar(slices: slices, progress: progress, highlighted: highlighted, t: Dither.time(timeline.date),
                               live: revealed && !reduceMotion)
            }
        } else {
            SolidShareBar(slices: slices, progress: progress, highlighted: highlighted)
        }
    }

    /// Two providers to a row, each with its color in the bar, its logo and its figure at the end.
    private func legend(_ totals: [(provider: ProviderID, value: Double)], byCost: Bool) -> some View {
        let rows = stride(from: 0, to: totals.count, by: 2).map { Array(totals[$0..<min($0 + 2, totals.count)]) }
        return Grid(horizontalSpacing: 12, verticalSpacing: 0) {
            ForEach(rows.indices, id: \.self) { row in
                GridRow {
                    ForEach(rows[row], id: \.provider) { item in
                        // Tight spacing: with the swatch, "Antigravity" and its figure still fit half the panel.
                        HStack(spacing: 6) {
                            HStack(spacing: 4) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(palette.color(for: item.provider))
                                    .frame(width: 7, height: 7)
                                ProviderLogo(provider: item.provider, size: 12).frame(width: 14)
                            }
                            Text(item.provider.displayName).fontWeight(.medium).lineLimit(1)
                            Spacer(minLength: 2)
                            Text(figure(item.value, byCost: byCost)).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 5)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6).fill(hovered == item.provider ? Theme.fill1 : .clear))
                        .opacity(hovered == nil || hovered == item.provider ? 1 : 0.45)
                        .contentShape(.rect)
                        .onHover { inside in
                            if inside { hovered = item.provider } else if hovered == item.provider { hovered = nil }
                        }
                    }
                    if rows[row].count == 1 { Color.clear.gridCellUnsizedAxes([.horizontal, .vertical]) }
                }
            }
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, -5)
        .animation(.easeOut(duration: 0.15), value: hovered)
    }

    private func figure(_ value: Double, byCost: Bool) -> String {
        byCost ? Format.dollars(value) : Format.tokens(Int(value))
    }
}

/// The spend bar in flat color: a capsule split into provider slices that grow in from the leading edge.
private struct SolidShareBar: View, Animatable {
    let slices: [(color: Color, share: Double)]
    var progress: Double
    let highlighted: Int?

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Canvas { context, size in
            var context = context
            context.clip(to: Capsule().path(in: CGRect(origin: .zero, size: size)))
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.track))
            var x: CGFloat = 0
            for (index, slice) in slices.enumerated() {
                let width = size.width * slice.share * progress
                let dim = highlighted == nil || highlighted == index ? 1 : 0.35
                context.fill(Path(CGRect(x: x, y: 0, width: max(width - 1, 0), height: size.height)),
                             with: .color(slice.color.opacity(dim)))
                x += width
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

    /// A provider's in-range cost, or its tokens.
    func total(for provider: ProviderID, byCost: Bool) -> Double {
        days.filter(\.inRange).reduce(0) { sum, day in
            sum + (byCost ? day.costByProvider[provider] ?? 0 : Double(day.tokensByProvider[provider] ?? 0))
        }
    }
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

    func readout(byCost: Bool) -> String { "\(dayLabel) · \(SpendText.amounts(tokens: tokens, cost: cost, byCost: byCost))" }

    /// What the charts size and shade a day by: its cost, or its tokens when nothing charted has a price.
    func value(byCost: Bool) -> Double { byCost ? cost : Double(tokens) }

    /// Provider slices with their share of the day's tokens or cost, top of the stack first (providers are in
    /// fixed order, bottom first).
    func segments(_ providers: [ProviderID], byCost: Bool) -> [(provider: ProviderID, share: Double)] {
        let total = value(byCost: byCost)
        guard total > 0 else { return [] }
        return providers.reversed().compactMap { provider in
            let value = byCost ? costByProvider[provider] ?? 0 : Double(tokensByProvider[provider] ?? 0)
            return value > 0 ? (provider, value / total) : nil
        }
    }
}
