import SwiftUI

@MainActor
struct SecondaryAccountSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("账号", value: state.snapshot?.accountLabel ?? "尚未登录或核验")
            if let plan = state.snapshot?.planType { LabeledContent("套餐", value: plan.capitalized) }
            HStack {
                Button(state.snapshot == nil ? "登录账号…" : "重新登录账号…") { state.signInSecondAccount() }
                    .disabled(state.isSigningIn || state.isSigningOut)
                if state.isSigningIn {
                    ProgressView().controlSize(.small)
                    Button("取消登录") { state.cancelSignIn() }
                } else {
                    Button("核验账号") { state.refresh() }.disabled(state.isRefreshing || state.isSigningOut)
                    Button("退出登录", role: .destructive) { state.signOut() }
                        .disabled(state.isSigningOut)
                    if state.isSigningOut { ProgressView().controlSize(.small) }
                }
            }
            Text(state.loginMessage ?? state.statusDetail)
                .font(.caption).foregroundStyle(.secondary)
            Text("通过官方网页登录，请选择要添加的用户。登录独立保存，各账号共用本地工作空间，仅主账号发送重置卡通知。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

