// Renders Support/AppIcon.icns: two usage rings on a dark tile.
// Usage: swift Scripts/make-icon.swift
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let scale = s / 1024

    // macOS icon grid: 824pt body inset 100pt, ~185pt corner radius.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let tile = CGPath(roundedRect: body, cornerWidth: 185 * scale, cornerHeight: 185 * scale, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 28 * scale,
                  color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.addPath(tile)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tile)
    ctx.clip()
    let background = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor(srgbRed: 0.36, green: 0.09, blue: 0.14, alpha: 1).cgColor,
        NSColor(srgbRed: 0.08, green: 0.03, blue: 0.06, alpha: 1).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.minY), options: [])
    // Soft glass highlight across the top.
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
        NSColor.white.withAlphaComponent(0.14).cgColor, NSColor.white.withAlphaComponent(0).cgColor,
    ] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: body.midX, y: body.maxY),
                           end: CGPoint(x: body.midX, y: body.midY + 40 * scale), options: [])
    ctx.restoreGState()

    let center = CGPoint(x: body.midX, y: body.midY)
    func ring(radius: CGFloat, fraction: CGFloat, color: NSColor) {
        let width = 74 * scale
        ctx.setLineWidth(width)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.addArc(center: center, radius: radius * scale, startAngle: 0, endAngle: .pi * 2, clockwise: false)
        ctx.strokePath()
        ctx.setStrokeColor(color.cgColor)
        let start = CGFloat.pi / 2
        ctx.addArc(center: center, radius: radius * scale, startAngle: start,
                   endAngle: start - .pi * 2 * fraction, clockwise: true)
        ctx.strokePath()
    }
    ring(radius: 268, fraction: 0.72, color: NSColor(srgbRed: 0.92, green: 0.41, blue: 0.20, alpha: 1))
    ring(radius: 160, fraction: 0.42, color: NSColor(srgbRed: 0.22, green: 0.53, blue: 0.90, alpha: 1))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
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
