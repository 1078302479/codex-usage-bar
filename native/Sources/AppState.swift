import Foundation
import Combine
import AppKit

enum SettingsTab: String, CaseIterable, Hashable { case accounts, menuBar, appearance, connection, reminders, about }

@MainActor
final class AppState: ObservableObject {
    let appUpdates = AppUpdateController()
    let loginItem = LoginItemController()
    lazy var dualClient: DualClientController = {
        let controller = DualClientController(defaults: defaults)
        controller.profiles = { [weak self] in
            self?.accountEntries.map { ($0.id, $0.state.codexHome, $0.state.verified && !$0.state.isSigningOut ? $0.state.snapshot?.accountScope : nil) } ?? []
        }
        controller.onActiveProfile = { [weak self] id in
            self?.selectedAccountID = id
            self?.syncActiveReminders(force: true)
        }
        controller.cliPath = { [weak self] in self?.preferences.cliPath ?? "" }
        controller.accountScopes = { [weak self] in
            guard let self else { return (nil, nil) }
            return (self.verified ? self.snapshot?.accountScope : nil,
                    self.secondAccount?.verified == true ? self.secondAccount?.snapshot?.accountScope : nil)
        }
        controller.onAccountUncertain = { [weak self] in self?.syncActiveReminders(force: true) }
        controller.onRestartSucceeded = { [weak self] secondary in
            guard let self else { return }
            self.showingSecondAccountDetails = secondary && self.secondAccount != nil
            self.syncActiveReminders(force: true)
            self.displayedAccount.panelOpened()
        }
        return controller
    }()
    private var reminderSnapshot: QuotaSnapshot?
    private var reminderVerified = false
    var onReminderDataChange: (() -> Void)?
    var reminderAccount: AppState? {
        if secondAccount == nil && additionalAccounts.isEmpty { return dualClient.activeSecondary ? nil : self }
        if let id = dualClient.activeProfileID {
            guard dualClient.detected else { return nil }
            return accountEntries.first(where: { $0.id == id })?.state
        }
        guard secondAccount != nil else { return dualClient.activeSecondary ? nil : self }
        guard dualClient.detected else { return nil }
        return dualClient.activeSecondary ? secondAccount : self
    }
    func syncActiveReminders(force: Bool = false) {
        guard codexHome == nil else { onReminderDataChange?(); return }
        let account = reminderAccount
        let snapshot = account?.snapshot
        let valid = account?.verified == true && !paused
        guard force || snapshot != reminderSnapshot || valid != reminderVerified else { return }
        reminderSnapshot = snapshot; reminderVerified = valid
        reminders.update(snapshot: snapshot, verified: valid)
        lowQuotaReminders.check()
        configureCreditCheck()
    }
    private func updateReminderData() {
        if codexHome != nil { onReminderDataChange?() }
        else { syncActiveReminders(force: true) }
    }
    let reminders: ResetCreditReminderController
    let lowQuotaReminders: LowQuotaReminderController
    @Published var panelHeight: CGFloat = 800
    @Published var settingsTab: SettingsTab = .menuBar
    private var lastCreditDetailsDefault: Bool?
    func applyCreditDetailsDefault(expanded: Bool) {
        guard lastCreditDetailsDefault != expanded else { return }
        lastCreditDetailsDefault = expanded
        resetCreditsExpanded = expanded
    }
    @Published var resetCreditsExpanded = false
    @Published var showingSecondAccountDetails = false {
        didSet {
            guard oldValue != showingSecondAccountDetails else { return }
            onDisplayChange?()
        }
    }
    @Published var orbitActivitySelected = false
    @Published var accountPickerPresented = false
    @Published var comparisonsExpanded = true
    @Published var pendingSwitchConfirmation: String?
    @Published var managingAccounts = false
    @Published var pendingAccountDeletion: String?
    @Published private(set) var deletingAccountID: String?
    @Published var accountManagementMessage: String?
    @Published private(set) var localAccountRemoved = false
    @Published var selectedAccountID: String? { didSet { onDisplayChange?() } }
    @Published private(set) var additionalAccounts: [String: AppState] = [:]
    @Published private(set) var additionalAccountIDs: [String] = []
    var accountEntries: [(id: String, state: AppState)] {
        (localAccountRemoved ? [] : [("primary", self)]) + (secondAccount.map { [("secondary", $0)] } ?? []) + additionalAccountIDs.compactMap { id in additionalAccounts[id].map { (id, $0) } }
    }
    var expandsCreditDetailsByDefault: Bool { false }
    var showsTokenActivity: Bool { !homeAccounts.isEmpty }
    var homeAccounts: [(id: String, state: AppState)] {
        orderedAccounts.filter { $0.state.snapshot?.accountScope != nil }
    }
    var displayedAccount: AppState {
        if let selectedAccountID, let entry = accountEntries.first(where: { $0.id == selectedAccountID }),
           managingAccounts || entry.state.snapshot?.accountScope != nil { return entry.state }
        let legacy = showingSecondAccountDetails ? (secondAccount ?? self) : self
        if managingAccounts || legacy.snapshot?.accountScope != nil { return legacy }
        return homeAccounts.first(where: { $0.id == dualClient.activeProfileID })?.state ?? homeAccounts.first?.state ?? self
    }
    /// Browsing another account in the panel never changes the menu bar's source.
    var menuBarAccount: AppState {
        accountEntries.first(where: { $0.id == dualClient.activeProfileID })?.state ?? self
    }
    private func restoreActiveAccountView() {
        let activeID = accountEntries.first(where: { $0.id == dualClient.activeProfileID })?.id
        if selectedAccountID != activeID { selectedAccountID = activeID }
        let secondary = activeID == "secondary"
        if showingSecondAccountDetails != secondary { showingSecondAccountDetails = secondary }
        accountPickerPresented = false
        pendingSwitchConfirmation = nil
    }
    func accountRole(_ id: String) -> String {
        guard dualClient.detected else { return "登录待确认" }
        if id == dualClient.activeProfileID { return "主账号" }
        guard accountEntries.first(where: { $0.id == id })?.state.snapshot?.accountScope != nil else { return "待登录账号" }
        let backups = orderedBackupAccounts.filter { $0.state.snapshot?.accountScope != nil }
        return "备用账号 \( (backups.firstIndex(where: { $0.id == id }) ?? 0) + 1)"
    }
    var orderedBackupAccounts: [(id: String, state: AppState)] {
        accountEntries.enumerated().filter { $0.element.id != dualClient.activeProfileID }
            .sorted { lhs, rhs in
                if lhs.element.state.isPlusAccount != rhs.element.state.isPlusAccount { return lhs.element.state.isPlusAccount }
                return lhs.offset < rhs.offset
            }.map { $0.element }
    }
    var orderedAccounts: [(id: String, state: AppState)] {
        let entries = accountEntries
        return entries.filter { $0.id == dualClient.activeProfileID } + orderedBackupAccounts
    }
    func addAccount(startLogin: Bool = true) {
        guard codexHome == nil else { return }
        if secondAccount == nil { setSecondAccountEnabled(true); if startLogin { secondAccount?.signInSecondAccount() }; return }
        let id = UUID().uuidString
        additionalAccountIDs.append(id)
        defaults.set(additionalAccountIDs, forKey: "additional-account-ids.v1")
        loadAdditionalAccount(id)
        if startLogin { additionalAccounts[id]?.signInSecondAccount() }
    }
    func canDeleteAccount(_ id: String) -> Bool {
        dualClient.detected && id != dualClient.activeProfileID && !dualClient.isSwitching && deletingAccountID == nil
            && accountEntries.contains { $0.id == id && !$0.state.isSigningOut }
    }
    func requestAccountDeletion(_ id: String) {
        guard canDeleteAccount(id) else { return }
        pendingAccountDeletion = id
    }
    func cancelAccountDeletion() { pendingAccountDeletion = nil }
    func confirmAccountDeletion() {
        guard let id = pendingAccountDeletion else { return }
        pendingAccountDeletion = nil
        guard canDeleteAccount(id), let account = accountEntries.first(where: { $0.id == id })?.state else { return }
        deletingAccountID = id
        accountManagementMessage = nil
        account.signOut { [weak self, weak account] success in
            guard let self, let account else { return }
            guard success else {
                self.deletingAccountID = nil
                self.accountManagementMessage = "删除失败，账号已保留，请重试。"
                return
            }
            // Update shared UI/registry synchronously when logout succeeds.
            // Process/notification cleanup must not keep a deleted card on screen.
            do {
                if id != "primary" {
                    account.onSignedOut = nil
                    account.onDisplayChange = nil
                    account.onReminderDataChange = nil
                }
                if id == "primary" {
                    self.localAccountRemoved = true
                    self.defaults.set(true, forKey: "local-account-removed.v1")
                } else if id == "secondary" {
                    self.secondAccount = nil
                    self.defaults.set(false, forKey: "second-account.enabled.v1")
                } else {
                    self.additionalAccounts.removeValue(forKey: id)
                    self.additionalAccountIDs.removeAll { $0 == id }
                    self.defaults.set(self.additionalAccountIDs, forKey: "additional-account-ids.v1")
                }
                self.selectedAccountID = self.dualClient.activeProfileID
                self.showingSecondAccountDetails = self.selectedAccountID == "secondary"
                self.deletingAccountID = nil
                self.syncActiveReminders(force: true)
                self.onDisplayChange?()
                if id != "primary" { Task { await account.stop() } }
            }
        }
    }
    private func loadAdditionalAccount(_ id: String) {
        guard UUID(uuidString: id) != nil, additionalAccounts[id] == nil else { return }
        let home = Self.secondAccountHome.deletingLastPathComponent().appendingPathComponent(id)
        let saved = UserDefaults(suiteName: "com.guoyuming.UsageBar.account." + id)!
        let account = AppState(defaults: saved, client: CodexClient(codexHome: home), reminderCenter: MonitoringOnlyReminderCenter(), codexHome: home)
        account.onSignedOut = { [weak self] in self?.dualClient.profileSignedOut(id) }
        account.preferences = preferences
        account.onDisplayChange = { [weak self] in self?.objectWillChange.send(); self?.onDisplayChange?() }
        account.onReminderDataChange = { [weak self] in self?.syncActiveReminders() }
        additionalAccounts[id] = account
        if started { account.start() }
        account.setPanelVisible(panelVisible)
    }
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
            if oldValue.panelFitsScreen != preferences.panelFitsScreen { panelPreferredHeight = nil; onPanelResize?(nil) }
            if oldValue.selectedBucket != preferences.selectedBucket { configureResetCheck() }
            if oldValue.cliPath != preferences.cliPath {
                cancelSignIn()
                invalidateConnection()
                clearAccount()
                lastFailure = nil; retryAttempt = 0
                scheduleRefresh(reason: "更换 Codex", delay: 0)
            }
            if let secondAccount, secondAccount.preferences != preferences { secondAccount.preferences = preferences }
            for account in additionalAccounts.values where account.preferences != preferences { account.preferences = preferences }
            onDisplayChange?()
        }
    }
    @Published var tokenActivity: TokenActivity?
    @Published var activityError: String?
    @Published var activityUpdatedAt: Date?
    private var activityAttemptAt: Date?
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
    @Published private(set) var isSigningOut = false
    var onSignedOut: (() -> Void)?
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
            secondary.onSignedOut = { [weak self] in self?.dualClient.profileSignedOut("secondary") }
            secondary.preferences = preferences
            secondary.onDisplayChange = { [weak self] in self?.objectWillChange.send(); self?.onDisplayChange?() }
            secondary.onReminderDataChange = { [weak self] in self?.syncActiveReminders() }
            secondAccount = secondary
            showingSecondAccountDetails = dualClient.activeSecondary
            if started { secondary.start() }
            secondary.setPanelVisible(panelVisible)
        } else if !enabled, let secondary = secondAccount {
            showingSecondAccountDetails = false
            secondAccount = nil
            secondary.onDisplayChange = nil
            secondary.onReminderDataChange = nil
            Task { await secondary.stop() }
        }
        syncActiveReminders(force: true)
        onDisplayChange?()
    }

    func signInSecondAccount() {
        guard !isSigningIn, !isSigningOut, !paused else { return }
        if codexHome == nil { localAccountRemoved = false; defaults.set(false, forKey: "local-account-removed.v1") }
        invalidateConnection(); clearAccount()
        lastFailure = nil; isSigningIn = true; loginMessage = "正在打开官方登录页面，请选择要登录的账号。"
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
                loginMessage = "请在浏览器完成该账号登录。"
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

    func signOut(completion: ((Bool) -> Void)? = nil) {
        guard !isSigningOut else { completion?(false); return }
        cancelSignIn()
        invalidateConnection()
        isSigningOut = true
        loginMessage = "正在退出登录…"
        let epoch = configurationEpoch
        let barrier = connectionBarrier
        Task { [weak self, client] in
            guard let self else { return }
            var succeeded = false
            defer { isSigningOut = false; onDisplayChange?(); completion?(succeeded) }
            await barrier?.value
            guard configurationEpoch == epoch else { return }
            do {
                try await client.logout(customPath: preferences.cliPath)
                guard configurationEpoch == epoch else { return }
                invalidateConnection()
                clearAccount()
                lastFailure = .authRequired
                authRecoveryAfter = nil
                loginMessage = "已退出登录，本地项目、聊天和模型配置已保留。"
                if codexHome == nil { dualClient.profileSignedOut("primary") }
                onSignedOut?()
                succeeded = true
            } catch {
                guard configurationEpoch == epoch else { return }
                loginMessage = "退出登录失败，请检查客户端连接后重试。"
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
        for account in additionalAccounts.values { account.refresh() }
    }

    init(defaults: UserDefaults = .standard, client: any QuotaClient = CodexClient(), recovery: RecoveryPolicy = RecoveryPolicy(), reminderCenter: any ReminderNotificationCenter = SystemReminderCenter(), codexHome: URL? = nil,
         loginOpener: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }, secondaryFactory: (() -> AppState)? = nil) {
        precondition(!recovery.retryDelays.isEmpty && recovery.retryDelays.allSatisfy { $0 > 0 && $0.isFinite })
        self.defaults = defaults; self.client = client; self.recovery = recovery
        self.localAccountRemoved = defaults.bool(forKey: "local-account-removed.v1")
        self.codexHome = codexHome
        self.loginOpener = loginOpener; self.secondaryFactory = secondaryFactory
        reminders = ResetCreditReminderController(defaults: defaults, center: reminderCenter)
        lowQuotaReminders = LowQuotaReminderController(defaults: defaults, center: reminderCenter)
        if let data = defaults.data(forKey: "preferences.v1"), let saved = try? JSONDecoder().decode(Preferences.self, from: data) { preferences = saved }
        else { preferences = Preferences() }
        if let data = defaults.data(forKey: "quota-cache.v1") { snapshot = try? JSONDecoder().decode(QuotaSnapshot.self, from: data) }
        reminders.onConfigurationChange = { [weak self] in self?.configureCreditCheck() }
        reminders.onNeedsRefresh = { [weak self] in self?.reminderAccount?.scheduleRefresh(reason: "重置卡提醒核验", delay: 0) }
        lowQuotaReminders.activeSnapshot = { [weak self] in
            guard let self, !self.paused, !self.dualClient.isSwitching, let account = self.reminderAccount,
                  account.verified, !account.isSigningOut else { return nil }
            return account.snapshot
        }
        lowQuotaReminders.onNeedsRefresh = { [weak self] in
            self?.reminderAccount?.scheduleRefresh(reason: "低额度提醒核验", delay: 0)
        }
    }

    var isPlusAccount: Bool {
        (snapshot?.planType ?? bucket?.planType)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "plus"
    }
    var isFreeAccount: Bool {
        (snapshot?.planType ?? bucket?.planType)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "free"
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
        let home = codexHome ?? CodexClient.primaryHome()
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
        if codexHome == nil {
            additionalAccountIDs = (defaults.stringArray(forKey: "additional-account-ids.v1") ?? []).filter { UUID(uuidString: $0) != nil }
            for id in additionalAccountIDs { loadAdditionalAccount(id) }
        }
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
        if codexHome == nil { dualClient.detectRunningAccount() }
        secondAccount?.panelOpened()
        for account in additionalAccounts.values { account.panelOpened() }
        guard !isRefreshing, lastFailure?.canRetry != false, nextRetryAt == nil else { return }
        if !verified || snapshot.map({ Date().timeIntervalSince($0.observedAt) > 2 }) != false || activityAttemptAt.map({ Date().timeIntervalSince($0) >= 300 }) != false { refresh(reason: "打开面板核验") }
    }

    func setPanelVisible(_ visible: Bool) {
        if !visible && codexHome == nil { restoreActiveAccountView() }
        guard panelVisible != visible else { return }
        panelVisible = visible
        secondAccount?.setPanelVisible(visible)
        for account in additionalAccounts.values { account.setPanelVisible(visible) }
        configurePolling()
    }

    func pollQuota(at date: Date = Date()) {
        if codexHome == nil { dualClient.detectRunningAccount() }
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
        guard !paused, !isSigningIn, !isSigningOut else { return }
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
                if snapshot?.accountScope != result.accountScope { tokenActivity = nil; activityUpdatedAt = nil; activityError = nil; activityAttemptAt = nil }
                snapshot = result; verified = true; lastFailure = nil; authRecoveryAfter = nil; lastSuccessfulAt = result.observedAt; now = Date()
                if codexHome != nil { loginMessage = "账号已核验。" }
                updateReminderData()
                configureCreditCheck()
                cancelRetry()
                if result.accountScope != nil, let data = try? JSONEncoder().encode(result) { defaults.set(data, forKey: "quota-cache.v1") }
                configureResetCheck()
                if (reason != "兜底额度核验" || panelVisible), let scope = result.accountScope,
                   manual || activityAttemptAt.map({ Date().timeIntervalSince($0) >= 300 }) != false {
                    activityAttemptAt = Date()
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
        if invalidateQuota { verified = false; updateReminderData() }
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
        activityAttemptAt = nil
        verified = false; snapshot = nil; tokenActivity = nil; activityUpdatedAt = nil; activityError = nil; lastSuccessfulAt = nil
        defaults.removeObject(forKey: "quota-cache.v1")
        updateReminderData()
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
        let boundaries = reminderAccount?.snapshot?.resetCredits?.availableDetails.compactMap(\.expiryDate).flatMap {
            [$0.addingTimeInterval(-86430), $0]
        }.filter { $0 > now } ?? []
        let interval = max(1, min(900, boundaries.min()?.timeIntervalSince(now) ?? 900))
        creditCheckTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.reminderAccount?.refresh(reason: "重置卡状态核验")
                self.configureCreditCheck()
            }
        }
    }

    func pause() {
        guard !paused else { return }
        secondAccount?.pause(); cancelSignIn()
        for account in additionalAccounts.values { account.pause() }
        paused = true; verified = false; invalidateConnection()
        updateReminderData()
        creditCheckTimer?.invalidate(); creditCheckTimer = nil
        clockTimer?.invalidate(); clockTimer = nil; pollTimer?.invalidate(); pollTimer = nil
        now = Date(); onDisplayChange?()
    }
    func resume() {
        guard paused else { return }
        paused = false; verified = false; now = Date()
        secondAccount?.resume()
        for account in additionalAccounts.values { account.resume() }
        configureClock(); configurePolling(); scheduleRefresh(reason: "唤醒核验", delay: recovery.wakeDelay)
        onDisplayChange?()
    }
    func stop() async {
        cancelSignIn()
        if let secondAccount { await secondAccount.stop() }
        for account in additionalAccounts.values { await account.stop() }
        paused = true; invalidateConnection()
        watcher?.stop(); watcher = nil; watchingClient = false
        connectivity?.stop(); connectivity = nil
        clockTimer?.invalidate(); clockTimer = nil; pollTimer?.invalidate(); pollTimer = nil
        creditCheckTimer?.invalidate(); creditCheckTimer = nil
        await connectionBarrier?.value
        // Already scheduled local notifications may remain when quitting normally.
        await reminders.flush()
        await lowQuotaReminders.flush()
        connectionBarrier = nil; started = false
    }
}
