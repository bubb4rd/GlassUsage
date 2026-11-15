import AppKit

/// Menu bar glyph: one capsule meter per account-wide window (session above weekly).
/// Drawn as a template image so it follows the menu bar's light/dark and tinting.
enum StatusIcon {
    static func image(fractions: [Double], dimmed: Bool) -> NSImage {
        let bars = fractions.isEmpty ? [0] : Array(fractions.prefix(2))
        let size = NSSize(width: 18, height: 16)
        let image = NSImage(size: size, flipped: true) { _ in
            let barHeight: CGFloat = bars.count == 1 ? 6 : 4.5
            let gap: CGFloat = 2.5
            let total = barHeight * CGFloat(bars.count) + gap * CGFloat(bars.count - 1)
            var y = (size.height - total) / 2
            let opacity: CGFloat = dimmed ? 0.45 : 1

            for fraction in bars {
                let track = NSRect(x: 1, y: y, width: size.width - 2, height: barHeight)
                let radius = barHeight / 2
                NSColor.black.withAlphaComponent(0.28 * opacity).setFill()
                NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()

                let clamped = min(max(fraction, 0), 1)
                if clamped > 0 {
                    // Keep tiny values visible as a dot rather than a sliver.
                    let width = max(track.width * clamped, barHeight)
                    let fill = NSRect(x: track.minX, y: y, width: width, height: barHeight)
                    NSColor.black.withAlphaComponent(opacity).setFill()
                    NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
                }
                y += barHeight + gap
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
