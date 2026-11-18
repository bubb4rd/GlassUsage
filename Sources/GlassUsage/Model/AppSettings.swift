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
    /// What the menu bar draws: its icons, their rings, and their percentages.
    var menuBarLayout: MenuBarLayout { didSet { defaults.set(Self.encode(menuBarLayout), forKey: Keys.menuBarLayout) } }
    /// The layout last made in Settings' ring editor, offered beside the presets so picking one doesn't lose it.
    var customMenuBarLayout: MenuBarLayout? {
        didSet { defaults.set(customMenuBarLayout.flatMap(Self.encode), forKey: Keys.customMenuBarLayout) }
    }
    /// For providers that meter model groups separately (Antigravity), the group the panel opens on, by provider
    /// id. A provider without one opens on the group closest to its limit.
    private var panelGroups: [String: String] { didSet { defaults.set(panelGroups, forKey: Keys.panelGroups) } }
    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: Keys.refresh) } }
    /// Show the token-spend block (totals, days, mix, models) below the limits.
    var showSpend: Bool { didSet { defaults.set(showSpend, forKey: Keys.spend) } }
    /// How the spend block draws the days.
    var spendView: SpendView { didSet { defaults.set(spendView.rawValue, forKey: Keys.spendView) } }
    /// Whether the spend charts tell providers apart by gray steps or by each provider's color.
    var spendColors: SpendColors { didSet { defaults.set(spendColors.rawValue, forKey: Keys.spendColors) } }
    /// Whether the spend block leads with dollars at API prices or with tokens, and ranks its lists by it.
    var spendUnit: SpendUnit { didSet { defaults.set(spendUnit.rawValue, forKey: Keys.spendUnit) } }
    /// Which lists the spend block offers under its chart; none hides the list.
    var spendLists: Set<SpendBreakdown> {
        didSet { defaults.set(SpendBreakdown.allCases.filter(spendLists.contains).map(\.rawValue), forKey: Keys.spendLists) }
    }
    /// Notify when a tracked limit reaches this level, and again when that window resets.
    var limitAlert: LimitAlertLevel { didSet { defaults.set(limitAlert.rawValue, forKey: Keys.limitAlert) } }
    /// Read project folders macOS guards (Documents, Desktop, Downloads, cloud and external drives), which asks for
    /// access the first time: for their logos, and to count a subfolder or worktree toward its repository.
    /// Folders elsewhere need no permission and are always read.
    var readProtectedFolders: Bool { didSet { defaults.set(readProtectedFolders, forKey: Keys.protectedFolders) } }
    /// The Projects list's offer to turn `readProtectedFolders` on was closed.
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
            Keys.spend: true,
            Keys.refresh: 5,
            Keys.protectedFolders: false,
            Keys.logoHintDismissed: false,
            Keys.spendLists: SpendBreakdown.allCases.map(\.rawValue),
        ]
        for (provider, paths) in installed { registered[Keys.enabled(provider)] = paths.contains(where: fm.fileExists) }
        defaults.register(defaults: registered)
        // 1.1 stored the percentage as an on/off switch; carry "off" over.
        if let legacy = defaults.object(forKey: Keys.legacyPercentSwitch) as? Bool {
            if !legacy { defaults.set("off", forKey: Keys.legacyPercent) }
            defaults.removeObject(forKey: Keys.legacyPercentSwitch)
        }
        let defaults = defaults
        let enabled = Set(ProviderID.allCases.filter { defaults.bool(forKey: Keys.enabled($0)) })
        self.enabled = enabled
        openOnHover = defaults.bool(forKey: Keys.hover)
        let panelGroups = defaults.dictionary(forKey: Keys.panelGroups) as? [String: String] ?? [:]
        self.panelGroups = panelGroups
        if let stored = Self.decode(defaults.data(forKey: Keys.menuBarLayout)), !stored.icons.isEmpty {
            menuBarLayout = stored
        } else {
            // Before 1.5 the menu bar drew one provider; draw what it drew. Its settings stay, for an older version.
            let provider = ProviderID(rawValue: defaults.string(forKey: Keys.legacyProvider) ?? "")
                ?? ProviderID.allCases.first(where: enabled.contains) ?? .claude
            let layout = MenuBarLayout.legacy(provider: provider, group: panelGroups[provider.rawValue],
                                              rings: defaults.string(forKey: Keys.legacyRings),
                                              percent: defaults.string(forKey: Keys.legacyPercent))
            menuBarLayout = layout
            defaults.set(Self.encode(layout), forKey: Keys.menuBarLayout)
        }
        customMenuBarLayout = Self.decode(defaults.data(forKey: Keys.customMenuBarLayout))
        refreshMinutes = defaults.integer(forKey: Keys.refresh)
        showSpend = defaults.bool(forKey: Keys.spend)
        spendView = SpendView(rawValue: defaults.string(forKey: Keys.spendView) ?? "") ?? .ledger
        // Graphite for new installs. A Mac that has run GlassUsage before (its support folder holds the price
        // list and log cache) keeps the provider colors it had. Stored now so the choice holds on later launches.
        let colors: SpendColors
        if let stored = SpendColors(rawValue: defaults.string(forKey: Keys.spendColors) ?? "") {
            colors = stored
        } else {
            colors = fm.fileExists(atPath: AppPaths.supportDirectory.path) ? .providers : .graphite
            defaults.set(colors.rawValue, forKey: Keys.spendColors)
        }
        spendColors = colors
        spendUnit = SpendUnit(rawValue: defaults.string(forKey: Keys.spendUnit) ?? "") ?? .value
        spendLists = Set((defaults.stringArray(forKey: Keys.spendLists) ?? []).compactMap(SpendBreakdown.init))
        limitAlert = LimitAlertLevel(rawValue: defaults.string(forKey: Keys.limitAlert) ?? "") ?? .off
        readProtectedFolders = defaults.bool(forKey: Keys.protectedFolders)
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

    /// The model group the panel opens on for `provider`.
    func panelGroup(for provider: ProviderID) -> String? {
        panelGroups[provider.rawValue]
    }

    /// Nil goes back to opening on the group closest to its limit.
    func setPanelGroup(_ group: String?, for provider: ProviderID) {
        panelGroups[provider.rawValue] = group
    }

    /// Tracked providers in the order the menu bar shows them, then the rest: the panel's order.
    var panelProviders: [ProviderID] { menuBarLayout.ordered(enabledProviders) }

    /// An edit made in Settings' ring editor; the result is also kept as the custom layout.
    func editMenuBarLayout(_ edit: (inout MenuBarLayout) -> Void) {
        var layout = menuBarLayout
        edit(&layout)
        guard layout != menuBarLayout else { return }
        menuBarLayout = layout
        customMenuBarLayout = layout
    }

    /// `spendLists` in tab order.
    var shownSpendLists: [SpendBreakdown] { SpendBreakdown.allCases.filter(spendLists.contains) }

    private static func encode(_ layout: MenuBarLayout) -> Data? { try? JSONEncoder().encode(layout) }

    private static func decode(_ data: Data?) -> MenuBarLayout? {
        data.flatMap { try? JSONDecoder().decode(MenuBarLayout.self, from: $0) }
    }

    private enum Keys {
        static func enabled(_ provider: ProviderID) -> String { "provider.\(provider.rawValue).enabled" }
        static let hover = "openOnHover"
        static let menuBarLayout = "menuBarLayout"
        static let customMenuBarLayout = "customMenuBarLayout"
        /// 1.4's menu bar settings, read once to carry them over and left in place.
        static let legacyProvider = "menuBarProvider"
        static let legacyRings = "menuBarRings"
        static let legacyPercent = "menuBarPercent"
        static let legacyPercentSwitch = "showPercentInMenuBar"
        static let spend = "showSpend"
        static let spendView = "spendView"
        static let spendColors = "spendColors"
        static let spendUnit = "spendUnit"
        static let spendLists = "spendLists"
        /// Named for 1.4, where the group picked for the menu bar was also the one the panel opened on.
        static let panelGroups = "menuBarGroups"
        static let refresh = "refreshMinutes"
        static let limitAlert = "limitAlert"
        /// Named for the setting's first use, project logos; kept so the choice carries over.
        static let protectedFolders = "logosFromProtectedFolders"
        static let logoHintDismissed = "logoHintDismissed"
    }
}

/// The share of a limit that triggers a notification, at the ring color bands, or no notifications.
enum LimitAlertLevel: String, CaseIterable {
    case off, half = "50", threeQuarters = "75", nearlyFull = "90"

    var threshold: Double? { Double(rawValue) }
    var label: String { threshold.map { "\(Int($0))%" } ?? "Off" }
}

/// Ledger: one bar per day. Calendar: weeks by weekday, shaded by each day's figure, with weekly totals.
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

/// How the spend charts tell providers apart. Graphite: gray steps, so color on the panel only marks limits.
/// Providers: each provider's identity color.
enum SpendColors: String, CaseIterable {
    case graphite, providers

    var label: String {
        switch self {
        case .graphite: "Graphite"
        case .providers: "Providers"
        }
    }
}
