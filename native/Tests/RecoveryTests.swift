import Foundation
import Darwin

private actor TestQuotaClient: QuotaClient {
    enum Reply: Sendable { case value(QuotaSnapshot), fail(CodexFailure), held }
    private var replies: [Reply]
    private var handler: (@Sendable (CodexSignal) -> Void)?
    private var held: CheckedContinuation<QuotaSnapshot, Error>?
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    private var usageFailure: CodexFailure?
    init(_ replies: [Reply], usageFailure: CodexFailure? = nil) { self.replies = replies; self.usageFailure = usageFailure }
    func setHandler(_ value: @escaping @Sendable (CodexSignal) -> Void) { handler = value }
    func fetch(customPath: String) async throws -> QuotaSnapshot {
        calls += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        guard !replies.isEmpty else { throw CodexFailure.unsupported }
        switch replies.removeFirst() {
        case .value(let snapshot): return snapshot
        case .fail(let failure): throw failure
        case .held: return try await withCheckedThrowingContinuation { held = $0 }
        }
    }
    func fetchUsage(expectedScope: String) throws -> TokenActivity {
        if let usageFailure { throw usageFailure }
        return TokenActivity(summary: nil, dailyUsageBuckets: nil)
    }
    func shutdown() {}
    func emit(_ signal: CodexSignal) { handler?(signal) }
    func append(_ reply: Reply) { replies.append(reply) }
    func release(_ snapshot: QuotaSnapshot) { held?.resume(returning: snapshot); held = nil }
}

@main struct RecoveryTests {
    @MainActor static func main() async throws {
        policyAndClassification()
        try await backoffAndReconnect()
        try await userActionErrors()
        try await networkRecovery()
        try await coalescing()
        try await accountNotification()
        try await sleepAndLateResults()
        try await sleepCancelsRetry()
        try await sourceChange()
        try await presentationAndActivity()
        if CommandLine.arguments.contains("--transport") { try await realTransport() }
        print("PASS: recovery coordinator and update-state regressions")
    }

    static func snapshot(_ scope: String = "fixture", age: TimeInterval = 0, reset: TimeInterval = 3600) -> QuotaSnapshot {
        let window = QuotaWindow(usedPercent: 10, windowDurationMins: 300, resetsAt: Date().addingTimeInterval(reset).timeIntervalSince1970)
        let bucket = QuotaBucket(limitId: "codex", limitName: nil, primary: window, secondary: nil, planType: "plus", spendControlReached: nil, rateLimitReachedType: nil)
        return QuotaSnapshot(observedAt: Date().addingTimeInterval(-age), accountScope: scope, accountLabel: "Fixture account", planType: "plus", buckets: [bucket])
    }
    @MainActor static func makeState(_ client: any QuotaClient, delays: [TimeInterval] = [0.08, 0.16, 0.32]) -> (AppState, UserDefaults, String) {
        let suite = "usagebar-recovery-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        return (AppState(defaults: defaults, client: client, recovery: RecoveryPolicy(retryDelays: delays, mergeDelay: 0.02, wakeDelay: 0.03)), defaults, suite)
    }
    static func require(_ value: Bool, _ message: String) { precondition(value, message) }
    @MainActor static func eventually(_ label: String, timeout: TimeInterval = 3, _ condition: @MainActor () async -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        fatalError("Timed out: " + label)
    }

    static func policyAndClassification() {
        let policy = RecoveryPolicy()
        require((0..<6).map { policy.delay(at: $0) } == [5, 15, 30, 60, 120, 300], "Production backoff schedule")
        require(policy.delay(at: 1000) == 300, "Retry interval must be capped")
        require(CodexClient.classifyRPCError(["code": -32601, "message": "Method not found"]) == .unsupported, "Unsupported RPC")
        require(CodexClient.classifyRPCError(["message": "Unauthorized"]) == .authRequired, "Authentication error")
        require(CodexClient.classifyRPCError(["data": ["statusCode": 401]]) == .authRequired, "Structured authentication error")
        require(CodexClient.classifyRPCError(["message": "error sending request: connection refused"]) == .networkUnavailable, "Network error")
        require(CodexClient.classifyRPCError(["message": "request timed out"]) == .timeout, "Timeout")
        require(CodexClient.classifyRPCError(["message": "Service unavailable"]) == .serviceUnavailable, "Service error")
        require(CodexClient.classifyRPCError(["code": -32602]) == .invalidResponse, "Protocol mismatch")
        print("PASS: error classification and bounded retry policy")
    }

    @MainActor static func backoffAndReconnect() async throws {
        let client = TestQuotaClient([.fail(.networkUnavailable), .fail(.timeout), .value(snapshot())])
        let (state, defaults, suite) = makeState(client)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.refresh(reason: "启动核验")
        try await eventually("first failure") { !state.isRefreshing && state.lastFailure == .networkUnavailable }
        require(state.nextRetryAt != nil && state.statusDetail.contains("下次自动重试"), "Retry must be visible")
        for _ in 0..<100 { state.scheduleRefresh(reason: "客户端额度变化", delay: 0); state.refresh(reason: "定时核验"); state.panelOpened() }
        require(await client.calls == 1, "Events must not bypass backoff")
        try await eventually("second failure") { !state.isRefreshing && state.lastFailure == .timeout }
        require((state.nextRetryAt?.timeIntervalSinceNow ?? 0) > 0.08, "Second retry uses longer delay")
        try await eventually("automatic recovery") { state.verified && !state.isRefreshing }
        require(await client.calls == 3, "Exactly two retry attempts")
        require(state.lastFailure == nil && state.nextRetryAt == nil && state.lastSuccessfulAt != nil, "Success clears retry state")
        let successful = state.lastSuccessfulAt
        await client.append(.value(snapshot()))
        await client.emit(.disconnected(.processStopped))
        try await eventually("idle disconnect") { state.lastFailure == .processStopped }
        require(state.lastSuccessfulAt == successful, "Failure retains last successful time")
        try await eventually("child reconnect") { state.verified && !state.isRefreshing }
        require(await client.calls == 4, "Idle child exit recovers automatically")
        await state.stop()
        print("PASS: automatic retries, event throttling, recovery and idle disconnect")
    }

    @MainActor static func userActionErrors() async throws {
        for failure: CodexFailure in [.authRequired, .unsupported, .missingCLI, .permissionDenied, .invalidResponse] {
            let client = TestQuotaClient([.fail(failure), .value(snapshot())])
            let (state, defaults, suite) = makeState(client)
            state.refresh(reason: "启动核验")
            try await eventually("user-action failure") { !state.isRefreshing && state.lastFailure == failure }
            require(state.nextRetryAt == nil, "User-action errors must stop retries")
            state.scheduleRefresh(reason: "客户端额度变化", delay: 0)
            state.refresh(reason: "定时核验"); state.panelOpened()
            state.networkChanged(available: false); state.networkChanged(available: true)
            try await Task.sleep(for: .milliseconds(35))
            require(await client.calls == 1, "Automatic triggers cannot retry user-action failures")
            state.refresh()
            try await eventually("explicit retry") { state.verified && !state.isRefreshing }
            require(await client.calls == 2, "Manual retry is allowed")
            await state.stop(); defaults.removePersistentDomain(forName: suite)
        }
        print("PASS: login/version/configuration failures stop automatic retries and allow explicit retry")
    }

    @MainActor static func networkRecovery() async throws {
        let client = TestQuotaClient([.fail(.networkUnavailable), .value(snapshot())])
        let (state, defaults, suite) = makeState(client, delays: [10])
        defer { defaults.removePersistentDomain(forName: suite) }
        state.refresh()
        try await eventually("offline failure") { !state.isRefreshing && state.nextRetryAt != nil }
        state.networkChanged(available: false); state.networkChanged(available: true); state.networkChanged(available: true)
        try await eventually("online recovery") { state.verified && !state.isRefreshing }
        try await Task.sleep(for: .milliseconds(40))
        require(await client.calls == 2, "Network recovery coalesces and bypasses the old delay once")
        await state.stop()
        print("PASS: a network return expedites one retry")
    }

    @MainActor static func coalescing() async throws {
        let client = TestQuotaClient([.held, .value(snapshot())])
        let (state, defaults, suite) = makeState(client)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.refresh()
        try await eventually("held query") { await client.calls == 1 }
        for _ in 0..<100 { state.refresh(reason: "客户端额度变化") }
        require(await client.calls == 1, "Only one query in flight")
        await client.release(snapshot())
        try await eventually("coalesced followup") { let count = await client.calls; return count == 2 && !state.isRefreshing }
        require(await client.maximumActive == 1, "Queries cannot overlap")
        await state.stop()
        print("PASS: 100 simultaneous triggers produce one coalesced followup without overlapping requests")
    }

    @MainActor static func sleepAndLateResults() async throws {
        let client = TestQuotaClient([.held, .value(snapshot("new"))])
        let (state, defaults, suite) = makeState(client)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.refresh()
        try await eventually("sleep query held") { await client.calls == 1 }
        state.pause(); state.pause()
        require(state.updateStatus == .sleeping && !state.isRefreshing && state.nextRetryAt == nil, "Sleep cancels query ownership and retries")
        state.networkChanged(available: false); state.networkChanged(available: true)
        state.resume(); state.resume()
        try await eventually("wake recovery") { !state.isRefreshing && state.snapshot?.accountScope == "new" }
        await client.release(snapshot("old"))
        try await Task.sleep(for: .milliseconds(50))
        require(state.snapshot?.accountScope == "new" && state.verified, "Pre-sleep results cannot overwrite wake data")
        require(await client.calls == 2, "Duplicate wake signals must not duplicate queries")
        await state.stop()
        print("PASS: sleep/wake cancellation, duplicate wake coalescing and stale-result rejection")
    }

    @MainActor static func accountNotification() async throws {
        let client = TestQuotaClient([.held, .value(snapshot("new-account"))])
        let (state, defaults, suite) = makeState(client)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.refresh()
        try await eventually("initial account query") { await client.calls == 1 }
        await client.emit(.accountChanged)
        try await eventually("account change queued") { state.snapshot == nil }
        // Give the signal a main-actor turn before releasing the old response.
        try await Task.sleep(for: .milliseconds(10))
        require(state.isRefreshing, "An account notification must not tear down initialization")
        await client.release(snapshot("old-account"))
        try await eventually("account revalidation") { state.verified && !state.isRefreshing }
        require(state.snapshot?.accountScope == "new-account", "Account notifications invalidate older results")
        require(await client.calls == 2, "Account changes coalesce into one same-connection revalidation")
        require(await client.maximumActive == 1, "Account revalidation cannot overlap the old request")
        await state.stop()
        print("PASS: initialization account notifications preserve the connection and reject old account results")
    }

    @MainActor static func sourceChange() async throws {
        let client = TestQuotaClient([.held, .value(snapshot("new-source"))])
        let (state, defaults, suite) = makeState(client)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.refresh()
        try await eventually("old source held") { await client.calls == 1 }
        state.preferences.cliPath = "/fixture/new-codex"
        try await eventually("new source verified") { !state.isRefreshing && state.snapshot?.accountScope == "new-source" }
        await client.release(snapshot("old-source"))
        try await Task.sleep(for: .milliseconds(40))
        require(state.snapshot?.accountScope == "new-source", "Old CLI result cannot replace a new source")
        await state.stop()
        print("PASS: connection configuration changes reject old results")
    }

    @MainActor static func sleepCancelsRetry() async throws {
        let client = TestQuotaClient([.fail(.networkUnavailable), .value(snapshot())])
        let (state, defaults, suite) = makeState(client)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.refresh()
        try await eventually("retry before sleep") { !state.isRefreshing && state.nextRetryAt != nil }
        state.pause()
        try await Task.sleep(for: .milliseconds(150))
        require(await client.calls == 1, "Retry cannot run while sleeping")
        require(state.nextRetryAt == nil, "Retry date is cleared during sleep")
        state.resume()
        try await eventually("wake after cancelled retry") { state.verified && !state.isRefreshing }
        require(await client.calls == 2, "Wake resumes one query")
        await state.stop()
        print("PASS: sleep cancels a pending retry and wake resumes one query")
    }

    @MainActor static func presentationAndActivity() async throws {
        let client = TestQuotaClient([.value(snapshot())], usageFailure: .unsupported)
        let (state, defaults, suite) = makeState(client)
        defer { defaults.removePersistentDomain(forName: suite) }
        state.snapshot = snapshot(age: 600)
        require(state.updateStatus == .waiting && state.timestampLabel.contains("本次尚未核验"), "Cache is not a successful validation")
        state.verified = true
        require(state.updateStatus == .stale, "Old verified data has an explicit stale state")
        state.snapshot = snapshot(reset: -1)
        require(state.updateStatus == .resetPending && state.menuTitle.contains("--"), "Reset cannot invent full allowance")
        state.refresh()
        try await eventually("quota succeeds without usage support") { !state.isRefreshing && state.verified }
        require(state.updateStatus == .verified && state.activityError != nil && state.nextRetryAt == nil, "Unsupported activity cannot break quota or trigger retries")
        await state.stop()
        let calls = await client.calls
        state.refresh(); state.scheduleRefresh(reason: "late event", delay: 0)
        try await Task.sleep(for: .milliseconds(100))
        require(await client.calls == calls, "Stopped application cannot restart requests")
        print("PASS: cache/stale/reset/success presentation, independent activity errors and stop cleanup")
    }

    @MainActor static func realTransport() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usagebar-transport-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("fixture-codex")
        let mode = root.appendingPathComponent("mode")
        let pidFile = root.appendingPathComponent("pid")
        let source = #"""
#!/usr/bin/env python3
import os, sys, json, pathlib, time
root = pathlib.Path(__file__).parent
(root / 'pid').write_text(str(os.getpid()))
for line in sys.stdin:
    m = json.loads(line)
    if 'id' not in m: continue
    method = m['method']
    mode = (root / 'mode').read_text()
    if method == 'account/rateLimits/read' and mode == 'hold':
        (root / 'holding').write_text('yes')
        time.sleep(30)
    if method == 'account/rateLimits/read' and mode != 'ok':
        error = {'code': -32601, 'message': 'Method not found'} if mode == 'unsupported' else {'code': -32000, 'message': 'error sending request: network unreachable'}
        print(json.dumps({'id': m['id'], 'error': error}), flush=True)
        continue
    if method == 'initialize':
        print(json.dumps({'method': 'account/updated', 'params': {'planType': 'plus'}}), flush=True)
        result = {'userAgent': 'fixture'}
    elif method == 'account/read': result = {'account': {'type': 'chatgpt', 'id': 'fixture', 'planType': 'plus'}}
    elif method == 'account/rateLimits/read': result = {'rateLimits': {'limitId': 'codex', 'primary': {'usedPercent': 10, 'windowDurationMins': 300, 'resetsAt': time.time()+3600}}}
    else: result = {'summary': None, 'dailyUsageBuckets': None}
    print(json.dumps({'id': m['id'], 'result': result}), flush=True)
"""#
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try "network".write(to: mode, atomically: true, encoding: .utf8)
        let (state, defaults, suite) = makeState(CodexClient(requestTimeout: 0.6), delays: [0.25, 0.5])
        defer { defaults.removePersistentDomain(forName: suite) }
        state.preferences.cliPath = script.path
        try await eventually("real RPC network failure", timeout: 5) { state.lastFailure == .networkUnavailable && !state.isRefreshing }
        try "ok".write(to: mode, atomically: true, encoding: .utf8)
        try await eventually("real RPC recovery", timeout: 5) { state.verified && !state.isRefreshing }
        let oldPID = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        require(Darwin.kill(oldPID, SIGTERM) == 0, "Terminate only the fixture child")
        try await eventually("real child replacement", timeout: 5) {
            let pid = try? String(contentsOf: pidFile, encoding: .utf8)
            return state.verified && !state.isRefreshing && pid != String(oldPID)
        }
        let holding = root.appendingPathComponent("holding")
        try "hold".write(to: mode, atomically: true, encoding: .utf8)
        state.refresh()
        try await eventually("real query held") { FileManager.default.fileExists(atPath: holding.path) }
        try await eventually("real request timeout", timeout: 5) { !state.isRefreshing && state.lastFailure == .timeout }
        try "ok".write(to: mode, atomically: true, encoding: .utf8)
        try await eventually("real timeout recovery", timeout: 5) { state.verified && !state.isRefreshing }
        try FileManager.default.removeItem(at: holding)
        try "hold".write(to: mode, atomically: true, encoding: .utf8)
        state.refresh()
        try await eventually("real pre-sleep query held") { FileManager.default.fileExists(atPath: holding.path) }
        state.pause()
        try "ok".write(to: mode, atomically: true, encoding: .utf8)
        state.resume(); state.resume()
        try await eventually("real wake during request", timeout: 5) { state.verified && !state.isRefreshing }
        try "unsupported".write(to: mode, atomically: true, encoding: .utf8)
        state.refresh()
        try await eventually("real unsupported RPC") { state.lastFailure == .unsupported && !state.isRefreshing }
        require(state.nextRetryAt == nil, "Real unsupported method stops retries")
        await state.stop()
        let newPID = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        require(Darwin.kill(newPID, 0) != 0, "Stopping closes the owned fixture process")
        print("PASS: real stdio network recovery, child relaunch, timeout recovery, in-flight sleep/wake, unsupported methods and cleanup")
    }
}
