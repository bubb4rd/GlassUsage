import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore!
    private var updater: Updater!
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings()
        store = UsageStore(settings: settings)
        updater = Updater()
        statusController = StatusItemController(store: store, updater: updater)
        store.start()
    }
}
