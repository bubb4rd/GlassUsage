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
    /// Which windows the menu bar glyph draws as rings.
    var menuBarRings: MenuBarRings { didSet { defaults.set(menuBarRings.rawValue, forKey: Keys.rings) } }
    /// Which percentage the menu bar shows next to the glyph.
    var menuBarPercent: MenuBarPercent { didSet { defaults.set(menuBarPercent.rawValue, forKey: Keys.percent) } }
    var menuBarProvider: ProviderID { didSet { defaults.set(menuBarProvider.rawValue, forKey: Keys.menuBarProvider) } }
    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: Keys.refresh) } }
    /// Show the token-spend block (totals, days, mix, models) below the limits.
    var showSpend: Bool { didSet { defaults.set(showSpend, forKey: Keys.spend) } }
    /// How the spend block draws the days.
    var spendView: SpendView { didSet { defaults.set(spendView.rawValue, forKey: Keys.spendView) } }
    /// Notify when a tracked limit reaches this level, and again when that window resets.
    var limitAlert: LimitAlertLevel { didSet { defaults.set(limitAlert.rawValue, forKey: Keys.limitAlert) } }
    /// Look for project logos in folders macOS guards (Documents, Desktop, Downloads, cloud and external drives),
    /// which asks for access the first time. Elsewhere logos need no permission and are always looked up.
    var logosFromProtectedFolders: Bool { didSet { defaults.set(logosFromProtectedFolders, forKey: Keys.protectedLogos) } }
    /// The Projects list's offer to turn `logosFromProtectedFolders` on was closed.
    var logoHintDismissed: Bool { didSet { defaults.set(logoHintDismissed, forKey: Keys.logoHintDismissed) } }

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
        // Track every provider whose CLI has been set up on this Mac; Antigravity also through T3 Code.
        let installed: [ProviderID: [String]] = [
            .claude: [URL.homeDirectory.appending(path: ".claude").path],
            .codex: [CodexProvider.authFileURL.path],
            .antigravity: [AntigravityProvider.stateDirectory.path, AntigravityLogs.t3ProfilesDirectory.path],
            .muse: [MuseProvider.authFileURL.path],
        ]
        var registered: [String: Any] = [
            Keys.hover: false,
            Keys.rings: MenuBarRings.both.rawValue,
            Keys.percent: MenuBarPercent.highest.rawValue,
            Keys.spend: true,
            Keys.menuBarProvider: ProviderID.claude.rawValue,
            Keys.refresh: 5,
            Keys.protectedLogos: false,
            Keys.logoHintDismissed: false,
        ]
        for (provider, paths) in installed { registered[Keys.enabled(provider)] = paths.contains(where: fm.fileExists) }
        defaults.register(defaults: registered)
        // 1.1 stored the percentage as an on/off switch; carry "off" over.
        if let legacy = defaults.object(forKey: Keys.legacyPercent) as? Bool {
            if !legacy { defaults.set(MenuBarPercent.off.rawValue, forKey: Keys.percent) }
            defaults.removeObject(forKey: Keys.legacyPercent)
        }
        let defaults = defaults
        enabled = Set(ProviderID.allCases.filter { defaults.bool(forKey: Keys.enabled($0)) })
        openOnHover = defaults.bool(forKey: Keys.hover)
        menuBarRings = MenuBarRings(rawValue: defaults.string(forKey: Keys.rings) ?? "") ?? .both
        menuBarPercent = MenuBarPercent(rawValue: defaults.string(forKey: Keys.percent) ?? "") ?? .highest
        menuBarProvider = ProviderID(rawValue: defaults.string(forKey: Keys.menuBarProvider) ?? "") ?? .claude
        refreshMinutes = defaults.integer(forKey: Keys.refresh)
        showSpend = defaults.bool(forKey: Keys.spend)
        spendView = SpendView(rawValue: defaults.string(forKey: Keys.spendView) ?? "") ?? .ledger
        limitAlert = LimitAlertLevel(rawValue: defaults.string(forKey: Keys.limitAlert) ?? "") ?? .off
        logosFromProtectedFolders = defaults.bool(forKey: Keys.protectedLogos)
        logoHintDismissed = defaults.bool(forKey: Keys.logoHintDismissed)
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
        static let rings = "menuBarRings"
        static let percent = "menuBarPercent"
        static let legacyPercent = "showPercentInMenuBar"
        static let spend = "showSpend"
        static let spendView = "spendView"
        static let menuBarProvider = "menuBarProvider"
        static let refresh = "refreshMinutes"
        static let limitAlert = "limitAlert"
        static let protectedLogos = "logosFromProtectedFolders"
        static let logoHintDismissed = "logoHintDismissed"
    }
}

/// The share of a limit that triggers a notification, at the ring color bands, or no notifications.
enum LimitAlertLevel: String, CaseIterable {
    case off, half = "50", threeQuarters = "75", nearlyFull = "90"

    var threshold: Double? { Double(rawValue) }
    var label: String { threshold.map { "\(Int($0))%" } ?? "Off" }
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

/// The windows the menu bar glyph draws: session inside and the longest window (week, or month) outside,
/// or one of them alone as a single ring.
enum MenuBarRings: String, CaseIterable {
    case both, session, weekly

    var label: String {
        switch self {
        case .both: "Both"
        case .session: "Session"
        case .weekly: "Weekly"
        }
    }
}

/// The percentage beside the glyph: none, the limit closest to running out, one window, or session and
/// longest window side by side.
enum MenuBarPercent: String, CaseIterable {
    case off, highest, session, weekly, both

    var label: String {
        switch self {
        case .off: "Off"
        case .highest: "Max"
        case .session: "Session"
        case .weekly: "Weekly"
        case .both: "Both"
        }
    }
}
