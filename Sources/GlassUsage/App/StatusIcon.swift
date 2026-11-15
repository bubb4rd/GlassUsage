import AppKit

/// Menu bar glyph: concentric rings, the shortest window (session) inside and the longest (week or month)
/// outside, each filled clockwise from 12 o'clock. Template image, so it follows the menu bar's light/dark
/// and tinting. Dimmed when the reading is stale or failed.
enum StatusIcon {
    /// Readings older than this dim the glyph.
    static let staleAfter: TimeInterval = 30 * 60

    /// The glyph for a provider's latest state, as the menu bar draws it. Providers that meter model
    /// groups show the group closest to its limit.
    static func image(for state: ProviderState?, now: Date = .now) -> NSImage {
        let snapshot = state?.snapshot
        let stale = snapshot.map { now.timeIntervalSince($0.fetchedAt) > staleAfter } ?? true
        return image(fractions: snapshot?.iconWindows.map(\.fraction) ?? [], dimmed: stale || state?.error != nil)
    }

    /// `fractions` are the windows shortest first; no fractions draws empty tracks.
    static func image(fractions: [Double], dimmed: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            let lineWidth: CGFloat = 2.2
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let alpha: CGFloat = dimmed ? 0.45 : 1

            func ring(radius: CGFloat, fraction: Double?) {
                let track = NSBezierPath()
                track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
                track.lineWidth = lineWidth
                NSColor.black.withAlphaComponent(0.35 * alpha).setStroke()
                track.stroke()

                guard let fraction, fraction > 0 else { return }
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90,
                              endAngle: 90 - 360 * CGFloat(min(fraction, 1)), clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                arc.stroke()
            }

            ring(radius: rect.width / 2 - lineWidth / 2 - 0.3, fraction: fractions.last)
            // A provider with a single window gets only the outer ring.
            if fractions.count != 1 {
                ring(radius: 3.2, fraction: fractions.count > 1 ? fractions.first : nil)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "GlassUsage"
        return image
    }
}
