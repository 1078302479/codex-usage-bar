import Foundation

private actor ProfileClient: QuotaClient {
    let id: String
    private var handler: (@Sendable (CodexSignal) -> Void)?
    private(set) var shutdowns = 0
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
    func shutdown() { shutdowns += 1 }
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
        try await coordinator()
        try await transport()
        print("PASS: independent profiles, login lifecycle, environment and process isolation")
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
        precondition(first.displayedAccount === second && displayChanges == 1, "Selecting B immediately updates the menu source")
        precondition(first.displayedAccount.menuTitle.contains("20%"), "Selected B menu uses B quota")
        first.showingSecondAccountDetails = false
        precondition(first.displayedAccount === first && displayChanges == 2)
        precondition(first.displayedAccount.menuTitle.contains("90%"), "Selected A menu uses A quota")
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
assert 'cli_auth_credentials_store="file"' in sys.argv
assert home.name in ['A','B']
(home/'pid').write_text(str(os.getpid()))
for line in sys.stdin:
 m=json.loads(line)
 if 'id' not in m:continue
 method=m['method']
 if method=='initialize':r={}
 elif method=='account/read':r={'account':{'type':'chatgpt','id':home.name,'planType':'plus'}}
 elif method=='account/rateLimits/read':r={'rateLimits':{'limitId':'codex','primary':{'usedPercent':10 if home.name=='A' else 80,'windowDurationMins':300,'resetsAt':time.time()+3600}}}
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
        await clientB.shutdown()
        let primary = CodexClient()
        do { _ = try await primary.beginLogin(customPath: script.path); fatalError("Primary login must be protected") }
        catch { precondition(error as? CodexFailure == .unsupported) }
    }
}
