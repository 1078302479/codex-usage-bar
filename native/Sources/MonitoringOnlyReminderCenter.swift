import Foundation

/// A secondary monitor must never reconcile or remove the main account's notifications.
struct MonitoringOnlyReminderCenter: ReminderNotificationCenter {
    func permission() async -> ReminderPermission { .unavailable }
    func requestPermission() async throws -> Bool { false }
    func pendingIDs() async -> Set<String> { [] }
    func deliveredIDs() async -> Set<String> { [] }
    func add(_ reminder: ResetCreditReminder) async throws { throw CocoaError(.featureUnsupported) }
    func removePending(_ ids: [String]) async {}
    func removeDelivered(_ ids: [String]) async {}
}
