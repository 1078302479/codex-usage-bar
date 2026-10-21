import Foundation
import Combine

@MainActor
final class AppState: ObservableObject {
    let loginItem = LoginItemController()
    @Published var panelHeight: CGFloat = 800
    var panelContentHeight: CGFloat = 0
    var panelPreferredHeight: CGFloat?
    var panelDragStart: CGFloat?
    var onPanelResize: ((CGFloat?) -> Void)?
    func panelContentMeasured(_ height: CGFloat) {
        guard height.isFinite, height > 0, abs(panelContentHeight - height) > 1 else { return }
        panelContentHeight = height
        onPanelResize?(nil)
    }

    @Published var preferences: Preferences {
        didSet {
            if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences.v1") }
            if oldValue.refreshMode != preferences.refreshMode { configurePolling() }
            if oldValue.selectedBucket != preferences.selectedBucket { configureResetCheck() }
            if oldValue.cliPath != preferences.cliPath {
                configurationEpoch += 1; verified = false; snapshot = nil; tokenActivity = nil; activityUpdatedAt = nil; activityError = nil; errorMessage = nil
                defaults.removeObject(forKey: "quota-cache.v1")
                Task { await client.shutdown(); await MainActor.run { self.scheduleRefresh(reason: "更换 Codex", delay: 0) } }
            }
            onDisplayChange?()
        }
    }
    @Published var tokenActivity: TokenActivity?
    @Published var activityError: String?
    @Published var activityUpdatedAt: Date?
    @Published var snapshot: QuotaSnapshot?
    @Published var verified = false
    @Published var isRefreshing = false
    @Published var errorMessage: String?
    @Published var now = Date()
    @Published var lastClientChange: Date?
    @Published var lastReason = "启动核验"
    @Published var watchingClient = false
    @Published var cliDraft = ""
    var onDisplayChange: (() -> Void)?

    private let defaults: UserDefaults
    private let client = CodexClient()
    private var watcher: ClientLogMonitor?
    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var resetTimer: Timer?
    private var scheduledRefresh: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var needsAnotherRefresh = false
    private var configurationEpoch = 0
    private var resetKey = ""
    private var resetAttempts = 0
    private var paused = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: "preferences.v1"), let saved = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = saved }
        else { preferences = Preferences() }
        if let data = defaults.data(forKey: "quota-cache.v1") { snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data) }
    }

    var bucket: QuotaBucket? { QuotaPresentation.selectedBucket(snapshot, preferences: preferences) }
    var menuTitle: String { QuotaPresentation.menuTitle(snapshot: snapshot, preferences: preferences, verified: verified, now: now) }
    var isStale: Bool { snapshot.map { now.timeIntervalSince($0.observedAt) > QuotaPresentation.staleAfter } ?? false }
    var watchDescription: String {
        if preferences.refreshMode != .followClient { return preferences.refreshMode.title + "向服务商核验" }
        return watchingClient ? "跟随客户端额度变化，收到变化后向服务商核验" : "未发现本机日志；启动、打开面板和唤醒时核验"
    }
    var timestampLabel: String {
        guard let date = snapshot?.observedAt else { return "尚未取得额度" }
        return "最近核验 " + QuotaPresentation.time(date)
    }

    func start() {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let monitor = ClientLogMonitor(root: home.appendingPathComponent("sessions")) { [weak self] date in
            Task { @MainActor in
                guard let self else { return }
                self.lastClientChange = date
                if self.preferences.refreshMode == .followClient { self.scheduleRefresh(reason: "客户端额度变化", delay: 1) }
            }
        }
        watcher = monitor; watchingClient = monitor.start()
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date(); self?.onDisplayChange?() }
        }
        configurePolling()
        Task { [weak self] in
            guard let self else { return }
            await client.setHandler { [weak self] signal in Task { @MainActor in self?.handle(signal) } }
            refresh(reason: "启动核验")
        }
    }

    private func handle(_ signal: CodexSignal) {
        guard !paused else { return }
        switch signal {
        case .quotaChanged:
            if preferences.refreshMode == .followClient { scheduleRefresh(reason: "额度变化通知", delay: 1) }
        case .accountChanged:
            configurationEpoch += 1; verified = false; snapshot = nil; tokenActivity = nil; activityUpdatedAt = nil; activityError = nil
            defaults.removeObject(forKey: "quota-cache.v1")
            onDisplayChange?(); scheduleRefresh(reason: "登录状态变化", delay: 0.8)
        case .disconnected:
            if !isRefreshing { verified = false; errorMessage = CodexFailure.processStopped.localizedDescription; onDisplayChange?() }
        }
    }

    func scheduleRefresh(reason: String, delay: TimeInterval) {
        guard !paused else { return }
        scheduledRefresh?.cancel()
        scheduledRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.refresh(reason: reason)
        }
    }

    func panelOpened() {
        guard !isRefreshing else { return }
        if !verified || snapshot.map({ Date().timeIntervalSince($0.observedAt) > 15 }) != false { refresh(reason: "打开面板核验") }
    }

    func refresh(reason: String = "手动核验") {
        guard !paused else { return }
        if isRefreshing { needsAnotherRefresh = true; return }
        isRefreshing = true; lastReason = reason; onDisplayChange?()
        let epoch = configurationEpoch; let custom = preferences.cliPath
        refreshTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await client.fetch(customPath: custom)
                if epoch == configurationEpoch && !paused {
                    if snapshot?.accountScope != result.accountScope { tokenActivity = nil; activityUpdatedAt = nil }
                    snapshot = result; verified = true; errorMessage = nil; now = Date()
                    if result.accountScope != nil, let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: "quota-cache.v1") }
                    configureResetCheck()
                    // Token activity aggregates update more slowly than quota. Revalidate on
                    // manual refresh, otherwise reuse a same-account result for five minutes.
                    if let scope = result.accountScope,
                       reason == "手动核验" || activityUpdatedAt.map({ Date().timeIntervalSince($0) >= 300 }) != false {
                        do {
                            let activity = try await client.fetchUsage(expectedScope: scope)
                            if epoch == configurationEpoch && !paused && snapshot?.accountScope == scope {
                                tokenActivity = activity; activityUpdatedAt = Date(); activityError = nil
                            }
                        } catch {
                            if epoch == configurationEpoch && !paused {
                                if (error as? CodexFailure) == .accountChanged {
                                    tokenActivity = nil; activityUpdatedAt = nil; verified = false; snapshot = nil
                                    defaults.removeObject(forKey: "quota-cache.v1"); needsAnotherRefresh = true
                                }
                                activityError = "暂时无法读取官方 Token 活动；可点击刷新重试。需要支持 account/usage/read 的 Codex 版本。"
                            }
                        }
                    }
                } else { needsAnotherRefresh = true }
            } catch {
                if epoch == configurationEpoch && !paused {
                    verified = false
                    errorMessage = (error as? CodexFailure)?.localizedDescription ?? CodexFailure.invalidResponse.localizedDescription
                    if let failure = error as? CodexFailure, failure == .authRequired || failure == .accountChanged {
                        snapshot = nil; defaults.removeObject(forKey: "quota-cache.v1")
                        if failure == .accountChanged { needsAnotherRefresh = true }
                    }
                }
            }
            isRefreshing = false; onDisplayChange?()
            if needsAnotherRefresh && !paused { needsAnotherRefresh = false; scheduleRefresh(reason: "合并后续更新", delay: 1) }
        }
    }

    private func configurePolling() {
        pollTimer?.invalidate(); pollTimer = nil
        guard !paused, let interval = preferences.refreshMode.interval else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(reason: "定时核验") }
        }
    }

    private func configureResetCheck() {
        resetTimer?.invalidate(); resetTimer = nil
        guard verified, let bucket, !paused else { return }
        let dates = [bucket.primary?.resetDate, bucket.secondary?.resetDate].compactMap { $0 }
        let key = bucket.id + dates.map { String($0.timeIntervalSince1970) }.joined(separator: "|")
        if resetKey != key { resetKey = key; resetAttempts = 0 }
        let elapsed = dates.contains { $0 <= Date() }
        let next = elapsed && resetAttempts < 3 ? Date().addingTimeInterval(30) : dates.filter { $0 > Date() }.min()
        guard let next else { return }
        resetTimer = Timer.scheduledTimer(withTimeInterval: max(1, next.timeIntervalSinceNow + 1), repeats: false) { [weak self] _ in
            Task { @MainActor in guard let self else { return }; self.resetAttempts += 1; self.refresh(reason: "重置边界核验") }
        }
    }

    func pause() {
        paused = true; scheduledRefresh?.cancel(); pollTimer?.invalidate(); resetTimer?.invalidate()
        Task { await client.shutdown() }
    }
    func resume() {
        paused = false; verified = false; configurePolling(); scheduleRefresh(reason: "唤醒核验", delay: 2)
    }
    func stop() async {
        paused = true; watcher?.stop(); clockTimer?.invalidate(); pollTimer?.invalidate(); resetTimer?.invalidate(); scheduledRefresh?.cancel()
        await client.shutdown()
    }
}
