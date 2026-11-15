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
    private let glass = NSGlassEffectView()

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
        contentView = container
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func setContent<Content: View>(_ view: Content) {
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
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
    /// kept inside `bounds`.
    func place(contentSize: CGSize, centerX: CGFloat, top: CGFloat, within bounds: NSRect) {
        let insets = Self.shadowInsets
        var glassX = centerX - contentSize.width / 2
        glassX = min(max(glassX, bounds.minX + 8), bounds.maxX - contentSize.width - 8)
        let frame = NSRect(x: glassX - insets.left, y: top - contentSize.height - insets.bottom,
                           width: contentSize.width + insets.left + insets.right,
                           height: contentSize.height + insets.top + insets.bottom)
        setFrame(frame, display: true)
    }

    func present() {
        alphaValue = 0
        orderFrontRegardless()
        makeKey()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
    }

    func dismiss(completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.orderOut(nil)
                completion()
            }
        }
    }
}
