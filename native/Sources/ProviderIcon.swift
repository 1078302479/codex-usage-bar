import AppKit

@MainActor
enum ProviderIcon {
    /// Transparent single-color Codex service mark, independent of the app icon.
    static func codex(size: CGFloat = 17) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            NSGraphicsContext.saveGraphicsState()
            let transform = NSAffineTransform(); transform.scale(by: size); transform.concat()
            let badge = NSBezierPath()
            for step in 0...360 {
                let angle = CGFloat(step) * .pi / 180
                let radius: CGFloat = 0.435 + 0.035 * cos(6 * angle)
                let point = NSPoint(x: 0.5 + cos(angle) * radius, y: 0.5 + sin(angle) * radius)
                if step == 0 { badge.move(to: point) } else { badge.line(to: point) }
            }
            badge.close()
            let chevron = NSBezierPath()
            let points: [NSPoint] = [NSPoint(x: 0.27, y: 0.68), NSPoint(x: 0.34, y: 0.71),
                                     NSPoint(x: 0.48, y: 0.51), NSPoint(x: 0.34, y: 0.31),
                                     NSPoint(x: 0.27, y: 0.34), NSPoint(x: 0.39, y: 0.51)]
            chevron.move(to: points[0]); for point in points.dropFirst() { chevron.line(to: point) }; chevron.close()
            badge.append(chevron)
            badge.append(NSBezierPath(roundedRect: NSRect(x: 0.55, y: 0.32, width: 0.23, height: 0.075), xRadius: 0.0375, yRadius: 0.0375))
            badge.windingRule = .evenOdd
            NSColor.white.setFill(); badge.fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Codex"
        return image
    }
}
