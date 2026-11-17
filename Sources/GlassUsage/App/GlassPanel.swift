import AppKit
import SwiftUI

/// Borderless, non-activating Liquid Glass panel. It takes key focus (for Escape and
/// keyboard navigation) without activating the app or stealing focus from the frontmost app.
final class GlassPanel: NSPanel {
    static let cornerRadius: CGFloat = 26
    /// Transparent room around the glass so its own shadow isn't clipped by the window rect.
    /// Kept small on top so the window never overlaps the menu bar item.
    static let shadowInsets = NSEdgeInsets(top: 4, left: 24, bottom: 32, right: 24)

    var contentSizeHint = CGSize(width: 360, height: 420)
    /// Open, or opening; false as soon as it starts closing, so a click mid-fade reopens it.
    private(set) var isPresented = false
    private let glass = NSGlassEffectView()
    /// Where `place` last put the window, which opening unrolls to even mid-resize.
    private var restingFrame = NSRect.zero
    /// Bumped on every open, so a close that's still fading out doesn't hide a panel reopened meanwhile.
    private var presentation = 0
    private let cursorTracker = CursorTracker()

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: contentSizeHint),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        // The window server's shadow traces the rectangular frame, not the rounded glass,
        // leaving a hairline box around the panel; the glass draws its own edge and depth.
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        let container = NSView()
        container.frame = NSRect(origin: .zero, size: contentSizeHint)
        let insets = Self.shadowInsets
        glass.frame = NSRect(x: insets.left, y: insets.bottom,
                             width: container.bounds.width - insets.left - insets.right,
                             height: container.bounds.height - insets.top - insets.bottom)
        glass.autoresizingMask = [.width, .height]
        container.addSubview(glass)
        glass.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                             owner: cursorTracker))
        PanelCursor.allowSettingInBackground()
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Height changes (spend on/off, range, Settings) animate the window and the SwiftUI content together.
    static let resizeDuration: TimeInterval = 0.25

    func setContent<Content: View>(_ view: Content) {
        // Pinned to the top and clipped, so a resizing window reveals or hides the bottom edge
        // instead of re-centering the content on every frame.
        let hosting = NSHostingView(rootView: view.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top))
        hosting.sizingOptions = []
        hosting.clipsToBounds = true
        hosting.frame = glass.bounds
        hosting.autoresizingMask = [.width, .height]
        glass.contentView = hosting
    }

    /// SwiftUI's ideal size for the current content, before the panel has been laid out.
    func idealContentSize() -> CGSize {
        guard let size = glass.contentView?.fittingSize, size.width > 0, size.height > 0 else { return contentSizeHint }
        return size
    }

    /// Sizes the window around `contentSize` with the glass's top edge at `top`, centered on `centerX`,
    /// kept inside `bounds`. `animated` grows or shrinks it from the top edge.
    func place(contentSize: CGSize, centerX: CGFloat, top: CGFloat, within bounds: NSRect, animated: Bool) {
        let insets = Self.shadowInsets
        var glassX = centerX - contentSize.width / 2
        glassX = min(max(glassX, bounds.minX + 8), bounds.maxX - contentSize.width - 8)
        let frame = NSRect(x: glassX - insets.left, y: top - contentSize.height - insets.bottom,
                           width: contentSize.width + insets.left + insets.right,
                           height: contentSize.height + insets.top + insets.bottom)
        restingFrame = frame
        guard animated, frame != self.frame else { return setFrame(frame, display: true) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.resizeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animator().setFrame(frame, display: true)
        }
    }

    /// Opening drops the panel from the menu bar: it fades in while unrolling from a shorter height, its top
    /// edge fixed. Closing folds it back up as it fades. Reduce Motion keeps only the fades.
    func present() {
        isPresented = true
        presentation += 1
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !isVisible {
            alphaValue = 0
            if motion { setFrame(folded(restingFrame), display: false) }
        }
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { context in
            // Gentle enough at the start that the unroll still shows while the fade comes up.
            context.duration = 0.36
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.75, 0.25, 1)
            animator().alphaValue = 1
            animator().setFrame(restingFrame, display: true)
        }
    }

    func dismiss(completion: @escaping @MainActor () -> Void) {
        isPresented = false
        PanelCursor.pointerInside = false
        let shown = presentation
        let motion = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
            if motion { animator().setFrame(folded(restingFrame), display: true) }
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentation == shown else { return }
                self.orderOut(nil)
                completion()
            }
        }
    }

    /// `frame` with the glass's bottom raised by a tenth of its height, top edge in place.
    private func folded(_ frame: NSRect) -> NSRect {
        let insets = Self.shadowInsets
        let lift = ((frame.height - insets.top - insets.bottom) * 0.1).rounded()
        return NSRect(x: frame.minX, y: frame.minY + lift, width: frame.width, height: frame.height - lift)
    }
}

/// Hands the pointer's moves over the glass to `PanelCursor`. The app underneath answers the same moves with its
/// own cursor, often a few milliseconds after ours (a web view picks it in another process), so after each move the
/// cursor is set again every millisecond until that app has had time to answer. Its cursor then lasts about a
/// millisecond, which a screen refresh rarely catches; resetting once per frame left it up for a whole frame.
private final class CursorTracker: NSResponder {
    private static let settle: CFTimeInterval = 0.25
    private var timer: Timer?
    private var holdUntil: CFTimeInterval = 0

    override func mouseEntered(with event: NSEvent) { moved() }
    override func mouseMoved(with event: NSEvent) { moved() }
    override func mouseExited(with event: NSEvent) {
        PanelCursor.pointerInside = false
        stop()
    }

    private func moved() {
        PanelCursor.pointerInside = true
        holdUntil = CACurrentMediaTime() + Self.settle
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.001, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reassert() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func reassert() {
        guard PanelCursor.pointerInside, CACurrentMediaTime() < holdUntil else { return stop() }
        PanelCursor.apply()
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
    }
}
