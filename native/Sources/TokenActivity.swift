import Foundation

struct TokenActivity: Codable, Sendable {
    struct Summary: Codable, Sendable {
        let lifetimeTokens: Double?
        let peakDailyTokens: Double?
        let longestRunningTurnSec: Double?
        let currentStreakDays: Double?
        let longestStreakDays: Double?
    }
    struct DailyBucket: Codable, Sendable {
        let startDate: String
        let tokens: Double?
    }
    let summary: Summary?
    let dailyUsageBuckets: [DailyBucket]?

    static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }
    static func count(_ value: Double?) -> String {
        guard let value = valid(value) else { return "暂无数据" }
        let unit: Double; let suffix: String
        if value >= 100_000_000 { unit = 100_000_000; suffix = "亿" }
        else if value >= 10_000 { unit = 10_000; suffix = "万" }
        else { unit = 1; suffix = "" }
        return (value / unit).formatted(.number.precision(.fractionLength(0...1))) + suffix
    }
    static func duration(_ value: Double?) -> String {
        guard let value = valid(value), value < Double(Int.max) else { return "暂无数据" }
        let seconds = Int(value)
        if seconds >= 3600 { return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分" }
        if seconds >= 60 { return "\(seconds / 60) 分 \(seconds % 60) 秒" }
        return "\(seconds) 秒"
    }
    static func days(_ value: Double?) -> String {
        guard let value = valid(value) else { return "暂无数据" }
        return count(value) + " 天"
    }
    // Dates are service-defined calendar buckets. Never infer missing buckets as zero,
    // or sum duplicate rows: the last valid row for a date wins.
    var dailyValues: [String: Double] {
        var result: [String: Double] = [:]
        for row in dailyUsageBuckets ?? [] {
            if Self.date(row.startDate) != nil, let value = Self.valid(row.tokens) { result[row.startDate] = value }
        }
        return result
    }
    static func date(_ key: String) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard key.count == 10, let date = f.date(from: key), f.string(from: date) == key else { return nil }
        return date
    }
    static func dayKey(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
    static func heatmapDays(now: Date = Date()) -> [String] {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // A 26-week grid aligned Sunday–Saturday; future cells stay empty.
        let today = calendar.startOfDay(for: now)
        let weekEnd = calendar.date(byAdding: .day, value: 7 - calendar.component(.weekday, from: today), to: today)!
        return (0..<182).map { dayKey(calendar.date(byAdding: .day, value: $0 - 181, to: weekEnd)!) }
    }
}
