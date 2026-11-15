import Foundation
import Observation
import ServiceManagement

@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    var claudeEnabled: Bool { didSet { defaults.set(claudeEnabled, forKey: Keys.claude) } }
    var codexEnabled: Bool { didSet { defaults.set(codexEnabled, forKey: Keys.codex) } }
    /// Peek at usage by hovering the menu bar icon, in addition to clicking.
    var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: Keys.hover) } }
    var showPercentInMenuBar: Bool { didSet { defaults.set(showPercentInMenuBar, forKey: Keys.percent) } }
    var menuBarProvider: ProviderID { didSet { defaults.set(menuBarProvider.rawValue, forKey: Keys.menuBarProvider) } }
    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: Keys.refresh) } }
    /// Show the token-spend sections (hero, daily bars, mix, models) above the limits.
    var showSpend: Bool { didSet { defaults.set(showSpend, forKey: Keys.spend) } }

    var launchAtLogin: Bool {
        get {
            access(keyPath: \.launchAtLogin)
            return SMAppService.mainApp.status == .enabled
        }
        set {
            withMutation(keyPath: \.launchAtLogin) {
                do {
                    if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                } catch {
                    NSLog("GlassUsage: launch at login change failed: \(error)")
                }
            }
        }
    }

    static let refreshChoices = [2, 5, 10, 15, 30]

    init() {
        let fm = FileManager.default
        let home = URL.homeDirectory
        defaults.register(defaults: [
            Keys.claude: fm.fileExists(atPath: home.appending(path: ".claude").path),
            Keys.codex: fm.fileExists(atPath: CodexProvider.authFileURL.path),
            Keys.hover: false,
            Keys.percent: true,
            Keys.spend: true,
            Keys.menuBarProvider: ProviderID.claude.rawValue,
            Keys.refresh: 5,
        ])
        claudeEnabled = defaults.bool(forKey: Keys.claude)
        codexEnabled = defaults.bool(forKey: Keys.codex)
        openOnHover = defaults.bool(forKey: Keys.hover)
        showPercentInMenuBar = defaults.bool(forKey: Keys.percent)
        menuBarProvider = ProviderID(rawValue: defaults.string(forKey: Keys.menuBarProvider) ?? "") ?? .claude
        refreshMinutes = defaults.integer(forKey: Keys.refresh)
        showSpend = defaults.bool(forKey: Keys.spend)
    }

    var enabledProviders: [ProviderID] {
        ProviderID.allCases.filter { isEnabled($0) }
    }

    func isEnabled(_ provider: ProviderID) -> Bool {
        switch provider {
        case .claude: claudeEnabled
        case .codex: codexEnabled
        }
    }

    func setEnabled(_ provider: ProviderID, _ enabled: Bool) {
        switch provider {
        case .claude: claudeEnabled = enabled
        case .codex: codexEnabled = enabled
        }
    }

    private enum Keys {
        static let claude = "provider.claude.enabled"
        static let codex = "provider.codex.enabled"
        static let hover = "openOnHover"
        static let percent = "showPercentInMenuBar"
        static let spend = "showSpend"
        static let menuBarProvider = "menuBarProvider"
        static let refresh = "refreshMinutes"
    }
}
