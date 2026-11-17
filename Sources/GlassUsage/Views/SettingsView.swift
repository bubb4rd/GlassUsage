import SwiftUI

/// A strip of choices (providers, menu bar, rings, percent, spend view, refresh) over one group of switches.
/// Version, updates, privacy and Quit live in the header.
struct SettingsView: View {
    let store: UsageStore
    let updater: Updater
    let onBack: () -> Void
    let onQuit: () -> Void

    @State private var autoUpdates = false
    @State private var showingPrivacy = false

    var body: some View {
        @Bindable var settings = store.settings

        VStack(alignment: .leading, spacing: 0) {
            header

            VStack(alignment: .leading, spacing: 8) {
                stripRow("Track") {
                    FlowLayout { ForEach(ProviderID.allCases) { trackChip($0) } }
                }
                stripRow("Menu bar") { FlowLayout { menuBarOptions } }
                stripRow("Rings") {
                    PillPicker(options: MenuBarRings.allCases.map { ($0, $0.label) }, selection: $settings.menuBarRings)
                }
                stripRow("Percent") {
                    PillPicker(options: MenuBarPercent.allCases.map { ($0, $0.label) }, selection: $settings.menuBarPercent)
                }
                stripRow("Spend") {
                    PillPicker(options: SpendView.allCases.map { ($0, $0.label) }, selection: $settings.spendView,
                               symbols: Dictionary(uniqueKeysWithValues: SpendView.allCases.map { ($0, $0.symbol) }))
                }
                stripRow("Refresh") {
                    PillPicker(options: AppSettings.refreshChoices.map { ($0, "\($0)") }, selection: Binding(
                        get: { settings.refreshMinutes },
                        set: { settings.refreshMinutes = $0; store.start() }))
                    Text("min").font(.system(size: 11.5)).foregroundStyle(.tertiary)
                }
                stripRow("Alerts") {
                    PillPicker(options: LimitAlertLevel.allCases.map { ($0, $0.label) }, selection: Binding(
                        get: { settings.limitAlert },
                        set: { level in
                            settings.limitAlert = level
                            if level != .off { Task { await store.alerts.requestPermission() } }
                        }))
                    if settings.limitAlert != .off && store.alerts.isBlocked {
                        Button { openNotificationSettings() } label: {
                            Image(systemName: "bell.slash.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.warning)
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Notifications are off for GlassUsage. Click to allow them in System Settings.")
                        .accessibilityLabel("Allow notifications in System Settings")
                    }
                }
                .help("Notify when a tracked limit reaches this level, and again when it resets")
                .task {
                    if settings.limitAlert != .off { await store.alerts.refreshPermission() }
                }
            }
            .padding(.top, 10)

            VStack(spacing: 0) {
                row("Open on hover") { Toggle("Open on hover", isOn: $settings.openOnHover) }
                divider
                row("Launch at login") { Toggle("Launch at login", isOn: $settings.launchAtLogin) }
                if updater.isAvailable {
                    divider
                    row("Update automatically") {
                        Toggle("Update automatically", isOn: $autoUpdates)
                            .onChange(of: autoUpdates) { _, value in updater.automaticallyChecks = value }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill1))
            .padding(.top, 12)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.good)
        .labelsHidden()
        .onAppear { autoUpdates = updater.automaticallyChecks }
    }

    private var header: some View {
        HStack(spacing: 6) {
            IconButton(symbol: "chevron.left", help: "Back", action: onBack)
            Text("Settings").font(.system(size: 15, weight: .semibold))
            Spacer()
            Text(Updater.versionString)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .help("GlassUsage \(Updater.versionString)")
            if let version = updater.availableVersion {
                Button { updater.checkForUpdates() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down.circle.fill")
                        Text("Update to \(version)")
                    }
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(Capsule().fill(Theme.good))
                    .fixedSize()
                }
                .buttonStyle(.plain)
                .help("GlassUsage \(version) is available")
            } else if updater.isAvailable {
                IconButton(symbol: "arrow.down.circle", help: "Check for updates") { updater.checkForUpdates() }
            }
            IconButton(symbol: "info.circle", help: "Privacy", active: showingPrivacy) { showingPrivacy.toggle() }
                .popover(isPresented: $showingPrivacy, arrowEdge: .bottom) { privacyNotes }
            IconButton(symbol: "power", help: "Quit GlassUsage (⌘Q)", action: onQuit)
                .keyboardShortcut("q")
        }
        .frame(height: 28)
        .padding(.leading, -6)
    }

    private var privacyNotes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("**Limits.** Reads Claude Code's Keychain login and Codex's auth.json, and asks the Antigravity and Muse Code CLIs (`agy -p /usage`, `muse usage`). Tokens are only read, never refreshed or stored.")
            Text("**Spend.** Token spend comes from Claude Code, Codex CLI, Muse Code and omp logs on this Mac, priced with LiteLLM's public list.")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 272, alignment: .leading)
        .padding(12)
    }

    /// GlassUsage's page under System Settings › Notifications.
    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Strip

    /// Turns a provider's limits on or off; a tracked provider without a reading says why.
    private func trackChip(_ provider: ProviderID) -> some View {
        let settings = store.settings
        let on = settings.isEnabled(provider)
        let error = on && store.state(for: provider).snapshot == nil ? store.state(for: provider).error : nil
        return Button {
            settings.setEnabled(provider, !on)
            if !on { Task { await store.refresh() } }
        } label: {
            HStack(spacing: 5) {
                ProviderLogo(provider: provider, size: 12).opacity(on ? 1 : 0.45)
                Text(provider.displayName)
                if let error {
                    Text("· \(error.isNotConnected ? "not signed in" : "unreachable")").foregroundStyle(Theme.warning)
                }
            }
            .padding(.horizontal, 9)
            .chip(selected: on)
        }
        .buttonStyle(.plain)
        .help(error.map { $0.isNotConnected ? provider.signInHint : $0.errorDescription ?? "" }
            ?? (on ? "Stop tracking \(provider.displayName)" : "Track \(provider.displayName) limits"))
        .accessibilityLabel("Track \(provider.displayName)")
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    /// Each tracked provider drawn as the menu bar item it would produce, with the chosen rings and
    /// percentage; picking one puts it in the menu bar.
    @ViewBuilder
    private var menuBarOptions: some View {
        let enabled = store.settings.enabledProviders
        if enabled.isEmpty {
            Text("Turn on a provider").font(.system(size: 11.5)).foregroundStyle(.tertiary)
        } else {
            ForEach(enabled) { menuBarOption($0, selected: $0 == store.menuBarProvider) }
            if enabled.count == 1 {
                Text("only tracked").font(.system(size: 11.5)).foregroundStyle(.tertiary)
            }
        }
    }

    private func menuBarOption(_ provider: ProviderID, selected: Bool) -> some View {
        let state = store.state(for: provider)
        let settings = store.settings
        return Button { settings.menuBarProvider = provider } label: {
            HStack(spacing: 6) {
                StatusItemPreview(state: state, rings: settings.menuBarRings, percent: settings.menuBarPercent)
                Text(provider.displayName).fixedSize()
            }
            .padding(.leading, 2)
            .padding(.trailing, 7)
            .chip(selected: selected, outlined: true)
        }
        .buttonStyle(.plain)
        .disabled(state.snapshot == nil)
        .opacity(state.snapshot == nil ? 0.55 : 1)
        .help(state.snapshot == nil
            ? "\(provider.displayName) has no reading to show"
            : "Show \(provider.displayName) in the menu bar")
        .accessibilityLabel("Show \(provider.displayName) in the menu bar")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func stripRow<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(title)
                .font(.system(size: 11.5))
                .foregroundStyle(.tertiary)
                .frame(width: 52, height: 26, alignment: .leading)
            HStack(spacing: 6) { content() }
                .frame(minHeight: 26)
        }
    }

    // MARK: Switches

    private var divider: some View {
        Rectangle().fill(Theme.hair).frame(height: 0.5).padding(.leading, 12)
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
    }
}

/// The status item as the menu bar draws it for one provider: the ring glyph plus the chosen percentage.
private struct StatusItemPreview: View {
    let state: ProviderState
    let rings: MenuBarRings
    let percent: MenuBarPercent

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: StatusIcon.image(for: state, rings: rings))
                .renderingMode(.template)
            if let text = StatusIcon.percentText(for: state.snapshot, mode: percent) {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
        }
        .fixedSize()
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 5)
        .frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color(red: 40 / 255, green: 40 / 255, blue: 60 / 255).opacity(0.65)))
    }
}

private extension View {
    /// Toggle chip in the settings strip: filled when selected, a hairline outline otherwise.
    /// `outlined` adds a ring to the selected chip, marking a single pick rather than an on/off toggle.
    func chip(selected: Bool, outlined: Bool = false) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9)
        return font(.system(size: 11.5))
            .foregroundStyle(selected ? .primary : .tertiary)
            .frame(height: 26)
            .background {
                if selected {
                    shape.fill(Theme.fill2)
                    if outlined { shape.strokeBorder(Color.primary.opacity(0.3), lineWidth: 1) }
                } else {
                    shape.strokeBorder(Theme.fill2, lineWidth: 0.5)
                }
            }
            .contentShape(shape)
    }
}

/// Lays chips out left to right, wrapping to a new line when the row is full.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(fitting: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(fitting: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func rows(fitting width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if let last = rows.last, !last.indices.isEmpty, last.width + spacing + size.width > width {
                rows.append(Row())
            }
            rows[rows.count - 1].width += (rows[rows.count - 1].indices.isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
            rows[rows.count - 1].indices.append(index)
        }
        return rows
    }
}
