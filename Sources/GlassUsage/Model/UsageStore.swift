import Foundation
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

    private var loop: Task<Void, Never>?
    private static let snapshotsKey = "lastSnapshots"

    init(settings: AppSettings) {
        self.settings = settings
        restoreSnapshots()
    }

    func state(for provider: ProviderID) -> ProviderState {
        states[provider] ?? ProviderState()
    }

    func start() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: .seconds(self.settings.refreshMinutes * 60))
            }
        }
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
        await withTaskGroup(of: (ProviderID, Result<ProviderSnapshot, ProviderError>).self) { group in
            for provider in settings.enabledProviders {
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
