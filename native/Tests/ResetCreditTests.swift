import Foundation

private actor TestReminderCenter: ReminderNotificationCenter {
    var status: ReminderPermission
    var grant = true
    var failAdd = false
    var holdAdd = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var permissionRequests = 0
    private(set) var added: [ResetCreditReminder] = []
    private(set) var lowQuotaAdded: [LowQuotaReminder] = []
    private(set) var pending: [String: ResetCreditReminder] = [:]
    private var delivered: Set<String> = []
    init(_ status: ReminderPermission = .allowed) { self.status = status }
    func permission() -> ReminderPermission { status }
    func requestPermission() -> Bool { permissionRequests += 1; status = grant ? .allowed : .denied; return grant }
    func pendingIDs() -> Set<String> { Set(pending.keys) }
    func deliveredIDs() -> Set<String> { delivered }
    func add(_ reminder: ResetCreditReminder) async throws {
        added.append(reminder)
        if holdAdd { await withCheckedContinuation { continuation = $0 } }
        if failAdd { throw CocoaError(.fileWriteUnknown) }
        pending[reminder.identifier] = reminder
    }
    func add(_ reminder: LowQuotaReminder) throws {
        if failAdd { throw CocoaError(.fileWriteUnknown) }
        lowQuotaAdded.append(reminder)
    }
    func removePending(_ ids: [String]) { for id in ids { pending.removeValue(forKey: id) } }
    func removeDelivered(_ ids: [String]) { delivered.subtract(ids) }
    func configure(status: ReminderPermission? = nil, grant: Bool = true, fail: Bool = false, hold: Bool = false) {
        if let status { self.status = status }; self.grant = grant; failAdd = fail; holdAdd = hold
    }
    func deliver(_ id: String) { pending.removeValue(forKey: id); delivered.insert(id) }
    func dismissAll() { delivered.removeAll() }
    func releaseAdd() { holdAdd = false; continuation?.resume(); continuation = nil }
    func addUnrelated() { pending["another.feature"] = ResetCreditReminder(identifier: "another.feature", fireAt: .distantFuture, expiresAt: .distantFuture) }
}

private actor CardFixtureClient: QuotaClient {
    private var handler: (@Sendable (CodexSignal) -> Void)?
    private var initialized = false
    private let expiry = Date().addingTimeInterval(172800)
    func setHandler(_ value: @escaping @Sendable (CodexSignal) -> Void) { handler = value }
    func fetch(customPath: String) async throws -> QuotaSnapshot {
        let first = !initialized
        initialized = true
        if first { handler?(.accountChanged); await Task.yield() }
        return ResetCreditTests.snapshot([ResetCreditTests.credit("integrated", expiry: expiry)], scope: first ? "old" : "current", at: Date())
    }
    func fetchUsage(expectedScope: String) -> TokenActivity { TokenActivity(summary: nil, dailyUsageBuckets: nil) }
    func shutdown() {}
}

@main struct ResetCreditTests {
    static let instant = Date(timeIntervalSince1970: 1_800_000_000)
    static func check(_ value: Bool, _ message: String) { precondition(value, message) }
    static func credit(_ id: String = "card", expiry: Date? = instant.addingTimeInterval(172800), status: String = "available") -> ResetCredit {
        ResetCredit(id: id, resetType: "codexRateLimits", status: status, grantedAt: nil, expiresAt: expiry?.timeIntervalSince1970, title: nil, description: nil)
    }
    static func snapshot(_ rows: [ResetCredit]?, count: Int? = 1, scope: String? = "account-a", at date: Date = instant) -> QuotaSnapshot {
        QuotaSnapshot(observedAt: date, accountScope: scope, accountLabel: "Fixture", planType: "plus", buckets: [], resetCredits: ResetCreditSummary(availableCount: count, credits: rows))
    }
    @MainActor private static func setup(_ center: TestReminderCenter) -> (ResetCreditReminderController, UserDefaults, String) {
        let suite = "usagebar-reset-tests-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (ResetCreditReminderController(defaults: defaults, center: center, clock: { instant }), defaults, suite)
    }
    @MainActor static func main() async throws {
        check(ResetCreditSummary.compactRemainingLabel(until: instant, now: instant) == "已到期，待核验", "Expired cards never show positive time")
        check(ResetCreditSummary.compactRemainingLabel(until: instant.addingTimeInterval(1), now: instant) == "约 1 分钟", "Subminute countdown is explicit")
        check(ResetCreditSummary.compactRemainingLabel(until: instant.addingTimeInterval(13 * 86400 + 18 * 3600), now: instant) == "约 13 天 18 小时", "Compact time retains days and hours")
        try decoding()
        planning()
        let threeDays = snapshot([credit("near", expiry: instant.addingTimeInterval(1)), credit("boundary", expiry: instant.addingTimeInterval(259200)), credit("outside", expiry: instant.addingTimeInterval(259201))], count: 3).resetCredits!
        check(threeDays.expiringWithinThreeDays(now: instant).count == 2 && threeDays.expiringWithinThreeDays(now: instant).complete, "72h includes exact boundary only")
        check(threeDays.expiringWithinThreeDays(now: instant.addingTimeInterval(1)).count == 2, "Already expired cards excluded")
        let partial = snapshot([credit("unknown", expiry: nil)], count: 3).resetCredits!.expiringWithinThreeDays(now: instant)
        check(partial.count == 0 && !partial.complete, "Incomplete dates cannot report definitive zero")

        await permissionAndOptIn()
        await persistenceAndCancellation()
        await failureAndRace()
        await stateIntegration()
        await lowQuotaNotifications()
        print("PASS: reset-credit decoding, eligibility, notifications, deduplication, cancellation and race regressions")
    }

    @MainActor private static func lowQuotaNotifications() async {
        let center = TestReminderCenter(.unknown)
        let (_, defaults, suite) = setup(center)
        defer { defaults.removePersistentDomain(forName: suite) }

        func quota(_ remaining: Double, scope: String = "active", resetAfter: Double = 300,
                   age: Double = 0) -> QuotaSnapshot {
            let window = QuotaWindow(usedPercent: 100 - remaining, windowDurationMins: 300,
                                     resetsAt: instant.addingTimeInterval(resetAfter).timeIntervalSince1970)
            let bucket = QuotaBucket(limitId: "codex", limitName: nil, primary: window, secondary: nil,
                                     planType: "free", spendControlReached: nil, rateLimitReachedType: nil)
            return QuotaSnapshot(observedAt: instant.addingTimeInterval(-age), accountScope: scope,
                                 accountLabel: "Fixture", planType: "free", buckets: [bucket])
        }

        var snapshot: QuotaSnapshot? = quota(12)
        let controller = LowQuotaReminderController(defaults: defaults, center: center, clock: { instant })
        controller.activeSnapshot = { snapshot }
        check(!controller.enabled && controller.threshold == 10, "Low quota is opt-in with a 10% default")
        controller.check()
        await controller.flush()
        let requests = await center.permissionRequests
        check(requests == 0, "Disabled low quota never requests authorization")
        await controller.setEnabled(true)
        controller.check()
        await controller.flush()
        let aboveThreshold = await center.lowQuotaAdded
        check(aboveThreshold.isEmpty, "Quota above threshold is silent")

        snapshot = quota(9)
        controller.check()
        controller.check()
        await controller.flush()
        let first = await center.lowQuotaAdded
        check(first.count == 1 && first[0].body.contains("9%") && first[0].body.contains("重置"),
              "Low quota reports the amount and reset time once")
        controller.setThreshold(15)
        let restarted = LowQuotaReminderController(defaults: defaults, center: center, clock: { instant })
        restarted.activeSnapshot = { snapshot }
        check(restarted.enabled && restarted.threshold == 15, "Opt-in and threshold persist")
        restarted.check()
        await restarted.flush()
        let duplicates = await center.lowQuotaAdded
        check(duplicates == first, "Delivery is deduplicated after app restart")

        snapshot = quota(8, resetAfter: 600, age: QuotaPresentation.staleAfter + 1)
        restarted.check()
        await restarted.flush()
        snapshot = quota(8, resetAfter: 0)
        restarted.check()
        await restarted.flush()
        let expired = await center.lowQuotaAdded
        check(expired == first, "Stale snapshots and expired windows never notify")

        snapshot = quota(8, resetAfter: 600)
        await center.configure(fail: true)
        restarted.check()
        await restarted.flush()
        await center.configure()
        restarted.check()
        await restarted.flush()
        snapshot = quota(8, scope: "other", resetAfter: 600)
        restarted.check()
        await restarted.flush()
        let later = await center.lowQuotaAdded
        check(later.count == 3 && Set(later.map(\.identifier)).count == 3,
              "New cycles and different accounts alert independently, and failed delivery can retry")
        print("PASS: low quota opt-in, threshold, freshness, durable deduplication and new cycles")
    }

    static func decoding() throws {
        let response = try JSONDecoder().decode(RateLimitsResponse.self, from: Data(#"{"rateLimits":{"limitId":"codex","primary":{"usedPercent":20}},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"a","resetType":"codexRateLimits","status":"available","expiresAt":1900000000},17,{"id":"bad","expiresAt":"not a date"},{"id":"b","resetType":"codexRateLimits","status":"available","expiresAt":null}]}}"#.utf8))
        check(response.buckets().count == 1, "Optional reset credits cannot break quota")
        check(response.rateLimitResetCredits?.availableCount == 3 && response.rateLimitResetCredits?.credits?.count == 2, "Skip malformed detail rows; preserve authoritative count")
        let countOnly = try JSONDecoder().decode(ResetCreditSummary.self, from: Data(#"{"availableCount":3,"credits":null}"#.utf8))
        let empty = try JSONDecoder().decode(ResetCreditSummary.self, from: Data(#"{"availableCount":0,"credits":[]}"#.utf8))
        check(countOnly.credits == nil && empty.credits == [], "Missing details differ from an empty list")
        let malformed = try JSONDecoder().decode(RateLimitsResponse.self, from: Data(#"{"rateLimits":{"limitId":"codex"},"rateLimitResetCredits":"bad"}"#.utf8))
        check(malformed.buckets().count == 1 && malformed.rateLimitResetCredits == nil, "Unknown reward payload preserves quota")
        let old = try JSONDecoder().decode(QuotaSnapshot.self, from: Data(#"{"observedAt":0,"accountScope":"fixture","accountLabel":"Fixture","planType":"plus","buckets":[]}"#.utf8))
        check(old.resetCredits == nil, "Old quota caches remain decodable")
        print("PASS: reset-credit protocol decoding is optional, loss tolerant and cache compatible")
    }

    static func planning() {
        let now = instant
        let valid = snapshot([credit()])
        let plan = ResetCreditReminder.plan(snapshot: valid, verified: true, now: now)
        check(plan.count == 1 && plan[0].fireAt == now.addingTimeInterval(86400), "Schedule exactly 24 hours before expiry")
        check(!plan[0].identifier.contains("account-a") && !plan[0].body.contains("account-a"), "Notification identifiers and copy do not expose account IDs")
        let soon = ResetCreditReminder.plan(snapshot: snapshot([credit(expiry: now.addingTimeInterval(3600))]), verified: true, now: now)
        check(soon.first?.fireAt == now.addingTimeInterval(1), "Catch up within 24 hours")
        check(ResetCreditReminder.plan(snapshot: valid, verified: false, now: now).isEmpty, "Unverified data cannot notify")
        check(ResetCreditReminder.plan(snapshot: valid, verified: true, now: now.addingTimeInterval(301)).isEmpty, "Stale data cannot schedule")
        for data in [snapshot([credit()], scope: nil), snapshot(nil), snapshot([credit(expiry: nil)]), snapshot([credit(expiry: now)]), snapshot([credit(expiry: now.addingTimeInterval(0.5))]), snapshot([credit(status: "used")]), snapshot([credit()], count: 0)] {
            check(ResetCreditReminder.plan(snapshot: data, verified: true, now: now).isEmpty, "Unknown, expired, used or unavailable cards cannot notify")
        }
        check(ResetCreditReminder.plan(snapshot: snapshot([credit(), credit()]), verified: true, now: now).count == 1, "Identical duplicate rows collapse")
        check(ResetCreditReminder.plan(snapshot: snapshot([credit(), credit(status: "used")]), verified: true, now: now).isEmpty, "Conflicting duplicate IDs cannot notify")
        let other = ResetCreditReminder.plan(snapshot: snapshot([credit()], scope: "account-b"), verified: true, now: now)
        check(other.first?.identifier != plan.first?.identifier, "Deduplication is account scoped")
        check(ResetCreditReminder.plan(snapshot: snapshot([credit("a"), credit("b")], count: 1), verified: true, now: now).count == 1, "Count remains authoritative")
        print("PASS: 24-hour scheduling, catch-up, unknown/expired/used handling and account scoping")
    }

    @MainActor static func permissionAndOptIn() async {
        let center = TestReminderCenter(.unknown)
        let (controller, defaults, suite) = setup(center)
        defer { defaults.removePersistentDomain(forName: suite) }
        controller.update(snapshot: snapshot([credit()]), verified: true)
        controller.start(); await controller.flush()
        check(!controller.enabled, "Disabled by default")
        check(await center.added.isEmpty, "Disabled users do not schedule notifications")
        check(await center.permissionRequests == 0, "Startup must not request permission")
        await controller.setEnabled(true); await controller.flush()
        check(controller.enabled, "Explicit opt-in enables reminders")
        check(await center.permissionRequests == 1, "Request permission only on opt-in")
        check(await center.added.isEmpty, "Enabling requires a new successful validation")
        controller.update(snapshot: snapshot([credit()]), verified: true); await controller.flush()
        check(await center.added.count == 1, "Opt-in schedules known expiry")
        await center.configure(status: .denied)
        controller.refreshPermission(); await controller.flush()
        check(await center.pendingIDs().isEmpty, "Revoked permission cancels pending reminders")
        let denied = TestReminderCenter(.unknown)
        await denied.configure(grant: false)
        let (blocked, d2, s2) = setup(denied)
        await blocked.setEnabled(true); await blocked.flush()
        check(!blocked.enabled && blocked.permission == .denied, "Permission denial does not fake an enabled toggle")
        d2.removePersistentDomain(forName: s2)
        print("PASS: opt-in permission, denial and revocation")
    }

    @MainActor static func persistenceAndCancellation() async {
        let center = TestReminderCenter()
        let (controller, defaults, suite) = setup(center)
        defer { defaults.removePersistentDomain(forName: suite) }
        let data = snapshot([credit("soon", expiry: instant.addingTimeInterval(3600)), credit("later")], count: 2)
        controller.update(snapshot: data, verified: true)
        await controller.setEnabled(true); await controller.flush()
        controller.update(snapshot: data, verified: true); await controller.flush()
        check(await center.added.count == 2, "Schedule one notification per card")
        controller.update(snapshot: data, verified: true); await controller.flush()
        check(await center.added.count == 2, "Repeated refresh does not duplicate pending notifications")
        let soonID = ResetCreditReminder.plan(snapshot: data, verified: true, now: instant)[0].identifier
        await center.deliver(soonID)
        let restarted = ResetCreditReminderController(defaults: defaults, center: center, clock: { instant.addingTimeInterval(2) })
        await center.dismissAll()
        restarted.update(snapshot: data, verified: true); await restarted.flush()
        check(await center.added.count == 2, "Restart after delivery remains deduplicated even if dismissed")
        await center.addUnrelated()
        restarted.update(snapshot: snapshot([credit("soon", expiry: instant.addingTimeInterval(3600), status: "used")], count: 0), verified: true)
        await restarted.flush()
        check(await center.pendingIDs() == ["another.feature"], "Used cards cancel only owned notifications")
        restarted.update(snapshot: snapshot([credit("new")], scope: "account-b"), verified: true); await restarted.flush()
        check(await center.pendingIDs().count == 2, "New account schedules its own card")
        restarted.update(snapshot: nil, verified: false); await restarted.flush()
        check(await center.pendingIDs() == ["another.feature"], "Account invalidation cancels pending cards")
        restarted.update(snapshot: snapshot([credit("new")], scope: "account-b"), verified: true); await restarted.flush()
        await restarted.setEnabled(false); await restarted.flush()
        check(await center.pendingIDs() == ["another.feature"], "Disable clears pending reminders")
        print("PASS: persistent deduplication, restart, card consumption, account changes and disable cleanup")
    }

    @MainActor static func failureAndRace() async {
        let center = TestReminderCenter()
        let (controller, defaults, suite) = setup(center)
        defer { defaults.removePersistentDomain(forName: suite) }
        await center.configure(fail: true)
        controller.update(snapshot: snapshot([credit()]), verified: true)
        await controller.setEnabled(true); await controller.flush()
        controller.update(snapshot: snapshot([credit()]), verified: true); await controller.flush()
        check(await center.pendingIDs().isEmpty, "Failed notification does not reserve a reminder")
        await center.configure()
        controller.update(snapshot: snapshot([credit()]), verified: true); await controller.flush()
        check(await center.pendingIDs().count == 1, "Failed scheduling retries on next validation")
        controller.update(snapshot: nil, verified: false); await controller.flush()
        await center.configure(hold: true)
        controller.update(snapshot: snapshot([credit("race")]), verified: true)
        for _ in 0..<200 {
            if await center.added.count >= 3 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        controller.update(snapshot: nil, verified: false)
        await center.releaseAdd(); await controller.flush()
        check(await center.pendingIDs().isEmpty, "Late add completion cannot reintroduce an old-account reminder")
        print("PASS: notification add failures and stale asynchronous completions")
    }

    @MainActor static func stateIntegration() async {
        let center = TestReminderCenter()
        let suite = "usagebar-reset-integration-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = AppState(defaults: defaults, client: CardFixtureClient(),
                             recovery: RecoveryPolicy(retryDelays: [0.02], mergeDelay: 0.01, wakeDelay: 0.01), reminderCenter: center)
        await state.reminders.setEnabled(true)
        for _ in 0..<400 {
            if state.verified && !state.isRefreshing { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await state.reminders.flush()
        check(state.snapshot?.accountScope == "current", "Enabling validates the account and survives initialization notifications")
        check(await center.pendingIDs().count == 1, "New service validation schedules the reminder")
        state.pause(); await state.reminders.flush()
        check(await center.pendingIDs().isEmpty, "Sleep clears potentially stale pending reminders")
        state.resume()
        for _ in 0..<400 {
            if state.verified && !state.isRefreshing { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        await state.reminders.flush()
        check(await center.pendingIDs().count == 1, "Wake revalidates and reschedules")
        await state.stop()
        check(await center.pendingIDs().count == 1, "Normal quit preserves already scheduled local notifications")
        let secondSuite = "usagebar-secondary-reminders-" + UUID().uuidString
        let secondDefaults = UserDefaults(suiteName: secondSuite)!
        defer { secondDefaults.removePersistentDomain(forName: secondSuite) }
        let second = AppState(defaults: secondDefaults, client: CardFixtureClient(), reminderCenter: MonitoringOnlyReminderCenter(), codexHome: URL(fileURLWithPath: "/fixture/B"))
        let primarySuite = "usagebar-primary-reminders-" + UUID().uuidString
        let primaryDefaults = UserDefaults(suiteName: primarySuite)!
        defer { primaryDefaults.removePersistentDomain(forName: primarySuite) }
        let main = AppState(defaults: primaryDefaults, client: CardFixtureClient(), reminderCenter: center, secondaryFactory: { second })
        main.dualClient.onRestartSucceeded = { _ in main.syncActiveReminders(force: true) }
        main.setSecondAccountEnabled(true)
        main.isRefreshing = true; second.isRefreshing = true
        let now = Date()
        let window = QuotaWindow(usedPercent: 96, windowDurationMins: 300, resetsAt: now.timeIntervalSince1970 + 300)
        let bucket = QuotaBucket(limitId: "codex", limitName: nil, primary: window, secondary: nil, planType: "plus",
                                 spendControlReached: nil, rateLimitReachedType: nil)
        let a = QuotaSnapshot(observedAt: now, accountScope: "A", accountLabel: "A", planType: "plus", buckets: [bucket],
                              resetCredits: .init(availableCount: 1, credits: [credit("primary", expiry: now.addingTimeInterval(172800))]))
        let b = QuotaSnapshot(observedAt: now, accountScope: "B", accountLabel: "B", planType: "plus", buckets: [bucket],
                              resetCredits: .init(availableCount: 1, credits: [credit("secondary", expiry: now.addingTimeInterval(172800))]))
        main.snapshot = a; main.verified = true
        second.snapshot = b; second.verified = true
        main.dualClient.acceptDetectedAccount(false)
        await main.reminders.setEnabled(true)
        await main.lowQuotaReminders.setEnabled(true)
        main.selectedAccountID = "secondary"
        main.syncActiveReminders(force: true); await main.reminders.flush()
        await main.lowQuotaReminders.flush()
        let aAlerts = await center.lowQuotaAdded
        check(aAlerts == LowQuotaReminder.plan(snapshot: a, threshold: 10, now: now),
              "Selecting backup B keeps low-quota alerts on active A")
        let aIDs = await center.pendingIDs()
        check(aIDs.count == 1 && main.reminderAccount === main, "A primary schedules only A")
        main.dualClient.acceptDetectedAccount(true)
        main.syncActiveReminders(force: true); await main.reminders.flush()
        await main.lowQuotaReminders.flush()
        let bAlerts = await center.lowQuotaAdded
        check(bAlerts == aAlerts + LowQuotaReminder.plan(snapshot: b, threshold: 10, now: now),
              "Active-account change routes low-quota alerts to B")
        let bIDs = await center.pendingIDs()
        check(bIDs.count == 1 && bIDs.isDisjoint(with: aIDs) && main.reminderAccount === second, "B primary replaces A reminders with B")
        main.showingSecondAccountDetails = false
        main.syncActiveReminders(force: true); await main.reminders.flush()
        check(await center.pendingIDs() == bIDs, "Viewing backup A must not change B reminders")
        main.dualClient.acceptDetectedAccount(false)
        main.syncActiveReminders(force: true); await main.reminders.flush()
        check(await center.pendingIDs() == aIDs, "Switching back restores A scheduling")
        print("PASS: A/B primary reminder routing, backup-view isolation and obsolete notification cancellation")
        print("PASS: opt-in triggers account validation; initialization, sleep/wake and normal-quit integration")
    }
}
