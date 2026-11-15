import AppKit

/// Menu bar glyph: the GlassUsage mark (docs/logo/glassusage-logo.svg) as a template image,
/// so it follows the menu bar's light/dark and tinting. Dimmed when the reading is stale.
enum StatusIcon {
    static func image(dimmed: Bool) -> NSImage {
        let size = NSSize(width: 17, height: 17)
        let image = NSImage(size: size, flipped: false) { rect in
            mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: dimmed ? 0.45 : 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "GlassUsage"
        return image
    }

    /// The circle and petals are one even-odd path, so overlaps are punched out.
    /// The viewBox is cropped to the mark's bounds so it fills the menu bar slot.
    private static let mark: NSImage = {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" viewBox="270 270 1028 1028">
        <path fill="#000" fill-rule="evenodd" d="M529 784a255 255 0 1 0 510 0a255 255 0 1 0 -510 0ZM958.01 856.46L1173.54 897.59A116 116 0 1 0 1173.54 670.41L958.01 711.54A74 74 0 0 0 958.01 856.46ZM711.54 958.01L670.41 1173.54A116 116 0 1 0 897.59 1173.54L856.46 958.01A74 74 0 0 0 711.54 958.01ZM609.99 711.54L394.46 670.41A116 116 0 1 0 394.46 897.59L609.99 856.46A74 74 0 0 0 609.99 711.54ZM856.46 609.99L897.59 394.46A116 116 0 1 0 670.41 394.46L711.54 609.99A74 74 0 0 0 856.46 609.99Z"/>
        </svg>
        """
        return NSImage(data: Data(svg.utf8)) ?? NSImage()
    }()
}
