// Genera AppIcon.icns: swift make_icon.swift
import AppKit

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Sfondo: quadrato arrotondato stile macOS con gradiente viola → blu
    let inset = s * 0.1
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(starting: NSColor(red: 0.55, green: 0.30, blue: 0.95, alpha: 1),
               ending: NSColor(red: 0.15, green: 0.45, blue: 0.95, alpha: 1))!
        .draw(in: shape, angle: -90)

    // Tre cursori verticali (mixer) con manopole a altezze diverse
    let trackW = rect.width * 0.06
    let knobW = rect.width * 0.2, knobH = rect.width * 0.11
    let top = rect.maxY - rect.height * 0.2, bottom = rect.minY + rect.height * 0.2
    for (i, level) in [0.35, 0.75, 0.55].enumerated() {
        let x = rect.minX + rect.width * (0.25 + 0.25 * CGFloat(i))
        NSColor(white: 1, alpha: 0.35).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - trackW / 2, y: bottom, width: trackW, height: top - bottom),
                     xRadius: trackW / 2, yRadius: trackW / 2).fill()
        let y = bottom + (top - bottom) * CGFloat(level)
        NSColor(white: 1, alpha: 0.6).setFill()
        NSBezierPath(roundedRect: NSRect(x: x - trackW / 2, y: bottom, width: trackW, height: y - bottom),
                     xRadius: trackW / 2, yRadius: trackW / 2).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: x - knobW / 2, y: y - knobH / 2, width: knobW, height: knobH),
                     xRadius: knobH / 2, yRadius: knobH / 2).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: "AppIcon.iconset")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
