import SwiftUI

@MainActor
struct ResetCreditSectionView: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void
    var allowsReminders = true
    var initiallyExpanded = false
    private var summary: ResetCreditSummary? { state.verified ? state.snapshot?.resetCredits : nil }
    private var earliest: Date? { summary?.availableDetails.compactMap(\.expiryDate).filter { $0 > state.now }.min() }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("重置卡").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { state.settingsTab = .reminders; openSettings() } label: { Label("提醒设置", systemImage: "bell") }
                    .buttonStyle(OrbitActionStyle())
                    .help(allowsReminders ? "设置当前登录账号的到期提醒" : "提醒跟随客户端当前登录账号，不跟随正在查看的备用账号")
            }
            if let summary {
                if let expiry = earliest {
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("最近一张将在").font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                            Text(ResetCreditSummary.compactRemainingLabel(until: expiry, now: state.now))
                                .font(.system(size: 24, weight: .medium)).monospacedDigit().tracking(-0.8)
                                .foregroundStyle(expiry.timeIntervalSince(state.now) <= 86400 ? PanelPalette.warning : PanelPalette.primary)
                            Text("后到期 · " + ResetCreditSummary.expiryLabel(expiry))
                                .font(.system(size: 9)).monospacedDigit().foregroundStyle(PanelPalette.secondary)
                        }
                        Spacer(minLength: 10)
                        VStack(spacing: 2) {
                            Text(summary.availableCount.map(String.init) ?? "--").font(.system(size: 25, weight: .medium)).monospacedDigit()
                            Text(summary.availableCount == nil ? "数量待确认" : "张可用").font(.system(size: 8)).foregroundStyle(PanelPalette.secondary)
                        }.frame(width: 52, height: 52).background(PanelPalette.background, in: Circle())
                            .overlay { Circle().strokeBorder(PanelPalette.border) }
                    }
                } else {
                    Text(summary.availableCount == 0 ? "当前没有可用重置卡。" : "可用 \(summary.availableCount.map(String.init) ?? "待确认") 张 · 到期时间待核验")
                        .font(.system(size: 12, weight: .medium))
                }
                if !summary.availableDetails.isEmpty {
                    timeline(Array(summary.availableDetails.prefix(3)))
                    HStack {
                        Text(expiringCaption(summary)).font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                        Spacer()
                        Button { state.resetCreditsExpanded.toggle() } label: {
                            Label(state.resetCreditsExpanded ? "收起明细" : "卡片明细", systemImage: state.resetCreditsExpanded ? "chevron.up" : "chevron.down")
                        }.buttonStyle(OrbitActionStyle()).accessibilityValue(state.resetCreditsExpanded ? "已展开" : "已折叠")
                    }
                    if state.resetCreditsExpanded {
                        VStack(spacing: 0) {
                            ForEach(Array(summary.availableDetails.enumerated()), id: \.element.id) { index, card in
                                if index > 0 { Divider() }
                                detail(card, index: index)
                            }
                        }
                    }
                }
                if summary.credits == nil || (summary.availableCount ?? 0) > summary.availableDetails.count {
                    Text("部分卡片明细未返回；只展示已知日期，不推算到期时间。")
                        .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                }
                if state.isStale { Text("以上为上次核验记录，请重新核验。").font(.system(size: 10)).foregroundStyle(PanelPalette.warning) }
            } else {
                Text(state.verified ? "服务暂未返回重置卡信息，不代表可用数量为零。" : "成功核验后显示当前账号的重置卡。")
                    .font(.system(size: 11)).foregroundStyle(PanelPalette.secondary)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(PanelPalette.background, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(PanelPalette.border) }
        .padding(.horizontal, OrbitLayout.inset)
    }
    private func expiringCaption(_ summary: ResetCreditSummary) -> String {
        let result = summary.expiringWithinThreeDays(now: state.now)
        if result.complete { return result.count == 0 ? "未来 72 小时内无到期卡片" : "3 天内 \(result.count) 张到期" }
        return result.count == 0 ? "未来 72 小时到期情况待确认" : "已知 3 天内 \(result.count) 张到期"
    }
    private func timeline(_ cards: [ResetCredit]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(PanelPalette.border).frame(height: 1)
                        Circle().fill(index == 0 ? PanelPalette.shortRing : PanelPalette.surface)
                            .frame(width: index == 0 ? 7 : 5, height: index == 0 ? 7 : 5)
                            .overlay { Circle().strokeBorder(index == 0 ? PanelPalette.shortRing : PanelPalette.secondary.opacity(0.4)) }
                    }.frame(height: 9)
                    Text(card.expiryDate.map { String(ResetCreditSummary.expiryLabel($0).dropFirst(5).prefix(5)) } ?? "日期待确认")
                        .font(.system(size: 11, weight: .medium)).monospacedDigit()
                    Text(card.expiryDate.map { QuotaPresentation.time($0) + ($0 <= state.now ? " 已到期，待核验" : " 到期") } ?? "未返回日期")
                        .font(.system(size: 9)).foregroundStyle(PanelPalette.secondary).lineLimit(2)
                }.frame(maxWidth: .infinity, alignment: .leading).accessibilityElement(children: .combine)
            }
        }.padding(.top, 5).help("仅展示最近三张已知卡片，完整日期见卡片明细；时间为北京时间")
    }
    private func detail(_ card: ResetCredit, index: Int) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("重置卡 \(index + 1)").font(.system(size: 10, weight: .medium))
                Text(card.expiryDate.map { ResetCreditSummary.expiryLabel($0) + " 到期 · 北京时间" } ?? "到期时间未返回")
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(PanelPalette.secondary)
            }
            Spacer()
            Text(card.expiryDate.map { ResetCreditSummary.remainingLabel(until: $0, now: state.now) } ?? "待确认")
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(PanelPalette.secondary)
        }.padding(.vertical, 11).accessibilityElement(children: .combine)
    }
}

@MainActor
struct ResetCreditReminderSettingsView: View {
    @ObservedObject var controller: ResetCreditReminderController
    @ObservedObject var lowQuota: LowQuotaReminderController

    var body: some View {
        Form {
            Section("低额度提醒") {
                Toggle("剩余额度达到阈值时提醒", isOn: Binding(get: { lowQuota.enabled }, set: { value in
                    Task { await lowQuota.setEnabled(value) }
                })).disabled(lowQuota.isUpdating)
                Picker("提醒阈值", selection: Binding(get: { lowQuota.threshold }, set: lowQuota.setThreshold)) {
                    ForEach(LowQuotaReminderController.thresholds, id: \.self) { value in
                        Text("\(value)%").tag(value)
                    }
                }.disabled(lowQuota.isUpdating)
                Text("当前登录账号的每个额度窗口在每次重置前最多提醒一次。")
                    .font(.caption).foregroundStyle(.secondary)
                if lowQuota.permission == .denied {
                    Button("在系统设置中允许通知") { controller.openSystemSettings() }
                } else if lowQuota.permission == .unavailable {
                    Text("当前运行方式不支持通知。").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("重置卡到期提醒") {
                Toggle("到期前 24 小时提醒", isOn: Binding(get: { controller.enabled }, set: { value in
                    Task { await controller.setEnabled(value) }
                })).disabled(controller.isUpdating)
                Text("首次开启时请求 macOS 通知权限。通知只包含到期时间，不包含账号信息，也不会自动使用重置卡。")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("系统通知", value: permissionLabel)
                Text(controller.message).font(.caption).foregroundStyle(.secondary)
                if controller.permission == .denied {
                    Button("打开系统通知设置") { controller.openSystemSettings() }
                }
            }
            Section("提醒规则") {
                Text("每张卡在到期前 24 小时提醒一次；开启或唤醒时若已进入 24 小时范围，会在成功核验后补提醒。")
                Text("同一账号、同一卡片的提醒会持久去重。发现卡片已使用、过期或账号变化后，取消对应提醒。只有数量而没有到期时间时不推算日期。")
                Text("开启提醒后每 15 分钟核验卡片状态，并在已知提醒时刻前额外核验；手动刷新可立即确认其他设备的变化。")
            }.font(.caption)
            Section("系统投递") {
                Text("已安排的本地通知在正常退出应用后仍可投递。通知基于最近一次成功核验，其他设备用卡后须再次核验才能取消。电脑关机、休眠或专注模式可能让提醒延后。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .onAppear { controller.refreshPermission() }
        .task { await lowQuota.refreshPermission() }
    }
    private var permissionLabel: String {
        switch controller.permission {
        case .unknown: return "尚未申请"
        case .allowed: return "已允许"
        case .denied: return "未允许"
        case .unavailable: return "当前运行方式不支持"
        }
    }
}
