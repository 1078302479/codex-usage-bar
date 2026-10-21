import Foundation
import Darwin

private final class OwnedProcess: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

enum CodexSignal: Sendable { case quotaChanged, accountChanged, disconnected(CodexFailure) }

protocol QuotaClient: Sendable {
    func setHandler(_ value: @escaping @Sendable (CodexSignal) -> Void) async
    func fetch(customPath: String) async throws -> QuotaSnapshot
    func fetchUsage(expectedScope: String) async throws -> TokenActivity
    func shutdown() async
}

actor CodexClient: QuotaClient {
    private let requestTimeout: TimeInterval
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errors: FileHandle?
    private var buffer = Data()
    private var errorTail = Data()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var counter = 0
    private var generation = UUID()
    private var ready = false
    private var path = ""
    private var handler: (@Sendable (CodexSignal) -> Void)?
    private var lastBuckets: [String: Data] = [:]
    private var deferredUpdates: [Data] = []
    private var readingQuota = false

    init(requestTimeout: TimeInterval = 12) {
        precondition(requestTimeout > 0 && requestTimeout.isFinite)
        self.requestTimeout = requestTimeout
    }

    func setHandler(_ value: @escaping @Sendable (CodexSignal) -> Void) { handler = value }

    static func discover(custom: String) throws -> String {
        let fm = FileManager.default
        if !custom.isEmpty {
            guard fm.isExecutableFile(atPath: custom) else { throw CodexFailure.missingCLI }
            return custom
        }
        let known = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                     "/Applications/Codex.app/Contents/Resources/codex",
                     "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"]
        let paths = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        guard let found = (paths + known).first(where: { fm.isExecutableFile(atPath: $0) }) else { throw CodexFailure.missingCLI }
        return found
    }

    func fetch(customPath: String) async throws -> QuotaSnapshot {
        try Task.checkCancellation()
        let executable = try Self.discover(custom: customPath)
        if process?.isRunning != true || path != executable || !ready { try await start(executable) }
        try Task.checkCancellation()
        guard ready else { throw CodexFailure.processStopped }
        let token = generation
        let decoder = JSONDecoder()
        let before = try decoder.decode(AccountResponse.self, from: await rpc("account/read", params: ["refreshToken": false])).account
        try checkSession(token)
        if before?.type?.lowercased() == "apikey" || before?.type?.lowercased() == "amazonbedrock" { throw CodexFailure.authRequired }
        readingQuota = true
        defer { if generation == token { readingQuota = false; deferredUpdates.removeAll() } }
        let raw = try await rpc("account/rateLimits/read")
        try checkSession(token)
        let response = try decoder.decode(RateLimitsResponse.self, from: raw)
        let buckets = response.buckets()
        guard !buckets.isEmpty else { throw CodexFailure.noQuota }
        let after = try decoder.decode(AccountResponse.self, from: await rpc("account/read", params: ["refreshToken": false])).account
        try checkSession(token)
        guard before?.scopeKey == after?.scopeKey, before?.type == after?.type else {
            readingQuota = false; lastBuckets.removeAll(); deferredUpdates.removeAll()
            throw CodexFailure.accountChanged
        }
        if let root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            if let map = root["rateLimitsByLimitId"] as? [String: Any], !map.isEmpty {
                lastBuckets = map.compactMapValues { try? JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
            } else if let one = root["rateLimits"] as? [String: Any] {
                let id = one["limitId"] as? String ?? "legacy"
                lastBuckets = [id: try JSONSerialization.data(withJSONObject: one, options: [.sortedKeys])]
            }
        }
        readingQuota = false
        let changed = deferredUpdates.contains { updateDiffers($0) }
        deferredUpdates.removeAll()
        if changed { handler?(.quotaChanged) }
        return QuotaSnapshot(observedAt: Date(), accountScope: after?.scopeKey, accountLabel: after?.maskedLabel ?? "Codex 当前登录",
                             planType: after?.planType ?? buckets.first?.planType, buckets: buckets)
    }

    func fetchUsage(expectedScope: String) async throws -> TokenActivity {
        let token = generation
        let decoder = JSONDecoder()
        let before = try decoder.decode(AccountResponse.self, from: await rpc("account/read", params: ["refreshToken": false])).account
        try checkSession(token)
        guard before?.scopeKey == expectedScope else { throw CodexFailure.accountChanged }
        let raw = try await rpc("account/usage/read")
        try checkSession(token)
        let after = try decoder.decode(AccountResponse.self, from: await rpc("account/read", params: ["refreshToken": false])).account
        try checkSession(token)
        guard before?.scopeKey == after?.scopeKey, after?.scopeKey == expectedScope else { throw CodexFailure.accountChanged }
        return try decoder.decode(TokenActivity.self, from: raw)
    }

    private func start(_ executable: String) async throws {
        shutdown()
        let current = UUID(); generation = current
        let task = Process(); let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = ["app-server", "--stdio", "-c", "analytics.enabled=false"]
        task.standardInput = stdin; task.standardOutput = stdout; task.standardError = stderr
        task.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(home)/.npm-global/bin"
        task.environment = env
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { await self?.consume(bytes, generation: current) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            guard !bytes.isEmpty else { return }
            Task { await self?.consumeError(bytes, generation: current) }
        }
        task.terminationHandler = { [weak self] _ in Task { await self?.terminated(generation: current) } }
        process = task; input = stdin.fileHandleForWriting; output = stdout.fileHandleForReading; errors = stderr.fileHandleForReading
        path = executable
        do { try task.run() } catch { shutdown(); throw CodexFailure.processStopped }
        do {
            _ = try await rpc("initialize", params: ["clientInfo": ["name": "usagebar_macos", "title": "CodexUsageBar", "version": "0.1.3"]])
            try checkSession(current)
            try send(["method": "initialized", "params": [:]])
            ready = true
        } catch { if generation == current { shutdown() }; throw error }
    }

    private func checkSession(_ token: UUID) throws {
        try Task.checkCancellation()
        guard generation == token else { throw CodexFailure.processStopped }
    }

    private func rpc(_ method: String, params: [String: Any]? = nil) async throws -> Data {
        try Task.checkCancellation()
        guard ["initialize", "account/read", "account/rateLimits/read", "account/usage/read"].contains(method), process?.isRunning == true else { throw CodexFailure.processStopped }
        counter += 1; let id = counter; let token = generation
        var message: [String: Any] = ["id": id, "method": method]
        if let params { message["params"] = params }
        let payload = try JSONSerialization.data(withJSONObject: message) + Data([10])
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            let timeout = requestTimeout
            deadlines[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                await self?.expire(id, generation: token)
            }
            do { try input?.write(contentsOf: payload) }
            catch { resolve(id, result: .failure(CodexFailure.processStopped)) }
        }
    }

    private func send(_ message: [String: Any]) throws {
        guard let input else { throw CodexFailure.processStopped }
        try input.write(contentsOf: JSONSerialization.data(withJSONObject: message) + Data([10]))
    }

    private func consume(_ bytes: Data, generation token: UUID) {
        guard token == generation else { return }
        buffer.append(bytes)
        if buffer.count > 2 * 1024 * 1024 { failAll(CodexFailure.invalidResponse); shutdown(); return }
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            guard let value = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let id = value["id"] as? Int, pending[id] != nil {
                if let error = value["error"] as? [String: Any] {
                    resolve(id, result: .failure(Self.classifyRPCError(error)))
                } else if let result = value["result"], let raw = try? JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed]) {
                    resolve(id, result: .success(raw))
                } else { resolve(id, result: .failure(CodexFailure.invalidResponse)) }
            } else if let method = value["method"] as? String {
                if method == "account/updated" { handler?(.accountChanged) }
                if method == "account/rateLimits/updated", let params = value["params"] as? [String: Any],
                   let rate = params["rateLimits"] as? [String: Any],
                   let raw = try? JSONSerialization.data(withJSONObject: rate, options: [.sortedKeys]) {
                    if readingQuota { deferredUpdates.append(raw); if deferredUpdates.count > 16 { deferredUpdates.removeFirst() } }
                    else if updateDiffers(raw) { handler?(.quotaChanged) }
                }
            }
        }
    }

    private func updateDiffers(_ raw: Data) -> Bool {
        guard let update = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { return false }
        let id = update["limitId"] as? String ?? "legacy"
        guard let prior = lastBuckets[id], let original = try? JSONSerialization.jsonObject(with: prior) as? [String: Any] else { return true }
        // Notifications can be sparse. Only compare the fields they actually supply.
        for name in ["primary", "secondary"] {
            guard let window = update[name] as? [String: Any] else { continue }
            guard let previous = original[name] as? [String: Any] else { return true }
            for key in ["usedPercent", "windowDurationMins", "resetsAt"] {
                if let next = window[key] as? NSNumber, next != previous[key] as? NSNumber { return true }
            }
        }
        for key in ["planType", "rateLimitReachedType", "spendControlReached"] {
            if let next = update[key], !(next is NSNull), String(describing: next) != String(describing: original[key] ?? "") { return true }
        }
        return false
    }

    private func consumeError(_ bytes: Data, generation token: UUID) {
        guard token == generation else { return }; errorTail.append(bytes)
        if errorTail.count > 8192 { errorTail = Data(errorTail.suffix(8192)) }
    }
    private func expire(_ id: Int, generation token: UUID) {
        guard token == generation else { return }
        resolve(id, result: .failure(CodexFailure.timeout))
        shutdown()
    }
    private func resolve(_ id: Int, result: Result<Data, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        guard let continuation = pending.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }
    private func failAll(_ error: CodexFailure) {
        let requests = pending; pending.removeAll()
        deadlines.values.forEach { $0.cancel() }; deadlines.removeAll()
        for continuation in requests.values { continuation.resume(throwing: error) }
    }
    private func terminated(generation token: UUID) {
        guard token == generation else { return }
        let denied = String(data: errorTail, encoding: .utf8)?.contains("Operation not permitted") == true
        ready = false; failAll(denied ? .permissionDenied : .processStopped)
        handler?(.disconnected(denied ? .permissionDenied : .processStopped))
    }

    /// Classify only transport/protocol errors; never expose server error text or credentials.
    static func classifyRPCError(_ error: [String: Any]) -> CodexFailure {
        let text = (error["message"] as? String ?? "").lowercased()
        let code = error["code"] as? Int
        let data = error["data"] as? [String: Any] ?? [:]
        let status = (data["statusCode"] ?? data["status_code"] ?? data["http_status_code"] ?? error["statusCode"]) as? Int
        if code == -32601 || text.contains("method not found") || text.contains("unsupported method") { return .unsupported }
        if status == 401 || ["unauthorized", "not authenticated", "authentication", "not logged in", "login required", "token expired", "refresh token"].contains(where: text.contains) { return .authRequired }
        if text.contains("timeout") || text.contains("timed out") { return .timeout }
        if ["network", "dns", "connection refused", "connection reset", "error sending request", "failed to send request", "offline", "temporary failure"].contains(where: text.contains) { return .networkUnavailable }
        if code == -32600 || code == -32602 { return .invalidResponse }
        return .serviceUnavailable
    }
    func shutdown() {
        generation = UUID(); ready = false
        output?.readabilityHandler = nil; errors?.readabilityHandler = nil
        process?.terminationHandler = nil
        try? input?.close()
        if let running = process, running.isRunning {
            let owned = OwnedProcess(running)
            let deadline = DispatchWorkItem {
                if owned.process.isRunning { Darwin.kill(owned.process.processIdentifier, SIGKILL) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: deadline)
            running.terminate(); running.waitUntilExit(); deadline.cancel()
        }
        try? output?.close(); try? errors?.close()
        input = nil; output = nil; errors = nil; process = nil
        buffer.removeAll(); errorTail.removeAll(); deferredUpdates.removeAll(); lastBuckets.removeAll()
        readingQuota = false; failAll(.processStopped)
    }
}
