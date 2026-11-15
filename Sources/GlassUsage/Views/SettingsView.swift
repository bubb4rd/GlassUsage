import SwiftUI

struct SettingsView: View {
    let store: UsageStore
    let onBack: () -> Void
    let onQuit: () -> Void

    var body: some View {
        @Bindable var settings = store.settings

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                IconButton(symbol: "chevron.left", help: "Back", action: onBack)
                Text("Settings").font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            .frame(height: 28)
            .padding(.leading, -6)

            section("Menu bar shows") {
                PillPicker(options: ProviderID.allCases.map { ($0, $0.displayName) }, selection: $settings.menuBarProvider)
            }
            group {
                row("Percentage") { Toggle("Percentage", isOn: $settings.showPercentInMenuBar) }
                divider
                row("Open on hover") { Toggle("Open on hover", isOn: $settings.openOnHover) }
            }
            .padding(.top, 8)

            section("Plan limits") {
                group {
                    ForEach(Array(ProviderID.allCases.enumerated()), id: \.element) { index, provider in
                        if index > 0 { divider }
                        HStack(spacing: 8) {
                            ProviderLogo(provider: provider)
                            Text(provider.displayName)
                            Spacer()
                            if let status = status(provider) {
                                Text(status).font(.system(size: 11.5)).foregroundStyle(.tertiary)
                            }
                            Toggle(provider.displayName, isOn: Binding(
                                get: { settings.isEnabled(provider) },
                                set: { enabled in
                                    settings.setEnabled(provider, enabled)
                                    if enabled { Task { await store.refresh() } }
                                }))
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                    }
                }
                note("Reads Claude Code's Keychain login and Codex's auth.json. Tokens are only read, never refreshed or stored.")
            }

            section("General") {
                group {
                    row("Check limits every") {
                        Picker("Check limits every", selection: Binding(
                            get: { settings.refreshMinutes },
                            set: { settings.refreshMinutes = $0; store.start() })) {
                            ForEach(AppSettings.refreshChoices, id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .fixedSize()
                    }
                    divider
                    row("Launch at login") { Toggle("Launch at login", isOn: $settings.launchAtLogin) }
                }
                note("Token spend comes from Claude Code, Codex CLI and omp logs on this Mac, priced with LiteLLM's public list.")
            }

            HStack {
                Text("GlassUsage 1.0 · logs stay on this Mac")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit", action: onQuit)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .keyboardShortcut("q")
            }
            .padding(.top, 16)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
        .tint(Theme.good)
        .labelsHidden()
    }

    private func status(_ provider: ProviderID) -> String? {
        let state = store.state(for: provider)
        if state.snapshot != nil { return nil }
        if let error = state.error { return error.isNotConnected ? "not found" : "unreachable" }
        return nil
    }

    private var divider: some View {
        Rectangle().fill(Theme.hair).frame(height: 0.5).padding(.leading, 12)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Eyebrow(title)
            content()
        }
        .padding(.top, 16)
    }

    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill1))
    }

    private func row<Control: View>(_ label: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            Text(label)
            Spacer()
            control()
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }
}
