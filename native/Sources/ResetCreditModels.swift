import Foundation
import CryptoKit

struct ResetCredit: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let resetType: String?
    let status: String?
    let grantedAt: Double?
    let expiresAt: Double?
    let title: String?
    let description: String?

    var expiryDate: Date? {
        guard let expiresAt, expiresAt.isFinite, expiresAt > 0, expiresAt <= 253402300799 else { return nil }
        return Date(timeIntervalSince1970: expiresAt)
    }
    var isAvailable: Bool { !id.isEmpty && status == "available" && resetType == "codexRateLimits" }
}

struct ResetCreditSummary: Codable, Equatable, Sendable {
    let availableCount: Int?
    let credits: [ResetCredit]?

    init(availableCount: Int?, credits: [ResetCredit]?) {
        self.availableCount = availableCount.flatMap { $0 >= 0 ? $0 : nil }
        self.credits = credits
    }
    private enum CodingKeys: String, CodingKey { case availableCount, credits }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let count = try? container.decode(Int.self, forKey: .availableCount)
        availableCount = count.flatMap { $0 >= 0 ? $0 : nil }
        if var rows = try? container.nestedUnkeyedContainer(forKey: .credits) {
            var valid: [ResetCredit] = []
            while !rows.isAtEnd {
                let row = try rows.superDecoder()
                if let value = try? ResetCredit(from: row), !value.id.isEmpty { valid.append(value) }
            }
            credits = valid
        } else { credits = nil }
    }
    var availableDetails: [ResetCredit] {
        guard availableCount != 0 else { return [] }
        // Conflicting rows are not safe to schedule. Keep the first ID once.
        let groups = Dictionary(grouping: credits ?? [], by: \.id)
        return groups.values.compactMap { rows in
            guard let first = rows.first, rows.allSatisfy({ $0 == first }), first.isAvailable else { return nil }
            return first
        }.sorted {
            let left = $0.expiryDate ?? .distantFuture, right = $1.expiryDate ?? .distantFuture
            return left == right ? $0.id < $1.id : left < right
        }
    }
    static func expiryLabel(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
    func expiringWithinThreeDays(now: Date) -> (count: Int, complete: Bool) {
        let details = availableDetails
        let knownDates = details.compactMap(\.expiryDate)
        let count = knownDates.filter { $0 > now && $0 <= now.addingTimeInterval(72 * 3600) }.count
        let complete = availableCount.map { $0 == details.count && knownDates.count == details.count } ?? false
        return (count, complete)
    }
    static func remainingLabel(until expiry: Date, now: Date) -> String {
        let remaining = expiry.timeIntervalSince(now)
        guard remaining > 0 else { return "已到期" }
        let minutes = Int(ceil(remaining / 60))
        let days = minutes / (24 * 60)
        let hours = (minutes / 60) % 24
        return "\(days) 天 \(hours) 小时 \(minutes % 60) 分钟后到期"
    }
}

struct ResetCreditReminder: Equatable, Sendable {
    static let prefix = "usagebar.reset-credit."
    let identifier: String
    let fireAt: Date
    let expiresAt: Date
    var body: String { "你有一张重置卡将于 " + ResetCreditSummary.expiryLabel(expiresAt) + "（北京时间）过期，记得按需使用。" }

    static func plan(snapshot: QuotaSnapshot?, verified: Bool, now: Date) -> [ResetCreditReminder] {
        guard verified, let snapshot, let scope = snapshot.accountScope, !scope.isEmpty,
              (-60...QuotaPresentation.staleAfter).contains(now.timeIntervalSince(snapshot.observedAt)),
              let summary = snapshot.resetCredits, let count = summary.availableCount, count > 0 else { return [] }
        // availableCount is authoritative; returned detail rows can be capped.
        return Array(summary.availableDetails.filter { $0.expiryDate.map { $0 > now } == true }.prefix(min(count, 32))).compactMap { credit in
            guard let expiry = credit.expiryDate, expiry > now.addingTimeInterval(1) else { return nil }
            let key = scope + "|" + credit.id + "|" + String(expiry.timeIntervalSince1970)
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return ResetCreditReminder(identifier: prefix + digest,
                                       fireAt: max(now.addingTimeInterval(1), expiry.addingTimeInterval(-86400)), expiresAt: expiry)
        }
    }
}
