import SwiftUI

@MainActor
struct DualAccountPanelView: View {
    @ObservedObject var primary: AppState
    @ObservedObject var secondary: AppState
    let openSettings: () -> Void
    private var selectedB: Bool { primary.showingSecondAccountDetails }

    private var selected: AppState { selectedB ? secondary : primary }
    private func manageAccounts() { primary.settingsTab = .connection; openSettings() }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("账号总览").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("管理账号", action: manageAccounts).buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.link)
            }.padding(.horizontal, 20).padding(.top, 17).padding(.bottom, 12)

            HStack(alignment: .top, spacing: 10) {
                DualAccountQuotaCard(state: primary, letter: "A", subtitle: "本机账号", selected: !selectedB,
                    accent: PanelPalette.shortRing, choose: { primary.showingSecondAccountDetails = false }, manage: manageAccounts)
                DualAccountQuotaCard(state: secondary, letter: "B", subtitle: "独立账号", selected: selectedB,
                    accent: PanelPalette.longRing, choose: { primary.showingSecondAccountDetails = true }, manage: manageAccounts)
            }.padding(.horizontal, 20).padding(.bottom, 14)

            if primary.snapshot?.accountScope != nil, primary.snapshot?.accountScope == secondary.snapshot?.accountScope {
                Label("两个位置为同一账号，额度不会相加。", systemImage: "info.circle")
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.warning)
                    .padding(.horizontal, 20).padding(.bottom, 12)
            }

            Divider()
            HStack(spacing: 8) {
                Text(selectedB ? "B" : "A")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(selectedB ? PanelPalette.longRing : PanelPalette.shortRing)
                    .frame(width: 22, height: 22)
                    .background((selectedB ? PanelPalette.longRing : PanelPalette.shortRing).opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text("账号详情").font(.system(size: 11, weight: .semibold))
                    Text(selected.snapshot?.accountLabel ?? "等待账号核验")
                        .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                }
                Spacer()
                Text("点击上方账号切换").font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
            }.padding(.horizontal, 20).padding(.vertical, 13)

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
        VStack(alignment: .leading, spacing: 0) {
            Button(action: choose) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 6) {
                        Text(letter).font(.system(size: 11, weight: .bold))
                            .foregroundStyle(accent).frame(width: 25, height: 25)
                            .background(accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                        Text(subtitle).font(.system(size: 10, weight: .medium)).foregroundStyle(PanelPalette.secondary)
                        Spacer(minLength: 2)
                        if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(accent) }
                    }
                    Text(state.snapshot?.accountLabel ?? "尚未登录")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        .padding(.top, 10)
                    Text(state.snapshot?.planType?.capitalized ?? "等待核验")
                        .font(.system(size: 9)).foregroundStyle(PanelPalette.secondary).padding(.top, 3)
                    metric(state.bucket?.primary, fallback: "短周期")
                        .padding(.top, 18)
                    metric(state.bucket?.secondary, fallback: "长期")
                        .padding(.top, 15)
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .accessibilityLabel("查看账号 " + letter + " 详情")
                .accessibilityValue(accessibilitySummary)

            Divider().padding(.top, 14).padding(.bottom, 10)
            HStack(spacing: 4) {
                Circle().fill(state.updateStatus.isWarning ? PanelPalette.warning : accent).frame(width: 4, height: 4)
                Text(state.isSigningIn ? "等待登录" : state.updateStatus.title)
                    .font(.system(size: 9)).foregroundStyle(PanelPalette.secondary).lineLimit(1)
                Spacer(minLength: 3)
                if state.isRefreshing || state.isSigningIn { ProgressView().controlSize(.mini) }
                else {
                    Button { state.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                        .buttonStyle(.plain).foregroundStyle(PanelPalette.secondary)
                        .accessibilityLabel("刷新账号 " + letter + " 额度")
                }
            }.help(state.statusDetail)
            if state.lastFailure != nil {
                Text(state.statusDetail).font(.system(size: 9)).foregroundStyle(PanelPalette.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 8)
            }
            if !state.verified && letter == "B" {
                Button("登录或管理账号", action: manage).buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.link).padding(.top, 8)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(selected ? accent.opacity(0.055) : Color.primary.opacity(0.018), in: RoundedRectangle(cornerRadius: 13))
        .overlay { RoundedRectangle(cornerRadius: 13).strokeBorder(selected ? accent.opacity(0.65) : Color.primary.opacity(0.06), lineWidth: selected ? 1.2 : 0.5) }
    }

    private func metric(_ window: QuotaWindow?, fallback: String) -> some View {
        let valid = state.verified && window?.isResetPending(at: state.now) == false
        let remaining = valid ? window?.remaining : nil
        let color = (remaining ?? 100) <= 10 ? PanelPalette.warning : accent
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(window?.windowDurationMins == 300 ? "5 小时" : window?.windowDurationMins == 10080 ? "7 天" : fallback)
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                Spacer(minLength: 3)
                Text(QuotaPresentation.value(window, verified: state.verified, now: state.now) + (state.isStale && valid ? "*" : ""))
                    .font(.system(size: 23, weight: .semibold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(PanelPalette.primary)
            }
            GeometryReader { proxy in
                Capsule().fill(PanelPalette.ringTrack)
                Capsule().fill(color).frame(width: proxy.size.width * CGFloat((remaining ?? 0) / 100))
            }.frame(height: 4).accessibilityHidden(true)
            Text(state.verified ? QuotaPresentation.resetLabel(window, now: state.now) : "重置时间未知")
                .font(.system(size: 9)).foregroundStyle(PanelPalette.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}
