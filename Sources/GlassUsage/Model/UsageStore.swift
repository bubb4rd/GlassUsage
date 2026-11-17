import AppKit
import Observation

@Observable
final class UsageStore {
    private(set) var states: [ProviderID: ProviderState] = [:]
    private(set) var isRefreshing = false
    private(set) var lastRefresh: Date?
    /// Token and spend reports from local agent logs.
    private(set) var localReports: [ProviderID: LocalUsageReport] = [:]
    private(set) var isScanningLogs = false

    let settings: AppSettings
    /// Near-limit and reset notifications for tracked providers.
    let alerts = LimitAlerts()

    private var loop: Task<Void, Never>?
    /// Providers the usage service rate limited: when to ask again, and how many limits in a row.
    @ObservationIgnored private var backoff: [ProviderID: (until: Date, strikes: Int)] = [:]
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    private static let snapshotsKey = "lastSnapshots"

    init(settings: AppSettings) {
        self.settings = settings
        restoreSnapshots()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Readings from before the sleep are stale; give the network a moment to come back first.
            MainActor.assumeIsolated { self?.start(after: .seconds(5)) }
        }
    }

    func state(for provider: ProviderID) -> ProviderState {
        states[provider] ?? ProviderState()
    }

    /// The provider the menu bar shows: the chosen one while it has a reading, otherwise the first
    /// enabled provider that does, otherwise the first enabled one.
    var menuBarProvider: ProviderID? {
        let enabled = settings.enabledProviders
        let withReading = enabled.filter { states[$0]?.snapshot != nil }
        if withReading.contains(settings.menuBarProvider) { return settings.menuBarProvider }
        if let first = withReading.first { return first }
        return enabled.contains(settings.menuBarProvider) ? settings.menuBarProvider : enabled.first
    }

    /// (Re)starts the refresh loop: a refresh now (or after `delay`), then one per refresh interval.
    func start(after delay: Duration = .zero) {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.nextRefreshDelay()))
            }
        }
    }

    /// The refresh interval, cut short so a fresh reading lands just after a window resets.
    private func nextRefreshDelay(now: Date = .now) -> TimeInterval {
        let interval = TimeInterval(settings.refreshMinutes * 60)
        let reset = settings.enabledProviders.compactMap { states[$0]?.snapshot?.nextReset(after: now) }.min()
        guard let reset else { return interval }
        return min(interval, max(reset.timeIntervalSince(now) + 5, 30))
    }

    /// Refresh unless data is younger than `maxAge`.
    func refreshIfStale(maxAge: TimeInterval = 60) {
        guard !isRefreshing else { return }
        if let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < maxAge { return }
        Task { await refresh() }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = .now
        }
        // Log scanning is independent of the network; don't make the gauges wait for it.
        Task { await scanLocalLogs() }
        let now = Date.now
        await withTaskGroup(of: (ProviderID, Result<ProviderSnapshot, ProviderError>).self) { group in
            // A rate-limited provider keeps its reading and error until its backoff ends, even on ⌘R.
            for provider in settings.enabledProviders where (backoff[provider]?.until ?? .distantPast) <= now {
                states[provider, default: ProviderState()].isLoading = true
                group.addTask { (provider, await Self.fetch(provider)) }
            }
            for await (provider, result) in group {
                var state = states[provider, default: ProviderState()]
                state.isLoading = false
                switch result {
                case .success(let snapshot):
                    state.snapshot = snapshot
                    state.error = nil
                    backoff[provider] = nil
                    alerts.check(snapshot, level: settings.limitAlert)
                case .failure(.rateLimited(let until)):
                    // The service's Retry-After when it sends one, else 5, 10, 20… minutes, at most an hour.
                    let strikes = (backoff[provider]?.strikes ?? 0) + 1
                    let fallback = now.addingTimeInterval(min(300 * pow(2, Double(strikes - 1)), 3600))
                    let retryAt = min(until ?? fallback, now.addingTimeInterval(3600))
                    backoff[provider] = (retryAt, strikes)
                    state.error = .rateLimited(until: retryAt)
                case .failure(let error):
                    // Keep the last good reading on screen; its timestamp shows its age.
                    state.error = error
                    if error.isNotConnected { state.snapshot = nil }
                }
                states[provider] = state
            }
        }
        persistSnapshots()
    }

    func scanLocalLogs() async {
        guard !isScanningLogs else { return }
        isScanningLogs = true
        defer { isScanningLogs = false }
        localReports = await LocalUsageScanner.shared.scan()
    }

    @concurrent
    private nonisolated static func fetch(_ provider: ProviderID) async -> Result<ProviderSnapshot, ProviderError> {
        do {
            switch provider {
            case .claude: return .success(try await ClaudeProvider.fetch())
            case .codex: return .success(try await CodexProvider.fetch())
            case .antigravity: return .success(try await AntigravityProvider.fetch())
            case .muse: return .success(try await MuseProvider.fetch())
            }
        } catch let error as ProviderError {
            return .failure(error)
        } catch let error as URLError {
            return .failure(.network(error.code == .notConnectedToInternet ? "You're offline." : error.localizedDescription))
        } catch {
            return .failure(.network(error.localizedDescription))
        }
    }

    private func persistSnapshots() {
        let snapshots = states.values.compactMap(\.snapshot)
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: Self.snapshotsKey)
        }
    }

    private func restoreSnapshots() {
        guard let data = UserDefaults.standard.data(forKey: Self.snapshotsKey),
              let snapshots = try? JSONDecoder().decode([ProviderSnapshot].self, from: data) else { return }
        for snapshot in snapshots {
            states[snapshot.provider] = ProviderState(snapshot: snapshot)
        }
    }
}
