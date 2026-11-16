import SwiftUI

@MainActor
struct DualAccountPanelView: View {
    @ObservedObject var primary: AppState
    @ObservedObject var controller: DualClientController
    let openSettings: () -> Void
    private var selectedID: String { primary.accountEntries.first(where: { $0.state === selected })?.id ?? "primary" }
    private var selected: AppState { primary.displayedAccount }
    private func manageAccounts() { primary.managingAccounts = true }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(primary.managingAccounts ? "账号管理" : "账号额度").font(.system(size: 12, weight: .semibold))
                Spacer()
                if primary.managingAccounts {
                    Button { primary.addAccount(startLogin: false) } label: { Label("添加账号", systemImage: "plus") }
                        .buttonStyle(.plain).font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(PanelPalette.link.opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                        .foregroundStyle(PanelPalette.link).disabled(primary.deletingAccountID != nil)
                    Button("完成") { primary.managingAccounts = false }
                        .buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(PanelPalette.link)
                } else {
                    Button("管理账号", action: manageAccounts).buttonStyle(.plain)
                        .font(.system(size: 10)).foregroundStyle(PanelPalette.link)
                }
            }.padding(.horizontal, 20).padding(.top, 17).padding(.bottom, 12)

            if primary.managingAccounts {
                Text("在此管理账号，与设置页同步").font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 10)
            }
            VStack(spacing: 8) {
                ForEach(primary.managingAccounts ? primary.orderedAccounts : primary.homeAccounts, id: \.id) { entry in
                    if primary.managingAccounts && entry.state.snapshot == nil {
                        PendingAccountLoginCard(owner: primary, state: entry.state, profileID: entry.id)
                    } else {
                    DualAccountQuotaCard(state: entry.state,
                        subtitle: primary.accountRole(entry.id), selected: selectedID == entry.id,
                        accent: entry.id == controller.activeProfileID ? PanelPalette.shortRing : PanelPalette.longRing,
                        profileID: entry.id, owner: primary, controller: controller, cliPath: primary.preferences.cliPath,
                        choose: { primary.selectedAccountID = entry.id }, manage: manageAccounts)
                    }
                }
            }.padding(.horizontal, 20).padding(.bottom, 4)

            if primary.managingAccounts {
                Text("移除账号仅清除登录信息，保留本地项目与聊天。")
                    .font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                    .padding(.horizontal, 20).padding(.vertical, 10)
                if primary.deletingAccountID != nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在删除账号…").font(.system(size: 10))
                    }.padding(.horizontal, 20).padding(.bottom, 8)
                }
                if let message = primary.accountManagementMessage {
                    Text(message).font(.system(size: 9)).foregroundStyle(PanelPalette.warning).padding(.horizontal, 20)
                }
            }
            DualClientPanelView(state: primary, controller: primary.dualClient)
            Divider()
            HStack(spacing: 5) {
                Text("正在查看 " + primary.accountRole(selectedID)).font(.system(size: 10, weight: .semibold))
                Text("· " + (selected.snapshot?.accountLabel ?? "等待核验"))
                    .font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                Spacer()
            }.padding(.horizontal, 20).padding(.top, 13).padding(.bottom, 3)

            ResetCreditSectionView(state: selected, openSettings: { primary.settingsTab = .reminders; openSettings() }, allowsReminders: controller.detected && selectedID == controller.activeProfileID, initiallyExpanded: primary.expandsCreditDetailsByDefault)
                .id("credits-" + selectedID)
            if primary.showsTokenActivity {
                TokenActivityView(state: selected).id("activity-" + selectedID)
            }

        }
    }
}

@MainActor
private struct DualAccountQuotaCard: View {
    @ObservedObject var state: AppState
    let subtitle: String
    let selected: Bool
    let accent: Color
    let profileID: String
    @ObservedObject var owner: AppState
    @ObservedObject var controller: DualClientController
    let cliPath: String
    let choose: () -> Void
    let manage: () -> Void

    private var canSwitch: Bool {
        controller.detected && !controller.isSwitching && profileID != controller.activeProfileID && state.verified && !state.isSigningOut
    }

    private var accessibilitySummary: String {
        let status = selected ? "已选择" : "未选择"
        let account = state.snapshot?.accountLabel ?? "尚未登录"
        let short = QuotaPresentation.value(state.bucket?.primary, verified: state.verified, now: state.now)
        if state.isFreeAccount {
            let value = QuotaPresentation.value(state.bucket?.primary ?? state.bucket?.secondary, verified: state.verified, now: state.now)
            return "\(status)，\(account)，额度剩余 \(value)"
        }
        let long = QuotaPresentation.value(state.bucket?.secondary, verified: state.verified, now: state.now)
        return "\(status)，\(account)，短期剩余 \(short)，长期剩余 \(long)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if owner.deletingAccountID == profileID {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在删除…").font(.system(size: 10)).foregroundStyle(PanelPalette.secondary)
                }
            }
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(subtitle).font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                        if controller.detected && profileID == controller.activeProfileID {
                            HStack(spacing: 3) {
                                Circle().fill(Color.green).frame(width: 4, height: 4)
                                Text("当前使用").font(.system(size: 8)).foregroundStyle(PanelPalette.secondary)
                            }
                        } else {
                            Button {
                                controller.switchToProfile(profileID, cliPath: cliPath)
                            } label: {
                                HStack(spacing: 3) {
                                    if controller.isSwitching && controller.targetProfileID == profileID {
                                        ProgressView().controlSize(.mini)
                                    } else {
                                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 9, weight: .medium))
                                    }
                                    Text(controller.isSwitching && controller.targetProfileID == profileID ? "切换中" : "切换")
                                        .font(.system(size: 9, weight: .semibold))
                                }
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .foregroundStyle(canSwitch ? PanelPalette.link : PanelPalette.secondary)
                                .background((canSwitch ? PanelPalette.link : PanelPalette.secondary).opacity(0.1), in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!canSwitch)
                                .accessibilityLabel("切换到" + subtitle + "并重启客户端")
                                .help("切换到此账号并重启客户端，请先保存任务")
                        }
                        if owner.managingAccounts && profileID != controller.activeProfileID {
                            Menu {
                                Button { state.signInSecondAccount() } label: { Label("重新登录", systemImage: "person.badge.key") }
                                Button { state.signOut() } label: { Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right") }
                                Divider()
                                Button(role: .destructive) { owner.requestAccountDeletion(profileID) } label: { Label("删除账号…", systemImage: "trash") }
                                    .disabled(!owner.canDeleteAccount(profileID))
                            } label: {
                                Image(systemName: "ellipsis").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(PanelPalette.secondary)
                                    .frame(width: 22, height: 22)
                                    .background(Color.primary.opacity(0.05), in: Circle())
                            }
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                            .disabled(state.isSigningIn || state.isSigningOut || controller.isSwitching || owner.deletingAccountID != nil)
                            .accessibilityLabel("更多账号操作").help("重新登录、退出或删除账号")
                        }
                        if selected && profileID != controller.activeProfileID {
                            Text("查看中").font(.system(size: 8)).foregroundStyle(accent)
                        }
                    }.fixedSize(horizontal: true, vertical: false)
                    Button(action: choose) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.snapshot?.accountLabel ?? "尚未登录")
                                .font(.system(size: 11, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                            Text(state.isPlusAccount ? "Plus" : state.isFreeAccount ? "Free" : (state.snapshot?.planType?.capitalized ?? "等待核验"))
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(state.isPlusAccount ? PanelPalette.link : PanelPalette.secondary)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background((state.isPlusAccount ? PanelPalette.link : PanelPalette.secondary).opacity(state.isPlusAccount ? 0.12 : 0.08), in: Capsule())
                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                        .accessibilityLabel("查看" + subtitle + "详情").accessibilityValue(accessibilitySummary)
                }.frame(maxWidth: .infinity, alignment: .leading)
                Button(action: choose) {
                    HStack(spacing: 10) {
                        if state.isFreeAccount {
                            metric(state.bucket?.primary ?? state.bucket?.secondary, fallback: "额度剩余", width: 190)
                        } else {
                            metric(state.bucket?.primary, fallback: "短周期")
                            metric(state.bucket?.secondary, fallback: "长期")
                        }
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("查看" + subtitle + "额度详情")
                VStack(spacing: 12) {
                    Circle().fill(state.updateStatus.isWarning ? PanelPalette.warning : accent).frame(width: 4, height: 4)
                    if state.isRefreshing || state.isSigningIn { ProgressView().controlSize(.mini) }
                    else {
                        Button { state.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 10)) }
                            .buttonStyle(.plain).foregroundStyle(PanelPalette.secondary)
                            .accessibilityLabel("刷新" + subtitle + "额度")
                    }
                }.frame(width: 14).help(state.statusDetail)
            }
            if state.lastFailure != nil && !state.isSigningIn {
                Text(state.statusDetail).font(.system(size: 9)).foregroundStyle(PanelPalette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.verified {
                HStack {
                    Button(state.isSigningIn ? "正在登录…" : "登录账号") { state.signInSecondAccount() }
                        .disabled(state.isSigningIn || state.isSigningOut || controller.isSwitching || owner.deletingAccountID != nil)
                    if state.isSigningIn { Button("取消") { state.cancelSignIn() } }
                    if let message = state.loginMessage { Text(message).font(.system(size: 9)).foregroundStyle(PanelPalette.secondary) }
                }.buttonStyle(.plain)
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

    private func metric(_ window: QuotaWindow?, fallback: String, width: CGFloat = 90) -> some View {
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
        }.frame(width: width, alignment: .leading)
    }
}

@MainActor
private struct PendingAccountLoginCard: View {
    @ObservedObject var owner: AppState
    @ObservedObject var state: AppState
    let profileID: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "person.badge.plus").font(.system(size: 19)).foregroundStyle(PanelPalette.link)
                VStack(alignment: .leading, spacing: 4) {
                    Text("新账号").font(.system(size: 11, weight: .semibold))
                    Text(state.isSigningIn ? "请在浏览器完成登录" : "通过官方网页登录")
                        .font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                }
                Spacer()
                if state.isSigningIn {
                    ProgressView().controlSize(.small)
                    Button("取消") { state.cancelSignIn() }.buttonStyle(.plain)
                } else {
                    Button("登录") { state.signInSecondAccount() }.buttonStyle(.borderedProminent)
                        .disabled(state.isSigningOut || owner.dualClient.isSwitching || owner.deletingAccountID != nil)
                }
                Button { owner.requestAccountDeletion(profileID) } label: {
                    Image(systemName: "trash").foregroundStyle(Color.red)
                }.buttonStyle(.plain).disabled(!owner.canDeleteAccount(profileID))
                    .accessibilityLabel("删除待登录账号")
            }
            if let message = state.loginMessage {
                Text(message).font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
            }
        }.padding(12)
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4])) }
    }
}
