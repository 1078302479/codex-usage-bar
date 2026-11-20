import SwiftUI

@MainActor
struct DualClientPanelView: View {
    @Environment(\.orbitPreview) private var preview
    @ObservedObject var controller: DualClientController
    static func isVisible(_ controller: DualClientController) -> Bool {
        controller.isSwitching || !controller.detected || switchError(controller) != nil
    }
    private static func switchError(_ controller: DualClientController) -> String? {
        controller.message.flatMap { $0.hasPrefix("已按所选账号重启") ? nil : $0 }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isSwitching || !controller.detected {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label(statusText, systemImage: "info.circle")
                        .foregroundStyle(PanelPalette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if controller.detectionIssue != nil && !controller.isSwitching {
                        Button("重新核验") { controller.detectRunningAccount(force: true) }
                            .buttonStyle(.link).disabled(preview || controller.detecting)
                    }
                }.font(.system(size: 10)).padding(.vertical, 4)
            }
            if let message = Self.switchError(controller) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 9)).foregroundStyle(PanelPalette.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            }
        }
    }
    private var statusText: String {
        if controller.isSwitching { return "正在切换账号并重启客户端…" }
        if controller.detecting { return "正在识别 Codex 当前账号…" }
        return controller.detectionIssue?.rawValue ?? "正在识别 Codex 当前账号…"
    }
}
