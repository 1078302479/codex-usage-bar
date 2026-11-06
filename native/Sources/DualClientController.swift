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
    // New desktop versions also read project state through the backend's CODEX_HOME.
    // Share only local workspace metadata; account UI state and credentials stay isolated.
    static func repairAccountWorkspaceState(home: URL) throws {
        let fm = FileManager.default
        let file = home.appendingPathComponent(".codex-global-state.json")
        guard fm.fileExists(atPath: file.path) else { return }
        let data = try Data(contentsOf: file)
        guard var state = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var accounts = state["electron-account-renderer-state-v1"] as? [String: Any],
              var inactive = accounts["inactive"] as? [String: [String: Any]] else { return }
        let keys = ["local-projects", "selected-project", "project-order", "project-appearances",
                    "app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host",
                    "sidebar-project-thread-orders", "thread-project-assignments", "thread-project-membership-host-ids",
                    "thread-writable-roots", "thread-workspace-root-hints", "projectless-thread-ids",
                    "thread-projectless-output-directories", "pinned-thread-ids", "app-server-migrated-pinned-thread-ids-by-host"]
        // Recover a missing active list from the account cache without replacing a nonempty list.
        var workspace = state
        if (workspace["local-projects"] as? [String: Any] ?? [:]).isEmpty {
            let candidates = inactive.values.compactMap { $0["globals"] as? [String: Any] }
                .filter { !($0["local-projects"] as? [String: Any] ?? [:]).isEmpty }
            if candidates.isEmpty { return }
            guard candidates.count == 1, let recovered = candidates.first else { throw CodexFailure.invalidResponse }
            workspace = recovered
        }
        for key in keys { if let value = workspace[key] { state[key] = value } }
        for (owner, var entry) in inactive {
            var globals = entry["globals"] as? [String: Any] ?? [:]
            for key in keys { if let value = workspace[key] { globals[key] = value } }
            entry["globals"] = globals
            inactive[owner] = entry
        }
        accounts["inactive"] = inactive
        state["electron-account-renderer-state-v1"] = accounts
        if (state as NSDictionary).isEqual(to: try JSONSerialization.jsonObject(with: data) as! [String: Any]) { return }
        try fm.copyItem(at: file, to: home.appendingPathComponent(".codex-global-state.json.workspace-backup-" + UUID().uuidString))
        let updated = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try updated.write(to: file, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    static func syncWorkspaceState(primary: URL, secondary: URL) throws {
        let fm = FileManager.default
        let name = ".codex-global-state.json"
        let source = primary.appendingPathComponent(name)
        guard fm.fileExists(atPath: source.path) else { return }
        let target = secondary.appendingPathComponent(name)
        guard let original = try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any] else {
            throw CodexFailure.invalidResponse
        }
        var result: [String: Any] = [:]
        let existing = fm.fileExists(atPath: target.path) ? try Data(contentsOf: target) : nil
        if let existing {
            guard let value = try JSONSerialization.jsonObject(with: existing) as? [String: Any] else { throw CodexFailure.invalidResponse }
            result = value
        }
        let keys = ["local-projects", "selected-project", "project-order", "project-appearances",
                    "sidebar-project-thread-orders", "thread-project-assignments", "thread-project-membership-host-ids",
                    "thread-writable-roots", "thread-workspace-root-hints", "projectless-thread-ids",
                    "thread-projectless-output-directories", "pinned-thread-ids", "app-server-migrated-pinned-thread-ids-by-host"]
        for key in keys {
            if let value = original[key] { result[key] = value }
        }
        for key in ["app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host"] {
            if var hosts = original[key] as? [String: Any] {
                if let state = hosts["local:" + primary.path] { hosts["local:" + secondary.path] = state }
                result[key] = hosts
            }
        }
        let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
        if let existing, let old = try JSONSerialization.jsonObject(with: existing) as? NSDictionary,
           old.isEqual(to: result) { return }
        if fm.fileExists(atPath: target.path) {
            try fm.copyItem(at: target, to: secondary.appendingPathComponent(name + ".workspace-backup-" + UUID().uuidString))
        }
        try data.write(to: target, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
    }
    static func prepareLauncher(cliPath: String) throws -> URL {
        let cli = try CodexClient.discover(custom: cliPath)
        let fm = FileManager.default
        for folder in [root, profile, AppState.secondAccountHome] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try shareSessions(primary: primaryHome, secondary: AppState.secondAccountHome)
        try syncWorkspaceState(primary: primaryHome, secondary: AppState.secondAccountHome)
        let launcher = root.appendingPathComponent("codex-secondary")
        let source = "#!/bin/sh\nunset OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN CODEX_APP_SERVER_WS_URL\nexport CODEX_HOME=" + quote(AppState.secondAccountHome.path) + "\nexec " + quote(cli) + " -c 'cli_auth_credentials_store=\"file\"' -c " + quote("sqlite_home=\"" + primaryHome.path + "\"") + " \"$@\"\n"
        try source.write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        return launcher
    }
    private let defaults: UserDefaults
    var onAccountUncertain: (() -> Void)?
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
        guard !pids.isEmpty else { detected = false; onAccountUncertain?(); return }
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
            guard let result else { detected = false; onAccountUncertain?(); return }
            acceptDetectedAccount(result)
        }
    }
    func acceptDetectedAccount(_ result: Bool) {
        let changed = activeSecondary != result || !detected
        detected = true; activeSecondary = result
        if changed {
            selectedSecondary = result
            defaults.set(result, forKey: "execution-account.secondary.v1")
            onRestartSucceeded?(result)
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
                try Self.repairAccountWorkspaceState(home: Self.primaryHome)
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
