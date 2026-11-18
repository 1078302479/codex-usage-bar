import Combine
import CryptoKit
import Foundation

struct LowQuotaReminder: Equatable, Sendable {
    let identifier: String
    let resetsAt: Date
    let body: String

    static func plan(snapshot: QuotaSnapshot?, threshold: Int, now: Date) -> [Self] {
        guard let snapshot, let scope = snapshot.accountScope, !scope.isEmpty,
              (-60...QuotaPresentation.staleAfter).contains(now.timeIntervalSince(snapshot.observedAt)),
              let bucket = QuotaPresentation.selectedBucket(snapshot, preferences: Preferences()) else { return [] }
        return [bucket.primary, bucket.secondary].enumerated().compactMap { index, window in
            guard let window, let remaining = window.remaining, remaining <= Double(threshold),
                  let reset = window.resetDate, reset > now else { return nil }
            let key = [scope, bucket.id, String(index), String(reset.timeIntervalSince1970)].joined(separator: "|")
            let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
            return Self(identifier: "usagebar.low-quota." + digest, resetsAt: reset,
                        body: "\(window.label)剩余 \(QuotaPresentation.percent(remaining))，\(QuotaPresentation.resetLabel(window, now: now))（北京时间）。")
        }
    }
}

@MainActor
final class LowQuotaReminderController: ObservableObject {
    static let thresholds = [5, 10, 15, 20, 25, 30]
    private static let enabledKey = "low-quota-reminders.enabled.v1"
    private static let thresholdKey = "low-quota-reminders.threshold.v1"
    private static let ledgerKey = "low-quota-reminders.ledger.v1"

    @Published private(set) var enabled: Bool
    @Published private(set) var threshold: Int
    @Published private(set) var permission: ReminderPermission = .unknown
    @Published private(set) var isUpdating = false
    var activeSnapshot: (() -> QuotaSnapshot?)?
    var onNeedsRefresh: (() -> Void)?

    private let defaults: UserDefaults
    private let center: any ReminderNotificationCenter
    private let clock: () -> Date
    private var sent: [String: Date]
    private var worker: Task<Void, Never>?
    private var needsCheck = false

    init(defaults: UserDefaults, center: any ReminderNotificationCenter, clock: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.center = center
        self.clock = clock
        enabled = defaults.bool(forKey: Self.enabledKey)
        let savedThreshold = defaults.integer(forKey: Self.thresholdKey)
        threshold = Self.thresholds.contains(savedThreshold) ? savedThreshold : 10
        sent = defaults.dictionary(forKey: Self.ledgerKey) as? [String: Date] ?? [:]
    }

    func setEnabled(_ value: Bool) async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        if value {
            permission = await center.permission()
            if permission == .unknown {
                _ = try? await center.requestPermission()
                permission = await center.permission()
            }
            guard permission == .allowed else { return }
        }
        enabled = value
        defaults.set(value, forKey: Self.enabledKey)
        if value { onNeedsRefresh?() }
    }

    func setThreshold(_ value: Int) {
        guard Self.thresholds.contains(value), value != threshold else { return }
        threshold = value
        defaults.set(value, forKey: Self.thresholdKey)
        if enabled { onNeedsRefresh?() }
    }

    func refreshPermission() async {
        guard !isUpdating else { return }
        permission = await center.permission()
    }

    func check() {
        guard enabled else { return }
        needsCheck = true
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while needsCheck {
                needsCheck = false
                await notify()
            }
            worker = nil
        }
    }

    func flush() async {
        while let worker { await worker.value }
    }

    private func candidates() -> [LowQuotaReminder] {
        guard enabled else { return [] }
        return LowQuotaReminder.plan(snapshot: activeSnapshot?(), threshold: threshold, now: clock())
            .filter { sent[$0.identifier] == nil }
    }

    private func notify() async {
        let retained = sent.filter { $0.value > clock() }
        if retained != sent {
            sent = retained
            defaults.set(sent, forKey: Self.ledgerKey)
        }
        guard !candidates().isEmpty else { return }
        await refreshPermission()
        guard permission == .allowed else { return }
        for reminder in candidates() {
            guard candidates().contains(reminder) else { continue }
            do {
                try await center.add(reminder)
                sent[reminder.identifier] = reminder.resetsAt
                defaults.set(sent, forKey: Self.ledgerKey)
            } catch {
                // A later successful quota check can retry delivery.
            }
        }
    }
}
