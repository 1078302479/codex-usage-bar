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
        precondition(MenuBarRenderer.percentageColors(snapshot: snap, preferences: p, verified: true, now: now).allSatisfy { $0 == nil })
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
        precondition(rows == [["0000FF"], ["FF0000"]])
        precondition(!MenuBarRenderer.stackedImage(lines: ["50%", "50%"], showIcon: false, colors: rows).isTemplate)
        p.showSecondary = false
        precondition(MenuBarRenderer.stackedColors(snapshot: snap, preferences: p, verified: true, now: now) == [["FF0000"]])
        let encoded = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Preferences.self, from: encoded)
        precondition(decoded == p)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "primaryColorRules"); legacy.removeValue(forKey: "secondaryColorRules")
        let old = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.primaryColorRules == nil && old.secondaryColorRules == nil)
        print("PASS: menu color boundaries, overlap priority, percent-only styling, independent identical values, unknown/expired quotas, stacked/no-icon colors, persistence and legacy defaults")
    }
}
