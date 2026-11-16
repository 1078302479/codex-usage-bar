import Foundation
@main struct SharedWorkspaceTests {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        for home in [a,b] { try fm.createDirectory(at: home.appendingPathComponent("sessions"), withIntermediateDirectories: true) }
        try Data("original".utf8).write(to: a.appendingPathComponent("sessions/a.jsonl"))
        try Data("secondary".utf8).write(to: b.appendingPathComponent("sessions/b.jsonl"))
        try Data("private".utf8).write(to: b.appendingPathComponent("auth.json"))
        try DualClientController.shareSessions(primary: a, secondary: b)
        try DualClientController.shareSessions(primary: a, secondary: b)
        precondition(fm.contentsEqual(atPath: a.appendingPathComponent("sessions/a.jsonl").path, andPath: b.appendingPathComponent("sessions/a.jsonl").path))
        precondition(!fm.fileExists(atPath: a.appendingPathComponent("sessions/b.jsonl").path))
        let sessionBackups = try fm.contentsOfDirectory(atPath: b.path).filter { $0.hasPrefix("sessions.backup-") }
        precondition(sessionBackups.count == 1)
        precondition(fm.fileExists(atPath: b.appendingPathComponent(sessionBackups[0] + "/b.jsonl").path))
        let auth = try Data(contentsOf: b.appendingPathComponent("auth.json"))
        precondition(auth == Data("private".utf8))
        let config = Data("model_provider = \"custom\"\n[model_providers.custom]\nname = \"Custom\"\n".utf8)
        try config.write(to: a.appendingPathComponent("config.toml"))
        try Data("old secondary settings".utf8).write(to: b.appendingPathComponent("config.toml"))
        try DualClientController.shareConfiguration(primary: a, secondary: b)
        try DualClientController.shareConfiguration(primary: a, secondary: b)
        let secondaryConfig = try Data(contentsOf: b.appendingPathComponent("config.toml"))
        precondition(secondaryConfig == config)
        let configBackups = try fm.contentsOfDirectory(atPath: b.path).filter { $0.hasPrefix("config.toml.backup-") }
        precondition(configBackups.count == 1)
        let configBackup = try Data(contentsOf: b.appendingPathComponent(configBackups[0]))
        precondition(configBackup == Data("old secondary settings".utf8))
        try fm.removeItem(at: a.appendingPathComponent("config.toml"))
        try DualClientController.shareConfiguration(primary: a, secondary: b)
        try config.write(to: a.appendingPathComponent("config.toml"))
        let restoredConfig = try Data(contentsOf: b.appendingPathComponent("config.toml"))
        precondition(restoredConfig == config)
        let stateName = ".codex-global-state.json"
        let workspace: [String: Any] = ["local-projects": ["p1": ["name": "project"]], "project-order": ["p1"],
            "app-server-project-id-by-legacy-project-id-by-host": ["local:" + a.path: ["p1": "server1"]],
            "electron-account-renderer-state-v1": ["owner": "primary-private"]]
        try JSONSerialization.data(withJSONObject: workspace).write(to: a.appendingPathComponent(stateName))
        try JSONSerialization.data(withJSONObject: ["local-projects": [:], "electron-account-renderer-state-v1": ["owner": "secondary-private"], "unknown-setting": true]).write(to: b.appendingPathComponent(stateName))
        try DualClientController.syncWorkspaceState(primary: a, secondary: b)
        try DualClientController.syncWorkspaceState(primary: a, secondary: b)
        let shared = try JSONSerialization.jsonObject(with: Data(contentsOf: b.appendingPathComponent(stateName))) as! [String: Any]
        precondition((shared["local-projects"] as? [String: Any])?.count == 1)
        precondition((shared["electron-account-renderer-state-v1"] as? [String: String])?["owner"] == "secondary-private")
        precondition(shared["unknown-setting"] as? Bool == true)
        let hosts = shared["app-server-project-id-by-legacy-project-id-by-host"] as! [String: [String: String]]
        precondition(hosts["local:" + b.path]?["p1"] == "server1")
        let preservedAuth = try Data(contentsOf: b.appendingPathComponent("auth.json"))
        precondition(preservedAuth == Data("private".utf8))
        let backups = try fm.contentsOfDirectory(atPath: b.path).filter { $0.contains(".workspace-backup-") }
        precondition(backups.count == 1)
        let accountState: [String: Any] = ["local-projects": [:], "electron-account-renderer-state-v1": [
            "owner": "B", "inactive": ["A": ["atoms": ["private": "A"], "globals": workspace]]]]
        try JSONSerialization.data(withJSONObject: accountState).write(to: a.appendingPathComponent(stateName))
        try DualClientController.repairAccountWorkspaceState(home: a)
        let repaired = try JSONSerialization.jsonObject(with: Data(contentsOf: a.appendingPathComponent(stateName))) as! [String: Any]
        precondition((repaired["local-projects"] as? [String: Any])?.isEmpty == true)
        let accounts = repaired["electron-account-renderer-state-v1"] as! [String: Any]
        precondition(accounts["owner"] as? String == "B")
        let inactive = accounts["inactive"] as! [String: [String: Any]]
        precondition((inactive["A"]?["atoms"] as? [String: String])?["private"] == "A")
        try DualClientController.repairAccountWorkspaceState(home: a)
        var different = accountState
        different["local-projects"] = ["p2": ["name": "second project"]]
        different["project-order"] = ["p2"]
        try JSONSerialization.data(withJSONObject: different).write(to: a.appendingPathComponent(stateName))
        try DualClientController.repairAccountWorkspaceState(home: a)
        let merged = try JSONSerialization.jsonObject(with: Data(contentsOf: a.appendingPathComponent(stateName))) as! [String: Any]
        precondition((merged["local-projects"] as? [String: Any])?.count == 1)
        precondition(merged["project-order"] as? [String] == ["p2"])
        let mergedAccounts = merged["electron-account-renderer-state-v1"] as! [String: Any]
        let mergedInactive = mergedAccounts["inactive"] as! [String: [String: Any]]
        let mergedGlobals = mergedInactive["A"]?["globals"] as! [String: Any]
        precondition((mergedGlobals["local-projects"] as? [String: Any])?.count == 1)
        let ambiguous: [String: Any] = ["local-projects": [:], "electron-account-renderer-state-v1": ["owner": "B", "inactive": [
            "A": ["globals": workspace], "C": ["globals": workspace]]]]
        let ambiguousData = try JSONSerialization.data(withJSONObject: ambiguous)
        try ambiguousData.write(to: a.appendingPathComponent(stateName))
        try DualClientController.repairAccountWorkspaceState(home: a)
        let empty = try JSONSerialization.jsonObject(with: Data(contentsOf: a.appendingPathComponent(stateName))) as! [String: Any]
        precondition((empty["local-projects"] as? [String: Any])?.isEmpty == true)
        let emptyAccounts = empty["electron-account-renderer-state-v1"] as! [String: Any]
        let emptyInactive = emptyAccounts["inactive"] as! [String: [String: Any]]
        for entry in emptyInactive.values {
            let globals = entry["globals"] as! [String: Any]
            precondition((globals["local-projects"] as? [String: Any])?.isEmpty == true)
            precondition(globals["project-order"] == nil)
        }
        print("PASS: authoritative local workspace and empty-list preservation and private atom preservation")
        print("PASS: workspace metadata, host mapping, private-state isolation, backup and idempotence")
        print("PASS: shared history, backed-up secondary files without importing them, unchanged authentication and idempotent setup")
    }
}
