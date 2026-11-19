import AppKit

@MainActor
enum MenuBarRenderer {
    static func colorHex(window: QuotaWindow?, rules: [PercentageColorRule]?, verified: Bool, now: Date) -> String? {
        guard verified, let window, !window.isResetPending(at: now), let value = window.remaining else { return nil }
        return colorHex(remaining: value, rules: rules)
    }
    static func colorHex(remaining: Double, rules: [PercentageColorRule]?) -> String? {
        rules?.first(where: { $0.matches(remaining) })?.hex
    }
    static func percentageColor(remaining: Double, rules: [PercentageColorRule]?) -> NSColor {
        colorHex(remaining: remaining, rules: rules).map(color) ?? PanelPalette.remainingQuotaColor(remaining)
    }
    static func color(_ hex: String) -> NSColor {
        let rgb = UInt32(hex, radix: 16) ?? 0xFFFFFF
        return NSColor(srgbRed: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                       blue: Double(rgb & 255) / 255, alpha: 1)
    }
    static func attributed(_ text: String, colors: [NSColor], font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        let regex = try! NSRegularExpression(pattern: #"<?[0-9]+(?:\.[0-9]+)?%"#)
        for (index, match) in regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length)).enumerated() {
            if index < colors.count { result.addAttribute(.foregroundColor, value: colors[index], range: match.range) }
        }
        return result
    }
    static func percentageColors(snapshot: QuotaSnapshot?, preferences p: Preferences, verified: Bool, now: Date) -> [NSColor] {
        guard verified else { return [] }
        let bucket = QuotaPresentation.selectedBucket(snapshot, preferences: p)
        return [(p.showPrimary, bucket?.primary, p.primaryColorRules), (p.showSecondary, bucket?.secondary, p.secondaryColorRules)].compactMap { shown, window, rules in
            guard shown, let window, !window.isResetPending(at: now), let remaining = window.remaining else { return nil }
            return percentageColor(remaining: remaining, rules: rules)
        }
    }
    static func title(snapshot: QuotaSnapshot?, preferences: Preferences, verified: Bool, now: Date) -> NSAttributedString {
        attributed(QuotaPresentation.menuTitle(snapshot: snapshot, preferences: preferences, verified: verified, now: now),
                   colors: percentageColors(snapshot: snapshot, preferences: preferences, verified: verified, now: now),
                   font: .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular))
    }
    static func stackedColors(snapshot: QuotaSnapshot?, preferences p: Preferences, verified: Bool, now: Date) -> [[NSColor]] {
        var top = p; top.isStacked = false; top.showIcon = true; top.showPrimary = false; top.showPrimaryReset = false
        var bottom = p; bottom.isStacked = false; bottom.showIcon = true; bottom.showSecondary = false; bottom.showSecondaryReset = false; bottom.showPlan = false
        return [top, bottom].filter { !QuotaPresentation.menuTitle(snapshot: snapshot, preferences: $0, verified: verified, now: now).isEmpty }
            .map { percentageColors(snapshot: snapshot, preferences: $0, verified: verified, now: now) }
    }
    static func stackedImage(lines: [String], showIcon: Bool, colors: [[NSColor]] = []) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium)
        let rows = Array(lines.prefix(2)).enumerated().map { index, line in
            attributed(line, colors: index < colors.count ? colors[index] : [], font: font)
        }
        let textWidth = ceil(rows.map { $0.size().width }.max() ?? 0)
        let iconWidth: CGFloat = showIcon ? (rows.isEmpty ? 18 : 23) : 0
        let size = NSSize(width: max(16, iconWidth + textWidth), height: 22)
        let image = NSImage(size: size, flipped: false) { _ in
            if showIcon { ProviderIcon.codex().draw(in: NSRect(x: 0, y: 2.5, width: 17, height: 17)) }
            for (index, row) in rows.enumerated() {
                let y: CGFloat = rows.count == 1 ? 5 : (index == 0 ? 10.5 : -0.5)
                row.draw(at: NSPoint(x: iconWidth, y: y))
            }
            return true
        }
        image.isTemplate = !showIcon && colors.allSatisfy { $0.isEmpty }
        image.cacheMode = .never
        image.accessibilityDescription = lines.prefix(2).joined(separator: "，")
        return image
    }
}
