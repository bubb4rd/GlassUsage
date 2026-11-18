import AppKit
import Observation
import SwiftUI

/// Owns the menu bar item and the glass panel that drops down from it.
/// Click toggles the panel; with "Open on hover" it also opens on hover. However it opened and whatever it shows,
/// the panel closes shortly after the pointer moves away from it and the icon.
final class StatusItemController: NSObject {
    private let store: UsageStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: GlassPanel
    private let panelModel = PanelModel()

    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var hoverTracker: HoverTracker?
    private var hoverOpenTask: Task<Void, Never>?
    private var leaveWatch: Timer?
    private var pointerLeftAt: CFTimeInterval?
    /// Opened by hover and not clicked since: a click on the icon then keeps it open instead of closing it,
    /// since it was most likely aimed at opening it.
    private var openedByHover = false
    private var anchor = NSPoint.zero

    private let updater: Updater

    init(store: UsageStore, updater: Updater) {
        self.store = store
        self.updater = updater
        panel = GlassPanel()
        super.init()

        let root = UsagePanelView(store: store, updater: updater, model: panelModel,
                                  onSizeChange: { [weak self] size in
                                      // Resizing the window inside SwiftUI's layout pass is ignored; do it next turn.
                                      DispatchQueue.main.async { self?.layoutPanel(size: size) }
                                  },
                                  onQuit: { NSApp.terminate(nil) })
        panel.setContent(root)
        updater.willShowWindow = { [weak self] in self?.hidePanel() }

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("GlassUsage")
            let tracker = HoverTracker(
                onEnter: { [weak self] in self?.pointerEnteredStatusItem() },
                onExit: { [weak self] in self?.hoverOpenTask?.cancel() })
            button.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                                  owner: tracker, userInfo: nil))
            hoverTracker = tracker
        }
        observeStore()
    }

    // MARK: Menu bar button

    private func observeStore() {
        withObservationTracking {
            updateButton()
        } onChange: {
            Task { @MainActor [weak self] in self?.observeStore() }
        }
    }

    private func updateButton() {
        guard let button = statusItem.button else { return }
        let provider = store.menuBarProvider
        let state = provider.map { store.state(for: $0) }
        let snapshot = state?.snapshot?.current(at: .now)

        let settings = store.settings
        button.image = StatusIcon.image(for: state, rings: settings.menuBarRings)

        if let percent = StatusIcon.percentText(for: snapshot, mode: settings.menuBarPercent) {
            button.attributedTitle = NSAttributedString(
                string: " \(percent)",
                attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)])
        } else {
            button.attributedTitle = NSAttributedString()
        }
        button.toolTip = panel.isPresented ? nil : snapshot.map(Self.tooltip) ?? "GlassUsage"
    }

    private static func tooltip(_ snapshot: ProviderSnapshot) -> String {
        let parts = snapshot.windows.map { "\($0.group.map { "\($0) " } ?? "")\($0.title) \(Int($0.percent.rounded()))%" }
        return "\(snapshot.provider.displayName): " + parts.joined(separator: " · ")
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        hoverOpenTask?.cancel()
        if panel.isPresented {
            if openedByHover { openedByHover = false } else { hidePanel() }
        } else {
            showPanel(byHover: false)
        }
    }

    private func showContextMenu() {
        hidePanel()
        let menu = NSMenu()
        menu.addItem(withTitle: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        if updater.isAvailable {
            menu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit GlassUsage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() { Task { await store.refresh() } }

    @objc private func checkForUpdates() { updater.checkForUpdates() }

    @objc private func openSettings() {
        panelModel.showingSettings = true
        showPanel(byHover: false)
    }

    // MARK: Hover

    private func pointerEnteredStatusItem() {
        guard store.settings.openOnHover, !panel.isPresented else { return }
        hoverOpenTask?.cancel()
        hoverOpenTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            self?.showPanel(byHover: true)
        }
    }

    // MARK: Leaving

    /// Room around the panel and icon the pointer can stray into, on top of the panel's transparent shadow insets.
    private static let leaveMargin: CGFloat = 10
    /// How long the pointer has to stay away before the panel closes, so a slip past the edge doesn't.
    private static let leaveGrace: CFTimeInterval = 0.3

    /// Polls rather than tracking areas so a panel resizing under a still pointer counts too. The timer runs only in
    /// the default run loop mode, so it waits while a menu from the panel is open or a control is being clicked.
    private func startLeaveWatch() {
        stopLeaveWatch()
        pointerLeftAt = nil
        leaveWatch = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
    }

    private func checkPointer() {
        guard panel.isPresented else { return stopLeaveWatch() }
        // A held button is a drag (or a click) in progress; closing mid-drag would drop it.
        if pointerIsNearPanel() || NSEvent.pressedMouseButtons != 0 {
            pointerLeftAt = nil
        } else if let left = pointerLeftAt {
            if CACurrentMediaTime() - left >= Self.leaveGrace { hidePanel() }
        } else {
            pointerLeftAt = CACurrentMediaTime()
        }
    }

    /// Over the panel, the icon, the gap between them, or another of GlassUsage's windows (the Privacy popover
    /// hangs off the panel in a window of its own).
    private func pointerIsNearPanel() -> Bool {
        let pointer = NSEvent.mouseLocation
        let margin = Self.leaveMargin
        if panel.frame.union(statusButtonScreenRect()).insetBy(dx: -margin, dy: -margin).contains(pointer) { return true }
        return NSApp.windows.contains { $0.isVisible && $0.frame.insetBy(dx: -margin, dy: -margin).contains(pointer) }
    }

    private func stopLeaveWatch() {
        leaveWatch?.invalidate()
        leaveWatch = nil
    }

    // MARK: Panel

    private func statusButtonScreenRect() -> NSRect {
        guard let button = statusItem.button, let window = button.window else { return .zero }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func showPanel(byHover: Bool) {
        let buttonRect = statusButtonScreenRect()
        anchor = NSPoint(x: buttonRect.midX, y: buttonRect.minY - 6)
        openedByHover = byHover
        layoutPanel(size: panel.idealContentSize())

        store.refreshIfStale()
        panel.present()
        panelModel.revealed = true
        statusItem.button?.highlight(true)
        statusItem.button?.toolTip = nil

        startLeaveWatch()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.hidePanel() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown, event.window === self.panel {
                self.openedByHover = false
            }
            guard event.type == .keyDown else { return event }
            if event.keyCode == 53 { // Escape: leave Settings first, then close.
                if self.panelModel.showingSettings { self.panelModel.showingSettings = false } else { self.hidePanel() }
                return nil
            }
            guard event.modifierFlags.contains(.command) else { return event }
            switch event.charactersIgnoringModifiers {
            case "r": Task { await self.store.refresh() }
            case ",": self.panelModel.showingSettings = true
            case "q": NSApp.terminate(nil)
            default: return event
            }
            return nil
        }
    }

    private func hidePanel() {
        guard panel.isPresented else { return }
        panelModel.revealed = false
        stopLeaveWatch()
        openedByHover = false
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        outsideClickMonitor = nil
        keyMonitor = nil
        statusItem.button?.highlight(false)
        panel.dismiss { [weak self] in
            self?.panelModel.showingSettings = false
            self?.updateButton()
        }
    }

    /// Keeps the panel hanging from the status item as its content grows or shrinks.
    private func layoutPanel(size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        panel.contentSizeHint = size
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        panel.place(contentSize: size, centerX: anchor.x, top: anchor.y, within: screen?.visibleFrame ?? .zero,
                    animated: panel.isVisible)
    }
}

@Observable
final class PanelModel {
    var showingSettings = false
    /// Drives the content's entrance as the panel opens and its exit as it closes.
    var revealed = false
    var range: SpendRange = .today
    var breakdown: SpendBreakdown = .models
}

private final class HoverTracker: NSResponder {
    private let onEnter: () -> Void
    private let onExit: () -> Void

    init(onEnter: @escaping () -> Void, onExit: @escaping () -> Void) {
        self.onEnter = onEnter
        self.onExit = onExit
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func mouseEntered(with event: NSEvent) { onEnter() }
    override func mouseExited(with event: NSEvent) { onExit() }
}
