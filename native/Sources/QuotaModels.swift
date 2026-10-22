import Foundation
import CryptoKit

struct QuotaWindow: Codable, Sendable, Equatable {
    let usedPercent: Double?
    let windowDurationMins: Int?
    let resetsAt: Double?

    var remaining: Double? {
        guard let usedPercent, usedPercent.isFinite, (0...100).contains(usedPercent) else { return nil }
        return 100 - usedPercent
    }
    var resetDate: Date? {
        guard let resetsAt, resetsAt.isFinite, resetsAt > 0, resetsAt <= 253402300799 else { return nil }
        return Date(timeIntervalSince1970: resetsAt)
    }
    var shortLabel: String {
        guard let n = windowDurationMins, n > 0 else { return "额度" }
        if n % 1440 == 0 { return "\(n / 1440)d" }
        if n % 60 == 0 { return "\(n / 60)h" }
        return "\(n)m"
    }
    var label: String {
        guard let n = windowDurationMins, n > 0 else { return "额度窗口" }
        if n % 1440 == 0 { return "\(n / 1440) 天窗口" }
        if n % 60 == 0 { return "\(n / 60) 小时窗口" }
        return "\(n) 分钟窗口"
    }
    func isResetPending(at now: Date) -> Bool { resetDate.map { $0 <= now } ?? false }
}

struct QuotaBucket: Codable, Sendable, Equatable, Identifiable {
    let limitId: String?
    let limitName: String?
    let primary: QuotaWindow?
    let secondary: QuotaWindow?
    let planType: String?
    let spendControlReached: Bool?
    let rateLimitReachedType: String?
    var id: String { limitId ?? "legacy" }
    var displayName: String { limitName ?? limitId ?? "Codex" }
}

struct AccountInfo: Codable, Sendable, Equatable {
    let type: String?
    let id: String?
    let chatgptAccountId: String?
    let workspaceId: String?
    let email: String?
    let planType: String?

    var name: String? = nil

    var scopeKey: String? {
        guard let identifier = chatgptAccountId ?? id ?? email else { return nil }
        let value = [type ?? "unknown", identifier, workspaceId ?? "workspace-unavailable"].joined(separator: "|")
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    var maskedLabel: String {
        guard let email, let at = email.lastIndex(of: "@") else { return "Codex 当前登录" }
        return String(email.prefix(2)) + "***" + email[at...]
    }
}

struct AccountResponse: Decodable, Sendable { let account: AccountInfo? }
struct RateLimitsResponse: Decodable, Sendable {
    let rateLimits: QuotaBucket?
    let rateLimitsByLimitId: [String: QuotaBucket]?
    let rateLimitResetCredits: ResetCreditSummary?
    private enum CodingKeys: String, CodingKey { case rateLimits, rateLimitsByLimitId, rateLimitResetCredits }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rateLimits = try c.decodeIfPresent(QuotaBucket.self, forKey: .rateLimits)
        rateLimitsByLimitId = try c.decodeIfPresent([String: QuotaBucket].self, forKey: .rateLimitsByLimitId)
        // An optional reward schema must never break ordinary quota validation.
        rateLimitResetCredits = try? c.decodeIfPresent(ResetCreditSummary.self, forKey: .rateLimitResetCredits)
    }
    func buckets() -> [QuotaBucket] {
        if let map = rateLimitsByLimitId, !map.isEmpty {
            return map.keys.sorted { a, b in a == "codex" ? b != "codex" : b == "codex" ? false : a < b }.compactMap { key in
                guard let bucket = map[key] else { return nil }
                return QuotaBucket(limitId: bucket.limitId ?? key, limitName: bucket.limitName,
                                   primary: bucket.primary, secondary: bucket.secondary, planType: bucket.planType,
                                   spendControlReached: bucket.spendControlReached, rateLimitReachedType: bucket.rateLimitReachedType)
            }
        }
        return rateLimits.map { [$0] } ?? []
    }
}

struct QuotaSnapshot: Codable, Sendable, Equatable {
    let observedAt: Date
    let accountScope: String?
    let accountLabel: String
    let planType: String?
    let buckets: [QuotaBucket]
    var accountName: String? = nil
    var resetCredits: ResetCreditSummary? = nil
}

enum RefreshMode: String, Codable, CaseIterable, Sendable {
    case followClient, everyMinute, everyFiveMinutes, everyFifteenMinutes
    var title: String {
        switch self {
        case .followClient: return "跟随 Codex 客户端（默认）"
        case .everyMinute: return "每 1 分钟"
        case .everyFiveMinutes: return "每 5 分钟"
        case .everyFifteenMinutes: return "每 15 分钟"
        }
    }
    var interval: TimeInterval? {
        switch self {
        case .followClient: return nil
        case .everyMinute: return 60
        case .everyFiveMinutes: return 300
        case .everyFifteenMinutes: return 900
        }
    }
}

enum AppAppearance: String, Codable, CaseIterable, Sendable {
    case dark, light, system
    var title: String { self == .dark ? "深色" : self == .light ? "浅色" : "跟随系统" }
}

struct PercentageColorRule: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var lower = 0
    var upper = 20
    var hex = "FF9F0A"
    func matches(_ value: Double) -> Bool {
        (0...100).contains(lower) && (lower...100).contains(upper) && value.isFinite &&
        value >= Double(lower) && value <= Double(upper) &&
        hex.count == 6 && hex.allSatisfy { $0.isHexDigit }
    }
}

struct Preferences: Codable, Sendable, Equatable {
    var primaryColorRules: [PercentageColorRule]? = nil
    var secondaryColorRules: [PercentageColorRule]? = nil
    // Optional for backwards-compatible decoding of existing preferences.v1.
    var stackedDisplay: Bool? = nil
    var isStacked: Bool {
        get { stackedDisplay == true }
        set { stackedDisplay = newValue }
    }
    var showIcon = true
    var showPrimary = true
    var showSecondary = true
    var showPrimaryReset = false
    var showSecondaryReset = false
    var showPlan = false
    var showLabels = true
    var resetDescriptions: Bool? = nil
    var showResetDescriptions: Bool {
        get { resetDescriptions ?? showLabels }
        set { resetDescriptions = newValue }
    }
    var useSeparator = true
    var separator = "|"
    var refreshMode: RefreshMode = .followClient
    var appearance: AppAppearance = .light
    var selectedBucket = "codex"
    var cliPath = ""
}

enum QuotaPresentation {
    static let staleAfter: TimeInterval = 300
    static func percent(_ value: Double) -> String {
        if value > 0 && value < 1 { return "<1%" }
        // Never round a nonzero allowance to zero, or a partially used allowance to 100%.
        if value == 100 { return "100%" }
        if value == 0 { return "0%" }
        if value == value.rounded() { return String(format: "%.0f%%", value) }
        return String(format: "%.1f%%", min(99.9, value))
    }
    static func value(_ window: QuotaWindow?, verified: Bool, now: Date) -> String {
        guard verified, let window, let remaining = window.remaining, !window.isResetPending(at: now) else { return "--" }
        return percent(remaining)
    }
    static func time(_ date: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
    static func resetLabel(_ window: QuotaWindow?, now: Date) -> String {
        guard let date = window?.resetDate else { return "重置时间未知" }
        if date <= now { return "预计重置时间已到，待确认" }
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        f.dateFormat = calendar.isDate(date, inSameDayAs: now) ? "'今天' HH:mm" : "MM-dd HH:mm"
        return f.string(from: date) + " 重置"
    }
    static func selectedBucket(_ snapshot: QuotaSnapshot?, preferences: Preferences) -> QuotaBucket? {
        snapshot?.buckets.first { $0.id == preferences.selectedBucket } ?? snapshot?.buckets.first { $0.id == "codex" } ?? snapshot?.buckets.first
    }
    static func stackedLines(snapshot: QuotaSnapshot?, preferences p: Preferences, verified: Bool, now: Date) -> [String] {
        // Reuse the exact accuracy/formatting rules of the normal menu title.
        var top = p
        top.isStacked = false; top.showIcon = true
        top.showPrimary = false; top.showPrimaryReset = false
        var bottom = p
        bottom.isStacked = false; bottom.showIcon = true
        bottom.showSecondary = false; bottom.showSecondaryReset = false; bottom.showPlan = false
        let rows = [menuTitle(snapshot: snapshot, preferences: top, verified: verified, now: now),
                    menuTitle(snapshot: snapshot, preferences: bottom, verified: verified, now: now)].filter { !$0.isEmpty }
        return rows.isEmpty && !p.showIcon ? ["CodexUsageBar"] : rows
    }
    static func menuTitle(snapshot: QuotaSnapshot?, preferences p: Preferences, verified: Bool, now: Date) -> String {
        let bucket = selectedBucket(snapshot, preferences: p)
        var fields: [String] = []
        let stale = snapshot.map { now.timeIntervalSince($0.observedAt) > staleAfter } ?? false
        func remaining(_ w: QuotaWindow?, fallback: String) -> String {
            let number = value(w, verified: verified, now: now)
            let label = p.showLabels ? "\(w?.shortLabel ?? fallback) " : ""
            return label + number + (number != "--" && stale ? "*" : "")
        }
        if p.showPrimary { fields.append(remaining(bucket?.primary, fallback: "短期")) }
        if p.showSecondary { fields.append(remaining(bucket?.secondary, fallback: "长期")) }
        if p.showPrimaryReset {
            let text = verified ? bucket?.primary?.resetDate.map(time) ?? "--" : "--"
            fields.append((p.showResetDescriptions ? "短期重置 " : "") + text)
        }
        if p.showSecondaryReset {
            let date = bucket?.secondary?.resetDate
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "MM-dd"
            fields.append((p.showResetDescriptions ? "长期重置 " : "") + (verified ? date.map { f.string(from: $0) } ?? "--" : "--"))
        }
        if p.showPlan { fields.append(verified ? snapshot?.planType?.capitalized ?? "套餐未知" : "账号待核验") }
        if fields.isEmpty { return p.showIcon ? "" : "CodexUsageBar" }
        let separator = ["|", "·", "/", "—"].contains(p.separator) ? p.separator : "|"
        return fields.joined(separator: p.useSeparator ? " \(separator) " : " ")
    }
}

enum CodexFailure: Error, LocalizedError, Sendable, Equatable {
    case missingCLI, authRequired, unsupported, timeout, processStopped, invalidResponse, accountChanged, noQuota, permissionDenied
    case networkUnavailable, serviceUnavailable

    var canRetry: Bool {
        switch self {
        case .networkUnavailable, .serviceUnavailable, .timeout, .processStopped, .accountChanged, .noQuota: return true
        case .missingCLI, .authRequired, .unsupported, .permissionDenied, .invalidResponse: return false
        }
    }
    var errorDescription: String? {
        switch self {
        case .missingCLI: return "未找到 Codex CLI，请在设置中选择本机可执行文件。"
        case .authRequired: return "本机 Codex 尚未提供可用的 ChatGPT 登录，请在终端完成 codex login 后重试。"
        case .unsupported: return "当前 Codex 版本不支持额度读取，请更新 Codex。"
        case .timeout: return "额度查询超时，将自动重新核验，也可点击刷新立即重试。"
        case .processStopped: return "Codex 连接已断开，将自动重连，也可点击刷新立即重试。"
        case .invalidResponse: return "返回的数据格式无法确认。请检查或更新本机 Codex，再点击刷新重试。"
        case .accountChanged: return "查询期间登录账号发生变化，正在等待重新核验。"
        case .noQuota: return "当前账号未返回可展示的套餐额度。"
        case .permissionDenied: return "当前运行环境阻止了 Codex 启动，请确认应用有正常的本机运行权限。"
        case .networkUnavailable: return "网络请求失败，请检查网络或代理。将自动重试，也可点击刷新立即重试。"
        case .serviceUnavailable: return "服务暂时不可用或请求受限，将稍后自动重试。"
        }
    }
}
