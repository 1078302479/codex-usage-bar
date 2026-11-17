import SwiftUI

@MainActor
struct DualClientPanelView: View {
    @Environment(\.orbitPreview) private var preview
    @ObservedObject var state: AppState
    @ObservedObject var controller: DualClientController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if controller.isSwitching || !controller.detected {
                Label(controller.isSwitching ? "正在切换账号并重启客户端…" : "正在确认客户端登录账号，确认后即可切换。", systemImage: "info.circle")
                    .font(.system(size: 9)).foregroundStyle(PanelPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            }
            if let message = controller.message, !message.hasPrefix("已按所选账号重启") {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 9)).foregroundStyle(PanelPalette.warning)
                    .fixedSize(horizontal: false, vertical: true).padding(.bottom, 8)
            }
        }
        .padding(.horizontal, 20)
        .task {
            guard !preview else { return }
            while !Task.isCancelled {
                controller.detectRunningAccount()
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
        }
    }
}
