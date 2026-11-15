import AppKit
import Sparkle

/// Sparkle updates from the appcast published with each GitHub release (`SUFeedURL` in Info.plist).
/// Only runs from a real .app bundle, so `swift run` builds don't raise update errors.
final class Updater: NSObject, SPUStandardUserDriverDelegate {
    private var controller: SPUStandardUpdaterController?

    var isAvailable: Bool { controller != nil }

    override init() {
        super.init()
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
    }

    var automaticallyChecks: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    /// A menu bar app has no window to come forward; let Sparkle show scheduled updates gently.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    static var versionString: String {
        let info = Bundle.main.infoDictionary
        return info?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
