import SwiftUI

@MainActor
struct SecondaryAccountSettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("账号 B", value: state.snapshot?.accountLabel ?? "尚未登录或核验")
            if let plan = state.snapshot?.planType { LabeledContent("套餐", value: plan.capitalized) }
            HStack {
                Button(state.snapshot == nil ? "登录第二个账号…" : "重新登录账号 B…") { state.signInSecondAccount() }
                    .disabled(state.isSigningIn)
                if state.isSigningIn {
                    ProgressView().controlSize(.small)
                    Button("取消登录") { state.cancelSignIn() }
                } else {
                    Button("核验账号 B") { state.refresh() }.disabled(state.isRefreshing)
                }
            }
            Text(state.loginMessage ?? state.statusDetail)
                .font(.caption).foregroundStyle(.secondary)
            Text("通过官方网页登录，请选择另一个账号。第二账号的登录独立保存，不会覆盖本机 Codex 登录。关闭监测保留登录，重新启用可恢复。第二账号暂不发送重置卡通知。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

