import AppKit
import Combine
import OSLog

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
                // The primary local workspace is authoritative. Preserve the secondary
                // history as a backup without importing it into the shared workspace.
                try fm.moveItem(at: target, to: secondary.appendingPathComponent(name + ".backup-" + UUID().uuidString))
            }
            try fm.createSymbolicLink(at: target, withDestinationURL: source)
        }
    }
    // Keep provider definitions and model settings available under either login home.
    // Credentials remain in each home's auth.json; preserve any previous secondary config.
    static func shareConfiguration(primary: URL, secondary: URL) throws {
        let fm = FileManager.default
        let source = primary.appendingPathComponent("config.toml")
        let target = secondary.appendingPathComponent("config.toml")
        if let link = try? fm.destinationOfSymbolicLink(atPath: target.path),
           URL(fileURLWithPath: link, relativeTo: secondary).standardizedFileURL == source.standardizedFileURL { return }
        if fm.fileExists(atPath: target.path) || (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
            try fm.moveItem(at: target, to: secondary.appendingPathComponent("config.toml.backup-" + UUID().uuidString))
        }
        // A dangling link is intentional when the primary has no configuration yet.
        try fm.createSymbolicLink(at: target, withDestinationURL: source)
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
        // The current local state is authoritative, including an empty project list.
        // Never restore or merge another account's cached projects or conversations.
        for (owner, var entry) in inactive {
            var globals = entry["globals"] as? [String: Any] ?? [:]
            for key in keys { globals[key] = state[key] }
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
            result[key] = original[key]
        }
        for key in ["app-server-project-id-by-legacy-project-id-by-host", "app-server-projects-migration-by-host"] {
            result.removeValue(forKey: key)
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
    static func prepareLauncher(cliPath: String, home: URL = AppState.secondAccountHome, profileID: String = "secondary") throws -> URL {
        let cli = try CodexClient.discover(custom: cliPath)
        let fm = FileManager.default
        for folder in [root, profile, home] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try shareConfiguration(primary: primaryHome, secondary: home)
        try shareSessions(primary: primaryHome, secondary: home)
        try syncWorkspaceState(primary: primaryHome, secondary: home)
        let launcher = root.appendingPathComponent("codex-" + profileID)
        let source = "#!/bin/sh\nunset OPENAI_API_KEY CODEX_API_KEY CODEX_ACCESS_TOKEN CODEX_APP_SERVER_WS_URL\nexport CODEX_HOME=" + quote(home.path) + "\nexec " + quote(cli) + " -c 'cli_auth_credentials_store=\"file\"' -c " + quote("sqlite_home=\"" + primaryHome.path + "\"") + " -c " + quote("usagebar_account_id=\"" + profileID + "\"") + " \"$@\"\n"
        try source.write(to: launcher, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
        return launcher
    }
    private let defaults: UserDefaults
    var profiles: (() -> [(id: String, home: URL?, scope: String?)])?
    var onActiveProfile: ((String) -> Void)?
    @Published private(set) var activeProfileID: String?
    @Published var targetProfileID = "primary"
    var accountScopes: (() -> (primary: String?, secondary: String?))?
    var cliPath: (() -> String)?
    var onAccountUncertain: (() -> Void)?
    var onRestartSucceeded: ((Bool) -> Void)?
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedSecondary = defaults.bool(forKey: "execution-account.secondary.v1")
        activeSecondary = selectedSecondary
        activeProfileID = defaults.string(forKey: "execution-account.profile.v1") ?? (selectedSecondary ? "secondary" : "primary")
    }
    @Published private(set) var detected = false
    private var lastDetection = Date.distantPast
    private var detecting = false
    private static let detectionLog = Logger(subsystem: "com.guoyuming.UsageBar", category: "DesktopAccount")
    nonisolated static func detectProfile(processList: String, desktopPIDs: Set<Int32>) -> String? {
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
        let candidates = rows.filter { row in
            guard descendants.contains(row.0), let executableEnd = row.2.range(of: "/codex ")?.upperBound else { return false }
            return row.2[executableEnd...].split(whereSeparator: \.isWhitespace).contains("app-server")
        }
        let serverIDs = Set(candidates.map { $0.0 })
        let parents = Dictionary(rows.map { ($0.0, $0.1) }, uniquingKeysWith: { first, _ in first })
        // Tools launched inside a chat may themselves spawn quota app-servers.
        // Only the outermost desktop backend identifies the client's login.
        let servers = candidates.filter { server in
            var parent = server.1
            var visited = Set<Int32>()
            while parent > 0 && visited.insert(parent).inserted {
                if serverIDs.contains(parent) { return false }
                parent = parents[parent] ?? 0
            }
            return true
        }
        guard !servers.isEmpty else { return nil }
        let identities = Set(servers.map { server -> String in
            let prefix = "usagebar_account_id=\""
            if let range = server.2.range(of: prefix), let end = server.2[range.upperBound...].firstIndex(of: "\"") {
                let id = String(server.2[range.upperBound..<end])
                if id == "secondary" || UUID(uuidString: id) != nil { return id }
            }
            return server.2.contains("sqlite_home=") && server.2.contains("cli_auth_credentials_store=") ? "secondary" : "primary"
        })
        return identities.count == 1 ? identities.first : nil
    }
    nonisolated static func detectSecondary(processList: String, desktopPIDs: Set<Int32>) -> Bool? {
        detectProfile(processList: processList, desktopPIDs: desktopPIDs).map { $0 != "primary" }
    }
    func detectRunningAccount() {
        guard !isSwitching, !detecting, Date().timeIntervalSince(lastDetection) > 3 else { return }
        guard let bundleID = Bundle(url: URL(fileURLWithPath: "/Applications/ChatGPT.app"))?.bundleIdentifier else { return }
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        guard !pids.isEmpty else { markAccountUncertain("Desktop is not running"); return }
        detecting = true; lastDetection = Date()
        Task {
            let profileList = profiles?() ?? []
            let result = await Task.detached { () -> String? in
                let process = Process(); let pipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/ps")
                process.arguments = ["-ww", "-axo", "pid=,ppid=,command="]
                process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                do { try process.run() } catch { return nil }
                let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                guard process.terminationStatus == 0 else { return nil }
                let list = String(decoding: data, as: UTF8.self)
                return Self.detectProfile(processList: list, desktopPIDs: pids)
            }.value
            guard !isSwitching else { detecting = false; return }
            guard let result else { detecting = false; markAccountUncertain("Desktop backend could not be identified"); return }
            // Process ancestry locates the desktop's login home, not its user identity.
            // Verify that home's current login against the monitored account identities.
            let probeHome = profileList.first(where: { $0.id == result })?.home ?? (result == "secondary" ? AppState.secondAccountHome : nil)
            let probe = CodexClient(codexHome: probeHome)
            let scope: String?
            do { scope = try await probe.readAccountScope(customPath: "/Applications/ChatGPT.app") }
            catch { scope = nil }
            await probe.shutdown()
            detecting = false
            guard !isSwitching else { return }
            guard let scope else { markAccountUncertain("Desktop backend account/read returned no verified identity"); return }
            if !profileList.isEmpty {
                guard confirmProfile(scope: scope, preferredProfileID: result) else {
                    markAccountUncertain("Desktop identity did not match a verified profile"); return
                }
                return
            }
            let scopes = accountScopes?()
            guard let matched = Self.matchAccount(scope: scope, primary: scopes?.primary, secondary: scopes?.secondary) else {
                markAccountUncertain("Desktop identity did not match a verified profile"); return
            }
            acceptDetectedAccount(matched)
        }
    }
    private func markAccountUncertain(_ reason: String) {
        Self.detectionLog.notice("\(reason, privacy: .public)")
        detected = false
        onAccountUncertain?()
    }
    @discardableResult
    func confirmProfile(scope: String?, preferredProfileID: String? = nil) -> Bool {
        guard let scope else { return false }
        let matches = (profiles?() ?? []).filter { $0.scope == scope }
        // The same login can be saved in multiple monitoring profiles. The desktop
        // backend identifies its login home; accept that hint only after its live
        // account/read identity matches the profile's independently verified scope.
        let match: (id: String, home: URL?, scope: String?)?
        if matches.count == 1 { match = matches.first }
        else if let preferredProfileID { match = matches.first { $0.id == preferredProfileID } }
        else { match = nil }
        guard let match else { return false }
        let changed = !detected || activeProfileID != match.id
        activeProfileID = match.id
        defaults.set(match.id, forKey: "execution-account.profile.v1")
        activeSecondary = match.id != "primary"
        detected = true
        if changed {
            Self.detectionLog.notice("Desktop identity matched a verified profile")
            onActiveProfile?(match.id)
        }
        return true
    }
    nonisolated static func matchAccount(scope: String?, primary: String?, secondary: String?) -> Bool? {
        guard let scope else { return nil }
        let matchesPrimary = scope == primary
        let matchesSecondary = scope == secondary
        guard matchesPrimary != matchesSecondary else { return nil }
        return matchesSecondary
    }
    func acceptDetectedAccount(_ result: Bool) {
        let changed = activeSecondary != result || !detected
        detected = true; activeSecondary = result
        activeProfileID = result ? "secondary" : "primary"
        if changed {
            selectedSecondary = result
            defaults.set(result, forKey: "execution-account.secondary.v1")
            onRestartSucceeded?(result)
        }
    }
    func restartSucceeded(secondary: Bool, label: String) {
        selectedSecondary = secondary
        activeSecondary = secondary
        activeProfileID = secondary ? "secondary" : "primary"
        detected = false
        defaults.set(secondary, forKey: "execution-account.secondary.v1")
        lastOpened = label
        onRestartSucceeded?(secondary)
    }
    @Published private(set) var activeSecondary = false
    func roleLabel(secondary: Bool) -> String { !detected ? "登录待确认" : (secondary == activeSecondary ? "主账号" : "备用账号") }
    var orderedSecondary: [Bool] { activeSecondary ? [true, false] : [false, true] }
    @Published var selectedSecondary = false
    @Published private(set) var isSwitching = false
    @Published private(set) var lastOpened: String?
    func switchToOtherAccount(cliPath: String) {
        guard detected, !isSwitching else { return }
        selectedSecondary = !activeSecondary
        switchAndRestart(cliPath: cliPath)
    }
    func profileSignedOut(_ id: String) {
        if activeProfileID == id {
            detected = false
            onAccountUncertain?()
        }
    }
    func switchToProfile(_ id: String, cliPath: String) {
        guard detected, !isSwitching, id != activeProfileID,
              profiles?().contains(where: { $0.id == id && $0.scope != nil }) == true else { return }
        targetProfileID = id
        selectedSecondary = id != "primary"
        switchAndRestart(cliPath: cliPath)
    }
    private func switchAndRestart(cliPath: String) {
        guard !isSwitching else { return }
        let profileID = profiles == nil ? (selectedSecondary ? "secondary" : "primary") : targetProfileID
        let useSecondary = profileID != "primary"
        isSwitching = true
        Task {
            defer { isSwitching = false }
            do {
                let app = URL(fileURLWithPath: "/Applications/ChatGPT.app")
                guard let bundle = Bundle(url: app), let bundleID = bundle.bundleIdentifier else { throw CodexFailure.missingCLI }
                let home = profiles?().first(where: { $0.id == profileID })?.home ?? (useSecondary ? AppState.secondAccountHome : Self.primaryHome)
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
                if useSecondary { wrapper = try Self.prepareLauncher(cliPath: cliPath, home: home, profileID: profileID) }
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
                activeProfileID = profileID
                defaults.set(profileID, forKey: "execution-account.profile.v1")
                onActiveProfile?(profileID)
                message = "已按所选账号重启，请在客户端核对 Codex 账号。"
            } catch { message = "切换未完成，请先核验所选账号登录，并检查 Codex 路径。" }
        }
    }
}
