import SwiftUI

@MainActor
struct ResetCreditSectionView: View {
    @ObservedObject var state: AppState
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("重置卡", systemImage: "ticket").font(.system(size: 12, weight: .semibold))
                Spacer()
                if state.verified, let count = state.snapshot?.resetCredits?.availableCount {
                    Text("可用 \(count) 张").font(.system(size: 12, weight: .medium)).monospacedDigit()
                } else { Text("待确认").font(.system(size: 10)).foregroundStyle(PanelPalette.secondary) }
            }
            if !state.verified {
                Text("核验成功后显示当前账号的重置卡。")
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
            } else if let summary = state.snapshot?.resetCredits {
                let expiring = summary.expiringWithinThreeDays(now: state.now)
                HStack {
                    Text("未来 72 小时内").font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                    Spacer()
                    Label(expiring.complete ? "3 天内到期 \(expiring.count) 张" : (expiring.count > 0 ? "3 天内已知 \(expiring.count) 张到期" : "3 天内到期待确认"), systemImage: "hourglass")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(expiring.count > 0 ? PanelPalette.warning : PanelPalette.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background((expiring.count > 0 ? PanelPalette.warning : PanelPalette.secondary).opacity(0.08), in: Capsule())
                }
                if let earliest = summary.availableDetails.compactMap(\.expiryDate).filter({ $0 > state.now }).min() {
                    expiryCard(earliest)
                }
                if summary.credits == nil {
                    Text("服务暂未返回卡片到期明细，无法安排过期提醒。")
                        .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                } else if !summary.availableDetails.isEmpty {
                    HStack {
                        Button { state.resetCreditsExpanded.toggle() } label: {
                            HStack(spacing: 6) {
                                Text("卡片明细").font(.system(size: 10))
                                Image(systemName: state.resetCreditsExpanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                            }
                        }.buttonStyle(.plain).foregroundStyle(PanelPalette.link)
                        .accessibilityLabel("卡片明细")
                        .accessibilityValue(state.resetCreditsExpanded ? "已展开" : "已折叠")
                        Spacer()
                        reminderButton
                    }.padding(.vertical, 4)
                    if state.resetCreditsExpanded {
                        VStack(spacing: 0) {
                            ForEach(Array(summary.availableDetails.enumerated()), id: \.element.id) { index, card in
                                if index > 0 { Divider().padding(.horizontal, 10) }
                                creditRow(card, index: index)
                            }
                        }
                        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
                        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.07), lineWidth: 1) }
                    }
                    if (summary.availableCount ?? 0) > summary.availableDetails.count {
                        Text("部分卡片明细未返回；仅为已知到期时间的卡片安排提醒。")
                            .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                    }
                } else {
                    Text(summary.availableCount == 0 ? "当前没有可用重置卡。" : "尚无可用的到期明细。")
                        .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                }
                if state.isStale { Text("以上为上次核验记录，请刷新确认。").font(.system(size: 10)).foregroundStyle(PanelPalette.warning) }
            } else {
                Text("当前服务未返回重置卡信息，不代表可用数量为零。")
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
            }
            if !state.verified || state.snapshot?.resetCredits?.availableDetails.isEmpty != false {
                reminderButton
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 15)
        .overlay(alignment: .top) { Rectangle().fill(Color.primary.opacity(0.09)).frame(height: 1) }
    }

    private func creditRow(_ card: ResetCredit, index: Int) -> some View {
        let expiry = card.expiryDate
        let urgent = expiry.map { $0.timeIntervalSince(state.now) <= 86400 } ?? false
        return HStack(spacing: 9) {
            Image(systemName: urgent ? "hourglass" : "ticket")
                .font(.system(size: 12)).foregroundStyle(urgent ? PanelPalette.warning : PanelPalette.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                Text("重置卡 \(index + 1)").font(.system(size: 10, weight: .medium))
                Text(expiry.map { ResetCreditSummary.expiryLabel($0) } ?? "到期时间未返回")
                    .font(.system(size: 9)).monospacedDigit().foregroundStyle(PanelPalette.secondary)
            }
            Spacer(minLength: 4)
            if let expiry {
                Text(expiry <= state.now ? "已到期，待核验" : ResetCreditSummary.remainingLabel(until: expiry, now: state.now))
                    .font(.system(size: 9, weight: .medium)).monospacedDigit()
                    .foregroundStyle(urgent ? PanelPalette.warning : PanelPalette.secondary)
            } else {
                Text("待确认").font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .accessibilityElement(children: .combine)
        .help("到期时间为北京时间")
    }

    private var reminderButton: some View {
        Button { state.settingsTab = .reminders; openSettings() } label: {
            Label("提醒设置", systemImage: "bell").font(.system(size: 10))
        }.buttonStyle(.plain).foregroundStyle(PanelPalette.link)
        .accessibilityLabel("设置重置卡到期提醒")
    }

    private func expiryCard(_ expiry: Date) -> some View {
        let urgent = expiry.timeIntervalSince(state.now) <= 86400
        let accent = urgent ? PanelPalette.warning : PanelPalette.link
        return HStack(spacing: 12) {
            Image(systemName: "ticket.fill").font(.system(size: 20)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 5) {
                Text(ResetCreditSummary.remainingLabel(until: expiry, now: state.now))
                    .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                Text(ResetCreditSummary.expiryLabel(expiry) + " 到期（北京时间）")
                    .font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                if urgent { Text("记得按需使用").font(.system(size: 9)).foregroundStyle(PanelPalette.secondary) }
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(accent.opacity(0.7)).frame(width: 3) }
    }

}

@MainActor
struct ResetCreditReminderSettingsView: View {
    @ObservedObject var controller: ResetCreditReminderController

    var body: some View {
        Form {
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
