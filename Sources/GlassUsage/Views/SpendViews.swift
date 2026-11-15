import SwiftUI

/// Hero numbers, daily stacked bars and token mix for the selected range.
struct SpendOverview: View {
    let summary: SpendSummary
    let range: SpendRange
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(Format.tokens(summary.tokens.total))
                        .font(.system(size: 34, weight: .bold))
                        .tracking(-1)
                        .contentTransition(.numericText())
                    Text("tokens burned \(range.phrase)")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(Format.usd(summary.cost))
                        .font(.system(size: 20, weight: .semibold))
                        .tracking(-0.4)
                        .contentTransition(.numericText())
                    Text("API-equivalent")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .help(costNote)
                }
            }
            .monospacedDigit()
            .animation(.smooth(duration: 0.3), value: summary.tokens.total)

            if isLoading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 64)
            } else {
                DailyBars(days: summary.days, providers: summary.providers)
                if summary.tokens.total > 0 {
                    TokenMix(tokens: summary.tokens)
                } else {
                    Text("No local usage \(range.phrase) yet.")
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private var costNote: String {
        var note = "Tokens priced at API list rates (LiteLLM). Subscriptions bill differently."
        if !summary.sources.isEmpty { note += " From \(summary.sources.map(\.displayName).formatted())." }
        if summary.hasUnpriced { note += " Some models have no list price and count as $0." }
        return note
    }
}

/// One column per day, stacked by provider; days outside the range are dimmed context.
private struct DailyBars: View {
    let days: [DaySpend]
    let providers: [ProviderID]

    private static let height: CGFloat = 64

    var body: some View {
        let peak = max(days.map(\.tokens).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: days.count > 14 ? 2 : 4) {
                ForEach(days) { day in
                    column(day, height: Self.height * Double(day.tokens) / Double(peak))
                        .frame(maxWidth: .infinity, maxHeight: Self.height, alignment: .bottom)
                        .opacity(day.inRange ? 1 : 0.55)
                        .help(tooltip(day))
                }
            }
            .frame(height: Self.height)

            if !providers.isEmpty {
                HStack(spacing: 12) {
                    ForEach(providers) { provider in
                        HStack(spacing: 5) {
                            Dot(color: Theme.color(for: provider), size: 7)
                            Text(provider.displayName).foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.system(size: 11.5))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Daily tokens")
    }

    @ViewBuilder
    private func column(_ day: DaySpend, height: CGFloat) -> some View {
        let segments = providers.reversed().compactMap { provider in
            day.tokensByProvider[provider].map { (provider, $0) }
        }
        if height < 1 || segments.isEmpty {
            // Empty days keep a baseline stub so the timeline stays readable.
            Capsule().fill(Theme.track).frame(height: 2)
        } else {
            let slit: CGFloat = segments.count > 1 && height >= CGFloat(segments.count) * 4 ? 1 : 0
            let inner = height - slit * CGFloat(segments.count - 1)
            VStack(spacing: slit) {
                ForEach(segments, id: \.0) { provider, tokens in
                    Rectangle()
                        .fill(Theme.color(for: provider))
                        .frame(height: inner * Double(tokens) / Double(day.tokens))
                }
            }
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 4, topTrailingRadius: 4))
        }
    }

    private func tooltip(_ day: DaySpend) -> String {
        "\(day.day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())) · "
            + "\(Format.tokens(day.tokens)) tokens · \(Format.usd(day.cost))"
    }
}

/// Where the tokens went: fresh input, output, cache reads and cache writes.
private struct TokenMix: View {
    let tokens: TokenCounts

    @State private var hovered: String?

    private var parts: [(name: String, value: Int, color: Color)] {
        [("Input", tokens.input, Theme.s1), ("Output", tokens.output, Theme.s2),
         ("Cache read", tokens.cacheRead, Theme.s3), ("Cache write", tokens.cacheWrite, Theme.s4)]
    }

    var body: some View {
        let total = max(Double(tokens.total), 1)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let visible = parts.filter { $0.value > 0 }
                let width = proxy.size.width - CGFloat(max(visible.count - 1, 0)) * 2
                HStack(spacing: 2) {
                    ForEach(visible, id: \.name) { part in
                        Rectangle()
                            .fill(part.color)
                            .frame(width: max(width * Double(part.value) / total, 3))
                            .opacity(hovered == nil || hovered == part.name ? 1 : 0.4)
                            .onHover { hovered = $0 ? part.name : nil }
                    }
                }
            }
            .frame(height: 6)
            .background(Theme.track)
            .clipShape(Capsule())

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible())], spacing: 3) {
                ForEach(parts, id: \.name) { part in
                    HStack(spacing: 5) {
                        Dot(color: part.color, size: 7)
                        Text(part.name).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        Spacer(minLength: 2)
                        Text(Format.tokens(part.value)).lineLimit(1).fixedSize()
                        Text(share(part.value, of: total))
                            .foregroundStyle(.tertiary)
                            .frame(width: 28, alignment: .trailing)
                    }
                    .opacity(hovered == nil || hovered == part.name ? 1 : 0.4)
                }
            }
            .font(.system(size: 11.5))
            .monospacedDigit()
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
    }

    private func share(_ value: Int, of total: Double) -> String {
        let percent = Double(value) / total * 100
        return value > 0 && percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
    }
}

/// Top models for the range: share bar, tokens and cost.
struct ModelList: View {
    let summary: SpendSummary

    var body: some View {
        let total = max(Double(summary.tokens.total), 1)
        VStack(alignment: .leading, spacing: 2) {
            Eyebrow("By model")
            ForEach(summary.models.prefix(5)) { model in
                HStack(spacing: 9) {
                    ProviderLogo(provider: model.provider, size: 12)
                    Text(model.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .help(model.model)
                    Spacer(minLength: 6)
                    Meter(fraction: Double(model.tokens.total) / total, color: Theme.color(for: model.provider).opacity(0.85),
                          height: 3)
                        .frame(width: 50)
                    Text(Format.tokens(model.tokens.total))
                        .fontWeight(.semibold)
                        .frame(width: 56, alignment: .trailing)
                    Text(Format.usd(model.cost))
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .trailing)
                }
                .monospacedDigit()
                .frame(height: 30)
                .accessibilityElement(children: .combine)
            }
        }
    }
}
