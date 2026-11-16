import AppKit
import Observation
import Sparkle

/// Sparkle updates from the appcast published with each GitHub release (`SUFeedURL` in Info.plist).
/// Only runs from a real .app bundle, so `swift run` builds don't raise update errors.
@Observable
final class Updater: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController?

    /// Version of a newer release found by the last check, so Settings can point at it.
    private(set) var availableVersion: String?

    var isAvailable: Bool { controller != nil }

    override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: self)
        // Silent probe: fills `availableVersion` without showing any UI.
        controller?.updater.checkForUpdateInformation()
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
    }

    /// A menu bar app has no window to come forward; let Sparkle show scheduled updates gently.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
