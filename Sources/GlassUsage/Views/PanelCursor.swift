import AppKit
import SwiftUI

/// The cursor while the pointer is over the panel: a pointing hand over a control, an arrow everywhere else.
///
/// The panel never activates GlassUsage, so the app underneath stays active: it keeps getting the pointer's
/// moves and setting its own cursor for what's beneath the glass (an I-beam over its text, a resize arrow over
/// its split views). `GlassPanel` calls `apply()` on every move over the glass and for a moment after, so ours wins.
@MainActor
enum PanelCursor {
    static var pointerInside = false {
        didSet { if pointerInside { apply() } }
    }

    /// Controls under the pointer. Can briefly be more than one while hover regions overlap mid-transition.
    fileprivate static var hoveredControls = 0 {
        didSet { if pointerInside { apply() } }
    }

    static func apply() {
        (hoveredControls > 0 ? NSCursor.pointingHand : NSCursor.arrow).set()
    }

    /// AppKit only lets the active app set the cursor. This WindowServer connection property (private, and what
    /// other non-activating overlays use) lets GlassUsage set it from the background. Looked up at runtime, so if
    /// it ever goes away the panel just keeps the cursor of the app underneath.
    static func allowSettingInBackground() {
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetConnectionProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let everywhere = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(everywhere, "_CGSDefaultConnection"),
              let setProperty = dlsym(everywhere, "CGSSetConnectionProperty") else { return }
        let cid = unsafeBitCast(connection, to: DefaultConnection.self)()
        _ = unsafeBitCast(setProperty, to: SetConnectionProperty.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }
}

extension View {
    /// Shows a pointing hand while the pointer is over this control.
    func pointingHand() -> some View { modifier(PointingHand()) }
}

private struct PointingHand: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                PanelCursor.hoveredControls += inside ? 1 : -1
            }
            // A control can go while under the pointer (Settings swaps the whole panel) without a hover exit.
            .onDisappear {
                guard hovering else { return }
                hovering = false
                PanelCursor.hoveredControls -= 1
            }
    }
}
