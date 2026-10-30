import SwiftUI

@MainActor
struct DualAccountPanelView: View {
    @ObservedObject var primary: AppState
    @ObservedObject var secondary: AppState
    @ObservedObject var controller: DualClientController
    let openSettings: () -> Void
    private var selectedB: Bool { primary.showingSecondAccountDetails }

    private var selected: AppState { selectedB ? secondary : primary }
    private func manageAccounts() { primary.settingsTab = .connection; openSettings() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("账号额度").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("管理账号", action: manageAccounts).buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.link)
            }.padding(.horizontal, 20).padding(.top, 17).padding(.bottom, 12)

            VStack(spacing: 8) {
                ForEach(controller.orderedSecondary, id: \.self) { isB in
                    DualAccountQuotaCard(state: isB ? secondary : primary,
                        letter: isB ? "B" : "A", subtitle: controller.roleLabel(secondary: isB), selected: selectedB == isB,
                        accent: isB ? PanelPalette.longRing : PanelPalette.shortRing,
                        choose: { primary.showingSecondAccountDetails = isB }, manage: manageAccounts)
                }
            }.padding(.horizontal, 20).padding(.bottom, 4)

            if primary.snapshot?.accountScope != nil, primary.snapshot?.accountScope == secondary.snapshot?.accountScope {
                Label("两个位置为同一账号，额度不会相加。", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.warning)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }

            DualClientPanelView(state: primary, controller: primary.dualClient)
            Divider()
            HStack(spacing: 5) {
                Text("正在查看 " + (selectedB ? "B" : "A")).font(.system(size: 10, weight: .semibold))
                Text("· " + (selected.snapshot?.accountLabel ?? "等待核验"))
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 13).padding(.bottom, 3)

            ResetCreditSectionView(state: selected, openSettings: openSettings, allowsReminders: !selectedB)
                .id(selectedB ? "credits-B" : "credits-A")
            TokenActivityView(state: selected).id(selectedB ? "activity-B" : "activity-A")
            HStack(spacing: 6) {
                Label(selected.updateStatus.title, systemImage: selected.updateStatus.symbol)
                Spacer()
                if let date = selected.lastSuccessfulAt { Text("核验于 " + QuotaPresentation.time(date)).monospacedDigit() }
            }.font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                .padding(.horizontal, 20).padding(.bottom, 14)
                .help(selected.statusDetail + "\n" + selected.watchDescription)
        }
    }
}

@MainActor
private struct DualAccountQuotaCard: View {
    @ObservedObject var state: AppState
    let letter: String
    let subtitle: String
    let selected: Bool
    let accent: Color
    let choose: () -> Void
    let manage: () -> Void

    private var accessibilitySummary: String {
        let status = selected ? "已选择" : "未选择"
        let account = state.snapshot?.accountLabel ?? "尚未登录"
        let short = QuotaPresentation.value(state.bucket?.primary, verified: state.verified, now: state.now)
        let long = QuotaPresentation.value(state.bucket?.secondary, verified: state.verified, now: state.now)
        return "\(status)，\(account)，短期剩余 \(short)，长期剩余 \(long)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button(action: choose) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 5) {
                                Text(letter).font(.system(size: 10, weight: .bold)).foregroundStyle(accent)
                                Text(subtitle).font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                                if selected { Text("查看中").font(.system(size: 8)).foregroundStyle(accent) }
                            }
                            Text(state.snapshot?.accountLabel ?? "尚未登录")
                                .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            Text(state.snapshot?.planType?.capitalized ?? "等待核验")
                                .font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        metric(state.bucket?.primary, fallback: "短周期")
                        metric(state.bucket?.secondary, fallback: "长期")
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel("查看账号 " + letter + " 详情").accessibilityValue(accessibilitySummary)
                VStack(spacing: 12) {
                    Circle().fill(state.updateStatus.isWarning ? PanelPalette.warning : accent).frame(width: 4, height: 4)
                    if state.isRefreshing || state.isSigningIn { ProgressView().controlSize(.mini) }
                    else {
                        Button { state.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                            .buttonStyle(.plain).foregroundStyle(PanelPalette.secondary)
                            .accessibilityLabel("刷新账号 " + letter + " 额度")
                    }
                }.frame(width: 14).help(state.statusDetail)
            }
            if state.lastFailure != nil {
                Text(state.statusDetail).font(.system(size: 9)).foregroundStyle(PanelPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.verified && letter == "B" {
                Button("登录或管理账号", action: manage).buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.link)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? accent.opacity(0.065) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .leading) {
            if selected { Capsule().fill(accent).frame(width: 3, height: 30) }
        }
    }

    private func metric(_ window: QuotaWindow?, fallback: String) -> some View {
        let valid = state.verified && window?.isResetPending(at: state.now) == false
        let remaining = valid ? window?.remaining : nil
        let color = (remaining ?? 100) <= 10 ? PanelPalette.warning : accent
        return VStack(alignment: .leading, spacing: 4) {
            Text(window?.windowDurationMins == 300 ? "5 小时剩余" : window?.windowDurationMins == 10080 ? "7 天剩余" : fallback)
                .font(.system(size: 8)).foregroundStyle(PanelPalette.secondary)
            Text(QuotaPresentation.value(window, verified: state.verified, now: state.now) + (state.isStale && valid ? "*" : ""))
                .font(.system(size: 18, weight: .semibold, design: .rounded)).monospacedDigit()
            GeometryReader { proxy in
                Capsule().fill(PanelPalette.ringTrack)
                Capsule().fill(color).frame(width: proxy.size.width * CGFloat((remaining ?? 0) / 100))
            }.frame(height: 3).accessibilityHidden(true)
            Text(state.verified ? QuotaPresentation.resetLabel(window, now: state.now) : "重置时间未知")
                .font(.system(size: 8)).foregroundStyle(PanelPalette.secondary).lineLimit(1).minimumScaleFactor(0.75)
        }.frame(width: 90, alignment: .leading)
    }
}
