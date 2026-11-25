import SwiftUI

@MainActor
struct OrbitPanelContent: View {
    @ObservedObject var owner: AppState
    @ObservedObject var controller: DualClientController
    let openSettings: () -> Void

    var body: some View {
        let account = owner.displayedAccount
        VStack(spacing: owner.preferences.panelCompact == true ? 7 : 10) {
            if owner.accountPickerPresented {
                TideAccountDrawer(owner: owner, controller: controller, openSettings: openSettings)
            } else if let retryAt = account.nextRetryAt {
                reconnect(account: account, at: retryAt)
            } else if owner.homeAccounts.isEmpty {
                emptyAccount
            } else {
                if controller.isSwitching || controller.detectionIssue != nil || DualClientPanelView.isVisible(controller) && controller.message != nil {
                    DualClientPanelView(controller: controller)
                }
                TideAccountOverview(owner: owner, account: account, openSettings: openSettings)
            }
        }
        .padding(.horizontal, 14)
    }

    private func reconnect(account: AppState, at retryAt: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 8) {
                Text("🌊").font(.system(size: 34))
                Text("连接中断，正在重连").font(.system(size: 15, weight: .semibold))
                Text("\(account.errorMessage ?? "Codex App Server 没有响应。")\n将在 \(max(0, Int(ceil(retryAt.timeIntervalSince(context.date))))) 秒后重试")
                    .font(.system(size: 12)).foregroundStyle(TidePalette.secondary)
                    .multilineTextAlignment(.center)
                Button("立即重试") { account.refresh(reason: "手动刷新") }
                    .buttonStyle(OrbitActionStyle(prominent: true))
            }
            .padding(22).frame(maxWidth: .infinity)
            .background(TidePalette.card, in: RoundedRectangle(cornerRadius: 20))
        }
    }

    private var emptyAccount: some View {
        let desktopFound = FileManager.default.fileExists(atPath: DualClientController.desktopPath)
        return VStack(spacing: 8) {
            TideRings(short: 100, long: 100, size: 64, stroke: 6)
            Text(owner.isRefreshing ? "正在核验账号…" : desktopFound ? "已找到本机 Codex" : "开始监测 Codex")
                .font(.system(size: 15, weight: .semibold))
            Text((desktopFound ? DualClientController.desktopPath + "\n" : "") + owner.statusDetail).font(.system(size: 12))
                .foregroundStyle(TidePalette.secondary).multilineTextAlignment(.center)
            Button("开始监测") { owner.refreshAllAccounts() }
                .buttonStyle(OrbitActionStyle(prominent: true)).disabled(owner.isRefreshing)
            Button("管理账号") { owner.settingsTab = .accounts; openSettings() }
                .buttonStyle(.link).font(.system(size: 11))
        }
        .padding(22).frame(maxWidth: .infinity)
    }
}

@MainActor
private struct TideAccountOverview: View {
    @ObservedObject var owner: AppState
    @ObservedObject var account: AppState
    let openSettings: () -> Void

    var body: some View {
        let bucket = account.bucket
        let singleSecondary = account.isFreeAccount && bucket?.primary == nil
        let projection = account.tideProjection
        VStack(spacing: owner.preferences.panelCompact == true ? 7 : 10) {
            if let buckets = account.snapshot?.buckets, buckets.count > 1 {
                Picker("额度", selection: Binding(get: { bucket?.id ?? "codex" }, set: { account.preferences.selectedBucket = $0 })) {
                    ForEach(buckets) { Text($0.displayName).tag($0.id) }
                }.font(.system(size: 11))
            }
            HStack(spacing: 10) {
                TideTank(account: account, window: singleSecondary ? bucket?.secondary : bucket?.primary,
                         title: account.isFreeAccount ? "周期额度" : "浪 · " + (bucket?.primary?.label.replacingOccurrences(of: "窗口", with: "") ?? "短周期"),
                         kind: singleSecondary ? .long : .short)
                if !account.isFreeAccount {
                    TideTank(account: account, window: bucket?.secondary, title: "潮 · " + (bucket?.secondary?.label.replacingOccurrences(of: "窗口", with: "") ?? "长周期"),
                             kind: .long)
                }
            }
            if account.updateStatus.isWarning {
                Label(account.statusDetail, systemImage: account.updateStatus.symbol)
                    .font(.system(size: 10)).foregroundStyle(TidePalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if bucket?.spendControlReached == true || bucket?.rateLimitReachedType != nil {
                Label("服务商报告了使用限制，请同时查看客户端提示。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(TidePalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let recommendation = owner.tideRecommendation(for: account).flatMap { target in
                target.state.bucket?.primary?.remaining.map { (target.id, owner.tideAvatarLabel(target.id), $0) }
            }
            let reset = bucket?.primary?.resetDate.flatMap { $0 > account.now ? $0 : nil }
            TideForecastCard(projection: projection, reset: reset, windowLabel: bucket?.primary?.shortLabel ?? "短周期", recommendation: recommendation) {
                owner.selectedAccountID = $0
                owner.accountPickerPresented = true
            }
            TideCreditsCard(account: account) {
                owner.settingsTab = .reminders; openSettings()
            }
            TideActivityCard(account: account)
        }
    }
}

@MainActor
extension AppState {
    func tideRecommendation(for displayed: AppState) -> (id: String, state: AppState)? {
        let current = displayed.bucket?.primary?.remaining ?? 0
        guard displayed.tideProjection?.exhaustion != nil else { return nil }
        return homeAccounts.filter { entry in
            let account = entry.state
            return account !== displayed && canSwitchAccount(entry.id) && account.updateStatus == .verified
                && (account.bucket?.primary?.remaining ?? 0) > current
        }.max { left, right in
            @MainActor func availableTime(_ account: AppState) -> TimeInterval {
                (account.tideProjection?.exhaustion ?? account.bucket?.primary?.resetDate ?? account.now)
                    .timeIntervalSince(account.now)
            }
            let leftTime = floor(availableTime(left.state) / 60)
            let rightTime = floor(availableTime(right.state) / 60)
            if leftTime != rightTime { return leftTime < rightTime }
            let leftShort = left.state.bucket?.primary?.remaining ?? 0
            let rightShort = right.state.bucket?.primary?.remaining ?? 0
            if leftShort != rightShort { return leftShort < rightShort }
            return (left.state.bucket?.secondary?.remaining ?? 0) < (right.state.bucket?.secondary?.remaining ?? 0)
        }
    }
}

@MainActor
private struct TideAccountDrawer: View {
    @ObservedObject var owner: AppState
    @ObservedObject var controller: DualClientController
    @Environment(\.orbitPreview) private var preview
    let openSettings: () -> Void

    var body: some View {
        let displayed = owner.displayedAccount
        let selected = owner.homeAccounts.first { $0.state === displayed }
        let recommendation = owner.tideRecommendation(for: owner.menuBarAccount)
        let target = selected.flatMap { $0.id == controller.activeProfileID ? nil : $0 } ?? recommendation
        VStack(alignment: .leading, spacing: 6) {
            Text("选择账号 · 单击只查看，不切换登录")
                .font(.system(size: 11, weight: .bold)).tracking(0.6)
                .foregroundStyle(TidePalette.tertiary).padding(.leading, 4)
            ForEach(owner.homeAccounts, id: \.id) { entry in
                TideAccountRow(owner: owner, account: entry.state, id: entry.id, recommended: recommendation?.id == entry.id) {
                    owner.selectedAccountID = entry.id
                    owner.accountPickerPresented = false
                }
            }
            if let target {
                TideHoldSwitch(owner: owner, controller: controller, account: target.state, id: target.id)
                    .id(target.id)
                Text("将正常退出 ChatGPT 并重新打开，请先保存任务")
                    .font(.system(size: 11)).foregroundStyle(TidePalette.secondary)
                    .frame(maxWidth: .infinity)
            }
            if DualClientPanelView.isVisible(controller) { DualClientPanelView(controller: controller) }
            HStack {
                Button("＋ 添加账号") { owner.addAccount() }.disabled(preview)
                Spacer()
                Button("管理账号 →") { owner.settingsTab = .accounts; openSettings() }
            }
            .font(.system(size: 12)).foregroundStyle(TidePalette.secondary)
            .buttonStyle(.plain).padding(.horizontal, 8).padding(.top, 5)
        }.padding(.vertical, 5)
    }
}

@MainActor
private struct TideAccountRow: View {
    @ObservedObject var owner: AppState
    @ObservedObject var account: AppState
    let id: String
    let recommended: Bool
    let select: () -> Void

    var body: some View {
        let quota = QuotaPresentation.accountQuota(snapshot: account.snapshot, verified: account.verified && !account.isSigningOut, now: account.now)
        let current = owner.dualClient.detected && owner.dualClient.activeProfileID == id
        let selected = owner.displayedAccount === account
        Button(action: select) {
            HStack(spacing: 12) {
                TideAvatar(index: owner.tideAvatarIndex(id), size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.snapshot?.accountLabel ?? "账号待核验").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(account.snapshot?.planType?.capitalized ?? "待核验")
                        if current { Text("· ● 当前登录").foregroundStyle(TidePalette.green) }
                        else if quota.cached { Text("· 上次核验") }
                        else if let count = account.snapshot?.resetCredits?.availableCount { Text("· \(count) 张重置卡") }
                    }.font(.system(size: 11)).foregroundStyle(TidePalette.secondary)
                }
                Spacer(minLength: 2)
                VStack(alignment: .trailing, spacing: 3) {
                    ForEach(quota.windows) { window in
                        let rules = window.id == 0 ? owner.preferences.primaryColorRules : owner.preferences.secondaryColorRules
                        let color = window.remaining.flatMap { MenuBarRenderer.colorHex(remaining: $0, rules: owner.preferences.followsQuotaColors ? rules : nil) }
                            .map { Color(nsColor: MenuBarRenderer.color($0)) }
                        Text(window.label + " " + (window.remaining.map(QuotaPresentation.percent) ?? "--"))
                            .foregroundStyle(quota.cached ? TidePalette.secondary : color ?? (window.id == 0 ? TidePalette.coral : TidePalette.indigo))
                    }
                }.font(.system(size: 11, design: .monospaced))
                TideRings(short: quota.windows.first?.remaining, long: quota.windows.dropFirst().first?.remaining)
            }
            .padding(10).frame(maxWidth: .infinity)
            .background((selected && !current) || recommended ? TidePalette.card : .clear, in: RoundedRectangle(cornerRadius: 16))
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if recommended {
                    Text("推荐 · 能撑最久").font(.system(size: 9.5, weight: .heavy))
                        .foregroundStyle(.white).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(TidePalette.indigo, in: Capsule()).offset(x: -12, y: -6)
                }
            }
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityLabel((account.snapshot?.accountLabel ?? "账号待核验") + "，" + quota.summary)
    }
}

@MainActor
private struct TideHoldSwitch: View {
    @ObservedObject var owner: AppState
    @ObservedObject var controller: DualClientController
    @ObservedObject var account: AppState
    @Environment(\.orbitPreview) private var preview
    @StateObject private var interaction = Interaction()
    private final class Interaction: ObservableObject {
        @Published var progress: CGFloat = 0
        @Published var accessibleConfirmation = false
    }
    let id: String

    var body: some View {
        let name = account.snapshot?.accountLabel ?? "所选账号"
        let letter = owner.tideAvatarLabel(id)
        let enabled = owner.canSwitchAccount(id)
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                TidePalette.ink
                LinearGradient(colors: [TidePalette.coral, TidePalette.indigo], startPoint: .leading, endPoint: .trailing)
                    .frame(width: geometry.size.width * interaction.progress)
                Label(controller.isSwitching ? "正在切换…" : "按住 · 切换到 \(letter) 并重启客户端",
                      systemImage: "clock").font(.system(size: 13, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.75).foregroundStyle(TidePalette.card)
                    .frame(maxWidth: .infinity)
            }.clipShape(RoundedRectangle(cornerRadius: 14))
        }.frame(height: 46)
        .contentShape(Rectangle())
        .onLongPressGesture(minimumDuration: 0.8, maximumDistance: 16) {
            performSwitch()
        } onPressingChanged: { pressing in
            guard enabled else { return }
            withAnimation(pressing ? .linear(duration: 0.8) : .easeOut(duration: 0.15)) {
                interaction.progress = pressing ? 1 : 0
            }
        }
        .opacity(enabled ? 1 : 0.45)
        .allowsHitTesting(enabled)
        .focusable(enabled)
        .onKeyPress(.space) {
            guard enabled else { return .ignored }
            interaction.accessibleConfirmation = true
            return .handled
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("切换到 \(name) 并重启客户端")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { interaction.accessibleConfirmation = true } }
        .alert("切换并重启客户端？", isPresented: $interaction.accessibleConfirmation) {
            Button("取消", role: .cancel) {}
            Button("切换并重启") { performSwitch() }
        } message: { Text("将正常退出 ChatGPT 并重新打开，请先保存任务。") }
    }

    private func performSwitch() {
        guard owner.canSwitchAccount(id) else { return }
        if preview { _ = controller.confirmProfile(scope: account.snapshot?.accountScope) }
        else { controller.switchToProfile(id, cliPath: owner.preferences.cliPath) }
        owner.accountPickerPresented = false
    }
}
