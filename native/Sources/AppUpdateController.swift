import AppKit
import Combine
import SwiftUI

struct AppRelease: Decodable, Sendable {
    let tag_name: String
    let html_url: URL
    let draft: Bool
    let prerelease: Bool
    var body: String? = nil
    var assets: [AppReleaseAsset]? = nil
    var safeURL: URL? {
        guard !draft, html_url.scheme == "https", html_url.host == "github.com",
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
    @Published private(set) var status = "启动后及每 8 小时检查更新"
    @Published private(set) var lastChecked: Date?
    @Published private(set) var downloading = false
    @Published private(set) var readyToInstall = false
    @Published private(set) var installing = false
    @Published private(set) var installationReport: String?
    @Published var acceptsPrereleases: Bool {
        didSet {
            defaults.set(acceptsPrereleases, forKey: "updates.accepts-prereleases.v1")
            if oldValue != acceptsPrereleases {
                task?.cancel(); task = nil; checking = false; latest = nil; check()
            }
        }
    }
    let currentVersion: String
    private let defaults: UserDefaults
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var downloadTask: Task<Void, Never>?
    private var preparedApp: URL?
    private var workDirectory: URL?
    private var installerProcess: Process?
    private var window: NSWindow?
    init(version: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.10", defaults: UserDefaults = .standard) {
        currentVersion = version; self.defaults = defaults
        acceptsPrereleases = defaults.bool(forKey: "updates.accepts-prereleases.v1")
        let result = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CodexUsageBar/updates/result.txt")
        if let text = try? String(contentsOf: result, encoding: .utf8) {
            status = text.trimmingCharacters(in: .whitespacesAndNewlines)
            installationReport = status
            try? FileManager.default.removeItem(at: result)
        }
    }
    var available: Bool { latest?.safeURL != nil && AppRelease.newer(latest!.tag_name, than: currentVersion) }
    var matchingArchive: AppReleaseAsset? { latest.flatMap { AppUpdateInstaller.archive(for: $0) } }
    var busy: Bool { downloading || installing }
    static func select(_ releases: [AppRelease], current: String, includePrereleases: Bool) -> AppRelease? {
        releases.filter { $0.safeURL != nil && (!$0.prerelease || includePrereleases) && AppRelease.version($0.tag_name) != nil }
            .sorted { AppRelease.newer($0.tag_name, than: $1.tag_name) }.first
    }
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
    func stop() {
        timer?.invalidate(); timer = nil; task?.cancel(); task = nil
        downloadTask?.cancel(); downloadTask = nil; checking = false
    }
    func check() {
        guard !checking, !busy, !readyToInstall else { return }
        checking = true; status = "正在检查更新…"
        let include = acceptsPrereleases
        task = Task { [weak self] in
            guard let self else { return }
            defer { if !Task.isCancelled { checking = false; task = nil } }
            do {
                let endpoint = include ? URL(string: "https://api.github.com/repos/1078302479/codex-usage-bar/releases?per_page=100")! : Self.endpoint
                let data = try await fetch(endpoint, limit: 8_000_000)
                try Task.checkCancellation()
                let releases = include ? try JSONDecoder().decode([AppRelease].self, from: data) : [try JSONDecoder().decode(AppRelease.self, from: data)]
                latest = Self.select(releases, current: currentVersion, includePrereleases: include)
                lastChecked = Date()
                if readyToInstall { status = "已校验，准备安装并重启" }
                else if available && matchingArchive == nil { status = "发现新版本，但尚未提供当前机型的安装包。" }
                else { status = available ? "发现新版本 " + (latest?.tag_name ?? "") : "当前通道暂无更新" }
            } catch {
                guard !Task.isCancelled else { return }
                lastChecked = Date(); status = "暂时无法检查更新，可稍后重试"
            }
        }
    }
    private func fetch(_ url: URL, limit: Int) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("CodexUsageBar/" + currentVersion, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= limit else { throw UpdateFailure.invalid("下载失败或文件过大，请重试。") }
        return data
    }
    func download() {
        guard available, !busy, !readyToInstall, let release = latest else { return }
        guard let asset = matchingArchive,
              let sums = release.assets?.first(where: { $0.name == "SHA256SUMS.txt" && AppUpdateInstaller.validAsset($0, tag: release.tag_name) }) else {
            status = "此版本没有匹配当前机型的 ZIP 安装包或校验文件。"; return
        }
        downloading = true; status = "正在下载 " + asset.name + "…"
        downloadTask = Task { [weak self] in
            guard let self else { return }
            var directory: URL?
            defer { downloading = false; downloadTask = nil }
            do {
                let checksums = try await fetch(sums.browser_download_url, limit: 100_000)
                let expected = try AppUpdateInstaller.checksum(String(decoding: checksums, as: UTF8.self), filename: asset.name)
                if let digest = asset.digest, digest != "sha256:" + expected { throw UpdateFailure.invalid("发布资产校验值不一致。") }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CodexUsageBar-update-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                directory = dir
                let request = URLRequest(url: asset.browser_download_url, timeoutInterval: 180)
                let (downloaded, response) = try await URLSession.shared.download(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure.invalid("安装包下载失败，请重试。") }
                try Task.checkCancellation()
                let archive = dir.appendingPathComponent(asset.name)
                try FileManager.default.moveItem(at: downloaded, to: archive)
                let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize
                guard size == asset.size else { throw UpdateFailure.invalid("安装包大小不一致，已停止更新。") }
                status = "正在校验并解压安装包…"
                let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
                let app = try await Task.detached {
                    try AppUpdateInstaller.verify(archive, expected: expected)
                    return try AppUpdateInstaller.unpackAndValidate(archive: archive, directory: dir.appendingPathComponent("extracted"), version: version)
                }.value
                try Task.checkCancellation()
                preparedApp = app; workDirectory = dir; readyToInstall = true
                status = "SHA-256、应用身份、版本、签名和架构校验通过。可安装并重启。"
            } catch {
                if let directory { try? FileManager.default.removeItem(at: directory) }
                status = Task.isCancelled ? "已取消下载" : error.localizedDescription
            }
        }
    }
    func cancelDownload() { downloadTask?.cancel() }
    func install() {
        guard readyToInstall, !busy, let app = preparedApp, let directory = workDirectory else { return }
        installing = true; status = "正在准备安装，请保存任务…"
        do {
            let helper = try AppUpdateInstaller.prepareInstall(app: app, target: Bundle.main.bundleURL, workDirectory: directory, pid: ProcessInfo.processInfo.processIdentifier)
            try helper.run(); installerProcess = helper
            status = "正在退出并安装更新…"
            NSApplication.shared.terminate(nil)
        } catch { installing = false; status = error.localizedDescription }
    }
    func openDownload() {
        if let window { window.makeKeyAndOrderFront(nil); NSApplication.shared.activate(ignoringOtherApps: true); return }
        let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 540), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.title = "CodexUsageBar 更新"; panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: AppUpdateDetailView(updates: self))
        panel.center(); panel.makeKeyAndOrderFront(nil); window = panel
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
