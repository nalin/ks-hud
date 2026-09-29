// Renders Resources/AppIcon.icns. Run: swift scripts/make-icon.swift
// Drawn natively at every size (rather than downscaled) so small sizes stay crisp.
import AppKit

func drawIcon(px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)  // design in a 1024 grid

    // Rounded-square tile on Apple's icon grid, with a soft drop shadow.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 24, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    NSColor.black.setFill()
    tile.fill()
    ctx.restoreGState()
    ctx.saveGState()
    tile.addClip()
    NSGradient(starting: NSColor(srgbRed: 0.16, green: 0.22, blue: 0.30, alpha: 1),
               ending: NSColor(srgbRed: 0.04, green: 0.06, blue: 0.09, alpha: 1))!.draw(in: tile, angle: -90)
    ctx.restoreGState()

    let green = NSColor(srgbRed: 0.24, green: 0.86, blue: 0.52, alpha: 1)
    let center = NSPoint(x: 512, y: 560)
    let radius: CGFloat = 250

    func arc(from start: CGFloat, to end: CGFloat, color: NSColor, width: CGFloat) {
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
        p.lineWidth = width
        p.lineCapStyle = .round
        color.setStroke()
        p.stroke()
    }
    // Speedometer: faint track, green progress, white needle.
    arc(from: 210, to: -30, color: NSColor.white.withAlphaComponent(0.16), width: 60)
    arc(from: 210, to: 50, color: green, width: 60)

    let needleAngle: CGFloat = 50 * .pi / 180
    let needle = NSBezierPath()
    needle.move(to: center)
    needle.line(to: NSPoint(x: center.x + cos(needleAngle) * 185, y: center.y + sin(needleAngle) * 185))
    needle.lineWidth = 30
    needle.lineCapStyle = .round
    NSColor.white.setStroke()
    needle.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 38, y: center.y - 38, width: 76, height: 76)).fill()

    // Treadmill belt with rollers.
    let belt = NSRect(x: 282, y: 232, width: 460, height: 64)
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(roundedRect: belt, xRadius: 32, yRadius: 32).fill()
    NSColor(srgbRed: 0.04, green: 0.06, blue: 0.09, alpha: 1).setFill()
    for x in [belt.minX + 32, belt.maxX - 32] {
        NSBezierPath(ovalIn: NSRect(x: x - 14, y: belt.midY - 14, width: 28, height: 28)).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for pt in [16, 32, 128, 256, 512] {
    try! drawIcon(px: pt).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt).png"))
    try! drawIcon(px: pt * 2).write(to: iconset.appendingPathComponent("icon_\(pt)x\(pt)@2x.png"))
}
let out = root.appendingPathComponent("Resources/AppIcon.icns")
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try! task.run()
task.waitUntilExit()
if CommandLine.arguments.count > 1 {  // optional: also dump a 1024 preview PNG
    try! drawIcon(px: 1024).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
print(task.terminationStatus == 0 ? "Wrote \(out.path)" : "iconutil failed")
