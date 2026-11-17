import AppKit
import SwiftUI

/// Standalone UI review app. It never starts production monitors or reads account credentials.
private actor OrbitFixtureClient: QuotaClient {
    let secondary: Bool
    init(secondary: Bool) { self.secondary = secondary }
    func setHandler(_ value: @escaping @Sendable (CodexSignal) -> Void) {}
    func fetch(customPath: String) async throws -> QuotaSnapshot { OrbitFixtures.snapshot(secondary: secondary) }
    func fetchUsage(expectedScope: String) async throws -> TokenActivity { OrbitFixtures.activity() }
    func shutdown() async {}
}

private enum OrbitFixtures {
    static func snapshot(secondary: Bool, free: Bool = false, mode: String = "正常") -> QuotaSnapshot {
        let now = Date()
        let low = mode == "低额度"
        let credits: [ResetCredit] = (0..<(secondary ? 1 : 3)).map { index -> ResetCredit in
            let days = Double(13 + index * 14)
            let interval: TimeInterval = mode == "到期预警" && index == 0 ? 64800 : days * 86400 + 64800
            let expiry = now.addingTimeInterval(interval).timeIntervalSince1970
            return ResetCredit(id: "preview-\(secondary)-\(index)", resetType: "codexRateLimits", status: "available", grantedAt: nil,
                        expiresAt: expiry,
                        title: nil, description: nil)
        }
        return QuotaSnapshot(observedAt: mode == "过期数据" ? now.addingTimeInterval(-600) : now,
            accountScope: secondary ? "preview-secondary" : "preview-primary", accountLabel: secondary ? "a1***@outlook.com" : "13***@163.com", planType: free ? "free" : "plus",
            buckets: [QuotaBucket(limitId: "codex", limitName: nil,
                primary: QuotaWindow(usedPercent: low ? 92 : (secondary ? 0 : 14), windowDurationMins: 300,
                                     resetsAt: now.addingTimeInterval(mode == "重置待确认" ? -1 : 7200).timeIntervalSince1970),
                secondary: free ? nil : QuotaWindow(usedPercent: low ? 88 : (secondary ? 3 : 47), windowDurationMins: 10080, resetsAt: now.addingTimeInterval(172800).timeIntervalSince1970),
                planType: free ? "free" : "plus", spendControlReached: nil, rateLimitReachedType: nil)],
            accountEmail: secondary ? "alex.wang@outlook.example" : "lin.chen@example.com",
            resetCredits: mode == "未知重置卡" ? nil : ResetCreditSummary(availableCount: free ? 0 : credits.count, credits: free ? [] : credits))
    }
    static func activity() -> TokenActivity {
        let days = TokenActivity.heatmapDays()
        return TokenActivity(summary: .init(lifetimeTokens: 650_000_000, peakDailyTokens: 120_000_000, longestRunningTurnSec: 1870, currentStreakDays: 0, longestStreakDays: 5),
            dailyUsageBuckets: days.enumerated().compactMap { i, day in
                guard let date = TokenActivity.date(day), date <= Date() else { return nil }
                return .init(startDate: day, tokens: i > 150 ? Double((i * 13) % 5) * 28_400_000 : 0)
            })
    }
}

@MainActor
private final class OrbitPreviewModel: ObservableObject {
    let state: AppState
    let suite: String
    @Published var showingSettings = false
    @Published var mode = "正常" { didSet { fixtures() } }
    @Published var free = false { didSet { fixtures() } }
    init() {
        suite = "com.guoyuming.UsageBar.UIReview." + UUID().uuidString
        let secondary = AppState(defaults: UserDefaults(suiteName: suite + ".secondary")!, client: OrbitFixtureClient(secondary: true),
            reminderCenter: MonitoringOnlyReminderCenter(), codexHome: URL(fileURLWithPath: "/preview/secondary"))
        state = AppState(defaults: UserDefaults(suiteName: suite)!, client: OrbitFixtureClient(secondary: false),
            reminderCenter: MonitoringOnlyReminderCenter(), secondaryFactory: { secondary })
        state.setSecondAccountEnabled(true)
        if CommandLine.arguments.contains("--three-accounts") { state.addAccount(startLogin: false) }
        state.panelHeight = OrbitLayout.defaultPanelHeight
        fixtures()
        if CommandLine.arguments.contains("--view-backup") { state.selectedAccountID = "secondary" }
    }
    func fixtures() {
        for entry in state.accountEntries {
            entry.state.snapshot = mode == "未登录" ? nil : OrbitFixtures.snapshot(secondary: entry.id != "primary", free: free && entry.id != "primary", mode: mode)
            if entry.id != "primary" && entry.id != "secondary", let snapshot = entry.state.snapshot {
                entry.state.snapshot = QuotaSnapshot(observedAt: snapshot.observedAt, accountScope: "preview-third", accountLabel: "dev***@gmail.com", planType: "free", buckets: [QuotaBucket(limitId: "codex", limitName: nil, primary: snapshot.buckets.first?.primary, secondary: nil, planType: "free", spendControlReached: nil, rateLimitReachedType: nil)], accountEmail: "developer.team@gmail.example", resetCredits: ResetCreditSummary(availableCount: 0, credits: []))
            }
            entry.state.verified = mode != "未登录"
            entry.state.now = Date()
            entry.state.tokenActivity = OrbitFixtures.activity()
            entry.state.activityUpdatedAt = Date()
        }
        if mode != "未登录" { _ = state.dualClient.confirmProfile(scope: "preview-primary") }
    }
    func cleanup() {
        for id in state.additionalAccountIDs { UserDefaults.standard.removePersistentDomain(forName: "com.guoyuming.UsageBar.account." + id) }
        UserDefaults.standard.removePersistentDomain(forName: suite)
        UserDefaults.standard.removePersistentDomain(forName: suite + ".secondary")
    }
}

@MainActor
private struct OrbitPreviewShell: View {
    @ObservedObject var model: OrbitPreviewModel
    @ObservedObject var state: AppState
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("本地 UI 预览 · 示例数据").font(.system(size: 12, weight: .semibold))
                Spacer()
                Picker("页面", selection: $model.showingSettings) {
                    Text("主弹窗").tag(false); Text("设置页面").tag(true)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 165)
                Picker("数据状态", selection: $model.mode) {
                    ForEach(["正常", "低额度", "到期预警", "过期数据", "重置待确认", "未知重置卡", "未登录"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 170)
                Toggle("备用 Free", isOn: $model.free).font(.system(size: 11))
                Picker("外观", selection: Binding(get: { state.preferences.appearance }, set: { state.preferences.appearance = $0 })) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }.labelsHidden().frame(width: 120)
            }.padding(15)
            Divider()
            if model.showingSettings {
                UsageSettingsView(state: state).padding(.vertical, 24)
            } else {
                QuotaPanelView(state: state) { model.showingSettings = true }.padding(.vertical, 20)
            }
            Spacer(minLength: 0)
            Text("预览不读取真实账号凭证，不登录、安装更新或重启客户端。换号仅切换示例数据。")
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(.bottom, 12)
        }
        .frame(width: 980, height: 970).background(Color(nsColor: .windowBackgroundColor))
        .environment(\.orbitPreview, true)
        .preferredColorScheme(state.preferences.appearance == .system ? nil : (state.preferences.appearance == .dark ? .dark : .light))
    }
}

@main
private struct OrbitPreviewApplication {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let model = OrbitPreviewModel()
        let host = NSHostingController(rootView: OrbitPreviewShell(model: model, state: model.state))
        let window = NSWindow(contentViewController: host)
        window.title = "CodexUsageBar — 本地 UI 预览（未发布）"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        let args = CommandLine.arguments
        if let flag = args.firstIndex(of: "--capture"), args.count > flag + 1 {
            let directory = URL(fileURLWithPath: args[flag + 1])
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let stages: [(String, SettingsTab?)] = [("panel", nil), ("account-menu", nil), ("activity-panel", nil), ("panel-bottom", nil)] + SettingsTab.allCases.map { ($0.rawValue, Optional($0)) }
            @MainActor func capture(_ index: Int) {
                guard index < stages.count else { model.cleanup(); app.terminate(nil); return }
                let (name, tab) = stages[index]
                model.state.orbitActivitySelected = name == "activity-panel"
                model.state.accountPickerPresented = name == "account-menu"
                model.showingSettings = tab != nil
                if let tab { model.state.settingsTab = tab }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
                    window.contentView?.layoutSubtreeIfNeeded()
                    if name == "panel-bottom", let root = window.contentView {
                        @MainActor func scrollBottom(_ view: NSView) {
                            if let scroll = view as? NSScrollView, let document = scroll.documentView, document.bounds.height > scroll.contentView.bounds.height {
                                let y = document.isFlipped ? document.bounds.height - scroll.contentView.bounds.height : 0
                                scroll.contentView.scroll(to: NSPoint(x: 0, y: y)); scroll.reflectScrolledClipView(scroll.contentView)
                            }
                            for child in view.subviews { scrollBottom(child) }
                        }
                        scrollBottom(root)
                    }
                    let captureWindow = name == "account-menu"
                        ? (NSApp.windows.first { $0 !== window && $0.isVisible && $0.frame.width >= 350 && $0.frame.width < 450 } ?? window)
                        : window
                    if let view = captureWindow.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: bitmap)
                        if let png = bitmap.representation(using: .png, properties: [:]) { try? png.write(to: directory.appendingPathComponent(name + ".png")) }
                    }
                    capture(index + 1)
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { capture(0) }
        }
        withExtendedLifetime((model, window)) { app.run() }
        model.cleanup()
    }
}
