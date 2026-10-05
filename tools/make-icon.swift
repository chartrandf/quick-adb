// Renders resources/AppIcon.icns: the green ant on a white rounded tile (same look as the window).
// Run: swift tools/make-icon.swift
import Cocoa

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icon grid: 824/1024 tile, ~185 corner radius, room for the shadow.
    let tile = NSRect(x: s * 100 / 1024, y: s * 110 / 1024, width: s * 824 / 1024, height: s * 824 / 1024)
    let path = NSBezierPath(roundedRect: tile, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = s * 20 / 1024
    shadow.shadowOffset = NSSize(width: 0, height: -s * 10 / 1024)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.set()
    NSColor.white.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: .white, ending: NSColor(white: 0.9, alpha: 1))!.draw(in: path, angle: -90)

    // Ant filled with a green gradient (symbol used as a mask).
    let symbol = NSImage(systemSymbolName: "ant.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(.init(pointSize: s * 0.42, weight: .bold))!
    let antRect = NSRect(x: (s - symbol.size.width) / 2, y: tile.midY - symbol.size.height / 2,
                         width: symbol.size.width, height: symbol.size.height)
    let ant = NSImage(size: symbol.size, flipped: false) { r in
        NSGradient(starting: NSColor(red: 0.36, green: 0.89, blue: 0.56, alpha: 1),
                   ending: NSColor(red: 0.13, green: 0.66, blue: 0.40, alpha: 1))!.draw(in: r, angle: -90)
        symbol.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1)
        return true
    }
    ant.draw(in: antRect)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("resources/AppIcon.icns").path]
try! p.run()
p.waitUntilExit()
try! render(512).write(to: root.appendingPathComponent("docs/icon.png"))
print("Wrote resources/AppIcon.icns")
