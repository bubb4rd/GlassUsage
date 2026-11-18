import AppKit

/// The menu bar item, drawn as one template image so it follows the menu bar's light/dark and tinting: each icon
/// one ring or two concentric ones, filled clockwise from 12 o'clock, followed by its percentage. A ring whose
/// reading is stale, failed or missing is dimmed on its own.
enum StatusIcon {
    /// Readings older than this dim their ring.
    static let staleAfter: TimeInterval = 30 * 60

    /// One ring as drawn. A nil fraction draws an empty track.
    struct Ring {
        var fraction: Double?
        var dimmed = false
    }

    private static let glyphSize: CGFloat = 16
    private static let lineWidth: CGFloat = 2.2
    private static let textGap: CGFloat = 4
    private static let iconGap: CGFloat = 7
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    /// The whole item: `icons` left to right, each followed by its percentage.
    static func image(_ icons: [ResolvedIcon]) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let parts = icons.map { icon -> (outer: Ring, inner: Ring?, text: NSAttributedString?) in
            let rings = icon.rings.map { Ring(fraction: $0.window?.fraction, dimmed: $0.dimmed) }
            return (rings.first ?? Ring(fraction: nil, dimmed: true), rings.count > 1 ? rings[1] : nil,
                    icon.percentText.map { NSAttributedString(string: $0, attributes: attributes) })
        }
        let widths = parts.map { glyphSize + ($0.text.map { textGap + ceil($0.size().width) } ?? 0) }
        let size = NSSize(width: max(widths.reduce(0, +) + iconGap * CGFloat(max(parts.count - 1, 0)), glyphSize),
                          height: glyphSize)
        let image = NSImage(size: size, flipped: false) { _ in
            var x: CGFloat = 0
            for (part, width) in zip(parts, widths) {
                drawGlyph(in: NSRect(x: x, y: 0, width: glyphSize, height: glyphSize), outer: part.outer, inner: part.inner)
                if let text = part.text {
                    // Digits centered on the rings: their cap height around the middle.
                    let baseline = (glyphSize - font.capHeight) / 2
                    text.draw(at: NSPoint(x: x + glyphSize + textGap, y: baseline + font.descender))
                }
                x += width + iconGap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description(icons).joined(separator: "; ")
        return image
    }

    /// A single icon without a percentage, as Settings' ring buttons show it.
    static func glyph(outer: Ring, inner: Ring?) -> NSImage {
        let image = NSImage(size: NSSize(width: glyphSize, height: glyphSize), flipped: false) { rect in
            drawGlyph(in: rect, outer: outer, inner: inner)
            return true
        }
        image.isTemplate = true
        return image
    }

    private static func drawGlyph(in rect: NSRect, outer: Ring, inner: Ring?) {
        let center = NSPoint(x: rect.midX, y: rect.midY)
        func ring(radius: CGFloat, _ ring: Ring) {
            let alpha: CGFloat = ring.dimmed ? 0.45 : 1
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.black.withAlphaComponent(0.35 * alpha).setStroke()
            track.stroke()

            guard let fraction = ring.fraction, fraction > 0 else { return }
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                          endAngle: 90 - 360 * CGFloat(min(fraction, 1)), clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            NSColor.black.withAlphaComponent(alpha).setStroke()
            arc.stroke()
        }
        ring(radius: rect.width / 2 - lineWidth / 2 - 0.3, outer)
        if let inner { ring(radius: 3.2, inner) }
    }

    /// One line per icon naming what each ring reads, for the tooltip and VoiceOver: "Claude: Weekly 62% · Session 34%",
    /// or "Claude: Weekly 62% · Codex: Weekly 88%" when the rings read different providers.
    static func description(_ icons: [ResolvedIcon]) -> [String] {
        icons.map { icon in
            guard !icon.rings.isEmpty else { return "\(icon.icon.outer.provider.displayName): no reading" }
            var line = ""
            var provider: ProviderID?
            for ring in icon.rings {
                if ring.source.provider != provider {
                    provider = ring.source.provider
                    line += (line.isEmpty ? "" : " · ") + "\(ring.source.provider.displayName): "
                } else if ring.window == nil {
                    // Both rings of a provider without a reading say so once.
                    continue
                } else {
                    line += " · "
                }
                if let window = ring.window {
                    line += "\(window.group.map { "\($0) " } ?? "")\(window.title) \(Int(window.percent.rounded()))%"
                } else {
                    line += "no reading"
                }
            }
            return line
        }
    }
}
