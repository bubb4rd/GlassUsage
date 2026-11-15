import SwiftUI

/// The drop-down panel. Data first: the numbers lead and every label is small and quiet.
struct UsagePanelView: View {
    let store: UsageStore
    let updater: Updater
    @Bindable var model: PanelModel
    let onSizeChange: (CGSize) -> Void
    let onQuit: () -> Void

    static let width: CGFloat = 360

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
        .animation(.smooth(duration: 0.2), value: model.showingSettings)
        .onGeometryChange(for: CGSize.self, of: \.size) { onSizeChange($0) }
    }

    private func main(now: Date) -> some View {
        let settings = store.settings
        let providers = settings.enabledProviders
        let summary = SpendSummary(reports: providers.compactMap { store.localReports[$0] }, range: model.range)

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Eyebrow("Limits", unit: store.isRefreshing ? "refreshing" : Format.ago(store.lastRefresh, now: now))
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)", spinning: store.isRefreshing) {
                    Task { await store.refresh() }
                }
                .disabled(store.isRefreshing)
                IconButton(symbol: "dollarsign.circle", help: settings.showSpend ? "Hide token spend" : "Show token spend",
                           active: settings.showSpend) {
                    settings.showSpend.toggle()
                }
                IconButton(symbol: "gearshape", help: "Settings (⌘,)") { model.showingSettings = true }
            }
            .frame(height: 28)

            if providers.isEmpty {
                Text("Turn on Claude or Codex in Settings.")
                    .font(.system(size: 12)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity).padding(.vertical, 24)
            } else {
                LimitsSection(store: store, providers: providers, now: now)
                if settings.showSpend {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Eyebrow("Spend")
                            Spacer()
                            PillPicker(options: SpendRange.allCases.map { ($0, $0.label) }, selection: $model.range)
                        }
                        SpendOverview(summary: summary, range: model.range, isLoading: store.localReports.isEmpty)
                    }
                    .blockDivider()
                    if !summary.models.isEmpty {
                        ModelList(summary: summary)
                            .blockDivider()
                    }
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
                ProviderLimits(provider: provider, state: store.state(for: provider), now: now)
            }
        }
    }
}

private struct ProviderLimits: View {
    let provider: ProviderID
    let state: ProviderState
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                }
                if let snapshot = state.snapshot, state.error != nil {
                    Text("· \(Format.ago(snapshot.fetchedAt, now: now))")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                        .help("Showing the last reading")
                }
            }
            .padding(.bottom, 6)

            if let snapshot = state.snapshot {
                HStack(spacing: 12) {
                    ForEach(snapshot.windows) { LimitRing(window: $0, now: now) }
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
            }
        }
        .padding(.top, 9)
        .padding(.bottom, 8)
    }
}

/// Session or weekly window as a ring in the status-band color, with its countdown and reset time.
private struct LimitRing: View {
    let window: UsageWindow
    let now: Date

    @State private var shown: Double = 0

    var body: some View {
        let band = Theme.Band(percent: window.percent)
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Theme.track, lineWidth: 6)
                Circle()
                    .trim(from: 0, to: max(shown, 0.01))
                    .stroke(band.color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("\(Int(window.percent.rounded()))")
                        .font(.system(size: 15, weight: .semibold))
                        .contentTransition(.numericText(value: window.percent))
                    Text("%")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(band == .critical ? AnyShapeStyle(Theme.critical) : AnyShapeStyle(.primary))
            }
            .padding(3)
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(window.shortLabel).foregroundStyle(.secondary)
                    if band == .critical {
                        Text("▲ near limit").font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.critical)
                    }
                }
                .font(.system(size: 11.5))
                if let reset = window.resetsAt {
                    Text(Format.until(reset, now: now))
                        .font(.system(size: 13, weight: .semibold))
                    Text(Format.clock(reset, now: now))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .monospacedDigit()
        .frame(maxWidth: .infinity, alignment: .leading)
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
