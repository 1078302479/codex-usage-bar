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
        print("PASS: shared history, preserved secondary files, unchanged authentication and idempotent setup")
    }
}
