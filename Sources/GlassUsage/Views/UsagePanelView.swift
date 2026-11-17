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
        .animation(Self.resize, value: model.breakdown)
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
                    SpendSection(summary: summary, range: $model.range, breakdown: $model.breakdown,
                                 style: settings.spendView, isLoading: store.localReports.isEmpty)
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

    /// Model group the user picked; nil follows the group closest to its limit, as the menu bar does.
    @State private var pickedGroup: String?

    var body: some View {
        let snapshot = state.snapshot?.current(at: now)
        let group = snapshot.flatMap(shownGroup)
        VStack(alignment: .leading, spacing: 0) {
            if showsTitle || group != nil {
                HStack(spacing: 7) {
                    if showsTitle { ProviderTitle(provider: provider, state: state) }
                    if let snapshot, let group {
                        GroupPicker(groups: snapshot.groups, selected: group) { pickedGroup = $0 }
                    }
                }
                .padding(.bottom, showsTitle ? 6 : 8)
            }

            if let snapshot {
                // Rings spread so the first starts at the leading edge and the last ends at the trailing one; a group
                // with a single window (Antigravity's Argon) starts at the leading edge too. Keyed by window length,
                // so a ring animates to its new place when the group changes.
                HStack(spacing: 0) {
                    ForEach(Array(shownWindows(snapshot, group: group).enumerated()), id: \.element.key) { index, window in
                        if index > 0 { Spacer(minLength: 12) }
                        LimitRing(window: window, now: now)
                    }
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

    /// The model group whose windows show, for providers that meter groups separately; nil for account-wide windows.
    private func shownGroup(in snapshot: ProviderSnapshot) -> String? {
        let groups = snapshot.groups
        guard !groups.isEmpty else { return nil }
        if let pickedGroup, groups.contains(pickedGroup) { return pickedGroup }
        return snapshot.mostConstrained?.group ?? groups[0]
    }

    /// The shown group's windows (or all of them when windows are account-wide), shortest first.
    private func shownWindows(_ snapshot: ProviderSnapshot, group: String?) -> [UsageWindow] {
        snapshot.windows.filter { $0.group == group }.sorted { $0.duration < $1.duration }
    }
}

/// Logo, name and plan.
private struct ProviderTitle: View {
    let provider: ProviderID
    let state: ProviderState

    var body: some View {
        HStack(spacing: 7) {
            ProviderLogo(provider: provider, size: 14)
            Text(provider.displayName).font(.system(size: 12.5, weight: .semibold)).fixedSize()
            if let plan = state.snapshot?.plan {
                Text(plan)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
    }
}

/// The shown model group's name between arrows that step through the groups, flush with the trailing edge.
private struct GroupPicker: View {
    let groups: [String]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 8)
            CycleArrows(options: groups.map { ($0, $0) }, selection: selected, noun: "model group", select: pick)
        }
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
        .accessibilityLabel("\(window.group.map { "\($0) " } ?? "")\(window.title) \(Format.percent(window.percent)) used"
            + (window.resetsAt.map { ", resets \(Format.clock($0, now: now))" } ?? ""))
    }
}
