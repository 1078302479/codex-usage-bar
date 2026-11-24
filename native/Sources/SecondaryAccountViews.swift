import SwiftUI

@MainActor
struct AccountSettingsCard: View {
    @ObservedObject var owner: AppState
    @ObservedObject var account: AppState
    @ObservedObject var controller: DualClientController
    let profileID: String

    private var duplicate: Bool { owner.duplicateAccountIDs.contains(profileID) }
    private var active: Bool { controller.detected && controller.activeProfileID == profileID }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(account.snapshot?.accountLabel ?? "尚未登录或核验")
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let plan = account.snapshot?.planType ?? account.bucket?.planType {
                    OrbitPlanBadge(plan: plan)
                }
                Spacer(minLength: 4)
                Group {
                    if active {
                        Label("主账号 · 当前登录", systemImage: "circle.fill").foregroundStyle(PanelPalette.success)
                    } else {
                        Text(owner.accountRole(profileID)).foregroundStyle(PanelPalette.secondary)
                    }
                }.font(.system(size: 10, weight: .medium))
            }
            if !duplicate {
                Text(quotaSummary).font(.system(size: 11)).monospacedDigit().foregroundStyle(PanelPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if account.isSigningIn {
                    ProgressView().controlSize(.small).accessibilityLabel("正在登录")
                    Button("取消登录") { account.cancelSignIn() }.buttonStyle(OrbitActionStyle())
                } else {
                    Button("核验账号") { account.refresh() }
                        .buttonStyle(OrbitActionStyle()).disabled(account.isRefreshing || account.isSigningOut)
                    Button(duplicate ? "换一个账号…" : (account.snapshot == nil ? "登录账号…" : "重新登录…")) {
                        account.signInSecondAccount()
                    }.buttonStyle(OrbitActionStyle())
                        .disabled(account.isSigningOut || (duplicate && (!controller.detected || controller.isSwitching)))
                    if !duplicate {
                        Menu {
                            Button("退出登录", role: .destructive) { account.signOut() }
                                .disabled(account.isSigningOut)
                            if profileID != controller.activeProfileID {
                                Button("删除账号…", role: .destructive) { owner.requestAccountDeletion(profileID) }
                                    .disabled(!owner.canDeleteAccount(profileID))
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle").accessibilityLabel("更多账号操作")
                        }.menuStyle(.borderlessButton).fixedSize()
                    }
                }
                Spacer()
                if owner.deletingAccountID == profileID || account.isSigningOut {
                    ProgressView().controlSize(.small)
                    Text(owner.deletingAccountID == profileID ? "正在删除…" : "正在退出…")
                        .font(.caption).foregroundStyle(PanelPalette.secondary)
                }
                if profileID != controller.activeProfileID && !duplicate {
                    OrbitSwitchButton(owner: owner, account: account, controller: controller, profileID: profileID,
                                      title: "切换并重启")
                }
            }
            if duplicate || account.loginMessage != nil || account.updateStatus != .verified {
                Text(duplicate ? "此账号已添加。若要添加备用账号，请在官方登录页选择另一个账号。" : (account.loginMessage ?? account.statusDetail))
                    .font(.caption).foregroundStyle(PanelPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.padding(12).orbitCard()
    }

    private var quotaSummary: String {
        let verified = account.verified && !account.isSigningOut
        let quota = QuotaPresentation.accountQuota(snapshot: account.isSigningOut ? nil : account.snapshot,
                                                    verified: verified, now: account.now)
        let creditCount = verified ? account.snapshot?.resetCredits?.availableCount : nil
        let creditText = creditCount.map { "重置卡 \($0) 张" + (account.isStale && !quota.cached ? "（上次核验）" : "") } ?? "重置卡待核验"
        return quota.summary + " · " + creditText
    }
}

