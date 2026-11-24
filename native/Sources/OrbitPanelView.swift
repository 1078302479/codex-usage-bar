import SwiftUI

@MainActor
struct OrbitPanelContent: View {
    @ObservedObject var owner: AppState
    @ObservedObject var controller: DualClientController
    let openSettings: () -> Void
    private var selectedID: String { owner.accountEntries.first(where: { $0.state === owner.displayedAccount })?.id ?? "primary" }
    private var spacing: CGFloat { owner.preferences.panelCompact == true ? 6 : 10 }

    var body: some View {
        VStack(spacing: spacing) {
            if DualClientPanelView.isVisible(controller) {
                DualClientPanelView(controller: controller).padding(.horizontal, OrbitLayout.inset)
            }
            if owner.homeAccounts.isEmpty {
                emptyAccount.padding(.horizontal, OrbitLayout.inset)
            } else {
                VStack(spacing: spacing) {
                    OrbitViewingCard(owner: owner, account: owner.displayedAccount,
                                     controller: controller, profileID: selectedID, openSettings: openSettings)
                    HStack(spacing: 3) {
                        tab("额度概览", activity: false)
                        tab("Token 活动", activity: true)
                    }.padding(3).background(PanelPalette.ringTrack, in: RoundedRectangle(cornerRadius: 9))
                }.padding(.horizontal, OrbitLayout.inset)
                if owner.orbitActivitySelected {
                    TokenActivityView(state: owner.displayedAccount).id("activity-" + selectedID)
                        .padding(.horizontal, OrbitLayout.inset)
                } else {
                    OrbitAccountInstruments(owner: owner, account: owner.displayedAccount)
                        .id(selectedID).padding(.horizontal, OrbitLayout.inset)
                    ResetCreditSectionView(state: owner.displayedAccount,
                        openSettings: { owner.settingsTab = .reminders; openSettings() },
                        allowsReminders: owner.reminderAccount === owner.displayedAccount).id("credits-" + selectedID)
                    OrbitActivityTeaser(owner: owner, account: owner.displayedAccount)
                        .padding(.horizontal, OrbitLayout.inset)
                }
            }
        }.padding(.vertical, spacing + 2)
    }

    private func tab(_ title: String, activity: Bool) -> some View {
        Button { owner.orbitActivitySelected = activity } label: {
            Text(title).font(.system(size: 12, weight: owner.orbitActivitySelected == activity ? .medium : .regular))
                .foregroundStyle(owner.orbitActivitySelected == activity ? PanelPalette.primary : PanelPalette.secondary)
                .frame(maxWidth: .infinity).padding(.vertical, 7)
                .background(owner.orbitActivitySelected == activity ? PanelPalette.background : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }.buttonStyle(.plain).accessibilityAddTraits(owner.orbitActivitySelected == activity ? .isSelected : [])
    }

    private var emptyAccount: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 25)).foregroundStyle(PanelPalette.secondary)
            Text(owner.isRefreshing ? "正在核验账号…" : "登录后查看额度").font(.system(size: 14, weight: .medium))
            Text(owner.statusDetail).font(.system(size: 11)).foregroundStyle(PanelPalette.secondary).multilineTextAlignment(.center)
            HStack {
                Button("核验账号") { owner.refreshAllAccounts() }.disabled(owner.isRefreshing)
                Button("打开账号管理") { owner.settingsTab = .accounts; openSettings() }
            }.buttonStyle(OrbitActionStyle())
        }.frame(maxWidth: .infinity).padding(24).orbitCard()
    }

}

@MainActor
private struct OrbitViewingCard: View {
    @ObservedObject var owner: AppState
    @ObservedObject var account: AppState
    @ObservedObject var controller: DualClientController
    let profileID: String
    let openSettings: () -> Void
    private var active: Bool { controller.detected && controller.activeProfileID == profileID }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if controller.detected {
                    Circle().fill(active ? PanelPalette.success : PanelPalette.warning).frame(width: 5, height: 5)
                }
                Text((active ? "当前登录账号" : "正在查看账号") + " · " + owner.accountRole(profileID))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(PanelPalette.secondary)
                Spacer()
                OrbitPlanBadge(plan: account.snapshot?.planType ?? account.bucket?.planType ?? "待确认")
            }
            Text(account.snapshot?.displayEmail ?? "账号待核验")
                .font(.system(size: 16, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Divider()
            HStack(spacing: 6) {
                Text("已登录 \(owner.homeAccounts.count) 个账号")
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                Spacer(minLength: 4)
                if !active {
                    OrbitSwitchButton(owner: owner, account: account, controller: controller,
                                      profileID: profileID, title: "切换并重启")
                }
                Button { owner.accountPickerPresented.toggle() } label: {
                    HStack(spacing: 6) {
                        Text("查看账号")
                        Image(systemName: "chevron.down").font(.system(size: 8))
                    }
                }.buttonStyle(OrbitActionStyle(prominent: active))
                    .popover(isPresented: $owner.accountPickerPresented, arrowEdge: .bottom) {
                        OrbitAccountMenu(owner: owner, controller: controller, selectedID: profileID,
                                         openSettings: openSettings)
                    }
            }
        }.padding(12).orbitCard()
    }
}

@MainActor
private struct OrbitActivityTeaser: View {
    @ObservedObject var owner: AppState
    @ObservedObject var account: AppState
    var body: some View {
        Button { owner.orbitActivitySelected = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PanelPalette.longRing).frame(width: 26, height: 26)
                    .background(PanelPalette.longRing.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                Text("累计 Token").font(.system(size: 11)).foregroundStyle(PanelPalette.secondary)
                Text(account.verified ? TokenActivity.count(account.tokenActivity?.summary?.lifetimeTokens) : "尚未核验")
                    .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                Spacer(minLength: 4)
                HStack(spacing: 4) {
                    Text("查看活动").font(.system(size: 11, weight: .medium))
                    Image(systemName: "chevron.right").font(.system(size: 8))
                }.foregroundStyle(PanelPalette.secondary)
            }.padding(.horizontal, 12).padding(.vertical, 8).orbitCard()
        }.buttonStyle(.plain).help("打开 Token 活动统计与每日用量")
    }
}

@MainActor
struct OrbitAccountMenu: View {
    @ObservedObject var owner: AppState
    @ObservedObject var controller: DualClientController
    let selectedID: String
    var openSettings: (() -> Void)? = nil
    private var selected: String { owner.accountEntries.first(where: { $0.state === owner.displayedAccount })?.id ?? selectedID }
    private var canSwitch: Bool {
        owner.canSwitchAccount(selected)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("查看账号").font(.system(size: 13, weight: .semibold))
                Text("点击账号查看额度").font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
            }.padding(16)
            Divider().padding(.horizontal, 16)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(owner.homeAccounts, id: \.id) { entry in
                        OrbitAccountOption(account: entry.state, preferences: owner.preferences, role: owner.accountRole(entry.id),
                            active: controller.detected && entry.id == controller.activeProfileID,
                            selected: selected == entry.id) {
                                owner.selectedAccountID = entry.id
                                owner.accountPickerPresented = false
                            }
                    }
                }.padding(7)
            }.frame(height: min(320, CGFloat(owner.homeAccounts.count) * 94 + 14))
            if selected != controller.activeProfileID {
                Divider().padding(.horizontal, 16)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(owner.accountRole(selected)).font(.system(size: 11, weight: .medium))
                        Text("切换将重启客户端").font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                    }
                    Spacer()
                    Button("切换并重启") {
                        let target = selected
                        owner.accountPickerPresented = false
                        DispatchQueue.main.async { owner.pendingSwitchConfirmation = target }
                    }.buttonStyle(OrbitActionStyle(prominent: true)).disabled(!canSwitch)
                }.padding(16)
            }
            if let openSettings {
                Divider().padding(.horizontal, 16)
                Button {
                    owner.accountPickerPresented = false
                    owner.settingsTab = .accounts
                    openSettings()
                } label: {
                    HStack {
                        Label("管理账号", systemImage: "slider.horizontal.3")
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 9))
                    }.font(.system(size: 11)).padding(16).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }.frame(width: 360).background(PanelPalette.background)
    }
}

@MainActor
private struct OrbitAccountOption: View {
    @ObservedObject var account: AppState
    let preferences: Preferences
    let role: String
    let active: Bool
    let selected: Bool
    let choose: () -> Void

    var body: some View {
        let quota = QuotaPresentation.accountQuota(snapshot: account.snapshot,
                                                  verified: account.verified && !account.isSigningOut, now: account.now)
        Button(action: choose) {
            VStack(alignment: .leading, spacing: 7) {
                Text(account.snapshot?.displayEmail ?? "账号待核验")
                    .font(.system(size: 12, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    Text("\(role) · \(account.snapshot?.planType?.capitalized ?? "待确认")")
                    Spacer(minLength: 3)
                    if active {
                        Circle().fill(Color.green).frame(width: 4, height: 4)
                        Text("当前登录")
                    } else if selected {
                        Text("正在查看")
                        Image(systemName: "checkmark")
                    } else {
                        Image(systemName: "chevron.right")
                    }
                }.font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 15) {
                    if quota.windows.isEmpty {
                        Text("额度待核验").font(.system(size: 11)).foregroundStyle(PanelPalette.secondary)
                    }
                    ForEach(quota.windows) { window in
                        let rules = window.id == 0 ? preferences.primaryColorRules : preferences.secondaryColorRules
                        let custom = window.remaining.flatMap {
                            MenuBarRenderer.colorHex(remaining: $0, rules: preferences.followsQuotaColors ? rules : nil)
                        }
                            .map { Color(nsColor: MenuBarRenderer.color($0)) }
                        let windowColor = window.id == 0 ? PanelPalette.shortRing : PanelPalette.longRing
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(window.label).font(.system(size: 11)).foregroundStyle(PanelPalette.secondary)
                                if let remaining = window.remaining {
                                    let quotaColor = custom ?? Color(nsColor: PanelPalette.remainingQuotaColor(remaining))
                                    Text(QuotaPresentation.percent(remaining))
                                        .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                                        .foregroundStyle(quota.cached ? PanelPalette.secondary : quotaColor)
                                } else {
                                    Text("待核验").font(.system(size: 11)).foregroundStyle(PanelPalette.secondary)
                                }
                            }
                            if let remaining = window.remaining {
                                GeometryReader { proxy in
                                    Capsule().fill(PanelPalette.ringTrack)
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(quota.cached ? PanelPalette.secondary : custom ?? windowColor)
                                                .frame(width: proxy.size.width * CGFloat(remaining) / 100)
                                        }
                                }.frame(width: 80, height: 3)
                            }
                        }
                        .frame(minWidth: 83, alignment: .leading)
                    }
                    Spacer(minLength: 0)
                    if quota.cached {
                        Text("上次核验").font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                    }
                }
                .accessibilityElement(children: .ignore).accessibilityLabel("剩余额度，" + quota.summary)
            }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? PanelPalette.surface : PanelPalette.background,
                            in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }.buttonStyle(.plain).help("查看此账号的额度，登录不会改变")
            .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

@MainActor
private struct OrbitAccountInstruments: View {
    @ObservedObject var owner: AppState
    @ObservedObject var account: AppState
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("当前额度").font(.system(size: 13, weight: .medium))
                Spacer()
                Text("剩余百分比").font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
            }
            if let buckets = account.snapshot?.buckets, buckets.count > 1 {
                Picker("额度桶", selection: Binding(get: { account.bucket?.id ?? "codex" }, set: { account.preferences.selectedBucket = $0 })) {
                    ForEach(buckets) { Text($0.displayName).tag($0.id) }
                }.font(.system(size: 11))
            }
            HStack(alignment: .top, spacing: 22) {
                let usesSecondary = account.isFreeAccount && account.bucket?.primary == nil
                let primaryRules = owner.preferences.followsQuotaColors ? owner.preferences.primaryColorRules : nil
                let secondaryRules = owner.preferences.followsQuotaColors ? owner.preferences.secondaryColorRules : nil
                OrbitCompactGauge(state: account, window: usesSecondary ? account.bucket?.secondary : account.bucket?.primary,
                                  fallback: account.isFreeAccount ? "周期额度" : "短周期额度",
                                  color: usesSecondary ? PanelPalette.longRing : PanelPalette.shortRing,
                                  rules: usesSecondary ? secondaryRules : primaryRules)
                if !account.isFreeAccount {
                    OrbitCompactGauge(state: account, window: account.bucket?.secondary, fallback: "长期额度",
                                      color: PanelPalette.longRing, rules: secondaryRules)
                }
            }
            if account.updateStatus.isWarning {
                Label(account.statusDetail, systemImage: account.updateStatus.symbol)
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.warning).fixedSize(horizontal: false, vertical: true)
            }
            if account.bucket?.spendControlReached == true || account.bucket?.rateLimitReachedType != nil {
                Label("服务商报告了使用限制，请同时查看客户端提示。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.warning)
            }
        }.padding(13).orbitCard()
    }
}

@MainActor
private struct OrbitCompactGauge: View {
    @ObservedObject var state: AppState
    let window: QuotaWindow?
    let fallback: String
    let color: Color
    let rules: [PercentageColorRule]?
    private var amount: String { QuotaPresentation.value(window, verified: state.verified, now: state.now) }
    private var remaining: Double? { amount == "--" ? nil : window?.remaining }
    private var configuredColor: Color? {
        MenuBarRenderer.colorHex(window: window, rules: rules, verified: state.verified && !state.isStale && !state.isSigningOut, now: state.now)
            .map { Color(nsColor: MenuBarRenderer.color($0)) }
    }
    var body: some View {
        let customColor = configuredColor
        let low = (remaining ?? 100) <= 20
        let accent = customColor ?? (low ? PanelPalette.warning : color)
        let resetLabel = QuotaPresentation.resetLabel(window, now: state.now)
        let countdown = state.verified && !state.isSigningOut ? QuotaPresentation.resetCountdown(window, now: state.now) : nil
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Circle().fill(accent).frame(width: 7, height: 7)
                Text(window?.label ?? fallback).font(.system(size: 11)).foregroundStyle(PanelPalette.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(amount.replacingOccurrences(of: "%", with: "")).font(.system(size: 34, weight: .medium)).tracking(-1).monospacedDigit()
                if amount.hasSuffix("%") { Text("%").font(.system(size: 15)) }
            }.foregroundStyle(customColor ?? (low ? PanelPalette.warning : PanelPalette.primary))
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(PanelPalette.ringTrack)
                    Capsule().fill(accent).frame(width: proxy.size.width * CGFloat(min(100, max(0, remaining ?? 0))) / 100)
                }
            }.frame(height: 5)
            Text(resetLabel).font(.system(size: 10))
                .foregroundStyle(PanelPalette.secondary).fixedSize(horizontal: false, vertical: true)
            if let countdown {
                Text(countdown).font(.system(size: 10, weight: .medium)).monospacedDigit()
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(PanelPalette.surface, in: Capsule())
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([window?.label ?? fallback, "\(state.isStale ? "上次" : "")剩余 \(amount)", resetLabel, countdown].compactMap { $0 }.joined(separator: "，"))
            .help(window?.isResetPending(at: state.now) == true ? "等待服务商确认重置，不自动补成 100%" : "两个周期额度独立计算，不相加")
    }
}

