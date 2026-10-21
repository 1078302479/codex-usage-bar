import Foundation
import Combine

enum SettingsTab: Hashable { case menuBar, connection, appearance }

@MainActor
final class AppState: ObservableObject {
    let loginItem = LoginItemController()
    @Published var panelHeight: CGFloat = 800
    @Published var settingsTab: SettingsTab = .menuBar
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
                invalidateConnection()
                clearAccount()
                lastFailure = nil; retryAttempt = 0
                scheduleRefresh(reason: "更换 Codex", delay: 0)
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
    @Published var now = Date()
    @Published var lastClientChange: Date?
    @Published var lastReason = "启动核验"
    @Published var watchingClient = false
    @Published var cliDraft = ""
    @Published private(set) var lastFailure: CodexFailure?
    @Published private(set) var lastSuccessfulAt: Date?
    @Published private(set) var nextRetryAt: Date?
    @Published private(set) var paused = false
    var onDisplayChange: (() -> Void)?

    private let defaults: UserDefaults
    private let client: any QuotaClient
    private let recovery: RecoveryPolicy
    private var watcher: ClientLogMonitor?
    private var connectivity: ConnectivityMonitor?
    private var networkAvailable: Bool?
    private var pollTimer: Timer?
    private var clockTimer: Timer?
    private var resetTimer: Timer?
    private var scheduledRefresh: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var connectionBarrier: Task<Void, Never>?
    private var activeRequest: UUID?
    private var queuedReason: String?
    private var disconnectDuringRefresh: CodexFailure?
    private var configurationEpoch = 0
    private var retryAttempt = 0
    private var resetKey = ""
    private var resetAttempts = 0
    private var started = false

    init(defaults: UserDefaults = .standard, client: any QuotaClient = CodexClient(), recovery: RecoveryPolicy = RecoveryPolicy()) {
        precondition(!recovery.retryDelays.isEmpty && recovery.retryDelays.allSatisfy { $0 > 0 && $0.isFinite })
        self.defaults = defaults; self.client = client; self.recovery = recovery
        if let data = defaults.data(forKey: "preferences.v1"), let saved = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = saved }
        else { preferences = Preferences() }
        if let data = defaults.data(forKey: "quota-cache.v1") { snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data) }
    }

    var bucket: QuotaBucket? { QuotaPresentation.selectedBucket(snapshot, preferences: preferences) }
    var menuTitle: String { QuotaPresentation.menuTitle(snapshot: snapshot, preferences: preferences, verified: verified, now: now) }
    var isStale: Bool { snapshot.map { now.timeIntervalSince($0.observedAt) > QuotaPresentation.staleAfter } ?? false }
    var errorMessage: String? { lastFailure?.localizedDescription }
    var updateStatus: UpdateStatus {
        if paused { return .sleeping }
        if isRefreshing { return .checking }
        if let lastFailure { return .failed(lastFailure) }
        guard verified else { return .waiting }
        if [bucket?.primary, bucket?.secondary].contains(where: { $0?.isResetPending(at: now) == true }) { return .resetPending }
        return isStale ? .stale : .verified
    }
    var statusDetail: String {
        let detail: String
        switch updateStatus {
        case .sleeping: detail = "已暂停查询，唤醒后重新核验。"
        case .checking: detail = "正在向服务商核验当前登录账号与额度。"
        case .waiting: detail = "尚未取得当前账号的有效额度，可点击刷新。"
        case .verified: detail = "额度已由服务商确认；其他设备的变化需等下一次核验。"
        case .stale: detail = "超过 5 分钟未成功核验，显示上次记录；菜单栏以 * 标记。"
        case .resetPending: detail = "预计重置时间已到，等待服务商确认，不自动补为 100%。"
        case .failed(let failure): detail = failure.localizedDescription
        }
        if let nextRetryAt {
            let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.timeZone = TimeZone(identifier: "Asia/Shanghai"); f.dateFormat = "HH:mm:ss"
            return detail + " 下次自动重试 " + f.string(from: nextRetryAt) + "。"
        }
        return detail
    }
    var watchDescription: String {
        if preferences.refreshMode != .followClient { return preferences.refreshMode.title + "向服务商核验" }
        return watchingClient ? "跟随客户端额度变化，收到变化后向服务商核验" : "未发现本机日志；启动、打开面板和唤醒时核验"
    }
    var timestampLabel: String {
        if let date = lastSuccessfulAt { return "最近成功核验 " + QuotaPresentation.time(date) }
        if let date = snapshot?.observedAt { return "上次缓存 " + QuotaPresentation.time(date) + "（本次尚未核验）" }
        return "尚无成功核验记录"
    }

    func start() {
        guard !started else { return }
        started = true; paused = false
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let monitor = ClientLogMonitor(root: home.appendingPathComponent("sessions")) { [weak self] date in
            Task { @MainActor in
                guard let self else { return }
                self.lastClientChange = date
                if self.preferences.refreshMode == .followClient { self.scheduleRefresh(reason: "客户端额度变化", delay: self.recovery.mergeDelay) }
            }
        }
        watcher = monitor; watchingClient = monitor.start()
        let network = ConnectivityMonitor { [weak self] available in Task { @MainActor in self?.networkChanged(available: available) } }
        connectivity = network; network.start()
        configureClock(); configurePolling()
        refresh(reason: "启动核验")
    }

    private func handle(_ signal: CodexSignal) {
        guard !paused else { return }
        switch signal {
        case .quotaChanged:
            if preferences.refreshMode == .followClient { scheduleRefresh(reason: "额度变化通知", delay: recovery.mergeDelay) }
        case .accountChanged:
            invalidateConnection(); clearAccount(); lastFailure = nil; retryAttempt = 0
            onDisplayChange?(); scheduleRefresh(reason: "登录状态变化", delay: recovery.mergeDelay)
        case .disconnected(let failure):
            if isRefreshing { disconnectDuringRefresh = failure }
            else if lastFailure?.canRetry != false { recordFailure(failure) }
        }
    }

    func networkChanged(available: Bool) {
        let previous = networkAvailable
        networkAvailable = available
        guard previous == false, available, !paused, lastFailure?.canRetry == true, !isRefreshing else { return }
        cancelRetry()
        scheduleRefresh(reason: "网络恢复核验", delay: recovery.mergeDelay)
    }

    func scheduleRefresh(reason: String, delay: TimeInterval) {
        guard !paused, lastFailure?.canRetry != false, nextRetryAt == nil else { return }
        // Debounce the first event rather than postponing indefinitely during a burst.
        guard scheduledRefresh == nil else { return }
        let epoch = configurationEpoch
        scheduledRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation() } catch { return }
            guard let self, epoch == self.configurationEpoch, !self.paused else { return }
            self.scheduledRefresh = nil
            self.refresh(reason: reason)
        }
    }

    func panelOpened() {
        guard !isRefreshing, lastFailure?.canRetry != false, nextRetryAt == nil else { return }
        if !verified || snapshot.map({ Date().timeIntervalSince($0.observedAt) > 15 }) != false { refresh(reason: "打开面板核验") }
    }

    func refresh(reason: String = "手动核验") {
        guard !paused else { return }
        let manual = reason == "手动核验" || reason == "应用连接设置"
        guard manual || (lastFailure?.canRetry != false && nextRetryAt == nil) else { return }
        if isRefreshing {
            if manual || queuedReason == nil { queuedReason = reason }
            return
        }
        scheduledRefresh?.cancel(); scheduledRefresh = nil
        if manual { cancelRetry(); retryAttempt = 0 }
        isRefreshing = true; lastReason = reason; now = Date(); disconnectDuringRefresh = nil
        onDisplayChange?()
        let epoch = configurationEpoch; let custom = preferences.cliPath; let request = UUID()
        activeRequest = request
        let barrier = connectionBarrier
        refreshTask = Task { [weak self, client] in
            guard let self else { return }
            await barrier?.value
            guard isCurrent(request, epoch: epoch) else { return }
            connectionBarrier = nil
            await client.setHandler { [weak self] signal in
                Task { @MainActor in
                    guard let self, self.configurationEpoch == epoch else { return }
                    self.handle(signal)
                }
            }
            do {
                try Task.checkCancellation()
                let result = try await client.fetch(customPath: custom)
                guard isCurrent(request, epoch: epoch) else { return }
                if snapshot?.accountScope != result.accountScope { tokenActivity = nil; activityUpdatedAt = nil; activityError = nil }
                snapshot = result; verified = true; lastFailure = nil; lastSuccessfulAt = result.observedAt; now = Date()
                cancelRetry()
                if result.accountScope != nil, let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: "quota-cache.v1") }
                configureResetCheck()
                if let scope = result.accountScope,
                   manual || activityUpdatedAt.map({ Date().timeIntervalSince($0) >= 300 }) != false {
                    do {
                        try Task.checkCancellation()
                        let activity = try await client.fetchUsage(expectedScope: scope)
                        guard isCurrent(request, epoch: epoch), snapshot?.accountScope == scope else { return }
                        tokenActivity = activity; activityUpdatedAt = Date(); activityError = nil
                    } catch {
                        guard isCurrent(request, epoch: epoch) else { return }
                        let failure = Self.failure(error)
                        activityError = failure == .unsupported ? "当前 Codex 不支持官方 Token 活动；额度核验不受影响。" : "官方 Token 活动暂不可用，可点击刷新重试。"
                        if failure == .accountChanged || failure == .authRequired { recordFailure(failure) }
                        else if failure.canRetry { recordFailure(failure, invalidateQuota: false) }
                    }
                }
            } catch {
                guard isCurrent(request, epoch: epoch) else { return }
                recordFailure(Self.failure(error))
            }
            guard isCurrent(request, epoch: epoch) else { return }
            isRefreshing = false; activeRequest = nil; refreshTask = nil
            if lastFailure == nil, let failure = disconnectDuringRefresh { recordFailure(failure) }
            disconnectDuringRefresh = nil
            let followup = queuedReason; queuedReason = nil
            if lastFailure == nil { retryAttempt = 0 }
            onDisplayChange?()
            if lastFailure == nil, let followup { scheduleRefresh(reason: followup, delay: recovery.mergeDelay) }
        }
    }

    private func isCurrent(_ request: UUID, epoch: Int) -> Bool {
        !paused && !Task.isCancelled && configurationEpoch == epoch && activeRequest == request
    }

    private static func failure(_ error: Error) -> CodexFailure {
        if let failure = error as? CodexFailure { return failure }
        if let urlError = error as? URLError { return urlError.code == .timedOut ? .timeout : .networkUnavailable }
        return .invalidResponse
    }

    private func recordFailure(_ failure: CodexFailure, invalidateQuota: Bool = true) {
        lastFailure = failure; now = Date()
        if invalidateQuota { verified = false }
        resetTimer?.invalidate(); resetTimer = nil
        scheduledRefresh?.cancel(); scheduledRefresh = nil
        queuedReason = nil
        if failure == .authRequired || failure == .accountChanged { clearAccount() }
        if failure.canRetry { scheduleRetry() } else { cancelRetry() }
        onDisplayChange?()
    }

    private func scheduleRetry() {
        guard !paused, retryTask == nil else { return }
        let delay = recovery.delay(at: retryAttempt); retryAttempt = min(retryAttempt + 1, recovery.retryDelays.count - 1)
        nextRetryAt = Date().addingTimeInterval(delay)
        let epoch = configurationEpoch
        retryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)); try Task.checkCancellation() } catch { return }
            guard let self, !self.paused, self.configurationEpoch == epoch else { return }
            self.retryTask = nil; self.nextRetryAt = nil
            self.refresh(reason: "自动恢复核验")
        }
    }

    private func cancelRetry() {
        retryTask?.cancel(); retryTask = nil; nextRetryAt = nil
    }

    private func clearAccount() {
        verified = false; snapshot = nil; tokenActivity = nil; activityUpdatedAt = nil; activityError = nil; lastSuccessfulAt = nil
        defaults.removeObject(forKey: "quota-cache.v1")
    }

    private func invalidateConnection() {
        configurationEpoch += 1
        scheduledRefresh?.cancel(); scheduledRefresh = nil; cancelRetry()
        refreshTask?.cancel(); refreshTask = nil; activeRequest = nil; isRefreshing = false
        queuedReason = nil; disconnectDuringRefresh = nil
        resetTimer?.invalidate(); resetTimer = nil
        // New requests wait for all older shutdowns; an old task cannot kill a new process.
        let previous = connectionBarrier
        connectionBarrier = Task { [client] in
            await previous?.value
            await client.setHandler { _ in }
            await client.shutdown()
        }
    }

    private func configureClock() {
        clockTimer?.invalidate()
        guard !paused else { clockTimer = nil; return }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date(); self?.onDisplayChange?() }
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
        guard !paused else { return }
        paused = true; verified = false; invalidateConnection()
        clockTimer?.invalidate(); clockTimer = nil; pollTimer?.invalidate(); pollTimer = nil
        now = Date(); onDisplayChange?()
    }
    func resume() {
        guard paused else { return }
        paused = false; verified = false; now = Date()
        configureClock(); configurePolling(); scheduleRefresh(reason: "唤醒核验", delay: recovery.wakeDelay)
        onDisplayChange?()
    }
    func stop() async {
        paused = true; invalidateConnection()
        watcher?.stop(); watcher = nil; watchingClient = false
        connectivity?.stop(); connectivity = nil
        clockTimer?.invalidate(); clockTimer = nil; pollTimer?.invalidate(); pollTimer = nil
        await connectionBarrier?.value
        connectionBarrier = nil; started = false
    }
}
