// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    let rect = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.75, blue: 0.55, alpha: 1),
                        NSColor(red: 0.05, green: 0.36, blue: 0.55, alpha: 1)])!.draw(in: path, angle: -60)
    // Phone outline
    let phone = NSRect(x: s * 0.36, y: s * 0.24, width: s * 0.28, height: s * 0.52)
    NSColor.white.setStroke()
    let outline = NSBezierPath(roundedRect: phone, xRadius: s * 0.05, yRadius: s * 0.05)
    outline.lineWidth = s * 0.035
    outline.stroke()
    // Breeze lines
    for (i, y) in [0.62, 0.5, 0.38].enumerated() {
        let line = NSBezierPath()
        line.lineWidth = s * 0.03
        line.lineCapStyle = .round
        line.move(to: NSPoint(x: s * (0.2 + Double(i) * 0.04), y: s * y))
        line.curve(to: NSPoint(x: s * 0.82, y: s * (y + 0.02)),
                   controlPoint1: NSPoint(x: s * 0.45, y: s * (y + 0.06)),
                   controlPoint2: NSPoint(x: s * 0.6, y: s * (y - 0.05)))
        NSColor.white.withAlphaComponent(0.85).setStroke()
        line.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
print(iconset.path)
