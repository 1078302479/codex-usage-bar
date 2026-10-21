import Foundation

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    func add() { lock.lock(); total += 1; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return total }
}

@main struct MonitorProbe {
    static func main() async throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("monitor-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let events = Events()
        let monitor = ClientLogMonitor(root: base) { _ in events.add() }
        guard monitor.start() else { fatalError("FSEvents could not start") }
        defer { monitor.stop(); try? FileManager.default.removeItem(at: base) }
        let file = base.appendingPathComponent("rollout-test.jsonl")
        func record(_ used: Int) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: Date()),
                "payload": ["type": "token_count", "rate_limits": ["limit_id": "codex", "primary": ["used_percent": used, "window_minutes": 300]]]]) + Data([10])
        }
        try record(16).write(to: file)
        for _ in 0..<20 { if events.count() > 0 { break }; try await Task.sleep(for: .milliseconds(150)) }
        guard events.count() > 0 else { fatalError("Quota write did not trigger client monitor") }
        let firstCount = events.count()
        let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: record(16))
        try await Task.sleep(for: .seconds(1.2))
        guard events.count() == firstCount else { fatalError("Identical quota values should be coalesced") }
        try handle.write(contentsOf: record(17))
        for _ in 0..<20 { if events.count() > firstCount { break }; try await Task.sleep(for: .milliseconds(150)) }
        guard events.count() > firstCount else { fatalError("Changed quota did not trigger monitor") }
        try handle.close()
        print("PASS: real FSEvents detect quota changes and ignore duplicate values")
    }
}
