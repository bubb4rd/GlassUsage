// Renders Support/AppIcon.icns and docs/icon.png from the icon artwork (docs/logo/glassusage-icon.png): the
// square artwork clipped to the macOS icon tile, with its drop shadow and a faint rim light.
// Usage: swift Scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let art = NSImage(contentsOf: root.appending(path: "docs/logo/glassusage-icon.png"))!

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current!.imageInterpolation = .high
    let ctx = NSGraphicsContext.current!.cgContext
    let scale = s / 1024

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
    art.draw(in: body, from: .zero, operation: .copy, fraction: 1)
    ctx.addPath(CGPath(roundedRect: body.insetBy(dx: 3 * scale, dy: 3 * scale),
                       cornerWidth: 182 * scale, cornerHeight: 182 * scale, transform: nil))
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.2).cgColor)
    ctx.setLineWidth(4 * scale)
    ctx.strokePath()
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
// The README shows it at 128pt.
try render(size: 256).write(to: root.appending(path: "docs/icon.png"))
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appending(path: "Support/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
print(iconutil.terminationStatus == 0 ? "Wrote Support/AppIcon.icns and docs/icon.png" : "iconutil failed")
