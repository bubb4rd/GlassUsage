import Foundation
import Observation
import UserNotifications

/// Decides which notifications a fresh reading earns: one when a window reaches the alert level, and one
/// when a window that alerted resets. `pending` holds the windows that alerted and are waiting for their reset.
enum LimitAlertRules {
    struct Pending: Codable, Equatable {
        /// "Claude session", kept so the reset alert can name a window the provider no longer reports.
        let label: String
        /// The reset the alerted window was heading for; nil when the provider gave none.
        let resetsAt: Date?
    }

    struct Alert: Equatable {
        /// Per window, so a reset alert replaces that window's near-limit alert in Notification Center.
        let id: String
        let title: String
        let body: String
    }

    static func evaluate(_ snapshot: ProviderSnapshot, threshold: Double, now: Date,
                         pending: inout [String: Pending]) -> [Alert] {
        let prefix = snapshot.provider.rawValue + "/"
        var alerts: [Alert] = []

        // Resets first, so a window whose new period is already past the level can alert again.
        for (key, sent) in pending.sorted(by: { $0.key < $1.key }) where key.hasPrefix(prefix) {
            let window = snapshot.windows.first { prefix + $0.id == key }
            // Without a reset time, the window counts as reset once it's back under the level (or gone).
            let didReset = sent.resetsAt.map { $0 <= now } ?? (window.map { $0.percent < threshold } ?? true)
            guard didReset else { continue }
            pending[key] = nil
            alerts.append(Alert(id: key, title: "\(sent.label) limit reset",
                                body: "Back to \(Format.percent(window?.percent ?? 0)) used."))
        }

        for window in snapshot.windows where window.percent >= threshold {
            let key = prefix + window.id
            guard pending[key] == nil else { continue }
            let label = label(snapshot.provider, window)
            pending[key] = Pending(label: label, resetsAt: window.resetsAt)
            let body = window.resetsAt.map { "Resets in \(Format.until($0, now: now)), \(Format.clock($0, now: now))." }
                ?? "Close to the limit."
            alerts.append(Alert(id: key, title: "\(label) at \(Format.percent(window.percent))", body: body))
        }
        return alerts
    }

    /// "Claude session", "Antigravity Gemini weekly".
    static func label(_ provider: ProviderID, _ window: UsageWindow) -> String {
        [provider.displayName, window.group, window.title.lowercased()].compactMap { $0 }.joined(separator: " ")
    }
}

/// Posts limit notifications for each fresh reading. Windows waiting for their reset alert are saved,
/// so a relaunch neither repeats an alert nor loses a reset.
@Observable
final class LimitAlerts: NSObject, UNUserNotificationCenterDelegate {
    /// Notifications for GlassUsage are turned off in System Settings.
    private(set) var isBlocked = false

    @ObservationIgnored private let center: UNUserNotificationCenter?
    @ObservationIgnored private var pending: [String: LimitAlertRules.Pending]
    private static let pendingKey = "limitAlertsPending"

    override init() {
        // The notification center needs an app bundle; `swift run` builds go without alerts.
        center = Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
        pending = UserDefaults.standard.data(forKey: Self.pendingKey)
            .flatMap { try? JSONDecoder().decode([String: LimitAlertRules.Pending].self, from: $0) } ?? [:]
        super.init()
        center?.delegate = self
    }

    /// Asks for permission (macOS prompts only the first time) and notes whether alerts can show.
    func requestPermission() async {
        guard let center else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        isBlocked = !granted
    }

    /// Re-reads the permission, which the user can change in System Settings at any time.
    func refreshPermission() async {
        guard let center else { return }
        isBlocked = await center.notificationSettings().authorizationStatus == .denied
    }

    /// Call with each successful reading of a tracked provider.
    func check(_ snapshot: ProviderSnapshot, level: LimitAlertLevel, now: Date = .now) {
        guard let threshold = level.threshold else {
            // Turning alerts off forgets what was pending, so turning them on starts fresh.
            if !pending.isEmpty { pending = [:]; save() }
            return
        }
        let alerts = LimitAlertRules.evaluate(snapshot, threshold: threshold, now: now, pending: &pending)
        guard !alerts.isEmpty else { return }
        save()
        for alert in alerts {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.sound = .default
            center?.add(UNNotificationRequest(identifier: alert.id, content: content, trigger: nil), withCompletionHandler: nil)
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(pending) {
            UserDefaults.standard.set(data, forKey: Self.pendingKey)
        }
    }

    /// Show alerts as banners even while the panel has GlassUsage in front.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
