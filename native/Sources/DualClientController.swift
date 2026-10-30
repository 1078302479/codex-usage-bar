import AppKit
import Combine

@MainActor
final class DualClientController: ObservableObject {
    @Published private(set) var message: String?
    static var root: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexUsageBar/account-switch") }
    static var primaryHome: URL { CodexClient.primaryHome() }
    static var profile: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex") }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    static func shareSessions(primary: URL, secondary: URL) throws {
        let fm = FileManager.default
        for name in ["sessions", "archived_sessions", "worktrees", "attachments"] {
            let source = primary.appendingPathComponent(name)
            let target = secondary.appendingPathComponent(name)
            try fm.createDirectory(at: source, withIntermediateDirectories: true)
            if let link = try? fm.destinationOfSymbolicLink(atPath: target.path) {
                guard URL(fileURLWithPath: link).resolvingSymlinksInPath() == source.resolvingSymlinksInPath() else { throw CodexFailure.invalidResponse }
                continue
            }
            if fm.fileExists(atPath: target.path) {
                // Preserve both histories; never replace an existing workspace file.
                if let entries = fm.enumerator(at: target, includingPropertiesForKeys: [.isDirectoryKey]) {
                    for case let item as URL in entries {
                        let base = target.resolvingSymlinksInPath().path + "/"
                        let resolved = item.resolvingSymlinksInPath().path
                        guard resolved.hasPrefix(base) else { throw CodexFailure.invalidResponse }
                        let relative = String(resolved.dropFirst(base.count))
                        let destination = source.appendingPathComponent(relative)
                        let directory = try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                        if directory { try fm.createDirectory(at: destination, withIntermediateDirectories: true) }
                        else if !fm.fileExists(atPath: destination.path) { try fm.copyItem(at: item, to: destination) }
                        else if !fm.contentsEqual(atPath: item.path, andPath: destination.path) { throw CodexFailure.invalidResponse }
                    }
                }
                try fm.moveItem(at: target, to: secondary.appendingPathComponent(name + ".backup-" + UUID().uuidString))
            }
            try fm.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }
    static func prepareLauncher(cliPath: String) throws -> URL {
        let cli = try CodexClient.discover(custom: cliPath)
        let fm = FileManager.default
        for folder in [root, profile, AppState.secondAccountHome] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try shareSessions(primary: primaryHome, secondary: AppState.secondAccountHome)
        let launcher = root.appendingPathComponent("codex-secondary")
        let source = "#!/bin/sh\nunset OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN CODEX_APP_SERVER_WS_URL\nexport CODEX_HOME=" + quote(AppState.secondAccountHome.path) + "\nexec " + quote(cli) + " -c 'cli_auth_credentials_store=\"file\"' -c " + quote("sqlite_home=\"" + primaryHome.path + "\"") + " \"$@\"\n"
        try source.write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        return launcher
    }
    private let defaults: UserDefaults
    var onRestartSucceeded: ((Bool) -> Void)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedSecondary = defaults.bool(forKey: "execution-account.secondary.v1")
        activeSecondary = selectedSecondary
    }
    @Published private(set) var detected = false
    private var lastDetection = Date.distantPast
    private var detecting = false
    nonisolated static func detectSecondary(processList: String, desktopPIDs: Set<Int32>) -> Bool? {
        let rows = processList.split(separator: "\n").compactMap { line -> (Int32, Int32, String)? in
            let parts = line.split(maxSplits: 2, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count == 3, let pid = Int32(parts[0]), let parent = Int32(parts[1]) else { return nil }
            return (pid, parent, String(parts[2]))
        }
        var descendants = desktopPIDs
        for _ in 0..<12 {
            let before = descendants.count
            for (pid, parent, _) in rows where descendants.contains(parent) { descendants.insert(pid) }
            if descendants.count == before { break }
        }
        let servers = rows.filter { descendants.contains($0.0) && $0.2.contains("/codex ") && $0.2.contains("app-server") }
        guard !servers.isEmpty else { return nil }
        let identities = Set(servers.map { $0.2.contains("sqlite_home=") && $0.2.contains("cli_auth_credentials_store=") })
        return identities.count == 1 ? identities.first : nil
    }
    func detectRunningAccount() {
        guard !isSwitching, !detecting, Date().timeIntervalSince(lastDetection) > 3 else { return }
        guard let bundleID = Bundle(url: URL(fileURLWithPath: "/Applications/ChatGPT.app"))?.bundleIdentifier else { return }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty else { detected = false; return }
        detecting = true; lastDetection = Date()
        Task {
            let result = await Task.detached { () -> Bool? in
                let process = Process(); let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/ps")
                process.arguments = ["-axo", "pid=,ppid=,command="]
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0, let list = String(data: data, encoding: .utf8) else { return nil }
                return Self.detectSecondary(processList: list, desktopPIDs: pids)
            }.value
            detecting = false
            guard !isSwitching else { return }
            guard let result else { detected = false; return }
            let changed = activeSecondary != result || !detected
            detected = true
            activeSecondary = result
            if changed {
                selectedSecondary = result
                defaults.set(result, forKey: "execution-account.secondary.v1")
                onRestartSucceeded?(result)
            }
        }
    }
    func restartSucceeded(secondary: Bool, label: String) {
        selectedSecondary = secondary
        activeSecondary = secondary
        detected = false
        defaults.set(secondary, forKey: "execution-account.secondary.v1")
        lastOpened = (secondary ? "B" : "A") + " · " + label
        onRestartSucceeded?(secondary)
    }
    @Published private(set) var activeSecondary = false
    func roleLabel(secondary: Bool) -> String { !detected ? "登录待确认" : (secondary == activeSecondary ? "本机账号" : "备用账号") }
    var orderedSecondary: [Bool] { activeSecondary ? [true, false] : [false, true] }
    @Published var selectedSecondary = false
    @Published private(set) var isSwitching = false
    @Published private(set) var lastOpened: String?
    func switchToOtherAccount(cliPath: String) {
        guard detected, !isSwitching else { return }
        selectedSecondary = !activeSecondary
        switchAndRestart(cliPath: cliPath)
    }
    private func switchAndRestart(cliPath: String) {
        guard !isSwitching else { return }
        let useSecondary = selectedSecondary
        isSwitching = true
        Task {
            defer { isSwitching = false }
            do {
                let app = URL(fileURLWithPath: "/Applications/ChatGPT.app")
                guard let bundle = Bundle(url: app), let bundleID = bundle.bundleIdentifier else { throw CodexFailure.missingCLI }
                let home = useSecondary ? AppState.secondAccountHome : Self.primaryHome
                // Verify the intended native login before closing any window.
                let check = CodexClient(codexHome: useSecondary ? home : nil)
                let snapshot: QuotaSnapshot
                do { snapshot = try await check.fetch(customPath: cliPath); await check.shutdown() }
                catch { await check.shutdown(); throw error }
                guard snapshot.accountScope != nil else { throw CodexFailure.authRequired }
                let apps = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                for running in apps { _ = running.terminate() }
                for _ in 0..<150 {
                    if apps.allSatisfy({ $0.isTerminated }) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                guard apps.allSatisfy({ $0.isTerminated }) else {
                    message = "客户端尚未退出，请处理未保存内容后重试。"; return
                }
                let wrapper: URL
                if useSecondary { wrapper = try Self.prepareLauncher(cliPath: cliPath) }
                else { wrapper = URL(fileURLWithPath: try CodexClient.discover(custom: cliPath)) }
                // Keep desktop workspace state on the original home; only the child login differs.
                try FileManager.default.createDirectory(at: Self.profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                process.arguments = ["-n", "--env", "CODEX_HOME=" + Self.primaryHome.path,
                    "--env", "CODEX_CLI_PATH=" + wrapper.path, "--env", "CODEX_APP_SERVER_FORCE_CLI=1",
                    "--env", "CODEX_APP_SERVER_WS_URL=", "--env", "OPENAI_API_KEY=", "--env", "CODEX_API_KEY=", "--env", "CODEX_ACCESS_TOKEN=",
                    "--env", "CODEX_ELECTRON_USER_DATA_PATH=",
                    app.path]
                let exit: Int32 = try await withCheckedThrowingContinuation { continuation in
                    process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
                    do { try process.run() } catch { continuation.resume(throwing: error) }
                }
                guard exit == 0 else { throw CodexFailure.processStopped }
                restartSucceeded(secondary: useSecondary, label: snapshot.accountLabel)
                message = "已按所选账号重启，请在客户端核对 Codex 账号。"
            } catch { message = "切换未完成，请先核验所选账号登录，并检查 Codex 路径。" }
        }
    }
}
