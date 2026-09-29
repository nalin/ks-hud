import AppKit

extension NSImage {
    /// The app icon's gauge and belt without the tile, as a template image so it follows the menu bar's appearance.
    static let statusIcon: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let center = NSPoint(x: 9, y: 10)
            func arc(to end: CGFloat, alpha: CGFloat) {
                let p = NSBezierPath()
                p.appendArc(withCenter: center, radius: 6.5, startAngle: 210, endAngle: end, clockwise: true)
                p.lineWidth = 1.8
                p.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alpha).setStroke()
                p.stroke()
            }
            arc(to: -30, alpha: 0.35)
            arc(to: 50, alpha: 1)

            let angle = 50 * CGFloat.pi / 180
            let needle = NSBezierPath()
            needle.move(to: center)
            needle.line(to: NSPoint(x: center.x + cos(angle) * 4.6, y: center.y + sin(angle) * 4.6))
            needle.lineWidth = 1.6
            needle.lineCapStyle = .round
            NSColor.black.setStroke()
            needle.stroke()

            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: center.x - 1.6, y: center.y - 1.6, width: 3.2, height: 3.2)).fill()
            NSBezierPath(roundedRect: NSRect(x: 3, y: 1.5, width: 12, height: 2.2), xRadius: 1.1, yRadius: 1.1).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "KS HUD"
        return image
    }()
}
