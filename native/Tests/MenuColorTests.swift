import AppKit

@main struct MenuColorTests {
    @MainActor static func main() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let red = PercentageColorRule(lower: 0, upper: 60, hex: "FF0000")
        let blue = PercentageColorRule(lower: 40, upper: 100, hex: "0000FF")
        precondition(red.matches(0) && red.matches(60) && !red.matches(60.01) && !red.matches(.nan))
        precondition(!PercentageColorRule(lower: 30, upper: 20, hex: "FF0000").matches(25))
        precondition(!PercentageColorRule(lower: 0, upper: 100, hex: "wrong!").matches(20))
        let w = QuotaWindow(usedPercent: 50, windowDurationMins: 300, resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970)
        let bucket = QuotaBucket(limitId: "codex", limitName: nil, primary: w, secondary: w, planType: nil, spendControlReached: nil, rateLimitReachedType: nil)
        let snap = QuotaSnapshot(observedAt: now, accountScope: "test", accountLabel: "Test", planType: "plus", buckets: [bucket])
        var p = Preferences()
        let low = PanelPalette.remainingQuotaColor(3)
        let medium = PanelPalette.remainingQuotaColor(37)
        let high = PanelPalette.remainingQuotaColor(58)
        precondition(Set([low, medium, high]).count == 3)
        func resolvedPalette(in appearance: NSAppearance.Name) -> [NSColor] {
            var colors: [NSColor] = []
            NSAppearance(named: appearance)!.performAsCurrentDrawingAppearance {
                colors = [low, medium, high].compactMap { $0.usingColorSpace(.sRGB) }
            }
            return colors
        }
        let lightPalette = resolvedPalette(in: .aqua)
        let darkPalette = resolvedPalette(in: .darkAqua)
        precondition(lightPalette.count == 3 && darkPalette.count == 3 && lightPalette != darkPalette)
        for (remaining, expected) in [(0.0, low), (20, low), (20.01, medium), (50, medium), (50.01, high), (100, high)] {
            precondition(MenuBarRenderer.percentageColor(remaining: remaining, rules: []) == expected)
        }
        precondition(MenuBarRenderer.percentageColors(snapshot: snap, preferences: p, verified: true, now: now) == [medium, medium])
        precondition(MenuBarRenderer.percentageColor(remaining: 58, rules: [PercentageColorRule(lower: 0, upper: 20)]) == high)
        precondition(MenuBarRenderer.percentageColors(snapshot: snap, preferences: p, verified: true, now: now.addingTimeInterval(3601)).isEmpty)
        p.isStacked = true; p.showIcon = false
        let defaultRows = MenuBarRenderer.stackedColors(snapshot: snap, preferences: p, verified: true, now: now)
        precondition(defaultRows == [[medium], [medium]])
        precondition(!MenuBarRenderer.stackedImage(lines: ["50%", "50%"], showIcon: false, colors: defaultRows).isTemplate)
        p = Preferences()
        p.primaryColorRules = [red, blue]; p.secondaryColorRules = [blue]
        let title = MenuBarRenderer.title(snapshot: snap, preferences: p, verified: true, now: now)
        let matches = try NSRegularExpression(pattern: "50%").matches(in: title.string, range: NSRange(location: 0, length: title.length))
        precondition(matches.count == 2)
        precondition((title.attribute(.foregroundColor, at: matches[0].range.location, effectiveRange: nil) as? NSColor) == MenuBarRenderer.color("FF0000"))
        precondition((title.attribute(.foregroundColor, at: matches[1].range.location, effectiveRange: nil) as? NSColor) == MenuBarRenderer.color("0000FF"))
        precondition((title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor) == NSColor.labelColor)
        precondition(MenuBarRenderer.percentageColors(snapshot: snap, preferences: p, verified: false, now: now).isEmpty)
        precondition(MenuBarRenderer.colorHex(window: w, rules: [red], verified: true, now: now.addingTimeInterval(3601)) == nil)
        p.isStacked = true; p.showIcon = false
        let rows = MenuBarRenderer.stackedColors(snapshot: snap, preferences: p, verified: true, now: now)
        precondition(rows == [[MenuBarRenderer.color("0000FF")], [MenuBarRenderer.color("FF0000")]])
        precondition(!MenuBarRenderer.stackedImage(lines: ["50%", "50%"], showIcon: false, colors: rows).isTemplate)
        p.showSecondary = false
        precondition(MenuBarRenderer.stackedColors(snapshot: snap, preferences: p, verified: true, now: now) == [[MenuBarRenderer.color("FF0000")]])
        let encoded = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Preferences.self, from: encoded)
        precondition(decoded == p)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "primaryColorRules"); legacy.removeValue(forKey: "secondaryColorRules")
        legacy.removeValue(forKey: "panelCompact"); legacy.removeValue(forKey: "panelFitsScreen")
        let old = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.primaryColorRules == nil && old.secondaryColorRules == nil)
        precondition(MenuBarRenderer.percentageColors(snapshot: snap, preferences: old, verified: true, now: now) == [medium])
        precondition(old.panelCompact == nil && old.panelFitsScreen == nil)
        p.panelCompact = true; p.panelFitsScreen = true
        let orbitPreferences = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        precondition(orbitPreferences.panelCompact == true && orbitPreferences.panelFitsScreen == true)
        print("PASS: menu color boundaries, overlap priority, percent-only styling, independent identical values, unknown/expired quotas, stacked/no-icon colors, persistence and legacy defaults")
    }
}
