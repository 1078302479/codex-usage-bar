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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TideAvatar(index: owner.tideAvatarIndex(profileID))
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.snapshot?.accountLabel ?? "尚未登录或核验")
                        .font(.system(size: 13, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(status).font(.system(size: 11))
                        .foregroundStyle(active ? TidePalette.green : TidePalette.tertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                actions
            }
            if !duplicate {
                HStack(spacing: 9) {
                    let quota = QuotaPresentation.accountQuota(snapshot: account.snapshot, verified: account.verified && !account.isSigningOut, now: account.now)
                    TideRings(short: quota.windows.first?.remaining, long: quota.windows.dropFirst().first?.remaining, size: 52, stroke: 5)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(quota.windows) { window in
                            let source = window.id == 0 ? account.bucket?.primary : account.bucket?.secondary
                            let reset = source?.resetDate.map { window.id == 0 ? QuotaPresentation.time($0) : String(ResetCreditSummary.expiryLabel($0).dropFirst(5).prefix(5)) }
                            let amount = Text(window.remaining.map(QuotaPresentation.percent) ?? "--").bold().monospacedDigit()
                            Text("\(window.label) \(amount)\(reset.map { " · " + $0 } ?? "")")
                        }
                        let count = Text(account.snapshot?.resetCredits?.availableCount.map { "\($0) 张" } ?? "待核验").bold()
                        Text("重置卡 \(count)")
                    }.font(.system(size: 11)).foregroundStyle(TidePalette.secondary).lineLimit(1).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    if profileID != controller.activeProfileID {
                        OrbitSwitchButton(owner: owner, account: account, controller: controller, profileID: profileID, title: "切换")
                    }
                }
            }
            if owner.deletingAccountID == profileID || account.isSigningOut || account.isSigningIn {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text(owner.deletingAccountID == profileID ? "正在删除…" : account.isSigningOut ? "正在退出…" : "正在登录…")
                    if account.isSigningIn { Button("取消") { account.cancelSignIn() }.buttonStyle(.link) }
                }.font(.caption).foregroundStyle(TidePalette.secondary)
            } else if duplicate || account.updateStatus != .verified {
                Text(duplicate ? "此账号已添加，请登录另一个账号。" : (account.loginMessage ?? account.statusDetail))
                    .font(.caption).foregroundStyle(TidePalette.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
        .background(active ? TidePalette.card : TidePalette.settingsSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay { if active { RoundedRectangle(cornerRadius: 14).strokeBorder(TidePalette.green, lineWidth: 1.5) } }
    }

    private var status: String {
        let plan = account.snapshot?.planType?.capitalized
        let state = active ? "当前登录" : duplicate ? "重复账号" :
            account.updateStatus == .verified ? "已核验 " + (account.snapshot.map { QuotaPresentation.time($0.observedAt) } ?? "") : account.updateStatus.title
        return [plan, state].compactMap { $0 }.joined(separator: " · ")
    }

    private var actions: some View {
        Menu {
            Button("核验账号") { account.refresh() }.disabled(account.isRefreshing || account.isSigningOut)
            Button(duplicate ? "换一个账号…" : (account.snapshot == nil ? "登录账号…" : "重新登录…")) {
                account.signInSecondAccount()
            }.disabled(account.isSigningIn || account.isSigningOut || (duplicate && (!controller.detected || controller.isSwitching)))
            if !duplicate {
                Button("退出登录", role: .destructive) { account.signOut() }.disabled(account.isSigningOut)
                if profileID != controller.activeProfileID {
                    Button("删除账号…", role: .destructive) { owner.requestAccountDeletion(profileID) }
                        .disabled(!owner.canDeleteAccount(profileID))
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TidePalette.tertiary).accessibilityLabel("更多账号操作")
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    }
}
