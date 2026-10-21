import Foundation

@main struct CoreTests {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            guard condition() else { fatalError("FAIL: \(label)") }
            count += 1; print("PASS: \(label)")
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let short = QuotaWindow(usedPercent: 16, windowDurationMins: 300, resetsAt: now.addingTimeInterval(3600).timeIntervalSince1970)
        let long = QuotaWindow(usedPercent: 3, windowDurationMins: 10080, resetsAt: now.addingTimeInterval(86400).timeIntervalSince1970)
        let bucket = QuotaBucket(limitId: "codex", limitName: nil, primary: short, secondary: long, planType: "plus", spendControlReached: false, rateLimitReachedType: nil)
        let snapshot = QuotaSnapshot(observedAt: now, accountScope: "account-a", accountLabel: "te***@example.com", planType: "plus", buckets: [bucket])
        let activity = try JSONDecoder().decode(TokenActivity.self, from: Data(#"{"summary":{"lifetimeTokens":1500000000,"peakDailyTokens":250000000,"longestRunningTurnSec":57120,"currentStreakDays":2,"longestStreakDays":5},"dailyUsageBuckets":[{"startDate":"2026-10-19","tokens":0},{"startDate":"2026-10-20","tokens":25},{"startDate":"2026-10-20","tokens":30},{"startDate":"2026-02-30","tokens":99},{"startDate":"2026-10-18","tokens":null}]}"#.utf8))
        check(TokenActivity.count(activity.summary?.lifetimeTokens) == "15亿", "official lifetime summary formatting")
        check(TokenActivity.duration(activity.summary?.longestRunningTurnSec) == "15 小时 52 分", "longest turn preserves official seconds")
        check(activity.dailyValues["2026-10-19"] == 0 && activity.dailyValues["2026-10-18"] == nil, "missing daily usage differs from zero")
        check(activity.dailyValues.count == 2 && activity.dailyValues["2026-10-20"] == 30, "daily rows validate dates and do not double count duplicates")
        check(TokenActivity.count(nil) == "暂无数据" && TokenActivity.count(-1) == "暂无数据", "missing and invalid metrics are not invented")
        let emptyActivity = try JSONDecoder().decode(TokenActivity.self, from: Data(#"{"summary":null,"dailyUsageBuckets":null}"#.utf8))
        check(emptyActivity.dailyUsageBuckets == nil, "nullable official activity supported")
        check(TokenActivity.heatmapDays(now: now).count == 182, "heatmap has 26 complete weeks")
        var p = Preferences()
        check(p.refreshMode == .followClient && p.refreshMode.interval == nil, "default follows client, not fixed polling")
        check(QuotaPresentation.menuTitle(snapshot: snapshot, preferences: p, verified: true, now: now) == "5h 84% | 7d 97%", "both independent windows with separator")
        p.isStacked = true
        check(QuotaPresentation.stackedLines(snapshot: snapshot, preferences: p, verified: true, now: now) == ["7d 97%", "5h 84%"], "stacked menu puts seven-day above five-hour")
        check(QuotaPresentation.stackedLines(snapshot: snapshot, preferences: p, verified: false, now: now) == ["7d --", "5h --"], "stacked menu preserves unknown state")
        var onlyWeek = p; onlyWeek.showPrimary = false
        check(QuotaPresentation.stackedLines(snapshot: snapshot, preferences: onlyWeek, verified: true, now: now) == ["7d 97%"], "stacked menu respects selected metrics")
        var oldJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as! [String: Any]
        oldJSON.removeValue(forKey: "stackedDisplay")
        let migrated = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: oldJSON))
        check(!migrated.isStacked && migrated.showSecondary, "old preferences migrate without losing choices")
        let restoredStack = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        check(restoredStack.isStacked, "stacked menu preference survives restart")
        var resetPrefs = Preferences()
        resetPrefs.showPrimary = false; resetPrefs.showSecondary = false
        resetPrefs.showPrimaryReset = true; resetPrefs.showSecondaryReset = true
        resetPrefs.showResetDescriptions = false
        let iso = ISO8601DateFormatter()
        let resetBucket = QuotaBucket(limitId: "codex", limitName: nil,
            primary: QuotaWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: iso.date(from: "2026-10-21T05:51:00Z")!.timeIntervalSince1970),
            secondary: QuotaWindow(usedPercent: 20, windowDurationMins: 10080, resetsAt: iso.date(from: "2026-10-27T06:34:00Z")!.timeIntervalSince1970),
            planType: "plus", spendControlReached: false, rateLimitReachedType: nil)
        let resetSnapshot = QuotaSnapshot(observedAt: now, accountScope: "a", accountLabel: "masked", planType: "plus", buckets: [resetBucket])
        check(QuotaPresentation.menuTitle(snapshot: resetSnapshot, preferences: resetPrefs, verified: true, now: now) == "13:51 | 10-27", "short reset shows only time and long reset only month-day")
        check(QuotaPresentation.stackedLines(snapshot: resetSnapshot, preferences: resetPrefs, verified: true, now: now) == ["10-27", "13:51"], "stacked reset formats preserve long-above-short order")
        resetPrefs.showLabels = false; resetPrefs.showResetDescriptions = true
        check(QuotaPresentation.menuTitle(snapshot: resetSnapshot, preferences: resetPrefs, verified: true, now: now) == "短期重置 13:51 | 长期重置 10-27", "reset descriptions toggle independently of quota labels")
        check(QuotaPresentation.menuTitle(snapshot: resetSnapshot, preferences: resetPrefs, verified: false, now: now) == "短期重置 -- | 长期重置 --", "unverified resets remain unknown")
        let savedReset = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(resetPrefs))
        check(savedReset.showResetDescriptions && !savedReset.showLabels, "reset description preference persists independently")
        var resetLegacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(resetPrefs)) as! [String: Any]
        resetLegacy.removeValue(forKey: "resetDescriptions")
        let migratedReset = try JSONDecoder().decode(Preferences.self, from: JSONSerialization.data(withJSONObject: resetLegacy))
        check(!migratedReset.showResetDescriptions && migratedReset.showPrimaryReset, "old reset description preference follows previous labels without data loss")
        p.isStacked = false
        p.useSeparator = false
        check(QuotaPresentation.menuTitle(snapshot: snapshot, preferences: p, verified: true, now: now) == "5h 84% 7d 97%", "separator can be removed")
        p.useSeparator = true; p.separator = "·"
        check(QuotaPresentation.menuTitle(snapshot: snapshot, preferences: p, verified: true, now: now) == "5h 84% · 7d 97%", "custom separator")
        p.showPrimary = false
        check(QuotaPresentation.menuTitle(snapshot: snapshot, preferences: p, verified: true, now: now) == "7d 97%", "seven-day remaining alone")
        p.showPrimary = true; p.showLabels = false
        check(QuotaPresentation.menuTitle(snapshot: snapshot, preferences: p, verified: true, now: now) == "84% · 97%", "compact display without labels")
        p = Preferences()
        check(QuotaPresentation.menuTitle(snapshot: snapshot, preferences: p, verified: false, now: now) == "5h -- | 7d --", "cached or changed account never appears verified")
        check(QuotaPresentation.menuTitle(snapshot: snapshot, preferences: p, verified: true, now: now.addingTimeInterval(301)) == "5h 84%* | 7d 97%*", "stale values are marked")
        let expired = QuotaWindow(usedPercent: 100, windowDurationMins: 300, resetsAt: now.timeIntervalSince1970)
        check(QuotaPresentation.value(expired, verified: true, now: now) == "--", "reset boundary does not fabricate 100 percent")
        check(QuotaPresentation.value(short, verified: true, now: now) == "84%", "remaining subtracts used")
        check(QuotaWindow(usedPercent: 0, windowDurationMins: 300, resetsAt: nil).remaining == 100, "zero usage is a valid full allowance")
        check(QuotaWindow(usedPercent: nil, windowDurationMins: 300, resetsAt: nil).remaining == nil, "unknown is not zero")
        check(QuotaWindow(usedPercent: 101, windowDurationMins: 300, resetsAt: nil).remaining == nil, "invalid usage rejected")
        check(QuotaPresentation.percent(0.4) == "<1%", "small remaining not rounded to exhausted")
        check(QuotaPresentation.percent(2.5) == "2.5%", "fractional percentage preserved")
        check(QuotaPresentation.percent(99.99) != "100%", "partially used allowance never rounded to full")
        let raw = Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":99}},"rateLimitsByLimitId":{"other":{"primary":{"usedPercent":42}},"codex":{"primary":{"usedPercent":16}}}}"#.utf8)
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: raw)
        check(response.buckets().count == 2 && response.buckets().first?.id == "codex", "multi-bucket view replaces legacy without duplication")
        let account = AccountInfo(type: "chatgpt", id: "account-a", chatgptAccountId: nil, workspaceId: "work-a", email: "testing@example.com", planType: "plus")
        let other = AccountInfo(type: "chatgpt", id: "account-a", chatgptAccountId: nil, workspaceId: "work-b", email: "testing@example.com", planType: "plus")
        check(account.maskedLabel == "te***@example.com", "account label is masked")
        check(account.scopeKey != other.scopeKey, "different workspaces isolated when supplied")
        let encoded = try JSONEncoder().encode(p)
        let restored = try JSONDecoder().decode(Preferences.self, from: encoded)
        check(restored == p, "display preferences survive persistence")
        p.showPrimary = false; p.showSecondary = false; p.showIcon = false
        check(QuotaPresentation.menuTitle(snapshot: snapshot, preferences: p, verified: true, now: now) == "CodexUsageBar", "all metrics disabled leaves accessible app entry")
        print("\(count) core checks passed")
    }
}
