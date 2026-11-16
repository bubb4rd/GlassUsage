import SwiftUI

/// The drop-down panel. Data first: the numbers lead and every label is small and quiet.
struct UsagePanelView: View {
    let store: UsageStore
    let updater: Updater
    @Bindable var model: PanelModel
    let onSizeChange: (CGSize) -> Void
    let onQuit: () -> Void

    static let width: CGFloat = 360
    /// Paired with the window's own resize animation in GlassPanel.
    static let resize = Animation.easeInOut(duration: GlassPanel.resizeDuration)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 15)) { context in
            Group {
                if model.showingSettings {
                    SettingsView(store: store, updater: updater, onBack: { model.showingSettings = false }, onQuit: onQuit)
                } else {
                    main(now: context.date)
                }
            }
            .transition(.opacity)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
        .font(.system(size: 13))
        .animation(Self.resize, value: model.showingSettings)
        .animation(Self.resize, value: model.range)
        .onGeometryChange(for: CGSize.self, of: \.size) { onSizeChange($0) }
    }

    private func main(now: Date) -> some View {
        let settings = store.settings
        let providers = settings.enabledProviders
        let summary = SpendSummary(reports: providers.compactMap { store.localReports[$0] }, range: model.range)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let first = providers.first {
                    ProviderTitle(provider: first, state: store.state(for: first))
                }
                Spacer()
                Text(store.isRefreshing ? "refreshing" : Format.ago(store.lastRefresh, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                    .help(store.lastRefresh.map { "Last refreshed \(Format.clock($0, now: now))" } ?? "")
                IconButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)", spinning: store.isRefreshing) {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)
                IconButton(symbol: "dollarsign.circle", help: settings.showSpend ? "Hide token spend" : "Show token spend",
                           active: settings.showSpend) {
                    withAnimation(Self.resize) { settings.showSpend.toggle() }
                }
                IconButton(symbol: "gearshape", help: updater.availableVersion == nil ? "Settings (⌘,)" : "Settings (⌘,): update available") {
                    model.showingSettings = true
                }
                .overlay(alignment: .topTrailing) {
                    if updater.availableVersion != nil {
                        Circle().fill(Theme.good).frame(width: 6, height: 6).offset(x: -3, y: 3)
                    }
                }
            }
            .frame(height: 28)

            if providers.isEmpty {
                Text("Turn on a provider in Settings.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                LimitsSection(store: store, providers: providers, now: now)
                if settings.showSpend {
                    SpendSection(summary: summary, range: $model.range, style: settings.spendView,
                                 isLoading: store.localReports.isEmpty)
                        .blockDivider()
                        .transition(.opacity)
                }
            }
        }
    }
}

private extension View {
    /// TokenHell separates blocks with a hairline rule rather than cards.
    func blockDivider() -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.hair).frame(height: 0.5).padding(.top, 12)
            self.padding(.top, 12)
        }
    }
}

// MARK: Limits

struct LimitsSection: View {
    let store: UsageStore
    let providers: [ProviderID]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(providers.enumerated()), id: \.element) { index, provider in
                if index > 0 { Rectangle().fill(Theme.hair).frame(height: 0.5) }
                // The first provider's title sits in the panel header.
                ProviderLimits(provider: provider, state: store.state(for: provider), now: now, showsTitle: index > 0)
            }
        }
    }
}

private struct ProviderLimits: View {
    let provider: ProviderID
    let state: ProviderState
    let now: Date
    let showsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle {
                ProviderTitle(provider: provider, state: state).padding(.bottom, 6)
            }

            if let snapshot = state.snapshot {
                if snapshot.groups.isEmpty {
                    // Windows spread so the first starts at the leading edge and the last ends at the trailing one.
                    HStack(spacing: 0) {
                        ForEach(Array(snapshot.windows.enumerated()), id: \.element.id) { index, window in
                            if index > 0 { Spacer(minLength: 12) }
                            LimitRing(window: window, now: now)
                        }
                    }
                } else {
                    GroupedLimits(snapshot: snapshot, now: now)
                }
            } else if state.error == nil {
                Text("Checking…").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            if let error = state.error {
                Text("⚠︎ \(error.isNotConnected ? provider.signInHint : error.errorDescription ?? "")")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.top, 3)
                    .help(state.snapshot.map { "Showing the reading from \(Format.ago($0.fetchedAt, now: now))" } ?? "")
            }
        }
        .padding(.top, showsTitle ? 9 : 6)
        .padding(.bottom, 8)
    }
}

/// Logo, name and plan.
private struct ProviderTitle: View {
    let provider: ProviderID
    let state: ProviderState

    var body: some View {
        HStack(spacing: 7) {
            ProviderLogo(provider: provider, size: 14)
            Text(provider.displayName).font(.system(size: 12.5, weight: .semibold))
            if let plan = state.snapshot?.plan {
                Text(plan.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.3)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.fill2))
                    .fixedSize()
            }
        }
    }
}

/// Providers that meter model groups separately: one row per group, one column per window length.
private struct GroupedLimits: View {
    let snapshot: ProviderSnapshot
    let now: Date

    private struct Column: Hashable {
        let key: String
        let label: String
    }

    var body: some View {
        let columns = columns
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
            GridRow {
                Text("")
                ForEach(columns, id: \.self) { Text($0.label) }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)

            ForEach(snapshot.groups, id: \.self) { group in
                GridRow {
                    Text(group)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(columns, id: \.self) { column in
                        if let window = snapshot.windows.first(where: { $0.group == group && $0.key == column.key }) {
                            CompactLimit(window: window, now: now)
                        } else {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
        .monospacedDigit()
    }

    /// Window lengths across all groups, shortest first ("5h", "week").
    private var columns: [Column] {
        var seen = Set<String>()
        return snapshot.windows.sorted { $0.duration < $1.duration }
            .filter { seen.insert($0.key).inserted }
            .map { Column(key: $0.key, label: $0.shortLabel) }
    }
}

/// One grouped window: a small ring in the band color, the percent used and the countdown.
private struct CompactLimit: View {
    let window: UsageWindow
    let now: Date

    var body: some View {
        let band = Theme.Band(percent: window.percent)
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(window.fraction, 0.01))
                    .stroke(band.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text("\(Int(window.percent.rounded()))%")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(band == .critical ? AnyShapeStyle(Theme.critical) : AnyShapeStyle(.primary))
                .frame(minWidth: 32, alignment: .leading)
            if let reset = window.resetsAt {
                Text(Format.until(reset, now: now))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .help(window.resetsAt.map { "Resets \(Format.clock($0, now: now))" } ?? "")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.group ?? "") \(window.title) \(Format.percent(window.percent)) used"
            + (window.resetsAt.map { ", resets \(Format.clock($0, now: now))" } ?? ""))
    }
}

/// Session or weekly window as a ring in the status-band color, with its countdown and reset time.
private struct LimitRing: View {
    let window: UsageWindow
    let now: Date

    @State private var shown: Double = 0

    var body: some View {
        let band = Theme.Band(percent: window.percent)
        HStack(spacing: 11) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 7)
                Circle()
                    .trim(from: 0, to: max(shown, 0.01))
                    .stroke(band.color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int(window.percent.rounded()))")
                        .font(.system(size: 18, weight: .semibold))
                        .contentTransition(.numericText(value: window.percent))
                    Text("%")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(band == .critical ? AnyShapeStyle(Theme.critical) : AnyShapeStyle(.primary))
            }
            .padding(3)
            .frame(width: 68, height: 68)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(window.shortLabel).foregroundStyle(.secondary)
                    if band == .critical {
                        Text("▲ near limit").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.critical)
                    }
                }
                .font(.system(size: 12))
                if let reset = window.resetsAt {
                    Text(Format.until(reset, now: now))
                        .font(.system(size: 15.5, weight: .semibold))
                    Text(Format.clock(reset, now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .monospacedDigit()
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.6)) { shown = window.fraction }
        }
        .onChange(of: window.fraction) { _, value in
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.4)) { shown = value }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(window.title) \(Format.percent(window.percent)) used"
            + (window.resetsAt.map { ", resets \(Format.clock($0, now: now))" } ?? ""))
    }
}
