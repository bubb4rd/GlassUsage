import Foundation
import Observation
import ServiceManagement

@Observable
final class AppSettings {
    private let defaults = UserDefaults.standard

    /// Providers whose limits are tracked; each is stored as `provider.<id>.enabled`.
    private var enabled: Set<ProviderID> {
        didSet {
            for provider in ProviderID.allCases {
                defaults.set(enabled.contains(provider), forKey: Keys.enabled(provider))
            }
        }
    }
    /// Peek at usage by hovering the menu bar icon, in addition to clicking.
    var openOnHover: Bool { didSet { defaults.set(openOnHover, forKey: Keys.hover) } }
    var showPercentInMenuBar: Bool { didSet { defaults.set(showPercentInMenuBar, forKey: Keys.percent) } }
    var menuBarProvider: ProviderID { didSet { defaults.set(menuBarProvider.rawValue, forKey: Keys.menuBarProvider) } }
    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: Keys.refresh) } }
    /// Show the token-spend block (totals, days, mix, models) below the limits.
    var showSpend: Bool { didSet { defaults.set(showSpend, forKey: Keys.spend) } }
    /// How the spend block draws the days.
    var spendView: SpendView { didSet { defaults.set(spendView.rawValue, forKey: Keys.spendView) } }

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
        // Track every provider whose CLI has been set up on this Mac.
        let installed: [ProviderID: String] = [
            .claude: URL.homeDirectory.appending(path: ".claude").path,
            .codex: CodexProvider.authFileURL.path,
            .antigravity: AntigravityProvider.stateDirectory.path,
            .muse: MuseProvider.authFileURL.path,
        ]
        var registered: [String: Any] = [
            Keys.hover: false,
            Keys.percent: true,
            Keys.spend: true,
            Keys.menuBarProvider: ProviderID.claude.rawValue,
            Keys.refresh: 5,
        ]
        for (provider, path) in installed { registered[Keys.enabled(provider)] = fm.fileExists(atPath: path) }
        defaults.register(defaults: registered)
        let defaults = defaults
        enabled = Set(ProviderID.allCases.filter { defaults.bool(forKey: Keys.enabled($0)) })
        openOnHover = defaults.bool(forKey: Keys.hover)
        showPercentInMenuBar = defaults.bool(forKey: Keys.percent)
        menuBarProvider = ProviderID(rawValue: defaults.string(forKey: Keys.menuBarProvider) ?? "") ?? .claude
        refreshMinutes = defaults.integer(forKey: Keys.refresh)
        showSpend = defaults.bool(forKey: Keys.spend)
        spendView = SpendView(rawValue: defaults.string(forKey: Keys.spendView) ?? "") ?? .ledger
    }

    var enabledProviders: [ProviderID] {
        ProviderID.allCases.filter { isEnabled($0) }
    }

    func isEnabled(_ provider: ProviderID) -> Bool {
        enabled.contains(provider)
    }

    func setEnabled(_ provider: ProviderID, _ isOn: Bool) {
        if isOn { enabled.insert(provider) } else { enabled.remove(provider) }
    }

    private enum Keys {
        static func enabled(_ provider: ProviderID) -> String { "provider.\(provider.rawValue).enabled" }
        static let hover = "openOnHover"
        static let percent = "showPercentInMenuBar"
        static let spend = "showSpend"
        static let spendView = "spendView"
        static let menuBarProvider = "menuBarProvider"
        static let refresh = "refreshMinutes"
    }
}

/// Ledger: one bar per day. Calendar: weeks by weekday, shaded by tokens, with weekly totals.
enum SpendView: String, CaseIterable {
    case ledger, calendar

    var label: String {
        switch self {
        case .ledger: "Ledger"
        case .calendar: "Calendar"
        }
    }

    var symbol: String {
        switch self {
        case .ledger: "chart.bar.fill"
        case .calendar: "square.grid.3x3.fill"
        }
    }
}
