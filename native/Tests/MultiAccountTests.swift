import Foundation

private actor ProfileClient: QuotaClient {
    let id: String
    private var handler: (@Sendable (CodexSignal) -> Void)?
    private(set) var shutdowns = 0
    private(set) var logouts = 0
    var failLogout = false
    var delayLogoutCleanup = false
    var successfulLogout = false
    private(set) var logoutCleanupFinished = false
    init(_ id: String) { self.id = id }
    func setHandler(_ value: @escaping @Sendable (CodexSignal) -> Void) { handler = value }
    func fetch(customPath: String) -> QuotaSnapshot {
        QuotaSnapshot(observedAt: Date(), accountScope: id, accountLabel: "Fixture " + id, planType: "plus",
            buckets: [QuotaBucket(limitId: "codex", limitName: nil,
                primary: QuotaWindow(usedPercent: id == "A" ? 10 : 80, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(3000).timeIntervalSince1970),
                secondary: nil, planType: "plus", spendControlReached: nil, rateLimitReachedType: nil)])
    }
    func fetchUsage(expectedScope: String) throws -> TokenActivity {
        guard expectedScope == id else { throw CodexFailure.accountChanged }
        return TokenActivity(summary: nil, dailyUsageBuckets: nil)
    }
    func beginLogin(customPath: String) -> URL { URL(string: "https://auth.openai.com/authorize?fixture=1")! }
    func complete(_ success: Bool) { handler?(.loginCompleted(success)) }
    func logout(customPath: String) throws {
        logouts += 1
        if failLogout { throw CodexFailure.serviceUnavailable }
        successfulLogout = true
    }
    func setLogoutFailure(_ value: Bool) { failLogout = value }
    func setDelayedLogoutCleanup() { delayLogoutCleanup = true }
    func shutdown() async {
        shutdowns += 1
        if delayLogoutCleanup && successfulLogout {
            try? await Task.sleep(for: .seconds(1))
            logoutCleanupFinished = true
        }
    }
}

@main struct MultiAccountTests {
    @MainActor static func wait(_ label: String, _ condition: @MainActor () async -> Bool) async throws {
        let end = Date().addingTimeInterval(5)
        while Date() < end {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Timed out: " + label)
    }
    @MainActor static func main() async throws {
        let normal = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        precondition(CodexClient.primaryHome(environment: [:]) == normal)
        precondition(CodexClient.primaryHome(environment: ["CODEX_HOME": AppState.secondAccountHome.path]) == normal, "B desktop environment must not replace primary identity")
        precondition(CodexClient.primaryHome(environment: ["CODEX_HOME": "/fixture/custom"]).path == "/fixture/custom", "Explicit custom primary homes remain supported")
        let fixture = "10 1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT\n11 10 /Applications/ChatGPT.app/codex app-server -c sqlite_home=/fixture -c cli_auth_credentials_store=file\n22 1 /Applications/ChatGPT.app/codex app-server"
        precondition(DualClientController.detectSecondary(processList: fixture, desktopPIDs: [10]) == true)
        precondition(DualClientController.detectSecondary(processList: fixture, desktopPIDs: [22]) == false)
        precondition(DualClientController.detectSecondary(processList: fixture, desktopPIDs: [10,22]) == nil)
        precondition(DualClientController.matchAccount(scope: "B", primary: "A", secondary: "B") == true)
        precondition(DualClientController.matchAccount(scope: "A", primary: "A", secondary: "B") == false)
        precondition(DualClientController.matchAccount(scope: "new-login", primary: "A", secondary: "B") == nil)
        precondition(DualClientController.matchAccount(scope: "A", primary: "A", secondary: "A") == nil)
        precondition(DualClientController.matchAccount(scope: nil, primary: "A", secondary: "B") == nil)
        precondition(DualClientController.detectSecondary(processList: fixture + "\n33 11 /fixture/codex app-server", desktopPIDs: [10]) == true, "Nested tool probes must not override the desktop login")
        try await deletionConfirmation()
        try await logoutIsolation()
        try await multipleProfiles()
        try await coordinator()
        try await transport()
        print("PASS: independent profiles, login lifecycle, environment and process isolation")
    }
    @MainActor static func deletionConfirmation() async throws {
        let suite = "usagebar-delete-" + UUID().uuidString
        let secondSuite = suite + "-second"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); UserDefaults(suiteName: secondSuite)?.removePersistentDomain(forName: secondSuite) }
        let client = ProfileClient("B")
        let second = AppState(defaults: UserDefaults(suiteName: secondSuite)!, client: client, reminderCenter: MonitoringOnlyReminderCenter(), codexHome: URL(fileURLWithPath: "/fixture/B"))
        let first = AppState(defaults: defaults, client: ProfileClient("A"), reminderCenter: MonitoringOnlyReminderCenter(), secondaryFactory: { second })
        first.setSecondAccountEnabled(true)
        first.refresh(); second.refresh()
        try await wait("deletion profiles ready") { first.verified && second.verified }
        precondition(first.showsTokenActivity, "Two signed-in accounts show activity")
        precondition(!first.expandsCreditDetailsByDefault)
        first.applyCreditDetailsDefault(expanded: first.expandsCreditDetailsByDefault)
        precondition(!first.resetCreditsExpanded)
        first.resetCreditsExpanded = true
        first.applyCreditDetailsDefault(expanded: false)
        precondition(first.resetCreditsExpanded, "Same policy must preserve manual expansion")
        first.applyCreditDetailsDefault(expanded: true)
        first.resetCreditsExpanded = false
        first.applyCreditDetailsDefault(expanded: true)
        precondition(!first.resetCreditsExpanded, "Same policy must preserve manual collapse")
        first.applyCreditDetailsDefault(expanded: false)
        precondition(!first.resetCreditsExpanded, "Dropping to two accounts applies collapsed default")
        precondition(first.dualClient.confirmProfile(scope: "A"))
        first.requestAccountDeletion("primary")
        precondition(first.pendingAccountDeletion == nil, "Active account must not be deletable")
        first.requestAccountDeletion("secondary")
        precondition(first.pendingAccountDeletion == "secondary" && first.secondAccount != nil)
        let before = await client.logouts
        precondition(before == 0, "Requesting confirmation must have no logout side effect")
        first.cancelAccountDeletion()
        first.confirmAccountDeletion()
        precondition(first.secondAccount != nil && first.deletingAccountID == nil)
        await client.setLogoutFailure(true)
        first.requestAccountDeletion("secondary"); first.confirmAccountDeletion()
        try await wait("failed delete settled") { first.deletingAccountID == nil }
        precondition(first.secondAccount === second && first.accountManagementMessage != nil)
        await client.setLogoutFailure(false)
        await client.setDelayedLogoutCleanup()
        first.requestAccountDeletion("secondary"); first.confirmAccountDeletion()
        precondition(first.deletingAccountID == "secondary", "Deletion progress must publish immediately")
        try await wait("confirmed deletion settled") { first.deletingAccountID == nil && first.secondAccount == nil }
        let cleanupFinished = await client.logoutCleanupFinished
        precondition(!cleanupFinished, "Card removal must not wait for slow background process cleanup")
        precondition(!defaults.bool(forKey: "second-account.enabled.v1"))
        precondition(first.verified && first.snapshot?.accountScope == "A")
        precondition(first.accountEntries.count == 1)
        precondition(first.showsTokenActivity, "One signed-in account shows activity")
        precondition(!first.expandsCreditDetailsByDefault)
        first.addAccount(startLogin: false)
        precondition(first.accountEntries.count == 2)
        await first.stop()
        print("PASS: deletion confirmation gate, cancel no-op, active-account protection, failure retention, registry update and re-add")
    }
    @MainActor static func logoutIsolation() async throws {
        let suiteA = "usagebar-logout-a-" + UUID().uuidString
        let suiteB = "usagebar-logout-b-" + UUID().uuidString
        let a = UserDefaults(suiteName: suiteA)!, b = UserDefaults(suiteName: suiteB)!
        defer { a.removePersistentDomain(forName: suiteA); b.removePersistentDomain(forName: suiteB) }
        let clientA = ProfileClient("A"), clientB = ProfileClient("B")
        let second = AppState(defaults: b, client: clientB, reminderCenter: MonitoringOnlyReminderCenter(), codexHome: URL(fileURLWithPath: "/fixture/B"))
        let first = AppState(defaults: a, client: clientA, reminderCenter: MonitoringOnlyReminderCenter(), secondaryFactory: { second })
        first.setSecondAccountEnabled(true)
        first.refresh(); second.refresh()
        try await wait("logout fixtures verified") { first.verified && second.verified }
        precondition(first.dualClient.confirmProfile(scope: "B"))
        await clientB.setLogoutFailure(true)
        second.signOut()
        try await wait("failed logout settled") { !second.isSigningOut }
        precondition(second.verified && second.snapshot?.accountScope == "B", "Failed logout must not pretend the login was cleared")
        await clientB.setLogoutFailure(false)
        second.signOut(); second.signOut()
        try await wait("logout settled") { !second.isSigningOut }
        precondition(second.snapshot == nil && !second.verified && second.tokenActivity == nil)
        precondition(b.data(forKey: "quota-cache.v1") == nil)
        precondition(first.verified && first.snapshot?.accountScope == "A", "Other account must remain logged in")
        precondition(!first.dualClient.detected && first.reminderAccount == nil)
        let logouts = await clientB.logouts
        precondition(logouts == 2, "Duplicate clicks must produce only one logout")
        first.signOut()
        try await wait("primary logout settled") { !first.isSigningOut }
        precondition(first.snapshot == nil && !first.verified)
        await first.stop()
        print("PASS: scoped logout, failure preservation, duplicate-click prevention, cache cleanup and active-role invalidation")
    }
    @MainActor static func multipleProfiles() async throws {
        let suite = "usagebar-many-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let second = AppState(defaults: defaults, client: ProfileClient("B"), reminderCenter: MonitoringOnlyReminderCenter(), codexHome: URL(fileURLWithPath: "/fixture/B"))
        let state = AppState(defaults: defaults, client: ProfileClient("A"), secondaryFactory: { second })
        state.addAccount(startLogin: false)
        state.addAccount(startLogin: false)
        state.addAccount(startLogin: false)
        precondition(state.accountEntries.count == 4)
        precondition(state.homeAccounts.isEmpty, "Added but unsigned accounts must not appear on home")
        precondition(!state.showsTokenActivity)
        precondition(Set(state.accountEntries.map { $0.id }).count == 4)
        precondition(defaults.stringArray(forKey: "additional-account-ids.v1") == state.additionalAccountIDs)
        for (index, entry) in state.accountEntries.enumerated() {
            entry.state.snapshot = QuotaSnapshot(observedAt: Date(), accountScope: "user-\(index)", accountLabel: "User \(index)", planType: "plus", buckets: [])
            entry.state.verified = true
        }
        precondition(state.showsTokenActivity, "All signed-in account counts retain activity")
        precondition(!state.expandsCreditDetailsByDefault)
        state.applyCreditDetailsDefault(expanded: state.expandsCreditDetailsByDefault)
        precondition(!state.resetCreditsExpanded)
        state.resetCreditsExpanded = true
        state.applyCreditDetailsDefault(expanded: false)
        precondition(state.resetCreditsExpanded, "Account count changes preserve manual expansion")
        let third = state.accountEntries[2]
        precondition(state.dualClient.confirmProfile(scope: "user-2"))
        precondition(state.orderedAccounts.first?.id == third.id)
        precondition(state.accountRole(third.id) == "主账号")
        precondition(state.accountRole("primary") == "备用账号 1")
        precondition(state.accountRole("secondary") == "备用账号 2")
        precondition(state.displayedAccount === third.state)
        precondition(state.reminderAccount === third.state)
        precondition(state.dualClient.confirmProfile(scope: "user-0"))
        precondition(state.accountRole("primary") == "主账号")
        precondition(state.accountRole("secondary") == "备用账号 1")
        precondition(state.accountRole(third.id) == "备用账号 2")
        precondition(!state.dualClient.confirmProfile(scope: "unknown"))
        let pending = state.accountEntries[3]
        let savedPendingSnapshot = pending.state.snapshot
        pending.state.snapshot = nil
        precondition(state.homeAccounts.count == 3 && state.accountEntries.count == 4)
        precondition(state.accountRole(pending.id) == "待登录账号")
        state.selectedAccountID = pending.id
        precondition(state.displayedAccount !== pending.state, "Hidden unsigned account must not leave empty home details")
        pending.state.snapshot = savedPendingSnapshot
        precondition(state.homeAccounts.count == 4, "Successful login restores home card")

        let secondEntry = state.accountEntries[1]
        secondEntry.state.snapshot = QuotaSnapshot(observedAt: Date(), accountScope: "user-1", accountLabel: "Free user", planType: "free", buckets: [])
        precondition(state.orderedAccounts.first?.id == "primary", "Current user remains first")
        precondition(state.orderedBackupAccounts.map { $0.id } == [third.id, state.accountEntries[3].id, "secondary"], "Plus accounts first, stable insertion order within tier")
        precondition(state.accountRole(third.id) == "备用账号 1")
        precondition(state.accountRole("secondary") == "备用账号 3")
        precondition(secondEntry.state.isFreeAccount && !secondEntry.state.isPlusAccount)
        precondition(state.dualClient.confirmProfile(scope: "user-1"))
        precondition(state.orderedAccounts.first?.id == "secondary", "Free current user stays primary ahead of Plus backups")

        // Duplicate login identities are valid when profiles have distinct auth homes.
        let duplicate = state.accountEntries[3]
        let originalDuplicate = duplicate.state.snapshot
        duplicate.state.snapshot = secondEntry.state.snapshot
        precondition(!state.dualClient.confirmProfile(scope: "user-1"), "No hint must leave duplicate identities ambiguous")
        precondition(!state.dualClient.confirmProfile(scope: "user-1", preferredProfileID: "primary"), "Unrelated home cannot override identity verification")
        precondition(state.dualClient.confirmProfile(scope: "user-1", preferredProfileID: duplicate.id), "Verified desktop home disambiguates duplicated login")
        precondition(state.dualClient.activeProfileID == duplicate.id)
        duplicate.state.snapshot = originalDuplicate

        let fixture = "10 1 /Applications/ChatGPT.app/Contents/MacOS/ChatGPT\n11 10 /fixture/codex -c usagebar_account_id=\"" + third.id + "\" -c sqlite_home=/fixture -c cli_auth_credentials_store=file app-server\n12 11 /fixture/codex app-server"
        precondition(DualClientController.detectProfile(processList: fixture, desktopPIDs: [10]) == third.id)
        await state.stop()
        for id in state.additionalAccountIDs { UserDefaults(suiteName: "com.guoyuming.UsageBar.account." + id)?.removePersistentDomain(forName: "com.guoyuming.UsageBar.account." + id) }
        print("PASS: four accounts, stable IDs, persisted registry, dynamic roles, reminders and nested backend detection")
    }
    @MainActor static func coordinator() async throws {
        let suiteA = "usagebar-profiles-a-" + UUID().uuidString
        let suiteB = "usagebar-profiles-b-" + UUID().uuidString
        let a = UserDefaults(suiteName: suiteA)!, b = UserDefaults(suiteName: suiteB)!
        defer { a.removePersistentDomain(forName: suiteA); b.removePersistentDomain(forName: suiteB) }
        let clientA = ProfileClient("A"), clientB = ProfileClient("B")
        var opened = 0
        let second = AppState(defaults: b, client: clientB, reminderCenter: MonitoringOnlyReminderCenter(),
            codexHome: URL(fileURLWithPath: "/fixture/B"), loginOpener: { _ in opened += 1; return true })
        let first = AppState(defaults: a, client: clientA, secondaryFactory: { second })
        first.setSecondAccountEnabled(true)
        precondition(first.secondAccount === second && a.bool(forKey: "second-account.enabled.v1"))
        first.preferences.isStacked = true
        precondition(second.preferences.isStacked, "Display preferences propagate")
        first.refresh(reason: "启动核验"); second.refresh(reason: "启动核验")
        try await wait("both profiles verified") { first.verified && second.verified && !first.isRefreshing && !second.isRefreshing }
        precondition(first.snapshot?.accountScope == "A" && second.snapshot?.accountScope == "B")
        var displayChanges = 0
        first.onDisplayChange = { displayChanges += 1 }
        precondition(first.displayedAccount === first)
        first.showingSecondAccountDetails = true
        precondition(first.displayedAccount === second && displayChanges == 1, "Selecting B updates panel details")
        precondition(first.displayedAccount.menuTitle.contains("20%"), "Selected B details use B quota")
        first.showingSecondAccountDetails = false
        precondition(first.displayedAccount === first && displayChanges == 2)
        precondition(first.displayedAccount.menuTitle.contains("90%"), "Selected A details use A quota")
        first.setPanelVisible(true)
        first.selectedAccountID = "secondary"
        precondition(first.displayedAccount === second, "Open panel can browse a backup")
        precondition(first.menuBarAccount === first, "Menu bar stays on active A while browsing B")
        first.accountPickerPresented = true
        first.pendingSwitchConfirmation = "secondary"
        first.setPanelVisible(false)
        precondition(first.displayedAccount === first && first.selectedAccountID == "primary", "Closing restores active A")
        precondition(!first.accountPickerPresented && first.pendingSwitchConfirmation == nil, "Closing clears transient account UI")
        precondition(first.dualClient.confirmProfile(scope: "B"), "Fixture can verify B as actual active account")
        first.setPanelVisible(true)
        first.selectedAccountID = "primary"
        precondition(first.displayedAccount === first && first.menuBarAccount === second, "Browsing A never changes active B menu bar")
        first.setPanelVisible(false)
        precondition(first.displayedAccount === second && first.selectedAccountID == "secondary", "Closing restores active B instead of assuming primary")
        first.setPanelVisible(true)
        precondition(first.displayedAccount === second, "Reopening starts with active B")
        first.setPanelVisible(false)
        precondition(first.dualClient.confirmProfile(scope: "A"))
        // Restore the original uncertain-state fixture for the remaining restart tests.
        first.dualClient.restartSucceeded(secondary: false, label: "Fixture A")
        first.selectedAccountID = nil
        precondition(first.dualClient.roleLabel(secondary: false) == "登录待确认")
        precondition(first.dualClient.orderedSecondary == [false, true])
        first.dualClient.selectedSecondary = true
        precondition(first.dualClient.orderedSecondary == [false, true], "Draft selection must not reorder accounts")
        precondition(first.displayedAccount === first, "Execution draft must not change viewing account")
        first.dualClient.restartSucceeded(secondary: true, label: "Fixture B")
        precondition(first.displayedAccount === second && first.dualClient.selectedSecondary, "Successful B restart synchronizes menu and details")
        precondition(first.dualClient.roleLabel(secondary: true) == "登录待确认", "Launch alone cannot prove the active backend")
        precondition(first.dualClient.orderedSecondary == [true, false], "Successful B restart puts B first")
        first.showingSecondAccountDetails = false
        precondition(first.dualClient.orderedSecondary == [true, false], "Viewing A must not reorder execution accounts")
        precondition(DualClientController(defaults: a).selectedSecondary, "Successful execution selection survives tool restart")
        first.dualClient.restartSucceeded(secondary: false, label: "Fixture A")
        precondition(first.displayedAccount === first && !DualClientController(defaults: a).selectedSecondary, "Successful A restart synchronizes and persists")
        precondition(a.data(forKey: "quota-cache.v1") != b.data(forKey: "quota-cache.v1"), "Profile caches must differ")
        first.setPanelVisible(true)
        precondition(second.panelVisible && second.quotaPollInterval == 15)
        second.signInSecondAccount()
        try await wait("browser flow started") { opened == 1 }
        precondition(second.isSigningIn && first.verified && second.snapshot == nil)
        second.refresh() // Must not tear down an in-progress login.
        precondition(second.isSigningIn)
        await clientB.complete(true)
        try await wait("login completion validated") { second.verified && !second.isSigningIn && !second.isRefreshing }
        second.signInSecondAccount()
        try await wait("second login opened") { opened == 2 }
        await clientB.complete(false)
        try await wait("login failure") { !second.isSigningIn && second.lastFailure == .authRequired }
        precondition(first.verified && first.snapshot?.accountScope == "A")
        second.signInSecondAccount()
        try await wait("cancel test opened") { opened == 3 }
        second.cancelSignIn()
        precondition(!second.isSigningIn)
        await clientB.complete(true)
        try await Task.sleep(for: .milliseconds(20))
        precondition(second.lastFailure == .authRequired, "Late completion after cancel cannot restore a session")
        first.pause()
        precondition(first.paused && second.paused)
        first.setSecondAccountEnabled(false)
        try await wait("disabled child stopped") { await clientB.shutdowns > 0 }
        precondition(first.secondAccount == nil && !a.bool(forKey: "second-account.enabled.v1"))
        precondition(first.displayedAccount === first && !first.showingSecondAccountDetails, "Disabling B restores A as the menu source")
        await first.stop()
    }

    static func transport() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("usagebar-two-profiles-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let script = root.appendingPathComponent("fixture-codex")
        let source = #"""
#!/usr/bin/env python3
import os,sys,json,pathlib,time
home=pathlib.Path(os.environ['CODEX_HOME'])
assert not any(os.environ.get(k) for k in ['OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN'])
isolated='cli_auth_credentials_store="file"' in sys.argv
if isolated:
 assert home.name in ['A','B']
 (home/'pid').write_text(str(os.getpid()))
for line in sys.stdin:
 m=json.loads(line)
 if 'id' not in m:continue
 method=m['method']
 if method=='initialize':r={}
 elif method=='account/read':r={'account':{'type':'chatgpt','id':home.name,'planType':'plus'}}
 elif method=='account/rateLimits/read':r={'rateLimits':{'limitId':'codex','primary':{'usedPercent':10 if home.name=='A' else 80,'windowDurationMins':300,'resetsAt':time.time()+3600}}}
 elif method=='account/logout':
  if isolated:(home/'logged-out').write_text('yes')
  r={}
 elif method=='account/login/start':r={'type':'chatgpt','loginId':'fixture','authUrl':'https://auth.openai.com/authorize?fixture=1'}
 else:r={'summary':None,'dailyUsageBuckets':None}
 print(json.dumps({'id':m['id'],'result':r}),flush=True)
"""#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let clientA = CodexClient(codexHome: root.appendingPathComponent("A"))
        let clientB = CodexClient(codexHome: root.appendingPathComponent("B"))
        async let a = clientA.fetch(customPath: script.path)
        async let b = clientB.fetch(customPath: script.path)
        let (one, two) = try await (a, b)
        precondition(one.accountScope != two.accountScope)
        precondition(one.buckets.first?.primary?.remaining == 90 && two.buckets.first?.primary?.remaining == 20)
        let url = try await clientB.beginLogin(customPath: script.path)
        precondition(CodexClient.isOfficialLoginURL(url))
        for raw in ["http://auth.openai.com/", "https://auth.openai.com.example.org/", "https://user@chatgpt.com/", "file:///tmp/login"] {
            precondition(!CodexClient.isOfficialLoginURL(URL(string: raw)!))
        }
        await clientA.shutdown()
        let stillActive = try await clientB.fetch(customPath: script.path)
        precondition(stillActive.accountScope == two.accountScope, "Shutting down A cannot stop B")
        try await clientB.logout(customPath: script.path)
        precondition(fm.fileExists(atPath: root.appendingPathComponent("B/logged-out").path))
        precondition(!fm.fileExists(atPath: root.appendingPathComponent("A/logged-out").path))
        let primary = CodexClient()
        let primaryURL = try await primary.beginLogin(customPath: script.path)
        precondition(CodexClient.isOfficialLoginURL(primaryURL))
        await primary.shutdown()
    }
}
