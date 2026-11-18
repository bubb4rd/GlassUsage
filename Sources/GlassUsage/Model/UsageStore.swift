import AppKit
import Network
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
    @ObservationIgnored private let pathMonitor = NWPathMonitor()
    @ObservationIgnored private var isOnline: Bool?
    private static let snapshotsKey = "lastSnapshots"

    init(settings: AppSettings) {
        self.settings = settings
        restoreSnapshots()
        rescanWhenFolderAccessChanges()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Readings from before the sleep are stale; give the network a moment to come back first.
            MainActor.assumeIsolated { self?.start(after: .seconds(5)) }
        }
        // Waking often beats the network back by more than those 5 s; refresh again once it's up, rather than
        // leaving the failed readings until the next interval.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated {
                guard let self else { return }
                let online = path.status == .satisfied
                defer { self.isOnline = online }
                if online, self.isOnline == false { self.start(after: .seconds(2)) }
            }
        }
        pathMonitor.start(queue: .main)
    }

    func state(for provider: ProviderID) -> ProviderState {
        states[provider] ?? ProviderState()
    }

    /// Turning on `readProtectedFolders` can merge projects in Documents into their repositories; show that now
    /// rather than at the next refresh. `scanLocalLogs` rereads the setting, so a change mid-scan isn't lost.
    private func rescanWhenFolderAccessChanges() {
        withObservationTracking { _ = settings.readProtectedFolders } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rescanWhenFolderAccessChanges()
                await self.scanLocalLogs()
            }
        }
    }

    /// `layout` (by default the menu bar's) as drawn from the latest readings. A provider that isn't tracked has
    /// no reading to give, so its rings draw empty.
    func menuBarIcons(_ layout: MenuBarLayout? = nil, now: Date = .now) -> [ResolvedIcon] {
        (layout ?? settings.menuBarLayout).resolve(now: now) { settings.isEnabled($0) ? state(for: $0) : nil }
    }

    /// (Re)starts the refresh loop: a refresh now (or after `delay`), then one per refresh interval.
    func start(after delay: Duration = .zero) {
        loop?.cancel()
        loop = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                guard let self else { return }
                // Its own task, so restarting the loop (wake, a new interval) doesn't cancel a refresh mid-request
                // and show its providers as failed.
                await Task { await self.refresh() }.value
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
        var readProtected: Bool
        repeat {
            readProtected = settings.readProtectedFolders
            localReports = await LocalUsageScanner.shared.scan(readProtectedFolders: readProtected)
        } while readProtected != settings.readProtectedFolders
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
