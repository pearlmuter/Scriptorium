// Renders Resources/AppIcon.icns: a vermilion pilcrow on paper, with the guardian's lapis diamond.
//   swift Scripts/make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.25); shadow.shadowBlurRadius = s * 0.02; shadow.shadowOffset = NSSize(width: 0, height: -s * 0.01); shadow.set()
    NSColor(srgbRed: 0.98, green: 0.968, blue: 0.94, alpha: 1).setFill(); tile.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    // Faint ruled lines, like a page.
    NSColor(srgbRed: 0.13, green: 0.12, blue: 0.11, alpha: 0.07).setFill()
    for i in 0..<5 { NSRect(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * (0.2 + CGFloat(i) * 0.13), width: rect.width * 0.64, height: max(1, s * 0.006)).fill() }
    let font = NSFont(name: "Baskerville-SemiBold", size: s * 0.6) ?? NSFont.systemFont(ofSize: s * 0.6)
    let mark = NSAttributedString(string: "¶", attributes: [.font: font, .foregroundColor: NSColor(srgbRed: 0.706, green: 0.275, blue: 0.173, alpha: 1)])
    let size = mark.size()
    mark.draw(at: NSPoint(x: rect.midX - size.width / 2 - s * 0.03, y: rect.midY - size.height / 2 - s * 0.01))
    // The guardian: a lapis caret with a diamond cap.
    let lapis = NSColor(srgbRed: 0.18, green: 0.31, blue: 0.62, alpha: 1); lapis.setFill()
    let x = rect.midX + size.width * 0.5 + s * 0.04, w = s * 0.022
    NSBezierPath(roundedRect: NSRect(x: x, y: rect.midY - s * 0.17, width: w, height: s * 0.30), xRadius: w / 2, yRadius: w / 2).fill()
    let d = NSBezierPath(), cx = x + w / 2, cy = rect.midY + s * 0.165, r = s * 0.035
    d.move(to: NSPoint(x: cx, y: cy + r)); d.line(to: NSPoint(x: cx + r * 0.8, y: cy)); d.line(to: NSPoint(x: cx, y: cy - r)); d.line(to: NSPoint(x: cx - r * 0.8, y: cy)); d.close(); d.fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let set = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try! FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128), ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! render(px).write(to: set.appendingPathComponent("icon_\(name).png"))
}
let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try! p.run(); p.waitUntilExit()
print("Wrote Resources/AppIcon.icns")
