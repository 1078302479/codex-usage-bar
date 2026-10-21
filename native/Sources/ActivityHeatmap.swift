import AppKit
import SwiftUI

struct ActivityHeatmap: NSViewRepresentable {
    let activity: TokenActivity
    let now: Date
    func makeNSView(context: Context) -> ActivityHeatmapView { ActivityHeatmapView() }
    func updateNSView(_ view: ActivityHeatmapView, context: Context) {
        view.update(days: TokenActivity.heatmapDays(now: now), values: activity.dailyValues)
    }
}

/// Own the tracking area and paint the tooltip in the same surface as the cells.
/// This works in a transient NSPopover without waiting for AppKit's help manager.
@MainActor
final class ActivityHeatmapView: NSView {
    private var days: [String] = []
    private var values: [String: Double] = [:]
    private var hovered: Int?
    private var tracking: NSTrackingArea?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func update(days: [String], values: [String: Double]) {
        self.days = days; self.values = values
        setAccessibilityElement(true); setAccessibilityRole(.image)
        setAccessibilityLabel("Token 活动热力图，最近 26 周。悬停或点击日期查看用量。")
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    private var cellWidth: CGFloat { max(1, (bounds.width - 22 - 25 * 3) / 26) }
    private func cellRect(_ index: Int) -> NSRect {
        NSRect(x: 22 + CGFloat(index / 7) * (cellWidth + 3), y: 22 + CGFloat(index % 7) * 13, width: cellWidth, height: 10)
    }
    func index(at point: NSPoint) -> Int? {
        guard days.count == 182 else { return nil }
        let week = Int(floor((point.x - 22) / (cellWidth + 3)))
        let day = Int(floor((point.y - 22) / 13))
        guard (0..<26).contains(week), (0..<7).contains(day) else { return nil }
        let index = week * 7 + day
        return cellRect(index).contains(point) ? index : nil
    }
    private func track(_ event: NSEvent) {
        let next = index(at: convert(event.locationInWindow, from: nil))
        if next != hovered {
            hovered = next
            setAccessibilityValue(next.map { detail($0) } ?? "未选择日期")
            needsDisplay = true
        }
    }
    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseDragged(with event: NSEvent) { track(event) }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); track(event) }
    override func mouseExited(with event: NSEvent) { hovered = nil; setAccessibilityValue("未选择日期"); needsDisplay = true }
    override func keyDown(with event: NSEvent) {
        guard !days.isEmpty else { return }
        let delta: Int
        switch event.keyCode { case 123: delta = -7; case 124: delta = 7; case 125: delta = 1; case 126: delta = -1; default: super.keyDown(with: event); return }
        hovered = max(0, min(days.count - 1, (hovered ?? days.count - 1) + delta))
        setAccessibilityValue(detail(hovered!)); needsDisplay = true
    }
    private func detail(_ index: Int) -> String {
        let day = days[index]
        return day + " · " + (values[day].map { $0.formatted(.number.precision(.fractionLength(0))) + " Token" } ?? "未返回数据")
    }
    private func text(_ value: String, at point: NSPoint, size: CGFloat = 9, color: NSColor = .secondaryLabelColor, weight: NSFont.Weight = .regular) {
        (value as NSString).draw(at: point, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard days.count == 182 else { return }
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let palette: [NSColor] = dark
            ? [NSColor(white: 0.22, alpha: 1), NSColor(red: 0.20, green: 0.30, blue: 0.49, alpha: 1), NSColor(red: 0.26, green: 0.43, blue: 0.70, alpha: 1), NSColor(red: 0.34, green: 0.57, blue: 0.89, alpha: 1), NSColor(red: 0.58, green: 0.73, blue: 1, alpha: 1)]
            : [NSColor(white: 0.91, alpha: 1), NSColor(red: 0.79, green: 0.86, blue: 0.97, alpha: 1), NSColor(red: 0.53, green: 0.69, blue: 0.93, alpha: 1), NSColor(red: 0.30, green: 0.52, blue: 0.85, alpha: 1), NSColor(red: 0.14, green: 0.36, blue: 0.70, alpha: 1)]
        let peak = values.values.max() ?? 0
        var previousMonth = ""
        for week in 0..<26 {
            let key = days[week * 7]
            let month = String(key.prefix(7))
            if month != previousMonth {
                if week < 25 && (week > 0 || (Int(key.suffix(2)) ?? 31) <= 7) { text(String(Int(key.dropFirst(5).prefix(2)) ?? 0) + "月", at: NSPoint(x: cellRect(week * 7).minX, y: 2)) }
                previousMonth = month
            }
        }
        for (row, name) in [(1, "一"), (3, "三"), (5, "五")] {
            text(name, at: NSPoint(x: 0, y: 22 + CGFloat(row) * 13), size: 8)
        }
        for index in days.indices {
            let rect = cellRect(index)
            let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            if let value = values[days[index]] {
                let level = value <= 0 || peak <= 0 ? 0 : max(1, min(4, Int(ceil(sqrt(value / peak) * 4))))
                palette[level].setFill(); path.fill()
            } else {
                (dark ? NSColor(white: 0.15, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill(); path.fill()
                NSColor.separatorColor.withAlphaComponent(0.30).setStroke(); path.lineWidth = 0.5; path.stroke()
            }
            if hovered == index {
                NSColor.controlAccentColor.setStroke(); path.lineWidth = 1.5; path.stroke()
            }
        }
        text("悬停或点击查看", at: NSPoint(x: 0, y: 121), size: 9)
        text("少", at: NSPoint(x: bounds.width - 88, y: 121), size: 8)
        for level in 0..<5 {
            palette[level].setFill()
            NSBezierPath(roundedRect: NSRect(x: bounds.width - 72 + CGFloat(level) * 11, y: 122, width: 8, height: 8), xRadius: 2, yRadius: 2).fill()
        }
        text("多", at: NSPoint(x: bounds.width - 12, y: 121), size: 8)
        if let hovered {
            let cell = cellRect(hovered)
            let width: CGFloat = 160; let height: CGFloat = 40
            let x = max(0, min(bounds.width - width, cell.midX - width / 2))
            let y = cell.minY >= 45 ? cell.minY - height - 4 : cell.maxY + 5
            let tooltip = NSRect(x: x, y: y, width: width, height: height)
            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.shadowBlurRadius = 5; shadow.shadowOffset = NSSize(width: 0, height: 1); shadow.set()
            NSColor(white: dark ? 0.92 : 0.13, alpha: 1).setFill()
            NSBezierPath(roundedRect: tooltip, xRadius: 6, yRadius: 6).fill()
            NSGraphicsContext.restoreGraphicsState()
            let foreground = NSColor(white: dark ? 0.1 : 1, alpha: 1)
            text(days[hovered], at: NSPoint(x: x + 9, y: y + 5), size: 9, color: foreground.withAlphaComponent(0.75))
            let value = values[days[hovered]].map { $0.formatted(.number.precision(.fractionLength(0))) + " Token" } ?? "未返回数据"
            text(value, at: NSPoint(x: x + 9, y: y + 20), size: 11, color: foreground, weight: .medium)
        }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
}
