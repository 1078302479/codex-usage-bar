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
        precondition(fm.fileExists(atPath: a.appendingPathComponent("sessions/b.jsonl").path))
        let auth = try Data(contentsOf: b.appendingPathComponent("auth.json"))
        precondition(auth == Data("private".utf8))
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
        precondition((repaired["local-projects"] as? [String: Any])?.count == 1)
        let accounts = repaired["electron-account-renderer-state-v1"] as! [String: Any]
        precondition(accounts["owner"] as? String == "B")
        let inactive = accounts["inactive"] as! [String: [String: Any]]
        precondition((inactive["A"]?["atoms"] as? [String: String])?["private"] == "A")
        try DualClientController.repairAccountWorkspaceState(home: a)
        let ambiguous: [String: Any] = ["local-projects": [:], "electron-account-renderer-state-v1": ["owner": "B", "inactive": [
            "A": ["globals": workspace], "C": ["globals": workspace]]]]
        let ambiguousData = try JSONSerialization.data(withJSONObject: ambiguous)
        try ambiguousData.write(to: a.appendingPathComponent(stateName))
        do {
            try DualClientController.repairAccountWorkspaceState(home: a)
            preconditionFailure("Ambiguous caches must not be merged")
        } catch CodexFailure.invalidResponse {}
        let untouched = try Data(contentsOf: a.appendingPathComponent(stateName))
        precondition(untouched == ambiguousData)
        print("PASS: account-switch workspace restoration and private atom preservation")
        print("PASS: workspace metadata, host mapping, private-state isolation, backup and idempotence")
        print("PASS: shared history, preserved secondary files, unchanged authentication and idempotent setup")
    }
}
