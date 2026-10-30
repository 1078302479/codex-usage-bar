import AppKit
import Combine

struct AppRelease: Decodable, Sendable {
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    var safeURL: URL? {
        guard !draft, !prerelease, html_url.scheme == "https", html_url.host == "github.com",
              html_url.user == nil, html_url.password == nil,
              html_url.path.hasPrefix("/1078302479/codex-usage-bar/releases/tag/") else { return nil }
        return html_url
    }
    static func version(_ value: String) -> [Int]? {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return nil }
        let numbers = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            return Int(part)
        }
        return numbers.count == parts.count ? numbers : nil
    }
    static func newer(_ candidate: String, than current: String) -> Bool {
        guard var a = version(candidate), var b = version(current) else { return false }
        while a.count < b.count { a.append(0) }; while b.count < a.count { b.append(0) }
        return b.lexicographicallyPrecedes(a)
    }
}

@MainActor
final class AppUpdateController: ObservableObject {
    static let interval: TimeInterval = 8 * 60 * 60
    static let endpoint = URL(string: "https://api.github.com/repos/1078302479/codex-usage-bar/releases/latest")!
    @Published private(set) var latest: AppRelease?
    @Published private(set) var checking = false
    @Published private(set) var status = "每 8 小时检查 GitHub 最新正式版"
    @Published private(set) var lastChecked: Date?
    let currentVersion: String
    private var timer: Timer?
    private var task: Task<Void, Never>?
    init(version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.6") { currentVersion = version }
    var available: Bool { latest?.safeURL != nil && AppRelease.newer(latest!.tag_name, than: currentVersion) }
    func start() {
        guard timer == nil else { return }
        check()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
    }
    func checkIfDue(now: Date = Date()) {
        if lastChecked.map({ now.timeIntervalSince($0) >= Self.interval }) != false { check() }
    }
    func stop() { timer?.invalidate(); timer = nil; task?.cancel(); task = nil; checking = false }
    func check() {
        guard !checking else { return }
        checking = true; status = "正在检查更新…"
        task = Task { [weak self] in
            guard let self else { return }
            defer { checking = false; task = nil }
            do {
                var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.setValue("CodexUsageBar/" + currentVersion, forHTTPHeaderField: "User-Agent")
                let (data, response) = try await URLSession.shared.data(for: request)
                try Task.checkCancellation()
                guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { throw URLError(.badServerResponse) }
                let release = try JSONDecoder().decode(AppRelease.self, from: data)
                guard release.safeURL != nil, AppRelease.version(release.tag_name) != nil else { throw URLError(.cannotParseResponse) }
                latest = release; lastChecked = Date()
                status = available ? "发现新版本 " + release.tag_name : "已是最新版本"
            } catch {
                guard !Task.isCancelled else { return }
                lastChecked = Date()
                status = "暂时无法检查更新，可稍后重试"
            }
        }
    }
    func openDownload() {
        guard available, let url = latest?.safeURL else { return }
        NSWorkspace.shared.open(url)
    }
}
