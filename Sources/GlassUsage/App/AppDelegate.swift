import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore!
    private var statusController: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let settings = AppSettings()
        store = UsageStore(settings: settings)
        statusController = StatusItemController(store: store)
        store.start()
    }
}
