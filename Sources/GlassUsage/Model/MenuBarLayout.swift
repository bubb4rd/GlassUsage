import Foundation

/// What the menu bar draws: one to three icons left to right, each one ring or two concentric ones, and each ring
/// reading any tracked provider's window. Each icon has its own percentage.
nonisolated struct MenuBarLayout: Codable, Hashable, Sendable {
    static let maxIcons = 3

    var icons: [MenuBarIcon]
}

nonisolated struct MenuBarIcon: Codable, Hashable, Sendable {
    var outer: RingSource
    /// Nil draws the outer ring alone.
    var inner: RingSource?
    var percent: IconPercent

    /// Outer first.
    var rings: [RingSource] { [outer] + (inner.map { [$0] } ?? []) }

    /// The providers its rings read, outer first, each once.
    var providers: [ProviderID] { inner.map { $0.provider == outer.provider ? [outer.provider] : [outer.provider, $0.provider] } ?? [outer.provider] }
}

/// The window a ring reads.
nonisolated struct RingSource: Codable, Hashable, Sendable {
    var provider: ProviderID
    var window: RingWindow
    /// For providers that meter model groups separately (Antigravity), the group to read; nil, or a group the
    /// provider no longer reports, follows the group closest to its limit.
    var group: String? = nil
}

nonisolated enum RingWindow: String, Codable, CaseIterable, Sendable {
    /// The session window (shorter than a day).
    case session
    /// The longest window: the week, or the month on some Codex plans.
    case long
    /// Whichever of the provider's windows is closest to its limit.
    case closest

    var label: String {
        switch self {
        case .session: "Session"
        case .long: "Week"
        case .closest: "Closest"
        }
    }
}

/// The percentage beside an icon: none, its ring closest to the limit, one ring's, or both side by side.
nonisolated enum IconPercent: String, Codable, CaseIterable, Sendable {
    case off, highest, outer, inner, both
}

/// Which ring of an icon.
nonisolated enum RingSlot: Hashable, Sendable {
    case outer, inner
}

/// What an icon of several draws, picked as a whole: one window as a single ring, or the week outside and the
/// session inside.
nonisolated enum IconSpan: Hashable, CaseIterable, Sendable {
    case session, week, both

    var label: String {
        switch self {
        case .session: "Session"
        case .week: "Week"
        case .both: "Both"
        }
    }
}

nonisolated enum MenuBarPreset: CaseIterable, Sendable {
    /// One provider: the week outside, the session inside.
    case classic
    /// Two providers' weeks, one outside the other.
    case duo
    /// An icon per provider, up to three.
    case sideBySide

    var label: String {
        switch self {
        case .classic: "Classic"
        case .duo: "Duo"
        case .sideBySide: "Side by side"
        }
    }
}

// MARK: Presets and migration

nonisolated extension MenuBarLayout {
    static func classic(_ provider: ProviderID, group: String? = nil) -> MenuBarLayout {
        MenuBarLayout(icons: [.both(provider, group: group, percent: .highest)])
    }

    /// Two layouts are presets of the same kind when they match after their groups are dropped, so a preset keeps
    /// the groups picked for its providers.
    static func preset(_ preset: MenuBarPreset, providers: [ProviderID], groups: [ProviderID: String] = [:]) -> MenuBarLayout? {
        guard let first = providers.first else { return nil }
        switch preset {
        case .classic:
            return classic(first, group: groups[first])
        case .duo:
            guard providers.count > 1 else { return nil }
            let second = providers[1]
            return MenuBarLayout(icons: [MenuBarIcon(
                outer: RingSource(provider: first, window: .long, group: groups[first]),
                inner: RingSource(provider: second, window: .long, group: groups[second]),
                percent: .both)])
        case .sideBySide:
            // Side by side gets wide fast; the numbers are left off so it stays clear of the notch.
            guard providers.count > 1 else { return nil }
            return MenuBarLayout(icons: providers.prefix(maxIcons).map { .both($0, group: groups[$0], percent: .off) })
        }
    }

    /// The presets on offer for these tracked providers, ordered as the menu bar shows them now, keeping the
    /// groups this layout picked.
    func presets(tracked: [ProviderID]) -> [(preset: MenuBarPreset, layout: MenuBarLayout)] {
        let providers = ordered(tracked)
        var groups: [ProviderID: String] = [:]
        for ring in icons.flatMap(\.rings) where groups[ring.provider] == nil { groups[ring.provider] = ring.group }
        return MenuBarPreset.allCases.compactMap { preset in
            Self.preset(preset, providers: providers, groups: groups).map { (preset, $0) }
        }
    }

    /// `providers` with the ones this layout shows first, left to right and outside in, then the rest in their order.
    func ordered(_ providers: [ProviderID]) -> [ProviderID] {
        var shown: [ProviderID] = []
        for ring in icons.flatMap(\.rings) where providers.contains(ring.provider) && !shown.contains(ring.provider) {
            shown.append(ring.provider)
        }
        return shown + providers.filter { !shown.contains($0) }
    }

    /// The single icon 1.4 drew from its menu bar settings, stored as raw strings: `rings` "both", "session" or
    /// "weekly"; `percent` "off", "highest", "session", "weekly" or "both". A percentage of a window the icon
    /// didn't draw becomes the drawn ring's.
    static func legacy(provider: ProviderID, group: String?, rings: String?, percent: String?) -> MenuBarLayout {
        let session = RingSource(provider: provider, window: .session, group: group)
        let long = RingSource(provider: provider, window: .long, group: group)
        let icon: MenuBarIcon = switch rings {
        case "session": MenuBarIcon(outer: session, inner: nil, percent: .highest)
        case "weekly": MenuBarIcon(outer: long, inner: nil, percent: .highest)
        default: MenuBarIcon(outer: long, inner: session, percent: .highest)
        }
        let two = icon.inner != nil
        var migrated = icon
        migrated.percent = switch percent {
        case "off": .off
        case "session" where two: .inner
        case "weekly" where two: .outer
        case "both" where two: .both
        default: .highest
        }
        return MenuBarLayout(icons: [migrated])
    }
}

nonisolated extension MenuBarIcon {
    static func both(_ provider: ProviderID, group: String? = nil, percent: IconPercent) -> MenuBarIcon {
        MenuBarIcon(outer: RingSource(provider: provider, window: .long, group: group),
                    inner: RingSource(provider: provider, window: .session, group: group), percent: percent)
    }
}

// MARK: Editing

nonisolated extension MenuBarIcon {
    subscript(slot: RingSlot) -> RingSource? {
        switch slot {
        case .outer: outer
        case .inner: inner
        }
    }

    /// Points a ring at another provider, back on the group closest to its limit.
    mutating func setProvider(_ provider: ProviderID, slot: RingSlot) {
        switch slot {
        case .outer: outer = RingSource(provider: provider, window: outer.window)
        case .inner: inner = inner.map { RingSource(provider: provider, window: $0.window) }
        }
    }

    mutating func setWindow(_ window: RingWindow, slot: RingSlot) {
        switch slot {
        case .outer: outer.window = window
        case .inner: inner?.window = window
        }
    }

    mutating func setGroup(_ group: String?, slot: RingSlot) {
        switch slot {
        case .outer: outer.group = group
        case .inner: inner?.group = group
        }
    }

    /// The icon's provider, picked as a whole: every ring reads it.
    mutating func setProvider(_ provider: ProviderID) {
        setProvider(provider, slot: .outer)
        setProvider(provider, slot: .inner)
    }

    mutating func setGroup(_ group: String?) {
        setGroup(group, slot: .outer)
        setGroup(group, slot: .inner)
    }

    /// Nil when the rings don't make one of the spans: a ring on the closest window, or rings of two providers.
    var span: IconSpan? {
        if let inner {
            return outer.window == .long && inner.window == .session && inner.provider == outer.provider ? .both : nil
        }
        return switch outer.window {
        case .session: .session
        case .long: .week
        case .closest: nil
        }
    }

    /// Redraws the icon as `span` of the outer ring's provider and group.
    mutating func setSpan(_ span: IconSpan) {
        let (provider, group) = (outer.provider, outer.group)
        switch span {
        case .session: outer = RingSource(provider: provider, window: .session, group: group); inner = nil
        case .week: outer = RingSource(provider: provider, window: .long, group: group); inner = nil
        case .both: self = .both(provider, group: group, percent: percent)
        }
        fitPercent()
    }

    /// A second ring inside a single one, on the provider's other window.
    mutating func addInnerRing() {
        guard inner == nil else { return }
        inner = RingSource(provider: outer.provider, window: outer.window == .session ? .long : .session, group: outer.group)
    }

    /// Takes one of two rings away; the inner one moves out when the outer goes.
    mutating func removeRing(_ slot: RingSlot) {
        guard let inner else { return }
        if slot == .outer { outer = inner }
        self.inner = nil
        fitPercent()
    }

    /// The percentages that name a ring, offered with two rings only; with one, the icon's percentage is on or off.
    mutating func fitPercent() {
        if inner == nil, percent != .off { percent = .highest }
    }
}

nonisolated extension MenuBarLayout {
    /// Whether `add` has room: a ring inside a single-ring icon, or another icon.
    var canAdd: Bool { (icons.count == 1 && icons[0].inner == nil) || icons.count < Self.maxIcons }

    /// One ring more: inside the only icon while it's a single ring, otherwise a new icon for the first tracked
    /// provider the menu bar doesn't show yet. Returns the index of the icon that changed or was added.
    @discardableResult
    mutating func add(tracked: [ProviderID]) -> Int? {
        if icons.count == 1, icons[0].inner == nil {
            icons[0].addInnerRing()
            return 0
        }
        guard icons.count < Self.maxIcons, let fallback = icons.last?.outer.provider else { return nil }
        let shown = Set(icons.flatMap(\.rings).map(\.provider))
        let provider = tracked.first { !shown.contains($0) } ?? fallback
        icons.append(.both(provider, percent: .off))
        return icons.count - 1
    }

    /// Never the last icon: the menu bar always draws one.
    mutating func removeIcon(at index: Int) {
        guard icons.count > 1, icons.indices.contains(index) else { return }
        icons.remove(at: index)
    }
}

// MARK: Reading

/// A ring as the menu bar draws it.
nonisolated struct ResolvedRing: Hashable, Sendable {
    let source: RingSource
    /// Nil while the provider has no reading: an empty track.
    let window: UsageWindow?
    /// The reading is missing, failed, or older than `StatusIcon.staleAfter`.
    let dimmed: Bool
}

/// An icon as the menu bar draws it: the rings that have a window to show, and its percentage.
nonisolated struct ResolvedIcon: Hashable, Sendable {
    let icon: MenuBarIcon
    /// Outer first. Empty when neither ring's window is reported: the icon draws an empty, dimmed track.
    let rings: [ResolvedRing]
    let percentText: String?
}

extension RingSource {
    /// Nil when the provider's reading has no such window (Muse Code reports no session): the ring is left out
    /// rather than drawn empty for good. A ring without a reading draws an empty track, dimmed.
    func resolve(_ state: ProviderState?, now: Date) -> ResolvedRing? {
        guard let state, let snapshot = state.snapshot else { return ResolvedRing(source: self, window: nil, dimmed: true) }
        let reading = snapshot.current(at: now).menuBarReading(preferring: group)
        let shown: UsageWindow? = switch window {
        case .session: reading.sessionWindow
        case .long: reading.longWindow
        case .closest: reading.mostConstrained
        }
        guard let shown else { return nil }
        let stale = now.timeIntervalSince(snapshot.fetchedAt) > StatusIcon.staleAfter
        return ResolvedRing(source: self, window: shown, dimmed: stale || state.error != nil)
    }
}

extension MenuBarLayout {
    /// `state` returns nil for a provider that isn't tracked, so its rings draw empty rather than an old reading.
    func resolve(now: Date, state: (ProviderID) -> ProviderState?) -> [ResolvedIcon] {
        icons.map { icon in
            let outer = icon.outer.resolve(state(icon.outer.provider), now: now)
            let inner = icon.inner.flatMap { $0.resolve(state($0.provider), now: now) }
            func percent(_ ring: ResolvedRing?) -> String? { ring?.window.map { "\(Int($0.percent.rounded()))%" } }
            let text: String? = switch icon.percent {
            case .off: nil
            case .highest: percent([outer, inner].compactMap(\.self).max { ($0.window?.percent ?? -1) < ($1.window?.percent ?? -1) })
            case .outer: percent(outer)
            case .inner: percent(inner)
            case .both:
                [outer, inner].compactMap(percent).nilIfEmpty?.joined(separator: " · ")
            }
            return ResolvedIcon(icon: icon, rings: [outer, inner].compactMap(\.self), percentText: text)
        }
    }
}

private extension Array {
    nonisolated var nilIfEmpty: Self? { isEmpty ? nil : self }
}
