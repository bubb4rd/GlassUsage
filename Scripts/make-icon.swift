// Renders Support/AppIcon.icns: the GlassUsage mark (docs/logo/glassusage-logo.svg) on a blue glass tile.
// Usage: swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
// The mark is white on transparent; NSImage reads SVG natively.
let mark = NSImage(contentsOf: root.appending(path: "docs/logo/glassusage-logo.svg"))!

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let scale = s / 1024
    let space = CGColorSpaceCreateDeviceRGB()

    // macOS icon grid: 824pt body inset 100pt, ~185pt corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let tile = CGPath(roundedRect: body, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                  color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.addPath(tile)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [
        NSColor(srgbRed: 0.42, green: 0.62, blue: 0.95, alpha: 1).cgColor,
        NSColor(srgbRed: 0.18, green: 0.36, blue: 0.78, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY), options: [])
    // Glass sheen across the top half and a faint rim light along the edge.
    let sheen = CGGradient(colorsSpace: space, colors: [
        NSColor.white.withAlphaComponent(0.28).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY + 60 * scale), options: [])
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3 * scale, dy: 3 * scale),
                       cornerWidth: 182 * scale, cornerHeight: 182 * scale, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.25).cgColor)
    ctx.setLineWidth(4 * scale)
    ctx.strokePath()
    ctx.restoreGState()

    // The mark at ~62% of the tile, with a soft drop shadow for depth.
    let side = 824 * 0.62 * scale
    let markRect = CGRect(x: body.midX - side / 2, y: body.midY - side / 2, width: side, height: side)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8 * scale), blur: 24 * scale,
                  color: NSColor(srgbRed: 0.05, green: 0.12, blue: 0.35, alpha: 0.45).cgColor)
    // The SVG's viewBox has generous margins; crop to the mark's bounds (270…1298 of 1568).
    let crop = NSRect(x: 270 / 1568 * mark.size.width, y: 270 / 1568 * mark.size.height,
                      width: 1028 / 1568 * mark.size.width, height: 1028 / 1568 * mark.size.height)
    mark.draw(in: markRect, from: crop, operation: .sourceOver, fraction: 1)
    ctx.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appending(path: "AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try render(size: points).write(to: iconset.appending(path: "icon_\(points)x\(points).png"))
    try render(size: points * 2).write(to: iconset.appending(path: "icon_\(points)x\(points)@2x.png"))
}
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Support/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Support/AppIcon.icns" : "iconutil failed")
