import AppKit
import SwiftUI

/// Settings grouped by what they change: which limits are tracked, the menu bar item, the spend block, and
/// the app itself. Version, updates, privacy and Quit live in the header.
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
            header.reveal(after: 0)

            VStack(alignment: .leading, spacing: 12) {
                section("Limits") {
                    FlowLayout { ForEach(ProviderID.allCases) { trackChip($0) } }
                        .padding(8)
                    divider
                    row("Limit alerts") { alertsControl }
                        .help("Notify when a tracked limit reaches this level, and again when it resets")
                        .task {
                            if settings.limitAlert != .off { await store.alerts.refreshPermission() }
                        }
                }
                .reveal(after: Motion.step)

                section("Menu bar") {
                    FlowLayout { menuBarOptions }
                        .padding(8)
                    divider
                    row("Rings") {
                        PillPicker(options: MenuBarRings.allCases.map { ($0, $0.label) }, selection: $settings.menuBarRings)
                    }
                    divider
                    row("Percentage") {
                        menuPicker(MenuBarPercent.allCases.map { ($0, $0.label) }, selection: $settings.menuBarPercent,
                                   help: "The percentage beside the menu bar glyph")
                    }
                    ForEach(groupedProviders) { provider in
                        divider
                        row("\(provider.displayName) models") { groupControl(provider) }
                    }
                    divider
                    row("Open on hover") { Toggle("Open on hover", isOn: $settings.openOnHover).pointingHand() }
                }
                .reveal(after: Motion.step * 2)

                section("Spend") {
                    row("Show") {
                        PillPicker(options: SpendUnit.allCases.map { ($0, $0.label) }, selection: $settings.spendUnit) {
                            Image(systemName: $0.symbol).font(.system(size: 9.5, weight: .semibold))
                        }
                    }
                    .help("What the spend block leads with and ranks by: dollars at API list prices, or tokens")
                    divider
                    row("Chart") {
                        PillPicker(options: SpendView.allCases.map { ($0, $0.label) }, selection: $settings.spendView) {
                            Image(systemName: $0.symbol).font(.system(size: 9.5))
                        }
                    }
                    divider
                    row("Colors") {
                        PillPicker(options: SpendColors.allCases.map { ($0, $0.label) }, selection: $settings.spendColors) {
                            swatch($0)
                        }
                    }
                    .help("How the spend charts tell providers apart: gray steps, or each provider's color")
                    divider
                    row("Lists") {
                        HStack(spacing: 5) { ForEach(SpendBreakdown.allCases, id: \.self) { listChip($0) } }
                    }
                    divider
                    row("Projects in Documents & Desktop") {
                        Toggle("Projects in Documents & Desktop", isOn: $settings.readProtectedFolders)
                            .pointingHand()
                    }
                    .help("Read project folders in Documents, Desktop, Downloads, iCloud Drive, cloud storage and external drives: for their logos, and to count a subfolder or worktree toward its repository. macOS asks for access first.")
                }
                .reveal(after: Motion.step * 3)

                section("General") {
                    row("Refresh every") {
                        menuPicker(AppSettings.refreshChoices.map { ($0, "\($0) min") }, selection: Binding(
                            get: { settings.refreshMinutes },
                            set: { settings.refreshMinutes = $0; store.start() }),
                                   help: "How often limits are fetched")
                    }
                    divider
                    row("Launch at login") { Toggle("Launch at login", isOn: $settings.launchAtLogin).pointingHand() }
                    if updater.isAvailable {
                        divider
                        row("Update automatically") {
                            Toggle("Update automatically", isOn: $autoUpdates)
                                .pointingHand()
                                .onChange(of: autoUpdates) { _, value in updater.automaticallyChecks = value }
                        }
                    }
                }
                .reveal(after: Motion.step * 4)
            }
            .padding(.top, 10)
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
                .pointingHand()
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
            Text("**Spend.** Token spend comes from Claude Code, Codex CLI, Antigravity, Muse Code and omp logs on this Mac, priced with LiteLLM's public list.")
            Text("**Project folders.** Reads each project folder's app icon, logo or favicon, and its `.git` to find the repository a subfolder or worktree belongs to. Folders in Documents, Desktop, Downloads, cloud storage and external drives are only read once you turn that on, in Settings or under the Projects list.")
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

    // MARK: Controls

    /// The alert level, and a way to System Settings when macOS blocks the notifications.
    @ViewBuilder
    private var alertsControl: some View {
        let settings = store.settings
        HStack(spacing: 4) {
            if settings.limitAlert != .off && store.alerts.isBlocked {
                Button { openNotificationSettings() } label: {
                    Image(systemName: "bell.slash.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHand()
                .help("Notifications are off for GlassUsage. Click to allow them in System Settings.")
                .accessibilityLabel("Allow notifications in System Settings")
            }
            menuPicker(LimitAlertLevel.allCases.map { ($0, $0.label) }, selection: Binding(
                get: { settings.limitAlert },
                set: { level in
                    settings.limitAlert = level
                    if level != .off { Task { await store.alerts.requestPermission() } }
                }), help: "Limit alerts")
        }
    }

    /// A compact value that opens a menu of `options`: for settings set once and rarely revisited. The menu is
    /// AppKit's: SwiftUI's `Menu` shows its items disabled in this non-activating panel, so nothing could be picked.
    private func menuPicker<Value: Hashable>(_ options: [(value: Value, label: String)], selection: Binding<Value>,
                                             help: String) -> some View {
        let selected = options.firstIndex { $0.value == selection.wrappedValue }
        return Button {
            OptionMenu.popUp(options.map(\.label), selected: selected) { selection.wrappedValue = options[$0].value }
        } label: {
            HStack(spacing: 5) {
                Text(selected.map { options[$0].label } ?? "")
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.leading, 9)
            .padding(.trailing, 7)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.fill2))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .pointingHand()
        .fixedSize()
        .help(help)
        .accessibilityLabel(help)
        .accessibilityValue(selected.map { options[$0].label } ?? "")
    }

    /// The spend chart's providers as a short stack in `colors`, so each option shows what it looks like.
    private func swatch(_ colors: SpendColors) -> some View {
        let palette = SpendPalette(style: colors, providers: ProviderID.allCases)
        return HStack(spacing: colors == .graphite ? 1 : 0) {
            ForEach(ProviderID.allCases) { Rectangle().fill(palette.color(for: $0)).frame(width: 3) }
        }
        .frame(height: 9)
        .clipShape(RoundedRectangle(cornerRadius: 2))
    }

    // MARK: Chips

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

    /// Offers or drops one of the lists under the spend chart; with all of them off the list goes.
    private func listChip(_ list: SpendBreakdown) -> some View {
        let settings = store.settings
        let on = settings.spendLists.contains(list)
        return Button {
            if on { settings.spendLists.remove(list) } else { settings.spendLists.insert(list) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: list.symbol).font(.system(size: 10)).opacity(on ? 1 : 0.6)
                Text(list.label)
            }
            .padding(.horizontal, 9)
            .chip(selected: on)
        }
        .buttonStyle(.plain)
        .help(on ? "Hide the \(list.label.lowercased()) list under the spend chart" : "Show \(list.label.lowercased()) under the spend chart")
        .accessibilityLabel("\(list.label) list")
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
                StatusItemPreview(state: state, rings: settings.menuBarRings, percent: settings.menuBarPercent,
                                  group: settings.menuBarGroup(for: provider))
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

    /// Tracked providers that meter model groups separately, so the menu bar has a group to pick.
    private var groupedProviders: [ProviderID] {
        store.settings.enabledProviders.filter { (store.state(for: $0).snapshot?.groups.count ?? 0) > 1 }
    }

    /// The model group the menu bar shows and the panel opens on; a group the provider stopped reporting reads
    /// as the default.
    private func groupControl(_ provider: ProviderID) -> some View {
        let settings = store.settings
        let groups = store.state(for: provider).snapshot?.groups ?? []
        let options: [(value: String?, label: String)] = [(nil, "Closest to limit")] + groups.map { ($0, $0) }
        return menuPicker(options, selection: Binding(
            get: { settings.menuBarGroup(for: provider).flatMap { groups.contains($0) ? $0 : nil } },
            set: { settings.setMenuBarGroup($0, for: provider) }),
                          help: "The \(provider.displayName) model group the menu bar shows")
    }

    /// A titled card of rows; areas of the app each get one.
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.leading, 12)
            VStack(spacing: 0) { content() }
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill1))
        }
    }

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
    let group: String?

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: StatusIcon.image(for: state, rings: rings, group: group))
                .renderingMode(.template)
            if let text = StatusIcon.percentText(for: state.snapshot, mode: percent, group: group) {
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
            .pointingHand()
    }
}

private extension SpendBreakdown {
    var symbol: String {
        switch self {
        case .models: "cpu"
        case .projects: "folder"
        case .sources: "terminal"
        }
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

/// The settings dropdowns' menu, popped up under the pointer with the current choice beneath it, as a pop-up
/// button opens.
private enum OptionMenu {
    static func popUp(_ labels: [String], selected: Int?, choose: @escaping (Int) -> Void) {
        let handler = Handler(choose: choose)
        let menu = NSMenu()
        for (index, label) in labels.enumerated() {
            let item = NSMenuItem(title: label, action: #selector(Handler.pick(_:)), keyEquivalent: "")
            item.target = handler
            item.tag = index
            item.state = index == selected ? .on : .off
            menu.addItem(item)
        }
        // Runs the menu until it closes; the items only hold the handler weakly.
        withExtendedLifetime(handler) {
            _ = menu.popUp(positioning: selected.flatMap { menu.item(at: $0) }, at: NSEvent.mouseLocation, in: nil)
        }
    }

    private final class Handler: NSObject {
        let choose: (Int) -> Void
        init(choose: @escaping (Int) -> Void) { self.choose = choose }
        @objc func pick(_ item: NSMenuItem) { choose(item.tag) }
    }
}
