import AppKit

@MainActor
enum MenuBarRenderer {
    /// Draw both rows inside the menu-bar height. A color provider icon keeps its
    /// original artwork; text resolves the status button's effective appearance.
    static func stackedImage(lines: [String], showIcon: Bool) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
        let rows = Array(lines.prefix(2))
        let textWidth = ceil(rows.map { ($0 as NSString).size(withAttributes: attributes).width }.max() ?? 0)
        let iconWidth: CGFloat = showIcon ? (rows.isEmpty ? 18 : 23) : 0
        let size = NSSize(width: max(16, iconWidth + textWidth), height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            if showIcon {
                ProviderIcon.codex().draw(in: NSRect(x: 0, y: 2.5, width: 17, height: 17))
            }
            for (index, row) in rows.enumerated() {
                let y: CGFloat = rows.count == 1 ? 5 : (index == 0 ? 10.5 : -0.5)
                (row as NSString).draw(at: NSPoint(x: iconWidth, y: y), withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = !showIcon
        image.cacheMode = .never
        image.accessibilityDescription = rows.joined(separator: "，")
        return image
    }
}
