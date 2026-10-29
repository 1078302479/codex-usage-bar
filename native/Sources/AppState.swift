import Foundation
import Combine
import AppKit

enum SettingsTab: Hashable { case menuBar, connection, reminders, appearance }

@MainActor
final class AppState: ObservableObject {
    let loginItem = LoginItemController()
    let reminders: ResetCreditReminderController
    @Published var panelHeight: CGFloat = 800
    @Published var settingsTab: SettingsTab = .menuBar
    @Published var resetCreditsExpanded = false
    @Published var showingSecondAccountDetails = false {
        didSet {
            guard oldValue != showingSecondAccountDetails else { return }
            onDisplayChange?()
        }
    }
    var displayedAccount: AppState { showingSecondAccountDetails ? (secondAccount ?? self) : self }
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
                cancelSignIn()
                invalidateConnection()
                clearAccount()
                lastFailure = nil; retryAttempt = 0
                scheduleRefresh(reason: "更换 Codex", delay: 0)
            }
            if let secondAccount, secondAccount.preferences != preferences { secondAccount.preferences = preferences }
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
    @Published private(set) var secondAccount: AppState?
    @Published private(set) var isSigningIn = false
    @Published private(set) var loginMessage: String?
    private var loginTask: Task<Void, Never>?
    private var loginExpiry: Task<Void, Never>?
    private let codexHome: URL?
    private let loginOpener: (URL) -> Bool
    private let secondaryFactory: (() -> AppState)?
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
    private var creditCheckTimer: Timer?
    private var scheduledRefresh: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var connectionBarrier: Task<Void, Never>?
    private var activeRequest: UUID?
    private var queuedReason: String?
    private var disconnectDuringRefresh: CodexFailure?
    private var configurationEpoch = 0
    private var accountEpoch = 0
    private var retryAttempt = 0
    private var authRecoveryAfter: Date?
    private var resetKey = ""
    private var resetAttempts = 0
    private var started = false
    private(set) var panelVisible = false
    var quotaPollInterval: TimeInterval { preferences.refreshMode.interval ?? (panelVisible ? 15 : 60) }

    static var secondAccountHome: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexUsageBar/accounts/secondary", isDirectory: true)
    }

    func setSecondAccountEnabled(_ enabled: Bool) {
        guard codexHome == nil else { return }
        defaults.set(enabled, forKey: "second-account.enabled.v1")
        if enabled, secondAccount == nil {
            let home = Self.secondAccountHome
            let secondary: AppState
            if let secondaryFactory { secondary = secondaryFactory() }
            else {
                let saved = UserDefaults(suiteName: "com.guoyuming.UsageBar.second-account")!
                secondary = AppState(defaults: saved, client: CodexClient(codexHome: home),
                    reminderCenter: MonitoringOnlyReminderCenter(), codexHome: home)
            }
            secondary.preferences = preferences
            secondary.onDisplayChange = { [weak self] in self?.onDisplayChange?() }
            secondAccount = secondary
            if started { secondary.start() }
            secondary.setPanelVisible(panelVisible)
        } else if !enabled, let secondary = secondAccount {
            showingSecondAccountDetails = false
            secondAccount = nil
            secondary.onDisplayChange = nil
            Task { await secondary.stop() }
        }
        onDisplayChange?()
    }

    func signInSecondAccount() {
        guard codexHome != nil, !isSigningIn, !paused else { return }
        invalidateConnection(); clearAccount()
        lastFailure = nil; isSigningIn = true; loginMessage = "正在打开官方登录页面，请选择另一个账号。"
        onDisplayChange?()
        let epoch = configurationEpoch
        let barrier = connectionBarrier
        loginTask = Task { [weak self, client] in
            guard let self else { return }
            await barrier?.value
            guard !Task.isCancelled, configurationEpoch == epoch, isSigningIn else { return }
            connectionBarrier = nil
            await client.setHandler { [weak self] signal in
                Task { @MainActor in
                    guard let self, self.configurationEpoch == epoch else { return }
                    self.handle(signal)
                }
            }
            do {
                let url = try await client.beginLogin(customPath: preferences.cliPath)
                guard !Task.isCancelled, configurationEpoch == epoch, isSigningIn else { return }
                guard loginOpener(url) else { throw CodexFailure.serviceUnavailable }
                loginMessage = "请在浏览器完成第二账号登录；本机原账号不受影响。"
                loginExpiry = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(600)) } catch { return }
                    self?.cancelSignIn()
                    self?.loginMessage = "登录等待已超时，请重试。"
                }
            } catch {
                guard configurationEpoch == epoch, !Task.isCancelled else { return }
                isSigningIn = false
                loginMessage = "无法开始官方登录，请检查 Codex 版本或连接后重试。"
                recordFailure(Self.failure(error))
            }
        }
    }

    func cancelSignIn() {
        guard isSigningIn else { return }
        loginTask?.cancel(); loginTask = nil; loginExpiry?.cancel(); loginExpiry = nil
        isSigningIn = false; loginMessage = "已取消登录。"
        invalidateConnection()
        recordFailure(.authRequired)
    }

    func refreshAllAccounts() {
        refresh()
        secondAccount?.refresh()
    }

    init(defaults: UserDefaults = .standard, client: any QuotaClient = CodexClient(), recovery: RecoveryPolicy = RecoveryPolicy(), reminderCenter: any ReminderNotificationCenter = SystemReminderCenter(), codexHome: URL? = nil,
         loginOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }, secondaryFactory: (() -> AppState)? = nil) {
        precondition(!recovery.retryDelays.isEmpty && recovery.retryDelays.allSatisfy { $0 > 0 && $0.isFinite })
        self.defaults = defaults; self.client = client; self.recovery = recovery
        self.codexHome = codexHome
        self.loginOpener = loginOpener; self.secondaryFactory = secondaryFactory
        reminders = ResetCreditReminderController(defaults: defaults, center: reminderCenter)
        if let data = defaults.data(forKey: "preferences.v1"), let saved = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = saved }
        else { preferences = Preferences() }
        if let data = defaults.data(forKey: "quota-cache.v1") { snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data) }
        reminders.onConfigurationChange = { [weak self] in self?.configureCreditCheck() }
        reminders.onNeedsRefresh = { [weak self] in self?.scheduleRefresh(reason: "重置卡提醒核验", delay: 0) }
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
        return (watchingClient ? "跟随客户端额度变化；" : "未发现本机日志；") + "面板显示时每 15 秒、后台每 60 秒补充核验额度"
    }
    var timestampLabel: String {
        if let date = lastSuccessfulAt { return "最近成功核验 " + QuotaPresentation.time(date) }
        if let date = snapshot?.observedAt { return "上次缓存 " + QuotaPresentation.time(date) + "（本次尚未核验）" }
        return "尚无成功核验记录"
    }

    func start() {
        guard !started else { return }
        started = true; paused = false
        reminders.start()
        let home = codexHome ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
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
        if codexHome == nil, defaults.bool(forKey: "second-account.enabled.v1") { setSecondAccountEnabled(true) }
    }

    private func handle(_ signal: CodexSignal) {
        guard !paused else { return }
        switch signal {
        case .loginCompleted(let success):
            guard isSigningIn else { return }
            isSigningIn = false; loginExpiry?.cancel(); loginExpiry = nil
            loginMessage = success ? "登录完成，正在核验第二账号。" : "登录未完成，请重试。"
            if success { lastFailure = nil; refresh(reason: "登录完成核验") }
            else { recordFailure(.authRequired) }
        case .quotaChanged:
            if preferences.refreshMode == .followClient { scheduleRefresh(reason: "额度变化通知", delay: recovery.mergeDelay) }
        case .accountChanged:
            // App Server also emits account/updated during initialization. Keep
            // this connection alive; invalidate its in-flight data and revalidate
            // on the same connection instead of restarting initialization forever.
            accountEpoch += 1
            clearAccount(); lastFailure = nil; retryAttempt = 0; cancelRetry()
            resetTimer?.invalidate(); resetTimer = nil
            scheduledRefresh?.cancel(); scheduledRefresh = nil
            if isRefreshing { queuedReason = "登录状态变化" }
            else { scheduleRefresh(reason: "登录状态变化", delay: recovery.mergeDelay) }
            onDisplayChange?()
        case .disconnected(let failure):
            if isSigningIn { isSigningIn = false; loginExpiry?.cancel(); loginMessage = "登录连接已断开，请重新登录。" }
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
        if !verified || snapshot.map({ Date().timeIntervalSince($0.observedAt) > 2 }) != false { refresh(reason: "打开面板核验") }
    }

    func setPanelVisible(_ visible: Bool) {
        guard panelVisible != visible else { return }
        panelVisible = visible
        secondAccount?.setPanelVisible(visible)
        configurePolling()
    }

    func pollQuota(at date: Date = Date()) {
        // Login can change in another Codex process without notifying this one.
        // Recreate only the failed auth session, at most once per minute.
        if lastFailure == .authRequired, !paused, !isRefreshing,
           let after = authRecoveryAfter, date >= after {
            invalidateConnection()
            lastFailure = nil
            authRecoveryAfter = nil
            refresh(reason: "重新读取登录状态")
            return
        }
        refresh(reason: preferences.refreshMode == .followClient ? "兜底额度核验" : "定时核验")
    }

    func refresh(reason: String = "手动核验") {
        guard !paused, !isSigningIn else { return }
        let manual = reason == "手动核验" || reason == "应用连接设置"
        guard manual || (lastFailure?.canRetry != false && nextRetryAt == nil) else { return }
        if isRefreshing {
            if manual || queuedReason == nil { queuedReason = reason }
            return
        }
        if manual {
            // A different CLI/desktop process may have switched accounts. Do not
            // retry against the old app-server's in-memory authentication.
            invalidateConnection()
            clearAccount()
            authRecoveryAfter = nil
        }
        scheduledRefresh?.cancel(); scheduledRefresh = nil
        if manual { cancelRetry(); retryAttempt = 0 }
        isRefreshing = true; lastReason = reason; now = Date(); disconnectDuringRefresh = nil
        onDisplayChange?()
        let epoch = configurationEpoch; let identity = accountEpoch
        let custom = preferences.cliPath; let request = UUID()
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
                guard identity == accountEpoch else { finishRefresh(request, epoch: epoch); return }
                if snapshot?.accountScope != result.accountScope { tokenActivity = nil; activityUpdatedAt = nil; activityError = nil }
                snapshot = result; verified = true; lastFailure = nil; authRecoveryAfter = nil; lastSuccessfulAt = result.observedAt; now = Date()
                if codexHome != nil { loginMessage = "账号 B 已核验。" }
                reminders.update(snapshot: result, verified: true)
                configureCreditCheck()
                cancelRetry()
                if result.accountScope != nil, let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: "quota-cache.v1") }
                configureResetCheck()
                if reason != "兜底额度核验", let scope = result.accountScope,
                   manual || activityUpdatedAt.map({ Date().timeIntervalSince($0) >= 300 }) != false {
                    do {
                        try Task.checkCancellation()
                        let activity = try await client.fetchUsage(expectedScope: scope)
                        guard isCurrent(request, epoch: epoch) else { return }
                        guard identity == accountEpoch else { finishRefresh(request, epoch: epoch); return }
                        guard snapshot?.accountScope == scope else { finishRefresh(request, epoch: epoch); return }
                        tokenActivity = activity; activityUpdatedAt = Date(); activityError = nil
                    } catch {
                        guard isCurrent(request, epoch: epoch) else { return }
                        guard identity == accountEpoch else { finishRefresh(request, epoch: epoch); return }
                        let failure = Self.failure(error)
                        activityError = failure == .unsupported ? "当前 Codex 不支持官方 Token 活动；额度核验不受影响。" : "官方 Token 活动暂不可用，可点击刷新重试。"
                        if failure == .accountChanged || failure == .authRequired { recordFailure(failure) }
                        else if failure.canRetry { recordFailure(failure, invalidateQuota: false) }
                    }
                }
            } catch {
                guard isCurrent(request, epoch: epoch) else { return }
                guard identity == accountEpoch else { finishRefresh(request, epoch: epoch); return }
                recordFailure(Self.failure(error))
            }
            finishRefresh(request, epoch: epoch)
        }
    }

    private func finishRefresh(_ request: UUID, epoch: Int) {
        guard isCurrent(request, epoch: epoch) else { return }
        isRefreshing = false; activeRequest = nil; refreshTask = nil
        if lastFailure == nil, let failure = disconnectDuringRefresh { recordFailure(failure) }
        disconnectDuringRefresh = nil
        let followup = queuedReason; queuedReason = nil
        if lastFailure == nil { retryAttempt = 0 }
        onDisplayChange?()
        if lastFailure == nil, let followup { scheduleRefresh(reason: followup, delay: recovery.mergeDelay) }
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
        authRecoveryAfter = failure == .authRequired ? Date().addingTimeInterval(60) : nil
        if invalidateQuota { verified = false; reminders.update(snapshot: nil, verified: false) }
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
        reminders.update(snapshot: nil, verified: false)
        creditCheckTimer?.invalidate(); creditCheckTimer = nil
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
        guard !paused else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: quotaPollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollQuota() }
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

    private func configureCreditCheck() {
        creditCheckTimer?.invalidate(); creditCheckTimer = nil
        guard reminders.enabled, !paused else { return }
        // Only opt-in reminder users gain periodic checks for cards used elsewhere.
        // Also validate shortly before an upcoming scheduled reminder/expiry.
        let now = Date()
        let boundaries = snapshot?.resetCredits?.availableDetails.compactMap(\.expiryDate).flatMap {
            [$0.addingTimeInterval(-86430), $0]
        }.filter { $0 > now } ?? []
        let interval = max(1, min(900, boundaries.min()?.timeIntervalSince(now) ?? 900))
        creditCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh(reason: "重置卡状态核验")
                self.configureCreditCheck()
            }
        }
    }

    func pause() {
        guard !paused else { return }
        secondAccount?.pause(); cancelSignIn()
        paused = true; verified = false; invalidateConnection()
        reminders.update(snapshot: nil, verified: false)
        creditCheckTimer?.invalidate(); creditCheckTimer = nil
        clockTimer?.invalidate(); clockTimer = nil; pollTimer?.invalidate(); pollTimer = nil
        now = Date(); onDisplayChange?()
    }
    func resume() {
        guard paused else { return }
        paused = false; verified = false; now = Date()
        secondAccount?.resume()
        configureClock(); configurePolling(); scheduleRefresh(reason: "唤醒核验", delay: recovery.wakeDelay)
        onDisplayChange?()
    }
    func stop() async {
        cancelSignIn()
        if let secondAccount { await secondAccount.stop() }
        paused = true; invalidateConnection()
        watcher?.stop(); watcher = nil; watchingClient = false
        connectivity?.stop(); connectivity = nil
        clockTimer?.invalidate(); clockTimer = nil; pollTimer?.invalidate(); pollTimer = nil
        creditCheckTimer?.invalidate(); creditCheckTimer = nil
        await connectionBarrier?.value
        // Already scheduled local notifications may remain when quitting normally.
        await reminders.flush()
        connectionBarrier = nil; started = false
    }
}
