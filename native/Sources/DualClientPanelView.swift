import SwiftUI

@MainActor
struct DualClientPanelView: View {
    @ObservedObject var state: AppState
    @ObservedObject var controller: DualClientController
    private var target: QuotaSnapshot? { controller.activeSecondary ? state.snapshot : state.secondAccount?.snapshot }
    private var canSwitch: Bool {
        controller.detected && !controller.isSwitching && (controller.activeSecondary ? state.verified : state.secondAccount?.verified == true)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                controller.switchToOtherAccount(cliPath: state.preferences.cliPath)
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(PanelPalette.link.opacity(0.08))
                        if controller.isSwitching { ProgressView().controlSize(.small) }
                        else { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 14, weight: .medium)).foregroundStyle(PanelPalette.link) }
                    }.frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(controller.detected ? "备用账号" : "正在识别执行账号")
                            .font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                        Text(controller.detected ? (target?.accountLabel ?? "请先登录备用账号") : "确认后即可切换")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(PanelPalette.primary)
                            .lineLimit(1).minimumScaleFactor(0.85)
                    }
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(controller.isSwitching ? "正在切换…" : "切换并重启")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(canSwitch ? PanelPalette.link : PanelPalette.secondary)
                        Text("请先保存任务").font(.system(size: 8)).foregroundStyle(PanelPalette.secondary)
                    }
                }.frame(maxWidth: .infinity).contentShape(Rectangle())
                    .padding(.vertical, 12)
            }
            .buttonStyle(.plain).disabled(!canSwitch)
            .accessibilityLabel("切换到备用账号并重启客户端")
            .accessibilityHint("请先保存任务。目标：" + (target?.accountLabel ?? "尚未登录"))
            .help("切换到备用账号并重启客户端，请先保存正在进行的任务")
            if let message = controller.message, !message.hasPrefix("已按所选账号重启") {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 9)).foregroundStyle(PanelPalette.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 20).padding(.top, 4)
    }
}
