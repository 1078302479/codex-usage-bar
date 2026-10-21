import Foundation

@main struct NativeQuotaProbe {
    static func main() async {
        let client = CodexClient()
        do {
            let snapshot = try await client.fetch(customPath: "")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
            print(String(decoding: try encoder.encode(snapshot), as: UTF8.self))
            if CommandLine.arguments.contains("--activity"), let scope = snapshot.accountScope {
                let usage = try await client.fetchUsage(expectedScope: scope)
                print(String(decoding: try encoder.encode(usage), as: UTF8.self))
            }
            await client.shutdown()
        } catch {
            await client.shutdown()
            print("Native quota probe failed: \(error.localizedDescription)")
            exit(1)
        }
    }
}
