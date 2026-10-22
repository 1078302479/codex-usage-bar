import Foundation
import Combine
import UserNotifications
import AppKit

enum ReminderPermission: Sendable, Equatable { case unknown, allowed, denied, unavailable }
private enum ReminderSchedulingError: Error { case expired }

protocol ReminderNotificationCenter: Sendable {
    func permission() async -> ReminderPermission
    func requestPermission() async throws -> Bool
    func pendingIDs() async -> Set<String>
    func deliveredIDs() async -> Set<String>
    func add(_ reminder: ResetCreditReminder) async throws
    func removePending(_ ids: [String]) async
    func removeDelivered(_ ids: [String]) async
}

struct SystemReminderCenter: ReminderNotificationCenter {
    // Command-line probes/tests have no app bundle. Do not instantiate UN there.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }
    func permission() async -> ReminderPermission {
        guard let center else { return .unavailable }
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional: return .allowed
        case .notDetermined: return .unknown
        default: return .denied
        }
    }
    func requestPermission() async throws -> Bool {
        guard let center else { return false }
        return try await center.requestAuthorization(options: [.alert, .sound])
    }
    func pendingIDs() async -> Set<String> {
        guard let center else { return [] }
        return Set(await center.pendingNotificationRequests().map(\.identifier))
    }
    func deliveredIDs() async -> Set<String> {
        guard let center else { return [] }
        return Set(await center.deliveredNotifications().map { $0.request.identifier })
    }
    func add(_ reminder: ResetCreditReminder) async throws {
        guard let center else { throw CocoaError(.featureUnsupported) }
        guard reminder.expiresAt.timeIntervalSinceNow > 1 else { throw ReminderSchedulingError.expired }
        let content = UNMutableNotificationContent()
        content.title = "重置卡即将过期"
        content.body = reminder.body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, reminder.fireAt.timeIntervalSinceNow), repeats: false)
        try await center.add(UNNotificationRequest(identifier: reminder.identifier, content: content, trigger: trigger))
    }
    func removePending(_ ids: [String]) async { center?.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(_ ids: [String]) async { center?.removeDeliveredNotifications(withIdentifiers: ids) }
}

@MainActor
final class ResetCreditReminderController: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var permission: ReminderPermission = .unknown
    @Published private(set) var isUpdating = false
    @Published private(set) var scheduledCount = 0
    @Published private(set) var message = "开启后，在重置卡到期前 24 小时提醒。"
    var onConfigurationChange: (() -> Void)?
    var onNeedsRefresh: (() -> Void)?

    private struct Record: Codable { let fireAt: Date; let expiresAt: Date }
    private let defaults: UserDefaults
    private let center: any ReminderNotificationCenter
    private let clock: () -> Date
    private var records: [String: Record]
    private var snapshot: QuotaSnapshot?
    private var verified = false
    private var revision = 0
    private var worker: Task<Void, Never>?
    private static let enabledKey = "reset-credit-reminders.enabled.v1"
    private static let ledgerKey = "reset-credit-reminders.ledger.v1"

    init(defaults: UserDefaults, center: any ReminderNotificationCenter = SystemReminderCenter(), clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults; self.center = center; self.clock = clock
        enabled = defaults.bool(forKey: Self.enabledKey)
        records = defaults.data(forKey: Self.ledgerKey).flatMap { try? JSONDecoder().decode([String: Record].self, from: $0) } ?? [:]
    }

    func start() { enqueue() }
    func refreshPermission() { enqueue() }

    func setEnabled(_ value: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        if value {
            var status = await center.permission()
            if status == .unknown {
                do { _ = try await center.requestPermission(); status = await center.permission() }
                catch { message = "无法请求系统通知权限，请稍后重试。"; return }
            }
            permission = status
            guard status == .allowed else {
                message = status == .unavailable ? "请从已构建的应用中开启通知。" : "系统通知尚未允许，请在系统设置中允许 CodexUsageBar 通知。"
                return
            }
        }
        enabled = value; defaults.set(value, forKey: Self.enabledKey)
        // Opt-in requires a new service validation, not just a recently viewed
        // snapshot: the card may have been consumed on another device meanwhile.
        if value { snapshot = nil; verified = false }
        enqueue(); onConfigurationChange?()
        if value { onNeedsRefresh?() }
    }

    func update(snapshot: QuotaSnapshot?, verified: Bool) {
        self.snapshot = snapshot; self.verified = verified
        // Disabled users never prompt for permission or schedule notifications.
        if enabled || worker != nil { enqueue() }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
    }

    func flush() async {
        while let task = worker { await task.value }
    }

    private func enqueue() {
        revision += 1
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while true {
                let token = revision
                await reconcile(token)
                if token == revision { break }
            }
            worker = nil
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.ledgerKey) }
    }

    private func reconcile(_ token: Int) async {
        let status = await center.permission()
        guard token == revision else { return }
        permission = status
        let pending = await center.pendingIDs().filter { $0.hasPrefix(ResetCreditReminder.prefix) }
        guard token == revision else { return }
        let delivered = await center.deliveredIDs().filter { $0.hasPrefix(ResetCreditReminder.prefix) }
        guard token == revision else { return }
        let now = clock()
        records = records.filter { $0.value.expiresAt.addingTimeInterval(86400) > now }
        let validSnapshot = verified && snapshot?.accountScope != nil && snapshot.map {
            (-60...QuotaPresentation.staleAfter).contains(now.timeIntervalSince($0.observedAt))
        } == true
        let plan = enabled && status == .allowed && validSnapshot
            ? ResetCreditReminder.plan(snapshot: snapshot, verified: true, now: now) : []
        let desired = Set(plan.map(\.identifier))
        let cancelled = pending.subtracting(desired)
        await center.removePending(Array(cancelled))
        // A cancelled pending notification has not been delivered. Allow a later
        // verified snapshot or re-enable to reschedule it, including a catch-up.
        for id in cancelled where !delivered.contains(id) { records.removeValue(forKey: id) }
        await center.removeDelivered(Array(delivered.subtracting(desired)))
        persist()
        guard token == revision else { return }
        scheduledCount = pending.intersection(desired).count
        guard enabled, status == .allowed, validSnapshot else {
            if !enabled { message = "提醒已关闭。" }
            else if status == .denied { message = "系统通知被关闭，请在系统设置中允许通知。" }
            else if status == .unavailable { message = "通知需要从原生应用运行。" }
            else { message = "等待成功核验当前账号后安排提醒。" }
            return
        }
        var failed = false
        for reminder in plan {
            guard token == revision else { return }
            if pending.contains(reminder.identifier) { continue }
            if delivered.contains(reminder.identifier) { continue }
            // Past reservations that are no longer pending were already handled
            // by Notification Center, including while the app was not running.
            if let record = records[reminder.identifier], record.fireAt <= now { continue }
            do {
                try await center.add(reminder)
                guard token == revision else {
                    await center.removePending([reminder.identifier])
                    return
                }
                records[reminder.identifier] = Record(fireAt: reminder.fireAt, expiresAt: reminder.expiresAt)
                persist(); scheduledCount += 1
            } catch { failed = true }
        }
        if failed { message = "部分提醒安排失败，将在下次核验时重试。" }
        else if snapshot?.resetCredits == nil { message = "当前服务未返回重置卡信息。" }
        else if snapshot?.resetCredits?.availableCount == 0 { message = "当前没有可用重置卡。" }
        else if snapshot?.resetCredits?.credits == nil { message = "仅返回数量，尚无到期明细，无法安排过期提醒。" }
        else { message = scheduledCount > 0 ? "已安排 \(scheduledCount) 条到期提醒；每张卡仅提醒一次。" : "暂无待发送的到期提醒。" }
    }
}
