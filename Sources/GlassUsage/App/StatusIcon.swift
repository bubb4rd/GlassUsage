import AppKit

/// Menu bar glyph: a ring gauge filled clockwise from 12 o'clock to the most constrained limit.
/// Template image, so it follows the menu bar's light/dark and tinting. Dimmed when the reading is stale.
enum StatusIcon {
    static func image(fraction: Double?, dimmed: Bool) -> NSImage {
        let size = NSSize(width: 15, height: 15)
        let image = NSImage(size: size, flipped: false) { rect in
            let lineWidth: CGFloat = 2.6
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2 - lineWidth / 2 - 0.5
            let alpha: CGFloat = dimmed ? 0.45 : 1

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.35 * alpha).setStroke()
            track.stroke()

            if let fraction, fraction > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(min(fraction, 1)), clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "GlassUsage"
        return image
    }
}
